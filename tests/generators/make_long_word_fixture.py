"""Generate a hardware fixture for long ASCII and UTF-8 word wrapping."""
from pathlib import Path
import zipfile


def main():
    path = Path(__file__).resolve().parents[1] / 'fixtures' / 'long-word-wrap.epub'
    path.parent.mkdir(parents=True, exist_ok=True)
    maximum = 'W' * 384
    unicode_word = 'café' * 76  # 380 UTF-8 bytes, with accents at split boundaries.
    url = 'https://example.com/' + 'abcdefghij0123456789' * 16
    chapter = '<html xmlns="http://www.w3.org/1999/xhtml"><body><h1>Word wrapping test</h1>'
    chapter += '<p>Each long token remains one selectable word. Try Pages, Scroll, RSVP transfers, font changes, and reopening.</p>'
    chapter += '<p>Before maximum ' + maximum + ' after maximum.</p>'
    chapter += '<p>Before Unicode ' + unicode_word + ' after Unicode.</p>'
    chapter += '<p>Before URL ' + url + ' after URL.</p>'
    chapter += '<ul><li>' + ('M' * 382) + '</li><li>Following list item.</li></ul>'
    chapter += '<hr/><p>End of wrapping test.</p></body></html>'
    with zipfile.ZipFile(path, 'w', compression=zipfile.ZIP_DEFLATED) as archive:
        archive.writestr('mimetype', 'application/epub+zip', compress_type=zipfile.ZIP_STORED)
        archive.writestr('META-INF/container.xml', '<container xmlns="urn:oasis:names:tc:opendocument:xmlns:container" version="1.0"><rootfiles><rootfile full-path="book.opf" media-type="application/oebps-package+xml"/></rootfiles></container>')
        archive.writestr('book.opf', '<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="id">long-word-wrap-test</dc:identifier><dc:title>Word Wrapping Test</dc:title><dc:language>en</dc:language></metadata><manifest><item id="chapter" href="chapter.xhtml" media-type="application/xhtml+xml"/></manifest><spine><itemref idref="chapter"/></spine></package>')
        archive.writestr('chapter.xhtml', chapter)
    with zipfile.ZipFile(path) as archive:
        assert archive.testzip() is None
    assert len(maximum.encode()) == 384
    assert len(unicode_word.encode()) == 380
    assert len(url.encode()) <= 384
    print(f'Validated {path}: {path.stat().st_size} bytes')


if __name__ == '__main__':
    main()
