#!/usr/bin/env python3
"""ARB (Flutter, lib/l10n/arb/app_{de,en,tr}.arb) -> Android strings.xml in :core.

Gleiche Texte wie die Flutter-App:
  core/src/main/res/values/strings.xml     Englisch (Systemsprache ≠ de/tr → en, wie L10n.systemLang)
  core/src/main/res/values-de/strings.xml  Deutsch (Quelltexte)
  core/src/main/res/values-tr/strings.xml  Türkisch
Fehlt eine Übersetzung, steht dort der deutsche Text (wie L10n.t()).
Platzhalter {0}, {1} … werden zu %1$s, %2$s …; Ressourcen-Name = ARB-Schlüssel
(Java-Schlüsselwörter bekommen ein „_“ angehängt).

Aufruf (aus tv_native/):  python3 tools/gen_strings.py [pfad/zu/arb]
"""
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
ARB = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, '..', 'lib', 'l10n', 'arb')
RES = os.path.join(ROOT, 'core', 'src', 'main', 'res')

KEYWORDS = set('''abstract assert boolean break byte case catch char class const continue default do double
else enum extends final finally float for goto if implements import instanceof int interface long native new
package private protected public return short static strictfp super switch synchronized this throw throws
transient try void volatile while true false null fun val var object when is in as typealias'''.split())


def load(lang):
    with open(os.path.join(ARB, f'app_{lang}.arb'), encoding='utf-8') as f:
        d = json.load(f)
    return {k: v for k, v in d.items() if not k.startswith('@') and isinstance(v, str)}


def res_name(key):
    return key + '_' if key in KEYWORDS else key


def android_text(s):
    has_args = re.search(r'\{\d+\}', s) is not None
    if has_args:
        s = s.replace('%', '%%')
        s = re.sub(r'\{(\d+)\}', lambda m: '%%%d$s' % (int(m.group(1)) + 1), s)
    s = (s.replace('\\', '\\\\').replace('&', '&amp;').replace('<', '&lt;').replace('>', '&gt;')
         .replace("'", "\\'").replace('"', '\\"').replace('\n', '\\n').replace('\t', '\\t'))
    if s.startswith('@') or s.startswith('?'):
        s = '\\' + s
    # Führende/abschließende Leerzeichen erhalten.
    if s != s.strip():
        s = s.replace(' ', '\\u0020', 1) if s.startswith(' ') else s
        if s.endswith(' '):
            s = s[:-1] + '\\u0020'
    formatted = '' if has_args or '%' not in s else ' formatted="false"'
    return s, formatted


def write(folder, table, fallback):
    os.makedirs(os.path.join(RES, folder), exist_ok=True)
    out = ['<?xml version="1.0" encoding="utf-8"?>',
           '<!-- ERZEUGT von tools/gen_strings.py aus lib/l10n/arb – nicht von Hand ändern. -->',
           '<resources xmlns:tools="http://schemas.android.com/tools" tools:ignore="MissingTranslation,UnusedResources,TypographyEllipsis,TypographyDashes">']
    for key in fallback:
        text, fmt = android_text(table.get(key) or fallback[key])
        out.append(f'    <string name="{res_name(key)}"{fmt}>{text}</string>')
    out.append('</resources>\n')
    with open(os.path.join(RES, folder, 'strings.xml'), 'w', encoding='utf-8') as f:
        f.write('\n'.join(out))
    return len(fallback)


def main():
    de, en, tr = load('de'), load('en'), load('tr')
    n = write('values', en, de)
    write('values-de', de, de)
    write('values-tr', tr, de)
    print(f'{n} Texte -> {RES}/values{{,-de,-tr}}/strings.xml')


if __name__ == '__main__':
    main()
