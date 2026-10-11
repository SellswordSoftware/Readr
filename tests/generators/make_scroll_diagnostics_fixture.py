"""Generate a reproducible EPUB for manual Scroll rendering diagnostics."""

from html import escape
from pathlib import Path
import xml.etree.ElementTree as ET
import zipfile


OUTPUT = Path(__file__).resolve().parents[1] / 'fixtures' / 'scroll-diagnostics.epub'
CHAPTERS = [
    ('ascii', '1. ASCII control', 'A', False, False, 180),
    ('unicode', '2. Unicode stress', 'U', True, False, 180),
    ('buffer', '3. Buffer stress', 'B', False, True, 120),
    ('combined', '4. Combined stress', 'C', True, True, 120),
]


def document(title, body):
    return (
        '<?xml version="1.0" encoding="UTF-8"?>'
        '<html xmlns="http://www.w3.org/1999/xhtml">'
        f'<head><title>{escape(title)}</title></head><body>{body}</body></html>'
    )


def chapter(title, prefix, unicode_text, delayed, count):
    instructions = [
        'Use Scroll mode. Try Newsleak Serif, then Roobert 20 Medium.',
        'Scroll slowly, then quickly. Reverse over the same numbered lines.',
        'Watch for stray symbols, missing text, loading dots, and sudden new lines.',
        'Numbers identify source lines; wrapping depends on the selected font.',
    ]
    if unicode_text:
        instructions.append('Accents and curly punctuation below are intentional. Extra symbols are not.')
    else:
        instructions.append('All visible text in this chapter is plain ASCII. No dots are printed in the numbered lines.')
    if delayed:
        instructions.append('This chapter deliberately adds invisible XML comments to slow text preparation. Wait if text is loading.')
    else:
        instructions.append('This chapter uses ordinary markup with no deliberate decoding delay.')
    patterns = (
        ['café naïve résumé déjà vu.', '“Hello”—“Goodbye”…', 'José François Zoë Björn.', 'Don’t stop—keep scrolling.']
        if unicode_text else
        ['The quick brown fox jumps.', 'Keep this numbered line in view.', 'Read forward and then reverse.', 'No symbols should appear here.']
    )
    # Valid invisible markup stretches the existing 256-byte frame budget without
    # changing visible lines. Keep this separate from the ordinary-content control.
    padding = '<!--' + ('invisible padding ' * 114) + '-->' if delayed else ''
    lines = ''.join(
        f'{padding}{escape(f"{prefix}{number:04d} {patterns[(number - 1) % len(patterns)]}")}<br/>'
        for number in range(1, count + 1)
    )
    body = f'<h1>{escape(title)}</h1>'
    body += ''.join(f'<p>{escape(text)}</p>' for text in instructions)
    body += f'<p>START NUMBERED LINES</p><p>{lines}</p><p>END {prefix}{count:04d}</p>'
    return document(title, body)


def validate(path):
    with zipfile.ZipFile(path) as archive:
        assert archive.testzip() is None
        first = archive.infolist()[0]
        assert first.filename == 'mimetype' and first.compress_type == zipfile.ZIP_STORED
        assert archive.read('mimetype') == b'application/epub+zip'
        for name in archive.namelist():
            if name.endswith(('.xml', '.opf', '.xhtml')):
                ET.fromstring(archive.read(name))
        ns = {'opf': 'http://www.idpf.org/2007/opf'}
        package = ET.fromstring(archive.read('book.opf'))
        manifest = {item.attrib['id']: item.attrib['href'] for item in package.findall('opf:manifest/opf:item', ns)}
        spine = package.findall('opf:spine/opf:itemref', ns)
        assert len(spine) == len(CHAPTERS)
        for ref, (name, _, prefix, _, delayed, count) in zip(spine, CHAPTERS):
            assert manifest[ref.attrib['idref']] == f'{name}.xhtml'
            root = ET.fromstring(archive.read(f'{name}.xhtml'))
            text = ''.join(root.find('{http://www.w3.org/1999/xhtml}body').itertext())
            assert all(f'{prefix}{number:04d} ' in text for number in range(1, count + 1))
            assert 'invisible padding' not in text
            assert (b'<!--' in archive.read(f'{name}.xhtml')) == delayed
        nav = ET.fromstring(archive.read('nav.xhtml'))
        assert [a.attrib['href'] for a in nav.iter('{http://www.w3.org/1999/xhtml}a')] == [f'{item[0]}.xhtml' for item in CHAPTERS]


def main():
    manifest = ''.join(f'<item id="{name}" href="{name}.xhtml" media-type="application/xhtml+xml"/>' for name, *_ in CHAPTERS)
    spine = ''.join(f'<itemref idref="{name}"/>' for name, *_ in CHAPTERS)
    entries = {
        'mimetype': 'application/epub+zip',
        'META-INF/container.xml': '<container xmlns="urn:oasis:names:tc:opendocument:xmlns:container" version="1.0"><rootfiles><rootfile full-path="book.opf" media-type="application/oebps-package+xml"/></rootfiles></container>',
        'book.opf': (
            '<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id">'
            '<metadata xmlns:dc="http://purl.org/dc/elements/1.1/">'
            '<dc:identifier id="id">urn:uuid:df6d3ac6-1eba-4df9-8ef7-fc0ef6d75288</dc:identifier>'
            '<dc:title>Readr Scroll Diagnostics</dc:title><dc:language>en</dc:language>'
            '<meta property="dcterms:modified">2026-10-11T00:00:00Z</meta></metadata>'
            f'<manifest>{manifest}<item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/></manifest><spine>{spine}</spine></package>'
        ),
        'nav.xhtml': document('Contents', '<nav xmlns:epub="http://www.idpf.org/2007/ops" epub:type="toc"><h1>Contents</h1><ol>' + ''.join(f'<li><a href="{name}.xhtml">{escape(title)}</a></li>' for name, title, *_ in CHAPTERS) + '</ol></nav>'),
    }
    for name, title, prefix, unicode_text, delayed, count in CHAPTERS:
        entries[f'{name}.xhtml'] = chapter(title, prefix, unicode_text, delayed, count)
    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(OUTPUT, 'w') as archive:
        for name, text in entries.items():
            info = zipfile.ZipInfo(name, date_time=(2026, 10, 11, 0, 0, 0))
            info.compress_type = zipfile.ZIP_STORED if name == 'mimetype' else zipfile.ZIP_DEFLATED
            archive.writestr(info, text.encode('utf-8'))
    validate(OUTPUT)
    print(f'Validated {OUTPUT}: {len(CHAPTERS)} chapters, 600 numbered lines, {OUTPUT.stat().st_size} bytes')


if __name__ == '__main__':
    main()
