from datetime import datetime, timezone
from html import escape
import io
import posixpath
from pathlib import PurePosixPath
from urllib.parse import unquote
import uuid
import xml.etree.ElementTree as ET
import zipfile

XHTML_NS = "http://www.w3.org/1999/xhtml"
CSS = """body{font-family:serif;line-height:1.45}h1,h2,h3{line-height:1.2}p{margin:.6em 0}.pagenum{display:none}.wst-center{text-align:center}.wst-uppercase{text-transform:uppercase}.book{margin:1.5em 0}.note{font-size:.9em}a{overflow-wrap:anywhere}"""


def document(title, body):
    return f'''<?xml version="1.0" encoding="utf-8"?>
<html xmlns="{XHTML_NS}" xmlns:epub="http://www.idpf.org/2007/ops" lang="en" xml:lang="en"><head><title>{escape(title)}</title><link rel="stylesheet" type="text/css" href="style.css"/></head><body>{body}</body></html>'''


def write_book(path, title, creator, chapters, rights, source):
    identifier = "urn:uuid:" + str(uuid.uuid4())
    modified = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    manifest = [
        '<item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>',
        '<item id="css" href="style.css" media-type="text/css"/>',
    ]
    spine = []
    links = []
    files = {}
    for index, (chapter_title, body) in enumerate(chapters):
        name = f"chapter{index:02}.xhtml"
        manifest.append(
            f'<item id="chapter{index}" href="{name}" media-type="application/xhtml+xml"/>'
        )
        spine.append(f'<itemref idref="chapter{index}"/>')
        links.append(f'<li><a href="{name}">{escape(chapter_title)}</a></li>')
        files[name] = document(chapter_title, body)
    files["nav.xhtml"] = document(
        title,
        '<nav epub:type="toc"><h1>Contents</h1><ol>' + "".join(links) + "</ol></nav>",
    )
    package = f"""<?xml version="1.0" encoding="utf-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="pub-id"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="pub-id">{identifier}</dc:identifier><dc:title>{escape(title)}</dc:title><dc:creator>{escape(creator)}</dc:creator><dc:language>en</dc:language><dc:source>{escape(source)}</dc:source><dc:rights>{escape(rights)}</dc:rights><meta property="dcterms:modified">{modified}</meta></metadata><manifest>{"".join(manifest)}</manifest><spine>{"".join(spine)}</spine></package>"""
    with zipfile.ZipFile(path, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        archive.writestr(
            "mimetype", "application/epub+zip", compress_type=zipfile.ZIP_STORED
        )
        archive.writestr(
            "META-INF/container.xml",
            '<?xml version="1.0" encoding="utf-8"?><container xmlns="urn:oasis:names:tc:opendocument:xmlns:container" version="1.0"><rootfiles><rootfile full-path="EPUB/package.opf" media-type="application/oebps-package+xml"/></rootfiles></container>',
        )
        archive.writestr("EPUB/package.opf", package)
        archive.writestr("EPUB/style.css", CSS)
        for name, content in files.items():
            ET.fromstring(content)
            archive.writestr("EPUB/" + name, content)


def validate_epub(data, expected, minimum_words=1000):
    with zipfile.ZipFile(io.BytesIO(data)) as archive:
        assert archive.testzip() is None
        assert archive.read("mimetype") == b"application/epub+zip"
        assert archive.infolist()[0].filename == "mimetype"
        assert archive.infolist()[0].compress_type == zipfile.ZIP_STORED
        container = ET.fromstring(archive.read("META-INF/container.xml"))
        rootfile = container.find(".//{*}rootfile").attrib["full-path"]
        package = ET.fromstring(archive.read(rootfile))
        metadata = package.find("{*}metadata")
        titles = [node.text or "" for node in metadata.findall("{*}title")]
        languages = [node.text or "" for node in metadata.findall("{*}language")]
        assert any(expected.casefold() in title.casefold() for title in titles), titles
        assert any(language.lower().startswith("en") for language in languages), (
            languages
        )
        items = {
            node.attrib["id"]: node.attrib
            for node in package.findall("{*}manifest/{*}item")
        }
        parent = str(PurePosixPath(rootfile).parent)
        texts = []
        for item in package.findall("{*}spine/{*}itemref"):
            entry = items[item.attrib["idref"]]
            filename = posixpath.normpath(
                posixpath.join(parent, unquote(entry["href"].split("#")[0]))
            )
            document = ET.fromstring(archive.read(filename))
            texts.append(" ".join(document.itertext()))
        text = " ".join(texts)
        word_count = len(text.split())
        assert word_count >= minimum_words, (titles, word_count)
        return {
            "epub_title": titles[0],
            "language": languages[0],
            "spine_documents": len(texts),
            "word_count": word_count,
        }
