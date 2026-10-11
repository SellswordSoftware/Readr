"""Generate a small EPUB for Unicode content and font-fallback hardware checks."""
from pathlib import Path
import zipfile


def main():
    path = Path(__file__).resolve().parents[1] / 'fixtures' / 'unicode-text.epub'
    paragraphs = [
        'Accents: café naïve résumé déjà vu. Names: José François Zoë Björn.',
        'Punctuation: “Curly quotes.” Don’t replace them—keep the text… Next sentence.',
        'Literal spacing: one\u00a0two\u202fthree\u2003four\u3000five.',
        'Entity spacing: one&nbsp;two&#160;three&#x202f;four&#x2003;five.',
        'Numeric accents: caf&#233; na&#239;ve r&#233;sum&#233;.',
        'Other scripts: Ελληνικά Кириллица 東京 中文. Fonts without these glyphs show question marks.',
    ]
    chapter = '<html xmlns="http://www.w3.org/1999/xhtml"><body><h1>Café — résumé</h1>'
    chapter += ''.join(f'<p>{text}</p>' for _ in range(4) for text in paragraphs)
    chapter += '</body></html>'
    with zipfile.ZipFile(path, 'w') as archive:
        archive.writestr('mimetype', 'application/epub+zip', compress_type=zipfile.ZIP_STORED)
        archive.writestr('META-INF/container.xml', '<container xmlns="urn:oasis:names:tc:opendocument:xmlns:container" version="1.0"><rootfiles><rootfile full-path="book.opf" media-type="application/oebps-package+xml"/></rootfiles></container>', compress_type=zipfile.ZIP_DEFLATED)
        archive.writestr('book.opf', '<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="id">unicode-text-test</dc:identifier><dc:title>Unicode Text Test</dc:title><dc:language>en</dc:language></metadata><manifest><item id="chapter" href="chapter.xhtml" media-type="application/xhtml+xml"/><item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/></manifest><spine><itemref idref="chapter"/></spine></package>', compress_type=zipfile.ZIP_DEFLATED)
        archive.writestr('nav.xhtml', '<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><body><nav epub:type="toc"><ol><li><a href="chapter.xhtml">Café — résumé</a></li></ol></nav></body></html>', compress_type=zipfile.ZIP_DEFLATED)
        archive.writestr('chapter.xhtml', chapter, compress_type=zipfile.ZIP_DEFLATED)
    with zipfile.ZipFile(path) as archive:
        assert archive.testzip() is None
    print(f'Validated {path}: {path.stat().st_size} bytes')


if __name__ == '__main__':
    main()
