"""Tokenizing and stemming for the call search index (Russian and English Snowball stemmers).

Ported from session-rag (MIT, same author), where stemming gave +6 pt hit@1 on inflected
Russian queries.
"""
import re
import threading
from functools import lru_cache

import snowballstemmer

_WORD = re.compile(r"[^\W_]+", re.U)
_CYR = re.compile(r"[а-яё]", re.I)
_RU = snowballstemmer.stemmer("russian")
_EN = snowballstemmer.stemmer("english")
# Snowball stemmer objects keep state between calls: one thread at a time.
_STEM_LOCK = threading.Lock()


@lru_cache(maxsize=200_000)
def stem(word: str) -> str:
    w = word.lower()
    if w.isdigit() or len(w) < 3:
        return w
    if _CYR.search(w):
        with _STEM_LOCK:
            return _RU.stemWord(w)
    if w.isascii() and w.isalpha():
        with _STEM_LOCK:
            return _EN.stemWord(w)
    return w


def words(text: str) -> list[str]:
    return [stem(m) for m in _WORD.findall(text)]


def stem_text(text: str) -> str:
    """Stemmed copy of a text for FTS (word order kept, so phrase queries still work)."""
    return " ".join(words(text))


_QUERY_TOKEN = re.compile(r"[\w.\-:/@]+", re.U)
# An OR of thousands of phrases takes minutes in FTS5; a real query never needs more than this.
MAX_PHRASES = 32


def fts_query(q: str) -> str:
    """OR of phrases; a token like ``10.9.8.7`` or ``node-selector`` becomes a phrase of its stemmed parts."""
    phrases = []
    for tok in _QUERY_TOKEN.findall(q):
        parts = words(tok)
        if not parts or (len(parts) == 1 and len(parts[0]) < 2):
            continue
        phrases.append('"' + " ".join(parts) + '"')
    return " OR ".join(list(dict.fromkeys(phrases))[:MAX_PHRASES])
