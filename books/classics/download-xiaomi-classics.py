import hashlib
import html
import json
import os
import re
import subprocess
import time
import xml.etree.ElementTree as ET
import zipfile
from datetime import datetime, timezone
from pathlib import Path

ROOT = (
    Path(os.environ.get("XIAOMI_BOOKS_CACHE", Path.home() / ".cache/book-collections"))
    / "classics"
)
TOLSTOY = ROOT / "Leo Tolstoy"
ORWELL = ROOT / "George Orwell"
MANIFEST = ROOT / "manifest.json"
CATALOG = json.loads(Path(__file__).with_name("editions.json").read_text())
PG_IDS = [
    2142,
    2450,
    2637,
    3540,
    3631,
    4761,
    7176,
    26660,
    27189,
    27726,
    38025,
    38690,
    43372,
    43794,
    46272,
    79027,
]
SE_EDITIONS = [
    ("what-is-art", "aylmer-maude"),
    ("resurrection", "louise-maude"),
    ("short-fiction", "various-translators"),
    ("hadji-murad", "aylmer-maude"),
    ("war-and-peace", "louise-maude_aylmer-maude"),
    ("anna-karenina", "constance-garnett"),
    ("the-kingdom-of-god-is-within-you", "leo-wiener"),
    ("a-confession", "aylmer-maude"),
]
DC = "{http://purl.org/dc/elements/1.1/}"
OPF = "{http://www.idpf.org/2007/opf}"
manifest = []


def fetch(url, path):
    if path.suffix == ".epub" and path.exists() and zipfile.is_zipfile(path):
        return
    subprocess.run(
        [
            "curl",
            "-fsSL",
            "--retry",
            "2",
            "--connect-timeout",
            "10",
            "--max-time",
            "60",
            url,
            "-o",
            str(path),
        ],
        check=True,
    )


def validate(path):
    with zipfile.ZipFile(path) as archive:
        if archive.testzip() is not None:
            raise ValueError(f"Corrupt archive: {path}")
        if archive.read("mimetype") != b"application/epub+zip":
            raise ValueError(f"Not an EPUB: {path}")
        container = ET.fromstring(archive.read("META-INF/container.xml"))
        package_path = next(
            node.attrib["full-path"]
            for node in container.iter()
            if node.tag.endswith("rootfile")
        )
        package = ET.fromstring(archive.read(package_path))
        title = package.findtext(f".//{DC}title")
        language = package.findtext(f".//{DC}language")
        if not title or language not in ("en", "en-US", "en-GB"):
            raise ValueError(f"Unexpected metadata: {path}, {title}, {language}")
        if not list(package.iter(f"{OPF}itemref")):
            raise ValueError(f"Empty spine: {path}")
        return title


def record(path, source):
    title = validate(path)
    manifest.append(
        {
            "title": title,
            "file": str(path.relative_to(ROOT)),
            "source": source,
            "bytes": path.stat().st_size,
            "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
        }
    )
    MANIFEST.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n")
    print(
        f"VALIDATED {path.relative_to(ROOT)} ({path.stat().st_size} bytes)", flush=True
    )


TOLSTOY.mkdir(parents=True, exist_ok=True)
ORWELL.mkdir(parents=True, exist_ok=True)
for work, translator in SE_EDITIONS:
    slug = f"leo-tolstoy_{work}_{translator}"
    url = f"https://standardebooks.org/ebooks/leo-tolstoy/{work}/{translator}/downloads/{slug}.epub?source=download"
    path = TOLSTOY / f"{work.replace('-', ' ').title()} [Standard Ebooks].epub"
    fetch(url, path)
    record(path, url)
    time.sleep(1)

for number in PG_IDS:
    title = CATALOG[str(number)]
    safe_title = re.sub(r'[<>:"/\\|?*\x00-\x1f]', "", title).strip()[:160]
    path = TOLSTOY / f"{safe_title} [PG-{number}].epub"
    url = f"https://www.gutenberg.org/ebooks/{number}.epub3.images"
    fetch(url, path)
    record(path, url)
    time.sleep(1)

poems = [
    ("Awake! Young Men of England", "1914-10-02", "Awake!_Young_Men_of_England"),
    ("Kitchener", "1916-07-21", "Kitchener_(Orwell)"),
]
chapters = []
for index, (title, published, page) in enumerate(poems, 1):
    source = f"https://en.wikisource.org/wiki/{page}"
    raw_path = ROOT / f"orwell-poem-{index}.wikitext"
    fetch(source + "?action=raw", raw_path)
    match = re.search(r"<poem>(.*?)</poem>", raw_path.read_text(), re.DOTALL)
    if match is None or len(match.group(1).strip()) < 200:
        raise ValueError(f"Missing poem text: {source}")
    text = html.escape(match.group(1).strip())
    chapter = f'''<?xml version="1.0" encoding="utf-8"?>
<html xmlns="http://www.w3.org/1999/xhtml" xml:lang="en"><head><title>{html.escape(title)}</title>
<style>pre {{white-space:pre-wrap; font-family:serif; line-height:1.5}}</style></head><body>
<h1>{html.escape(title)}</h1><p>George Orwell (published as Eric Blair)</p><pre>{text}</pre>
<p>First published {published} in the Henley and South Oxfordshire Standard.</p>
<p>Original poem: public domain in the United States. <a href="{html.escape(source)}">Transcription: Wikisource</a>.
Wikisource contributions are available under <a href="https://creativecommons.org/licenses/by-sa/4.0/">CC BY-SA 4.0</a>.</p>
</body></html>'''
    chapters.append((title, chapter))

modified = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
items = "".join(
    f'<item id="p{i}" href="poem-{i}.xhtml" media-type="application/xhtml+xml"/>'
    for i in range(1, len(chapters) + 1)
)
spine = "".join(f'<itemref idref="p{i}"/>' for i in range(1, len(chapters) + 1))
links = "".join(
    f'<li><a href="poem-{i}.xhtml">{html.escape(title)}</a></li>'
    for i, (title, _) in enumerate(chapters, 1)
)
package = f"""<?xml version="1.0" encoding="utf-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="book-id">
<metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
<dc:identifier id="book-id">urn:orwell:early-poems:1914-1916</dc:identifier>
<dc:title>Early Poems (1914–1916)</dc:title><dc:creator>George Orwell</dc:creator><dc:language>en</dc:language>
<dc:rights>Original poems: public domain in the United States. Wikisource transcriptions: CC BY-SA 4.0.</dc:rights>
<meta property="dcterms:modified">{modified}</meta></metadata>
<manifest><item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>{items}</manifest>
<spine>{spine}</spine></package>"""
nav = f"""<?xml version="1.0" encoding="utf-8"?>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" xml:lang="en">
<head><title>Early Poems (1914–1916)</title></head><body><h1>Early Poems (1914–1916)</h1>
<p>George Orwell</p><nav epub:type="toc"><h2>Contents</h2><ol>{links}</ol></nav></body></html>"""
path = ORWELL / "Early Poems (1914-1916).epub"
with zipfile.ZipFile(path, "w", compression=zipfile.ZIP_DEFLATED) as archive:
    archive.writestr(
        "mimetype", "application/epub+zip", compress_type=zipfile.ZIP_STORED
    )
    archive.writestr(
        "META-INF/container.xml",
        '<?xml version="1.0"?><container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>',
    )
    archive.writestr("OEBPS/content.opf", package)
    archive.writestr("OEBPS/nav.xhtml", nav)
    for index, (_, chapter) in enumerate(chapters, 1):
        ET.fromstring(chapter)
        archive.writestr(f"OEBPS/poem-{index}.xhtml", chapter)
record(path, [f"https://en.wikisource.org/wiki/{page}" for _, _, page in poems])
print(
    f"CLASSICS_DOWNLOAD_COMPLETE files={len(manifest)} bytes={sum(item['bytes'] for item in manifest)}",
    flush=True,
)
