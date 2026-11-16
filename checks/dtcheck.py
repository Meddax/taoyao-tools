#!/usr/bin/env python3
"""Lightweight device tree sanity check for the taoyao 6.12 port.

It is not a replacement for dtc: it runs the C preprocessor over a base
.dts and an overlay .dtso exactly like the kernel's DT build does, then
checks what dtc would reject first:

  * every #include resolves (the preprocessor fails otherwise),
  * braces are balanced,
  * every &label / <&label ...> reference in the overlay is defined in
    the base device tree or in the overlay itself,
  * labels defined twice inside the overlay are reported as warnings,
  * inside every node body all properties come before the first subnode
    (dtc: "Properties must precede subnodes"),
  * every statement ends with ';' and cell lists are closed.

Usage:
  dtcheck.py --kernel <kernel tree> --base yupik-taoyao.dts \
             --overlay taoyao-sm7325-overlay.dtso [--cpp clang]

The real compile (dtc -@, fdtoverlay) still runs in CI.
"""
import argparse
import os
import re
import subprocess
import sys

LABEL_DEF = re.compile(r'(?<![\w&/])([A-Za-z_][\w]*)\s*:\s*(?=[A-Za-z_/&][^;{}]*\{)')
REF = re.compile(r'&([A-Za-z_][\w]*)')


def preprocess(cpp, kernel, path, markers=False):
    dts = os.path.join(kernel, 'arch/arm64/boot/dts/vendor')
    incs = [
        os.path.dirname(os.path.abspath(path)),
        os.path.join(dts, 'qcom'),
        os.path.join(dts, 'include'),
        os.path.join(kernel, 'scripts/dtc/include-prefixes'),
        os.path.join(kernel, 'include'),
        os.path.join(kernel, 'techpack/audio/include'),
        os.path.join(kernel, 'techpack/camera'),
    ]
    cmd = [cpp, '-E', '-nostdinc', '-undef', '-D__DTS__',
           '-x', 'assembler-with-cpp'] + ([] if markers else ['-P'])
    for i in incs:
        cmd += ['-I', i]
    cmd.append(path)
    res = subprocess.run(cmd, capture_output=True, text=True)
    if res.returncode != 0:
        sys.stderr.write(res.stderr)
        raise SystemExit(f'preprocessing failed: {path}')
    return res.stdout


def strip_comments(text):
    out, i, n = [], 0, len(text)
    in_str = False
    while i < n:
        c = text[i]
        if in_str:
            out.append(c)
            if c == '\\' and i + 1 < n:
                out.append(text[i + 1])
                i += 2
                continue
            if c == '"':
                in_str = False
            i += 1
            continue
        if c == '"':
            in_str = True
            out.append(c)
            i += 1
        elif text.startswith('/*', i):
            j = text.find('*/', i + 2)
            i = n if j < 0 else j + 2
        elif text.startswith('//', i):
            j = text.find('\n', i)
            i = n if j < 0 else j
        else:
            out.append(c)
            i += 1
    return ''.join(out)


def strip_strings(text):
    return re.sub(r'"(?:\\.|[^"\\])*"', '""', text)


def labels(text):
    return LABEL_DEF.findall(text)


def refs(text):
    # skip &{/path} references
    return [m.group(1) for m in REF.finditer(text)]


TOKEN = re.compile(r'''
    (?P<ws>\s+)
  | (?P<marker>^\#\s*\d+\s+"[^"]*"[^\n]*$)
  | (?P<str>"(?:\\.|[^"\\])*")
  | (?P<char>'(?:\\.|[^'\\])')
  | (?P<bytes>\[[^\]]*\])
  | (?P<kw>/dts-v1/|/plugin/|/delete-node/|/delete-property/|/bits/|/memreserve/|/omit-if-no-ref/|/include/)
  | (?P<pathref>&\{[^}]*\})
  | (?P<ref>&[A-Za-z_][\w]*)
  | (?P<label>[A-Za-z_][\w]*:)
  | (?P<lt><)
  | (?P<p>[{};=])
  | (?P<name>[^\s{};=<>"'\[\]&()]+)
  | (?P<other>.)
''', re.X | re.M)
MARKER = re.compile(r'^#\s*(\d+)\s+"([^"]*)"')


def structure_ok(text, name):
    """Check node bodies the way dtc's grammar does: in a node, every
    property (and /delete-property/) must come before the first subnode
    (or /delete-node/). text is preprocessor output with line markers."""
    pos, n = 0, len(text)
    src, line = name, 1
    stack = []          # per open node: [seen_subnode, where]
    stmt = []           # tokens of the current statement at this depth
    stmt_where = None
    errors = []

    def where():
        return f'{src}:{line}'

    while pos < n:
        m = TOKEN.match(text, pos)
        kind, val = m.lastgroup, m.group(0)
        if kind == 'marker':
            mm = MARKER.match(val)
            src, line = mm.group(2), int(mm.group(1))
            pos = m.end()
            # the marker line itself is followed by its newline (ws token)
            if pos < n and text[pos] == '\n':
                pos += 1
            continue
        if kind == 'lt':
            # cell list: scan to the matching '>' outside parentheses
            depth, j = 0, m.end()
            while j < n:
                c = text[j]
                if c == '(':
                    depth += 1
                elif c == ')':
                    depth -= 1
                elif c == '>' and depth == 0:
                    break
                elif c in ';{}' and depth == 0:
                    errors.append(f'{where()}: cell list not closed with ">"')
                    break
                j += 1
            val = text[pos:j + 1]
            kind = 'cells'
            m_end = j + 1
        else:
            m_end = m.end()
        line += val.count('\n')
        pos = m_end
        if kind == 'ws':
            continue
        if not stmt:
            stmt_where = where()
        if val == '{':
            # opening a node body: this statement is a subnode of the parent
            if stack:
                stack[-1][0] = True
            stack.append([False, stmt_where])
            stmt = []
            continue
        if val == '}':
            if stmt:
                errors.append(f'{stmt_where}: statement before "}}" lacks ";"')
                stmt = []
            if not stack:
                errors.append(f'{where()}: unbalanced "}}"')
            else:
                stack.pop()
            # the "};" terminator
            m2 = re.compile(r'\s*;').match(text, pos)
            if m2:
                line += m2.group(0).count('\n')
                pos = m2.end()
            else:
                errors.append(f'{where()}: "}}" not followed by ";"')
            continue
        if val == ';':
            if stack and stmt:
                first = next((t for t in stmt if t[0] != 'label'), None)
                is_node = first is not None and first[1] == '/delete-node/'
                if not is_node:
                    if stack[-1][0]:
                        errors.append(f'{stmt_where}: property "{first[1] if first else "?"}" '
                                      'after a subnode (dtc: Properties must precede subnodes)')
            stmt = []
            continue
        stmt.append((kind, val))
    if stack:
        errors.append(f'{name}: {len(stack)} node(s) not closed')
    for e in errors[:50]:
        print(e)
    return not errors


def braces_ok(text, name):
    depth = 0
    for lineno, line in enumerate(text.splitlines(), 1):
        depth += line.count('{') - line.count('}')
        if depth < 0:
            print(f'{name}:{lineno}: unbalanced closing brace')
            return False
    if depth != 0:
        print(f'{name}: {depth} unclosed brace(s)')
        return False
    return True


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--kernel', required=True)
    ap.add_argument('--base', required=True)
    ap.add_argument('--overlay', required=True)
    ap.add_argument('--cpp', default='clang')
    ap.add_argument('--dump', help='write the preprocessed overlay here')
    a = ap.parse_args()

    base = strip_strings(strip_comments(preprocess(a.cpp, a.kernel, a.base)))
    ovl_raw = strip_comments(preprocess(a.cpp, a.kernel, a.overlay))
    ovl = strip_strings(ovl_raw)
    if a.dump:
        with open(a.dump, 'w') as f:
            f.write(ovl_raw)

    ok = braces_ok(base, a.base) & braces_ok(ovl, a.overlay)
    for path in (a.base, a.overlay):
        ok &= structure_ok(strip_comments(preprocess(a.cpp, a.kernel, path, markers=True)), path)

    base_labels = set(labels(base))
    ovl_label_list = labels(ovl)
    ovl_labels = set(ovl_label_list)
    seen, dups = set(), set()
    for lab in ovl_label_list:
        if lab in seen:
            dups.add(lab)
        seen.add(lab)
    # dtc accepts a label repeated on the same node (e.g. a node re-opened in
    # a second dtsi), so this is only a hint for a human to look at.
    for lab in sorted(dups):
        print(f'warning: label defined more than once in overlay: {lab}')

    known = base_labels | ovl_labels
    missing = sorted({r for r in refs(ovl) if r not in known})
    for r in missing:
        print(f'undefined reference in overlay: &{r}')
    if missing:
        ok = False

    base_missing = sorted({r for r in refs(base) if r not in base_labels})
    for r in base_missing:
        print(f'undefined reference in base: &{r}')
    if base_missing:
        ok = False

    print(f'base labels: {len(base_labels)}, overlay labels: {len(ovl_labels)}, '
          f'overlay refs: {len(set(refs(ovl)))}')
    print('OK' if ok else 'FAILED')
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())
