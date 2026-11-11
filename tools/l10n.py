#!/usr/bin/env python3
"""Localization of the Swift code.

  tools/l10n.py check   every Russian string in Sources/**/*.swift goes through L("…") and is translated in en.lproj
  tools/l10n.py keys    print all L("…") keys
  tools/l10n.py wrap    wrap bare Russian literals in L("…") (one-time migration)

Rule: every user-facing string is written in Russian inside L("…"), with %@ instead of
interpolation. Translations live in Sources/Sozvon/Resources/en.lproj/Localizable.strings
(L() from SozvonCore also reads them from the app bundle).
A block between // l10n-ignore-start and // l10n-ignore-end, and lines ending with // l10n-ignore, are not checked.
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SOURCES = ROOT / "Sources"
EN = SOURCES / "Sozvon/Resources/en.lproj/Localizable.strings"
CYR = re.compile(r"[А-Яа-яЁё]")


def literals(line):
    out, i, n = [], 0, len(line)
    while i < n:
        if line.startswith("//", i):
            break
        if line[i] == '"':
            j = i + 1
            while j < n and line[j] != '"':
                j += 2 if line[j] == "\\" else 1
            out.append((i, j + 1, line[i + 1:j]))
            i = j + 1
            continue
        i += 1
    return out


def scan():
    for f in sorted(SOURCES.rglob("*.swift")):
        ignore = False
        lines = f.read_text().splitlines()
        for no, line in enumerate(lines, 1):
            if "l10n-ignore-start" in line:
                ignore = True
            if "l10n-ignore-end" in line:
                ignore = False
                continue
            if ignore or line.rstrip().endswith("// l10n-ignore"):
                continue
            for s, e, c in literals(line):
                if CYR.search(c):
                    yield f, no, line, s, e, c


def load_en():
    if not EN.exists():
        return {}
    text = EN.read_text(encoding="utf-8")
    pairs = re.findall(r'^"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)";', text, re.M)
    return dict(pairs)


def main(cmd):
    if cmd == "wrap":
        files = {}
        for f, no, line, s, e, c in scan():
            if line[max(0, s - 2):s] == "L(":
                continue
            if "\\(" in c:
                print(f"interpolation, fix it by hand: {f.relative_to(SOURCES)}:{no}: {c}")
                continue
            files.setdefault(f, []).append((no, s, e))
        for f, items in files.items():
            lines = f.read_text().splitlines()
            for no, s, e in sorted(items, key=lambda x: (x[0], -x[1])):
                l = lines[no - 1]
                lines[no - 1] = l[:s] + "L(" + l[s:e] + ")" + l[e:]
            f.write_text("\n".join(lines) + "\n")
            print(f"{f.relative_to(SOURCES)}: wrapped {len(items)}")
        return 0
    keys, bad = [], []
    for f, no, line, s, e, c in scan():
        if line[max(0, s - 2):s] != "L(":
            bad.append(f"{f.relative_to(SOURCES)}:{no}: string without L(): \"{c}\"")
        elif "\\(" in c:
            bad.append(f"{f.relative_to(SOURCES)}:{no}: interpolation inside L(), use %@: \"{c}\"")
        else:
            keys.append(c)
    keys = list(dict.fromkeys(keys))
    if cmd == "keys":
        print("\n".join(keys))
        return 0
    en = load_en()
    for k in keys:
        if k not in en:
            bad.append(f"missing English translation: \"{k}\"")
        elif en[k].count("%@") != k.count("%@"):
            bad.append(f"placeholder count differs: \"{k}\"")
    unused = [k for k in en if k not in keys]
    for k in unused:
        print(f"warning: unused translation \"{k}\"")
    for b in bad:
        print(b)
    print(f"l10n: {len(keys)} strings, {len(bad)} errors")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else "check"))
