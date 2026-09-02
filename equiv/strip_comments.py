#!/usr/bin/env python3
"""Strip // and /* */ comments from Verilog and normalise whitespace, so two trees can be
diffed on CODE ONLY. Used to prove a comment-only commit changed no code.
   usage: strip_comments.py <file>            -> stdout
          strip_comments.py <dirA> <dirB>     -> diff of every *.v/*.vh, exit 1 if any differ
"""
import re, sys, os, difflib

def strip(text):
    out, i, n = [], 0, len(text)
    while i < n:
        c = text[i]
        if c == '"':                      # string literal, copy verbatim
            j = i + 1
            while j < n and text[j] != '"':
                j += 2 if text[j] == '\\' else 1
            out.append(text[i:j+1]); i = j + 1
        elif text.startswith('//', i):
            j = text.find('\n', i); i = n if j < 0 else j
        elif text.startswith('/*', i):
            j = text.find('*/', i + 2); i = n if j < 0 else j + 2
        else:
            out.append(c); i += 1
    lines = [re.sub(r'\s+', ' ', l).strip() for l in ''.join(out).split('\n')]
    return '\n'.join(l for l in lines if l) + '\n'

def main():
    if len(sys.argv) == 2:
        sys.stdout.write(strip(open(sys.argv[1]).read())); return 0
    a, b = sys.argv[1], sys.argv[2]
    names = sorted(f for f in os.listdir(a) if f.endswith(('.v', '.vh')))
    rc = 0
    for f in names:
        pa, pb = os.path.join(a, f), os.path.join(b, f)
        if not os.path.exists(pb):
            print(f'MISSING in {b}: {f}'); rc = 1; continue
        sa, sb = strip(open(pa).read()), strip(open(pb).read())
        if sa != sb:
            rc = 1
            print(f'CODE DIFFERS: {f}')
            for l in difflib.unified_diff(sa.splitlines(), sb.splitlines(), pa, pb, lineterm='', n=1):
                print('   ' + l)
    extra = sorted(set(os.listdir(b)) - set(names))
    extra = [f for f in extra if f.endswith(('.v', '.vh'))]
    if extra: print('EXTRA in', b, ':', extra); rc = 1
    print('CODE IDENTICAL (comments/whitespace only)' if rc == 0 else 'CODE DIFFERS')
    return rc

if __name__ == '__main__':
    sys.exit(main())
