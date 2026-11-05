from html.parser import HTMLParser
import json
from paths import ROOT
import re
from urllib.parse import urljoin


class ShelfParser(HTMLParser):
    def __init__(self, page):
        super().__init__()
        self.page = page
        self.books = []
        self.book = None
        self.capture = None
        self.fragments = []
        self.row_text = []

    def finish_book(self):
        if self.book:
            text = " ".join(self.row_text)
            year = re.search(r"published\s+(-?\d+)", text)
            self.book["published"] = int(year.group(1)) if year else None
            self.books.append(self.book)
        self.book = None
        self.row_text = []

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        classes = attrs.get("class", "").split()
        if tag == "div" and "elementList" in classes:
            self.finish_book()
        if tag == "a" and "bookTitle" in classes:
            self.finish_book()
            url = urljoin("https://www.goodreads.com", attrs["href"])
            self.book = {
                "goodreads_id": re.search(r"/book/show/(\d+)", url).group(1),
                "goodreads_url": url,
                "shelf_page": self.page,
            }
            self.capture = "title"
            self.fragments = []
        elif (
            tag == "a"
            and "authorName" in classes
            and self.book
            and "author" not in self.book
        ):
            self.capture = "author"
            self.fragments = []

    def handle_data(self, data):
        if self.capture:
            self.fragments.append(data)
        if self.book:
            self.row_text.append(data)

    def handle_endtag(self, tag):
        if tag == "a" and self.capture:
            text = " ".join("".join(self.fragments).split())
            if self.capture == "title":
                text = re.sub(
                    r"\s+\((Paperback|Hardcover|Mass Market Paperback|Kindle Edition|ebook|Audio CD|Unknown Binding|Library Binding|Audible Audio)\)$",
                    "",
                    text,
                    flags=re.I,
                )
            self.book[self.capture] = text
            self.capture = None
            self.fragments = []


books = []
for page in range(1, 2):
    parser = ShelfParser(page)
    parser.feed((ROOT / "sources" / f"goodreads-{page}.html").read_text())
    parser.finish_book()
    print(f"Page {page}: {len(parser.books)} books")
    books.extend(parser.books)
ids = [book["goodreads_id"] for book in books]
assert len(ids) == len(set(ids)), "Pagination returned duplicate books"
assert len(books) == 50, f"Expected 50 visible Goodreads titles, found {len(books)}"
for index, book in enumerate(books, 1):
    book["index"] = index
    assert book.get("title") and book.get("author"), book
(ROOT / "catalog.json").write_text(
    json.dumps(books, ensure_ascii=False, indent=2) + "\n"
)
(ROOT / "titles.tsv").write_text(
    "\n".join(
        f"{book['index']}\t{book['title']}\t{book['author']}\t{book['published']}"
        for book in books
    )
    + "\n"
)
