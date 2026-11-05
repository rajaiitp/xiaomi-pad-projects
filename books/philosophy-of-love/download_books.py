from datetime import datetime, timezone
import hashlib
from html import unescape
import io
import json
from pathlib import Path
from paths import ROOT
import re
import time
import subprocess
import sys
from urllib.request import Request, urlopen
from epub_tools import validate_epub
import zipfile

OUT = ROOT / "ebooks"
OUT.mkdir(exist_ok=True)
PG_BOOKS = [
    (
        1,
        1600,
        "01 Plato - Symposium (Benjamin Jowett).epub",
        "Symposium",
        "Benjamin Jowett",
    ),
    (
        14,
        8438,
        "14 Aristotle - Nicomachean Ethics (D P Chase).epub",
        "Nicomachean",
        "D. P. Chase",
    ),
    (
        18,
        1636,
        "18 Plato - Phaedrus (Benjamin Jowett).epub",
        "Phaedrus",
        "Benjamin Jowett",
    ),
    (32, 1579, "32 Plato - Lysis (Benjamin Jowett).epub", "Lysis", "Benjamin Jowett"),
]


def fetch(url, timeout=60):
    request = Request(url, headers={"User-Agent": "Mozilla/5.0", "Accept": "*/*"})
    with urlopen(request, timeout=timeout) as response:
        return response.read(), response.geturl()


def record(
    index, filename, data, source, download, rights, translator=None, minimum_words=1000
):
    validation = validate_epub(
        data,
        "Nicomachean"
        if index == 14
        else {
            1: "Symposium",
            18: "Phaedrus",
            27: "Letters",
            32: "Lysis",
            33: "Marriage",
        }[index],
        minimum_words,
    )
    (ROOT / "sources" / f"original-{index:02}.epub").write_bytes(data)
    destination = OUT / filename
    temporary = destination.with_suffix(".epub.part")
    temporary.write_bytes(data)
    temporary.replace(destination)
    entry = {
        "index": index,
        "file": "ebooks/" + filename,
        "bytes": len(data),
        "sha256": hashlib.sha256(data).hexdigest(),
        "source_url": source,
        "download_url": download,
        "rights": rights,
        "translator": translator,
        **validation,
    }
    downloads.append(entry)
    (ROOT / "downloads.json").write_text(
        json.dumps(downloads, ensure_ascii=False, indent=2) + "\n"
    )
    print(
        f"VALIDATED {filename}: {len(data):,} bytes, {validation['word_count']:,} words",
        flush=True,
    )


(ROOT / "catalog.json").write_bytes(Path(__file__).with_name("shelf.json").read_bytes())
downloads = []
for index, number, filename, expected, translator in PG_BOOKS:
    source_url = f"https://www.gutenberg.org/ebooks/{number}"
    page, _ = fetch(source_url)
    (ROOT / "sources" / f"gutenberg-{number}.html").write_bytes(page)
    text = unescape(re.sub(r"<[^>]+>", " ", page.decode()))
    text = " ".join(text.split())
    assert "Public domain in the USA" in text, source_url
    assert expected.casefold() in text.casefold(), source_url
    data, url = fetch(f"https://www.gutenberg.org/ebooks/{number}.epub3.images")
    record(
        index,
        filename,
        data,
        source_url,
        url,
        "Public domain in the USA; Project Gutenberg edition and notices retained.",
        translator,
    )
    time.sleep(0.5)

source_url = "https://www.poetryintranslation.com/PITBR/German/RilkeLetters.php"
page, _ = fetch(source_url)
assert b"non-commercial" in page.lower() and b"2021" in page
(ROOT / "sources" / "rilke-letters.html").write_bytes(page)
rights_page, _ = fetch("https://www.poetryintranslation.com/Admin/Copyright.php")
(ROOT / "sources" / "poetry-in-translation-copyright.html").write_bytes(rights_page)
url = "https://www.poetryintranslation.com/Downloadcat/Epub/RilkeLettersepub.zip"
data, final_url = fetch(url)
with zipfile.ZipFile(io.BytesIO(data)) as archive:
    files = [
        name
        for name in archive.namelist()
        if name.lower().endswith(".epub") and not name.startswith("__MACOSX/")
    ]
    assert len(files) == 1, files
    epub = archive.read(files[0])
record(
    27,
    "27 Rainer Maria Rilke - Letters to a Young Poet (A S Kline).epub",
    epub,
    source_url,
    final_url,
    "A. S. Kline translation copyright 2021. Publisher explicitly permits free non-commercial reproduction, storage and transmission; original German collection published 1929. Original ebook and notices retained. See https://www.poetryintranslation.com/Admin/Copyright.php",
    "A. S. Kline",
    minimum_words=8000,
)

source_url = "https://en.wikisource.org/wiki/Marriage_and_Morals"
page, _ = fetch(source_url)
(ROOT / "sources" / "marriage-and-morals.html").write_bytes(page)
for script in ("build_russell.py", "normalize_epubs.py", "build_catalog.py"):
    subprocess.run([sys.executable, str(Path(__file__).with_name(script))], check=True)
downloads = json.loads((ROOT / "downloads.json").read_text())
(ROOT / "download-run.json").write_text(
    json.dumps(
        {
            "completed_at": datetime.now(timezone.utc).isoformat(),
            "books": len(downloads),
        },
        indent=2,
    )
    + "\n"
)
print(f"COMPLETE: {len(downloads)} validated ebooks", flush=True)
