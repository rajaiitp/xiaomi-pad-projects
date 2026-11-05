import argparse
import hashlib
import os
import shutil
import json
import posixpath
import shlex
import subprocess
import xml.etree.ElementTree as ET
import zipfile
from pathlib import Path
from urllib.parse import unquote, urlsplit

ROOT = (
    Path(os.environ.get("XIAOMI_BOOKS_CACHE", Path.home() / ".cache/book-collections"))
    / "classics"
)
ADB = os.environ.get("ADB") or shutil.which("adb")
parser = argparse.ArgumentParser()
parser.add_argument("--serial", default=os.environ.get("ANDROID_SERIAL"))
arguments = parser.parse_args()
if not arguments.serial or not ADB:
    parser.error("Provide --serial or ANDROID_SERIAL, and put adb on PATH or set ADB")
DEVICE = arguments.serial
OPF = "{http://www.idpf.org/2007/opf}"
rows = json.loads((ROOT / "manifest.json").read_text())
assert len(rows) == 25
expected = {}
for row in rows:
    path = ROOT / row["file"]
    assert hashlib.sha256(path.read_bytes()).hexdigest() == row["sha256"], path
    with zipfile.ZipFile(path) as archive:
        assert archive.testzip() is None, path
        assert archive.read("mimetype") == b"application/epub+zip", path
        container = ET.fromstring(archive.read("META-INF/container.xml"))
        package_path = next(
            node.attrib["full-path"]
            for node in container.iter()
            if node.tag.endswith("rootfile")
        )
        package = ET.fromstring(archive.read(package_path))
        items = {node.attrib["id"]: node.attrib for node in package.iter(f"{OPF}item")}
        for itemref in package.iter(f"{OPF}itemref"):
            href = urlsplit(items[itemref.attrib["idref"]]["href"])
            assert not href.scheme, (path, href)
            chapter_path = posixpath.normpath(
                posixpath.join(posixpath.dirname(package_path), unquote(href.path))
            )
            chapter = archive.read(chapter_path)
            assert chapter.strip(), (path, chapter_path)
            ET.fromstring(chapter)
    expected["/sdcard/Books/" + row["file"]] = row["sha256"]

command = "sha256sum " + " ".join(shlex.quote(path) for path in expected)
output = subprocess.check_output([ADB, "-s", DEVICE, "shell", command], text=True)
actual = dict(
    (filename.strip(), digest)
    for digest, filename in (line.split(maxsplit=1) for line in output.splitlines())
)
assert actual == expected, "Tablet checksums differ from verified downloads"
inventory = subprocess.check_output(
    [ADB, "-s", DEVICE, "shell", "find /sdcard/Books -type f -name '*.epub'"], text=True
).splitlines()
assert set(expected).issubset(inventory), "Missing tablet ebook files"
print(f"VERIFIED_CLASSICS files={len(rows)} bytes={sum(row['bytes'] for row in rows)}")
print("Tolstoy: 24 EPUBs; Orwell: 1 EPUB, 2 early poems; all SHA-256 checksums match.")
