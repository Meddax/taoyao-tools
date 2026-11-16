#!/usr/bin/env python3
"""Builds the taoyao_powerhint612 KernelSU module zip (stdlib only, deterministic).

  python3 -I tools/build_module.py [--input PH] [--build-dir DIR] [--dist DIR]
          [--sysfs-list LIST] [--update-golden] [--skip-tests]

Steps: known input -> transformer -> validator (stock on the input, 612 on the
output) -> goldens -> module dir -> sh -n, ship gates, tests -> zip -> sha256.
"""

import argparse
import hashlib
import importlib.util
import os
import re
import shutil
import subprocess
import sys
import zipfile
from pathlib import Path

sys.dont_write_bytecode = True

PRJ = Path(__file__).resolve().parent.parent
TOOLS = PRJ / "tools"
DEFAULT_INPUT = str(PRJ / "tests" / "data" / "powerhint.stock.json")
# raw/sysfs-list.txt from a taoyao-check run on kernel 6.12 (optional check)
DEFAULT_SYSFS = os.environ.get("TY_SYSFS_LIST", "")
ZIP_NAME = "taoyao-powerhint612-v1.2.zip"
ZIP_ORDER = ("module.prop", "customize.sh", "post-mount.sh", "service.sh", "uninstall.sh",
             "lib.sh", "powerhint.json", "powerhint.json.sha256", "known-inputs.txt",
             "guards.txt", "expect.txt", "README-ru.txt", "LICENSE.txt")
SOURCE_FILES = ("module.prop", "customize.sh", "post-mount.sh", "service.sh", "uninstall.sh",
                "lib.sh", "README-ru.txt")
ZIP_DATE = (2026, 11, 14, 0, 0, 0)
GOLDENS = (("powerhint.json", "powerhint.612.json"), ("report-ru.txt", "report-ru.txt"),
           ("guards.txt", "guards.txt"), ("expect.txt", "expect.txt"))

GATE_RE = re.compile(r"redwood|genie|vajra|telegram|t\.me|http|github|cl(?:a)ude|anth(?:r)opic|assistant"
                     r"|ассистент|нейросет|\bИИ\b|\bAI\b", re.I)
# The MeruDevTools license text and the Apache-2.0 text are copied verbatim:
# they name GitHub, AI/ИИ/нейросети (in the license's own prohibitions) and
# apache.org.  For their verbatim parts only this narrower gate applies.
LICENSE_GATE_RE = re.compile(r"redwood|genie|vajra|telegram|t\.me|cl(?:a)ude|anth(?:r)opic|assistant"
                             r"|ассистент", re.I)
EMAIL_RE = re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+")
ALLOWED_EMAIL = "i@meru-ii.ru"
AUTHOR = "Meddax и MeruDevTools"


def load(name):
    spec = importlib.util.spec_from_file_location(name, TOOLS / (name + ".py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class BuildError(Exception):
    pass


def sha256(data):
    return hashlib.sha256(data).hexdigest()


# ---------------------------------------------------------------- license

LICENSE_SRC = PRJ / "third_party" / "LICENSE.taoyao"
LICENSE_SRC_SHA = "8c53c4e4371a764baf6bd39104b06af813435c0d5b8382876a3b09b620b5b7cd"
APACHE_SRC = PRJ / "third_party" / "Apache-2.0.txt"
APACHE_SRC_SHA = "cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30"

RU_SCOPE = """\
Продукт: Модуль KernelSU «taoyao: powerhint.json для ядра 6.12» для Xiaomi
         Mi 12 Lite (taoyao)
Архив:   zip модуля taoyao-powerhint612-v<версия>.zip
Файлы:   в zip модуля:
           module.prop, customize.sh, post-mount.sh, service.sh,
             uninstall.sh, lib.sh;
           guards.txt, expect.txt, known-inputs.txt и
             powerhint.json.sha256;
           README-ru.txt;
           этот файл лицензии (LICENSE.txt);
         а также списки изменений и инструкции Разработчиков к модулю.
         Файл powerhint.json в Продукт не входит: он построен на файле
         проекта LineageOS и распространяется по лицензии Apache-2.0
         (части 2 и 3 этого файла, раздел 10).
"""

EN_SCOPE = """\
Product: the KernelSU module "taoyao: powerhint.json for kernel 6.12" for
         the Xiaomi Mi 12 Lite (taoyao) («Модуль KernelSU «taoyao:
         powerhint.json для ядра 6.12» для Xiaomi Mi 12 Lite (taoyao)»)
Archive: the module zip taoyao-powerhint612-v<version>.zip
Files:   in the module zip:
           module.prop, customize.sh, post-mount.sh, service.sh,
             uninstall.sh, lib.sh;
           guards.txt, expect.txt, known-inputs.txt and
             powerhint.json.sha256;
           README-ru.txt;
           this license file (LICENSE.txt);
         and the Developers' changelogs and instructions for the module.
         The file powerhint.json is not part of the Software: it is built
         on a file of the LineageOS project and is distributed under the
         Apache-2.0 license (parts 2 and 3 of this file, section 10).
"""

PART1_HEAD = """\
ЧАСТЬ 1 из 3. ЛИЦЕНЗИЯ НА СКРИПТЫ И ТЕКСТЫ МОДУЛЯ / PART 1 of 3. LICENSE
FOR THE MODULE'S SCRIPTS AND TEXTS
========================================================================

"""

PART2 = """\

========================================================================
ЧАСТЬ 2 из 3. УВЕДОМЛЕНИЕ О ФАЙЛЕ powerhint.json (Apache-2.0)
========================================================================

Файл powerhint.json в этом архиве — изменённая версия файла
configs/powerhint.json из дерева устройства Xiaomi Mi 12 Lite проекта
LineageOS (device_xiaomi_taoyao; в прошивках Evolution X 16 и crDroid 16 он
устанавливается как /vendor/etc/powerhint.json).

  SPDX-FileCopyrightText: The LineageOS Project
  SPDX-License-Identifier: Apache-2.0

Исходный файл распространяется по лицензии Apache License, Version 2.0;
изменённый файл распространяется по той же лицензии (её текст — в части 3).
Лицензия MeruDevTools (часть 1) к файлу powerhint.json не применяется.

Изменения (Apache-2.0, п. 4(b)): в 2026 г. Meddax и MeruDevTools изменили
файл для ядра Linux 6.12:
  - удалены 5 узлов планировщика WALT (/proc/sys/kernel/sched_*) и 7
    действий с ними;
  - узлы шины памяти перенесены в /sys/devices/system/cpu/bus_dcvs/
    (LLCC/boost_freq, DDR/boost_freq, LLCC/90b6400.qcom,bwmon-llcc/),
    значения пересчитаны из МБ/с в кГц, узлы CPUBWMinFreq и LLCCBWMinFreq
    переименованы в LLCCBoostFreq и DDRBoostFreq;
  - ограничения частот CPU и частоты GPU приведены к таблицам ядра 6.12,
    удалено действие GPUMaxFreq=540000000 подсказки SUSTAINED_PERFORMANCE;
  - ключ "Path" заменён на "Paths" во всех узлах.

Notice (English): the file powerhint.json in this archive is a modified
version of configs/powerhint.json of the LineageOS device tree for the
Xiaomi Mi 12 Lite (device_xiaomi_taoyao), Copyright The LineageOS Project,
licensed under the Apache License, Version 2.0 (text in part 3). It was
modified in 2026 by Meddax and MeruDevTools for the Linux 6.12 kernel (the
changes are listed above) and is distributed under the same license. The
MeruDevTools license (part 1) does not apply to it.

========================================================================
ЧАСТЬ 3 из 3. ТЕКСТ ЛИЦЕНЗИИ APACHE 2.0 / PART 3 of 3. APACHE LICENSE 2.0
========================================================================

"""


def _replace_block(lines, start_prefix, end_prefix, new_block):
    s = next(i for i, l in enumerate(lines) if l.startswith(start_prefix))
    e = next(i for i, l in enumerate(lines) if i > s and l.startswith(end_prefix))
    return lines[:s] + new_block.splitlines(keepends=True) + lines[e:], (s, e)


def make_license():
    src = LICENSE_SRC.read_bytes()
    if sha256(src) != LICENSE_SRC_SHA:
        raise BuildError("third_party/LICENSE.taoyao changed (sha256 %s)" % sha256(src))
    ap = APACHE_SRC.read_bytes()
    if sha256(ap) != APACHE_SRC_SHA:
        raise BuildError("third_party/Apache-2.0.txt changed")
    lines = src.decode("utf-8").splitlines(keepends=True)
    lines, _ = _replace_block(lines, "Продукт: ", "Связь: ", RU_SCOPE)
    lines, _ = _replace_block(lines, "Product: ", "Contact: ", EN_SCOPE)
    part1 = "".join(lines)
    if not part1.endswith("\n"):
        part1 += "\n"
    return (PART1_HEAD + part1 + PART2 + ap.decode("utf-8")).encode("utf-8")


def license_generated_text():
    """The parts of LICENSE.txt written for this module (not copied)."""
    return PART1_HEAD + RU_SCOPE + EN_SCOPE + PART2


# ---------------------------------------------------------------- gates

def ship_gates(mod_dir):
    """Returns a list of problems in the shipped files of mod_dir."""
    problems = []
    mod_dir = Path(mod_dir)
    names = sorted(p.name for p in mod_dir.iterdir())
    if sorted(ZIP_ORDER) != names:
        problems.append("shipped file set differs: %s" % names)
    for name in ZIP_ORDER:
        p = mod_dir / name
        if not p.is_file():
            continue
        data = p.read_bytes()
        if b"\r" in data:
            problems.append("%s: CR in file (LF only)" % name)
        if data.startswith(b"\xef\xbb\xbf"):
            problems.append("%s: BOM" % name)
        try:
            text = data.decode("utf-8")
        except UnicodeDecodeError:
            problems.append("%s: not UTF-8" % name)
            continue
        if not text.endswith("\n"):
            problems.append("%s: no final newline" % name)
        if name == "LICENSE.txt":
            for m in LICENSE_GATE_RE.finditer(text):
                problems.append("%s: forbidden word %r" % (name, m.group(0)))
        else:
            for m in GATE_RE.finditer(text):
                problems.append("%s: forbidden word %r" % (name, m.group(0)))
        for m in EMAIL_RE.finditer(text):
            if m.group(0) != ALLOWED_EMAIL:
                problems.append("%s: e-mail %s" % (name, m.group(0)))
    for m in GATE_RE.finditer(license_generated_text()):
        problems.append("LICENSE.txt (generated part): forbidden word %r" % m.group(0))
    lic = mod_dir / "LICENSE.txt"
    if lic.is_file() and lic.read_bytes() != make_license():
        problems.append("LICENSE.txt differs from make_license()")
    prop = mod_dir / "module.prop"
    if prop.is_file():
        kv = dict(l.split("=", 1) for l in prop.read_text("utf-8").splitlines() if "=" in l)
        if kv.get("author") != AUTHOR:
            problems.append("module.prop: author is %r" % kv.get("author"))
        if kv.get("id") != "taoyao_powerhint612" or not re.match(r"^[a-zA-Z][a-zA-Z0-9._-]+$", kv.get("id", "")):
            problems.append("module.prop: bad id")
        for k in ("name", "version", "versionCode", "description"):
            if not kv.get(k):
                problems.append("module.prop: no %s" % k)
    lib = mod_dir / "lib.sh"
    if lib.is_file() and lib.read_text("utf-8").count('\nTP_ROOT=""\n') != 1:
        problems.append('lib.sh: the line TP_ROOT="" must occur exactly once')
    return problems


def sh_syntax(mod_dir):
    problems = []
    for name in ZIP_ORDER:
        if name.endswith(".sh"):
            for sh in (["dash", "-n"], ["busybox", "sh", "-n"]):
                r = subprocess.run(sh + [str(Path(mod_dir) / name)], capture_output=True, text=True)
                if r.returncode != 0:
                    problems.append("%s %s: %s" % (" ".join(sh), name, r.stderr.strip()))
    return problems


# ---------------------------------------------------------------- zip

def write_zip(mod_dir, out_path):
    tmp = Path(str(out_path) + ".tmp")
    with zipfile.ZipFile(tmp, "w") as zf:
        for name in ZIP_ORDER:
            data = (Path(mod_dir) / name).read_bytes()
            zi = zipfile.ZipInfo(name, date_time=ZIP_DATE)
            zi.create_system = 3
            zi.external_attr = 0o100644 << 16
            zi.compress_type = zipfile.ZIP_DEFLATED
            zf.writestr(zi, data, compress_type=zipfile.ZIP_DEFLATED, compresslevel=9)
    os.replace(tmp, out_path)


# ---------------------------------------------------------------- build

def run_py(args, what):
    r = subprocess.run([sys.executable, "-I", "-B"] + [str(a) for a in args], capture_output=True, text=True)
    if r.returncode != 0:
        raise BuildError("%s failed (exit %d):\n%s%s" % (what, r.returncode, r.stdout, r.stderr))
    return r


def build(input_path, build_dir, dist_dir, sysfs, update_golden=False, skip_tests=False, log=print):
    T = load("powerhint612")
    V = T.V
    build_dir = Path(build_dir)
    dist_dir = Path(dist_dir)
    data = Path(input_path).read_bytes()
    in_sha = sha256(data)
    if in_sha not in T.KNOWN_INPUTS:
        raise BuildError("unknown input sha256 %s" % in_sha)
    log("input: %s sha256 %s" % (input_path, in_sha))
    mod = build_dir / "module"
    if mod.exists():
        shutil.rmtree(mod)
    mod.mkdir(parents=True)
    report = build_dir / "report-ru.txt"
    args = [TOOLS / "powerhint612.py", input_path, "-o", mod / "powerhint.json", "--report", report,
            "--guards", mod / "guards.txt", "--expect", mod / "expect.txt"]
    if sysfs:
        args += ["--sysfs-list", sysfs]
    log(run_py(args, "transformer").stdout.strip())

    vargs = [TOOLS / "validate_powerhint.py", input_path, "--profile", "stock", "--stock", input_path]
    r = run_py(vargs, "validator (stock profile on the input)")
    log("validator stock/input: " + r.stdout.strip().splitlines()[-1])
    vexp = build_dir / "expect.validator.txt"
    vargs = [TOOLS / "validate_powerhint.py", mod / "powerhint.json", "--profile", "612",
             "--stock", input_path, "--expect-out", vexp]
    if sysfs:
        vargs += ["--sysfs-list", sysfs]
    r = run_py(vargs, "validator (612 profile on the output)")
    log("validator 612/output: " + r.stdout.strip().splitlines()[-1])
    if vexp.read_bytes() != (mod / "expect.txt").read_bytes():
        raise BuildError("validator summary differs from expect.txt")

    gold = PRJ / "tests" / "golden"
    for built, gname in GOLDENS:
        src = report if built == "report-ru.txt" else mod / built
        g = gold / gname
        if update_golden:
            gold.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(src, g)
            log("golden updated: %s" % g)
        elif not g.is_file() or g.read_bytes() != src.read_bytes():
            raise BuildError("%s differs from golden %s (review, then --update-golden)" % (built, g))

    for name in SOURCE_FILES:
        shutil.copyfile(PRJ / "module" / name, mod / name)
    out_sha = sha256((mod / "powerhint.json").read_bytes())
    (mod / "powerhint.json.sha256").write_bytes(("%s  powerhint.json\n" % out_sha).encode())
    (mod / "known-inputs.txt").write_bytes("".join(
        "%s  %s\n" % (k, v) for k, v in sorted(T.KNOWN_INPUTS.items())).encode("utf-8"))
    (mod / "LICENSE.txt").write_bytes(make_license())

    problems = sh_syntax(mod) + ship_gates(mod)
    if problems:
        raise BuildError("checks failed:\n  " + "\n  ".join(problems))
    log("sh -n (dash, busybox sh) and ship gates: ok")

    if not skip_tests:
        r = subprocess.run(["sh", str(PRJ / "tests" / "run.sh"), str(mod)], capture_output=True, text=True)
        log(r.stdout.strip().splitlines()[-1] if r.stdout.strip() else "(no output)")
        if r.returncode != 0:
            raise BuildError("shell tests failed:\n%s%s" % (r.stdout, r.stderr))
        r = subprocess.run([sys.executable, "-I", "-B", "-m", "unittest", "discover", "-s", str(PRJ / "tests")],
                           capture_output=True, text=True)
        tail = [l for l in r.stderr.strip().splitlines() if l.startswith(("Ran ", "OK", "FAILED"))]
        log("unit tests: " + " / ".join(tail))
        if r.returncode != 0:
            raise BuildError("unit tests failed:\n%s%s" % (r.stdout, r.stderr))

    dist_dir.mkdir(parents=True, exist_ok=True)
    zpath = dist_dir / ZIP_NAME
    write_zip(mod, zpath)
    zsha = sha256(zpath.read_bytes())
    (dist_dir / (ZIP_NAME + ".sha256")).write_bytes(("%s  %s\n" % (zsha, ZIP_NAME)).encode())
    log("zip: %s" % zpath)
    log("sha256: %s" % zsha)
    return zpath, zsha


def main(argv=None):
    ap = argparse.ArgumentParser(prog="build_module.py")
    ap.add_argument("--input", default=DEFAULT_INPUT)
    ap.add_argument("--build-dir", default=str(PRJ / "build"))
    ap.add_argument("--dist", default=str(PRJ / "dist"))
    ap.add_argument("--sysfs-list", default=DEFAULT_SYSFS if os.path.isfile(DEFAULT_SYSFS) else None)
    ap.add_argument("--update-golden", action="store_true")
    ap.add_argument("--skip-tests", action="store_true")
    a = ap.parse_args(argv)
    try:
        build(a.input, a.build_dir, a.dist, a.sysfs_list, a.update_golden, a.skip_tests)
    except (BuildError, OSError) as e:
        print("build failed: %s" % e, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
