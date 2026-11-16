#!/usr/bin/env python3
"""UAPI ABI diff gate for the taoyao 6.12 port.

Every taoyao ROM (stock HyperOS, crDroid, Evolution X) runs vendor userspace
built against the msm-5.4 headers: ipacm, libadsprpc, CamX, the audio, display
and video HALs, qseecomd, the touch, fingerprint and NFC HALs. A 6.12 header
that differs from 5.4 breaks those binaries without a build error. Many QTI
ioctls encode a pointer type (_IOWR(..., struct x *)), so even a struct that
grows keeps its command number and nobody notices (the IPA_HDR_MAX_SIZE break).

For each header set in units.conf this tool generates a C probe and compiles
it for aarch64 and armv7 (clang --target, -c only, no kernel build). It reads
back every _IOC number, every integer #define and enumerator, and sizeof,
_Alignof, offsetof and member sizes of every struct, union and typedef the
headers define. The dumps of the 6.12 tree are compared with the dumps of the
5.4 headers kept in ref/. A difference fails the check unless allowlist.txt
lists it with a reason.

Units (units.conf) and references (ref/, made with `ref`):
  ref/5.4.txt      st: taoyao-stock, the Xiaomi taoyao 5.4 OSS = what the
                   stock HyperOS blobs were built with; holds every unit and
                   is the reference of every unit except the ones below
  ref/5.4-los.txt  los: taoyao54, the LineageOS 5.4 kernel headers
                   (include/uapi/linux of skglab kernel_xiaomi_taoyao
                   lineage-23.2; the EvoX arunika and taoyao-labs lineage-24.0
                   kernels and evoxdev cnb carry the same IPA headers);
                   holds the units with `ref = los`: ipa (msm_ipa.h,
                   rmnet_ipa_fd_ioctl.h, ipa_qmi_service_v01.h) and rmnet
                   (msm_rmnet.h). Evolution X and crDroid build ipacm and
                   libipanat from source against these headers, and taoyao's
                   native IPA/WAN layout is this one (techpack/dataipa, behind
                   CONFIG_MACH_XIAOMI_TAOYAO); stock HyperOS's older layout is
                   translated at the ioctl boundary by ipam (uapi_stock=1).
  `check --unit-ref ipa=st` compares a unit with the other reference instead
  (here: what the stock-layout translation has to convert; those rows FAIL,
  the allowlist covers the native layout only).

Commands
  ref    --tree st=<taoyao-stock>@HEAD+wt --tree t=<taoyao54>@HEAD+wt
         [--which st,los]
         write ref/5.4.txt (st) and ref/5.4-los.txt (los; needs only t) from
         the 5.4 trees (5.4 side of units.conf; both are sparse partial
         clones here, hence git HEAD + worktree)
  dump   --tree <dir>[@<rev>[+wt]] [--side 612|54] [--arch A] [--config F] [-o F]
         dump one tree (<rev>: read the files from git, +wt: overlay the files
         on disk, for a sparse checkout with local changes)
  check  --tree <k612>[@<rev>[+wt]] [--config <taoyao_defconfig>]
         [--report F] [--show-added] [--unit-ref UNIT=st|los ...]
         6.12 tree against ref/ (each unit against its reference) with
         allowlist.txt; exit 1 on a difference that is not allowlisted (the
         taoyao CI step)
  same   --tree <k612> [--base-rev HEAD] [--config <redwood_defconfig>]
         6.12 tree at <base-rev> against its working tree, with
         allowlist-same.txt (CI, second check: the redwood ROM is built
         against the unpatched 6.12 headers, so seen through redwood_defconfig
         the port must not change them outside a taoyao gate; additions are
         not checked)
  diff   <old.txt> <new.txt> [--allow F]
         compare two dumps

--config <defconfig or .config> force-includes an autoconf.h made from it for
the 6.12 side, so the probe sees a header the way the kernel compiles it (a
CONFIG_MACH_XIAOMI_TAOYAO gate in a UAPI header selects the taoyao layout).
The 5.4 side is probed as userspace sees it: no CONFIG_, no __KERNEL__.

Each ref file records a hash of the 5.4 side of the units it holds (for los:
with the 5.4 root replaced by tree t) and of the probe (shims and this
script's probe version); check refuses a ref made with other ones. A unit
that does not compile is an error in every command.

Dump lines: KIND<TAB>KEY<TAB>VALUE<TAB>UNIT, KIND one of
  IOC   ioctl number (any macro built on _IOC)    DEF   integer #define
  ENUM  enumerator                                SIZE / ALIGN   of a type
  OFF / FSIZE  offset and size of a member        BITW  bit-field width
  IOCT  payload type of an ioctl and FTYPE member type (not compared; they
        tie a changed struct to the ioctls that carry it in the report)
"""
import argparse
import configparser
import fnmatch
import hashlib
import json
import os
import re
import shutil
import struct
import subprocess
import sys
import tempfile
from concurrent.futures import ThreadPoolExecutor

HERE = os.path.dirname(os.path.abspath(__file__))
ARCHES = {
    # bionic triples, as the vendor blobs were built (ILP32 armv7, LP64 aarch64)
    'aarch64': ('aarch64-linux-android', 'arm64'),
    'armv7': ('armv7a-linux-androideabi', 'arm'),
}
COMPARED = ('IOC', 'DEF', 'ENUM', 'SIZE', 'ALIGN', 'OFF', 'FSIZE', 'BITW')
# bump when the probe changes what it records or how (ref/ must be remade)
PROBE_VERSION = 1
IOC_BASE = {'_IOC', '_IO', '_IOR', '_IOW', '_IOWR', '_IOR_BAD', '_IOW_BAD', '_IOWR_BAD'}
DEFINE_RE = re.compile(r'^[ \t]*#[ \t]*define[ \t]+([A-Za-z_]\w*)(\()?', re.M)
CC = os.environ.get('UAPICHECK_CC', 'clang')
# the 5.4 references in ref/: st = stock HyperOS (taoyao-stock, every unit),
# los = the LineageOS 5.4 kernel headers Evolution X and crDroid build their
# ipacm with (taoyao54, only the units with `ref = los` in units.conf)
REFS = {'st': '5.4.txt', 'los': '5.4-los.txt'}
LOS_ROOT = 't'
ERR = 'ERROR: '     # prefix of a note that makes the dump unusable


def log(msg):
    print(msg, file=sys.stderr, flush=True)


# ---------------------------------------------------------------- units.conf

def load_units(path=None):
    cp = configparser.ConfigParser(interpolation=None, inline_comment_prefixes=None)
    cp.optionxform = str
    cp.read(path or os.path.join(HERE, 'units.conf'))
    units = []
    for name in cp.sections():
        sec = cp[name]
        u = {'name': name}
        for side in ('54', '612'):
            def get(key, default=''):
                return sec.get(f'{side}.{key}', sec.get(key, default))
            u[side] = {
                'root': get('root', 'main'),
                'inc': get('inc').split(),
                'hdr': get('hdr').split(),
                'extract': get('extract').split(),
                'define': get('define').split(),
            }
        u['ref'] = sec.get('ref', 'st')
        if u['ref'] not in REFS:
            sys.exit(f'units.conf: [{name}] ref = {u["ref"]}: not one of {", ".join(REFS)}')
        units.append(u)
    return units


def unit_hash(u, side):
    s = u[side]
    blob = json.dumps([u['name'], s], sort_keys=True).encode()
    return hashlib.sha256(blob).hexdigest()[:12]


def ref_units(units, ref):
    """the units a reference file holds, with their 5.4 side as probed for it:
    st = every unit as units.conf says; los = the units with `ref = los`, the
    5.4 side read from the LineageOS 5.4 tree (LOS_ROOT) instead"""
    if ref == 'st':
        return units
    out = []
    for u in units:
        if u['ref'] == ref:
            v = json.loads(json.dumps(u))
            v['54']['root'] = LOS_ROOT
            out.append(v)
    return out


def ref_units_line(units, ref):
    return ' '.join(f'{u["name"]}:{unit_hash(u, "54")}' for u in ref_units(units, ref))


def probe_hash():
    """the shims and the probe version: what makes a 5.4 and a 6.12 dump comparable"""
    h = hashlib.sha256(f'probe {PROBE_VERSION}'.encode())
    base = os.path.join(HERE, 'shim')
    for dp, dn, fn in sorted(os.walk(base)):
        dn.sort()
        for f in sorted(fn):
            h.update(os.path.relpath(os.path.join(dp, f), base).encode())
            h.update(open(os.path.join(dp, f), 'rb').read())
    return h.hexdigest()[:12]


# ---------------------------------------------------------------- trees

class Tree:
    """A source tree: a directory, or <dir>@<rev> read from git, or
    <dir>@<rev>+wt = git rev overlaid with what is on disk (sparse K)."""

    def __init__(self, spec, tmp):
        self.spec = spec
        self.rev = None
        self.wt = False
        d = spec
        if '@' in spec:
            d, rev = spec.rsplit('@', 1)
            if rev.endswith('+wt'):
                rev, self.wt = rev[:-3], True
            self.rev = rev
        self.dir = os.path.abspath(d)
        if not os.path.isdir(self.dir):
            sys.exit(f'uapicheck: no such tree {self.dir}')
        self.tmp = tmp
        self.root = self.dir if self.rev is None else None

    def git(self, *args, check=True):
        # never fetch: a partial clone (blob:none) must not go to the network
        env = dict(os.environ, GIT_NO_LAZY_FETCH='1')
        return subprocess.run(['git', '-C', self.dir, *args], check=check, env=env,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE)

    def describe(self):
        h = ''
        if os.path.exists(os.path.join(self.dir, '.git')):
            r = self.git('rev-parse', '--short=12', self.rev or 'HEAD', check=False)
            h = r.stdout.decode().strip()
        if self.rev is None:
            mode = 'files' + (f', HEAD {h}' if h else '')
        else:
            mode = f'git {self.rev} {h}' + (' + worktree' if self.wt else '')
        return f'{os.path.basename(self.dir)} ({mode})'

    def materialize(self, paths):
        """Make <paths> (dirs or files, relative) available on disk; returns the root."""
        if self.rev is None:
            return self.dir
        if self.root is None:
            self.root = tempfile.mkdtemp(prefix='tree-', dir=self.tmp)
            self.done = set()
        want = [p for p in sorted(set(paths)) if p not in self.done]
        self.done.update(want)
        exist = [p for p in want if self.git('ls-tree', '--name-only', self.rev, '--', p).stdout.strip()]
        if exist:
            # a partial clone may lack blobs; list them instead of fetching
            r = self.git('rev-list', '--objects', '--missing=print', self.rev, '--', *exist)
            missing = [x[1:] for x in r.stdout.decode().split() if x.startswith('?')]
            if missing:
                sys.exit(f'uapicheck: {self.dir} is a partial clone without {len(missing)} objects under '
                         f'{" ".join(exist)} at {self.rev}; fetch them first or pass the directory')
            tar = self.git('archive', '--format=tar', self.rev, '--', *exist)
            subprocess.run(['tar', '-x', '-C', self.root], input=tar.stdout, check=True)
        if self.wt:
            for p in want:
                src = os.path.join(self.dir, p)
                if os.path.isfile(src):
                    os.makedirs(os.path.dirname(os.path.join(self.root, p)), exist_ok=True)
                    shutil.copy2(src, os.path.join(self.root, p))
                elif os.path.isdir(src):
                    for dp, dn, fn in os.walk(src):
                        rel = os.path.relpath(dp, self.dir)
                        os.makedirs(os.path.join(self.root, rel), exist_ok=True)
                        for f in fn:
                            shutil.copy2(os.path.join(dp, f), os.path.join(self.root, rel, f))
        return self.root


# ---------------------------------------------------------------- config -> autoconf

def autoconf_from(path, out):
    lines = ['/* uapicheck: CONFIG_ symbols from %s */' % os.path.basename(path)]
    n = 0
    with open(path) as f:
        for line in f:
            m = re.match(r'^(CONFIG_\w+)=(.*)$', line.strip())
            if not m:
                continue
            k, v = m.groups()
            if v == 'y':
                lines.append(f'#define {k} 1')
            elif v == 'm':
                lines.append(f'#define {k}_MODULE 1')
            elif v != 'n':
                lines.append(f'#define {k} {v}')
            n += 1
    with open(out, 'w') as f:
        f.write('\n'.join(lines) + '\n')
    return n


# ---------------------------------------------------------------- extract mode

def extract_header(src, dst):
    """Keep the parts of a kernel-internal header that can describe an ABI:
    #define/#undef, preprocessor conditionals, #pragma pack and struct, union,
    enum and typedef definitions. Includes, prototypes and inline functions
    go. Returns the chunk table [(first line, last line, label)] of dst."""
    text = open(src, errors='replace').read()
    # join continuation lines but keep the line count of each logical line
    raw = text.split('\n')
    logical = []
    i = 0
    while i < len(raw):
        line, n = raw[i], 1
        while line.endswith('\\') and i + n < len(raw):
            line = line[:-1] + ' ' + raw[i + n]
            n += 1
        logical.append(line)
        i += n
    out, chunks = [], []

    def emit(lines, label):
        start = len(out) + 1
        out.extend(lines)
        if label:
            chunks.append((start, len(out), label))

    j = 0
    while j < len(logical):
        s = logical[j]
        t = s.strip()
        if t.startswith('#'):
            d = re.match(r'#\s*(\w+)', t)
            d = d.group(1) if d else ''
            if d in ('define', 'undef'):
                emit([s], f'macro {t.split()[1] if len(t.split()) > 1 else ""}')
            elif d in ('if', 'ifdef', 'ifndef', 'elif', 'else', 'endif'):
                emit([s], None)
            elif d == 'pragma' and 'pack' in t:
                emit([s], None)
            j += 1
            continue
        m = re.match(r'^\s*(typedef\s+)?(struct|union|enum)\b[^;(]*\{', s) if not t.startswith('static') else None
        if m:
            # collect until the braces balance and the declaration ends with ';'
            body, depth, k = [], 0, j
            while k < len(logical):
                body.append(logical[k])
                code = re.sub(r'//.*|/\*.*?\*/', '', logical[k])
                depth += code.count('{') - code.count('}')
                if depth <= 0 and ';' in code.split('}')[-1]:
                    break
                k += 1
            name = re.match(r'^\s*(?:typedef\s+)?(struct|union|enum)\s*(\w*)', s)
            emit(body, f'{name.group(1)} {name.group(2) or "(anonymous)"}')
            j = k + 1
            continue
        if re.match(r'^\s*typedef\b[^{]*;\s*$', s) and '(' not in s:
            emit([s], 'typedef ' + s.strip().rstrip(';').split()[-1])
        j += 1
    with open(dst, 'w') as f:
        f.write('\n'.join(out) + '\n')
    return chunks


# ---------------------------------------------------------------- clang JSON AST

def annotate_files(node, state):
    """Clang's JSON gives a location's file only when it changes; walk in
    emission order and put the file of every decl into node['_file']."""
    if isinstance(node, list):
        for x in node:
            annotate_files(x, state)
        return
    if not isinstance(node, dict):
        return

    def bare(loc):
        if not isinstance(loc, dict):
            return
        if 'spellingLoc' in loc or 'expansionLoc' in loc:
            bare(loc.get('spellingLoc'))
            bare(loc.get('expansionLoc'))
            return
        if 'file' in loc:
            state['file'] = loc['file']

    for k, v in list(node.items()):
        if k == 'loc':
            bare(v)
            node['_file'] = state['file']
        elif k == 'range':
            if isinstance(v, dict):
                bare(v.get('begin'))
                bare(v.get('end'))
        elif k in ('includedFrom',):
            continue
        elif isinstance(v, (dict, list)):
            annotate_files(v, state)


ANON_RE = re.compile(r'\((unnamed|anonymous)\b|::\(anonymous')


def record_fields(rec, prefix):
    """[(path, qualType, bitwidth or None, flexible)] of a record, anonymous
    members flattened, members of unnamed type descended into."""
    out = []
    pending = None
    for ch in rec.get('inner', []):
        kind = ch.get('kind')
        if kind == 'RecordDecl':
            if ch.get('completeDefinition') and not ch.get('name'):
                pending = ch
            continue
        if kind != 'FieldDecl':
            continue
        qt = ch.get('type', {}).get('qualType', '')
        name = ch.get('name')
        if not name:
            if pending is not None:
                out += record_fields(pending, prefix)
            pending = None
            continue
        path = prefix + name
        width = None
        if ch.get('isBitfield'):
            for e in ch.get('inner', []):
                if e.get('kind') == 'ConstantExpr' and 'value' in e:
                    width = int(e['value'])
            if width is None:
                width = -1
        # x[] and the old x[0] are the same ABI: no member size for either
        flex = bool(re.search(r'\[0?\]$', qt.rstrip()))
        out.append((path, qt, width, flex))
        if ANON_RE.search(qt) and pending is not None:
            dims = re.findall(r'\[\d*\]', qt)
            out += record_fields(pending, path + '[0]' * len(dims) + '.')
        pending = None
    return out


def collect_ast(ast, unit_files):
    records, enums, typedefs = [], [], []
    anon_by_id = {}

    def in_unit(n):
        f = n.get('_file')
        return f is not None and os.path.realpath(f) in unit_files

    def walk(nodes):
        for n in nodes:
            k = n.get('kind')
            if k == 'RecordDecl':
                if n.get('completeDefinition') and in_unit(n):
                    if n.get('name'):
                        records.append((f"{n['tagUsed']} {n['name']}", f"{n['tagUsed']} {n['name']}", n))
                    else:
                        anon_by_id[n['id']] = n
                walk(n.get('inner', []))
            elif k == 'EnumDecl':
                if in_unit(n):
                    for e in n.get('inner', []):
                        if e.get('kind') == 'EnumConstantDecl':
                            enums.append(e['name'])
            elif k == 'TypedefDecl' and not n.get('isImplicit') and in_unit(n):
                owned = None
                for t in n.get('inner', []):
                    o = t.get('ownedTagDecl')
                    if o and o.get('kind') == 'RecordDecl':
                        owned = o['id']
                typedefs.append((n['name'], owned))
    walk(ast.get('inner', []))
    for name, owned in typedefs:
        if owned and owned in anon_by_id:
            records.append((f'typedef {name}', name, anon_by_id[owned]))
        else:
            records.append((f'typedef {name}', name, None))
    return records, enums


# ---------------------------------------------------------------- macros

def parse_dm(text):
    """clang -dM output -> {name: (params or None, body)}"""
    macros = {}
    for line in text.splitlines():
        m = re.match(r'#define (\w+)(\([^)]*\))? ?(.*)$', line)
        if m:
            macros[m.group(1)] = (m.group(2), m.group(3))
    return macros


def ioc_macros(macros):
    """Names of the macros that expand to an _IOC() (directly or through other macros)."""
    ioc = set(IOC_BASE)
    tok = {n: set(re.findall(r'[A-Za-z_]\w*', b)) for n, (_, b) in macros.items()}
    changed = True
    while changed:
        changed = False
        for n, t in tok.items():
            if n not in ioc and t & ioc:
                ioc.add(n)
                changed = True
    return ioc


def split_args(s):
    """'a, (b, c), d)' -> ['a', '(b, c)', 'd'] up to the closing paren."""
    args, depth, cur = [], 0, ''
    for ch in s:
        if ch == '(':
            depth += 1
        elif ch == ')':
            if depth == 0:
                args.append(cur.strip())
                return args
            depth -= 1
        elif ch == ',' and depth == 0:
            args.append(cur.strip())
            cur = ''
            continue
        cur += ch
    return None


CALL_RE = re.compile(r'\b([A-Za-z_]\w*)\s*\(')


def ioc_type(body, macros, ioc, depth=0):
    """Payload type of an ioctl macro, as written: the type argument of the
    _IOR/_IOW/_IOWR at the bottom of the macro chain ('-' for _IO)."""
    if depth > 8:
        return None
    pos = 0
    while True:
        m = CALL_RE.search(body, pos)
        if not m:
            break
        name = m.group(1)
        pos = m.end()
        if name not in ioc or name == '_IOC':
            continue
        args = split_args(body[m.end():])
        if args is None:
            return None
        if name in ('_IOR', '_IOW', '_IOWR', '_IOR_BAD', '_IOW_BAD', '_IOWR_BAD') and len(args) == 3:
            return re.sub(r'\s+', ' ', args[2]).replace(' *', '*')
        if name == '_IO':
            return '-'
        params, mbody = macros.get(name, (None, ''))
        if params is None:
            return None
        sub = mbody
        for pn, av in zip([x.strip() for x in params.strip('()').split(',')], args):
            if pn:
                sub = re.sub(r'\b%s\b' % re.escape(pn), lambda _m, av=av: av, sub)
        return ioc_type(sub, macros, ioc, depth + 1)
    t = body.strip()
    while t.startswith('(') and t.endswith(')'):
        t = t[1:-1].strip()
    if t in macros and macros[t][0] is None:
        return ioc_type(macros[t][1], macros, ioc, depth + 1)
    return None


# ---------------------------------------------------------------- ELF

def elf_section(path, want):
    data = open(path, 'rb').read()
    if data[:4] != b'\x7fELF':
        raise ValueError('not ELF')
    is64 = data[4] == 2
    if is64:
        shoff, = struct.unpack_from('<Q', data, 0x28)
        shentsize, shnum, shstrndx = struct.unpack_from('<HHH', data, 0x3A)
        fmt = '<IIQQQQIIQQ'
    else:
        shoff, = struct.unpack_from('<I', data, 0x20)
        shentsize, shnum, shstrndx = struct.unpack_from('<HHH', data, 0x2E)
        fmt = '<IIIIIIIIII'
    secs = [struct.unpack_from(fmt, data, shoff + i * shentsize) for i in range(shnum)]
    stroff = secs[shstrndx][4]
    for s in secs:
        name = data[stroff + s[0]:data.index(b'\0', stroff + s[0])].decode()
        if name == want:
            return data[s[4]:s[4] + s[5]]
    raise ValueError(f'no section {want}')


# ---------------------------------------------------------------- one unit

class Env:
    def __init__(self, tmp, side, config=None, allow_missing=False):
        self.tmp = tmp
        self.side = side
        self.allow_missing = allow_missing
        self.config = config
        self.autoconf = None
        if config:
            self.autoconf = os.path.join(tmp, 'autoconf.h')
            autoconf_from(config, self.autoconf)
        r = subprocess.run([CC, '-print-resource-dir'], stdout=subprocess.PIPE, check=True)
        self.resource = os.path.join(r.stdout.decode().strip(), 'include')

    def asm_dir(self, root, arch):
        """The asm/ headers 'make headers' generates: asm-generic wrappers for
        what arch/<a>/include/uapi/asm does not have."""
        a = ARCHES[arch][1]
        d = os.path.join(self.tmp, f'asm-{arch}-{abs(hash(root))}')
        if os.path.isdir(d):
            return d
        os.makedirs(os.path.join(d, 'asm'))
        have = set(os.listdir(os.path.join(root, 'arch', a, 'include/uapi/asm'))) \
            if os.path.isdir(os.path.join(root, 'arch', a, 'include/uapi/asm')) else set()
        gen = os.path.join(root, 'include/uapi/asm-generic')
        for f in os.listdir(gen) if os.path.isdir(gen) else []:
            if f.endswith('.h') and f not in have:
                with open(os.path.join(d, 'asm', f), 'w') as o:
                    o.write(f'#include <asm-generic/{f}>\n')
        # make headers: arm's unistd and arm64's sve_context are generated too,
        # nothing here needs them. linux/version.h, from the tree's Makefile
        # (taoyao-stock has none: its kernel is 5.4.289)
        ver = {'54': (5, 4, 289), '612': (6, 12, 0)}[self.side]
        mk = os.path.join(root, 'Makefile')
        if os.path.isfile(mk):
            t = open(mk, errors='replace').read(2000)
            v = [re.search(r'^%s\s*=\s*(\d+)' % k, t, re.M) for k in ('VERSION', 'PATCHLEVEL', 'SUBLEVEL')]
            if all(v):
                ver = tuple(int(x.group(1)) for x in v)
        os.makedirs(os.path.join(d, 'linux'))
        with open(os.path.join(d, 'linux/version.h'), 'w') as o:
            o.write('#define LINUX_VERSION_CODE %d\n' % ((ver[0] << 16) + (ver[1] << 8) + min(ver[2], 255)))
            o.write('#define KERNEL_VERSION(a, b, c) (((a) << 16) + ((b) << 8) + ((c) > 255 ? 255 : (c)))\n')
            o.write('#define LINUX_VERSION_MAJOR %d\n#define LINUX_VERSION_PATCHLEVEL %d\n'
                    '#define LINUX_VERSION_SUBLEVEL %d\n' % ver)
        return d


def run(cmd, **kw):
    return subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, **kw)


def probe_unit(env, unit, arch, roots):
    side = env.side
    spec = unit[side]
    if not spec['hdr'] and not spec['extract']:
        return [], [f'{ERR}{unit["name"]}: no {side} headers in units.conf']
    root = roots[spec['root']]
    target = ARCHES[arch][0]
    work = tempfile.mkdtemp(prefix=f'{unit["name"]}-{arch}-', dir=env.tmp)
    incs = [os.path.join(root, i) for i in spec['inc']]
    incs += [os.path.join(root, 'include/uapi'), os.path.join(root, 'arch', ARCHES[arch][1], 'include/uapi'),
             env.asm_dir(root, arch)]
    notes = []
    unit_files = set()
    hdrs_found = []
    for h in spec['hdr']:
        for d in incs:
            p = os.path.join(d, h)
            if os.path.isfile(p):
                unit_files.add(os.path.realpath(p))
                hdrs_found.append(h)
                break
        else:
            if not env.allow_missing:
                return [], [f'{ERR}{unit["name"]}: {h} not found in the {side} tree']
            notes.append(f'{unit["name"]}: {h} not in this tree')
    cflags = ['--target=' + target, '-std=gnu11', '-nostdinc', '-isystem', env.resource,
              '-I', os.path.join(HERE, 'shim/libc')]
    for i in incs:
        cflags += ['-I', i]
    # what make headers_install does to a UAPI header: no __KERNEL__ part,
    # no compiler_types.h (shim), no __user/__force/__iomem annotations,
    # __packed spelled out
    cflags += ['-U__KERNEL__', '-D__EXPORTED_HEADERS__', '-D__user=', '-D__force=', '-D__iomem=',
               '-D__attribute_const__=', '-D__packed=__attribute__((packed))']
    cflags += ['-w', '-ferror-limit=0', '-fno-color-diagnostics', '-fno-caret-diagnostics']
    cflags += ['-D' + d for d in spec['define']]
    if env.autoconf and side == '612':
        cflags += ['-include', env.autoconf]

    # headers: prelude, the unit's headers, then the extracted kernel headers
    pre = ['#include <stddef.h>', '#include <stdint.h>', '#include <sys/types.h>', '#include <linux/types.h>',
           '#include <linux/ioctl.h>']
    if spec['extract']:
        pre.append('#include <linux/version.h>')
        pre.append(f'#include "{os.path.join(HERE, "shim/kernel.h")}"')
    if not hdrs_found and not [x for x in spec['extract'] if os.path.isfile(os.path.join(root, x))]:
        return [], notes
    hdr_lines = pre + [f'#include <{h}>' for h in hdrs_found]
    ext_files = []
    for x in spec['extract']:
        src = os.path.join(root, x)
        if not os.path.isfile(src):
            if not env.allow_missing:
                return [], [f'{ERR}{unit["name"]}: {x} not found in the {side} tree']
            notes.append(f'{unit["name"]}: {x} not in this tree')
            continue
        dst = os.path.join(work, 'x_' + os.path.basename(x))
        chunks = extract_header(src, dst)
        ext_files.append((dst, chunks, x))
        unit_files.add(os.path.realpath(dst))
        hdr_lines.append(f'#include "{dst}"')
    hdrs = os.path.join(work, 'hdrs.h')
    with open(hdrs, 'w') as f:
        f.write('\n'.join(hdr_lines) + '\n')

    # extracted headers: drop the chunks clang rejects (kernel-only types)
    for _ in range(12):
        r = run([CC, *cflags, '-fsyntax-only', '-x', 'c', hdrs])
        if r.returncode == 0:
            break
        err = r.stderr.decode(errors='replace')
        dropped = False
        for dst, chunks, x in ext_files:
            bad = {int(m.group(1)) for m in re.finditer(re.escape(dst) + r':(\d+):\d+: error', err)}
            if not bad:
                continue
            lines = open(dst).read().split('\n')
            for (a, b, label) in list(chunks):
                if any(a <= ln <= b for ln in bad):
                    for ln in range(a - 1, b):
                        lines[ln] = ''
                    notes.append(f'{unit["name"]}: {x}: {label} not probed (kernel-only types)')
                    chunks.remove((a, b, label))
                    dropped = True
            with open(dst, 'w') as f:
                f.write('\n'.join(lines))
        if not dropped:
            return [], [f'{ERR}{unit["name"]} ({side}, {arch}): headers do not compile:\n' + err[:4000]]
    else:
        return [], [f'{ERR}{unit["name"]} ({side}, {arch}): extracted headers still fail']

    # macros
    r = run([CC, *cflags, '-E', '-dM', '-x', 'c', hdrs])
    if r.returncode:
        return [], [f'{ERR}{unit["name"]}: -dM failed: ' + r.stderr.decode()[:2000]]
    macros = parse_dm(r.stdout.decode(errors='replace'))
    ioc = ioc_macros(macros)
    names = []
    for uf in sorted(unit_files):
        for m in DEFINE_RE.finditer(open(uf, errors='replace').read()):
            if not m.group(2) and m.group(1) not in names:
                names.append(m.group(1))

    # types
    r = run([CC, *cflags, '-fsyntax-only', '-Xclang', '-ast-dump=json', '-x', 'c', hdrs])
    if r.returncode:
        return [], [f'{ERR}{unit["name"]}: AST dump failed: ' + r.stderr.decode()[:2000]]
    ast = json.loads(r.stdout)
    annotate_files(ast, {'file': None})
    records, enums = collect_ast(ast, unit_files)
    del ast

    items = []    # (kind, key, expr or None, fixed value)
    for n in names:
        if n not in macros or macros[n][0] is not None or not macros[n][1].strip():
            continue
        if n in ioc:
            items.append(('IOC', n, n, None))
            t = ioc_type(macros[n][1], macros, ioc)
            if t:
                items.append(('IOCT', n, None, t))
        else:
            items.append(('DEF', n, n, None))
    seen_enum = set()
    for e in enums:
        if e not in seen_enum:
            seen_enum.add(e)
            items.append(('ENUM', e, e, None))
    seen_rec = set()
    for key, texpr, node in records:
        if key in seen_rec:
            continue
        seen_rec.add(key)
        items.append(('SIZE', key, f'sizeof({texpr})', None))
        items.append(('ALIGN', key, f'_Alignof({texpr})', None))
        if node is None:
            continue
        for path, qt, width, flex in record_fields(node, ''):
            fk = f'{key}.{path}'
            items.append(('FTYPE', fk, None, re.sub(r' at [^)]*\)', ')', qt)))
            if width is not None:
                items.append(('BITW', fk, None, str(width)))
                continue
            items.append(('OFF', fk, f'__builtin_offsetof({texpr}, {path})', None))
            if not flex:
                items.append(('FSIZE', fk, f'sizeof((({texpr} *)0)->{path})', None))

    probes = [i for i in items if i[2] is not None]
    values = compile_probe(cflags, hdrs, probes, work, notes, unit['name'])
    out = []
    for kind, key, expr, fixed in items:
        if expr is None:
            out.append((kind, key, fixed, unit['name']))
        elif (kind, key) in values:
            out.append((kind, key, values[(kind, key)], unit['name']))
    shutil.rmtree(work, ignore_errors=True)
    return out, notes


def compile_probe(cflags, hdrs, probes, work, notes, uname):
    """Evaluate the probe expressions for the target: each one is a separate
    constant in section .uapiprobe (separate declarations, so that clang
    reports every expression it rejects in one pass); the values are read
    back from the ELF object, nothing is linked or run."""
    INTTYPES = ('char: 1, signed char: 1, unsigned char: 1, short: 1, unsigned short: 1, int: 1, '
                'unsigned int: 1, long: 1, unsigned long: 1, long long: 1, unsigned long long: 1, '
                '_Bool: 1, default: 0')
    live = list(range(len(probes)))
    if not live:
        return {}
    src = os.path.join(work, 'probe.c')
    obj = os.path.join(work, 'probe.o')
    for attempt in range(4):
        head = [f'#include "{hdrs}"',
                'struct uapicheck_ent { unsigned long long v; unsigned int idx; int neg; int isint; };',
                '#define E(n) __attribute__((used, section(".uapiprobe"), aligned(8))) '
                'static const struct uapicheck_ent uapicheck_##n']
        first = len(head) + 1
        body = []
        for i in live:
            e = probes[i][2]
            body.append(f'E({i}) = {{ (unsigned long long)({e}), {i}, ({e}) < 0, _Generic(({e}), {INTTYPES}) }};')
        with open(src, 'w') as f:
            f.write('\n'.join(head + body + ['']))
        r = run([CC, *cflags, '-c', '-O0', src, '-o', obj])
        if r.returncode == 0:
            break
        err = r.stderr.decode(errors='replace')
        bad = {int(m.group(1)) - first for m in re.finditer(re.escape(src) + r':(\d+):\d+: error', err)}
        bad = {b for b in bad if 0 <= b < len(live)}
        if not bad:
            notes.append(f'{ERR}{uname}: probe failed:\n{err[:3000]}')
            return {}
        live = [x for j, x in enumerate(live) if j not in bad]
    else:
        notes.append(f'{ERR}{uname}: probe kept failing')
        return {}
    data = elf_section(obj, '.uapiprobe')
    if len(data) != 24 * len(live):
        notes.append(f'{ERR}{uname}: probe section has {len(data)} bytes for {len(live)} entries')
        return {}
    values = {}
    for j in range(len(live)):
        v, i, neg, isint = struct.unpack_from('<QIii', data, j * 24)
        if not isint:
            continue
        kind, key = probes[i][0], probes[i][1]
        if neg:
            v -= 1 << 64
        values[(kind, key)] = hex(v) if kind == 'IOC' else str(v)
    return values


def dump_tree(trees, side, arches, config=None, units=None, jobs=None, allow_missing=False):
    """{arch: {(kind, key): (value, unit)}}, notes"""
    units = units or load_units()
    tmp = tempfile.mkdtemp(prefix='uapicheck-')
    try:
        env = Env(tmp, side, config, allow_missing)
        ts = {name: Tree(spec, tmp) for name, spec in trees.items()}
        need = {}
        for u in units:
            s = u[side]
            if s['root'] not in ts:
                continue
            p = need.setdefault(s['root'], set(['include/uapi', 'arch/arm64/include/uapi', 'arch/arm/include/uapi']))
            p.update(s['inc'])
            p.update(s['extract'])
        roots = {n: ts[n].materialize(sorted(need.get(n, ()))) for n in ts}
        for r in roots.values():
            for a in arches:
                env.asm_dir(r, a)
        jobs_list = [(u, a) for u in units for a in arches if u[side]['root'] in roots]
        res = {a: {} for a in arches}
        notes = []
        with ThreadPoolExecutor(max_workers=jobs or os.cpu_count() or 4) as ex:
            futs = [(u, a, ex.submit(probe_unit, env, u, a, roots)) for u, a in jobs_list]
            for u, a, f in futs:
                out, n = f.result()
                for x in n:
                    if x not in notes:
                        notes.append(x)
                for kind, key, val, un in out:
                    k = (kind, key)
                    if k in res[a] and res[a][k][0] != val:
                        notes.append(f'{key}: {kind} defined twice ({res[a][k][1]}, {un})')
                        continue
                    res[a].setdefault(k, (val, un))
        missing_root = sorted({u[side]['root'] for u in units} - set(roots))
        if missing_root:
            notes.append(f'{ERR}trees not given: ' + ', '.join(missing_root))
        return res, notes, {n: t.describe() for n, t in ts.items()}
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def write_dump(path, d, header):
    with open(path, 'w') as f:
        for h in header:
            f.write(f'# {h}\n')
        for (kind, key), (val, unit) in sorted(d.items()):
            f.write(f'{kind}\t{key}\t{val}\t{unit}\n')


def write_ref(path, res, header):
    """ref/5.4.txt: KIND KEY VALUE(aarch64) VALUE(armv7, '=' if the same) UNIT"""
    a64, a32 = res.get('aarch64', {}), res.get('armv7', {})
    with open(path, 'w') as f:
        for h in header:
            f.write(f'# {h}\n')
        f.write('# KIND\tKEY\taarch64\tarmv7 (= same)\tUNIT\n')
        for k in sorted(set(a64) | set(a32)):
            v64, u64 = a64.get(k, ('-', None))
            v32, u32 = a32.get(k, ('-', None))
            f.write(f'{k[0]}\t{k[1]}\t{v64}\t{"=" if v32 == v64 else v32}\t{u64 or u32}\n')


def read_ref(path):
    res, header = {'aarch64': {}, 'armv7': {}}, []
    with open(path) as f:
        for line in f:
            if line.startswith('#'):
                header.append(line[1:].strip())
                continue
            p = line.rstrip('\n').split('\t')
            if len(p) != 5:
                continue
            kind, key, v64, v32, unit = p
            v32 = v64 if v32 == '=' else v32
            if v64 != '-':
                res['aarch64'][(kind, key)] = (v64, unit)
            if v32 != '-':
                res['armv7'][(kind, key)] = (v32, unit)
    return res, header


def read_dump(path):
    d, header = {}, []
    with open(path) as f:
        for line in f:
            if line.startswith('#'):
                header.append(line[1:].strip())
                continue
            p = line.rstrip('\n').split('\t')
            if len(p) == 4:
                d[(p[0], p[1])] = (p[2], p[3])
    return d, header


# ---------------------------------------------------------------- diff

def load_allow(path):
    """allowlist.txt: KIND[@arch] KEY-GLOB[|GLOB...] STATUS REASON...
    STATUS ok = intended or harmless, known = a real difference, fix pending
    (the check passes but reports it as a warning), =NAME = renamed: the 5.4
    value of KEY must be the 6.12 value of NAME (checked; a mismatch fails;
    KEY is then a plain name, a member key may use =.member for a member of
    the same struct)."""
    rules = []
    if not path or not os.path.exists(path):
        return rules
    for n, line in enumerate(open(path), 1):
        line = line.strip()
        if not line or line.startswith('#'):
            continue
        # columns are separated by two or more spaces or a tab (keys such as
        # "struct x.member" contain one space)
        p = re.split(r'\t+|  +', line, maxsplit=3)
        if len(p) < 4 or not (p[2] in ('ok', 'known') or p[2].startswith('=')):
            sys.exit(f'{path}:{n}: need KIND[@arch] KEY STATUS(ok|known|=NAME) REASON')
        kind, arch = (p[0].split('@', 1) + [None])[:2]
        rules.append({'kind': kind, 'arch': arch, 'keys': p[1].split('|'), 'status': p[2],
                      'reason': p[3], 'line': n, 'hits': 0})
    return rules


def match_allow(rules, kind, key, arch):
    for r in rules:
        if r['kind'] not in ('*', kind):
            continue
        if r['arch'] and r['arch'] != arch:
            continue
        if any(fnmatch.fnmatchcase(key, g) for g in r['keys']):
            r['hits'] += 1
            return r
    return None


def ioc_decode(v):
    v = int(v, 16) if isinstance(v, str) else v
    d = {0: '-', 1: 'W', 2: 'R', 3: 'RW'}[(v >> 30) & 3]
    t = (v >> 8) & 0xff
    tc = chr(t) if 32 < t < 127 else hex(t)
    return f'{v:#x} ({d} {tc!r} nr {v & 0xff} size {(v >> 16) & 0x3fff})'


def fmt_val(kind, v):
    if v is None:
        return 'absent'
    return ioc_decode(int(v, 0)) if kind == 'IOC' else str(v)


CONST_KINDS = ('IOC', 'DEF', 'ENUM')


def comparable(d):
    """{(kind or CONST, key): (value, kind, unit)}: ioctl numbers, #defines and
    enumerators are one namespace, compared by value (6.12 turned the binder
    and ashmem ioctl #defines into enumerators for bindgen)."""
    out = {}
    for (kind, key), (val, unit) in d.items():
        if kind in CONST_KINDS:
            out[('CONST', key)] = (int(val, 0), kind, unit)
        elif kind in COMPARED:
            out[(kind, key)] = (val, kind, unit)
    return out


def compare(old, new, arches, rules):
    """-> list of findings {kind, key, unit, arch: {a: (old, new)}, status, rule}"""
    found = {}
    for a in arches:
        o, n = comparable(old.get(a, {})), comparable(new.get(a, {}))
        for k in set(o) | set(n):
            ov, okind, ounit = o.get(k, (None, None, None))
            nv, nkind, nunit = n.get(k, (None, None, None))
            if ov == nv:
                continue
            kind = 'IOC' if 'IOC' in (okind, nkind) else (okind or nkind)
            f = found.setdefault(k, {'kind': kind, 'key': k[1], 'unit': ounit or nunit, 'arch': {}})
            if kind == 'IOC':
                f['kind'] = 'IOC'
            f['arch'][a] = (None if ov is None else (hex(ov) if kind == 'IOC' else str(ov)),
                            None if nv is None else (hex(nv) if kind == 'IOC' else str(nv)))
    out = []
    for k, f in sorted(found.items()):
        f['rule'] = None
        if all(ov is None for ov, nv in f['arch'].values()):
            f['status'] = 'added'
        else:
            st = 'ok'
            for a in f['arch']:
                r = match_allow(rules, f['kind'], f['key'], a)
                if r is None:
                    st = 'FAIL'
                    f['rule'] = None
                    break
                f['rule'] = r
                if r['status'].startswith('='):
                    if not alias_holds(old.get(a, {}), new.get(a, {}), k, f['key'], r['status'][1:]):
                        st = 'FAIL'
                        f['alias_bad'] = r['status'][1:]
                        break
                elif r['status'] == 'known':
                    st = 'known'
            f['status'] = st
        out.append(f)
    return out


def alias_holds(old, new, k, key, other):
    """5.4 value of key == 6.12 value of other (a renamed constant or member)"""
    o, n = comparable(old), comparable(new)
    if other.startswith('.') and '.' in key:
        other = key.split('.', 1)[0] + other
    ov = o.get(k, (None,))[0]
    nk = (k[0], other)
    nv = n.get(nk, (None,))[0]
    return ov is not None and ov == nv


def users_index(dump):
    """type -> [(ioctl or member that carries it)] from IOCT / FTYPE lines"""
    users = {}
    for (kind, key), (val, unit) in dump.items():
        if kind == 'IOCT':
            t = val.rstrip('*').strip()
            users.setdefault(t, []).append(('ioctl', key, val.endswith('*')))
        elif kind == 'FTYPE':
            t = re.sub(r'\[.*$', '', val).replace('const ', '').replace('volatile ', '')
            t = t.rstrip('* ').strip()
            owner = key.split('.', 1)[0]
            owner = owner[len('typedef '):] if owner.startswith('typedef ') else owner
            users.setdefault(t, []).append(('member', key, owner))
    return users


def carriers(users, typ, depth=0, seen=None):
    """ioctls that carry <typ>, directly or nested in another struct"""
    seen = seen or set()
    if typ in seen or depth > 6:
        return []
    seen.add(typ)
    out = []
    for u in users.get(typ, []):
        if u[0] == 'ioctl':
            out.append((u[1], u[2], typ))
        else:
            out += carriers(users, u[2], depth + 1, seen)
    return out


def type_of_key(kind, key):
    if kind in ('SIZE', 'ALIGN'):
        t = key
    elif kind in ('OFF', 'FSIZE', 'BITW'):
        t = key.split('.', 1)[0]
    else:
        return None
    return t[len('typedef '):] if t.startswith('typedef ') else t


def report(findings, old, new, arches, show_added=False, gh=False, title='', labels=('5.4', '6.12')):
    lo, ln = labels
    users = users_index(next(iter(old.values()), {}))
    lines = []
    order = {'FAIL': 0, 'known': 1, 'ok': 2, 'added': 3}
    groups = {}
    for f in findings:
        groups.setdefault(f['status'], []).append(f)
    counts = {s: len(v) for s, v in groups.items()}
    lines.append(f'{title}: ' + ', '.join(f'{counts.get(s, 0)} {s}' for s in ('FAIL', 'known', 'ok', 'added')))
    for st in sorted(groups, key=lambda s: order.get(s, 9)):
        if st == 'added' and not show_added:
            continue
        lines.append('')
        lines.append({'FAIL': '== differences not in the allowlist (FAIL)',
                      'known': '== known differences, fix pending (allowlist: known)',
                      'ok': '== accepted differences (allowlist: ok)',
                      'added': f'== only in the {ln} headers (not checked)'}[st])
        for f in sorted(groups[st], key=lambda f: (f['unit'], type_of_key(f['kind'], f['key']) or f['key'], f['kind'], f['key'])):
            per = f['arch']
            vals = set(per.values())
            if len(vals) == 1 and len(per) == len(arches):
                (ov, nv), = vals
                where = 'both'
                desc = f'{lo} {fmt_val(f["kind"], ov)}  {ln} {fmt_val(f["kind"], nv)}'
            else:
                where = ','.join(sorted(per))
                desc = '; '.join(f'{a}: {lo} {fmt_val(f["kind"], per[a][0])} {ln} {fmt_val(f["kind"], per[a][1])}'
                                 for a in sorted(per))
            s = f'{f["kind"]:5} {f["key"]}  [{f["unit"]}, {where}]  {desc}'
            t = type_of_key(f['kind'], f['key'])
            if t and st != 'added':
                c = carriers(users, t)
                if c:
                    s += '\n      carried by: ' + ', '.join(
                        sorted({f'{n}{" (pointer-typed: same number)" if p else ""}' for n, p, _ in c}))
            if f.get('alias_bad'):
                s += f'\n      allowlist says renamed to {f["alias_bad"]}, but its 6.12 value differs'
            if f.get('rule'):
                s += f'\n      allowlist:{f["rule"]["line"]}: {f["rule"]["reason"]}'
            lines.append('  ' + s)
            if gh and st == 'FAIL':
                print(f'::error title=UAPI ABI::{f["kind"]} {f["key"]} [{f["unit"]}, {where}]: {desc}'
                      + (' (allowlist says renamed, value differs)' if f.get('alias_bad') else ''))
    if gh and counts.get('known'):
        print(f'::warning title=UAPI ABI::{counts["known"]} known differences from the 5.4 UAPI still need a fix '
              f'(allowlist status known), listed in the log')
    return '\n'.join(lines), counts


# ---------------------------------------------------------------- commands

def parse_trees(specs):
    trees = {}
    for s in specs or []:
        if '=' in s and not s.startswith('/') and s.split('=', 1)[0].isidentifier():
            n, p = s.split('=', 1)
        else:
            n, p = 'main', s
        trees[n] = p
    return trees


def fatal(notes, github):
    """print the notes; True if one of them makes the dump unusable"""
    bad = False
    for n in notes:
        if n.startswith(ERR):
            bad = True
            print(('::error::uapicheck: ' if github else 'uapicheck: ') + n[len(ERR):].splitlines()[0])
            log(n)
        else:
            log('note: ' + n)
    return bad


def cmd_ref(a):
    trees = parse_trees(a.tree)
    if 'st' in trees:
        trees['main'] = trees.pop('st')
    units = load_units()
    arches = sorted(ARCHES)         # the ref always holds both
    which = a.which.split(',') if a.which else list(REFS)
    for ref in which:
        if ref not in REFS:
            sys.exit(f'uapicheck: --which {ref}: not one of {", ".join(REFS)}')
    title = {'st': 'uapicheck reference: the 5.4 headers the taoyao vendor userspace was built with',
             'los': 'uapicheck reference: the LineageOS 5.4 headers Evolution X and crDroid build '
                    'ipacm with (taoyao54), for the units with ref = los'}
    rc = 0
    for ref in which:
        us = ref_units(units, ref)
        res, notes, desc = dump_tree(trees, '54', arches, None, us, a.jobs)
        if fatal(notes, False):
            log(f'uapicheck: ref/{REFS[ref]} not written')
            rc = 1
            continue
        os.makedirs(os.path.join(HERE, 'ref'), exist_ok=True)
        used = {u['54']['root'] for u in us}
        hdr = [title[ref],
               'trees: ' + '; '.join(f'{k}={v}' for k, v in sorted(desc.items()) if k in used),
               'units: ' + ref_units_line(units, ref),
               f'probe: {probe_hash()}']
        hdr += ['note: ' + n.splitlines()[0] for n in notes]
        p = os.path.join(HERE, 'ref', REFS[ref])
        write_ref(p, res, hdr)
        log(f'{p}: ' + ', '.join(f'{len(res[x])} {x} values' for x in arches))
    return rc


def cmd_dump(a):
    trees = parse_trees(a.tree)
    res, notes, desc = dump_tree(trees, a.side, a.arch, a.config, None, a.jobs)
    bad = fatal(notes, False)
    for arch in a.arch:
        out = a.output.replace('%a', arch) if a.output else None
        if out:
            write_dump(out, res[arch], ['trees: ' + '; '.join(f'{k}={v}' for k, v in desc.items())])
            log(f'{out}: {len(res[arch])} lines')
        else:
            for (kind, key), (val, unit) in sorted(res[arch].items()):
                print(f'{arch}\t{kind}\t{key}\t{val}\t{unit}')
    return 1 if bad else 0


def finish(findings, old, new, arches, a, title, rules, labels=('5.4', '6.12')):
    text, counts = report(findings, old, new, arches, a.show_added, gh=a.github, title=title, labels=labels)
    print(text)
    for r in rules:
        if r['hits'] == 0:
            msg = f'allowlist.txt:{r["line"]}: {r["kind"]} {"|".join(r["keys"])} matches no difference any more; remove it'
            print(f'::notice::{msg}' if a.github else 'note: ' + msg)
    if a.report:
        with open(a.report, 'w') as f:
            f.write(text + '\n')
    return 1 if counts.get('FAIL') else 0


def load_refs(units, arches, github):
    """{arch: {(kind, key): (value, unit)}} with every unit's values taken
    from the reference units.conf (or --unit-ref) names for it; None if a
    reference file is missing or stale"""
    conf = load_units()
    refs = {arch: {} for arch in arches}
    for ref in sorted({u['ref'] for u in units}):
        name = REFS[ref]
        path = os.path.join(HERE, 'ref', name)
        if not os.path.exists(path):
            print(('::error::' if github else '') + f'uapicheck: ref/{name} is missing: run uapicheck.py ref')
            return None
        allrefs, hdr = read_ref(path)
        # ref/ must have been made from this units.conf (5.4 side) and probe
        head = {h.split(': ', 1)[0]: h.split(': ', 1)[1] for h in hdr if ': ' in h}
        want = {'units': ref_units_line(conf, ref), 'probe': probe_hash()}
        for k, what in (('units', 'units.conf (5.4 side or ref =)'), ('probe', 'the probe (shim/ or PROBE_VERSION)')):
            if head.get(k) != want[k]:
                msg = f'uapicheck: {what} changed since ref/{name} was made: run uapicheck.py ref'
                print(('::error::' if github else '') + msg)
                return None
        held = {u['name'] for u in ref_units(conf, ref)}
        names = {u['name'] for u in units if u['ref'] == ref}
        if names - held:
            print(('::error::' if github else '') +
                  f'uapicheck: ref/{name} holds no {", ".join(sorted(names - held))} (units.conf ref =)')
            return None
        for arch in arches:
            for k, (v, unit) in allrefs[arch].items():
                if unit in names:
                    refs[arch][k] = (v, unit)
    return refs


def cmd_check(a):
    units = load_units()
    for spec in a.unit_ref or []:
        name, _, ref = spec.partition('=')
        hit = [u for u in units if u['name'] == name]
        if not hit or ref not in REFS:
            sys.exit(f'uapicheck: --unit-ref {spec}: need UNIT=REF, UNIT from units.conf, REF one of {", ".join(REFS)}')
        hit[0]['ref'] = ref
    refs = load_refs(units, a.arch, a.github)
    if refs is None:
        return 1
    new, notes, desc = dump_tree(parse_trees(a.tree), '612', a.arch, a.config, units, a.jobs)
    bad = fatal(notes, a.github)
    rules = load_allow(a.allow)
    findings = compare(refs, new, a.arch, rules)
    los = [u['name'] for u in units if u['ref'] == 'los']
    which = '5.4 ref' + (f' (LineageOS 5.4 for {" ".join(los)}, stock for the rest)' if los else '')
    title = f'UAPI ABI: 6.12 {desc.get("main", "")} vs {which} ({", ".join(a.arch)})'
    rc = finish(findings, refs, new, a.arch, a, title, rules)
    return 1 if bad else rc


def cmd_same(a):
    units = load_units()
    trees = parse_trees(a.tree)
    base = {k: (v.split('@')[0] + '@' + a.base_rev) for k, v in trees.items()}
    # a header the port adds is not in the base tree: what it defines is
    # new to redwood's ROM, which never uses it; only changed and removed
    # values can break that ROM
    old, n1, d1 = dump_tree(base, '612', a.arch, a.config, units, a.jobs, allow_missing=True)
    new, n2, d2 = dump_tree(trees, '612', a.arch, a.config, units, a.jobs, allow_missing=True)
    bad = fatal(n1 + n2, a.github)
    rules = load_allow(a.allow)
    findings = compare(old, new, a.arch, rules)
    title = (f'UAPI ABI: 6.12 {d2.get("main", "")} vs {d1.get("main", a.base_rev)} '
             f'({", ".join(a.arch)}, {os.path.basename(a.config or "no config")})')
    rc = finish(findings, old, new, a.arch, a, title, rules, labels=(a.base_rev, 'patched'))
    return 1 if bad else rc


def cmd_diff(a):
    old, new = {}, {}
    o, _ = read_dump(a.old)
    n, _ = read_dump(a.new)
    old['x'], new['x'] = o, n
    rules = load_allow(a.allow)
    findings = compare(old, new, ['x'], rules)
    return finish(findings, old, new, ['x'], a, f'{a.old} vs {a.new}', rules)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    sub = ap.add_subparsers(dest='cmd', required=True)

    def common(p, allow=True):
        p.add_argument('--arch', action='append', choices=sorted(ARCHES))
        p.add_argument('-j', '--jobs', type=int)
        if allow:
            p.add_argument('--allow', default=os.path.join(HERE, 'allowlist.txt'))
            p.add_argument('--report')
            p.add_argument('--show-added', action='store_true')
            p.add_argument('--github', action='store_true', help='GitHub Actions annotations')

    p = sub.add_parser('ref')
    p.add_argument('--tree', action='append', required=True)
    p.add_argument('--which', help='comma-separated references to write (default: all: %s)' % ','.join(REFS))
    common(p, allow=False)
    p = sub.add_parser('dump')
    p.add_argument('--tree', action='append', required=True)
    p.add_argument('--side', default='612', choices=('54', '612'))
    p.add_argument('--config')
    p.add_argument('-o', '--output', help='file (%%a = arch)')
    common(p, allow=False)
    p = sub.add_parser('check')
    p.add_argument('--tree', action='append', required=True)
    p.add_argument('--config')
    p.add_argument('--unit-ref', action='append', metavar='UNIT=REF',
                   help='compare UNIT against another reference than units.conf says (st or los)')
    common(p)
    p = sub.add_parser('same')
    p.add_argument('--tree', action='append', required=True)
    p.add_argument('--base-rev', default='HEAD')
    p.add_argument('--config')
    common(p)
    p.set_defaults(allow=os.path.join(HERE, 'allowlist-same.txt'))
    p = sub.add_parser('diff')
    p.add_argument('old')
    p.add_argument('new')
    common(p)
    a = ap.parse_args()
    a.arch = a.arch or sorted(ARCHES)
    return {'ref': cmd_ref, 'dump': cmd_dump, 'check': cmd_check, 'same': cmd_same, 'diff': cmd_diff}[a.cmd](a)


if __name__ == '__main__':
    sys.exit(main())
