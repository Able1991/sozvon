// Tokenizing and stemming for the search index: a port of engine/sozvon_engine/textproc.py.
// Russian and English Snowball stemmers, generated from the same Snowball release the engine uses.
import English from "./vendor/snowball/english-stemmer.js";
import Russian from "./vendor/snowball/russian-stemmer.js";

const ru = new Russian();
const en = new English();

const WORD_CHAR = /^[\p{L}\p{N}]$/u; // Python [^\W_]: letters and digits
const QUERY_TOKEN = /[\p{L}\p{N}_.\-:/@]+/gu; // Python [\w.\-:/@]+
const CYR = /[а-яё]/;
const DIGITS = /^\p{Nd}+$/u;
const ASCII_ALPHA = /^[a-z]+$/;

// Words repeat a lot in a transcript: a per-isolate cache keeps stemming cheap on the Free plan CPU budget.
const cache = new Map<string, string>();
const CACHE_MAX = 50_000;

export function stem(word: string): string {
  const w = word.toLowerCase();
  const hit = cache.get(w);
  if (hit !== undefined) return hit;
  let out = w;
  if (!DIGITS.test(w) && [...w].length >= 3) {
    if (CYR.test(w)) out = ru.stemWord(w);
    else if (ASCII_ALPHA.test(w)) out = en.stemWord(w);
  }
  if (cache.size >= CACHE_MAX) cache.clear();
  cache.set(w, out);
  return out;
}

// Unicode regexes are the slowest part of indexing, so words are cut with a lazily filled table of
// BMP code units (0 unknown, 1 word, 2 not): about 4x faster than matchAll(/[\p{L}\p{N}]+/gu).
const kind = new Uint8Array(0x10000);

function isWordAt(s: string, i: number): number { // -> length of the word character at i, 0 if none
  const c = s.charCodeAt(i);
  if (c >= 0xd800 && c <= 0xdbff) { // astral: rare, test the code point directly
    const ch = String.fromCodePoint(s.codePointAt(i)!);
    return WORD_CHAR.test(ch) ? ch.length : 0;
  }
  let k = kind[c];
  if (k === 0) kind[c] = k = WORD_CHAR.test(String.fromCharCode(c)) ? 1 : 2;
  return k === 1 ? 1 : 0;
}

/** Raw words (letters and digits runs) of a text, like Python re.findall(r"[^\W_]+"). */
export function tokens(text: string): string[] {
  const out: string[] = [];
  let start = -1;
  for (let i = 0; i < text.length;) {
    const n = isWordAt(text, i);
    if (n) {
      if (start < 0) start = i;
      i += n;
    } else {
      if (start >= 0) out.push(text.slice(start, i));
      start = -1;
      i += text.charCodeAt(i) >= 0xd800 && text.charCodeAt(i) <= 0xdbff ? 2 : 1;
    }
  }
  if (start >= 0) out.push(text.slice(start));
  return out;
}

export function words(text: string): string[] {
  return tokens(text).map(stem);
}

/** Stemmed copy of a text for FTS (word order kept, so phrase queries still work). */
export function stemText(text: string): string {
  return words(text).join(" ");
}

/** OR of phrases; a token like `10.9.8.7` or `node-selector` becomes a phrase of its stemmed parts. */
export function ftsQuery(q: string): string {
  const phrases = new Set<string>();
  for (const m of q.matchAll(QUERY_TOKEN)) {
    const parts = words(m[0]);
    if (parts.length === 0 || (parts.length === 1 && [...parts[0]].length < 2)) continue;
    phrases.add(`"${parts.join(" ")}"`);
  }
  return [...phrases].join(" OR ");
}
