"""Fetch pinned Xiph sources and retain the portable library sources."""

import hashlib
import io
import json
from pathlib import Path
import tarfile
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
VENDOR = ROOT / "tests" / "reference" / "vendor"
PACKAGES = [
    ("ogg", "1.3.6", "83e6704730683d004d20e21b8f7f55dcb3383cdf84c0daedf30bde175f774638"),
    ("vorbis", "1.3.7", "0e982409a9c3fc82ee06e08205b1355e5c6aa4c36bca58146ef399621b0ce5ab"),
    ("theora", "1.2.0", "279327339903b544c28a92aeada7d0dcfd0397b59c2f368cc698ac56f515906e"),
]


def main():
    """Verify release checksums before writing the selected source files."""
    manifest = []
    for name, version, checksum in PACKAGES:
        archive = f"lib{name}-{version}.tar.gz"
        url = f"https://downloads.xiph.org/releases/{name}/{archive}"
        data = urllib.request.urlopen(url, timeout=60).read()
        actual = hashlib.sha256(data).hexdigest()
        if actual != checksum:
            raise RuntimeError(f"Checksum mismatch for {archive}: {actual}")
        count = 0
        with tarfile.open(fileobj=io.BytesIO(data), mode="r:gz") as source:
            for member in source.getmembers():
                parts = Path(member.name).parts[1:]
                if not member.isfile() or not parts or ".." in parts:
                    continue
                relative = Path(*parts)
                keep = (
                    relative.as_posix() in {"COPYING", "LICENSE", "AUTHORS", "README.md", "README"}
                    or (parts[0] == "include" and relative.suffix == ".h")
                    or (parts[0] in {"src", "lib"} and len(parts) == 2
                        and relative.suffix in {".c", ".h"})
                )
                if keep:
                    target = VENDOR / name / relative
                    target.parent.mkdir(parents=True, exist_ok=True)
                    target.write_bytes(source.extractfile(member).read())
                    count += 1
        manifest.append({"name": name, "version": version, "url": url,
                         "sha256": checksum, "files": count})
        print(f"Vendored {name} {version}: {count} files")
    (VENDOR / "sources.json").write_text(
        json.dumps(manifest, indent=2) + "\n", encoding="utf-8", newline="\n"
    )


if __name__ == "__main__":
    main()
