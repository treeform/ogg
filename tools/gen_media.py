"""Generate the tiny synthetic corpus and independent FFmpeg decode oracles."""

import argparse
import hashlib
import json
import math
from pathlib import Path
import shutil
import struct
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
DATA = ROOT / "tests" / "data"
CASES = [
    {"name": "mono", "rate": 22050, "channels": 1, "samples": 5512},
    {"name": "stereo", "rate": 48000, "channels": 2, "samples": 12000},
    {"name": "silence", "rate": 8000, "channels": 1, "samples": 2000},
    {"name": "continued", "rate": 48000, "channels": 1, "samples": 12000},
    {"name": "video420", "width": 64, "height": 48, "format": "yuv420p"},
    {"name": "video422", "width": 64, "height": 48, "format": "yuv422p"},
    {"name": "video444", "width": 64, "height": 48, "format": "yuv444p"},
    {"name": "mixed", "width": 82, "height": 50, "format": "yuv420p",
     "rate": 48000, "channels": 2, "samples": 24000},
]


def run(args):
    """Run a media tool, reporting any failure immediately."""
    subprocess.run(args, check=True)


def digest(path):
    """Return the SHA-256 of one checked-in fixture."""
    return hashlib.sha256(path.read_bytes()).hexdigest()


def make_sources(case, directory):
    """Create original PCM tones and moving RGB bars without external media."""
    if "channels" in case:
        pcm = bytearray()
        for i in range(case["samples"]):
            for channel in range(case["channels"]):
                sample = 0.0
                if case["name"] != "silence":
                    frequency = 440 if channel == 0 else 660
                    amplitude = 0.25 if channel == 0 else 0.125
                    sample = amplitude * math.sin(2 * math.pi * frequency * i / case["rate"])
                pcm.extend(struct.pack("<f", sample))
        (directory / "audio.f32").write_bytes(pcm)
    if "width" in case:
        rgb = bytearray()
        colors = [(220, 40, 30), (40, 210, 60), (30, 60, 220), (210, 190, 40)]
        for frame in range(6):
            for y in range(case["height"]):
                for x in range(case["width"]):
                    color = colors[((x + frame * 7) * 4 // case["width"]) % 4]
                    if (x // 8 + y // 8 + frame) % 5 == 0:
                        color = tuple(value // 2 for value in color)
                    rgb.extend(color)
        (directory / "video.rgb").write_bytes(rgb)


def generate():
    """Encode fixtures and record recipes, decoder identities, and checksums."""
    DATA.mkdir(parents=True, exist_ok=True)
    manifest = {
        "license": "CC0-1.0",
        "source": "Original mathematical tones and moving RGB patterns from tools/gen_media.py",
        "ffmpeg": subprocess.check_output(["ffmpeg", "-version"], text=True).splitlines()[0],
        "audio_decoder": "FFmpeg native vorbis (not libvorbis)",
        "video_decoder": "FFmpeg native theora (not libtheora)",
        "cases": [],
    }
    for case in CASES:
        with tempfile.TemporaryDirectory(prefix="ogg-corpus-") as temporary:
            directory = Path(temporary)
            make_sources(case, directory)
            args = ["ffmpeg", "-hide_banner", "-loglevel", "error", "-y"]
            if "width" in case:
                args += ["-f", "rawvideo", "-pixel_format", "rgb24", "-video_size",
                         f"{case['width']}x{case['height']}", "-framerate", "12",
                         "-i", str(directory / "video.rgb")]
            if "channels" in case:
                args += ["-f", "f32le", "-ar", str(case["rate"]), "-ac",
                         str(case["channels"]), "-i", str(directory / "audio.f32")]
            if case["name"] == "continued":
                metadata = directory / "metadata.txt"
                metadata.write_text(";FFMETADATA1\ncomment=" + "packet-boundary " * 5000 + "\n")
                args += ["-f", "ffmetadata", "-i", str(metadata), "-map_metadata", "1"]
            else:
                args += ["-map_metadata", "-1"]
            args += ["-fflags", "+bitexact"]
            if "width" in case:
                args += ["-c:v", "libtheora", "-q:v", "5", "-pix_fmt", case["format"],
                         "-flags:v", "+bitexact"]
            if "channels" in case:
                args += ["-c:a", "libvorbis", "-q:a", "4", "-flags:a", "+bitexact"]
            name = case["name"]
            media = DATA / (name + (".ogv" if "width" in case else ".ogg"))
            args += [str(media)]
            run(args)
            entry = dict(case, file=media.name, sha256=digest(media))
            entry["encode"] = [arg.replace(str(directory), "<generated>")
                               .replace(str(DATA), "tests/data") for arg in args]
            if "channels" in case:
                reference = DATA / (name + ".f32")
                raw = directory / "decoded.f32"
                run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
                     "-flags2", "+skip_manual", "-c:a", "vorbis", "-i", str(media),
                     "-map", "0:a:0", "-c:a", "pcm_f32le", "-f", "f32le", str(raw)])
                # The first Vorbis packet primes the overlap buffer. Decode with
                # manual trimming, remove that packet's output, and keep exactly
                # the known source length (also recorded by the EOS granule).
                frames = json.loads(subprocess.check_output([
                    "ffprobe", "-v", "error", "-flags2", "+skip_manual",
                    "-select_streams", "a:0", "-show_frames", "-read_intervals", "%+#1",
                    "-of", "json", str(media)
                ], text=True))["frames"]
                preroll = frames[0]["nb_samples"]
                size = 4 * case["channels"]
                decoded = raw.read_bytes()[preroll * size:(preroll + case["samples"]) * size]
                if len(decoded) != case["samples"] * size:
                    raise RuntimeError(f"Incomplete independent audio decode: {name}")
                reference.write_bytes(decoded)
                entry["audio_preroll"] = preroll
                entry["audio_reference"] = reference.name
                entry["audio_sha256"] = digest(reference)
                entry["decoded_samples"] = reference.stat().st_size // (4 * case["channels"])
            if "width" in case:
                reference = DATA / (name + ".yuv")
                run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
                     "-c:v", "theora", "-i", str(media), "-map", "0:v:0",
                     "-pix_fmt", case["format"], "-fps_mode", "passthrough",
                     "-f", "rawvideo", str(reference)])
                entry["video_reference"] = reference.name
                entry["video_sha256"] = digest(reference)
                entry["frames"] = 6
                entry["fps"] = 12
            manifest["cases"].append(entry)
            print(f"Generated {media.name}: {media.stat().st_size} bytes")
    (DATA / "manifest.json").write_text(
        json.dumps(manifest, indent=2) + "\n", encoding="utf-8", newline="\n"
    )


def verify():
    """Verify the checked-in corpus without requiring FFmpeg or network access."""
    manifest = json.loads((DATA / "manifest.json").read_text())
    for case in manifest["cases"]:
        for file_key, hash_key in [("file", "sha256"),
                                   ("audio_reference", "audio_sha256"),
                                   ("video_reference", "video_sha256")]:
            if file_key in case and digest(DATA / case[file_key]) != case[hash_key]:
                raise RuntimeError(f"Fixture checksum mismatch: {case[file_key]}")
    print(f"Verified {len(manifest['cases'])} corpus cases")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--verify", action="store_true")
    options = parser.parse_args()
    if options.verify:
        verify()
    else:
        if not shutil.which("ffmpeg") or not shutil.which("ffprobe"):
            raise SystemExit("FFmpeg and ffprobe with Vorbis and Theora support are required")
        generate()
