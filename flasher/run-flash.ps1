# Флешер ядра MeruDevTools для Xiaomi Mi 12 Lite (taoyao), версия 1.2
# SPDX-License-Identifier: LicenseRef-MeruDevTools
# © 2026 Meddax (meru_ii) и команда MeruDevTools. Лицензия: LICENSE-flash.txt
#
# Windows part, started by run-flash.bat (Windows PowerShell 5.1; also runs
# under PowerShell 7). run-flash.sh does the same on Linux and macOS; both
# scripts have the same structure, messages, flow and exit codes.
#
# What it does: finds the kernel zip next to it (taoyao-<series>-v<ver>.zip,
# any version), checks it, finds the phone over adb and installs the zip
# with the zip's own installer, in one of two ways chosen by itself:
#   (A) from the booted system with root for adb (su -c id gives uid=0): the
#       zip's update-binary runs on the phone under su, detached from adb;
#   (B) from recovery with adb sideload: two passes in LineageOS-based
#       recoveries (step 1 = copy of the slot only, step 2 = write), one pass
#       in TWRP / OrangeFox with decrypted /data.
# Before anything is written, the copy of the slot (boot, vendor_boot, dtbo
# and the installer's restore zip) is pulled to the PC and verified; the
# phone's stock images are kept in taoyao-stock-images, which this script
# never changes or deletes. It never runs fastboot and never writes a
# partition itself; it only reads them (sha256) in recovery or under su.
#
# adb runs through System.Diagnostics.Process with our own Windows argument
# quoting (PowerShell 5.1 does not escape quotes for native commands). Local
# files are relative names in the process working directory, so the folder
# may hold spaces, & ( ) [ ] % ! and Cyrillic letters. Commands sent to the
# phone hold no single quote except the su -c '...' wrapper.
#
# Exit codes: 0 done and confirmed; 10 stopped, nothing written; 11 cancelled
# by the user; 12 the installer wrote and put the original images back (the
# slot is as before); 13 attention: the slot may be damaged or its state is
# not confirmed (the screen says what to do).
#Requires -Version 5.1
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

########################################################################
# THE CONSTANTS TABLE. The same names, in the same order, in run-flash.sh.
# A future installer or recovery change is a one-line edit here. Values
# marked "from the zip" are defaults, replaced at run time by what the chosen
# kernel zip's tools/ty-lib.sh says (Read-ZipValues).
# Regular expressions: POSIX ERE that .NET accepts unchanged.
# --- the flasher -------------------------------------------------------
$Script:BRAND = 'Флешер ядра MeruDevTools для Xiaomi Mi 12 Lite (taoyao)'
$Script:VER = '1.2'
$Script:DEVICE = 'taoyao'
# space-separated: a kernel release <series>.* in this list is "a build of
# this port"; anything else is the ROM's own kernel (stock)
$Script:PORT_SERIES = '6.12'
# --- kernel zip names (matched on the lower-cased name) ----------------
# groups: 1 series, 2 major, 3 minor, 5 patch (optional), 6 -noksu, 8 browser copy number
$Script:ZIP_RE = '^taoyao-([0-9]+\.[0-9]+)-v([0-9]+)\.([0-9]+)(\.([0-9]+))?(-noksu)?( ?\(([0-9]+)\))?\.zip$'
$Script:ZIP_NEAR_RE = '^taoyao.*\.zip$'                  # look-alikes reported when nothing matches ZIP_RE
$Script:ZIP_SKIP_RE = '^taoyao-(logs|flash|restore)-'    # our other zips: never kernel candidates
$Script:REL_RE = '^([0-9]+\.[0-9]+)\.[0-9]+-taoyao-v([0-9]+(\.[0-9]+)+)$'   # vmods/kernel.release
$Script:VERFILE_RE = '^version ([0-9]+(\.[0-9]+)+),'     # a line of the zip's "version" file (mk-ak3.sh --number)
$Script:VERLINE1_RE = '^Linux ([^,]+), KernelSU: ([^,]+),'   # first line of "version"
$Script:KSU_NONE = 'noksu'
$Script:ZIP_NEED = @('META-INF/com/google/android/update-binary', 'anykernel.sh', 'tools/ak3-core.sh', 'tools/ty-lib.sh',
  'vmods/kernel.release', 'vmods/modules.load', 'version', 'Image', 'dtb', 'dtbo.img',
  'restore/update-binary', 'restore/restore.sh')
$Script:UB_MARK = 'AnyKernel3'                           # must occur in META-INF/.../update-binary
$Script:AK_DEVICE_RE = '^device\.name1=taoyao$'          # a line of anykernel.sh
$Script:AK_CHECK_RE = '^do\.devicecheck=1$'
$Script:GEN2_MARK = 'taoyao-result'                      # tools/ty-lib.sh of a zip that writes the result lines
$Script:GEN3_MARK = 'taoyao-run'                         # ... and a run id as the first taoyao- line of each pass
# --- installer: paths (from the zip: tools/ty-lib.sh) ------------------
$Script:BACKUP_NAME = 'taoyao-6.12-backup'               # ty-lib.sh: ^TY_BACKUPNAME=(.*);$
$Script:STORES = '/sdcard /storage/emulated/0 /data/media/0'   # ty-lib.sh: ^TY_STORES="(.*)";$
$Script:LAST_LOG = 'taoyao-6.12-last.log'                # ty-lib.sh: /(taoyao-[A-Za-z0-9.]+-last\.log)
$Script:RLOG_NAME = 'taoyao-restore-last.log'            # restore/restore.sh: ${W%/*}/taoyao-restore-last.log
$Script:REC_TMP = '/tmp'
$Script:REC_AKHOME = '/tmp/anykernel'                    # update-binary: $POSTINSTALL/tmp/anykernel
$Script:REC_LOG = '/tmp/recovery.log'                    # diagnosis only
$Script:PH_WORK = '/data/local/tmp/taoyao-flash'         # (A): our work dir; AKHOME=$PH_WORK/ak, TY_RESTORE_TMP=$PH_WORK
$Script:BAKDIR_RE = '^[0-9]{8}-[0-9]{6}(-[0-9]+)?(_[ab])$'   # ty_keep: <stamp><slot>, <stamp>-<n><slot>
$Script:INSTLOG_RE = '^install-([0-9]{8}-[0-9]{6})\.log$'
$Script:PSTORE_RE = '^pstore-[0-9]{8}-[0-9]{6}$'
$Script:RZIP_FMT = 'taoyao-restore-{dir}.zip'            # its checksum: {zip}.sha256 ("<hex>  <name>")
# --- installer: result lines (taoyao-result interface, 75b0c4d+) -------
$Script:RES_PREFIX = 'taoyao-result: '                   # values below; the LAST such line of a log counts
$Script:RES_STEP1 = 'step1'
$Script:RES_DONE = 'done'
$Script:RES_CLEAN = 'abort-clean'
$Script:RES_RESTORED = 'abort-restored'
$Script:RES_DIRTY = 'abort-dirty'
$Script:RES_RZ_OK = 'restored'                           # restore zip (in RLOG_NAME)
$Script:RES_RZ_FAIL = 'restore-failed'
$Script:KEY_BACKUP = 'taoyao-backup: '
$Script:KEY_SLOT = 'taoyao-slot: '
$Script:KEY_KERNEL = 'taoyao-kernel: '
$Script:KEY_RUN = 'taoyao-run: '                         # <stamp>-<pid>: a log without a new run id is not this pass's
# --- installer: English text markers (fallback for the 0.18 installer) --
$Script:TXT_STEP1 = 'NOT INSTALLED YET - step 1 of 2'
$Script:TXT_DONE_RE = '^Done: boot(_[ab]), vendor_boot_[ab] and dtbo_[ab] written and read back\.$'
$Script:TXT_BACKUP_RE = '^- Backup of slot (_[ab])( \(already there\))?: (/.+)$'
$Script:TXT_RELEASE_RE = 'modules into lib/modules/([^, ]+),'   # the release this run installs (both generations)
$Script:TXT_ROLLBACK = '- Writing the original images back to slot'
$Script:TXT_ROLLED = 'is as it was before this zip.'
$Script:TXT_DIRTY_RE = 'IS NOW HALF [0-9.]+ AND WILL NOT BOOT'
# installer notes not repeated on the PC: what they ask for (the copy to the
# PC) the flasher does itself
$Script:NOTE_SKIP_RE = 'backup is only in RAM|PC: adb pull|Copy them to the PC|phone: Advanced > Enable ADB'
$Script:TXT_RAMNOTE_RE = '^!! The backup is only in RAM: (/\S+)'   # its "copy it now" block: lines starting with !!
$Script:TXT_ABORTING = 'Aborting...'
$Script:TXT_NOTHING = 'Nothing was written'
$Script:TXT_AK3_DEV = 'Unsupported device. Aborting...'
$Script:TXT_AK3_UNZIP = 'Unzip failed. Aborting...'
$Script:TXT_AK3_BB = 'Busybox setup failed. Aborting...'
$Script:TXT_RZ_HEAD_RE = '^Taoyao [0-9.]+ port: RESTORE slot (_[ab])$'
$Script:TXT_RZ_OK = 'holds the saved images again (sha256 read back)'
$Script:TXT_RZ_NOOP = 'already holds the saved images. Nothing to do.'
$Script:TXT_RZ_FAIL = '!! Could not write:'
# installer notes repeated on the PC besides lines starting with "!" and
# warnings: the IPA lines (the ROM the installer saw, the hint of the
# taoyao-ipa-stock file); NOTE_IPA_RE: the ROM was not recognised
$Script:NOTE_RE = 'IPA UAPI|IPA:|taoyao-ipa-|HyperOS|not recognised|/sdcard and flash again'
$Script:NOTE_IPA_RE = 'taoyao-ipa-stock|IPA: (the )?ROM (was )?not recognised'
# --- PC folders (next to the script, or the fallback base) -------------
$Script:PC_LOG = 'run-flash.log'
$Script:PC_LOG_OLD = 'run-flash.old.log'                 # rotation at 5 MB
$Script:PC_LOCK = 'run-flash.lock'
$Script:PC_STOCK = 'taoyao-stock-images'
$Script:PC_PREV_FMT = 'taoyao-{series}-backups'          # {series} of the saved kernel, e.g. taoyao-6.12-backups
$Script:PC_PULL_FMT = '{BACKUP_NAME}-{yyyyMMdd-HHmmss}'  # this run's raw pull folder
# --- limits and timeouts (seconds) --------------------------------------
$Script:T_POLL = 2            # adb devices while waiting; 1 while waiting for "sideload"
$Script:T_HINT = 30           # repeat the hint (and the bell) this often
$Script:T_DEVICE = 180        # first wait for any phone (then Enter: wait more)
$Script:T_SIDELOAD_UP = 90    # after "adb reboot sideload": time for the "sideload" state
$Script:T_USER = 600          # waits for a tap on the phone (Enable ADB, Apply from ADB, unlock)
$Script:T_REC_BACK = 20       # after a sideload: time for "recovery" to come back by itself before the hint
$Script:T_SU = 30             # one "su -c id" try (3 tries)
$Script:T_STALL = 300         # sideload: no progress change for this long = failed (covers "Install anyway?")
$Script:T_INSTALL_A = 900     # (A) whole installer run; 180 without new output = warning line
$Script:T_PULL = 900          # one adb pull
$Script:T_HASH = 180          # sha256 of the three partitions on the phone
$Script:T_BOOT = 300          # after "adb reboot": wait for the booted system
$Script:T_REBOOT_AGAIN = 20   # after "adb reboot <target>": still booted this long = "adb reboot recovery" once more
$Script:T_REBOOT_FAIL = 60    # ... and this long = the phone does not reboot (stop)
$Script:T_LEAVE = 60          # after "adb reboot": time for the phone to leave before the boot wait
$Script:T_SVC = 30            # after "svc power reboot" (Android's own reboot): time to leave before "adb reboot"
$Script:T_UNAUTH_WAIT = 60    # "unauthorized" this long in a wait for recovery = that recovery refuses this PC
$Script:T_OFFLINE_WAIT = 20   # "offline" this long: one "adb reconnect offline"
# (run-flash.sh: T_UNAUTH, T_OFFLINE; PowerShell names ignore case, and
# $T_Unauth / $T_Offline are messages here)
$Script:T_TWRP_SL = 20        # TWRP / OrangeFox: after "twrp sideload", time for the "sideload" state (then the hint)
$Script:MAX_PULLS = 3         # pulls of one backup dir when the cable drops (each after the phone is back)
$Script:MAX_TRIES = 3         # transfers of one pass
$Script:MAX_ROUNDS = 2        # step-2 passes that come back as "step 1"
$Script:BAT_WARN = 30         # %: below = warning + yes
$Script:BAT_STOP = 15         # %: below = stop
$Script:DATA_NEED_MB = 1500   # (A): free space in /data for the run (work dir + copy on /sdcard)
$Script:STORE_NEED_MB = 400   # recovery: free space a store needs for the copy (less: the installer keeps it in RAM)
# --- phone command templates (section 6 of the design) -----------------
# Placeholders: {BN} BACKUP_NAME, {LAST} LAST_LOG, {RLOG} RLOG_NAME, {W}
# PH_WORK, {SLOT} slot, {DIR} a backup dir, {ROOT} a backup root, {FILE} a
# file, {STORE_GLOBS} "<store>/{BN}/*" for every STORES entry, {STORES} the
# STORES list, {OFF}/{OFF1} byte offsets, {KIND} kernel|restore, {ZIP} the
# zip's name in {W}. Output is key=value lines ending with end=1; a probe
# without end=1 failed. P_REC's store=<store>:<df line> lines: the stores
# the installer's ty_persistent + ty_keep would take (readlink -f, the file
# system of the longest mount point not rootfs/tmpfs/ramfs, a test mkdir);
# with one of them (and room) the installer copies there and writes at once.
$Script:P_ANDROID = 'set -f; for p in ro.product.device ro.build.product ro.product.vendor.device ro.vendor.product.device ro.boot.hwname ro.product.model ro.build.fingerprint ro.build.display.id ro.build.version.release ro.boot.slot_suffix ro.boot.flash.locked ro.boot.verifiedbootstate ro.boot.vbmeta.device_state sys.boot_completed sys.user.0.ce_available ro.mi.os.version.name ro.miui.ui.version.name ro.lineage.version ro.modversion ro.crdroid.version ro.evolution.version ro.build.date.utc ro.evolution.build.version ro.crdroid.build.version ro.lineage.build.version ro.mi.os.version.incremental; do echo $p=$(getprop $p); done; u=$(grep -m 1 "^ro.build.date.utc=" /system/build.prop 2>/dev/null); echo romutc=${u#*=}; echo kr=$(uname -r); echo bat=$(dumpsys battery 2>/dev/null | grep -m 1 level: | tr -dc 0-9); echo dfdata=$(df -k /data 2>/dev/null | tail -n 1); [ -d /sdcard/Android ] && echo sd=1; echo now=$(date +%s); echo end=1'
$Script:P_SU_ID = 'su -c id'
# P_ROOT runs under su (Invoke-Dev adds the su -c wrapper)
$Script:P_ROOT = 'set -f; grep -E "^androidboot[.](verifiedbootstate|vbmeta[.]device_state|slot_suffix) " /proc/bootconfig 2>/dev/null | sed -e "s/^androidboot[.]/bc./" -e "s/ = /=/" -e "s/\"//g"; for t in $(cat /proc/cmdline 2>/dev/null); do case $t in androidboot.verifiedbootstate=*|androidboot.vbmeta.device_state=*|androidboot.slot_suffix=*) echo cl.${t#androidboot.};; esac; done; echo dfwork=$(df -k /data/local/tmp 2>/dev/null | tail -n 1); p=$(cat {W}/rf.pid 2>/dev/null); [ -n "$p" ] && kill -0 $p 2>/dev/null && echo rfrun=$p; [ -f {W}/ub.rc ] && echo ubrc=$(cat {W}/ub.rc); [ -f {W}/ub.out ] && echo ubout=1; echo end=1'
$Script:P_REC = 'set -f; echo uid=$(id -u); for p in ro.product.device ro.build.product ro.product.vendor.device ro.vendor.product.device ro.boot.hwname ro.boot.slot_suffix ro.debuggable ro.build.type ro.build.fingerprint ro.lineage.version ro.modversion ro.crdroid.version ro.evolution.version ro.twrp.version ro.build.date.utc; do echo $p=$(getprop $p); done; [ -e /twres ] && echo twrp=1; echo kr=$(uname -r); echo bat=$(cat /sys/class/power_supply/battery/capacity 2>/dev/null); grep -E "^androidboot[.](verifiedbootstate|vbmeta[.]device_state|slot_suffix) " /proc/bootconfig 2>/dev/null | sed -e "s/^androidboot[.]/bc./" -e "s/ = /=/" -e "s/\"//g"; for t in $(cat /proc/cmdline 2>/dev/null); do case $t in androidboot.verifiedbootstate=*|androidboot.vbmeta.device_state=*|androidboot.slot_suffix=*) echo cl.${t#androidboot.};; esac; done; grep -q " /data " /proc/mounts && echo datamnt=1; [ -d /sdcard/Android ] && echo sdandroid=1; ( : > /sdcard/.run-flash-probe ) 2>/dev/null && rm -f /sdcard/.run-flash-probe && echo sdw=1; for s in {STORES}; do q=$(readlink -f $s 2>/dev/null); [ -n "$q" ] && [ -d "$q" ] || continue; b=/; f=rootfs; while read -r x m t y; do case "$q/" in "$m"/*) [ ${#m} -ge ${#b} ] && b=$m && f=$t;; esac; done < /proc/mounts; case $f in rootfs|tmpfs|ramfs) continue;; esac; [ "$b" != / ] || continue; mkdir $q/.run-flash-probe 2>/dev/null && rmdir $q/.run-flash-probe && echo store=$s:$(df -k $q 2>/dev/null | tail -n 1); done; echo storeprobe=1; echo dftmp=$(df -k /tmp 2>/dev/null | tail -n 1); [ -d /tmp/anykernel ] && echo akhome=$(stat -c %Y /tmp/anykernel 2>/dev/null); set +f; for d in /tmp/{BN}/* {STORE_GLOBS}; do [ -f $d/SHA256SUMS ] && echo bak=$(readlink -f $d); done; for f in /tmp/{LAST} /tmp/anykernel/install.log /tmp/{RLOG}; do [ -f $f ] && echo log=$(stat -c %Y $f 2>/dev/null):$f; done; echo now=$(date +%s); echo end=1'
# P_HASH: in recovery as it is, in Android under su
$Script:P_HASH = 'set -f; for p in boot vendor_boot dtbo; do b=; for d in /dev/block/bootdevice/by-name /dev/block/by-name; do [ -e $d/${p}{SLOT} ] && { b=$d/${p}{SLOT}; break; }; done; if [ -n "$b" ]; then echo h_$p=$(sha256sum $b 2>/dev/null | cut -d" " -f1); else echo h_$p=; fi; done; echo end=1'
$Script:P_LISTDIR = 'set -f; cd {DIR} 2>/dev/null || { echo nodir=1; echo end=1; exit 0; }; set +f; for f in *; do [ -f "$f" ] && echo F=$(stat -c %s "$f" 2>/dev/null):$(stat -c %Y "$f" 2>/dev/null):$f; done; echo =SUMS; cat SHA256SUMS 2>/dev/null; echo =INFO; cat info.txt 2>/dev/null; echo =END; echo end=1'
$Script:P_LISTROOT = 'set +f; for d in {ROOT}/*; do [ -d $d ] && echo D=${d##*/}; done; echo end=1'
$Script:P_CAT = 'cat {FILE}'
$Script:P_RECLOG = 'grep -E "Unsupported device|Unzip failed|Busybox setup failed|Aborting" /tmp/recovery.log 2>/dev/null | tail -n 5'
$Script:P_TWRP_SIDELOAD = 'twrp sideload'
$Script:P_KRS = 'echo kr=$(uname -r); echo bc=$(getprop sys.boot_completed); echo sl=$(getprop ro.boot.slot_suffix); echo end=1'
# root managers that hide su from adb until Shell is granted (package names);
# only the matching names leave the phone
$Script:ROOTMGR_RE = 'kernelsu|sukisu|ksunext|apatch|magisk'
$Script:P_PM = 'pm list packages 2>/dev/null | grep -iE "{RE}"; echo end=1'
# (A) only: work dir, start, poll (no su: the files are 644 in a shell-owned
# dir), clean up (under su: the runner's files are root's)
$Script:P_A_PREP = 'mkdir -p {W}/bb && echo end=1'
$Script:P_A_SUMS = 'cd {W} && sha256sum {ZIP} update-binary bb/busybox rf-run.sh; echo end=1'
$Script:P_A_START = 'sh {W}/rf-run.sh {KIND} {ZIP}'
$Script:P_A_POLL = 'cd {W} 2>/dev/null || { echo RF_POLL nowork; exit 0; }; s=$(wc -c < ub.out 2>/dev/null); echo RF_POLL rc=$(cat ub.rc 2>/dev/null) sz=$s; [ -n "$s" ] && [ "$s" -gt {OFF} ] && tail -c +{OFF1} ub.out 2>/dev/null | head -c $((s - {OFF}))'
$Script:P_A_CLEAN = 'cd {W} 2>/dev/null && rm -f kernel.zip restore.zip update-binary rf-run.sh ub.out ub.err ub.rc ub.rc.tmp rf.pid bb/busybox bb/bin/unzip; echo end=1'
$Script:P_A_PULLCOPY = 'mkdir -p {W}/pull/{NAME} && cp -f {DIR}/* {W}/pull/{NAME}/ && chmod -R a+rX {W}/pull && echo end=1'
$Script:P_A_PULLCLEAN = 'rm -rf {W}/pull; echo end=1'
# (A) copy only (after the system route from a recovery whose ADB has no
# root): the slot's three partitions read (never written) into {W}/pull/{NAME},
# with SHA256SUMS and info.txt as the installer writes them
$Script:P_A_BACKUP = 'set -f; d={W}/pull/{NAME}; rm -rf {W}/pull; mkdir -p $d || exit 1; for p in boot vendor_boot dtbo; do b=; for x in /dev/block/bootdevice/by-name /dev/block/by-name; do [ -e $x/${p}{SLOT} ] && { b=$x/${p}{SLOT}; break; }; done; [ -n "$b" ] || { echo nopart=$p; exit 1; }; cat $b > $d/$p.img || exit 1; done; cd $d || exit 1; sha256sum boot.img vendor_boot.img dtbo.img > SHA256SUMS || exit 1; { echo slot={SLOT}; echo kernel=$(uname -r); echo "date=$(date -u "+%Y-%m-%d %H:%M:%S") UTC"; echo fingerprint=$(getprop ro.build.fingerprint); u=$(grep -m 1 "^ro.build.date.utc=" /system/build.prop 2>/dev/null); u=${u#*=}; f=file; [ -n "$u" ] || { u=$(getprop ro.build.date.utc); f=getprop; }; [ -n "$u" ] || f=; echo rom_build_utc=$u; v=$(grep -m 1 "^ro.build.date=" /system/build.prop 2>/dev/null); echo "rom_build_date=${v#*=}"; v=$(grep -m 1 "^ro.build.version.incremental=" /system/build.prop 2>/dev/null); echo "rom_build_inc=${v#*=}"; v=; for p in ro.evolution.build.version ro.crdroid.build.version ro.lineage.version ro.lineage.build.version ro.modversion ro.mi.os.version.incremental; do [ -n "$v" ] || v=$(getprop $p); done; echo "rom_version=$v"; echo rom_build_from=$f; echo boot_ramdisk=; echo replaced_by=none; } > info.txt || exit 1; chmod -R a+rX {W}/pull && echo COPIED'
# rf-run.sh, the phone side of (A): pushed as a file (LF line ends, UTF-8
# without BOM). It starts the installer detached from adb, so a pulled
# cable, a closed window or Ctrl+C on the PC never stop it half-way.
# OUTFD 1 is a regular file opened for append: ui_print re-opens
# /proc/self/fd/1, which fails for adb's socket.
$Script:RF_RUN = @(
  '# Флешер ядра MeruDevTools 1.2, часть для телефона: запускает установщик'
  '# отдельно от adb, чтобы выдернутый кабель не остановил его на середине.'
  '# SPDX-License-Identifier: LicenseRef-MeruDevTools'
  '# © 2026 Meddax (meru_ii) и команда MeruDevTools. Лицензия: LICENSE-flash.txt'
  '# sh rf-run.sh kernel|restore <zip в рабочей папке>'
  'W=/data/local/tmp/taoyao-flash'
  'cd "$W" || { echo RF_NOWORK; exit 3; }'
  'umask 022'
  'p=$(cat rf.pid 2>/dev/null)'
  'if [ -n "$p" ] && kill -0 "$p" 2>/dev/null && [ ! -f ub.rc ]; then echo "RF_BUSY $p"; exit 4; fi'
  'case $1 in'
  '  kernel) export AKHOME="$W/ak";;'
  '  restore) export TY_RESTORE_TMP="$W";;'
  '  *) echo RF_USAGE; exit 2;;'
  'esac'
  '[ -f "$2" ] && [ -f update-binary ] || { echo RF_NOFILES; exit 3; }'
  'if ! command -v unzip >/dev/null 2>&1 && [ -f bb/busybox ]; then'
  '  chmod 755 bb/busybox; mkdir -p bb/bin; ln -sf ../busybox bb/bin/unzip'
  '  export PATH="$W/bb/bin:$PATH"'
  'fi'
  'rm -f ub.out ub.err ub.rc ub.rc.tmp rf.pid'
  ': > ub.out'
  'S=; command -v setsid >/dev/null 2>&1 && S=setsid'
  'nohup $S sh -c ''sh ./update-binary 3 1 "$0" >> ub.out 2>> ub.err < /dev/null; echo $? > ub.rc.tmp; chmod 644 ub.out ub.err ub.rc.tmp 2>/dev/null; mv -f ub.rc.tmp ub.rc'' "$W/$2" > /dev/null 2>&1 < /dev/null &'
  'echo $! > rf.pid'
  'echo "RF_STARTED $!"'
)
# --- other fixed texts and addresses -------------------------------------
$Script:PT_URL = 'https://developer.android.com/tools/releases/platform-tools'
$Script:PT_TERMS = 'https://developer.android.com/studio/terms'
$Script:PT_BASE = 'https://dl.google.com/android/repository'   # TAOYAO_PT_URL replaces it (tests)
$Script:DRV_URL = 'https://developer.android.com/studio/run/win-usb'
$Script:ADB_MIN = '1.0.39'                               # older adb: "too old" (platform-tools 30.x = 1.0.41)
# END OF THE CONSTANTS TABLE
########################################################################

$Utf8 = New-Object System.Text.UTF8Encoding($false)
$IsWin = ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT)
# (PowerShell 7 outside Windows: only for tests)
$IsMac = $false
if (-not $IsWin) { try { $IsMac = [bool](Get-Variable -Name IsMacOS -ValueOnly -ErrorAction SilentlyContinue) } catch { } }
$PtTerms = $Script:PT_TERMS; $PtBase = $Script:PT_BASE
$Here = $PSScriptRoot
if (-not $Here) { try { $Here = Split-Path -Parent $MyInvocation.MyCommand.Path } catch { $Here = (Get-Location).ProviderPath } }
$Argv = @($args)
$RC_OK = 0; $RC_FAIL = 10; $RC_CANCEL = 11; $RC_ROLLED = 12; $RC_ATTN = 13
$Launcher = 'run-flash.bat'
if (-not $IsWin) { $Launcher = 'pwsh run-flash.ps1' }

# run state
$Script:LogPath = $null
$Script:LogBuf = New-Object System.Text.StringBuilder
$Script:Serials = New-Object 'System.Collections.Generic.List[string]'
$Script:MaskRules = @()
$Script:Base = $null; $Script:Bases = New-Object 'System.Collections.Generic.List[string]'
$Script:Adb = $null; $Script:AdbVer = ''; $Script:AdbRoot = $false; $Script:AdbProc = $null; $Script:AdbUp = $false
$Script:Serial = $null; $Script:DState = 'none'; $Script:DItems = @(); $Script:DSer = $null; $Script:MultiPick = $false
$Script:SeenSer = New-Object 'System.Collections.Generic.List[string]'   # every serial "adb devices" listed in this run
$Script:SerChecked = @{}       # new serial -> getprop said taoyao (true/false)
$Script:PullCurDir = $null     # the pull folder copy being pulled (removed on Ctrl+C)
$Script:SlServed = $false      # the last sideload served at least one block of the zip
$Script:FiledOk = @{}          # kept folder (| phone dir) -> '' whole, or what is wrong (Test-FiledFull)
$Script:Phase = 'pre'; $Script:PrePullPhase = 'pre'; $Script:RunWrites = $false
$Script:Menu = $false; $Script:KeysOk = $false; $Script:FromCmdline = $false; $Script:Dropped = $false
$Script:BackToMenu = $false    # the restore list or its question said «back» (started from the menu)
$Script:Mode = ''; $Script:ArgPath = ''; $Script:ArgNote = ''
$Script:Zips = New-Object System.Collections.ArrayList; $Script:Zip = $null
$Script:ExitCode = 0; $Script:Lock = $null; $Script:LockPath = $null
$Script:OldOutEnc = $null; $Script:CtrlCSet = $false
$Script:EnterPressed = $false; $Script:EscPressed = $false; $Script:DotOpen = $false
$Script:IpaHinted = $false; $Script:LastPass = ''
$Script:Dc = $null
$Script:StepN = 0; $Script:StepM = 0
$Script:PullDir = $null; $Script:PullPartial = New-Object 'System.Collections.Generic.List[string]'
$Script:Handled = @{}        # remote dir + SHA256SUMS -> PC folder (this run)
$Script:Filed = $null         # cache of the folders under taoyao-stock-images / taoyao-*-backups
$Script:Gate = @{}            # answers of the pre-write gate (asked once per run)
$Script:WinDrvShown = $false
$Script:PhoneTouched = $false  # something was sent to the phone (for the summary)
$Script:FlashRc = 0
$Script:Sum = @{}             # what the final summary says
$Script:LastNow = [long]0      # phone clock at the last probe (T0p)
$Script:Rec = $null; $Script:And = $null
$Script:Slot = ''
$Script:PtStage = $null; $Script:PtJob = $null; $Script:PtErr = ''; $Script:PtVer = ''; $Script:PtZip = ''
$Script:SeenRuns = New-Object 'System.Collections.Generic.List[string]'   # taoyao-run ids of passes already read
$Script:Warned = @{}           # zips already reported as skipped
$Script:SeenLogs = @{}          # name|sha256 of the logs a result was read from (never fresh again)
$Script:TmpDir = $null        # PC temp folder of this run (removed at the end)
# (1.1) a recovery whose ADB has no root: Rnr once seen in this run; Q2 / Q3
$Script:Rnr = $false; $Script:RnrDataMnt = $false; $Script:RnrFp = ''; $Script:RnrRid = ''; $Script:RnrKr = ''; $Script:RnrStep1 = $false; $Script:RnrQ1 = $false
$Script:RootMgr = ''; $Script:RootMgrSaid = $false; $Script:SentAny = $false
$Script:QCopy = $null; $Script:QLine = ''; $Script:QHow = ''; $Script:QRid = ''; $Script:GateFprSaid = ''; $Script:QSent = 0; $Script:QKind = ''; $Script:QWant = ''
$Script:RsF = $null; $Script:RsCls = ''
$Script:RnrRamSeen = $false; $Script:RnrPass1W = $false; $Script:RnrSlot = ''; $Script:Q2Why = ''; $Script:RootWhy = ''
$Script:SumShown = $false; $Script:WaitSaw = $null
$Script:PhaseSaid = $false     # the stop text is on the screen (the summary points to it)
$Script:NoFooter = $false      # no forum footer: the user's own «no», or nothing to report
$Script:CurCtx = 'android'; $Script:CurState = ''   # where the phone is: android | recovery
$Script:HasSu = $false; $Script:RzMode = $false; $Script:TwoPass = $false
$Script:Pass1Dir = ''; $Script:Pass1Shown = $false; $Script:SawRec = $false; $Script:RecChecked = $false
$Script:RecCopies = @(); $Script:RamCopy = $null; $Script:SlotH = $null
$Script:RzText = ''; $Script:Ak3Line = ''; $Script:VRz = $false; $Script:PullErr = ''; $Script:PullLost = $false; $Script:BlWhat = ''

########################################################################
# MESSAGES (Russian). The same ids and order in run-flash.sh. {0}, {1}, ...
# are filled in with -f; the comment after each says what they are.
# Tags: «ОШИБКА:» red, «ВНИМАНИЕ:» yellow, «ОК:» green; hints for the phone
# start with «>>> » (yellow, with the bell).
# --- start and files ---
$M_BANNER = '{0}, версия {1}'                                     # brand, version
$M_LICENSE1 = 'Лицензия MeruDevTools — LICENSE-flash.txt рядом со скриптом. Продолжая, вы принимаете её условия.'
$M_LICENSE2 = 'License: LICENSE-flash.txt (MeruDevTools License). By continuing you accept it.'
$M_KEYS = 'Нажмите Enter (или Д) — да, Esc (или Н) — нет.'
$M_KEYS_AMBIG = 'Непонятно: на этой клавише и Y, и Н. Нажмите Enter (или Д) — да, Esc (или Н) — нет.'
$M_FOLDER = 'Папка флешера: {0}'
$M_ZIP_FOUND = 'Найдено ядро v{0}: {1}'                           # version, file name
$M_ZIP_SEVERAL = 'Найдено ядер: {0}. Выбрано самое новое — v{1} ({2}).'
$M_ZIP_SEVERAL_MENU = 'Выбрать другое — пункт 5 меню.'
$M_PICK_ZIP = 'Какой файл ядра взять? Нажмите цифру (Esc — назад):'
$M_ZIP_SEVERAL_CMD = 'Другой файл можно указать так: {0} install <файл>'
$M_ZIP_COPY = 'ОК: {0} — копия, которую браузер сохранил повторно («({1})» в имени); содержимое проверено: это ядро v{2}.'
$M_ZIP_NONE = 'Рядом с флешером нет файла ядра. Положите его в папку {0} (имя вида taoyao-6.12-vX.XX.zip — так его называет страница загрузки) и запустите флешер снова. Можно и перетащить zip ядра на run-flash.bat.'
$M_ZIP_NEAR = 'Похожие файлы с другим именем: {0}. Флешер берёт только файлы с исходным именем taoyao-<серия>-v<версия>.zip (можно «(1)» в конце) — не переименовывайте ядро.'
$M_ZIP_SKIPPED = 'ВНИМАНИЕ: {0} пропущен: {1}'                     # name, reason
$M_ZIP_BROKEN = 'ОШИБКА: {0} не открывается как ZIP-архив — он повреждён или скачан не до конца. Скачайте его заново.'
$M_ZIP_WRAPPER = 'ОШИБКА: {0} — архив-обёртка (так GitHub отдаёт файлы сборки): внутри лежит {1}. Распакуйте его (правой кнопкой → «Извлечь все…») и положите {1} рядом с флешером.'
$M_ZIP_WRAPPER_ASK = '{0} — архив-обёртка (так GitHub отдаёт файлы сборки): внутри лежит ядро {1}. Распаковать его в папку {2}? (Enter или Д — да, Esc или Н — нет)'
$M_ZIP_WRAPPER_DONE = 'ОК: ядро распаковано: {0}'
$M_ZIP_WRAPPER_FAIL = 'ОШИБКА: не удалось распаковать {0} из {1} (мало места или архив повреждён).'
$M_ZIP_BADNAME = 'ОШИБКА: {0} — файл ядра ({1}), но с изменённым именем. Флешер берёт только файлы с исходным именем, как на странице загрузки: верните ему имя {2} и запустите флешер снова.'
$M_ZIP_NOTOURS = 'ОШИБКА: {0} — не zip ядра taoyao от MeruDevTools (в нём нет {1}).'
$M_ZIP_NOTTAOYAO = 'ОШИБКА: {0} — не для Xiaomi Mi 12 Lite (taoyao): в нём устройство «{1}».'
$M_ZIP_RENAMED = 'ОШИБКА: имя {0} говорит v{1}, а внутри ядро {2} (файл version: «{3}»). Файл переименован или повреждён — скачайте ядро заново с официальной страницы.'
$M_ZIP_KSU = 'ОШИБКА: имя {0} говорит: {1}, а внутри KernelSU «{2}». Файл переименован — скачайте ядро заново с официальной страницы.'
$M_ZIP_NOVERSION = 'ОШИБКА: в {0} нет номера версии — это не выпускная сборка. Скачайте ядро с официальной страницы.'
$M_ZIP_SHA_OK = 'ОК: контрольная сумма совпадает ({0}).'
$M_ZIP_SHA_BAD = 'ОШИБКА: контрольная сумма {0} не совпадает с {1} — файл повреждён при скачивании. Скачайте его заново.'
$M_ZIP_INFO1 = 'Файл: {0} ({1})'
$M_ZIP_INFO2 = 'Ядро в файле: {0}, KernelSU: {1}'
$M_ZIP_NOTFOUND = 'ОШИБКА: файл или папка «{0}» не найдены.'
$M_NO_UNZIP = 'ОШИБКА: не нашлось программы для чтения ZIP.'
$M_BAD_ARG = 'ОШИБКА: непонятный параметр «{0}».'
$M_DROP_MANY = 'Перетащено несколько файлов; беру {0}.'
$M_NEED_TTY = 'ОШИБКА: флешер работает только в окне терминала (он задаёт вопросы).'
$M_LOCKED = 'ОШИБКА: флешер уже запущен в другом окне. Закройте то окно или дождитесь его окончания.'
$M_IN_ZIP = 'ОШИБКА: похоже, флешер запущен прямо из ZIP-архива: Windows распаковала его во временную папку, и копии разделов потом пропадут. Закройте это окно, щёлкните по ZIP-файлу правой кнопкой → «Извлечь все…», откройте распакованную папку и запустите run-flash.bat там.'
$M_QUICKEDIT = 'Не щёлкайте мышью по этому окну во время работы: Windows ставит вывод на паузу. Если вывод «застыл», нажмите Esc.'
$M_BASE_FALLBACK = 'ВНИМАНИЕ: не удаётся создать папку для копий и журнала в «{0}»: нет прав на запись. Копии и журнал будут в «{1}». Лучше перенести папку флешера, например, на Рабочий стол.'
$M_BASE_LONG = 'ВНИМАНИЕ: путь к папке флешера очень длинный — перенесите её, например, в C:\MeruDevTools.'
$M_BASE_NONE = 'ОШИБКА: не удаётся создать папку для копий и журнала.'
# --- phone search (texts of the log collector where they exist) ---
$T_WaitNone = @'
Телефон не найден. Проверьте:
  • телефон включён и разблокирован;
  • кабель подключён прямо к компьютеру и передаёт данные (некоторые кабели только заряжают);
  • на телефоне включена «Отладка по USB». Как включить: Настройки → «О телефоне» → 7 раз нажмите на «Версия ОС» (HyperOS) или «Номер сборки» (crDroid, Evolution X); затем откройте «Для разработчиков» (HyperOS: «Расширенные настройки» → «Для разработчиков»; crDroid, Evolution X: «Система» → «Для разработчиков») и включите «Отладка по USB»;
  • если телефон в рекавери: включите там ADB (LineageOS: Advanced → Enable ADB) или выберите Apply update → Apply from ADB;
  • если телефон в режиме fastboot (на экране заяц или надпись FASTBOOT): удерживайте кнопку питания около 15 секунд — он перезагрузится.
'@
$T_WaitNoneDrv = '  • если телефон всё равно не виден — установите драйвер USB: {0}'
$T_Unauth = 'Телефон подключён, но этот компьютер ещё не разрешён. На экране телефона появится вопрос «Разрешить отладку по USB?»: поставьте галочку «Всегда разрешать с этого компьютера» и нажмите «Разрешить» (или «OK»). Если вопроса нет — разблокируйте экран, отключите и снова подключите кабель. Не помогло — в разделе «Для разработчиков» отзовите разрешения отладки по USB (пункт называется примерно «Отозвать авторизацию отладки по USB») и подключите кабель снова.'
$T_UnauthRec = 'Рекавери показывает компьютеру статус «unauthorized». Если на экране телефона есть вопрос о разрешении отладки — нажмите «Разрешить». Жду…'
$T_Offline = 'Телефон виден, но не отвечает. Отключите и снова подключите кабель. Если не поможет — выключите и снова включите «Отладку по USB».'
$T_NoPerm = 'Нет прав на доступ к телефону по USB. Отключите и снова подключите кабель и запустите флешер снова.'
$T_NoPermLinux = 'Linux: нужны правила udev для Android (пакет android-sdk-platform-tools-common или android-udev-rules) и членство в группе plugdev; после установки отключите и снова подключите кабель.'
$T_Connecting = 'Телефон подключается…'
$M_FASTBOOT = 'Телефон в режиме fastboot или загрузчика. Флешер с ним не работает: удерживайте кнопку питания около 15 секунд, чтобы перезагрузить телефон.'
$M_RESCUE = 'Телефон в режиме восстановления Android (rescue) — флешер с ним не работает. Перезагрузите телефон.'
$T_RootHow = @'
  • SukiSU-Ultra или KernelSU: откройте приложение-менеджер → вкладка «Суперпользователь» → в меню ⋮ включите показ системных приложений → найдите «Shell» (com.android.shell) → включите доступ.
  • APatch: приложение APatch → вкладка «SuperUser» → в меню ⋮ «Показать системные приложения» → найдите «Shell» (com.android.shell) → включите доступ.
  • Magisk: Magisk → Настройки → «Доступ суперпользователя» → «Приложения и ADB».
'@
$M_WAIT_PHONE = 'Жду подключения телефона… (до {0} мин)'
$M_WAITING = '… жду {0}'                                          # elapsed
$M_WAIT_MORE = 'Телефон так и не перешёл в нужный режим за {0}. Enter или Д — ждать ещё, Esc или Н — остановиться (флешер следит за телефоном и сейчас).'
$M_WAIT_MORE_CABLE = 'Телефон так и не подключился снова за {0}. Enter или Д — ждать ещё, Esc или Н — остановиться (флешер следит за телефоном и сейчас).'
$H_WIN_DRIVER = '>>> Компьютер не видит телефон в рекавери. Обычно это драйвер Windows: скачайте Google USB Driver ({0}) и распакуйте ZIP. В Диспетчере устройств (правой кнопкой по «Пуск») у устройства с жёлтым значком: «Обновить драйвер» → «Найти драйверы на этом компьютере» → «Выбрать драйвер из списка доступных драйверов на компьютере» → «Установить с диска…» → «Обзор…» → файл android_winusb.inf в распакованной папке → «Android ADB Interface» → «Далее». Подробно — README-flash-ru.txt, раздел 2.'
$M_MULTI_PICKED = 'Подключено несколько устройств; выбран Xiaomi Mi 12 Lite.'
$M_MULTI_ASK = 'Подключено несколько устройств. Нажмите цифру нужного (Esc — выход):'
$M_MULTI_ITEM = '  {0}  {1} ({2}), состояние: {3}, серийный номер {4}'
$M_SERIAL_GONE = 'ОШИБКА: переменная ANDROID_SERIAL указывает на устройство, которого сейчас нет. Подключите его или удалите эту переменную.'
$M_NOT_TAOYAO = 'ОШИБКА: подключено устройство «{0}» ({1}), а флешер — только для Xiaomi Mi 12 Lite (taoyao). Ничего не делаю.'
$M_PHONE_NOANSWER = 'ОШИБКА: телефон не ответил ({0}). Отключите и снова подключите кабель и запустите флешер снова.'
$M_PHONE = 'Телефон: Xiaomi Mi 12 Lite ({0}), Android {1}, прошивка {2}'
$M_WAIT_BOOT = 'Телефон ещё загружается — жду…'
$M_UNLOCK_SCREEN = '>>> Разблокируйте экран телефона: до первой разблокировки его память недоступна.'
$M_NOW_ON = 'Сейчас на телефоне: {0}, будет установлено: v{1}{2}'   # release, version, note
$M_NOW_ON_REC = ' (по данным рекавери)'
$M_NOW_ON_COPY = ' (по копии слота)'
$M_NOW_ON_B = 'Сейчас на телефоне: {0}'                 # backup only: nothing is installed
$M_OLD_UNNUMBERED = 'На телефоне сборка 6.12 без номера в имени ядра (0.17 или старше).'
$M_STOCK_NOW = 'На телефоне сейчас ядро прошивки ({0}): копия, которую сделает установщик, — это стоковые образы. Флешер сохранит их на компьютере.'
$M_BL_OK = 'Загрузчик разблокирован.'
$M_BL_UNKNOWN = 'Состояние загрузчика телефон не сообщает — установщик проверит его сам.'
$M_BL_PROPS_LOCKED = 'ВНИМАНИЕ: по свойствам системы загрузчик заблокирован. На кастомных прошивках это часто подмена (для Play Integrity). Установщик проверит загрузчик сам и ничего не запишет, если он действительно заблокирован.'
$M_BL_LOCKED = 'ОШИБКА: загрузчик телефона заблокирован ({0}). Заблокированный загрузчик не примет изменённые boot, vendor_boot и dtbo: телефон покажет «The system has been destroyed», и вернуть его можно будет только через EDL. Сначала разблокируйте загрузчик. Ничего не записано.'
$M_SLOT = 'Активный слот: {0}'
$M_NO_SLOT = 'ОШИБКА: не удалось узнать активный слот телефона.'
$M_BAT = 'Заряд батареи: {0} %'
$M_BAT_STOP = 'ОШИБКА: заряд батареи {0} % — слишком мало для установки. Зарядите телефон хотя бы до 30 % и запустите флешер снова.'
$M_BAT_WARN_ASK = 'ВНИМАНИЕ: заряд батареи {0} %. Лучше зарядить телефон до 30 % и больше. Продолжить? (Enter или Д — да, Esc или Н — нет)'
$M_BAT_UNKNOWN = 'Заряд батареи узнать не удалось — убедитесь, что он не ниже 30 %.'
$M_DATA_SPACE = 'ОШИБКА: во внутренней памяти телефона свободно {0} МБ, а для установки нужно около 1,5 ГБ (копия разделов и рабочие файлы). Освободите место и запустите флешер снова.'
$M_PC_SPACE = 'ОШИБКА: на диске компьютера свободно {0} МБ, а для копии разделов нужно около {1} МБ. Освободите место (или перенесите папку флешера на другой диск).'
# --- root and the way ---
$M_ROOT_WAIT = 'Жду ответа на запрос прав root на экране телефона…'
$M_ROOT_RETRY = 'Запрос прав root отклонён или остался без ответа. Magisk спрашивает на экране — нажмите «Разрешить» (лучше «навсегда»); SukiSU-Ultra, KernelSU и APatch не спрашивают — доступ для Shell включается в их приложении. Пробую ещё раз через 5 секунд… (попытка {0} из 3)'
$M_ROOT_OK = 'Права root для adb: есть.'
$M_ROOT_NONE = 'Права root для adb: нет (su для adb не найден).'
$M_ROOT_NONE2 = 'Если root на телефоне есть, включите в приложении root доступ для Shell (README-flash-ru.txt, раздел 2) и запустите флешер снова — тогда он всё сделает прямо из системы.'
$M_ROOT_MGR = 'На телефоне установлено приложение {0}. Такие менеджеры не показывают запрос на экране, а прячут su от приложений, которым доступ не выдан, — поэтому su для adb не виден. Если в приложении написано, что root работает, включите доступ для Shell:'
$M_ROOT_MGR_MAGISK = 'На телефоне есть приложение Magisk, но su для adb не найден. Проверьте на главном экране Magisk, что он установлен, и включите доступ для Shell:'
$M_ROOT_MGR_ASK = 'Enter или Д — проверить ещё раз (сначала включите доступ для Shell), Esc или Н — {0}.'
$M_ROOT_DENIED_ASK = 'Root для Shell не выдан. Enter или Д — попробовать ещё раз (разрешите запрос на телефоне или включите доступ для Shell в приложении root), Esc или Н — {0}.'
$M_ROOT_NO_B = 'устанавливать через рекавери'
$M_ROOT_NO_A = 'выйти'
$M_ROOT_NO_R = 'возвращать образы через рекавери'
$M_ROOT_NO_NR = 'без root (варианты ниже)'
$M_WAY_A = 'Способ: установка из системы (root через USB) — за один проход; копия разделов сохранится во внутренней памяти телефона и потом на компьютере.'
$M_WAY_B_NOROOT = 'Способ: установка через рекавери (adb sideload), потому что root для adb на телефоне нет. Для LineageOS / crDroid / Evolution X — в два прохода: сначала только копия разделов, потом запись.'
$M_WAY_B_REC = 'Способ: установка через рекавери (adb sideload) — телефон уже в рекавери.'
$M_WAY_B_FORCED = 'Способ: установка через рекавери (как вы выбрали).'
$M_STOCK_NOROOT = 'В стоковой HyperOS рекавери Xiaomi не умеет устанавливать такие zip, а root для adb нет. Варианты: получить root (Magisk, KernelSU или SukiSU-Ultra с доступом root для Shell) — тогда флешер установит ядро прямо из системы; или установить TWRP / OrangeFox. У вас установлен TWRP или OrangeFox? (Enter или Д — да, перезагрузить в него; Esc или Н — нет, выйти)'
$M_A_NEEDS_ROOT = 'ОШИБКА: для установки из системы нужен root для adb (Shell).'
$M_A_NEEDS_SYSTEM = 'ОШИБКА: телефон в рекавери. Для install-system загрузите систему (Reboot system now) или запустите флешер с install-recovery.'
$M_REBOOT_REC_ASK = 'Перезагрузить телефон в рекавери для установки? (Enter или Д — да, Esc или Н — нет)'
$M_REBOOT_REC_ASK_R = 'Перезагрузить телефон в рекавери для возврата образов? (Enter или Д — да, Esc или Н — нет)'
$M_REBOOT_REC_ASK_B = 'Перезагрузить телефон в рекавери, чтобы сделать копию разделов? (Enter или Д — да, Esc или Н — нет)'
$M_REBOOTING_REC = 'Перезагружаю телефон в рекавери…'
$M_REBOOT_NOT_TAKEN = 'Телефон не перезагрузился по команде — пробую обычную перезагрузку в рекавери.'
$M_BOOTED_NOT_REC = 'ОШИБКА: телефон загрузился в систему, а не в рекавери. Войдите в рекавери вручную: выключите телефон, затем зажмите громкость вверх + питание до логотипа. Потом запустите флешер снова.'
# --- recovery ---
$M_REC_KIND = 'Рекавери: {0}'
$M_NR_WHY = 'ВНИМАНИЕ: ADB этого рекавери работает без прав root (uid {0}) — так устроены «user»-сборки рекавери LineageOS, crDroid и Evolution X. Root от SukiSU-Ultra, KernelSU или Magisk есть только в загруженной системе, а в рекавери его нет, даже с ядром KernelSU. Без root флешер не может прочитать здесь журнал установщика и забрать копию разделов.'
$M_NR_FORCED = 'Установить через рекавери, как вы выбрали (install-recovery), не получится: в это рекавери флешер заглянуть не может.'
$M_NR_NOTHING = 'На телефоне ничего не менялось.'
$M_NR_RAMSEEN = 'В этом сеансе рекавери установщик уже запускали: в памяти телефона есть копия слота {0} от прошлой отправки, поэтому следующая отправка может сразу записать ядро.'
$M_NR_P1_OLD = 'Проход 1 ядро не записал: телефон загрузился с прежним ядром {0}.'
$M_NR_PASS1 = 'Проход 1 установщика уже отправлен, но внутренняя память в этом рекавери закрыта: установщик мог сделать только копию слота в памяти телефона (на экране телефона — «NOT INSTALLED YET - step 1 of 2»), ядро не записано.'
$M_NR_PASS1_W = 'Проход 1 установщика уже отправлен, а в этом рекавери открыта внутренняя память: установщик мог сразу записать ядро. Посмотрите на экран телефона: «Done: … written and read back.» — ядро установлено; «NOT INSTALLED YET - step 1 of 2» — записи не было; «Aborting...» — установщик остановился.'
$M_NR_BACKUP = 'Сделать только копию разделов через такое рекавери нельзя: забрать её на компьютер флешер отсюда не может.'
$M_NR_Q1_I = 'Лучший путь: перезагрузить телефон в систему и установить ядро оттуда, с root для Shell через USB, за один проход — тогда копия разделов сохранится и на компьютере. Перезагрузить телефон в систему? (Enter или Д — да, Esc или Н — нет)'
$M_NR_Q1_I2 = 'Лучший путь — из системы, за один проход (копия разделов сохранится и на компьютере), но root для adb там флешер не нашёл. Если root на телефоне есть, после перезагрузки включите доступ для Shell — флешер покажет как и проверит ещё раз. Перезагрузить телефон в систему? (Enter или Д — да, Esc или Н — нет)'
$M_NR_Q1_B = 'Копию разделов флешер может сделать из системы, с root для Shell через USB. Перезагрузить телефон в систему? (Enter или Д — да, Esc или Н — нет)'
$M_NR_Q1_R = 'Лучший путь, если система на телефоне загружается: перезагрузить телефон в систему и вернуть образы оттуда, с root для Shell через USB, — тогда флешер проверит слот по sha256. Перезагрузить телефон в систему? (Enter или Д — да, Esc или Н — нет; система не загружается — Н)'
$M_NR_REBOOTING = 'Перезагружаю телефон в систему…'
$H_NR_REBOOT_SELF = '>>> Телефон не перезагрузился по команде adb: выберите на телефоне Reboot system now.'
$M_NR_NOSYS = 'ОШИБКА: телефон не появился в системе за {0}. Если он загрузился — запустите флешер снова. Если система не загружается — войдите в рекавери (выключите телефон, затем зажмите громкость вверх + питание до логотипа), включите Advanced → Enable ADB и запустите флешер снова; на вопрос «Перезагрузить телефон в систему?» ответьте Н.'
$M_NR_ROOT_ASK = 'Enter или Д — проверить root ещё раз (сначала включите доступ для Shell), Esc или Н — без root (варианты ниже).'
$M_NR_END = 'Root для adb в системе нет, а ADB рекавери работает без root — так флешер ядро не установит. Варианты: включите root для Shell (как — выше) и запустите флешер снова; поставьте рекавери TWRP / OrangeFox (их ADB работает с root); или установите вручную — тогда копия разделов, которую сделает установщик, останется только в памяти телефона и пропадёт при перезагрузке. Вручную: в рекавери Apply update → Apply from ADB, на компьютере {0} введите эту команду, затем на телефоне снова Apply update → Apply from ADB и ту же команду ещё раз, без перезагрузки:'
$M_NR_END_R = 'Root для adb в системе нет, а ADB рекавери работает без root — так флешер образы не вернёт. Варианты: включите root для Shell (как — выше) и запустите флешер снова; поставьте рекавери TWRP / OrangeFox (их ADB работает с root); или верните вручную: в рекавери Apply update → Apply from ADB, затем на компьютере {0}:'
$M_NR_END_B = 'Root для adb в системе нет, а ADB рекавери работает без root — так флешер копию разделов не сделает. Варианты: включите root для Shell (как — выше) и запустите флешер снова; или поставьте рекавери TWRP / OrangeFox (их ADB работает с root).'
$M_Q2_ASK = 'Можно и через Apply from ADB: флешер отправит ядро, а итог проверит сам — после перезагрузки, по версии работающего ядра. Путь назад — проверенная копия на компьютере: {0}. {1} (Enter или Д — да, Esc или Н — нет)'
$M_Q2_ASK_FPR = 'Можно и через Apply from ADB: флешер отправит ядро, а итог проверит сам — после перезагрузки, по версии работающего ядра. Путь назад — копия на компьютере, совпавшая с прошивкой только по отпечатку: {0}. {1} (Enter или Д — да, Esc или Н — нет)'
$M_Q2_FPRONLY = 'ВНИМАНИЕ: копия для пути назад совпала с прошивкой только по отпечатку (fingerprint): {0}. Модули для Play Integrity подменяют отпечаток, поэтому совпадение не доказывает, что сборка та же. Если прошивку обновляли после этой копии, restore-zip откажется записывать её образы, и вернуться можно будет только образами из самой прошивки или перепрошивкой. Надёжнее путь через систему с root для Shell или рекавери TWRP / OrangeFox: там копию разделов сделает установщик.'
$M_Q2_GO = 'Установить так?'
$M_Q2_GO_A = 'Перезагрузить телефон в рекавери и установить так?'
$M_Q2_NONE = 'Через Apply from ADB флешер не устанавливает: копия разделов, которую сделает установщик, пропадёт при перезагрузке, а проверенной копии слота {0} этой прошивки на компьютере нет — пути назад не было бы.'
$M_Q2_NONE_OPT = 'Варианты: путь через систему с root для Shell или рекавери TWRP / OrangeFox (их ADB работает с root).'
$M_Q2_SAMEVER = 'Через Apply from ADB флешер не устанавливает: в слоте уже ядро {0}, и проверить установку по версии работающего ядра нельзя.'
$M_Q2_WARN = 'ВНИМАНИЕ: копия разделов, которую сделает установщик, останется только в памяти телефона и пропадёт при перезагрузке. Путь назад — копия на компьютере {0}: пункт {1} меню флешера или Apply from ADB с её restore-zip.'
$M_Q2_WARN_D = 'ВНИМАНИЕ: копию разделов, которую сделает установщик, флешер в этот раз на компьютер не заберёт (если она окажется во внутренней памяти, в папке taoyao-6.12-backup, — заберёт при следующем запуске из системы). Путь назад — копия на компьютере {0}: пункт {1} меню флешера или Apply from ADB с её restore-zip.'
$M_Q2_WARN_1 = 'ВНИМАНИЕ: копия разделов, которую установщик уже сделал, есть только в памяти телефона и пропадёт при перезагрузке. Путь назад — копия на компьютере {0}: пункт {1} меню флешера или Apply from ADB с её restore-zip.'
$M_Q2_SCREEN_ASK = 'Что на экране телефона? Строка «NOT INSTALLED YET - step 1 of 2» — нажмите Enter или Д: флешер отправит ядро ещё раз, и оно запишется. Другая («Done: … written and read back.», «Aborting...») — Esc или Н: перезагрузка и проверка.'
$M_Q2_PASS1_ASK = 'Что на экране телефона после прохода 1? Строка «NOT INSTALLED YET - step 1 of 2» — нажмите Enter или Д: флешер отправит ядро ещё раз, и оно запишется. Другая («Done: … written and read back.», «Aborting...») — Esc или Н: без отправки, сразу перезагрузка и проверка.'
$M_Q3_ASK = 'Можно и через Apply from ADB: флешер отправит restore-zip этой копии (он сам проверит телефон, слот и образы), а итог проверит после перезагрузки, по версии работающего ядра. {0} (Enter или Д — да, Esc или Н — нет)'
$M_Q3_GO = 'Отправить?'
$M_Q3_GO_A = 'Перезагрузить телефон в рекавери и отправить?'
$M_Q3_NOT = 'Через Apply from ADB этот возврат флешер не предлагает: {0} — проверить его по версии работающего ядра нельзя.'
$M_Q3_WHY_SLOT = 'копия снята со слота {0}, а телефон работает со слота {1}'
$M_Q3_WHY_SAME = 'в слоте уже ядро {0}'
$H_Q_REBOOT = '>>> На телефоне: Reboot system now. Флешер дождётся системы и проверит версию ядра.'
$M_Q_BOOT_WAIT = 'Жду загрузки системы (до {0} мин). Esc или Н — не ждать.'
$M_Q_OK = 'ОК: телефон загрузился с ядром {0} — установлено, проверено по версии работающего ядра.'
$M_Q3_OK = 'ОК: телефон загрузился с ядром {0} — возвращено, проверено по версии работающего ядра.'
$M_Q_OLD = 'ОШИБКА: телефон загрузился со старым ядром {0} — ядро v{1} не записано. Причину установщик показывал на экране рекавери (на английском) до перезагрузки. Что дальше: включите root для Shell — тогда флешер установит ядро из системы; или поставьте рекавери TWRP / OrangeFox.'
$M_Q3_OLD = 'ОШИБКА: телефон загрузился с прежним ядром {0} — образы копии не вернулись. Причину restore-zip показывал на экране рекавери (на английском) до перезагрузки; чаще всего прошивка в слоте с тех пор изменилась (обновление, Magisk) и эти образы к ней не подходят. Что дальше: включите root для Shell и запустите флешер снова — он сравнит слот с копией. Если прошивку меняли, не записывайте эти образы и через fastboot — перепрошейте прошивку.'
$M_Q_OTHER = 'ВНИМАНИЕ: телефон загрузился с ядром {0} (слот {1}), а ожидалось {2} в слоте {3}{4}. Итог не подтверждён. Запустите флешер снова из системы — он покажет, что в слоте; путь назад — копия на компьютере {5}.'
$M_Q_NOBOOT = 'ВНИМАНИЕ: телефон не загрузился в систему за {0}. Если он остановился в fastboot или не загружается — верните образы из копии на компьютере (как — в итоге ниже).'
$M_Q3_NOBOOT = 'ВНИМАНИЕ: телефон не загрузился в систему за {0}. Если он остановился в fastboot или не загружается, а прошивку после этой копии не меняли — запишите её образы через fastboot (команды ниже); если меняли — перепрошейте прошивку.'
$M_Q_OTHER_SLOT = ' — возможно, слот {0} не загрузился и телефон сам переключился на другой'
$M_Q_SKIP = 'Проверка пропущена, итог не подтверждён. Посмотрите сами: Настройки → О телефоне → Версия ядра (crDroid, Evolution X: О телефоне → Версия Android → Версия ядра; HyperOS: О телефоне → Все параметры → Версия ядра); должно быть {0}.'
$M_A_BACKUP_FAIL = 'ОШИБКА: прочитать разделы слота {0} на телефоне не удалось ({1}). Ничего не записано.'
$M_RZ_PC_FAIL = 'ВНИМАНИЕ: restore-zip для копии сделать не удалось (подробности — в run-flash.log). Образы для fastboot сохранены: {0}.'
$M_A_BACKUP_PULLFAIL = 'ОШИБКА: копию разделов не удалось сохранить на компьютере ({0}). На телефоне ничего не записано, копии там не осталось — запустите флешер снова.'
$M_NO_SHELL_CHECKS = 'Телефон сразу в режиме Apply from ADB: заглянуть в рекавери флешер пока не может. Модель, загрузчик, слот и место проверит сам установщик и ничего не запишет, если что-то не так (заряд батареи проверен в системе: {0}).'
$M_SIDELOAD_UNKNOWN_B = 'Телефон уже ждёт файл (Apply from ADB). Флешер сначала должен заглянуть в рекавери: только так он узнает, не запишет ли установщик ядро сразу (тогда «только копию» здесь сделать нельзя).'
$M_SIDELOAD_UNKNOWN = 'Телефон уже ждёт файл (Apply from ADB). Флешер сначала должен заглянуть в рекавери: если в этом сеансе уже делали шаг 1, следующая отправка сразу запишет ядро.'
$H_ENABLE_ADB_B = '>>> На телефоне: Advanced → Enable ADB — чтобы флешер проверил рекавери перед копией (TWRP / OrangeFox: ничего нажимать не нужно).'
$H_ENABLE_ADB_R = '>>> На телефоне: Advanced → Enable ADB — чтобы флешер проверил слот перед возвратом образов (TWRP / OrangeFox: ничего нажимать не нужно).'
$M_SIDELOAD_UNKNOWN_R = 'Телефон уже ждёт файл (Apply from ADB). Флешер сначала должен заглянуть в рекавери: проверить телефон и запомнить слот, чтобы потом проверить возврат.'
$H_TWRP_WAIT = '>>> Телефон должен загрузиться в TWRP / OrangeFox. Если на экране меню рекавери Xiaomi (Reboot, Wipe Data, подключение к компьютеру) — оно не умеет устанавливать такие zip: выберите Reboot → Reboot to System.'
$M_XIAOMI_REC_WAYS = 'Варианты: получить root (Magisk, KernelSU или SukiSU-Ultra с доступом root для Shell) — тогда флешер установит ядро прямо из системы; или установить TWRP / OrangeFox.'
$H_LEAVE_SIDELOAD = '>>> На телефоне: выйдите из Apply from ADB (стрелка «Назад» вверху экрана) и включите Advanced → Enable ADB (TWRP / OrangeFox: кнопка Cancel внизу экрана).'
$H_ENTER_SIDELOAD = '>>> Если на телефоне меню рекавери: выберите Apply update → Apply from ADB (TWRP: Advanced → ADB Sideload и проведите по полосе).'
$H_APPLY_LOS = '>>> На телефоне: Apply update → Apply from ADB. Дальше флешер всё сделает сам.'
$H_APPLY_LOS2 = '>>> На телефоне снова: Apply update → Apply from ADB. Не перезагружайте телефон: копия слота пока в его памяти.'
$H_APPLY_Q = '>>> На телефоне: Apply update → Apply from ADB.'
$H_SIDELOAD_TWRP = '>>> На телефоне: Advanced → ADB Sideload → проведите по полосе внизу (OrangeFox: меню → ADB & Sideload).'
$H_ADB_LOS = '>>> На телефоне: Advanced → Enable ADB — чтобы флешер прочитал журнал установщика и забрал копию разделов.'
$H_ADB_TWRP = '>>> На телефоне: когда установка закончится, вернитесь в главное меню TWRP / OrangeFox (кнопка «Назад») — флешер прочитает журнал установщика.'
$H_SIGNATURE = '>>> Если телефон спросит «Signature verification failed. Install anyway?» — выберите Yes.'
$H_STEP1_ERROR_FRESH = 'Внимание: после этого прохода рекавери LineageOS / crDroid / Evolution X покажет ошибку («Installation aborted», статус 1), а TWRP / OrangeFox без открытой внутренней памяти — «Updater process ended with ERROR: 1» и «Error installing zip file» — так и задумано: это шаг 1, ничего не записано. TWRP / OrangeFox с открытой внутренней памятью сразу установит ядро. Не перезагружайте телефон — флешер продолжит сам.'
$H_STEP1_ERROR_OK = 'Внимание: после этого прохода рекавери покажет ошибку («Installation aborted», статус 1) — так и задумано: это шаг 1, ничего не записано. Не перезагружайте телефон — флешер продолжит сам.'
$H_STEP1_ERROR_TWRP = 'Внимание: после этого прохода TWRP / OrangeFox покажет ошибку («Updater process ended with ERROR: 1», «Error installing zip file») — так и задумано: это шаг 1, ничего не записано. Не перезагружайте телефон — флешер продолжит сам.'
$M_MAYBE_XIAOMI_REC = 'Если на телефоне меню рекавери Xiaomi (Reboot, Wipe Data, режим подключения к компьютеру) — оно не умеет устанавливать такие zip. Ничего не записано. Выберите Reboot → Reboot to System.'
$M_REC_UNAUTH = 'ОШИБКА: рекавери не пускает этот компьютер по ADB (статус unauthorized): это «user»-сборка рекавери, она не умеет спрашивать разрешение. Без ADB флешер не может забрать копию разделов, а без копии на компьютере ядро не записывается. Ничего не записано. Варианты: 1) установить ядро из системы с root (Magisk, KernelSU или SukiSU-Ultra с доступом для Shell) — флешер выберет этот способ сам; 2) временно поставить рекавери LineageOS (официальные сборки пускают ADB) или TWRP / OrangeFox; 3) заранее сохранить boot.img, vendor_boot.img и dtbo.img своей прошивки из её payload.bin. Телефон можно перезагрузить: Reboot system now.'
$M_UNAUTH_MAYBE_REC = 'Если телефон сейчас не в системе, а в рекавери: рекавери «user»-сборки показывает компьютеру «unauthorized» и не умеет спрашивать разрешение — по ADB флешер с ним работать не сможет. Варианты: 1) установить ядро из системы с root (Magisk, KernelSU или SukiSU-Ultra с доступом для Shell) — флешер выберет этот способ сам; 2) временно поставить рекавери LineageOS (официальные сборки пускают ADB) или TWRP / OrangeFox. Телефон можно перезагрузить: Reboot system now — и запустить флешер снова.'
$M_REC_UNAUTH_AFTER = 'ОШИБКА: рекавери не пускает этот компьютер по ADB (статус unauthorized). Флешер не может проверить, чем закончилась установка. Не перезагружайте телефон и посмотрите на его экран: «Done: … written and read back.» — ядро установлено; «NOT INSTALLED YET - step 1 of 2» — ничего не записано (копию из памяти рекавери флешер забрать не может, телефон можно перезагрузить: Reboot system now); «Aborting...» — установщик остановился.'
$M_RAM_REUSE = 'В памяти рекавери уже есть копия слота {0} от шага 1 в этом сеансе: {1}. Установщик её использует: следующая отправка сразу запишет ядро.'
$M_RAM_ONPC = 'Эта копия уже на компьютере: {0}'
$M_RAM_OLD = 'В памяти рекавери есть копия слота {0} ({1}), но слот с тех пор изменился. Сохраняю её на компьютер; установщик сделает новую копию.'
$M_ONEPASS = 'В этом рекавери (TWRP / OrangeFox) открыта внутренняя память: установщик сохранит копию разделов в /sdcard/{0} и сразу установит ядро — за один проход. Потом флешер заберёт копию на компьютер.'
$M_ALREADY_DONE = 'В этом сеансе рекавери ядро v{0} уже установлено (так пишет журнал установщика). Ставить ещё раз не нужно.'
$M_NEED_LOG_FIRST = 'Подождите: сначала флешер должен прочитать журнал прошлой отправки.'
$M_REBOOTED_AFTER_STEP1 = 'ОШИБКА: телефон перезагрузился после шага 1 — копия из памяти рекавери пропала. Ничего не записано. Запустите флешер снова.'
$M_REBOOTED_UNKNOWN = 'ВНИМАНИЕ: телефон перезагрузился сразу после установки — флешер не успел прочитать её итог. Проверьте: Настройки → О телефоне → Версия ядра (должно быть {0}). Если телефон не загружается — см. «Как вернуться» ниже.'
$M_AK3_EARLY = 'ОШИБКА: установщик остановился в самом начале, до своих проверок ({0}). Ничего не записано.'
$M_RETRY = 'Передача прервалась, установщик не запускался — ничего не записано. Повторяю (попытка {0} из {1}).'
$M_TRIES_OUT = 'ОШИБКА: файл не удалось передать на телефон {0} раза. Ничего не записано. Попробуйте другой кабель и другой порт USB (без разветвителя) и запустите флешер снова.'
$M_TRIES_OUT_Q = 'ОШИБКА: файл не удалось передать на телефон {0} раза. Прошлая отправка могла уже записать ядро — итог не подтверждён. Перезагрузите телефон (Reboot system now) и посмотрите версию ядра (должно быть {1}); если телефон не загружается — верните образы из копии на компьютере (как — в итоге ниже).'
$M_TRIES_OUT_W = 'ОШИБКА: файл не удалось передать на телефон {0} раза, а итог последней попытки неизвестен. Не перезагружайте телефон и посмотрите на его экран: «Done: … written and read back.» — ядро установлено; «Aborting...» — нет.'
$M_STEP1_AGAIN = 'Установщик не нашёл копию из шага 1 (рекавери, видимо, перезапускался) и сделал новую копию — ничего не записано. Сохраняю её и повторяю запись.'
$M_ROUNDS_OUT = 'ОШИБКА: копия из шага 1 снова пропала. Не перезапускайте рекавери между шагами и запустите флешер снова.'
$M_UNCONFIRMED = 'ОШИБКА: не удалось подтвердить итог по журналу установщика ({0}). Телефон оставьте в рекавери и не перезагружайте. На экране телефона: «Done: … written and read back.» — ядро установлено; «NOT INSTALLED YET - step 1 of 2» — записи не было; «Aborting...» — установщик остановился. Приложите к сообщению на форуме файл {1}.'
$M_UNCONFIRMED_A = 'ОШИБКА: не удалось подтвердить итог по журналу установщика ({0}). Не перезагружайте телефон. Подождите несколько минут и запустите флешер снова: он прочитает итог установки на телефоне. Приложите к сообщению на форуме файл {1}.'
$M_UNC_NOLOG = 'журнала этого прохода на телефоне нет'
$M_UNC_INCOMPLETE = 'журнал обрывается: установщик, видимо, прервался'
$M_UNC_SAME = 'ВНИМАНИЕ: итог по журналу установщика не подтверждён ({0}).'
$M_UNC_PASS_W = 'ВНИМАНИЕ: этот проход мог сразу записать ядро (TWRP / OrangeFox с открытой внутренней памятью или рекавери с открытой /data), поэтому «ничего не записано» здесь сказать нельзя.'
$M_SENDING_SL = 'Отправляю {0}: {1} %'                               # what, percent
$M_SENT_SL = 'Отправлено: {0}.'
$M_SL_FAILED = 'Передача не удалась ({0}).'
$M_INSTALLING_REC = 'Установщик работает на телефоне — жду его окончания…'
# --- results ---
$M_STEP1_OK = 'ОК: шаг 1 из 2 пройден: копия слота {0} сделана, ничего не записано.'
$M_DONE = 'ОК: ядро v{0} установлено: boot{1}, vendor_boot{1} и dtbo{1} записаны и проверены установщиком.'
$M_ABORT_CLEAN = 'Установщик остановился, ничего не записано.'
$M_ROLLED_BACK = 'Установщик остановился после начала записи и вернул исходные образы: слот {0} такой же, как до установки.'
$M_DIRTY = 'ОШИБКА: установщик не смог вернуть исходные образы — слот {0} сейчас наполовину {2} и НЕ ЗАГРУЗИТСЯ. Не перезагружайте телефон. Копия разделов на компьютере: {1}.'
$M_RESCUE_ASK = 'Попробовать сейчас же вернуть слот restore-zip''ом из этой копии, не перезагружая телефон? (Enter или Д — да, Esc или Н — нет)'
$M_RESCUED = 'ОК: исходные образы снова в слоте {0} (проверено по sha256).'
# (the slot against the copy of step 1 on the PC: before a pass that writes is
# sent again, and when such a pass ends without a confirmed result)
$M_SLOT_SAME = 'ОК: слот {0} не изменился: sha256 boot, vendor_boot и dtbo совпадают с копией на компьютере — ничего не записано.'
$M_SLOT_HALF = 'ОШИБКА: слот {0} уже не такой, как копия на компьютере (sha256 разделов не совпадает): установщик остановился на середине записи, слот может не загрузиться. Не перезагружайте телефон. Копия разделов до установки: {1}.'
$M_SLOT_CHANGED = 'ОШИБКА: установщик написал, что ничего не записал, но слот {0} уже не такой, как копия на компьютере (sha256 разделов не совпадает). Флешер больше ничего не отправляет и эту копию как стоковую не сохраняет. Не перезагружайте телефон. Копия разделов до установки: {1}.'
$M_SLOT_UNREAD = 'ОШИБКА: флешер не смог прочитать разделы слота {0}, чтобы убедиться, что они не менялись, и поэтому не отправляет файл ещё раз. Телефон оставьте в рекавери и не перезагружайте. Приложите к сообщению на форуме файл {1}.'
$M_IPA_HINT = 'ВНИМАНИЕ: установщик не узнал прошивку и включил режим IPA для Evolution X / crDroid. Только если у вас стоковая HyperOS или прошивка с vendor от Xiaomi (иначе может не работать точка доступа): в рекавери до шага 2, пока она пускает ADB, выполните в другом окне {0} shell touch /tmp/taoyao-ipa-stock; при установке из системы или в TWRP / OrangeFox с открытой памятью положите пустой файл taoyao-ipa-stock во внутреннюю память (/sdcard). Затем установите ядро (ещё раз). Подробно — README-flash-ru.txt, раздел 9.'
$M_INSTALLER_NOTES = 'Заметки установщика:'
$M_REASON = 'Причина:'
$M_WHY_LOCKED = 'Загрузчик телефона заблокирован. Заблокированный загрузчик не примет изменённые boot, vendor_boot и dtbo: телефон покажет «The system has been destroyed», и вернуть его можно будет только через EDL. Сначала разблокируйте загрузчик.'
$M_WHY_NEXTSLOT = 'Загрузчик в следующий раз запустит другой слот (после установки прошивки или обновления). Перезагрузите телефон в рекавери ещё раз (после обновления — один раз загрузите систему) и запустите флешер снова.'
$M_WHY_TMPSPACE = 'В памяти рекавери мало места для копии. Перезагрузите рекавери (ничего больше не устанавливая) и запустите флешер снова.'
$M_WHY_SDSPACE = 'Во внутренней памяти телефона нет места для копии разделов (нужно около 400 МБ). Освободите место.'
$M_WHY_CMDLINE = 'Командная строка ядра для этой прошивки получилась бы слишком длинной — телефон загрузился бы в рекавери. Сообщите на форуме, приложите run-flash.log.'
$M_WHY_HEADER = 'Формат boot / vendor_boot этой прошивки установщик не поддерживает.'
$M_WHY_DEVICE = 'Установщик не узнал телефон: это не Xiaomi Mi 12 Lite (taoyao).'
$M_WHY_UNZIP = 'Файл не распаковался на телефоне — передача, видимо, повредила его. Запустите флешер снова; не помогает — другой кабель или порт.'
$M_WHY_BADZIP = 'Файл ядра собран неправильно — сообщите на форуме.'
$M_WHY_RZ_ROM = 'Прошивка в слоте с тех пор изменилась (обновление или другая прошивка): эти образы к ней не подходят, возврат их не записал. Установите прошивку заново или используйте копию этой прошивки.'
$M_WHY_RZ_SUMS = 'restore-zip повреждён.'
$M_WHY_OTHER = 'Причина — в строках выше (на английском).'
# --- copies ---
$M_PHONE_COPIES = 'На телефоне найдено копий: {0} (новых для компьютера: {1}, ≈ {2})'
$M_NONE_ON_PHONE = 'Копий разделов во внутренней памяти телефона нет.'
$M_NONE_ON_REC = 'Копий разделов на телефоне (в памяти рекавери и во внутренней памяти) нет.'
$M_COPY_KNOWN = 'Такая копия уже есть: {0} — повторно не сохраняю.'
$M_COPY_KNOWN_BAD = 'ВНИМАНИЕ: на компьютере уже есть папка с этой копией ({0}), но она неполная или повреждена ({1}). Её флешер не трогает, а копию с телефона сохранит заново, в новую папку.'
$M_STOCK_SAVED = 'Стоковые образы сохранены: {0} — храните эту папку: это возврат на стоковое ядро.'
$M_STOCK_SAVED2 = 'Ядро в копии: {0}, прошивка: {1}, слот {2}'
$M_STOCK_UNKNOWNK = '(версия ядра в копии не определилась)'
$M_PREV_SAVED = 'Копия прошлой сборки {0} ({1}) сохранена: {2}'
$M_PULLING = 'Копирую на компьютер: {0} ({1})…'
$M_VERIFY_OK = 'ОК: копия {0} на компьютере проверена (размеры, sha256, restore-zip).'
$M_VERIFY_OK_NORZ = 'ОК: копия {0} на компьютере проверена (размеры, sha256); restore-zip в ней нет.'
$M_VERIFY_RETRY = 'Копия скопировалась с ошибкой ({0}). Копирую ещё раз…'
$M_STOCK_NONE_PC = 'Стоковых образов этой прошивки (слот {0}) на компьютере нет.'
$M_STOCK_NONE_UNK = 'Подходят ли к этой прошивке стоковые образы слота {0} на компьютере — неизвестно.'
$M_RZ_MISSING = 'ВНИМАНИЕ: установщик не смог сделать restore-zip (мало памяти). Образы для fastboot сохранены: {0}.'
$M_RZ_NONE_STOP = 'ОШИБКА: установщик не смог сделать restore-zip (мало памяти в рекавери), а без него второй шаг не делается. Ничего не записано. Перезагрузите рекавери, чтобы освободить память (Reboot → Recovery; ничего больше не устанавливая), и запустите флешер снова: установщик сделает копию заново. Образы для fastboot уже на компьютере: {0}.'
$M_COPY_NOT_ON_PC = 'ОШИБКА: копии разделов (с restore-zip) на компьютере нет — второй шаг не делается. Ничего не записано. Не перезагружайте телефон; запустите флешер снова — он найдёт копию и продолжит.'
$M_PULL_LOST = 'Связь с телефоном пропала во время копирования ({0}). Подключите кабель снова — флешер дождётся телефона и продолжит копирование.'
$M_PULL_LOST_FAIL = 'ОШИБКА: копию разделов не удалось забрать на компьютер: связь с телефоном пропадала {0} раза. Ничего не записано. Не перезагружайте телефон (копия пока может быть только в его памяти); попробуйте другой кабель и порт USB (без разветвителя) и запустите флешер снова — он найдёт копию и продолжит.'
$H_REPLUG = '>>> Подключите кабель снова и не перезагружайте телефон (в рекавери LineageOS, если ADB выключился: Advanced → Enable ADB).'
$H_REPLUG_A = '>>> Подключите кабель снова.'
$M_VERIFY_FAILED = 'ОШИБКА: копия на компьютере не прошла проверку: {0}. Ничего не записано. Не перезагружайте телефон (копия пока только в его памяти) и попробуйте другой кабель или порт; запустите флешер снова — он продолжит.'
$M_PULL_LATER = 'ВНИМАНИЕ: ядро установлено, но копию разделов не удалось забрать на компьютер ({0}). Она лежит на телефоне: {1}. Запустите флешер ещё раз и выберите пункт 4 — он сначала заберёт копии из памяти телефона (на вопрос о перезагрузке в рекавери ответьте Esc), или скопируйте эту папку вручную (Внутренняя память → {2}).'
$M_ACCESS_DENIED = 'Windows не дал adb записать файл в папку «{0}». Возможно, включена защита «Контролируемый доступ к папкам». Перенесите папку флешера, например, в C:\MeruDevTools и запустите снова.'
$M_STOCK_PRESENT = 'Стоковые образы этой прошивки есть на компьютере: {0}'
$M_STOCK_PRESENT_FPR = 'Есть стоковые образы слота {0}, совпавшие с прошивкой только по отпечатку: {1}'
$M_STOCK_MAYBE = 'Есть стоковые образы слота {0}, возможно, другой сборки прошивки: {1}'
$M_STOCK_FPRONLY = 'ВНИМАНИЕ: эта копия совпала с прошивкой только по отпечатку (fingerprint): {0}. Модули для Play Integrity подменяют отпечаток, поэтому совпадение не доказывает, что сборка та же. Если прошивку обновляли после этой копии, restore-zip откажется записывать её образы.'
$M_STOCK_OTHERBUILD = 'ВНИМАНИЕ: стоковые образы слота {0} на компьютере — от другой сборки прошивки, не той, что стоит на телефоне сейчас: {1}. К этой прошивке они не подходят: restore-zip из такой копии откажется их записывать.'
$M_STOCK_OLDER = 'ВНИМАНИЕ: стоковые образы слота {0} на компьютере сделаны, по часам телефона, раньше, чем собрана прошивка, которая стоит на нём сейчас (сборка от {2}): {1}. Скорее всего, они от прошлой сборки, до обновления прошивки. Точнее сравнить нельзя: сборки прошивки в этих копиях нет (их сделали установщик до 0.20 или флешер до 1.2).'
$M_FPR_WHY_COPY = 'сборки прошивки в копии нет (копию сделали установщик до 0.20 или флешер до 1.2)'
$M_FPR_WHY_PHONE = 'сборку прошивки на телефоне сейчас не прочитать'
$M_STOCK_CANTCMP = 'Есть стоковые образы слота {0}: {1}. Но сборку прошивки на телефоне сейчас определить нельзя, поэтому флешер не знает, подходят ли они к ней.'
$M_COPY_BUILT = '{0} (сборка прошивки от {1})'
$M_COPY_MADE = '{0} (копия от {1})'
$M_ROM_BUILT = '{0} (сборка от {1})'
$M_STOCK_MISSING = "ВНИМАНИЕ: на телефоне уже ядро {3} ({0}), поэтому копия, которую сделает установщик, — это копия прошлой сборки {3}, а не стоковых образов. {5} Их можно взять только из копии первой установки {3} (папка {4}, которую вы тогда сохранили) или из самой прошивки (boot.img, vendor_boot.img и dtbo.img из её архива или payload.bin). Без них вернуться на стоковое ядро можно только перепрошивкой.`r`nВсё равно установить ядро v{2}? (Enter или Д — да, Esc или Н — нет)"
$M_DOWNGRADE_ASK = 'ВНИМАНИЕ: на телефоне более новая сборка (v{0}), чем в файле (v{1}). Установить более старую? (Enter или Д — да, Esc или Н — нет)'
$M_SAME_ASK = 'Эта версия (v{0}) уже установлена. Установить её ещё раз? (Enter или Д — да, Esc или Н — нет)'
$M_NOKSU_NOTE = 'ВНИМАНИЕ: в этой сборке нет KernelSU (noksu): после установки root (SukiSU / KernelSU) пропадёт, и следующий раз флешер будет ставить ядро через рекавери.'
$M_RAM_NOTE_ONPC = 'Копия из памяти рекавери уже на компьютере и проверена: {0} — забирать её вручную не нужно.'
$M_RAM_KEPT = 'Копия слота остаётся в памяти рекавери, пока телефон не перезагрузится.'
# --- restore ---
$M_RESTORE_NONE = 'На компьютере нет сохранённых {0} (папка {1}). Они появляются, когда флешер устанавливает ядро. Без них вернуть стоковое ядро можно образами из самой прошивки (fastboot) или её перепрошивкой.'
$M_RESTORE_NONE_STOCK = 'стоковых образов'
$M_RESTORE_NONE_PREV = 'На компьютере нет сохранённых копий прошлых сборок ядра taoyao (папки taoyao-<серия>-backups рядом с флешером). Они появляются, когда флешер ставит новую сборку поверх старой.'
$M_RESTORE_LIST = 'Какую копию вернуть? Нажмите цифру (Esc — выход):'
$M_RESTORE_ITEM = '  {0}  {1}'
$M_RESTORE_LINE = '{0} — слот {1}, ядро {2}, копия от {3}'
$M_RESTORE_CONFIRM = 'Вернуть эту копию в слот {0}? (Enter или Д — да, Esc или Н — нет)'
$M_RESTORE_BAD = 'ОШИБКА: копия {0} повреждена ({1}). Возврат из неё не делаю.'
$M_RESTORE_CHECKED = 'ОК: копия на компьютере проверена: {0}'
$M_RESTORE_ZIPONLY = '(образов в папке нет — хватает restore-zip, он сам проверяет свои образы)'
$M_RESTORE_OTHERSLOT_ASK = 'ВНИМАНИЕ: копия снята со слота {0}, а телефон сейчас работает со слота {1}. Возврат запишет слот {0} — на загрузку телефона это не повлияет. Всё равно продолжить? (Enter или Д — да, Esc или Н — нет)'
$M_RESTORE_OTHERROM = 'ВНИМАНИЕ: копия снята с другой сборки прошивки. Если прошивка в слоте с тех пор менялась, restore-zip откажется записывать — это нормально.'
$M_RESTORE_MAYBEROM = 'ВНИМАНИЕ: копия, {0}, снята с другой сборки прошивки. Если прошивка в слоте с тех пор менялась, restore-zip откажется записывать — это нормально.'
$M_HOW_OLDER = 'скорее всего'
$M_HOW_FPRDIFF = 'возможно'
$M_RESTORE_NOOP = 'ОК: слот {0} уже содержит эти образы — ничего делать не нужно.'
$M_RESTORED = 'Готово: слот {0} снова содержит сохранённые образы (проверено по sha256): ядро {1}.'
$M_RESTORE_REFUSED = 'Возврат не выполнен, ничего не записано:'
$M_RESTORE_DIRTY = 'ОШИБКА: возврат записал слот {0} не полностью — НЕ перезагружайте телефон. Запишите образы через fastboot из папки {1}:'
$M_RESTORE_UNCONFIRMED = 'ВНИМАНИЕ: флешер не смог проверить слот {0} после возврата. Посмотрите на экран телефона: «holds the saved images again» — возврат выполнен; «Nothing was written» — нет.'
# --- (A) ---
$M_SENDING = 'Отправляю ядро v{0} на телефон…'
$M_SENDING_RZ = 'Отправляю restore-zip на телефон…'
$M_PUSH_BAD = 'ОШИБКА: файл на телефоне не совпал с файлом на компьютере. Отключите и снова подключите кабель и запустите флешер снова.'
$M_PUSH_FAIL = 'ОШИБКА: не удалось отправить файл на телефон ({0}). Отключите и снова подключите кабель и запустите флешер снова. Ничего не записано.'
$M_PUSH_OK = 'ОК: файлы на телефоне проверены (sha256).'
$M_A_NOSTART = 'ОШИБКА: установщик на телефоне не запустился ({0}). Ничего не записано.'
$M_A_RUNNING = 'На телефоне уже идёт установка (запущена раньше) — жду её окончания.'
$M_A_PREVIOUS = 'На телефоне есть итог прошлой установки — читаю его.'
$M_A_GOING = '… установка идёт ({0}). Не отключайте телефон.'
$M_A_SLOW = 'Установка идёт дольше обычного — подождите.'
$M_A_TIMEOUT = 'ОШИБКА: установка идёт уже 15 минут. Флешер перестаёт ждать. Не перезагружайте телефон ещё 5 минут, потом запустите флешер снова — он прочитает итог.'
$M_A_CABLE = 'Связь с телефоном пропала — установка на телефоне продолжается сама. Подключите кабель снова.'
$M_A_STARTED = 'Установщик запущен на телефоне. Его сообщения:'
# --- backup / reboot ---
$M_BACKUP_NEEDS_REC = 'В работающей системе установщик сразу устанавливает ядро; только копию разделов умеет делать лишь рекавери (LineageOS, crDroid, Evolution X, TWRP, OrangeFox).'
$M_BACKUP_NOT_HERE = 'ОШИБКА: в этом рекавери открыта внутренняя память, и установщик сразу установит ядро — «только копию» здесь сделать нельзя. Ничего не записано.'
$M_BACKUP_DONE = 'ОК: копия разделов сохранена, на телефоне ничего не записано: {0}'
$M_BACKUP_UNEXPECTED = 'ВНИМАНИЕ: установщик неожиданно установил ядро за один проход (внутренняя память оказалась доступна).'
$M_ONEPASS_UNPREDICTED = 'ОК: установщик сохранил копию во внутренней памяти и записал ядро за один проход.'
$M_REBOOT_ASK = 'Перезагрузить телефон в систему? (Enter или Д — да, Esc или Н — нет)'
$M_REBOOT_SELF = 'Перезагрузите телефон сами: Reboot system now.'
$M_REBOOT_SELF_A = 'Перезагрузите телефон сами, когда будет удобно: записанное ядро заработает после перезагрузки.'
$M_REBOOT_NOT_NOW = 'Телефон не перезагружаю: {0}'
$M_BOOT_WAIT = 'Жду загрузки системы (до 5 мин). Esc или Н — не ждать.'
$M_REBOOTING_SYS = 'Перезагружаю телефон (как перезагрузка из меню кнопки питания)…'
$M_REBOOT_FALLBACK = 'Android сам не начал перезагрузку — перезагружаю командой adb reboot.'
$M_BOOT_OK = 'Телефон загрузился с ядром {0}.'
$M_BOOT_OTHER = 'ВНИМАНИЕ: телефон загрузился с ядром {0}, ожидалось {1}.'
$M_BOOT_UNAUTH = 'Телефон загрузился, но этот компьютер не разрешён для отладки — версию ядра флешер не видит. Разрешите отладку по USB на телефоне или посмотрите сами: Настройки → О телефоне → Версия ядра.'
$M_BOOT_NONE = 'Телефон не появился в системе за 5 минут. Если он остановился в fastboot или не загружается — см. «Как вернуться» в итоге.'
$M_BOOT_SKIP = 'Не жду загрузки.'
# --- Ctrl+C and the end ---
$M_CANCEL_Q = 'Остановить флешер? (Enter или Д — да, Esc или Н — нет)'
$M_CANCEL_PULL_Q = 'Остановить копирование? (Enter или Д — да, Esc или Н — нет)'
$M_CANCEL_RUN_Q = 'Установка на телефоне, возможно, уже идёт — прерывать её нельзя. Enter или Д — ждать дальше (лучше так), Esc или Н — перестать ждать'
$M_CANCEL_PRE = 'Остановлено. На телефоне ничего не менялось.'
$M_CANCEL_WAIT = 'Остановлено. Ничего не записано. Если телефон в рекавери — его можно перезагрузить: Reboot system now.'
$M_CANCEL_RAM = 'Остановлено. Ничего не записано. Не перезагружайте телефон: копия разделов пока только в его памяти. Запустите флешер снова — он найдёт копию и продолжит.'
$M_CANCEL_RAMPC = 'Остановлено. Ничего не записано, копия на компьютере: {0}. Телефон можно перезагрузить.'
$M_CANCEL_RUN = 'Флешер больше не ждёт. Не перезагружайте телефон, пока на его экране не появится итог (рекавери) или ещё несколько минут (система). Потом запустите флешер снова: он прочитает журнал установщика и закончит.'
$M_CANCEL_DONE = 'Остановлено.'
$M_CANCEL_Q2 = 'Остановлено. Итог флешер не проверил. Если телефон ещё в рекавери — перезагрузите его (Reboot system now); в системе посмотрите версию ядра: Настройки → О телефоне → Версия ядра (crDroid, Evolution X: О телефоне → Версия Android → Версия ядра; HyperOS: О телефоне → Все параметры → Версия ядра); должно быть {0}.'
$M_CANCEL_QRUN = 'Флешер больше не ждёт. Не перезагружайте телефон, пока на его экране не появится итог. Потом перезагрузите его (Reboot system now) и посмотрите версию ядра: Настройки → О телефоне → Версия ядра (crDroid, Evolution X: О телефоне → Версия Android → Версия ядра; HyperOS: О телефоне → Все параметры → Версия ядра); должно быть {0}.'
$M_CANCEL_QRUN1 = 'Флешер больше не ждёт. Эта отправка ядро не записывает (шаг 1). Дождитесь итога на экране телефона — потом телефон можно перезагрузить: Reboot system now.'
$M_CANCEL_SEEN = 'Остановлено. Флешер в этот раз ничего не отправлял. Прошлая отправка в этом сеансе рекавери могла записать ядро — её итог на экране телефона.'
$M_CANCEL_SAID = 'Остановлено вами — что с телефоном и что делать, написано выше.'
$M_GO_ON = 'Продолжаю.'
$M_PRESS_KEY = 'Нажмите любую клавишу, чтобы закрыть окно.'
$M_FAILED = "Не получилось. Приложите к сообщению на форуме файл:`r`n  {0}`r`nВ нём нет серийного номера телефона и имени пользователя компьютера."
$M_INTERNAL = 'Внутренняя ошибка флешера: {0}'
# --- adb ---
$M_ADB = 'adb: {0} (версия {1})'
$M_ADB_OLD = 'ОШИБКА: найден только старый adb (версия {0}: {1}). С ним флешер работает ненадёжно. Скачайте свежий: {2} — и распакуйте папку platform-tools рядом с флешером: тогда будет использован он.'
$M_ADB_OLD_HERE = 'ОШИБКА: найден только старый adb (версия {0}) — в папке флешера: {1}. С ним флешер работает ненадёжно. Скачайте свежий: {2} — и замените им папку platform-tools рядом с флешером.'
$M_ADB_DLL = 'ОШИБКА: {0} не запустится: рядом с ним нет файлов AdbWinApi.dll и AdbWinUsbApi.dll. Распакуйте папку platform-tools целиком, со всеми файлами.'
$M_ADB_NONE = 'ОШИБКА: не найдена программа adb (Android Platform Tools) — без неё компьютер не может работать с телефоном.'
$M_ADB_HOW1 = ' 1. Скачайте «SDK Platform-Tools for Windows»: {0}'
$M_ADB_HOW2 = ' 2. Распакуйте архив так, чтобы папка platform-tools оказалась рядом с run-flash.bat (должен получиться файл {0}).'
$M_ADB_HOW3 = ' 3. Запустите run-flash.bat снова.'
$M_ADB_HOWX = ' Linux: sudo apt install adb (Debian, Ubuntu) или sudo dnf install android-tools (Fedora); macOS: brew install android-platform-tools. Или распакуйте Android SDK Platform-Tools ({0}) так, чтобы папка platform-tools оказалась рядом с флешером.'
$M_ADB_CLASH = 'ВНИМАНИЕ: другая программа на компьютере запускает свою версию adb, и они мешают друг другу. Если телефон будет «пропадать», закройте программы для работы с телефоном и запустите флешер снова.'
$M_ADB_NOSERVER = 'ОШИБКА: не удалось запустить службу adb ({0}). Закройте другие программы, которые работают с телефоном по USB, и запустите флешер снова. Не помогло — перезагрузите компьютер.'
# --- steps (headings «Шаг N из M: …») ---
$S_I1 = 'проверка файла ядра v{0} (секунды)'
$S_I2 = 'поиск телефона и проверки (до 3 мин, пока вы подключаете телефон)'
$S_I3 = 'старые копии разделов с телефона — на компьютер (0–2 мин)'
$S_I4A = 'отправка ядра v{0} на телефон (≈10 с)'
$S_I4B = 'переход в режим установки Apply from ADB (≈1 мин и ваши нажатия)'
$S_I4B_TWRP = 'переход в режим установки ADB Sideload (≈1 мин и ваши нажатия)'
$S_GO_TWRP = 'переход в рекавери TWRP / OrangeFox (≈1 мин)'
$S_I5_COPY = 'установщик ядра v{0}, проход 1 — копия разделов, ничего не записывается (≈1–2 мин)'
$S_I5_FRESH = 'установщик ядра v{0}, проход 1 — LineageOS / crDroid / Evolution X: только копия разделов; TWRP / OrangeFox с открытой памятью: копия и запись ядра (≈1–2 мин)'
$S_I5_A = 'установщик ядра v{0} — копия разделов и запись ядра за один проход (≈1–2 мин)'
$S_I5_ONE = 'установщик ядра v{0}, проход 1 — копия разделов и запись ядра (≈1–2 мин)'
$S_I5_REUSE = 'установщик ядра v{0}, проход 1 — копия уже есть, сразу запись ядра (≈1–2 мин)'
$S_I6 = 'копия разделов — на компьютер и проверка (≈1 мин)'
$S_I7_TWO = 'установщик ядра v{0}, проход 2 — запись ядра (≈1–2 мин)'
$S_I7_ONE = 'запись уже сделана на шаге 5 — перезагрузка и проверка'
$S_I7_DONE = 'запись уже сделана — перезагрузка и проверка'
$S_R1 = 'выбор и проверка копии на компьютере (секунды)'
$S_R2 = 'поиск телефона и проверки (до 3 мин, пока вы подключаете телефон)'
$S_R3A = 'подготовка: restore-zip на телефон (≈10 с)'
$S_R3B = 'подготовка: переход в рекавери и в режим Apply from ADB (≈1 мин и ваши нажатия)'
$S_R3_REC = 'подготовка: режим Apply from ADB (ваши нажатия)'
$S_R3_TWRP = 'подготовка: переход в рекавери TWRP / OrangeFox (≈1 мин)'
$S_R4 = 'возврат образов restore-zip''ом (≈30 с)'
$S_R5 = 'проверка слота и перезагрузка'
$S_B1 = 'проверка файла ядра v{0} (секунды)'
$S_B2 = 'поиск телефона и проверки (до 3 мин, пока вы подключаете телефон)'
$S_B3 = 'переход в рекавери и в режим Apply from ADB (≈1 мин и ваши нажатия)'
$S_B3_REC = 'переход в режим установки Apply from ADB (ваши нажатия)'
$S_B3_TWRP = 'переход в режим установки ADB Sideload (ваши нажатия)'
$S_B4 = 'установщик ядра v{0}, проход 1 — копия разделов, ничего не записывается (≈1–2 мин)'
$S_B5 = 'копия на компьютер и проверка (≈1 мин)'
$S_Q_I4 = 'переход в режим установки Apply from ADB (ваши нажатия)'
$S_Q_I5_1 = 'установщик ядра v{0}, отправка 1 из 2 — копия слота в памяти телефона, ничего не записывается (≈1–2 мин)'
$S_Q_I6_2 = 'установщик ядра v{0}, отправка 2 из 2 — запись ядра (≈1–2 мин)'
$S_Q_I5_W = 'установщик ядра v{0} — запись ядра (копия из прохода 1 уже в памяти телефона) (≈1–2 мин)'
$S_Q_I5 = 'установщик ядра v{0} (≈1–2 мин)'
$S_Q_CHECK = 'перезагрузка и проверка версии ядра'
$S_Q_R4 = 'возврат образов restore-zip''ом через Apply from ADB (≈30 с)'
$S_BA3 = 'копия разделов слота {0} на телефоне (≈1 мин)'
$S_BA4 = 'копия разделов — на компьютер и проверка (≈1 мин)'
$S_SKIP = '  (на этом шаге делать нечего: {0})'
# --- the final summary ---
$U_HEAD = '================ ИТОГ ================'
$U_FOOT = '======================================'
$U_INSTALLED = 'Установлено: ядро v{0} ({1}{2}), файл {3}'               # version, release, «, KernelSU: …» or nothing, file
$U_RESTORED = 'Возвращено: ядро {0} в слот {1} (папка {2})'
$U_BACKUP = 'Сохранена копия разделов (ничего не записано)'
$U_NOTHING = 'Ничего не записано: {0}.'
$U_ROLLED = 'Ядро v{0} не установлено: установщик вернул исходные образы, слот {1} как до установки.'
$U_WHAT_NOW = 'ЧТО ДЕЛАТЬ СЕЙЧАС: {0}'
$U_WAY = 'Способ: {0}'
$U_WAY_A = 'из работающей системы с root через USB, за один проход'
$U_WAY_B2 = 'рекавери, adb sideload в два прохода ({0})'
$U_WAY_B1 = 'рекавери, adb sideload за один проход ({0})'
$U_SLOT_W = 'Слот: {0} — boot{0}, vendor_boot{0}, dtbo{0} записаны и проверены установщиком'
$U_WAS = 'Было: {0}'
$U_STOCK = 'Стоковые образы: {0}'
$U_STOCK_NONE = 'Стоковых образов этой прошивки на компьютере нет.'
$U_STOCK_OTHER = 'Стоковые образы этого слота, возможно, другой сборки прошивки: {0}'
$U_STOCK_FPR = 'Стоковые образы (совпали с прошивкой только по отпечатку): {0}'
$U_STOCK_OTHERB = 'Стоковые образы этого слота от другой сборки прошивки: {0}'
$U_STOCK_OLDER = 'Стоковые образы этого слота, скорее всего, от прошлой сборки прошивки: {0}'
$U_PREV = 'Прошлая сборка {1}: {0}'
$U_PHONECOPY = 'Копия на телефоне: {0}'
$U_PULLDIR = 'Прочие файлы этого запуска: {0}'
$U_BACK_STOCK = 'Как вернуться на стоковое ядро:'
$U_BACK_PREV = 'Как вернуться на прошлую сборку:'
$U_BACK_MENU2 = '  • флешер: пункт 2 меню ({0} restore-stock);'
$U_BACK_MENU3 = '  • флешер: пункт 3 меню ({0} restore-prev);'
$U_BACK_COPY = 'Как вернуть образы из копии:'
$U_BACKDIR = 'Копия разделов: {0}'
$U_BACK_SIDELOAD = '  • вручную в рекавери: Apply update → Apply from ADB (TWRP: Advanced → ADB Sideload), затем на компьютере {0}:'
$U_BACK_FB = '  • если телефон не загружается: выключите его, зажмите Vol- и Power (режим fastboot) и на компьютере {0} по очереди:'
# (where the user types those commands)
$U_TERM_WIN = 'в командной строке (Win+R → cmd → Enter)'
$U_TERM_NIX = 'в Терминале'
$U_BACK_DRIVER = '    (Windows: если fastboot пишет «waiting for any device», нужен Google USB Driver — README-flash-ru.txt, раздел 2.)'
$U_LOG = 'Журнал: {0}'
# --- added for the flows (same ids in run-flash.sh) ---
$M_LOST = 'Связь с телефоном прервалась — жду, когда он снова появится…'
$M_BOOT_TIMEOUT = 'ОШИБКА: телефон не загрузился или не был разблокирован за 10 минут. Разблокируйте его и запустите флешер снова.'
$M_SL_STALL = 'передача стоит на месте 5 минут'
$M_SL_STALL99 = 'установщик на телефоне не закончил работу за 15 минут'
$M_REBOOT_FAILED = 'ОШИБКА: телефон не перезагрузился по команде adb. Перезагрузите его в рекавери вручную (выключите, затем зажмите громкость вверх + питание до логотипа) и запустите флешер снова.'
$M_REBOOTED_WAITING = 'ОШИБКА: телефон перезагрузился в систему, пока флешер ждал режим Apply from ADB. Ничего не записано. Запустите флешер снова.'
$M_UNC_NODIR = 'установщик не назвал папку копии'
$M_A_STEP1 = 'ОШИБКА: установщик в системе сделал только копию разделов и ничего не записал. Запустите флешер снова; не поможет — установите ядро через рекавери (install-recovery).'
$M_PREV_RESULT = 'Итог прошлой установки на телефоне: {0}.'
$M_PREV_DONE = 'ядро установлено'
$M_PREV_CLEAN = 'установщик остановился, ничего не записано'
$M_PREV_ROLLED = 'установщик остановился и вернул исходные образы'
$M_PREV_DIRTY = 'установщик не смог вернуть исходные образы'
$M_PREV_UNKNOWN = 'итог не ясен'
$M_PREV_RZ = 'На телефоне есть итог прошлого возврата образов: {0}.'
$M_PREV_RZ_OK = 'образы возвращены'
$M_PREV_RZ_FAIL = 'возврат не выполнен'
$M_ALREADY_DONE_A = 'Ядро v{0} уже установлено прошлым запуском флешера (так пишет журнал установщика). Ставить ещё раз не нужно.'
$M_INTERNAL_PHONE = 'Если на телефоне шла установка — не перезагружайте его несколько минут, затем запустите флешер снова: он прочитает журнал установщика.'
$U_RESCUED = 'Ядро v{0} не установлено: исходные образы возвращены в слот {1} restore-zip''ом (проверено по sha256).'
$U_NOOP = 'Ничего делать не нужно: слот {0} уже содержит образы из {1}'
$U_READY = 'Готово.'
$U_ROLLED0 = 'Ядро не установлено: установщик вернул исходные образы.'
$U_UNCONF = 'Итог не подтверждён — см. сообщения выше.'
$U_NOTHING0 = 'Ничего не записано.'
$U_NOTHING_SEE = 'Ничего не записано (см. сообщения выше).'
$U_NOT_CONFIRMED = 'Итог установки ядра v{0} не подтверждён.'
$U_NOT_CONFIRMED1 = 'Итог шага 1 не подтверждён — запись не начиналась.'
$U_NOT_CONFIRMED_T = 'Итог установки ядра v{0} не подтверждён (установка шла дольше 15 минут).'
$U_SAME = 'Ядро v{0} не установлено: установщик остановился, слот {1} не изменился (sha256 совпадает с копией на компьютере).'
$U_DIRTY = 'ОШИБКА: ядро v{0} записано не полностью, установщик не смог вернуть исходные образы.'
$U_HALF = 'ОШИБКА: установка ядра v{0} оборвалась на середине записи, слот {1} записан не полностью.'
$U_CHANGED = 'ОШИБКА: слот {0} изменился, хотя установщик написал, что ничего не записал.'
$U_UNREAD = 'Итог не подтверждён: разделы слота {0} не прочитались.'
$U_REBOOTED = 'Итог установки неизвестен: телефон перезагрузился раньше, чем флешер прочитал журнал.'
$U_REBOOTED1 = 'Ничего не записано: телефон перезагрузился после шага 1.'
$U_UNAUTH1 = 'Ничего не записано: рекавери не пускает компьютер по ADB.'
$U_LOCKED = 'Ничего не записано: загрузчик заблокирован.'
$U_PULL_LOST = 'Ничего не записано: копию разделов не удалось забрать на компьютер.'
$U_PC_SPACE = 'Ничего не записано: на диске компьютера мало места для копии разделов.'
$U_VERIFY_BAD = 'Ничего не записано: копия разделов не прошла проверку на компьютере.'
$U_RZ_NONE = 'Ничего не записано: установщик не смог сделать restore-zip.'
$U_NOCOPY = 'Ничего не записано: копии разделов нет на компьютере.'
$U_NOCOPY_RAM = 'Ничего не записано: копию из памяти рекавери не удалось забрать на компьютер.'
$U_INSTALLED_EARLIER = 'Установлено: ядро v{0} ({1}), файл {2} (в этом сеансе рекавери, раньше)'
$U_WAY_B_EARLIER = 'рекавери, adb sideload ({0}; установлено раньше в этом сеансе рекавери)'
$U_SLOT = 'Слот: {0}'
$U_TRIES = 'Ничего не записано: файл не удалось передать на телефон.'
$U_TRIES_W = 'Итог неизвестен: передача файла прерывалась {0} раза.'
$U_CLEAN = 'Ничего не записано: установщик ядра v{0} остановился (причина выше).'
$U_AK3 = 'Ничего не записано: установщик остановился в самом начале.'
$U_A_STEP1 = 'Ничего не записано: установщик сделал только копию разделов.'
$U_GATE_NO = 'Ничего не записано: нет стоковых образов на компьютере (вы ответили «нет»).'
$U_BACKUP_PHONE = 'Сохранены копии из памяти телефона (ничего не записано)'
$U_DIRTY_RZ = 'ОШИБКА: возврат записал слот {0} не полностью.'
$U_RZ_REFUSED = 'Возврат не выполнен, ничего не записано.'
$U_RZ_NOT_CONFIRMED = 'Итог возврата не подтверждён.'
$U_RZ_REBOOTED = 'Итог возврата не подтверждён: телефон перезагрузился.'
$U_RZ_UNAUTH = 'Итог возврата не подтверждён: рекавери не пускает компьютер по ADB.'
$U_TODO_DIRTY = 'Не перезагружайте телефон. Верните образы restore-zip''ом (пункт 2 или 3 меню флешера) или через fastboot из папки копии.'
$U_TODO_HALF = 'Не перезагружайте телефон. Верните образы restore-zip''ом (пункт 2 или 3 меню флешера) или через fastboot из папки {0}.'
$U_TODO_CHANGED = 'Не перезагружайте телефон. Верните образы restore-zip''ом из папки {0} (пункт 2 или 3 меню флешера) или через fastboot.'
$U_TODO_SAME = 'Запустите флешер снова; если это повторится — приложите run-flash.log к сообщению на форуме.'
$U_TODO_UNC_A = 'Не перезагружайте телефон несколько минут, потом запустите флешер снова — он прочитает итог установки на телефоне.'
$U_TODO_UNC_B = 'Оставьте телефон в рекавери и посмотрите на его экран: «Done: … written and read back.» — ядро установлено; «Aborting...» — нет.'
$U_TODO_UNAUTH = 'Не перезагружайте телефон и посмотрите на его экран (см. выше).'
$U_TODO_TIMEOUT = 'Не перезагружайте телефон ещё 5 минут, потом запустите флешер снова — он прочитает итог.'
$U_TODO_RZ_DIRTY = 'Не перезагружайте телефон в систему. Запишите образы через fastboot из папки {0} (команды выше).'
$U_BOOT = 'Загрузка: телефон загрузился с ядром {0}'
$U_BOOT_OTHER = 'Загрузка: телефон загрузился с ядром {0} (ожидалось {1})'
$U_BOOT_UNAUTH = 'Загрузка: телефон загрузился (версию ядра проверьте сами)'
$U_BOOT_NONE = 'Загрузка: телефон не появился в системе за 5 минут'
$U_BOOT_UNC = 'Загрузка: не подтверждена'
$U_NOTE_PHONE = 'Копия разделов осталась только на телефоне: {0}'
$U_REC_UNKNOWN = 'рекавери'
$M_WAY_B_REC_BAK = 'Копию разделов сделает рекавери (adb sideload, только шаг 1 установщика) — телефон уже в рекавери.'
$U_WAY_B_RAM = 'рекавери, adb sideload (копия из шага 1 этого сеанса; {0})'
$U_WAY_BAK = 'рекавери, adb sideload (только шаг 1: копия)'
$U_WAY_RA = 'из работающей системы с root через USB'
$U_WAY_RB = 'рекавери, adb sideload'
$U_WAY_Q = 'рекавери без root ({0}), Apply from ADB'
$U_WAY_Q_N = ', отправок: {0}'
$U_WAY_A_BAK = 'из работающей системы с root через USB (флешер прочитал разделы слота)'
$U_NR_END = 'Ничего не записано: root для adb в системе нет, а ADB рекавери работает без root.'
$U_A_BAK_FAIL = 'Ничего не записано: копию разделов не удалось сохранить на компьютере.'
$U_Q_OK = 'Установлено: ядро v{0} ({1}{2}), файл {3} — проверено по версии работающего ядра'
$U_Q3_OK = 'Возвращено: ядро {0} в слот {1} (папка {2}), проверено по версии работающего ядра'
$U_Q_OLD = 'Ядро v{0} не установлено: телефон загрузился со старым ядром {1}.'
$U_Q3_OLD = 'Образы не вернулись: телефон загрузился с прежним ядром {0}.'
$U_Q_SKIP = 'Итог не подтверждён: проверка версии ядра пропущена.'
$U_Q_UNAUTH = 'Итог не подтверждён: версию ядра флешер не увидел.'
$U_Q_NOBOOT = 'Итог не подтверждён: телефон не загрузился в систему.'
$U_Q_OTHER = 'Итог не подтверждён (см. сообщения выше).'
$U_QB_OK = 'Проверка: телефон загрузился с ядром {0}'
$U_QB_OLD = 'Проверка: телефон загрузился с ядром {0} (как до отправки)'
$U_QB_OTHER = 'Проверка: телефон загрузился с ядром {0} (слот {1}), ожидалось {2}'
$U_QB_NONE = 'Проверка: телефон не загрузился в систему за {0} мин'
$U_QB_SKIP = 'Проверка: пропущена'
$U_QB_UNAUTH = 'Проверка: телефон загрузился, но версию ядра флешер не увидел'
$U_TODO_Q_NOBOOT = 'Если телефон не загружается — верните образы из копии {0} (команды ниже).'
$U_TODO_Q3_NOBOOT = 'Если телефон не загружается — запишите образы через fastboot из папки {0} (команды выше).'

########################################################################
# run-flash.log: masked (adb serials, profile folder, user and computer
# name, MAC and IP addresses, e-mail and user@host); the screen shows full
# PC paths, the log shows them masked
function Update-Mask {
  $rules = New-Object System.Collections.ArrayList
  foreach ($s in $Script:Serials) { [void]$rules.Add(@([regex]::Escape($s), '<serial>')) }
  $prof = $env:USERPROFILE
  if (-not $prof) { $prof = $env:HOME }
  if ($prof -and $prof.Length -gt 3) { [void]$rules.Add(@(('(?i)' + [regex]::Escape($prof)), '%USERPROFILE%')) }
  $skip = @('root', 'user', 'admin', 'guest', 'shell', 'home', 'localhost')
  foreach ($n in @($env:USERNAME, $env:USER, $env:COMPUTERNAME, [Environment]::MachineName)) {
    if ($n -and $n.Length -ge 3 -and ($skip -notcontains $n.ToLowerInvariant())) {
      $rep = '<user>'
      if ($n -eq $env:COMPUTERNAME -or $n -eq [Environment]::MachineName) { $rep = '<host>' }
      [void]$rules.Add(@(('(?i)(?<![A-Za-z0-9_])' + [regex]::Escape($n) + '(?![A-Za-z0-9_])'), $rep))
    }
  }
  [void]$rules.Add(@('([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}', 'xx:xx:xx:xx:xx:xx'))
  [void]$rules.Add(@('[A-Za-z0-9._%+-]+@[A-Za-z0-9._-]+', '<user@host>'))
  # (not inside version numbers such as V816.0.5.0.ULIMIXM)
  [void]$rules.Add(@('(?<![0-9A-Za-z.])([0-9]{1,3}\.){3}[0-9]{1,3}(?![0-9A-Za-z.])', 'ipv4'))
  [void]$rules.Add(@('(?<![0-9A-Za-z:.])[0-9a-fA-F]{1,4}(:[0-9a-fA-F]{0,4}){3,7}(?![0-9A-Za-z:])', 'ipv6'))
  $Script:MaskRules = $rules.ToArray()
}
function Mask-Text([string]$t) {
  if ($null -eq $t) { return '' }
  foreach ($r in $Script:MaskRules) { $t = [regex]::Replace($t, $r[0], $r[1]) }
  return $t
}
function Add-Serial([string]$s) {
  if (-not $s) { return }
  if (-not $Script:Serials.Contains($s)) { $Script:Serials.Add($s); Update-Mask }
}

# Write-Log <text>: into run-flash.log only (masked, with the time)
function Write-Log([string]$t, [bool]$raw = $false) {
  $ts = (Get-Date).ToString('HH:mm:ss')
  $sb = New-Object System.Text.StringBuilder
  foreach ($l in ($t -split "`r?`n")) {
    if (-not $raw) { $l = Mask-Text $l }
    [void]$sb.Append($ts + ' ' + $l + "`r`n")
  }
  if ($Script:LogPath) {
    try { [IO.File]::AppendAllText($Script:LogPath, $sb.ToString(), $Utf8) } catch { }
  } else { [void]$Script:LogBuf.Append($sb.ToString()) }
}
# a line of progress dots ends before any other output
function Close-Dots { if ($Script:DotOpen) { Write-Host ''; $Script:DotOpen = $false } }
function Write-Dot { Write-Host -NoNewline '.'; $Script:DotOpen = $true }
# on the screen and in the log
function Say([string]$t) { Close-Dots; Write-Host $t; Write-Log $t }
function WarnM([string]$t) { Close-Dots; Write-Host $t -ForegroundColor Yellow; Write-Log $t }
function ErrM([string]$t) { Close-Dots; Write-Host $t -ForegroundColor Red; Write-Log $t }
function GoodM([string]$t) { Close-Dots; Write-Host $t -ForegroundColor Green; Write-Log $t }
# Head <text>: a cyan line without a step number
function Head([string]$t) { Close-Dots; Write-Host $t -ForegroundColor Cyan; Write-Log $t }
function Dim([string]$t) { Close-Dots; Write-Host $t -ForegroundColor DarkGray; Write-Log $t }
# Ring: the terminal bell, and a beep on Windows (where the console has one)
function Ring {
  try { [Console]::Write([char]7) } catch { }
  if ($IsWin) { try { [Console]::Beep(880, 200) } catch { } }
}
# Hint <text> [bell]: what to tap on the phone (yellow); the bell when the user must act
function Hint([string]$t, [bool]$bell = $true) {
  Close-Dots
  Write-Host $t -ForegroundColor Yellow
  Write-Log $t
  if ($bell) { Ring }
}
# Step <text>: «Шаг N из M: …», N counts up by itself
function Step([string]$t) {
  $Script:StepN++
  Close-Dots
  Write-Host ''
  $s = 'Шаг {0} из {1}: {2}' -f $Script:StepN, $Script:StepM, $t
  Write-Host $s -ForegroundColor Cyan
  Write-Log $s
}
function Format-Elapsed([int]$s) {
  if ($s -ge 60) { return ('{0} мин {1} с' -f [int][Math]::Floor($s / 60), ($s % 60)) }
  return ('{0} с' -f $s)
}
function Format-Size([long]$n) {
  if ($n -ge 1073741824) { return ('{0:0.0} ГБ' -f ($n / 1073741824.0)).Replace('.', ',') }
  if ($n -ge 1048576) { return ('{0:0.0} МБ' -f ($n / 1048576.0)).Replace('.', ',') }
  return ('{0} КБ' -f [int][Math]::Ceiling($n / 1024.0))
}
function Format-PhoneTime([long]$t, [string]$fmt) {
  try { return [DateTimeOffset]::FromUnixTimeSeconds($t).ToLocalTime().ToString($fmt) } catch { return '?' }
}
# Show-Block <lines>: installer text quoted on the screen, «  | <line>»
function Show-Block([string[]]$lines) {
  foreach ($l in $lines) { Say ('  | ' + $l) }
}

########################################################################
# exit, keys, Ctrl+C
function Stop-Run([int]$code) { $Script:ExitCode = $code; throw 'RUNFLASH-EXIT' }
function Test-Exit($e) { return ("$e" -eq 'RUNFLASH-EXIT') }

function Clear-Keys {
  $Script:EnterPressed = $false; $Script:EscPressed = $false
  if (-not $Script:KeysOk) { return }
  try { while ([Console]::KeyAvailable) { [void][Console]::ReadKey($true) } } catch { }
}
function Test-CtrlC($k) {
  return ((($k.Key -eq [ConsoleKey]::C) -and (($k.Modifiers -band [ConsoleModifiers]::Control) -ne 0)) -or ([int]$k.KeyChar -eq 3))
}
# Read-KeyX: ENTER, ESC, INT or the character
function Read-KeyX {
  if (-not $Script:KeysOk) { return 'ESC' }
  $k = [Console]::ReadKey($true)
  if ($k.Key -eq [ConsoleKey]::Enter) { return 'ENTER' }
  if ($k.Key -eq [ConsoleKey]::Escape) { return 'ESC' }
  if (Test-CtrlC $k) { return 'INT' }
  return [string]$k.KeyChar
}
# Get-KeyKind <key from Read-KeyX>: one key table for every question (as
# run-flash.sh key_name): YES = Enter, Д, д and L, l (the Д key in the Latin
# layout); NO = Esc, Ctrl+C, Н, н, N, n; AMBIG = Y, y (the same key as Н in
# the Russian layout: it could mean either, so the question is asked again);
# else the key itself (a digit of a menu)
function Get-KeyKind([string]$k) {
  if ($k -eq 'ENTER' -or @('Д', 'д', 'L', 'l') -ccontains $k) { return 'YES' }
  if ($k -eq 'ESC' -or $k -eq 'INT' -or @('Н', 'н', 'N', 'n') -ccontains $k) { return 'NO' }
  if (@('Y', 'y') -ccontains $k) { return 'AMBIG' }
  return $k
}
# Read-YesNo: Enter, Д (L) = yes; Esc, Н, N (or Ctrl+C) = no; Y asked again;
# any other key: the line with the keys; without a console: the default
function Read-YesNo([bool]$default) {
  if (-not $Script:KeysOk) { return $default }
  while ($true) {
    $k = Read-KeyX
    switch (Get-KeyKind $k) {
      'YES' { Write-Log ('answer: {0} (yes)' -f $k); return $true }
      'NO' { Write-Log ('answer: {0} (no)' -f $k); return $false }
      'AMBIG' { Write-Log 'answer: Y (asked again)'; Say $M_KEYS_AMBIG }
      default { Say $M_KEYS }
    }
  }
}
# Ask-Yes <text> [bell]: keys pressed before are dropped, then the question
function Ask-Yes([string]$t, [bool]$bell = $false) {
  Clear-Keys
  WarnM $t
  if ($bell) { Ring }
  return (Read-YesNo $false)
}

# Get-CancelText: what the user is told when the flasher stops now, by phase
#   pre      nothing was sent to the phone
#   wait     the phone was told to reboot / is in recovery, no copy in RAM
#   ramcopy  a copy of the slot exists only in the recovery's RAM
#   ramonpc  that copy is on the PC (before the writing pass)
#   running  a sideload or the installer may be running on the phone
#   done     the flash ended (reboot offer, boot check)
function Get-CancelText([string]$ph) {
  switch ($ph) {
    'pre' { return $M_CANCEL_PRE }
    # (a copy in the RAM of a recovery whose ADB has no root cannot be taken: no «do not reboot»)
    'wait' { if ((Test-RamUnsaved) -and -not $Script:Rnr) { return $M_CANCEL_RAM }; return $M_CANCEL_WAIT }
    'ramcopy' { return $M_CANCEL_RAM }
    'ramonpc' {
      $p = ''; if ($Script:Sum.ContainsKey('RamPc')) { $p = [string]$Script:Sum['RamPc'] }
      return ($M_CANCEL_RAMPC -f $p)
    }
    'running' {
      # (a send of Q2 / Q3: no log to read in that recovery)
      if ($Script:QKind -and $Script:RunWrites) { return ($M_CANCEL_QRUN -f $Script:QWant) }
      if ($Script:QKind) { return $M_CANCEL_QRUN1 }
      return $M_CANCEL_RUN
    }
    'q2' { return ($M_CANCEL_Q2 -f $Script:QWant) }
    'seen' { return $M_CANCEL_SEEN }
    default { return $M_CANCEL_DONE }
  }
  return $M_CANCEL_DONE
}
# Test-RamUnsaved: the last recovery probe listed a copy in the recovery's
# RAM that is not on the PC (verified) yet: a reboot would lose it
function Test-RamUnsaved {
  if ($null -eq $Script:Rec) { return $false }
  foreach ($b in @($Script:Rec.Baks)) {
    if (-not $b -or -not $b.StartsWith($Script:REC_TMP + '/')) { continue }
    $c = Get-CopyOf $b
    if ($null -eq $c -or -not $c.Ok) { return $true }
  }
  return $false
}
# Invoke-Cancel [code] [timeout]: stop now, say what state the phone is in.
# Without a code the phase decides: 11 cancelled (10 when a wait timed out
# with no key pressed) while nothing can have been written, 13 while a pass
# that may write runs, after the flash its own result
function Invoke-Cancel([int]$code = -1, [bool]$timeout = $false) {
  if ($null -ne $Script:AdbProc) { try { $Script:AdbProc.Kill() } catch { }; $Script:AdbProc = $null }
  $ph = $Script:Phase
  if ($ph -eq 'pull') {
    foreach ($f in @($Script:PullPartial)) { try { if ([IO.File]::Exists($f)) { [IO.File]::Delete($f) } } catch { } }
    $Script:PullPartial.Clear()
    # (the unverified part of the copy being pulled goes too; kept folders are never touched)
    if ($Script:PullCurDir) { try { if ([IO.Directory]::Exists($Script:PullCurDir)) { [IO.Directory]::Delete($Script:PullCurDir, $true) } } catch { }; $Script:PullCurDir = $null }
    $ph = $Script:PrePullPhase
  }
  Write-Log ('stopped (phase {0}, timeout {1})' -f $ph, $timeout)
  $txt = Get-CancelText $ph
  WarnM $txt; $Script:PhaseSaid = $true
  $writes = (($ph -eq 'running' -or $ph -eq 'q2') -and $Script:RunWrites)
  $after = ($ph -eq 'done' -or $ph -eq 'boot')
  if ($code -lt 0) {
    $code = $RC_CANCEL; if ($timeout) { $code = $RC_FAIL }
    if ($writes) { $code = $RC_ATTN }
    if ($after) { $code = $Script:FlashRc }
  }
  if ($Script:PhoneTouched) {
    if (-not $Script:Sum.ContainsKey('Result')) {
      if ($writes) { $Script:Sum['Result'] = 'unconfirmed' } else { $Script:Sum['Result'] = 'stopped' }
    }
    try { Show-Summary $code } catch { if (Test-Exit $_) { throw } }
  }
  Stop-Run $code
}
function Invoke-CancelAsk {
  Close-Dots
  Write-Host ''
  if ($Script:Phase -eq 'boot') { $Script:EscPressed = $true; return }
  if ($Script:Phase -eq 'running') {
    if (Ask-Yes $M_CANCEL_RUN_Q) { Say $M_GO_ON; return }
    Invoke-Cancel
  }
  $q = $M_CANCEL_Q
  if ($Script:Phase -eq 'pull') { $q = $M_CANCEL_PULL_Q }
  if (Ask-Yes $q) { Invoke-Cancel }
  Say $M_GO_ON
}
# Test-Interrupt: in every wait; Ctrl+C asks, Enter and Esc are remembered
function Test-Interrupt {
  if (-not $Script:KeysOk) { return }
  $hit = $false
  try {
    while ([Console]::KeyAvailable) {
      $k = [Console]::ReadKey($true)
      if (Test-CtrlC $k) { $hit = $true; break }
      $ch = [string]$k.KeyChar
      # (the key table of Get-KeyKind; Y means nothing here)
      if ($k.Key -eq [ConsoleKey]::Enter -or @('Д', 'д', 'L', 'l') -ccontains $ch) { $Script:EnterPressed = $true }
      if ($k.Key -eq [ConsoleKey]::Escape -or @('Н', 'н', 'N', 'n') -ccontains $ch) { $Script:EscPressed = $true }
    }
  } catch { return }
  if ($hit) { Invoke-CancelAsk }
}
function Wait-Sec([double]$sec) {
  $sw = [Diagnostics.Stopwatch]::StartNew()
  while ($sw.Elapsed.TotalSeconds -lt $sec) { Start-Sleep -Milliseconds 200; Test-Interrupt }
}

function Open-Folder([string]$dir) {
  if (-not ($Script:Menu -or $Script:FromCmdline) -or -not $IsWin -or -not $dir) { return }
  try {
    $ex = Join-Path $env:SystemRoot 'explorer.exe'
    Start-Process -FilePath $ex -ArgumentList ('"' + $dir + '"')
  } catch { Write-Log ('explorer: ' + $_) }
}
function Show-Failed {
  Write-Host ''
  if ($Script:LogPath) { ErrM ($M_FAILED -f $Script:LogPath) } else { ErrM 'Не получилось.' }
}
# Get-WhyShort <message>: its first sentence, for the summary line
function Get-WhyShort([string]$t) {
  $t = ($t -replace '^(ОШИБКА|ВНИМАНИЕ): ', '').Trim()
  $i = $t.IndexOf('. ')
  if ($i -gt 0) { $t = $t.Substring(0, $i) }
  return $t.TrimEnd('.')
}
# Fail <text> [code]: stop with an explanation. Once something was sent to
# the phone and no outcome is known yet, the summary says what the stop
# means for the slot: nothing written (before any pass that may write), or
# not confirmed (a pass that may write had started: exit 13)
function Fail([string]$t, [int]$code = 10) {
  if ($t) { ErrM $t }
  if ($Script:PhoneTouched -and -not $Script:Sum.ContainsKey('Result')) {
    $ph = $Script:Phase; if ($ph -eq 'pull') { $ph = $Script:PrePullPhase }
    if ((($ph -eq 'running' -or $ph -eq 'q2') -and $Script:RunWrites) -or $code -eq $RC_ATTN) {
      $Script:Sum['Result'] = 'unconfirmed'
      if ($code -eq $RC_FAIL) { $code = $RC_ATTN }
    } elseif ($ph -ne 'done' -and $ph -ne 'boot' -and $code -ne $RC_OK) {
      $Script:Sum['Result'] = 'nothing'
      if ($t -and -not $Script:Sum.ContainsKey('Why')) { $Script:Sum['Why'] = Get-WhyShort $t }
    }
  }
  Show-Summary $code
  Stop-Run $code
}

########################################################################
# arguments, help, menu
function Show-Help {
  $l = $Launcher; $pad = ' ' * ($l.Length + 27)
  Write-Host 'Запуск:'
  Write-Host ('  {0}                         меню' -f $l)
  Write-Host ('  {0} install [файл.zip]      установить ядро (способ выбирается сам)' -f $l)
  Write-Host ('  {0} install-system [файл]   установить из работающей системы с root' -f $l)
  Write-Host ('  {0} install-recovery [файл] установить через рекавери (adb sideload)' -f $l)
  Write-Host ('  {0} restore-stock [папка]   вернуть стоковое ядро (копия на компьютере)' -f $l)
  Write-Host ('  {0} restore-prev [папка]    вернуть прошлую сборку ядра taoyao' -f $l)
  Write-Host ($pad + '(копии в taoyao-<серия>-backups)')
  Write-Host ('  {0} backup [файл.zip]       только сохранить копию разделов' -f $l)
  Write-Host ('  {0} help                    эта справка' -f $l)
  Write-Host ('  {0} <файл.zip>              то же, что install <файл.zip>' -f $l)
  if ($IsWin) { Write-Host ($pad + '(можно перетащить zip на run-flash.bat)') }
  Write-Host ''
  Write-Host 'Файл ядра (taoyao-6.12-vX.XX.zip или taoyao-6.12-vX.XX-noksu.zip) флешер'
  Write-Host 'ищет рядом с собой и в текущей папке; из нескольких берёт самое новое.'
  Write-Host 'Ответы на вопросы: Enter или Д — да; Esc или Н — нет (в латинской'
  Write-Host 'раскладке: L — да, N — нет; на Y флешер переспросит: это клавиша Н).'
  Write-Host 'Подробно: README-flash-ru.txt.'
  Write-Host ''
  Write-Host 'Коды выхода: 0 — готово; 10 — остановлено, ничего не записано; 11 —'
  Write-Host 'отменено вами; 12 — установщик начал запись и вернул исходные образы;'
  Write-Host '13 — внимание: состояние слота не подтверждено (см. сообщения).'
}

# Split-CmdLine <text>: blanks outside quotes separate, quotes are removed
# (no backslash rules: a dropped folder "C:\dir\" keeps its backslash)
function Split-CmdLine([string]$s) {
  $out = New-Object 'System.Collections.Generic.List[string]'
  $cur = New-Object System.Text.StringBuilder
  $inq = $false; $has = $false
  foreach ($ch in $s.ToCharArray()) {
    if ($ch -eq [char]34) { $inq = -not $inq; $has = $true; continue }
    if (-not $inq -and ($ch -eq ' ' -or $ch -eq "`t")) {
      if ($has) { $out.Add($cur.ToString()); [void]$cur.Clear(); $has = $false }
      continue
    }
    [void]$cur.Append($ch); $has = $true
  }
  if ($has) { $out.Add($cur.ToString()) }
  return $out.ToArray()
}
# Get-BatArgs: the arguments of run-flash.bat from cmd's own command line
# (RUNFLASH_CMDLINE, taken with delayed expansion, where "&" stays plain
# text; %* would be cut at an unquoted "&" of a dropped path). The .bat is
# found by its full path (RUNFLASH_BATF, %~f0), else by its name followed by
# a quote, a blank or the end; the first such place after cmd's "/c" counts
# (a dropped file's folder may hold the same name)
function Get-BatArgs {
  $cl = [string]$env:RUNFLASH_CMDLINE
  $bat = [string]$env:RUNFLASH_BAT
  $batf = [string]$env:RUNFLASH_BATF
  if (-not $cl -or -not $bat) { return }
  $low = $cl.ToLowerInvariant()
  $from = 0
  $mc = [regex]::Match($low, '(^|\s)/[ck](\s|")')
  if ($mc.Success) { $from = $mc.Index }
  $j = -1
  if ($batf) {
    $i = $low.IndexOf($batf.ToLowerInvariant(), $from)
    if ($i -ge 0) { $j = $i + $batf.Length }
  }
  if ($j -lt 0) {
    $i = $from
    while ($true) {
      $i = $low.IndexOf($bat.ToLowerInvariant(), $i)
      if ($i -lt 0) { return }
      $e = $i + $bat.Length
      if ($e -ge $cl.Length -or $cl[$e] -eq [char]34 -or [char]::IsWhiteSpace($cl[$e])) { $j = $e; break }
      $i = $e
    }
  }
  if ($j -lt $cl.Length -and $cl[$j] -eq [char]34) { $j++ }
  $rest = $cl.Substring($j)
  $nq = 0; foreach ($ch in $rest.ToCharArray()) { if ($ch -eq [char]34) { $nq++ } }
  $t = $rest.TrimEnd()
  if (($nq % 2) -eq 1 -and $t.EndsWith('"')) { $rest = $t.Substring(0, $t.Length - 1) }
  return @(Split-CmdLine $rest)
}

# Read-Args <list>: sets Mode (menu, help, install, install-system,
# install-recovery, backup, restore-stock, restore-prev) and ArgPath;
# returns 'ok' or 'bad:<word>'
function Read-Args([string[]]$a) {
  $Script:Mode = ''; $Script:ArgPath = ''; $Script:ArgNote = ''
  $list = New-Object 'System.Collections.Generic.List[string]'
  foreach ($x in $a) { if ($null -ne $x -and ([string]$x).Trim()) { $list.Add(([string]$x).Trim()) } }
  if ($list.Count -eq 0) { $Script:Mode = 'menu'; return 'ok' }
  $w = $list[0].ToLowerInvariant()
  if ($w.StartsWith('--')) { $w = $w.Substring(2) }
  if (@('help', '-h', 'h', '/?', '-?', '?', '/h', 'справка') -contains $w) { $Script:Mode = 'help'; return 'ok' }
  $words = @('install', 'install-system', 'install-recovery', 'backup', 'restore-stock', 'restore-prev')
  if ($words -contains $w) {
    $Script:Mode = $w
    if ($list.Count -ge 2) { $Script:ArgPath = $list[1] }
    if ($list.Count -ge 3) { return ('bad:' + $list[2]) }
    return 'ok'
  }
  # a path alone: a kernel zip (or a folder) dropped on run-flash.bat
  $first = ''
  foreach ($x in $list) {
    if ($x.ToLowerInvariant().EndsWith('.zip')) { $first = $x; break }
  }
  if (-not $first -and $list.Count -eq 1) {
    $p = $list[0]
    try { if ([IO.Directory]::Exists($p)) { $first = $p } } catch { }
  }
  if (-not $first) { return ('bad:' + $list[0]) }
  $Script:Mode = 'install'; $Script:ArgPath = $first; $Script:Dropped = $true
  if ($list.Count -gt 1) { $Script:ArgNote = ($M_DROP_MANY -f [IO.Path]::GetFileName($first)) }
  return 'ok'
}

function Get-RestoreCount([string]$kind) {
  $n = 0
  foreach ($f in @(Get-FiledFolders)) { if ($f.Class -eq $kind -and $f.Restorable) { $n++ } }
  return $n
}
function Show-Menu {
  Write-Host ''
  Write-Host 'Что сделать? Нажмите цифру:'
  Write-Host ''
  $z = $Script:Zip
  if ($null -ne $z) { Write-Host ('  1  Установить ядро v{0} ({1})' -f (Get-ZipShownVer $z), $z.Name) }
  else { Write-Host '  1  Установить ядро — файл ядра не найден' }
  Write-Host ('  2  Вернуть стоковое ядро (копий на компьютере: {0})' -f (Get-RestoreCount 'STOCK'))
  Write-Host '  3  Вернуть прошлую сборку ядра taoyao (копии в taoyao-<серия>-backups)'
  Write-Host ('     копий на компьютере: {0}' -f (Get-RestoreCount 'PREV'))
  Write-Host '  4  Только сохранить копию разделов (ничего не записывается)'
  $ok = @(Get-ValidZips)
  if ($ok.Count -gt 1) { Write-Host ('  5  Выбрать другой файл ядра (найдено: {0})' -f $ok.Count) }
  Write-Host ''
  Write-Host '  0  Выход'
}
# Select-OtherZip: menu 5, the valid zips newest first (at most 9)
function Select-OtherZip {
  $ok = @(Get-ValidZips)
  Write-Host ''
  Say $M_PICK_ZIP
  $n = [Math]::Min(9, $ok.Count)
  for ($i = 0; $i -lt $n; $i++) { Say ('  {0}  v{1}  {2}' -f ($i + 1), (Get-ZipShownVer $ok[$i]), $ok[$i].Name) }
  while ($true) {
    $k = Read-KeyX
    # (Esc, Н / N, Ctrl+C and 0: back to the menu, as run-flash.sh pick_zip)
    if ($k -eq '0' -or (Get-KeyKind $k) -eq 'NO') { return }
    $d = 0
    if ([int]::TryParse($k, [ref]$d) -and $d -ge 1 -and $d -le $n) {
      Set-Zip $ok[$d - 1]
      Say ($M_ZIP_FOUND -f (Get-ZipShownVer $Script:Zip), $Script:Zip.Name)
      return
    }
  }
}
function Show-MenuChoice {
  # (keys pressed before the menu is shown are dropped, as run-flash.sh menu)
  Clear-Keys
  Show-Menu
  :menu while ($true) {
    $k = Read-KeyX
    $max = 4; if (@(Get-ValidZips).Count -gt 1) { $max = 5 }
    switch ($k) {
      '1' {
        if ($null -eq $Script:Zip) { Say ($M_ZIP_NONE -f $Here); Show-Menu; continue menu }
        $Script:Mode = 'install'
      }
      '2' {
        if ((Get-RestoreCount 'STOCK') -eq 0) { ErrM ($M_RESTORE_NONE -f $M_RESTORE_NONE_STOCK, (Join-Path $Script:Base $Script:PC_STOCK)); Show-Menu; continue menu }
        $Script:Mode = 'restore-stock'
      }
      '3' {
        if ((Get-RestoreCount 'PREV') -eq 0) { ErrM $M_RESTORE_NONE_PREV; Show-Menu; continue menu }
        $Script:Mode = 'restore-prev'
      }
      '4' {
        if ($null -eq $Script:Zip) { Say ($M_ZIP_NONE -f $Here); Show-Menu; continue menu }
        $Script:Mode = 'backup'
      }
      '5' {
        if ($max -lt 5) { Say ('Нажмите цифру от 0 до {0}.' -f $max); continue menu }
        Select-OtherZip; Show-Menu; continue menu
      }
      '0' { $Script:Mode = 'exit' }
      # (Esc, Н / N and Ctrl+C: the same as 0, as run-flash.sh menu)
      { (Get-KeyKind $_) -eq 'NO' } { $Script:Mode = 'exit' }
      default { Say ('Нажмите цифру от 0 до {0}.' -f $max); continue menu }
    }
    Write-Log ('menu: {0} -> {1}' -f $k, $Script:Mode)
    return
  }
}

########################################################################
# files: sha256, zips
try { Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem } catch { }

function Get-Sha256([string]$path) {
  $fs = [IO.File]::Open($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
  try {
    $h = [Security.Cryptography.SHA256]::Create()
    try { $b = $h.ComputeHash($fs) } finally { $h.Dispose() }
  } finally { $fs.Dispose() }
  return ([BitConverter]::ToString($b) -replace '-', '').ToLowerInvariant()
}
function Get-FileLen([string]$path) {
  try { return (New-Object IO.FileInfo $path).Length } catch { return [long]-1 }
}
# Read-ZipText <archive> <entry>: the entry as text (CR removed), or $null
function Read-ZipText($za, [string]$name) {
  $e = $za.GetEntry($name)
  if ($null -eq $e) { return $null }
  $s = $e.Open()
  try {
    $r = New-Object IO.StreamReader($s, $Utf8)
    try { return $r.ReadToEnd().Replace("`r", '') } finally { $r.Dispose() }
  } finally { $s.Dispose() }
}
# Save-ZipEntry <zip path> <entry> <file>: one entry to a file; $true if written
function Save-ZipEntry([string]$zip, [string]$name, [string]$dest) {
  $za = [IO.Compression.ZipFile]::OpenRead($zip)
  try {
    $e = $za.GetEntry($name)
    if ($null -eq $e) { return $false }
    $s = $e.Open()
    try {
      $o = [IO.File]::Create($dest)
      try { $s.CopyTo($o) } finally { $o.Dispose() }
    } finally { $s.Dispose() }
    return ((Get-FileLen $dest) -eq $e.Length)
  } finally { $za.Dispose() }
}
function Get-Lines([string]$t) {
  if ($null -eq $t) { return }
  return @($t.Replace("`r", '') -split "`n")
}

# version keys: (major, minor, patch) compared numerically part by part
function Get-VerKey([string]$v) {
  $p = @($v.Split('.'))
  $k = @(0, 0, 0)
  for ($i = 0; $i -lt 3 -and $i -lt $p.Count; $i++) { $n = 0; [void][int]::TryParse($p[$i], [ref]$n); $k[$i] = $n }
  return ,$k
}
function Compare-Ver([string]$a, [string]$b) {
  $x = Get-VerKey $a; $y = Get-VerKey $b
  for ($i = 0; $i -lt 3; $i++) {
    if ($x[$i] -lt $y[$i]) { return -1 }
    if ($x[$i] -gt $y[$i]) { return 1 }
  }
  return 0
}
# Get-RelVer <kernel release>: "0.19" of 6.12.96-taoyao-v0.19, else ''
function Get-RelVer([string]$rel) {
  $m = [regex]::Match([string]$rel, '-v([0-9]+(\.[0-9]+)+)$')
  if ($m.Success) { return $m.Groups[1].Value }
  return ''
}
function Get-Series([string]$rel) {
  $m = [regex]::Match([string]$rel, '^([0-9]+\.[0-9]+)\.')
  if ($m.Success) { return $m.Groups[1].Value }
  return ''
}
# Test-PortSeries <kernel release>: a build of this port (as run-flash.sh
# in_port): it matches REL_RE (...-taoyao-v<n>.<n>, any series), or its
# series is in PORT_SERIES or is the chosen zip's series; else the ROM's own
function Test-PortSeries([string]$rel) {
  if ([regex]::IsMatch([string]$rel, $Script:REL_RE)) { return $true }
  $s = Get-Series $rel
  if (-not $s) { return $false }
  $l = @($Script:PORT_SERIES.Split(' ') | Where-Object { $_ })
  if ($null -ne $Script:Zip -and $Script:Zip.Series) { $l += [string]$Script:Zip.Series }
  return ($l -contains $s)
}

# New-ZipCand <path>: a kernel zip candidate from its name (or $null)
function New-ZipCand([string]$path) {
  $name = [IO.Path]::GetFileName($path)
  $low = $name.ToLowerInvariant()
  if ($low -match $Script:ZIP_SKIP_RE) { return $null }
  $m = [regex]::Match($low, $Script:ZIP_RE)
  if (-not $m.Success) { return $null }
  $ver = $m.Groups[2].Value + '.' + $m.Groups[3].Value
  if ($m.Groups[5].Success) { $ver += '.' + $m.Groups[5].Value }
  $fi = New-Object IO.FileInfo $path
  return [pscustomobject]@{
    Path = $fi.FullName; Name = $name; Dir = $fi.DirectoryName; Size = $fi.Length; Mtime = $fi.LastWriteTimeUtc
    Series = $m.Groups[1].Value; Ver = $ver; NoKsu = $m.Groups[6].Success
    CopyN = $(if ($m.Groups[8].Success) { $m.Groups[8].Value } else { '' })
    Ok = $false; Reason = ''; Rel = ''; Ksu = ''; VerLine = ''; ShaFile = ''; Sha = ''
    Gen = 1; BackupName = ''; Stores = ''; LastLog = ''; KString = ''; Checked = $false; Wrapper = ''
  }
}
# Test-Zip <cand>: the checks Z1-Z8; sets Ok, or Reason (an ОШИБКА text)
function Test-Zip($c) {
  $c.Checked = $true
  $za = $null
  try { $za = [IO.Compression.ZipFile]::OpenRead($c.Path) }
  catch { $c.Reason = ($M_ZIP_BROKEN -f $c.Name); return }
  try {
    # Z2: a wrapper (GitHub's artifact download holds the real zip): no
    # anykernel.sh, and an entry that is a kernel zip by its name
    $files = @($za.Entries | Where-Object { -not $_.FullName.EndsWith('/') })
    if ($null -eq $za.GetEntry('anykernel.sh')) {
      foreach ($e in $files) {
        $en = [IO.Path]::GetFileName($e.FullName)
        if ($en.ToLowerInvariant() -match $Script:ZIP_RE) {
          $c.Wrapper = $e.FullName
          $c.Reason = ($M_ZIP_WRAPPER -f $c.Name, $en); return
        }
      }
    }
    # Z3: our files
    foreach ($n in $Script:ZIP_NEED) {
      if ($null -eq $za.GetEntry($n)) { $c.Reason = ($M_ZIP_NOTOURS -f $c.Name, $n); return }
    }
    # Z4: AnyKernel3, for taoyao, device check on
    $ub = Read-ZipText $za 'META-INF/com/google/android/update-binary'
    $ak = @(Get-Lines (Read-ZipText $za 'anykernel.sh'))
    $c.KString = ''
    $dev = '?'; $hasDev = $false; $hasChk = $false
    foreach ($l in $ak) {
      if ($l -match $Script:AK_DEVICE_RE) { $hasDev = $true }
      if ($l -match $Script:AK_CHECK_RE) { $hasChk = $true }
      if ($l.StartsWith('device.name1=')) { $dev = $l.Substring(13) }
      if ($l.StartsWith('kernel.string=') -and -not $c.KString) { $c.KString = $l.Substring(14) }
    }
    if (-not $ub.Contains($Script:UB_MARK)) { $c.Reason = ($M_ZIP_NOTOURS -f $c.Name, ('AnyKernel3 в ' + 'META-INF/com/google/android/update-binary')); return }
    if (-not ($hasDev -and $hasChk)) { if (-not $dev) { $dev = '?' }; $c.Reason = ($M_ZIP_NOTTAOYAO -f $c.Name, $dev); return }
    # Z5: kernel.release against the name
    $rel = (Read-ZipText $za 'vmods/kernel.release').Trim()
    $c.Rel = $rel
    $vtext = Read-ZipText $za 'version'
    $vl = @(Get-Lines $vtext)
    $vline = ''; foreach ($l in $vl) { if ($l -match $Script:VERFILE_RE) { $vline = $l; break } }
    $shown = $vline; if (-not $shown -and $vl.Count -gt 0) { $shown = $vl[0] }
    $mr = [regex]::Match($rel, $Script:REL_RE)
    if (-not $mr.Success -or $mr.Groups[1].Value -ne $c.Series -or (Compare-Ver $mr.Groups[2].Value $c.Ver) -ne 0) {
      $c.Reason = ($M_ZIP_RENAMED -f $c.Name, $c.Ver, $rel, $shown); return
    }
    # Z6: the version file
    if (-not $vline) { $c.Reason = ($M_ZIP_NOVERSION -f $c.Name); return }
    $c.VerLine = $vline
    $mv = [regex]::Match($vline, $Script:VERFILE_RE)
    $m1 = [regex]::Match([string]$vl[0], $Script:VERLINE1_RE)
    $ksu = ''; if ($m1.Success) { $ksu = $m1.Groups[2].Value.Trim() }
    $c.Ksu = $ksu
    if ($m1.Success -and ($c.NoKsu -ne ($ksu -eq $Script:KSU_NONE))) {
      $want = 'сборка без KernelSU (noksu)'; if (-not $c.NoKsu) { $want = 'сборка с KernelSU' }
      $c.Reason = ($M_ZIP_KSU -f $c.Name, $want, $ksu); return
    }
    if ((Compare-Ver $mv.Groups[1].Value $c.Ver) -ne 0 -or -not $m1.Success -or $m1.Groups[1].Value.Trim() -ne $rel) {
      $c.Reason = ($M_ZIP_RENAMED -f $c.Name, $c.Ver, $rel, ([string]$vl[0] + ' / ' + $vline)); return
    }
    # values the installer uses (4.4)
    $ty = Read-ZipText $za 'tools/ty-lib.sh'
    # generation: 1 = text markers only (0.18), 2 = taoyao-result lines, 3 = also a taoyao-run id per pass
    $c.Gen = 1; if ($ty.Contains($Script:GEN2_MARK)) { $c.Gen = 2 }
    if ($c.Gen -eq 2 -and $ty.Contains($Script:GEN3_MARK)) { $c.Gen = 3 }
    foreach ($l in (Get-Lines $ty)) {
      $x = [regex]::Match($l, '^TY_BACKUPNAME=(.*);$'); if ($x.Success -and -not $c.BackupName) { $c.BackupName = $x.Groups[1].Value }
      $x = [regex]::Match($l, '^TY_STORES="(.*)";$'); if ($x.Success -and -not $c.Stores) { $c.Stores = $x.Groups[1].Value }
    }
    $x = [regex]::Match($ty, '/(taoyao-[A-Za-z0-9.]+-last\.log)'); if ($x.Success) { $c.LastLog = $x.Groups[1].Value }
    # Z8: every entry readable to its end (the installer's own unzip checks the CRCs)
    $buf = New-Object byte[] 65536
    foreach ($e in $files) {
      $s = $e.Open()
      try {
        $n = [long]0
        while ($true) { $r = $s.Read($buf, 0, $buf.Length); if ($r -le 0) { break }; $n += $r }
        if ($n -ne $e.Length) { throw 'length' }
      } finally { $s.Dispose() }
    }
  } catch {
    if (Test-Exit $_) { throw }
    $c.Reason = ($M_ZIP_BROKEN -f $c.Name); return
  } finally { if ($null -ne $za) { $za.Dispose() } }
  # Z7: a .sha256 file next to it
  $cands = @($c.Path + '.sha256')
  if ($c.CopyN) {
    $base = [regex]::Replace($c.Name, ' ?\([0-9]+\)(\.[Zz][Ii][Pp])$', '$1')
    $cands += (Join-Path $c.Dir ($base + '.sha256'))
  }
  foreach ($sf in $cands) {
    if (-not [IO.File]::Exists($sf)) { continue }
    $want = ''
    try {
      $m = [regex]::Match([IO.File]::ReadAllText($sf), '[0-9A-Fa-f]{64}')
      if ($m.Success) { $want = $m.Value.ToLowerInvariant() }
    } catch { }
    $got = Get-Sha256 $c.Path
    $c.Sha = $got; $c.ShaFile = [IO.Path]::GetFileName($sf)
    if ($want -ne $got) { $c.Reason = ($M_ZIP_SHA_BAD -f $c.Name, $c.ShaFile); return }
    break
  }
  $c.Ok = $true
}
function Get-ReasonText([string]$t) { return ($t -replace '^ОШИБКА: ', '') }

# Expand-Wrapper <cand>: the kernel zip inside a wrapper zip, next to it,
# after a yes; the path of the extracted zip, or ''. A wrapper with the same
# name as the zip inside is replaced by it (it holds nothing else we need).
function Expand-Wrapper($c) {
  $inner = [IO.Path]::GetFileName($c.Wrapper)
  $dest = Join-Path $c.Dir $inner
  $same = [string]::Equals($inner, $c.Name, [StringComparison]::OrdinalIgnoreCase)
  if (-not $same -and [IO.File]::Exists($dest)) { Write-Log ('wrapper {0}: {1} is there already' -f $c.Name, $inner); return $dest }
  if (-not $Script:KeysOk) { ErrM $c.Reason; return '' }
  if (-not (Ask-Yes ($M_ZIP_WRAPPER_ASK -f $c.Name, $inner, $c.Dir))) { return '' }
  $part = $dest + '.part'; $old = Join-Path $c.Dir ($c.Name + '.wrapper')
  try {
    if ([IO.File]::Exists($part)) { [IO.File]::Delete($part) }
    if (-not (Save-ZipEntry $c.Path $c.Wrapper $part)) { throw 'длина не совпала' }
    if ($same) {
      if ([IO.File]::Exists($old)) { [IO.File]::Delete($old) }
      [IO.File]::Move($c.Path, $old)
      try { [IO.File]::Move($part, $dest) } catch { [IO.File]::Move($old, $c.Path); throw }
      try { [IO.File]::Delete($old) } catch { Write-Log ('wrapper not removed: ' + $_.Exception.Message) }
    } else { [IO.File]::Move($part, $dest) }
  } catch {
    if (Test-Exit $_) { throw }
    try { if ([IO.File]::Exists($part)) { [IO.File]::Delete($part) } } catch { }
    Write-Log ('wrapper not extracted: ' + $_.Exception.GetBaseException().Message)
    ErrM ($M_ZIP_WRAPPER_FAIL -f $inner, $c.Name)
    return ''
  }
  GoodM ($M_ZIP_WRAPPER_DONE -f $dest)
  Write-Log ('wrapper extracted: {0} -> {1}' -f $c.Name, $inner)
  return $dest
}

# Get-BadNameText <path>: why a zip given by its path (or dropped) is not
# taken although it is a file: its name is not a kernel zip's name. A kernel
# zip of ours that was renamed is told so (with the name to give it back).
function Get-BadNameText([string]$path) {
  $gn = [IO.Path]::GetFileName($path)
  $za = $null
  try { $za = [IO.Compression.ZipFile]::OpenRead($path) } catch { return ($M_ZIP_BROKEN -f $gn) }
  try {
    if ($null -ne $za.GetEntry('anykernel.sh') -and $null -ne $za.GetEntry('vmods/kernel.release')) {
      $rel = (Read-ZipText $za 'vmods/kernel.release').Trim()
      $m = [regex]::Match($rel, $Script:REL_RE)
      $want = 'taoyao-6.12-vX.XX.zip'
      if ($m.Success) {
        $want = 'taoyao-' + $m.Groups[1].Value + '-v' + $m.Groups[2].Value
        $v1 = @(Get-Lines (Read-ZipText $za 'version'))
        if ($v1.Count -gt 0) { $k = [regex]::Match([string]$v1[0], $Script:VERLINE1_RE); if ($k.Success -and $k.Groups[2].Value.Trim() -eq $Script:KSU_NONE) { $want += '-noksu' } }
        $want += '.zip'
      }
      return ($M_ZIP_BADNAME -f $gn, $rel, $want)
    }
    foreach ($e in $za.Entries) {
      $en = [IO.Path]::GetFileName($e.FullName)
      if ($en.ToLowerInvariant() -match $Script:ZIP_RE) { return ($M_ZIP_WRAPPER -f $gn, $en) }
    }
  } catch { if (Test-Exit $_) { throw } } finally { $za.Dispose() }
  return ($M_ZIP_NOTOURS -f $gn, 'anykernel.sh')
}
# Find-Zips: candidates by name, newest first, each checked; sets $Script:Zip
function Find-Zips {
  $given = ''
  for ($round = 1; $round -le 2; $round++) {
    $Script:Zips.Clear(); $Script:Zip = $null
    $dirs = New-Object 'System.Collections.Generic.List[string]'
    $files = New-Object 'System.Collections.Generic.List[string]'
    if ($given) { $files.Add($given) }
    elseif ($Script:ArgPath) {
      $p = $Script:ArgPath
      try { $p = [IO.Path]::GetFullPath([IO.Path]::Combine((Get-Location).ProviderPath, $p)) } catch { }
      if ([IO.Directory]::Exists($p)) { $dirs.Add($p) }
      elseif ([IO.File]::Exists($p)) { $files.Add($p); $given = $p }
      else { ErrM ($M_ZIP_NOTFOUND -f $p); Stop-Run $RC_FAIL }
    } else {
      $dirs.Add($Here)
      try {
        $cwd = (Get-Location).ProviderPath
        if ($cwd -and ([IO.Path]::GetFullPath($cwd).TrimEnd('\', '/') -ne [IO.Path]::GetFullPath($Here).TrimEnd('\', '/'))) { $dirs.Add($cwd) }
      } catch { }
    }
    $near = New-Object 'System.Collections.Generic.List[string]'
    foreach ($d in $dirs) {
      try { foreach ($f in [IO.Directory]::GetFiles($d)) { if ([IO.Path]::GetFileName($f).ToLowerInvariant().EndsWith('.zip')) { $files.Add($f) } } } catch { }
    }
    $cands = New-Object System.Collections.ArrayList
    foreach ($f in $files) {
      $c = New-ZipCand $f
      if ($null -ne $c) { [void]$cands.Add($c); continue }
      $low = [IO.Path]::GetFileName($f).ToLowerInvariant()
      if (-not $given -and $low -match $Script:ZIP_NEAR_RE -and $low -notmatch $Script:ZIP_SKIP_RE) { $near.Add([IO.Path]::GetFileName($f)) }
    }
    if ($given -and $cands.Count -eq 0) {
      ErrM (Get-BadNameText $given)
      Stop-Run $RC_FAIL
    }
    # newest first (the same version: the newer series first, 6.18 before
    # 6.12); KernelSU build before -noksu; the original before "(n)"; newer file first
    $sorted = @($cands | Sort-Object -Property `
        @{ Expression = { (Get-VerKey $_.Ver)[0] }; Descending = $true },
        @{ Expression = { (Get-VerKey $_.Ver)[1] }; Descending = $true },
        @{ Expression = { (Get-VerKey $_.Ver)[2] }; Descending = $true },
        @{ Expression = { (Get-VerKey $_.Series)[0] }; Descending = $true },
        @{ Expression = { (Get-VerKey $_.Series)[1] }; Descending = $true },
        @{ Expression = { [int]$_.NoKsu }; Descending = $false },
        @{ Expression = { $n = 0; [void][int]::TryParse([string]$_.CopyN, [ref]$n); $n }; Descending = $false },
        @{ Expression = { $_.Mtime }; Descending = $true })
    # the same version twice, byte for byte: keep the one without "(n)"
    $keep = New-Object System.Collections.ArrayList
    foreach ($c in $sorted) {
      $dup = $false
      foreach ($k in $keep) {
        if ($k.Ver -eq $c.Ver -and $k.NoKsu -eq $c.NoKsu -and $k.Size -eq $c.Size -and $k.Path -ne $c.Path) {
          try { if ((Get-Sha256 $k.Path) -eq (Get-Sha256 $c.Path)) { $dup = $true; Write-Log ('same file twice: ' + $c.Name); break } } catch { }
        }
      }
      if (-not $dup) { [void]$keep.Add($c) }
    }
    $again = $false
    foreach ($c in $keep) {
      Test-Zip $c
      [void]$Script:Zips.Add($c)
      Write-Log ('zip {0}: ok={1} rel={2} gen={3} {4}' -f $c.Name, $c.Ok, $c.Rel, $c.Gen, $c.Reason)
      if ($c.Ok) { if ($null -eq $Script:Zip) { Set-Zip $c } ; continue }
      # (a wrapper: offered once per run; then the folder is read again)
      if ($c.Wrapper -and $round -eq 1) {
        $x = Expand-Wrapper $c
        if ($x) { $again = $true; if ($given) { $given = $x }; continue }
        if ($given) { Stop-Run $RC_FAIL }
      }
      if ($given) { ErrM $c.Reason; Stop-Run $RC_FAIL }
      if (-not $Script:Warned.ContainsKey($c.Path)) { $Script:Warned[$c.Path] = 1; WarnM ($M_ZIP_SKIPPED -f $c.Name, (Get-ReasonText $c.Reason)) }
    }
    if (-not $again) { break }
  }
  $ok = @(Get-ValidZips)
  if ($ok.Count -eq 0) {
    Say ($M_ZIP_NONE -f $Here)
    if ($near.Count -gt 0) { WarnM ($M_ZIP_NEAR -f [string]::Join(', ', $near.ToArray())) }
    return
  }
  if ($ok.Count -eq 1) { Say ($M_ZIP_FOUND -f (Get-ZipShownVer $Script:Zip), $Script:Zip.Name) }
  else {
    Say ($M_ZIP_SEVERAL -f $ok.Count, (Get-ZipShownVer $Script:Zip), $Script:Zip.Name)
    if ($Script:Mode -eq 'menu') { Say $M_ZIP_SEVERAL_MENU } else { Say ($M_ZIP_SEVERAL_CMD -f $Launcher) }
  }
}
function Get-ValidZips { return @($Script:Zips | Where-Object { $_.Ok }) }
# Get-ZipShownVer <cand>: the version as the lists show it (v0.19-noksu)
function Get-ZipShownVer($c) { if ($c.NoKsu) { return ($c.Ver + '-noksu') }; return $c.Ver }
# Set-Zip <cand>: the zip to flash, and the installer's paths from it
function Set-Zip($c) {
  $Script:Zip = $c
  if ($c.BackupName) { $Script:BACKUP_NAME = $c.BackupName } else { Write-Log 'zip: no TY_BACKUPNAME, default kept' }
  if ($c.Stores) { $Script:STORES = $c.Stores } else { Write-Log 'zip: no TY_STORES, default kept' }
  if ($c.LastLog) { $Script:LAST_LOG = $c.LastLog } else { Write-Log 'zip: no last-log name, default kept' }
  Write-Log ('chosen: {0} ({1}; {2}); backup name {3}, stores {4}, last log {5}, installer generation {6}' -f $c.Name, $c.Rel, $c.KString, $Script:BACKUP_NAME, $Script:STORES, $Script:LAST_LOG, $c.Gen)
}
# Show-ZipInfo: step 1 of install and backup
function Show-ZipInfo {
  $c = $Script:Zip
  Say ($M_ZIP_INFO1 -f $c.Name, (Format-Size $c.Size))
  Say ($M_ZIP_INFO2 -f $c.Rel, $c.Ksu)
  if ($c.ShaFile) { GoodM ($M_ZIP_SHA_OK -f $c.ShaFile) }
  if ($c.CopyN) { GoodM ($M_ZIP_COPY -f $c.Name, $c.CopyN, $c.Ver) }
}

########################################################################
# adb processes
function Quote-WinArg([string]$a) {
  if ($a.Length -gt 0 -and $a -notmatch '[\s"]') { return $a }
  $sb = New-Object System.Text.StringBuilder
  [void]$sb.Append('"')
  $bs = 0
  foreach ($ch in $a.ToCharArray()) {
    if ($ch -eq [char]92) { $bs++; continue }
    if ($ch -eq [char]34) {
      [void]$sb.Append((New-Object string ([char]92), (2 * $bs + 1)))
      [void]$sb.Append('"'); $bs = 0; continue
    }
    if ($bs -gt 0) { [void]$sb.Append((New-Object string ([char]92), $bs)); $bs = 0 }
    [void]$sb.Append($ch)
  }
  [void]$sb.Append((New-Object string ([char]92), (2 * $bs)))
  [void]$sb.Append('"')
  return $sb.ToString()
}
function Start-AdbProc([string[]]$A, [string]$Dir, [bool]$NoSerial, [string]$Exe) {
  $all = New-Object 'System.Collections.Generic.List[string]'
  if (-not $NoSerial -and $Script:Serial) { $all.Add('-s'); $all.Add($Script:Serial) }
  foreach ($x in $A) { $all.Add($x) }
  $q = New-Object 'System.Collections.Generic.List[string]'
  foreach ($x in $all) { $q.Add((Quote-WinArg $x)) }
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  if ($Exe) { $psi.FileName = $Exe } else { $psi.FileName = $Script:Adb }
  $psi.Arguments = [string]::Join(' ', $q.ToArray())
  if ($Dir) { $psi.WorkingDirectory = $Dir } else { $psi.WorkingDirectory = $Here }
  $psi.UseShellExecute = $false
  $psi.CreateNoWindow = $true
  $psi.RedirectStandardInput = $true
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.StandardOutputEncoding = $Utf8
  $psi.StandardErrorEncoding = $Utf8
  $p = New-Object System.Diagnostics.Process
  $p.StartInfo = $psi
  $tag = 'adb'; if ($Exe) { $tag = [IO.Path]::GetFileName($Exe) }
  Write-Log ('> ' + $tag + ' ' + $psi.Arguments)
  [void]$p.Start()
  try { $p.StandardInput.Close() } catch { }
  return $p
}
# Invoke-Adb: a captured adb call with a time limit (code 124 after it);
# Ctrl+C is read while it waits
function Invoke-Adb([string[]]$A, [int]$TimeoutSec = 20, [string]$Dir = '', [bool]$NoSerial = $false, [string]$Exe = '', [bool]$NoLog = $false) {
  $p = Start-AdbProc $A $Dir $NoSerial $Exe
  $Script:AdbProc = $p
  $to = $p.StandardOutput.ReadToEndAsync()
  $te = $p.StandardError.ReadToEndAsync()
  $sw = [Diagnostics.Stopwatch]::StartNew()
  $timedOut = $false
  while (-not $p.WaitForExit(200)) {
    Test-Interrupt
    if ($sw.Elapsed.TotalSeconds -ge $TimeoutSec) {
      try { $p.Kill() } catch { }
      $timedOut = $true; break
    }
  }
  try { [void][Threading.Tasks.Task]::WaitAll([Threading.Tasks.Task[]]@($to, $te), 2000) } catch { }
  $o = ''; $e = ''
  if ($to.IsCompleted -and -not $to.IsFaulted) { $o = $to.Result }
  if ($te.IsCompleted -and -not $te.IsFaulted) { $e = $te.Result }
  $code = 124
  if (-not $timedOut) { try { $code = $p.ExitCode } catch { $code = 1 } }
  $Script:AdbProc = $null
  try { $p.Dispose() } catch { }
  $o = $o.Replace("`r", ''); $e = $e.Replace("`r", '')
  if (-not $NoLog) {
    $txt = ($o + $e)
    if ($txt.Length -gt 3000) { $txt = $txt.Substring(0, 3000) + ' […]' }
    Write-Log ('< rc={0} {1}' -f $code, $txt.TrimEnd())
  }
  return [pscustomobject]@{ Code = $code; Out = $o; Err = $e; TimedOut = $timedOut }
}
# Invoke-Dev <command> [root] [seconds]: adb shell; as root through su -c
function Invoke-Dev([string]$cmd, [bool]$root = $false, [int]$TimeoutSec = 30) {
  if ($cmd.Contains("'")) { throw 'кавычка в команде для телефона' }
  $full = $cmd
  if ($root -and -not $Script:AdbRoot) { $full = "su -c '" + $cmd + "'" }
  $r = Invoke-Adb @('shell', $full) $TimeoutSec
  $Script:Dc = $r
  return $r
}
function Test-Lost($r) {
  if ($null -eq $r) { return $false }
  return (($r.Out + $r.Err) -match "(?i)device '.*' not found|no devices/emulators found|device offline|device unauthorized|error: closed|protocol fault|connection reset|failed to get feature set|no device|device still authorizing")
}
# ConvertFrom-KV <text>: key=value lines -> @{ H = first value per key; All = all pairs }
function ConvertFrom-KV([string]$t) {
  $h = @{}; $all = New-Object System.Collections.ArrayList
  foreach ($l0 in ([string]$t -split "`n")) {
    $l = $l0.TrimEnd("`r")
    $i = $l.IndexOf('=')
    if ($i -le 0) { continue }
    $k = $l.Substring(0, $i); $v = $l.Substring($i + 1)
    if (-not $h.ContainsKey($k)) { $h[$k] = $v }
    [void]$all.Add(@($k, $v))
  }
  return @{ H = $h; All = $all }
}
function Get-KV($kv, [string]$key) {
  if ($kv.H.ContainsKey($key)) { return [string]$kv.H[$key] }
  return ''
}
function Get-KVAll($kv, [string]$key) {
  $r = New-Object 'System.Collections.Generic.List[string]'
  foreach ($p in $kv.All) { if ($p[0] -eq $key) { $r.Add($p[1]) } }
  return $r.ToArray()
}

########################################################################
# adb discovery
function Test-AdbVer([string]$v) {
  $m = [regex]::Match($v, '^(\d+)\.(\d+)\.(\d+)')
  if (-not $m.Success) { return $false }
  $n = [regex]::Match($Script:ADB_MIN, '^(\d+)\.(\d+)\.(\d+)')
  for ($i = 1; $i -le 3; $i++) {
    $a = [int]$m.Groups[$i].Value; $b = [int]$n.Groups[$i].Value
    if ($a -ne $b) { return ($a -gt $b) }
  }
  return $true
}
function Find-Adb {
  $cand = New-Object 'System.Collections.Generic.List[string]'
  if ($env:ADB) { $cand.Add($env:ADB) }
  if ($IsWin) {
    $cand.Add((Join-Path $Here 'adb.exe'))
    $cand.Add((Join-Path $Here 'platform-tools\adb.exe'))
    $cand.Add((Join-Path $Here 'platform-tools-latest-windows\platform-tools\adb.exe'))
  } else {
    $cand.Add((Join-Path $Here 'adb'))
    $cand.Add((Join-Path $Here 'platform-tools/adb'))
  }
  # (where Get-PlatformTools puts adb when the script folder is read-only)
  $ud = Get-PtUserDir
  if ($ud) { if ($IsWin) { $cand.Add((Join-Path $ud 'adb.exe')) } else { $cand.Add((Join-Path $ud 'adb')) } }
  try {
    $gc = @(Get-Command -Name adb -CommandType Application -ErrorAction SilentlyContinue)
    foreach ($g in $gc) { if ($g.Path) { $cand.Add($g.Path) } }
  } catch { }
  if ($IsWin) {
    foreach ($b in @($env:LOCALAPPDATA)) { if ($b) { $cand.Add((Join-Path $b 'Android\Sdk\platform-tools\adb.exe')) } }
    foreach ($b in @($env:ANDROID_HOME, $env:ANDROID_SDK_ROOT)) { if ($b) { $cand.Add((Join-Path $b 'platform-tools\adb.exe')) } }
    if ($env:USERPROFILE) {
      $cand.Add((Join-Path $env:USERPROFILE 'platform-tools\adb.exe'))
      $cand.Add((Join-Path $env:USERPROFILE 'Downloads\platform-tools\adb.exe'))
      $cand.Add((Join-Path $env:USERPROFILE 'Downloads\platform-tools-latest-windows\platform-tools\adb.exe'))
    }
    if ($env:LOCALAPPDATA) {
      $cand.Add((Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Links\adb.exe'))
      $pk = Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages'
      if ([IO.Directory]::Exists($pk)) {
        try {
          foreach ($d in @(Get-ChildItem -LiteralPath $pk -Directory -Filter 'Google.PlatformTools*' -ErrorAction SilentlyContinue)) {
            $cand.Add((Join-Path $d.FullName 'platform-tools\adb.exe'))
          }
        } catch { }
      }
    }
    $cand.Add('C:\platform-tools\adb.exe'); $cand.Add('C:\adb\adb.exe')
  } else {
    foreach ($b in @($env:ANDROID_HOME, $env:ANDROID_SDK_ROOT)) { if ($b) { $cand.Add((Join-Path $b 'platform-tools/adb')) } }
    foreach ($p in @('/opt/homebrew/bin/adb', '/usr/local/bin/adb', '/usr/bin/adb')) { $cand.Add($p) }
  }
  $seen = @{}
  $oldV = ''; $oldP = ''; $dllP = ''
  foreach ($p in $cand) {
    if (-not $p) { continue }
    $key = $p.ToLowerInvariant()
    if ($seen.ContainsKey($key)) { continue }
    $seen[$key] = 1
    if (-not [IO.File]::Exists($p)) { continue }
    # (an adb.exe without its DLLs is tried all the same: Scoop and Chocolatey
    # shims start the real one; the DLL hint is only for one that fails)
    $nodll = $false
    if ([IO.Path]::GetFileName($p).ToLowerInvariant() -eq 'adb.exe') {
      $dir = [IO.Path]::GetDirectoryName($p)
      if (-not ([IO.File]::Exists((Join-Path $dir 'AdbWinApi.dll')) -and [IO.File]::Exists((Join-Path $dir 'AdbWinUsbApi.dll')))) {
        $nodll = $true
        Write-Log ('adb candidate without its DLLs next to it: ' + $p)
      }
    }
    try { $r = Invoke-Adb @('version') 10 '' $true $p }
    catch {
      if (Test-Exit $_) { throw }
      Write-Log ('adb candidate does not start: {0} ({1})' -f $p, $_)
      if ($nodll -and -not $dllP) { $dllP = $p }
      continue
    }
    if ($r.Code -ne 0) {
      Write-Log ('adb candidate failed: ' + $p)
      if ($nodll -and -not $dllP) { $dllP = $p }
      continue
    }
    $m = [regex]::Match($r.Out, 'Android Debug Bridge version ([0-9][0-9.]*)')
    $v = ''; if ($m.Success) { $v = $m.Groups[1].Value }
    $inst = ''
    $mi = [regex]::Match($r.Out, '(?m)^Installed as (.+?)\s*$')
    if ($mi.Success) { $inst = $mi.Groups[1].Value }
    if (Test-AdbVer $v) {
      $Script:Adb = $p
      if ($inst -and [IO.File]::Exists($inst)) { $Script:Adb = $inst }
      $Script:AdbVer = $v
      Write-Log ('adb: {0} (version {1})' -f $Script:Adb, $v)
      return
    }
    Write-Log ('adb candidate too old ({0}): {1}' -f $v, $p)
    if (-not $oldV) { $oldV = $v; $oldP = $p }
  }
  # (no usable adb: offer SDK Platform-Tools from Google, as the log collector)
  if (Get-PlatformTools $oldV $oldP) { return }
  Write-Host ''
  if ($oldV) {
    $od = [IO.Path]::GetDirectoryName($oldP)
    if ($od -eq $Here -or $od -eq (Join-Path $Here 'platform-tools')) { ErrM ($M_ADB_OLD_HERE -f $oldV, $oldP, $Script:PT_URL) }
    else { ErrM ($M_ADB_OLD -f $oldV, $oldP, $Script:PT_URL) }
  }
  elseif ($dllP) { ErrM ($M_ADB_DLL -f $dllP) }
  else {
    ErrM $M_ADB_NONE
    if ($IsWin) {
      Say ($M_ADB_HOW1 -f $Script:PT_URL)
      Say ($M_ADB_HOW2 -f (Join-Path $Here 'platform-tools\adb.exe'))
      Say $M_ADB_HOW3
    } else { Say ($M_ADB_HOWX -f $Script:PT_URL) }
  }
  Fail ''
}
# Initialize-Adb: adb found and its server started, once per run (in step 2)
function Initialize-Adb {
  if ($Script:AdbUp) { return }
  Find-Adb
  Start-AdbServer
  Write-Log ($M_ADB -f $Script:Adb, $Script:AdbVer)
  $Script:AdbUp = $true
}
function Start-AdbServer {
  $r = Invoke-Adb @('start-server') 30 '' $true
  $txt = $r.Out + $r.Err
  if ($txt -match "doesn't match this client") { WarnM $M_ADB_CLASH }
  if ($r.Code -ne 0) {
    $first = ''
    foreach ($l in ($txt -split "`n")) { if ($l -and -not $l.StartsWith('*')) { $first = $l; break } }
    Fail ($M_ADB_NOSERVER -f $first)
  }
}

########################################################################
# the phone: devices and the one wait routine
# Scan-Devices [states the flow expects]: "adb devices -l" -> the state of
# our phone (none, device, recovery, sideload, unauthorized, offline,
# no permissions, authorizing, connecting, host, rescue, bootloader, multi,
# serialgone); sets $Script:Serial when one phone is ours. Once a phone is
# chosen, another serial is never taken for it when that serial was listed
# before in this run (an emulator, a second phone): only a new serial that
# says it is a taoyao (device:/product: of its line, or getprop in a shell
# state) while the chosen one is gone (some recoveries report another serial)
function Scan-Devices([string[]]$want = @()) {
  $r = Invoke-Adb @('devices', '-l') 10 '' $true '' $true
  $re = '^(\S+)\s+(no permissions|device|unauthorized|offline|recovery|sideload|bootloader|rescue|authorizing|connecting|host)(\s.*)?$'
  $items = New-Object System.Collections.ArrayList
  foreach ($l0 in ($r.Out -split "`n")) {
    $l = $l0.Trim()
    if (-not $l -or $l.StartsWith('*') -or $l.StartsWith('List of devices') -or $l.StartsWith('adb server') -or $l.StartsWith('error:')) { continue }
    $m = [regex]::Match($l, $re)
    if (-not $m.Success) { continue }
    $s = $m.Groups[1].Value
    Add-Serial $s
    $rest = $m.Groups[3].Value
    $model = '?'; $dn = ''; $prod = ''
    $mm = [regex]::Match($rest, 'model:(\S+)'); if ($mm.Success) { $model = $mm.Groups[1].Value }
    $md = [regex]::Match($rest, 'device:(\S+)'); if ($md.Success) { $dn = $md.Groups[1].Value }
    $mp = [regex]::Match($rest, 'product:(\S+)'); if ($mp.Success) { $prod = $mp.Groups[1].Value }
    [void]$items.Add([pscustomobject]@{ Ser = $s; St = $m.Groups[2].Value; Model = $model; Dev = $dn; Prod = $prod })
  }
  Write-Log (($r.Out + $r.Err).Trim())
  $Script:DItems = $items.ToArray()
  # (the serials listed before this scan; then this scan's join them)
  $prior = $Script:SeenSer.ToArray()
  foreach ($i in $items) { if (-not $Script:SeenSer.Contains($i.Ser)) { $Script:SeenSer.Add($i.Ser) } }
  $st = 'none'
  if ($env:ANDROID_SERIAL) {
    $st = 'none'
    foreach ($i in $items) { if ($i.Ser -eq $env:ANDROID_SERIAL) { $st = $i.St; $Script:Serial = $i.Ser } }
    return $st
  }
  if ($Script:Serial) {
    foreach ($i in $items) { if ($i.Ser -eq $Script:Serial) { return $i.St } }
    # (the serial normally stays the same in Android, recovery and sideload)
    $new = @($items | Where-Object { ($want -contains $_.St) -and ($prior -notcontains $_.Ser) })
    $ours = New-Object System.Collections.ArrayList
    foreach ($i in $new) { if (Test-SerTaoyao $i) { [void]$ours.Add($i) } }
    if ($ours.Count -eq 1) {
      $x = $ours[0]
      Write-Log ('serial changed: {0} -> {1} ({2})' -f (Mask-Text $Script:Serial), (Mask-Text $x.Ser), $x.St)
      $Script:Serial = $x.Ser
      return $x.St
    }
    foreach ($i in $items) { if ($prior -contains $i.Ser) { continue }; if ($ours -notcontains $i) { Write-Log ('new device not taken: ' + $i.St) } }
    return 'none'
  }
  if ($items.Count -eq 0) { return 'none' }
  if ($items.Count -eq 1) { $Script:Serial = $items[0].Ser; return $items[0].St }
  $tao = @($items | Where-Object { $_.Dev -eq $Script:DEVICE -or $_.Prod -like ($Script:DEVICE + '*') })
  if ($tao.Count -eq 1) {
    $Script:Serial = $tao[0].Ser
    if (-not $Script:MultiPick) { $Script:MultiPick = $true; Say $M_MULTI_PICKED }
    return $tao[0].St
  }
  return 'multi'
}
# Test-SerTaoyao <item>: a device line that names taoyao; with no such
# fields, in a shell state, getprop (asked once per serial)
function Test-SerTaoyao($i) {
  if ($i.Dev -or $i.Prod) { return ($i.Dev -eq $Script:DEVICE -or $i.Prod -like ($Script:DEVICE + '*')) }
  if (@('device', 'recovery') -notcontains $i.St) { return $false }
  if ($Script:SerChecked.ContainsKey($i.Ser)) { return [bool]$Script:SerChecked[$i.Ser] }
  $r = Invoke-Adb @('-s', $i.Ser, 'shell', 'getprop ro.product.device; getprop ro.build.product; getprop ro.boot.hwname') 15 '' $true
  $ok = $false
  foreach ($l in (Get-Lines $r.Out)) { if ($l.Trim() -eq $Script:DEVICE) { $ok = $true } }
  if ($r.Code -eq 0) { $Script:SerChecked[$i.Ser] = $ok }
  return $ok
}
# Select-Device: several phones, none clearly ours: the user picks one
function Select-Device {
  Close-Dots
  $it = @($Script:DItems)
  WarnM $M_MULTI_ASK
  $n = [Math]::Min(9, $it.Count)
  for ($i = 0; $i -lt $n; $i++) {
    $dn = $it[$i].Dev; if (-not $dn) { $dn = '?' }
    Say ($M_MULTI_ITEM -f ($i + 1), $it[$i].Model, $dn, $it[$i].St, $it[$i].Ser)
  }
  Ring
  while ($true) {
    $k = Read-KeyX
    # (Esc, Н / N and Ctrl+C: stop; the phase decides the text and the code)
    if ((Get-KeyKind $k) -eq 'NO') { Write-Log 'device list: stopped'; Invoke-Cancel }
    $d = 0
    if ([int]::TryParse($k, [ref]$d) -and $d -ge 1 -and $d -le $n) { $Script:Serial = $it[$d - 1].Ser; Write-Log 'device picked by the user'; return }
  }
}

# Wait-Phone: polls "adb devices" until the phone is in one of -Want (or
# -StopOn: returned for the caller to handle). A dot per poll; every T_HINT
# a "… жду" line, the hint again and the bell. At -Limit: "Enter — ждать
# ещё, Esc — остановиться" while the polling goes on; no key for another
# -Limit: the phase message and the exit (Invoke-Cancel decides the code by
# the phase). -EscSkip: Esc returns 'skip'. -UnauthLimit: 'unauthorized'
# this long is returned. -LimitText: said once at the limit, before the
# question. -MoreText: that question (default M_WAIT_MORE). -UnauthNote:
# said once after 60 s of 'unauthorized'.
function Wait-Phone {
  param(
    [string[]]$Want,
    [int]$Limit = 600,
    [string]$Hint = '',
    [int]$HintAfter = 0,
    [string[]]$StopOn = @(),
    [string]$Ctx = 'android',
    [int]$UnauthLimit = 0,
    [int]$Poll = 2,
    [hashtable]$StateHints = $null,
    [bool]$EscSkip = $false,
    [bool]$NoAsk = $false,
    [string]$NoneText = '',
    [bool]$Bell = $true,
    [string]$LimitText = '',
    [string]$MoreText = '',
    [string]$UnauthNote = ''
  )
  Clear-Keys
  $sw = [Diagnostics.Stopwatch]::StartNew()
  $last = '?'; $nextHint = [double]$HintAfter; $shownHint = ''
  $asked = -1.0; $unauthT = -1.0; $offT = -1.0; $reconn = $false; $noneT = -1.0; $nextLine = [double]$Script:T_HINT
  $Script:WaitSaw = New-Object 'System.Collections.Generic.List[string]'
  while ($true) {
    $st = Scan-Devices $Want
    if ($st -eq 'multi') { Select-Device; continue }
    if (-not $Script:WaitSaw.Contains($st)) { $Script:WaitSaw.Add($st) }
    if ($Want -contains $st -or $StopOn -contains $st) { Close-Dots; Write-Log ('phone state: ' + $st); return $st }
    $el = $sw.Elapsed.TotalSeconds
    if ($st -ne $last) {
      Write-Log ('phone state: ' + $st)
      switch ($st) {
        'none' { if ($NoneText) { Say $NoneText } }
        'unauthorized' { if ($Ctx -eq 'recovery') { WarnM $T_UnauthRec } else { WarnM $T_Unauth } }
        'offline' { WarnM $T_Offline }
        'no permissions' { WarnM $T_NoPerm; if (-not $IsWin) { Say $T_NoPermLinux } }
        'bootloader' { WarnM $M_FASTBOOT }
        'rescue' { WarnM $M_RESCUE }
        'authorizing' { Say $T_Connecting }
        'connecting' { Say $T_Connecting }
        'host' { Say $T_Connecting }
      }
      $last = $st
      if ($st -eq 'unauthorized') { $unauthT = $el } else { $unauthT = -1.0 }
      if ($st -eq 'offline') { $offT = $el } else { $offT = -1.0 }
      if ($st -eq 'none') { $noneT = $el } else { $noneT = -1.0 }
    }
    if ($st -eq 'unauthorized' -and $UnauthLimit -gt 0 -and ($el - $unauthT) -ge $UnauthLimit) { Close-Dots; return 'unauthorized' }
    if ($st -eq 'unauthorized' -and $UnauthNote -and $unauthT -ge 0 -and ($el - $unauthT) -ge 60) { WarnM $UnauthNote; $UnauthNote = '' }
    if ($st -eq 'offline' -and -not $reconn -and ($el - $offT) -ge $Script:T_OFFLINE_WAIT) { $reconn = $true; [void](Invoke-Adb @('reconnect', 'offline') 10 '' $true) }
    if ($IsWin -and $Ctx -eq 'recovery' -and $st -eq 'none' -and -not $Script:WinDrvShown -and $noneT -ge 0 -and ($el - $noneT) -ge 60) {
      $Script:WinDrvShown = $true; Hint ($H_WIN_DRIVER -f $Script:DRV_URL) $false
    }
    # the hint: at once when the state that has its own hint shows up, then every T_HINT
    $h = $Hint
    if ($null -ne $StateHints -and $StateHints.ContainsKey($st)) { $h = [string]$StateHints[$st] }
    if ($h -and $asked -lt 0 -and $el -ge $HintAfter -and ($h -ne $shownHint -or $el -ge $nextHint)) {
      if ($h -eq $shownHint) { Say ($M_WAITING -f (Format-Elapsed ([int]$el))) }
      Hint $h $Bell
      $shownHint = $h; $nextHint = $el + $Script:T_HINT; $nextLine = $el + $Script:T_HINT
    } elseif ($asked -lt 0 -and $el -ge $nextLine) {
      Say ($M_WAITING -f (Format-Elapsed ([int]$el))); $nextLine = $el + $Script:T_HINT
    }
    if ($EscSkip -and $Script:EscPressed) { Close-Dots; return 'skip' }
    if ($NoAsk -and $el -ge $Limit) { Close-Dots; return 'timeout' }
    if ($asked -lt 0 -and $el -ge $Limit) {
      Close-Dots
      $what = Format-Elapsed $Limit
      if ($Limit -ge 60) { $what = ('{0} мин' -f [int]($Limit / 60)) }
      if ($LimitText) { WarnM $LimitText }
      $mt = $M_WAIT_MORE; if ($MoreText) { $mt = $MoreText }
      WarnM ($mt -f $what)
      Ring
      $asked = $el; $Script:EnterPressed = $false; $Script:EscPressed = $false
    }
    if ($asked -ge 0) {
      if ($Script:EnterPressed) {
        $Script:EnterPressed = $false; $asked = -1.0; $sw.Reset(); $sw.Start(); $nextHint = 0; $nextLine = [double]$Script:T_HINT
        if ($unauthT -ge 0) { $unauthT = 0.0 }; if ($offT -ge 0) { $offT = 0.0 }; if ($noneT -ge 0) { $noneT = 0.0 }
        Say $M_GO_ON
      }
      elseif ($Script:EscPressed) { Close-Dots; Invoke-Cancel }
      elseif (($el - $asked) -ge $Limit) { Close-Dots; Invoke-Cancel -1 $true }
    }
    Write-Dot
    Wait-Sec $Poll
  }
}
########################################################################
# adb from Google: with no usable adb, SDK Platform-Tools are downloaded
# from dl.google.com on this computer once the user agrees to Google's terms
# (Google's adb is not part of our ZIP), checked (Windows: the Authenticode
# signature of adb.exe must be Valid and Google LLC's), and put into
# platform-tools next to the script, or into a per-user folder when the
# script folder is read-only (the same code as the log collector's run-check.ps1). TAOYAO_ADB_DOWNLOAD=1 downloads without the
# question, =0 never; TAOYAO_PT_URL replaces the download folder (https://,
# or a local http server on 127.0.0.1 or localhost for tests).
function Get-PtUserDir {
  if ($IsWin) {
    if ($env:LOCALAPPDATA) { return (Join-Path $env:LOCALAPPDATA 'MeruDevTools\platform-tools') }
    return ''
  }
  $h = $env:HOME
  if (-not $h -or $h -eq '/') { return '' }
  if ($IsMac) { return ($h + '/Library/Application Support/MeruDevTools/platform-tools') }
  $x = $env:XDG_DATA_HOME
  if (-not ($x -and $x.StartsWith('/'))) { $x = $h + '/.local/share' }
  return ($x + '/MeruDevTools/platform-tools')
}
# Get-PtUrl: the archive for this computer in $Script:PtZip; 1 a bad
# TAOYAO_PT_URL, 2 nothing for this computer ($Script:PtErr)
function Get-PtUrl {
  $b = $PtBase
  if ($env:TAOYAO_PT_URL) { $b = [string]$env:TAOYAO_PT_URL }
  $b = $b.TrimEnd('/')
  if ($b -cnotmatch '^https://[^/@\s]+(/\S*)?$' -and $b -cnotmatch '^http://(127\.0\.0\.1|localhost)(:[0-9]+)?(/[^@\s]*)?$') {
    $Script:PtErr = 'TAOYAO_PT_URL: можно указать только адрес https://'
    return 1
  }
  if ($IsWin) { $os = 'windows' }
  elseif ($IsMac) { $os = 'darwin' }
  else {
    $arch = '?'
    try { $arch = [string][Runtime.InteropServices.RuntimeInformation]::OSArchitecture } catch { }
    if ($arch -ne 'X64') {
      $Script:PtErr = ('Google выпускает SDK Platform-Tools для Linux только для x86-64 (этот компьютер: {0})' -f $arch)
      return 2
    }
    $os = 'linux'
  }
  $Script:PtZip = $b + '/platform-tools-latest-' + $os + '.zip'
  return 0
}
# Read-PtAnswer <old version>: $true when the user agrees to the download
function Read-PtAnswer([string]$oldV) {
  Write-Host ''
  if ($env:TAOYAO_ADB_DOWNLOAD -eq '1') {
    Say ('TAOYAO_ADB_DOWNLOAD=1: скачиваю adb без вопроса (условия Google: {0}).' -f $PtTerms)
    return $true
  }
  if (-not $Script:KeysOk) {
    Write-Log 'adb download: no console for the question'
    WarnM ('Чтобы скачать adb с сайта Google без вопроса, задайте переменную TAOYAO_ADB_DOWNLOAD=1 (этим вы принимаете условия Google: {0}).' -f $PtTerms)
    return $false
  }
  if ($oldV) {
    $q = 'Найденный adb слишком старый (версия {0}). Скачать свежий Android SDK Platform-Tools с сайта Google (около 7–15 МБ, нужен интернет)? Нажимая Д, вы принимаете условия Google: {1} [Д/н]' -f $oldV, $PtTerms
  } else {
    $q = 'adb не найден. Скачать Android SDK Platform-Tools с сайта Google (около 7–15 МБ, нужен интернет)? Нажимая Д, вы принимаете условия Google: {0} [Д/н]' -f $PtTerms
  }
  Clear-Keys
  WarnM $q
  while ($true) {
    $k = Read-KeyX
    switch (Get-KeyKind $k) {
      'YES' { Write-Log ('answer: {0} (download)' -f $k); return $true }
      'NO' { Write-Log ('answer: {0} (no download)' -f $k); return $false }
      'AMBIG' { Say 'Непонятно: на этой клавише и Y, и Н. Нажмите Enter (или Д) — скачать, Esc (или Н) — не скачивать.' }
      default { Say 'Нажмите Д или Enter — скачать, Н или Esc — не скачивать.' }
    }
  }
}
# Wait-PtDone <process or IAsyncResult> <seconds>: $false after the limit;
# a line every 15 s; Ctrl+C asks
function Wait-PtDone($w, [int]$lim) {
  $sw = [Diagnostics.Stopwatch]::StartNew(); $next = 15
  while ($true) {
    if ($w -is [Diagnostics.Process]) { if ($w.WaitForExit(200)) { return $true } }
    elseif ($w.AsyncWaitHandle.WaitOne(200)) { return $true }
    Test-Interrupt
    $el = [int]$sw.Elapsed.TotalSeconds
    if ($el -ge $lim) { return $false }
    if ($el -ge $next) { Say ('… скачиваю, прошло ' + (Format-Elapsed $el)); $next += 15 }
  }
}
# (in a runspace of its own, so that the wait above shows the time and
# reacts to Ctrl+C; the system proxy, with the Windows logon for a proxy
# that asks for one; a plain file name in the download folder, which may
# hold [ ] and Cyrillic)
$PtIwr = {
  param($u, $d, $n)
  $ProgressPreference = 'SilentlyContinue'
  $ErrorActionPreference = 'Stop'
  try { $wp = [Net.WebRequest]::DefaultWebProxy; if ($null -ne $wp) { $wp.Credentials = [Net.CredentialCache]::DefaultNetworkCredentials } } catch { }
  Set-Location -LiteralPath $d
  Invoke-WebRequest -Uri $u -OutFile $n -UseBasicParsing -TimeoutSec 60
}
# Invoke-PtGet <url> <folder> <file name> <curl>: one download attempt with
# Invoke-WebRequest, or with curl when its path is given; $Script:PtErr
function Invoke-PtGet([string]$url, [string]$dir, [string]$name, [string]$curl) {
  $path = Join-Path $dir $name
  try { if ([IO.File]::Exists($path)) { [IO.File]::Delete($path) } } catch { }
  $lim = 900; $err = ''; $done = $false
  if ($curl) {
    $pr = '=https'; if ($url.StartsWith('http://')) { $pr = '=http' }
    $p = Start-AdbProc @('-fsSL', '--proto', $pr, '--proto-redir', $pr, '--connect-timeout', '30', '--speed-limit', '1024', '--speed-time', '60', '--max-filesize', '209715200', '-o', $name, $url) $dir $true $curl
    $Script:AdbProc = $p
    $to = $p.StandardOutput.ReadToEndAsync(); $te = $p.StandardError.ReadToEndAsync()
    try {
      $done = Wait-PtDone $p $lim
      if ($done) {
        try { [void][Threading.Tasks.Task]::WaitAll([Threading.Tasks.Task[]]@($to, $te), 2000) } catch { }
        $e = ''; if ($te.IsCompleted -and -not $te.IsFaulted) { $e = $te.Result.Trim() }
        Write-Log ('< rc={0} {1}' -f $p.ExitCode, $e)
        if ($p.ExitCode -ne 0) {
          $err = @($e -split "`r?`n")[-1].Trim()
          if (-not $err) { $err = 'код ' + $p.ExitCode }
        }
      } else { try { $p.Kill() } catch { } }
    } finally { $Script:AdbProc = $null; try { $p.Dispose() } catch { } }
  } else {
    Write-Log ('> Invoke-WebRequest ' + $url)
    $ps = [PowerShell]::Create()
    $Script:PtJob = $ps
    try {
      [void]$ps.AddScript($PtIwr).AddArgument($url).AddArgument($dir).AddArgument($name)
      $h = $ps.BeginInvoke()
      $done = Wait-PtDone $h $lim
      if ($done) {
        try { [void]$ps.EndInvoke($h) } catch {
          $ex = $_.Exception
          while ($null -ne $ex.InnerException) { $ex = $ex.InnerException }
          $err = $ex.Message
        }
        if (-not $err -and $ps.Streams.Error.Count -gt 0) { $err = [string]$ps.Streams.Error[0] }
        Write-Log ('< ' + $err)
      }
    } finally {
      if (-not $done) { try { $ps.Stop() } catch { } }
      try { $ps.Dispose() } catch { }
      $Script:PtJob = $null
    }
  }
  if (-not $done) { $err = 'загрузка не закончилась за 15 мин' }
  if (-not $err) {
    $len = 0; try { $len = (New-Object IO.FileInfo $path).Length } catch { }
    if ($len -le 0) { $err = 'пустой ответ' }
  }
  if ($err) {
    $err = $err.Trim().TrimEnd('.')
    if ($err.Length -gt 200) { $err = $err.Substring(0, 200) }
    try { [IO.File]::Delete($path) } catch { }
    $Script:PtErr = $err
    return $false
  }
  return $true
}
# Expand-PtZip <zip> <folder>: the archive opens, holds platform-tools/adb
# (Windows: adb.exe, AdbWinApi.dll and AdbWinUsbApi.dll) and nothing outside
# platform-tools/; then it is extracted; $Script:PtErr
function Expand-PtZip([string]$zip, [string]$dir) {
  try { Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop } catch { Write-Log ('System.IO.Compression.FileSystem: ' + $_) }
  $need = @('platform-tools/adb')
  if ($IsWin) { $need = @('platform-tools/adb.exe', 'platform-tools/AdbWinApi.dll', 'platform-tools/AdbWinUsbApi.dll') }
  $names = New-Object 'System.Collections.Generic.List[string]'
  try {
    $z = [IO.Compression.ZipFile]::OpenRead($zip)
    try { foreach ($e in $z.Entries) { $names.Add($e.FullName) } } finally { $z.Dispose() }
  } catch { Write-Log ('zip: ' + $_); $Script:PtErr = 'архив не открывается'; return $false }
  foreach ($n in $names) {
    $m = $n.Replace('\', '/')
    if (-not $m.StartsWith('platform-tools/', [StringComparison]::Ordinal) -or ('/' + $m + '/').Contains('/../') -or $m.Contains(':') -or $n.Contains('\')) {
      Write-Log ('archive entry outside platform-tools/: ' + $n)
      $Script:PtErr = 'в архиве есть файлы вне папки platform-tools'
      return $false
    }
  }
  foreach ($x in $need) {
    $found = $false
    foreach ($n in $names) { if ([string]::Equals($n, $x, [StringComparison]::OrdinalIgnoreCase)) { $found = $true; break } }
    if (-not $found) { $Script:PtErr = ('в архиве нет {0}' -f $x); return $false }
  }
  try { [IO.Compression.ZipFile]::ExtractToDirectory($zip, $dir) } catch { Write-Log ('extract: ' + $_); $Script:PtErr = 'архив повреждён'; return $false }
  return $true
}
# Test-PtAdb <platform-tools folder>: adb there is signed by Google
# (Windows: Authenticode, macOS: codesign) and prints its version (1.0.39 or
# newer); $Script:PtVer, $Script:PtErr
function Test-PtAdb([string]$d) {
  $exe = Join-Path $d 'adb'; if ($IsWin) { $exe = Join-Path $d 'adb.exe' }
  if (-not $IsWin) {
    foreach ($f in @(Get-ChildItem -LiteralPath $d -File -ErrorAction SilentlyContinue)) {
      if (-not $f.Name.Contains('.')) { try { & chmod '+x' $f.FullName } catch { } }
    }
  }
  # (the cmdlet is missing only outside Windows, e.g. PowerShell 7 on Linux)
  $gas = Get-Command -Name Get-AuthenticodeSignature -ErrorAction SilentlyContinue
  if ($gas) {
    $sig = $null; $subj = ''
    try { $sig = Get-AuthenticodeSignature -LiteralPath $exe } catch { Write-Log ('Get-AuthenticodeSignature: ' + $_) }
    if ($null -eq $sig) { $Script:PtErr = 'не удалось проверить цифровую подпись adb'; return $false }
    $st = [string]$sig.Status
    if ($null -ne $sig.SignerCertificate) { $subj = [string]$sig.SignerCertificate.Subject }
    Write-Log ('adb signature: {0}; {1}' -f $st, $subj)
    if ($st -ne 'Valid') { $Script:PtErr = ('цифровая подпись adb недействительна ({0})' -f $st); return $false }
    if ($subj -notmatch 'Google LLC') { $Script:PtErr = 'adb подписан не Google LLC'; return $false }
  } else { Write-Log 'Get-AuthenticodeSignature is not available here: the signature of adb is not checked' }
  if ($IsMac) {
    if ([IO.File]::Exists('/usr/bin/xattr')) {
      $r = Invoke-Adb @('-p', 'com.apple.quarantine', $exe) 10 '' $true '/usr/bin/xattr'
      if ($r.Code -eq 0) { [void](Invoke-Adb @('-r', '-d', 'com.apple.quarantine', $d) 30 '' $true '/usr/bin/xattr'); Write-Log 'quarantine attribute removed' }
    }
    if ([IO.File]::Exists('/usr/bin/codesign')) {
      $r = Invoke-Adb @('--verify', '--strict', $exe) 30 '' $true '/usr/bin/codesign'
      if ($r.Code -ne 0) { $Script:PtErr = 'цифровая подпись adb недействительна'; return $false }
      $r = Invoke-Adb @('-dvv', $exe) 30 '' $true '/usr/bin/codesign'
      if (($r.Out + $r.Err) -notmatch '(?m)^Authority=.*Google LLC') { $Script:PtErr = 'adb подписан не Google LLC'; return $false }
    } else { Write-Log 'codesign not found: the signature of adb is not checked' }
  }
  $r = $null
  try { $r = Invoke-Adb @('version') 10 '' $true $exe }
  catch { if ("$_" -eq 'RUNFLASH-EXIT') { throw }; Write-Log ('downloaded adb does not start: ' + $_) }
  $v = ''
  if ($null -ne $r -and $r.Code -eq 0) {
    $m = [regex]::Match($r.Out, 'Android Debug Bridge version ([0-9][0-9.]*)')
    if ($m.Success) { $v = $m.Groups[1].Value }
  }
  if (-not $v) { $Script:PtErr = 'adb не запускается'; return $false }
  if (-not (Test-AdbVer $v)) { $Script:PtErr = ('в архиве старый adb (версия {0})' -f $v); return $false }
  $Script:PtVer = $v
  return $true
}
# New-PtStage <folder>: a fresh temporary folder that can be written to
function New-PtStage([string]$st) {
  try {
    if ([IO.Directory]::Exists($st)) { [IO.Directory]::Delete($st, $true) }
    [void][IO.Directory]::CreateDirectory($st)
    $t = Join-Path $st 'probe'
    [IO.File]::WriteAllText($t, '', $Utf8); [IO.File]::Delete($t)
    return $true
  } catch {
    Write-Log ('cannot use {0}: {1}' -f $st, $_.Exception.Message)
    try { [IO.Directory]::Delete($st, $true) } catch { }
    return $false
  }
}
function Remove-PtStage {
  if (-not $Script:PtStage) { return }
  try { [IO.Directory]::Delete($Script:PtStage, $true) } catch { Write-Log ('temporary folder not removed: ' + $_.Exception.Message) }
  $Script:PtStage = $null
}
# Move-PtDir <from> <to>: '' or the reason; a few tries (an antivirus may
# still be reading the new files)
function Move-PtDir([string]$a, [string]$b) {
  $e = ''
  for ($i = 0; $i -lt 5; $i++) {
    if ($i -gt 0) { Wait-Sec 1 }
    try { [IO.Directory]::Move($a, $b); return '' }
    catch { $e = $_.Exception.GetBaseException().Message; Write-Log ('move {0} -> {1}: {2}' -f $a, $b, $e) }
  }
  return $e
}
# Get-PlatformTools <old version> <old adb>: $true when a fresh adb is in
# place ($Script:Adb, $Script:AdbVer)
function Get-PlatformTools([string]$oldV, [string]$oldP) {
  $Script:PtErr = ''; $Script:PtZip = ''; $Script:PtVer = ''
  if ($env:TAOYAO_ADB_DOWNLOAD -eq '0') { Write-Log 'adb download: off (TAOYAO_ADB_DOWNLOAD=0)'; return $false }
  $u = Get-PtUrl
  if ($u -eq 2) { Write-Log ('adb download not offered: ' + $Script:PtErr); return $false }
  if ($u -ne 0) { Write-Host ''; ErrM $Script:PtErr; return $false }
  $curl = ''
  $cn = 'curl'; if ($IsWin) { $cn = 'curl.exe' }
  try { $c = @(Get-Command -Name $cn -CommandType Application -ErrorAction SilentlyContinue); if ($c.Count -gt 0) { $curl = $c[0].Path } } catch { }
  if (-not (Read-PtAnswer $oldV)) { return $false }
  # (next to the script; a folder there that cannot be written: per-user)
  $par = $Here
  $st = Join-Path $par ('.platform-tools-dl.' + $PID)
  if (-not (New-PtStage $st)) {
    $ud = Get-PtUserDir
    $ok = $false
    if ($ud) {
      $par = [IO.Path]::GetDirectoryName($ud)
      $st = Join-Path $par ('.platform-tools-dl.' + $PID)
      $ok = New-PtStage $st
    }
    if (-not $ok) { ErrM 'Не удаётся создать папку для adb ни рядом с флешером, ни в папке пользователя.'; return $false }
    Write-Log 'the script folder is read-only: adb goes to the per-user folder'
  }
  $Script:PtStage = $st
  # (left by a run that was closed during the download)
  try {
    foreach ($d in @(Get-ChildItem -LiteralPath $par -Directory -Force -ErrorAction SilentlyContinue)) {
      if (($d.Name.StartsWith('.platform-tools-dl.') -or $d.Name.StartsWith('.platform-tools-old.')) -and $d.FullName -ne $st -and $d.LastWriteTime -lt (Get-Date).AddHours(-1)) {
        try { [IO.Directory]::Delete($d.FullName, $true); Write-Log ('old temporary folder removed: ' + $d.Name) } catch { }
      }
    }
  } catch { }
  # (Windows PowerShell 5.1 on an older .NET offers only TLS 1.0 by default)
  try {
    $sp = [Net.ServicePointManager]::SecurityProtocol
    if ([int]$sp -ne 0) { [Net.ServicePointManager]::SecurityProtocol = $sp -bor [Net.SecurityProtocolType]::Tls12 }
  } catch { Write-Log ('TLS 1.2: ' + $_) }
  Head 'Скачиваю Android SDK Platform-Tools с сайта Google…'
  Write-Log ('download: {0} into {1}' -f $Script:PtZip, $st)
  $zip = Join-Path $st 'platform-tools.zip'
  $n = 1
  while ($true) {
    # (the second try with curl.exe, when Windows has it)
    $use = ''; if ($n -ge 2) { $use = $curl }
    if (Invoke-PtGet $Script:PtZip $st 'platform-tools.zip' $use) { break }
    if ($n -ge 2) {
      ErrM ('Не удалось скачать Android SDK Platform-Tools ({0}). Проверьте подключение к интернету; на рабочем компьютере загрузку может запрещать прокси-сервер или антивирус.' -f $Script:PtErr)
      Remove-PtStage; return $false
    }
    WarnM ('Не удалось скачать ({0}). Пробую ещё раз…' -f $Script:PtErr)
    $n++; Wait-Sec 3
  }
  Say 'Проверяю скачанный архив…'
  $x = Join-Path $st 'x'
  if (-not (Expand-PtZip $zip $x) -or -not (Test-PtAdb (Join-Path $x 'platform-tools'))) {
    ErrM ('Скачанный архив не прошёл проверку: {0}. Он удалён, ничего не установлено.' -f $Script:PtErr)
    Remove-PtStage; return $false
  }
  try { [IO.File]::Delete($zip) } catch { }
  # (the new adb restarts an older server anyway; it is stopped here with its
  # own adb, and only when the versions differ)
  if ($oldP -and $oldV -ne $Script:PtVer) {
    try { $r = Invoke-Adb @('kill-server') 15 '' $true $oldP; Write-Log ('old adb server stopped: {0} kill-server, rc {1}' -f $oldP, $r.Code) }
    catch { if ("$_" -eq 'RUNFLASH-EXIT') { throw }; Write-Log ('old adb kill-server: ' + $_) }
  }
  # (an old platform-tools folder goes only now, after the checks)
  $dst = Join-Path $par 'platform-tools'
  $old = Join-Path $par ('.platform-tools-old.' + $PID)
  $had = ([IO.Directory]::Exists($dst) -or [IO.File]::Exists($dst))
  if ($had) {
    try { if ([IO.Directory]::Exists($old)) { [IO.Directory]::Delete($old, $true) } } catch { }
    $e = Move-PtDir $dst $old
    if ($e) {
      ErrM ('Не удаётся заменить старую папку «{0}» ({1}). Закройте программы, которые её используют, и запустите флешер снова.' -f $dst, $e)
      Remove-PtStage; return $false
    }
  }
  $e = Move-PtDir (Join-Path $x 'platform-tools') $dst
  if ($e) {
    ErrM ('Не удаётся положить папку platform-tools в «{0}» ({1}).' -f $par, $e)
    if ($had) { [void](Move-PtDir $old $dst) }
    Remove-PtStage; return $false
  }
  if ($had) { try { [IO.Directory]::Delete($old, $true) } catch { Write-Log ('old platform-tools folder not removed: ' + $_.Exception.Message) } }
  Remove-PtStage
  if ($IsWin) { $Script:Adb = Join-Path $dst 'adb.exe' } else { $Script:Adb = Join-Path $dst 'adb' }
  $Script:AdbVer = $Script:PtVer
  Write-Log ('adb: {0} (version {1}, downloaded)' -f $Script:Adb, $Script:AdbVer)
  GoodM ('Готово: Android SDK Platform-Tools скачаны и проверены (adb {0}).' -f $Script:AdbVer)
  if ($par -ne $Here) {
    Say ('В папку флешера нельзя записывать, поэтому adb сохранён в «{0}» — там он найдётся и в следующий раз.' -f $dst)
  }
  return $true
}

########################################################################
# PC folders: the base (the script's folder, or Desktop\MeruDevTools when
# that cannot be written), run-flash.log, the lock, the temp folder, and
# the catalogue of the copies kept under taoyao-stock-images and
# taoyao-<series>-backups (both bases are searched)
function Get-FallbackBase {
  $desk = ''
  try { $desk = [Environment]::GetFolderPath('Desktop') } catch { }
  if ($desk -and [IO.Directory]::Exists($desk)) { return (Join-Path $desk 'MeruDevTools') }
  $h = $env:USERPROFILE; if (-not $h) { $h = $env:HOME }
  if ($h) { return (Join-Path $h 'MeruDevTools') }
  return (Join-Path ([IO.Path]::GetTempPath()) 'MeruDevTools')
}
function Select-Base {
  $Script:Bases.Clear()
  $fb = Get-FallbackBase
  $probe = Join-Path $Here ('.run-flash-probe.' + $PID)
  $ok = $false
  try { [void][IO.Directory]::CreateDirectory($probe); [IO.Directory]::Delete($probe); $ok = $true } catch { }
  if ($ok) { $Script:Base = $Here }
  else {
    try { [void][IO.Directory]::CreateDirectory($fb) } catch { ErrM $M_BASE_NONE; Stop-Run $RC_FAIL }
    $Script:Base = $fb
    WarnM ($M_BASE_FALLBACK -f $Here, $fb)
  }
  $Script:Bases.Add($Script:Base)
  foreach ($b in @($Here, $fb)) {
    $have = $false
    foreach ($x in $Script:Bases) { if ([string]::Equals($x.TrimEnd('\', '/'), $b.TrimEnd('\', '/'), [StringComparison]::OrdinalIgnoreCase)) { $have = $true } }
    if (-not $have -and [IO.Directory]::Exists($b)) { $Script:Bases.Add($b) }
  }
  if ($IsWin -and $Script:Base.Length -gt 150) { WarnM $M_BASE_LONG }
}
# Open-Log: run-flash.log in the base (rotated at 5 MB), the lines buffered so far
function Open-Log {
  $Script:LogPath = Join-Path $Script:Base $Script:PC_LOG
  try {
    if ([IO.File]::Exists($Script:LogPath) -and (Get-FileLen $Script:LogPath) -gt 5242880) {
      $old = Join-Path $Script:Base $Script:PC_LOG_OLD
      if ([IO.File]::Exists($old)) { [IO.File]::Delete($old) }
      [IO.File]::Move($Script:LogPath, $old)
    }
    $head = "`r`n" + ('==== {0} {1}, {2} ====' -f $Script:BRAND, $Script:VER, (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')) + "`r`n"
    [IO.File]::AppendAllText($Script:LogPath, $head, $Utf8)
    if ($Script:LogBuf.Length -gt 0) {
      # (masked already when it was buffered)
      [IO.File]::AppendAllText($Script:LogPath, $Script:LogBuf.ToString(), $Utf8)
      [void]$Script:LogBuf.Clear()
    }
  } catch { $Script:LogPath = $null }
}
function Lock-Folder {
  $Script:LockPath = Join-Path $Script:Base $Script:PC_LOCK
  try {
    $Script:Lock = [IO.File]::Open($Script:LockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
  } catch {
    $Script:LockPath = $null
    ErrM $M_LOCKED
    $Script:NoFooter = $true
    Stop-Run $RC_FAIL
  }
}
# Get-TmpDir: a temp folder of this run (files extracted from zips for (A))
function Get-TmpDir {
  if ($Script:TmpDir -and [IO.Directory]::Exists($Script:TmpDir)) { return $Script:TmpDir }
  $t = Join-Path ([IO.Path]::GetTempPath()) ('runflash.' + $PID + '.' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
  [void][IO.Directory]::CreateDirectory($t)
  $Script:TmpDir = $t
  return $t
}
# Get-PullDir: this run's raw pull folder <base>/<BACKUP_NAME>-<yyyyMMdd-HHmmss>
function Get-PullDir {
  if ($Script:PullDir -and [IO.Directory]::Exists($Script:PullDir)) { return $Script:PullDir }
  $name = $Script:PC_PULL_FMT.Replace('{BACKUP_NAME}', $Script:BACKUP_NAME).Replace('{yyyyMMdd-HHmmss}', (Get-Date).ToString('yyyyMMdd-HHmmss'))
  $p = Join-Path $Script:Base $name
  [void][IO.Directory]::CreateDirectory($p)
  $Script:PullDir = $p
  Write-Log ('pull folder: ' + $p)
  return $p
}
# Remove-EmptyDirs <folder>: the pull folder goes at the end when nothing is left in it
function Remove-EmptyDirs([string]$d) {
  if (-not $d -or -not [IO.Directory]::Exists($d)) { return }
  try {
    foreach ($s in @([IO.Directory]::GetDirectories($d))) { Remove-EmptyDirs $s }
    if (@([IO.Directory]::GetFileSystemEntries($d)).Count -eq 0) { [IO.Directory]::Delete($d) }
  } catch { }
}
function Get-FreeMB([string]$dir) {
  try {
    $root = [IO.Path]::GetPathRoot([IO.Path]::GetFullPath($dir))
    $di = New-Object IO.DriveInfo $root
    return [long]($di.AvailableFreeSpace / 1048576)
  } catch { return [long]-1 }
}

# key=value text (info.txt, restore.prop): the first value of each key
function Read-InfoText([string]$t) {
  $h = @{}
  foreach ($l in (Get-Lines $t)) {
    $i = $l.IndexOf('=')
    if ($i -le 0 -or $l.StartsWith(' ')) { continue }
    $k = $l.Substring(0, $i)
    if (-not $h.ContainsKey($k)) { $h[$k] = $l.Substring($i + 1).Trim() }
  }
  return $h
}
function Get-H($h, [string]$k) { if ($null -ne $h -and $h.ContainsKey($k)) { return [string]$h[$k] }; return '' }
# SHA256SUMS text: name -> hash ("<64 hex>  <name>")
function Read-Sums([string]$t) {
  $h = @{}
  foreach ($l in (Get-Lines $t)) {
    $m = [regex]::Match($l.Trim(), '^([0-9a-fA-F]{64}) [ *]?([A-Za-z0-9._-]+)$')
    if ($m.Success) { $h[$m.Groups[2].Value] = $m.Groups[1].Value.ToLowerInvariant() }
  }
  return $h
}
$Script:IMGS = @('boot.img', 'vendor_boot.img', 'dtbo.img')
function Test-SameSums($a, $b) {
  foreach ($n in $Script:IMGS) {
    $x = Get-H $a $n; $y = Get-H $b $n
    if (-not $x -or $x -ne $y) { return $false }
  }
  return $true
}
# Get-Class <kernel release>: PREV for a build of this port, else STOCK
function Get-Class([string]$k) {
  if (Test-PortSeries $k) { return 'PREV' }
  return 'STOCK'
}

# Get-FiledFolders: every kept copy (both bases), cached until the next filing
function Get-FiledFolders {
  if ($null -ne $Script:Filed) { return $Script:Filed }
  $list = New-Object System.Collections.ArrayList
  foreach ($b in $Script:Bases) {
    $tops = New-Object System.Collections.ArrayList
    $st = Join-Path $b $Script:PC_STOCK
    if ([IO.Directory]::Exists($st)) { [void]$tops.Add(@($st, 'STOCK')) }
    try {
      foreach ($d in [IO.Directory]::GetDirectories($b)) {
        $n = [IO.Path]::GetFileName($d)
        if ($n -match '^taoyao-[0-9]+\.[0-9]+-backups$') { [void]$tops.Add(@($d, 'PREV')) }
      }
    } catch { }
    foreach ($t in $tops) {
      $sub = @()
      try { $sub = @([IO.Directory]::GetDirectories($t[0])) } catch { }
      foreach ($d in $sub) {
        $f = Read-PcFolder $d $t[1]
        if ($null -ne $f) { [void]$list.Add($f) }
      }
    }
  }
  $Script:Filed = $list.ToArray()
  return $Script:Filed
}
# Read-PcFolder <folder> <class>: one kept copy, or $null without info.txt
function Read-PcFolder([string]$d, [string]$cls) {
  $ip = Join-Path $d 'info.txt'
  if (-not [IO.File]::Exists($ip)) { return $null }
  $info = @{}; $sums = @{}
  try { $info = Read-InfoText ([IO.File]::ReadAllText($ip)) } catch { }
  $sp = Join-Path $d 'SHA256SUMS'
  if ([IO.File]::Exists($sp)) { try { $sums = Read-Sums ([IO.File]::ReadAllText($sp)) } catch { } }
  $rz = @()
  try { $rz = @([IO.Directory]::GetFiles($d, 'taoyao-restore-*.zip')) } catch { }
  $rzp = ''
  if ($rz.Count -eq 1 -and [IO.File]::Exists($rz[0] + '.sha256')) { $rzp = $rz[0] }
  $name = [IO.Path]::GetFileName($d)
  $stamp = ''
  $m = [regex]::Match($name, '-([0-9]{8}-[0-9]{6}(-[0-9]+)?)(-[0-9]+)?$')
  if ($m.Success) { $stamp = $m.Groups[1].Value }
  $label = $name
  $i = $name.IndexOf('-slot_'); if ($i -gt 0) { $label = $name.Substring(0, $i) }
  return [pscustomobject]@{
    Path = $d; Name = $name; Class = $cls; Info = $info; Sums = $sums; Slot = (Get-H $info 'slot')
    Kernel = (Get-H $info 'kernel'); Fp = (Get-H $info 'fingerprint'); Ramdisk = (Get-H $info 'boot_ramdisk')
    Rid = (Get-RidOf $info); DateEp = (Get-EpochOf (Get-H $info 'date'))
    RZip = $rzp; Restorable = [bool]($rzp -and $sums.Count -ge 3); Stamp = $stamp; Label = $label
  }
}

# Get-EpochOf <date of info.txt>: those seconds since 1970, read as UTC
# (installers write UTC; the flasher's own copies before 1.2, local time);
# -1 for anything else (run-flash.sh epoch_of)
function Get-EpochOf([string]$d) {
  $m = [regex]::Match($d, '^([0-9]{4})-([0-9]{2})-([0-9]{2}) ([0-9]{2}):([0-9]{2}):([0-9]{2})')
  if (-not $m.Success) { return [long]-1 }
  try {
    $t = New-Object DateTime ([int]$m.Groups[1].Value), ([int]$m.Groups[2].Value), ([int]$m.Groups[3].Value), ([int]$m.Groups[4].Value), ([int]$m.Groups[5].Value), ([int]$m.Groups[6].Value), ([DateTimeKind]::Utc)
    return [long][Math]::Floor(($t - (New-Object DateTime 1970, 1, 1, 0, 0, 0, ([DateTimeKind]::Utc))).TotalSeconds)
  } catch { return [long]-1 }
}
# Format-Utc <seconds since 1970>: «16.09.2026 14:18 UTC» ('' for anything else)
function Format-Utc([string]$n) {
  if ($n -notmatch '^[0-9]+$') { return '' }
  $t = (New-Object DateTime 1970, 1, 1, 0, 0, 0, ([DateTimeKind]::Utc)).AddSeconds([double]$n)
  return ($t.ToString('dd.MM.yyyy HH:mm', [Globalization.CultureInfo]::InvariantCulture) + ' UTC')
}
# Format-InfoDate <date of info.txt>: «14.11.2026 06:32», with « UTC» when it says so
function Format-InfoDate([string]$d) {
  $m = [regex]::Match($d, '^([0-9]{4})-([0-9]{2})-([0-9]{2}) ([0-9]{2}:[0-9]{2})')
  if (-not $m.Success) { return '' }
  $r = ('{0}.{1}.{2} {3}' -f $m.Groups[3].Value, $m.Groups[2].Value, $m.Groups[1].Value, $m.Groups[4].Value)
  if ($d.EndsWith(' UTC')) { $r = $r + ' UTC' }
  return $r
}
# Get-FprWhy <PC folder> <ROM build now>: why only the fingerprint compared
# (M_STOCK_FPRONLY, M_Q2_FPRONLY): the copy has no ROM build, or the phone's
# cannot be read now (run-flash.sh fpr_why)
function Get-FprWhy($f, [string]$rid) {
  if ($f.Rid -and -not $rid) { return $M_FPR_WHY_PHONE }
  return $M_FPR_WHY_COPY
}
# Get-RidOf <info>: its rom_build_utc (installer 0.20 on), digits only
function Get-RidOf($info) {
  $r = [string](Get-H $info 'rom_build_utc')
  if ($r -match '^[0-9]+$') { return $r }
  return ''
}
# Get-AndRid <Android probe>: ro.build.date.utc of /system/build.prop, which
# Play Integrity modules do not touch; getprop only when the file cannot be read
function Get-AndRid($kv) {
  $r = [string](Get-KV $kv 'romutc')
  if ($r -notmatch '^[0-9]+$') { $r = [string](Get-KV $kv 'ro.build.date.utc') }
  if ($r -notmatch '^[0-9]+$') { return '' }
  return $r
}
# Get-RomCmp <boot ramdisk now> <build time now> <fingerprint now> <kept
# folder>: the folder's ROM build against the phone's (13.2; rc of
# run-flash.sh): same (the same boot ramdisk, or the same
# ro.build.date.utc), other (another one), older (a copy without
# rom_build_utc made, by the phone's clock, more than a day before the ROM
# now on the phone was built; only for a date after 2021-01-01: a
# recovery's clock is never set and reads about 1970), fpr (only the
# fingerprint is the same: Play Integrity modules spoof it), fprdiff
# (another fingerprint), unknown
function Get-RomCmp([string]$bn, [string]$rn, [string]$fn, $f) {
  $cb = [string]$f.Ramdisk; $cr = [string]$f.Rid; $cf = [string]$f.Fp; $ce = [long]$f.DateEp
  if ($bn -and $cb) { if ($bn -eq $cb) { return 'same' }; return 'other' }
  if ($rn -and $cr) { if ($rn -eq $cr) { return 'same' }; return 'other' }
  if ($rn -and $ce -ge 1609459200 -and [long]$rn -gt $ce + 86400) { return 'older' }
  if ($fn -and $cf) { if ($fn -eq $cf) { return 'fpr' }; return 'fprdiff' }
  return 'unknown'
}

########################################################################
# phone probes (section 6 of the design): Android, root, recovery, hashes
function Get-Tpl([string]$t) {
  $globs = New-Object 'System.Collections.Generic.List[string]'
  foreach ($s in @($Script:STORES.Split(' ') | Where-Object { $_ })) { $globs.Add($s + '/' + $Script:BACKUP_NAME + '/*') }
  return $t.Replace('{BN}', $Script:BACKUP_NAME).Replace('{LAST}', $Script:LAST_LOG).Replace('{RLOG}', $Script:RLOG_NAME).Replace('{W}', $Script:PH_WORK).Replace('{STORE_GLOBS}', [string]::Join(' ', $globs.ToArray())).Replace('{STORES}', $Script:STORES)
}
function Get-FirstLine($r) {
  $t = ''
  if ($null -ne $r) { $t = ($r.Out + $r.Err).Trim() }
  $f = @($t -split "`n")[0]
  if (-not $f) { $f = 'нет ответа' }
  if ($f.Length -gt 150) { $f = $f.Substring(0, 150) }
  return $f
}
# Invoke-Probe <command> <root> <states to wait for if the phone is lost>:
# a key=value probe; waits for the phone when the connection was lost
function Invoke-Probe([string]$cmd, [bool]$root, [string[]]$want, [int]$sec = 30) {
  for ($i = 0; $i -lt 3; $i++) {
    $r = Invoke-Dev $cmd $root $sec
    $kv = ConvertFrom-KV $r.Out
    if ((Get-KV $kv 'end') -eq '1') { return $kv }
    if ((Test-Lost $r) -or $r.TimedOut) {
      WarnM $M_LOST
      $st = Wait-Phone -Want $want -Limit $Script:T_USER -Ctx (Get-Ctx $want)
      continue
    }
    Fail ($M_PHONE_NOANSWER -f (Get-FirstLine $r))
  }
  Fail ($M_PHONE_NOANSWER -f (Get-FirstLine $Script:Dc))
}
function Get-Ctx([string[]]$want) { if ($want -contains 'recovery') { return 'recovery' }; return 'android' }
function Test-Taoyao($kv) {
  foreach ($k in @('ro.product.device', 'ro.build.product', 'ro.product.vendor.device', 'ro.vendor.product.device', 'ro.boot.hwname')) {
    if ((Get-KV $kv $k) -eq $Script:DEVICE) { return $true }
  }
  return $false
}
function Get-DevName($kv) {
  foreach ($k in @('ro.product.device', 'ro.build.product', 'ro.product.vendor.device', 'ro.boot.hwname')) { $v = Get-KV $kv $k; if ($v) { return $v } }
  return '?'
}
function Get-SlotOf($kv) {
  foreach ($k in @('bc.slot_suffix', 'cl.slot_suffix', 'ro.boot.slot_suffix')) {
    $v = Get-KV $kv $k
    if ($v) { return $v }
  }
  return ''
}
# Get-BlState <kv> <reliable>: unlocked | locked | unknown ($Script:BlWhat: what it said)
function Get-BlState($kv, [bool]$reliable) {
  $Script:BlWhat = ''
  $vbs = Get-KV $kv 'bc.verifiedbootstate'; if (-not $vbs) { $vbs = Get-KV $kv 'cl.verifiedbootstate' }
  $ds = Get-KV $kv 'bc.vbmeta.device_state'; if (-not $ds) { $ds = Get-KV $kv 'cl.vbmeta.device_state' }
  if (-not $reliable -and -not $vbs -and -not $ds) {
    $vbs = Get-KV $kv 'ro.boot.verifiedbootstate'; $ds = Get-KV $kv 'ro.boot.vbmeta.device_state'
    if ((Get-KV $kv 'ro.boot.flash.locked') -eq '1' -and -not $ds) { $ds = 'locked' }
  }
  $Script:BlWhat = [string]::Join(', ', @(@($vbs, $ds) | Where-Object { $_ }))
  if ($vbs -eq 'orange' -or $ds -eq 'unlocked') { return 'unlocked' }
  if (@('green', 'yellow', 'red') -contains $vbs -or $ds -eq 'locked') { return 'locked' }
  return 'unknown'
}
# Show-BlCheck <kv> <reliable>: the bootloader line; locked and reliable: stop
function Show-BlCheck($kv, [bool]$reliable) {
  $bl = Get-BlState $kv $reliable
  if ($bl -eq 'unlocked') { GoodM $M_BL_OK; return }
  if ($bl -eq 'locked') {
    if ($reliable) { $Script:Sum['Result'] = 'nothing'; $Script:Sum['What'] = $U_LOCKED; Fail ($M_BL_LOCKED -f $Script:BlWhat) }
    WarnM $M_BL_PROPS_LOCKED; return
  }
  Say $M_BL_UNKNOWN
}
# Test-Battery <percent text>: 13.4; the question is asked once per run
function Test-Battery([string]$b) {
  if ($Script:Gate.ContainsKey('batdone')) { return }
  $Script:Gate['batdone'] = $true
  $n = -1
  if (-not ($b -and [int]::TryParse($b.Trim(), [ref]$n))) { Say $M_BAT_UNKNOWN; return }
  $Script:Sum['Bat'] = $n
  if ($n -lt $Script:BAT_STOP) { Fail ($M_BAT_STOP -f $n) }
  if ($n -lt $Script:BAT_WARN) {
    if ($Script:Gate.ContainsKey('bat')) { WarnM ($M_BAT -f $n); return }
    $Script:Gate['bat'] = $true
    if (-not (Ask-Yes ($M_BAT_WARN_ASK -f $n))) { Invoke-Cancel }
    return
  }
  Say ($M_BAT -f $n)
}

# Get-AndroidInfo: P_ANDROID; waits for the end of the boot and the first
# unlock; checks the model (a stop for any other phone)
function Get-AndroidInfo {
  $sw = [Diagnostics.Stopwatch]::StartNew(); $shown = ''; $next = 0
  while ($true) {
    $kv = Invoke-Probe $Script:P_ANDROID $false @('device')
    $now = [long]0; [void][long]::TryParse((Get-KV $kv 'now'), [ref]$now); $Script:LastNow = $now
    if ((Get-KV $kv 'sys.boot_completed') -ne '1') {
      if ($shown -ne 'boot') { $shown = 'boot'; Say $M_WAIT_BOOT }
    } elseif ((Get-KV $kv 'sys.user.0.ce_available') -ne 'true' -and (Get-KV $kv 'sd') -ne '1') {
      if ($shown -ne 'lock') { $shown = 'lock'; Hint $M_UNLOCK_SCREEN; $next = $sw.Elapsed.TotalSeconds + $Script:T_HINT }
      elseif ($sw.Elapsed.TotalSeconds -ge $next) { Hint $M_UNLOCK_SCREEN; $next = $sw.Elapsed.TotalSeconds + $Script:T_HINT }
    } else { break }
    if ($sw.Elapsed.TotalSeconds -ge $Script:T_USER) { Fail $M_BOOT_TIMEOUT }
    Wait-Sec 3
  }
  $Script:And = $kv
  $rb = Get-AndRid $kv; $rf = ''
  if ($rb) { if ((Get-KV $kv 'romutc') -match '^[0-9]+$') { $rf = ' (file)' } else { $rf = ' (getprop)' } } else { $rb = '?' }
  $fpl = Get-KV $kv 'ro.build.fingerprint'; if (-not $fpl) { $fpl = '?' }
  Write-Log ('ROM build: {0}{1}, fingerprint {2}' -f $rb, $rf, $fpl)
  if (-not (Test-Taoyao $kv)) {
    $model = Get-KV $kv 'ro.product.model'; if (-not $model) { $model = '?' }
    Fail ($M_NOT_TAOYAO -f $model, (Get-DevName $kv))
  }
  if (-not $Script:Sum.ContainsKey('PhoneShown')) {
    $Script:Sum['PhoneShown'] = $true
    $model = Get-KV $kv 'ro.product.model'; if (-not $model) { $model = '?' }
    $rel = Get-KV $kv 'ro.build.version.release'; if (-not $rel) { $rel = '?' }
    $rom = Get-KV $kv 'ro.build.display.id'; if (-not $rom) { $rom = '?' }
    if (Test-StockHyperOs $kv) { $rom = 'HyperOS (' + $rom + ')' }
    Say ($M_PHONE -f $model, $rel, $rom)
  }
  return $kv
}
# Test-StockHyperOs <kv>: stock HyperOS / MIUI (its recovery cannot install our zip)
function Test-StockHyperOs($kv) {
  $mi = (Get-KV $kv 'ro.mi.os.version.name') -or (Get-KV $kv 'ro.miui.ui.version.name')
  $custom = (Get-KV $kv 'ro.lineage.version') -or (Get-KV $kv 'ro.crdroid.version') -or (Get-KV $kv 'ro.evolution.version') -or (Get-KV $kv 'ro.modversion')
  return ($mi -and -not $custom)
}

# Test-Root: 'root' (su -c id gives uid=0), 'denied' (su is there, no
# uid=0), 'nosu' or 'mgr' (no su for adb, but a root manager that hides it
# is installed); three tries of T_SU, as the log collector
function Test-Root {
  $r = Invoke-Dev 'id -u' $false 20
  if ($r.Out.Trim() -eq '0') { $Script:AdbRoot = $true; GoodM $M_ROOT_OK; return 'root' }
  $Script:AdbRoot = $false
  $try = 1; $outx = ''
  while ($try -le 3) {
    $p = Start-AdbProc @('shell', $Script:P_SU_ID) '' $false ''
    $Script:AdbProc = $p
    $to = $p.StandardOutput.ReadToEndAsync(); $te = $p.StandardError.ReadToEndAsync()
    $sw = [Diagnostics.Stopwatch]::StartNew(); $shown = $false; $timedOut = $false
    while (-not $p.WaitForExit(200)) {
      Test-Interrupt
      if (-not $shown -and $sw.Elapsed.TotalSeconds -ge 5) { $shown = $true; Hint $M_ROOT_WAIT }
      if ($sw.Elapsed.TotalSeconds -ge $Script:T_SU) { try { $p.Kill() } catch { }; $timedOut = $true; break }
    }
    try { [void][Threading.Tasks.Task]::WaitAll([Threading.Tasks.Task[]]@($to, $te), 2000) } catch { }
    $outx = ''
    if ($to.IsCompleted -and -not $to.IsFaulted) { $outx += $to.Result }
    if ($te.IsCompleted -and -not $te.IsFaulted) { $outx += $te.Result }
    $code = 124; if (-not $timedOut) { try { $code = $p.ExitCode } catch { $code = 1 } }
    $Script:AdbProc = $null
    try { $p.Dispose() } catch { }
    Write-Log ('< rc={0} {1}' -f $code, $outx.Trim())
    if ($outx -match 'uid=0') { GoodM $M_ROOT_OK; return 'root' }
    if ($outx -match "(?i)device '.*' not found|no devices|device offline|error: closed") {
      WarnM $M_LOST
      [void](Wait-Phone -Want @('device') -Limit $Script:T_USER)
      continue
    }
    if ($code -eq 127 -or $outx -match '(?i)not found|inaccessible|No such file') {
      # (KernelSU, SukiSU-Ultra and APatch hide su from apps they have not
      # granted and never ask on screen: their manager app tells)
      if (Test-RootMgr) { return 'mgr' }
      Say $M_ROOT_NONE; Say $M_ROOT_NONE2; return 'nosu'
    }
    if ($try -lt 3) { WarnM ($M_ROOT_RETRY -f ($try + 1)); Wait-Sec 5 }
    $try++
  }
  return 'denied'
}
# Get-RootInfo: P_ROOT under su (reliable bootloader state, the work dir)
function Get-RootInfo {
  return (Invoke-Probe (Get-Tpl $Script:P_ROOT) $true @('device'))
}

# Get-RecInfo: P_REC (recovery, root shell); the phone's clock in LastNow
function Get-RecInfo {
  $kv = Invoke-Probe (Get-Tpl $Script:P_REC) $false @('recovery')
  $now = [long]0; [void][long]::TryParse((Get-KV $kv 'now'), [ref]$now); $Script:LastNow = $now
  $logs = New-Object System.Collections.ArrayList
  foreach ($l in (Get-KVAll $kv 'log')) {
    $m = [regex]::Match($l, '^([0-9]*):(/.+)$')
    if ($m.Success) { $t = [long]-1; [void][long]::TryParse($m.Groups[1].Value, [ref]$t); [void]$logs.Add([pscustomobject]@{ Mtime = $t; Path = $m.Groups[2].Value }) }
  }
  $ak = [long]-1; [void][long]::TryParse((Get-KV $kv 'akhome'), [ref]$ak)
  $twrp = ((Get-KV $kv 'twrp') -eq '1')
  # (no parentheses in the name: it also goes inside «Способ: … (…)»)
  $kind = 'TWRP или OrangeFox'
  $tv = Get-KV $kv 'ro.twrp.version'; if ($twrp -and $tv) { $kind = $kind + ', версия ' + $tv }
  if (-not $twrp) {
    $kind = 'на базе LineageOS'
    $cr = Get-KV $kv 'ro.crdroid.version'; $ev = Get-KV $kv 'ro.evolution.version'; $lo = Get-KV $kv 'ro.lineage.version'; if (-not $lo) { $lo = Get-KV $kv 'ro.modversion' }
    if ($cr) { $kind = 'LineageOS из crDroid ' + $cr }
    elseif ($ev) { $kind = 'LineageOS из Evolution X ' + $ev }
    elseif ($lo) { $kind = 'LineageOS ' + $lo }
  }
  $dm = ((Get-KV $kv 'datamnt') -eq '1')
  # (the ROM's recovery is built with the ROM: the same ro.build.date.utc;
  # TWRP / OrangeFox describe themselves)
  $rrid = [string](Get-KV $kv 'ro.build.date.utc')
  if ($rrid -notmatch '^[0-9]+$' -or $twrp -or (Get-KV $kv 'ro.twrp.version')) { $rrid = '' }
  # (the installer keeps its copy in the first store it can use, as the
  # store= lines say, and then writes in the same pass; without the
  # storeprobe line the old test: /sdcard usable)
  $sd = $false
  if ((Get-KV $kv 'storeprobe') -eq '1') {
    foreach ($x in (Get-KVAll $kv 'store')) {
      $i = $x.IndexOf(':'); $mb = [long]-1
      if ($i -gt 0) { $mb = Get-DfAvailMB $x.Substring($i + 1) }
      Write-Log ('store {0}: {1} MB free' -f $x, $mb)
      if ($mb -lt 0 -or $mb -ge $Script:STORE_NEED_MB) { $sd = $true }
    }
  } else { $sd = ($dm -and ((Get-KV $kv 'sdandroid') -eq '1' -or (Get-KV $kv 'sdw') -eq '1')) }
  $rec = [pscustomobject]@{
    Kv = $kv; Uid = (Get-KV $kv 'uid'); Twrp = $twrp; Kind = $kind; Kr = (Get-KV $kv 'kr'); Bat = (Get-KV $kv 'bat')
    Slot = (Get-SlotOf $kv); DataMnt = $dm
    SdUsable = $sd
    AkHome = $ak; Baks = @(Get-KVAll $kv 'bak'); Logs = $logs.ToArray(); Now = $now
    Debuggable = ((Get-KV $kv 'ro.debuggable') -eq '1'); Fp = (Get-KV $kv 'ro.build.fingerprint')
    Rid = $rrid
  }
  $Script:Rec = $rec
  $Script:Sum['Rec'] = $kind
  return $rec
}
# Test-RecChecks <rec> <first>: taoyao, bootloader, slot, battery, uid 0
function Test-RecChecks($rec, [bool]$first, [string]$nowLine = '') {
  if (-not (Test-Taoyao $rec.Kv)) { Fail ($M_NOT_TAOYAO -f '?', (Get-DevName $rec.Kv)) }
  if ($first) { Say ($M_REC_KIND -f $rec.Kind) }
  $bl = Get-BlState $rec.Kv $true
  if ($bl -eq 'locked') {
    if ($first) { $Script:Sum['Result'] = 'nothing'; $Script:Sum['What'] = $U_LOCKED }
    Fail ($M_BL_LOCKED -f $Script:BlWhat)
  }
  if ($first) { if ($bl -eq 'unlocked') { GoodM $M_BL_OK } else { Say $M_BL_UNKNOWN } }
  if ($rec.Slot -ne '_a' -and $rec.Slot -ne '_b') { Fail $M_NO_SLOT }
  $Script:Slot = $rec.Slot
  if ($first) { Say ($M_SLOT -f $rec.Slot) }
  if ($first -and $nowLine) { Say $nowLine }
  Test-Battery $rec.Bat
  # (1.1: ADB without root: never just fail)
  if ($rec.Uid -ne '0') { Invoke-RecNoRoot $rec }
}
# Get-SlotHashes <slot> <root>: sha256 of boot, vendor_boot, dtbo of a slot
# (recovery as it is; Android under su); keys boot.img, vendor_boot.img, dtbo.img
function Get-SlotHashes([string]$slot, [bool]$root, [string[]]$want) {
  $kv = Invoke-Probe ($Script:P_HASH.Replace('{SLOT}', $slot)) $root $want $Script:T_HASH
  $h = @{}
  foreach ($p in @('boot', 'vendor_boot', 'dtbo')) { $h[$p + '.img'] = (Get-KV $kv ('h_' + $p)).ToLowerInvariant() }
  Write-Log ('slot {0}: boot {1}, vendor_boot {2}, dtbo {3}' -f $slot, $h['boot.img'], $h['vendor_boot.img'], $h['dtbo.img'])
  return $h
}
function Test-HashesKnown($h) { foreach ($n in $Script:IMGS) { if (-not (Get-H $h $n)) { return $false } }; return $true }

########################################################################
# copies of the slot: list on the phone, pull, verify, classify and file
# (section 12). Filed folders under taoyao-stock-images and
# taoyao-<series>-backups are never changed afterwards.

# Get-Remote <path> <su>: in Android without su, /sdcard for the other names
# of the internal storage (adb's shell can read /sdcard)
function Get-Remote([string]$p, [bool]$su) {
  if ($su -or $Script:CurCtx -ne 'android') { return $p }
  foreach ($x in @('/storage/emulated/0/', '/data/media/0/')) { if ($p.StartsWith($x)) { return '/sdcard/' + $p.Substring($x.Length) } }
  return $p
}
# Get-RootDirs <root> <su>: names in a backup root (D= lines)
function Get-RootDirs([string]$root, [bool]$su, [string[]]$want) {
  $kv = Invoke-Probe ($Script:P_LISTROOT.Replace('{ROOT}', $root)) $su $want
  return @(Get-KVAll $kv 'D')
}
# Get-PhoneDir <dir> <su>: one backup dir: files (size, mtime), SHA256SUMS, info.txt
function Get-PhoneDir([string]$dir, [bool]$su, [string[]]$want) {
  $r = $null
  for ($i = 0; $i -lt 3; $i++) {
    $r = Invoke-Dev ($Script:P_LISTDIR.Replace('{DIR}', $dir)) $su 60
    if ($r.Out -match '(?m)^end=1\s*$') { break }
    if ((Test-Lost $r) -or $r.TimedOut) { WarnM $M_LOST; [void](Wait-Phone -Want $want -Limit $Script:T_USER -Ctx (Get-Ctx $want)); continue }
    Fail ($M_PHONE_NOANSWER -f (Get-FirstLine $r))
  }
  if ($r.Out -notmatch '(?m)^end=1\s*$') { Fail ($M_PHONE_NOANSWER -f (Get-FirstLine $r)) }
  if ($r.Out -match '(?m)^nodir=1') { return $null }
  $files = @{}; $sums = New-Object System.Text.StringBuilder; $info = New-Object System.Text.StringBuilder
  $sec = ''
  foreach ($l in (Get-Lines $r.Out)) {
    if ($l -eq '=SUMS') { $sec = 'sums'; continue }
    if ($l -eq '=INFO') { $sec = 'info'; continue }
    if ($l -eq '=END') { $sec = 'end'; continue }
    if ($sec -eq '') {
      $m = [regex]::Match($l, '^F=([0-9]*):([0-9]*):(.+)$')
      if ($m.Success) {
        $sz = [long]-1; [void][long]::TryParse($m.Groups[1].Value, [ref]$sz)
        $mt = [long]-1; [void][long]::TryParse($m.Groups[2].Value, [ref]$mt)
        $files[$m.Groups[3].Value] = [pscustomobject]@{ Size = $sz; Mtime = $mt }
      }
    } elseif ($sec -eq 'sums') { [void]$sums.Append($l + "`n") }
    elseif ($sec -eq 'info') { [void]$info.Append($l + "`n") }
  }
  $name = $dir.Substring($dir.LastIndexOf('/') + 1)
  $mn = [regex]::Match($name, $Script:BAKDIR_RE)
  $logs = @($files.Keys | Where-Object { $_ -match $Script:INSTLOG_RE } | Sort-Object)
  $infoH = Read-InfoText $info.ToString()
  return [pscustomobject]@{
    Path = $dir; Name = $name; Slot = $(if ($mn.Success) { $mn.Groups[2].Value } else { '' }); Su = $su
    Files = $files; SumsText = $sums.ToString(); Sums = (Read-Sums $sums.ToString()); InfoText = $info.ToString(); Info = $infoH
    Logs = $logs; RzName = $Script:RZIP_FMT.Replace('{dir}', $name); Kernel = (Get-H $infoH 'kernel')
  }
}
function Get-ListingBytes($pd) {
  $n = [long]0
  foreach ($k in $pd.Files.Keys) { if ($pd.Files[$k].Size -gt 0) { $n += $pd.Files[$k].Size } }
  return $n
}
function Get-SumsKey($pd) { return ($pd.Path + '|' + (Get-H $pd.Sums 'boot.img') + (Get-H $pd.Sums 'vendor_boot.img') + (Get-H $pd.Sums 'dtbo.img')) }

# Test-FiledFull <kept folder> [listing]: '' when the kept folder is whole:
# the three images there, not empty, with the sizes of the phone's copy
# (when given) and the sha256 of its SHA256SUMS, and its restore zip (needed
# when the phone's copy has one) matching its .sha256 and the images; else
# what is wrong. Checked once per folder and run (the files are never changed).
function Test-FiledFull($f, $pd) {
  $key = $f.Path
  if ($null -ne $pd) { $key = $f.Path + '|' + $pd.Path }
  if ($Script:FiledOk.ContainsKey($key)) { return [string]$Script:FiledOk[$key] }
  $e = ''
  try {
    foreach ($n in $Script:IMGS) {
      $pf = Join-Path $f.Path $n
      if (-not [IO.File]::Exists($pf)) { $e = ('нет файла ' + $n); break }
      $len = Get-FileLen $pf
      if ($len -le 0) { $e = ($n + ' пустой'); break }
      if ($null -ne $pd -and $pd.Files.ContainsKey($n) -and $pd.Files[$n].Size -ge 0 -and $len -ne $pd.Files[$n].Size) { $e = ('{0}: размер {1} вместо {2}' -f $n, $len, $pd.Files[$n].Size); break }
      $want = Get-H $f.Sums $n
      if (-not $want -or (Get-Sha256 $pf) -ne $want) { $e = ($n + ': sha256 не совпадает с SHA256SUMS'); break }
    }
    $needRz = ($null -ne $pd -and $pd.Files.ContainsKey($pd.RzName))
    if (-not $e -and ($needRz -or $f.RZip)) {
      if (-not $f.RZip) { $e = 'нет restore-zip или его .sha256' }
      else {
        $w = [regex]::Match([IO.File]::ReadAllText($f.RZip + '.sha256'), '^[0-9a-fA-F]{64}')
        if (-not $w.Success -or (Get-Sha256 $f.RZip) -ne $w.Value.ToLowerInvariant()) { $e = ([IO.Path]::GetFileName($f.RZip) + ': sha256 не совпадает с .sha256') }
        else { $x = Test-RestoreZip $f.RZip $f.Slot $f.Path $f.Sums; if ($x) { $e = ([IO.Path]::GetFileName($f.RZip) + ': ' + $x) } }
      }
    }
  } catch { if (Test-Exit $_) { throw }; $e = ('не читается: ' + $_.Exception.Message) }
  if ($e) { Write-Log ('kept folder not whole: {0}: {1}' -f $f.Path, $e) }
  $Script:FiledOk[$key] = $e
  return $e
}
# Find-Filed <listing> [quiet]: a kept PC folder of the same class, slot and
# images that is whole (Test-FiledFull); a kept folder with the same images
# that is not whole is named once (the copy is then pulled and filed anew)
function Find-Filed($pd, [bool]$quiet = $false) {
  $cls = Get-Class $pd.Kernel
  foreach ($f in @(Get-FiledFolders)) {
    if ($f.Class -ne $cls -or $f.Slot -ne $pd.Slot) { continue }
    if (-not (Test-SameSums $f.Sums $pd.Sums)) { continue }
    $e = Test-FiledFull $f $pd
    if (-not $e) { return $f }
    if (-not $quiet -and -not $Script:Warned.ContainsKey('filed|' + $f.Path)) { $Script:Warned['filed|' + $f.Path] = 1; WarnM ($M_COPY_KNOWN_BAD -f $f.Path, $e) }
  }
  return $null
}

# Invoke-PullFile <remote> <local name> <folder>: one adb pull ($Script:PullErr;
# $Script:PullLost: it failed because the connection was lost)
function Invoke-PullFile([string]$remote, [string]$name, [string]$dir) {
  $lp = Join-Path $dir $name
  try { if ([IO.File]::Exists($lp)) { [IO.File]::Delete($lp) } } catch { }
  $Script:PullPartial.Add($lp)
  $r = Invoke-Adb @('pull', $remote, $name) $Script:T_PULL $dir
  [void]$Script:PullPartial.Remove($lp)
  $Script:PullErr = ''; $Script:PullLost = $false
  $txt = $r.Out + $r.Err
  if ($r.Code -eq 0 -and [IO.File]::Exists($lp)) { return $true }
  $Script:PullLost = ((Test-Lost $r) -or $r.TimedOut)
  if ($txt -match '(?i)Access is denied|Отказано в доступе') { WarnM ($M_ACCESS_DENIED -f $dir) }
  $Script:PullErr = Get-FirstLine $r
  if ($txt -match '(?i)Permission denied') { $Script:PullErr = 'Permission denied' }
  try { if ([IO.File]::Exists($lp)) { [IO.File]::Delete($lp) } } catch { }
  return $false
}

# Test-Backup <PC folder> <listing>: the checks of 12.4; '' or what failed
# ($Script:VRz: the restore zip is there and checks out)
function Test-Backup([string]$pc, $pd) {
  $Script:VRz = $false
  foreach ($n in @('boot.img', 'vendor_boot.img', 'dtbo.img', 'SHA256SUMS', 'info.txt')) {
    $p = Join-Path $pc $n
    if (-not [IO.File]::Exists($p)) { return ('нет файла ' + $n) }
    $len = Get-FileLen $p
    if ($pd.Files.ContainsKey($n) -and $pd.Files[$n].Size -ge 0 -and $len -ne $pd.Files[$n].Size) { return ('{0}: {1} байт вместо {2}' -f $n, $len, $pd.Files[$n].Size) }
    if ($Script:IMGS -contains $n -and $len -le 0) { return ($n + ' пустой') }
  }
  $sums = Read-Sums ([IO.File]::ReadAllText((Join-Path $pc 'SHA256SUMS')))
  if ($sums.Count -ne 3) { return ('SHA256SUMS: {0} строк вместо 3' -f $sums.Count) }
  foreach ($n in $Script:IMGS) {
    $want = Get-H $sums $n
    if (-not $want) { return ('SHA256SUMS: нет строки ' + $n) }
    if ((Get-Sha256 (Join-Path $pc $n)) -ne $want) { return ('sha256 ' + $n + ' не совпадает с SHA256SUMS') }
  }
  $info = Read-InfoText ([IO.File]::ReadAllText((Join-Path $pc 'info.txt')))
  if ((Get-H $info 'slot') -ne $pd.Slot) { return ('info.txt: слот не ' + $pd.Slot) }
  if (-not (Get-H $info 'kernel')) { return 'info.txt: нет строки kernel=' }
  # the restore zip (may be missing: "could not make it (no space?)")
  $rz = Join-Path $pc $pd.RzName
  if (-not $pd.Files.ContainsKey($pd.RzName) -and -not [IO.File]::Exists($rz)) { return '' }
  if (-not [IO.File]::Exists($rz)) { return ('нет файла ' + $pd.RzName) }
  if (-not [IO.File]::Exists($rz + '.sha256')) { return ('нет файла ' + $pd.RzName + '.sha256') }
  $w = [regex]::Match([IO.File]::ReadAllText($rz + '.sha256'), '^[0-9a-fA-F]{64}')
  if (-not $w.Success -or (Get-Sha256 $rz) -ne $w.Value.ToLowerInvariant()) { return ('sha256 ' + $pd.RzName + ' не совпадает с ' + $pd.RzName + '.sha256') }
  $e = Test-RestoreZip $rz $pd.Slot $pc $sums
  if ($e) { return ($pd.RzName + ': ' + $e) }
  $Script:VRz = $true
  return ''
}
# Test-RestoreZip <zip> <slot> <folder with images or ''> <sums>: restore.prop
# says taoyao and the slot, sizes match the images, its SHA256SUMS = the folder's
function Test-RestoreZip([string]$rz, [string]$slot, [string]$pc, $sums) {
  $za = $null
  try {
    $za = [IO.Compression.ZipFile]::OpenRead($rz)
    $prop = Read-InfoText (Read-ZipText $za 'restore.prop')
    if ((Get-H $prop 'device') -ne $Script:DEVICE) { return ('restore.prop: не ' + $Script:DEVICE) }
    if ((Get-H $prop 'slot') -ne $slot) { return ('restore.prop: слот не ' + $slot) }
    if ($pc) {
      foreach ($p in @('boot', 'vendor_boot', 'dtbo')) {
        $f = Join-Path $pc ($p + '.img')
        if ([IO.File]::Exists($f) -and [string](Get-FileLen $f) -ne (Get-H $prop ($p + '.size'))) { return ('restore.prop: размер ' + $p + ' не совпадает') }
      }
    }
    $zs = Read-Sums (Read-ZipText $za 'SHA256SUMS')
    if (-not (Test-SameSums $zs $sums)) { return 'SHA256SUMS в restore-zip другие' }
    return ''
  } catch { return 'не открывается как ZIP' }
  finally { if ($null -ne $za) { $za.Dispose() } }
}

# Get-StockLabel <info>: the ROM build for the folder name
function Get-StockLabel($info) {
  $r = Get-H $info 'ipa_uapi_stock_reason'
  $m = [regex]::Match($r, '^[^:]+: hyperos, stock (HyperOS [^ ,]+),')
  if ($m.Success) { return $m.Groups[1].Value }
  $m = [regex]::Match($r, '^[^:]+: custom, ([^,]+), vendor built')
  if ($m.Success) { return $m.Groups[1].Value }
  $fp = Get-H $info 'fingerprint'
  $f = @($fp.Split('/'))
  if ($f.Count -ge 5) { $inc = $f[4].Split(':')[0]; if ($inc) { return $inc } }
  $rd = Get-H $info 'boot_ramdisk'
  if ($rd.Length -ge 8) { return ('rom-' + $rd.Substring(0, 8)) }
  return 'unknown-rom'
}
function Get-SafeName([string]$s) {
  $s = [regex]::Replace($s, '[^A-Za-z0-9._-]', '_')
  $s = [regex]::Replace($s, '_+', '_').Trim('_')
  if ($s.Length -gt 40) { $s = $s.Substring(0, 40) }
  if (-not $s) { $s = 'copy' }
  return $s
}
# Save-Backup <pulled folder> <listing>: rename into its class folder (or
# copy, check, delete); the new path
function Save-Backup([string]$pc, $pd) {
  $info = Read-InfoText ([IO.File]::ReadAllText((Join-Path $pc 'info.txt')))
  $k = Get-H $info 'kernel'
  $cls = Get-Class $k
  if ($cls -eq 'STOCK') { $label = Get-StockLabel $info; $top = Join-Path $Script:Base $Script:PC_STOCK }
  else {
    $v = Get-RelVer $k
    if ($v) { $label = 'v' + $v } else { $label = $k }
    $top = Join-Path $Script:Base ($Script:PC_PREV_FMT.Replace('{series}', (Get-Series $k)))
  }
  $stamp = $pd.Name; if ($pd.Slot) { $stamp = $pd.Name.Substring(0, $pd.Name.Length - $pd.Slot.Length) }
  $name = (Get-SafeName $label) + '-slot_' + $pd.Slot.TrimStart('_') + '-' + $stamp
  [void][IO.Directory]::CreateDirectory($top)
  $dest = Join-Path $top $name; $n = 2
  while ([IO.Directory]::Exists($dest) -or [IO.File]::Exists($dest)) { $dest = Join-Path $top ($name + '-' + $n); $n++ }
  $moved = $false
  try { [IO.Directory]::Move($pc, $dest); $moved = $true } catch { Write-Log ('move failed, copying: ' + $_.Exception.Message) }
  if (-not $moved) {
    [void][IO.Directory]::CreateDirectory($dest)
    foreach ($f in [IO.Directory]::GetFiles($pc)) {
      $t = Join-Path $dest ([IO.Path]::GetFileName($f))
      [IO.File]::Copy($f, $t)
      if ((Get-FileLen $t) -ne (Get-FileLen $f)) { throw ('копия файла не совпала: ' + $t) }
      if ($Script:IMGS -contains [IO.Path]::GetFileName($f) -and (Get-Sha256 $t) -ne (Get-Sha256 $f)) { throw ('копия файла не совпала: ' + $t) }
    }
    [IO.Directory]::Delete($pc, $true)
  }
  $Script:Filed = $null
  Write-Log ('filed as {0}: {1}' -f $cls, $dest)
  return $dest
}
# Add-SumCopy <class> <path> <listing>: remember for the summary
function Add-SumCopy([string]$cls, [string]$path, $pd) {
  $key = 'Stock'; if ($cls -eq 'PREV') { $key = 'Prev' }
  if (-not $Script:Sum.ContainsKey($key)) { $Script:Sum[$key] = New-Object System.Collections.ArrayList }
  foreach ($x in $Script:Sum[$key]) { if ($x.Path -eq $path) { return } }
  [void]$Script:Sum[$key].Add([pscustomobject]@{ Path = $path; Slot = $pd.Slot; Kernel = $pd.Kernel; Ramdisk = (Get-H $pd.Info 'boot_ramdisk'); Fp = (Get-H $pd.Info 'fingerprint'); RzName = $pd.RzName })
}

# Copy-PhoneDir <listing> <want>: pull + verify (+ one more pull) + file; or
# M_COPY_KNOWN for a copy that is on the PC already (and whole). A lost
# connection is waited for (the file is pulled again once the phone is back
# in a <want> state), at most MAX_TRIES times. An object: Ok, Path, Class,
# RzOk, Known, Reason, Lost (it failed because the connection kept dropping)
# Copy-NewLogs <phone dir> <kept folder>: its install logs that the kept
# folder lacks, into this run's pull folder (as run-flash.sh pull_dir)
function Copy-NewLogs($pd, [string]$kept) {
  foreach ($lg in @($pd.Logs)) {
    if (-not $lg -or [IO.File]::Exists((Join-Path $kept $lg))) { continue }
    $d = Join-Path (Get-PullDir) $pd.Name
    if ([IO.File]::Exists((Join-Path $d $lg))) { continue }
    [void][IO.Directory]::CreateDirectory($d)
    [void](Invoke-PullFile (Get-Remote ($pd.Path + '/' + $lg) $pd.Su) $lg $d)
  }
}
function Copy-PhoneDir($pd, [string[]]$want, [bool]$mkRz = $false) {
  $key = Get-SumsKey $pd
  if ($Script:Handled.ContainsKey($key)) {
    $h = $Script:Handled[$key]
    if ($h.Ok -and $h.Path) { Copy-NewLogs $pd $h.Path }
    return $h
  }
  $cls = Get-Class $pd.Kernel
  $res = [pscustomobject]@{ Ok = $false; Path = ''; Class = $cls; RzOk = $false; Known = $false; Reason = ''; Listing = $pd; Lost = $false; Disk = $false }
  $known = Find-Filed $pd
  $prev = $Script:Phase
  $Script:PrePullPhase = $prev; $Script:Phase = 'pull'
  try {
    if ($null -ne $known) {
      Say ($M_COPY_KNOWN -f $known.Path)
      # (install logs that the kept folder lacks go to this run's pull folder)
      Copy-NewLogs $pd $known.Path
      $res.Ok = $true; $res.Path = $known.Path; $res.Known = $true
      $res.RzOk = [bool]($known.RZip -and [IO.Path]::GetFileName($known.RZip) -eq $pd.RzName)
      if (-not $res.RzOk) { $res.RzOk = [bool]$known.RZip }
      Add-SumCopy $cls $known.Path $pd
      $Script:Handled[$key] = $res
      return $res
    }
    $need = (Get-ListingBytes $pd)
    $free = Get-FreeMB $Script:Base
    $needMB = [long]([Math]::Ceiling($need * 1.05 / 1048576.0)) + 100
    if ($free -ge 0 -and $free -lt $needMB) { $t = ($M_PC_SPACE -f $free, $needMB); ErrM $t; $res.Reason = (Get-ReasonText $t); $res.Disk = $true; return $res }
    $d = Join-Path (Get-PullDir) $pd.Name
    $Script:PullCurDir = $d
    $lostN = 0
    for ($round = 1; $round -le 2; $round++) {
      [void][IO.Directory]::CreateDirectory($d)
      $names = [string[]]@($pd.Files.Keys | Where-Object { $_ -match '^[A-Za-z0-9._-]+$' })
      [Array]::Sort($names, [StringComparer]::Ordinal)
      $useRoot = $false; $err = ''
      foreach ($n in $names) {
        Say ($M_PULLING -f $n, (Format-Size $pd.Files[$n].Size))
        while ($true) {
          $remote = Get-Remote ($pd.Path + '/' + $n) $pd.Su
          if ($useRoot) { $remote = $Script:PH_WORK + '/pull/' + $pd.Name + '/' + $n }
          $ok = Invoke-PullFile $remote $n $d
          if (-not $ok -and -not $useRoot -and $Script:PullErr -eq 'Permission denied' -and $Script:CurCtx -eq 'android' -and $Script:HasSu) {
            # (Android: a folder adb cannot read: copy it as root to the work dir first)
            [void](Invoke-Dev (Get-Tpl $Script:P_A_PREP) $false 30)
            $cp = Invoke-Dev ($Script:P_A_PULLCOPY.Replace('{W}', $Script:PH_WORK).Replace('{NAME}', $pd.Name).Replace('{DIR}', $pd.Path)) $true 300
            if ($cp.Out -match 'end=1') { $useRoot = $true; $ok = Invoke-PullFile ($Script:PH_WORK + '/pull/' + $pd.Name + '/' + $n) $n $d }
          }
          # (a cable pulled mid-file can also show as a read error: the phone gone counts as lost)
          if (-not $ok -and -not $Script:PullLost) { $sn = Scan-Devices $want; if ($want -notcontains $sn) { $Script:PullLost = $true } }
          if ($ok -or -not $Script:PullLost) { break }
          # (the cable or the connection went: wait for the phone, then this file again)
          $lostN++
          Write-Log ('pull: connection lost ({0}), {1}' -f $n, $lostN)
          if ($lostN -gt $Script:MAX_PULLS) { break }
          WarnM ($M_PULL_LOST -f $n)
          $h = $H_REPLUG; if ((Get-Ctx $want) -ne 'recovery') { $h = $H_REPLUG_A }
          [void](Wait-Phone -Want $want -Limit $Script:T_USER -Ctx (Get-Ctx $want) -Hint $h -HintAfter 5 -MoreText $M_WAIT_MORE_CABLE)
          Wait-Sec 1
        }
        if (-not $ok) { $err = ('{0}: {1}' -f $n, $Script:PullErr); break }
      }
      if ($useRoot) { [void](Invoke-Dev (Get-Tpl $Script:P_A_PULLCLEAN) $true 60) }
      if ($err -and $lostN -gt $Script:MAX_PULLS) {
        try { [IO.Directory]::Delete($d, $true) } catch { }
        $Script:PullCurDir = $null
        $res.Reason = $err; $res.Lost = $true
        return $res
      }
      # (way A copy only: the restore zip made here; info.txt then names it)
      $rzPcNone = $false
      if (-not $err -and $mkRz) {
        if (New-RzPc $d $pd) { $pd.Files['info.txt'].Size = Get-FileLen (Join-Path $d 'info.txt') } else { $rzPcNone = $true }
      }
      if (-not $err) { $err = Test-Backup $d $pd }
      if (-not $err) { if ($Script:VRz) { GoodM ($M_VERIFY_OK -f $pd.Name) } else { GoodM ($M_VERIFY_OK_NORZ -f $pd.Name) }; break }
      Write-Log ('verify failed: ' + $err)
      # (only the pull folder's copy is removed, never a kept folder)
      try { [IO.Directory]::Delete($d, $true) } catch { }
      if ($round -eq 1) { WarnM ($M_VERIFY_RETRY -f $err); continue }
      $Script:PullCurDir = $null
      $res.Reason = $err
      return $res
    }
    $dest = Save-Backup $d $pd
    $Script:PullCurDir = $null
    $res.Ok = $true; $res.Path = $dest; $res.RzOk = $Script:VRz
    if ($cls -eq 'STOCK') {
      GoodM ($M_STOCK_SAVED -f $dest)
      $k = $pd.Kernel; if ($k -eq 'unknown') { $k = $k + ' ' + $M_STOCK_UNKNOWNK }
      # (the ROM build when the copy names it: the fingerprint may be spoofed)
      $fpd = Get-H $pd.Info 'fingerprint'; $r = Get-RidOf $pd.Info
      if ($r) { $v = Get-H $pd.Info 'rom_version'; if (-not $v) { $v = '?' }; $fpd = ($M_ROM_BUILT -f $v, (Format-Utc $r)) }
      Say ($M_STOCK_SAVED2 -f $k, $fpd, $pd.Slot)
    } else {
      $v = Get-RelVer $pd.Kernel; if ($v) { $v = 'v' + $v } else { $v = $pd.Kernel }
      GoodM ($M_PREV_SAVED -f (Get-Series $pd.Kernel), $v, $dest)
    }
    if (-not $Script:VRz) { if ($rzPcNone) { WarnM ($M_RZ_PC_FAIL -f $dest) } else { WarnM ($M_RZ_MISSING -f $dest) } }
    Add-SumCopy $cls $dest $pd
    $Script:Handled[$key] = $res
    return $res
  } finally { $Script:Phase = $prev }
}

# Sync-PhoneCopies <dirs> <su> <want>: every backup dir given (remote paths)
# that is not on the PC yet: pulled, verified, filed; newest first
function Sync-PhoneCopies([string[]]$dirs, [bool]$su, [string[]]$want, [string]$count = 'all') {
  $out = New-Object System.Collections.ArrayList
  $list = New-Object System.Collections.ArrayList
  $seen = @{}
  foreach ($d in @($dirs | Sort-Object -Descending { $_.Substring($_.LastIndexOf('/') + 1) })) {
    if (-not $d -or $seen.ContainsKey($d)) { continue }
    $seen[$d] = 1
    $nm = $d.Substring($d.LastIndexOf('/') + 1)
    if ($nm -notmatch $Script:BAKDIR_RE) { continue }
    $pd = Get-PhoneDir $d $su $want
    if ($null -eq $pd -or $pd.Sums.Count -lt 3) { continue }
    [void]$list.Add($pd)
  }
  if ($list.Count -eq 0) { return }
  $new = 0; $bytes = [long]0
  foreach ($pd in $list) { if (-not $Script:Handled.ContainsKey((Get-SumsKey $pd)) -and $null -eq (Find-Filed $pd $true)) { $new++; $bytes += Get-ListingBytes $pd } }
  $unh = @($list | Where-Object { -not $Script:Handled.ContainsKey((Get-SumsKey $_)) }).Count
  # (the count line: in step 3 (all), after a write only when there are
  # new ones (new), never for the copy of this pass (none): as run-flash.sh)
  $show = ($unh -gt 0); if ($count -eq 'none') { $show = $false } elseif ($count -eq 'new') { $show = ($new -gt 0) }
  if ($show) { Say ($M_PHONE_COPIES -f $list.Count, $new, (Format-Size $bytes)) }
  foreach ($pd in $list) {
    $r = Copy-PhoneDir $pd $want
    $r | Add-Member -NotePropertyName Remote -NotePropertyValue $pd.Path -Force
    [void]$out.Add($r)
  }
  return $out.ToArray()
}
# Copy-Pstore <root> <names> <su>: the last boots' kernel logs (small), once per PC
function Copy-Pstore([string]$root, [string[]]$names, [bool]$su) {
  foreach ($n in $names) {
    if ($n -notmatch $Script:PSTORE_RE) { continue }
    $have = $false
    foreach ($b in $Script:Bases) {
      try {
        foreach ($pf in [IO.Directory]::GetDirectories($b, ($Script:BACKUP_NAME + '-*'))) { if ([IO.Directory]::Exists((Join-Path $pf $n))) { $have = $true } }
      } catch { }
    }
    if ($have) { continue }
    $r = Invoke-Adb @('pull', (Get-Remote ($root + '/' + $n) $su), $n) 120 (Get-PullDir)
    if ($r.Code -eq 0) { Write-Log ('pstore pulled: ' + $n) } else { try { [IO.Directory]::Delete((Join-Path (Get-PullDir) $n), $true) } catch { } }
  }
}
# Sync-Root <root> <su> <want>: the backup dirs and pstore dirs of one root
function Sync-Root([string]$root, [bool]$su, [string[]]$want, [string]$count = 'all') {
  $names = @(Get-RootDirs $root $su $want)
  $dirs = @($names | Where-Object { $_ -match $Script:BAKDIR_RE } | ForEach-Object { $root + '/' + $_ })
  $r = @()
  if ($dirs.Count -gt 0) { $r = @(Sync-PhoneCopies $dirs $su $want $count) }
  Copy-Pstore $root @($names | Where-Object { $_ -match $Script:PSTORE_RE }) $su
  return $r
}

########################################################################
# the installer's result (section 11): taoyao-result lines first (75b0c4d
# and later), the English text markers for the 0.18 installer; taoyao-run
# ids (later builds) tell this pass's log from an older one

# Read-LogInfo <text>: what one installer log (or the streamed screen text) says
function Read-LogInfo([string]$text) {
  $o = [pscustomobject]@{
    Lines = @(Get-Lines $text); RunIds = (New-Object 'System.Collections.Generic.List[string]'); Res = ''; Rel = ''; Slot = ''; Dir = ''; Reused = $false
    Cls = ''; HasRes = $false; RzRes = ''; RzHead = $false; RzOk = $false; RzNoop = $false; RzFail = $false; NothingWritten = $false
  }
  $done = $false; $dirty = $false; $rb = -1; $rolled = $false; $step1 = $false; $abort = -1
  $i = 0
  foreach ($l0 in $o.Lines) {
    $l = $l0.TrimEnd()
    if ($l.StartsWith('ui_print ')) { $l = $l.Substring(9) }
    $t = $l.Trim()
    if ($t.StartsWith('| ')) { $t = $t.Substring(2).Trim() }
    if ($l.StartsWith($Script:KEY_RUN)) { $o.RunIds.Add($l.Substring($Script:KEY_RUN.Length).Trim()) }
    elseif ($l.StartsWith($Script:RES_PREFIX)) { $o.Res = $l.Substring($Script:RES_PREFIX.Length).Trim(); $o.HasRes = $true }
    elseif ($l.StartsWith($Script:KEY_KERNEL)) { $o.Rel = $l.Substring($Script:KEY_KERNEL.Length).Trim() }
    elseif ($l.StartsWith($Script:KEY_SLOT)) { $o.Slot = $l.Substring($Script:KEY_SLOT.Length).Trim() }
    elseif ($l.StartsWith($Script:KEY_BACKUP)) { $o.Dir = $l.Substring($Script:KEY_BACKUP.Length).Trim() }
    $m = [regex]::Match($t, $Script:TXT_BACKUP_RE)
    if ($m.Success) {
      if (-not $o.Slot) { $o.Slot = $m.Groups[1].Value }
      if ($m.Groups[2].Success) { $o.Reused = $true }
      if (-not $o.Dir) { $o.Dir = $m.Groups[3].Value.Trim() }
    }
    if (-not $o.Rel) { $m = [regex]::Match($t, $Script:TXT_RELEASE_RE); if ($m.Success) { $o.Rel = $m.Groups[1].Value } }
    $m = [regex]::Match($t, $Script:TXT_DONE_RE); if ($m.Success) { $done = $true; if (-not $o.Slot) { $o.Slot = $m.Groups[1].Value } }
    if ($t -match $Script:TXT_DIRTY_RE) { $dirty = $true }
    if ($t.StartsWith($Script:TXT_ROLLBACK)) { $rb = $i }
    if ($rb -ge 0 -and $t.Contains($Script:TXT_ROLLED)) { $rolled = $true }
    if ($t.Contains($Script:TXT_STEP1)) { $step1 = $true }
    if ($t.Contains($Script:TXT_ABORTING)) { $abort = $i }
    if ($t.Contains($Script:TXT_NOTHING)) { $o.NothingWritten = $true }
    # restore zip
    $m = [regex]::Match($t, $Script:TXT_RZ_HEAD_RE); if ($m.Success) { $o.RzHead = $true; if (-not $o.Slot) { $o.Slot = $m.Groups[1].Value } }
    if ($t.Contains($Script:TXT_RZ_OK)) { $o.RzOk = $true }
    if ($t.Contains($Script:TXT_RZ_NOOP)) { $o.RzNoop = $true }
    if ($t.StartsWith($Script:TXT_RZ_FAIL)) { $o.RzFail = $true }
    $i++
  }
  if ($o.HasRes) {
    switch ($o.Res) {
      { $_ -eq $Script:RES_DONE } { $o.Cls = 'DONE' }
      { $_ -eq $Script:RES_DIRTY } { $o.Cls = 'DIRTY' }
      { $_ -eq $Script:RES_RESTORED } { $o.Cls = 'RESTORED' }
      { $_ -eq $Script:RES_STEP1 } { $o.Cls = 'STEP1' }
      { $_ -eq $Script:RES_CLEAN } { $o.Cls = 'CLEAN' }
      { $_ -eq $Script:RES_RZ_OK } { $o.RzRes = 'ok' }
      { $_ -eq $Script:RES_RZ_FAIL } { $o.RzRes = 'fail' }
    }
  }
  if (-not $o.Cls -and -not $o.RzRes) {
    if ($done) { $o.Cls = 'DONE' }
    elseif ($dirty) { $o.Cls = 'DIRTY' }
    elseif ($rb -ge 0 -and $rolled) { $o.Cls = 'RESTORED' }
    elseif ($step1) { $o.Cls = 'STEP1' }
    elseif ($abort -ge 0 -and ($rb -lt 0 -or $rb -lt $abort)) { $o.Cls = 'CLEAN' }
  }
  return $o
}

# New-Src <name> <text> <mtime> <stream>: one source of a result
function New-Src([string]$name, [string]$text, [long]$mtime, [bool]$stream) {
  $i = Read-LogInfo $text
  return [pscustomobject]@{ Name = $name; Text = $text; Mtime = $mtime; Stream = $stream; I = $i; Fresh = $false; Why = '' }
}
function Get-LogKey($s) {
  $h = [Security.Cryptography.SHA256]::Create()
  try { $b = $h.ComputeHash($Utf8.GetBytes([string]$s.Text)) } finally { $h.Dispose() }
  return ($s.Name + '|' + [BitConverter]::ToString($b))
}
# Test-Fresh <src> <T0p> <release>: the log belongs to this pass
function Test-Fresh($s, [long]$t0p, [string]$krel) {
  if ($s.Stream) { return $true }
  if ($Script:SeenLogs.ContainsKey((Get-LogKey $s))) { $s.Why = 'read in an earlier pass'; return $false }
  if ($null -ne $Script:Zip -and $Script:Zip.Gen -ge 3 -and -not $Script:RzMode) {
    # (a later installer writes a run id first: none, or one read before, is an older log)
    if ($s.I.RunIds.Count -eq 0) { $s.Why = 'no run id'; return $false }
    if ($Script:SeenRuns.Contains($s.I.RunIds[0])) { $s.Why = 'old run id'; return $false }
  }
  if ($t0p -gt 0 -and $s.Mtime -ge 0 -and $s.Mtime -lt ($t0p - 5)) { $s.Why = 'older than this pass'; return $false }
  if ($s.Mtime -lt 0 -and $t0p -gt 0) { $s.Why = 'no time'; return $false }
  if ($krel -and $s.I.Rel -and $s.I.Rel -ne $krel) { $s.Why = ('release ' + $s.I.Rel); return $false }
  return $true
}
# Get-Result <sources> <T0p> <release> <akhome mtime>: the result object
#   Res: DONE DIRTY RESTORED STEP1 CLEAN INCOMPLETE AK3_EARLY NOLOG
function Get-Result($srcs, [long]$t0p, [string]$krel, [long]$akm) {
  $fresh = New-Object System.Collections.ArrayList
  foreach ($s in @($srcs)) {
    if ($null -eq $s) { continue }
    $s.Fresh = Test-Fresh $s $t0p $krel
    Write-Log ('result source {0}: fresh={1} {2} class={3} res={4} rel={5} dir={6} runs={7}' -f $s.Name, $s.Fresh, $s.Why, $s.I.Cls, $s.I.Res, $s.I.Rel, $s.I.Dir, [string]::Join(',', $s.I.RunIds.ToArray()))
    if ($s.Fresh) { [void]$fresh.Add($s) }
  }
  $res = [pscustomobject]@{ Res = 'NOLOG'; Src = $null; Slot = ''; Dir = ''; Reused = $false; Text = ''; Fresh = $fresh.ToArray() }
  foreach ($c in @('DONE', 'DIRTY', 'RESTORED', 'STEP1', 'CLEAN')) {
    foreach ($s in $fresh) { if ($s.I.Cls -eq $c) { $res.Res = $c; $res.Src = $s; break } }
    if ($null -ne $res.Src) { break }
  }
  if ($null -eq $res.Src) {
    # (a fresh log of this run without an outcome: the installer was cut off)
    foreach ($s in $fresh) { if (-not $s.Stream -and ($s.I.Rel -or $s.I.RunIds.Count -gt 0 -or $s.I.Lines.Count -gt 3)) { $res.Res = 'INCOMPLETE'; $res.Src = $s; break } }
  }
  if ($null -eq $res.Src -and $akm -ge 0 -and ($t0p -le 0 -or $akm -ge ($t0p - 5))) { $res.Res = 'AK3_EARLY' }
  # slot, backup dir, "(already there)" from any fresh source
  foreach ($s in @(@($res.Src) + @($fresh))) {
    if ($null -eq $s) { continue }
    if (-not $res.Slot -and $s.I.Slot) { $res.Slot = $s.I.Slot }
    if (-not $res.Dir -and $s.I.Dir) { $res.Dir = $s.I.Dir }
    if ($s.I.Reused) { $res.Reused = $true }
  }
  if ($null -ne $res.Src) { $res.Text = $res.Src.Text }
  foreach ($s in $fresh) {
    foreach ($id in $s.I.RunIds) { if (-not $Script:SeenRuns.Contains($id)) { $Script:SeenRuns.Add($id) } }
    if (-not $s.Stream) { $Script:SeenLogs[(Get-LogKey $s)] = 1 }
  }
  Write-Log ('result: {0} (slot {1}, dir {2}, reused {3})' -f $res.Res, $res.Slot, $res.Dir, $res.Reused)
  if ($res.Text) { Write-Log ("chosen log:`n" + $res.Text) }
  return $res
}
# Get-PhoneText <path> <su>: a phone file as text, or $null
function Get-PhoneText([string]$path, [bool]$su) {
  $r = Invoke-Dev ($Script:P_CAT.Replace('{FILE}', $path)) $su 30
  if ($r.Code -ne 0) { return $null }
  return $r.Out
}
function Get-PhoneMtime([string]$path, [bool]$su) {
  $r = Invoke-Dev ('stat -c %Y ' + $path + ' 2>/dev/null; echo end=1') $su 20
  $m = [regex]::Match($r.Out, '^([0-9]+)')
  if ($m.Success) { return [long]$m.Groups[1].Value }
  return [long]-1
}
# Get-DirLogSrc <dir> <su> <want>: the newest install-*.log of a backup dir
function Get-DirLogSrc([string]$dir, [bool]$su, [string[]]$want) {
  $pd = Get-PhoneDir $dir $su $want
  if ($null -eq $pd -or $pd.Logs.Count -eq 0) { return $null }
  $lg = $pd.Logs[$pd.Logs.Count - 1]
  $t = Get-PhoneText ($dir + '/' + $lg) $su
  if ($null -eq $t) { return $null }
  return (New-Src ($dir + '/' + $lg) $t $pd.Files[$lg].Mtime $false)
}
# Get-RecSources <rec> <dirs to look in>: /tmp/{LAST}, /tmp/anykernel/install.log,
# the newest install log of the dirs named by those, of the given dirs and of
# every backup dir the probe listed
function Get-RecSources($rec, [string[]]$dirs) {
  $out = New-Object System.Collections.ArrayList
  $want = @('recovery')
  $seenDir = @{}
  foreach ($p in @(($Script:REC_TMP + '/' + $Script:LAST_LOG), ($Script:REC_AKHOME + '/install.log'))) {
    $lg = @($rec.Logs | Where-Object { $_.Path -eq $p })
    if ($lg.Count -eq 0) { continue }
    $t = Get-PhoneText $p $false
    if ($null -ne $t) { [void]$out.Add((New-Src $p $t $lg[0].Mtime $false)) }
  }
  $all = New-Object 'System.Collections.Generic.List[string]'
  foreach ($s in $out) { if ($s.I.Dir) { $all.Add($s.I.Dir) } }
  foreach ($d in $dirs) { if ($d) { $all.Add($d) } }
  foreach ($d in $rec.Baks) { if ($d) { $all.Add($d) } }
  foreach ($d in $all) {
    if ($seenDir.ContainsKey($d)) { continue }
    $seenDir[$d] = 1
    $s = Get-DirLogSrc $d $false $want
    if ($null -ne $s) { [void]$out.Add($s) }
  }
  return $out.ToArray()
}

# Show-Reason <text>: the installer's own words, then what they mean (3.4)
function Show-Reason([string]$text) {
  $lines = New-Object 'System.Collections.Generic.List[string]'
  foreach ($l0 in (Get-Lines $text)) {
    $l = $l0.TrimEnd()
    if ($l.StartsWith('ui_print')) { $l = $l.Substring(8).TrimStart(); if (-not $l) { continue } }
    if ($l.StartsWith($Script:RES_PREFIX)) { break }
    $lines.Add($l)
  }
  # (the last paragraph; when it is a single line, the one before it too; at
  # most 15 lines, as run-flash.sh reason_lines)
  $e = $lines.Count; $s0 = 0; $k = 0
  for ($i = $lines.Count - 1; $i -ge 0; $i--) {
    if ($lines[$i].Trim() -eq '') {
      $k++
      if ($k -eq 1) { $s0 = $i + 1 } else { if (($e - $s0) -le 1) { $s0 = $i + 1 }; break }
    }
  }
  if (($e - $s0) -gt 15) { $s0 = $e - 15 }
  $show = New-Object 'System.Collections.Generic.List[string]'
  for ($i = $s0; $i -lt $e; $i++) {
    $t = $lines[$i]
    if ($t.Trim() -eq '' -or $t.StartsWith('taoyao-')) { continue }
    $show.Add($t)
  }
  if ($show.Count -gt 0) { Say $M_REASON; Show-Block $show.ToArray() }
  $all = [string]::Join("`n", $lines.ToArray())
  $why = $M_WHY_OTHER
  if ($all.Contains('The bootloader is LOCKED')) { $why = $M_WHY_LOCKED }
  elseif ($all -match 'will start slot .* next') { $why = $M_WHY_NEXTSLOT }
  elseif ($all -match 'Only .* MiB free in') { $why = $M_WHY_TMPSPACE }
  elseif ($all.Contains('No room for the backup of slot')) { $why = $M_WHY_SDSPACE }
  elseif ($all.Contains('command line would be')) { $why = $M_WHY_CMDLINE }
  elseif ($all.Contains('has header version')) { $why = $M_WHY_HEADER }
  elseif ($all.Contains('Unsupported device') -or ($all -match 'is for .*, not this phone')) { $why = $M_WHY_DEVICE }
  elseif ($all.Contains('Unzip failed') -or $all.Contains('Busybox setup failed')) { $why = $M_WHY_UNZIP }
  elseif ($all.Contains('No 6.12 ') -or $all.Contains('Bad kernel.release') -or ($all -match 'is not the .* kernel the modules were built for') -or ($all -match 'names .*, which is not in the zip')) { $why = $M_WHY_BADZIP }
  elseif ($all.Contains('another ramdisk than the saved boot.img')) { $why = $M_WHY_RZ_ROM }
  elseif ($all.Contains('do not match SHA256SUMS')) { $why = $M_WHY_RZ_SUMS }
  WarnM $why
  $Script:Sum['Why'] = $why
}
# Show-Notes <text>: the installer's warnings, repeated on the PC; its "!!
# The backup is only in RAM … copy it now" block is left out once that copy
# is on the PC (a line says where instead)
function Show-Notes([string]$text) {
  $n = New-Object 'System.Collections.Generic.List[string]'
  $skip = $false; $onPc = ''
  foreach ($l0 in (Get-Lines $text)) {
    $l = $l0.Trim()
    if ($l.StartsWith('ui_print')) { $l = $l.Substring(8).Trim() }
    if ($l.StartsWith('| ')) { $l = $l.Substring(2) }
    $m = [regex]::Match($l, $Script:TXT_RAMNOTE_RE)
    if ($m.Success) {
      $c = Get-CopyOf $m.Groups[1].Value.Trim()
      if ($null -ne $c -and $c.Ok) { $skip = $true; $onPc = $c.Path; continue }
    }
    if ($skip) { if ($l.StartsWith('!!')) { continue }; $skip = $false }
    if ($l.StartsWith($Script:RES_PREFIX) -or $l -match $Script:NOTE_SKIP_RE) { continue }
    if ($l.StartsWith('!') -or $l -match $Script:NOTE_RE -or $l -match '(?i)warning') { if (-not $n.Contains($l)) { $n.Add($l) } }
  }
  if ($n.Count -gt 0) {
    Say $M_INSTALLER_NOTES
    Show-Block $n.ToArray()
    if (-not $Script:IpaHinted -and @($n | Where-Object { $_ -match $Script:NOTE_IPA_RE }).Count -gt 0) {
      $Script:IpaHinted = $true
      WarnM ($M_IPA_HINT -f (Get-ToolCmd 'adb'))
    }
  }
  if ($onPc) { Say ($M_RAM_NOTE_ONPC -f $onPc) }
}

########################################################################
# the pre-write gate (section 13): before any pass that may write, and
# again after a step 1 with the new copy's info.txt. Each question is asked
# at most once per run.

# Find-StockFor <slot> <boot_ramdisk> <fingerprint> <ROM build>: a kept
# stock copy of this ROM build and slot (Get-RomCmp: the same build first,
# then only the same fingerprint); $Script:StockHow = 'same' or 'fpr'
function Find-StockFor([string]$slot, [string]$rd, [string]$fp, [string]$rid = '') {
  $Script:StockHow = ''
  foreach ($want in @('same', 'fpr')) {
    foreach ($f in @(Get-FiledFolders)) {
      if ($f.Class -ne 'STOCK' -or $f.Slot -ne $slot) { continue }
      if ((Get-RomCmp $rd $rid $fp $f) -ne $want) { continue }
      if (-not (Test-KeptUsable $f)) { continue }
      $Script:StockHow = $want
      return $f
    }
  }
  return $null
}
# Test-KeptUsable <kept folder>: a way back: whole (Test-FiledFull), or at
# least its restore zip checks out
function Test-KeptUsable($f) {
  if (-not (Test-FiledFull $f $null)) { return $true }
  if (-not $f.RZip) { return $false }
  try {
    $w = [regex]::Match([IO.File]::ReadAllText($f.RZip + '.sha256'), '^[0-9a-fA-F]{64}')
    if (-not $w.Success -or (Get-Sha256 $f.RZip) -ne $w.Value.ToLowerInvariant()) { return $false }
    return (-not (Test-RestoreZip $f.RZip $f.Slot '' $f.Sums))
  } catch { if (Test-Exit $_) { throw }; return $false }
}
function Get-StockOfSlot([string]$slot) {
  return @(@(Get-FiledFolders) | Where-Object { $_.Class -eq 'STOCK' -and $_.Slot -eq $slot })
}
# Show-StockNow <kernel in the slot> <slot>: M_STOCK_NOW, once, for a kernel
# of the ROM, and not once this run has the stock images of that slot on the PC
function Show-StockNow([string]$sk, [string]$slot) {
  if (-not $sk -or (Test-PortSeries $sk) -or $Script:Gate.ContainsKey('stocknow')) { return }
  if ($Script:Sum.ContainsKey('Stock') -and @($Script:Sum['Stock'] | Where-Object { $_.Slot -eq $slot }).Count -gt 0) { return }
  $Script:Gate['stocknow'] = $true
  Say ($M_STOCK_NOW -f $sk)
}
# Test-Gate <kernel in the slot> <slot> <boot_ramdisk> <fingerprint> <how
# known> <ROM build: ro.build.date.utc>
function Test-Gate([string]$sk, [string]$slot, [string]$rd, [string]$fp, [string]$how, [string]$rid = '') {
  $z = $Script:Zip
  Write-Log ('gate: slot kernel {0} ({1}), slot {2}, ramdisk {3}, fingerprint {4}, build {5}' -f $sk, $how, $slot, $rd, $fp, $rid)
  if (Test-PortSeries $sk) {
    # 13.2: the copy this install makes is of a 6.12 build, not stock (the
    # boot ramdisk, else the build time, else only the fingerprint)
    $hit = Find-StockFor $slot $rd $fp $rid
    if ($null -ne $hit) {
      if (-not $Script:Gate.ContainsKey('stockshown')) {
        $Script:Gate['stockshown'] = $true
        if ($Script:StockHow -eq 'fpr') {
          Say ($M_STOCK_PRESENT_FPR -f $slot, $hit.Path)
          WarnM ($M_STOCK_FPRONLY -f (Get-FprWhy $hit $rid)); $Script:GateFprSaid = $hit.Path
        } else { GoodM ($M_STOCK_PRESENT -f $hit.Path) }
      }
      $Script:Sum['StockMatch'] = $hit.Path
      if ($Script:StockHow -eq 'fpr') { $Script:Sum['StockFpr'] = $hit.Path } else { [void]$Script:Sum.Remove('StockFpr') }
    } elseif (-not $Script:Gate.ContainsKey('stock')) {
      $oth = New-Object 'System.Collections.Generic.List[string]'; $old = New-Object 'System.Collections.Generic.List[string]'; $may = New-Object 'System.Collections.Generic.List[string]'
      foreach ($f in @(Get-StockOfSlot $slot)) {
        $v = Get-RomCmp $rd $rid $fp $f
        if ($v -eq 'other') { if ($f.Rid) { $oth.Add(($M_COPY_BUILT -f $f.Path, (Format-Utc $f.Rid))) } else { $oth.Add($f.Path) } }
        elseif ($v -eq 'older') { $dt = Format-InfoDate (Get-H $f.Info 'date'); if ($dt) { $old.Add(($M_COPY_MADE -f $f.Path, $dt)) } else { $old.Add($f.Path) } }
        else { $may.Add($f.Path) }
      }
      if ($oth.Count -gt 0) { WarnM ($M_STOCK_OTHERBUILD -f $slot, [string]::Join('; ', $oth.ToArray())) }
      if ($old.Count -gt 0) { WarnM ($M_STOCK_OLDER -f $slot, [string]::Join('; ', $old.ToArray()), (Format-Utc $rid)) }
      $none = $M_STOCK_NONE_PC
      if ($may.Count -gt 0) {
        if (-not $rd -and -not $rid -and -not $fp) { WarnM ($M_STOCK_CANTCMP -f $slot, [string]::Join('; ', $may.ToArray())); $none = $M_STOCK_NONE_UNK }
        else { WarnM ($M_STOCK_MAYBE -f $slot, [string]::Join('; ', $may.ToArray())) }
      }
      $Script:Gate['stock'] = $true
      if (-not (Ask-Yes ($M_STOCK_MISSING -f $sk, $slot, $z.Ver, (Get-Series $sk), $Script:BACKUP_NAME, ($none -f $slot)) $true)) {
        if ($Script:Phase -eq 'ramcopy' -or $Script:Phase -eq 'ramonpc') { Say $M_RAM_KEPT }
        $Script:Sum['What'] = $U_GATE_NO
        Invoke-Cancel
      }
    }
    # 13.3: the version (compared only within one series, as run-flash.sh)
    if (-not $Script:Gate.ContainsKey('ver') -and (-not (Get-RelVer $sk) -or (Get-Series $sk) -eq [string]$z.Series)) {
      $Script:Gate['ver'] = $true
      $v = Get-RelVer $sk
      if (-not $v) { Say $M_OLD_UNNUMBERED }
      else {
        $c = Compare-Ver $z.Ver $v
        if ($c -lt 0) { if (-not (Ask-Yes ($M_DOWNGRADE_ASK -f $v, $z.Ver) $true)) { Invoke-Cancel } }
        elseif ($c -eq 0) { if (-not (Ask-Yes ($M_SAME_ASK -f $v) $true)) { Invoke-Cancel } }
      }
    }
  }
  else { Show-StockNow $sk $slot }
  # 13.5: KernelSU
  if ($z.NoKsu -and -not $Script:Gate.ContainsKey('noksu') -and ((Test-PortSeries $sk) -or $Script:HasSu)) {
    $Script:Gate['noksu'] = $true
    WarnM $M_NOKSU_NOTE
  }
}

########################################################################
# way (A): the zip's own update-binary runs on the booted phone under su,
# detached from adb by rf-run.sh (section 9); also for restore zips
function Get-PhoneNow([bool]$su) {
  $r = Invoke-Dev 'date +%s' $su 20
  $m = [regex]::Match($r.Out, '([0-9]{9,})')
  if ($m.Success) { return [long]$m.Groups[1].Value }
  return [long]0
}
# Send-FilesA <zip> <kind>: the zip, its update-binary and busybox, and
# rf-run.sh into the work dir; checked by sha256 on the phone
function Send-FilesA([string]$zipPath, [string]$kind) {
  $zn = 'kernel.zip'; if ($kind -eq 'restore') { $zn = 'restore.zip' }
  $tmp = Get-TmpDir
  foreach ($f in @('update-binary', 'busybox', 'rf-run.sh')) { try { [IO.File]::Delete((Join-Path $tmp $f)) } catch { } }
  if (-not (Save-ZipEntry $zipPath 'META-INF/com/google/android/update-binary' (Join-Path $tmp 'update-binary'))) { Fail ($M_PUSH_FAIL -f 'update-binary') }
  $hasBb = $false
  try { $hasBb = Save-ZipEntry $zipPath 'tools/busybox' (Join-Path $tmp 'busybox') } catch { $hasBb = $false }
  [IO.File]::WriteAllText((Join-Path $tmp 'rf-run.sh'), ([string]::Join("`n", $Script:RF_RUN) + "`n"), $Utf8)
  $r = Invoke-Dev (Get-Tpl $Script:P_A_PREP) $false 30
  if ($r.Out -notmatch 'end=1') { Fail ($M_PUSH_FAIL -f (Get-FirstLine $r)) }
  $pcs = @{}
  $pcs[$zn] = Get-Sha256 $zipPath
  $pcs['update-binary'] = Get-Sha256 (Join-Path $tmp 'update-binary')
  $pcs['rf-run.sh'] = Get-Sha256 (Join-Path $tmp 'rf-run.sh')
  if ($hasBb) { $pcs['bb/busybox'] = Get-Sha256 (Join-Path $tmp 'busybox') }
  for ($try = 1; $try -le 2; $try++) {
    $pushes = @(
      @([IO.Path]::GetFileName($zipPath), ($Script:PH_WORK + '/' + $zn), [IO.Path]::GetDirectoryName($zipPath)),
      @('update-binary', ($Script:PH_WORK + '/update-binary'), $tmp),
      @('rf-run.sh', ($Script:PH_WORK + '/rf-run.sh'), $tmp))
    if ($hasBb) { $pushes += ,@('busybox', ($Script:PH_WORK + '/bb/busybox'), $tmp) }
    foreach ($p in $pushes) {
      $r = Invoke-Adb @('push', $p[0], $p[1]) 900 $p[2]
      if ($r.Code -ne 0) {
        if (Test-Lost $r) { WarnM $M_LOST; [void](Wait-Phone -Want @('device') -Limit $Script:T_USER); continue }
        Fail ($M_PUSH_FAIL -f (Get-FirstLine $r))
      }
    }
    $names = @($zn, 'update-binary', 'rf-run.sh'); if ($hasBb) { $names += 'bb/busybox' }
    $r = Invoke-Dev ('cd ' + $Script:PH_WORK + ' && sha256sum ' + [string]::Join(' ', $names) + '; echo end=1') $false 120
    $bad = ''
    foreach ($n in $names) {
      $m = [regex]::Match($r.Out, '(?m)^([0-9a-f]{64})\s+' + [regex]::Escape($n) + '\s*$')
      if (-not $m.Success -or $m.Groups[1].Value -ne $pcs[$n]) { $bad = $n; break }
    }
    if (-not $bad) { GoodM $M_PUSH_OK; return }
    Write-Log ('pushed file differs: ' + $bad)
  }
  Fail $M_PUSH_BAD
}
# Show-UbLine <line>: one line of the installer's output (ui_print protocol)
function Show-UbLine([string]$l, $sb) {
  $l = $l.TrimEnd("`r")
  if (-not $l.StartsWith('ui_print')) { Write-Log ('  ' + $l); return }
  $t = $l.Substring(8)
  if ($t.StartsWith(' ')) { $t = $t.Substring(1) }
  if ($l.Trim() -eq 'ui_print') { return }
  [void]$sb.Append($t + "`n")
  $s = '  | ' + $t
  $x = $t.Trim()
  Close-Dots
  if ($x.StartsWith('!!')) { Write-Host $s -ForegroundColor Red }
  elseif ($x.StartsWith('Done:')) { Write-Host $s -ForegroundColor Green }
  elseif ($x.StartsWith($Script:TXT_STEP1) -or $x.StartsWith('! Note')) { Write-Host $s -ForegroundColor Yellow }
  else { Write-Host $s }
  Write-Log $s
}
# Watch-A: polls ub.out / ub.rc in the work dir every second; the streamed
# text and the installer's exit code. A lost cable is waited for: the
# installer goes on by itself.
function Watch-A {
  $Script:Phase = 'running'; $Script:RunWrites = $true
  $off = [long]0; $carry = ''; $sb = New-Object System.Text.StringBuilder
  $useSu = $false; $firstPoll = $true
  $sw = [Diagnostics.Stopwatch]::StartNew(); $lastOut = 0.0; $nextNote = 60.0; $slow = $false
  $rc = ''
  while ($true) {
    $cmd = $Script:P_A_POLL.Replace('{W}', $Script:PH_WORK).Replace('{OFF1}', [string]($off + 1)).Replace('{OFF}', [string]$off)
    $r = Invoke-Dev $cmd $useSu 30
    $lines = @(Get-Lines $r.Out)
    $head = ''; $k = -1
    for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i].StartsWith('RF_POLL')) { $head = $lines[$i]; $k = $i; break } }
    if (-not $head) {
      if ((Test-Lost $r) -or $r.TimedOut -or $r.Code -ne 0) {
        WarnM $M_A_CABLE
        [void](Wait-Phone -Want @('device') -Limit $Script:T_USER -Hint $M_A_CABLE -HintAfter $Script:T_HINT)
        continue
      }
      Wait-Sec 1; continue
    }
    if ($head -match 'nowork') { Write-Log 'work dir gone'; break }
    $mr = [regex]::Match($head, 'rc=([0-9]*)'); $ms = [regex]::Match($head, 'sz=([0-9]*)')
    $sz = -1; if ($ms.Success -and $ms.Groups[1].Value) { $sz = [long]$ms.Groups[1].Value }
    if ($firstPoll -and $sz -lt 0 -and -not $useSu) { $useSu = $true; $firstPoll = $false; continue }
    $firstPoll = $false
    if ($sz -ge 0 -and $sz -lt $off) { $off = 0; $carry = ''; continue }
    if ($sz -gt $off) {
      # (the rest of the output are the new bytes of ub.out)
      $body = ''
      if ($k + 1 -lt $lines.Count) { $body = [string]::Join("`n", $lines[($k + 1)..($lines.Count - 1)]) }
      $raw = $r.Out
      $p = $raw.IndexOf($head)
      if ($p -ge 0) { $body = $raw.Substring($p + $head.Length); if ($body.StartsWith("`n")) { $body = $body.Substring(1) } }
      $text = $carry + $body
      $parts = $text.Split([char]10)
      for ($i = 0; $i -lt $parts.Count - 1; $i++) { Show-UbLine $parts[$i] $sb }
      $carry = $parts[$parts.Count - 1]
      $off = $sz
      $lastOut = $sw.Elapsed.TotalSeconds; $nextNote = $lastOut + 60
    }
    if ($mr.Success -and $mr.Groups[1].Value) {
      $rc = $mr.Groups[1].Value
      if ($carry) { Show-UbLine $carry $sb; $carry = '' }
      break
    }
    $el = $sw.Elapsed.TotalSeconds
    if ($el -ge $nextNote) { Say ($M_A_GOING -f (Format-Elapsed ([int]$el))); $nextNote = $el + 60 }
    if (-not $slow -and ($el - $lastOut) -ge 180) { $slow = $true; WarnM $M_A_SLOW }
    if ($el -ge $Script:T_INSTALL_A) {
      if ($Script:RzMode) { $Script:Sum['What'] = $U_RZ_NOT_CONFIRMED }
      else { $v = '?'; if ($null -ne $Script:Zip) { $v = $Script:Zip.Ver }; $Script:Sum['What'] = ($U_NOT_CONFIRMED_T -f $v); $Script:Sum['Todo'] = $U_TODO_TIMEOUT }
      Fail $M_A_TIMEOUT $RC_ATTN
    }
    Wait-Sec 1
  }
  Write-Log ('installer exit code: ' + $rc)
  return [pscustomobject]@{ Text = $sb.ToString(); Rc = $rc }
}
# Start-A <kind> <zip name in the work dir>: rf-run.sh under su
function Start-A([string]$kind, [string]$zn) {
  $r = Invoke-Dev ($Script:P_A_START.Replace('{W}', $Script:PH_WORK).Replace('{KIND}', $kind).Replace('{ZIP}', $zn)) $true 60
  $t = $r.Out + $r.Err
  if ($t -match 'RF_STARTED') { $Script:PhoneTouched = $true; return 'started' }
  if ($t -match 'RF_BUSY') { WarnM $M_A_RUNNING; $Script:PhoneTouched = $true; return 'busy' }
  Fail ($M_A_NOSTART -f (Get-FirstLine $r))
}
function Clear-WorkA {
  # (the installer's ak/install.log after an abort goes to the PC first)
  $t = Get-PhoneText ($Script:PH_WORK + '/ak/install.log') $true
  if ($null -ne $t) { try { [IO.File]::WriteAllText((Join-Path (Get-PullDir) 'install-ak.log'), $t, $Utf8) } catch { } }
  [void](Invoke-Dev (Get-Tpl $Script:P_A_CLEAN) $true 30)
}
# Get-ASources <stream> <dir>: (A)'s result sources, newest log first
function Get-ASources([string]$stream, [string]$dir) {
  $out = New-Object System.Collections.ArrayList
  $p = $Script:PH_WORK + '/' + $Script:LAST_LOG
  $t = Get-PhoneText $p $true
  if ($null -ne $t) { [void]$out.Add((New-Src $p $t (Get-PhoneMtime $p $true) $false)) }
  [void]$out.Add((New-Src 'screen' $stream -1 $true))
  $dirs = New-Object 'System.Collections.Generic.List[string]'
  if ($dir) { $dirs.Add($dir) }
  foreach ($s in $out) { if ($s.I.Dir -and -not $dirs.Contains($s.I.Dir)) { $dirs.Add($s.I.Dir) } }
  foreach ($d in $dirs) { $s = Get-DirLogSrc $d $true @('device'); if ($null -ne $s) { [void]$out.Add($s) } }
  $p = $Script:PH_WORK + '/ak/install.log'
  $t = Get-PhoneText $p $true
  if ($null -ne $t) { [void]$out.Add((New-Src $p $t (Get-PhoneMtime $p $true) $false)) }
  return $out.ToArray()
}
# Invoke-SystemInstall: steps 4-7 of way (A)
function Invoke-SystemInstall {
  $z = $Script:Zip
  Step ($S_I4A -f $z.Ver)
  Say ($M_SENDING -f $z.Ver)
  Send-FilesA $z.Path 'kernel'
  Step ($S_I5_A -f $z.Ver)
  $t0p = Get-PhoneNow $true
  [void](Start-A 'kernel' 'kernel.zip')
  Say $M_A_STARTED
  $w = Watch-A
  $res = Get-Result (Get-ASources $w.Text '') $t0p $z.Rel ([long]-1)
  Complete-Install $res 'A' $null
}

########################################################################
# way (B): recovery sideload (section 10). The PC watches "adb devices" all
# the time and starts each sideload and each pull by itself; the user only
# taps what adb cannot do.

# Invoke-Sideload <zip> <what>: one "adb sideload" with a progress line;
# OK, FAILED_EARLY or FAILED_LATE (the exit code alone is never trusted:
# the installer's log decides)
function Invoke-Sideload([string]$path, [string]$what, [string]$note = '') {
  $dir = [IO.Path]::GetDirectoryName($path); $name = [IO.Path]::GetFileName($path)
  Hint $H_SIGNATURE
  if ($note) { WarnM $note }
  $p = Start-AdbProc @('sideload', $name) $dir $false ''
  $Script:AdbProc = $p
  $bo = New-Object char[] 4096; $be = New-Object char[] 4096
  $to = $p.StandardOutput.ReadAsync($bo, 0, $bo.Length); $te = $p.StandardError.ReadAsync($be, 0, $be.Length)
  $sb = New-Object System.Text.StringBuilder
  $sw = [Diagnostics.Stopwatch]::StartNew(); $lastChange = 0.0; $nextSig = [double]$Script:T_HINT
  $pct = -1; $serving = $false; $xfer = $false; $stall = $false
  while ($true) {
    $got = $false
    if ($null -ne $to -and $to.IsCompleted) {
      $n = 0; if (-not $to.IsFaulted) { $n = $to.Result }
      if ($n -gt 0) { [void]$sb.Append($bo, 0, $n); $to = $p.StandardOutput.ReadAsync($bo, 0, $bo.Length); $got = $true } else { $to = $null }
    }
    if ($null -ne $te -and $te.IsCompleted) {
      $n = 0; if (-not $te.IsFaulted) { $n = $te.Result }
      if ($n -gt 0) { [void]$sb.Append($be, 0, $n); $te = $p.StandardError.ReadAsync($be, 0, $be.Length); $got = $true } else { $te = $null }
    }
    if ($got) {
      $all = $sb.ToString()
      if ($all.Contains('serving:')) { $serving = $true }
      if ($all.Contains('Total xfer:')) { $xfer = $true }
      $ms = [regex]::Matches($all, '\(~([0-9]+)%\)')
      if ($ms.Count -gt 0) {
        $v = [int]$ms[$ms.Count - 1].Groups[1].Value
        if ($v -ne $pct) {
          $pct = $v; $lastChange = $sw.Elapsed.TotalSeconds; $nextSig = $lastChange + $Script:T_HINT
          Write-Host -NoNewline ("`r" + ($M_SENDING_SL -f $what, $pct) + '   '); $Script:DotOpen = $true
        }
      }
    }
    if ($null -eq $to -and $null -eq $te -and $p.HasExited) { break }
    if (-not $got) { Start-Sleep -Milliseconds 200 }
    Test-Interrupt
    $el = $sw.Elapsed.TotalSeconds
    # ("Install anyway?" stops the transfer part-way: the hint again while it
    # stands below 95 %; at 99 % the installer itself runs on the phone, which
    # may take minutes: no hint, a "… жду" line, and the whole-run limit)
    if ($pct -ge 99) {
      if ($el -ge $nextSig) { Say ($M_WAITING -f (Format-Elapsed ([int]$el))); $nextSig = $el + 60 }
      if (($el - $lastChange) -ge $Script:T_INSTALL_A) { $stall = $true; try { $p.Kill() } catch { }; break }
    } else {
      if ($el -ge $nextSig -and $pct -lt 95) { Hint $H_SIGNATURE; $nextSig = $el + $Script:T_HINT }
      if (($el - $lastChange) -ge $Script:T_STALL) { $stall = $true; try { $p.Kill() } catch { }; break }
    }
  }
  $code = 124
  if (-not $stall) { try { [void]$p.WaitForExit(5000); $code = $p.ExitCode } catch { $code = 1 } }
  $Script:AdbProc = $null
  try { $p.Dispose() } catch { }
  Close-Dots
  $txt = $sb.ToString().Replace("`r", "`n")
  $t2 = $txt; if ($t2.Length -gt 3000) { $t2 = $t2.Substring($t2.Length - 3000) }
  Write-Log ('< sideload rc={0} stall={1} {2}' -f $code, $stall, $t2.Trim())
  # (no block served: the recovery never read the zip, its installer cannot have run)
  $Script:SlServed = ($serving -or $pct -ge 0 -or $xfer)
  $res = 'FAILED_LATE'
  if (-not $stall -and ($code -eq 0 -or $xfer)) { $res = 'OK' }
  elseif (-not $stall -and -not $serving -and $sw.Elapsed.TotalSeconds -lt 15 -and $txt -match '(?i)no devices|not found|connection failed|closed|cannot read|failed to connect') { $res = 'FAILED_EARLY' }
  # (the last progress line at 100 %, then «Отправлено»: as run-flash.sh)
  if ($res -eq 'OK') { if ($pct -ne 100) { Say ($M_SENDING_SL -f $what, 100) }; Say ($M_SENT_SL -f $what) }
  else {
    $f = @($txt.Trim() -split "`n" | Where-Object { $_ -and $_ -notmatch 'serving:' })
    $why = 'код ' + $code; if ($stall -and $pct -ge 99) { $why = $M_SL_STALL99 } elseif ($stall) { $why = $M_SL_STALL } elseif ($f.Count -gt 0) { $why = $f[$f.Count - 1].Trim() }
    Write-Log ($M_SL_FAILED -f $why)
  }
  return $res
}

# Enter-Recovery <plain> [hint] [hint at once] [limit text]: from Android
# after the yes: adb reboot sideload (adb reboot recovery for TWRP /
# OrangeFox on stock HyperOS, and where the flasher must look into the
# recovery first: backup only); the state seen
function Enter-Recovery([bool]$plain, [string]$hint = '', [bool]$hintNow = $false, [string]$limitText = '') {
  if (-not $hint) { $hint = $H_ENTER_SIDELOAD }
  Say $M_REBOOTING_REC
  $Script:PhoneTouched = $true; $Script:Phase = 'wait'
  $how = 'sideload'; if ($plain) { $how = 'recovery' }
  [void](Invoke-Adb @('reboot', $how) 30)
  $sw = [Diagnostics.Stopwatch]::StartNew(); $left = $false; $again = $plain
  while ($sw.Elapsed.TotalSeconds -lt $Script:T_REBOOT_FAIL) {
    $st = Scan-Devices @('device', 'sideload', 'recovery')
    if ($st -ne 'device') { $left = $true; break }
    if (-not $again -and $sw.Elapsed.TotalSeconds -ge $Script:T_REBOOT_AGAIN) {
      $again = $true; $plain = $true; WarnM $M_REBOOT_NOT_TAKEN
      [void](Invoke-Adb @('reboot', 'recovery') 30)
    }
    Write-Dot; Wait-Sec 1
  }
  Close-Dots
  if (-not $left) { Fail $M_REBOOT_FAILED }
  $after = $Script:T_SIDELOAD_UP; if ($plain) { $after = 30 }; if ($hintNow) { $after = 5 }
  $st = Wait-Phone -Want @('sideload', 'recovery') -StopOn @('device') -Limit $Script:T_USER -Hint $hint -HintAfter $after -Ctx 'recovery' -UnauthLimit $Script:T_UNAUTH_WAIT -Poll 1 -LimitText $limitText
  if ($st -eq 'device') { Fail $M_BOOTED_NOT_REC }
  if ($st -eq 'unauthorized') { $Script:Sum['What'] = $U_UNAUTH1; Fail $M_REC_UNAUTH }
  return $st
}
# Wait-Sideload <hint> <twrp>: until the phone is in "sideload" (state
# 'recovery' before: TWRP gets "twrp sideload" first)
function Wait-Sideload([string]$hint, [bool]$twrp, [string]$stopWhy) {
  $after = 0
  if ($Script:Phase -eq 'pre') { $Script:Phase = 'wait' }
  if ($twrp -and (Scan-Devices @('recovery', 'sideload')) -eq 'recovery') {
    [void](Invoke-Dev $Script:P_TWRP_SIDELOAD $false 15)
    $hint = $H_SIDELOAD_TWRP; $after = $Script:T_TWRP_SL
  }
  $st = Wait-Phone -Want @('sideload') -StopOn @('device') -Limit $Script:T_USER -Hint $hint -HintAfter $after -Ctx 'recovery' -UnauthLimit $Script:T_UNAUTH_WAIT -Poll 1
  if ($st -eq 'device') { Fail $stopWhy }
  if ($st -eq 'unauthorized') { $Script:Sum['What'] = $U_UNAUTH1; Fail $M_REC_UNAUTH }
  # (1 s after the state was first seen, once more with get-state)
  Wait-Sec 1
  $g = Invoke-Adb @('get-state') 10
  return ($g.Out.Trim() -eq 'sideload')
}
# Wait-AfterPass <writes> <transfer>: until the recovery has ADB again
function Wait-AfterPass([bool]$writes, [string]$tr) {
  if ($tr -eq 'OK' -or $Script:SlServed) { Say $M_INSTALLING_REC }
  # (the Xiaomi-recovery note only at the limit: right after a broken
  # transfer the phone may be in a LineageOS-type recovery whose installer
  # still runs; as run-flash.sh b_wait_back)
  $lt = ''
  if ($tr -ne 'OK' -and -not $Script:SawRec) { $lt = $M_MAYBE_XIAOMI_REC }
  $hint = $H_ADB_LOS; if ($null -ne $Script:Rec -and $Script:Rec.Twrp) { $hint = $H_ADB_TWRP }
  $stop = @('device', 'sideload')
  # (right after the transfer the phone shows "sideload" for a few seconds
  # more: that is still the same pass, not Apply from ADB chosen again)
  $sw = [Diagnostics.Stopwatch]::StartNew()
  while ($sw.Elapsed.TotalSeconds -lt 30) {
    if ((Scan-Devices @('sideload', 'recovery')) -ne 'sideload') { break }
    Write-Dot; Wait-Sec 1
  }
  while ($true) {
    $st = Wait-Phone -Want @('recovery') -StopOn $stop -Limit $Script:T_USER -Hint $hint -HintAfter $Script:T_REC_BACK -Ctx 'recovery' -UnauthLimit $Script:T_UNAUTH_WAIT -Poll 2 -LimitText $lt
    if ($st -eq 'sideload') {
      # (Apply from ADB again before the log was read: never send now)
      WarnM $M_NEED_LOG_FIRST
      $hint = $H_LEAVE_SIDELOAD; $stop = @('device'); continue
    }
    if ($st -eq 'device') {
      if ($Script:RzMode) { $Script:Sum['What'] = $U_RZ_REBOOTED; Fail ($M_RESTORE_UNCONFIRMED -f [string]$Script:Sum['Slot']) $RC_ATTN }
      if ($writes) { $Script:Sum['What'] = $U_REBOOTED; Fail ($M_REBOOTED_UNKNOWN -f $Script:Zip.Rel) $RC_ATTN }
      $Script:Sum['What'] = $U_REBOOTED1
      Fail $M_REBOOTED_AFTER_STEP1
    }
    if ($st -eq 'unauthorized') {
      if ($Script:RzMode) { $Script:Sum['What'] = $U_RZ_UNAUTH; Fail ($M_RESTORE_UNCONFIRMED -f [string]$Script:Sum['Slot']) $RC_ATTN }
      if ($writes) { $Script:Sum['Todo'] = $U_TODO_UNAUTH; Fail $M_REC_UNAUTH_AFTER $RC_ATTN }
      $Script:Sum['What'] = $U_UNAUTH1
      Fail $M_REC_UNAUTH
    }
    $Script:SawRec = $true
    return
  }
}
# Get-CopyFailText <copy result>: why the copy is not on the PC (a lost
# connection, or a failed check)
function Get-CopyFailText($c) {
  if ($c.Lost) { $Script:Sum['What'] = $U_PULL_LOST; return ($M_PULL_LOST_FAIL -f ($Script:MAX_PULLS + 1), $c.Reason) }
  # (low disk space: Copy-PhoneDir said it already)
  if ($c.PSObject.Properties['Disk'] -and $c.Disk) { $Script:Sum['What'] = $U_PC_SPACE; return '' }
  $Script:Sum['What'] = $U_VERIFY_BAD
  return ($M_VERIFY_FAILED -f $c.Reason)
}
function Get-BakSet($rec) { $h = @{}; foreach ($b in @($rec.Baks)) { $h[$b] = 1 }; return $h }

# Invoke-KernelPass <next> <pass> <fresh>: one pass of the kernel zip, with
# the transfer retries of 10.6; the result object
function Invoke-KernelPass([string]$next, [int]$pass, [bool]$fresh) {
  $z = $Script:Zip
  $try = 0; $inSl = $fresh
  $twrp = ($null -ne $Script:Rec -and $Script:Rec.Twrp)
  $before = @{}; if ($null -ne $Script:Rec) { $before = Get-BakSet $Script:Rec }
  $hint = $H_APPLY_LOS; if ($pass -ge 2 -or $next -eq 'WRITE') { $hint = $H_APPLY_LOS2 }
  while ($true) {
    if (-not $inSl) {
      if (-not (Wait-Sideload $hint $twrp $M_REBOOTED_WAITING)) { continue }
    }
    if ($inSl) {
      # (just before the send, once more: the phone still waits in Apply from ADB)
      Wait-Sec 1
      $g = Invoke-Adb @('get-state') 10
      if ($g.Out.Trim() -ne 'sideload') { $inSl = $false; continue }
    }
    $inSl = $false
    $t0p = [long]0; if (-not $fresh -and $Script:LastNow -gt 0) { $t0p = $Script:LastNow }
    $t0 = [Diagnostics.Stopwatch]::StartNew()
    $try++
    if ($pass -eq 1 -and -not $Script:Pass1Shown) {
      $Script:Pass1Shown = $true
      if ($fresh -and $next -eq 'COPY') { Step ($S_I5_FRESH -f $z.Ver) }
      else { switch ($next) { 'WRITE' { Step ($S_I5_REUSE -f $z.Ver) } 'ONEPASS' { Step ($S_I5_ONE -f $z.Ver) } default { Step ($S_I5_COPY -f $z.Ver) } } }
    }
    # (a pass sent before any look into the recovery may write at once: TWRP /
    # OrangeFox with the internal storage open; no "nothing is written" then)
    $note = ''
    if ($next -eq 'COPY') { if ($fresh) { $note = $H_STEP1_ERROR_FRESH } elseif ($twrp) { $note = $H_STEP1_ERROR_TWRP } else { $note = $H_STEP1_ERROR_OK } }
    $Script:Phase = 'running'; $Script:PhoneTouched = $true
    $Script:RunWrites = ($next -ne 'COPY' -or $fresh -or ($null -ne $Script:Rec -and $Script:Rec.DataMnt))
    $Script:SentAny = $true
    $tr = Invoke-Sideload $z.Path ('ядро v' + $z.Ver) $note
    if ($tr -eq 'FAILED_EARLY' -and $try -lt $Script:MAX_TRIES) {
      if ((Scan-Devices @('sideload')) -eq 'sideload') { WarnM ($M_RETRY -f ($try + 1), $Script:MAX_TRIES); Wait-Sec 2; $inSl = $true; continue }
    }
    # (nothing of the zip reached the phone: nothing can have been written)
    if ($tr -ne 'OK' -and -not $Script:SlServed) { $Script:RunWrites = $false }
    # (a pass that only copies: once it was sent, the copy is in the recovery's RAM)
    if (-not $Script:RunWrites) { if ($tr -eq 'OK') { $Script:Phase = 'ramcopy' } else { $Script:Phase = 'wait' } }
    Wait-AfterPass $Script:RunWrites $tr
    $rec = Get-RecInfo
    # (the first look into a recovery reached straight in Apply from ADB: its checks now)
    if (-not $Script:RecChecked) { $Script:RecChecked = $true; Test-RecChecks $rec $true (Get-NowLine $rec) }
    if ($t0p -le 0) { $t0p = $rec.Now - [long]$t0.Elapsed.TotalSeconds - 30 }
    $dirs = @(); if ($Script:Pass1Dir) { $dirs = @($Script:Pass1Dir) }
    $res = Get-Result (Get-RecSources $rec $dirs) $t0p $z.Rel $rec.AkHome
    $newDir = $false
    foreach ($b in @($rec.Baks)) { if (-not $before.ContainsKey($b)) { $newDir = $true } }
    $Script:LastPass = $next
    if ($tr -ne 'OK' -and ($res.Res -eq 'NOLOG' -or $res.Res -eq 'AK3_EARLY') -and -not $newDir) {
      # (the transfer broke and no log of this pass is there. The pass that
      # writes goes again only when the slot is still the copy of step 1:
      # the installer may have written part of it before the recovery
      # restarted, and its log is gone with /tmp then)
      $same = $false
      if ($next -eq 'WRITE' -and $null -ne $Script:RamCopy) {
        switch (Compare-SlotCopy $rec.Slot) {
          'diff' { Stop-SlotChanged $M_SLOT_HALF $rec.Slot }
          'unread' { Stop-SlotUnread $rec.Slot }
          default { $same = $true }
        }
      }
      if ($try -lt $Script:MAX_TRIES) {
        WarnM ($M_RETRY -f ($try + 1), $Script:MAX_TRIES)
        $fresh = $false
        continue
      }
      if ($next -eq 'COPY') { $Script:Sum['What'] = $U_TRIES; Fail ($M_TRIES_OUT -f $Script:MAX_TRIES) }
      if ($same) {
        GoodM ($M_SLOT_SAME -f $rec.Slot)
        $Script:RunWrites = $false; $Script:Sum['Result'] = 'nothing'; $Script:Sum['What'] = $U_TRIES
        Fail ($M_TRIES_OUT -f $Script:MAX_TRIES)
      }
      $Script:Sum['What'] = ($U_TRIES_W -f $Script:MAX_TRIES)
      Fail ($M_TRIES_OUT_W -f $Script:MAX_TRIES) $RC_ATTN
    }
    return $res
  }
}

# Invoke-RecProbe <first>: P_REC, the checks, the copies of this session
# pulled to the PC (they vanish with the next reboot); the probe object
function Invoke-RecProbe([bool]$first) {
  $Script:CurCtx = 'recovery'; $Script:SawRec = $true
  $rec = Get-RecInfo
  $nowLine = ''; if ($first) { $nowLine = Get-NowLine $rec }
  Test-RecChecks $rec $first $nowLine
  $Script:RecChecked = $true
  $Script:Sum['Rec'] = $rec.Kind
  if (-not $Script:Sum.ContainsKey('Was')) { $Script:Sum['Was'] = $rec.Kr }
  $s3 = ($first -and $Script:Sum['Kind'] -eq 'install' -and $Script:StepN -lt 3)
  if ($first -and $Script:Sum['Kind'] -eq 'install') { Step-To 3 $S_I3 }
  if (@($rec.Baks).Count -gt 0) { $Script:RecCopies = @(Sync-PhoneCopies $rec.Baks $false @('recovery')) } else { $Script:RecCopies = @() }
  if ($s3 -and @($Script:RecCopies).Count -eq 0) { Say $M_NONE_ON_REC }
  return $rec
}
# Get-NowLine <rec>: «Сейчас на телефоне: … (по данным рекавери)» (not for a restore)
function Get-NowLine($rec) {
  if ($null -eq $Script:Zip -or $Script:RzMode) { return '' }
  if ($Script:Sum['Kind'] -eq 'backup') { return (($M_NOW_ON_B -f $rec.Kr) + $M_NOW_ON_REC) }
  return ($M_NOW_ON -f $rec.Kr, $Script:Zip.Ver, $M_NOW_ON_REC)
}
# Get-NextPass <rec>: what the next sideload of the kernel zip will do: COPY, WRITE or ONEPASS
function Get-NextPass($rec) {
  $Script:RamCopy = $null
  $ram = @(@($Script:RecCopies) | Where-Object { $_.Listing.Path.StartsWith($Script:REC_TMP + '/' + $Script:BACKUP_NAME + '/') -and $_.Listing.Slot -eq $rec.Slot })
  $ramAll = @(@($rec.Baks) | Where-Object { $_.StartsWith($Script:REC_TMP + '/' + $Script:BACKUP_NAME + '/') -and $_.EndsWith($rec.Slot) })
  if ($ramAll.Count -gt 0) {
    $h = Get-SlotHashes $rec.Slot $false @('recovery')
    $Script:SlotH = $h
    foreach ($c in $ram) {
      if (Test-SameSums $c.Listing.Sums $h) {
        $Script:RamCopy = $c
        Say ($M_RAM_REUSE -f $rec.Slot, $c.Listing.Path)
        if ($c.Ok) { Say ($M_RAM_ONPC -f $c.Path); $Script:Phase = 'ramonpc'; $Script:Sum['RamPc'] = $c.Path } else { $Script:Phase = 'ramcopy' }
        return 'WRITE'
      }
    }
    foreach ($b in $ramAll) {
      $pc = ''; foreach ($c in $ram) { if ($c.Listing.Path -eq $b -and $c.Ok) { $pc = $c.Path } }
      Say ($M_RAM_OLD -f $rec.Slot, $b)
    }
  }
  if ($rec.SdUsable) { Say ($M_ONEPASS -f $Script:BACKUP_NAME); return 'ONEPASS' }
  return 'COPY'
}
# Test-AlreadyDone <rec>: a DONE of this zip in this recovery session (/tmp)
# whose slot has changed since its copy
function Test-AlreadyDone($rec) {
  $z = $Script:Zip
  $srcs = @()
  $p = $Script:REC_TMP + '/' + $Script:LAST_LOG
  if (@($rec.Logs | Where-Object { $_.Path -eq $p }).Count -gt 0) { $t = Get-PhoneText $p $false; if ($null -ne $t) { $srcs += (New-Src $p $t -1 $false) } }
  foreach ($b in @($rec.Baks)) {
    if (-not $b.StartsWith($Script:REC_TMP + '/')) { continue }
    $s = Get-DirLogSrc $b $false @('recovery'); if ($null -ne $s) { $srcs += $s }
  }
  foreach ($s in $srcs) {
    if ($s.I.Cls -ne 'DONE' -or $s.I.Rel -ne $z.Rel -or -not $s.I.Dir) { continue }
    $c = @(@($Script:RecCopies) | Where-Object { $_.Listing.Path -eq $s.I.Dir })
    if ($c.Count -eq 0) { continue }
    $h = $Script:SlotH; if ($null -eq $h) { $h = Get-SlotHashes $rec.Slot $false @('recovery'); $Script:SlotH = $h }
    if ((Test-HashesKnown $h) -and -not (Test-SameSums $c[0].Listing.Sums $h)) { Write-Log ('already done: ' + $s.Name); return $s }
  }
  return $null
}
# Invoke-RecoveryFlow <entry> <backup only>: entry 'recovery', 'sideload'
# (right after this run's reboot) or 'sideload-unknown' (found so at the start)
function Invoke-RecoveryFlow([string]$entry, [bool]$backupOnly) {
  $z = $Script:Zip
  $Script:CurCtx = 'recovery'
  $round = 0; $pass = 1; $fresh = $false; $rec = $null; $next = 'COPY'
  $Script:Pass1Dir = ''; $Script:Pass1Shown = $false; $p2Shown = $false; $copyShown = $false
  $sGo = 4; $sP1 = 5; $sCopy = 6; $sP2 = 7
  if ($backupOnly) { $sGo = 3; $sP1 = 4; $sCopy = 5; $sP2 = 5 }
  # (backup only never sends blind: a recovery that can keep the copy in the
  # internal storage would write at once; the flasher must look first)
  if ($backupOnly -and $entry -eq 'sideload') { $entry = 'sideload-unknown' }
  if ($entry -eq 'sideload-unknown') {
    if ($backupOnly) { WarnM $M_SIDELOAD_UNKNOWN_B } else { Say $M_SIDELOAD_UNKNOWN }
    if ($Script:Phase -eq 'pre') { $Script:Phase = 'wait' }
    $st = Wait-Phone -Want @('recovery') -StopOn @('device') -Limit $Script:T_USER -Hint $H_LEAVE_SIDELOAD -Ctx 'recovery' -UnauthLimit $Script:T_UNAUTH_WAIT
    if ($st -eq 'device') { Fail $M_REBOOTED_WAITING }
    if ($st -eq 'unauthorized') { $Script:Sum['Result'] = 'nothing'; $Script:Sum['What'] = $U_UNAUTH1; Fail $M_REC_UNAUTH }
    $entry = 'recovery'
  }
  if ($entry -eq 'sideload') {
    $fresh = $true
    $b = '?'; if ($Script:Sum.ContainsKey('Bat')) { $b = [string]$Script:Sum['Bat'] + ' %' }
    Say ($M_NO_SHELL_CHECKS -f $b)
  } else {
    $rec = Invoke-RecProbe $true
    if (-not $backupOnly) {
      $done = Test-AlreadyDone $rec
      if ($null -ne $done) {
        GoodM ($M_ALREADY_DONE -f $z.Ver)
        $Script:PhoneTouched = $true; $Script:Phase = 'done'; $Script:FlashRc = 0; $Script:RunWrites = $false
        $Script:Sum['Kind'] = 'install'; $Script:Sum['Slot'] = $rec.Slot; $Script:Sum['Result'] = 'done'
        $Script:Sum['What'] = ($U_INSTALLED_EARLIER -f $z.Ver, $z.Rel, $z.Name)
        $k = [string]$Script:Sum['Rec']; if (-not $k) { $k = $U_REC_UNKNOWN }
        $Script:Sum['Way'] = ($U_WAY_B_EARLIER -f $k)
        $Script:Sum['SlotLine'] = ($U_SLOT -f $rec.Slot)
        # (what the slot held before: the copy that install made)
        $dc = @(@($Script:RecCopies) | Where-Object { $_.Listing.Path -eq $done.I.Dir })
        if ($dc.Count -gt 0 -and $dc[0].Listing.Kernel) { $Script:Sum['Was'] = $dc[0].Listing.Kernel }
        Step-To 7 $S_I7_DONE
        Invoke-Reboot $z.Rel
        Show-Summary $RC_OK
        Open-Folder (Get-StockShown)
        Stop-Run $RC_OK
      }
    }
    $next = Get-NextPass $rec
  }
  if ($backupOnly) { $Script:Sum['Way'] = $U_WAY_BAK }
  :passes while ($true) {
    if ($backupOnly) {
      if ($next -eq 'WRITE') {
        if ($null -eq $Script:RamCopy) { $Script:Sum['What'] = $U_NOCOPY_RAM; Fail $M_COPY_NOT_ON_PC }
        if (-not $Script:RamCopy.Ok) { Fail (Get-CopyFailText $Script:RamCopy) }
        Complete-Backup $Script:RamCopy
        return
      }
      # (with /data mounted the installer may keep the copy in the internal
      # storage and write at once: "nothing is written" cannot be promised)
      if ($next -eq 'ONEPASS' -or ($null -ne $rec -and $rec.DataMnt)) { $Script:Sum['What'] = $U_NOTHING0; Fail $M_BACKUP_NOT_HERE }
    }
    if (-not $fresh -and ($next -ne 'COPY' -or ($null -ne $rec -and $rec.DataMnt))) {
      $sk = $rec.Kr; $rd = ''; $fp = ''; $rid = $rec.Rid; $how = 'recovery'
      if ($null -ne $Script:RamCopy) { $sk = $Script:RamCopy.Listing.Kernel; $rd = Get-H $Script:RamCopy.Listing.Info 'boot_ramdisk'; $fp = Get-H $Script:RamCopy.Listing.Info 'fingerprint'; $rid = Get-RidOf $Script:RamCopy.Listing.Info; $how = 'copy' }
      else {
        $mine = @(@($Script:RecCopies) | Where-Object { $_.Listing.Slot -eq $rec.Slot -and $_.Listing.Kernel -eq $rec.Kr })
        if ($mine.Count -gt 0) { $fp = Get-H $mine[0].Listing.Info 'fingerprint'; $rd = Get-H $mine[0].Listing.Info 'boot_ramdisk'; $rid = Get-RidOf $mine[0].Listing.Info }
      }
      Test-Gate $sk $rec.Slot $rd $fp $how $rid
    } elseif (-not $fresh -and -not $backupOnly -and $null -ne $rec) {
      # (the copy pass: what that copy will be, before it is made)
      Show-StockNow $rec.Kr $rec.Slot
    }
    if ($next -eq 'WRITE' -and ($null -eq $Script:RamCopy -or -not $Script:RamCopy.Ok -or -not $Script:RamCopy.RzOk)) {
      if ($null -ne $Script:RamCopy -and -not $Script:RamCopy.Ok -and $Script:RamCopy.Reason) { Fail (Get-CopyFailText $Script:RamCopy) }
      if ($null -ne $Script:RamCopy -and $Script:RamCopy.Ok) { $Script:Sum['What'] = $U_RZ_NONE; Fail ($M_RZ_NONE_STOP -f $Script:RamCopy.Path) }
      $Script:Sum['What'] = $U_NOCOPY; Fail $M_COPY_NOT_ON_PC
    }
    if ($pass -eq 1 -and -not $Script:Pass1Shown) {
      $tw = ($null -ne $Script:Rec -and $Script:Rec.Twrp)
      if ($backupOnly) { if ($tw) { Step-To $sGo $S_B3_TWRP } else { Step-To $sGo $S_B3_REC } }
      elseif ($tw) { Step-To $sGo $S_I4B_TWRP } else { Step-To $sGo $S_I4B }
    }
    if ($pass -ge 2 -and -not $p2Shown) { $p2Shown = $true; Step-To $sP2 ($S_I7_TWO -f $z.Ver) }
    $writes = ($next -ne 'COPY')
    $res = Invoke-KernelPass $next $pass $fresh
    $fresh = $false
    $rec = $Script:Rec
    switch ($res.Res) {
      'STEP1' {
        if ($next -eq 'WRITE' -and $null -ne $Script:RamCopy) {
          # (a pass that was to write came back as step 1: the slot must still
          # be the one copied before, or something did write; that slot is
          # then never filed as a copy)
          switch (Compare-SlotCopy $rec.Slot) {
            'diff' { Stop-SlotChanged $M_SLOT_CHANGED $rec.Slot }
            'unread' { Stop-SlotUnread $rec.Slot }
          }
        }
        GoodM ($M_STEP1_OK -f $res.Slot)
        $Script:Phase = 'ramcopy'
        if ($next -eq 'WRITE') {
          $round++
          WarnM $M_STEP1_AGAIN
          if ($round -gt $Script:MAX_ROUNDS) { $Script:Sum['What'] = $U_NOTHING0; Fail $M_ROUNDS_OUT }
        }
        Show-Notes $res.Text
        if (-not $copyShown) { $copyShown = $true; Step-To $sCopy $S_I6 }
        $dirs = New-Object 'System.Collections.Generic.List[string]'
        if ($res.Dir) { $dirs.Add($res.Dir) }
        foreach ($b in @($rec.Baks)) { if (-not $dirs.Contains($b)) { $dirs.Add($b) } }
        $Script:RecCopies = @(Sync-PhoneCopies $dirs.ToArray() $false @('recovery') 'none')
        $cur = @(@($Script:RecCopies) | Where-Object { $_.Listing.Path -eq $res.Dir })
        if ($cur.Count -eq 0) { $Script:Sum['What'] = $U_NOTHING0; Fail ($M_UNCONFIRMED -f $M_UNC_NODIR, $Script:LogPath) }
        $c = $cur[0]
        $Script:RamCopy = $c; $Script:Pass1Dir = $res.Dir
        if (-not $c.Ok) { Fail (Get-CopyFailText $c) }
        if (-not $c.RzOk) { $Script:Sum['What'] = $U_RZ_NONE; Fail ($M_RZ_NONE_STOP -f $c.Path) }
        $Script:Phase = 'ramonpc'; $Script:Sum['RamPc'] = $c.Path
        Test-Gate $c.Listing.Kernel $c.Listing.Slot (Get-H $c.Listing.Info 'boot_ramdisk') (Get-H $c.Listing.Info 'fingerprint') 'copy' (Get-RidOf $c.Listing.Info)
        if ($backupOnly) { Complete-Backup $c; return }
        $next = 'WRITE'; $pass++; $Script:TwoPass = $true
        continue passes
      }
      default {
        if (-not $Script:Pass1Shown) { $Script:Pass1Shown = $true }
        Complete-Install $res 'B' $rec
        return
      }
    }
  }
}

########################################################################
# restore (section 14): a restore zip from a kept PC folder, one pass,
# confirmed by the slot's sha256 (and the restore zip's own log)
function Format-Stamp([string]$s) {
  $m = [regex]::Match($s, '^([0-9]{4})([0-9]{2})([0-9]{2})-([0-9]{2})([0-9]{2})')
  if ($m.Success) { return ('{0}.{1}.{2} {3}:{4}' -f $m.Groups[3].Value, $m.Groups[2].Value, $m.Groups[1].Value, $m.Groups[4].Value, $m.Groups[5].Value) }
  return '?'
}
# Get-CopyDate <kept copy>: «13.11.2026 13:50» from the date of its info.txt
# (written by the installer with the copy), else from the folder's name (as
# run-flash.sh rs_line)
function Get-CopyDate($f) {
  $d = Format-InfoDate (Get-H $f.Info 'date')
  if ($d) { return $d }
  return (Format-Stamp $f.Stamp)
}
# Test-RestoreFolder <folder>: '' or what is wrong (14.1)
function Test-RestoreFolder($f, [bool]$quiet = $false) {
  if (-not $f.RZip) { return 'нет restore-zip или его .sha256' }
  $w = [regex]::Match([IO.File]::ReadAllText($f.RZip + '.sha256'), '^[0-9a-fA-F]{64}')
  $rn = [IO.Path]::GetFileName($f.RZip)
  if (-not $w.Success -or (Get-Sha256 $f.RZip) -ne $w.Value.ToLowerInvariant()) { return ('sha256 ' + $rn + ' не совпадает с ' + $rn + '.sha256') }
  $imgs = 0
  foreach ($n in $Script:IMGS) {
    $p = Join-Path $f.Path $n
    if (-not [IO.File]::Exists($p)) { continue }
    $imgs++
    if ((Get-Sha256 $p) -ne (Get-H $f.Sums $n)) { return ('sha256 ' + $n + ' не совпадает с SHA256SUMS') }
  }
  $pcDir = ''; if ($imgs -eq 3) { $pcDir = $f.Path }
  $e = Test-RestoreZip $f.RZip $f.Slot $pcDir $f.Sums
  if ($e) { return ([IO.Path]::GetFileName($f.RZip) + ': ' + $e) }
  if ($imgs -lt 3 -and -not $quiet) { Say $M_RESTORE_ZIPONLY }
  return ''
}
# Select-RestoreFolder <class>: the folder to restore from (a list to pick from)
function Select-RestoreFolder([string]$cls) {
  $f = $null
  if ($Script:ArgPath) {
    $p = $Script:ArgPath
    try { $p = [IO.Path]::GetFullPath([IO.Path]::Combine((Get-Location).ProviderPath, $p)) } catch { }
    if (-not [IO.Directory]::Exists($p)) { Fail ($M_ZIP_NOTFOUND -f $p) }
    $f = Read-PcFolder $p $cls
    if ($null -eq $f) { Fail ($M_RESTORE_BAD -f $p, 'нет info.txt') }
    $f.Class = Get-Class $f.Kernel
  } else {
    $c = @(@(Get-FiledFolders) | Where-Object { $_.Class -eq $cls -and $_.Restorable } | Sort-Object -Property Stamp -Descending)
    if ($c.Count -eq 0) {
      if ($cls -eq 'PREV') { Fail $M_RESTORE_NONE_PREV }
      Fail ($M_RESTORE_NONE -f $M_RESTORE_NONE_STOCK, (Join-Path $Script:Base $Script:PC_STOCK))
    }
    Clear-Keys
    WarnM $M_RESTORE_LIST
    $n = [Math]::Min(9, $c.Count)
    for ($i = 0; $i -lt $n; $i++) { Say ($M_RESTORE_ITEM -f ($i + 1), ($M_RESTORE_LINE -f $c[$i].Label, $c[$i].Slot, $c[$i].Kernel, (Get-CopyDate $c[$i]))) }
    Ring
    while ($true) {
      $k = Read-KeyX
      if ($k -eq '0' -or (Get-KeyKind $k) -eq 'NO') {
        # (started from the menu: back to it, as run-flash.sh rs_pick)
        if ($Script:Menu) { Write-Log 'restore list: back to the menu'; $Script:BackToMenu = $true; return $null }
        Invoke-Cancel
      }
      $d = 0
      if ([int]::TryParse($k, [ref]$d) -and $d -ge 1 -and $d -le $n) { $f = $c[$d - 1]; break }
    }
  }
  # (checked first, then the question: as run-flash.sh)
  $e = Test-RestoreFolder $f
  if ($e) { Fail ($M_RESTORE_BAD -f $f.Path, $e) }
  GoodM ($M_RESTORE_CHECKED -f $f.Path)
  Say ('  ' + ($M_RESTORE_LINE -f $f.Label, $f.Slot, $f.Kernel, (Get-CopyDate $f)))
  if (-not (Ask-Yes ($M_RESTORE_CONFIRM -f $f.Slot) $true)) {
    if ($Script:Menu) { Write-Log 'restore: back to the menu'; $Script:BackToMenu = $true; return $null }
    Invoke-Cancel
  }
  Write-Log ('restore from {0}: slot {1}, kernel {2}' -f $f.Path, $f.Slot, $f.Kernel)
  return $f
}
# Get-RzVerdict <folder> <hashes before or $null> <hashes after> <log info or $null>
#   ok, refused, dirty, unconfirmed
function Get-RzVerdict($f, $hb, $ha, $li) {
  if ((Test-HashesKnown $ha) -and (Test-SameSums $f.Sums $ha)) { return 'ok' }
  if (-not (Test-HashesKnown $ha)) { return 'unconfirmed' }
  $failed = ($null -ne $li -and ($li.RzFail))
  if ($null -ne $hb -and (Test-HashesKnown $hb)) {
    $same = $true
    foreach ($n in $Script:IMGS) { if ((Get-H $hb $n) -ne (Get-H $ha $n)) { $same = $false } }
    if ($same -and -not $failed) { return 'refused' }
    return 'dirty'
  }
  if ($failed) { return 'dirty' }
  if ($null -ne $li -and ($li.NothingWritten -or $li.RzRes -eq 'fail')) { return 'refused' }
  return 'unconfirmed'
}
# Invoke-RestoreRun <folder> <way> <hashes before>: the restore zip through
# its own update-binary: (A) under su, (B) by sideload; the verdict
function Invoke-RestoreRun($f, [string]$way, $hb, [bool]$steps = $false) {
  $Script:RzMode = $true
  $slot = $f.Slot
  if ($way -eq 'A') {
    Say $M_SENDING_RZ
    Send-FilesA $f.RZip 'restore'
    if ($steps) { Step $S_R4 }
    $t0p = Get-PhoneNow $true
    [void](Start-A 'restore' 'restore.zip')
    Say $M_A_STARTED
    $w = Watch-A
    $li = $null
    $p = $Script:PH_WORK + '/' + $Script:RLOG_NAME
    $t = Get-PhoneText $p $true
    if ($null -ne $t -and (Get-PhoneMtime $p $true) -ge ($t0p - 5)) { $li = Read-LogInfo $t; $Script:RzText = $t } else { $li = Read-LogInfo $w.Text; $Script:RzText = $w.Text }
    $ha = Get-SlotHashes $slot $true @('device')
    [void](Invoke-Dev (Get-Tpl $Script:P_A_CLEAN) $true 30)
    return (Get-RzVerdict $f $hb $ha $li)
  }
  $try = 0; $inSl = $false
  $twrp = ($null -ne $Script:Rec -and $Script:Rec.Twrp)
  if ($Script:CurState -eq 'sideload') { $inSl = $true }
  while ($true) {
    if (-not $inSl) { if (-not (Wait-Sideload $H_APPLY_LOS $twrp $M_REBOOTED_WAITING)) { continue } }
    else {
      Wait-Sec 1
      $g = Invoke-Adb @('get-state') 10
      if ($g.Out.Trim() -ne 'sideload') { $inSl = $false; continue }
    }
    $inSl = $false
    $t0p = $Script:LastNow; $t0 = [Diagnostics.Stopwatch]::StartNew()
    $try++
    $Script:Phase = 'running'; $Script:RunWrites = $true; $Script:PhoneTouched = $true
    $tr = Invoke-Sideload $f.RZip 'restore-zip'
    if ($tr -eq 'FAILED_EARLY' -and $try -lt $Script:MAX_TRIES -and (Scan-Devices @('sideload')) -eq 'sideload') { WarnM ($M_RETRY -f ($try + 1), $Script:MAX_TRIES); Wait-Sec 2; $inSl = $true; continue }
    Wait-AfterPass $true $tr
    $rec = Get-RecInfo
    if ($t0p -le 0) { $t0p = $rec.Now - [long]$t0.Elapsed.TotalSeconds - 30 }
    $li = $null; $Script:RzText = ''
    $p = $Script:REC_TMP + '/' + $Script:RLOG_NAME
    $lg = @($rec.Logs | Where-Object { $_.Path -eq $p -and $_.Mtime -ge ($t0p - 5) })
    if ($lg.Count -gt 0) { $t = Get-PhoneText $p $false; if ($null -ne $t) { $li = Read-LogInfo $t; $Script:RzText = $t } }
    $ha = Get-SlotHashes $slot $false @('recovery')
    $v = Get-RzVerdict $f $hb $ha $li
    if ($v -ne 'ok' -and $tr -ne 'OK' -and ($null -eq $li -or $li.NothingWritten) -and $v -ne 'dirty') {
      if ($try -lt $Script:MAX_TRIES) { WarnM ($M_RETRY -f ($try + 1), $Script:MAX_TRIES); continue }
      Fail ($M_TRIES_OUT -f $Script:MAX_TRIES)
    }
    return $v
  }
}
# Format-Arg <path>: a path as the user types it in the terminal of this
# system: "..." in cmd (a Windows path holds no "), '...' in bash / zsh
function Format-Arg([string]$p) {
  if ($IsWin) { return '"' + $p + '"' }
  return "'" + $p.Replace("'", "'\''") + "'"
}
# Get-ToolCmd <adb|fastboot>: that program of the platform-tools in use,
# with its full path, ready to type (its bare name when it is not there)
function Get-ToolCmd([string]$tool) {
  $exe = $tool; if ($IsWin) { $exe += '.exe' }
  if ($Script:Adb) {
    try {
      $p = [IO.Path]::Combine([IO.Path]::GetDirectoryName([string]$Script:Adb), $exe)
      if ([IO.File]::Exists($p)) { return (Format-Arg $p) }
    } catch { }
  }
  return $tool
}
function Get-TermText { if ($IsWin) { return $U_TERM_WIN }; return $U_TERM_NIX }
# Get-BackLines <folder> <slot> <restore zip or ''>: the ways back typed by
# hand: the restore zip by adb sideload, the images by fastboot (full paths)
function Get-BackLines([string]$dir, [string]$slot, [string]$rz) {
  $l = New-Object 'System.Collections.Generic.List[string]'
  if ($rz) {
    $l.Add(($U_BACK_SIDELOAD -f (Get-TermText)))
    $l.Add(('      {0} sideload {1}' -f (Get-ToolCmd 'adb'), (Format-Arg $rz)))
  }
  $l.Add(($U_BACK_FB -f (Get-TermText)))
  $fb = Get-ToolCmd 'fastboot'
  foreach ($p in @('boot', 'vendor_boot', 'dtbo')) { $l.Add(('      {0} flash {1}{2} {3}' -f $fb, $p, $slot, (Format-Arg ([IO.Path]::Combine($dir, $p + '.img'))))) }
  if ($IsWin) { $l.Add($U_BACK_DRIVER) }
  return $l.ToArray()
}
# Show-Fastboot <folder> <slot>: the fastboot lines for a kept folder
function Show-Fastboot([string]$dir, [string]$slot) {
  Say ('  ' + $dir)
  foreach ($x in @(Get-BackLines $dir $slot '')) { Say $x }
}
# Invoke-Restore <class>: menu 2 (STOCK) and 3 (PREV); the steps and lines
# of run-flash.sh restore_flow
# Invoke-Restore <class> [again]: again = after the system route
# (Invoke-RecNoRoot): the copy is chosen, from step 2
function Invoke-Restore([string]$cls, [bool]$again = $false) {
  $Script:StepM = 5; $Script:Sum['Kind'] = 'restore'; $Script:RzMode = $true
  if ($again) {
    $f = $Script:RsF
    Step-At 2 $S_R2
  } else {
    Step $S_R1
    $f = Select-RestoreFolder $cls
    # (back to the menu: nothing was asked of the phone; the next choice starts afresh)
    if ($Script:BackToMenu) { $Script:StepN = 0; $Script:RzMode = $false; [void]$Script:Sum.Remove('Kind'); return }
    $Script:RsF = $f; $Script:RsCls = $cls
    $Script:Sum['RzFolder'] = $f.Path; $Script:Sum['RzKernel'] = $f.Kernel; $Script:Sum['Slot'] = $f.Slot
    Step $S_R2
    Initialize-Adb
  }
  $st = Wait-First
  $way = 'B'; $hb = $null; $entry = $st
  if ($st -eq 'device') {
    $Script:CurCtx = 'android'
    $kv = Get-AndroidInfo
    $Script:Sum['Was'] = Get-KV $kv 'kr'
    $s = Get-SlotOf $kv
    if ($s -ne '_a' -and $s -ne '_b') { Fail $M_NO_SLOT }
    $Script:Slot = $s; Say ($M_SLOT -f $s)
    Test-Battery (Get-KV $kv 'bat')
    # (the slot and the ROM build against the folder, once)
    if ($s -ne $f.Slot) { $Script:Gate['rsslot'] = $true; if (-not (Ask-Yes ($M_RESTORE_OTHERSLOT_ASK -f $f.Slot, $s))) { Invoke-Cancel } }
    $fp = Get-KV $kv 'ro.build.fingerprint'; $rid = Get-AndRid $kv
    if ($fp -or $rid) {
      $v = Get-RomCmp '' $rid $fp $f
      Write-Log ("restore: the copy's ROM build against the phone's: " + $v)
      if ($v -eq 'other') { WarnM $M_RESTORE_OTHERROM }
      elseif ($v -eq 'older') { WarnM ($M_RESTORE_MAYBEROM -f $M_HOW_OLDER) }
      elseif ($v -eq 'fprdiff') { WarnM ($M_RESTORE_MAYBEROM -f $M_HOW_FPRDIFF) }
    }
    $root = Invoke-RootLoop
    if ($root -eq 'root') {
      $Script:HasSu = $true; $way = 'A'; $Script:Sum['Way'] = $U_WAY_RA
      # (the bootloader is checked here without a line of its own)
      $ri = Get-RootInfo
      if ((Get-BlState $ri $true) -eq 'locked') { Fail ($M_BL_LOCKED -f $Script:BlWhat) }
      $hb = Get-SlotHashes $f.Slot $true @('device')
      if (Test-SameSums $f.Sums $hb) { GoodM ($M_RESTORE_NOOP -f $f.Slot); $Script:Sum['Result'] = 'noop'; $Script:Sum['What'] = ($U_NOOP -f $f.Slot, $f.Path); Show-Summary $RC_OK; Stop-Run $RC_OK }
    } elseif ($Script:Rnr) {
      # (the recovery's ADB has no root: Q3 from here, or the options)
      Invoke-NrAndroidEnd $kv
    } elseif (Test-StockHyperOs $kv) {
      if (-not (Ask-Yes $M_STOCK_NOROOT $true)) { $Script:Sum['Result'] = 'nothing'; $Script:Sum['What'] = $U_NOTHING0; $Script:NoFooter = $true; Show-Summary $RC_FAIL; Stop-Run $RC_FAIL }
      Step $S_R3_TWRP
      $entry = Enter-Recovery $true $H_TWRP_WAIT $true ($M_MAYBE_XIAOMI_REC + ' ' + $M_XIAOMI_REC_WAYS)
    } else {
      Step $S_R3B
      if (-not (Ask-Yes $M_REBOOT_REC_ASK_R $true)) { Invoke-Cancel }
      # (into the recovery's menu with ADB: the slot is read before and after
      # the restore zip, the only proof of what it did)
      $entry = Enter-Recovery $true $H_ENABLE_ADB_R $true
    }
  }
  if ($way -eq 'B') {
    $Script:Sum['Way'] = $U_WAY_RB
    $Script:CurCtx = 'recovery'
    if ($entry -eq 'sideload') {
      WarnM $M_SIDELOAD_UNKNOWN_R
      if ($Script:Phase -eq 'pre') { $Script:Phase = 'wait' }
      $x = Wait-Phone -Want @('recovery') -StopOn @('device') -Limit $Script:T_USER -Hint $H_LEAVE_SIDELOAD -Ctx 'recovery' -UnauthLimit $Script:T_UNAUTH_WAIT
      if ($x -eq 'device') { Fail $M_REBOOTED_WAITING }
      if ($x -ne 'recovery') { $Script:Sum['What'] = $U_UNAUTH1; Fail $M_REC_UNAUTH }
      $entry = 'recovery'
    }
    $rec = Invoke-RecProbe $true
    if ($rec.Slot -ne $f.Slot -and -not $Script:Gate.ContainsKey('rsslot')) { $Script:Gate['rsslot'] = $true; if (-not (Ask-Yes ($M_RESTORE_OTHERSLOT_ASK -f $f.Slot, $rec.Slot))) { Invoke-Cancel } }
    $hb = Get-SlotHashes $f.Slot $false @('recovery')
    if (Test-SameSums $f.Sums $hb) { GoodM ($M_RESTORE_NOOP -f $f.Slot); $Script:Sum['Result'] = 'noop'; $Script:Sum['What'] = ($U_NOOP -f $f.Slot, $f.Path); Invoke-Reboot $f.Kernel; Show-Summary $RC_OK; Stop-Run $RC_OK }
    $Script:CurState = 'recovery'
    if ($Script:StepN -lt 3) { Step $S_R3_REC }
    # (the tap into Apply from ADB belongs to step 3)
    $twrp = ($null -ne $Script:Rec -and $Script:Rec.Twrp)
    while (-not (Wait-Sideload $H_APPLY_LOS $twrp $M_REBOOTED_WAITING)) { }
    $Script:CurState = 'sideload'
    Step $S_R4
  } else { Step $S_R3A }
  $v = Invoke-RestoreRun $f $way $hb $true
  switch ($v) {
    'ok' {
      GoodM ($M_RESTORED -f $f.Slot, $f.Kernel)
      $Script:Sum['Result'] = 'restored'; $Script:Phase = 'done'; $Script:FlashRc = 0; $Script:RunWrites = $false
      Step $S_R5
      Invoke-Reboot $f.Kernel
      Show-Summary $RC_OK; Open-Folder $f.Path
      Stop-Run $RC_OK
    }
    'refused' {
      WarnM $M_RESTORE_REFUSED
      if ($Script:RzText) { Show-Reason $Script:RzText }
      $Script:Sum['Result'] = 'nothing'; $Script:Sum['What'] = $U_RZ_REFUSED; $Script:RunWrites = $false
      Fail '' $RC_FAIL
    }
    'dirty' {
      ErrM ($M_RESTORE_DIRTY -f $f.Slot, $f.Path)
      Show-Fastboot $f.Path $f.Slot
      $Script:Sum['Result'] = 'dirty'; $Script:Sum['What'] = ($U_DIRTY_RZ -f $f.Slot); $Script:Sum['Todo'] = ($U_TODO_RZ_DIRTY -f $f.Path)
      Fail '' $RC_ATTN
    }
    default {
      WarnM ($M_RESTORE_UNCONFIRMED -f $f.Slot)
      $Script:Sum['Result'] = 'unconfirmed'; $Script:Sum['What'] = $U_RZ_NOT_CONFIRMED
      Fail '' $RC_ATTN
    }
  }
}

########################################################################
# results, reboot and the boot check, the final summary (sections 11.4, 16, 17)

# Step-To <n> <text>: the heading of step n (skipped steps are not repeated)
function Step-To([int]$n, [string]$t) {
  if ($Script:StepN -ge $n) { return }
  $Script:StepN = $n - 1
  Step $t
}
# Wait-First: step 2's wait for the phone in any state the flows handle
function Wait-First {
  $none = $T_WaitNone.TrimEnd()
  if ($IsWin) { $none = $none + "`r`n" + ($T_WaitNoneDrv -f $Script:DRV_URL) }
  $st = Wait-Phone -Want @('device', 'recovery', 'sideload') -Limit $Script:T_DEVICE -NoneText ($none + "`r`n" + ($M_WAIT_PHONE -f [int]($Script:T_DEVICE / 60))) -Bell $false -UnauthNote $M_UNAUTH_MAYBE_REC
  Write-Log ('first state: ' + $st)
  return $st
}
# Get-SlotCopyOnPc <slot>: a verified copy of this slot's original on the PC (this run)
function Test-SlotCopyOnPc([string]$slot) {
  foreach ($k in @('Stock', 'Prev')) {
    if (-not $Script:Sum.ContainsKey($k)) { continue }
    foreach ($x in $Script:Sum[$k]) { if ($x.Slot -eq $slot) { return $true } }
  }
  return $false
}
# Get-CopyOf <remote dir>: this run's result for a backup dir
function Get-CopyOf([string]$dir) {
  foreach ($k in @($Script:Handled.Keys)) { $c = $Script:Handled[$k]; if ($c.Listing.Path -eq $dir) { return $c } }
  return $null
}
# Copy-AfterDone <res> <way>: step 6 after a write: the copy of the slot (and any new one) to the PC
function Copy-AfterDone($res, [string]$way) {
  if ($way -eq 'A') {
    $Script:CurCtx = 'android'
    foreach ($s in @($Script:STORES.Split(' ') | Where-Object { $_ })) {
      if ($res.Dir -and $res.Dir.StartsWith($s + '/' + $Script:BACKUP_NAME + '/')) { [void](Sync-PhoneCopies @($res.Dir) $true @('device') 'none') }
    }
    [void](Sync-Root ('/sdcard/' + $Script:BACKUP_NAME) $true @('device') 'new')
    [void](Sync-Root ($Script:PH_WORK + '/' + $Script:BACKUP_NAME) $true @('device') 'new')
    if ($res.Dir -and $null -eq (Get-CopyOf $res.Dir)) { [void](Sync-PhoneCopies @($res.Dir) $true @('device') 'none') }
  } else {
    $dirs = New-Object 'System.Collections.Generic.List[string]'
    if ($res.Dir) { $dirs.Add($res.Dir) }
    if ($null -ne $Script:Rec) { foreach ($b in @($Script:Rec.Baks)) { if (-not $dirs.Contains($b)) { $dirs.Add($b) } } }
    if ($dirs.Count -gt 0) { [void](Sync-PhoneCopies $dirs.ToArray() $false @('recovery') 'none') }
  }
  return (Get-CopyOf $res.Dir)
}
# Complete-Install <result> <way> <recovery probe>: what each outcome means (11.4)
function Complete-Install($res, [string]$way, $rec) {
  $z = $Script:Zip
  $slot = $res.Slot; if (-not $slot) { $slot = $Script:Slot }
  $Script:Sum['Slot'] = $slot; if ($Script:Sum['Kind'] -ne 'backup') { $Script:Sum['Kind'] = 'install' }
  if ($way -eq 'A') { $Script:Sum['Way'] = $U_WAY_A }
  elseif ($res.Res -eq 'DONE') {
    $k = [string]$Script:Sum['Rec']; if (-not $k) { $k = $U_REC_UNKNOWN }
    if ($Script:TwoPass) { $Script:Sum['Way'] = ($U_WAY_B2 -f $k) }
    elseif ($Script:LastPass -eq 'WRITE') { $Script:Sum['Way'] = ($U_WAY_B_RAM -f $k) }
    else { $Script:Sum['Way'] = ($U_WAY_B1 -f $k) }
  }
  if ($way -eq 'B' -and $res.Res -eq 'NOLOG') {
    # (no log of this pass: the recovery's own log tells an early stop of AnyKernel3)
    $rl = Invoke-Dev $Script:P_RECLOG $false 20
    $last = @(Get-Lines $rl.Out | Where-Object { $_.Trim() })
    if ($last.Count -gt 0 -and $last[$last.Count - 1] -match 'Unsupported device|Unzip failed|Busybox setup failed') { $res.Res = 'AK3_EARLY'; $Script:Ak3Line = $last[$last.Count - 1].Trim() }
  }
  switch ($res.Res) {
    'DONE' {
      GoodM ($M_DONE -f $z.Ver, $slot)
      Show-Notes $res.Text
      if ($way -eq 'B' -and $Script:LastPass -eq 'COPY') { Say $M_ONEPASS_UNPREDICTED; Write-Log 'one pass, not predicted' }
      if ($way -eq 'B' -and $Script:Sum['Kind'] -eq 'backup') { WarnM $M_BACKUP_UNEXPECTED }
      $Script:Sum['Result'] = 'done'; $Script:Phase = 'done'; $Script:FlashRc = 0; $Script:RunWrites = $false
      $Script:Sum['SlotLine'] = ($U_SLOT_W -f $slot)
      # (backup only has 5 steps: its last is the copy)
      $sCopy = 6; $sEnd = 7; if ($Script:StepM -lt 7) { $sCopy = $Script:StepM; $sEnd = 0 }
      Step-To $sCopy $S_I6
      # (before the copy: a stop during it still names the copy on the phone)
      if ($res.Dir -and -not $res.Dir.StartsWith($Script:REC_TMP + '/')) { $Script:Sum['PhoneCopy'] = $res.Dir }
      $c = Copy-AfterDone $res $way
      $rc = $RC_OK
      if ($null -eq $c -or -not $c.Ok) {
        $why = 'нет копии'; if ($null -ne $c -and $c.Reason) { $why = $c.Reason }
        WarnM ($M_PULL_LATER -f $why, $res.Dir, $Script:BACKUP_NAME)
        $Script:Sum['Note'] = ($U_NOTE_PHONE -f $res.Dir)
        if (-not (Test-SlotCopyOnPc $slot)) { $rc = $RC_ATTN }
        $Script:FlashRc = $rc
      }
      if ($sEnd -gt 0) { Step-To $sEnd $S_I7_ONE }
      if ($way -eq 'A') { Clear-WorkA }
      Invoke-Reboot $z.Rel
      Show-Summary $rc
      Open-Folder (Get-StockShown)
      Stop-Run $rc
    }
    'STEP1' {
      # (way A cannot end in step 1; nothing was written)
      GoodM ($M_STEP1_OK -f $slot)
      $Script:Sum['Result'] = 'nothing'; $Script:Sum['What'] = $U_A_STEP1
      if ($way -eq 'A') { Clear-WorkA }
      Fail $M_A_STEP1
    }
    'CLEAN' {
      ErrM $M_ABORT_CLEAN
      Show-Reason $res.Text
      $Script:Sum['Result'] = 'nothing'; $Script:Sum['What'] = ($U_CLEAN -f $z.Ver)
      if ($way -eq 'A') { Clear-WorkA }
      Fail '' $RC_FAIL
    }
    'RESTORED' {
      WarnM ($M_ROLLED_BACK -f $slot)
      Show-Reason $res.Text
      $Script:Sum['Result'] = 'rolled'
      if ($way -eq 'A') { Clear-WorkA }
      Fail '' $RC_ROLLED
    }
    'DIRTY' { Invoke-Dirty $res $way $slot }
    'AK3_EARLY' {
      $line = $Script:Ak3Line
      if (-not $line) {
        $rl = Invoke-Dev $Script:P_RECLOG $false 20
        $l2 = @(Get-Lines $rl.Out | Where-Object { $_.Trim() })
        if ($l2.Count -gt 0) { $line = $l2[$l2.Count - 1].Trim() } else { $line = '?' }
      }
      ErrM ($M_AK3_EARLY -f $line)
      if ($line -match 'Unsupported device') { WarnM $M_WHY_DEVICE; $Script:Sum['Why'] = $M_WHY_DEVICE } elseif ($line -match 'Unzip|Busybox') { WarnM $M_WHY_UNZIP; $Script:Sum['Why'] = $M_WHY_UNZIP }
      $Script:Sum['Result'] = 'nothing'; $Script:Sum['What'] = $U_AK3
      Fail '' $RC_FAIL
    }
    default {
      $what = $M_UNC_NOLOG; if ($res.Res -eq 'INCOMPLETE') { $what = $M_UNC_INCOMPLETE }
      if ($way -eq 'B' -and $Script:LastPass -eq 'WRITE' -and $null -ne $Script:RamCopy) {
        # (way B, the pass that writes, the copy from step 1 on the PC: the
        # slot itself tells whether anything was written)
        $cmp = Compare-SlotCopy $slot
        if ($cmp -eq 'same') {
          WarnM ($M_UNC_SAME -f $what)
          GoodM ($M_SLOT_SAME -f $slot)
          $Script:Sum['Result'] = 'nothing'; $Script:Sum['What'] = ($U_SAME -f $z.Ver, $slot); $Script:Sum['Todo'] = $U_TODO_SAME; $Script:RunWrites = $false
          Fail '' $RC_FAIL
        }
        if ($cmp -eq 'diff') { Stop-SlotChanged $M_SLOT_HALF $slot }
      }
      if ($way -eq 'A') {
        ErrM ($M_UNCONFIRMED_A -f $what, $Script:LogPath)
        $Script:Sum['Result'] = 'unconfirmed'; $Script:Sum['What'] = ($U_NOT_CONFIRMED -f $z.Ver); $Script:Sum['Todo'] = $U_TODO_UNC_A
        Fail '' $RC_ATTN
      }
      ErrM ($M_UNCONFIRMED -f $what, $Script:LogPath)
      if (-not $Script:RunWrites) { $Script:Sum['Result'] = 'unconfirmed'; $Script:Sum['What'] = $U_NOT_CONFIRMED1; Fail '' $RC_FAIL }
      if ($way -eq 'B' -and $Script:RunWrites -and $Script:LastPass -ne 'WRITE') {
        # (a first pass that may have written at once: the copy of the slot
        # the installer made before any write goes to the PC, if there is one)
        WarnM $M_UNC_PASS_W
        $c = Copy-PassCopy $res $rec $slot
        if ($null -ne $c -and $c.Ok) { $Script:Sum['BakDir'] = $c.Path }
      }
      $Script:Sum['Result'] = 'unconfirmed'; $Script:Sum['What'] = ($U_NOT_CONFIRMED -f $z.Ver); $Script:Sum['Todo'] = $U_TODO_UNC_B
      Fail '' $RC_ATTN
    }
  }
}
# Copy-PassCopy <result> <recovery probe> <slot>: after a first pass that may
# have written and whose result is not confirmed: the copy the installer made
# before writing (the dir its log names, else the newest copy of this slot in
# the internal storage) to the PC; the copy result or $null (as run-flash.sh
# pass_copy)
function Copy-PassCopy($res, $rec, [string]$slot) {
  $d = [string]$res.Dir
  if (-not $d -and $null -ne $rec) {
    foreach ($b in @($rec.Baks)) {
      if (-not $b -or $b.StartsWith($Script:REC_TMP + '/') -or -not $b.EndsWith($slot)) { continue }
      if (-not $d -or [string]::CompareOrdinal(($b.Substring($b.LastIndexOf('/') + 1)), ($d.Substring($d.LastIndexOf('/') + 1))) -gt 0) { $d = $b }
    }
  }
  if (-not $d) { return $null }
  if (-not $d.StartsWith($Script:REC_TMP + '/')) { $Script:Sum['PhoneCopy'] = $d }
  $c = Get-CopyOf $d
  if ($null -eq $c) { [void](Sync-PhoneCopies @($d) $false @('recovery') 'none'); $c = Get-CopyOf $d }
  return $c
}
# Invoke-Dirty <result> <way> <slot>: the rollback failed; the restore zip
# of the copy may still fix it without a reboot (only after a yes)
function Invoke-Dirty($res, [string]$way, [string]$slot) {
  $Script:Sum['Result'] = 'dirty'; $Script:FlashRc = $RC_ATTN
  $c = $null
  if ($res.Dir) { $c = Get-CopyOf $res.Dir; if ($null -eq $c) { $c = Copy-AfterDone $res $way } }
  $pcp = '?'; if ($null -ne $c -and $c.Ok) { $pcp = $c.Path }
  $ser = [string]$Script:PORT_SERIES.Split(' ')[0]; if ($null -ne $Script:Zip) { $ser = [string]$Script:Zip.Series }
  ErrM ($M_DIRTY -f $slot, $pcp, $ser)
  Show-Reason $res.Text
  $v = '?'; if ($null -ne $Script:Zip) { $v = $Script:Zip.Ver }
  $Script:Sum['What'] = ($U_DIRTY -f $v); $Script:Sum['Todo'] = $U_TODO_DIRTY
  if ($null -ne $c -and $c.Ok) { $Script:Sum['BakDir'] = $c.Path }
  Invoke-RescueOffer $c $way $slot
  Fail '' $RC_ATTN
}
# Invoke-RescueOffer <copy> <way> <slot>: the restore zip of that verified PC
# copy, after a yes, without a reboot (14.4); returns when it did not help
function Invoke-RescueOffer($c, [string]$way, [string]$slot) {
  if ($null -eq $c -or -not $c.Ok -or -not $c.RzOk -or -not $Script:KeysOk) { return }
  $f = Read-PcFolder $c.Path $c.Class
  if ($null -eq $f -or -not $f.RZip -or -not (Ask-Yes $M_RESCUE_ASK $true)) { return }
  $hb = $null
  $v = Invoke-RestoreRun $f $way $hb
  if ($v -eq 'ok') {
    GoodM ($M_RESCUED -f $slot)
    $Script:Sum['Result'] = 'rescued'; $Script:FlashRc = $RC_ROLLED; $Script:Phase = 'done'; $Script:RunWrites = $false
    $v = '?'; if ($null -ne $Script:Zip) { $v = $Script:Zip.Ver }
    $Script:Sum['What'] = ($U_RESCUED -f $v, $slot); $Script:Sum.Remove('Todo')
    Invoke-Reboot $f.Kernel
    Show-Summary $RC_ROLLED
    Stop-Run $RC_ROLLED
  }
}
# Compare-SlotCopy <slot>: the slot against the copy of step 1 on the PC
# ($Script:RamCopy, its SHA256SUMS there): 'same', 'diff' or 'unread' (as
# run-flash.sh slot_vs)
function Compare-SlotCopy([string]$slot) {
  $c = $Script:RamCopy
  $r = 'unread'
  if ($null -ne $c -and $c.Ok -and $c.Path) {
    $sums = @{}
    try { $sums = Read-Sums ([IO.File]::ReadAllText((Join-Path $c.Path 'SHA256SUMS'))) } catch { if (Test-Exit $_) { throw } }
    if ($sums.Count -eq 3) {
      $h = Get-SlotHashes $slot $false @('recovery')
      $Script:SlotH = $h
      if (Test-HashesKnown $h) { if (Test-SameSums $sums $h) { $r = 'same' } else { $r = 'diff' } }
    }
  }
  $pp = '?'; if ($null -ne $c) { $pp = $c.Path }
  Write-Log ('slot {0} against {1}: {2}' -f $slot, $pp, $r)
  return $r
}
# Stop-SlotChanged <message> <slot>: the slot is no longer the copy of step 1
# on the PC although no pass ended with "Done": the rescue offer (its restore
# zip, after a yes), the ways back, 13; no new copy is filed
function Stop-SlotChanged([string]$fmt, [string]$slot) {
  $c = $Script:RamCopy
  $Script:Sum['Result'] = 'dirty'; $Script:FlashRc = $RC_ATTN; $Script:Sum['Slot'] = $slot; $Script:Sum['Half'] = $true
  $pp = '?'
  if ($null -ne $c -and $c.Path) { $Script:Sum['BakDir'] = $c.Path; $pp = $c.Path }
  ErrM ($fmt -f $slot, $pp)
  if ($fmt -eq $M_SLOT_HALF) {
    $v = '?'; if ($null -ne $Script:Zip) { $v = $Script:Zip.Ver }
    $Script:Sum['What'] = ($U_HALF -f $v, $slot); $Script:Sum['Todo'] = ($U_TODO_HALF -f $pp)
  } else { $Script:Sum['What'] = ($U_CHANGED -f $slot); $Script:Sum['Todo'] = ($U_TODO_CHANGED -f $pp) }
  Invoke-RescueOffer $c 'B' $slot
  Fail '' $RC_ATTN
}
# Stop-SlotUnread <slot>: the slot could not be read to compare it: 13
function Stop-SlotUnread([string]$slot) {
  $Script:Sum['Result'] = 'unconfirmed'; $Script:Sum['Slot'] = $slot; $Script:Sum['What'] = ($U_UNREAD -f $slot)
  if ($null -ne $Script:RamCopy -and $Script:RamCopy.Path) { $Script:Sum['BakDir'] = $Script:RamCopy.Path }
  Fail ($M_SLOT_UNREAD -f $slot, $Script:LogPath) $RC_ATTN
}
# Complete-Backup <copy>: menu 4 is done
function Complete-Backup($c) {
  GoodM ($M_BACKUP_DONE -f $c.Path)
  $Script:Sum['Kind'] = 'backup'; $Script:Sum['Result'] = 'backup'; $Script:Phase = 'done'; $Script:FlashRc = 0
  $Script:Sum['Slot'] = $c.Listing.Slot; $Script:Sum['BakDir'] = $c.Path
  Invoke-Reboot $c.Listing.Kernel
  Show-Summary $RC_OK
  Open-Folder $c.Path
  Stop-Run $RC_OK
}

# Invoke-RebootAndroid: the reboot to the system from the running system:
# Android's own (svc power reboot, as the power menu: the system closes the
# apps and stops its services before init's short shutdown). A plain "adb
# reboot" leaves all of that to init's few seconds: on one phone /data then
# was not unmounted in time, and the next boot checked all of /data (fsck).
# (Not shown yet that svc avoids it: init's shutdown is the same.)
# adb reboot when svc is refused, or when the phone has not left within
# T_SVC (twice that while Android says it is shutting down); run-flash.sh
# reboot_android
function Invoke-RebootAndroid {
  Say $M_REBOOTING_SYS
  $r = Invoke-Adb @('shell', 'svc power reboot') $Script:T_SVC
  $why = ''
  if (($r.Out + $r.Err) -match '(?i)fail|exception|error|denied|not found|inaccessible|unknown|usage') { $why = 'svc refused' }
  else {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($true) {
      $st = Scan-Devices @('device')
      if ($st -ne 'device') { Write-Log ('svc power reboot: the phone is restarting ({0})' -f $st); return }
      if ($sw.Elapsed.TotalSeconds -ge $Script:T_SVC) {
        if (-not $why) {
          $q = Invoke-Dev 'getprop sys.shutdown.requested' $false 15
          if ($q.Code -eq 0 -and $q.Out.Trim()) { $why = 'slow'; $sw = [Diagnostics.Stopwatch]::StartNew(); Write-Log 'svc power reboot: Android is shutting down, waiting once more'; continue }
        }
        $why = ('the phone did not restart in {0} s' -f $Script:T_SVC); break
      }
      Wait-Sec 1
    }
  }
  Write-Log ('svc power reboot: {0}: adb reboot' -f $why)
  Say $M_REBOOT_FALLBACK
  [void](Invoke-Adb @('reboot') 30)
}
# Invoke-Reboot <expected release>: the reboot offer and the boot check
function Invoke-Reboot([string]$expect) {
  $Script:Phase = 'done'
  if (-not $Script:KeysOk -or -not (Ask-Yes $M_REBOOT_ASK $true)) {
    if ($Script:CurCtx -eq 'recovery') { Say $M_REBOOT_SELF } else { Say $M_REBOOT_SELF_A }
    return
  }
  # (Android's own reboot only from a running system: the phone's state now
  # decides, "device" is Android; from a recovery as before)
  $st = Scan-Devices @('device', 'recovery')
  if ($st -eq 'device') { Invoke-RebootAndroid } else { [void](Invoke-Adb @('reboot') 30) }
  $Script:Sum['Rebooted'] = $true
  $Script:Phase = 'boot'
  Say $M_BOOT_WAIT
  # (it leaves first, then comes back booted: a scan right after the command
  # may still see the system that is shutting down)
  Clear-Keys
  $sl = [Diagnostics.Stopwatch]::StartNew()
  while ($sl.Elapsed.TotalSeconds -lt $Script:T_LEAVE) {
    if (@('device', 'recovery', 'sideload') -notcontains (Scan-Devices @('device'))) { break }
    if ($Script:EscPressed) { Say $M_BOOT_SKIP; $Script:Phase = 'done'; return }
    Wait-Sec 1
  }
  $st = Wait-Phone -Want @('device') -StopOn @('unauthorized') -Limit $Script:T_BOOT -EscSkip $true -NoAsk $true -Bell $false
  if ($st -eq 'skip') { Say $M_BOOT_SKIP; $Script:Phase = 'done'; return }
  if ($st -eq 'timeout') { WarnM $M_BOOT_NONE; $Script:Sum['Boot'] = $U_BOOT_NONE; $Script:Phase = 'done'; return }
  if ($st -eq 'unauthorized') { WarnM $M_BOOT_UNAUTH; $Script:Sum['Boot'] = $U_BOOT_UNAUTH; $Script:Phase = 'done'; return }
  $sw = [Diagnostics.Stopwatch]::StartNew()
  while ($sw.Elapsed.TotalSeconds -lt $Script:T_BOOT) {
    $x = Invoke-Dev 'getprop sys.boot_completed' $false 15
    if ($x.Out.Trim() -eq '1') { break }
    if ($Script:EscPressed) { Say $M_BOOT_SKIP; $Script:Phase = 'done'; return }
    Write-Dot; Wait-Sec 3
  }
  Close-Dots
  $k = (Invoke-Dev 'uname -r' $false 15).Out.Trim()
  $Script:Phase = 'done'
  if ($k -and $k -eq $expect) { GoodM ($M_BOOT_OK -f $k); $Script:Sum['Boot'] = ($U_BOOT -f $k) }
  elseif ($k) { WarnM ($M_BOOT_OTHER -f $k, $expect); $Script:Sum['Boot'] = ($U_BOOT_OTHER -f $k, $expect) }
  else { WarnM $M_BOOT_NONE; $Script:Sum['Boot'] = $U_BOOT_UNC }
}

# Get-StockShown: the stock folder of this slot that the summary names: the
# one the gate matched, else one saved or met in this run (run-flash.sh SUM_STOCK)
function Get-StockShown {
  $slot = [string]$Script:Sum['Slot']; if (-not $slot) { $slot = $Script:Slot }
  if ($Script:Sum.ContainsKey('StockMatch')) { return [string]$Script:Sum['StockMatch'] }
  if ($Script:Sum.ContainsKey('Stock')) {
    foreach ($x in $Script:Sum['Stock']) { if ($x.Slot -eq $slot) { return $x.Path } }
  }
  return ''
}
# Get-StockForBackup <slot>: menu 4 that neither made nor met stock images:
# the PC's stock folder of this slot for this ROM build (the boot ramdisk of
# this run's copy, else the build time, else the fingerprint, as the gate
# matches; run-flash.sh sum_stock_pc), or $null
function Get-StockForBackup([string]$slot) {
  $i = Get-BackupIds
  if (-not $i[0] -and -not $i[1] -and -not $i[2]) { $Script:StockHow = ''; return $null }
  return (Find-StockFor $slot $i[0] $i[1] $i[2])
}
# Get-BackupIds: the boot ramdisk, fingerprint and ROM build that menu 4's
# summary matches stock folders with (this run's copy, else Android's)
function Get-BackupIds {
  $rd = ''; $fp = ''; $rid = ''
  if ($null -ne $Script:And) { $fp = Get-KV $Script:And 'ro.build.fingerprint'; $rid = Get-AndRid $Script:And }
  $b = [string]$Script:Sum['BakDir']
  if ($b) {
    $f = Read-PcFolder $b 'STOCK'
    if ($null -ne $f) { $rd = [string]$f.Ramdisk; if ($f.Fp) { $fp = [string]$f.Fp }; if ($f.Rid) { $rid = [string]$f.Rid } }
  }
  return @([string]$rd, [string]$fp, [string]$rid)
}
# Show-Summary [exit code]: the final block (screen and log), once; the lines
# of run-flash.sh show_summary
function Show-Summary([int]$rc = -1) {
  if ($Script:SumShown -or (-not $Script:PhoneTouched -and -not $Script:Sum.ContainsKey('Result'))) { return }
  $Script:SumShown = $true
  if ($rc -lt 0) { $rc = $Script:FlashRc }
  $z = $Script:Zip; $s = $Script:Sum
  $slot = [string]$s['Slot']; if (-not $slot) { $slot = $Script:Slot }
  $res = [string]$s['Result']; $kind = [string]$s['Kind']
  $wrote = ($Script:RunWrites -or (@('done', 'dirty', 'rolled', 'rescued', 'unconfirmed') -contains $res))
  $out = New-Object 'System.Collections.Generic.List[object]'
  if ($s['Todo']) { $out.Add(@('R', ($U_WHAT_NOW -f $s['Todo']))) }
  $what = [string]$s['What']
  if (-not $what -and $null -ne $z) {
    switch ($res) {
      'done' { $k = ''; if ($z.Ksu) { $k = ', KernelSU: ' + $z.Ksu }; $what = ($U_INSTALLED -f $z.Ver, $z.Rel, $k, $z.Name) }
      'rolled' { $what = ($U_ROLLED -f $z.Ver, $slot) }
    }
  }
  if (-not $what) {
    if ($res -eq 'backup') { $what = $U_BACKUP }
    elseif ($res -eq 'restored') { $what = ($U_RESTORED -f $s['RzKernel'], $slot, $s['RzFolder']) }
    elseif ($res -eq 'nothing' -and $s['Why']) { $what = ($U_NOTHING -f ([string]$s['Why']).TrimEnd('.')) }
  }
  if (-not $what) {
    switch ($rc) {
      0 { $what = $U_READY }
      11 { if ($Script:PhaseSaid) { $what = $M_CANCEL_SAID } else { $what = Get-CancelText $Script:Phase } }
      12 { $what = $U_ROLLED0 }
      13 { $what = $U_UNCONF }
      default { if ($wrote) { $what = $U_UNCONF } else { $what = $U_NOTHING_SEE } }
    }
  }
  $out.Add(@('N', $what))
  if ($s['Way']) { $out.Add(@('N', ($U_WAY -f $s['Way']))) }
  if ($s['SlotLine']) { $out.Add(@('N', [string]$s['SlotLine'])) }
  if ($s['Was'] -and $kind -ne 'restore') { $out.Add(@('N', ($U_WAS -f $s['Was']))) }
  if ($s['Boot']) { $out.Add(@('N', [string]$s['Boot'])) }
  $stock = ''
  if ($kind -ne 'restore') {
    $stock = Get-StockShown; $sfpr = ($stock -and $stock -eq [string]$s['StockFpr'])
    $oth = New-Object 'System.Collections.Generic.List[string]'; $old = New-Object 'System.Collections.Generic.List[string]'; $may = New-Object 'System.Collections.Generic.List[string]'
    if (-not $stock -and $kind -eq 'backup' -and $slot) {
      $m = Get-StockForBackup $slot
      if ($null -ne $m) { $stock = $m.Path; $sfpr = ($Script:StockHow -eq 'fpr') }
      else {
        $i = Get-BackupIds
        foreach ($f in @(Get-StockOfSlot $slot)) {
          $v = Get-RomCmp $i[0] $i[2] $i[1] $f
          if ($v -eq 'other') { $oth.Add($f.Path) } elseif ($v -eq 'older') { $old.Add($f.Path) } else { $may.Add($f.Path) }
        }
      }
    }
    if ($stock -and $sfpr) { $out.Add(@('N', ($U_STOCK_FPR -f $stock))) }
    elseif ($stock) { $out.Add(@('N', ($U_STOCK -f $stock))) }
    elseif ($oth.Count + $old.Count + $may.Count -gt 0) {
      if ($oth.Count -gt 0) { $out.Add(@('N', ($U_STOCK_OTHERB -f [string]::Join('; ', $oth.ToArray())))) }
      if ($old.Count -gt 0) { $out.Add(@('N', ($U_STOCK_OLDER -f [string]::Join('; ', $old.ToArray())))) }
      if ($may.Count -gt 0) { $out.Add(@('N', ($U_STOCK_OTHER -f [string]::Join('; ', $may.ToArray())))) }
    }
    elseif ($wrote -or $kind -eq 'backup') { $out.Add(@('N', $U_STOCK_NONE)) }
  }
  $prev = ''
  if ($s.ContainsKey('Prev')) {
    foreach ($x in $s['Prev']) {
      if (-not $prev -and ($x.Slot -eq $slot -or -not $slot)) { $prev = $x.Path; $out.Add(@('N', ($U_PREV -f $x.Path, (Get-Series ([string]$x.Kernel))))) }
    }
  }
  $bak = ''; if ($s.ContainsKey('BakDir')) { $bak = [string]$s['BakDir'] }
  if ($bak -and ($bak -eq $stock -or $bak -eq $prev)) { $bak = '' }
  if ($bak) { $out.Add(@('N', ($U_BACKDIR -f $bak))) }
  if ($s.ContainsKey('PhoneCopy')) { $out.Add(@('N', ($U_PHONECOPY -f $s['PhoneCopy']))) }
  if ($s['Note']) { $out.Add(@('Y', [string]$s['Note'])) }
  if ($Script:PullDir -and [IO.Directory]::Exists($Script:PullDir) -and @([IO.Directory]::GetFileSystemEntries($Script:PullDir)).Count -gt 0) { $out.Add(@('N', ($U_PULLDIR -f $Script:PullDir))) }
  # how to go back: the stock folder, else the previous build, else the copy
  # of this run (not after a restore: it was the way back)
  $back = ''; $bcls = 'STOCK'; $bhead = $U_BACK_STOCK
  if ($stock) { $back = $stock } elseif ($prev) { $back = $prev; $bcls = 'PREV'; $bhead = $U_BACK_PREV } elseif ($bak) { $back = $bak; $bcls = ''; $bhead = $U_BACK_COPY }
  if ($back -and $slot -and $kind -ne 'restore') {
    $f = Read-PcFolder $back 'STOCK'
    $bslot = $slot; if ($null -ne $f -and $f.Slot) { $bslot = $f.Slot }
    $rz = ''; if ($null -ne $f -and $f.RZip) { $rz = $f.RZip }
    $out.Add(@('N', $bhead))
    if ($rz -and $bcls -eq 'STOCK') { $out.Add(@('N', ($U_BACK_MENU2 -f $Launcher))) }
    elseif ($rz -and $bcls -eq 'PREV') { $out.Add(@('N', ($U_BACK_MENU3 -f $Launcher))) }
    foreach ($x in @(Get-BackLines $back $bslot $rz)) { $out.Add(@('N', $x)) }
  }
  if ($Script:LogPath) { $out.Add(@('N', ($U_LOG -f $Script:LogPath))) }
  Close-Dots
  Write-Host ''
  Write-Host $U_HEAD -ForegroundColor Cyan; Write-Log $U_HEAD
  foreach ($x in $out) {
    switch ($x[0]) { 'R' { ErrM $x[1] } 'Y' { WarnM $x[1] } default { Say $x[1] } }
  }
  Write-Host $U_FOOT -ForegroundColor Cyan; Write-Log $U_FOOT
}

########################################################################
# a recovery whose ADB has no root (1.1): user builds of LineageOS-type
# recoveries drop adbd to uid 2000 and have no su, whatever the kernel; the
# root of SukiSU-Ultra / KernelSU / Magisk is only in the booted system.
# Q1: the same action from the system with root (one pass); Q2 (install):
# the kernel zip by Apply from ADB, step 1 and step 2, then the reboot and
# the check of the running kernel, only with a verified way back on the PC;
# Q3 (restore): the PC-verified restore zip by Apply from ADB, the same check.
# The same flow, texts and exit codes as run-flash.sh rec_noroot.

# Step-At <n> <text>: the heading of step n as run-flash.sh step_h prints it
# (a step again or back: «(ещё раз)» when it is the same number)
function Step-At([int]$n, [string]$t) {
  Close-Dots
  Write-Host ''
  $s = 'Шаг {0} из {1}: {2}' -f $n, $Script:StepM, $t
  if ($n -eq $Script:StepN) { $s = 'Шаг {0} из {1} (ещё раз): {2}' -f $n, $Script:StepM, $t }
  $Script:StepN = $n
  Write-Host $s -ForegroundColor Cyan
  Write-Log $s
}
# Test-RootMgr: a root manager that hides su until Shell is granted (R2):
# $true when one is installed; the how-to once
function Test-RootMgr {
  $r = Invoke-Dev ($Script:P_PM.Replace('{RE}', $Script:ROOTMGR_RE)) $false 15
  $p = @(@(Get-Lines $r.Out) | ForEach-Object { $_.Trim() } | Where-Object { $_.StartsWith('package:') } | ForEach-Object { $_.Substring(8) } | Where-Object { $_ -match ('(?i)' + $Script:ROOTMGR_RE) } | Select-Object -First 4)
  if ($p.Count -eq 0) { Write-Log 'root manager: none found'; return $false }
  $j = ([string]::Join(' ', $p)).ToLowerInvariant()
  $name = 'Magisk'
  if ($j.Contains('sukisu')) { $name = 'SukiSU-Ultra' }
  elseif ($j.Contains('kernelsu') -or $j.Contains('ksunext')) { $name = 'KernelSU' }
  elseif ($j.Contains('apatch')) { $name = 'APatch' }
  $Script:RootMgr = $name
  Write-Log ('root manager: {0} ({1})' -f $name, [string]::Join(' ', $p))
  if (-not $Script:RootMgrSaid) {
    $Script:RootMgrSaid = $true
    if ($name -eq 'Magisk') { WarnM $M_ROOT_MGR_MAGISK } else { WarnM ($M_ROOT_MGR -f $name) }
    Say $T_RootHow.TrimEnd()
  }
  return $true
}
# Get-RootAsk <root result>: the question of Invoke-RootLoop
function Get-RootAsk([string]$root) {
  $no = $M_ROOT_NO_B
  if ($Script:Mode -eq 'install-system') { $no = $M_ROOT_NO_A } elseif ([string]$Script:Sum['Kind'] -eq 'restore') { $no = $M_ROOT_NO_R }
  if ($Script:Rnr) { $no = $M_ROOT_NO_NR }
  if ($root -eq 'mgr') { return ($M_ROOT_MGR_ASK -f $no) }
  if ($root -eq 'denied') { return ($M_ROOT_DENIED_ASK -f $no) }
  return $M_NR_ROOT_ASK
}
# Invoke-RootLoop: Test-Root, then ask again while root is denied or a root
# manager hides su; after the system route also once with the how-to when
# there is no su at all. install-system: «нет» stops (11). The last result
function Invoke-RootLoop {
  $root = Test-Root; $how = $false
  while ($root -ne 'root') {
    if ($root -ne 'denied' -and $root -ne 'mgr') {
      if (-not $Script:Rnr -or $how) { break }
      $how = $true; Say $T_RootHow.TrimEnd()
    }
    if (-not (Ask-Yes (Get-RootAsk $root) $true)) {
      if ($Script:Mode -eq 'install-system') { Invoke-Cancel }
      break
    }
    $root = Test-Root
  }
  $Script:RootWhy = ''; if ($root -ne 'root') { $Script:RootWhy = $root }
  return $root
}
# Add-SumQ <PC folder>: Q2's way back, for the summary («Как вернуться»)
function Add-SumQ($c) {
  if ($c.Class -eq 'STOCK') {
    $Script:Sum['StockMatch'] = $c.Path
    if ($Script:QHow -eq 'fpr') { $Script:Sum['StockFpr'] = $c.Path } else { [void]$Script:Sum.Remove('StockFpr') }
    return
  }
  $l = New-Object System.Collections.ArrayList
  [void]$l.Add([pscustomobject]@{ Path = $c.Path; Slot = $c.Slot; Kernel = $c.Kernel; Ramdisk = $c.Ramdisk; Fp = $c.Fp; RzName = [IO.Path]::GetFileName($c.RZip) })
  if ($Script:Sum.ContainsKey('Prev')) { foreach ($x in $Script:Sum['Prev']) { if ($x.Path -ne $c.Path) { [void]$l.Add($x) } } }
  $Script:Sum['Prev'] = $l
}
# Find-QCopy <fingerprint> <kernel now> <ROM build now>: Q2's way back: a PC
# copy (stock or taoyao-<series>-backups) of this slot and this ROM build
# (Get-RomCmp: same, or for a copy without rom_build_utc the same
# fingerprint) whose restore zip passes Test-RestoreFolder; one of this
# build (same) before one that matched by the fingerprint only (fpr), then
# the one of the kernel in the slot now, then the newest. QHow: the verdict
function Find-QCopy([string]$fp, [string]$kr, [string]$rid = '') {
  $Script:QCopy = $null; $Script:QLine = ''; $Script:QHow = ''; $Script:QRid = $rid
  $slot = $Script:Slot
  if (($fp -or $rid) -and $slot) {
    $Script:Filed = $null
    $c = @(@(Get-FiledFolders) | Where-Object { $_.Slot -eq $slot -and $_.Restorable -and (@('same', 'fpr') -contains (Get-RomCmp '' $rid $fp $_)) })
    $c = @($c | Sort-Object -Property @{ Expression = { if ((Get-RomCmp '' $rid $fp $_) -eq 'same') { 0 } else { 1 } } }, @{ Expression = { if ($_.Kernel -eq $kr) { 0 } else { 1 } } }, @{ Expression = { Get-H $_.Info 'date' }; Descending = $true })
    foreach ($f in $c) {
      $e = Test-RestoreFolder $f $true
      if ($e) { Write-Log ('Q2 copy {0}: {1}' -f $f.Path, $e); continue }
      $Script:QCopy = $f; $Script:QHow = Get-RomCmp '' $rid $fp $f
      $Script:QLine = ($M_RESTORE_LINE -f $f.Label, $f.Slot, $f.Kernel, (Get-CopyDate $f))
      break
    }
  }
  $w = 'none'; if ($null -ne $Script:QCopy) { $w = $Script:QCopy.Path }
  $rl = $rid; if (-not $rl) { $rl = '?' }
  $mh = ''; if ($Script:QHow) { $mh = ', match ' + $Script:QHow }
  Write-Log ('Q2 way back: {0} (slot {1}, build {2}, fingerprint {3}{4})' -f $w, $slot, $rl, $fp, $mh)
  return ($null -ne $Script:QCopy)
}
# Ask-Q2 <go text>: the Q2 question; a way back that matched by the
# fingerprint only is named so, with the warning first (unless the gate just
# gave it for that very copy; run-flash.sh q2_ask)
function Ask-Q2([string]$go) {
  if ($Script:QHow -eq 'fpr') {
    if ($Script:GateFprSaid -ne $Script:QCopy.Path) { WarnM ($M_Q2_FPRONLY -f (Get-FprWhy $Script:QCopy $Script:QRid)) }
    return (Ask-Yes ($M_Q2_ASK_FPR -f $Script:QLine, $go) $true)
  }
  return (Ask-Yes ($M_Q2_ASK -f $Script:QLine, $go) $true)
}
# Test-Q2Ok <fingerprint> <kernel now> <ROM build now>: Q2 may be offered (else why not)
function Test-Q2Ok([string]$fp, [string]$kr, [string]$rid = '') {
  $Script:Q2Why = ''
  if ($null -ne $Script:Zip -and $kr -eq $Script:Zip.Rel) { $Script:Q2Why = 'same'; Say ($M_Q2_SAMEVER -f $Script:Zip.Rel); return $false }
  if (Find-QCopy $fp $kr $rid) { return $true }
  $s = $Script:Slot; if (-not $s) { $s = '?' }
  $Script:Q2Why = 'none'; Say ($M_Q2_NONE -f $s)
  return $false
}
# Test-Q3Ok <kernel now>: Q3 may be offered: the copy is of the running slot
# and the version would show the restore
function Test-Q3Ok([string]$kr) {
  $f = $Script:RsF
  if ($f.Slot -ne $Script:Slot) { $s = $Script:Slot; if (-not $s) { $s = '?' }; Say ($M_Q3_NOT -f ($M_Q3_WHY_SLOT -f $f.Slot, $s)); return $false }
  if ($kr -and $f.Kernel -eq $kr) { Say ($M_Q3_NOT -f ($M_Q3_WHY_SAME -f $kr)); return $false }
  return $true
}
# Invoke-RecNoRoot <rec>: Test-RecChecks found uid != 0 in the recovery. Says
# why and what happened on the phone so far, then Q1, Q2 / Q3; never returns
function Invoke-RecNoRoot($rec) {
  $kind = [string]$Script:Sum['Kind']
  Write-Log ('recovery ADB without root: uid {0}, ro.build.type {1}, ro.debuggable {2}, data mounted {3}' -f $rec.Uid, (Get-KV $rec.Kv 'ro.build.type'), (Get-KV $rec.Kv 'ro.debuggable'), $rec.DataMnt)
  $Script:Rnr = $true; $Script:RnrDataMnt = $rec.DataMnt; $Script:RnrFp = $rec.Fp; $Script:RnrRid = $rec.Rid; $Script:RnrKr = $rec.Kr; $Script:RnrSlot = $rec.Slot; $Script:RnrRamSeen = $false; $Script:RnrPass1W = $false
  # (nothing goes the way B planned; what the slot holds now, for the summary)
  [void]$Script:Sum.Remove('Way'); if (-not $Script:Sum.ContainsKey('Was')) { $Script:Sum['Was'] = $rec.Kr }
  $u = [string]$rec.Uid; if (-not $u) { $u = '?' }
  WarnM ($M_NR_WHY -f $u)
  if ($Script:Mode -eq 'install-recovery') { Say $M_NR_FORCED }
  # (the only pass sent before the first look: this run's first pass after
  # its own reboot into Apply from ADB; without /data it can only copy)
  if ($Script:SentAny -and $Script:SlServed) {
    if (-not $rec.DataMnt) { Say $M_NR_PASS1; $Script:RunWrites = $false; $Script:RnrStep1 = $true; $Script:Phase = 'wait' }
    else { WarnM $M_NR_PASS1_W; $Script:Phase = 'q2'; $Script:QWant = $Script:Zip.Rel; $Script:RnrPass1W = $true }
  } else {
    # (a copy of this slot in the recovery's RAM: an installer ran earlier in
    # this recovery session, and the next send may write at once)
    $Script:RnrRamSeen = (@(@($rec.Baks) | Where-Object { $_ -and $_.StartsWith($Script:REC_TMP + '/' + $Script:BACKUP_NAME + '/') -and $_.EndsWith($rec.Slot) }).Count -gt 0)
    if ($Script:RnrRamSeen) {
      Write-Log ('a copy of slot {0} in the recovery''s RAM from an earlier send' -f $rec.Slot)
      Say ($M_NR_RAMSEEN -f $rec.Slot); $Script:Phase = 'seen'
    } else { Say $M_NR_NOTHING }
  }
  if ($kind -eq 'backup') { Say $M_NR_BACKUP }
  if (-not $Script:RnrQ1) {
    $Script:RnrQ1 = $true
    $q = $M_NR_Q1_I; if ($kind -eq 'backup') { $q = $M_NR_Q1_B } elseif ($kind -eq 'restore') { $q = $M_NR_Q1_R } elseif ($Script:RootWhy) { $q = $M_NR_Q1_I2 }
    if (Ask-Yes $q $true) { Invoke-NrToSystem }
  }
  if ($kind -eq 'restore') {
    if ((Test-Q3Ok $rec.Kr) -and (Ask-Yes ($M_Q3_ASK -f $M_Q3_GO) $true)) { Invoke-Q3 $rec.Kr }
  } elseif ($kind -ne 'backup') {
    if (Test-Q2Ok $rec.Fp $rec.Kr $rec.Rid) {
      Test-Gate $rec.Kr $rec.Slot '' $rec.Fp 'recovery' $rec.Rid
      if (Ask-Q2 $M_Q2_GO) { Invoke-Q2 $rec.Kr }
    } elseif ($Script:Q2Why -eq 'none') { Say $M_Q2_NONE_OPT }
  }
  Invoke-Cancel
}
# Invoke-NrToSystem: Q1 yes: adb reboot (no root needed), the wait for
# Android, then the command again as a start in Android does it
function Invoke-NrToSystem {
  $kind = [string]$Script:Sum['Kind']
  # (a pass of this run that may have written (M_NR_PASS1_W) stays so)
  $Script:PhoneTouched = $true; if ($Script:RunWrites) { $Script:Phase = 'q2' } else { $Script:Phase = 'wait' }
  Say $M_NR_REBOOTING
  Write-Log 'adb reboot (to the system: recovery ADB without root)'
  $r = Invoke-Adb @('reboot') 30
  if ($r.Code -ne 0) { Hint $H_NR_REBOOT_SELF }
  $Script:Sum['Rebooted'] = $true
  Say $M_BOOT_WAIT
  $st = Wait-Phone -Want @('device') -Limit $Script:T_BOOT -EscSkip $true -NoAsk $true -Bell $false
  if ($st -eq 'skip') { Invoke-Cancel }
  if ($st -eq 'timeout') {
    # (the way back the PC holds for this slot, if any: the summary prints it)
    if ($kind -eq 'install' -and (Find-QCopy $Script:RnrFp $Script:RnrKr $Script:RnrRid)) { Add-SumQ $Script:QCopy }
    Fail ($M_NR_NOSYS -f ('{0} мин' -f [int][Math]::Floor(($Script:T_BOOT + 30) / 60)))
  }
  # (this run's way B state is over, and with the reboot any copy in the
  # recovery's RAM; the questions asked once stay asked)
  $Script:CurCtx = 'android'; $Script:Rec = $null; $Script:RamCopy = $null; $Script:RecChecked = $false; $Script:Pass1Shown = $false; $Script:SawRec = $false; $Script:RnrStep1 = $false; $Script:RnrRamSeen = $false; $Script:RnrPass1W = $false
  # (the phone line again, as a start in Android prints it)
  [void]$Script:Sum.Remove('PhoneShown')
  if ($Script:Mode -eq 'install-recovery') { $Script:Mode = 'install'; Write-Log 'install-recovery: the system route, as install' }
  if ($kind -eq 'backup') { Invoke-Install 'backup' $true }
  elseif ($kind -eq 'restore') { Invoke-Restore $Script:RsCls $true }
  else { Invoke-Install $Script:Mode $true }
  Stop-Run $RC_OK
}
# Invoke-NrP1Check <android probe> <kernel>: Android after the system route,
# and this run's pass 1 may have written (M_NR_PASS1_W): the new kernel
# running is the check (0, and the installer's copy to the PC); the old one:
# pass 1 wrote nothing
function Invoke-NrP1Check($kv, [string]$kr) {
  $z = $Script:Zip
  Write-Log ('pass 1 may have written: running {0} (zip {1}, before {2})' -f $kr, $z.Rel, $Script:RnrKr)
  $sl = Get-SlotOf $kv
  Write-Log ('check: state device, kernel {0}, slot {1} (expected {2} in {3}, before {4})' -f $kr, $sl, $z.Rel, $Script:RnrSlot, $Script:RnrKr)
  # (the slot that pass 1 wrote is the one running, or the probe does not say)
  if ($kr -and $kr -eq $z.Rel -and (-not $sl -or $sl -eq $Script:RnrSlot)) {
    $Script:Phase = 'done'; $Script:RunWrites = $false; $Script:FlashRc = 0
    GoodM ($M_Q_OK -f $kr)
    $rn = [string]$Script:Sum['Rec']; if (-not $rn) { $rn = $U_REC_UNKNOWN }
    $Script:Sum['Way'] = ($U_WAY_Q -f $rn) + ($U_WAY_Q_N -f 1)
    $k = ''; if ($z.Ksu) { $k = ', KernelSU: ' + $z.Ksu }
    $Script:Sum['Result'] = 'done'; $Script:Sum['What'] = ($U_Q_OK -f $z.Ver, $z.Rel, $k, $z.Name)
    $s = $Script:Slot; if (-not $s) { $s = '?' }
    $Script:Sum['SlotLine'] = ($U_SLOT -f $s); $Script:Sum['Boot'] = ($U_QB_OK -f $kr)
    Step-At 3 $S_I3
    $n = @(Sync-Root ('/sdcard/' + $Script:BACKUP_NAME) $false @('device')).Count
    if ($n -eq 0) { Say $M_NONE_ON_PHONE }
    Show-Summary $RC_OK
    Stop-Run $RC_OK
  }
  if ($kr -and $kr -eq $Script:RnrKr) {
    $Script:RunWrites = $false; $Script:Phase = 'wait'
    Say ($M_NR_P1_OLD -f $kr)
  }
}
# Invoke-NrEnd: the system route is done and there is no root: the options
function Invoke-NrEnd {
  $kind = [string]$Script:Sum['Kind']
  $Script:PhoneTouched = $true; $Script:NoFooter = $true
  if ($kind -eq 'backup') { WarnM $M_NR_END_B }
  elseif ($kind -eq 'restore') { WarnM ($M_NR_END_R -f (Get-TermText)); Say ('      {0} sideload {1}' -f (Get-ToolCmd 'adb'), (Format-Arg $Script:RsF.RZip)) }
  else { WarnM ($M_NR_END -f (Get-TermText)); Say ('      {0} sideload {1}' -f (Get-ToolCmd 'adb'), (Format-Arg $Script:Zip.Path)) }
  if (-not $Script:RunWrites) { $Script:Sum['Result'] = 'nothing'; $Script:Sum['What'] = $U_NR_END }
  Fail '' $RC_FAIL
}
# Invoke-NrAndroidEnd <android probe>: Android after the system route, still
# without root: Q2 / Q3 from here (they reboot into Apply from ADB), else the options
function Invoke-NrAndroidEnd($kv) {
  $kind = [string]$Script:Sum['Kind']
  $kr = Get-KV $kv 'kr'; $fp = Get-KV $kv 'ro.build.fingerprint'; $rid = Get-AndRid $kv
  if ($kind -eq 'restore') {
    if ((Test-Q3Ok $kr) -and (Ask-Yes ($M_Q3_ASK -f $M_Q3_GO_A) $true)) {
      Step-At 3 $S_R3B
      [void](Enter-Recovery $false '' $false '')
      $Script:CurCtx = 'recovery'
      Invoke-Q3 $kr
    }
  } elseif ($kind -ne 'backup') {
    if (Test-Q2Ok $fp $kr $rid) {
      Test-Gate $kr $Script:Slot '' $fp 'android' $rid
      if (Ask-Q2 $M_Q2_GO_A) {
        Step-At 4 $S_I4B
        $e = Enter-Recovery $false '' $false ''
        # (the battery as the system reported it just now, as run-flash.sh)
        if ($e -eq 'sideload') { $b = '?'; $bv = Get-KV $kv 'bat'; if ($bv) { $b = $bv + ' %' } elseif ($Script:Sum.ContainsKey('Bat')) { $b = [string]$Script:Sum['Bat'] + ' %' }; Say ($M_NO_SHELL_CHECKS -f $b) }
        $Script:CurCtx = 'recovery'
        Invoke-Q2 $kr
      }
    }
  }
  Invoke-NrEnd
}
# Send-Q <zip> <what> <copy only> <step> <step text>: one send of Q2 / Q3 by
# Apply from ADB (transfer retries as for the passes), its step heading once
# the phone waits for the file; $false when the phone is in the system
# instead (it was rebooted: the check decides)
function Send-Q([string]$path, [string]$what, [bool]$copy, [int]$sn, [string]$stt) {
  $try = 0; $said = $false
  $hint = $H_APPLY_Q; if ($Script:QSent -gt 0) { $hint = $H_APPLY_LOS2 }
  while ($true) {
    if ((Scan-Devices @('sideload')) -ne 'sideload') {
      $st = Wait-Phone -Want @('sideload') -StopOn @('device') -Limit $Script:T_USER -Hint $hint -Ctx 'recovery' -Poll 1
      if ($st -eq 'device') { return $false }
    }
    if (-not $said) { $said = $true; Step-At $sn $stt }
    Wait-Sec 1
    $g = Invoke-Adb @('get-state') 10
    if ($g.Out.Trim() -ne 'sideload') { continue }
    $try++
    $wb = $Script:RunWrites
    if (-not $copy) { $Script:RunWrites = $true }
    $Script:Phase = 'running'; $Script:PhoneTouched = $true; $Script:SentAny = $true
    $note = ''; if ($copy) { $note = $H_STEP1_ERROR_OK }
    $tr = Invoke-Sideload $path $what $note
    if ($tr -eq 'FAILED_EARLY' -and -not $Script:SlServed) {
      $Script:RunWrites = $wb
      if ($try -lt $Script:MAX_TRIES) {
        if ((Scan-Devices @('sideload')) -eq 'sideload') { WarnM ($M_RETRY -f ($try + 1), $Script:MAX_TRIES); Wait-Sec 2 }
        continue
      }
      if (-not $Script:RunWrites) { $Script:Phase = 'wait'; $Script:Sum['Result'] = 'nothing'; $Script:Sum['What'] = $U_TRIES; Fail ($M_TRIES_OUT -f $Script:MAX_TRIES) }
      # (an earlier send of this run may have written)
      Fail ($M_TRIES_OUT_Q -f $Script:MAX_TRIES, $Script:QWant) $RC_ATTN
    }
    $Script:QSent++
    # (between two sends: a stop says what is known)
    if ($Script:RunWrites) { $Script:Phase = 'q2' } else { $Script:Phase = 'wait' }
    $lim = 30; if ($tr -ne 'OK') { $lim = $Script:T_USER }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $lim) {
      if ((Scan-Devices @('sideload', 'recovery')) -ne 'sideload') { break }
      Wait-Sec 1
    }
    return $true
  }
}
# Invoke-Q2 <kernel before>: Q2: two sends (step 1, step 2) in a recovery
# without /data: the first can only copy (into RAM), the second writes, and
# a send after a write only copies again (the installer: no write without
# its step-1 copy of the same slot); one send when this session already has
# the step-1 copy; with /data mounted one send that may write at once, then
# the question about the screen line
function Invoke-Q2([string]$was) {
  $z = $Script:Zip; $c = $Script:QCopy
  $n = 2; $ask = $false
  # (/data open, or a copy of the slot already in the recovery's RAM: the
  # first send may write at once, the screen tells; pass 1 of this run
  # with /data open: the screen tells before any send)
  if ($Script:RnrPass1W) { $n = 0 }
  elseif ($Script:RnrDataMnt -or $Script:RnrRamSeen) { $n = 1; $ask = $true }
  elseif ($Script:RnrStep1) { $n = 1 }
  Write-Log ('Q2: sends planned {0}, question {1}, after the question about pass 1 {2}' -f $n, $ask, $Script:RnrPass1W)
  $mn = '3'; if ($c.Class -eq 'STOCK') { $mn = '2' }
  if ($Script:RnrDataMnt) { WarnM ($M_Q2_WARN_D -f $c.Path, $mn) }
  elseif ($Script:RnrStep1 -or $Script:RnrRamSeen) { WarnM ($M_Q2_WARN_1 -f $c.Path, $mn) }
  else { WarnM ($M_Q2_WARN -f $c.Path, $mn) }
  # (pass 1 of this run counts: the kernel was sent once already)
  $Script:PhoneTouched = $true; $Script:QSent = 0; if ($Script:RnrStep1 -or $Script:RnrPass1W) { $Script:QSent = 1 }; $Script:QKind = 'install'; $Script:QWant = $z.Rel
  if (-not $Script:Sum.ContainsKey('Was')) { $Script:Sum['Was'] = $was }
  Add-SumQ $c
  $rn = [string]$Script:Sum['Rec']; if (-not $rn) { $rn = $U_REC_UNKNOWN }
  $way = ($U_WAY_Q -f $rn); $Script:Sum['Way'] = $way
  if ($Script:RnrPass1W -and (Ask-Yes $M_Q2_PASS1_ASK $true)) { $n = 1 }
  if ($n -gt 0 -and $Script:StepN -lt 4) { Step-At 4 $S_Q_I4 }
  for ($i = 1; $i -le $n; $i++) {
    $c1 = $false; $sn = 5
    if ($n -eq 2 -and $i -eq 1) { $c1 = $true; $stt = ($S_Q_I5_1 -f $z.Ver) }
    elseif ($n -eq 2) { $sn = 6; $stt = ($S_Q_I6_2 -f $z.Ver) }
    elseif ($Script:RnrStep1 -or $Script:RnrPass1W) { $stt = ($S_Q_I5_W -f $z.Ver) }
    else { $stt = ($S_Q_I5 -f $z.Ver) }
    if (-not (Send-Q $z.Path ('ядро v' + $z.Ver) $c1 $sn $stt)) { break }
    if ($ask -and $i -eq 1 -and (Ask-Yes $M_Q2_SCREEN_ASK $true)) { $n = 2; $ask = $false }
  }
  $Script:Sum['Way'] = $way + ($U_WAY_Q_N -f $Script:QSent)
  Step-At 7 $S_Q_CHECK
  Invoke-QCheck $z.Rel $was
}
# Invoke-Q3 <kernel before>: Q3: the restore zip by Apply from ADB, then the reboot and the check
function Invoke-Q3([string]$was) {
  $f = $Script:RsF
  $Script:PhoneTouched = $true; $Script:QSent = 0; $Script:QKind = 'restore'; $Script:QWant = $f.Kernel
  $rn = [string]$Script:Sum['Rec']; if (-not $rn) { $rn = $U_REC_UNKNOWN }
  $Script:Sum['Way'] = ($U_WAY_Q -f $rn)
  if ($Script:StepN -lt 3) { Step-At 3 $S_R3_REC }
  [void](Send-Q $f.RZip 'restore-zip' $false 4 $S_Q_R4)
  Step-At 5 $S_Q_CHECK
  Invoke-QCheck $f.Kernel $was
}
# Invoke-QCheck <expected release> <release before>: Q2 / Q3 end: the reboot
# (adb reboot after a yes when the recovery's ADB is on, else the tap on the
# phone), the wait for the system and its uname -r and slot; stops (0 the
# expected kernel runs, 10 the old one, 13 not confirmed)
function Invoke-QCheck([string]$want, [string]$was) {
  $lim = $Script:T_USER; $rb = $false
  # (right after a sideload adbd restarts: the recovery's ADB, if it is on,
  # comes back in a few seconds, and then adb reboot spares the tap)
  $st = Scan-Devices @('recovery', 'device')
  if ($st -ne 'recovery' -and $st -ne 'device') {
    $st = Wait-Phone -Want @('recovery') -StopOn @('device') -Limit $Script:T_REC_BACK -NoAsk $true -Ctx 'recovery' -Poll 1 -Bell $false
  }
  $Script:Phase = 'boot'
  $st = Scan-Devices @('recovery', 'device')
  if ($st -eq 'recovery' -and (Ask-Yes $M_REBOOT_ASK $true)) {
    [void](Invoke-Adb @('reboot') 30)
    $Script:Sum['Rebooted'] = $true; $rb = $true; $lim = $Script:T_BOOT
  } elseif ($st -ne 'device') { Hint $H_Q_REBOOT }
  $Script:Phase = 'boot'
  $res = 'device'
  if ($st -ne 'device' -or $rb) {
    Say ($M_Q_BOOT_WAIT -f [int][Math]::Floor(($lim + 59) / 60))
    Clear-Keys
    # (the phone first leaves the recovery, after adb reboot or the tap: until
    # then "unauthorized" is the recovery's ADB, not the system's)
    $ll = $Script:T_LEAVE; if (-not $rb) { $ll = $lim }
    $left = $false
    $sl = [Diagnostics.Stopwatch]::StartNew()
    while ($sl.Elapsed.TotalSeconds -lt $ll) {
      if (@('recovery', 'sideload', 'unauthorized') -notcontains (Scan-Devices @('device'))) { $left = $true; break }
      if ($Script:EscPressed) { $res = 'skip'; break }
      Wait-Sec 1
    }
    if ($res -ne 'skip' -and -not $rb -and -not $left) { $res = 'timeout' }
    if ($res -ne 'skip' -and $res -ne 'timeout') { $res = Wait-Phone -Want @('device') -Limit $lim -EscSkip $true -NoAsk $true -Bell $false -UnauthLimit $Script:T_UNAUTH_WAIT }
  }
  $kr = ''; $sl2 = ''; $bc = ''
  if ($res -eq 'device') {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $Script:T_BOOT) {
      $r = Invoke-Dev $Script:P_KRS $false 20
      $kv = ConvertFrom-KV $r.Out
      $kr = Get-KV $kv 'kr'; $bc = Get-KV $kv 'bc'; $sl2 = Get-KV $kv 'sl'
      if ((Get-KV $kv 'end') -ne '1' -and (Test-Lost $r)) {
        $res = Wait-Phone -Want @('device') -Limit $Script:T_BOOT -EscSkip $true -NoAsk $true -Bell $false -UnauthLimit $Script:T_UNAUTH_WAIT
        if ($res -ne 'device') { break }
        $Script:Phase = 'boot'
      }
      if ($bc -eq '1' -and $kr) { break }
      if ($Script:EscPressed) { $res = 'skip'; break }
      Write-Dot; Wait-Sec 3
    }
    Close-Dots
    if ($res -eq 'device' -and $bc -ne '1') { $res = 'timeout' }
  }
  $Script:Phase = 'done'
  Write-Log ('check: state {0}, kernel {1}, slot {2} (expected {3} in {4}, before {5})' -f $res, $kr, $sl2, $want, $Script:Slot, $was)
  $mins = [int][Math]::Floor(($lim + 59) / 60)
  $okSlot = (-not $sl2 -or $sl2 -eq $Script:Slot)
  if ($res -eq 'skip') {
    WarnM ($M_Q_SKIP -f $want); $Script:Sum['Boot'] = $U_QB_SKIP
    $Script:Sum['Result'] = 'unconfirmed'; $Script:Sum['What'] = $U_Q_SKIP; Fail '' $RC_ATTN
  }
  if ($res -eq 'unauthorized') {
    WarnM $M_BOOT_UNAUTH; $Script:Sum['Boot'] = $U_QB_UNAUTH
    $Script:Sum['Result'] = 'unconfirmed'; $Script:Sum['What'] = $U_Q_UNAUTH; Fail '' $RC_ATTN
  }
  if ($res -ne 'device') {
    if ($Script:QKind -eq 'restore') { WarnM ($M_Q3_NOBOOT -f ('{0} мин' -f $mins)) } else { WarnM ($M_Q_NOBOOT -f ('{0} мин' -f $mins)) }
    $Script:Sum['Boot'] = ($U_QB_NONE -f $mins)
    $Script:Sum['Result'] = 'unconfirmed'; $Script:Sum['What'] = $U_Q_NOBOOT
    if ($Script:QKind -eq 'restore') {
      Show-Fastboot $Script:RsF.Path $Script:RsF.Slot
      $Script:Sum['Todo'] = ($U_TODO_Q3_NOBOOT -f $Script:RsF.Path)
    } else { $Script:Sum['Todo'] = ($U_TODO_Q_NOBOOT -f $Script:QCopy.Path) }
    Fail '' $RC_ATTN
  }
  if ($kr -eq $want -and $okSlot) {
    $Script:RunWrites = $false; $Script:FlashRc = 0
    if ($Script:QKind -eq 'restore') {
      GoodM ($M_Q3_OK -f $kr)
      $Script:Sum['Result'] = 'restored'; $Script:Sum['What'] = ($U_Q3_OK -f $Script:RsF.Kernel, $Script:RsF.Slot, $Script:RsF.Path)
    } else {
      GoodM ($M_Q_OK -f $kr)
      $z = $Script:Zip; $k = ''; if ($z.Ksu) { $k = ', KernelSU: ' + $z.Ksu }
      $Script:Sum['Result'] = 'done'; $Script:Sum['What'] = ($U_Q_OK -f $z.Ver, $z.Rel, $k, $z.Name)
      $Script:Sum['SlotLine'] = ($U_SLOT -f $Script:Slot)
    }
    $Script:Sum['Boot'] = ($U_QB_OK -f $kr)
    Show-Summary $RC_OK
    Stop-Run $RC_OK
  }
  if ($kr -eq $was -and $okSlot) {
    $Script:RunWrites = $false; $Script:NoFooter = $true
    $Script:Sum['Boot'] = ($U_QB_OLD -f $kr); $Script:Sum['Result'] = 'nothing'
    if ($Script:QKind -eq 'restore') { ErrM ($M_Q3_OLD -f $kr); $Script:Sum['What'] = ($U_Q3_OLD -f $kr) }
    else { ErrM ($M_Q_OLD -f $kr, $Script:Zip.Ver); $Script:Sum['What'] = ($U_Q_OLD -f $Script:Zip.Ver, $kr) }
    Fail '' $RC_FAIL
  }
  $gk = $kr; if (-not $gk) { $gk = '?' }; $gs = $sl2; if (-not $gs) { $gs = '?' }
  $why = ''; if ($sl2 -and $sl2 -ne $Script:Slot) { $why = ($M_Q_OTHER_SLOT -f $Script:Slot) }
  $qp = ''; if ($Script:QKind -eq 'restore') { $qp = $Script:RsF.Path } elseif ($null -ne $Script:QCopy) { $qp = $Script:QCopy.Path }
  WarnM ($M_Q_OTHER -f $gk, $gs, $want, $Script:Slot, $why, $qp)
  $Script:Sum['Boot'] = ($U_QB_OTHER -f $gk, $gs, $want)
  $Script:Sum['Result'] = 'unconfirmed'; $Script:Sum['What'] = $U_Q_OTHER
  Fail '' $RC_ATTN
}
# Copy-ZipStream <archive> <entry name> <stream>: one entry (deflated)
function Copy-ZipStream($za, [string]$name, $in) {
  $e = $za.CreateEntry($name, [IO.Compression.CompressionLevel]::Optimal)
  $o = $e.Open()
  try { $in.CopyTo($o) } finally { $o.Dispose() }
}
# New-RzPc <PC copy folder> <listing>: its restore zip, made on the PC as the
# installer makes it (restore/ and the tools of the chosen kernel zip, the
# copy's images and SHA256SUMS), with its .sha256; $false when it cannot be made
function New-RzPc([string]$d, $pd) {
  $z = $Script:Zip
  $rz = Join-Path $d $pd.RzName
  $src = $null; $za = $null; $ok = $false
  try {
    $src = [IO.Compression.ZipFile]::OpenRead($z.Path)
    $map = @(@('META-INF/com/google/android/update-binary', 'restore/update-binary'), @('restore.sh', 'restore/restore.sh'), @('LICENSE', 'LICENSE'), @('LICENSE.taoyao', 'LICENSE.taoyao'), @('tools/busybox', 'tools/busybox'), @('tools/magiskboot', 'tools/magiskboot'))
    foreach ($m in $map) { if ($null -eq $src.GetEntry($m[1])) { Write-Log ('restore zip: ' + $m[1] + ' not in ' + $z.Name); return $false } }
    $info = Read-InfoText ([IO.File]::ReadAllText((Join-Path $d 'info.txt')))
    $prop = 'device=' + $Script:DEVICE + "`n"
    foreach ($k in @('slot', 'kernel', 'date', 'fingerprint', 'boot_ramdisk', 'replaced_by')) { $prop += $k + '=' + (Get-H $info $k) + "`n" }
    foreach ($p in @('boot', 'vendor_boot', 'dtbo')) { $prop += $p + '.size=' + (Get-FileLen (Join-Path $d ($p + '.img'))) + "`n" }
    if ([IO.File]::Exists($rz)) { [IO.File]::Delete($rz) }
    $za = [IO.Compression.ZipFile]::Open($rz, [IO.Compression.ZipArchiveMode]::Create)
    $txt = @{ 'META-INF/com/google/android/updater-script' = "# dummy file; update-binary is a shell script`n"; 'restore.prop' = $prop }
    foreach ($n in @('META-INF/com/google/android/update-binary', 'META-INF/com/google/android/updater-script', 'restore.sh', 'restore.prop', 'LICENSE', 'LICENSE.taoyao', 'tools/busybox', 'tools/magiskboot', 'SHA256SUMS', 'boot.img', 'vendor_boot.img', 'dtbo.img')) {
      $in = $null
      if ($txt.ContainsKey($n)) { $in = New-Object IO.MemoryStream (, $Utf8.GetBytes($txt[$n])) }
      elseif (@('SHA256SUMS', 'boot.img', 'vendor_boot.img', 'dtbo.img') -contains $n) { $in = [IO.File]::OpenRead((Join-Path $d $n)) }
      else { $sn = ''; foreach ($m in $map) { if ($m[0] -eq $n) { $sn = $m[1] } }; $in = $src.GetEntry($sn).Open() }
      try { Copy-ZipStream $za $n $in } finally { $in.Dispose() }
    }
    $ok = $true
  } catch { Write-Log ('restore zip: ' + $_.Exception.Message) }
  finally {
    if ($null -ne $za) { try { $za.Dispose() } catch { $ok = $false } }
    if ($null -ne $src) { $src.Dispose() }
  }
  if (-not $ok) { try { if ([IO.File]::Exists($rz)) { [IO.File]::Delete($rz) } } catch { }; return $false }
  $nm = [IO.Path]::GetFileName($rz)
  [IO.File]::WriteAllText($rz + '.sha256', ('{0}  {1}' -f (Get-Sha256 $rz), $nm) + "`n", $Utf8)
  [IO.File]::AppendAllText((Join-Path $d 'info.txt'), ('restore zip (recovery: adb sideload; or a flasher app): ' + $nm + "`n"), $Utf8)
  Write-Log ('restore zip made on the PC: ' + $nm)
  return $true
}
# Invoke-BackupA <android probe>: way A of "copy only" (after the system
# route from a recovery whose ADB has no root): the active slot's
# partitions read under su (never written), pulled, checked, the restore
# zip made on the PC, filed
function Invoke-BackupA($kv) {
  $Script:Sum['Way'] = $U_WAY_A_BAK
  $ri = Get-RootInfo
  $slot = Get-SlotOf $ri; if (-not $slot) { $slot = Get-SlotOf $kv }
  if ($slot -ne '_a' -and $slot -ne '_b') { Fail $M_NO_SLOT }
  $Script:Slot = $slot; $Script:Sum['Slot'] = $slot
  $mb = Get-DfAvailMB (Get-KV $kv 'dfdata')
  if ($mb -ge 0 -and $mb -lt $Script:STORE_NEED_MB) { Fail ($M_DATA_SPACE -f $mb) }
  Step-At 3 ($S_BA3 -f $slot)
  $dn = (Get-Date -Format 'yyyyMMdd-HHmmss') + $slot
  $rd = $Script:PH_WORK + '/pull/' + $dn
  $Script:PhoneTouched = $true
  $r = Invoke-Dev ((Get-Tpl $Script:P_A_BACKUP).Replace('{SLOT}', $slot).Replace('{NAME}', $dn)) $true 300
  if ($r.Out -notmatch '(?m)^COPIED\s*$') {
    $l = Get-FirstLine $r
    [void](Invoke-Dev (Get-Tpl $Script:P_A_PULLCLEAN) $true 60)
    Fail ($M_A_BACKUP_FAIL -f $slot, $l)
  }
  Step-At 4 $S_BA4
  $pd = Get-PhoneDir $rd $false @('device')
  $c = $null
  if ($null -ne $pd) { $c = Copy-PhoneDir $pd @('device') $true }
  [void](Invoke-Dev (Get-Tpl $Script:P_A_PULLCLEAN) $true 60)
  if ($null -eq $c -or -not $c.Ok) {
    $w = '?'; if ($null -ne $c -and $c.Reason) { $w = $c.Reason }
    $Script:Sum['Result'] = 'nothing'; $Script:Sum['What'] = $U_A_BAK_FAIL
    Fail ($M_A_BACKUP_PULLFAIL -f $w)
  }
  $Script:Phase = 'done'
  GoodM ($M_BACKUP_DONE -f $c.Path)
  $Script:Sum['Result'] = 'backup'; $Script:Sum['BakDir'] = $c.Path; $Script:FlashRc = 0; $Script:RunWrites = $false
  Show-Summary $RC_OK
  Open-Folder $c.Path
  Stop-Run $RC_OK
}

########################################################################
# install and backup: steps 1-3 and the choice of the way (sections 7-9)
function Get-ClassRu([string]$c) {
  switch ($c) {
    'DONE' { return $M_PREV_DONE }
    'CLEAN' { return $M_PREV_CLEAN }
    'RESTORED' { return $M_PREV_ROLLED }
    'DIRTY' { return $M_PREV_DIRTY }
  }
  return $M_PREV_UNKNOWN
}
# Read-PrevA <root info>: an installer run of an earlier flasher start in the
# work dir: still running (watched to its end) or finished (its result first)
function Read-PrevA($ri) {
  $z = $Script:Zip
  $res = $null
  if (Get-KV $ri 'rfrun') {
    WarnM $M_A_RUNNING
    $Script:PhoneTouched = $true
    $w = Watch-A
    $li = Read-LogInfo $w.Text
    if ($li.RzHead) {
      Say ($M_PREV_RZ -f $(if ($li.RzOk -or $li.RzNoop -or $li.RzRes -eq 'ok') { $M_PREV_RZ_OK } else { $M_PREV_RZ_FAIL }))
      Clear-WorkA; $Script:Phase = 'pre'; $Script:RunWrites = $false; return
    }
    $res = Get-Result (Get-ASources $w.Text '') 0 '' ([long]-1)
  } elseif (Get-KV $ri 'ubrc') {
    Say $M_A_PREVIOUS
    $t = Get-PhoneText ($Script:PH_WORK + '/ub.out') $true
    if ($null -eq $t) { $t = '' }
    $li = Read-LogInfo $t
    if ($li.RzHead) {
      Say ($M_PREV_RZ -f $(if ($li.RzOk -or $li.RzNoop -or $li.RzRes -eq 'ok') { $M_PREV_RZ_OK } else { $M_PREV_RZ_FAIL }))
      Clear-WorkA; return
    }
    $sb = New-Object System.Text.StringBuilder
    foreach ($l in (Get-Lines $t)) { if ($l.StartsWith('ui_print ')) { [void]$sb.Append($l.Substring(9) + "`n") } }
    $res = Get-Result (Get-ASources $sb.ToString() '') 0 '' ([long]-1)
  } else { return }
  $rel = ''; if ($null -ne $res.Src) { $rel = $res.Src.I.Rel }
  Say ($M_PREV_RESULT -f (Get-ClassRu $res.Res))
  if ($res.Res -eq 'DIRTY') { Invoke-Dirty $res 'A' $Script:Slot }
  if ($res.Res -eq 'DONE' -and $rel -eq $z.Rel) {
    GoodM ($M_ALREADY_DONE_A -f $z.Ver)
    $Script:Sum['Way'] = $U_WAY_A
    Complete-Install $res 'A' $null
  }
  if ($res.Res -eq 'INCOMPLETE') {
    # (its work folder goes before the stop, so that the next run does not
    # stop at the same earlier run again; the logs on the phone stay)
    Clear-WorkA
    $Script:PhoneTouched = $true; $Script:RunWrites = $true
    Complete-Install $res 'A' $null
  }
  Clear-WorkA
  # (nothing of this run is on the phone yet)
  $Script:Phase = 'pre'; $Script:RunWrites = $false
}
# Get-DfAvailMB <df line>: the "Available" column of "df -k" in MB
function Get-DfAvailMB([string]$l) {
  $f = @($l.Trim() -split '\s+')
  if ($f.Count -ge 4) { $v = [long]0; if ([long]::TryParse($f[3], [ref]$v)) { return [long]($v / 1024) } }
  return [long]-1
}
# Invoke-Install <mode> [again]: again = after the system route from a
# recovery whose ADB has no root (Invoke-RecNoRoot): from step 2, the phone in Android
function Invoke-Install([string]$mode, [bool]$again = $false) {
  $z = $Script:Zip
  if ($null -eq $z) { Stop-Run $RC_FAIL }
  $backup = ($mode -eq 'backup')
  $Script:StepM = 7; if ($backup) { $Script:StepM = 5 }
  $Script:Sum['Kind'] = 'install'; if ($backup) { $Script:Sum['Kind'] = 'backup' }
  if ($again) {
    if ($backup) { Step-At 2 $S_B2 } else { Step-At 2 $S_I2 }
  } else {
    Step ($S_I1 -f $z.Ver)
    Show-ZipInfo
    if ($backup) { Step $S_B2 } else { Step $S_I2 }
    Initialize-Adb
  }
  $st = Wait-First
  if ($st -eq 'device') {
    $Script:CurCtx = 'android'
    $kv = Get-AndroidInfo
    $kr = Get-KV $kv 'kr'
    # (after the system route: what the slot held before this run's pass)
    if (-not ($again -and $Script:Sum.ContainsKey('Was'))) { $Script:Sum['Was'] = $kr }
    # (the system route after a pass 1 that may have written: the running kernel tells)
    if ($again -and -not $backup -and $Script:RunWrites -and $Script:Phase -eq 'q2') { Invoke-NrP1Check $kv $kr }
    $root = 'skip'
    if ($mode -ne 'install-recovery' -and -not $backup) { $root = Invoke-RootLoop }
    if ($root -eq 'root') {
      # ---- way (A)
      $Script:HasSu = $true
      Say $M_WAY_A; $Script:Sum['Way'] = $U_WAY_A
      $ri = Get-RootInfo
      Show-BlCheck $ri $true
      $slot = Get-SlotOf $ri; if (-not $slot) { $slot = Get-SlotOf $kv }
      if ($slot -ne '_a' -and $slot -ne '_b') { Fail $M_NO_SLOT }
      $Script:Slot = $slot; $Script:Sum['Slot'] = $slot; Say ($M_SLOT -f $slot)
      Test-Battery (Get-KV $kv 'bat')
      $mb = Get-DfAvailMB (Get-KV $kv 'dfdata')
      if ($mb -ge 0 -and $mb -lt $Script:DATA_NEED_MB) { Fail ($M_DATA_SPACE -f $mb) }
      Say ($M_NOW_ON -f $kr, $z.Ver, '')
      Read-PrevA $ri
      Step $S_I3
      $n = @(Sync-Root ('/sdcard/' + $Script:BACKUP_NAME) $true @('device')).Count
      $n += @(Sync-Root ($Script:PH_WORK + '/' + $Script:BACKUP_NAME) $true @('device')).Count
      if ($n -eq 0) { Say $M_NONE_ON_PHONE }
      Test-Gate $kr $slot '' (Get-KV $kv 'ro.build.fingerprint') 'android' (Get-AndRid $kv)
      Invoke-SystemInstall
      return
    }
    # ---- way (B) from the booted system
    if ($mode -eq 'install-system') { ErrM $M_A_NEEDS_ROOT; Say $T_RootHow.TrimEnd(); Fail '' }
    # (the recovery's ADB has no root: not into it again but Q2, or the options)
    if (-not $backup) { if ($mode -eq 'install-recovery') { Say $M_WAY_B_FORCED } elseif (-not (Test-StockHyperOs $kv) -and -not $Script:Rnr) { Say $M_WAY_B_NOROOT } }
    Show-BlCheck $kv $false
    $slot = Get-SlotOf $kv
    if ($slot) { $Script:Slot = $slot; $Script:Sum['Slot'] = $slot; Say ($M_SLOT -f $slot) }
    Test-Battery (Get-KV $kv 'bat')
    if (-not $backup) { Say ($M_NOW_ON -f $kr, $z.Ver, ''); Step $S_I3 }
    $n = @(Sync-Root ('/sdcard/' + $Script:BACKUP_NAME) $false @('device')).Count
    if ($backup -and $Script:Rnr) {
      $Script:CurCtx = 'android'
      if ((Invoke-RootLoop) -eq 'root') { $Script:HasSu = $true; Invoke-BackupA $kv }
      Invoke-NrEnd
    }
    if ($backup) { Say $M_BACKUP_NEEDS_REC } elseif ($n -eq 0) { Say $M_NONE_ON_PHONE }
    if (-not $backup -and $Script:Rnr) { Invoke-NrAndroidEnd $kv }
    # (the version and stock questions of the gate here, in the system: the
    # first pass is sent before any look into the recovery, and a TWRP /
    # OrangeFox with the internal storage open writes in that very pass)
    if (-not $backup) { Test-Gate $kr $slot '' (Get-KV $kv 'ro.build.fingerprint') 'android' (Get-AndRid $kv) }
    $plain = $false; $hint = ''; $now = $false; $lt = ''
    if (Test-StockHyperOs $kv) {
      if (-not (Ask-Yes $M_STOCK_NOROOT $true)) { $Script:Sum['Result'] = 'nothing'; $Script:Sum['What'] = $U_NOTHING0; $Script:NoFooter = $true; Show-Summary $RC_FAIL; Stop-Run $RC_FAIL }
      $plain = $true; $hint = $H_TWRP_WAIT; $now = $true; $lt = $M_MAYBE_XIAOMI_REC + ' ' + $M_XIAOMI_REC_WAYS
      if ($backup) { Step $S_GO_TWRP } else { Step-To 4 $S_GO_TWRP }
    } else {
      $q = $M_REBOOT_REC_ASK; if ($backup) { $q = $M_REBOOT_REC_ASK_B }
      # (the heading of step 4 before the question, as run-flash.sh)
      if (-not $backup) { Step-To 4 $S_I4B }
      if (-not (Ask-Yes $q $true)) {
        if ($backup) {
          $saved = ($Script:Sum.ContainsKey('Stock') -or $Script:Sum.ContainsKey('Prev'))
          if ($saved) { $Script:Sum['Result'] = 'backup'; $Script:Sum['What'] = $U_BACKUP_PHONE; $Script:PhoneTouched = $true; Show-Summary $RC_OK; Stop-Run $RC_OK }
        }
        Invoke-Cancel
      }
      # (backup only: into the recovery's menu, not straight into Apply from
      # ADB: the flasher looks into the recovery before the pass)
      if ($backup) { $plain = $true; $hint = $H_ENABLE_ADB_B; $now = $true; Step $S_B3 }
    }
    $Script:Pass1Shown = $false
    $entry = Enter-Recovery $plain $hint $now $lt
    Invoke-RecoveryFlow $entry $backup
    return
  }
  # ---- way (B): the phone is in recovery already
  if ($mode -eq 'install-system') { Fail $M_A_NEEDS_SYSTEM }
  if ($backup) { Say $M_WAY_B_REC_BAK } else { Say $M_WAY_B_REC }
  if ($st -eq 'sideload') { Invoke-RecoveryFlow 'sideload-unknown' $backup } else { Invoke-RecoveryFlow 'recovery' $backup }
}

########################################################################
# the main flow
function Invoke-Main {
  $a = $Argv
  if ($a.Count -ge 1 -and [string]$a[0] -eq '--cmdline') { $Script:FromCmdline = $true; $a = @(Get-BatArgs) }
  $pr = Read-Args $a
  if ($Script:Mode -eq 'help') { Write-Host ($M_BANNER -f $Script:BRAND, $Script:VER); Write-Host ''; Show-Help; $Script:FromCmdline = $false; return $RC_OK }
  Update-Mask
  Write-Host ($M_BANNER -f $Script:BRAND, $Script:VER) -ForegroundColor Cyan
  # (the license notice comes first, before any question and any adb command:
  # continuing after it is the acceptance, clause 2.4 of the license)
  Say $M_LICENSE1
  Say $M_LICENSE2
  Write-Log ('PowerShell {0}, {1}' -f $PSVersionTable.PSVersion, [Environment]::OSVersion.VersionString) $true
  Write-Log ('args: ' + [string]::Join(' ', [string[]]@($a)))
  if ($pr -ne 'ok') {
    ErrM ($M_BAD_ARG -f $pr.Substring(4))
    Write-Host ''; Show-Help
    return $RC_FAIL
  }
  if (-not $Script:KeysOk) { ErrM $M_NEED_TTY; return $RC_FAIL }
  $Script:Menu = ($Script:Mode -eq 'menu')
  Say ($M_FOLDER -f $Here)
  # (Explorer runs a script from inside a ZIP after unpacking the whole ZIP
  # into %TEMP%\Temp1_<name>.zip: the copies would land there)
  if ($Here -match '(?i)\\Temp\d*_[^\\]+\.zip(\\|$)') { ErrM $M_IN_ZIP; return $RC_FAIL }
  if ($IsWin) { Write-Host $M_QUICKEDIT -ForegroundColor DarkGray }
  Select-Base
  Open-Log
  Lock-Folder
  if ($Script:ArgNote) { Say $Script:ArgNote }
  $needZip = @('menu', 'install', 'install-system', 'install-recovery', 'backup') -contains $Script:Mode
  if ($needZip) { Find-Zips }
  while ($true) {
    if ($Script:Menu) {
      Show-MenuChoice
      # (the user chose to leave: no "press a key" after that)
      if ($Script:Mode -eq 'exit') { $Script:Menu = $false; $Script:FromCmdline = $false; return $RC_OK }
    }
    if ($needZip -and $Script:Mode -ne 'restore-stock' -and $Script:Mode -ne 'restore-prev' -and $null -eq $Script:Zip) { return $RC_FAIL }
    $Script:BackToMenu = $false
    switch ($Script:Mode) {
      'restore-stock' { Invoke-Restore 'STOCK' }
      'restore-prev' { Invoke-Restore 'PREV' }
      default { Invoke-Install $Script:Mode }
    }
    # (Esc or «нет» at the restore list or its question, from the menu: the menu again)
    if (-not $Script:BackToMenu) { break }
    $Script:Mode = 'menu'
  }
  return $RC_OK
}

########################################################################
# console setup, run, restore the console
try { $Script:OldOutEnc = [Console]::OutputEncoding; [Console]::OutputEncoding = $Utf8 } catch { }
try { $OutputEncoding = $Utf8 } catch { }
try { $Host.UI.RawUI.WindowTitle = ($M_BANNER -f $Script:BRAND, $Script:VER) } catch { }
try { $Script:KeysOk = -not [Console]::IsInputRedirected } catch { $Script:KeysOk = $false }
if ($Script:KeysOk) { try { [Console]::TreatControlCAsInput = $true; $Script:CtrlCSet = $true } catch { } }
$rc = $RC_FAIL
try {
  $rc = Invoke-Main
} catch {
  if (Test-Exit $_) {
    $rc = $Script:ExitCode
    # (the forum footer after every exit 10, 12 and 13, as run-flash.sh finish)
    if (@($RC_FAIL, $RC_ROLLED, $RC_ATTN) -contains $rc -and $Script:LogPath -and -not $Script:NoFooter) { try { Show-Failed } catch { } }
  }
  elseif ($_.Exception -is [System.Management.Automation.PipelineStoppedException]) { $rc = $RC_CANCEL }
  else {
    $msg = $_.Exception.Message
    try { Write-Log ('internal error: ' + $_.ToString() + ' at ' + $_.InvocationInfo.PositionMessage) } catch { }
    try { Close-Dots; Write-Host ($M_INTERNAL -f $msg) -ForegroundColor Red } catch { }
    try { if ($Script:PhoneTouched) { Write-Host $M_INTERNAL_PHONE -ForegroundColor Yellow } } catch { }
    try { Show-Failed } catch { }
    $rc = $RC_FAIL
    if ($Script:RunWrites) { $rc = $RC_ATTN }
  }
} finally {
  if ($null -ne $Script:AdbProc) { try { $Script:AdbProc.Kill() } catch { } }
  if ($null -ne $Script:PtJob) { try { $Script:PtJob.Stop(); $Script:PtJob.Dispose() } catch { } }
  if ($Script:PtStage) { try { [IO.Directory]::Delete($Script:PtStage, $true) } catch { } }
  if ($Script:TmpDir) { try { [IO.Directory]::Delete($Script:TmpDir, $true) } catch { } }
  try { Remove-EmptyDirs $Script:PullDir } catch { }
  try { Write-Log ('exit code ' + $rc) } catch { }
  if ($null -ne $Script:Lock) {
    try { $Script:Lock.Close() } catch { }
    try { [IO.File]::Delete($Script:LockPath) } catch { }
  }
  if ($Script:Menu -or $Script:FromCmdline) {
    Write-Host ''
    Clear-Keys
    Write-Host -NoNewline $M_PRESS_KEY
    try { [void][Console]::ReadKey($true) } catch { try { [void](Read-Host) } catch { } }
    Write-Host ''
  }
  if ($Script:CtrlCSet) { try { [Console]::TreatControlCAsInput = $false } catch { } }
  if ($null -ne $Script:OldOutEnc) { try { [Console]::OutputEncoding = $Script:OldOutEnc } catch { } }
}
exit $rc
