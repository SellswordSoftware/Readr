"""Generate a valid EPUB whose chapters exercise zero-output DEFLATE work."""
from pathlib import Path
import struct
import zipfile
import zlib


def compressed(kind, count, text):
    bits = []

    def write(value, width):
        bits.extend((value >> shift) & 1 for shift in range(width))

    def align_byte():
        bits.extend([0] * (-len(bits) % 8))

    for _ in range(count):
        write(0, 1)
        if kind == 'stored':
            write(0, 2)
            align_byte()
            write(0, 16)
            write(65535, 16)
        elif kind == 'fixed':
            write(1, 2)
            write(0, 7)
        else:
            write(2, 2)
            write(0, 5)
            write(0, 5)
            write(14, 4)
            for symbol in (16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1):
                write(1 if symbol <= 1 else 0, 3)
            for _ in range(256):
                write(0, 1)
            write(1, 1)
            write(1, 1)
            write(0, 1)
    write(1, 1)
    write(0, 2)
    align_byte()
    write(len(text), 16)
    write(len(text) ^ 65535, 16)
    for byte in text:
        write(byte, 8)
    data = bytes(sum(bits[start + shift] << shift for shift in range(8)) for start in range(0, len(bits), 8))
    assert zlib.decompress(data, -15) == text
    return data


def main():
    chapters = [('stored', 20000), ('fixed', 200), ('dynamic', 200)]
    manifest = ''.join(f'<item id="{kind}" href="{kind}.xhtml" media-type="application/xhtml+xml"/>' for kind, _ in chapters)
    spine = ''.join(f'<itemref idref="{kind}"/>' for kind, _ in chapters)
    entries = [
        ('mimetype', b'application/epub+zip', None),
        ('META-INF/container.xml', b'<container xmlns="urn:oasis:names:tc:opendocument:xmlns:container" version="1.0"><rootfiles><rootfile full-path="book.opf" media-type="application/oebps-package+xml"/></rootfiles></container>', None),
        ('book.opf', f'<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="id">decoder-work</dc:identifier><dc:title>Decoder Work Test</dc:title><dc:language>en</dc:language></metadata><manifest>{manifest}<item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/></manifest><spine>{spine}</spine></package>'.encode(), None),
        ('nav.xhtml', ('<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><body><nav epub:type="toc"><ol>' + ''.join(f'<li><a href="{kind}.xhtml">{kind.title()} empty blocks</a></li>' for kind, _ in chapters) + '</ol></nav></body></html>').encode(), None),
    ]
    for kind, count in chapters:
        text = (f'<html xmlns="http://www.w3.org/1999/xhtml"><body><h1>{kind.title()} empty blocks</h1>' + ''.join(f'<p>Paragraph {number}. The decoder has completed the empty blocks. Reading controls, page turns, mode changes, and returning to Library should remain responsive.</p>' for number in range(1, 21)) + '</body></html>').encode()
        entries.append((f'{kind}.xhtml', text, compressed(kind, count, text)))
    output = bytearray()
    directory = bytearray()
    for name, text, data in entries:
        name = name.encode()
        method = 8 if data is not None else 0
        data = text if data is None else data
        crc = zlib.crc32(text)
        offset = len(output)
        output.extend(struct.pack('<IHHHHHIIIHH', 0x04034b50, 20, 0, method, 0, 0, crc, len(data), len(text), len(name), 0) + name + data)
        directory.extend(struct.pack('<IHHHHHHIIIHHHHHII', 0x02014b50, 20, 20, 0, method, 0, 0, crc, len(data), len(text), len(name), 0, 0, 0, 0, 0, offset) + name)
    offset = len(output)
    output.extend(directory)
    output.extend(struct.pack('<IHHHHIIH', 0x06054b50, 0, 0, len(entries), len(entries), len(directory), offset, 0))
    path = Path(__file__).resolve().parents[1] / 'fixtures' / 'decoder-work.epub'
    path.write_bytes(output)
    with zipfile.ZipFile(path) as archive:
        assert archive.testzip() is None
    print(f'Validated {path}: {len(entries)} entries, {len(output)} bytes')


if __name__ == '__main__':
    main()
