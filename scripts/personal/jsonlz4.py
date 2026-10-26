"""Minimal Mozilla JSONLZ4 reader and literal-only writer (no dependency install)."""
import json
import struct

MAGIC = b'mozLz40\0'

def decompress(raw):
    assert raw[:8] == MAGIC, 'Not a Mozilla LZ4 file'
    expected = struct.unpack('<I', raw[8:12])[0]
    data = raw[12:]
    out = bytearray()
    pos = 0
    while pos < len(data):
        token = data[pos]
        pos += 1
        length = token >> 4
        if length == 15:
            while True:
                value = data[pos]; pos += 1; length += value
                if value != 255: break
        out.extend(data[pos:pos+length]); pos += length
        if pos == len(data): break
        offset = int.from_bytes(data[pos:pos+2], 'little'); pos += 2
        assert 0 < offset <= len(out)
        match = (token & 15) + 4
        if (token & 15) == 15:
            while True:
                value = data[pos]; pos += 1; match += value
                if value != 255: break
        for _ in range(match): out.append(out[-offset])
        assert len(out) <= expected
    assert len(out) == expected
    return bytes(out)

def loads(raw):
    return json.loads(decompress(raw))

def dumps(value):
    payload = json.dumps(value, ensure_ascii=False, separators=(',', ':')).encode('utf-8')
    size = len(payload)
    block = bytearray([min(size,15) << 4])
    if size >= 15:
        remaining = size - 15
        while remaining >= 255:
            block.append(255); remaining -= 255
        block.append(remaining)
    block.extend(payload)
    raw = MAGIC + struct.pack('<I', size) + block
    assert loads(raw) == value
    return raw
