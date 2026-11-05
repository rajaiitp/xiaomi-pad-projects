import csv
from datetime import datetime, timezone
import hashlib
from html import escape
import json
from paths import ROOT
from pathlib import Path
import shutil
from urllib.parse import quote, urlencode

from epub_tools import validate_epub, write_book

OUT = ROOT / "tablet"
OUT.mkdir(exist_ok=True)
(OUT / "ebooks").mkdir(exist_ok=True)
SOURCE = "https://www.goodreads.com/shelf/show/philosophy-of-love"
books = json.loads((ROOT / "catalog.json").read_text())
snapshot = json.loads(Path(__file__).with_name("shelf.json").read_text())
assert [book["goodreads_id"] for book in books] == [
    book["goodreads_id"] for book in snapshot
], "Shelf changed; review edition mappings before building the catalog"
downloads = {
    entry["index"]: entry for entry in json.loads((ROOT / "downloads.json").read_text())
}
assert len(books) == 50 and len(downloads) == 6

NOTES = {
    4: "A free provisional AI-assisted web translation exists, but it is not a verified complete scholarly edition and was not included as an ebook.",
    19: "The original Italian work is old, but the English translation located is a modern copyrighted edition.",
    34: "The original Russian work is old; authorization for a complete free English translation was not established.",
    35: "This is Béroul's work, not Bédier's later retelling. A different public-domain retelling was not substituted.",
    36: "The archive's English text credits a 1971 translation. Free-download authorization for that translation was not established.",
    37: "The English archive text credits Alix Holt's 1972 translation, published in 1977. It was not treated as public domain solely because the original essay is older.",
    38: "An English version is titled Make Way for Winged Eros (A Letter to Working Youth). Translation authorization was not established; the Italian-titled Goodreads work was not silently omitted.",
    41: "The original German work was published in 1923, but English translations have separate copyright terms.",
}
PUBLISHERS = {
    8: "https://www.carriejenkins.net/what-love-is-and-what-it-could-be",
    9: "https://mitpress.mit.edu/9780262516174/philosophy-of-love/",
    16: "https://link.springer.com/book/10.1057/9781137455802",
    19: "https://press.uchicago.edu/ucp/books/book/chicago/D/bo3636437.html",
    44: "https://www.upress.umn.edu/9781517916435/nothing-wanting/",
}
EXTRA_READING = {
    4: (
        "Provisional AI-assisted web text (not a scholarly edition)",
        "https://worksoflovesk.org/read-the-translation/",
    ),
    36: (
        "Archive page and translation credits",
        "https://www.marxists.org/archive/kollonta/1926/autobiography.htm",
    ),
    37: (
        "Archive page and translation credits",
        "https://www.marxists.org/archive/kollonta/1921/sex-class-struggle.htm",
    ),
    38: (
        "English archive page and translation credits",
        "https://www.marxists.org/archive/kollonta/1923/winged-eros.htm",
    ),
}

intro = """<h1>Philosophy of Love — Reading Catalog</h1>
<p>This collection covers the 50 distinct books publicly visible on the supplied Goodreads shelf. Goodreads reports 138 entries, but pagination repeats the first 50. You approved processing the visible 50; the other 88 were not accessible and are not claimed as cataloged.</p>
<p><strong>6 complete English ebooks downloaded; 44 titles have purchase and library-search links.</strong> Older public-domain translations may differ from the Goodreads edition. Copyright and permission were checked for the selected English text, not inferred solely from the original work's age.</p>
<p>Store and library links are searches or official book pages, not promises of stock or borrowing availability. An account, payment, library card, or the provider's reading app may be required. No purchases or loans were initiated.</p>
<p>Open the ebooks folder in your reading app. This catalog itself is not a replacement for the linked books.</p>
<p><a href="https://www.goodreads.com/shelf/show/philosophy-of-love">Original Goodreads shelf</a></p>"""
html_sections = []
epub_chapters = [("About this collection", intro)]

for book in books:
    index = book["index"]
    query = f"{book['title']} {book['author']}"
    book["purchase_search_url"] = "https://www.kobo.com/us/en/search?" + urlencode(
        {"query": query}
    )
    book["library_search_url"] = "https://search.worldcat.org/search?" + urlencode(
        {"q": query}
    )
    book["ebook_loan_search_url"] = "https://www.overdrive.com/search?" + urlencode(
        {"q": query}
    )
    if index in PUBLISHERS:
        book["official_book_page"] = PUBLISHERS[index]
    entry = downloads.get(index)
    if entry:
        book["status"] = "downloaded"
        book["download"] = entry
        path = ROOT / entry["file"]
        data = path.read_bytes()
        assert hashlib.sha256(data).hexdigest() == entry["sha256"]
        result = validate_epub(data, entry["epub_title"], minimum_words=1000)
        assert result["word_count"] == entry["word_count"]
        shutil.copyfile(path, OUT / entry["file"])
    else:
        book["status"] = "links_only"
        book["availability_note"] = NOTES.get(
            index,
            "A complete authorized free English download was not established. Use the official purchase/library options below.",
        )

    heading = f"{index:02}. {book['title']} — {book['author']}"
    body = f"<h1>{escape(heading)}</h1>"
    if entry:
        body += (
            f"<p><strong>Downloaded EPUB.</strong> File: {escape(entry['file'])}</p>"
        )
        if entry.get("translator"):
            body += f"<p>Selected translation: {escape(entry['translator'])}</p>"
        body += f'<p>{escape(entry["rights"])}</p><p><a href="{escape(entry["source_url"], quote=True)}">Download source and edition details</a></p>'
        if entry.get("format_note"):
            body += f'<p class="note">{escape(entry["format_note"])}</p>'
    else:
        body += f"<p><strong>Links only — ebook not downloaded.</strong> {escape(book['availability_note'])}</p>"
    links = [
        ("Goodreads book details", book["goodreads_url"]),
        ("Purchase search: Kobo", book["purchase_search_url"]),
        ("Library search: WorldCat", book["library_search_url"]),
        ("Ebook borrowing search: OverDrive", book["ebook_loan_search_url"]),
    ]
    if index in PUBLISHERS:
        links.insert(1, ("Official publisher/author page", PUBLISHERS[index]))
    if index in EXTRA_READING:
        links.append(EXTRA_READING[index])
    body += (
        "<ul>"
        + "".join(
            f'<li><a href="{escape(url, quote=True)}">{escape(label)}</a></li>'
            for label, url in links
        )
        + "</ul>"
    )
    epub_chapters.append((heading, body))
    if entry:
        body += f'<p><a href="{quote(entry["file"], safe="/")}">Open downloaded EPUB</a></p>'
    html_sections.append(f'<section class="book" id="book{index:02}">{body}</section>')

collection = {
    "source_shelf": SOURCE,
    "created_at": datetime.now(timezone.utc).isoformat(),
    "scope": {
        "shelf_reported_total": 138,
        "visible_titles": 50,
        "inaccessible_titles_not_processed": 88,
        "user_approved_scope": "visible_50",
    },
    "language": "English",
    "copyright_jurisdiction": "United States",
    "downloaded_books": 6,
    "link_only_books": 44,
    "books": books,
}
(OUT / "collection.json").write_text(
    json.dumps(collection, ensure_ascii=False, indent=2) + "\n"
)
with (OUT / "catalog.csv").open("w", newline="", encoding="utf-8") as stream:
    writer = csv.writer(stream)
    writer.writerow(
        [
            "Number",
            "Title",
            "Author",
            "Status",
            "Downloaded file",
            "Source",
            "Goodreads",
            "Purchase search",
            "Library search",
            "Ebook borrowing search",
            "Notes",
        ]
    )
    for book in books:
        entry = book.get("download", {})
        writer.writerow(
            [
                book["index"],
                book["title"],
                book["author"],
                book["status"],
                entry.get("file", ""),
                entry.get("source_url", ""),
                book["goodreads_url"],
                book["purchase_search_url"],
                book["library_search_url"],
                book["ebook_loan_search_url"],
                entry.get("rights", book.get("availability_note", "")),
            ]
        )
html = (
    '<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Philosophy of Love — Reading Catalog</title><style>body{font:18px/1.5 sans-serif;max-width:900px;margin:auto;padding:1em}h1{font-size:1.35em}.book{border-top:1px solid #aaa;padding-top:1em;margin-top:2em}a{overflow-wrap:anywhere}</style></head><body>'
    + intro
    + "".join(html_sections)
    + "</body></html>"
)
(OUT / "Catalog.html").write_text(html)
write_book(
    OUT / "00 Philosophy of Love - Catalog.epub",
    "Philosophy of Love — Reading Catalog",
    "Personal library catalog",
    epub_chapters,
    "Bibliographic metadata, provenance, and links only; ebook permissions are recorded individually.",
    SOURCE,
)
validate_epub(
    (OUT / "00 Philosophy of Love - Catalog.epub").read_bytes(),
    "Philosophy of Love",
    minimum_words=1000,
)
files = sorted(
    path for path in OUT.rglob("*") if path.is_file() and path.name != "SHA256SUMS"
)
(OUT / "SHA256SUMS").write_text(
    "".join(
        f"{hashlib.sha256(path.read_bytes()).hexdigest()}  {path.relative_to(OUT).as_posix()}\n"
        for path in files
    )
)
print(
    f"READY: {len(downloads)} books, {len(books)} catalog entries, {len(files) + 1} files, {sum(path.stat().st_size for path in OUT.rglob('*') if path.is_file()):,} bytes"
)
