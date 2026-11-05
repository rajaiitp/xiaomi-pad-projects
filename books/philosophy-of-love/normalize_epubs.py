import hashlib
import io
import json
from paths import ROOT
from urllib.parse import unquote
import xml.etree.ElementTree as ET
import zipfile

from epub_tools import validate_epub

ET.register_namespace("", "http://www.w3.org/1999/xhtml")
ET.register_namespace("epub", "http://www.idpf.org/2007/ops")
ET.register_namespace("opf", "http://www.idpf.org/2007/opf")
ET.register_namespace("dc", "http://purl.org/dc/elements/1.1/")
ET.register_namespace("ncx", "http://www.daisy.org/z3986/2005/ncx/")
ET.register_namespace("svg", "http://www.w3.org/2000/svg")
entries = json.loads((ROOT / "downloads.json").read_text())

for entry in entries:
    if entry["index"] == 33:
        continue
    path = ROOT / entry["file"]
    original = ROOT / "sources" / f"original-{entry['index']:02}.epub"
    if not original.exists():
        original.write_bytes(path.read_bytes())
    data = original.read_bytes()
    entry["original_sha256"] = hashlib.sha256(data).hexdigest()
    with zipfile.ZipFile(io.BytesIO(data)) as source:
        if entry["index"] != 27:
            modified = {}
            for name in source.namelist():
                content = source.read(name)
                if name == "OEBPS/toc.xhtml":
                    text = content.decode("utf-8")
                    assert text.count(' aria-label="Table of Contents"') == 1
                    changed = text.replace(' aria-label="Table of Contents"', "", 1)
                    ET.fromstring(changed)
                    content = changed.encode("utf-8")
                modified[name] = content
            entry["format_note"] = (
                "Removed one invalid ARIA attribute from the navigation document for EPUBCheck conformance. All displayed text, book content, and licence notices are unchanged."
            )
        else:
            names = {name: name.replace(" ", "_") for name in source.namelist()}
            assert len(set(names.values())) == len(names)
            modified = {}
            for name in source.namelist():
                content = source.read(name)
                if name.endswith((".htm", ".html", ".xhtml", ".opf", ".ncx")):
                    tree = ET.fromstring(content)
                    before = list(tree.itertext())
                    for node in tree.iter():
                        local = node.tag.rsplit("}", 1)[-1]
                        if local == "body":
                            node.attrib.pop("link", None)
                            node.attrib.pop("vlink", None)
                        if local == "br":
                            node.attrib.pop("clear", None)
                        for attribute in ("href", "src"):
                            value = node.get(attribute)
                            if value is None:
                                continue
                            filename, marker, fragment = value.partition("#")
                            key = unquote(filename)
                            if key in names:
                                node.set(attribute, names[key] + marker + fragment)
                    assert list(tree.itertext()) == before
                    content = ET.tostring(tree, encoding="utf-8", xml_declaration=True)
                modified[names[name]] = content
            entry["format_note"] = (
                "Normalized internal filenames and links, and removed deprecated presentation attributes. All book text, images, translation credits and copyright notices are unchanged."
            )
            entry["rights"] = entry["rights"].replace(
                "Original ebook and notices retained.",
                "Translation text, images, and notices retained; packaging normalized without textual changes.",
            )
        with zipfile.ZipFile(path, "w", compression=zipfile.ZIP_DEFLATED) as output:
            output.writestr(
                "mimetype", modified.pop("mimetype"), compress_type=zipfile.ZIP_STORED
            )
            for name, content in modified.items():
                output.writestr(name, content)
    result = validate_epub(path.read_bytes(), entry["epub_title"], minimum_words=1000)
    assert result["word_count"] == entry["word_count"], (entry["index"], result)
    entry.update(result)
    entry["bytes"] = path.stat().st_size
    entry["sha256"] = hashlib.sha256(path.read_bytes()).hexdigest()
    print("NORMALIZED, TEXT UNCHANGED:", path.name)
(ROOT / "downloads.json").write_text(
    json.dumps(entries, ensure_ascii=False, indent=2) + "\n"
)
