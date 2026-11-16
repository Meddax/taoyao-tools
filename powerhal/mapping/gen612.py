#!/usr/bin/env python3
# Builds a 6.12 draft of the ROM powerhint.json from the mapping decisions
# and checks it against the libperfmgr parse rules (HintManager.cc ParseNodes/
# ParseActions): unique node names, unique paths, unique non-empty values,
# DefaultIndex in range, every action's Node and Value defined.
import json, sys, collections

src, out = sys.argv[1], sys.argv[2]
d = json.load(open(src))

DROP = {"SchedPreferSpread", "SchedBusyHystNs", "SchedBusyHystEnableCPUs",
        "SchedMinTaskUtilForBoost", "SchedMinTaskUtilForColoc"}
LLCC = "/sys/devices/system/cpu/bus_dcvs/LLCC"
DDR = "/sys/devices/system/cpu/bus_dcvs/DDR"
BW = LLCC + "/90b6400.qcom,bwmon-llcc"

# name -> (new name, new path, value map old->new or None, extra keys)
REMAP = {
    "CPUBWHystTriggerCount": ("CPUBWHystTriggerCount", BW + "/hyst_trigger_count", None, {"AllowFailure": True}),
    "CPUBWHistMemory": ("CPUBWHistMemory", BW + "/hist_memory", None, {"AllowFailure": True}),
    "CPUBWHystLength": ("CPUBWHystLength", BW + "/hyst_length", None, {"AllowFailure": True}),
    "CPUBWMinFreq": ("LLCCBoostFreq", LLCC + "/boost_freq",
                     {"12298": "806000", "9155": "600000", "4577": "150000"}, {"AllowFailure": True}),
    "LLCCBWMinFreq": ("DDRBoostFreq", DDR + "/boost_freq",
                      {"6515": "1708000", "3879": "1017000", "762": "200000"}, {"AllowFailure": True}),
    # kgsl: 6.12 takes only exact pwrlevel frequencies (550/450/315 MHz)
    "GPUMaxFreq": ("GPUMaxFreq", "/sys/class/kgsl/kgsl-3d0/devfreq/max_freq",
                   {"840000000": "550000000", "443000000": "450000000", "540000000": None}, {}),
    "GPUMinFreq": ("GPUMinFreq", "/sys/class/kgsl/kgsl-3d0/devfreq/min_freq",
                   {"540000000": "550000000", "379000000": "450000000", "315000000": "315000000"}, {}),
    # cpufreq caps: 6.12 floors policy->max to the table, 5.4 picked the next OPP up
    "CPULittleClusterMaxFreq": (None, None, {"1612800": "1651200"}, {}),
    "CPUBigClusterMaxFreq": (None, None, {"1324800": "1344000"}, {}),
    "CPUBigPlusClusterMaxFreq": (None, None, {"1555200": "1766400"}, {}),
}

renamed = {}
vmap = {}
nodes = []
for n in d["Nodes"]:
    name = n["Name"]
    if name in DROP:
        continue
    path = n.get("Path") or n["Paths"][0]
    nn = collections.OrderedDict()
    newname, newpath, m, extra = REMAP.get(name, (None, None, None, {}))
    newname = newname or name
    renamed[name] = newname
    nn["Name"] = newname
    nn["Paths"] = [newpath or path]
    vals = []
    for v in n["Values"]:
        nv = v if m is None or v not in m else m[v]
        if nv is None:
            continue
        vmap[(name, v)] = nv
        vals.append(nv)
    nn["Values"] = vals
    if "DefaultIndex" in n:
        nn["DefaultIndex"] = n["DefaultIndex"]
    for k in ("ResetOnInit", "Type", "HoldFd", "WriteOnly", "Truncate"):
        if k in n:
            nn[k] = n[k]
    nn.update(extra)
    nodes.append(nn)

actions = []
for a in d["Actions"]:
    if a["Node"] in DROP:
        continue
    if (a["Node"], a["Value"]) not in vmap:
        # GPUMaxFreq 540000000 (SUSTAINED_PERFORMANCE): no cap on 5.4 (kgsl
        # rounded it up to 550 MHz) -> dropped for parity
        print("dropped action:", a["PowerHint"], a["Node"], a["Value"], file=sys.stderr)
        continue
    na = collections.OrderedDict(a)
    na["Node"] = renamed[a["Node"]]
    na["Value"] = vmap[(a["Node"], a["Value"])]
    actions.append(na)

doc = collections.OrderedDict([("Nodes", nodes), ("Actions", actions)])
json.dump(doc, open(out, "w"), indent=2, ensure_ascii=False)
open(out, "a").write("\n")

# libperfmgr rule check
err = 0
names, paths = set(), set()
for i, n in enumerate(nodes):
    if n["Name"] in names: print("dup name", n["Name"]); err += 1
    names.add(n["Name"])
    for p in n["Paths"]:
        if p in paths: print("dup path", p); err += 1
        paths.add(p)
    is_file = n.get("Type", "File") == "File"
    if len(set(n["Values"])) != len(n["Values"]): print("dup value", n["Name"]); err += 1
    if is_file and any(v == "" for v in n["Values"]): print("empty value", n["Name"]); err += 1
    di = n.get("DefaultIndex", len(n["Values"]) - 1)
    if di > len(n["Values"]) - 1: print("DefaultIndex", n["Name"]); err += 1
byname = {n["Name"]: n for n in nodes}
for a in actions:
    if a["Node"] not in byname: print("action node missing", a); err += 1; continue
    if a["Value"] not in byname[a["Node"]]["Values"]: print("action value missing", a); err += 1
    if not isinstance(a.get("Duration"), int): print("duration", a); err += 1
print("nodes", len(nodes), "actions", len(actions), "errors", err)
for n in nodes:
    di = n.get("DefaultIndex", len(n["Values"]) - 1)
    print("%-32s default=%-12s %s" % (n["Name"], n["Values"][di] if n["Values"] else "-", n["Paths"][0]))
sys.exit(1 if err else 0)
