#!/usr/bin/env python3
"""Validator for a libperfmgr powerhint.json (taoyao, kernel 6.12).

Python 3 stdlib only.  Usage:

  python3 -I validate_powerhint.py FILE [--profile hal|stock|612] [--stock PH]
          [--sysfs-list SYSFS_LIST] [--expect-out FILE]

Exit codes: 0 no errors, 1 errors, 3 unreadable or unparsable file, 64 usage.

Rules H* mirror what the power HAL parser does
(hardware/google/pixel power-libperfmgr/libperfmgr/HintManager.cc, "HM:<line>"):
an H error means HintManager::GetFromJSON() returns nullptr and the service
dies in LOG(FATAL) "Invalid config" (HM:383-386).  Rules S* are stricter than
the HAL, so the leniency of jsoncpp never matters.

Profiles: hal = H + S1-S2; stock = hal + S3 + S10-S11; 612 = stock + S12-S18.
S18 (612 profile with --stock) re-derives the whole expected 6.12 file from the
ROM file and the rule table of powerhint612.py (loaded by path) and requires
the nodes and actions to be exactly that.
"""

import argparse
import json
import os
import sys

# --------------------------------------------------------------------------
# Constants shared with powerhint612.py (it loads this file by path).
# --------------------------------------------------------------------------

# PowerHint names of the ROM file, in the order of first appearance
# (configs/powerhint.json:312,342,426,474,540,552,570).  Support is derived
# from Actions: lineage power-libperfmgr aidl/SupportManager.cpp:114-133.
STOCK_HINTS = ("SUSTAINED_PERFORMANCE", "INTERACTION", "INTERACTIVE", "LAUNCH",
               "EXPENSIVE_RENDERING", "Flipendo", "GAME")

# The 10 nodes that exist only on 5.4 (phone run 0.19, raw/perfmgr-fail.txt:1-10).
ONLY54_PATHS = (
    "/sys/class/devfreq/soc:qcom,cpu-llcc-ddr-bw/min_freq",
    "/sys/class/devfreq/soc:qcom,cpu-cpu-llcc-bw/min_freq",
    "/sys/class/devfreq/soc:qcom,cpu-cpu-llcc-bw/bw_hwmon/hyst_trigger_count",
    "/sys/class/devfreq/soc:qcom,cpu-cpu-llcc-bw/bw_hwmon/hyst_length",
    "/sys/class/devfreq/soc:qcom,cpu-cpu-llcc-bw/bw_hwmon/hist_memory",
    "/proc/sys/kernel/sched_prefer_spread",
    "/proc/sys/kernel/sched_min_task_util_for_colocation",
    "/proc/sys/kernel/sched_min_task_util_for_boost",
    "/proc/sys/kernel/sched_busy_hysteresis_enable_cpus",
    "/proc/sys/kernel/sched_busy_hyst_ns",
)

NODE_KEYS = ("Name", "Path", "Paths", "Values", "DefaultIndex", "ResetOnInit",
             "Type", "Truncate", "HoldFd", "WriteOnly", "AllowFailure")
BOOL_KEYS = ("ResetOnInit", "Truncate", "HoldFd", "WriteOnly", "AllowFailure")
FILE_ONLY_BOOL_KEYS = ("Truncate", "HoldFd", "WriteOnly", "AllowFailure")  # HM:674-711
ACTION_KEYS = ("PowerHint", "Node", "Duration", "Value", "Type",
               "EnableProperty", "EnableFlag", "DisableFlag")
# ADD_FLAG list: libperfmgr include/perfmgr/FlagProvider.h:77-80, looked up by
# FlagProvider::GetterFromString (FlagProvider.cc:69-72).
FLAG_NAMES = ("test_flag", "gpu_load_up_for_blurs", "ramp_down_sf_prefer_high_cap",
              "chrome_profile_bypass_hboost_severe_jank_level")
ADPF_PREFIX = "<AdpfConfig>:"  # HM:56

# cpufreq tables of 6.12 on the phone (run 0.19, sys/cpufreq.txt:8,24,40) and
# related_cpus (sys/cpufreq.txt:9,25,41).
CPU_TABLES = {
    0: (300000, 691200, 806400, 940800, 1152000, 1324800, 1516800, 1651200, 1804800),
    4: (691200, 940800, 1228800, 1344000, 1516800, 1651200, 1900800, 2054400, 2131200, 2400000),
    7: (806400, 1056000, 1324800, 1516800, 1766400, 1862400, 2035200, 2208000, 2380800, 2400000),
}
CPU_POLICY = {0: 0, 1: 0, 2: 0, 3: 0, 4: 4, 5: 4, 6: 4, 7: 7}
CPU_UNLIMITED = "9999999"

# KGSL power levels (run 0.19, sys/kgsl.txt:73).
KGSL_LEVELS = ("550000000", "450000000", "315000000")
KGSL_DEVFREQ = "/sys/class/kgsl/kgsl-3d0/devfreq/"
KGSL_CLASS = "/sys/class/kgsl/kgsl-3d0/"
KGSL_DEV = "/sys/devices/platform/soc/3d00000.qcom,kgsl-3d0"

# bus_dcvs tables (k612 arch/arm64/boot/dts/vendor/qcom/yupik.dtsi:1547-1555
# LLCC, 1559-1571 LPDDR4X "ddr4", 1574-1586 LPDDR5 "ddr5"), kHz.
BD = "/sys/devices/system/cpu/bus_dcvs"
LLCC_TABLE = (150000, 300000, 466000, 600000, 806000, 933000, 1066000)
DDR_LP4X_TABLE = (200000, 451000, 547000, 681000, 768000, 1017000, 1353000, 1555000,
                  1708000, 2092000)
DDR_LP5_TABLE = (200000, 451000, 547000, 681000, 768000, 1555000, 1708000, 2092000,
                 2736000, 3196000)
LLCC_MAX = 1066000
DDR_MAX = 2092000  # hw_max common to both DDR tables
LLCC_BOOST = BD + "/LLCC/boost_freq"
DDR_BOOST = BD + "/DDR/boost_freq"
BWMON_LLCC = BD + "/LLCC/90b6400.qcom,bwmon-llcc"
BWMON_ATTRS = ("hyst_trigger_count", "hist_memory", "hyst_length")
HYST_TRIGGER = BWMON_LLCC + "/hyst_trigger_count"

# Nodes the 6.12 rules leave exactly as in the ROM file (only Path -> Paths).
KEEP_NAMES = (
    "CPULittleClusterMinFreq", "CPULittleClusterUpRateLimit", "CPULittleClusterDownRateLimit",
    "CPUBigClusterMinFreq", "CPUBigClusterUpRateLimit", "CPUBigClusterDownRateLimit",
    "CPUBigPlusClusterMinFreq", "CPUBigPlusClusterUpRateLimit", "CPUBigPlusClusterDownRateLimit",
    "UclampTAMin", "UclampTALatency", "UclampFgMin",
    "GPUForceRailOn", "GPUForceClkOn", "GPUIdleTimer",
    "PowerHALMainState", "PowerHALRenderingState",
)
# Names of the nodes the 6.12 rules change (after renaming).
CHANGED_NAMES = (
    "CPULittleClusterMaxFreq", "CPUBigClusterMaxFreq", "CPUBigPlusClusterMaxFreq",
    "GPUMaxFreq", "GPUMinFreq",
    "CPUBWHystTriggerCount", "CPUBWHistMemory", "CPUBWHystLength",
    "LLCCBoostFreq", "DDRBoostFreq",
)

U64_MAX = 2 ** 64 - 1
PROFILES = ("hal", "stock", "612")


class Finding:
    __slots__ = ("level", "code", "obj", "msg", "ref")

    def __init__(self, level, code, obj, msg, ref):
        self.level, self.code, self.obj, self.msg, self.ref = level, code, obj, msg, ref

    def __str__(self):
        ref = " (%s)" % self.ref if self.ref else ""
        return "%-7s %-4s %s: %s%s" % (self.level, self.code, self.obj, self.msg, ref)


class Result:
    def __init__(self):
        self.findings = []
        self.unparsable = False
        self.summary = None

    def add(self, level, code, obj, msg, ref=""):
        self.findings.append(Finding(level, code, obj, msg, ref))

    def err(self, code, obj, msg, ref=""):
        self.add("ERROR", code, obj, msg, ref)

    def warn(self, code, obj, msg, ref=""):
        self.add("WARNING", code, obj, msg, ref)

    def note(self, code, obj, msg, ref=""):
        self.add("NOTE", code, obj, msg, ref)

    @property
    def errors(self):
        return [f for f in self.findings if f.level == "ERROR"]

    @property
    def warnings(self):
        return [f for f in self.findings if f.level == "WARNING"]

    def codes(self, level="ERROR"):
        return [f.code for f in self.findings if f.level == level]


# --------------------------------------------------------------------------
# Parsing
# --------------------------------------------------------------------------

class StrictError(ValueError):
    pass


def _strict_pairs(pairs):
    seen = set()
    for k, _ in pairs:
        if k in seen:
            raise StrictError("duplicate key %r" % k)
        seen.add(k)
    return dict(pairs)


def _strict_const(name):
    raise StrictError("non-finite number %s" % name)


def strict_parse(data):
    """Strict JSON: UTF-8 without BOM, no comments, no trailing data, no
    NaN/Infinity, no duplicate keys.  Returns the object (any JSON type)."""
    if data.startswith(b"\xef\xbb\xbf"):
        raise StrictError("UTF-8 BOM")
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError as e:
        raise StrictError("invalid UTF-8 at byte %d" % e.start)
    dec = json.JSONDecoder(object_pairs_hook=_strict_pairs, parse_constant=_strict_const)
    try:
        return dec.decode(text)
    except StrictError:
        raise
    except ValueError as e:
        raise StrictError(str(e))


def _strip_comments_and_commas(text, issues):
    """Removes // and /* */ comments and trailing commas outside strings
    (jsoncpp accepts both with its default settings)."""
    out = []
    i, n = 0, len(text)
    in_str = False
    while i < n:
        c = text[i]
        if in_str:
            out.append(c)
            if c == "\\" and i + 1 < n:
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
            continue
        if c == "/" and i + 1 < n and text[i + 1] == "/":
            j = text.find("\n", i)
            j = n if j < 0 else j
            issues.append("comment")
            out.append(" " * (j - i))
            i = j
            continue
        if c == "/" and i + 1 < n and text[i + 1] == "*":
            j = text.find("*/", i + 2)
            j = n if j < 0 else j + 2
            issues.append("comment")
            out.append("".join(ch if ch == "\n" else " " for ch in text[i:j]))
            i = j
            continue
        if c == ",":
            j = i + 1
            while j < n and text[j] in " \t\r\n":
                j += 1
            if j < n and text[j] in "}]":
                issues.append("trailing comma")
                out.append(" ")
                i += 1
                continue
        out.append(c)
        i += 1
    return "".join(out)


def lenient_parse(data, res):
    """Parses what jsoncpp would accept; every leniency used is an S1 error.
    Returns the object or raises ValueError."""
    if data.startswith(b"\xef\xbb\xbf"):
        res.err("S1", "file", "UTF-8 BOM (jsoncpp skips it)")
        data = data[3:]
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError as e:
        res.err("S1", "file", "invalid UTF-8 at byte %d" % e.start)
        text = data.decode("latin-1")
    issues = []
    text = _strip_comments_and_commas(text, issues)
    for kind in sorted(set(issues)):
        res.err("S1", "file", "%s (%d), accepted by jsoncpp, rejected here" % (kind, issues.count(kind)))
    dups = []
    specials = []

    def pairs(p):
        seen = set()
        for k, _ in p:
            if k in seen:
                dups.append(k)
            seen.add(k)
        return dict(p)

    def const(name):
        specials.append(name)
        return float("nan") if name == "NaN" else float(name.replace("Infinity", "inf"))

    dec = json.JSONDecoder(object_pairs_hook=pairs, parse_constant=const)
    stripped = text.lstrip(" \t\r\n")
    obj, end = dec.raw_decode(stripped)
    rest = stripped[end:].strip(" \t\r\n")
    if rest:
        res.err("S1", "file", "trailing data after the JSON value (jsoncpp ignores it)")
    for k in dups:
        res.err("S1", "file", "duplicate key %r (jsoncpp keeps the last one)" % k)
    for s in specials:
        res.err("S1", "file", "non-finite number %s" % s)
        res.err("H2", "file", "jsoncpp rejects %s (allowSpecialFloats is off): JSON parse fails" % s,
                "HM:521-525")
    return obj


# --------------------------------------------------------------------------
# jsoncpp-like helpers
# --------------------------------------------------------------------------

class JsonAbort(Exception):
    pass


def as_string(v):
    """Json::Value::asString(): null -> "", numbers and bools convert, arrays and
    objects abort the process."""
    if v is None:
        return ""
    if isinstance(v, str):
        return v
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, int):
        return str(v)
    if isinstance(v, float):
        return repr(v)
    raise JsonAbort("value is not convertible to string")


def is_uint64(v):
    if isinstance(v, bool):
        return False
    if isinstance(v, int):
        return 0 <= v <= U64_MAX
    if isinstance(v, float):
        return v == v and v.is_integer() and 0 <= v <= U64_MAX
    return False


def json_empty(v):
    """Json::Value::empty(): true for null and for an empty array or object."""
    if v is None:
        return True
    if isinstance(v, (list, dict)):
        return len(v) == 0
    return False


def node_paths(n):
    """Paths the HAL would use for a node (Path first, then Paths)."""
    out = []
    p = n.get("Path")
    if isinstance(p, str) and p:
        out.append(p)
    ps = n.get("Paths")
    if isinstance(ps, list):
        out.extend(x for x in ps if isinstance(x, str))
    return out


def node_type(n):
    t = n.get("Type")
    if t is None or t == "":
        return "File"
    return t if isinstance(t, str) else "?"


def normalized(n):
    """A node with the legacy "Path" folded into "Paths", in the HAL's order
    (Path first, then Paths: HM:547-586), at the position of the first of
    the two keys."""
    out = {}
    merged = node_paths(n)
    for k, v in n.items():
        if k in ("Path", "Paths"):
            if "Paths" not in out:
                out["Paths"] = merged
        else:
            out[k] = v
    return out


def same_json(a, b):
    """Type-strict equality (json.loads gives False == 0 and 1 == True in
    Python; the HAL does not treat them alike: HM:636-642, 656-711)."""
    return json.dumps(a, sort_keys=True) == json.dumps(b, sort_keys=True)


def rule_matches(n, rule):
    """True if node n is exactly the ROM node a rule of powerhint612.py was
    written for (key set and type-strict values)."""
    want = {"Name": rule["name"], "Path": rule["path"], "Values": rule["values"]}
    want.update(rule["extra"])
    return isinstance(n, dict) and same_json(n, want)


def canonical(path):
    """Resolves the sysfs aliases the ROM file uses to the paths that the
    collector lists (sysfs-list.txt has no symlinks)."""
    pre = "/sys/devices/system/cpu/cpu"
    if path.startswith(pre):
        rest = path[len(pre):]
        num, sep, tail = rest.partition("/")
        if num.isdigit() and tail.startswith("cpufreq/"):
            pol = CPU_POLICY.get(int(num), int(num))
            return "/sys/devices/system/cpu/cpufreq/policy%d/%s" % (pol, tail[len("cpufreq/"):])
    if path.startswith(KGSL_DEVFREQ):
        return KGSL_DEV + "/devfreq/3d00000.qcom,kgsl-3d0/" + path[len(KGSL_DEVFREQ):]
    if path.startswith(KGSL_CLASS):
        return KGSL_DEV + "/kgsl/kgsl-3d0/" + path[len(KGSL_CLASS):]
    return path


def cpu_of(path):
    """CPU number for a cpuN/cpufreq or policyN path, else None."""
    for pre in ("/sys/devices/system/cpu/cpu", "/sys/devices/system/cpu/cpufreq/policy"):
        if path.startswith(pre):
            num = path[len(pre):].split("/", 1)[0]
            if num.isdigit():
                return int(num)
    return None


def default_index(n):
    vals = n.get("Values") if isinstance(n.get("Values"), list) else []
    di = n.get("DefaultIndex")
    if di is not None and is_uint64(di):
        return int(di)
    return len(vals) - 1


def first_hint_order(actions):
    order = []
    for a in actions:
        if isinstance(a, dict):
            h = a.get("PowerHint")
            if isinstance(h, str) and h and h not in order:
                order.append(h)
    return order


# --------------------------------------------------------------------------
# Rules
# --------------------------------------------------------------------------

def check_hal(root, res):
    """H3-H19.  Returns the summary dict (what the HAL would log)."""
    nodes = root.get("Nodes")
    if not isinstance(nodes, list):
        nodes = []
    if not nodes:
        res.err("H3", "Nodes", "no nodes: \"Failed to parse Nodes section\"", "HM:447-451")
    names = {}
    seen_paths = set()
    legacy = 0
    node_values = {}
    for i, n in enumerate(nodes):
        obj = "Nodes[%d]" % i
        if not isinstance(n, dict):
            res.err("H4", obj, "node is not an object (jsoncpp aborts)", "HM:531")
            continue
        try:
            name = as_string(n.get("Name"))
        except JsonAbort:
            res.err("H4", obj, "Name is not convertible to string (jsoncpp aborts)", "HM:531")
            continue
        obj = "Nodes[%d] %s" % (i, name or "?")
        if not name:
            res.err("H4", obj, "empty Name: \"Failed to read Node's Name\"", "HM:532-536")
        elif name in names:
            res.err("H4", obj, "duplicate Name", "HM:539-544")
        names.setdefault(name, i)
        paths_parsed = []
        try:
            path = as_string(n.get("Path"))
        except JsonAbort:
            res.err("H5", obj, "Path is not convertible to string (jsoncpp aborts)", "HM:547")
            path = ""
        if path:
            legacy += 1
            res.warn("H5", obj, "legacy \"Path\": \"old node path format detected\"", "HM:549-550")
            if path in seen_paths:
                res.err("H5", obj, "duplicate path %s" % path, "HM:551-555")
            seen_paths.add(path)
            paths_parsed.append(path)
        ps = n.get("Paths")
        if json_empty(ps):
            if not paths_parsed:
                res.err("H6", obj, "no Paths and no Path: \"Failed to read Node's Paths\"", "HM:557-568")
        elif isinstance(ps, list):
            for j, p in enumerate(ps):
                try:
                    s = as_string(p)
                except JsonAbort:
                    res.err("H6", obj, "Paths[%d] is not convertible to string (jsoncpp aborts)" % j,
                            "HM:572")
                    continue
                if not s:
                    res.err("H6", obj, "empty Paths[%d]" % j, "HM:573-578")
                elif s in seen_paths:
                    res.err("H6", obj, "duplicate path %s" % s, "HM:579-584")
                seen_paths.add(s)
                paths_parsed.append(s)
        elif isinstance(ps, dict):
            res.err("H6", obj, "Paths is an object (jsoncpp aborts on index access)", "HM:571-572")
        try:
            t = as_string(n.get("Type"))
        except JsonAbort:
            res.err("H7", obj, "Type is not convertible to string (jsoncpp aborts)", "HM:589")
            t = "File"
        if t == "" or t == "File":
            is_file = True
        elif t in ("Property", "Event"):
            is_file = False
        else:
            res.err("H7", obj, "invalid Type %r (case-sensitive: File, Property, Event)" % t,
                    "HM:588-607")
            is_file = True
        vals = n.get("Values")
        vlist = []
        if isinstance(vals, list):
            vset = set()
            for j, v in enumerate(vals):
                try:
                    s = as_string(v)
                except JsonAbort:
                    res.err("H8", obj, "Values[%d] is not convertible to string (jsoncpp aborts)" % j,
                            "HM:612")
                    continue
                if s in vset:
                    res.err("H8", obj, "duplicate value %r" % s, "HM:613-620")
                if is_file and s == "":
                    res.err("H8", obj, "empty value in a File node", "HM:622-627")
                vset.add(s)
                vlist.append(s)
        if len(vlist) < 1:
            res.err("H8", obj, "no Values: \"Failed to read Node's Values\"", "HM:630-634")
        node_values[name] = vlist
        di = n.get("DefaultIndex")
        if di is not None and not is_uint64(di):
            res.warn("H9", obj, "DefaultIndex %r is not a uint64: the HAL ignores it and uses the last value"
                     % (di,), "HM:636-642")
        elif di is not None and vlist and int(di) > len(vlist) - 1:
            res.err("H9", obj, "DefaultIndex %d out of bound (max %d)" % (int(di), len(vlist) - 1),
                    "HM:646-652")
        for k in BOOL_KEYS:
            if k in n and not isinstance(n[k], bool):
                if k in FILE_ONLY_BOOL_KEYS and not is_file:
                    continue
                res.warn("H10", obj, "%s %r is not a bool: the HAL ignores it" % (k, n[k]), "HM:656-711")
        for p in paths_parsed:
            if p.startswith(ADPF_PREFIX):
                adpf = root.get("AdpfConfig")
                if not isinstance(adpf, list) or not adpf:
                    res.err("H19", obj, "path %r needs an AdpfConfig section; without one the HAL"
                            " reads adpfs[0] of an empty vector" % p, "HM:56, 467-481")

    actions = root.get("Actions")
    if not isinstance(actions, list):
        actions = []
    total = 0
    per_hint = {}
    order = []
    for i, a in enumerate(actions):
        obj = "Actions[%d]" % i
        if not isinstance(a, dict):
            res.err("H11", obj, "action is not an object (jsoncpp aborts)", "HM:751")
            continue
        try:
            hint = as_string(a.get("PowerHint"))
        except JsonAbort:
            res.err("H11", obj, "PowerHint is not convertible to string (jsoncpp aborts)", "HM:751")
            continue
        if not hint:
            res.err("H11", obj, "empty PowerHint", "HM:752-757")
            continue
        obj = "Actions[%d] %s" % (i, hint)
        try:
            t = as_string(a.get("Type"))
        except JsonAbort:
            res.err("H12", obj, "Type is not convertible to string (jsoncpp aborts)", "HM:760")
            continue
        if t not in ("", "DoHint", "EndHint", "MaskHint"):
            res.err("H12", obj, "invalid action Type %r" % t, "HM:765-778")
            continue
        entry = per_hint.setdefault(hint, {"node": [], "hint": 0})
        if hint not in order:
            order.append(hint)
        if t == "":
            try:
                node = as_string(a.get("Node"))
                value = as_string(a.get("Value"))
            except JsonAbort:
                res.err("H13", obj, "Node or Value is not convertible to string (jsoncpp aborts)",
                        "HM:780")
                continue
            if node not in names:
                res.err("H13", obj, "Node %r is not in the Nodes section" % node, "HM:784-791")
            elif value not in node_values.get(node, []):
                res.err("H14", obj, "Value %r is not defined in Node %s" % (value, node), "HM:797-803")
            d = a.get("Duration")
            if d is None or not is_uint64(d):
                res.err("H15", obj, "Duration %r is missing or not a uint64" % (d,), "HM:807-813")
            if node in entry["node"]:
                res.err("H16", obj, "Node %s appears twice in PowerHint %s" % (node, hint), "HM:816-824")
            entry["node"].append(node)
        else:
            try:
                value = as_string(a.get("Value"))
            except JsonAbort:
                value = ""
            if not value:
                res.err("H17", obj, "hint action with an empty Value", "HM:832-837")
            entry["hint"] += 1
        total += 1
    if not per_hint:
        res.err("H18", "Actions", "no actions: \"Failed to parse Actions section\"", "HM:488-491")
    return {
        "nodes": len(nodes),
        "actions": total,
        "old_path_warnings": legacy,
        "hints": [(h, len(per_hint[h]["node"]), per_hint[h]["hint"]) for h in order],
    }


def check_strict_types(root, res):
    """S1 (root keys) and S2 (types)."""
    keys = list(root.keys())
    extra = [k for k in keys if k not in ("Nodes", "Actions")]
    missing = [k for k in ("Nodes", "Actions") if k not in root]
    if extra:
        res.err("S1", "root", "root keys must be exactly Nodes and Actions; extra: %s" % ", ".join(extra))
    if missing:
        res.err("S1", "root", "missing root keys: %s" % ", ".join(missing))
    nodes = root.get("Nodes")
    if not isinstance(nodes, list):
        res.err("S2", "Nodes", "Nodes must be an array")
        nodes = []
    for i, n in enumerate(nodes):
        obj = "Nodes[%d]" % i
        if not isinstance(n, dict):
            res.err("S2", obj, "node must be an object")
            continue
        obj = "Nodes[%d] %s" % (i, n.get("Name") if isinstance(n.get("Name"), str) else "?")
        for k in n:
            if k not in NODE_KEYS:
                res.err("S2", obj, "unknown node key %r" % k)
        if not isinstance(n.get("Name"), str):
            res.err("S2", obj, "Name must be a string")
        if "Path" in n and not isinstance(n["Path"], str):
            res.err("S2", obj, "Path must be a string")
        if "Paths" in n and not (isinstance(n["Paths"], list)
                                 and all(isinstance(p, str) for p in n["Paths"])):
            res.err("S2", obj, "Paths must be a list of strings")
        if not (isinstance(n.get("Values"), list) and all(isinstance(v, str) for v in n["Values"])):
            res.err("S2", obj, "Values must be a list of strings")
        if "DefaultIndex" in n:
            di = n["DefaultIndex"]
            if isinstance(di, bool) or not isinstance(di, int) or di < 0:
                res.err("S2", obj, "DefaultIndex must be a non-negative integer, got %r" % (di,))
        for k in BOOL_KEYS:
            if k in n and not isinstance(n[k], bool):
                res.err("S2", obj, "%s must be true or false, got %r" % (k, n[k]))
        if "Type" in n:
            t = n["Type"]
            if not isinstance(t, str):
                res.err("S2", obj, "Type must be a string")
            elif t == "Event":
                res.err("S2", obj, "Type Event is not allowed here")
    actions = root.get("Actions")
    if not isinstance(actions, list):
        res.err("S2", "Actions", "Actions must be an array")
        actions = []
    for i, a in enumerate(actions):
        obj = "Actions[%d]" % i
        if not isinstance(a, dict):
            res.err("S2", obj, "action must be an object")
            continue
        for k in a:
            if k not in ACTION_KEYS:
                res.err("S2", obj, "unknown action key %r" % k)
        if "Type" in a:
            res.err("S2", obj, "action Type must be absent (DoHint/EndHint/MaskHint are not used here)")
        for k in ("PowerHint", "Node", "Value"):
            if not isinstance(a.get(k), str):
                res.err("S2", obj, "%s must be a string" % k)
        d = a.get("Duration")
        if isinstance(d, bool) or not isinstance(d, int) or not 0 <= d <= U64_MAX:
            res.err("S2", obj, "Duration must be an integer 0..2^64-1, got %r" % (d,))
            d = None
        if "EnableProperty" in a:
            ep = a["EnableProperty"]
            if not isinstance(ep, str) or not ep.startswith("vendor.powerhal."):
                res.err("S2", obj, "EnableProperty must be a string starting with vendor.powerhal.")
            if d is None or d <= 0:
                res.err("S2", obj, "EnableProperty is allowed only with Duration > 0")
        for k in ("EnableFlag", "DisableFlag"):
            if k in a and a[k] not in FLAG_NAMES:
                res.err("S2", obj, "%s %r is not one of %s (FlagProvider.h:77-80)"
                        % (k, a[k], ", ".join(FLAG_NAMES)))


def file_nodes(root):
    nodes = root.get("Nodes") if isinstance(root.get("Nodes"), list) else []
    for i, n in enumerate(nodes):
        if isinstance(n, dict) and node_type(n) == "File":
            yield i, n


def check_s3(root, res):
    seen = {}
    for i, n in file_nodes(root):
        for p in node_paths(n):
            c = canonical(p)
            if c in seen and seen[c][1] != p:
                res.err("S3", "Nodes[%d] %s" % (i, n.get("Name")),
                        "path %s is the same file as %s of Nodes[%d] (%s)" % (p, seen[c][1], seen[c][0], c))
            seen.setdefault(c, (i, p))


def hint_set(root):
    acts = root.get("Actions") if isinstance(root.get("Actions"), list) else []
    return first_hint_order(acts)


def check_s10(root, res, stock):
    want = list(hint_set(stock)) if stock is not None else list(STOCK_HINTS)
    have = hint_set(root)
    missing = [h for h in want if h not in have]
    extra = [h for h in have if h not in want]
    if missing:
        res.err("S10", "Actions", "PowerHint without actions (no longer supported): %s"
                % ", ".join(missing), "SupportManager.cpp:114-133")
    if extra:
        res.err("S10", "Actions", "PowerHint not in the ROM file: %s" % ", ".join(extra))


def stock_nodes(stock):
    nodes = stock.get("Nodes") if isinstance(stock.get("Nodes"), list) else []
    return {n.get("Name"): n for n in nodes if isinstance(n, dict)}


def check_s11(root, res, stock):
    mine = {n.get("Name"): (i, n) for i, n in enumerate(root.get("Nodes") or []) if isinstance(n, dict)}
    for name, sn in stock_nodes(stock).items():
        if node_type(sn) != "Property":
            continue
        if name not in mine:
            res.err("S11", "Nodes", "Property node %s of the ROM file is missing" % name)
        elif normalized(mine[name][1]) != normalized(sn):
            res.err("S11", "Nodes[%d] %s" % (mine[name][0], name), "Property node differs from the ROM file")


def check_s12_s13(root, res):
    for i, n in enumerate(root.get("Nodes") or []):
        if not isinstance(n, dict):
            continue
        obj = "Nodes[%d] %s" % (i, n.get("Name"))
        if "Path" in n:
            res.err("S12", obj, "legacy \"Path\" key: use \"Paths\"", "HM:549-550")
        for p in node_paths(n):
            if p in ONLY54_PATHS:
                res.err("S13", obj, "5.4-only path %s (no such node on 6.12)" % p, "perfmgr-fail.txt:1-10")


def load_sysfs(path):
    with open(path, "rb") as f:
        return set(line.decode("utf-8", "replace").rstrip("\r\n") for line in f)


def check_s14(root, res, sysfs):
    for i, n in file_nodes(root):
        obj = "Nodes[%d] %s" % (i, n.get("Name"))
        for p in node_paths(n):
            if p.startswith("/dev/cpuctl/"):
                continue
            if p == HYST_TRIGGER:
                res.note("S14", obj, "%s is not in the list: the collector drops names with"
                         " 'trigger' (taoyao-check.sh:4790); present in source (bwmon.c:361-363, 412)" % p)
                continue
            if canonical(p) not in sysfs:
                res.err("S14", obj, "path %s (%s) does not exist on the phone" % (p, canonical(p)))


def _ints(vals):
    out = []
    for v in vals:
        if isinstance(v, str) and v.isdigit():
            out.append(int(v))
        else:
            out.append(None)
    return out


def check_s15(root, res):
    for i, n in file_nodes(root):
        obj = "Nodes[%d] %s" % (i, n.get("Name"))
        vals = n.get("Values") if isinstance(n.get("Values"), list) else []
        for p in node_paths(n):
            if p.endswith("/scaling_max_freq") and cpu_of(p) is not None:
                table = CPU_TABLES.get(CPU_POLICY.get(cpu_of(p), -1))
                for v in vals:
                    if v == CPU_UNLIMITED:
                        continue
                    if table is None or not (isinstance(v, str) and v.isdigit() and int(v) in table):
                        res.err("S15", obj, "cap %r is not a frequency of policy%s (cpufreq.txt:8,24,40);"
                                " 6.12 rounds a max down (cpufreq.c:2672-2680)"
                                % (v, CPU_POLICY.get(cpu_of(p), "?")))
            elif p in (KGSL_DEVFREQ + "max_freq", KGSL_DEVFREQ + "min_freq"):
                for v in vals:
                    if v not in KGSL_LEVELS:
                        res.err("S15", obj, "GPU frequency %r is not a KGSL level %s (kgsl.txt:73)"
                                % (v, "/".join(KGSL_LEVELS)))
            elif p == LLCC_BOOST:
                for v, iv in zip(vals, _ints(vals)):
                    if iv is None or iv not in LLCC_TABLE or iv > LLCC_MAX:
                        res.err("S15", obj, "LLCC boost %r is not in the LLCC table (yupik.dtsi:1547-1555)"
                                " or above %d" % (v, LLCC_MAX))
            elif p == DDR_BOOST:
                for v, iv in zip(vals, _ints(vals)):
                    if iv is None or iv > DDR_MAX or (iv not in DDR_LP4X_TABLE and iv not in DDR_LP5_TABLE):
                        res.err("S15", obj, "DDR boost %r is in neither DDR table (yupik.dtsi:1559-1586)"
                                " or above %d" % (v, DDR_MAX))
                    elif iv not in DDR_LP4X_TABLE or iv not in DDR_LP5_TABLE:
                        res.note("S15", obj, "DDR boost %d is in one DDR table only; on the other one the"
                                 " kernel rounds it up (dcvs.c:275-286)" % iv)


def check_s16(root, res):
    for i, n in file_nodes(root):
        obj = "Nodes[%d] %s" % (i, n.get("Name"))
        vals = n.get("Values") if isinstance(n.get("Values"), list) else []
        ints = _ints(vals)
        paths = node_paths(n)
        is_boost = any(p.startswith(BD + "/") and p.endswith("/boost_freq") for p in paths)
        is_bwmon = any(p.startswith(BD + "/") and p.rsplit("/", 1)[-1] in BWMON_ATTRS for p in paths)
        if not (is_boost or is_bwmon):
            continue
        if None in ints:
            res.err("S16", obj, "values must be decimal numbers")
            continue
        if is_boost and any(a <= b for a, b in zip(ints, ints[1:])):
            res.err("S16", obj, "boost values must be strictly descending (strongest first):"
                    " RequestGroup priority follows the index (FileNode.cc:49-55)")
        if is_bwmon and any(a >= b for a, b in zip(ints, ints[1:])):
            res.err("S16", obj, "bwmon hysteresis values must be strictly ascending (0 = no"
                    " hysteresis = strongest first; FileNode.cc:49-55)")
        if default_index(n) != len(vals) - 1:
            res.err("S16", obj, "the default must be the last value")


def check_s17(root, res, stock):
    sn = stock_nodes(stock)
    for i, n in enumerate(root.get("Nodes") or []):
        if not isinstance(n, dict):
            continue
        name = n.get("Name")
        obj = "Nodes[%d] %s" % (i, name)
        if name in KEEP_NAMES:
            if name not in sn:
                res.err("S17", obj, "node is not in the ROM file")
            elif normalized(n) != normalized(sn[name]):
                res.err("S17", obj, "node must be identical to the ROM file (only Path -> Paths)")
        elif name in CHANGED_NAMES:
            continue
        elif name not in sn or normalized(n) != normalized(sn[name]):
            res.err("S17", obj, "node unknown to the 6.12 rules and not identical to the ROM file")


_RULES = None


def load_rules():
    """The rule table of powerhint612.py (next to this file), loaded by path."""
    global _RULES
    if _RULES is None:
        import importlib.util
        spec = importlib.util.spec_from_file_location(
            "powerhint612_rules", os.path.join(os.path.dirname(os.path.abspath(__file__)), "powerhint612.py"))
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        _RULES = mod.RULES
    return _RULES


def expected_612(stock, rules):
    """Independent re-derivation of the 6.12 file from the ROM file: a node
    that is exactly a rule's ROM node gets the rule (DROP, KEEP, REMAP, MOVE,
    RENAME); any other node is kept as it is (Path folded into Paths) unless
    one of its paths exists only on 5.4, then it is dropped with its actions.
    Returns (nodes, actions) or None if the ROM file has no usable lists."""
    nodes = stock.get("Nodes")
    actions = stock.get("Actions")
    if not isinstance(nodes, list) or not isinstance(actions, list):
        return None
    by_name = {r["name"]: r for r in rules}
    out_nodes = []
    dropped = set()
    rename = {}
    vmaps = {}
    drops = {}
    for n in nodes:
        if not isinstance(n, dict):
            return None
        name = n.get("Name")
        rule = by_name.get(name)
        if rule is None or not rule_matches(n, rule):
            if any(p in ONLY54_PATHS for p in node_paths(n)):
                dropped.add(name)
            else:
                out_nodes.append(normalized(n))
            continue
        dec = rule["decision"]
        if dec == "DROP":
            dropped.add(name)
            continue
        base = normalized(n)
        if dec == "KEEP":
            out_nodes.append(base)
            continue
        vmap = rule.get("vmap", {})
        dv = set(rule.get("drop_values", ()))
        vals = [vmap.get(v, v) for v in n["Values"] if v not in dv]
        old_def = n["Values"][n["DefaultIndex"]] if "DefaultIndex" in n else n["Values"][-1]
        new_name = rule.get("new_name", name)
        e = {}
        for k, v in base.items():
            if k == "Name":
                e[k] = new_name
            elif k == "Paths":
                e[k] = [rule["new_path"]] if rule.get("new_path") else v
            elif k == "Values":
                e[k] = vals
            elif k == "DefaultIndex":
                e[k] = vals.index(vmap.get(old_def, old_def))
            else:
                e[k] = v
        out_nodes.append(e)
        rename[name] = new_name
        vmaps[name] = vmap
        drops[name] = dv
    out_actions = []
    for a in actions:
        if not isinstance(a, dict):
            return None
        node = a.get("Node")
        if node in dropped or a.get("Value") in drops.get(node, ()):
            continue
        e = {}
        for k, v in a.items():
            if k == "Node":
                e[k] = rename.get(v, v)
            elif k == "Value":
                e[k] = vmaps.get(node, {}).get(v, v)
            else:
                e[k] = v
        out_actions.append(e)
    return out_nodes, out_actions


def check_s18(root, res, stock, rules):
    exp = expected_612(stock, rules)
    if exp is None:
        res.err("S18", "file", "the ROM file has no usable Nodes/Actions lists")
        return
    want_nodes, want_actions = exp
    have_nodes = root.get("Nodes") if isinstance(root.get("Nodes"), list) else []
    have_actions = root.get("Actions") if isinstance(root.get("Actions"), list) else []
    msgs = []
    wn = [n.get("Name") for n in want_nodes]
    hn = [n.get("Name") if isinstance(n, dict) else None for n in have_nodes]
    if wn != hn:
        miss = [x for x in wn if x not in hn]
        extra = [x for x in hn if x not in wn]
        msgs.append(("Nodes", "node names or order differ from the rules; missing: %s; extra: %s"
                     % (", ".join(map(str, miss)) or "-", ", ".join(map(str, extra)) or "-")))
    have_by = {n.get("Name"): n for n in have_nodes if isinstance(n, dict)}
    for i, w in enumerate(want_nodes):
        h = have_by.get(w.get("Name"))
        if h is not None and not same_json(h, w):
            msgs.append(("Nodes[%d] %s" % (hn.index(w.get("Name")), w.get("Name")),
                         "node differs from the one the rules give: %s"
                         % json.dumps(w, ensure_ascii=False, sort_keys=True)))
    if len(have_actions) != len(want_actions):
        msgs.append(("Actions", "%d actions, the rules give %d" % (len(have_actions), len(want_actions))))
    for i, (h, w) in enumerate(zip(have_actions, want_actions)):
        if not same_json(h, w):
            msgs.append(("Actions[%d]" % i, "action differs from the one the rules give: %s"
                         % json.dumps(w, ensure_ascii=False, sort_keys=True)))
            break
    for obj, msg in msgs[:12]:
        res.err("S18", obj, msg)


def validate_bytes(data, profile="612", stock=None, sysfs=None, rules=None):
    """Validates JSON bytes.  stock: parsed ROM object or None; sysfs: set of
    paths or None; rules: the rule table for S18 (default: powerhint612.py).
    Returns Result (res.unparsable set when no object could be obtained)."""
    res = Result()
    try:
        root = strict_parse(data)
    except StrictError:
        try:
            root = lenient_parse(data, res)
        except ValueError as e:
            res.err("H2", "file", "JSON parse error: %s" % e, "HM:521-525")
            res.unparsable = True
            return res
    if not isinstance(root, dict):
        res.err("S1", "root", "root must be an object")
        res.err("H3", "root", "no Nodes section", "HM:447-451")
        return res
    res.summary = check_hal(root, res)
    check_strict_types(root, res)
    if profile in ("stock", "612"):
        check_s3(root, res)
        check_s10(root, res, stock)
        if stock is not None:
            check_s11(root, res, stock)
    if profile == "612":
        check_s12_s13(root, res)
        if sysfs is not None:
            check_s14(root, res, sysfs)
        check_s15(root, res)
        check_s16(root, res)
        if stock is not None:
            check_s17(root, res, stock)
            if isinstance(stock, dict):
                check_s18(root, res, stock, rules if rules is not None else load_rules())
    return res


def expect_text(summary):
    lines = ["nodes=%d" % summary["nodes"], "actions=%d" % summary["actions"],
             "old_path_warnings=%d" % summary["old_path_warnings"]]
    for h, n, _ in summary["hints"]:
        lines.append("hint.%s=%d" % (h, n))
    return "\n".join(lines) + "\n"


def log_lines(summary):
    out = ["%d Nodes parsed successfully (HM:723)" % summary["nodes"],
           "%d actions parsed successfully (HM:845)" % summary["actions"]]
    for h, n, k in summary["hints"]:
        out.append("PowerHint %s has %d node actions, and %d hint actions parsed (HM:848-850)" % (h, n, k))
    out.append("\"old node path format detected\" warnings: %d (HM:550)" % summary["old_path_warnings"])
    return out


class _Parser(argparse.ArgumentParser):
    def error(self, message):
        self.print_usage(sys.stderr)
        sys.stderr.write("%s: error: %s\n" % (self.prog, message))
        sys.exit(64)


def main(argv=None):
    ap = _Parser(prog="validate_powerhint.py", description="Validate a libperfmgr powerhint.json")
    ap.add_argument("file")
    ap.add_argument("--profile", choices=PROFILES, default="612")
    ap.add_argument("--stock")
    ap.add_argument("--sysfs-list")
    ap.add_argument("--expect-out")
    a = ap.parse_args(argv)
    try:
        with open(a.file, "rb") as f:
            data = f.read()
    except OSError as e:
        print("ERROR   H1   file: cannot read %s: %s (HM:441-445)" % (a.file, e.strerror))
        return 3
    stock = None
    if a.stock:
        try:
            with open(a.stock, "rb") as f:
                stock = strict_parse(f.read())
        except (OSError, StrictError) as e:
            print("cannot use --stock %s: %s" % (a.stock, e), file=sys.stderr)
            return 64
    sysfs = None
    if a.sysfs_list:
        try:
            sysfs = load_sysfs(a.sysfs_list)
        except OSError as e:
            print("cannot read --sysfs-list %s: %s" % (a.sysfs_list, e.strerror), file=sys.stderr)
            return 64
    res = validate_bytes(data, a.profile, stock, sysfs)
    for f in res.findings:
        print(str(f))
    if res.unparsable:
        print("result: unparsable")
        return 3
    s = res.summary
    if s is not None:
        for line in log_lines(s):
            print("expect: " + line)
        if a.expect_out:
            with open(a.expect_out, "w", encoding="utf-8", newline="\n") as f:
                f.write(expect_text(s))
    print("result: profile=%s errors=%d warnings=%d nodes=%s actions=%s"
          % (a.profile, len(res.errors), len(res.warnings),
             s["nodes"] if s else "-", s["actions"] if s else "-"))
    return 1 if res.errors else 0


if __name__ == "__main__":
    sys.exit(main())
