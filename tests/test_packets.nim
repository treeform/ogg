## Compare native packet boundaries and metadata directly with libogg.
import std/[os, unittest]
import ogg/[bindings, packets]

type
  CStream {.importc: "ogg_stream_state", header: "<ogg/ogg.h>".} = object
  CPage {.importc: "ogg_page", header: "<ogg/ogg.h>".} = object
    header, body: pointer
    header_len, body_len: clong
  CPacket {.importc: "ogg_packet", header: "<ogg/ogg.h>".} = object
    packet: pointer
    bytes, b_o_s, e_o_s: clong
    granulepos, packetno: int64

{.push header: "<ogg/ogg.h>".}
proc init(s: var CStream, serial: cint): cint {.importc: "ogg_stream_init".}
proc clear(s: var CStream): cint {.importc: "ogg_stream_clear".}
proc pageIn(s: var CStream, p: var CPage): cint {.importc: "ogg_stream_pagein".}
proc packetOut(s: var CStream, p: var CPacket): cint {.importc: "ogg_stream_packetout".}
proc serial(p: var CPage): cint {.importc: "ogg_page_serialno".}
{.pop.}

proc comparePackets(data: string) =
  ## Walks the same pages with libogg and compares each completed packet.
  var
    reader = PacketReader(data: data)
    streams: array[2, CStream]
    serials: seq[cint]
    pos = 0
    packet: Packet
  defer:
    for i in 0 ..< serials.len:
      discard streams[i].clear()
  while pos < data.len:
    let segments = ord(data[pos + 26])
    var bodyLen = 0
    for i in 0 ..< segments:
      bodyLen += ord(data[pos + 27 + i])
    let headerLen = 27 + segments
    var page = CPage(header: data[pos].unsafeAddr, header_len: clong(headerLen),
      body: cast[pointer](cast[uint](data[pos].unsafeAddr) + uint(headerLen)),
      body_len: clong(bodyLen))
    let serial = page.serial()
    if serial notin serials:
      require serials.len < streams.len
      require streams[serials.len].init(serial) == 0
      serials.add(serial)
    let stream = serials.find(serial)
    require streams[stream].pageIn(page) == 0
    var expected: CPacket
    while streams[stream].packetOut(expected) > 0:
      require reader.nextPacket(packet)
      check packet.stream == stream
      check packet.number == expected.packetno
      check (packet.number == 0) == (expected.b_o_s != 0)
      check packet.eos == (expected.e_o_s != 0)
      check packet.granule == expected.granulepos
      require packet.data.len == expected.bytes
      if expected.bytes > 0:
        check equalMem(packet.data[0].unsafeAddr, expected.packet, packet.data.len)
    pos += headerLen + bodyLen
  check not reader.nextPacket(packet)

suite "Native Ogg packets":
  for path in walkFiles(currentSourcePath().parentDir / "data" / "*.og?"):
    test path.extractFilename:
      comparePackets(readFile(path))

