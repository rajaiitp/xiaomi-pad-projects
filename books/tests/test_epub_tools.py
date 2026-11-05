import importlib.util
import io
from pathlib import Path
import tempfile
import unittest
import zipfile

SOURCE = Path(__file__).resolve().parents[1] / "philosophy-of-love/epub_tools.py"
SPEC = importlib.util.spec_from_file_location("epub_tools", SOURCE)
epub_tools = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(epub_tools)


class EpubTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.path = Path(self.directory.name) / "book.epub"
        epub_tools.write_book(
            self.path,
            "Test & Book",
            "Test Author",
            [("First", "<p>one two three</p>"), ("Second", "<p>four five six</p>")],
            "Test rights",
            "https://example.org/book",
        )
        self.data = self.path.read_bytes()

    def mutate(self, name, transform):
        output = io.BytesIO()
        with zipfile.ZipFile(io.BytesIO(self.data)) as source:
            with zipfile.ZipFile(output, "w") as target:
                for entry in source.infolist():
                    content = source.read(entry)
                    target.writestr(
                        entry, transform(content) if entry.filename == name else content
                    )
        return output.getvalue()

    def test_round_trip(self):
        result = epub_tools.validate_epub(self.data, "Test & Book", minimum_words=1)
        self.assertEqual(result["spine_documents"], 2)
        self.assertEqual(result["language"], "en")
        self.assertGreaterEqual(result["word_count"], 6)

    def test_wrong_title_rejected(self):
        with self.assertRaises(AssertionError):
            epub_tools.validate_epub(self.data, "Other title", minimum_words=1)

    def test_short_book_rejected(self):
        with self.assertRaises(AssertionError):
            epub_tools.validate_epub(self.data, "Test", minimum_words=1000)

    def test_wrong_mimetype_rejected(self):
        data = self.mutate("mimetype", lambda _: b"text/html")
        with self.assertRaises(AssertionError):
            epub_tools.validate_epub(data, "Test", minimum_words=1)

    def test_non_english_rejected(self):
        data = self.mutate(
            "EPUB/package.opf",
            lambda value: value.replace(b">en</dc:language>", b">fr</dc:language>"),
        )
        with self.assertRaises(AssertionError):
            epub_tools.validate_epub(data, "Test", minimum_words=1)

    def test_missing_spine_document_rejected(self):
        data = self.mutate(
            "EPUB/package.opf",
            lambda value: value.replace(b"chapter00.xhtml", b"missing.xhtml"),
        )
        with self.assertRaises(KeyError):
            epub_tools.validate_epub(data, "Test", minimum_words=1)

    def test_compressed_mimetype_rejected(self):
        output = io.BytesIO()
        with zipfile.ZipFile(io.BytesIO(self.data)) as source:
            with zipfile.ZipFile(
                output, "w", compression=zipfile.ZIP_DEFLATED
            ) as target:
                for entry in source.infolist():
                    target.writestr(entry.filename, source.read(entry))
        with self.assertRaises(AssertionError):
            epub_tools.validate_epub(output.getvalue(), "Test", minimum_words=1)


if __name__ == "__main__":
    unittest.main()
