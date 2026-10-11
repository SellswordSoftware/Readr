"""Generate an EPUB with two readable appendices omitted from its TOC."""
from pathlib import Path
import base64
import zipfile


def main():
    path = Path(__file__).resolve().parents[1] / 'fixtures' / 'chapter-navigation.epub'
    names = ['wrap0000', 'body', 'appendix-a', 'appendix-b', 'image-wrapper']
    manifest = ''.join(f'<item id="{name}" href="{name}.xhtml" media-type="application/xhtml+xml"/>' for name in names)
    spine = ''.join(f'<itemref idref="{name}"/>' for name in names)
    paragraphs = {
        'wrap0000': '<img src="pixel.png" alt="Cover"/>',
        'body': '<h1>Main body</h1><p>The TOC lists only this document. Continue to Appendix A, then Appendix B. Reverse traversal from Appendix B should return to Appendix A.</p>',
        'appendix-a': '<h1>Appendix A</h1><p>This readable document is absent from the TOC. Forward goes to Appendix B; backward goes to the main body.</p>',
        'appendix-b': '<h1>Appendix B</h1><p>This second readable document is also absent from the TOC. Backward must return to Appendix A.</p>',
        'image-wrapper': '<img src="pixel.png" alt="Illustration"/><p><a href="body.xhtml">Wrapper navigation link.</a></p>',
    }
    with zipfile.ZipFile(path, 'w') as archive:
        archive.writestr('mimetype', 'application/epub+zip', compress_type=zipfile.ZIP_STORED)
        archive.writestr('META-INF/container.xml', '<container xmlns="urn:oasis:names:tc:opendocument:xmlns:container" version="1.0"><rootfiles><rootfile full-path="book.opf" media-type="application/oebps-package+xml"/></rootfiles></container>', compress_type=zipfile.ZIP_DEFLATED)
        archive.writestr('book.opf', f'<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="id">chapter-navigation-test</dc:identifier><dc:title>Chapter Navigation Test</dc:title><dc:language>en</dc:language></metadata><manifest>{manifest}<item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/><item id="pixel" href="pixel.png" media-type="image/png"/></manifest><spine>{spine}</spine></package>', compress_type=zipfile.ZIP_DEFLATED)
        archive.writestr('nav.xhtml', '<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><body><nav epub:type="toc"><ol><li><a href="body.xhtml">Main body</a></li></ol></nav></body></html>', compress_type=zipfile.ZIP_DEFLATED)
        for name in names:
            archive.writestr(f'{name}.xhtml', f'<html xmlns="http://www.w3.org/1999/xhtml"><body>{paragraphs[name]}</body></html>', compress_type=zipfile.ZIP_DEFLATED)
        archive.writestr('pixel.png', base64.b64decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jhGsAAAAASUVORK5CYII='))
    with zipfile.ZipFile(path) as archive:
        assert archive.testzip() is None
    print(f'Validated {path}: {path.stat().st_size} bytes')


if __name__ == '__main__':
    main()
