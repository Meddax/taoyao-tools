#!/usr/bin/env python3
"""Check that every option a defconfig asks for made it into the .config,
and that the device's mandatory options are there.

Usage: cfgcheck.py <defconfig> <.config> [--ignore SYM ...] [--require SYM=VAL ...]
                   [--profile auto|taoyao|none]
       cfgcheck.py --list [taoyao]

make <defconfig> and olddefconfig drop an option without a word when its
dependencies are not met: a missing toolchain (no rustc/bindgen drops
CONFIG_RUST and with it CONFIG_ASHMEM, no pahole drops CONFIG_DEBUG_INFO_BTF
and CONFIG_SCHED_CLASS_EXT), a renamed symbol or a typo. Every
"CONFIG_X=v" line of the defconfig must appear unchanged in the .config,
and every "# CONFIG_X is not set" must stay off.

The mandatory list of a device (PROFILES below) goes further: options the
taoyao ROMs (5.4-era vendor userspace under Android 16) need whether or not
the defconfig names them, each with the reason. One that is on only through
its Kconfig default (DM_USER) is checked in the .config all the same. A
profile is applied automatically (--profile auto, the default) when the
defconfig or the .config has its device symbol (CONFIG_MACH_XIAOMI_TAOYAO=y),
so the redwood build is not held to the taoyao list.

--ignore SYM ...       options CI changes on purpose (LOCALVERSION, KernelSU)
--require SYM=VAL ...  values the .config must have whatever the defconfig
                       says; VAL may list alternatives, y|m
--profile NAME         mandatory list to apply: auto (default), taoyao, none
--list [NAME]          print a mandatory list with the reasons

Symbols may be given with or without the CONFIG_ prefix. Each difference is
printed as a GitHub Actions ::error:: line; the exit status is 1 if there
is any.
"""
import re
import sys

SET = re.compile(r'^(CONFIG_[A-Za-z0-9_]+)=(.*)$')
UNSET = re.compile(r'^# (CONFIG_[A-Za-z0-9_]+) is not set$')

# (symbol, allowed values, reason). "n" = must be off (absent or "is not set").
TAOYAO = [
    # the taoyao gates the port's 5.4-compatible ABI hangs on
    ('MACH_XIAOMI_TAOYAO', 'y', 'taoyao board gate: every taoyao-only UAPI/ABI choice (CONFIG_MACH_XIAOMI_TAOYAO) depends on it'),
    ('TARGET_PRODUCT_TAOYAO', 'y', 'taoyao behaviour of the 5.4 audio drivers (TFA9874, machine driver)'),
    ('AUDIO_QGKI', 'y', '5.4 QGKI audio ABI: QTI compress codec ids up to 0x100B (sound/core/compress_offload.c), the 5.4 HAL mixer controls'),
    ('MI_DISP', 'y', '/dev/mi_display_* (mi_disp.h ioctls) for the Xiaomi display feature HAL'),
    ('XM_BATT_LAYOUT_TAOYAO', 'y', 'taoyao battery/charger sysfs layout the ROMs read'),
    ('TAOYAO_PERF_COMPAT', 'y', 'the msm-5.4 power HAL nodes the unmodified ROM files write (devfreq soc:qcom,cpu-cpu-llcc-bw and soc:qcom,cpu-llcc-ddr-bw, WALT sysctl stubs, /sys/kernel/taoyao/perf_compat) and the bwmon hand-off in bwmon.c: without it libperfmgr fails on 10 nodes again'),
    # memory and IPC the 5.4 vendor libraries use
    ('ION', 'm|y', '5.4 vendor allocates through /dev/ion (libion, gralloc, CamX, codec2): ACK dropped ION, the port carries it'),
    ('ION_MSM_HEAPS', 'm|y', 'the msm ION heaps (system, qsecom, secure display/camera ...) by their msm_ion_ids.h ids'),
    ('DMABUF_HEAPS_SYSTEM', 'n', 'with /dev/dma_heap/system present Codec2 allocates from it instead of ION and video breaks (redwood: Suvkernel a7e4ef9)'),
    ('DMABUF_HEAPS_CMA', 'n', 'same as DMABUF_HEAPS_SYSTEM: the 5.4 vendor must keep allocating through ION'),
    ('ASHMEM', 'y', '/dev/ashmem: the 5.4 vendor libcutils uses it (stock ABI)'),
    ('RUST', 'y', 'android16-6.12 has only the Rust ashmem (and the Rust binder): without RUST, ASHMEM silently goes'),
    ('STAGING', 'y', 'ION and ashmem live in drivers/staging'),
    ('ANDROID_BINDER_IPC', 'y', 'binder'),
    ('ANDROID_BINDERFS', 'y', 'binderfs: init mounts /dev/binderfs on Android 16'),
    ('COMPAT', 'y', '32-bit vendor blobs (armv7 HAL libraries)'),
    ('ARMV8_DEPRECATED', 'y', 'emulation of the deprecated AArch32 instructions some 32-bit blobs still use (stock has it)'),
    ('SWP_EMULATION', 'y', 'AArch32 SWP/SWPB emulation (stock has it)'),
    ('CP15_BARRIER_EMULATION', 'y', 'AArch32 CP15 barrier emulation (stock has it)'),
    ('SETEND_EMULATION', 'y', 'AArch32 SETEND emulation (stock has it)'),
    ('ARM64_4K_PAGES', 'y', '4K pages: the 5.4 vendor binaries and ION assume 4096-byte pages'),
    # cgroups, scheduler and memory pressure (task profiles, lmkd)
    ('MEMCG', 'y', 'memory cgroup (lmkd, task profiles)'),
    ('MEMCG_V1', 'y', 'cgroups.json of these ROMs mounts the v1 memcg controller (/dev/memcg)'),
    ('CPUSETS', 'y', 'cpusets'),
    ('CPUSETS_V1', 'y', '/dev/cpuset (v1): init and the vendor init scripts write /dev/cpuset/*/cpus'),
    ('CGROUP_FREEZER', 'y', 'cgroup freezer for the app freezer (task profiles Frozen/Unfrozen)'),
    ('UCLAMP_TASK', 'y', 'uclamp (task profiles)'),
    ('UCLAMP_TASK_GROUP', 'y', 'cpu.uclamp.* in the cgroups the task profiles write'),
    ('PSI', 'y', 'lmkd watches memory pressure through PSI'),
    # boot, OTA, storage encryption, firmware
    ('IKCONFIG', 'y', 'in-kernel config'),
    ('IKCONFIG_PROC', 'y', '/proc/config.gz, read by VTS-style checks and the ROM scripts'),
    ('FW_LOADER_USER_HELPER', 'y', 'firmware fallback through ueventd (vendor firmware not in /vendor/firmware_mnt)'),
    ('DM_USER', 'y', 'dm-user for snapuserd (Virtual A/B OTA); on only through its Kconfig default, the defconfig does not name it'),
    ('DM_DEFAULT_KEY', 'y', 'metadata encryption of /data (dm-default-key)'),
    ('BLK_INLINE_ENCRYPTION', 'y', 'file-based encryption through the UFS ICE'),
    ('QTI_HW_KEY_MANAGER_V1', 'm|y', 'ICE hardware key manager used for the inline-encryption keys (stock: QTI_HW_KEY_MANAGER=y)'),
    # modem, data, QMI
    ('QRTR', 'm|y', 'QRTR: every QMI client (FastRPC, PDR, sysmon, IPA, WLAN fw service); stock =y'),
    ('QRTR_SMD', 'm|y', 'QRTR over GLINK/SMD to the remote processors'),
    ('TIPC', 'm|y', 'qcrild needs TIPC (Suvkernel: the signed GKI tipc module); stock =y'),
    ('UIO_MSM_SHAREDMEM', 'm|y', '/dev/uio* for rmt_storage / tftp_server (modem EFS); stock =y'),
    ('IPA3', 'm|y', 'IPA (ipacm, tethering, data path); stock =y'),
    ('RMNET_CORE', 'm|y', 'rmnet data devices (otherwise data calls fail with OEM_DCFAILCAUSE_4)'),
    # netd and BPF
    ('CGROUP_BPF', 'y', 'netd attaches its cgroup BPF programs'),
    ('BPF_JIT', 'y', 'BPF JIT (netd, bpfloader)'),
    ('NETFILTER_XT_MATCH_BPF', 'y', 'xt_bpf match used by netd'),
    ('DEBUG_INFO_BTF', 'y', 'the base ships BTF for the Android BPF programs; SCHED_CLASS_EXT depends on it'),
    # device nodes and vendor UAPI providers (uapicheck checks their ABI)
    ('I2C_CHARDEV', 'y', '/dev/i2c-* (stock has it)'),
    ('SPI_SPIDEV', 'y', '/dev/spidev* (stock has it)'),
    ('USB_CONFIGFS_F_FS', 'y', 'adb and MTP through FunctionFS'),
    ('QSEECOM', 'm|y', '/dev/qseecom: qseecomd, keymaster/gatekeeper TAs'),
    ('CRYPTO_DEV_QCEDEV', 'm|y', '/dev/qce (qcedev)'),
    ('MSM_ADSPRPC', 'm|y', '/dev/adsprpc-smd: FastRPC for audio, sensors and the camera (SNPE)'),
    ('QCOM_KGSL', 'm|y', '/dev/kgsl-3d0: the Adreno driver of the 5.4 GPU blobs'),
]
PROFILES = {'taoyao': ('CONFIG_MACH_XIAOMI_TAOYAO', TAOYAO)}


def sym(s):
    return s if s.startswith('CONFIG_') else 'CONFIG_' + s


def parse(path):
    """{symbol: value}, 'n' for "is not set"; a later line wins, as in kconfig."""
    vals = {}
    with open(path) as f:
        for line in f:
            line = line.strip()
            m = SET.match(line)
            if m:
                vals[m.group(1)] = m.group(2)
                continue
            m = UNSET.match(line)
            if m:
                vals[m.group(1)] = 'n'
    return vals


def show(k, v):
    return 'absent' if v == 'n' else f'{k}={v}'


def list_profile(name):
    if name not in PROFILES:
        sys.exit(f'no profile {name!r} (have: {", ".join(PROFILES)})')
    gate, entries = PROFILES[name]
    print(f'# mandatory options of {name} (applied when the .config has {gate}=y)')
    for s, vals, why in entries:
        print(f'CONFIG_{s}={vals}\t# {why}')
    return 0


def main():
    args = sys.argv[1:]
    if args and args[0] == '--list':
        return list_profile(args[1] if len(args) > 1 else 'taoyao')
    ignore, require, files, mode, profile = set(), {}, [], None, 'auto'
    for a in args:
        if a in ('--ignore', '--require', '--profile'):
            mode = a
        elif mode == '--ignore':
            ignore.add(sym(a))
        elif mode == '--require':
            if '=' not in a:
                sys.exit(f'--require needs SYM=VAL, got {a!r}')
            k, v = a.split('=', 1)
            require[sym(k)] = (v, 'required on the command line')
        elif mode == '--profile':
            profile, mode = a, None
        else:
            files.append(a)
    if len(files) != 2:
        sys.exit(__doc__)
    want, got = parse(files[0]), parse(files[1])

    if profile == 'auto':
        # the defconfig counts too: a gate symbol that olddefconfig dropped
        # must not switch the device's mandatory list off
        profile = next((n for n, (gate, _) in PROFILES.items()
                        if 'y' in (got.get(gate), want.get(gate))), 'none')
    if profile != 'none' and profile not in PROFILES:
        sys.exit(f'no profile {profile!r} (have: {", ".join(PROFILES)}, auto, none)')
    mandatory = {}
    if profile != 'none':
        for s, vals, why in PROFILES[profile][1]:
            mandatory[sym(s)] = (vals, why)
    # a value given with --require wins over the profile's
    mandatory.update(require)

    bad = []
    # the profile only adds checks: a defconfig option it also lists must
    # still come out exactly as the defconfig says (QRTR=y demoted to =m by
    # olddefconfig is an error even though the profile accepts m|y); only
    # --require overrides the defconfig's value
    ndef = 0
    for k, v in want.items():
        if k in ignore or k in require:
            continue
        ndef += 1
        g = got.get(k, 'n')
        if v == 'n':
            if g != 'n':
                bad.append(f'{k} is not set in the defconfig but {k}={g} in .config')
        elif g != v:
            bad.append(f'defconfig option lost: {k}={v} ({show(k, g)} in .config)')
    nman = 0
    for k, (vals, why) in mandatory.items():
        if k in ignore:
            continue
        nman += 1
        g = got.get(k, 'n')
        if g not in vals.split('|'):
            if vals == 'n':
                bad.append(f'{k} must be off ({k}={g} in .config): {why}')
            else:
                bad.append(f'required option missing: {k}={vals} ({show(k, g)} in .config): {why}')

    for b in bad:
        print(f'::error::{b}')
    checked = len(set(k for k in want if k not in ignore) | set(k for k in mandatory if k not in ignore))
    what = f'{ndef} defconfig options, ' \
           f'{nman} mandatory ({profile if profile != "none" else "no device profile"}' \
           f'{" + --require" if require else ""})'
    if bad:
        print(f'{len(bad)} of {checked} checked options are wrong in .config ({what})')
        return 1
    print(f'all {checked} checked options are in .config ({what})'
          + (f'; not checked, changed by CI: {" ".join(sorted(ignore))}' if ignore else ''))
    return 0


if __name__ == '__main__':
    sys.exit(main())
