#!/usr/bin/env bash
# Pull every L("key", "English") / Lf(...) out of the source and sync the tables in
# Resources/*.lproj/Localizable.strings.
#
# English is written at the call site, so the code is the single source of truth for it
# and en.lproj is overwritten on every run. Every other language is a translation:
# nothing is overwritten, missing keys are marked MISSING with the English alongside.
#   scripts/i18n-scan.sh
set -euo pipefail
cd "$(dirname "$0")/.."
python3 - <<'PY'
import re, os, glob, sys

pairs = {}   # key -> English

# Two literal forms have to be recognised:
#   L("key", "one line")
#   L("key", """
#   several lines
#   """)
# Recognising only the single-line form captures the multi-line one as an **empty string**, which is
# then written into .strings over a correct translation — and the sentence disappears from the
# interface entirely (2026-09-06: this is how welcome.why was lost, taking a whole paragraph out of
# the welcome window).
#   L("key", """
#   """)
SINGLE = re.compile(r'\bLf?\(\s*"((?:[^"\\]|\\.)+)"\s*,\s*"((?:[^"\\]|\\.)*)"')
# A third form joins several pieces with +:
#   L("key", "first line\n"
#            + "second line\n"
#            + "third line")
# Recognising only the first piece silently drops the rest — the interface shows one sentence, and
# because it is **not an empty string, nothing detects it**. Caught 2026-09-06 03:00: all four
# permission explanations had been truncated to a single sentence, and those four are the body text
# of "you clicked a dimmed button, here is why" — the lines a user most needs to read.
CONCAT = re.compile(
    r'\bLf?\(\s*"(?:[^"\\]|\\.)+"\s*,\s*"(?:[^"\\]|\\.)*"'   # the first piece
    r'(?:\s*\+\s*"(?:[^"\\]|\\.)*")+')                            # every piece after it
PIECE  = re.compile(r'"((?:[^"\\]|\\.)*)"')
MULTI  = re.compile(r'\bLf?\(\s*"((?:[^"\\]|\\.)+)"\s*,\s*"""\n(.*?)\n\s*"""', re.S)

def dedent_swift(block: str) -> str:
    lines = block.split("\n")
    indents = [len(l) - len(l.lstrip()) for l in lines if l.strip()]
    cut = min(indents) if indents else 0
    return "\n".join(l[cut:] if len(l) >= cut else l for l in lines).strip()

conflicts = []
for f in glob.glob("Sources/**/*.swift", recursive=True):
    raw = open(f).read()
    # Skip comment lines — an example in a doc comment is not a real string
    body = "\n".join(l for l in raw.split("\n") if not l.lstrip().startswith("//"))
    found = {}
    for k, zh in MULTI.findall(body):
        found[k] = dedent_swift(zh).replace("\n", "\\n")
    for whole in CONCAT.findall(body):
        parts = PIECE.findall(whole)
        if len(parts) >= 3:         # key plus at least two pieces of body
            found[parts[0]] = "".join(parts[1:])
    for k, zh in SINGLE.findall(body):
        found.setdefault(k, zh)     # the multi-line and concatenated forms are already captured
    for k, zh in found.items():
        if not zh.strip():
            print(f"⚠️  {k} has an empty string, skipping (never let an empty string overwrite a translation)")
            continue
        if k in pairs and pairs[k] != zh:
            print(f"⚠️  key conflict {k}: {pairs[k]!r} vs {zh!r}")
            conflicts.append(k)
        pairs[k] = zh
print(f"{len(pairs)} strings found")
if conflicts:
    # Two call sites, one key, different English: one of them is showing the wrong sentence, and
    # every translation table can only hold one of them. Stop here rather than write either.
    sys.exit(f"✗ {len(conflicts)} key(s) used with two different English strings: {conflicts} — rename one")

def load(path):
    if not os.path.exists(path): return {}
    out = {}
    for line in open(path, encoding="utf-8"):
        m = re.match(r'^"((?:[^"\\]|\\.)+)"\s*=\s*"((?:[^"\\]|\\.)*)";', line.strip())
        if m: out[m.group(1)] = m.group(2)
    return out

def write(path, table, header):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        f.write(f"// {header}\n// Maintained by scripts/i18n-scan.sh. Translations can be edited by hand; keys cannot.\n\n")
        for k in sorted(table):
            f.write(f'"{k}" = "{table[k]}";\n')

# English is **the literal in the code** and is overwritten every run; every other language is a
# translation table that only gains missing keys and is never overwritten.
# The language list comes from Resources/*.lproj itself — adding a language means creating a
# directory, and the script picks it up.
SRC = "en"    # the language written at the call site
locales = sorted(os.path.basename(d)[:-len(".lproj")] for d in glob.glob("Resources/*.lproj"))
assert SRC in locales, "no Resources/en.lproj"

def path(loc): return f"Resources/{loc}.lproj/Localizable.strings"

tables = {loc: load(path(loc)) for loc in locales}

# The call-site language is overwritten from the code every run.
# It used to be "keep whatever is already there", and then editing the string in the
# source changed nothing on screen — three separate times in one day (2026-09-05).
# Writing it at the call site is what makes the code the single source of truth;
# a .strings file with its own copy defeats that.
new_zh, changed_zh = 0, []
zh = tables[SRC]
for k, v in pairs.items():
    if k not in zh: new_zh += 1
    elif zh[k] != v: changed_zh.append(k)
    zh[k] = v

# Other languages: mark what is missing as MISSING with the English alongside, so whoever translates
# does not have to go back to the source
for loc in locales:
    if loc == SRC: continue
    t = tables[loc]
    for k, v in pairs.items():
        if k not in t: t[k] = "MISSING: " + v

# Drop keys deleted from the code out of every table, so they do not pile up
for t in tables.values():
    for k in [k for k in t if k not in pairs]: del t[k]

NAMES = {"zh-Hans": "Simplified Chinese", "zh-HK": "Traditional Chinese (Hong Kong)", "en": "English", "ja": "Japanese",
         "ko": "한국어", "de": "Deutsch", "fr": "Francais", "es": "Espanol",
         "it": "Italiano", "pt-BR": "Portugues (Brasil)", "ru": "Russkiy"}
for loc in locales:
    write(path(loc), tables[loc], NAMES.get(loc, loc))

# Placeholders have to line up in every language — a translation that drops a %@ shows hardcoded old
# content on that line instead of the variable
SPEC = re.compile(r'%(?:\d+\$)?[-+ #0]*[\d.*]*(?:hh|h|ll|l|q|L|z|j|t)?[@dDiuUxXoOfeEgGcCsSpaA]')
bad = []
for loc in locales:
    if loc == SRC: continue
    for k in sorted(set(zh) & set(tables[loc])):
        v = tables[loc][k]
        if v.startswith("MISSING:"): continue
        if SPEC.findall(zh[k]) != SPEC.findall(v): bad.append((loc, k))
if bad:
    print(f"placeholder mismatch on {len(bad)} keys — a dropped %@ means hardcoded old content:")
    for loc, k in bad[:10]:
        print(f"   [{loc}] {k}")
        print(f"     zh {zh[k][:66]}")
        print(f"     {loc} {tables[loc][k][:66]}")

print(f"English: {new_zh} new")
for loc in locales:
    if loc == SRC: continue
    miss = [k for k, v in tables[loc].items() if v.startswith("MISSING:")]
    print(f"  {loc:<8} untranslated {len(miss):>3} / {len(tables[loc])}")
if changed_zh:
    print(f"English changed on {len(changed_zh)} keys — the other languages may need to follow:", ", ".join(changed_zh[:8]))
PY
