from concurrent.futures import ThreadPoolExecutor
import hashlib
from html import escape
import json
from paths import ROOT
import time
from urllib.parse import urljoin
from urllib.request import Request, urlopen

from bs4 import BeautifulSoup, Comment
from epub_tools import validate_epub, write_book

SOURCE = "https://en.wikisource.org/wiki/Marriage_and_Morals"
LICENSE = "https://creativecommons.org/licenses/by-sa/4.0/"
RIGHTS = "Russell's 1929 US text is public domain in the USA. Wikisource contributions and this EPUB assembly are provided under CC BY-SA 4.0, with source attribution. Formatting adapted from the online transcription; text not rewritten."
ALLOWED_TAGS = {
    "p",
    "span",
    "div",
    "h1",
    "h2",
    "h3",
    "h4",
    "h5",
    "h6",
    "ul",
    "ol",
    "li",
    "blockquote",
    "em",
    "i",
    "b",
    "strong",
    "small",
    "sup",
    "sub",
    "table",
    "thead",
    "tbody",
    "tr",
    "td",
    "th",
    "hr",
    "br",
    "a",
    "dl",
    "dt",
    "dd",
    "pre",
    "code",
}


def fetch_chapter(number):
    url = SOURCE + f"/Chapter_{number}"
    path = ROOT / "sources" / f"russell-chapter-{number}.html"
    if not path.exists():
        request = Request(url, headers={"User-Agent": "Mozilla/5.0"})
        with urlopen(request, timeout=45) as response:
            data = response.read()
        path.write_bytes(data)
        time.sleep(0.25)
    soup = BeautifulSoup(path.read_bytes(), "html.parser")
    blocks = soup.select("div.prp-pages-output")
    assert blocks, url
    extras = [
        node
        for node in soup.select("ol.references")
        if not node.find_parent("div", class_="prp-pages-output")
    ]
    fragment = BeautifulSoup(
        "".join(str(block) for block in [*blocks, *extras]), "html.parser"
    )
    for node in list(fragment.select("script, style, link, .ws-noexport, .pagenum")):
        if node.parent:
            node.decompose()
    for comment in fragment.find_all(string=lambda value: isinstance(value, Comment)):
        comment.extract()
    assert not fragment.find_all(["img", "math", "svg"]), (
        f"Chapter needs embedded assets: {url}"
    )
    before_text = " ".join(fragment.stripped_strings)
    assert len(before_text.split()) > 300, (url, len(before_text.split()))
    for tag in list(fragment.find_all(True)):
        if tag.name not in ALLOWED_TAGS:
            tag.unwrap()
            continue
        tag.attrs = {
            key: value
            for key, value in tag.attrs.items()
            if key in {"id", "class", "href", "title", "colspan", "rowspan"}
        }
        if tag.name == "a" and tag.get("href"):
            href = tag["href"]
            if href.startswith("javascript:"):
                del tag["href"]
            elif not href.startswith("#"):
                tag["href"] = urljoin(url, href)
    assert " ".join(fragment.stripped_strings) == before_text, url
    body = str(fragment)
    print(f"CHAPTER {number}: {len(before_text.split()):,} words", flush=True)
    return number, body, len(before_text.split()), url


toc_source = BeautifulSoup(
    (ROOT / "sources" / "marriage-and-morals.html").read_bytes(), "html.parser"
)
titles = {}
for anchor in toc_source.select('a[href*="Marriage_and_Morals/Chapter_"]'):
    number = int(anchor["href"].rsplit("_", 1)[1].split("#")[0])
    titles[number] = anchor.get_text(" ", strip=True)
assert set(titles) == set(range(1, 22)), titles
with ThreadPoolExecutor(max_workers=2) as executor:
    results = sorted(executor.map(fetch_chapter, range(1, 22)))
intro = f'''<h1>Marriage and Morals</h1><p>Bertrand Russell</p><p>Originally published by Horace Liveright, New York, 1929.</p><h2>Edition and rights</h2><p>{escape(RIGHTS)}</p><p>Source: <a href="{SOURCE}">Wikisource transcription</a>. <a href="{LICENSE}">Creative Commons Attribution-ShareAlike 4.0</a>.</p><p>All 21 chapters are included. This reflowable EPUB was assembled from the public chapter pages because the website's export service required an interactive bot check.</p>'''
chapters = [("Title and edition information", intro)]
for number, body, count, url in results:
    title = f"{number}. {titles[number]}"
    chapters.append(
        (
            title,
            f'<h1>{escape(title)}</h1>{body}<p class="note">Source and contributors: <a href="{url}">Wikisource chapter {number}</a>; <a href="{url}?action=history">revision history</a>.</p>',
        )
    )
filename = "33 Bertrand Russell - Marriage and Morals (1929).epub"
path = ROOT / "ebooks" / filename
write_book(path, "Marriage and Morals", "Bertrand Russell", chapters, RIGHTS, SOURCE)
data = path.read_bytes()
validation = validate_epub(data, "Marriage and Morals", minimum_words=30000)
assert validation["spine_documents"] == 22
entry = {
    "index": 33,
    "file": "ebooks/" + filename,
    "bytes": len(data),
    "sha256": hashlib.sha256(data).hexdigest(),
    "source_url": SOURCE,
    "download_url": None,
    "rights": RIGHTS,
    "translator": None,
    "chapters": [
        {"number": number, "source_url": url, "word_count": count}
        for number, _, count, url in results
    ],
    **validation,
}
manifest = json.loads((ROOT / "downloads.json").read_text())
manifest = [item for item in manifest if item["index"] != 33]
manifest.append(entry)
(ROOT / "downloads.json").write_text(
    json.dumps(manifest, ensure_ascii=False, indent=2) + "\n"
)
print(
    f"COMPLETE {filename}: {len(data):,} bytes; {validation['word_count']:,} words",
    flush=True,
)
