#!/usr/bin/env python3
"""Rewrites the Evolution X 16 / crDroid 16 taoyao powerhint.json (written for
kernel 5.4) for the taoyao Linux 6.12 kernel.  Python 3 stdlib only.

  python3 -I powerhint612.py INPUT -o OUT.json [--report REPORT.txt]
          [--guards GUARDS.txt] [--expect EXPECT.txt] [--sysfs-list LIST] [--force]

Exit codes:
  0  ok
  2  unknown input sha256 (only a known file is rewritten; --force overrides)
  3  unreadable, corrupt or non-UTF-8 input (--force does not override)
  4  unrecognised structure (--force skips unrecognised nodes, nothing else)
  5  the output fails the validator: internal error (--force does not override)
  64 usage error
"""

import argparse
import hashlib
import importlib.util
import json
import re
import sys
from pathlib import Path

sys.dont_write_bytecode = True

_spec = importlib.util.spec_from_file_location(
    "validate_powerhint", Path(__file__).with_name("validate_powerhint.py"))
V = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(V)

KNOWN_INPUTS = {
    "1f43929093c1584fef2cc1d2eb3294a0d685b50e21b3b293201379ddab1f7d6a":
        "Evolution X 16 / crDroid 16, device_xiaomi_taoyao configs/powerhint.json (шаблон lahaina)",
}

ACTION_KEYS = ("PowerHint", "Node", "Duration", "Value")

CPU0 = "/sys/devices/system/cpu/cpu0/cpufreq"
CPU4 = "/sys/devices/system/cpu/cpu4/cpufreq"
CPU7 = "/sys/devices/system/cpu/cpu7/cpufreq"
KG = "/sys/class/kgsl/kgsl-3d0"
OLD_LLCC = "/sys/class/devfreq/soc:qcom,cpu-cpu-llcc-bw"
OLD_DDR = "/sys/class/devfreq/soc:qcom,cpu-llcc-ddr-bw"
BD = V.BD
BW = V.BWMON_LLCC
# hw_min_freq of each bus_dcvs table (K612 yupik.dtsi:1549, 1562, 1577; dcvs.c:737).
BOOST_TABLE_MIN = {V.LLCC_BOOST: V.LLCC_TABLE[0], V.DDR_BOOST: V.DDR_LP4X_TABLE[0]}

RI = {"ResetOnInit": True}
D0 = {"DefaultIndex": 0, "ResetOnInit": True}
PROP = {"Type": "Property"}

REASON_KEEP_CPUMIN = ("минимум округляется вверх одинаково на 5.4 и 6.12; путь тот же"
                      " (K612 drivers/cpufreq/cpufreq.c:2679)")
REASON_KEEP_RATE = ("узел есть на 6.12 благодаря нашему патчу schedutil"
                    " (K612 kernel/sched/cpufreq_schedutil.c:163-175; RUN raw/sysfs-list.txt:19093-19139)")
REASON_KEEP_UCLAMP = "на ядре 0.19 записи без ошибок (RUN raw/perfmgr-fail.txt:1-10 их не содержит)"
REASON_KEEP_KGSL = ("узел принимается на 6.12 (K612 techpack/graphics/kgsl_pwrctrl.c:737-768; RUN sys/kgsl.txt:55,64,68)")
REASON_DROP_WALT = ("WALT нет в ядре 6.12 (RUN raw/config.txt: нет CONFIG_SCHED_WALT; узла нет в"
                    " RUN raw/sysctl.txt:112-124; ошибки записи RUN raw/perfmgr-fail.txt:6-10)")
REASON_CAP = ("6.12 округляет максимум вниз (K612 drivers/cpufreq/cpufreq.c:2672-2680), 5.4 брала"
              " следующую частоту вверх; берём её явно, таблица RUN sys/cpufreq.txt:%s")

# One entry per node of the known ROM file, in file order.
#   path/values/extra: the node's exact content (the fingerprint)
#   decision: KEEP | REMAP | DROP | MOVE | RENAME
#   name/new_path: new name and path (MOVE, RENAME)
#   vmap: old value -> new value (missing = unchanged)
#   drop_values: values removed together with the actions that use them
RULES = [
    dict(name="CPULittleClusterMaxFreq", path=CPU0 + "/scaling_max_freq",
         values=["9999999", "1612800"], extra=D0, decision="REMAP", vmap={"1612800": "1651200"},
         reason=REASON_CAP % "8"),
    dict(name="CPULittleClusterMinFreq", path=CPU0 + "/scaling_min_freq",
         values=["9999999", "1708800", "1305600", "691200"], extra=RI, decision="KEEP",
         reason=REASON_KEEP_CPUMIN),
    dict(name="CPULittleClusterUpRateLimit", path=CPU0 + "/schedutil/up_rate_limit_us",
         values=["500", "2000"], extra=RI, decision="KEEP", reason=REASON_KEEP_RATE),
    dict(name="CPULittleClusterDownRateLimit", path=CPU0 + "/schedutil/down_rate_limit_us",
         values=["20000", "2000"], extra=RI, decision="KEEP", reason=REASON_KEEP_RATE),
    dict(name="CPUBigClusterMaxFreq", path=CPU4 + "/scaling_max_freq",
         values=["9999999", "1324800"], extra=D0, decision="REMAP", vmap={"1324800": "1344000"},
         reason=REASON_CAP % "24"),
    dict(name="CPUBigClusterMinFreq", path=CPU4 + "/scaling_min_freq",
         values=["9999999", "1324800", "1075200", "710400"], extra=RI, decision="KEEP",
         reason=REASON_KEEP_CPUMIN),
    dict(name="CPUBigClusterUpRateLimit", path=CPU4 + "/schedutil/up_rate_limit_us",
         values=["500", "2000"], extra=RI, decision="KEEP", reason=REASON_KEEP_RATE),
    dict(name="CPUBigClusterDownRateLimit", path=CPU4 + "/schedutil/down_rate_limit_us",
         values=["10000", "2000"], extra=RI, decision="KEEP", reason=REASON_KEEP_RATE),
    dict(name="CPUBigPlusClusterMaxFreq", path=CPU7 + "/scaling_max_freq",
         values=["9999999", "1555200"], extra=D0, decision="REMAP", vmap={"1555200": "1766400"},
         reason=REASON_CAP % "40"),
    dict(name="CPUBigPlusClusterMinFreq", path=CPU7 + "/scaling_min_freq",
         values=["9999999", "1075200", "844800"], extra=RI, decision="KEEP",
         reason=REASON_KEEP_CPUMIN),
    dict(name="CPUBigPlusClusterUpRateLimit", path=CPU7 + "/schedutil/up_rate_limit_us",
         values=["500", "2000"], extra=RI, decision="KEEP", reason=REASON_KEEP_RATE),
    dict(name="CPUBigPlusClusterDownRateLimit", path=CPU7 + "/schedutil/down_rate_limit_us",
         values=["5000", "2000"], extra=RI, decision="KEEP", reason=REASON_KEEP_RATE),
    dict(name="UclampTAMin", path="/dev/cpuctl/top-app/cpu.uclamp.min",
         values=["0", "25", "50"], extra=D0, decision="KEEP", reason=REASON_KEEP_UCLAMP),
    dict(name="UclampTALatency", path="/dev/cpuctl/top-app/cpu.uclamp.latency_sensitive",
         values=["1", "0"], extra=RI, decision="KEEP", reason=REASON_KEEP_UCLAMP),
    dict(name="UclampFgMin", path="/dev/cpuctl/foreground/cpu.uclamp.min",
         values=["0", "50"], extra=D0, decision="KEEP", reason=REASON_KEEP_UCLAMP),
    dict(name="SchedPreferSpread", path="/proc/sys/kernel/sched_prefer_spread",
         values=["4", "0"], extra=RI, decision="DROP", reason=REASON_DROP_WALT),
    dict(name="SchedBusyHystNs", path="/proc/sys/kernel/sched_busy_hyst_ns",
         values=["99000000", "3000000", "0"], extra=RI, decision="DROP", reason=REASON_DROP_WALT),
    dict(name="SchedBusyHystEnableCPUs", path="/proc/sys/kernel/sched_busy_hysteresis_enable_cpus",
         values=["255", "15", "0"], extra=RI, decision="DROP", reason=REASON_DROP_WALT),
    dict(name="SchedMinTaskUtilForBoost", path="/proc/sys/kernel/sched_min_task_util_for_boost",
         values=["0", "51"], extra=RI, decision="DROP", reason=REASON_DROP_WALT),
    dict(name="SchedMinTaskUtilForColoc", path="/proc/sys/kernel/sched_min_task_util_for_colocation",
         values=["0", "35"], extra=RI, decision="DROP", reason=REASON_DROP_WALT),
    dict(name="GPUMaxFreq", path=KG + "/devfreq/max_freq",
         values=["840000000", "540000000", "443000000"], extra=D0, decision="REMAP",
         vmap={"840000000": "550000000", "443000000": "450000000"}, drop_values=["540000000"],
         reason=("запись любого числа в devfreq/max_freq проходит (K612 drivers/devfreq/devfreq.c:1621-1660;"
                 " 840000000 на 0.19 записывался без ошибок, RUN raw/perfmgr-fail.txt:1-10), но действует только"
                 " уровень KGSL 550/450/315 МГц с точностью 5 МГц (K612 techpack/graphics/kgsl_pwrctrl.c:2136-2143;"
                 " RUN sys/kgsl.txt:73): 840000000 уровнем не является, ядро его пропускает (NOTIFY_DONE,"
                 " kgsl_pwrctrl.c:2142-2143) и не снимает прежний предел; поэтому «без предела» — ровно"
                 " 550000000, верхний уровень. 540000000 и его действие"
                 " SUSTAINED_PERFORMANCE удалены: на 5.4 значение округлялось вверх до 550 МГц, то есть"
                 " ограничения не было (taoyao54 drivers/gpu/msm/kgsl_pwrscale.c:318-329). 443000000 -> 450000000,"
                 " действий с ним нет")),
    dict(name="GPUMinFreq", path=KG + "/devfreq/min_freq",
         values=["540000000", "379000000", "315000000"], extra=RI, decision="REMAP",
         vmap={"540000000": "550000000", "379000000": "450000000"},
         reason=("devfreq KGSL выбирает только точный уровень (K612 techpack/graphics/kgsl_pwrscale.c:258-263;"
                 " RUN sys/kgsl.txt:73,75): 540000000 -> 550000000"
                 " (EXPENSIVE_RENDERING), 379000000 -> 450000000 (GAME); 315000000 — нижний уровень,"
                 " значение по умолчанию")),
    dict(name="GPUForceRailOn", path=KG + "/force_rail_on", values=["1", "0"], extra=RI,
         decision="KEEP", reason=REASON_KEEP_KGSL),
    dict(name="GPUForceClkOn", path=KG + "/force_clk_on", values=["1", "0"], extra=RI,
         decision="KEEP", reason=REASON_KEEP_KGSL),
    dict(name="GPUIdleTimer", path=KG + "/idle_timer", values=["10000", "58"], extra=RI,
         decision="KEEP", reason=REASON_KEEP_KGSL),
    dict(name="CPUBWHystTriggerCount", path=OLD_LLCC + "/bw_hwmon/hyst_trigger_count",
         values=["0", "3"], extra=RI, decision="MOVE", new_path=BW + "/hyst_trigger_count",
         reason=("атрибут bwmon LLCC на 6.12 (K612 drivers/soc/qcom/dcvs/bwmon.c:361-363, 412); в списке"
                 " RUN его нет, потому что сборщик отбрасывает имена с 'trigger'"
                 " (port-6.12/tools/taoyao-check.sh:4790); наличие проверяет guards.txt")),
    dict(name="CPUBWHistMemory", path=OLD_LLCC + "/bw_hwmon/hist_memory",
         values=["0", "20"], extra=RI, decision="MOVE", new_path=BW + "/hist_memory",
         reason="атрибут bwmon LLCC на 6.12 (bwmon.c:358-360; RUN raw/sysfs-list.txt:19452)"),
    dict(name="CPUBWHystLength", path=OLD_LLCC + "/bw_hwmon/hyst_length",
         values=["0", "10"], extra=RI, decision="MOVE", new_path=BW + "/hyst_length",
         reason="атрибут bwmon LLCC на 6.12 (bwmon.c:364-366; RUN raw/sysfs-list.txt:19434)"),
    dict(name="CPUBWMinFreq", path=OLD_LLCC + "/min_freq",
         values=["12298", "9155", "4577"], extra=RI, decision="RENAME", new_name="LLCCBoostFreq",
         new_path=BD + "/LLCC/boost_freq",
         vmap={"12298": "806000", "9155": "600000", "4577": "300000"},
         reason=("пол частоты LLCC на 6.12 — bus_dcvs/LLCC/boost_freq в кГц (RUN raw/sysfs-list.txt:19426;"
                 " K612 drivers/soc/qcom/dcvs/dcvs.c:112-155, 275-276); пересчёт МБ/с -> кГц ниже. В покое"
                 " 300000, как на 5.4: 4577 МБ/с — это 300 МГц, вторая строка таблицы LLCC, а не нижняя"
                 " (150 МГц = 2288 МБ/с; taoyao54 arch/arm64/boot/dts/vendor/qcom/yupik.dtsi:3190-3191);"
                 " сервис пишет значение по умолчанию при запуске (ResetOnInit), то есть на 5.4 LLCC"
                 " всегда держалась не ниже 300 МГц. Голос только в активном состоянии, как и на 5.4"
                 " (K612 dcvs_icc.c:70-72; taoyao54 yupik.dtsi:3231)")),
    dict(name="LLCCBWMinFreq", path=OLD_DDR + "/min_freq",
         values=["6515", "3879", "762"], extra=RI, decision="RENAME", new_name="DDRBoostFreq",
         new_path=BD + "/DDR/boost_freq",
         vmap={"6515": "1708000", "3879": "1017000", "762": "200000"},
         reason=("это шина DDR (cpu-llcc-ddr-bw); на 6.12 — bus_dcvs/DDR/boost_freq в кГц"
                 " (RUN raw/sysfs-list.txt:19240); пересчёт ниже; в покое 200000 = hw_min")),
    dict(name="PowerHALMainState", path="vendor.powerhal.state",
         values=["SUSTAINED_PERFORMANCE", ""], extra=PROP, decision="KEEP",
         reason="свойство Android, от ядра не зависит"),
    dict(name="PowerHALRenderingState", path="vendor.powerhal.rendering",
         values=["EXPENSIVE_RENDERING", ""], extra=PROP, decision="KEEP",
         reason="свойство Android, от ядра не зависит"),
]
RULES_BY_NAME = {r["name"]: r for r in RULES}

DECISION_RU = {
    "KEEP": "ОСТАВЛЕН",
    "REMAP": "ПЕРЕСЧИТАН",
    "DROP": "УДАЛЁН",
    "MOVE": "ПЕРЕНЕСЁН",
    "RENAME": "ПЕРЕИМЕНОВАН",
    "SKIP": "ПРОПУЩЕН (не распознан)",
    "DROP54": "УДАЛЁН (путь только для 5.4)",
}

# Unit conversion for the report: kHz = MBps * 1048576 / (1000 * width);
# width 16 bytes for LLCC, 4 for DDR (taoyao54 yupik.dtsi:19-25 MHZ_TO_MBPS).
CONVERSIONS = [
    ("LLCC", 16, V.LLCC_TABLE, "CPUBWMinFreq"),
    ("DDR", 4, V.DDR_LP4X_TABLE, "LLCCBWMinFreq"),
]


class Fail(Exception):
    def __init__(self, code, msg):
        Exception.__init__(self, msg)
        self.code = code


class _Parser(argparse.ArgumentParser):
    def error(self, message):
        self.print_usage(sys.stderr)
        sys.stderr.write("%s: error: %s\n" % (self.prog, message))
        sys.exit(64)


def line_numbers(text, key):
    """1-based line numbers of each occurrence of the key "<key>": in text."""
    pat = re.compile(r'"%s"\s*:' % re.escape(key))
    starts = [0]
    for m in re.finditer("\n", text):
        starts.append(m.end())
    out = []
    import bisect
    for m in pat.finditer(text):
        out.append(bisect.bisect_right(starts, m.start()))
    return out


def check_structure(root):
    """Checks that --force does not override (exit 4)."""
    if set(root.keys()) != {"Nodes", "Actions"}:
        raise Fail(4, "корневые ключи должны быть ровно Nodes и Actions, есть: %s"
                   % ", ".join(root.keys()))
    nodes, actions = root["Nodes"], root["Actions"]
    if not isinstance(nodes, list) or not isinstance(actions, list):
        raise Fail(4, "Nodes и Actions должны быть массивами")
    names = set()
    for i, n in enumerate(nodes):
        if not isinstance(n, dict) or not isinstance(n.get("Name"), str) or not n["Name"]:
            raise Fail(4, "Nodes[%d]: нет имени" % i)
        if n["Name"] in names:
            raise Fail(4, "Nodes[%d]: имя %s повторяется" % (i, n["Name"]))
        names.add(n["Name"])
        if not isinstance(n.get("Values"), list) or not all(isinstance(v, str) for v in n["Values"]):
            raise Fail(4, "Nodes[%d] %s: Values должен быть списком строк" % (i, n["Name"]))
        if "Path" in n and "Paths" in n:
            raise Fail(4, "Nodes[%d] %s: заданы и Path, и Paths" % (i, n["Name"]))
        if "Path" in n and not isinstance(n["Path"], str):
            raise Fail(4, "Nodes[%d] %s: Path должен быть строкой" % (i, n["Name"]))
        if "Paths" in n and not (isinstance(n["Paths"], list) and all(isinstance(p, str) for p in n["Paths"])):
            raise Fail(4, "Nodes[%d] %s: Paths должен быть списком строк" % (i, n["Name"]))
        di = n.get("DefaultIndex")
        if "DefaultIndex" in n and (isinstance(di, bool) or not isinstance(di, int)
                                    or not 0 <= di < len(n["Values"])):
            raise Fail(4, "Nodes[%d] %s: DefaultIndex должен быть номером значения, есть %r" % (i, n["Name"], di))
        for k in V.BOOL_KEYS:
            if k in n and not isinstance(n[k], bool):
                raise Fail(4, "Nodes[%d] %s: %s должен быть true или false" % (i, n["Name"], k))
    for i, a in enumerate(actions):
        if not isinstance(a, dict) or set(a.keys()) != set(ACTION_KEYS):
            raise Fail(4, "Actions[%d]: ключи должны быть ровно %s (без Type)"
                       % (i, ", ".join(ACTION_KEYS)))
        if not all(isinstance(a[k], str) for k in ("PowerHint", "Node", "Value")):
            raise Fail(4, "Actions[%d]: PowerHint, Node и Value должны быть строками" % i)
        d = a["Duration"]
        if isinstance(d, bool) or not isinstance(d, int) or d < 0:
            raise Fail(4, "Actions[%d]: Duration должен быть целым >= 0" % i)
        if a["Node"] not in names:
            raise Fail(4, "Actions[%d]: узла %s нет в Nodes" % (i, a["Node"]))


def fingerprint_ok(n, rule):
    """Exact, type-strict node content (False is not 0, 1 is not true)."""
    return V.rule_matches(n, rule)


def node_path(n):
    """Paths in the HAL's order: Path first, then Paths (HM:547-586)."""
    return V.node_paths(n)


def to_paths(n):
    """Legacy "Path" folded into "Paths" at the same key position."""
    return V.normalized(n)


def transform(root, force):
    """Returns (out_root, plan, dropped_actions, warnings)."""
    plan = []  # per input node: dict(index, name, decision, rule, new)
    warnings = []
    seen_rules = set()
    for i, n in enumerate(root["Nodes"]):
        name = n["Name"]
        rule = RULES_BY_NAME.get(name)
        paths = node_path(n)
        if rule is not None and fingerprint_ok(n, rule):
            plan.append(dict(index=i, name=name, decision=rule["decision"], rule=rule))
            seen_rules.add(name)
            continue
        why = "узел не из таблицы правил" if rule is None else "содержимое узла отличается от ожидаемого"
        if not force:
            raise Fail(4, "Nodes[%d] %s: %s" % (i, name, why))
        if any(p in V.ONLY54_PATHS for p in paths):
            plan.append(dict(index=i, name=name, decision="DROP54", rule=rule))
            warnings.append("Nodes[%d] %s: %s; путь есть только на 5.4 — узел удалён вместе с действиями"
                            % (i, name, why))
        else:
            plan.append(dict(index=i, name=name, decision="SKIP", rule=rule))
            warnings.append("Nodes[%d] %s: %s; оставлен без изменений (--force)" % (i, name, why))
    missing = [r["name"] for r in RULES if r["name"] not in seen_rules]
    if missing and not force:
        raise Fail(4, "в файле нет узлов: %s" % ", ".join(missing))
    if missing:
        warnings.append("нет узлов из таблицы правил: %s" % ", ".join(missing))

    new_nodes = []
    rename = {}
    vmaps = {}
    drops = {}
    dropped_nodes = set()
    for item in plan:
        n = root["Nodes"][item["index"]]
        dec = item["decision"]
        rule = item["rule"]
        if dec in ("DROP", "DROP54"):
            dropped_nodes.add(n["Name"])
            item["new"] = None
            continue
        out = to_paths(n)
        if dec in ("SKIP", "KEEP"):
            rename[n["Name"]] = n["Name"]
            item["new"] = out
            new_nodes.append(out)
            continue
        vmap = dict(rule.get("vmap", {}))
        drop_values = list(rule.get("drop_values", []))
        new_name = rule.get("new_name", n["Name"])
        new_path = rule.get("new_path")
        old_vals = n["Values"]
        new_vals = []
        for v in old_vals:
            if v in drop_values:
                continue
            new_vals.append(vmap.get(v, v))
        # DefaultIndex follows the default value, not the index.
        old_def = old_vals[n["DefaultIndex"]] if "DefaultIndex" in n else old_vals[-1]
        if old_def in drop_values:
            raise Fail(5, "%s: значение по умолчанию удаляется" % n["Name"])
        new_def = vmap.get(old_def, old_def)
        rebuilt = {}
        for k, v in out.items():
            if k == "Name":
                rebuilt[k] = new_name
            elif k == "Paths":
                rebuilt[k] = [new_path] if new_path else v
            elif k == "Values":
                rebuilt[k] = new_vals
            elif k == "DefaultIndex":
                rebuilt[k] = new_vals.index(new_def)
            else:
                rebuilt[k] = v
        if "DefaultIndex" not in out and new_vals[-1] != new_def:
            raise Fail(5, "%s: значение по умолчанию перестало быть последним" % n["Name"])
        rename[n["Name"]] = new_name
        vmaps[n["Name"]] = vmap
        drops[n["Name"]] = set(drop_values)
        item["new"] = rebuilt
        new_nodes.append(rebuilt)

    new_actions = []
    dropped_actions = []
    for i, a in enumerate(root["Actions"]):
        node = a["Node"]
        if node in dropped_nodes:
            dropped_actions.append((i, a, "узел удалён"))
            continue
        if a["Value"] in drops.get(node, ()):
            dropped_actions.append((i, a, "значение удалено"))
            continue
        na = {}
        for k, v in a.items():
            if k == "Node":
                na[k] = rename.get(node, node)
            elif k == "Value":
                na[k] = vmaps.get(node, {}).get(v, v)
            else:
                na[k] = v
        new_actions.append(na)
    return {"Nodes": new_nodes, "Actions": new_actions}, plan, dropped_actions, warnings


def serialize(obj):
    return (json.dumps(obj, indent=2, ensure_ascii=False) + "\n").encode("utf-8")


def file_node_paths(root):
    for n in root["Nodes"]:
        if V.node_type(n) == "File":
            for p in V.node_paths(n):
                yield p


def make_guards(root):
    lines = []
    for p in file_node_paths(root):
        lines.append("exists %s" % p)
    for n in root["Nodes"]:
        for p in V.node_paths(n):
            if p.endswith("/cpufreq/scaling_max_freq"):
                avail = p[: -len("scaling_max_freq")] + "scaling_available_frequencies"
                for v in n["Values"]:
                    if v != V.CPU_UNLIMITED:
                        lines.append("has %s %s" % (avail, v))
    gpu = set()
    for n in root["Nodes"]:
        for p in V.node_paths(n):
            if p in (V.KGSL_DEVFREQ + "max_freq", V.KGSL_DEVFREQ + "min_freq"):
                gpu.update(n["Values"])
    gpu = {v for v in gpu if v.isdigit()}
    for v in sorted(gpu, key=lambda x: -int(x)):
        lines.append("has %savailable_frequencies %s" % (V.KGSL_DEVFREQ, v))
    boosts = []
    for n in root["Nodes"]:
        for p in V.node_paths(n):
            if p in BOOST_TABLE_MIN and all(v.isdigit() for v in n["Values"]):
                boosts.append((p[: -len("boost_freq")], BOOST_TABLE_MIN[p], n))
    for d, tmin, n in boosts:
        lines.append("ge %shw_max_freq %d" % (d, max(int(v) for v in n["Values"])))
    for d, tmin, n in boosts:
        lines.append("eq %shw_min_freq %d" % (d, tmin))
    for d, tmin, n in boosts:
        dv = n["Values"][V.default_index(n)]
        if int(dv) != tmin:
            lines.append("has %savailable_frequencies %s" % (d, dv))
    # 550000000 must be the top KGSL level (speed bin 117: K612
    # arch/arm64/boot/dts/vendor/qcom/gpu/yupik-gpu-pwrlevels.dtsi:226-231;
    # the phone, RUN sys/kgsl.txt:73), or the default GPUMaxFreq would cap the
    # GPU: bins 0/172, 148 and 129 top at 812, 700 and 608 MHz (same file
    # :17-22, 122-127, 394-399, 322-327) and still list 550/450/315.
    if gpu:
        lines.append("first %savailable_frequencies %s" % (V.KGSL_DEVFREQ, max(gpu, key=int)))
    return "\n".join(lines) + "\n"


def hint_counts(root):
    order = V.first_hint_order(root["Actions"])
    return [(h, sum(1 for a in root["Actions"] if a["PowerHint"] == h)) for h in order]


def fmt_khz(mbps, width):
    # exact rational value, printed with one decimal (round half up)
    num = mbps * 1048576
    den = 1000 * width
    tenths = (num * 10 * 2 + den) // (2 * den)
    return "%d.%d" % (tenths // 10, tenths % 10), num / den


def round_up(x, table):
    for t in table:
        if t >= x:
            return t
    return table[-1]


def ru_plural(n, one, few, many):
    if n % 10 == 1 and n % 100 != 11:
        return one
    if 2 <= n % 10 <= 4 and not 12 <= n % 100 <= 14:
        return few
    return many


def make_report(in_sha, out_sha, text, root, out, plan, dropped, warnings, summary):
    L = []
    w = L.append
    w("Отчёт: powerhint.json для ядра Linux 6.12 (taoyao-powerhint612 v1.1)")
    w("")
    w("Обозначения ссылок:")
    w("  PH   — входной файл configs/powerhint.json (device_xiaomi_taoyao)")
    w("  HM   — libperfmgr/HintManager.cc, FN — libperfmgr/FileNode.cc (hardware/google/pixel)")
    w("  K612 — дерево ядра 6.12 (port/k612), taoyao54 — ядро Xiaomi 5.4")
    w("  RUN  — данные телефона на ядре 0.19 (taoyao-check-20261114-093748)")
    w("")
    desc = KNOWN_INPUTS.get(in_sha, "НЕИЗВЕСТНЫЙ ФАЙЛ (--force)")
    w("Вход:  sha256 %s" % in_sha)
    w("       %s" % desc)
    w("Выход: sha256 %s" % out_sha)
    n_in, n_out = len(root["Nodes"]), len(out["Nodes"])
    a_in, a_out = len(root["Actions"]), len(out["Actions"])
    w("Узлов: %d -> %d; действий: %d -> %d; подсказок PowerHint: %d -> %d"
      % (n_in, n_out, a_in, a_out, len(V.first_hint_order(root["Actions"])),
         len(V.first_hint_order(out["Actions"]))))
    w("Формат путей: \"Path\" -> \"Paths\" во всех узлах (убирает предупреждения"
      " \"old node path format detected\", HM:549-550)")
    w("AllowFailure не задаётся: все пути проверяются до подмены (guards.txt), а ошибка ENOENT"
      " остаётся видна в журнале (FN:82)")
    w("")
    w("Узлы (строка — номер строки \"Name\" во входном файле):")
    name_lines = line_numbers(text, "Name")
    for k, item in enumerate(plan):
        n = root["Nodes"][item["index"]]
        line = name_lines[item["index"]] if item["index"] < len(name_lines) else "?"
        w("")
        w("%2d. %s (PH:%s) — %s" % (k + 1, n["Name"], line, DECISION_RU[item["decision"]]))
        old_p = ", ".join(node_path(n))
        new = item.get("new")
        if new is None:
            w("    путь: %s -> (удалён)" % old_p)
        else:
            new_p = ", ".join(V.node_paths(new))
            w("    путь: %s%s" % (old_p, "" if new_p == old_p else " -> " + new_p))
            if new["Name"] != n["Name"]:
                w("    имя:  %s -> %s" % (n["Name"], new["Name"]))
            if new["Values"] != n["Values"]:
                rule = item["rule"]
                parts = []
                for v in n["Values"]:
                    if v in rule.get("drop_values", ()):
                        parts.append("%s -> (удалено)" % v)
                    else:
                        parts.append("%s -> %s" % (v, rule.get("vmap", {}).get(v, v)))
                w("    значения: " + "; ".join(parts))
            else:
                w("    значения: без изменений (%s)" % ", ".join(repr(v) for v in n["Values"]))
            di = V.default_index(new)
            w("    по умолчанию: %r%s" % (new["Values"][di],
                                          " (DefaultIndex %d)" % new["DefaultIndex"]
                                          if "DefaultIndex" in new else " (последнее значение)"))
        if item["decision"] in ("SKIP", "DROP54"):
            w("    причина: не распознан (--force)")
        else:
            w("    причина: %s" % item["rule"]["reason"])
    w("")
    w("Удалённые действия (строка — номер строки \"PowerHint\" этого действия во входном файле):")
    hint_lines = line_numbers(text, "PowerHint")
    if not dropped:
        w("  нет")
    for i, a, why in dropped:
        line = hint_lines[i] if i < len(hint_lines) else "?"
        w("  PH:%s  %s: %s = %s (%s)" % (line, a["PowerHint"], a["Node"], a["Value"], why))
    w("")
    w("Действий по подсказкам (было -> стало):")
    before = dict(hint_counts(root))
    after = dict(hint_counts(out))
    for h in V.first_hint_order(root["Actions"]):
        w("  %-22s %2d -> %2d" % (h, before.get(h, 0), after.get(h, 0)))
    w("")
    w("Пересчёт полос шины (5.4: МБ/с; 6.12: кГц):")
    w("  кГц = МБ/с x 1048576 / (1000 x ширина); ширина LLCC 16 байт, DDR 4 байта"
      " (taoyao54 yupik.dtsi:19-25); округление вверх до таблицы 6.12, как и в ядре (K612 dcvs.c:275-286)")
    w("  таблицы: LLCC K612 yupik.dtsi:1547-1555; DDR (LPDDR4X) yupik.dtsi:1559-1571,"
      " DDR (LPDDR5) yupik.dtsi:1574-1586")
    for bus, width, table, name in CONVERSIONS:
        rule = RULES_BY_NAME[name]
        for v in rule["values"]:
            s, x = fmt_khz(int(v), width)
            up = round_up(x, table)
            chosen = int(rule["vmap"][v])
            note = ""
            if chosen != up:
                note = " -> выбрано %d" % chosen
            if bus == "DDR" and chosen not in V.DDR_LP5_TABLE:
                note += "; на LPDDR5 ядро округлит до %d" % round_up(chosen, V.DDR_LP5_TABLE)
            w("  %-4s %6s МБ/с -> %10s кГц -> по таблице %7d%s" % (bus, v, s, up, note))
    w("")
    w("Ожидаемые строки журнала сервиса питания (logcat, тег libperfmgr):")
    for line in V.log_lines(summary):
        w("  " + line)
    w("  (порядок строк PowerHint на телефоне может быть другим: unordered_map, HM:847-851)")
    w("")
    w("Предупреждения --force:")
    if not warnings:
        w("  нет")
    for x in warnings:
        w("  " + x)
    return "\n".join(L) + "\n"


def run(args):
    try:
        data = Path(args.input).read_bytes()
    except OSError as e:
        raise Fail(3, "не удалось прочитать %s: %s" % (args.input, e.strerror))
    in_sha = hashlib.sha256(data).hexdigest()
    try:
        root = V.strict_parse(data)
    except V.StrictError as e:
        raise Fail(3, "файл повреждён или не строгий JSON: %s" % e)
    if not isinstance(root, dict):
        raise Fail(3, "корень JSON не объект")
    text = data.decode("utf-8")
    check_structure(root)
    if in_sha not in KNOWN_INPUTS and not args.force:
        raise Fail(2, "неизвестный файл: sha256 %s (используйте --force, чтобы преобразовать"
                   " только распознанные узлы)" % in_sha)
    out, plan, dropped, warnings = transform(root, args.force)
    out_bytes = serialize(out)
    sysfs = None
    if args.sysfs_list:
        try:
            sysfs = V.load_sysfs(args.sysfs_list)
        except OSError as e:
            raise Fail(64, "не удалось прочитать --sysfs-list: %s" % e.strerror)
    res = V.validate_bytes(out_bytes, "612", stock=root, sysfs=sysfs, rules=RULES)
    skipped = {"Nodes[%d] %s" % (k, item["new"]["Name"])
               for k, item in enumerate(i for i in plan if i.get("new") is not None)
               if item["decision"] == "SKIP"}
    errors = []
    for f in res.errors:
        if f.code in ("S15", "S16") and f.obj in skipped:
            warnings.append("проверка %s для пропущенного узла: %s" % (f.code, f.msg))
        else:
            errors.append(f)
    if V.first_hint_order(out["Actions"]) != V.first_hint_order(root["Actions"]):
        errors.append("набор подсказок PowerHint изменился")
    for p in file_node_paths(out):
        if p in V.ONLY54_PATHS:
            errors.append("остался путь 5.4: %s" % p)
    if errors:
        raise Fail(5, "внутренняя ошибка: результат не проходит проверку:\n  "
                   + "\n  ".join(str(e) for e in errors))
    out_sha = hashlib.sha256(out_bytes).hexdigest()
    Path(args.output).write_bytes(out_bytes)
    if args.report:
        rep = make_report(in_sha, out_sha, text, root, out, plan, dropped, warnings, res.summary)
        Path(args.report).write_bytes(rep.encode("utf-8"))
    if args.guards:
        Path(args.guards).write_bytes(make_guards(out).encode("utf-8"))
    if args.expect:
        Path(args.expect).write_bytes(V.expect_text(res.summary).encode("utf-8"))
    for x in warnings:
        print("предупреждение: " + x, file=sys.stderr)
    nn, na = len(out["Nodes"]), len(out["Actions"])
    print("готово: %d %s, %d %s, sha256 %s" % (nn, ru_plural(nn, "узел", "узла", "узлов"),
                                            na, ru_plural(na, "действие", "действия", "действий"), out_sha))
    return 0


def main(argv=None):
    ap = _Parser(prog="powerhint612.py", description="powerhint.json 5.4 -> 6.12 (taoyao)")
    ap.add_argument("input")
    ap.add_argument("-o", "--output", required=True)
    ap.add_argument("--report")
    ap.add_argument("--guards")
    ap.add_argument("--expect")
    ap.add_argument("--sysfs-list")
    ap.add_argument("--force", action="store_true")
    args = ap.parse_args(argv)
    try:
        return run(args)
    except Fail as e:
        print("ошибка (%d): %s" % (e.code, e), file=sys.stderr)
        return e.code


if __name__ == "__main__":
    sys.exit(main())
