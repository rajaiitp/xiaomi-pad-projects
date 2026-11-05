import os
from pathlib import Path

ROOT = (
    Path(os.environ.get("XIAOMI_BOOKS_CACHE", Path.home() / ".cache/book-collections"))
    / "philosophy-of-love"
)
ROOT.mkdir(parents=True, exist_ok=True)
(ROOT / "sources").mkdir(exist_ok=True)
