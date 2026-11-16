#!/usr/bin/env bash
# Флешер ядра MeruDevTools для Xiaomi Mi 12 Lite (taoyao), версия 1.2
# SPDX-License-Identifier: LicenseRef-MeruDevTools
# © 2026 Meddax (meru_ii) и команда MeruDevTools. Лицензия: LICENSE-flash.txt
#
# Linux and macOS part; Windows: run-flash.bat + run-flash.ps1 (same flow,
# same messages, same exit codes, same folders on the PC).
# Installs a taoyao kernel zip (taoyao-<series>-v<version>.zip, any version,
# found next to this script or given as an argument) through the zip's own
# installer: from the booted system with root over USB (one pass), or by
# adb sideload in the recovery (two passes in LineageOS-based recoveries:
# copy first, then write). Keeps the phone's stock boot, vendor_boot and
# dtbo on the PC (taoyao-stock-images: never changed or deleted) and puts
# them back with their restore zip. Never runs fastboot, never writes a
# partition itself, never reboots the phone without a yes.
#   bash run-flash.sh                  menu
#   bash run-flash.sh install [zip]    and the other words of: bash run-flash.sh help
# bash 3.2 subset (macOS /bin/bash), UTF-8 without BOM, LF line ends. Every
# command sent to the phone is one adb argument without a single quote
# (except the su -c '...' wrapper).
# Exit codes: 0 done, 10 stopped (nothing written), 11 cancelled by the user,
# 12 the installer wrote and put the original images back, 13 attention (the
# slot may be damaged or its state is unconfirmed), 143 TERM, 129 HUP.

# (dash, zsh or "sh run-flash.sh": start again under bash, not in POSIX mode)
if [ -z "${BASH_VERSION-}" ]; then
  command -v bash >/dev/null 2>&1 || { echo "Нужен bash. Установите его и запустите: bash run-flash.sh"; exit 10; }
  exec bash "$0" "$@"
fi
case ":${SHELLOPTS-}:" in
  *:posix:*) [ -z "${RUNFLASH_REEXEC-}" ] && RUNFLASH_REEXEC=1 exec bash +o posix "$0" "$@";;
esac

# (byte-wise text tools: invalid UTF-8 in a phone log line must not make BSD
# sed or grep drop it; the Russian text is printed as bytes either way)
export LC_ALL=C
# (bash 5.2: "&" in the replacement of ${x//a/b} would mean the match; paths
# may hold "&")
shopt -u patsub_replacement 2>/dev/null

########################################################################
# CONSTANTS. Every installer marker, phone path, file name pattern and time
# limit the flasher relies on is here: a future change of the installer or
# of a recovery is a one-line edit. The same table, in the same order, is at
# the top of run-flash.ps1. Values marked "from the zip" are defaults: the
# chosen kernel zip's tools/ty-lib.sh replaces them at run time.
# Regexes are POSIX ERE ([[ $x =~ $re ]]), case-sensitive, except ZIP_RE,
# which is matched against the lower-cased file name.

# --- the flasher ------------------------------------------------------
BRAND='Флешер ядра MeruDevTools для Xiaomi Mi 12 Lite (taoyao)'
VER=1.2
DEVICE=taoyao
PORT_SERIES='6.12'   # space-separated: a kernel release <series>.* in this list, of
                     # the chosen zip's series, or matching REL_RE (...-taoyao-v<n>.<n>,
                     # any series) is "a build of this port"; anything else is the
                     # ROM's own (stock)
# --- kernel zip names (matched on the lower-cased name) ---------------
# groups: 1 series, 2 major, 3 minor, 5 patch (optional), 6 -noksu, 8 browser copy number
ZIP_RE='^taoyao-([0-9]+\.[0-9]+)-v([0-9]+)\.([0-9]+)(\.([0-9]+))?(-noksu)?( ?\(([0-9]+)\))?\.zip$'
ZIP_NEAR_RE='^taoyao.*\.zip$'                  # look-alikes reported when nothing matches ZIP_RE
ZIP_SKIP_RE='^taoyao-(logs|flash|restore)-'    # our other zips: never kernel candidates
REL_RE='^([0-9]+\.[0-9]+)\.[0-9]+-taoyao-v([0-9]+(\.[0-9]+)+)$'   # vmods/kernel.release
VERFILE_RE='^version ([0-9]+(\.[0-9]+)+),'     # a line of the zip's "version" file (mk-ak3.sh --number)
VERLINE1_RE='^Linux ([^,]+), KernelSU: ([^,]+),'   # first line of "version"
KSU_NONE=noksu
ZIP_NEED='META-INF/com/google/android/update-binary anykernel.sh tools/ak3-core.sh tools/ty-lib.sh vmods/kernel.release vmods/modules.load version Image dtb dtbo.img restore/update-binary restore/restore.sh'
UB_MARK=AnyKernel3                             # must occur in META-INF/.../update-binary
AK_DEVICE_RE='^device\.name1=taoyao$'          # a line of anykernel.sh
AK_CHECK_RE='^do\.devicecheck=1$'
GEN2_MARK=taoyao-result                        # tools/ty-lib.sh of a zip that writes the result lines
# --- installer: paths (from the zip: tools/ty-lib.sh) -----------------
BACKUP_NAME=taoyao-6.12-backup                 # ty-lib.sh: ^TY_BACKUPNAME=(.*);$
STORES='/sdcard /storage/emulated/0 /data/media/0'   # ty-lib.sh: ^TY_STORES="(.*)";$
LAST_LOG=taoyao-6.12-last.log                  # ty-lib.sh: /(taoyao-[A-Za-z0-9.]+-last\.log)
RLOG_NAME=taoyao-restore-last.log              # restore.sh: ${W%/*}/taoyao-restore-last.log
REC_TMP=/tmp
REC_AKHOME=/tmp/anykernel                      # update-binary: $POSTINSTALL/tmp/anykernel
REC_LOG=/tmp/recovery.log                      # diagnosis only
PH_WORK=/data/local/tmp/taoyao-flash           # (A): our work dir; AKHOME=$PH_WORK/ak, TY_RESTORE_TMP=$PH_WORK
BAKDIR_RE='^[0-9]{8}-[0-9]{6}(-[0-9]+)?(_[ab])$'   # ty_keep: <stamp><slot>, <stamp>-<n><slot>
INSTLOG_RE='^install-([0-9]{8}-[0-9]{6})\.log$'
PSTORE_RE='^pstore-[0-9]{8}-[0-9]{6}$'
RZIP_FMT='taoyao-restore-{dir}.zip'            # its checksum: {zip}.sha256 ("<hex>  <name>")
# --- installer: result lines (taoyao-result interface, 75b0c4d and later)
RES_PREFIX='taoyao-result: '                   # the LAST such line of a log counts
RES_STEP1=step1
RES_DONE=done
RES_CLEAN=abort-clean
RES_RESTORED=abort-restored
RES_DIRTY=abort-dirty
RES_RZ_OK=restored                             # restore zip (in RLOG_NAME)
RES_RZ_FAIL=restore-failed
KEY_BACKUP='taoyao-backup: '
KEY_SLOT='taoyao-slot: '
KEY_KERNEL='taoyao-kernel: '
KEY_RUN='taoyao-run: '                         # first taoyao- line of each pass (next installer
                                               # builds): a log whose run id was seen before the
                                               # pass is an old one, whatever its time
# --- installer: English text markers (fallback for the 0.18 installer) --
TXT_STEP1='NOT INSTALLED YET - step 1 of 2'
TXT_DONE_RE='^Done: boot(_[ab]), vendor_boot_[ab] and dtbo_[ab] written and read back\.$'
TXT_BACKUP_RE='^- Backup of slot (_[ab])( \(already there\))?: (/.+)$'
TXT_RELEASE_RE='modules into lib/modules/([^, ]+),'   # the release this run installs (both generations)
TXT_ROLLBACK='- Writing the original images back to slot'
TXT_ROLLED='is as it was before this zip.'
TXT_DIRTY_RE='IS NOW HALF [0-9.]+ AND WILL NOT BOOT'
TXT_ABORTING='Aborting...'
TXT_NOTHING='Nothing was written'
TXT_AK3_DEV='Unsupported device. Aborting...'
TXT_AK3_UNZIP='Unzip failed. Aborting...'
TXT_AK3_BB='Busybox setup failed. Aborting...'
TXT_RZ_HEAD_RE='^Taoyao [0-9.]+ port: RESTORE slot (_[ab])$'
TXT_RZ_OK='holds the saved images again (sha256 read back)'
TXT_RZ_NOOP='already holds the saved images. Nothing to do.'
TXT_RZ_FAIL='!! Could not write:'
# installer notes not repeated on the PC: what they ask for (the copy to the
# PC) the flasher does itself (ERE)
NOTE_SKIP_RE='backup is only in RAM|PC: adb pull|Copy them to the PC|phone: Advanced > Enable ADB'
# the installer's "copy it now" block after a pass that kept the copy in RAM:
# this line, then lines starting with !! (ERE; \1 the copy's dir)
TXT_RAMNOTE_RE='^!! The backup is only in RAM: (/[^ ]+)'
# installer notes repeated on the PC besides lines starting with "!" and
# warnings: the IPA lines (the ROM the installer saw, the hint of the
# taoyao-ipa-stock file); NOTE_IPA_RE: the ROM was not recognised (ERE)
NOTE_RE='IPA UAPI|IPA:|taoyao-ipa-|HyperOS|not recognised|/sdcard and flash again'
NOTE_IPA_RE='taoyao-ipa-stock|IPA: (the )?ROM (was )?not recognised'
# abort reasons (installer text, glob, matched in the log of the run) -> message
WHY_TABLE='*The bootloader is LOCKED*	M_WHY_LOCKED
*will start slot * next*	M_WHY_NEXTSLOT
*Only * MiB free in*	M_WHY_TMPSPACE
*No room for the backup of slot*	M_WHY_SDSPACE
*command line would be*	M_WHY_CMDLINE
*has header version*	M_WHY_HEADER
*Unsupported device*	M_WHY_DEVICE
*Unzip failed*	M_WHY_UNZIP
*Busybox setup failed*	M_WHY_UNZIP
*No 6.12 *	M_WHY_BADZIP
*Bad kernel.release*	M_WHY_BADZIP
*is not the * kernel the modules were built for*	M_WHY_BADZIP
*names *, which is not in the zip*	M_WHY_BADZIP
*another ramdisk than the saved boot.img*	M_WHY_RZ_ROM
*do not match SHA256SUMS*	M_WHY_RZ_SUMS
*is for *, not this phone*	M_WHY_DEVICE'
# --- PC folders (next to the script, or the fallback base) ------------
PC_LOG=run-flash.log
PC_LOG_OLD=run-flash.old.log                   # rotation at 5 MB
PC_LOCK=.run-flash.lock                        # bash: a directory with a pid file
PC_STOCK=taoyao-stock-images
PC_PREV_FMT='taoyao-{series}-backups'          # {series} of the saved kernel, e.g. taoyao-6.12-backups
PC_PULL_FMT='{BACKUP_NAME}-{stamp}'            # this run's raw pull folder, stamp yyyymmdd-HHMMSS
# --- limits and timeouts (seconds) ------------------------------------
T_POLL=2             # adb devices while waiting; 1 while waiting for "sideload"
T_HINT=30            # repeat the hint (and the bell) this often
T_DEVICE=180         # first wait for any phone (then Enter: wait more)
T_SIDELOAD_UP=90     # after "adb reboot sideload": time for the "sideload" state
T_USER=600           # waits for a tap on the phone (Enable ADB, Apply from ADB, unlock)
T_REC_BACK=20        # after a sideload: time for "recovery" to come back by itself before the hint
T_SU=30              # one "su -c id" try (3 tries)
T_STALL=300          # sideload: no progress change for this long = failed (covers "Install anyway?")
T_INSTALL_A=900      # (A) whole installer run; 180 without new output = warning line
T_PULL=900           # one adb pull
T_HASH=180           # sha256 of the three partitions on the phone
T_BOOT=300           # after "adb reboot": wait for the booted system
T_REBOOT_AGAIN=20    # after "adb reboot <target>": still booted this long = "adb reboot recovery" once more
T_REBOOT_FAIL=60     # ... and this long = the phone does not reboot (stop)
T_LEAVE=60           # after "adb reboot": time for the phone to leave before the boot wait
T_SVC=30             # after "svc power reboot" (Android's own reboot): time to leave before "adb reboot"
T_UNAUTH=60          # "unauthorized" this long in a wait for recovery = that recovery refuses this PC
T_OFFLINE=20         # "offline" this long: one "adb reconnect offline"
T_TWRP_SL=20         # TWRP / OrangeFox: after "twrp sideload", time for the "sideload" state
MAX_PULLS=3          # pulls of one backup dir when the cable drops (each after the phone is back)
MAX_TRIES=3          # transfers of one pass
MAX_ROUNDS=2         # step-2 passes that come back as "step 1"
BAT_WARN=30          # %: below = warning + yes
BAT_STOP=15          # %: below = stop
DATA_NEED_MB=1500    # (A): free space in /data for the run (work dir + copy on /sdcard)
STORE_NEED_MB=400    # recovery: free space a store needs for the copy (less: the installer keeps it in RAM)
# --- adb from Google (no usable adb on the PC: downloaded after a yes) ---
PT_BASE='https://dl.google.com/android/repository'   # + /platform-tools-latest-{linux,darwin}.zip;
                                               # TAOYAO_PT_URL replaces it (tests: http://127.0.0.1)
PT_TERMS='https://developer.android.com/studio/terms'
PT_URL='https://developer.android.com/tools/releases/platform-tools'   # manual download page
ADB_MIN=1.0.39                                 # older adb: "too old" (platform-tools 30.x = 1.0.41)

# --- phone commands (section 6 of the design). Placeholders: {BN}
# BACKUP_NAME, {LAST} LAST_LOG, {RLOG} RLOG_NAME, {W} PH_WORK, {SLOT}, {DIR}
# a backup dir, {ROOT} a backup root, {FILE}, {STORE_GLOBS} (every STORES
# entry s as s/{BN}/*), {STORES}, {OFF} / {OFF1} byte offsets. Probes print
# key=value lines and end with end=1 (missing: the probe failed). P_REC's
# store=<store>:<df line> lines: the stores on a disk file system that can be
# written (the installer keeps its copy in the first one it can use).
P_ANDROID='set -f; for p in ro.product.device ro.build.product ro.product.vendor.device ro.vendor.product.device ro.boot.hwname ro.product.model ro.build.fingerprint ro.build.display.id ro.build.version.release ro.boot.slot_suffix ro.boot.flash.locked ro.boot.verifiedbootstate ro.boot.vbmeta.device_state sys.boot_completed sys.user.0.ce_available ro.mi.os.version.name ro.miui.ui.version.name ro.lineage.version ro.modversion ro.crdroid.version ro.evolution.version ro.build.date.utc ro.evolution.build.version ro.crdroid.build.version ro.lineage.build.version ro.mi.os.version.incremental; do echo $p=$(getprop $p); done; u=$(grep -m 1 "^ro.build.date.utc=" /system/build.prop 2>/dev/null); echo romutc=${u#*=}; echo kr=$(uname -r); echo bat=$(dumpsys battery 2>/dev/null | grep -m 1 level: | tr -dc 0-9); echo dfdata=$(df -k /data 2>/dev/null | tail -n 1); [ -d /sdcard/Android ] && echo sd=1; echo now=$(date +%s); echo end=1'
P_SU_ID='su -c id'
P_ROOT='set -f; grep -E "^androidboot[.](verifiedbootstate|vbmeta[.]device_state|slot_suffix) " /proc/bootconfig 2>/dev/null | sed -e "s/^androidboot[.]/bc./" -e "s/ = /=/" -e "s/\"//g"; for t in $(cat /proc/cmdline 2>/dev/null); do case $t in androidboot.verifiedbootstate=*|androidboot.vbmeta.device_state=*|androidboot.slot_suffix=*) echo cl.${t#androidboot.};; esac; done; echo dfwork=$(df -k /data/local/tmp 2>/dev/null | tail -n 1); p=$(cat {W}/rf.pid 2>/dev/null); [ -n "$p" ] && kill -0 $p 2>/dev/null && echo rfrun=$p; [ -f {W}/ub.rc ] && echo ubrc=$(cat {W}/ub.rc); [ -f {W}/ub.out ] && echo ubout=1; echo end=1'
P_REC='set -f; echo uid=$(id -u); for p in ro.product.device ro.build.product ro.product.vendor.device ro.vendor.product.device ro.boot.hwname ro.boot.slot_suffix ro.debuggable ro.build.type ro.build.fingerprint ro.lineage.version ro.modversion ro.crdroid.version ro.evolution.version ro.twrp.version ro.build.date.utc; do echo $p=$(getprop $p); done; [ -e /twres ] && echo twrp=1; echo kr=$(uname -r); echo bat=$(cat /sys/class/power_supply/battery/capacity 2>/dev/null); grep -E "^androidboot[.](verifiedbootstate|vbmeta[.]device_state|slot_suffix) " /proc/bootconfig 2>/dev/null | sed -e "s/^androidboot[.]/bc./" -e "s/ = /=/" -e "s/\"//g"; for t in $(cat /proc/cmdline 2>/dev/null); do case $t in androidboot.verifiedbootstate=*|androidboot.vbmeta.device_state=*|androidboot.slot_suffix=*) echo cl.${t#androidboot.};; esac; done; grep -q " /data " /proc/mounts && echo datamnt=1; [ -d /sdcard/Android ] && echo sdandroid=1; ( : > /sdcard/.run-flash-probe ) 2>/dev/null && rm -f /sdcard/.run-flash-probe && echo sdw=1; for s in {STORES}; do q=$(readlink -f $s 2>/dev/null); [ -n "$q" ] && [ -d "$q" ] || continue; b=/; f=rootfs; while read -r x m t y; do case "$q/" in "$m"/*) [ ${#m} -ge ${#b} ] && b=$m && f=$t;; esac; done < /proc/mounts; case $f in rootfs|tmpfs|ramfs) continue;; esac; [ "$b" != / ] || continue; mkdir $q/.run-flash-probe 2>/dev/null && rmdir $q/.run-flash-probe && echo store=$s:$(df -k $q 2>/dev/null | tail -n 1); done; echo storeprobe=1; echo dftmp=$(df -k /tmp 2>/dev/null | tail -n 1); [ -d /tmp/anykernel ] && echo akhome=$(stat -c %Y /tmp/anykernel 2>/dev/null); set +f; for d in /tmp/{BN}/* {STORE_GLOBS}; do [ -f $d/SHA256SUMS ] && echo bak=$(readlink -f $d); done; for f in /tmp/{LAST} /tmp/anykernel/install.log /tmp/{RLOG}; do [ -f $f ] && echo log=$(stat -c %Y $f 2>/dev/null):$f; done; echo now=$(date +%s); echo end=1'
P_HASH='set -f; for p in boot vendor_boot dtbo; do b=; for d in /dev/block/bootdevice/by-name /dev/block/by-name; do [ -e $d/${p}{SLOT} ] && { b=$d/${p}{SLOT}; break; }; done; if [ -n "$b" ]; then echo h_$p=$(sha256sum $b 2>/dev/null | cut -d" " -f1); else echo h_$p=; fi; done; echo end=1'
P_LISTDIR='set -f; cd {DIR} 2>/dev/null || { echo nodir=1; echo end=1; exit 0; }; set +f; for f in *; do [ -f "$f" ] && echo F=$(stat -c %s "$f" 2>/dev/null):$(stat -c %Y "$f" 2>/dev/null):$f; done; echo =SUMS; cat SHA256SUMS 2>/dev/null; echo =INFO; cat info.txt 2>/dev/null; echo =END; echo end=1'
P_LISTROOT='set +f; for d in {ROOT}/*; do [ -d $d ] && echo D=${d##*/}; done; echo end=1'
P_CAT='cat {FILE}'
P_STAT='stat -c %Y {FILE} 2>/dev/null; echo end=1'
P_RECLOG='grep -E "Unsupported device|Unzip failed|Busybox setup failed|Aborting" /tmp/recovery.log 2>/dev/null | tail -n 5'
P_TWRP_SIDELOAD='twrp sideload'
P_KR='echo kr=$(uname -r); echo bc=$(getprop sys.boot_completed); echo end=1'
P_KRS='echo kr=$(uname -r); echo bc=$(getprop sys.boot_completed); echo sl=$(getprop ro.boot.slot_suffix); echo end=1'
# root managers that hide su from adb until Shell is granted (package names, ERE):
# only the matching names leave the phone
ROOTMGR_RE='kernelsu|sukisu|ksunext|apatch|magisk'
P_PM='pm list packages 2>/dev/null | grep -iE "{RE}"; echo end=1'
P_NOW='echo now=$(date +%s); echo end=1'
P_DF_PC='df -Pk {DIR}'
# (A) only: work dir, start, poll, checksums of the pushed files, clean up
P_A_PREP='mkdir -p {W} {W}/bb && chmod 755 {W} {W}/bb && echo end=1'
P_A_START='sh {W}/rf-run.sh {KIND} {ZIP}'
P_A_POLL='cd {W} 2>/dev/null || { echo RF_POLL nowork; exit 0; }; s=$(wc -c < ub.out 2>/dev/null); echo RF_POLL rc=$(cat ub.rc 2>/dev/null) sz=$s; [ -n "$s" ] && [ "$s" -gt {OFF} ] && tail -c +{OFF1} ub.out 2>/dev/null | head -c $((s - {OFF}))'
P_A_SUMS='cd {W} 2>/dev/null && sha256sum {FILES} 2>/dev/null; echo end=1'
P_A_CLEAN='cd {W} 2>/dev/null && rm -f kernel.zip restore.zip update-binary rf-run.sh ub.out ub.err ub.rc ub.rc.tmp rf.pid bb/busybox bb/bin/unzip; echo end=1'
P_A_ROOTCOPY='mkdir -p {W}/pull/{NAME} && cp {DIR}/{NAME2} {W}/pull/{NAME}/ && chmod -R a+rX {W}/pull && echo COPIED'
P_A_ROOTCOPY_RM='rm -rf {W}/pull; echo end=1'
# (A) copy only (after the system route from a recovery whose ADB has no
# root): the slot's three partitions read (never written) into {W}/pull/{NAME},
# with SHA256SUMS and info.txt as the installer writes them
P_A_BACKUP='set -f; d={W}/pull/{NAME}; rm -rf {W}/pull; mkdir -p $d || exit 1; for p in boot vendor_boot dtbo; do b=; for x in /dev/block/bootdevice/by-name /dev/block/by-name; do [ -e $x/${p}{SLOT} ] && { b=$x/${p}{SLOT}; break; }; done; [ -n "$b" ] || { echo nopart=$p; exit 1; }; cat $b > $d/$p.img || exit 1; done; cd $d || exit 1; sha256sum boot.img vendor_boot.img dtbo.img > SHA256SUMS || exit 1; { echo slot={SLOT}; echo kernel=$(uname -r); echo "date=$(date -u "+%Y-%m-%d %H:%M:%S") UTC"; echo fingerprint=$(getprop ro.build.fingerprint); u=$(grep -m 1 "^ro.build.date.utc=" /system/build.prop 2>/dev/null); u=${u#*=}; f=file; [ -n "$u" ] || { u=$(getprop ro.build.date.utc); f=getprop; }; [ -n "$u" ] || f=; echo rom_build_utc=$u; v=$(grep -m 1 "^ro.build.date=" /system/build.prop 2>/dev/null); echo "rom_build_date=${v#*=}"; v=$(grep -m 1 "^ro.build.version.incremental=" /system/build.prop 2>/dev/null); echo "rom_build_inc=${v#*=}"; v=; for p in ro.evolution.build.version ro.crdroid.build.version ro.lineage.version ro.lineage.build.version ro.modversion ro.mi.os.version.incremental; do [ -n "$v" ] || v=$(getprop $p); done; echo "rom_version=$v"; echo rom_build_from=$f; echo boot_ramdisk=; echo replaced_by=none; } > info.txt || exit 1; chmod -R a+rX {W}/pull && echo COPIED'
# the runner pushed to the phone for (A): starts the installer detached from
# adb (nohup, setsid, every fd redirected), so that a pulled cable, a closed
# window or Ctrl+C on the PC never stop it half-way. OUTFD 1 is a regular
# file opened for append: ui_print re-opens /proc/self/fd/1.
RF_RUN='# Флешер ядра MeruDevTools 1.2, часть для телефона: запускает установщик
# отдельно от adb, чтобы выдернутый кабель не остановил его на середине.
# SPDX-License-Identifier: LicenseRef-MeruDevTools
# © 2026 Meddax (meru_ii) и команда MeruDevTools. Лицензия: LICENSE-flash.txt
# sh rf-run.sh kernel|restore <zip в рабочей папке>
W=/data/local/tmp/taoyao-flash
cd "$W" || { echo RF_NOWORK; exit 3; }
umask 022
p=$(cat rf.pid 2>/dev/null)
if [ -n "$p" ] && kill -0 "$p" 2>/dev/null && [ ! -f ub.rc ]; then echo "RF_BUSY $p"; exit 4; fi
case $1 in
  kernel) export AKHOME="$W/ak";;
  restore) export TY_RESTORE_TMP="$W";;
  *) echo RF_USAGE; exit 2;;
esac
[ -f "$2" ] && [ -f update-binary ] || { echo RF_NOFILES; exit 3; }
if ! command -v unzip >/dev/null 2>&1 && [ -f bb/busybox ]; then
  chmod 755 bb/busybox; mkdir -p bb/bin; ln -sf ../busybox bb/bin/unzip
  export PATH="$W/bb/bin:$PATH"
fi
rm -f ub.out ub.err ub.rc ub.rc.tmp rf.pid
: > ub.out
S=; command -v setsid >/dev/null 2>&1 && S=setsid
nohup $S sh -c '"'"'sh ./update-binary 3 1 "$0" >> ub.out 2>> ub.err < /dev/null; echo $? > ub.rc.tmp; chmod 644 ub.out ub.err ub.rc.tmp 2>/dev/null; mv -f ub.rc.tmp ub.rc'"'"' "$W/$2" > /dev/null 2>&1 < /dev/null &
echo $! > rf.pid
echo "RF_STARTED $!"'
# (end of the constants)
########################################################################

RC_OK=0; RC_FAIL=10; RC_CANCEL=11; RC_ROLLED=12; RC_ATTN=13
LAUNCHER='bash run-flash.sh'
ADB_USER=${ADB-}

case $0 in
  */*) HERE=$(cd -- "${0%/*}" 2>/dev/null && pwd -P);;
  *) HERE=$(pwd -P);;
esac
[ -n "$HERE" ] || { echo "Не удаётся определить папку скрипта."; exit 10; }
CWD=$(pwd -P 2>/dev/null)

if [ -t 1 ] && [ "${TERM-dumb}" != dumb ] && [ -z "${NO_COLOR-}" ]; then
  C0=$'\033[0m'; CC=$'\033[36m'; CY=$'\033[33m'; CR=$'\033[31m'; CG=$'\033[32m'
else
  C0=; CC=; CY=; CR=; CG=
fi

# keys: only with a terminal on stdin (no prompts and no menu otherwise)
TTYOK=
if [ -t 0 ] && { : </dev/tty; } 2>/dev/null; then TTYOK=1; fi

# (a temporary folder whose path has no blanks: some lists below are split on them)
TB=${TMPDIR:-/tmp}; case $TB in *[[:space:]]*) TB=/tmp;; esac
TMPD=$(mktemp -d "${TB%/}/runflash.XXXXXX" 2>/dev/null) || { echo "Не удаётся создать временную папку."; exit 10; }

# run state (see the design: sections 9-17)
LOG=; LOGBUF=; LOCKD=; BASE=; ALTBASE=; ADB=; ADBVER=; SERIAL=; ADBPID=; SERIALS=
INTR=; PHASE=pre; MENU=; CMD=; ARGPATH=; DOTS=; STEPM=7; STEPN=0
WSTATE=; WGONE=; W_ALSO=; W_UNAUTH=0; W_POLL=; W_ESC=; DSTATE=; DSER=
ZIPTOOL=; ZPATH=; ZNAME=; ZDIR=; ZVER=; ZSERIES=; ZKSU=; KREL=; ZGEN=GEN1; ZSIZE=; ZCOPY=; ZNOKSU=
ZCOUNT=0; ZLIST=; KSTRING=
WAY=; HAVE_ROOT=; ROOTWHY=; SLOT=; KR=; FPR=; A_RID=; R_RID=; RNR_RID=; RS_RID=; RS_DEP=; BATP=; BATCHK=; PNOW=; T0P=; T0=
RECKIND=; RECNAME=; NEXT=; ROUND=0; TRY=0; FRESHSL=; SEENREC=; WROTE=; RAMCOPY=; RAMONPC=
PULLDIR=; HANDLED=; RESULT=; RES_DIR=; RES_SLOT=; RES_REUSED=; RES_LOG=; RES_LOGS=
GATE_STOCK=; GATE_VER=; GATE_BAT=; GATE_NOKSU=; GATE_FPRSAID=
SUM_ON=; SUM_WHAT=; SUM_WAY=; SUM_SLOT=; SUM_WAS=; SUM_STOCK=; SUM_STOCK_FPR=; SUM_STOCK_OTHER=; SUM_STOCK_OLDER=; SUM_STOCK_MAYBE=; SUM_PREV=; SUM_PHONE=; SUM_NOTE=; SUM_TODO=
SUM_RZ=; SUM_BAKDIR=; SUM_REBOOT=; SAVED=; OPENDIR=; BOOTWANT=; LASTVERIFIED=
WHERE=; OTHERS=; PASS1DIR=; RAMDIR=; SI_BEST=; PS_N=0; PS_TOTAL=0; H4=; H4W=; PS_QUIET=; OLD_RUNIDS=; BOOTSKIP=; PICKSAID=; PULLPART=; PULLCUR=; PULLPHASE=; GATE_NOW=; FAIL_TXT=; DONE_RC=
STTYSAVE=; PTSTAGE=; PTSTAGE2=; PTOLD=; PTDST=; PTERR=; PTZIP=; PTVER=; PHASE_SAID=; NOFOOTER=; ZWRAPS=; ZEXTRA=; NOREBOOT=; SUM_WAYK=
# (1.1) a recovery whose ADB has no root: RNR=1 once seen in this run; Q2 / Q3
RNR=; RNR_DATAMNT=; RNR_FPR=; RNR_KR=; RNR_STEP1=; RNR_Q1=; ROOTMGR=; ROOTMGR_SAID=; Q_COPY=; Q_CLS=; Q_LINE=; Q_SENT=0; Q_KIND=; Q_WANT=; RS_QUIET=
RNR_RAMSEEN=; RNR_PASS1W=; RNR_SLOT=; Q2_WHY=; RZ_WHY=

########################################################################
# masking for run-flash.log: serials, home folder, user and computer name,
# MAC and IP addresses, e-mail and user@host (the screen shows full paths)
esc_re() { printf '%s' "$1" | sed -e 's/[]\/$*.^|[(){}+?]/\\&/g'; }
build_mask() {
  local d s u h
  d=$(printf '\001')
  {
    for s in $SERIALS; do printf 's%s%s%s<serial>%sg\n' "$d" "$(esc_re "$s")" "$d" "$d"; done
    [ -n "${HOME-}" ] && [ "$HOME" != / ] && printf 's%s%s%s~%sg\n' "$d" "$(esc_re "$HOME")" "$d" "$d"
    u=$(id -un 2>/dev/null)
    case $u in ''|root|user|admin|guest|shell|home|?|??) ;;
      *) printf 's%s(^|[^A-Za-z0-9_])%s([^A-Za-z0-9_]|$)%s\\1<user>\\2%sg\n' "$d" "$(esc_re "$u")" "$d" "$d";;
    esac
    for h in "$(hostname 2>/dev/null)" "$(hostname -s 2>/dev/null)"; do
      case $h in ''|localhost|localhost.*|?|??) ;;
        *) printf 's%s(^|[^A-Za-z0-9_])%s([^A-Za-z0-9_]|$)%s\\1<host>\\2%sg\n' "$d" "$(esc_re "$h")" "$d" "$d";;
      esac
    done
    printf '%s\n' 's/([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}/xx:xx:xx:xx:xx:xx/g'
    printf '%s\n' 's/[A-Za-z0-9._%+-]+@[A-Za-z0-9._-]+/<user@host>/g'
    # (an address stands alone: not "OS1.0.26.0.ULIMIXM"; twice, as a pass
    # takes the character after an address)
    printf '%s\n' 's/(^|[^0-9A-Za-z.])([0-9]{1,3}\.){3}[0-9]{1,3}([^0-9A-Za-z.]|$)/\1ipv4\3/g'
    printf '%s\n' 's/(^|[^0-9A-Za-z.])([0-9]{1,3}\.){3}[0-9]{1,3}([^0-9A-Za-z.]|$)/\1ipv4\3/g'
    printf '%s\n' 's/(^|[^0-9A-Za-z:.])[0-9a-fA-F]{1,4}(:[0-9a-fA-F]{0,4}){3,7}([^0-9A-Za-z:]|$)/\1ipv6\3/g'
    printf '%s\n' 's/(^|[^0-9A-Za-z:.])[0-9a-fA-F]{1,4}(:[0-9a-fA-F]{0,4}){3,7}([^0-9A-Za-z:]|$)/\1ipv6\3/g'
  } > "$TMPD/mask.sed"
}
mask() { sed -E -f "$TMPD/mask.sed" 2>/dev/null; }
# cutc <bytes>: the first line of stdin cut to that many bytes, but never
# inside a UTF-8 character (LC_ALL=C: ${s:0:n} counts bytes)
cutc() {
  local s c n=$1
  IFS= read -r s || [ -n "$s" ] || return 0
  if [ ${#s} -gt "$n" ]; then
    while [ "$n" -gt 0 ]; do
      c=${s:$n:1}
      case $c in [$'\200'-$'\277']) n=$((n - 1));; *) break;; esac
    done
    s=${s:0:$n}
  fi
  printf '%s\n' "$s"
}
add_serial() {
  [ -n "$1" ] || return 0
  case " $SERIALS " in *" $1 "*) return 0;; esac
  SERIALS="$SERIALS $1"; build_mask
}

# logl <text>: into run-flash.log only (masked, with the time)
logl() {
  local ts; ts=$(date '+%H:%M:%S')
  if [ -n "$LOG" ]; then
    printf '%s\n' "$1" | mask | sed "s/^/$ts /" >> "$LOG" 2>/dev/null
  else
    LOGBUF="$LOGBUF$ts $1
"
  fi
}
# logf <file> <prefix>: a whole file into the log (masked)
logf() {
  [ -n "$LOG" ] && [ -f "$1" ] || return 0
  { tr -d '\r' < "$1" | mask | sed "s/^/$(date '+%H:%M:%S') $2| /"; } >> "$LOG" 2>/dev/null
}
# the progress dots of a wait end their line before the next message
nl_dots() { [ -n "$DOTS" ] && { printf '\n'; DOTS=; }; return 0; }
# on the screen and in the log: say (plain), step (cyan), warnm (yellow),
# errm (red), goodm (green), hintm (yellow, a tap on the phone: bell)
say()   { nl_dots; printf '%s\n' "$1"; logl "$1"; }
step()  { nl_dots; printf '%s%s%s\n' "$CC" "$1" "$C0"; logl "$1"; }
warnm() { nl_dots; printf '%s%s%s\n' "$CY" "$1" "$C0"; logl "$1"; }
errm()  { nl_dots; printf '%s%s%s\n' "$CR" "$1" "$C0"; logl "$1"; }
goodm() { nl_dots; printf '%s%s%s\n' "$CG" "$1" "$C0"; logl "$1"; }
bell()  { printf '\a'; }
hintm() { nl_dots; printf '%s%s%s\n' "$CY" "$1" "$C0"; logl "$1"; case $1 in '>>>'*) bell;; esac; }
dot()   { printf '.'; DOTS=1; }
# fill <text> [<key> <value>]...: the {key} places of a message
fill() {
  local s=$1 k v; shift
  while [ $# -ge 2 ]; do k=$1; v=$2; shift 2; s=${s//"{$k}"/$v}; done
  printf '%s' "$s"
}
# step_h <n> <text>: "Шаг N из M: ..." (cyan)
step_h() {
  echo
  if [ "$1" = "$STEPN" ]; then step "Шаг $1 из $STEPM (ещё раз): $2"; else step "Шаг $1 из $STEPM: $2"; fi
  STEPN=$1
}
# pcmd <template> [<key> <value>]...: a phone command with its placeholders filled
pcmd() {
  local t=$1 g= s; shift
  for s in $STORES; do g="$g $s/$BACKUP_NAME/*"; done
  fill "$t" BN "$BACKUP_NAME" LAST "$LAST_LOG" RLOG "$RLOG_NAME" W "$PH_WORK" STORE_GLOBS "${g# }" STORES "$STORES" "$@"
}

########################################################################
# MESSAGES (Russian; the same texts, in the same order, in run-flash.ps1).
# Tags: «ОШИБКА:» red, «ВНИМАНИЕ:» yellow, «ОК:» green; hints for the phone
# start with «>>> ». {key} places are filled by fill.

# --- start and files
M_BANNER="$BRAND, версия $VER"
M_LICENSE1='Лицензия MeruDevTools — LICENSE-flash.txt рядом со скриптом. Продолжая, вы принимаете её условия.'
M_LICENSE2='License: LICENSE-flash.txt (MeruDevTools License). By continuing you accept it.'
M_FOLDER='Папка флешера: {path}'
M_ZIP_FOUND='Найдено ядро v{ver}: {name}'
M_ZIP_SEVERAL='Найдено ядер: {n}. Выбрано самое новое — v{ver} ({name}).'
M_ZIP_SEVERAL_MENU='Выбрать другое — пункт 5 меню.'
M_ZIP_SEVERAL_CMD="Другой файл можно указать так: $LAUNCHER install <файл>"
M_ZIP_COPY='ОК: {name} — копия, которую браузер сохранил повторно («({k})» в имени); содержимое проверено: это ядро v{ver}.'
M_ZIP_NONE="Рядом с флешером нет файла ядра. Положите его в папку {path} (имя вида taoyao-6.12-vX.XX.zip — так его называет страница загрузки) и запустите флешер снова. Можно и указать файл: $LAUNCHER install <файл>."
M_ZIP_NEAR='Похожие файлы с другим именем: {list}. Флешер берёт только файлы с исходным именем taoyao-<серия>-v<версия>.zip (можно «(1)» в конце) — не переименовывайте ядро.'
M_ZIP_SKIPPED='ВНИМАНИЕ: {name} пропущен: {reason}'
M_ZIP_BROKEN='ОШИБКА: {name} не открывается как ZIP-архив — он повреждён или скачан не до конца. Скачайте его заново.'
M_ZIP_WRAPPER='ОШИБКА: {name} — архив-обёртка (так GitHub отдаёт файлы сборки): внутри лежит {inner}. Распакуйте его и положите {inner} рядом с флешером.'
M_ZIP_WRAP_ASK='{name} — архив-обёртка (так GitHub отдаёт файлы сборки): внутри лежит ядро {inner}. Распаковать его в папку {dir}? (Enter или Д — да, Esc или Н — нет)'
M_ZIP_UNWRAPPED='ОК: ядро распаковано: {path}'
M_ZIP_UNWRAP_FAIL='ОШИБКА: не удалось распаковать {inner} из {name} (мало места или архив повреждён).'
M_PICK_ZIP='Какой файл ядра взять? Нажмите цифру (Esc — назад):'
M_ZIP_NOTOURS='ОШИБКА: {name} — не zip ядра taoyao от MeruDevTools (в нём нет {entry}).'
M_ZIP_NOTTAOYAO='ОШИБКА: {name} — не для Xiaomi Mi 12 Lite (taoyao): в нём устройство «{dev}».'
M_ZIP_RENAMED='ОШИБКА: имя {name} говорит v{ver}, а внутри ядро {rel} (файл version: «{vline}»). Файл переименован или повреждён — скачайте ядро заново с официальной страницы.'
M_ZIP_KSU='ОШИБКА: имя {name} говорит: {want}, а внутри KernelSU «{ksu}». Файл переименован — скачайте ядро заново с официальной страницы.'
M_ZIP_NOVERSION='ОШИБКА: в {name} нет номера версии — это не выпускная сборка. Скачайте ядро с официальной страницы.'
M_ZIP_SHA_OK='ОК: контрольная сумма совпадает ({file}).'
M_ZIP_SHA_BAD='ОШИБКА: контрольная сумма {name} не совпадает с {file} — файл повреждён при скачивании. Скачайте его заново.'
M_ZIP_INFO1='Файл: {name} ({size})'
M_ZIP_INFO2='Ядро в файле: {rel}, KernelSU: {ksu}'
M_NO_UNZIP='ОШИБКА: не нашлось программы для чтения ZIP (unzip, python3 или bsdtar). Установите unzip: sudo apt install unzip (Debian, Ubuntu), sudo dnf install unzip (Fedora).'
M_BAD_ARG='ОШИБКА: непонятный параметр «{arg}».'
M_DROP_MANY='Указано несколько файлов; беру {name}.'
M_KEYS='Нажмите Enter (или Д) — да, Esc (или Н) — нет.'
M_KEYS_AMBIG='Непонятно: на этой клавише и Y, и Н. Нажмите Enter (или Д) — да, Esc (или Н) — нет.'
M_NEED_TTY='ОШИБКА: флешер работает только в окне терминала (он задаёт вопросы).'
M_LOCKED='ОШИБКА: флешер уже запущен в другом окне. Закройте то окно или дождитесь его окончания.'
M_NOT_FOUND='ОШИБКА: файл или папка «{path}» не найдены.'

# --- phone search
M_WAIT_NONE1='Телефон не найден. Проверьте:
  • телефон включён и разблокирован;
  • кабель подключён прямо к компьютеру и передаёт данные (некоторые кабели только заряжают);
  • на телефоне включена «Отладка по USB». Как включить: Настройки → «О телефоне» → 7 раз нажмите на «Версия ОС» (HyperOS) или «Номер сборки» (crDroid, Evolution X); затем откройте «Для разработчиков» (HyperOS: «Расширенные настройки» → «Для разработчиков»; crDroid, Evolution X: «Система» → «Для разработчиков») и включите «Отладка по USB»;
  • если телефон в рекавери: включите там ADB (LineageOS: Advanced → Enable ADB) или выберите Apply update → Apply from ADB;
  • если телефон в режиме fastboot (на экране заяц или надпись FASTBOOT): удерживайте кнопку питания около 15 секунд — он перезагрузится.'
M_WAIT_MAC='Если Mac спросит «Разрешить подключение аксессуара?», нажмите «Разрешить».'
M_WAIT_NONE2='Жду подключения телефона… (до {min} мин)'
M_UNAUTH='Телефон подключён, но этот компьютер ещё не разрешён. На экране телефона появится вопрос «Разрешить отладку по USB?»: поставьте галочку «Всегда разрешать с этого компьютера» и нажмите «Разрешить» (или «OK»). Если вопроса нет — разблокируйте экран, отключите и снова подключите кабель. Не помогло — в разделе «Для разработчиков» отзовите разрешения отладки по USB (пункт называется примерно «Отозвать авторизацию отладки по USB») и подключите кабель снова.'
M_UNAUTH_REC='Если телефон сейчас не в системе, а в рекавери: рекавери «user»-сборки показывает компьютеру «unauthorized» и не умеет спрашивать разрешение — по ADB флешер с ним работать не сможет. Варианты: 1) установить ядро из системы с root (Magisk, KernelSU или SukiSU-Ultra с доступом для Shell) — флешер выберет этот способ сам; 2) временно поставить рекавери LineageOS (официальные сборки пускают ADB) или TWRP / OrangeFox. Телефон можно перезагрузить: Reboot system now — и запустить флешер снова.'
M_UNAUTH_INREC='Рекавери показывает компьютеру статус «unauthorized». Если на экране телефона есть вопрос о разрешении отладки — нажмите «Разрешить». Жду…'
M_AUTHORIZING='Телефон подключается…'
M_OFFLINE='Телефон виден, но не отвечает. Отключите и снова подключите кабель. Если не поможет — выключите и снова включите «Отладку по USB».'
M_NOPERM='Нет прав на доступ к телефону по USB. Установите правила udev для Android (Debian/Ubuntu: sudo apt install android-sdk-platform-tools-common; Fedora: sudo dnf install android-tools; Arch: sudo pacman -S android-udev), отключите и снова подключите кабель.'
M_FASTBOOT='Телефон в режиме fastboot или загрузчика. Флешер с ним не работает: удерживайте кнопку питания около 15 секунд, чтобы перезагрузить телефон.'
M_SERIALGONE='ВНИМАНИЕ: переменная ANDROID_SERIAL указывает на устройство, которого сейчас нет. Подключите его или удалите эту переменную.'
M_MULTI_PICKED='Подключено несколько устройств; выбран Xiaomi Mi 12 Lite.'
M_MULTI_ASK='Подключено несколько устройств. Нажмите цифру нужного (Esc — выход):'
M_NOT_TAOYAO='ОШИБКА: подключено устройство «{model}» ({dev}), а флешер — только для Xiaomi Mi 12 Lite (taoyao). Ничего не делаю.'
M_PHONE_NOANSWER='ОШИБКА: телефон не ответил ({line}). Отключите и снова подключите кабель и запустите флешер снова.'
M_WAIT_BOOT='Телефон ещё загружается — жду…'
M_UNLOCK_SCREEN='>>> Разблокируйте экран телефона: до первой разблокировки его память недоступна.'
M_PHONE='Телефон: Xiaomi Mi 12 Lite ({model}), Android {rel}, прошивка {rom}'
M_NOW_ON='Сейчас на телефоне: {release}, будет установлено: v{ver}'
M_NOW_ON_REC=' (по данным рекавери)'
M_NOW_ON_B='Сейчас на телефоне: {release}'
M_NOW_ON_COPY=' (по копии слота)'
M_OLD_UNNUMBERED='На телефоне сборка 6.12 без номера в имени ядра (0.17 или старше).'
M_BL_OK='Загрузчик разблокирован.'
M_BL_UNKNOWN='Состояние загрузчика телефон не сообщает — установщик проверит его сам.'
M_BL_PROPS_LOCKED='ВНИМАНИЕ: по свойствам системы загрузчик заблокирован. На кастомных прошивках это часто подмена (для Play Integrity). Установщик проверит загрузчик сам и ничего не запишет, если он действительно заблокирован.'
M_BL_LOCKED='ОШИБКА: загрузчик телефона заблокирован ({vbs}). Заблокированный загрузчик не примет изменённые boot, vendor_boot и dtbo: телефон покажет «The system has been destroyed», и вернуть его можно будет только через EDL. Сначала разблокируйте загрузчик. Ничего не записано.'
M_SLOT='Активный слот: {slot}'
M_NO_SLOT='ОШИБКА: не удалось узнать активный слот телефона.'
M_BAT_OK='Заряд батареи: {n} %'
M_BAT_STOP='ОШИБКА: заряд батареи {n} % — слишком мало для установки. Зарядите телефон хотя бы до 30 % и запустите флешер снова.'
M_BAT_WARN_ASK='ВНИМАНИЕ: заряд батареи {n} %. Лучше зарядить телефон до 30 % и больше. Продолжить? (Enter или Д — да, Esc или Н — нет)'
M_BAT_UNKNOWN='Заряд батареи узнать не удалось — убедитесь, что он не ниже 30 %.'
M_DATA_SPACE='ОШИБКА: во внутренней памяти телефона свободно {n} МБ, а для установки нужно около 1,5 ГБ (копия разделов и рабочие файлы). Освободите место и запустите флешер снова.'
M_PC_SPACE='ОШИБКА: на диске компьютера свободно {n} МБ, а для копии разделов нужно около {m} МБ. Освободите место (или перенесите папку флешера на другой диск).'
M_BASE_FALLBACK='ВНИМАНИЕ: не удаётся создать папку для копий и журнала в «{here}»: нет прав на запись. Копии и журнал будут в «{base}». Лучше перенести папку флешера, например, на Рабочий стол.'

# --- root and the way
M_ROOT_WAIT='Жду ответа на запрос прав root на экране телефона…'
M_ROOT_RETRY='Запрос прав root отклонён или остался без ответа. Magisk спрашивает на экране — нажмите «Разрешить» (лучше «навсегда»); SukiSU-Ultra, KernelSU и APatch не спрашивают — доступ для Shell включается в их приложении. Пробую ещё раз через 5 секунд… (попытка {n} из 3)'
M_ROOT_OK='Права root для adb: есть.'
M_ROOT_NONE='Права root для adb: нет (su для adb не найден).'
M_ROOT_NONE2='Если root на телефоне есть, включите в приложении root доступ для Shell (README-flash-ru.txt, раздел 2) и запустите флешер снова — тогда он всё сделает прямо из системы.'
M_ROOT_MGR='На телефоне установлено приложение {name}. Такие менеджеры не показывают запрос на экране, а прячут su от приложений, которым доступ не выдан, — поэтому su для adb не виден. Если в приложении написано, что root работает, включите доступ для Shell:'
M_ROOT_MGR_MAGISK='На телефоне есть приложение Magisk, но su для adb не найден. Проверьте на главном экране Magisk, что он установлен, и включите доступ для Shell:'
M_ROOT_MGR_ASK='Enter или Д — проверить ещё раз (сначала включите доступ для Shell), Esc или Н — {no}.'
M_ROOT_HOW='  • SukiSU-Ultra или KernelSU: откройте приложение-менеджер → вкладка «Суперпользователь» → в меню ⋮ включите показ системных приложений → найдите «Shell» (com.android.shell) → включите доступ.
  • APatch: приложение APatch → вкладка «SuperUser» → в меню ⋮ «Показать системные приложения» → найдите «Shell» (com.android.shell) → включите доступ.
  • Magisk: Magisk → Настройки → «Доступ суперпользователя» → «Приложения и ADB».'
M_ROOT_DENIED_ASK='Root для Shell не выдан. Enter или Д — попробовать ещё раз (разрешите запрос на телефоне или включите доступ для Shell в приложении root), Esc или Н — {no}.'
M_ROOT_NO_B='устанавливать через рекавери'
M_ROOT_NO_A='выйти'
M_ROOT_NO_R='возвращать образы через рекавери'
M_ROOT_NO_NR='без root (варианты ниже)'
M_WAY_A='Способ: установка из системы (root через USB) — за один проход; копия разделов сохранится во внутренней памяти телефона и потом на компьютере.'
M_WAY_B_NOROOT='Способ: установка через рекавери (adb sideload), потому что root для adb на телефоне нет. Для LineageOS / crDroid / Evolution X — в два прохода: сначала только копия разделов, потом запись.'
M_WAY_B_REC='Способ: установка через рекавери (adb sideload) — телефон уже в рекавери.'
M_WAY_B_FORCED='Способ: установка через рекавери (как вы выбрали).'
M_WAY_B_REC_BAK='Копию разделов сделает рекавери (adb sideload, только шаг 1 установщика) — телефон уже в рекавери.'
M_STOCK_NOROOT='В стоковой HyperOS рекавери Xiaomi не умеет устанавливать такие zip, а root для adb нет. Варианты: получить root (Magisk, KernelSU или SukiSU-Ultra с доступом root для Shell) — тогда флешер установит ядро прямо из системы; или установить TWRP / OrangeFox. У вас установлен TWRP или OrangeFox? (Enter или Д — да, перезагрузить в него; Esc или Н — нет, выйти)'
M_A_NEEDS_ROOT='ОШИБКА: для установки из системы нужен root для adb (Shell).'
M_A_NEEDS_SYSTEM="ОШИБКА: телефон в рекавери. Для install-system загрузите систему (Reboot system now) или запустите флешер с install-recovery."
M_REBOOT_REC_ASK='Перезагрузить телефон в рекавери для установки? (Enter или Д — да, Esc или Н — нет)'
M_REBOOT_REC_ASK_R='Перезагрузить телефон в рекавери для возврата образов? (Enter или Д — да, Esc или Н — нет)'
M_REBOOT_REC_ASK_B='Перезагрузить телефон в рекавери, чтобы сделать копию разделов? (Enter или Д — да, Esc или Н — нет)'
M_REBOOTING_REC='Перезагружаю телефон в рекавери…'
M_NO_REBOOT='ОШИБКА: телефон не перезагружается по команде adb. Войдите в рекавери вручную: выключите телефон, затем зажмите громкость вверх + питание до логотипа. Потом запустите флешер снова. Ничего не записано.'
M_BOOTED_NOT_REC='ОШИБКА: телефон загрузился в систему, а не в рекавери. Войдите в рекавери вручную: выключите телефон, затем зажмите громкость вверх + питание до логотипа. Потом запустите флешер снова.'

# --- recovery
M_REC_KIND='Рекавери: {kind}'
M_NR_WHY='ВНИМАНИЕ: ADB этого рекавери работает без прав root (uid {uid}) — так устроены «user»-сборки рекавери LineageOS, crDroid и Evolution X. Root от SukiSU-Ultra, KernelSU или Magisk есть только в загруженной системе, а в рекавери его нет, даже с ядром KernelSU. Без root флешер не может прочитать здесь журнал установщика и забрать копию разделов.'
M_NR_FORCED='Установить через рекавери, как вы выбрали (install-recovery), не получится: в это рекавери флешер заглянуть не может.'
M_NR_NOTHING='На телефоне ничего не менялось.'
M_NR_RAMSEEN='В этом сеансе рекавери установщик уже запускали: в памяти телефона есть копия слота {slot} от прошлой отправки, поэтому следующая отправка может сразу записать ядро.'
M_NR_P1_OLD='Проход 1 ядро не записал: телефон загрузился с прежним ядром {rel}.'
M_NR_PASS1='Проход 1 установщика уже отправлен, но внутренняя память в этом рекавери закрыта: установщик мог сделать только копию слота в памяти телефона (на экране телефона — «NOT INSTALLED YET - step 1 of 2»), ядро не записано.'
M_NR_PASS1_W='Проход 1 установщика уже отправлен, а в этом рекавери открыта внутренняя память: установщик мог сразу записать ядро. Посмотрите на экран телефона: «Done: … written and read back.» — ядро установлено; «NOT INSTALLED YET - step 1 of 2» — записи не было; «Aborting...» — установщик остановился.'
M_NR_BACKUP='Сделать только копию разделов через такое рекавери нельзя: забрать её на компьютер флешер отсюда не может.'
M_NR_Q1_I='Лучший путь: перезагрузить телефон в систему и установить ядро оттуда, с root для Shell через USB, за один проход — тогда копия разделов сохранится и на компьютере. Перезагрузить телефон в систему? (Enter или Д — да, Esc или Н — нет)'
M_NR_Q1_I2='Лучший путь — из системы, за один проход (копия разделов сохранится и на компьютере), но root для adb там флешер не нашёл. Если root на телефоне есть, после перезагрузки включите доступ для Shell — флешер покажет как и проверит ещё раз. Перезагрузить телефон в систему? (Enter или Д — да, Esc или Н — нет)'
M_NR_Q1_B='Копию разделов флешер может сделать из системы, с root для Shell через USB. Перезагрузить телефон в систему? (Enter или Д — да, Esc или Н — нет)'
M_NR_Q1_R='Лучший путь, если система на телефоне загружается: перезагрузить телефон в систему и вернуть образы оттуда, с root для Shell через USB, — тогда флешер проверит слот по sha256. Перезагрузить телефон в систему? (Enter или Д — да, Esc или Н — нет; система не загружается — Н)'
M_NR_REBOOTING='Перезагружаю телефон в систему…'
H_NR_REBOOT_SELF='>>> Телефон не перезагрузился по команде adb: выберите на телефоне Reboot system now.'
M_NR_NOSYS='ОШИБКА: телефон не появился в системе за {t}. Если он загрузился — запустите флешер снова. Если система не загружается — войдите в рекавери (выключите телефон, затем зажмите громкость вверх + питание до логотипа), включите Advanced → Enable ADB и запустите флешер снова; на вопрос «Перезагрузить телефон в систему?» ответьте Н.'
M_NR_ROOT_ASK='Enter или Д — проверить root ещё раз (сначала включите доступ для Shell), Esc или Н — без root (варианты ниже).'
M_NR_END='Root для adb в системе нет, а ADB рекавери работает без root — так флешер ядро не установит. Варианты: включите root для Shell (как — выше) и запустите флешер снова; поставьте рекавери TWRP / OrangeFox (их ADB работает с root); или установите вручную — тогда копия разделов, которую сделает установщик, останется только в памяти телефона и пропадёт при перезагрузке. Вручную: в рекавери Apply update → Apply from ADB, на компьютере {term} введите эту команду, затем на телефоне снова Apply update → Apply from ADB и ту же команду ещё раз, без перезагрузки:'
M_NR_END_R='Root для adb в системе нет, а ADB рекавери работает без root — так флешер образы не вернёт. Варианты: включите root для Shell (как — выше) и запустите флешер снова; поставьте рекавери TWRP / OrangeFox (их ADB работает с root); или верните вручную: в рекавери Apply update → Apply from ADB, затем на компьютере {term}:'
M_NR_END_B='Root для adb в системе нет, а ADB рекавери работает без root — так флешер копию разделов не сделает. Варианты: включите root для Shell (как — выше) и запустите флешер снова; или поставьте рекавери TWRP / OrangeFox (их ADB работает с root).'
M_Q2_ASK='Можно и через Apply from ADB: флешер отправит ядро, а итог проверит сам — после перезагрузки, по версии работающего ядра. Путь назад — проверенная копия на компьютере: {line}. {go} (Enter или Д — да, Esc или Н — нет)'
M_Q2_ASK_FPR='Можно и через Apply from ADB: флешер отправит ядро, а итог проверит сам — после перезагрузки, по версии работающего ядра. Путь назад — копия на компьютере, совпавшая с прошивкой только по отпечатку: {line}. {go} (Enter или Д — да, Esc или Н — нет)'
M_Q2_FPRONLY='ВНИМАНИЕ: копия для пути назад совпала с прошивкой только по отпечатку (fingerprint): {why}. Модули для Play Integrity подменяют отпечаток, поэтому совпадение не доказывает, что сборка та же. Если прошивку обновляли после этой копии, restore-zip откажется записывать её образы, и вернуться можно будет только образами из самой прошивки или перепрошивкой. Надёжнее путь через систему с root для Shell или рекавери TWRP / OrangeFox: там копию разделов сделает установщик.'
M_Q2_GO='Установить так?'
M_Q2_GO_A='Перезагрузить телефон в рекавери и установить так?'
M_Q2_NONE='Через Apply from ADB флешер не устанавливает: копия разделов, которую сделает установщик, пропадёт при перезагрузке, а проверенной копии слота {slot} этой прошивки на компьютере нет — пути назад не было бы.'
M_Q2_NONE_OPT='Варианты: путь через систему с root для Shell или рекавери TWRP / OrangeFox (их ADB работает с root).'
M_Q2_SAMEVER='Через Apply from ADB флешер не устанавливает: в слоте уже ядро {rel}, и проверить установку по версии работающего ядра нельзя.'
M_Q2_WARN='ВНИМАНИЕ: копия разделов, которую сделает установщик, останется только в памяти телефона и пропадёт при перезагрузке. Путь назад — копия на компьютере {path}: пункт {n} меню флешера или Apply from ADB с её restore-zip.'
M_Q2_WARN_D='ВНИМАНИЕ: копию разделов, которую сделает установщик, флешер в этот раз на компьютер не заберёт (если она окажется во внутренней памяти, в папке taoyao-6.12-backup, — заберёт при следующем запуске из системы). Путь назад — копия на компьютере {path}: пункт {n} меню флешера или Apply from ADB с её restore-zip.'
M_Q2_WARN_1='ВНИМАНИЕ: копия разделов, которую установщик уже сделал, есть только в памяти телефона и пропадёт при перезагрузке. Путь назад — копия на компьютере {path}: пункт {n} меню флешера или Apply from ADB с её restore-zip.'
M_Q2_SCREEN_ASK='Что на экране телефона? Строка «NOT INSTALLED YET - step 1 of 2» — нажмите Enter или Д: флешер отправит ядро ещё раз, и оно запишется. Другая («Done: … written and read back.», «Aborting...») — Esc или Н: перезагрузка и проверка.'
M_Q2_PASS1_ASK='Что на экране телефона после прохода 1? Строка «NOT INSTALLED YET - step 1 of 2» — нажмите Enter или Д: флешер отправит ядро ещё раз, и оно запишется. Другая («Done: … written and read back.», «Aborting...») — Esc или Н: без отправки, сразу перезагрузка и проверка.'
M_Q3_ASK='Можно и через Apply from ADB: флешер отправит restore-zip этой копии (он сам проверит телефон, слот и образы), а итог проверит после перезагрузки, по версии работающего ядра. {go} (Enter или Д — да, Esc или Н — нет)'
M_Q3_GO='Отправить?'
M_Q3_GO_A='Перезагрузить телефон в рекавери и отправить?'
M_Q3_NOT='Через Apply from ADB этот возврат флешер не предлагает: {why} — проверить его по версии работающего ядра нельзя.'
M_Q3_WHY_SLOT='копия снята со слота {s1}, а телефон работает со слота {s2}'
M_Q3_WHY_SAME='в слоте уже ядро {rel}'
H_Q_REBOOT='>>> На телефоне: Reboot system now. Флешер дождётся системы и проверит версию ядра.'
M_Q_BOOT_WAIT='Жду загрузки системы (до {min} мин). Esc или Н — не ждать.'
M_Q_OK='ОК: телефон загрузился с ядром {rel} — установлено, проверено по версии работающего ядра.'
M_Q3_OK='ОК: телефон загрузился с ядром {rel} — возвращено, проверено по версии работающего ядра.'
M_Q_OLD='ОШИБКА: телефон загрузился со старым ядром {rel} — ядро v{ver} не записано. Причину установщик показывал на экране рекавери (на английском) до перезагрузки. Что дальше: включите root для Shell — тогда флешер установит ядро из системы; или поставьте рекавери TWRP / OrangeFox.'
M_Q3_OLD='ОШИБКА: телефон загрузился с прежним ядром {rel} — образы копии не вернулись. Причину restore-zip показывал на экране рекавери (на английском) до перезагрузки; чаще всего прошивка в слоте с тех пор изменилась (обновление, Magisk) и эти образы к ней не подходят. Что дальше: включите root для Shell и запустите флешер снова — он сравнит слот с копией. Если прошивку меняли, не записывайте эти образы и через fastboot — перепрошейте прошивку.'
M_Q_OTHER='ВНИМАНИЕ: телефон загрузился с ядром {got} (слот {slot}), а ожидалось {want} в слоте {wslot}{why}. Итог не подтверждён. Запустите флешер снова из системы — он покажет, что в слоте; путь назад — копия на компьютере {path}.'
M_Q_NOBOOT='ВНИМАНИЕ: телефон не загрузился в систему за {t}. Если он остановился в fastboot или не загружается — верните образы из копии на компьютере (как — в итоге ниже).'
M_Q3_NOBOOT='ВНИМАНИЕ: телефон не загрузился в систему за {t}. Если он остановился в fastboot или не загружается, а прошивку после этой копии не меняли — запишите её образы через fastboot (команды ниже); если меняли — перепрошейте прошивку.'
M_Q_OTHER_SLOT=' — возможно, слот {wslot} не загрузился и телефон сам переключился на другой'
M_Q_SKIP='Проверка пропущена, итог не подтверждён. Посмотрите сами: Настройки → О телефоне → Версия ядра (crDroid, Evolution X: О телефоне → Версия Android → Версия ядра; HyperOS: О телефоне → Все параметры → Версия ядра); должно быть {rel}.'
M_A_BACKUP_FAIL='ОШИБКА: прочитать разделы слота {slot} на телефоне не удалось ({line}). Ничего не записано.'
M_RZ_PC_NOTOOL='ВНИМАНИЕ: restore-zip для копии не сделан — на компьютере нет программы для создания ZIP (zip, python3 или bsdtar). Образы для fastboot сохранены: {path}.'
M_RZ_PC_FAIL='ВНИМАНИЕ: restore-zip для копии сделать не удалось (подробности — в run-flash.log). Образы для fastboot сохранены: {path}.'
M_A_BACKUP_PULLFAIL='ОШИБКА: копию разделов не удалось сохранить на компьютере ({what}). На телефоне ничего не записано, копии там не осталось — запустите флешер снова.'
M_NO_SHELL_CHECKS='Телефон сразу в режиме Apply from ADB: заглянуть в рекавери флешер пока не может. Модель, загрузчик, слот и место проверит сам установщик и ничего не запишет, если что-то не так (заряд батареи проверен в системе: {n}).'
M_SIDELOAD_UNKNOWN='Телефон уже ждёт файл (Apply from ADB). Флешер сначала должен заглянуть в рекавери: если в этом сеансе уже делали шаг 1, следующая отправка сразу запишет ядро.'
M_SIDELOAD_UNKNOWN_B='Телефон уже ждёт файл (Apply from ADB). Флешер сначала должен заглянуть в рекавери: только так он узнает, не запишет ли установщик ядро сразу (тогда «только копию» здесь сделать нельзя).'
M_SIDELOAD_UNKNOWN_R='Телефон уже ждёт файл (Apply from ADB). Флешер сначала должен заглянуть в рекавери: проверить телефон и запомнить слот, чтобы потом проверить возврат.'
H_LEAVE_SIDELOAD='>>> На телефоне: выйдите из Apply from ADB (стрелка «Назад» вверху экрана) и включите Advanced → Enable ADB (TWRP / OrangeFox: кнопка Cancel внизу экрана).'
H_ENTER_SIDELOAD='>>> Если на телефоне меню рекавери: выберите Apply update → Apply from ADB (TWRP: Advanced → ADB Sideload и проведите по полосе).'
H_APPLY_LOS='>>> На телефоне: Apply update → Apply from ADB. Дальше флешер всё сделает сам.'
H_APPLY_LOS2='>>> На телефоне снова: Apply update → Apply from ADB. Не перезагружайте телефон: копия слота пока в его памяти.'
H_APPLY_Q='>>> На телефоне: Apply update → Apply from ADB.'
H_SIDELOAD_TWRP='>>> На телефоне: Advanced → ADB Sideload → проведите по полосе внизу (OrangeFox: меню → ADB & Sideload).'
H_ADB_LOS='>>> На телефоне: Advanced → Enable ADB — чтобы флешер прочитал журнал установщика и забрал копию разделов.'
H_ENABLE_ADB='>>> На телефоне в рекавери: Advanced → Enable ADB — чтобы флешер проверил телефон перед установкой.'
H_ENABLE_ADB_B='>>> На телефоне: Advanced → Enable ADB — чтобы флешер проверил рекавери перед копией (TWRP / OrangeFox: ничего нажимать не нужно).'
H_ENABLE_ADB_R='>>> На телефоне: Advanced → Enable ADB — чтобы флешер проверил слот перед возвратом образов (TWRP / OrangeFox: ничего нажимать не нужно).'
H_TWRP_WAIT='>>> Телефон должен загрузиться в TWRP / OrangeFox. Если на экране меню рекавери Xiaomi (Reboot, Wipe Data, подключение к компьютеру) — оно не умеет устанавливать такие zip: выберите Reboot → Reboot to System.'
H_REPLUG='>>> Подключите кабель снова и не перезагружайте телефон (в рекавери LineageOS, если ADB выключился: Advanced → Enable ADB).'
H_REPLUG_A='>>> Подключите кабель снова.'
H_SIGNATURE='>>> Если телефон спросит «Signature verification failed. Install anyway?» — выберите Yes.'
H_STEP1_ERROR_OK='Внимание: после этого прохода рекавери покажет ошибку («Installation aborted», статус 1) — так и задумано: это шаг 1, ничего не записано. Не перезагружайте телефон — флешер продолжит сам.'
H_STEP1_ERROR_FRESH='Внимание: после этого прохода рекавери LineageOS / crDroid / Evolution X покажет ошибку («Installation aborted», статус 1), а TWRP / OrangeFox без открытой внутренней памяти — «Updater process ended with ERROR: 1» и «Error installing zip file» — так и задумано: это шаг 1, ничего не записано. TWRP / OrangeFox с открытой внутренней памятью сразу установит ядро. Не перезагружайте телефон — флешер продолжит сам.'
H_STEP1_ERROR_TWRP='Внимание: после этого прохода TWRP / OrangeFox покажет ошибку («Updater process ended with ERROR: 1», «Error installing zip file») — так и задумано: это шаг 1, ничего не записано. Не перезагружайте телефон — флешер продолжит сам.'
M_MAYBE_XIAOMI_REC='Если на телефоне меню рекавери Xiaomi (Reboot, Wipe Data, режим подключения к компьютеру) — оно не умеет устанавливать такие zip. Ничего не записано. Выберите Reboot → Reboot to System.'
M_XIAOMI_REC_WAYS='Варианты: получить root (Magisk, KernelSU или SukiSU-Ultra с доступом root для Shell) — тогда флешер установит ядро прямо из системы; или установить TWRP / OrangeFox.'
M_MAYBE_XIAOMI_REC_W="$M_MAYBE_XIAOMI_REC $M_XIAOMI_REC_WAYS"
M_REC_UNAUTH='ОШИБКА: рекавери не пускает этот компьютер по ADB (статус unauthorized): это «user»-сборка рекавери, она не умеет спрашивать разрешение. Без ADB флешер не может забрать копию разделов, а без копии на компьютере ядро не записывается. Ничего не записано. Варианты: 1) установить ядро из системы с root (Magisk, KernelSU или SukiSU-Ultra с доступом для Shell) — флешер выберет этот способ сам; 2) временно поставить рекавери LineageOS (официальные сборки пускают ADB) или TWRP / OrangeFox; 3) заранее сохранить boot.img, vendor_boot.img и dtbo.img своей прошивки из её payload.bin. Телефон можно перезагрузить: Reboot system now.'
M_REC_UNAUTH_AFTER='ОШИБКА: рекавери не пускает этот компьютер по ADB (статус unauthorized). Флешер не может проверить, чем закончилась установка. Не перезагружайте телефон и посмотрите на его экран: «Done: … written and read back.» — ядро установлено; «NOT INSTALLED YET - step 1 of 2» — ничего не записано (копию из памяти рекавери флешер забрать не может, телефон можно перезагрузить: Reboot system now); «Aborting...» — установщик остановился.'
M_RAM_REUSE='В памяти рекавери уже есть копия слота {slot} от шага 1 в этом сеансе: {dir}. Установщик её использует: следующая отправка сразу запишет ядро.'
M_RAM_REUSE_PC='Эта копия уже на компьютере: {path}'
M_RAM_NOTE_ONPC='Копия из памяти рекавери уже на компьютере и проверена: {path} — забирать её вручную не нужно.'
M_RAM_REUSE_B='В памяти рекавери уже есть копия слота {slot} от шага 1 в этом сеансе: {dir}. Отправлять ничего не нужно.'
M_RAM_OLD='В памяти рекавери есть копия слота {slot} ({dir}), но слот с тех пор изменился. Сохраняю её на компьютер; установщик сделает новую копию.'
M_ONEPASS='В этом рекавери (TWRP / OrangeFox) открыта внутренняя память: установщик сохранит копию разделов в /sdcard/{BN} и сразу установит ядро — за один проход. Потом флешер заберёт копию на компьютер.'
M_ALREADY_DONE='В этом сеансе рекавери ядро v{ver} уже установлено (так пишет журнал установщика). Ставить ещё раз не нужно.'
M_NEED_LOG_FIRST='Подождите: сначала флешер должен прочитать журнал прошлой отправки.'
M_REBOOTED_AFTER_STEP1='ОШИБКА: телефон перезагрузился после шага 1 — копия из памяти рекавери пропала. Ничего не записано. Запустите флешер снова.'
M_REBOOTED_UNKNOWN='ВНИМАНИЕ: телефон перезагрузился сразу после установки — флешер не успел прочитать её итог. Проверьте: Настройки → О телефоне → Версия ядра (должно быть {rel}). Если телефон не загружается — см. «Как вернуться» ниже.'
M_AK3_EARLY='ОШИБКА: установщик остановился в самом начале, до своих проверок ({line}). Ничего не записано.'
M_RETRY='Передача прервалась, установщик не запускался — ничего не записано. Повторяю (попытка {n} из {max}).'
M_TRIES_OUT='ОШИБКА: файл не удалось передать на телефон {max} раза. Ничего не записано. Попробуйте другой кабель и другой порт USB (без разветвителя) и запустите флешер снова.'
M_TRIES_OUT_Q='ОШИБКА: файл не удалось передать на телефон {max} раза. Прошлая отправка могла уже записать ядро — итог не подтверждён. Перезагрузите телефон (Reboot system now) и посмотрите версию ядра (должно быть {rel}); если телефон не загружается — верните образы из копии на компьютере (как — в итоге ниже).'
M_TRIES_OUT_W='ОШИБКА: файл не удалось передать на телефон {max} раза, а итог последней попытки неизвестен. Не перезагружайте телефон и посмотрите на его экран: «Done: … written and read back.» — ядро установлено; «Aborting...» — нет.'
M_STEP1_AGAIN='Установщик не нашёл копию из шага 1 (рекавери, видимо, перезапускался) и сделал новую копию — ничего не записано. Сохраняю её и повторяю запись.'
M_ROUNDS_OUT='ОШИБКА: копия из шага 1 снова пропала. Не перезапускайте рекавери между шагами и запустите флешер снова.'
M_UNCONFIRMED='ОШИБКА: не удалось подтвердить итог по журналу установщика ({what}). Телефон оставьте в рекавери и не перезагружайте. На экране телефона: «Done: … written and read back.» — ядро установлено; «NOT INSTALLED YET - step 1 of 2» — записи не было; «Aborting...» — установщик остановился. Приложите к сообщению на форуме файл {log}.'
M_UNCONFIRMED_A='ОШИБКА: не удалось подтвердить итог по журналу установщика ({what}). Не перезагружайте телефон. Подождите несколько минут и запустите флешер снова: он прочитает итог установки на телефоне. Приложите к сообщению на форуме файл {log}.'
M_SLOT_SAME='ОК: слот {slot} не изменился: sha256 boot, vendor_boot и dtbo совпадают с копией на компьютере — ничего не записано.'
M_SLOT_HALF='ОШИБКА: слот {slot} уже не такой, как копия на компьютере (sha256 разделов не совпадает): установщик остановился на середине записи, слот может не загрузиться. Не перезагружайте телефон. Копия разделов до установки: {path}.'
M_SLOT_CHANGED='ОШИБКА: установщик написал, что ничего не записал, но слот {slot} уже не такой, как копия на компьютере (sha256 разделов не совпадает). Флешер больше ничего не отправляет и эту копию как стоковую не сохраняет. Не перезагружайте телефон. Копия разделов до установки: {path}.'
M_SLOT_UNREAD='ОШИБКА: флешер не смог прочитать разделы слота {slot}, чтобы убедиться, что они не менялись, и поэтому не отправляет файл ещё раз. Телефон оставьте в рекавери и не перезагружайте. Приложите к сообщению на форуме файл {log}.'
M_PULL_LOST='Связь с телефоном пропала во время копирования ({what}). Подключите кабель снова — флешер дождётся телефона и продолжит копирование.'
M_PULL_LOST_FAIL='ОШИБКА: копию разделов не удалось забрать на компьютер: связь с телефоном пропадала {n} раза. Ничего не записано. Не перезагружайте телефон (копия пока может быть только в его памяти); попробуйте другой кабель и порт USB (без разветвителя) и запустите флешер снова — он найдёт копию и продолжит.'
M_SENDING_SL='Отправляю {what}: {pct} %'
M_SENT_SL='Отправлено: {what}.'
M_INSTALLING_REC='Установщик работает на телефоне — жду его окончания…'
M_ONEPASS_UNPREDICTED='ОК: установщик сохранил копию во внутренней памяти и записал ядро за один проход.'

# --- results
M_STEP1_OK='ОК: шаг 1 из 2 пройден: копия слота {slot} сделана, ничего не записано.'
M_DONE='ОК: ядро v{ver} установлено: boot{slot}, vendor_boot{slot} и dtbo{slot} записаны и проверены установщиком.'
M_ABORT_CLEAN='Установщик остановился, ничего не записано.'
M_ROLLED_BACK='Установщик остановился после начала записи и вернул исходные образы: слот {slot} такой же, как до установки.'
M_DIRTY='ОШИБКА: установщик не смог вернуть исходные образы — слот {slot} сейчас наполовину {series} и НЕ ЗАГРУЗИТСЯ. Не перезагружайте телефон. Копия разделов на компьютере: {path}.'
M_RESCUE_ASK="Попробовать сейчас же вернуть слот restore-zip'ом из этой копии, не перезагружая телефон? (Enter или Д — да, Esc или Н — нет)"
M_RESCUED='ОК: исходные образы снова в слоте {slot} (проверено по sha256).'
M_IPA_HINT='ВНИМАНИЕ: установщик не узнал прошивку и включил режим IPA для Evolution X / crDroid. Только если у вас стоковая HyperOS или прошивка с vendor от Xiaomi (иначе может не работать точка доступа): в рекавери до шага 2, пока она пускает ADB, выполните в другом окне {cmd} shell touch /tmp/taoyao-ipa-stock; при установке из системы или в TWRP / OrangeFox с открытой памятью положите пустой файл taoyao-ipa-stock во внутреннюю память (/sdcard). Затем установите ядро (ещё раз). Подробно — README-flash-ru.txt, раздел 9.'
M_PREV_RZ='На телефоне есть итог прошлого возврата образов: {what}.'
M_PREV_RZ_OK='образы возвращены'
M_PREV_RZ_FAIL='возврат не выполнен'
M_UNC_PASS_W='ВНИМАНИЕ: этот проход мог сразу записать ядро (TWRP / OrangeFox с открытой внутренней памятью или рекавери с открытой /data), поэтому «ничего не записано» здесь сказать нельзя.'
# (the ways back typed by hand: where, and a note for fastboot on Linux)
M_TERM='в Терминале'
M_BACK_SIDELOAD='  • вручную в рекавери: Apply update → Apply from ADB (TWRP: Advanced → ADB Sideload), затем на компьютере {term}:'
M_BACK_FB='  • если телефон не загружается: выключите его, зажмите Vol- и Power (режим fastboot) и на компьютере {term} по очереди:'
M_BACK_UDEV='    (Linux: если fastboot пишет «no permissions» или «waiting for any device», нужны правила udev — README-flash-ru.txt, раздел 2.)'
M_INSTALLER_NOTES='Заметки установщика:'
M_REASON='Причина:'
M_WHY_LOCKED='Загрузчик телефона заблокирован. Заблокированный загрузчик не примет изменённые boot, vendor_boot и dtbo: телефон покажет «The system has been destroyed», и вернуть его можно будет только через EDL. Сначала разблокируйте загрузчик.'
M_WHY_NEXTSLOT='Загрузчик в следующий раз запустит другой слот (после установки прошивки или обновления). Перезагрузите телефон в рекавери ещё раз (после обновления — один раз загрузите систему) и запустите флешер снова.'
M_WHY_TMPSPACE='В памяти рекавери мало места для копии. Перезагрузите рекавери (ничего больше не устанавливая) и запустите флешер снова.'
M_WHY_SDSPACE='Во внутренней памяти телефона нет места для копии разделов (нужно около 400 МБ). Освободите место.'
M_WHY_CMDLINE="Командная строка ядра для этой прошивки получилась бы слишком длинной — телефон загрузился бы в рекавери. Сообщите на форуме, приложите run-flash.log."
M_WHY_HEADER='Формат boot / vendor_boot этой прошивки установщик не поддерживает.'
M_WHY_DEVICE='Установщик не узнал телефон: это не Xiaomi Mi 12 Lite (taoyao).'
M_WHY_UNZIP='Файл не распаковался на телефоне — передача, видимо, повредила его. Запустите флешер снова; не помогает — другой кабель или порт.'
M_WHY_BADZIP='Файл ядра собран неправильно — сообщите на форуме.'
M_WHY_RZ_ROM='Прошивка в слоте с тех пор изменилась (обновление или другая прошивка): эти образы к ней не подходят, возврат их не записал. Установите прошивку заново или используйте копию этой прошивки.'
M_WHY_RZ_SUMS="restore-zip повреждён."
M_WHY_OTHER='Причина — в строках выше (на английском).'

# --- copies
M_COPY_KNOWN='Такая копия уже есть: {path} — повторно не сохраняю.'
M_STOCK_SAVED='Стоковые образы сохранены: {path} — храните эту папку: это возврат на стоковое ядро.'
M_STOCK_SAVED2='Ядро в копии: {kernel}, прошивка: {fpr}, слот {slot}'
M_STOCK_UNKNOWNK=' (версия ядра в копии не определилась)'
M_PREV_SAVED='Копия прошлой сборки {series} ({label}) сохранена: {path}'
M_STOCK_PRESENT='Стоковые образы этой прошивки есть на компьютере: {path}'
M_STOCK_PRESENT_FPR='Есть стоковые образы слота {slot}, совпавшие с прошивкой только по отпечатку: {path}'
M_STOCK_MAYBE='Есть стоковые образы слота {slot}, возможно, другой сборки прошивки: {list}'
M_STOCK_FPRONLY='ВНИМАНИЕ: эта копия совпала с прошивкой только по отпечатку (fingerprint): {why}. Модули для Play Integrity подменяют отпечаток, поэтому совпадение не доказывает, что сборка та же. Если прошивку обновляли после этой копии, restore-zip откажется записывать её образы.'
M_STOCK_OTHERBUILD='ВНИМАНИЕ: стоковые образы слота {slot} на компьютере — от другой сборки прошивки, не той, что стоит на телефоне сейчас: {list}. К этой прошивке они не подходят: restore-zip из такой копии откажется их записывать.'
M_STOCK_OLDER='ВНИМАНИЕ: стоковые образы слота {slot} на компьютере сделаны, по часам телефона, раньше, чем собрана прошивка, которая стоит на нём сейчас (сборка от {now}): {list}. Скорее всего, они от прошлой сборки, до обновления прошивки. Точнее сравнить нельзя: сборки прошивки в этих копиях нет (их сделали установщик до 0.20 или флешер до 1.2).'
M_FPR_WHY_COPY='сборки прошивки в копии нет (копию сделали установщик до 0.20 или флешер до 1.2)'
M_FPR_WHY_PHONE='сборку прошивки на телефоне сейчас не прочитать'
M_STOCK_CANTCMP='Есть стоковые образы слота {slot}: {list}. Но сборку прошивки на телефоне сейчас определить нельзя, поэтому флешер не знает, подходят ли они к ней.'
M_COPY_BUILT='{path} (сборка прошивки от {date})'
M_COPY_MADE='{path} (копия от {date})'
M_ROM_BUILT='{ver} (сборка от {date})'
M_STOCK_MISSING='ВНИМАНИЕ: на телефоне уже ядро {series} ({kernel}), поэтому копия, которую сделает установщик, — это копия прошлой сборки {series}, а не стоковых образов. {none} Их можно взять только из копии первой установки {series} (папка {BN}, которую вы тогда сохранили) или из самой прошивки (boot.img, vendor_boot.img и dtbo.img из её архива или payload.bin). Без них вернуться на стоковое ядро можно только перепрошивкой.
Всё равно установить ядро v{ver}? (Enter или Д — да, Esc или Н — нет)'
M_STOCK_NONE_PC='Стоковых образов этой прошивки (слот {slot}) на компьютере нет.'
M_STOCK_NONE_UNK='Подходят ли к этой прошивке стоковые образы слота {slot} на компьютере — неизвестно.'
M_RZ_MISSING="ВНИМАНИЕ: установщик не смог сделать restore-zip (мало памяти). Образы для fastboot сохранены: {path}."
M_RZ_NONE_STOP="ОШИБКА: установщик не смог сделать restore-zip (мало памяти в рекавери), а без него второй шаг не делается. Ничего не записано. Перезагрузите рекавери, чтобы освободить память (Reboot → Recovery; ничего больше не устанавливая), и запустите флешер снова: установщик сделает копию заново. Образы для fastboot уже на компьютере: {path}."
M_COPY_NOT_ON_PC='ОШИБКА: копии разделов (с restore-zip) на компьютере нет — второй шаг не делается. Ничего не записано. Не перезагружайте телефон; запустите флешер снова — он найдёт копию и продолжит.'
M_VERIFY_FAILED='ОШИБКА: копия на компьютере не прошла проверку: {what}. Ничего не записано. Не перезагружайте телефон (копия пока только в его памяти) и попробуйте другой кабель или порт; запустите флешер снова — он продолжит.'
M_VERIFY_FAILED_DISK='ВНИМАНИЕ: копия {dir} с телефона не прошла проверку на компьютере ({what}). Она остаётся на телефоне.'
M_PULL_LATER='ВНИМАНИЕ: ядро установлено, но копию разделов не удалось забрать на компьютер ({what}). Она лежит на телефоне: {path}. Запустите флешер ещё раз и выберите пункт 4 — он сначала заберёт копии из памяти телефона (на вопрос о перезагрузке в рекавери ответьте Esc), или скопируйте эту папку вручную (Внутренняя память → {BN}).'
M_ON_PHONE='На телефоне найдено копий: {n} (новых для компьютера: {k}, ≈ {size})'
M_NONE_ON_REC='Копий разделов на телефоне (в памяти рекавери и во внутренней памяти) нет.'
M_NONE_ON_PHONE='Копий разделов во внутренней памяти телефона нет.'
M_PULLING='Копирую на компьютер: {file} ({size})…'
M_VERIFY_OK_NORZ='ОК: копия {dir} на компьютере проверена (размеры, sha256); restore-zip в ней нет.'
M_VERIFY_OK='ОК: копия {dir} на компьютере проверена (размеры, sha256, restore-zip).'
M_DOWNGRADE_ASK='ВНИМАНИЕ: на телефоне более новая сборка (v{have}), чем в файле (v{ver}). Установить более старую? (Enter или Д — да, Esc или Н — нет)'
M_SAME_ASK='Эта версия (v{ver}) уже установлена. Установить её ещё раз? (Enter или Д — да, Esc или Н — нет)'
M_NOKSU_NOTE='ВНИМАНИЕ: в этой сборке нет KernelSU (noksu): после установки root (SukiSU / KernelSU) пропадёт, и следующий раз флешер будет ставить ядро через рекавери.'
M_STOCK_NOW='На телефоне сейчас ядро прошивки ({kernel}): копия, которую сделает установщик, — это стоковые образы. Флешер сохранит их на компьютере.'

# --- restore
M_RESTORE_NONE_STOCK='На компьютере нет сохранённых стоковых образов (папка {dir}). Они появляются, когда флешер устанавливает ядро. Без них вернуть стоковое ядро можно образами из самой прошивки (fastboot) или её перепрошивкой.'
M_RESTORE_NONE_PREV='На компьютере нет сохранённых копий прошлых сборок ядра taoyao (папки taoyao-<серия>-backups рядом с флешером). Они появляются, когда флешер ставит новую сборку поверх старой.'
M_RESTORE_LIST='Какую копию вернуть? Нажмите цифру (Esc — выход):'
M_RESTORE_CONFIRM='Вернуть эту копию в слот {slot}? (Enter или Д — да, Esc или Н — нет)'
M_RESTORE_BAD='ОШИБКА: копия {path} повреждена ({what}). Возврат из неё не делаю.'
M_RESTORE_OK_PC='ОК: копия на компьютере проверена: {path}'
M_RESTORE_NOIMG='(образов в папке нет — хватает restore-zip, он сам проверяет свои образы)'
M_RESTORE_OTHERSLOT_ASK='ВНИМАНИЕ: копия снята со слота {s1}, а телефон сейчас работает со слота {s2}. Возврат запишет слот {s1} — на загрузку телефона это не повлияет. Всё равно продолжить? (Enter или Д — да, Esc или Н — нет)'
M_RESTORE_OTHERROM='ВНИМАНИЕ: копия снята с другой сборки прошивки. Если прошивка в слоте с тех пор менялась, restore-zip откажется записывать — это нормально.'
M_RESTORE_MAYBEROM='ВНИМАНИЕ: копия, {how}, снята с другой сборки прошивки. Если прошивка в слоте с тех пор менялась, restore-zip откажется записывать — это нормально.'
M_HOW_OLDER='скорее всего'
M_HOW_FPRDIFF='возможно'
M_RESTORE_NOOP='ОК: слот {slot} уже содержит эти образы — ничего делать не нужно.'
M_RESTORED='Готово: слот {slot} снова содержит сохранённые образы (проверено по sha256): ядро {kernel}.'
M_RESTORE_REFUSED='Возврат не выполнен, ничего не записано:'
M_RESTORE_REFUSED_NOLOG='  (слот не изменился — проверено по sha256). Этот restore-zip сделан старой сборкой установщика и журнала не ведёт: причину он показал на экране телефона. Чаще всего это «another ramdisk than the saved boot.img»: прошивка в слоте с тех пор изменилась, и эти образы к ней не подходят.'
M_RESTORE_DIRTY='ОШИБКА: возврат записал слот {slot} не полностью — НЕ перезагружайте телефон. Запишите образы через fastboot из папки {path}:'
M_RESTORE_UNCONFIRMED='ВНИМАНИЕ: флешер не смог проверить слот {slot} после возврата. Посмотрите на экран телефона: «holds the saved images again» — возврат выполнен; «Nothing was written» — нет.'

# --- (A)
M_SENDING='Отправляю ядро v{ver} на телефон…'
M_SENDING_RZ='Отправляю restore-zip на телефон…'
M_PUSH_BAD='ОШИБКА: файл на телефоне не совпал с файлом на компьютере. Отключите и снова подключите кабель и запустите флешер снова.'
M_PUSH_FAIL='ОШИБКА: не удалось отправить файл на телефон ({line}). Отключите и снова подключите кабель и запустите флешер снова. Ничего не записано.'
M_A_NOSTART='ОШИБКА: установщик на телефоне не запустился ({out}). Ничего не записано.'
M_A_RUNNING='На телефоне уже идёт установка (запущена раньше) — жду её окончания.'
M_A_PREVIOUS='На телефоне есть итог прошлой установки — читаю его.'
M_PREV_RESULT='Итог прошлой установки на телефоне: {what}.'
M_PREV_DONE='ядро установлено'
M_PREV_CLEAN='установщик остановился, ничего не записано'
M_PREV_ROLLED='установщик остановился и вернул исходные образы'
M_PREV_DIRTY='установщик не смог вернуть исходные образы'
M_PREV_UNKNOWN='итог не ясен'
M_ALREADY_DONE_A='Ядро v{ver} уже установлено прошлым запуском флешера (так пишет журнал установщика). Ставить ещё раз не нужно.'
M_A_STARTED='Установщик запущен на телефоне. Его сообщения:'
M_A_GOING='… установка идёт ({t}). Не отключайте телефон.'
M_A_SLOW='Установка идёт дольше обычного — подождите.'
M_A_TIMEOUT='ОШИБКА: установка идёт уже 15 минут. Флешер перестаёт ждать. Не перезагружайте телефон ещё 5 минут, потом запустите флешер снова — он прочитает итог.'
M_A_CABLE='Связь с телефоном пропала — установка на телефоне продолжается сама. Подключите кабель снова.'

# --- backup only, reboot
M_BACKUP_NEEDS_REC='В работающей системе установщик сразу устанавливает ядро; только копию разделов умеет делать лишь рекавери (LineageOS, crDroid, Evolution X, TWRP, OrangeFox).'
M_BACKUP_NOT_HERE='ОШИБКА: в этом рекавери открыта внутренняя память, и установщик сразу установит ядро — «только копию» здесь сделать нельзя. Ничего не записано.'
M_BACKUP_DONE='ОК: копия разделов сохранена, на телефоне ничего не записано: {path}'
M_BACKUP_UNEXPECTED='ВНИМАНИЕ: установщик неожиданно установил ядро за один проход (внутренняя память оказалась доступна).'
M_REBOOT_ASK='Перезагрузить телефон в систему? (Enter или Д — да, Esc или Н — нет)'
M_REBOOT_SELF='Перезагрузите телефон сами: Reboot system now.'
M_REBOOT_SELF_A='Перезагрузите телефон сами, когда будет удобно: записанное ядро заработает после перезагрузки.'
M_REBOOT_NOT='Телефон не перезагружаю: {why}'
M_BOOT_WAIT='Жду загрузки системы (до 5 мин). Esc или Н — не ждать.'
M_REBOOTING_SYS='Перезагружаю телефон (как перезагрузка из меню кнопки питания)…'
M_REBOOT_FALLBACK='Android сам не начал перезагрузку — перезагружаю командой adb reboot.'
M_BOOT_OK='Телефон загрузился с ядром {rel}.'
M_BOOT_OTHER='ВНИМАНИЕ: телефон загрузился с ядром {got}, ожидалось {want}.'
M_BOOT_UNAUTH='Телефон загрузился, но этот компьютер не разрешён для отладки — версию ядра флешер не видит. Разрешите отладку по USB на телефоне или посмотрите сами: Настройки → О телефоне → Версия ядра.'
M_BOOT_NONE='Телефон не появился в системе за 5 минут. Если он остановился в fastboot или не загружается — см. «Как вернуться» в итоге.'

# --- ending
M_PRESS_KEY='Нажмите любую клавишу, чтобы закрыть окно.'
M_FAILED='Не получилось. Приложите к сообщению на форуме файл:
  {log}
В нём нет серийного номера телефона и имени пользователя компьютера.'
M_STOPPED_PRE='Остановлено. На телефоне ничего не менялось.'
M_STOPPED_WAIT='Остановлено. Ничего не записано. Если телефон в рекавери — его можно перезагрузить: Reboot system now.'
M_STOPPED_RAM='Остановлено. Ничего не записано. Не перезагружайте телефон: копия разделов пока только в его памяти. Запустите флешер снова — он найдёт копию и продолжит.'
M_STOPPED_RAMPC='Остановлено. Ничего не записано, копия на компьютере: {path}. Телефон можно перезагрузить.'
M_STOPPED_SAID='Остановлено вами — что с телефоном и что делать, написано выше.'
M_STOPPED_RUN='Флешер больше не ждёт. Не перезагружайте телефон, пока на его экране не появится итог (рекавери) или ещё несколько минут (система). Потом запустите флешер снова: он прочитает журнал установщика и закончит.'
M_STOPPED_RUN_A='Флешер больше не ждёт. Установка на телефоне продолжается сама: не перезагружайте телефон несколько минут, потом запустите флешер снова — он прочитает итог установки и закончит.'
M_STOPPED_DONE='Остановлено.'
M_STOPPED_Q2='Остановлено. Итог флешер не проверил. Если телефон ещё в рекавери — перезагрузите его (Reboot system now); в системе посмотрите версию ядра: Настройки → О телефоне → Версия ядра (crDroid, Evolution X: О телефоне → Версия Android → Версия ядра; HyperOS: О телефоне → Все параметры → Версия ядра); должно быть {rel}.'
M_STOPPED_QRUN='Флешер больше не ждёт. Не перезагружайте телефон, пока на его экране не появится итог. Потом перезагрузите его (Reboot system now) и посмотрите версию ядра: Настройки → О телефоне → Версия ядра (crDroid, Evolution X: О телефоне → Версия Android → Версия ядра; HyperOS: О телефоне → Все параметры → Версия ядра); должно быть {rel}.'
M_STOPPED_QRUN1='Флешер больше не ждёт. Эта отправка ядро не записывает (шаг 1). Дождитесь итога на экране телефона — потом телефон можно перезагрузить: Reboot system now.'
M_STOPPED_SEEN='Остановлено. Флешер в этот раз ничего не отправлял. Прошлая отправка в этом сеансе рекавери могла записать ядро — её итог на экране телефона.'
M_STOP_ASK='Остановить флешер? (Enter или Д — да, Esc или Н — нет)'
M_STOP_ASK_RUN='Установка на телефоне, возможно, уже идёт — прерывать её нельзя. Enter или Д — ждать дальше (лучше так), Esc или Н — перестать ждать'
M_STOP_ASK_PULL='Остановить копирование? (Enter или Д — да, Esc или Н — нет)'
M_GOON='Продолжаю.'
M_WAITED='… жду {t}'
M_WAIT_MORE='Телефон так и не перешёл в нужный режим за {t}. Enter или Д — ждать ещё, Esc или Н — остановиться (флешер следит за телефоном и сейчас).'
M_WAIT_MORE_CABLE='Телефон так и не подключился снова за {t}. Enter или Д — ждать ещё, Esc или Н — остановиться (флешер следит за телефоном и сейчас).'

########################################################################
# keys, questions, exit, Ctrl+C
cleanup() {
  [ -n "$ADBPID" ] && kill "$ADBPID" 2>/dev/null
  # (stopped between the two renames of the platform-tools folder: the old
  # one comes back)
  if [ -n "$PTOLD" ] && [ ! -e "$PTDST" ] && [ ! -L "$PTDST" ]; then mv "$PTOLD" "$PTDST" 2>/dev/null; fi
  [ -n "$PTSTAGE" ] && rm -rf "$PTSTAGE"
  [ -n "$PTSTAGE2" ] && rm -rf "$PTSTAGE2"
  [ -n "$LOCKD" ] && rm -rf "$LOCKD"
  [ -n "$STTYSAVE" ] && stty "$STTYSAVE" </dev/tty 2>/dev/null
  rm -rf "$TMPD"
}
trap cleanup EXIT
trap 'INTR=1' INT
trap 'logl "terminated (TERM)"; exit 143' TERM
trap 'logl "terminated (HUP)"; exit 129' HUP

flushkeys() { [ -n "$TTYOK" ] || return 0; while IFS= read -r -s -n 1 -t 1 _k </dev/tty; do :; done 2>/dev/null; }
# readkey: one key from the terminal. KEY = ENTER, ESC, INT, YES (Д, д, and
# L, l: the Д key in the Latin layout), NO (Н, н, N, n), AMBIG (Y, y: the
# same key as Н in the Russian layout, so it could mean either: asked again)
# or the character itself (a digit of a menu)
readkey() {
  local k= k2=
  if ! IFS= read -r -s -n 1 k </dev/tty 2>/dev/null; then
    if [ -n "$INTR" ]; then INTR=; KEY=INT; else KEY=ESC; fi
    return 0
  fi
  key_name "$k"
}
# key_name <byte>: KEY for it (a Cyrillic letter is two bytes in UTF-8: the
# second one is read here)
key_name() {
  local k=$1 k2=
  case $k in $'\320'|$'\321') IFS= read -r -s -n 1 -t 1 k2 </dev/tty 2>/dev/null; k=$k$k2;; esac
  case $k in
    '') KEY=ENTER;;
    $'\e') KEY=ESC; while IFS= read -r -s -n 1 -t 1 k </dev/tty 2>/dev/null; do :; done;;
    $'\003') KEY=INT;;
    Д|д|L|l) KEY=YES;;
    Н|н|N|n) KEY=NO;;
    Y|y) KEY=AMBIG;;
    *) KEY=$k;;
  esac
}
# readkey_t <seconds>: as readkey, KEY empty when no key came in time
readkey_t() {
  local k= rc
  KEY=
  [ -n "$TTYOK" ] || { sleep "$1"; return 0; }
  IFS= read -r -s -n 1 -t "$1" k </dev/tty 2>/dev/null; rc=$?
  if [ $rc -gt 128 ] && [ -z "$INTR" ]; then return 0; fi   # (time out)
  [ $rc != 0 ] && return 0
  key_name "$k"
  return 0
}
# qkey: readkey for a question or a menu, but Ctrl+C is noticed while it
# waits (bash does not end a read on a trapped SIGINT: the key after it would
# answer) and means INT; a terminal that is gone (reads fail at once) means ESC
qkey() {
  local k= s f=0
  while :; do
    s=$SECONDS
    IFS= read -r -s -n 1 -t 1 k </dev/tty 2>/dev/null && break
    if [ -n "$INTR" ]; then INTR=; KEY=INT; return 0; fi
    if [ "$SECONDS" = "$s" ]; then f=$((f + 1)); [ $f -ge 3 ] && { KEY=ESC; return 0; }; else f=0; fi
  done
  if [ -n "$INTR" ]; then INTR=; KEY=INT; return 0; fi
  key_name "$k"
}
# ask_yes: Enter, Д or L yes (0); Esc, Н, N or Ctrl+C no (1); Y asked
# again; without a terminal: the default ($1)
ask_yes() {
  [ -n "$TTYOK" ] || return "${1:-1}"
  while :; do
    qkey
    case $KEY in
      ENTER|YES) logl "answer: yes ($KEY)"; return 0;;
      ESC|INT|NO) logl "answer: no ($KEY)"; return 1;;
      AMBIG) logl "answer: Y (asked again)"; say "$M_KEYS_AMBIG";;
      *) say "$M_KEYS";;
    esac
  done
}
# prompt_yes <text> [default]: keys pressed before are dropped, then the
# question (yellow, bell), then ask_yes
prompt_yes() { flushkeys; warnm "$1"; bell; ask_yes "${2:-1}"; }

open_folder() {  # <folder>
  [ -n "$MENU" ] && [ -n "$1" ] && [ -d "$1" ] || return 0
  case $(uname -s 2>/dev/null) in
    Darwin) open "$1" >/dev/null 2>&1;;
    *) if [ -n "${DISPLAY-}${WAYLAND_DISPLAY-}" ] && command -v xdg-open >/dev/null 2>&1; then
         xdg-open "$1" >/dev/null 2>&1 &
       fi;;
  esac
  return 0
}

# finish <rc>: summary (when something happened on the phone), the forum
# footer after a failure, the "press a key" of the menu, exit
SUM_SHOWN=
finish() {
  local rc=$1
  [ -n "$ADBPID" ] && { kill "$ADBPID" 2>/dev/null; ADBPID=; }
  if [ -n "$SUM_ON" ] && [ -z "$SUM_SHOWN" ]; then show_summary "$rc"; fi
  case $rc in
    10|12|13) if [ -n "$LOG" ] && [ -z "$NOFOOTER" ]; then echo; errm "$(fill "$M_FAILED" log "$LOG")"; fi;;
  esac
  if [ -n "$PULLDIR" ] && [ -d "$PULLDIR" ]; then
    rmdir "$PULLDIR" 2>/dev/null && logl "pull folder empty, removed"
  fi
  logl "exit code $rc"
  open_folder "$OPENDIR"
  if [ -n "$MENU" ]; then
    echo
    flushkeys
    printf '%s' "$M_PRESS_KEY"
    readkey; echo
  fi
  exit "$rc"
}
fail() { [ -n "$1" ] && { errm "$1"; FAIL_TXT=$1; }; finish $RC_FAIL; }
# why_short <message>: its first sentence, for the summary line
why_short() {
  local t=$1
  t=${t#ОШИБКА: }; t=${t#ВНИМАНИЕ: }
  case $t in *'. '*) t=${t%%. *};; esac
  while [ "${t%.}" != "$t" ]; do t=${t%.}; done
  printf '%s' "$t"
}

# the message for "stopped now" in each phase (section 18.3)
phase_msg() {
  case $PHASE in
    pre|'') printf '%s' "$M_STOPPED_PRE";;
    wait) printf '%s' "$M_STOPPED_WAIT";;
    ram) printf '%s' "$M_STOPPED_RAM";;
    rampc) fill "$M_STOPPED_RAMPC" path "${RAMONPC:-?}";;
    run) if [ "$WAY" = A ]; then printf '%s' "$M_STOPPED_RUN_A"
         # (a send of Q2 / Q3: no log to read in that recovery)
         elif [ -n "$Q_KIND" ] && [ "$WROTE" = maybe ]; then fill "$M_STOPPED_QRUN" rel "${Q_WANT:-$KREL}"
         elif [ -n "$Q_KIND" ]; then printf '%s' "$M_STOPPED_QRUN1"
         else printf '%s' "$M_STOPPED_RUN"; fi;;
    done) printf '%s' "$M_STOPPED_DONE";;
    q2) fill "$M_STOPPED_Q2" rel "${Q_WANT:-$KREL}";;
    seen) printf '%s' "$M_STOPPED_SEEN";;
    *) printf '%s' "$M_STOPPED_WAIT";;
  esac
}
# warn_phase: the phase message once on the screen (the summary then only
# points to it)
warn_phase() { warnm "$(phase_msg)"; PHASE_SAID=1; }
# stop_rc <code>: the exit code of a stop (a time limit, Esc, Ctrl+C): after
# the flash (phase done) its own code; 13 while a pass that may write was
# sent and its result is not confirmed (WROTE=maybe), else <code> (as
# run-flash.ps1)
stop_rc() {
  if [ "$PHASE" = done ]; then printf '%s' "${DONE_RC:-0}"
  elif [ "$WROTE" = maybe ]; then printf '%s' "$RC_ATTN"; else printf '%s' "$1"; fi
}
cancel_now() {
  [ -n "$ADBPID" ] && { kill "$ADBPID" 2>/dev/null; ADBPID=; }
  echo
  if [ "$PHASE" = pull ]; then
    [ -n "$PULLPART" ] && rm -f "$PULLPART"
    # (the unverified part of the copy being pulled goes too, as
    # run-flash.ps1; kept folders are never touched)
    [ -n "$PULLCUR" ] && rm -rf "$PULLCUR"
    PULLCUR=; PHASE=$PULLPHASE
  fi
  warn_phase
  logl "cancelled by the user (phase ${PHASE:-pre})"
  finish "$(stop_rc $RC_CANCEL)"
}
# check_intr: called in every wait; Ctrl+C asks before it stops
check_intr() {
  [ -n "$INTR" ] || return 0
  INTR=
  [ -n "$TTYOK" ] || cancel_now
  echo; DOTS=
  case $PHASE in
    boot) BOOTSKIP=1; return 0;;
    run)
      flushkeys; warnm "$M_STOP_ASK_RUN"
      if ask_yes 0; then say "$M_GOON"; return 0; fi
      cancel_now;;
    pull) if prompt_yes "$M_STOP_ASK_PULL" 1; then cancel_now; fi;;
    *) if prompt_yes "$M_STOP_ASK" 1; then cancel_now; fi;;
  esac
  say "$M_GOON"
  return 0
}
# nap <seconds>: sleep, but react to Ctrl+C
nap() {
  local i=0 n=$(( $1 * 5 ))
  while [ $i -lt $n ]; do sleep 0.2; i=$((i + 1)); check_intr; done
}
# q <command...>: for $(...) whose result matters (filing, verifying): bash
# gives a command substitution the default SIGINT, so Ctrl+C would kill it
# half-way and leave an empty or partial value; here it is ignored (the main
# shell still notices Ctrl+C and asks at its next wait)
q() { trap '' INT; "$@"; }
elapsed() { local s=$1; if [ "$s" -ge 60 ]; then echo "$((s / 60)) мин $((s % 60)) с"; else echo "$s с"; fi; }
now_s() { date +%s; }

########################################################################
# run_to <seconds> <outfile> <command...>: stdout and stderr to outfile,
# stdin from /dev/null; 124 after the time limit
# Every child runs with SIGINT ignored (bg_run): Ctrl+C in the terminal goes
# to the whole process group, and a killed adb pull or sideload would lose
# the transfer although the user then chooses to go on waiting
bg_run() { trap '' INT; if [ "$(type -t "$1")" = function ]; then "$@"; else exec "$@"; fi; }
run_to() {
  local lim=$1 of=$2 pid i=0 rc
  shift 2
  ( bg_run "$@" ) </dev/null >"$of" 2>&1 &
  pid=$!; ADBPID=$pid
  while kill -0 "$pid" 2>/dev/null; do
    if [ $i -ge $((lim * 5)) ]; then
      kill "$pid" 2>/dev/null; sleep 1; kill -9 "$pid" 2>/dev/null
      wait "$pid" 2>/dev/null; ADBPID=
      return 124
    fi
    sleep 0.2; i=$((i + 1))
    check_intr
  done
  wait "$pid"; rc=$?
  ADBPID=
  return $rc
}
# adb_in <dir> <adb arguments...>: adb with -s, its working directory <dir>
# (local files are relative names: any characters in the folder work)
adb_in() { local d=$1; shift; cd -- "$d" && exec "$ADB" -s "$SERIAL" "$@"; }
adbs() { "$ADB" -s "$SERIAL" "$@"; }

# dev_call <seconds> <root 0|1> <command>: adb shell; output (CR stripped)
# in $TMPD/dc.out
dev_call() {
  local lim=$1 root=$2 cmd=$3 full rc
  case $cmd in *"'"*) echo "Внутренняя ошибка флешера: кавычка в команде для телефона" >&2; finish $RC_FAIL;; esac
  full=$cmd
  # (adbd itself runs as root: no su, as run-flash.ps1)
  [ "$root" = 1 ] && [ -z "$ADBROOT" ] && full="su -c '$cmd'"
  logl "> adb shell $(printf '%s' "$full" | cutc 400)"
  run_to "$lim" "$TMPD/dc.raw" "$ADB" -s "$SERIAL" shell "$full"; rc=$?
  tr -d '\r' < "$TMPD/dc.raw" > "$TMPD/dc.out"
  logl "< rc=$rc $(head -c 3000 "$TMPD/dc.out")"
  return $rc
}
# lost: the last adb call failed because the phone is gone
lost() {
  grep -qiE "device '.*' not found|no devices/emulators found|device offline|device unauthorized|error: closed|protocol fault|connection reset|failed to get feature set|no device|device still authorizing" "${1:-$TMPD/dc.out}" 2>/dev/null
}
# kv <key> [file]: value of a key=value line
kv() { awk -v k="$1" 'index($0, k "=") == 1 { print substr($0, length(k) + 2); exit }' "${2:-$TMPD/dc.out}" | tr -d '\r'; }
# probe_ok: the last probe printed its end=1
probe_ok() { grep -q '^end=1$' "$TMPD/dc.out" 2>/dev/null; }

########################################################################
# adb: find it (as the log collector), start the server
ver_ok() {  # <x.y.z>: ADB_MIN (1.0.39) or newer
  case $1 in ''|*[!0-9.]*) return 1;; esac
  [ "$(vercmp "$1" "$ADB_MIN")" != -1 ]
}
find_adb() {
  local p rc v inst seen=" " oldv= oldp= os ud m t
  os=$(uname -s 2>/dev/null)
  ud=$(pt_user_dir)
  pt_stale "$HERE"; [ -n "$ud" ] && pt_stale "${ud%/*}"
  for p in "$ADB_USER" "$HERE/adb" "$HERE/platform-tools/adb" "${ud:+$ud/adb}" "$(command -v adb 2>/dev/null)" \
           /opt/homebrew/bin/adb /usr/local/bin/adb "${HOME-}/Library/Android/sdk/platform-tools/adb" \
           "${HOME-}/Android/Sdk/platform-tools/adb" "${ANDROID_HOME:+$ANDROID_HOME/platform-tools/adb}" \
           "${ANDROID_SDK_ROOT:+$ANDROID_SDK_ROOT/platform-tools/adb}" "${HOME-}/platform-tools/adb" \
           "${HOME-}/Downloads/platform-tools/adb" /usr/bin/adb; do
    [ -n "$p" ] || continue
    case $seen in *" $p "*) continue;; esac
    seen="$seen$p "
    [ -f "$p" ] || continue
    if [ ! -x "$p" ]; then
      case $p in "$HERE"/*) chmod +x "$p" 2>/dev/null && logl "made executable: $p";; esac
    fi
    [ -x "$p" ] || { logl "adb candidate not executable: $p"; continue; }
    run_to 10 "$TMPD/ver" "$p" version; rc=$?
    if [ $rc = 137 ] && [ "$os" = Darwin ]; then
      logl "adb candidate killed by macOS (quarantine? xattr -d com.apple.quarantine): $p"; continue
    fi
    if [ $rc != 0 ]; then logl "adb candidate failed (rc $rc): $p $(head -c 300 "$TMPD/ver")"; continue; fi
    v=$(sed -n 's/^Android Debug Bridge version \([0-9][0-9.]*\).*/\1/p' "$TMPD/ver" | head -n 1)
    inst=$(sed -n 's/^Installed as //p' "$TMPD/ver" | head -n 1 | tr -d '\r')
    if ver_ok "$v"; then
      ADB=$p; [ -n "$inst" ] && [ -x "$inst" ] && ADB=$inst
      ADBVER=$v
      logl "adb: $ADB (version $v)"
      return 0
    fi
    logl "adb candidate too old ($v): $p"
    [ -z "$oldv" ] && { oldv=$v; oldp=$p; }
  done
  # (no usable adb: offer SDK Platform-Tools from Google; when the user says
  # no, the manual way, and the run ends as cancelled, not failed)
  pt_get "$oldv" "$oldp"; rc=$?
  [ $rc = 0 ] && return 0
  # (t: the first letter, after the tag when it is an error)
  m=errm; t="ОШИБКА: н"; [ $rc = 3 ] && { m=warnm; t=Н; }
  echo
  if [ -n "$oldv" ]; then
    case $oldp in
      "$HERE/platform-tools/adb"|"$HERE/adb") $m "${t}айден только старый adb (версия $oldv) — в папке флешера: $oldp. С ним флешер работает ненадёжно. Скачайте свежий: $PT_URL — и замените им папку platform-tools рядом с флешером.";;
      *) $m "${t}айден только старый adb (версия $oldv: $oldp). С ним флешер работает ненадёжно. Скачайте свежий: $PT_URL — и распакуйте папку platform-tools рядом с флешером: тогда будет использован он.";;
    esac
  elif [ "$os" = Darwin ]; then
    $m "${t}е найдена программа adb. Установите её одной командой: brew install --cask android-platform-tools — или скачайте «SDK Platform-Tools for Mac»: $PT_URL и положите папку platform-tools рядом с run-flash.sh."
  else
    $m "${t}е найдена программа adb. Установите пакет (Debian/Ubuntu: sudo apt install adb; Fedora: sudo dnf install android-tools; Arch: sudo pacman -S android-tools) или скачайте «SDK Platform-Tools for Linux»: $PT_URL и положите папку platform-tools рядом с run-flash.sh."
  fi
  if [ $rc = 3 ]; then
    echo
    warnm "adb не скачан — поставьте его, как написано выше, и запустите флешер снова."
    logl "cancelled: the adb download was declined"
    PHASE_SAID=1; SUM_WHAT=; NOFOOTER=1
    finish $RC_CANCEL
  fi
  NOFOOTER=; fail ""
}
start_server() {
  local rc
  run_to 30 "$TMPD/ss" "$ADB" start-server; rc=$?
  logl "adb start-server: rc $rc $(head -c 500 "$TMPD/ss")"
  if grep -q "doesn't match this client" "$TMPD/ss"; then
    warnm "ВНИМАНИЕ: другая программа на компьютере запускает свою версию adb, и они мешают друг другу. Если телефон будет «пропадать», закройте программы для работы с телефоном и запустите флешер снова."
  fi
  if [ $rc != 0 ]; then
    fail "ОШИБКА: не удалось запустить службу adb ($(grep -v '^\*' "$TMPD/ss" | head -n 1)). Закройте другие программы, которые работают с телефоном по USB, и запустите флешер снова. Не помогло — перезагрузите компьютер."
  fi
}

########################################################################
# adb from Google: with no usable adb, SDK Platform-Tools are downloaded
# from dl.google.com on this computer once the user agrees to Google's terms
# (Google's adb is not part of our ZIP), checked, and put into platform-tools
# next to the flasher, or into a per-user folder when the flasher's folder
# is read-only or its platform-tools folder cannot be replaced.
# TAOYAO_ADB_DOWNLOAD=1 downloads without the question, =0 never;
# TAOYAO_PT_URL replaces the download folder for tests (https://dl.google.com
# only, or a local server on 127.0.0.1 or localhost).
PTZIP=; PTFILE=; PTKIND=; PTAUTO=; PTWHERE=; PTKILLED=; PTMOVED=0
# pt_user_dir: the per-user platform-tools folder
pt_user_dir() {
  [ -n "${HOME-}" ] && [ "$HOME" != / ] || return 1
  if [ "$(uname -s 2>/dev/null)" = Darwin ]; then
    printf '%s\n' "$HOME/Library/Application Support/MeruDevTools/platform-tools"
  else
    case ${XDG_DATA_HOME-} in
      /*) printf '%s\n' "$XDG_DATA_HOME/MeruDevTools/platform-tools";;
      *) printf '%s\n' "$HOME/.local/share/MeruDevTools/platform-tools";;
    esac
  fi
}
# pt_url: the archive for this computer in PTZIP; 1 a bad TAOYAO_PT_URL,
# 2 nothing for this computer (PTERR)
pt_url() {
  local b=${TAOYAO_PT_URL:-$PT_BASE} os
  local re1='^https://dl\.google\.com(/[^@[:space:]]*)?$' re2='^https?://(127\.0\.0\.1|localhost)(:[0-9]+)?(/[^@[:space:]]*)?$'
  while [ "${b%/}" != "$b" ]; do b=${b%/}; done
  if ! [[ $b =~ $re1 ]] && ! [[ $b =~ $re2 ]]; then
    PTERR="TAOYAO_PT_URL: можно указать только адрес на https://dl.google.com (или на 127.0.0.1 для проверки)"
    return 1
  fi
  case $(uname -s 2>/dev/null) in
    Darwin) os=darwin;;
    Linux) case $(uname -m 2>/dev/null) in
         x86_64|amd64) os=linux;;
         *) PTERR="Google выпускает SDK Platform-Tools для Linux только для x86-64 (этот компьютер: $(uname -m 2>/dev/null))"; return 2;;
       esac;;
    *) PTERR="у Google нет SDK Platform-Tools для $(uname -s 2>/dev/null)"; return 2;;
  esac
  PTZIP="$b/platform-tools-latest-$os.zip"
  return 0
}
# pt_auto: TAOYAO_ADB_DOWNLOAD as PTAUTO: 1 (download without the question),
# 0 (never) or empty (ask)
pt_auto() {
  local v
  v=$(printf '%s' "${TAOYAO_ADB_DOWNLOAD-}" | tr -d ' ' | tr 'A-Z' 'a-z')
  case $v in
    '') PTAUTO=;;
    1|yes|true|on|да|Да|ДА) PTAUTO=1;;
    0|no|false|off|нет|Нет|НЕТ) PTAUTO=0;;
    *) PTAUTO=
       warnm "ВНИМАНИЕ: непонятное значение TAOYAO_ADB_DOWNLOAD=«$(printf '%s' "$TAOYAO_ADB_DOWNLOAD" | cutc 40)»: нужно 1 (скачивать adb) или 0 (не скачивать)."
       ;;
  esac
}
# pt_ask <old version>: 0 when the user agrees to the download, 3 when not,
# 1 with no terminal for the question; Ctrl+C stops the run
pt_ask() {
  local q
  echo
  if [ "$PTAUTO" = 1 ]; then
    say "TAOYAO_ADB_DOWNLOAD=1: скачиваю adb без вопроса (условия Google: $PT_TERMS)."
    return 0
  fi
  if [ -z "$TTYOK" ]; then
    logl "adb download: no terminal for the question"
    warnm "Чтобы скачать adb с сайта Google без вопроса, задайте переменную TAOYAO_ADB_DOWNLOAD=1 (этим вы принимаете условия Google: $PT_TERMS)."
    return 1
  fi
  if [ -n "$1" ]; then
    q="Найденный adb слишком старый (версия $1). Скачать свежий Android SDK Platform-Tools с сайта Google (около 7–15 МБ, нужен интернет)? Нажимая Д, вы принимаете условия Google: $PT_TERMS [Д/н]"
  else
    q="adb не найден. Скачать Android SDK Platform-Tools с сайта Google (около 7–15 МБ, нужен интернет)? Нажимая Д, вы принимаете условия Google: $PT_TERMS [Д/н]"
  fi
  flushkeys
  warnm "$q"
  while :; do
    # (qkey names the keys: Д, д, L, l are YES, Н, н, N, n are NO; Y shares
    # its key with Н, so it could mean either and is asked again: AMBIG)
    qkey
    case $KEY in
      ENTER|YES) logl "answer: $KEY (download)"; return 0;;
      ESC|NO) logl "answer: $KEY (no download)"; return 3;;
      INT) logl "answer: Ctrl+C"; cancel_now;;
      AMBIG) say "Непонятно: на этой клавише и Y, и Н. Нажмите Enter (или Д) — скачать, Esc (или Н) — не скачивать.";;
      *) say "Нажмите Д или Enter — скачать, Н или Esc — не скачивать.";;
    esac
  done
}
# pt_mb <file>: ", скачано 2,3 МБ" while the file grows
pt_mb() {
  local n
  [ -n "$1" ] && [ -f "$1" ] || return 0
  n=$(wc -c 2>/dev/null < "$1" | tr -d ' ')
  case $n in ''|0|*[!0-9]*) return 0;; esac
  awk -v b="$n" 'BEGIN { if (b >= 104858) printf ", скачано %.1f МБ", b / 1048576; else printf ", скачано %d КБ", (b + 1023) / 1024 }' | tr . ,
}
# pt_run <seconds> <outfile> <command...>: like run_to, with a line every 15 s
pt_run() {
  local lim=$1 of=$2 pid i=0 rc
  shift 2
  ( bg_run "$@" ) </dev/null >"$of" 2>&1 &
  pid=$!; ADBPID=$pid
  while kill -0 "$pid" 2>/dev/null; do
    if [ $i -ge $((lim * 5)) ]; then
      kill "$pid" 2>/dev/null; sleep 1; kill -9 "$pid" 2>/dev/null
      wait "$pid" 2>/dev/null; ADBPID=
      return 124
    fi
    sleep 0.2; i=$((i + 1))
    [ $((i % 75)) = 0 ] && say "… скачиваю, прошло $(elapsed $((i / 5)))$(pt_mb "$PTFILE")"
    check_intr
  done
  wait "$pid"; rc=$?
  ADBPID=
  return $rc
}
# pt_why <curl|wget> <exit code>: PTERR in Russian from the exit code and the
# message in $TMPD/dl.log (which run-flash.log keeps as it is); PTKIND net (no
# internet, DNS, proxy, timeout, TLS), disk, or empty
pt_why() {
  local t=$1 rc=$2 l h= k=
  PTKIND=
  l=$(grep -v '^[[:space:]]*$' "$TMPD/dl.log" 2>/dev/null | tail -n 1 | sed 's/^[0-9][0-9-]* [0-9][0-9:]* //' | cutc 200)
  if [ "$t:$rc" = curl:22 ] || [ "$t:$rc" = wget:8 ]; then
    h=$(grep -o 'error: [0-9][0-9][0-9]\|ERROR [0-9][0-9][0-9]' "$TMPD/dl.log" 2>/dev/null | tail -n 1 | grep -o '[0-9][0-9][0-9]$')
  fi
  if [ -n "$h" ]; then
    case $h in
      407) PTERR="прокси-сервер требует пароль (ошибка 407)"; PTKIND=net;;
      *) PTERR="сервер ответил ошибкой $h";;
    esac
    return 0
  fi
  if [ "$t" = curl ]; then
    case $rc in
      5) k=proxy;; 6) k=dns;; 7) k=conn;; 23) k=disk;; 47) k=redir;; 63) k=big;;
      28) if grep -qi 'too slow' "$TMPD/dl.log" 2>/dev/null; then k=slow; else k=time; fi;;
      35|51|53|54|58|59|60|64|66|77|80|82|83|90|91) k=tls;;
      16|18|52|55|56|92) k=cut;;
    esac
  else
    case $rc in
      3) k=disk;;
      5) k=tls;;
      4) if grep -qi 'resolv\|name or service\|name resolution' "$TMPD/dl.log" 2>/dev/null; then k=dns
         elif grep -qi 'refused' "$TMPD/dl.log" 2>/dev/null; then k=conn
         elif grep -qi 'timed out' "$TMPD/dl.log" 2>/dev/null; then k=time
         else k=cut; fi;;
    esac
  fi
  case $k in
    proxy) PTERR="не удаётся найти прокси-сервер"; PTKIND=net;;
    dns) PTERR="не удаётся найти сервер: нет интернета или не работает DNS"; PTKIND=net;;
    conn) PTERR="не удаётся подключиться к серверу"; PTKIND=net;;
    time) PTERR="сервер не отвечает"; PTKIND=net;;
    slow) PTERR="сервер перестал присылать данные"; PTKIND=net;;
    cut) PTERR="соединение прервалось"; PTKIND=net;;
    tls) PTERR="не удаётся установить защищённое соединение"; PTKIND=net;;
    disk) PTERR="не удаётся записать файл, возможно, нет места на диске"; PTKIND=disk;;
    redir) PTERR="слишком много перенаправлений";;
    big) PTERR="файл слишком большой";;
    *) PTERR=${l%.}; [ -n "$PTERR" ] || PTERR="код $rc";;
  esac
  return 0
}
# pt_fetch <url> <file>: one download attempt (curl, else wget); PTERR, PTKIND
pt_fetch() {
  local p=https rc t
  case $1 in http://*) p=http;; esac
  rm -f "$2"; PTFILE=$2; PTKIND=
  if command -v curl >/dev/null 2>&1; then
    t=curl
    logl "> curl $1"
    pt_run 900 "$TMPD/dl.log" curl -fsSL --proto "=$p" --proto-redir "=$p" --connect-timeout 30 \
      --speed-limit 1024 --speed-time 60 --max-filesize 209715200 -o "$2" "$1"; rc=$?
  else
    t=wget
    logl "> wget $1"
    pt_run 900 "$TMPD/dl.log" wget --timeout=60 --tries=1 --max-redirect=5 --progress=dot:mega -O "$2" "$1"; rc=$?
  fi
  PTFILE=
  logl "< rc=$rc $(grep -v '^[[:space:]]*$' "$TMPD/dl.log" | tail -n 3 | head -c 600)"
  # (curl refuses a redirect to http:// with exit code 1; wget follows it)
  if { [ $t = wget ] && [ $rc = 0 ] && [ $p = https ] && grep -qi '^Location: *http:' "$TMPD/dl.log"; } ||
     { [ $t = curl ] && [ $rc = 1 ] && grep -qi 'protocol.*not supported\|disabled' "$TMPD/dl.log"; }; then
    PTERR="сервер перенаправил загрузку на незащищённый адрес http://"
  elif [ $rc = 0 ] && [ -s "$2" ]; then
    return 0
  elif [ $rc = 124 ]; then
    PTERR="загрузка не закончилась за 15 мин"; PTKIND=net
  elif [ $rc = 0 ]; then
    PTERR="сервер прислал пустой файл"
  else
    pt_why $t $rc
  fi
  rm -f "$2"
  return 1
}
# pt_unpack <zip> <folder>: the archive opens, holds platform-tools/adb and
# nothing outside platform-tools/; then it is extracted (unzip, else
# python3, else bsdtar); PTERR, PTWHERE (check: a bad archive, unpack: it
# could not be extracted here)
pt_unpack() {
  local z=$1 d=$2 t use= l have= bad= rc
  PTWHERE=check
  for t in unzip python3 bsdtar; do
    command -v $t >/dev/null 2>&1 || continue
    case $t in
      unzip) unzip -Z1 "$z" > "$TMPD/ptlist" 2>/dev/null;;
      python3) python3 -I -c 'import sys, zipfile
for n in zipfile.ZipFile(sys.argv[1]).namelist(): print(n)' "$z" > "$TMPD/ptlist" 2>/dev/null;;
      bsdtar) bsdtar -tf "$z" > "$TMPD/ptlist" 2>/dev/null;;
    esac && [ -s "$TMPD/ptlist" ] && { use=$t; break; }
    logl "$t: cannot list the archive"
  done
  [ -n "$use" ] || { PTERR="архив не открывается"; return 1; }
  while IFS= read -r l; do
    case $l in platform-tools/*) ;; *) bad=$l; break;; esac
    case /$l/ in */../*|*\\*) bad=$l; break;; esac
    [ "$l" = platform-tools/adb ] && have=1
  done < "$TMPD/ptlist"
  if [ -n "$bad" ]; then
    logl "archive entry outside platform-tools/: $bad"
    PTERR="в архиве есть файлы вне папки platform-tools"; return 1
  fi
  [ -n "$have" ] || { PTERR="в архиве нет platform-tools/adb"; return 1; }
  PTWHERE=unpack
  mkdir -p "$d" 2>/dev/null || { PTERR="не удаётся создать временную папку"; return 1; }
  case $use in
    unzip) run_to 120 "$TMPD/ptx" unzip -q -o "$z" -d "$d";;
    python3) run_to 120 "$TMPD/ptx" python3 -I -m zipfile -e "$z" "$d";;
    bsdtar) run_to 120 "$TMPD/ptx" bsdtar -xf "$z" -C "$d";;
  esac
  rc=$?
  logl "$use: rc $rc $(head -c 300 "$TMPD/ptx")"
  [ $rc = 0 ] && [ -f "$d/platform-tools/adb" ] && return 0
  # (the real reason: a damaged archive, a full disk, or the tool's message)
  if [ $rc = 124 ]; then PTERR="распаковка не закончилась за 2 мин"
  elif grep -qi 'no space\|disk full\|quota' "$TMPD/ptx" 2>/dev/null; then PTERR="нет места на диске"
  elif [ $rc = 0 ] || grep -qi 'crc\|bad zip\|badzip\|corrupt\|invalid\|truncated\|damaged' "$TMPD/ptx" 2>/dev/null; then
    PTWHERE=check; PTERR="архив повреждён"
  else
    PTERR=$(grep -v '^[[:space:]]*$' "$TMPD/ptx" | tail -n 1 | cutc 200)
    PTERR=${PTERR%.}; [ -n "$PTERR" ] || PTERR="$use: код $rc"
  fi
  return 1
}
# pt_check <platform-tools folder>: adb there is signed by Google (macOS:
# codesign) and prints its version (1.0.39 or newer); PTVER, PTERR
pt_check() {
  local a="$1/adb" f rc v
  # (python3 does not keep the x bit)
  for f in "$1"/*; do
    case ${f##*/} in *.*) ;; *) [ -f "$f" ] && chmod +x "$f" 2>/dev/null;; esac
  done
  if [ "$(uname -s 2>/dev/null)" = Darwin ]; then
    if xattr -p com.apple.quarantine "$a" >/dev/null 2>&1; then
      xattr -r -d com.apple.quarantine "$1" 2>/dev/null
      logl "quarantine attribute removed"
    fi
    if command -v codesign >/dev/null 2>&1; then
      run_to 30 "$TMPD/cs" codesign --verify --strict "$a"; rc=$?
      logl "codesign --verify: rc $rc $(head -c 300 "$TMPD/cs")"
      [ $rc = 0 ] || { PTERR="цифровая подпись adb недействительна"; return 1; }
      run_to 30 "$TMPD/cs" codesign -dvv "$a"
      v=$(grep '^Authority=' "$TMPD/cs" | head -n 1)
      logl "codesign: $v"
      # (the signer itself, e.g. "Developer ID Application: Google LLC (TEAMID)")
      printf '%s\n' "$v" | grep -Eq '^Authority=[^:]+: Google LLC \([A-Z0-9]+\)$' || { PTERR="adb подписан не Google LLC"; return 1; }
    else
      logl "codesign not found: the signature of adb is not checked"
    fi
  fi
  run_to 10 "$TMPD/ptv" "$a" version; rc=$?
  v=$(sed -n 's/^Android Debug Bridge version \([0-9][0-9.]*\).*/\1/p' "$TMPD/ptv" | head -n 1)
  logl "downloaded adb: rc $rc $(head -c 300 "$TMPD/ptv")"
  if [ $rc != 0 ] || [ -z "$v" ]; then PTERR="adb не запускается"; return 1; fi
  ver_ok "$v" || { PTERR="в архиве старый adb (версия $v)"; return 1; }
  PTVER=$v
  return 0
}
pt_drop() {
  [ -n "$PTSTAGE" ] && rm -rf "$PTSTAGE"
  [ -n "$PTSTAGE2" ] && rm -rf "$PTSTAGE2"
  PTSTAGE=; PTSTAGE2=
}
# pt_stage <folder>: a new empty temporary folder there
pt_stage() {
  rm -rf "$1" 2>/dev/null
  mkdir -p "${1%/*}" 2>/dev/null
  mkdir "$1" 2>/dev/null
}
# pt_alive <pid>: that process still runs (of any user)
pt_alive() {
  kill -0 "$1" 2>/dev/null && return 0
  [ -d "/proc/$1" ] && return 0
  ps -p "$1" >/dev/null 2>&1
}
# pt_merge <old folder> <new folder>: what the old platform-tools folder holds
# and the new one has not (the user's own files, e.g. scrcpy) moves into the
# new one; PTMOVED; 1 when something could not be moved
pt_merge() {
  local o=$1 n=$2 f bad=
  PTMOVED=0
  [ -d "$o" ] && [ ! -L "$o" ] && [ -d "$n" ] || return 0
  for f in "$o"/* "$o"/.[!.]* "$o"/..?*; do
    [ -e "$f" ] || [ -L "$f" ] || continue
    [ -e "$n/${f##*/}" ] || [ -L "$n/${f##*/}" ] && continue
    if mv "$f" "$n/" 2>/dev/null; then
      PTMOVED=$((PTMOVED + 1)); logl "kept from the old platform-tools folder: ${f##*/}"
    else
      bad=1; logl "cannot move from the old platform-tools folder: ${f##*/}"
    fi
  done
  [ -z "$bad" ]
}
# pt_stale <folder>: what a run that was killed (or whose window was closed)
# during the download left there: its temporary folder goes; a platform-tools
# folder it had moved aside comes back when there is none, else what the
# user had added to it moves into the new one. Not while that run still goes
# (an hour at most)
pt_stale() {
  local d n
  [ -d "$1" ] || return 0
  for d in "$1"/.platform-tools-dl.* "$1"/.platform-tools-old.*; do
    [ -e "$d" ] || [ -L "$d" ] || continue
    n=${d##*.}
    [ "$n" = "$$" ] && continue
    case $n in
      ''|*[!0-9]*) ;;
      *) if pt_alive "$n" && [ -z "$(find "$d" -maxdepth 0 -mmin +60 2>/dev/null)" ]; then continue; fi;;
    esac
    case ${d##*/} in
      .platform-tools-old.*)
        if [ ! -e "$1/platform-tools" ] && [ ! -L "$1/platform-tools" ]; then
          mv "$d" "$1/platform-tools" 2>/dev/null && { logl "platform-tools folder restored from ${d##*/}"; continue; }
        else
          pt_merge "$d" "$1/platform-tools" || { logl "${d##*/} kept: not everything could be moved"; continue; }
        fi;;
    esac
    rm -rf "$d" 2>/dev/null && logl "old temporary folder removed: ${d##*/}"
  done
  return 0
}
# pt_mverr: why mv failed ($TMPD/mv), short and in Russian; the message itself
# goes to run-flash.log
pt_mverr() {
  local l
  l=$(head -n 1 "$TMPD/mv" 2>/dev/null)
  logl "mv: $l"
  case $l in
    *'Permission denied'*|*'Operation not permitted'*|*'Read-only file system'*) echo "нет доступа";;
    *[Bb]usy*) echo "папка занята другой программой";;
    *) printf '%s\n' "${l##*: }" | cutc 120;;
  esac
}
# pt_place <new platform-tools> <folder>: the new folder in place of
# <folder>/platform-tools (an old one goes aside first and comes back if the
# new one cannot be put there); PTERR
pt_place() {
  local src=$1 par=$2 dst old had= keep
  dst="$par/platform-tools"; old="$par/.platform-tools-old.$$"
  if [ -e "$dst" ] || [ -L "$dst" ]; then
    had=1
    rm -rf "$old" 2>/dev/null
    if ! mv "$dst" "$old" 2>"$TMPD/mv"; then
      PTERR="не удаётся заменить старую папку «$dst» ($(pt_mverr))"
      return 1
    fi
    PTOLD=$old; PTDST=$dst
  fi
  if ! mv "$src" "$dst" 2>"$TMPD/mv"; then
    PTERR="не удаётся положить папку platform-tools в «$par» ($(pt_mverr))"
    if [ -n "$had" ] && ! mv "$old" "$dst" 2>/dev/null; then
      warnm "ВНИМАНИЕ: старая папка platform-tools сейчас называется «$old» — переименуйте её обратно в platform-tools."
    fi
    PTOLD=; PTDST=
    return 1
  fi
  PTOLD=; PTDST=
  [ -n "$had" ] || return 0
  if pt_merge "$old" "$dst"; then
    rm -rf "$old" 2>/dev/null || logl "old platform-tools folder not removed"
  else
    keep="$par/platform-tools.old-$(date +%Y%m%d-%H%M%S)"
    mv "$old" "$keep" 2>/dev/null || keep=$old
    warnm "ВНИМАНИЕ: не все файлы из старой папки platform-tools удалось перенести в новую — старая папка сохранена как «$keep»."
  fi
  [ "$PTMOVED" -gt 0 ] && say "Файлы из старой папки platform-tools, которых нет в новой ($PTMOVED), перенесены в неё."
  return 0
}
# pt_install <zip> <temporary folder> <folder> <old version> <old adb>: the
# archive is unpacked into the temporary folder and checked, an older adb
# server is stopped, and platform-tools goes into <folder>; PTWHERE (check,
# unpack or place) and PTERR when it fails
pt_install() {
  local x="$2/x" rc
  rm -rf "$x" 2>/dev/null
  pt_unpack "$1" "$x" || return 1
  PTWHERE=check
  pt_check "$x/platform-tools" || return 1
  # (the new adb restarts an older server anyway; it is stopped here with its
  # own adb, and only when the versions differ)
  if [ -n "$5" ] && [ -z "$PTKILLED" ] && [ "$4" != "$PTVER" ]; then
    PTKILLED=1
    run_to 15 "$TMPD/ks" "$5" kill-server; rc=$?
    logl "old adb server stopped: $5 kill-server, rc $rc $(head -c 200 "$TMPD/ks")"
  fi
  PTWHERE=place
  pt_place "$x/platform-tools" "$3"
}
# pt_get <old version> <old adb>: 0 when a fresh adb is in place (ADB,
# ADBVER); 1 when not (the reason is on the screen); 3 when the user said no
pt_get() {
  local oldv=$1 oldp=$2 par st ud up n=1 rc e1= net= disk= m hint ro=
  PTERR=; PTZIP=; PTVER=; PTWHERE=; PTKILLED=
  pt_auto
  if [ "$PTAUTO" = 0 ]; then logl "adb download: off (TAOYAO_ADB_DOWNLOAD=0)"; return 1; fi
  pt_url; rc=$?
  if [ $rc = 2 ]; then echo; warnm "ВНИМАНИЕ: автоматическая загрузка adb недоступна: $PTERR."; return 1; fi
  if [ $rc != 0 ]; then echo; errm "ОШИБКА: $PTERR"; return 1; fi
  if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
    echo; warnm "ВНИМАНИЕ: автоматическая загрузка adb недоступна: на компьютере нет программы curl или wget."; return 1
  fi
  if ! command -v unzip >/dev/null 2>&1 && ! command -v python3 >/dev/null 2>&1 && ! command -v bsdtar >/dev/null 2>&1; then
    echo; warnm "ВНИМАНИЕ: автоматическая загрузка adb недоступна: на компьютере нет программы unzip."; return 1
  fi
  pt_ask "$oldv"; rc=$?
  [ $rc = 0 ] || return $rc
  # (next to the flasher; a folder there that cannot be written: per-user)
  ud=$(pt_user_dir); up=${ud%/*}
  par=$HERE; st="$par/.platform-tools-dl.$$"
  if ! pt_stage "$st"; then
    if [ -z "$ud" ] || ! pt_stage "$up/.platform-tools-dl.$$"; then
      errm "ОШИБКА: не удаётся создать папку для adb ни рядом с флешером, ни в папке пользователя."
      return 1
    fi
    par=$up; st="$up/.platform-tools-dl.$$"; ro=1
    logl "the script folder is read-only: adb goes to the per-user folder"
  fi
  PTSTAGE=$st
  step "Скачиваю Android SDK Platform-Tools с сайта Google…"
  logl "download: $PTZIP into $st"
  while ! pt_fetch "$PTZIP" "$st/platform-tools.zip"; do
    case $PTKIND in net) net=1;; disk) disk=1;; esac
    if [ $n -ge 2 ]; then
      if [ "$e1" = "$PTERR" ]; then m=$PTERR; else m="1-я попытка: $e1; 2-я: $PTERR"; fi
      if [ -n "$disk" ]; then hint=" Освободите место на диске и запустите флешер снова."
      elif [ -n "$net" ]; then hint=" Проверьте подключение к интернету; на рабочем компьютере загрузку может запрещать прокси-сервер или антивирус."
      else hint=" Попробуйте позже."; fi
      errm "ОШИБКА: не удалось скачать Android SDK Platform-Tools ($m).$hint"
      pt_drop; return 1
    fi
    e1=$PTERR
    warnm "Не удалось скачать ($PTERR). Пробую ещё раз…"
    n=$((n + 1)); nap 3
  done
  say "Проверяю скачанный архив…"
  pt_install "$st/platform-tools.zip" "$st" "$par" "$oldv" "$oldp"; rc=$?
  # (the platform-tools folder next to the flasher cannot be replaced, e.g. a
  # program still uses it: the per-user folder, which is searched too)
  if [ $rc != 0 ] && [ "$PTWHERE" = place ] && [ "$par" = "$HERE" ] && [ -n "$ud" ]; then
    warnm "ВНИМАНИЕ: не получилось положить adb рядом с флешером: $PTERR. Сохраняю его в папку пользователя."
    if pt_stage "$up/.platform-tools-dl.$$"; then
      PTSTAGE2="$up/.platform-tools-dl.$$"
      if pt_install "$st/platform-tools.zip" "$PTSTAGE2" "$up" "$oldv" "$oldp"; then rc=0; par=$up; fi
    fi
  fi
  if [ $rc != 0 ]; then
    case $PTWHERE in
      check) errm "ОШИБКА: скачанный архив не прошёл проверку: $PTERR. Он удалён, ничего не установлено.";;
      unpack) errm "ОШИБКА: не удалось распаковать скачанный архив ($PTERR). Он удалён, ничего не установлено.";;
      *) errm "ОШИБКА: не удаётся установить adb: $PTERR. Закройте программы, которые используют папку platform-tools, и запустите флешер снова.";;
    esac
    pt_drop; return 1
  fi
  pt_drop
  ADB="$par/platform-tools/adb"; ADBVER=$PTVER
  logl "adb: $ADB (version $ADBVER, downloaded)"
  goodm "ОК: Android SDK Platform-Tools скачаны и проверены (adb $ADBVER)."
  if [ "$par" != "$HERE" ] && [ -n "$ro" ]; then
    say "В папку флешера нельзя записывать, поэтому adb сохранён в «$par/platform-tools» — там он найдётся и в следующий раз."
  elif [ "$par" != "$HERE" ]; then
    say "adb сохранён в «$par/platform-tools» — там он найдётся и в следующий раз."
  fi
  return 0
}


########################################################################
# devices. scan_devices: one look at "adb devices -l" (extra fields, CR,
# daemon messages tolerated). Sets DSTATE for the chosen phone (SERIAL, or
# the one to choose): none, device, recovery, sideload, unauthorized,
# offline, no permissions, authorizing, connecting, host, rescue,
# bootloader, multi; DSER its serial.
DV_N=0; MULTIPICK=; SERGONE_SAID=
scan_devices() {
  local re='^([^[:space:]]+)[[:space:]]+(no permissions|device|unauthorized|offline|recovery|sideload|bootloader|rescue|authorizing|connecting|host)([[:space:]].*)?$'
  local rem='model:([^[:space:]]+)' red='device:([^[:space:]]+)' rep='product:([^[:space:]]+)'
  local l s st rest n=0 i nt=0 ti= aidx= sidx= other=0 oidx=
  DSTATE=none; DSER=; MULTIPICK=
  run_to 10 "$TMPD/dev" "$ADB" devices -l
  while IFS= read -r l; do
    l=${l%$'\r'}
    case $l in ''|'*'*|'List of devices'*|'adb server'*|'error:'*|'adb: '*) continue;; esac
    [[ $l =~ $re ]] || continue
    s=${BASH_REMATCH[1]}; st=${BASH_REMATCH[2]}; rest=${BASH_REMATCH[3]}
    add_serial "$s"
    DV_S[$n]=$s; DV_ST[$n]=$st; DV_M[$n]=; DV_D[$n]=; DV_P[$n]=
    [[ $rest =~ $rem ]] && DV_M[$n]=${BASH_REMATCH[1]}
    [[ $rest =~ $red ]] && DV_D[$n]=${BASH_REMATCH[1]}
    [[ $rest =~ $rep ]] && DV_P[$n]=${BASH_REMATCH[1]}
    n=$((n + 1))
  done < "$TMPD/dev"
  DV_N=$n
  i=0
  while [ $i -lt $n ]; do
    case "${DV_D[$i]}:${DV_P[$i]}" in "$DEVICE:"*|*":$DEVICE"*) nt=$((nt + 1)); ti=$i;; esac
    [ -n "${ANDROID_SERIAL-}" ] && [ "${DV_S[$i]}" = "$ANDROID_SERIAL" ] && aidx=$i
    [ -n "$SERIAL" ] && [ "${DV_S[$i]}" = "$SERIAL" ] && sidx=$i
    # (a candidate for "the serial changed": not one of the devices that were
    # there when the phone was picked, and not another model)
    if [ -n "$SERIAL" ] && [ "${DV_S[$i]}" != "$SERIAL" ]; then
      case " $OTHERS " in *" ${DV_S[$i]} "*) ;;
        *) case "${DV_D[$i]}:${DV_P[$i]}" in ':'|"$DEVICE:"*|*":$DEVICE"*) other=$((other + 1)); oidx=$i;; esac;;
      esac
    fi
    i=$((i + 1))
  done
  if [ -n "${ANDROID_SERIAL-}" ]; then
    if [ -n "$aidx" ]; then DSER=${DV_S[$aidx]}; DSTATE=${DV_ST[$aidx]}
    else
      DSTATE=none
      [ -z "$SERGONE_SAID" ] && [ $n -gt 0 ] && { SERGONE_SAID=1; warnm "$M_SERIALGONE"; }
    fi
    return 0
  fi
  if [ -n "$SERIAL" ]; then
    if [ -n "$sidx" ]; then DSER=$SERIAL; DSTATE=${DV_ST[$sidx]}; return 0; fi
    # (the serial normally stays the same in Android, recovery and sideload;
    # one other phone in the state the flow waits for: that is it)
    if [ $other = 1 ]; then
      case " $W_WANT $W_ALSO " in *" ${DV_ST[$oidx]} "*)
        logl "serial changed: $SERIAL -> ${DV_S[$oidx]}"
        SERIAL=${DV_S[$oidx]}; DSER=$SERIAL; DSTATE=${DV_ST[$oidx]}; return 0;;
      esac
    fi
    DSTATE=none; return 0
  fi
  if [ $n = 0 ]; then DSTATE=none; return 0; fi
  if [ $n = 1 ]; then DSER=${DV_S[0]}; DSTATE=${DV_ST[0]}; return 0; fi
  if [ $nt = 1 ]; then DSER=${DV_S[$ti]}; DSTATE=${DV_ST[$ti]}; MULTIPICK=1; return 0; fi
  DSTATE=multi
}
# pick_device: several phones and none of them clearly taoyao: ask
pick_device() {
  local i
  nl_dots
  warnm "$M_MULTI_ASK"
  i=0
  while [ $i -lt "$DV_N" ] && [ $i -lt 9 ]; do
    # (the whole serial on the screen, to tell two phones apart; the log
    # masks it: scan_devices added it to the mask)
    say "  $((i + 1))  ${DV_M[$i]:-?} (${DV_D[$i]:-${DV_P[$i]:-?}}), состояние: ${DV_ST[$i]}, серийный номер ${DV_S[$i]}"
    i=$((i + 1))
  done
  bell
  while :; do
    qkey
    case $KEY in
      [1-9]) if [ "$KEY" -le "$DV_N" ]; then
               SERIAL=${DV_S[$((KEY - 1))]}; logl "device picked: $KEY"
               OTHERS=; i=0
               while [ $i -lt "$DV_N" ]; do [ "${DV_S[$i]}" != "$SERIAL" ] && OTHERS="$OTHERS ${DV_S[$i]}"; i=$((i + 1)); done
               return 0
             fi;;
      ESC|INT|NO) logl "device list: stopped (phase ${PHASE:-pre})"; warn_phase; finish "$(stop_rc $RC_CANCEL)";;
    esac
  done
}

# wait_phone <wanted states> <limit s> <hint> <phase>: polls "adb devices"
# until the phone is in one of the wanted states (or in W_ALSO), printing a
# dot each poll, the hint again (with the bell for a tap on the phone) every
# T_HINT, and what it sees when the state changes. Hint: the name of a hint
# variable, NONE (the "phone not found" text when nobody is there) or
# empty. Options (reset after each call): W_ALSO more states that end the
# wait; W_UNAUTH seconds of "unauthorized" that end it (0: never); W_POLL
# seconds between polls; W_ESC=1: Esc ends the wait (WSTATE=skip); W_SOFT=1:
# the limit ends the wait (WSTATE=timeout), no question; W_LIMITMSG: a text
# shown when the limit is reached; W_MORE: the question at the limit
# (default M_WAIT_MORE). Sets WSTATE, WGONE (the phone was gone
# meanwhile), WSECS. At the limit: Enter waits more, Esc stops (exit 11), no
# key for another limit: exit 10.
W_WANT=
wait_phone() {
  local want=$1 lim=$2 hint=$3 ph=$4 htext= t0=$SECONDS last= el nexth asked= askt=0 offt= recd= i
  local ut= poll=${W_POLL:-$T_POLL} also=$W_ALSO wun=${W_UNAUTH:-0} wesc=$W_ESC kk soft=$W_SOFT lmsg=$W_LIMITMSG unote= wm more
  more=${W_MORE:-$M_WAIT_MORE}
  W_ALSO=; W_UNAUTH=0; W_POLL=; W_ESC=; W_SOFT=; W_LIMITMSG=; W_MORE=
  W_WANT=$want
  [ -n "$ph" ] && PHASE=$ph
  WGONE=; WSTATE=
  case $hint in ''|NONE) ;; *) eval "htext=\$$hint";; esac
  [ -n "$htext" ] && hintm "$htext"
  nexth=$T_HINT
  logl "wait for: $want ${also:+(or $also) }limit ${lim}s"
  while :; do
    MULTIPICK=
    scan_devices
    if [ "$DSTATE" = multi ]; then pick_device; scan_devices; fi
    if [ "$DSTATE" != "$last" ]; then
      logl "device state: $DSTATE"
      case " $want $also " in *" $DSTATE "*) ;;
        *)
          case $DSTATE in
            none) WGONE=1
                  if [ "$hint" = NONE ]; then
                    nl_dots; warnm "$M_WAIT_NONE1"
                    [ "$(uname -s 2>/dev/null)" = Darwin ] && say "$M_WAIT_MAC"
                    say "$(fill "$M_WAIT_NONE2" min $(( (lim + 59) / 60 )))"
                  fi;;
            # (the system asks on its screen; a recovery shows the state,
            # M_UNAUTH_REC follows after 60 s in the first wait)
            unauthorized) case " $want " in *" device "*) warnm "$M_UNAUTH";; *) warnm "$M_UNAUTH_INREC";; esac;;
            authorizing|connecting|host) say "$M_AUTHORIZING";;
            offline) warnm "$M_OFFLINE";;
            'no permissions') warnm "$M_NOPERM";;
            bootloader) warnm "$M_FASTBOOT";;
            sideload) if [ "$PHASE" != boot ] && [ -z "$Q_KIND" ]; then
                        [ -n "$SENT_ANY" ] && hintm "$M_NEED_LOG_FIRST"
                        [ "$hint" != H_LEAVE_SIDELOAD ] && hintm "$H_LEAVE_SIDELOAD"
                      fi;;
            rescue) warnm "Телефон в режиме восстановления Android (rescue) — флешер с ним не работает. Перезагрузите телефон.";;
          esac;;
      esac
      last=$DSTATE
    fi
    case " $want $also " in *" $DSTATE "*)
      if [ -z "$SERIAL" ] && [ -n "$DSER" ]; then
        OTHERS=; i=0
        while [ $i -lt "$DV_N" ]; do [ "${DV_S[$i]}" != "$DSER" ] && OTHERS="$OTHERS ${DV_S[$i]}"; i=$((i + 1)); done
      fi
      SERIAL=$DSER
      [ -n "$MULTIPICK" ] && [ -z "$PICKSAID" ] && { PICKSAID=1; say "$M_MULTI_PICKED"; }
      WSTATE=$DSTATE; WSECS=$((SECONDS - t0)); nl_dots; return 0;;
    esac
    # unauthorized for W_UNAUTH s: the caller decides
    if [ "$DSTATE" = unauthorized ]; then
      [ -z "$ut" ] && ut=$SECONDS
      if [ -z "$unote" ] && [ $((SECONDS - ut)) -ge 60 ]; then
        case " $want " in *" device "*) case " $want " in *" recovery "*) unote=1; nl_dots; warnm "$M_UNAUTH_REC";; esac;; esac
      fi
      if [ "$wun" -gt 0 ] && [ $((SECONDS - ut)) -ge "$wun" ]; then WSTATE=unauthorized; nl_dots; return 0; fi
    else ut=; fi
    # offline for T_OFFLINE: one reconnect
    if [ "$DSTATE" = offline ]; then
      [ -z "$offt" ] && offt=$SECONDS
      if [ -z "$recd" ] && [ $((SECONDS - offt)) -ge "$T_OFFLINE" ]; then
        recd=1; run_to 10 "$TMPD/rc" "$ADB" reconnect offline; logl "adb reconnect offline: $(head -c 200 "$TMPD/rc")"
      fi
    else offt=; fi
    el=$((SECONDS - t0))
    if [ $el -ge $nexth ]; then
      nexth=$((nexth + T_HINT))
      if [ -z "$asked" ]; then
        say "$(fill "$M_WAITED" t "$(elapsed $el)")"
        # (not while the phone is there but refuses this computer: the tap
        # the hint asks for is done, M_UNAUTH said what is wrong)
        if [ "$DSTATE" = unauthorized ]; then :; elif [ -n "$htext" ]; then hintm "$htext"; fi
      fi
    fi
    if [ $el -ge "$lim" ] && [ -n "$soft" ]; then WSTATE=timeout; WSECS=$el; nl_dots; return 0; fi
    if [ $el -ge "$lim" ] && [ -z "$asked" ]; then
      [ -n "$lmsg" ] && warnm "$lmsg"
      [ -n "$TTYOK" ] || { warn_phase; finish "$(stop_rc $RC_FAIL)"; }
      asked=1; askt=$SECONDS
      if [ "$lim" -ge 60 ]; then wm="$(( (lim + 30) / 60 )) мин"; else wm=$(elapsed "$lim"); fi
      flushkeys; warnm "$(fill "$more" t "$wm")"; bell
    fi
    if [ -n "$asked" ] && [ $((SECONDS - askt)) -ge "$lim" ]; then
      warn_phase; finish "$(stop_rc $RC_FAIL)"
    fi
    if [ -n "$asked$wesc" ]; then
      kk=0
      while [ $kk -lt "$poll" ]; do
        readkey_t 1; check_intr
        case $KEY in
          ENTER|YES) [ -n "$asked" ] && { asked=; t0=$SECONDS; nexth=$T_HINT; say "$M_GOON"; [ -n "$htext" ] && hintm "$htext"; }; break;;
          ESC|INT|NO) if [ -n "$wesc" ]; then WSTATE=skip; nl_dots; return 0; fi
                   if [ -n "$asked" ]; then warn_phase; finish "$(stop_rc $RC_CANCEL)"; fi;;
        esac
        [ -n "$BOOTSKIP" ] && { WSTATE=skip; nl_dots; return 0; }
        kk=$((kk + 1))
      done
    else
      nap "$poll"
      [ -n "$BOOTSKIP" ] && { WSTATE=skip; nl_dots; return 0; }
    fi
    dot
  done
}
# state_now: one look, DSTATE of the chosen phone
state_now() { local w=$W_WANT; scan_devices; W_WANT=$w; }

########################################################################
# files on the PC: sha256, size, time, free space, zip reading
sha256_of() {  # <file>: the hex digest (empty on failure)
  local h
  if command -v sha256sum >/dev/null 2>&1; then h=$(sha256sum < "$1" 2>/dev/null)
  elif command -v shasum >/dev/null 2>&1; then h=$(shasum -a 256 < "$1" 2>/dev/null)
  else h=$(openssl dgst -sha256 < "$1" 2>/dev/null | awk '{ print $NF }'); fi
  h=${h%% *}
  case $h in *[!0-9a-f]*|'') h=;; esac
  [ ${#h} = 64 ] || h=
  printf '%s' "$h"
}
fsize() { wc -c < "$1" 2>/dev/null | tr -d ' '; }
mtime_of() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo 0; }
size_h() {  # <bytes>: "3,0 МБ" / "512 КБ"
  awk -v b="${1:-0}" 'BEGIN { if (b >= 1073741824) printf "%.1f ГБ", b / 1073741824; else if (b >= 1048576) printf "%.1f МБ", b / 1048576; else printf "%d КБ", (b + 1023) / 1024 }' | tr . ,
}
free_mb() { df -Pk "$1" 2>/dev/null | awk 'NR == 2 { print int($4 / 1024) }'; }
# vercmp <a> <b>: numerically part by part ("0.18" < "0.19" < "1.0"; a
# missing part is 0); prints -1, 0 or 1
vercmp() {
  local a=$1 b=$2 x y
  while [ -n "$a" ] || [ -n "$b" ]; do
    x=${a%%.*}; y=${b%%.*}
    case $a in *.*) a=${a#*.};; *) a=;; esac
    case $b in *.*) b=${b#*.};; *) b=;; esac
    x=$(printf '%s' "${x:-0}" | sed 's/^0*//'); y=$(printf '%s' "${y:-0}" | sed 's/^0*//')
    x=${x:-0}; y=${y:-0}
    if [ ${#x} -ne ${#y} ]; then
      [ ${#x} -gt ${#y} ] && { echo 1; return; }
      echo -1; return
    fi
    [[ $x > $y ]] && { echo 1; return; }
    [[ $x < $y ]] && { echo -1; return; }
  done
  echo 0
}
lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
safe_name() {  # <text>: [A-Za-z0-9._-] only, runs of _ collapsed, at most 40 characters
  local s
  s=$(printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_' | tr -s '_')
  s=${s#_}; s=${s:0:40}; s=${s%_}
  printf '%s' "$s"
}

# zip tools: unzip, else python3 (zipfile), else bsdtar. unzip treats
# [ ] * ? in an archive name as a pattern, so it runs in the zip's folder
# with the plain name (our names hold none of these).
detect_ziptool() {
  if command -v unzip >/dev/null 2>&1; then ZIPTOOL=unzip
  elif command -v python3 >/dev/null 2>&1; then ZIPTOOL=python
  elif command -v bsdtar >/dev/null 2>&1; then ZIPTOOL=bsdtar
  else ZIPTOOL=; fi
  logl "zip tool: ${ZIPTOOL:-none}"
}
zip_list() {  # <zip>: the entry names, one per line
  local d=${1%/*} b=${1##*/}
  case $ZIPTOOL in
    unzip) (cd -- "$d" && unzip -Z1 "$b") 2>/dev/null | tr -d '\r';;
    python) python3 -I -c 'import sys, zipfile
for n in zipfile.ZipFile(sys.argv[1]).namelist(): print(n)' "$1" 2>/dev/null;;
    bsdtar) (cd -- "$d" && bsdtar -tf "$b") 2>/dev/null;;
    *) return 1;;
  esac
}
zip_cat() {  # <zip> <entry>: the entry on stdout
  local d=${1%/*} b=${1##*/}
  case $ZIPTOOL in
    unzip) (cd -- "$d" && unzip -p "$b" "$2") 2>/dev/null;;
    python) python3 -I -c 'import sys, zipfile
sys.stdout.buffer.write(zipfile.ZipFile(sys.argv[1]).read(sys.argv[2]))' "$1" "$2" 2>/dev/null;;
    bsdtar) (cd -- "$d" && bsdtar -xOf "$b" "$2") 2>/dev/null;;
    *) return 1;;
  esac
}
zip_test() {  # <zip>: every entry readable, CRCs right
  local d=${1%/*} b=${1##*/}
  case $ZIPTOOL in
    unzip) (cd -- "$d" && unzip -tq "$b") >/dev/null 2>&1;;
    python) python3 -I -c 'import sys, zipfile
sys.exit(0 if zipfile.ZipFile(sys.argv[1]).testzip() is None else 1)' "$1" >/dev/null 2>&1;;
    bsdtar) (cd -- "$d" && bsdtar -xOf "$b") >/dev/null 2>&1;;
    *) return 1;;
  esac
}
# zip_text <zip> <entry> <file>: an entry as text (CR removed) into <file>
zip_text() { zip_cat "$1" "$2" | tr -d '\r' > "$3"; [ -s "$3" ]; }

########################################################################
# kernel zips (section 4)
# name_parse <file name>: NP_SERIES NP_VER (as written) NP_MAJ NP_MIN NP_PAT
# NP_NOKSU NP_COPY; false when it is not a kernel zip name
name_parse() {
  local ln
  ln=$(lower "$1")
  NP_SERIES=; NP_VER=; NP_MAJ=; NP_MIN=; NP_PAT=; NP_NOKSU=; NP_COPY=
  [[ $ln =~ $ZIP_SKIP_RE ]] && return 1
  [[ $ln =~ $ZIP_RE ]] || return 1
  NP_SERIES=${BASH_REMATCH[1]}; NP_MAJ=${BASH_REMATCH[2]}; NP_MIN=${BASH_REMATCH[3]}
  NP_PAT=${BASH_REMATCH[5]}; NP_NOKSU=${BASH_REMATCH[6]}; NP_COPY=${BASH_REMATCH[8]}
  NP_VER=$NP_MAJ.$NP_MIN${NP_PAT:+.$NP_PAT}
  # (absurd numbers are not a release)
  [ ${#NP_MAJ} -le 6 ] && [ ${#NP_MIN} -le 6 ] && [ ${#NP_PAT} -le 6 ] && [ ${#NP_COPY} -le 6 ] && [ ${#NP_SERIES} -le 13 ]
}

# check_zip <path>: checks Z1-Z8 of one zip. Sets CZ_OK (1/empty), CZ_MSG
# (the full error), CZ_SHORT (the reason for "skipped"), and on success
# CZ_VER CZ_SERIES CZ_KREL CZ_KSU CZ_NOKSU CZ_COPY CZ_GEN CZ_BN CZ_STORES
# CZ_LAST CZ_KSTR CZ_SHAMSG
check_zip() {
  local p=$1 n=${1##*/} e l x inner dev rel rser rver vline vv l1 sf h want k
  CZ_OK=; CZ_MSG=; CZ_SHORT=; CZ_SHAMSG=; CZ_GEN=GEN1; CZ_BN=; CZ_STORES=; CZ_LAST=; CZ_KSTR=; CZ_INNER=; CZ_RUN=
  name_parse "$n" || { CZ_MSG=$(fill "$M_ZIP_NOTOURS" name "$n" entry "имени taoyao-<серия>-v<версия>.zip"); CZ_SHORT="другое имя"; return 1; }
  CZ_VER=$NP_VER; CZ_SERIES=$NP_SERIES; CZ_NOKSU=$NP_NOKSU; CZ_COPY=$NP_COPY
  # Z1 opens as a zip
  if ! zip_list "$p" > "$TMPD/zl" || [ ! -s "$TMPD/zl" ]; then
    CZ_MSG=$(fill "$M_ZIP_BROKEN" name "$n"); CZ_SHORT="не открывается как ZIP (повреждён или скачан не до конца)"; return 1
  fi
  # Z2 a wrapper (a GitHub artifact download holding the kernel zip): every
  # entry is a zip, or an entry is a kernel zip and there is no installer
  if ! grep -qv '\.[zZ][iI][pP]$' "$TMPD/zl" || wrap_inner "$TMPD/zl"; then
    if wrap_inner "$TMPD/zl"; then CZ_INNER=$WI; inner=${WI##*/}
    else inner=$(head -n 1 "$TMPD/zl"); inner=${inner##*/}; fi
    CZ_MSG=$(fill "$M_ZIP_WRAPPER" name "$n" inner "$inner"); CZ_SHORT="архив-обёртка, внутри $inner"
    name_parse "$n"
    return 1
  fi
  # Z3 our files
  for e in $ZIP_NEED; do
    if ! grep -qxF "$e" "$TMPD/zl"; then
      CZ_MSG=$(fill "$M_ZIP_NOTOURS" name "$n" entry "$e"); CZ_SHORT="не zip ядра taoyao (нет $e)"; return 1
    fi
  done
  # Z4 AnyKernel3 for taoyao
  dev=
  if zip_text "$p" anykernel.sh "$TMPD/ak.sh"; then
    dev=$(sed -n 's/^device\.name1=//p' "$TMPD/ak.sh" | head -n 1)
    CZ_KSTR=$(sed -n 's/^kernel\.string=//p' "$TMPD/ak.sh" | head -n 1)
  fi
  x=1
  zip_cat "$p" META-INF/com/google/android/update-binary | grep -q "$UB_MARK" || x=
  [ -n "$x" ] && { grep -Eq "$AK_DEVICE_RE" "$TMPD/ak.sh" && grep -Eq "$AK_CHECK_RE" "$TMPD/ak.sh"; } || x=
  if [ -z "$x" ]; then
    CZ_MSG=$(fill "$M_ZIP_NOTTAOYAO" name "$n" dev "${dev:-?}"); CZ_SHORT="не для taoyao (устройство «${dev:-?}»)"; return 1
  fi
  # Z5 kernel.release names the same series and version as the file name
  rel=$(zip_cat "$p" vmods/kernel.release | tr -d '\r' | head -n 1 | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
  vline=$(zip_cat "$p" version | tr -d '\r' | grep -E "$VERFILE_RE" | head -n 1)
  if [[ $rel =~ $REL_RE ]]; then rser=${BASH_REMATCH[1]}; rver=${BASH_REMATCH[2]}; else rser=; rver=; fi
  if [ -z "$rser" ] || [ "$rser" != "$CZ_SERIES" ] || [ "$(vercmp "$rver" "$CZ_VER")" != 0 ]; then
    CZ_MSG=$(fill "$M_ZIP_RENAMED" name "$n" ver "$CZ_VER" rel "${rel:-?}" vline "${vline:-?}"); CZ_SHORT="имя говорит v$CZ_VER, а внутри ядро ${rel:-?}"; return 1
  fi
  CZ_KREL=$rel
  # Z6 the version file says the same
  if [ -z "$vline" ]; then
    CZ_MSG=$(fill "$M_ZIP_NOVERSION" name "$n"); CZ_SHORT="нет номера версии"; return 1
  fi
  [[ $vline =~ $VERFILE_RE ]] && vv=${BASH_REMATCH[1]}
  l1=$(zip_cat "$p" version | tr -d '\r' | head -n 1)
  CZ_KSU=
  if [[ $l1 =~ $VERLINE1_RE ]]; then x=${BASH_REMATCH[1]}; CZ_KSU=${BASH_REMATCH[2]}; else x=; fi
  want=; [ "$CZ_KSU" = "$KSU_NONE" ] && want=-noksu
  if [ -n "$x" ] && [ "$want" != "$CZ_NOKSU" ]; then
    if [ -n "$CZ_NOKSU" ]; then CZ_SHORT="в имени -noksu, а внутри ядро с KernelSU (${CZ_KSU:-?})"; x='сборка без KernelSU (noksu)'
    else CZ_SHORT="в имени нет -noksu, а внутри ядро без KernelSU"; x='сборка с KernelSU'; fi
    CZ_MSG=$(fill "$M_ZIP_KSU" name "$n" want "$x" ksu "$CZ_KSU"); return 1
  fi
  if [ "$(vercmp "$vv" "$CZ_VER")" != 0 ] || [ "$x" != "$rel" ]; then
    CZ_MSG=$(fill "$M_ZIP_RENAMED" name "$n" ver "$CZ_VER" rel "$rel" vline "$l1 / $vline"); CZ_SHORT="имя не совпадает с файлом version («$vline»)"; return 1
  fi
  # Z7 a .sha256 next to it
  sf=
  for x in "$p.sha256" "${p%.*}.zip.sha256" "$(printf '%s' "$p" | sed -E 's/ ?\([0-9]+\)(\.[zZ][iI][pP])$/\1/').sha256"; do
    [ -f "$x" ] && { sf=$x; break; }
  done
  if [ -n "$sf" ]; then
    want=$(tr -d '\r' < "$sf" | grep -oE '[0-9a-fA-F]{64}' | head -n 1 | tr 'A-F' 'a-f')
    h=$(q sha256_of "$p")
    if [ -z "$want" ] || [ "$h" != "$want" ]; then
      CZ_MSG=$(fill "$M_ZIP_SHA_BAD" name "$n" file "${sf##*/}"); CZ_SHORT="контрольная сумма не совпадает с ${sf##*/}"; return 1
    fi
    CZ_SHAMSG=$(fill "$M_ZIP_SHA_OK" file "${sf##*/}")
  fi
  # Z8 every entry reads back (CRC)
  if ! zip_test "$p"; then
    CZ_MSG=$(fill "$M_ZIP_BROKEN" name "$n"); CZ_SHORT="повреждён (ошибка CRC)"; return 1
  fi
  # values from the zip's tools/ty-lib.sh (4.4)
  if zip_text "$p" tools/ty-lib.sh "$TMPD/tylib.sh"; then
    CZ_BN=$(sed -n 's/^TY_BACKUPNAME=\(.*\);$/\1/p' "$TMPD/tylib.sh" | head -n 1)
    CZ_STORES=$(sed -n 's/^TY_STORES="\(.*\)";$/\1/p' "$TMPD/tylib.sh" | head -n 1)
    CZ_LAST=$(grep -oE '/taoyao-[A-Za-z0-9.]+-last\.log' "$TMPD/tylib.sh" | head -n 1); CZ_LAST=${CZ_LAST#/}
    grep -q "$GEN2_MARK" "$TMPD/tylib.sh" && CZ_GEN=GEN2
    grep -q "${KEY_RUN%: }" "$TMPD/tylib.sh" && CZ_RUN=1
  fi
  case $CZ_BN in *[!A-Za-z0-9._-]*) CZ_BN=;; esac
  case $CZ_STORES in *[!A-Za-z0-9._/\ -]*) CZ_STORES=;; esac
  CZ_OK=1
  return 0
}

# zip_key <path>: "<sort key>\t<path>" of a name_parse'd zip: version
# descending (the port's own build number, whatever the kernel series),
# for one version the newer series first, the KernelSU build before
# -noksu, the name without "(n)" first, then the newer file
zip_key() {
  local nk=0 sa=${NP_SERIES%%.*} sb=${NP_SERIES#*.}
  [ -n "$NP_NOKSU" ] && nk=1
  printf '%06d%06d%06d%06d%06d%d%06d%012d\t%s\n' $((999999 - 10#$NP_MAJ)) $((999999 - 10#$NP_MIN)) $((999999 - 10#${NP_PAT:-0})) \
    $((999999 - 10#$sa)) $((999999 - 10#$sb)) "$nk" $((10#${NP_COPY:-0})) $((999999999999 - $(mtime_of "$1"))) "$1"
}
# wrap_inner <entry list>: WI = the first entry named like a kernel zip,
# when this zip is not one itself (no installer in it); false otherwise
wrap_inner() {
  local e
  WI=
  grep -qxF META-INF/com/google/android/update-binary "$1" && return 1
  while IFS= read -r e; do
    name_parse "${e##*/}" && { WI=$e; return 0; }
  done < "$1"
  return 1
}
# unwrap_zips: every wrapper found (ZWRAPS "path|inner" lines) whose kernel
# version is not there yet: offer to unpack its kernel zip next to it (a
# free name: "(n)" added when the name is taken). 0 when something was unpacked
unwrap_zips() {
  local l w inner ib d t n i have did=1
  [ -n "$ZWRAPS" ] || return 1
  printf '%s' "$ZWRAPS" > "$TMPD/wraps"
  while IFS= read -r l; do
    [ -n "$l" ] || continue
    w=${l%%|*}; inner=${l#*|}; ib=${inner##*/}; d=${w%/*}
    name_parse "$ib" || continue
    have=; i=0
    while [ $i -lt "$ZOK_N" ]; do [ "${ZOK_V[$i]}" = "$NP_VER$NP_NOKSU" ] && have=1; i=$((i + 1)); done
    [ -n "$have" ] && { logl "wrapper $w: v$NP_VER$NP_NOKSU is there already"; continue; }
    prompt_yes "$(fill "$M_ZIP_WRAP_ASK" name "${w##*/}" inner "$ib" dir "$d")" 1 || continue
    t="$d/$ib"; n=1
    while [ -e "$t" ]; do t="$d/${ib%.*} ($n).zip"; n=$((n + 1)); done
    if zip_cat "$w" "$inner" > "$t.part" && [ -s "$t.part" ] && mv -f "$t.part" "$t"; then
      goodm "$(fill "$M_ZIP_UNWRAPPED" path "$t")"
      [ "$ARGPATH" = "$w" ] && ARGPATH=$t
      did=0
    else
      rm -f "$t.part"; errm "$(fill "$M_ZIP_UNWRAP_FAIL" inner "$ib" name "${w##*/}")"
    fi
  done < "$TMPD/wraps"
  return $did
}

# find_zips: candidates (section 4.1, 4.2), checked newest first. Sets
# ZOK_N and ZOK_P[i] (valid zips, newest first), ZSKIP (skipped messages),
# ZNEAR (look-alike names), ZARG_BAD (an explicit zip failed: its message)
find_zips() {
  local dirs= d f b key i n=0 seen=" " lastkey= lastsha= h vk
  ZOK_N=0; ZSKIP=; ZNEAR=; ZARG_BAD=; ZEXPL=; ZWRAPS=
  : > "$TMPD/zc"
  if [ -n "$ARGPATH" ] && [ -f "$ARGPATH" ]; then
    ZEXPL=1
    printf '%s\t%s\n' 0 "$ARGPATH" > "$TMPD/zc"
    # (a wrapper given by its path, whatever its name)
    if ! name_parse "${ARGPATH##*/}" && zip_list "$ARGPATH" > "$TMPD/zl" 2>/dev/null && wrap_inner "$TMPD/zl"; then
      ZWRAPS="$ARGPATH|$WI
"
    fi
  else
    if [ -n "$ARGPATH" ]; then dirs=$ARGPATH; else dirs=$HERE; [ "$CWD" != "$HERE" ] && dirs="$HERE
$CWD"; fi
    while IFS= read -r d; do
      [ -d "$d" ] || continue
      for f in "$d"/*; do
        [ -f "$f" ] || continue
        b=${f##*/}
        case $b in *.[zZ][iI][pP]) ;; *) continue;; esac
        case $seen in *" $f "*) continue;; esac
        seen="$seen$f "
        if name_parse "$b"; then
          zip_key "$f" >> "$TMPD/zc"
        else
          case $(lower "$b") in
            taoyao-logs-*|taoyao-flash-*|taoyao-restore-*) ;;
            taoyao*.zip)
              # (a look-alike that holds a kernel zip is a wrapper: offered for unpacking)
              if zip_list "$f" > "$TMPD/zl" 2>/dev/null && wrap_inner "$TMPD/zl"; then
                ZWRAPS="$ZWRAPS$f|$WI
"
              else
                ZNEAR="${ZNEAR:+$ZNEAR, }$b"
              fi;;
          esac
        fi
      done
    done <<EOF
$dirs
EOF
    sort -o "$TMPD/zc" "$TMPD/zc"
  fi
  while IFS="$(printf '\t')" read -r key f; do
    [ -n "$f" ] || continue
    b=${f##*/}
    name_parse "$b"
    # two names of one version with the same bytes: the first (without "(n)") only
    vk="$NP_MAJ.$NP_MIN.${NP_PAT:-0}$NP_NOKSU"
    if [ "$vk" = "$lastkey" ]; then
      h=$(q sha256_of "$f")
      if [ -n "$h" ] && [ "$h" = "$lastsha" ]; then logl "same as the zip before: $b"; continue; fi
    else
      lastkey=$vk; lastsha=$(q sha256_of "$f")
    fi
    if check_zip "$f"; then
      ZOK_P[$ZOK_N]=$f; ZOK_V[$ZOK_N]=$CZ_VER$CZ_NOKSU; ZOK_N=$((ZOK_N + 1))
      [ $ZOK_N -ge 9 ] && break
    else
      logl "zip rejected: $b: $CZ_SHORT"
      [ -n "$CZ_INNER" ] && ZWRAPS="$ZWRAPS$f|$CZ_INNER
"
      if [ -n "$ZEXPL" ]; then ZARG_BAD=$CZ_MSG
      else ZSKIP="$ZSKIP$(fill "$M_ZIP_SKIPPED" name "$b" reason "$CZ_SHORT")
"; fi
    fi
  done < "$TMPD/zc"
}

# use_zip <path>: check it again and make it the chosen one (values of 4.4)
use_zip() {
  check_zip "$1" || return 1
  ZPATH=$1; ZNAME=${1##*/}; ZDIR=${1%/*}
  ZVER=$CZ_VER; ZSERIES=$CZ_SERIES; KREL=$CZ_KREL; ZKSU=$CZ_KSU; ZNOKSU=$CZ_NOKSU; ZCOPY=$CZ_COPY
  ZGEN=$CZ_GEN; KSTRING=$CZ_KSTR; ZSHAMSG=$CZ_SHAMSG; ZRUN=$CZ_RUN
  ZSIZE=$(q fsize "$1")
  if [ -n "$CZ_BN" ]; then BACKUP_NAME=$CZ_BN; else logl "ty-lib.sh: no TY_BACKUPNAME, default $BACKUP_NAME"; fi
  if [ -n "$CZ_STORES" ]; then STORES=$CZ_STORES; else logl "ty-lib.sh: no TY_STORES, default"; fi
  if [ -n "$CZ_LAST" ]; then LAST_LOG=$CZ_LAST; else logl "ty-lib.sh: no last log name, default $LAST_LOG"; fi
  logl "zip: $ZNAME v$ZVER release $KREL ksu $ZKSU gen $ZGEN; $KSTRING; backup $BACKUP_NAME, stores $STORES, last log $LAST_LOG"
  return 0
}
# show_zip: the found / chosen lines (M_ZIP_FOUND / SEVERAL, COPY, INFO)
show_zip() {
  if [ "$ZOK_N" -gt 1 ]; then
    say "$(fill "$M_ZIP_SEVERAL" n "$ZOK_N" ver "$ZVER$ZNOKSU" name "$ZNAME")"
    if [ -n "$MENU" ]; then say "$M_ZIP_SEVERAL_MENU"; else say "$M_ZIP_SEVERAL_CMD"; fi
  else
    goodm "$(fill "$M_ZIP_FOUND" ver "$ZVER$ZNOKSU" name "$ZNAME")"
  fi
}
show_zip_info() {
  [ -n "$ZCOPY" ] && goodm "$(fill "$M_ZIP_COPY" name "$ZNAME" k "$ZCOPY" ver "$ZVER")"
  [ -n "$ZSHAMSG" ] && goodm "$ZSHAMSG"
  say "$(fill "$M_ZIP_INFO1" name "$ZNAME" size "$(size_h "$ZSIZE")")"
  say "$(fill "$M_ZIP_INFO2" rel "$KREL" ksu "${ZKSU:-?}")"
}

########################################################################
# phone probes (section 6)
ADBROOT=
# probe_android: P_ANDROID; waits for the end of the boot and the first
# unlock (T_USER). Sets A_* and KR, FPR, BATP, SLOT, PNOW
probe_android() {
  local waited=0 shown= bc ce sd next=$T_HINT nl=0
  while :; do
    if ! dev_call 30 0 "$(pcmd "$P_ANDROID")" || ! probe_ok; then
      if lost && [ $nl -lt 5 ]; then nl=$((nl + 1)); nap 2; wait_phone device "$T_USER" "" ""; continue; fi
      fail "$(fill "$M_PHONE_NOANSWER" line "$(cutc 120 < "$TMPD/dc.out")")"
    fi
    bc=$(kv sys.boot_completed); ce=$(kv sys.user.0.ce_available); sd=$(kv sd)
    if [ "$bc" != 1 ]; then
      [ -z "$shown" ] && { shown=boot; say "$M_WAIT_BOOT"; }
    elif [ "$ce" != true ] && [ "$sd" != 1 ]; then
      [ "$shown" != lock ] && { shown=lock; hintm "$M_UNLOCK_SCREEN"; }
    else
      break
    fi
    if [ $waited -ge "$T_USER" ]; then fail "ОШИБКА: телефон не загрузился или не был разблокирован за $((T_USER / 60)) мин."; fi
    nap 5; waited=$((waited + 5))
    if [ $waited -ge $next ]; then next=$((next + T_HINT)); say "$(fill "$M_WAITED" t "$(elapsed $waited)")"; [ "$shown" = lock ] && hintm "$M_UNLOCK_SCREEN"; fi
  done
  A_DEV=$(kv ro.product.device); A_BDEV=$(kv ro.build.product); A_VDEV=$(kv ro.product.vendor.device)
  A_VDEV2=$(kv ro.vendor.product.device); A_HW=$(kv ro.boot.hwname); A_MODEL=$(kv ro.product.model)
  FPR=$(kv ro.build.fingerprint); A_ROM=$(kv ro.build.display.id); A_REL=$(kv ro.build.version.release)
  # (the ROM build: ro.build.date.utc of /system/build.prop, which Play
  # Integrity modules do not touch; getprop only when the file cannot be read)
  A_RID=$(kv romutc); A_RIDF=file
  case $A_RID in ''|*[!0-9]*) A_RID=$(kv ro.build.date.utc); A_RIDF=getprop;; esac
  case $A_RID in ''|*[!0-9]*) A_RID=; A_RIDF=;; esac
  logl "ROM build: ${A_RID:-?} ${A_RIDF:+($A_RIDF)}, fingerprint ${FPR:-?}"
  A_SLOTP=$(kv ro.boot.slot_suffix); A_LOCKED=$(kv ro.boot.flash.locked); A_VBS=$(kv ro.boot.verifiedbootstate)
  A_VDS=$(kv ro.boot.vbmeta.device_state)
  A_MIOS=$(kv ro.mi.os.version.name)$(kv ro.miui.ui.version.name)
  A_CUSTOM=$(kv ro.lineage.version)$(kv ro.modversion)$(kv ro.crdroid.version)$(kv ro.evolution.version)
  KR=$(kv kr); BATP=$(kv bat); A_DF=$(kv dfdata); PNOW=$(kv now)
  SLOT=$A_SLOTP
  A_STOCKHY=; [ -n "$A_MIOS" ] && [ -z "$A_CUSTOM" ] && A_STOCKHY=1
  # (the ROM on the phone line: stock HyperOS named so)
  A_ROMLBL=${A_ROM:-?}; [ -n "$A_STOCKHY" ] && A_ROMLBL="HyperOS ($A_ROMLBL)"
  return 0
}
is_taoyao() {  # <values...>: one of them is the device name
  local v
  for v in "$@"; do [ "$v" = "$DEVICE" ] && return 0; done
  return 1
}
check_taoyao_android() {
  is_taoyao "$A_DEV" "$A_BDEV" "$A_VDEV" "$A_VDEV2" "$A_HW" && return 0
  fail "$(fill "$M_NOT_TAOYAO" model "${A_MODEL:-?}" dev "${A_DEV:-?}")"
}

# root_check: "su -c id" (3 tries of T_SU, as the log collector). HAVE_ROOT=1,
# or ROOTWHY=nosu (no su for adb) / mgr (no su, but a root manager that
# hides it is installed) / denied (asked, not granted)
root_check() {
  local try out rc waited
  HAVE_ROOT=; ROOTWHY=; ADBROOT=
  dev_call 20 0 "id -u"
  if [ "$(tr -d '\r\n ' < "$TMPD/dc.out")" = 0 ]; then
    ADBROOT=1; HAVE_ROOT=1; say "$M_ROOT_OK"; return 0
  fi
  try=1
  while [ $try -le 3 ]; do
    logl "> adb shell $P_SU_ID (try $try)"
    ( bg_run "$ADB" -s "$SERIAL" shell "$P_SU_ID" ) </dev/null >"$TMPD/su.out" 2>&1 &
    ADBPID=$!; waited=0
    while kill -0 "$ADBPID" 2>/dev/null; do
      sleep 0.2; waited=$((waited + 1)); check_intr
      [ $waited = 25 ] && say "$M_ROOT_WAIT"
      if [ $waited -ge $((T_SU * 5)) ]; then kill "$ADBPID" 2>/dev/null; sleep 1; kill -9 "$ADBPID" 2>/dev/null; break; fi
    done
    wait "$ADBPID" 2>/dev/null; rc=$?; ADBPID=
    [ $waited -ge $((T_SU * 5)) ] && rc=124
    out=$(tr -d '\r' < "$TMPD/su.out")
    logl "< rc=$rc $out"
    case $out in *uid=0*) HAVE_ROOT=1; say "$M_ROOT_OK"; return 0;; esac
    if lost "$TMPD/su.out"; then wait_phone device "$T_USER" "" ""; continue; fi
    if [ $rc = 127 ] || printf '%s' "$out" | grep -qiE 'not found|inaccessible|No such file'; then
      ROOTWHY=nosu
      # (KernelSU, SukiSU-Ultra and APatch hide su from apps they have not
      # granted and never ask on screen: their manager app tells)
      if root_mgr; then ROOTWHY=mgr; return 1; fi
      say "$M_ROOT_NONE"; say "$M_ROOT_NONE2"; return 1
    fi
    if [ $try -lt 3 ]; then warnm "$(fill "$M_ROOT_RETRY" n $((try + 1)))"; nap 5; fi
    try=$((try + 1))
  done
  ROOTWHY=denied
  return 1
}

# bl_eval <verifiedbootstate> <vbmeta.device_state>: BL = unlocked, locked, unknown
bl_eval() {
  BL=unknown
  case $1 in orange) BL=unlocked;; green|yellow|red) BL=locked;; esac
  case $2 in unlocked) BL=unlocked;; locked) [ "$BL" = unknown ] && BL=locked;; esac
}
# probe_root: P_ROOT under su (bootloader from bootconfig/cmdline, the
# work dir, an installer of an earlier run)
probe_root() {
  dev_call 30 1 "$(pcmd "$P_ROOT")"
  probe_ok || return 1
  R_VBS=$(kv bc.verifiedbootstate); [ -z "$R_VBS" ] && R_VBS=$(kv cl.verifiedbootstate)
  R_VDS=$(kv bc.vbmeta.device_state); [ -z "$R_VDS" ] && R_VDS=$(kv cl.vbmeta.device_state)
  R_SLOT=$(kv bc.slot_suffix); [ -z "$R_SLOT" ] && R_SLOT=$(kv cl.slot_suffix)
  A_DFWORK=$(kv dfwork); A_RFRUN=$(kv rfrun); A_UBRC=$(kv ubrc); A_UBOUT=$(kv ubout)
  [ -n "$R_SLOT" ] && SLOT=$R_SLOT
  return 0
}
# check_bl <reliable 1|0>: the bootloader lines; stops when it is locked
check_bl() {
  if [ "$1" = 1 ]; then
    bl_eval "$R_VBS" "$R_VDS"
    case $BL in
      unlocked) goodm "$M_BL_OK";;
      locked) SUM_ON=1; SUM_WHAT="Ничего не записано: загрузчик заблокирован."; fail "$(fill "$M_BL_LOCKED" vbs "${R_VBS:-${R_VDS:-?}}")";;
      *) say "$M_BL_UNKNOWN";;
    esac
  else
    bl_eval "$A_VBS" "$A_VDS"
    [ "$A_LOCKED" = 1 ] && [ "$BL" = unknown ] && BL=locked
    case $BL in
      unlocked) goodm "$M_BL_OK";;
      locked) warnm "$M_BL_PROPS_LOCKED";;
      *) say "$M_BL_UNKNOWN";;
    esac
  fi
}
check_slot() {
  case $SLOT in _a|_b) say "$(fill "$M_SLOT" slot "$SLOT")";; *) fail "$M_NO_SLOT";; esac
}
# check_battery: section 13.4 (asked once per run)
check_battery() {
  [ -n "$BATCHK" ] && return 0
  BATCHK=1
  case $BATP in
    ''|*[!0-9]*) say "$M_BAT_UNKNOWN"; return 0;;
  esac
  if [ "$BATP" -lt "$BAT_STOP" ]; then fail "$(fill "$M_BAT_STOP" n "$BATP")"; fi
  if [ "$BATP" -lt "$BAT_WARN" ]; then
    prompt_yes "$(fill "$M_BAT_WARN_ASK" n "$BATP")" 1 || { warn_phase; finish $RC_CANCEL; }
    return 0
  fi
  say "$(fill "$M_BAT_OK" n "$BATP")"
}

# probe_rec: P_REC in recovery (the shell is root, or rec_checks sees that it
# is not). Sets R_* and RECKIND
# (twrp | los), RECNAME, KR, SLOT, BATP, PNOW, R_BAKS (backup dirs, one
# per line), R_LOGS ("mtime:path" lines), R_AKHOME (mtime)
probe_rec() {
  local t nl=0
  while :; do
    dev_call 40 0 "$(pcmd "$P_REC")"
    probe_ok && break
    if lost && [ $nl -lt 5 ]; then
      nl=$((nl + 1)); nap 2
      W_ALSO=; wait_phone recovery "$T_USER" H_ADB_LOS ""
      continue
    fi
    fail "$(fill "$M_PHONE_NOANSWER" line "$(cutc 120 < "$TMPD/dc.out")")"
  done
  R_UID=$(kv uid)
  R_DEV=$(kv ro.product.device); R_BDEV=$(kv ro.build.product); R_VDEV=$(kv ro.product.vendor.device)
  R_VDEV2=$(kv ro.vendor.product.device); R_HW=$(kv ro.boot.hwname); R_DEBUG=$(kv ro.debuggable)
  R_TYPE=$(kv ro.build.type); R_FPR=$(kv ro.build.fingerprint); R_TWRPV=$(kv ro.twrp.version)
  # (the ROM's recovery is built with the ROM: the same ro.build.date.utc;
  # TWRP / OrangeFox describe themselves)
  R_RID=$(kv ro.build.date.utc)
  case $R_RID in ''|*[!0-9]*) R_RID=;; esac
  { [ -n "$R_TWRPV" ] || [ "$(kv twrp)" = 1 ]; } && R_RID=
  R_LOS=$(kv ro.lineage.version); [ -z "$R_LOS" ] && R_LOS=$(kv ro.modversion)
  R_CRD=$(kv ro.crdroid.version); R_EVO=$(kv ro.evolution.version)
  R_VBS=$(kv bc.verifiedbootstate); [ -z "$R_VBS" ] && R_VBS=$(kv cl.verifiedbootstate)
  R_VDS=$(kv bc.vbmeta.device_state); [ -z "$R_VDS" ] && R_VDS=$(kv cl.vbmeta.device_state)
  t=$(kv bc.slot_suffix); [ -z "$t" ] && t=$(kv cl.slot_suffix); [ -z "$t" ] && t=$(kv ro.boot.slot_suffix)
  SLOT=$t
  KR=$(kv kr); BATP=$(kv bat); PNOW=$(kv now)
  R_DATAMNT=$(kv datamnt); R_SDANDROID=$(kv sdandroid); R_SDW=$(kv sdw); R_AKHOME=$(kv akhome)
  # (the installer keeps its copy in the first store it can use, as the
  # store= lines say, and then writes in the same pass; without the
  # storeprobe line the old test: /sdcard usable)
  R_SDUSABLE=
  if [ "$(kv storeprobe)" = 1 ]; then
    R_SDUSABLE=$(sed -n 's/^store=[^:]*://p' "$TMPD/dc.out" | tr -d '\r' | awk -v n="$STORE_NEED_MB" '{ mb = ($4 ~ /^[0-9]+$/) ? int($4 / 1024 + 0.5) : -1; if (mb < 0 || mb >= n) { print 1; exit } }')
    logl "stores: $(sed -n 's/^store=//p' "$TMPD/dc.out" | awk -F: '{ print $1 }' | tr '\n' ' ')usable: ${R_SDUSABLE:-no}"
  elif [ -n "$R_DATAMNT" ] && [ -n "$R_SDANDROID$R_SDW" ]; then R_SDUSABLE=1; fi
  R_BAKS=$(sed -n 's/^bak=//p' "$TMPD/dc.out" | awk '!s[$0]++')
  R_LOGS=$(sed -n 's/^log=//p' "$TMPD/dc.out")
  # (no parentheses in the name: it also goes inside «Способ: … (…)»)
  if [ "$(kv twrp)" = 1 ]; then RECKIND=twrp; RECNAME="TWRP или OrangeFox${R_TWRPV:+, версия $R_TWRPV}"
  else
    RECKIND=los
    if [ -n "$R_CRD" ]; then RECNAME="LineageOS из crDroid $R_CRD"
    elif [ -n "$R_EVO" ]; then RECNAME="LineageOS из Evolution X $R_EVO"
    elif [ -n "$R_LOS" ]; then RECNAME="LineageOS $R_LOS"
    else RECNAME="на базе LineageOS"; fi
  fi
  SEENREC=1
  T0P=$PNOW
  return 0
}
# rec_checks: section 10.2 checks (taoyao, bootloader, slot, battery, uid 0)
REC_SHOWN=
rec_checks() {
  if ! is_taoyao "$R_DEV" "$R_BDEV" "$R_VDEV" "$R_VDEV2" "$R_HW"; then
    fail "$(fill "$M_NOT_TAOYAO" model "${R_DEV:-?}" dev "${R_HW:-${R_DEV:-?}}")"
  fi
  if [ -z "$REC_SHOWN" ]; then
    REC_SHOWN=1
    say "$(fill "$M_REC_KIND" kind "$RECNAME")"
    check_bl 1
    check_slot
    case $CMD in
      restore*) ;;
      backup) say "$(fill "$M_NOW_ON_B" release "${KR:-?}")$M_NOW_ON_REC";;
      *) [ -n "$KREL" ] && say "$(fill "$M_NOW_ON" release "${KR:-?}" ver "$ZVER")$M_NOW_ON_REC";;
    esac
  else
    bl_eval "$R_VBS" "$R_VDS"
    [ "$BL" = locked ] && fail "$(fill "$M_BL_LOCKED" vbs "${R_VBS:-${R_VDS:-?}}")"
    case $SLOT in _a|_b) ;; *) fail "$M_NO_SLOT";; esac
  fi
  check_battery
  # (1.1: ADB without root: never just fail)
  [ "$R_UID" = 0 ] || rec_noroot
}

# slot_hashes <root 0|1>: P_HASH of SLOT: H_boot H_vendor_boot H_dtbo
slot_hashes() {
  H_boot=; H_vendor_boot=; H_dtbo=
  dev_call "$T_HASH" "$1" "$(pcmd "$P_HASH" SLOT "$SLOT")"
  probe_ok || return 1
  H_boot=$(kv h_boot); H_vendor_boot=$(kv h_vendor_boot); H_dtbo=$(kv h_dtbo)
  [ ${#H_boot} = 64 ] && [ ${#H_vendor_boot} = 64 ] && [ ${#H_dtbo} = 64 ]
}
# list_dir <remote dir> <root 0|1> <out prefix>: P_LISTDIR into
# <prefix>.files ("size:mtime:name"), <prefix>.sums, <prefix>.info
list_dir() {
  dev_call 40 "$2" "$(pcmd "$P_LISTDIR" DIR "$1")"
  probe_ok || return 2
  grep -q '^nodir=1$' "$TMPD/dc.out" && return 1
  sed -n 's/^F=//p' "$TMPD/dc.out" > "$3.files"
  awk '/^=SUMS$/ { s = 1; next } /^=INFO$/ { s = 0 } s' "$TMPD/dc.out" > "$3.sums"
  awk '/^=INFO$/ { s = 1; next } /^=END$/ { s = 0 } s' "$TMPD/dc.out" > "$3.info"
  return 0
}
# list_root <remote root> <root 0|1>: dir names in $TMPD/lr (none: empty)
list_root() {
  : > "$TMPD/lr"
  dev_call 30 "$2" "$(pcmd "$P_LISTROOT" ROOT "$1")"
  probe_ok || return 1
  sed -n 's/^D=//p' "$TMPD/dc.out" > "$TMPD/lr"
  return 0
}
# fetch_text <remote file> <local file> <root 0|1>: false when missing
fetch_text() {
  if dev_call 40 "$3" "$(pcmd "$P_CAT" FILE "$1")" && [ -s "$TMPD/dc.out" ]; then
    cp -f "$TMPD/dc.out" "$2"; return 0
  fi
  rm -f "$2"; return 1
}
remote_mtime() {  # <remote file> <root 0|1>
  dev_call 20 "$2" "$(pcmd "$P_STAT" FILE "$1")" >/dev/null 2>&1
  head -n 1 "$TMPD/dc.out" | grep -E '^[0-9]+$'
}
# kv of a local key=value file (info.txt, restore.prop)
info_get() { sed -n "s/^$2=//p" "$1" 2>/dev/null | tr -d '\r' | head -n 1; }
# sums_get <SHA256SUMS> <image name>: its hash
sums_get() { tr -d '\r' < "$1" 2>/dev/null | awk -v n="$2" '$2 == n || $2 == "*" n { print $1; exit }'; }

########################################################################
# the installer's result (section 11)
# log_release <file>: the release a log names (KEY_KERNEL, else the modules line)
log_release() {
  local r l
  r=$(sed -n "s/^${KEY_KERNEL}//p" "$1" 2>/dev/null | tail -n 1)
  if [ -z "$r" ]; then
    l=$(grep -E "$TXT_RELEASE_RE" "$1" 2>/dev/null | head -n 1)
    [[ $l =~ $TXT_RELEASE_RE ]] && r=${BASH_REMATCH[1]}
  fi
  printf '%s' "$r"
}
# log_class <file>: DONE DIRTY RESTORED STEP1 CLEAN or NONE (the last
# taoyao-result line when there is one, else the English text)
log_class() {
  local r
  r=$(grep "^$RES_PREFIX" "$1" 2>/dev/null | tail -n 1); r=${r#"$RES_PREFIX"}
  if [ -n "$r" ]; then
    case $r in
      "$RES_DONE") echo DONE;; "$RES_DIRTY") echo DIRTY;; "$RES_RESTORED") echo RESTORED;;
      "$RES_STEP1") echo STEP1;; "$RES_CLEAN") echo CLEAN;; *) echo NONE;;
    esac
    return 0
  fi
  # (a log that has taoyao- lines but no result line: the installer was cut
  # off; its English text is not trusted then)
  if grep -q '^taoyao-[a-z]*: ' "$1"; then echo NONE; return 0; fi
  if grep -Eq "$TXT_DONE_RE" "$1"; then echo DONE
  elif grep -Eq "$TXT_DIRTY_RE" "$1"; then echo DIRTY
  elif awk -v a="$TXT_ROLLBACK" -v b="$TXT_ROLLED" 'index($0, a) == 1 { s = 1 } s && index($0, b) { f = 1 } END { exit !f }' "$1"; then echo RESTORED
  elif grep -qF "$TXT_STEP1" "$1"; then echo STEP1
  elif awk -v a="$TXT_ABORTING" -v b="$TXT_ROLLBACK" 'index($0, a) { s = 1; r = 0 } s && index($0, b) == 1 { r = 1 } END { exit !(s && !r) }' "$1"; then echo CLEAN
  else echo NONE; fi
}
# run_id <log>: its "taoyao-run:" id (installers from the next build on;
# empty for older ones)
run_id() { sed -n "s/^${KEY_RUN}//p" "$1" 2>/dev/null | head -n 1 | tr -d '\r '; }
# log_new <log>: false when the log is one of a run before this pass: its
# run id was seen before the pass, or the zip writes run ids and it has none
log_new() {
  local id
  id=$(run_id "$1")
  if [ -z "$id" ]; then [ -z "$ZRUN" ]; return; fi
  case " $OLD_RUNIDS " in *" $id "*) return 1;; esac
  return 0
}
# note_runids <remote log>...: the run ids of these logs on the phone now
# (before a pass) into OLD_RUNIDS; RUN_ROOT=1 reads them under su
note_runids() {
  local p f n=0 id
  OLD_RUNIDS=
  for p in "$@"; do
    f="$TMPD/or$n.log"; n=$((n + 1))
    fetch_text "$p" "$f" "${RUN_ROOT:-0}" || continue
    id=$(run_id "$f"); [ -n "$id" ] && OLD_RUNIDS="$OLD_RUNIDS $id"
  done
  RUN_ROOT=
  [ -n "$OLD_RUNIDS" ] && logl "run ids before this pass:$OLD_RUNIDS"
  return 0
}
# rec_logs_now: the logs P_REC listed (R_LOGS "mtime:path" lines), paths only
rec_logs_now() { printf '%s\n' "$R_LOGS" | sed -n 's/^[0-9]*://p'; }

# log_facts <file>: RES_SLOT RES_DIR RES_REUSED from a log (if not set yet)
log_facts() {
  local l d s
  d=$(sed -n "s/^${KEY_BACKUP}//p" "$1" | tail -n 1)
  s=$(sed -n "s/^${KEY_SLOT}//p" "$1" | tail -n 1)
  l=$(grep -E "$TXT_BACKUP_RE" "$1" | tail -n 1)
  if [[ $l =~ $TXT_BACKUP_RE ]]; then
    [ -z "$s" ] && s=${BASH_REMATCH[1]}
    [ -z "$d" ] && d=${BASH_REMATCH[3]}
    [ -n "${BASH_REMATCH[2]}" ] && RES_REUSED=1
  fi
  [ -z "$RES_DIR" ] && RES_DIR=$d
  [ -z "$RES_SLOT" ] && RES_SLOT=$s
  return 0
}
# classify <local log files...>: RESULT by the first rule of 11.2 that any
# of them satisfies; RES_LOG = the file that decided
classify() {
  local f c rule
  RESULT=; RES_LOG=
  for f in "$@"; do log_facts "$f"; done
  for rule in DONE DIRTY RESTORED STEP1 CLEAN; do
    for f in "$@"; do
      c=$(log_class "$f")
      if [ "$c" = "$rule" ]; then RESULT=$rule; RES_LOG=$f; return 0; fi
    done
  done
  if [ $# -gt 0 ]; then RESULT=INCOMPLETE; RES_LOG=$1; fi
  return 0
}
# reason_lines <log>: the installer's reason (section 3.4), "  | " lines
reason_lines() {
  awk -v p="$RES_PREFIX" '
    index($0, p) == 1 { exit }
    { a[n++] = $0 }
    END {
      e = n; s = 0; k = 0
      for (i = n - 1; i >= 0; i--) if (a[i] == "" || a[i] == " ") { k++; if (k == 1) s = i + 1; else { if (e - s <= 1) s = i + 1; break } }
      if (e - s > 15) s = e - 15
      for (i = s; i < e; i++) if (a[i] !~ /^taoyao-/ && a[i] != "" && a[i] != " ") print "  | " a[i]
    }' "$1"
}
# why_of <log>: the Russian explanation of an abort (WHY_TABLE)
why_of() {
  local txt g id
  txt=$(cat "$1" 2>/dev/null)
  while IFS="$(printf '\t')" read -r g id; do
    [ -n "$g" ] || continue
    # shellcheck disable=SC2254
    case $txt in $g) eval "printf '%s' \"\$$id\""; return 0;; esac
  done <<EOF
$WHY_TABLE
EOF
  printf '%s' "$M_WHY_OTHER"
}
# show_reason <log>: the reason block and its explanation
show_reason() {
  [ -f "$1" ] || { say "$M_WHY_OTHER"; return 0; }
  say "$M_REASON"
  reason_lines "$1" > "$TMPD/why.txt"
  while IFS= read -r l; do say "$l"; done < "$TMPD/why.txt"
  warnm "$(why_of "$1")"
}
# show_notes <log>: the installer's own warnings, repeated on the PC (not
# those that ask for the copy on the PC: the flasher takes it itself); its
# "!! The backup is only in RAM … copy it now" block is left out once that
# copy is on the PC (a line says where instead; RAMNOTE_DIR: that copy)
IPA_HINTED=; RAMNOTE_DIR=
show_notes() {
  local d pc=
  [ -f "$1" ] || return 0
  tr -d '\r' < "$1" | sed -e 's/^[[:space:]]*//' > "$TMPD/notes.in"
  d=$(sed -nE "s#${TXT_RAMNOTE_RE}.*#\\1#p" "$TMPD/notes.in" | tail -n 1)
  [ -n "$d" ] && pc=$(ram_onpc_any "$d")
  if [ -n "$pc" ]; then
    awk -v re="$TXT_RAMNOTE_RE" '$0 ~ re { k = 1; next } k && /^!!/ { next } { k = 0; print }' "$TMPD/notes.in" > "$TMPD/notes.in2" && mv -f "$TMPD/notes.in2" "$TMPD/notes.in"
  fi
  grep -E "^!|$NOTE_RE|[Ww][Aa][Rr][Nn][Ii][Nn][Gg]" "$TMPD/notes.in" | grep -v "^$RES_PREFIX" | grep -Ev "$NOTE_SKIP_RE" | awk '!s[$0]++' > "$TMPD/notes.txt"
  if [ -s "$TMPD/notes.txt" ]; then
    say "$M_INSTALLER_NOTES"
    while IFS= read -r l; do
      case $l in '!'*) warnm "  | $l";; *) say "  | $l";; esac
    done < "$TMPD/notes.txt"
    if [ -z "$IPA_HINTED" ] && grep -Eq "$NOTE_IPA_RE" "$TMPD/notes.txt"; then
      IPA_HINTED=1; warnm "$(fill "$M_IPA_HINT" cmd "$(tool_cmd adb)")"
    fi
  fi
  if [ -n "$pc" ]; then RAMNOTE_DIR=$d; say "$(fill "$M_RAM_NOTE_ONPC" path "$pc")"; fi
  return 0
}

# log_seen <path:mtime>: a log an earlier pass already read (LOG_SEEN)
LOG_SEEN=; AK_SEEN=; RCUT=
log_seen() { case " $LOG_SEEN " in *" $1 "*) return 0;; esac; return 1; }
# log_ours <local log>: the log may be of this kernel: it names KREL, or no
# release at all (an abort before the backup step names none: OTA pending,
# low space, locked bootloader). Only a log naming another release is not
log_ours() {
  local r
  r=$(log_release "$1")
  [ -z "$r" ] || [ "$r" = "$KREL" ]
}
# read_result_rec: after a pass in recovery (P_REC done): the logs of this
# pass (section 11.1). A log counts when it was written after the probe
# before this pass (RCUT = its time + 1; after a fresh recovery boot with no
# probe before the pass, an estimate of the start of the transfer), is not
# one an earlier pass read (LOG_SEEN), has no run id seen before the pass
# and names this release or none. Sets RESULT and RES_*
read_result_rec() {
  local m p n=0 files= d nl ml f cut=${RCUT:-0} dirs seen=
  RES_DIR=; RES_SLOT=; RES_REUSED=; RESULT=; RES_LOG=; RES_LOGS=
  logl "logs of this pass: written at $cut or later"
  for p in "/tmp/$LAST_LOG" "$REC_AKHOME/install.log"; do
    m=$(printf '%s\n' "$R_LOGS" | awk -F: -v p="$p" '{ q = substr($0, index($0, ":") + 1) } q == p { print $1; exit }')
    [ -n "$m" ] || continue
    seen="$seen $p:$m"
    if [ "$m" -lt "$cut" ]; then logl "log $p ($m) is older than this pass"; continue; fi
    if log_seen "$p:$m"; then logl "log $p ($m) was read after an earlier pass"; continue; fi
    n=$((n + 1)); f="$TMPD/rl$n.log"
    fetch_text "$p" "$f" 0 || continue
    if ! log_new "$f"; then logl "log $p is of an earlier run ($(run_id "$f"))"; continue; fi
    if log_ours "$f"; then files="$files $f"; logl "fresh log: $p"
    else logl "log $p names $(log_release "$f"), not $KREL"; fi
  done
  # the newest install-*.log of the dir the logs name, then of every backup dir
  dirs=$R_BAKS
  for f in $files; do log_facts "$f"; done
  [ -n "$RES_DIR" ] && dirs="$RES_DIR
$dirs"
  [ -n "$PASS1DIR" ] && dirs="$PASS1DIR
$dirs"
  for d in $(printf '%s\n' "$dirs" | awk 'NF && !s[$0]++'); do
    list_dir "$d" 0 "$TMPD/rr" || continue
    nl=; ml=0
    while IFS=: read -r _s m f; do
      [[ $f =~ $INSTLOG_RE ]] || continue
      [ "${m:-0}" -ge "$ml" ] && { ml=${m:-0}; nl=$f; }
    done < "$TMPD/rr.files"
    [ -n "$nl" ] || continue
    seen="$seen $d/$nl:$ml"
    [ "$ml" -ge "$cut" ] || continue
    if log_seen "$d/$nl:$ml"; then logl "log $d/$nl was read after an earlier pass"; continue; fi
    n=$((n + 1)); f="$TMPD/rl$n.log"
    fetch_text "$d/$nl" "$f" 0 || continue
    log_new "$f" || { logl "log $d/$nl is of an earlier run"; continue; }
    if log_ours "$f"; then files="$files $f"; logl "fresh log: $d/$nl"; fi
  done
  LOG_SEEN="$LOG_SEEN$seen"
  RES_DIR=; RES_SLOT=; RES_REUSED=
  # shellcheck disable=SC2086
  classify $files
  RES_LOGS=$files
  if [ -z "$RESULT" ]; then
    # (/tmp/anykernel made by this pass: AnyKernel3 stopped before the
    # taoyao part wrote its log)
    if [ -n "$R_AKHOME" ] && [ "$R_AKHOME" -ge "$cut" ] && [ "$R_AKHOME" != "$AK_SEEN" ]; then RESULT=AK3_EARLY; else RESULT=NOLOG; fi
  fi
  AK_SEEN=$R_AKHOME
  logl "result: $RESULT (dir ${RES_DIR:-?}, slot ${RES_SLOT:-?}${RES_REUSED:+, reused})"
  [ -n "$RES_LOG" ] && logf "$RES_LOG" "installer "
  # (no result: what the recovery itself logged, for the screen and the log)
  RECLOG_LINES=
  case $RESULT in
    AK3_EARLY|NOLOG|INCOMPLETE)
      if dev_call 20 0 "$P_RECLOG"; then RECLOG_LINES=$(grep -v '^$' "$TMPD/dc.out" | tail -n 5); fi
      [ -n "$RECLOG_LINES" ] && logl "recovery.log: $RECLOG_LINES";;
  esac
  return 0
}

########################################################################
# PC folders (section 12): bases, log, lock
pick_base() {
  ALTBASE="${HOME-/tmp}/MeruDevTools"; [ -d "${HOME-}/Desktop" ] && ALTBASE="$HOME/Desktop/MeruDevTools"
  if mkdir "$HERE/.run-flash-probe.$$" 2>/dev/null; then rmdir "$HERE/.run-flash-probe.$$"; BASE=$HERE; return 0; fi
  mkdir -p "$ALTBASE" 2>/dev/null || { errm "ОШИБКА: не удаётся создать папку для копий и журнала."; exit $RC_FAIL; }
  BASE=$ALTBASE
  warnm "$(fill "$M_BASE_FALLBACK" here "$HERE" base "$BASE")"
}
# bases: where filed copies are looked for (the script folder and the fallback)
bases() { printf '%s\n' "$BASE" "$HERE" "$ALTBASE" | awk 'NF && !s[$0]++' | while IFS= read -r b; do [ -d "$b" ] && printf '%s\n' "$b"; done; }
open_log() {
  local sz
  LOG="$BASE/$PC_LOG"
  sz=$(q fsize "$LOG" 2>/dev/null)
  if [ -n "$sz" ] && [ "$sz" -gt 5242880 ]; then mv -f "$LOG" "$BASE/$PC_LOG_OLD" 2>/dev/null; fi
  if ! { : >> "$LOG"; } 2>/dev/null; then LOG=; return 0; fi
  {
    printf '\n==== %s %s, %s ====\n' "$BRAND" "$VER" "$(date '+%Y-%m-%d %H:%M:%S')"
  } >> "$LOG"
  if [ -n "$LOGBUF" ]; then printf '%s' "$LOGBUF" | mask >> "$LOG"; LOGBUF=; fi
}
take_lock() {
  local d="$BASE/$PC_LOCK" op
  if ! mkdir "$d" 2>/dev/null; then
    op=$(cat "$d/pid" 2>/dev/null)
    if [ -n "$op" ] && kill -0 "$op" 2>/dev/null; then
      errm "$M_LOCKED"; LOG=; finish $RC_FAIL
    fi
    rm -rf "$d"; mkdir "$d" 2>/dev/null || return 0
  fi
  echo $$ > "$d/pid"; LOCKD=$d
}
ensure_pulldir() {
  [ -n "$PULLDIR" ] && [ -d "$PULLDIR" ] && return 0
  PULLDIR="$BASE/$(fill "$PC_PULL_FMT" BACKUP_NAME "$BACKUP_NAME" stamp "$(date +%Y%m%d-%H%M%S)")"
  mkdir -p "$PULLDIR" 2>/dev/null || { errm "ОШИБКА: не удаётся создать папку $PULLDIR."; PULLDIR=; return 1; }
  logl "pull folder: $PULLDIR"
}

# series_of <release>: "6.12" of "6.12.96-taoyao-v0.19"
series_of() { printf '%s' "$1" | sed -n 's/^\([0-9][0-9]*\.[0-9][0-9]*\)\..*/\1/p'; }
# in_port <release>: a build of this port: its series is in PORT_SERIES or
# is the chosen zip's, or it is named as our builds are (REL_RE: a future
# series, e.g. 6.18.5-taoyao-v1.2); anything else is the ROM's own kernel
in_port() {
  local s
  [[ $1 =~ $REL_RE ]] && return 0
  s=$(q series_of "$1")
  [ -n "$s" ] || return 1
  case " $PORT_SERIES $ZSERIES " in *" $s "*) return 0;; esac
  return 1
}
class_of() { if in_port "$1"; then echo PREV; else echo STOCK; fi; }
ver_of_rel() { local re='-v([0-9]+(\.[0-9]+)+)$'; [[ $1 =~ $re ]] && printf '%s' "${BASH_REMATCH[1]}"; }
# epoch_of <yyyy-mm-dd HH:MM:SS[ UTC]>: those seconds since 1970, read as
# UTC (installers write UTC; the flasher's own copies before 1.2, local
# time); empty for anything else
epoch_of() {
  local re='^([0-9]{4})-([0-9]{2})-([0-9]{2}) ([0-9]{2}):([0-9]{2}):([0-9]{2})' y m d h mi se era yoe doy
  [[ $1 =~ $re ]] || return 0
  y=$((10#${BASH_REMATCH[1]})); m=$((10#${BASH_REMATCH[2]})); d=$((10#${BASH_REMATCH[3]}))
  h=$((10#${BASH_REMATCH[4]})); mi=$((10#${BASH_REMATCH[5]})); se=$((10#${BASH_REMATCH[6]}))
  [ $m -le 2 ] && y=$((y - 1))
  era=$((y / 400)); yoe=$((y - era * 400))
  if [ $m -gt 2 ]; then doy=$(( (153 * (m - 3) + 2) / 5 + d - 1 )); else doy=$(( (153 * (m + 9) + 2) / 5 + d - 1 )); fi
  printf '%s' $(( (era * 146097 + yoe * 365 + yoe / 4 - yoe / 100 + doy - 719468) * 86400 + h * 3600 + mi * 60 + se ))
}
# utc_h <seconds since 1970>: "16.09.2026 14:18 UTC" (empty for anything else)
utc_h() {
  local z doe era yoe doy mp d m y s
  case $1 in ''|*[!0-9]*) return 0;; esac
  s=$(( $1 % 86400 )); z=$(( $1 / 86400 + 719468 ))
  era=$(( z / 146097 )); doe=$(( z - era * 146097 ))
  yoe=$(( (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365 ))
  y=$(( yoe + era * 400 )); doy=$(( doe - (365 * yoe + yoe / 4 - yoe / 100) ))
  mp=$(( (5 * doy + 2) / 153 )); d=$(( doy - (153 * mp + 2) / 5 + 1 ))
  if [ $mp -lt 10 ]; then m=$((mp + 3)); else m=$((mp - 9)); fi
  [ $m -le 2 ] && y=$((y + 1))
  printf '%02d.%02d.%04d %02d:%02d UTC' "$d" "$m" "$y" $((s / 3600)) $((s % 3600 / 60))
}
# dt_h <date of info.txt>: "14.11.2026 06:32", with " UTC" when it says so
dt_h() {
  local u=
  case $1 in *' UTC') u=' UTC';; esac
  printf '%s' "$1" | sed -n "s/^\([0-9]\{4\}\)-\([0-9][0-9]\)-\([0-9][0-9]\) \([0-9][0-9]:[0-9][0-9]\).*/\3.\2.\1 \4$u/p"
}
# fpr_why <copy dir> <ROM build now>: why only the fingerprint compared
# (M_STOCK_FPRONLY, M_Q2_FPRONLY): the copy has no ROM build, or the phone's
# cannot be read now
fpr_why() { if [ -n "$(rid_of "$1/info.txt")" ] && [ -z "$2" ]; then printf '%s' "$M_FPR_WHY_PHONE"; else printf '%s' "$M_FPR_WHY_COPY"; fi; }
# rid_of <info.txt>: its rom_build_utc (installer 0.20 on), digits only
rid_of() { local r; r=$(q info_get "$1" rom_build_utc); case $r in ''|*[!0-9]*) ;; *) printf '%s' "$r";; esac; }
# the ROM build of a copy against the phone's (13.2): rc(<boot ramdisk
# now>, <build time now>, <fingerprint now>, the copy's <ramdisk>,
# <rom_build_utc>, <fingerprint>, <time made>): same (the same boot ramdisk,
# or the same ro.build.date.utc), other (another one), older (a copy
# without rom_build_utc made, by the phone's clock, more than a day before
# the ROM now on the phone was built: most likely of an earlier build;
# only for a date after 2021-01-01: a recovery's clock is never set and
# reads about 1970, so its copies tell nothing by their date), fpr
# (only the fingerprint is the same: Play Integrity modules spoof it, so it
# proves nothing), fprdiff (another fingerprint, which a spoof can also
# explain), unknown (nothing to compare)
ROM_AWK='function rc(bn, rn, fn, cb, cr, cf, ce) {
  if (bn != "" && cb != "") return (bn == cb ? "same" : "other")
  if (rn != "" && cr != "") return (rn == cr ? "same" : "other")
  if (rn != "" && ce != "" && ce + 0 >= 1609459200 && rn + 0 > ce + 86400) return "older"
  if (fn != "" && cf != "") return (fn == cf ? "fpr" : "fprdiff")
  return "unknown"
}'
# rom_list <class or ANY> <slot> <boot ramdisk now> <build time now>
# <fingerprint now>: every known copy of that slot (scan order), one line
# each: verdict, dir, its rom_build_utc, its date, class, kernel, restore
# zip (TAB-separated, "-" for empty)
rom_list() {
  [ -f "$TMPD/known" ] || scan_known
  awk -F'\t' -v c="$1" -v s="$2" -v bn="$3" -v rn="$4" -v fn="$5" "$ROM_AWK"'
    ($1 == c || c == "ANY") && $3 == s { print rc(bn, rn, fn, $6, $12, $5, $13) "\t" $2 "\t" ($12 == "" ? "-" : $12) "\t" ($11 == "" ? "-" : $11) "\t" $1 "\t" ($4 == "" ? "-" : $4) "\t" $10 }' "$TMPD/known"
}
# rl_paths <rom_list file> <verdict>...: the dirs with those verdicts,
# "; "-joined, each with the build of its ROM (other) or the date it was
# made (older)
rl_paths() {
  local f=$1 v d u dt x out=
  shift
  while IFS="$(printf '\t')" read -r v d u dt _c _k _z; do
    case " $* " in *" $v "*) ;; *) continue;; esac
    x=$d
    if [ "$v" = other ] && [ "$u" != - ]; then x=$(fill "$M_COPY_BUILT" path "$d" date "$(utc_h "$u")")
    elif [ "$v" = older ] && [ "$dt" != - ]; then x=$(fill "$M_COPY_MADE" path "$d" date "$(dt_h "$dt")"); fi
    out="${out:+$out; }$x"
  done < "$f"
  printf '%s' "$out"
}

# scan_known: every filed folder under the bases into $TMPD/known, one per
# line: class dir slot kernel fingerprint boot_ramdisk h_boot h_vendor_boot
# h_dtbo restore-zip date rom_build_utc date-in-seconds (TAB-separated)
scan_known() {
  local b d
  : > "$TMPD/known"
  while IFS= read -r b; do
    for d in "$b/$PC_STOCK"/*; do add_known STOCK "$d"; done
    for d in "$b"/taoyao-*-backups/*; do add_known PREV "$d"; done
  done <<EOF
$(bases)
EOF
}
add_known() {
  local c=$1 d=$2 rz= z n=0 i="$2/info.txt" s="$2/SHA256SUMS"
  [ -d "$d" ] && [ -f "$i" ] && [ -f "$s" ] || return 0
  for z in "$d"/taoyao-restore-*.zip; do [ -f "$z" ] && { n=$((n + 1)); rz=${z##*/}; }; done
  [ $n -gt 1 ] && rz=MANY
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$c" "$d" "$(q info_get "$i" slot)" "$(q info_get "$i" kernel)" \
    "$(q info_get "$i" fingerprint)" "$(q info_get "$i" boot_ramdisk)" "$(q sums_get "$s" boot.img)" \
    "$(q sums_get "$s" vendor_boot.img)" "$(q sums_get "$s" dtbo.img)" "${rz:--}" "$(q info_get "$i" date)" \
    "$(rid_of "$i")" "$(q epoch_of "$(q info_get "$i" date)")" >> "$TMPD/known"
}
# find_known <class> <slot> <h_boot> <h_vendor_boot> <h_dtbo>: the folder
# holding exactly these images (prints it)
find_known() {
  [ -f "$TMPD/known" ] || scan_known
  awk -F'\t' -v c="$1" -v s="$2" -v a="$3" -v b="$4" -v d="$5" '$1 == c && $3 == s && $7 == a && $8 == b && $9 == d && a != "" { print $2; exit }' "$TMPD/known"
}

# pull_files <remote dir> <root 0|1> <files list> <local dir>: every listed
# file (safe names only) by adb pull, working directory <local dir>
pull_files() {
  local rd=$1 rt=$2 lst=$3 dst=$4 sz m f rc src rcp= pd
  rd=$(android_path "$rd")
  PULLPHASE=$PHASE; PHASE=pull; PD_FILE=
  while IFS=: read -r sz m f; do
    case $f in ''|*[!A-Za-z0-9._-]*) [ -n "$f" ] && logl "not pulled (name): $f"; continue;; esac
    say "$(fill "$M_PULLING" file "$f" size "$(size_h "$sz")")"
    PULLPART="$dst/$f"
    src="$rd/$f"; [ -n "$rcp" ] && src=$rcp/$f
    logl "> adb pull $src"
    run_to "$T_PULL" "$TMPD/pull.out" adb_in "$dst" pull "$src" "$f"; rc=$?
    logl "< rc=$rc $(tr '\r' '\n' < "$TMPD/pull.out" | tail -n 2 | tr '\n' ' ')"
    if [ $rc != 0 ] && grep -qi 'permission denied' "$TMPD/pull.out" && [ -n "$HAVE_ROOT" ] && [ -z "$rcp" ] && [ "$WHERE" = android ]; then
      # (a folder only root can read: a copy that adb can read)
      pd=${rd##*/}
      if dev_call 120 1 "mkdir -p $PH_WORK/pull && rm -rf $PH_WORK/pull/$pd && cp -r $rd $PH_WORK/pull/$pd && chmod -R a+rX $PH_WORK/pull && echo COPIED" && grep -q COPIED "$TMPD/dc.out"; then
        rcp=$PH_WORK/pull/$pd
        run_to "$T_PULL" "$TMPD/pull.out" adb_in "$dst" pull "$rcp/$f" "$f"; rc=$?
      fi
    fi
    if [ $rc != 0 ]; then
      if grep -qi 'access is denied\|operation not permitted' "$TMPD/pull.out"; then
        warnm "ВНИМАНИЕ: система компьютера не даёт записать файл в папку флешера. Перенесите папку флешера, например, в домашнюю папку."
      fi
      PD_FILE=$f; PD_WHAT="$f не скопировался ($(grep -iE 'error|failed|denied' "$TMPD/pull.out" | head -n 1 | cutc 100))"
      PHASE=$PULLPHASE; PULLPART=
      [ -n "$rcp" ] && dev_call 30 1 "$(pcmd "$P_A_ROOTCOPY_RM")" >/dev/null 2>&1
      return 1
    fi
  done < "$lst"
  [ -n "$rcp" ] && dev_call 30 1 "$(pcmd "$P_A_ROOTCOPY_RM")" >/dev/null 2>&1
  PHASE=$PULLPHASE; PULLPART=
  return 0
}
# android_path: in the booted system /sdcard for the other names of internal storage
android_path() {
  if [ "$WHERE" = android ]; then
    case $1 in /storage/emulated/0/*) printf '/sdcard/%s' "${1#/storage/emulated/0/}"; return;;
      /data/media/0/*) printf '/sdcard/%s' "${1#/data/media/0/}"; return;; esac
  fi
  printf '%s' "$1"
}

# verify_backup <local dir> <dir name> [phone files list]: section 12.4.
# VB_WHAT (what failed), VB_RZOK=1 when the restore zip checked out,
# VB_RZNONE=1 when there is none (on the phone either)
verify_backup() {
  local d=$1 dn=$2 lst=$3 slot f psz lsz n h want rz l1 l2 p
  VB_WHAT=; VB_RZOK=; VB_RZNONE=
  slot=_${dn##*_}
  for f in boot.img vendor_boot.img dtbo.img SHA256SUMS info.txt; do
    [ -f "$d/$f" ] || { VB_WHAT="нет файла $f"; return 1; }
    lsz=$(q fsize "$d/$f")
    if [ -n "$lst" ]; then
      psz=$(awk -F: -v n="$f" '$3 == n { print $1; exit }' "$lst")
      [ -n "$psz" ] && [ "$psz" != "$lsz" ] && { VB_WHAT="$f: $lsz байт вместо $psz"; return 1; }
    fi
    case $f in *.img) [ "${lsz:-0}" -gt 0 ] || { VB_WHAT="$f пустой"; return 1; };; esac
  done
  # every other listed file arrived whole
  if [ -n "$lst" ]; then
    while IFS=: read -r psz _m f; do
      case $f in ''|*[!A-Za-z0-9._-]*) continue;; esac
      [ -f "$d/$f" ] || { VB_WHAT="нет файла $f"; return 1; }
      [ "$(q fsize "$d/$f")" = "$psz" ] || { VB_WHAT="$f: неполный"; return 1; }
    done < "$lst"
  fi
  n=$(tr -d '\r' < "$d/SHA256SUMS" | awk 'NF' | wc -l | tr -d ' ')
  [ "$n" = 3 ] || { VB_WHAT="SHA256SUMS: $n строк вместо 3"; return 1; }
  for f in boot.img vendor_boot.img dtbo.img; do
    want=$(q sums_get "$d/SHA256SUMS" "$f")
    case $want in *[!0-9a-f]*|'') VB_WHAT="SHA256SUMS: нет строки $f"; return 1;; esac
    [ ${#want} = 64 ] || { VB_WHAT="SHA256SUMS: плохая строка $f"; return 1; }
    h=$(q sha256_of "$d/$f")
    [ "$h" = "$want" ] || { VB_WHAT="sha256 $f не совпадает с SHA256SUMS"; return 1; }
  done
  [ "$(q info_get "$d/info.txt" slot)" = "$slot" ] || { VB_WHAT="info.txt: слот не $slot"; return 1; }
  [ -n "$(q info_get "$d/info.txt" kernel)" ] || { VB_WHAT="info.txt: нет строки kernel="; return 1; }
  rz="$d/$(fill "$RZIP_FMT" dir "$dn")"
  if [ ! -f "$rz" ]; then
    if [ -n "$lst" ] && grep -q ":${rz##*/}\$" "$lst"; then VB_WHAT="нет файла ${rz##*/}"; return 1; fi
    VB_RZNONE=1; return 0
  fi
  [ -f "$rz.sha256" ] || { VB_WHAT="нет файла ${rz##*/}.sha256"; return 1; }
  want=$(tr -d '\r' < "$rz.sha256" | awk '{ print $1; exit }')
  h=$(q sha256_of "$rz")
  [ -n "$h" ] && [ "$h" = "$want" ] || { VB_WHAT="sha256 ${rz##*/} не совпадает с ${rz##*/}.sha256"; return 1; }
  zip_text "$rz" restore.prop "$TMPD/vb.prop" || { VB_WHAT="${rz##*/}: нет restore.prop"; return 1; }
  [ "$(q info_get "$TMPD/vb.prop" device)" = "$DEVICE" ] || { VB_WHAT="restore.prop: не $DEVICE"; return 1; }
  [ "$(q info_get "$TMPD/vb.prop" slot)" = "$slot" ] || { VB_WHAT="restore.prop: слот не $slot"; return 1; }
  for p in boot vendor_boot dtbo; do
    [ "$(q info_get "$TMPD/vb.prop" $p.size)" = "$(q fsize "$d/$p.img")" ] || { VB_WHAT="restore.prop: размер $p не совпадает"; return 1; }
  done
  zip_text "$rz" SHA256SUMS "$TMPD/vb.sums" || { VB_WHAT="${rz##*/}: нет SHA256SUMS"; return 1; }
  l1=$(sed 's/^[[:space:]]*//; s/[[:space:]]*$//' "$TMPD/vb.sums" | awk 'NF')
  l2=$(tr -d '\r' < "$d/SHA256SUMS" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | awk 'NF')
  [ "$l1" = "$l2" ] || { VB_WHAT="SHA256SUMS в restore-zip другие"; return 1; }
  VB_RZOK=1
  return 0
}

# label_of <info.txt> <class>: the folder label (section 12.5)
label_of() {
  local i=$1 r l= f k re1='^[^:]+: hyperos, stock (HyperOS [^ ,]+),' re2='^[^:]+: custom, ([^,]+), vendor built'
  if [ "$2" = STOCK ]; then
    r=$(q info_get "$i" ipa_uapi_stock_reason)
    if [[ $r =~ $re1 ]]; then l=${BASH_REMATCH[1]}
    elif [[ $r =~ $re2 ]]; then l=${BASH_REMATCH[1]}
    else
      f=$(q info_get "$i" fingerprint); f=$(printf '%s' "$f" | cut -d/ -f5); l=${f%%:*}
      [ -z "$l" ] && { k=$(q info_get "$i" boot_ramdisk); [ -n "$k" ] && l="rom-${k:0:8}"; }
      [ -z "$l" ] && l=unknown-rom
    fi
  else
    k=$(q info_get "$i" kernel); l=$(ver_of_rel "$k")
    if [ -n "$l" ]; then l=v$l; else l=$k; fi
  fi
  l=$(safe_name "$l"); [ -z "$l" ] && l=unknown
  printf '%s' "$l"
}
# file_backup <local dir> <class> <dir name>: move a verified copy into its
# class folder (never into an existing folder). PD_PATH = where it went
file_backup() {
  local src=$1 cls=$2 dn=$3 slot stamp label name parent dst i=2 kernel fpr ser f ok
  slot=${dn##*_}; stamp=${dn%_*}
  kernel=$(q info_get "$src/info.txt" kernel); fpr=$(q info_get "$src/info.txt" fingerprint)
  # (the ROM build when the copy names it: the fingerprint may be spoofed)
  f=$(rid_of "$src/info.txt"); ok=$(q info_get "$src/info.txt" rom_version)
  [ -n "$f" ] && fpr=$(fill "$M_ROM_BUILT" ver "${ok:-?}" date "$(utc_h "$f")")
  ok=
  label=$(q label_of "$src/info.txt" "$cls")
  name="$label-slot_$slot-$stamp"
  if [ "$cls" = STOCK ]; then parent="$BASE/$PC_STOCK"
  else ser=$(q series_of "$kernel"); parent="$BASE/$(fill "$PC_PREV_FMT" series "$ser")"; fi
  mkdir -p "$parent" 2>/dev/null || { PD_WHAT="не удаётся создать $parent"; return 1; }
  dst="$parent/$name"
  while [ -e "$dst" ]; do dst="$parent/$name-$i"; i=$((i + 1)); done
  if ! mv "$src" "$dst" 2>/dev/null; then
    mkdir -p "$dst" || { PD_WHAT="не удаётся создать $dst"; return 1; }
    ok=1
    for f in "$src"/*; do
      [ -f "$f" ] || continue
      cp -p "$f" "$dst/" || ok=
      [ "$(q fsize "$f")" = "$(q fsize "$dst/${f##*/}")" ] || ok=
      case $f in *.img) [ "$(q sha256_of "$f")" = "$(q sha256_of "$dst/${f##*/}")" ] || ok=;; esac
    done
    if [ -z "$ok" ]; then rm -rf "$dst"; PD_WHAT="не удалось скопировать в $parent"; return 1; fi
    rm -rf "$src"
  fi
  PD_PATH=$dst
  logl "filed $cls: $dst"
  if [ "$cls" = STOCK ]; then
    goodm "$(fill "$M_STOCK_SAVED" path "$dst")"
    say "$(fill "$M_STOCK_SAVED2" kernel "$kernel" fpr "${fpr:-?}" slot "_$slot")$( [ "$kernel" = unknown ] && printf '%s' "$M_STOCK_UNKNOWNK")"
    SUM_STOCK=$dst; SUM_STOCK_FPR=; OPENDIR=$dst
  else
    goodm "$(fill "$M_PREV_SAVED" series "$(q series_of "$kernel")" label "$label" path "$dst")"
    SUM_PREV=$dst
  fi
  SAVED=1
  add_known "$cls" "$dst"
  return 0
}

# pd_lost <wanted state> <adb output>: the last pull or listing failed
# because the phone is gone (adb's message, or it is not in that state now)
pd_lost() {
  lost "$2" && return 0
  state_now
  [ "$DSTATE" != "$1" ]
}
# pd_reconnect <what failed>: the cable dropped during a pull: wait for the
# phone to come back in the same state (at most MAX_PULLS times). False when
# it does not (PD_LOST), or comes back booted (PD_GONE: a copy in the
# recovery's RAM is gone then)
pd_reconnect() {
  PD_LOSTN=$((PD_LOSTN + 1))
  if [ "$PD_LOSTN" -gt "$MAX_PULLS" ]; then PD_LOST=1; return 1; fi
  warnm "$(fill "$M_PULL_LOST" what "$1")"
  if [ "$WHERE" = android ]; then
    W_ALSO=; W_MORE=$M_WAIT_MORE_CABLE; wait_phone device "$T_USER" H_REPLUG_A ""
  else
    W_ALSO=device; W_UNAUTH=$T_UNAUTH; W_MORE=$M_WAIT_MORE_CABLE; wait_phone recovery "$T_USER" H_REPLUG ""
    case $WSTATE in
      device) PD_GONE=1; PD_WHAT="телефон перезагрузился в систему"; return 1;;
      unauthorized) PD_LOST=1; return 1;;
    esac
  fi
  logl "phone back after a lost pull ($PD_LOSTN)"
  return 0
}
# pull_dir <remote dir> <root 0|1> [<listing prefix>] [mkrz]: one backup dir to
# the PC (12.3-12.5): already there (PD_KNOWN=1), or pulled, verified
# (one more pull on failure) and filed. A dropped cable: the phone is
# waited for and the dir pulled again (PD_LOST / PD_GONE when that fails).
# PD_PATH, PD_CLASS, PD_RZOK, PD_WHAT.
# 0 ok, 1 verification failed, 2 not readable / pull failed, 3 no space
pull_dir() {
  local rd=$1 rt=$2 lp=$3 mkrz=$4 rzpc= dn=${1##*/} dslot kernel cls hb hv hd k need free dst try f want=recovery rc
  PD_PATH=; PD_CLASS=; PD_RZOK=; PD_KNOWN=; PD_WHAT=; PD_LOST=; PD_GONE=; PD_LOSTN=0; PD_FILE=
  [ "$WHERE" = android ] && want=device
  [[ $dn =~ $BAKDIR_RE ]] || { PD_WHAT="не папка копии: $dn"; return 2; }
  dslot=${BASH_REMATCH[2]}
  if [ -z "$lp" ]; then
    lp="$TMPD/pd"
    while :; do
      list_dir "$rd" "$rt" "$lp"; rc=$?
      [ $rc = 0 ] && break
      if [ $rc = 2 ] && pd_lost "$want" "$TMPD/dc.out"; then
        pd_reconnect "папка $rd не читается" && continue
        [ -n "$PD_WHAT" ] || PD_WHAT="связь с телефоном пропала"
        return 2
      fi
      PD_WHAT="папка $rd не читается"; [ $rc = 1 ] && PD_WHAT="папки $rd на телефоне нет"
      return 2
    done
  fi
  kernel=$(q info_get "$lp.info" kernel)
  cls=$(q class_of "$kernel"); PD_CLASS=$cls
  hb=$(q sums_get "$lp.sums" boot.img); hv=$(q sums_get "$lp.sums" vendor_boot.img); hd=$(q sums_get "$lp.sums" dtbo.img)
  k=$(q find_known "$cls" "$dslot" "$hb" "$hv" "$hd")
  if [ -n "$k" ]; then
    # (its images must still be whole and of the phone's sizes; a folder
    # without a restore zip does not count when the phone's copy has one)
    f=$(ls "$k"/taoyao-restore-*.zip 2>/dev/null | head -n 1); f=${f##*/taoyao-restore-}; f=${f%.zip}
    if verify_backup "$k" "${f:-$dn}" && \
       [ "$(q fsize "$k/boot.img")" = "$(awk -F: '$3 == "boot.img" { print $1 }' "$lp.files")" ] && \
       [ "$(q fsize "$k/vendor_boot.img")" = "$(awk -F: '$3 == "vendor_boot.img" { print $1 }' "$lp.files")" ] && \
       [ "$(q fsize "$k/dtbo.img")" = "$(awk -F: '$3 == "dtbo.img" { print $1 }' "$lp.files")" ] && \
       { [ -z "$VB_RZNONE" ] || ! grep -q ':taoyao-restore-[^:]*\.zip$' "$lp.files"; }; then
      PD_KNOWN=1; PD_PATH=$k; PD_RZOK=$VB_RZOK
      # (not again for the RAM copy that show_notes just named)
      [ "$rd" = "$RAMNOTE_DIR" ] || say "$(fill "$M_COPY_KNOWN" path "$k")"
      if [ "$cls" = STOCK ]; then SUM_STOCK=$k; SUM_STOCK_FPR=; [ -z "$OPENDIR" ] && OPENDIR=$k; else SUM_PREV=$k; fi
      # its install logs that the PC folder lacks: into the pull folder
      grep -E ':install-[0-9]{8}-[0-9]{6}\.log$' "$lp.files" > "$TMPD/pd.logs"
      : > "$TMPD/pd.need"
      while IFS=: read -r _s _m f; do [ -f "$k/$f" ] || printf '%s\n' "$_s:$_m:$f" >> "$TMPD/pd.need"; done < "$TMPD/pd.logs"
      if [ -s "$TMPD/pd.need" ] && ensure_pulldir; then
        mkdir -p "$PULLDIR/$dn" && pull_files "$rd" "$rt" "$TMPD/pd.need" "$PULLDIR/$dn" >/dev/null
      fi
      return 0
    fi
    logl "known folder $k does not verify (${VB_WHAT:-no restore zip}): pulling again"
  fi
  need=$(awk -F: '{ s += $1 } END { print int(s * 1.05 / 1048576) + 100 }' "$lp.files")
  free=$(free_mb "$BASE")
  if [ -n "$free" ] && [ "$free" -lt "$need" ]; then
    errm "$(fill "$M_PC_SPACE" n "$free" m "$need")"; PD_WHAT="мало места на диске компьютера"; return 3
  fi
  ensure_pulldir || { PD_WHAT="нет папки для копии"; return 2; }
  dst="$PULLDIR/$dn"
  try=1
  while [ $try -le 2 ]; do
    rm -rf "$dst"; mkdir -p "$dst" || { PD_WHAT="не удаётся создать $dst"; return 2; }
    PULLCUR=$dst
    if ! pull_files "$rd" "$rt" "$lp.files" "$dst"; then
      PULLCUR=; rm -rf "$dst"
      if pd_lost "$want" "$TMPD/pull.out"; then
        pd_reconnect "${PD_FILE:-$PD_WHAT}" || { [ -n "$PD_WHAT" ] || PD_WHAT="связь с телефоном пропала"; return 2; }
        # (still there? a recovery that restarted has lost its RAM copy)
        list_dir "$rd" "$rt" "$TMPD/pdre"; rc=$?
        [ $rc = 1 ] && { PD_GONE=1; PD_WHAT="копии $rd на телефоне больше нет (телефон перезагружался?)"; return 2; }
        continue
      fi
      [ $try = 2 ] && return 2
      try=$((try + 1)); continue
    fi
    PULLCUR=
    # (way A copy only: the restore zip made here; info.txt then names it)
    if [ -n "$mkrz" ]; then
      rzpc=
      if mk_rz "$dst" "$dn"; then
        awk -F: -v OFS=: -v s="$(q fsize "$dst/info.txt")" '$3 == "info.txt" { $1 = s } { print }' "$lp.files" > "$lp.files2" && mv -f "$lp.files2" "$lp.files"
      else rzpc=$RZ_WHY; fi
    fi
    verify_backup "$dst" "$dn" "$lp.files" && break
    logl "verify failed: $VB_WHAT"
    [ $try = 1 ] && warnm "Копия скопировалась с ошибкой ($VB_WHAT). Копирую ещё раз…"
    try=$((try + 1))
  done
  if [ $try -gt 2 ]; then rm -rf "$dst"; PD_WHAT=$VB_WHAT; return 1; fi
  if [ -n "$VB_RZNONE" ]; then goodm "$(fill "$M_VERIFY_OK_NORZ" dir "$dn")"; else goodm "$(fill "$M_VERIFY_OK" dir "$dn")"; fi
  file_backup "$dst" "$cls" "$dn" || return 2
  PD_RZOK=$VB_RZOK
  if [ -n "$VB_RZNONE" ]; then
    case $rzpc in
      tool) warnm "$(fill "$M_RZ_PC_NOTOOL" path "$PD_PATH")";;
      ?*) warnm "$(fill "$M_RZ_PC_FAIL" path "$PD_PATH")";;
      *) warnm "$(fill "$M_RZ_MISSING" path "$PD_PATH")";;
    esac
  fi
  return 0
}

# pull_store <remote root> <root 0|1>: every backup dir there (newest
# first) that the PC lacks, plus the newest pstore dir (12.6). Never fatal.
pull_store() {
  local r=$1 rt=$2 d i=0 n=0 k=0 sz=0 kernel cls hb hv hd ps
  PS_N=0
  [ -f "$TMPD/known" ] || scan_known
  list_root "$r" "$rt" || return 0
  grep -E "$BAKDIR_RE" "$TMPD/lr" | sort -r > "$TMPD/ps.names"
  [ -s "$TMPD/ps.names" ] || return 0
  while IFS= read -r d; do
    i=$((i + 1))
    list_dir "$r/$d" "$rt" "$TMPD/ps$i" || { echo skip > "$TMPD/ps$i.state"; continue; }
    n=$((n + 1))
    case $d in *"$SLOT") if [ -z "$SI_BEST" ] || [[ $d > $SI_BEST ]]; then SI_BEST=$d; cp -f "$TMPD/ps$i.info" "$TMPD/slotinfo.txt"; fi;; esac
    kernel=$(q info_get "$TMPD/ps$i.info" kernel); cls=$(q class_of "$kernel")
    hb=$(q sums_get "$TMPD/ps$i.sums" boot.img); hv=$(q sums_get "$TMPD/ps$i.sums" vendor_boot.img); hd=$(q sums_get "$TMPD/ps$i.sums" dtbo.img)
    if [ -n "$(q find_known "$cls" "_${d##*_}" "$hb" "$hv" "$hd")" ]; then echo known > "$TMPD/ps$i.state"
    else echo new > "$TMPD/ps$i.state"; k=$((k + 1)); sz=$((sz + $(awk -F: '{ s += $1 } END { printf "%d", s }' "$TMPD/ps$i.files"))); fi
  done < "$TMPD/ps.names"
  PS_N=$n
  [ $n -gt 0 ] && { [ -z "$PS_QUIET" ] || [ $k -gt 0 ]; } && say "$(fill "$M_ON_PHONE" n "$n" k "$k" size "$(size_h "$sz")")"
  i=0
  while IFS= read -r d; do
    i=$((i + 1))
    [ "$(cat "$TMPD/ps$i.state" 2>/dev/null)" = skip ] && continue
    [ -n "$PS_QUIET" ] && [ "$(cat "$TMPD/ps$i.state" 2>/dev/null)" = known ] && continue
    if ! pull_dir "$r/$d" "$rt" "$TMPD/ps$i"; then
      warnm "$(fill "$M_VERIFY_FAILED_DISK" dir "$r/$d" what "${PD_WHAT:-?}")"
    fi
    case $r in /tmp/*) [ -n "$PD_PATH" ] && note_ram "$r/$d" "$PD_PATH" "$PD_RZOK";; esac
  done < "$TMPD/ps.names"
  # the newest pstore dir (logs of a boot that failed), once
  ps=$(grep -E "$PSTORE_RE" "$TMPD/lr" | sort | tail -n 1)
  if [ -n "$ps" ] && ! ls -d "$BASE/$BACKUP_NAME"-*/"$ps" >/dev/null 2>&1; then
    if dev_call 30 "$rt" "set +f; cd $r/$ps 2>/dev/null && for f in *; do [ -f \"\$f\" ] && echo F=\$(stat -c %s \"\$f\"):0:\$f; done; echo end=1" && probe_ok; then
      sed -n 's/^F=//p' "$TMPD/dc.out" > "$TMPD/pst.files"
      if [ -s "$TMPD/pst.files" ] && ensure_pulldir && mkdir -p "$PULLDIR/$ps"; then
        pull_files "$r/$ps" "$rt" "$TMPD/pst.files" "$PULLDIR/$ps" >/dev/null && say "Журнал прошлой загрузки (pstore) сохранён: $PULLDIR/$ps"
      fi
    fi
  fi
  return 0
}
# note_ram <remote dir> <pc path> <rz ok>: a RAM copy of this recovery
# session that is on the PC now (RAM_DONE: "dir|path|rzok" lines)
RAM_DONE=
note_ram() { RAM_DONE="$RAM_DONE$1|$2|$3
"; }
ram_onpc() {  # <remote dir>: its PC path if it is verified there (with its restore zip)
  printf '%s' "$RAM_DONE" | awk -F'|' -v d="$1" '$1 == d && $3 == "1" { print $2; exit }'
}
ram_onpc_any() {  # <remote dir>: its PC path, with or without a restore zip
  printf '%s' "$RAM_DONE" | awk -F'|' -v d="$1" '$1 == d && $2 != "" { print $2; exit }'
}
# slot_vs <PC folder>: the slot (P_HASH of SLOT) against that copy's
# SHA256SUMS: SLOTCMP = same, diff or unread
slot_vs() {
  SLOTCMP=unread
  [ -f "$1/SHA256SUMS" ] || return 0
  slot_hashes 0 || return 0
  if [ "$H_boot" = "$(q sums_get "$1/SHA256SUMS" boot.img)" ] && [ "$H_vendor_boot" = "$(q sums_get "$1/SHA256SUMS" vendor_boot.img)" ] \
     && [ "$H_dtbo" = "$(q sums_get "$1/SHA256SUMS" dtbo.img)" ]; then SLOTCMP=same; else SLOTCMP=diff; fi
  logl "slot $SLOT against $1: $SLOTCMP"
}

########################################################################
# stock_now <slot kernel>: M_STOCK_NOW (13.2) once, before the copy is made:
# not for a build of this port, and not once stock images of this slot were
# saved (or found on the PC) in this run
stock_now() {
  [ -n "$1" ] && [ -z "$GATE_NOW" ] || return 0
  in_port "$1" && return 0
  [ -n "$SUM_STOCK" ] && [ "$(q info_get "$SUM_STOCK/info.txt" slot)" = "$SLOT" ] && return 0
  GATE_NOW=1; say "$(fill "$M_STOCK_NOW" kernel "$1")"
}
# the pre-write gate (section 13): <slot kernel> <fingerprint> <boot_ramdisk>
# <from: copy|phone|rec> <ROM build: ro.build.date.utc>. Each question is
# asked once per run.
gate() {
  local kern=$1 fpr=$2 brd=$3 src=$4 rid=$5 found= how= maybe= other= older= have c none
  [ -n "$kern" ] || return 0
  scan_known
  if in_port "$kern"; then
    # 13.2 stock images of this ROM build on the PC? (the boot ramdisk, else
    # the build time, else only the fingerprint: rom_list)
    rom_list STOCK "$SLOT" "$brd" "$rid" "$fpr" > "$TMPD/gate.rl"
    logl "gate: slot kernel $kern ($src), ramdisk ${brd:-?}, build ${rid:-?}, fingerprint ${fpr:-?}: $(awk -F'\t' '{ printf "%s %s; ", $1, $2 }' "$TMPD/gate.rl")"
    found=$(awk -F'\t' '$1 == "same" { print $2; exit }' "$TMPD/gate.rl")
    if [ -z "$found" ]; then found=$(awk -F'\t' '$1 == "fpr" { print $2; exit }' "$TMPD/gate.rl"); [ -n "$found" ] && how=fpr; fi
    if [ -n "$found" ]; then
      if [ "$GATE_STOCK" != present ]; then
        if [ "$how" = fpr ]; then
          say "$(fill "$M_STOCK_PRESENT_FPR" slot "$SLOT" path "$found")"
          warnm "$(fill "$M_STOCK_FPRONLY" why "$(fpr_why "$found" "$rid")")"; GATE_FPRSAID=$found
        else goodm "$(fill "$M_STOCK_PRESENT" path "$found")"; fi
      fi
      GATE_STOCK=present; SUM_STOCK=$found; SUM_STOCK_FPR=; [ "$how" = fpr ] && SUM_STOCK_FPR=$found
    elif [ "$GATE_STOCK" != yes ]; then
      other=$(rl_paths "$TMPD/gate.rl" other); older=$(rl_paths "$TMPD/gate.rl" older); maybe=$(rl_paths "$TMPD/gate.rl" fprdiff unknown)
      [ -n "$other" ] && warnm "$(fill "$M_STOCK_OTHERBUILD" slot "$SLOT" list "$other")"
      [ -n "$older" ] && warnm "$(fill "$M_STOCK_OLDER" slot "$SLOT" list "$older" now "$(utc_h "$rid")")"
      none=$M_STOCK_NONE_PC
      if [ -n "$maybe" ]; then
        if [ -z "$brd$rid$fpr" ]; then warnm "$(fill "$M_STOCK_CANTCMP" slot "$SLOT" list "$maybe")"; none=$M_STOCK_NONE_UNK
        else warnm "$(fill "$M_STOCK_MAYBE" slot "$SLOT" list "$maybe")"; fi
      fi
      if prompt_yes "$(fill "$M_STOCK_MISSING" none "$(fill "$none" slot "$SLOT")" series "$(q series_of "$kern")" kernel "$kern" slot "$SLOT" BN "$BACKUP_NAME" ver "$ZVER")" 1; then
        GATE_STOCK=yes
      else
        SUM_WHAT="Ничего не записано: нет стоковых образов на компьютере (вы ответили «нет»)."
        warn_phase; finish $RC_CANCEL
      fi
    fi
    # 13.3 the version
    if [ -z "$GATE_VER" ]; then
      have=$(ver_of_rel "$kern")
      if [ -z "$have" ]; then say "$M_OLD_UNNUMBERED"; GATE_VER=1
      elif [ "$(q series_of "$kern")" = "$ZSERIES" ]; then
        c=$(vercmp "$have" "$ZVER")
        if [ "$c" = 1 ]; then
          prompt_yes "$(fill "$M_DOWNGRADE_ASK" have "$have" ver "$ZVER")" 1 || { warn_phase; finish $RC_CANCEL; }
        elif [ "$c" = 0 ]; then
          prompt_yes "$(fill "$M_SAME_ASK" ver "$ZVER")" 1 || { warn_phase; finish $RC_CANCEL; }
        fi
        GATE_VER=1
      fi
    fi
  else
    stock_now "$kern"
  fi
  # 13.5 KernelSU
  if [ -n "$ZNOKSU" ] && [ -z "$GATE_NOKSU" ] && { [ "$WAY" = A ] || in_port "$kern"; }; then
    GATE_NOKSU=1; warnm "$M_NOKSU_NOTE"
  fi
  return 0
}

########################################################################
# (A): the zip's own installer from the booted system with root (section 9)

# a_stage <zip>: the files pushed with it into $TMPD/a: update-binary and
# tools/busybox from that zip, and rf-run.sh (LF line ends)
a_stage() {
  local d="$TMPD/a"
  rm -rf "$d"; mkdir -p "$d" || return 1
  zip_cat "$1" META-INF/com/google/android/update-binary > "$d/update-binary" 2>/dev/null
  [ -s "$d/update-binary" ] || return 1
  zip_cat "$1" tools/busybox > "$d/busybox" 2>/dev/null
  [ -s "$d/busybox" ] || rm -f "$d/busybox"
  printf '%s\n' "$RF_RUN" > "$d/rf-run.sh"
  return 0
}
# a_push1 <local dir> <local name> <remote path>: one adb push
a_push1() {
  local rc
  logl "> adb push $2 $3"
  run_to 900 "$TMPD/push.out" adb_in "$1" push "$2" "$3"; rc=$?
  logl "< rc=$rc $(tr '\r' '\n' < "$TMPD/push.out" | grep -v '^\[' | tail -n 2 | tr '\n' ' ' | cutc 300)"
  [ $rc = 0 ] && return 0
  A_PUSHERR=$(tr '\r' '\n' < "$TMPD/push.out" | grep -iE 'error|failed|denied|no space|not found' | head -n 1 | cutc 120)
  [ -n "$A_PUSHERR" ] || A_PUSHERR="код $rc"
  return 1
}
# a_push <zip> <remote name>: the zip and the staged files into PH_WORK,
# then their sha256 on the phone against the PC's (one more try on a
# mismatch). 0 ok; 1 failed (A_PUSHERR, or a mismatch: A_PUSHBAD=1)
a_push() {
  local z=$1 rn=$2 try=1 f want got files list
  A_PUSHERR=; A_PUSHBAD=
  while [ $try -le 2 ]; do
    dev_call 30 0 "$(pcmd "$P_A_PREP")"
    if ! probe_ok; then
      lost && { wait_phone device "$T_USER" "" pre; continue; }
      A_PUSHERR=$(cutc 120 < "$TMPD/dc.out"); return 1
    fi
    a_push1 "${z%/*}" "${z##*/}" "$PH_WORK/$rn" || { lost "$TMPD/push.out" && { wait_phone device "$T_USER" "" pre; try=$((try + 1)); continue; }; return 1; }
    a_push1 "$TMPD/a" update-binary "$PH_WORK/update-binary" || return 1
    a_push1 "$TMPD/a" rf-run.sh "$PH_WORK/rf-run.sh" || return 1
    files="$rn update-binary rf-run.sh"
    if [ -f "$TMPD/a/busybox" ]; then a_push1 "$TMPD/a" busybox "$PH_WORK/bb/busybox" || return 1; files="$files bb/busybox"; fi
    dev_call 120 0 "$(pcmd "$P_A_SUMS" FILES "$files")"
    list=ok
    for f in $files; do
      case $f in "$rn") want=$(q sha256_of "$z");; bb/busybox) want=$(q sha256_of "$TMPD/a/busybox");; *) want=$(q sha256_of "$TMPD/a/$f");; esac
      got=$(awk -v n="$f" '$2 == n { print $1; exit }' "$TMPD/dc.out")
      [ -n "$want" ] && [ "$got" = "$want" ] || { list=bad; logl "sha256 on the phone: $f ${got:-none}, PC $want"; }
    done
    [ $list = ok ] && { logl "pushed and checked: $files"; return 0; }
    try=$((try + 1))
  done
  A_PUSHBAD=1
  return 1
}
# a_now: the phone's clock (for the freshness of the logs)
a_now() {
  dev_call 20 0 "$P_NOW" && probe_ok && kv now
}
# a_start <kernel|restore> <zip name in PH_WORK>: rf-run.sh under su.
# 0 started (A_PID), 2 an installer of an earlier run is still running
# (A_PID), 1 did not start (A_STARTOUT)
a_start() {
  local l
  A_PID=; A_STARTOUT=
  dev_call 60 1 "$(pcmd "$P_A_START" KIND "$1" ZIP "$2")"
  l=$(grep -E '^RF_' "$TMPD/dc.out" | head -n 1)
  case $l in
    'RF_STARTED '*) A_PID=${l#RF_STARTED }; logl "installer started on the phone (pid $A_PID)"; return 0;;
    'RF_BUSY '*) A_PID=${l#RF_BUSY }; return 2;;
  esac
  A_STARTOUT=$(grep -v '^$' "$TMPD/dc.out" | head -n 1 | cutc 160)
  return 1
}
# a_show <line of ub.out>: "ui_print <text>" as "  | <text>", coloured
a_show() {
  local l=$1 t
  case $l in 'ui_print '*) t=${l#ui_print };; *) return 0;; esac
  case $t in ''|' ') return 0;; esac
  case $t in
    '!!'*) errm "  | $t";;
    'Done:'*) goodm "  | $t";;
    'NOT INSTALLED YET'*|'! Note'*|'Note:'*) warnm "  | $t";;
    *) say "  | $t";;
  esac
}
# a_watch <from offset>: polls ub.out on the phone every second and shows
# the new lines until ub.rc appears (A_RC). The installer runs detached:
# a pulled cable or Ctrl+C on the PC never stops it. 0 ended; 1 the work
# folder vanished; 2 the time limit (T_INSTALL_A) passed
a_watch() {
  local off=${1:-0} useroot=0 first=1 t0=$SECONDS last=$SECONDS nextgo=60 slow= l sz rc n shown=0 fin=
  A_RC=
  : > "$TMPD/a.stream"
  PHASE=run
  while :; do
    dev_call 30 "$useroot" "$(pcmd "$P_A_POLL" OFF "$off" OFF1 $((off + 1)))"
    if ! grep -q '^RF_POLL' "$TMPD/dc.raw" 2>/dev/null; then
      if lost; then
        warnm "$M_A_CABLE"
        W_ALSO=; wait_phone device "$T_USER" "" run
        PHASE=run; continue
      fi
      nap 1; continue
    fi
    l=$(tr -d '\r' < "$TMPD/dc.raw" | grep -m 1 '^RF_POLL')
    case $l in *nowork*) logl "work folder gone"; return 1;; esac
    rc=$(printf '%s' "$l" | sed -n 's/.* rc=\([0-9]*\) .*/\1/p')
    sz=$(printf '%s' "$l" | sed -n 's/.* sz=\([0-9]*\).*/\1/p')
    if [ -n "$first" ]; then
      first=
      if [ -z "$sz" ] && [ "$useroot" = 0 ]; then logl "ub.out not readable as shell: polling under su"; useroot=1; continue; fi
    fi
    if [ -n "$sz" ]; then
      if [ "$sz" -lt "$off" ]; then off=0; : > "$TMPD/a.stream"; shown=0; logl "ub.out started again"; continue; fi
      if [ "$sz" -gt "$off" ]; then
        # (the bytes after the marker line, exactly; CR of an old adb's tty
        # mode removed. The last line may still be incomplete: it stays so)
        n=$(grep -n -m 1 '^RF_POLL' "$TMPD/dc.raw" | cut -d: -f1)
        n=$(head -n "$n" "$TMPD/dc.raw" | wc -c | tr -d ' ')
        tail -c +$((n + 1)) "$TMPD/dc.raw" | tr -d '\r' > "$TMPD/a.new"
        cat "$TMPD/a.new" >> "$TMPD/a.stream"
        off=$sz; last=$SECONDS
        n=$(wc -l < "$TMPD/a.stream" | tr -d ' ')
        if [ "$n" -gt "$shown" ]; then
          sed -n "$((shown + 1)),${n}p" "$TMPD/a.stream" > "$TMPD/a.lines"
          while IFS= read -r l; do a_show "$l"; done < "$TMPD/a.lines"
          shown=$n
        fi
      fi
    fi
    if [ -n "$rc" ]; then
      # (one more look: bytes written between the size and the rc reading)
      [ -n "$fin" ] && { A_RC=$rc; break; }
      fin=1; continue
    fi
    if [ $((SECONDS - last)) -ge "$nextgo" ]; then
      say "$(fill "$M_A_GOING" t "$(elapsed $((SECONDS - t0)))")"
      nextgo=$((nextgo + 60))
      [ -z "$slow" ] && [ $((SECONDS - last)) -ge 180 ] && { slow=1; warnm "$M_A_SLOW"; }
    fi
    [ $((SECONDS - last)) -lt 60 ] && nextgo=60
    [ $((SECONDS - t0)) -ge "$T_INSTALL_A" ] && return 2
    nap 1
  done
  # (the last line without a newline)
  l=$(tail -c 300 "$TMPD/a.stream" | tail -n 1)
  [ -n "$l" ] && [ "$(wc -l < "$TMPD/a.stream" | tr -d ' ')" = "$shown" ] && a_show "$l"
  logl "installer on the phone ended: rc $A_RC"
  logf "$TMPD/a.stream" "phone "
  return 0
}
# a_result: the result of an (A) kernel run (11.1): the streamed text, the
# fresh last log, the newest install log of the backup dir, AKHOME's log
a_result() {
  local files="$TMPD/a.text" m f cut=$(( ${A_T0P:-0} - 5 )) d nl ml k=0 lf
  RES_DIR=; RES_SLOT=; RES_REUSED=; RESULT=; RES_LOG=
  sed -n 's/^ui_print \(.*\)$/\1/p' "$TMPD/a.stream" | grep -v '^ui_print$' > "$TMPD/a.text"
  for f in "$PH_WORK/$LAST_LOG" "$PH_WORK/ak/install.log"; do
    m=$(remote_mtime "$f" 0)
    [ -n "$m" ] && [ "$m" -ge "$cut" ] || continue
    k=$((k + 1)); lf="$TMPD/al$k.log"
    fetch_text "$f" "$lf" 0 || fetch_text "$f" "$lf" 1 || continue
    log_new "$lf" || { logl "log $f is of an earlier run"; continue; }
    log_ours "$lf" && files="$files $lf"
  done
  for f in $files; do log_facts "$f"; done
  d=$RES_DIR
  if [ -n "$d" ] && list_dir "$d" 0 "$TMPD/ard"; then
    nl=; ml=0
    while IFS=: read -r _s m f; do
      [[ $f =~ $INSTLOG_RE ]] || continue
      [ "${m:-0}" -ge "$ml" ] && { ml=${m:-0}; nl=$f; }
    done < "$TMPD/ard.files"
    if [ -n "$nl" ] && [ "$ml" -ge "$cut" ] && fetch_text "$d/$nl" "$TMPD/ari.log" 0 && log_new "$TMPD/ari.log"; then
      files="$files $TMPD/ari.log"
    fi
  fi
  RES_DIR=; RES_SLOT=; RES_REUSED=
  # shellcheck disable=SC2086
  classify $files
  [ -s "$TMPD/a.text" ] || [ "$RESULT" != INCOMPLETE ] || RESULT=NOLOG
  [ -z "$RESULT" ] && RESULT=NOLOG
  RES_LOGS=$files
  logl "result (A): $RESULT (dir ${RES_DIR:-?}, slot ${RES_SLOT:-?}, rc ${A_RC:-?})"
  return 0
}
# a_clean: the pushed files and the runner's own files (the last logs, an
# abort's AKHOME and the installer's fallback copy stay)
a_clean() {
  dev_call 30 0 "$(pcmd "$P_A_CLEAN")" >/dev/null 2>&1 || true
  probe_ok || dev_call 30 1 "$(pcmd "$P_A_CLEAN")" >/dev/null 2>&1
  return 0
}
# a_run <kernel|restore> <zip> <remote name>: steps 4 and 5 of way A: stage,
# push, start (or watch one that runs already), watch. A_WATCH = 0 ended,
# 1 work folder gone, 2 time limit
a_run() {
  local kind=$1 z=$2 rn=$3 rc
  if [ -z "$A_SKIPSTART" ]; then
    a_stage "$z" || fail "$(fill "$M_A_NOSTART" out "в zip нет update-binary")"
    if [ "$kind" = kernel ]; then say "$(fill "$M_SENDING" ver "$ZVER")"; else say "$M_SENDING_RZ"; fi
    if ! a_push "$z" "$rn"; then
      a_clean
      if [ -n "$A_PUSHBAD" ]; then fail "$M_PUSH_BAD"; fi
      fail "$(fill "$M_PUSH_FAIL" line "$A_PUSHERR")"
    fi
    goodm "ОК: файлы на телефоне проверены (sha256)."
  fi
  [ -n "$A_STEPH" ] && step_h "$A_STEPN" "$A_STEPH"
  # (the logs there now are of earlier runs)
  RUN_ROOT=1 note_runids "$PH_WORK/$LAST_LOG" "$PH_WORK/ak/install.log"
  A_T0P=$(a_now)
  if [ -z "$A_SKIPSTART" ]; then
    a_start "$kind" "$rn"; rc=$?
    case $rc in
      1) a_clean; fail "$(fill "$M_A_NOSTART" out "${A_STARTOUT:-нет ответа}")";;
      2) warnm "$M_A_RUNNING";;
    esac
  fi
  WROTE=maybe; SUM_ON=1
  say "$M_A_STARTED"
  a_watch 0; A_WATCH=$?
  return 0
}

########################################################################
# (B): recovery sideload (section 10)

# b_from_android <sideload|recovery> <hint> <hint at once 1|0> [<limit
# message>]: "adb reboot <target>" (after the user's yes) and the wait for
# the recovery; <hint> (a variable name) is shown at once or after
# T_SIDELOAD_UP, <limit message> (a variable name) at the time limit.
# FRESHSL=1 when the phone shows up in "sideload" after it was gone (a
# fresh recovery boot: /tmp is empty)
b_from_android() {
  local tg=$1 hint=$2 now=$3 lmsg=$4 t el again=
  PHASE=wait; SUM_ON=1
  say "$M_REBOOTING_REC"
  logl "> adb reboot $tg"
  run_to 30 "$TMPD/rb.out" "$ADB" -s "$SERIAL" reboot "$tg"
  logl "< rc=$? $(head -c 200 "$TMPD/rb.out")"
  # (still in the system after T_REBOOT_AGAIN: the command did not work)
  t=$SECONDS
  while :; do
    state_now
    [ "$DSTATE" != device ] && break
    el=$((SECONDS - t))
    if [ $el -ge "$T_REBOOT_AGAIN" ] && [ -z "$again" ]; then
      again=1
      logl "still booted after adb reboot $tg: adb reboot recovery"
      run_to 30 "$TMPD/rb.out" "$ADB" -s "$SERIAL" reboot recovery
      if [ "$tg" = sideload ]; then hintm "$H_APPLY_LOS"; fi
    fi
    [ $el -ge "$T_REBOOT_FAIL" ] && fail "$M_NO_REBOOT"
    nap 1
  done
  if [ "$now" != 1 ]; then
    W_SOFT=1; W_POLL=1; W_ALSO=device; wait_phone "sideload recovery" "$T_SIDELOAD_UP" "" wait
  else
    WSTATE=timeout
  fi
  if [ "$WSTATE" = timeout ]; then
    W_POLL=1; W_ALSO=device; [ -n "$lmsg" ] && eval "W_LIMITMSG=\$$lmsg"
    wait_phone "sideload recovery" "$T_USER" "$hint" wait
  fi
  case $WSTATE in
    device) fail "$M_BOOTED_NOT_REC";;
    sideload) FRESHSL=1; NEXT=COPY
              case $CMD in install*) say "$(fill "$M_NO_SHELL_CHECKS" n "${BATP:-?} %")";; esac;;
    recovery) FRESHSL=;;
  esac
  return 0
}

# b_wait_rec_start: the phone is in "sideload" at the start, not by this
# run: never send blind (an earlier step 1 of this recovery session would
# make the next sideload write at once). Wait for "recovery" and probe
b_wait_rec_start() {
  case $CMD in
    backup) warnm "$M_SIDELOAD_UNKNOWN_B";;
    restore*) warnm "$M_SIDELOAD_UNKNOWN_R";;
    *) warnm "$M_SIDELOAD_UNKNOWN";;
  esac
  W_ALSO=device; W_UNAUTH=$T_UNAUTH; wait_phone recovery "$T_USER" H_LEAVE_SIDELOAD wait
  [ "$WSTATE" = device ] && fail "$M_BOOTED_NOT_REC"
  [ "$WSTATE" = unauthorized ] && { SUM_ON=1; SUM_WHAT="Ничего не записано: рекавери не пускает компьютер по ADB."; fail "$M_REC_UNAUTH"; }
  return 0
}

# rec_copies: every backup dir the probe listed, RAM (/tmp) first: they
# vanish with the next reboot (10.2 point 1, 12.6)
rec_copies() {
  local roots r n=0
  roots=$(printf '%s\n' "$R_BAKS" | sed 's|/[^/]*$||' | awk 'NF && !s[$0]++')
  for r in $(printf '%s\n' "$roots" | grep "^$REC_TMP/"; printf '%s\n' "$roots" | grep -v "^$REC_TMP/"); do
    pull_store "$r" 0; n=$((n + PS_N))
  done
  PS_TOTAL=$n
  return 0
}
# rec_decide: NEXT for the coming pass (10.2 points 2-3)
rec_decide() {
  local d sl=${SLOT#_} cands= m
  NEXT=COPY; RAMDIR=
  for d in $R_BAKS; do
    case $d in "$REC_TMP/$BACKUP_NAME/"*"_$sl") cands="$cands $d";; esac
  done
  if [ -n "$cands" ]; then
    if slot_hashes 0; then
      for d in $cands; do
        list_dir "$d" 0 "$TMPD/rd" || continue
        if [ "$(q sums_get "$TMPD/rd.sums" boot.img)" = "$H_boot" ] && [ "$(q sums_get "$TMPD/rd.sums" vendor_boot.img)" = "$H_vendor_boot" ] \
           && [ "$(q sums_get "$TMPD/rd.sums" dtbo.img)" = "$H_dtbo" ]; then
          NEXT=WRITE; RAMDIR=$d; cp -f "$TMPD/rd.info" "$TMPD/ram.info"; break
        fi
      done
      for d in $cands; do
        [ "$d" = "$RAMDIR" ] || warnm "$(fill "$M_RAM_OLD" slot "$SLOT" dir "$d")"
      done
    else
      logl "slot hashes not readable: the RAM copy is not reused"
    fi
  fi
  if [ "$NEXT" = WRITE ] && [ -n "$(ram_onpc_any "$RAMDIR")" ] && [ -z "$(ram_onpc "$RAMDIR")" ]; then
    # (on the PC, but without a restore zip: b_install stops with M_RZ_NONE_STOP)
    logl "RAM copy $RAMDIR has no restore zip"
  elif [ "$NEXT" = WRITE ]; then
    if [ "$CMD" = backup ]; then say "$(fill "$M_RAM_REUSE_B" slot "$SLOT" dir "$RAMDIR")"
    else say "$(fill "$M_RAM_REUSE" slot "$SLOT" dir "$RAMDIR")"; fi
    m=$(ram_onpc "$RAMDIR"); [ -n "$m" ] && { say "$(fill "$M_RAM_REUSE_PC" path "$m")"; RAMONPC=$m; }
  elif [ -n "$R_SDUSABLE" ]; then
    NEXT=ONEPASS; say "$(fill "$M_ONEPASS" BN "$BACKUP_NAME")"
  fi
  logl "next pass: $NEXT"
}
# rec_already_done: this recovery session installed KREL already (a log
# says DONE for it and the slot no longer holds that run's backup): 0
rec_already_done() {
  local p f n=0 d nl ml m _s fl
  [ -n "$KREL" ] || return 1
  : > "$TMPD/ad.list"
  for p in $(rec_logs_now); do
    case $p in */"$RLOG_NAME") continue;; esac
    n=$((n + 1)); fetch_text "$p" "$TMPD/ad$n.log" 0 && printf '%s\n' "$TMPD/ad$n.log" >> "$TMPD/ad.list"
  done
  for d in $R_BAKS; do
    case $d in "$REC_TMP/"*) ;; *) continue;; esac
    list_dir "$d" 0 "$TMPD/adl" || continue
    nl=; ml=0
    while IFS=: read -r _s m fl; do
      [[ $fl =~ $INSTLOG_RE ]] || continue
      [ "${m:-0}" -ge "$ml" ] && { ml=${m:-0}; nl=$fl; }
    done < "$TMPD/adl.files"
    [ -n "$nl" ] || continue
    n=$((n + 1)); fetch_text "$d/$nl" "$TMPD/ad$n.log" 0 && printf '%s\n' "$TMPD/ad$n.log" >> "$TMPD/ad.list"
  done
  while IFS= read -r f; do
    [ "$(log_class "$f")" = DONE ] && [ "$(log_release "$f")" = "$KREL" ] || continue
    RES_DIR=; RES_SLOT=; log_facts "$f"
    [ -n "$RES_DIR" ] && [ "${RES_SLOT:-$SLOT}" = "$SLOT" ] || continue
    list_dir "$RES_DIR" 0 "$TMPD/add" || continue
    slot_hashes 0 || return 1
    if [ "$(q sums_get "$TMPD/add.sums" boot.img)" != "$H_boot" ] || [ "$(q sums_get "$TMPD/add.sums" dtbo.img)" != "$H_dtbo" ] \
       || [ "$(q sums_get "$TMPD/add.sums" vendor_boot.img)" != "$H_vendor_boot" ]; then
      logl "already installed in this session: $f (backup $RES_DIR)"
      return 0
    fi
  done < "$TMPD/ad.list"
  RES_DIR=; RES_SLOT=
  return 1
}
# b_probe <install|backup|restore>: P_REC and everything of 10.2.
# 0 ready (NEXT set), 2 already installed in this session
b_probe() {
  probe_rec
  rec_checks
  note_runids $(rec_logs_now)
  if [ "$1" = install ] && [ "$STEPN" -lt 3 ]; then
    step_h 3 "старые копии разделов с телефона — на компьютер (0–2 мин)"
    rec_copies
    [ "$PS_TOTAL" = 0 ] && say "$M_NONE_ON_REC"
  else
    rec_copies
  fi
  [ "$1" = restore ] && return 0
  if [ "$1" = install ] && rec_already_done; then return 2; fi
  rec_decide
  return 0
}

# b_wait_sideload <pass kind> <phase>: the phone into "sideload" (TWRP:
# "twrp sideload" first; LineageOS: the user taps Apply from ADB)
b_wait_sideload() {
  local kind=$1 ph=$2 h
  state_now
  [ "$DSTATE" = sideload ] && return 0
  if [ "$RECKIND" = twrp ] && [ "$DSTATE" = recovery ]; then
    dev_call 20 0 "$P_TWRP_SIDELOAD" >/dev/null 2>&1
    W_SOFT=1; W_POLL=1; wait_phone sideload "$T_TWRP_SL" "" "$ph"
    [ "$WSTATE" = sideload ] && return 0
    h=H_SIDELOAD_TWRP
  elif [ "$kind" = WRITE ] && [ -n "$PASS2" ]; then h=H_APPLY_LOS2
  else h=H_APPLY_LOS; fi
  W_POLL=1; W_ALSO=device; wait_phone sideload "$T_USER" "$h" "$ph"
  if [ "$WSTATE" = device ]; then
    if [ -n "$RAMDIR" ]; then fail "$M_REBOOTED_AFTER_STEP1"; fi
    fail "$M_BOOTED_NOT_REC"
  fi
  return 0
}

# do_sideload <folder> <file> <what> <copy pass 1|0|2 (2: after a fresh
# boot straight into sideload, may be one pass in TWRP)>: one "adb sideload",
# shown as one updating line. XFER = OK, EARLY (nothing reached the
# installer), LATE (broke off), NOTREADY (the phone left sideload)
do_sideload() {
  local d=$1 n=$2 what=$3 copy=$4 pid rc st pct= lastpct=x lastch hn el
  XFER=
  sleep 1
  run_to 10 "$TMPD/gs" "$ADB" -s "$SERIAL" get-state
  st=$(tr -d '\r\n ' < "$TMPD/gs")
  if [ "$st" != sideload ]; then logl "get-state before the sideload: $st"; XFER=NOTREADY; return 0; fi
  TRY=$((TRY + 1)); T0=$SECONDS; SENT_ANY=1
  hintm "$H_SIGNATURE"
  case $copy in
    1) if [ "$RECKIND" = twrp ]; then warnm "$H_STEP1_ERROR_TWRP"; else warnm "$H_STEP1_ERROR_OK"; fi;;
    2) warnm "$H_STEP1_ERROR_FRESH";;
  esac
  # (from here a pass that may write is on its way: a stop is 13 now)
  [ -n "$SL_WRITES" ] && WROTE=maybe
  logl "> adb sideload $n (try $TRY)"
  PHASE=run
  ( trap '' INT; cd -- "$d" && exec "$ADB" -s "$SERIAL" sideload "$n" ) </dev/null > "$TMPD/sl.out" 2>&1 &
  pid=$!; ADBPID=$pid; lastch=$SECONDS; hn=$T_HINT
  logl "sideload started"
  while kill -0 "$pid" 2>/dev/null; do
    nap 1
    pct=$(tr '\r' '\n' < "$TMPD/sl.out" | grep -o '(~[0-9]*%)' | tail -n 1 | tr -dc '0-9')
    if [ "$pct" != "$lastpct" ]; then
      lastpct=$pct; lastch=$SECONDS; hn=$T_HINT
      printf '\r%s ' "$(fill "$M_SENDING_SL" what "$what" pct "${pct:-0}")"; DOTS=1
    fi
    el=$((SECONDS - lastch))
    # ("Install anyway?" stops the transfer part-way: the hint again while it
    # stands below 95 %; at 99 % the installer itself runs on the phone, which
    # may take minutes: no hint, a "… жду" line, the installer's limit)
    if [ "${pct:-0}" -ge 99 ]; then
      if [ $el -ge "$hn" ]; then hn=$((el + 60)); say "$(fill "$M_WAITED" t "$(elapsed $((SECONDS - T0)))")"; fi
      if [ $el -ge "$T_INSTALL_A" ]; then
        logl "sideload: at ${pct} % for ${T_INSTALL_A}s, the installer did not finish, stopped"
        kill "$pid" 2>/dev/null; sleep 1; kill -9 "$pid" 2>/dev/null
        break
      fi
    else
      if [ $el -ge "$hn" ]; then hn=$((hn + T_HINT)); [ "${pct:-0}" -lt 95 ] && hintm "$H_SIGNATURE"; fi
      if [ $el -ge "$T_STALL" ]; then
        logl "sideload: no progress for ${T_STALL}s, stopped"
        kill "$pid" 2>/dev/null; sleep 1; kill -9 "$pid" 2>/dev/null
        break
      fi
    fi
  done
  wait "$pid" 2>/dev/null; rc=$?; ADBPID=
  nl_dots
  logl "< rc=$rc (last ~${lastpct:-?}%) $(tr '\r' '\n' < "$TMPD/sl.out" | grep -v '^serving' | grep -v '^[[:space:]]*$' | tail -n 3 | tr '\n' ' ' | cutc 400)"
  if [ $rc = 0 ] || grep -q 'Total xfer:' "$TMPD/sl.out"; then XFER=OK
  elif ! grep -q 'serving:' "$TMPD/sl.out" && { [ $((SECONDS - T0)) -lt 15 ] || grep -qiE 'no devices/emulators found|not found|connection failed|closed' "$TMPD/sl.out"; }; then XFER=EARLY
  else XFER=LATE; fi
  logl "transfer: $XFER"
  [ "$XFER" = OK ] && [ "$lastpct" != 100 ] && say "$(fill "$M_SENDING_SL" what "$what" pct 100)"
  [ "$XFER" = OK ] && say "$(fill "$M_SENT_SL" what "$what")"
  return 0
}

# b_wait_back <pass kind>: after a sideload, the phone back in "recovery"
# (by itself, else Enable ADB); a reboot or "unauthorized" ends the run
b_wait_back() {
  local kind=$1 ph=run h=H_ADB_LOS
  [ "$kind" = COPY ] && [ -z "$PASSW" ] && ph=ram
  W_SOFT=1; W_POLL=1; W_ALSO=device; W_UNAUTH=$T_UNAUTH; wait_phone recovery "$T_REC_BACK" "" "$ph"
  if [ "$WSTATE" = timeout ]; then
    [ "$RECKIND" = twrp ] && h=
    W_POLL=1; W_ALSO=device; W_UNAUTH=$T_UNAUTH
    [ -z "$SEENREC" ] && [ "$XFER" != OK ] && W_LIMITMSG=$M_MAYBE_XIAOMI_REC
    wait_phone recovery "$T_USER" "$h" "$ph"
  fi
  case $WSTATE in
    device)
      if [ "$kind" = COPY ] && [ -z "$PASSW" ]; then SUM_WHAT="Ничего не записано: телефон перезагрузился после шага 1."; fail "$M_REBOOTED_AFTER_STEP1"; fi
      if [ "$kind" = RESTORE ]; then
        errm "$(fill "$M_RESTORE_UNCONFIRMED" slot "$RS_SLOT")"; SUM_WHAT="Итог возврата не подтверждён: телефон перезагрузился."
        finish $RC_ATTN
      fi
      errm "$(fill "$M_REBOOTED_UNKNOWN" rel "$KREL")"
      SUM_WHAT="Итог установки неизвестен: телефон перезагрузился раньше, чем флешер прочитал журнал."
      finish $RC_ATTN;;
    unauthorized)
      if [ "$kind" = COPY ] && [ -z "$PASSW" ]; then SUM_WHAT="Ничего не записано: рекавери не пускает компьютер по ADB."; fail "$M_REC_UNAUTH"; fi
      if [ "$kind" = RESTORE ]; then
        errm "$(fill "$M_RESTORE_UNCONFIRMED" slot "$RS_SLOT")"; SUM_WHAT="Итог возврата не подтверждён: рекавери не пускает компьютер по ADB."
        finish $RC_ATTN
      fi
      errm "$M_REC_UNAUTH_AFTER"
      SUM_TODO="Не перезагружайте телефон и посмотрите на его экран (см. выше)."
      finish $RC_ATTN;;
  esac
  return 0
}

# b_pass <COPY|WRITE|ONEPASS|RESTORE> <folder> <file> <what>: one pass with
# up to MAX_TRIES transfers (a broken transfer is sent again only when the
# installer provably did not run). Ends with the phone probed in recovery
# and, for the kernel zip, RESULT read (11)
b_pass() {
  local kind=$1 d=$2 n=$3 what=$4 tp ph=wait f wb
  TRY=0
  SL_WRITES=; { [ "$kind" != COPY ] || [ -n "$PASSW" ]; } && SL_WRITES=1
  [ "$kind" = WRITE ] && [ -n "$RAMONPC" ] && ph=rampc
  while :; do
    b_wait_sideload "$kind" "$ph"
    # (freshness of the logs after this pass: the probe just before it, i.e.
    # the one after the pass before, never an older one; none when the phone
    # came straight from Android into sideload: /tmp is empty then)
    if [ -n "$FRESHSL" ]; then tp=; AK_SEEN=
    else
      tp=$T0P; AK_SEEN=$R_AKHOME
      for f in $(printf '%s\n' "$R_LOGS" | awk -F: 'NF >= 2 { print $1 ":" substr($0, index($0, ":") + 1) }'); do
        LOG_SEEN="$LOG_SEEN ${f#*:}:${f%%:*}"
      done
    fi
    f=0; [ "$kind" = COPY ] && { f=1; [ -n "$FRESHSL" ] && f=2; }
    wb=$WROTE
    do_sideload "$d" "$n" "$what" "$f"
    [ "$XFER" = NOTREADY ] && continue
    # (nothing of the zip reached the phone: this send cannot have written)
    [ "$XFER" = EARLY ] && WROTE=$wb
    if [ "$XFER" = EARLY ]; then
      state_now
      if [ "$DSTATE" = sideload ] && [ "$TRY" -lt "$MAX_TRIES" ]; then
        warnm "$(fill "$M_RETRY" n $((TRY + 1)) max "$MAX_TRIES")"; nap 2; continue
      fi
    fi
    # (the zip reached the recovery: its installer runs, the wait is for it)
    case $XFER in OK|LATE) say "$M_INSTALLING_REC";; esac
    b_wait_back "$kind"
    FRESHSL=
    probe_rec
    rec_checks
    # (T0P stays the time of this probe: the next pass starts after it)
    if [ -n "$tp" ]; then RCUT=$((tp + 1)); else RCUT=$((PNOW - (SECONDS - T0) - 35)); fi
    [ "$kind" = RESTORE ] && return 0
    read_result_rec
    SLOTCMP=
    if [ "$XFER" != OK ] && [ "$RESULT" = NOLOG ]; then
      # (before the zip that writes goes again: the slot must still be the
      # copy from step 1)
      if [ "$kind" = WRITE ] && [ -n "$RAMONPC" ]; then
        slot_vs "$RAMONPC"
        case $SLOTCMP in
          diff) on_result B WRITE;;
          unread) errm "$(fill "$M_SLOT_UNREAD" slot "$SLOT" log "${LOG:-run-flash.log}")"
                  NOREBOOT="состояние слота не подтверждено"; SUM_WHAT="Итог не подтверждён: разделы слота $SLOT не прочитались."
                  finish $RC_ATTN;;
        esac
      fi
      if [ "$TRY" -lt "$MAX_TRIES" ]; then
        warnm "$(fill "$M_RETRY" n $((TRY + 1)) max "$MAX_TRIES")"; continue
      fi
      if [ "$kind" = COPY ] || { [ "$kind" = WRITE ] && [ "$SLOTCMP" = same ]; }; then
        [ "$kind" = WRITE ] && { goodm "$(fill "$M_SLOT_SAME" slot "$SLOT")"; WROTE=; }
        SUM_WHAT="Ничего не записано: файл не удалось передать на телефон."
        fail "$(fill "$M_TRIES_OUT" max "$MAX_TRIES")"
      fi
      errm "$(fill "$M_TRIES_OUT_W" max "$MAX_TRIES")"
      SUM_WHAT="Итог неизвестен: передача файла прерывалась $MAX_TRIES раза."
      finish $RC_ATTN
    fi
    return 0
  done
}

# b_gate [now]: the gate (13) before a pass in recovery that may write; with
# "now", before a pass that only copies: no questions, only M_STOCK_NOW
b_gate() {
  local f="$TMPD/slotinfo.txt"
  if [ "$NEXT" = WRITE ] && [ -f "$TMPD/ram.info" ]; then f="$TMPD/ram.info"; fi
  if [ "$1" = now ]; then
    if [ -f "$f" ]; then stock_now "$(q info_get "$f" kernel)"; else stock_now "$KR"; fi
  elif [ -f "$f" ]; then
    gate "$(q info_get "$f" kernel)" "$(q info_get "$f" fingerprint)" "$(q info_get "$f" boot_ramdisk)" copy "$(rid_of "$f")"
  else
    gate "$KR" "" "" rec "$R_RID"
  fi
}

# rescue_pc_copy <remote backup dir>: the verified PC folder (with its
# restore zip) of that copy, if any
rescue_pc_copy() {
  RESCUE_PC=$(ram_onpc "$1")
  [ -n "$RESCUE_PC" ] && return 0
  [ -n "$1" ] || return 1
  if pull_dir "$1" 0 && [ -n "$PD_RZOK" ]; then RESCUE_PC=$PD_PATH; return 0; fi
  return 1
}

# on_result <A|B> <pass kind>: the outcomes of 11.4 other than STEP1 (DONE
# is handled by the caller after this returns 0)
on_result() {
  local way=$1 kind=$2 why pc
  case $RESULT in
    DONE) return 0;;
    CLEAN)
      errm "$M_ABORT_CLEAN"; show_reason "$RES_LOG"
      SUM_WHAT="Ничего не записано: установщик ядра v$ZVER остановился (причина выше)."
      NOREBOOT=; finish $RC_FAIL;;
    RESTORED)
      errm "$(fill "$M_ROLLED_BACK" slot "${RES_SLOT:-$SLOT}")"; show_reason "$RES_LOG"
      SUM_WHAT="Ядро v$ZVER не установлено: установщик вернул исходные образы, слот ${RES_SLOT:-$SLOT} как до установки."
      finish $RC_ROLLED;;
    DIRTY)
      RESCUE_PC=; rescue_pc_copy "$RES_DIR"; pc=$RESCUE_PC
      errm "$(fill "$M_DIRTY" slot "${RES_SLOT:-$SLOT}" path "${pc:-нет}" series "$ZSERIES")"
      show_reason "$RES_LOG"
      NOREBOOT="слот ${RES_SLOT:-$SLOT} не загрузится"
      SUM_WHAT="ОШИБКА: ядро v$ZVER записано не полностью, установщик не смог вернуть исходные образы."
      SUM_TODO="Не перезагружайте телефон. Верните образы restore-zip'ом (пункт 2 или 3 меню флешера) или через fastboot из папки копии."
      [ -n "$pc" ] && SUM_BAKDIR=$pc
      if [ -n "$pc" ] && prompt_yes "$M_RESCUE_ASK" 1; then
        rescue_now "$way" "$pc"
      fi
      finish $RC_ATTN;;
    AK3_EARLY)
      errm "$(fill "$M_AK3_EARLY" line "$(printf '%s\n' "$RECLOG_LINES" | tail -n 1 | cutc 120)")"
      case $RECLOG_LINES in *'Unsupported device'*) warnm "$M_WHY_DEVICE";; *'Unzip failed'*|*'Busybox setup failed'*) warnm "$M_WHY_UNZIP";; esac
      SUM_WHAT="Ничего не записано: установщик остановился в самом начале."
      finish $RC_FAIL;;
    *)
      why="журнала этого прохода на телефоне нет"; [ "$RESULT" = INCOMPLETE ] && why="журнал обрывается: установщик, видимо, прервался"
      [ -n "$RECLOG_LINES" ] && { say "Рекавери пишет:"; printf '%s\n' "$RECLOG_LINES" | while IFS= read -r l; do say "  | $l"; done; }
      # (way B, the pass that writes, the copy from step 1 on the PC: the
      # slot itself tells whether anything was written)
      SLOTCMP=unread
      [ "$way" = B ] && [ "$kind" = WRITE ] && [ -n "$RAMONPC" ] && slot_vs "$RAMONPC"
      case $SLOTCMP in
        same)
          warnm "ВНИМАНИЕ: итог по журналу установщика не подтверждён ($why)."
          goodm "$(fill "$M_SLOT_SAME" slot "$SLOT")"
          WROTE=; NOREBOOT=
          SUM_WHAT="Ядро v$ZVER не установлено: установщик остановился, слот $SLOT не изменился (sha256 совпадает с копией на компьютере)."
          SUM_TODO="Запустите флешер снова; если это повторится — приложите run-flash.log к сообщению на форуме."
          finish $RC_FAIL;;
        diff)
          errm "$(fill "$M_SLOT_HALF" slot "$SLOT" path "$RAMONPC")"
          NOREBOOT="слот $SLOT записан не полностью"; SUM_BAKDIR=$RAMONPC
          SUM_WHAT="ОШИБКА: установка ядра v$ZVER оборвалась на середине записи, слот $SLOT записан не полностью."
          SUM_TODO="Не перезагружайте телефон. Верните образы restore-zip'ом (пункт 2 или 3 меню флешера) или через fastboot из папки $RAMONPC."
          if prompt_yes "$M_RESCUE_ASK" 1; then rescue_now B "$RAMONPC"; fi
          finish $RC_ATTN;;
      esac
      if [ "$way" = A ]; then
        errm "$(fill "$M_UNCONFIRMED_A" what "$why" log "${LOG:-run-flash.log}")"
        NOREBOOT="итог установки не подтверждён"
        SUM_WHAT="Итог установки ядра v$ZVER не подтверждён."
        SUM_TODO="Не перезагружайте телефон несколько минут, потом запустите флешер снова — он прочитает итог установки на телефоне."
        finish $RC_ATTN
      fi
      errm "$(fill "$M_UNCONFIRMED" what "$why" log "${LOG:-run-flash.log}")"
      NOREBOOT="итог установки не подтверждён"
      if [ "$kind" = COPY ] && [ -z "$PASSW" ]; then SUM_WHAT="Итог шага 1 не подтверждён — запись не начиналась."; finish $RC_FAIL; fi
      case $kind in COPY|ONEPASS)
        # (a first pass that may have written at once: the copy the
        # installer made before writing goes to the PC, if there is one)
        warnm "$M_UNC_PASS_W"
        pass_copy && SUM_BAKDIR=$PD_PATH;;
      esac
      SUM_WHAT="Итог установки ядра v$ZVER не подтверждён."
      SUM_TODO="Оставьте телефон в рекавери и посмотрите на его экран: «Done: … written and read back.» — ядро установлено; «Aborting...» — нет."
      finish $RC_ATTN;;
  esac
}

# pass_copy: after a first pass that may have written and whose result is
# not confirmed: the copy of the slot the installer made before any write
# (the dir its log names, else the newest copy of this slot in the internal
# storage) to the PC; PD_PATH, rc 0 when it is there and verified
pass_copy() {
  local d=$RES_DIR b s=${SLOT#_}
  if [ -z "$d" ]; then
    for b in $R_BAKS; do
      case $b in "$REC_TMP/"*) continue;; *"_$s") ;; *) continue;; esac
      if [ -z "$d" ] || [[ ${b##*/} > ${d##*/} ]]; then d=$b; fi
    done
  fi
  PD_PATH=
  [ -n "$d" ] || return 1
  case $d in "$REC_TMP/"*) ;; *) SUM_PHONE=$d;; esac
  pull_dir "$d" 0 || { warnm "$(fill "$M_VERIFY_FAILED_DISK" dir "$d" what "${PD_WHAT:-?}")"; return 1; }
  [ -n "$PD_PATH" ]
}
# done_copy <way>: after DONE: the copy the installer kept (RES_DIR) to the
# PC; rc 0, or 13 when it could not be taken (M_PULL_LATER)
done_copy() {
  local d=$RES_DIR rc
  DONE_RC=0
  [ -n "$d" ] || return 0
  case $d in "$REC_TMP/"*) ;; *) SUM_PHONE=$d;; esac
  pull_dir "$d" 0; rc=$?
  if [ $rc != 0 ]; then
    warnm "$(fill "$M_PULL_LATER" what "${PD_WHAT:-?}" path "$d" BN "$BACKUP_NAME")"
    SUM_NOTE="Копия разделов осталась только на телефоне: $d"
    DONE_RC=$RC_ATTN
  fi
  return 0
}

# b_install <install|backup>: the pass loop of 10.3-10.7; the phone is in
# recovery or sideload (FRESHSL: right after this run's reboot)
b_install() {
  local mode=$1 pk rc ok r
  PASS2=; SKIPPROBE=
  while :; do
    if [ -z "$FRESHSL" ] && [ -z "$SKIPPROBE" ]; then
      if [ "$DSTATE" != recovery ]; then
        W_ALSO=device; W_UNAUTH=$T_UNAUTH; wait_phone recovery "$T_USER" H_LEAVE_SIDELOAD wait
        [ "$WSTATE" = device ] && fail "$M_BOOTED_NOT_REC"
        [ "$WSTATE" = unauthorized ] && { SUM_WHAT="Ничего не записано: рекавери не пускает компьютер по ADB."; fail "$M_REC_UNAUTH"; }
      fi
      b_probe "$mode"; rc=$?
      if [ $rc = 2 ]; then
        goodm "$(fill "$M_ALREADY_DONE" ver "$ZVER")"
        WROTE=yes; SUM_ON=1
        SUM_WHAT="Установлено: ядро v$ZVER ($KREL), файл $ZNAME (в этом сеансе рекавери, раньше)"
        SUM_SLOT="Слот: $SLOT"
        SUM_WAY="Способ: рекавери, adb sideload ($RECNAME; установлено раньше в этом сеансе рекавери)"
        r=$(q info_get "$TMPD/add.info" kernel); [ -n "$r" ] && SUM_WAS=$r
        step_h 7 "запись уже сделана — перезагрузка и проверка"
        reboot_check "$KREL"
        finish $RC_OK
      fi
    fi
    SKIPPROBE=
    [ -n "$FRESHSL" ] && NEXT=COPY
    if [ "$mode" = backup ]; then
      case $NEXT in
        WRITE) r=$(ram_onpc_any "$RAMDIR")
               if [ -z "$r" ]; then SUM_WHAT="Ничего не записано: копию из памяти рекавери не удалось забрать на компьютер."; fail "$M_COPY_NOT_ON_PC"; fi
               backup_done "$r";;
        ONEPASS) SUM_WHAT="Ничего не записано."; fail "$M_BACKUP_NOT_HERE";;
        *) [ -n "$R_DATAMNT" ] && { SUM_WHAT="Ничего не записано."; fail "$M_BACKUP_NOT_HERE"; };;
      esac
    fi
    if [ "$NEXT" != COPY ] || [ -n "$R_DATAMNT" ]; then b_gate
    elif [ "$mode" != backup ]; then b_gate now; fi
    if [ "$NEXT" = WRITE ] && [ -z "$(ram_onpc "$RAMDIR")" ]; then
      r=$(ram_onpc_any "$RAMDIR")
      if [ -n "$r" ]; then SUM_WHAT="Ничего не записано: установщик не смог сделать restore-zip."; fail "$(fill "$M_RZ_NONE_STOP" path "$r")"; fi
      SUM_WHAT="Ничего не записано: копии разделов нет на компьютере."; fail "$M_COPY_NOT_ON_PC"
    fi
    if [ -z "$H4" ]; then
      H4=1
      r="Apply from ADB"; [ "$RECKIND" = twrp ] && [ -z "$FRESHSL" ] && r="ADB Sideload"
      if [ "$mode" = backup ]; then step_h 3 "переход в режим установки $r (ваши нажатия)"
      else step_h 4 "переход в режим установки $r (≈1 мин и ваши нажатия)"; fi
      b_wait_sideload "$NEXT" "$( [ -n "$RAMONPC" ] && echo rampc || echo wait)"
    elif [ "$mode" = backup ] && [ -z "$H4W" ]; then
      # (backup from Android: step 3 was "into the recovery and Apply from
      # ADB", the tap belongs to it)
      H4W=1; b_wait_sideload "$NEXT" wait
    fi
    case $NEXT in
      COPY) if [ -n "$FRESHSL" ] && [ "$mode" != backup ]; then
              # (straight from Android into sideload: which recovery it is,
              # is known only after this pass)
              step_h 5 "установщик ядра v$ZVER, проход 1 — LineageOS / crDroid / Evolution X: только копия разделов; TWRP / OrangeFox с открытой памятью: копия и запись ядра (≈1–2 мин)"
            else
              step_h "$( [ "$mode" = backup ] && echo 4 || echo 5)" "установщик ядра v$ZVER, проход 1 — копия разделов, ничего не записывается (≈1–2 мин)"
            fi;;
      ONEPASS) step_h 5 "установщик ядра v$ZVER, проход 1 — копия разделов и запись ядра (≈1–2 мин)";;
      WRITE) if [ -n "$PASS2" ]; then step_h 7 "установщик ядра v$ZVER, проход 2 — запись ядра (≈1–2 мин)"
             else step_h 5 "установщик ядра v$ZVER, проход 1 — копия уже есть, сразу запись ядра (≈1–2 мин)"; fi;;
    esac
    pk=$NEXT
    # (a pass that may write: not only WRITE / ONEPASS, also the first pass
    # sent straight after the reboot into sideload, before the flasher could
    # look into the recovery, and any pass while /data is open: TWRP /
    # OrangeFox then installs at once. WROTE=maybe once it is sent)
    PASSW=; { [ "$pk" != COPY ] || [ -n "$FRESHSL" ] || [ -n "$R_DATAMNT" ]; } && PASSW=1
    SUM_ON=1
    [ -z "$SUM_WAS" ] && SUM_WAS=$KR
    b_pass "$pk" "$ZDIR" "$ZNAME" "ядро v$ZVER"
    if [ "$RESULT" = STEP1 ]; then
      if [ "$pk" = WRITE ] && [ -n "$RAMONPC" ]; then
        # (a pass that was to write came back as step 1: then the slot must
        # still be the one copied before, or something did write)
        slot_vs "$RAMONPC"
        case $SLOTCMP in
          diff) errm "$(fill "$M_SLOT_CHANGED" slot "$SLOT" path "$RAMONPC")"
                NOREBOOT="слот $SLOT изменился"; SUM_BAKDIR=$RAMONPC
                SUM_WHAT="ОШИБКА: слот $SLOT изменился, хотя установщик написал, что ничего не записал."
                SUM_TODO="Не перезагружайте телефон. Верните образы restore-zip'ом из папки $RAMONPC (пункт 2 или 3 меню флешера) или через fastboot."
                if prompt_yes "$M_RESCUE_ASK" 1; then rescue_now B "$RAMONPC"; fi
                finish $RC_ATTN;;
          unread) errm "$(fill "$M_SLOT_UNREAD" slot "$SLOT" log "${LOG:-run-flash.log}")"
                NOREBOOT="состояние слота не подтверждено"; SUM_WHAT="Итог не подтверждён: разделы слота $SLOT не прочитались."
                finish $RC_ATTN;;
        esac
      fi
      WROTE=
      goodm "$(fill "$M_STEP1_OK" slot "${RES_SLOT:-$SLOT}")"
      show_notes "$RES_LOG"
      if [ "$pk" = WRITE ]; then
        ROUND=$((ROUND + 1)); warnm "$M_STEP1_AGAIN"
        [ "$ROUND" -gt "$MAX_ROUNDS" ] && { SUM_WHAT="Ничего не записано."; fail "$M_ROUNDS_OUT"; }
      fi
      PHASE=ram
      step_h "$( [ "$mode" = backup ] && echo 5 || echo 6)" "копия разделов — на компьютер и проверка (≈1 мин)"
      [ -n "$RES_DIR" ] || { SUM_WHAT="Ничего не записано."; fail "$(fill "$M_UNCONFIRMED" what "установщик не назвал папку копии" log "${LOG:-run-flash.log}")"; }
      pull_dir "$RES_DIR" 0; rc=$?
      if [ $rc != 0 ]; then
        if [ $rc = 3 ]; then SUM_WHAT="Ничего не записано: на диске компьютера мало места для копии разделов."; fail ""; fi
        if [ -n "$PD_GONE" ]; then SUM_WHAT="Ничего не записано: телефон перезагрузился после шага 1."; fail "$M_REBOOTED_AFTER_STEP1"; fi
        if [ -n "$PD_LOST" ]; then SUM_WHAT="Ничего не записано: копию разделов не удалось забрать на компьютер."; fail "$(fill "$M_PULL_LOST_FAIL" n "$PD_LOSTN")"; fi
        SUM_WHAT="Ничего не записано: копия разделов не прошла проверку на компьютере."
        fail "$(fill "$M_VERIFY_FAILED" what "${PD_WHAT:-?}")"
      fi
      note_ram "$RES_DIR" "$PD_PATH" "$PD_RZOK"
      if [ -z "$PD_RZOK" ]; then SUM_WHAT="Ничего не записано: установщик не смог сделать restore-zip."; fail "$(fill "$M_RZ_NONE_STOP" path "$PD_PATH")"; fi
      RAMONPC=$PD_PATH; PHASE=rampc; RAMDIR=$RES_DIR; PASS1DIR=$RES_DIR
      cp -f "$PD_PATH/info.txt" "$TMPD/ram.info" 2>/dev/null
      r=$(q info_get "$TMPD/ram.info" kernel); [ -n "$r" ] && SUM_WAS=$r
      [ "$mode" = backup ] && backup_done "$PD_PATH"
      NEXT=WRITE; PASS2=1; SKIPPROBE=1
      b_gate
      # (this pass's logs are old ones for the next pass)
      for ok in $RES_LOGS; do r=$(run_id "$ok"); [ -n "$r" ] && OLD_RUNIDS="$OLD_RUNIDS $r"; done
      continue
    fi
    on_result B "$pk"
    # DONE (a stop from here on: «Остановлено.», the installed kernel in the
    # summary and the flash's own code, as run-flash.ps1)
    WROTE=yes; PHASE=done
    goodm "$(fill "$M_DONE" ver "$ZVER" slot "${RES_SLOT:-$SLOT}")"
    show_notes "$RES_LOG"
    [ "$pk" = COPY ] && { say "$M_ONEPASS_UNPREDICTED"; logl "one pass, not predicted"; }
    [ "$mode" = backup ] && warnm "$M_BACKUP_UNEXPECTED"
    SUM_WHAT="Установлено: ядро v$ZVER ($KREL${ZKSU:+, KernelSU: $ZKSU}), файл $ZNAME"
    SUM_SLOT="Слот: ${RES_SLOT:-$SLOT} — boot${RES_SLOT:-$SLOT}, vendor_boot${RES_SLOT:-$SLOT}, dtbo${RES_SLOT:-$SLOT} записаны и проверены установщиком"
    case $pk in
      WRITE) if [ -n "$PASS2" ]; then SUM_WAY="Способ: рекавери, adb sideload в два прохода ($RECNAME)"; else SUM_WAY="Способ: рекавери, adb sideload (копия из шага 1 этого сеанса; $RECNAME)"; fi;;
      *) SUM_WAY="Способ: рекавери, adb sideload за один проход ($RECNAME)";;
    esac
    if [ -z "$PASS2" ]; then
      if [ "$mode" = backup ]; then step_h 5 "копия разделов — на компьютер и проверка (≈1 мин)"
      else step_h 6 "копия разделов — на компьютер и проверка (≈1 мин)"; fi
    fi
    done_copy B
    [ -z "$PASS2" ] && [ "$mode" != backup ] && step_h 7 "запись уже сделана на шаге 5 — перезагрузка и проверка"
    reboot_check "$KREL"
    finish "$DONE_RC"
  done
}

########################################################################
# a recovery whose ADB has no root (1.1): user builds of LineageOS-type
# recoveries drop adbd to uid 2000 and have no su, whatever the kernel; the
# root of SukiSU-Ultra / KernelSU / Magisk is only in the booted system.
# Q1: the same action from the system with root (one pass); Q2 (install):
# the kernel zip by Apply from ADB, step 1 and step 2, then the reboot and
# the check of the running kernel, only with a verified way back on the PC;
# Q3 (restore): the PC-verified restore zip by Apply from ADB, the same check

# root_ask: the question of root_loop for ROOTWHY (denied / mgr / RNR)
root_ask() {
  local no=$M_ROOT_NO_B
  case $CMD in install-system) no=$M_ROOT_NO_A;; restore*) no=$M_ROOT_NO_R;; esac
  [ -n "$RNR" ] && no=$M_ROOT_NO_NR
  case $ROOTWHY in
    mgr) fill "$M_ROOT_MGR_ASK" no "$no";;
    denied) fill "$M_ROOT_DENIED_ASK" no "$no";;
    *) printf '%s' "$M_NR_ROOT_ASK";;
  esac
}
# root_loop: after root_check: ask again while root is denied or a root
# manager hides su; after the system route (RNR) also once with the how-to
# when there is no su at all. install-system: «нет» stops (11)
root_loop() {
  local how=
  while [ -z "$HAVE_ROOT" ]; do
    case $ROOTWHY in
      denied|mgr) ;;
      *) { [ -n "$RNR" ] && [ -z "$how" ]; } || break
         how=1; say "$M_ROOT_HOW";;
    esac
    if ! prompt_yes "$(root_ask)" 1; then
      [ "$CMD" = install-system ] && { warn_phase; finish $RC_CANCEL; }
      break
    fi
    root_check
  done
  return 0
}
# root_mgr: a root manager that hides su until Shell is granted (R2): 0
# when one is installed (ROOTMGR its name); the how-to once
root_mgr() {
  local p
  dev_call 15 0 "$(fill "$P_PM" RE "$ROOTMGR_RE")" >/dev/null 2>&1
  p=$(sed -n 's/^package://p' "$TMPD/dc.out" | tr -d '\r ' | grep -iE "$ROOTMGR_RE" | head -n 4 | tr '\n' ' ')
  [ -n "$p" ] || { logl "root manager: none found"; return 1; }
  case $(lower "$p") in
    *sukisu*) ROOTMGR=SukiSU-Ultra;;
    *kernelsu*|*ksunext*) ROOTMGR=KernelSU;;
    *apatch*) ROOTMGR=APatch;;
    *) ROOTMGR=Magisk;;
  esac
  logl "root manager: $ROOTMGR ($p)"
  if [ -z "$ROOTMGR_SAID" ]; then
    ROOTMGR_SAID=1
    if [ "$ROOTMGR" = Magisk ]; then warnm "$M_ROOT_MGR_MAGISK"; else warnm "$(fill "$M_ROOT_MGR" name "$ROOTMGR")"; fi
    say "$M_ROOT_HOW"
  fi
  return 0
}

# q_copy <fingerprint> <kernel now> <ROM build now>: Q2's way back: a PC
# copy (stock or taoyao-<series>-backups) of SLOT and this ROM build
# (rom_list: same, or for a copy without rom_build_utc the same
# fingerprint) whose restore zip passes rs_check; one of this build (same)
# before one that matched by the fingerprint only (fpr), then the one of the
# kernel in the slot now, then the newest. Q_COPY Q_CLS Q_LINE Q_HOW (the
# verdict) Q_RID (the ROM build it was matched to)
q_copy() {
  local fpr=$1 kr=$2 rid=$3 c d v _s _p _d
  Q_COPY=; Q_CLS=; Q_LINE=; Q_HOW=; Q_RID=$rid
  [ -n "$fpr$rid" ] && [ -n "$SLOT" ] || return 1
  scan_known
  rom_list ANY "$SLOT" "" "$rid" "$fpr" | awk -F'\t' -v k="$kr" '($1 == "same" || $1 == "fpr") && $7 != "-" && $7 != "MANY" { print ($1 == "same" ? 0 : 1) "\t" ($6 == k ? 0 : 1) "\t" $4 "\t" $5 "\t" $1 "\t" $2 }' \
    | sort -t "$(printf '\t')" -k1,1 -k2,2 -k3,3r > "$TMPD/qc.list"
  while IFS="$(printf '\t')" read -r _s _p _d c v d; do
    [ -n "$d" ] || continue
    RS_QUIET=1 rs_check "$d" || { logl "Q2 copy $d: $RS_WHAT"; continue; }
    Q_COPY=$d; Q_CLS=$c; Q_HOW=$v; Q_LINE=$(rs_line "$d"); break
  done < "$TMPD/qc.list"
  logl "Q2 way back: ${Q_COPY:-none} (slot $SLOT, build ${rid:-?}, fingerprint ${fpr:-?}${Q_HOW:+, match $Q_HOW})"
  [ -n "$Q_COPY" ]
}
# q_sum: Q2's way back into the summary («Как вернуться»)
q_sum() { if [ "$Q_CLS" = STOCK ]; then SUM_STOCK=$Q_COPY; SUM_STOCK_FPR=; [ "$Q_HOW" = fpr ] && SUM_STOCK_FPR=$Q_COPY; else SUM_PREV=$Q_COPY; fi; }
# q2_ask <go text>: the Q2 question; a way back that matched by the
# fingerprint only is named so, with the warning first (unless the gate
# just gave it for that very copy)
q2_ask() {
  if [ "$Q_HOW" = fpr ]; then
    [ "$GATE_FPRSAID" = "$Q_COPY" ] || warnm "$(fill "$M_Q2_FPRONLY" why "$(fpr_why "$Q_COPY" "$Q_RID")")"
    prompt_yes "$(fill "$M_Q2_ASK_FPR" line "$Q_LINE" go "$1")" 1
  else prompt_yes "$(fill "$M_Q2_ASK" line "$Q_LINE" go "$1")" 1; fi
}
# q2_ok <fingerprint> <kernel now> <ROM build now>: Q2 may be offered (else
# why not, once)
q2_ok() {
  Q2_WHY=
  if [ -n "$KREL" ] && [ "$2" = "$KREL" ]; then Q2_WHY=same; say "$(fill "$M_Q2_SAMEVER" rel "$KREL")"; return 1; fi
  q_copy "$1" "$2" "$3" && return 0
  Q2_WHY=none; say "$(fill "$M_Q2_NONE" slot "${SLOT:-?}")"
  return 1
}
# q3_ok: Q3 may be offered: the copy is of the running slot and the version
# would show the restore
q3_ok() {
  if [ "$RS_SLOT" != "$SLOT" ]; then say "$(fill "$M_Q3_NOT" why "$(fill "$M_Q3_WHY_SLOT" s1 "$RS_SLOT" s2 "${SLOT:-?}")")"; return 1; fi
  if [ -n "$KR" ] && [ "$RS_KERNEL" = "$KR" ]; then say "$(fill "$M_Q3_NOT" why "$(fill "$M_Q3_WHY_SAME" rel "$KR")")"; return 1; fi
  return 0
}

# rec_noroot: rec_checks found uid != 0 in the recovery. Says why and what
# happened on the phone so far, then Q1, Q2 / Q3; never returns
rec_noroot() {
  local q d
  logl "recovery ADB without root: uid ${R_UID:-?}, ro.build.type ${R_TYPE:-?}, ro.debuggable ${R_DEBUG:-?}, data mounted ${R_DATAMNT:-no}"
  RNR=1; RNR_DATAMNT=$R_DATAMNT; RNR_FPR=$R_FPR; RNR_RID=$R_RID; RNR_KR=$KR; RNR_SLOT=$SLOT; RNR_RAMSEEN=; RNR_PASS1W=
  # (nothing goes the way B planned; what the slot holds now, for the summary)
  SUM_WAY=; [ -z "$SUM_WAS" ] && SUM_WAS=$KR
  warnm "$(fill "$M_NR_WHY" uid "${R_UID:-?}")"
  [ "$CMD" = install-recovery ] && say "$M_NR_FORCED"
  # (the only pass sent before the first look: this run's first pass after
  # its own reboot into Apply from ADB; without /data it can only copy)
  if [ -n "$SENT_ANY" ] && [ "$XFER" != EARLY ]; then
    if [ -z "$R_DATAMNT" ]; then say "$M_NR_PASS1"; WROTE=; RNR_STEP1=1; PHASE=wait
    else warnm "$M_NR_PASS1_W"; PHASE=q2; Q_WANT=$KREL; RNR_PASS1W=1; fi
  else
    # (a copy of this slot in the recovery's RAM: an installer ran earlier in
    # this recovery session, and the next send may write at once)
    for d in $R_BAKS; do case $d in "$REC_TMP/$BACKUP_NAME/"*"$SLOT") RNR_RAMSEEN=1;; esac; done
    if [ -n "$RNR_RAMSEEN" ]; then
      logl "a copy of slot $SLOT in the recovery's RAM from an earlier send"
      say "$(fill "$M_NR_RAMSEEN" slot "$SLOT")"; PHASE=seen
    else
      say "$M_NR_NOTHING"
    fi
  fi
  [ "$CMD" = backup ] && say "$M_NR_BACKUP"
  if [ -z "$RNR_Q1" ]; then
    RNR_Q1=1
    case $CMD in backup) q=$M_NR_Q1_B;; restore*) q=$M_NR_Q1_R;; *) q=$M_NR_Q1_I; [ -n "$ROOTWHY" ] && q=$M_NR_Q1_I2;; esac
    prompt_yes "$q" 1 && nr_to_system
  fi
  case $CMD in
    backup) ;;
    restore*) if q3_ok && prompt_yes "$(fill "$M_Q3_ASK" go "$M_Q3_GO")" 1; then q3_run; fi;;
    *) if q2_ok "$R_FPR" "$KR" "$R_RID"; then
         gate "$KR" "$R_FPR" "" rec "$R_RID"
         q2_ask "$M_Q2_GO" && q2_run
       elif [ "$Q2_WHY" = none ]; then say "$M_Q2_NONE_OPT"; fi;;
  esac
  warn_phase; finish "$(stop_rc $RC_CANCEL)"
}
# nr_to_system: Q1 yes: adb reboot (no root needed), the wait for Android,
# then the command again as a start in Android does it
nr_to_system() {
  local rc ph=wait
  # (a pass of this run that may have written (M_NR_PASS1_W) stays so)
  [ "$WROTE" = maybe ] && ph=q2
  SUM_ON=1; PHASE=$ph
  say "$M_NR_REBOOTING"
  logl "> adb reboot (to the system: recovery ADB without root)"
  run_to 30 "$TMPD/rb.out" "$ADB" -s "$SERIAL" reboot; rc=$?
  logl "< rc=$rc $(head -c 200 "$TMPD/rb.out")"
  [ $rc != 0 ] && hintm "$H_NR_REBOOT_SELF"
  SUM_REBOOT=1
  say "$M_BOOT_WAIT"
  W_ESC=1; W_SOFT=1; W_POLL=2; wait_phone device "$T_BOOT" "" "$ph"
  case $WSTATE in
    skip) warn_phase; finish "$(stop_rc $RC_CANCEL)";;
    timeout)
      FAIL_TXT=$(fill "$M_NR_NOSYS" t "$(( (T_BOOT + 30) / 60 )) мин"); errm "$FAIL_TXT"
      # (the way back the PC holds for this slot, if any: the summary prints it)
      case $CMD in restore*|backup) ;; *) q_copy "$RNR_FPR" "$RNR_KR" "$RNR_RID" && q_sum;; esac
      finish "$(stop_rc $RC_FAIL)";;
  esac
  # (this run's way B state is over, and with the reboot any copy in the
  # recovery's RAM; the questions asked once stay asked)
  FRESHSL=; H4=; H4W=; PASS2=; SKIPPROBE=; NEXT=COPY; REC_SHOWN=; WHERE=android; SEENREC=; RNR_STEP1=; RNR_RAMSEEN=; RNR_PASS1W=
  [ "$CMD" = install-recovery ] && { CMD=install; logl "install-recovery: the system route, as install"; }
  case $CMD in
    backup) backup_flow again;;
    restore-stock) restore_flow stock again;;
    restore-prev) restore_flow prev again;;
    *) install_flow again;;
  esac
  finish $RC_OK
}
# nr_p1_check: Android after the system route, and this run's pass 1 may
# have written (M_NR_PASS1_W): the new kernel running is the check (0, and
# the installer's copy to the PC); the old one: pass 1 wrote nothing
nr_p1_check() {
  logl "pass 1 may have written: running ${KR:-?} (zip $KREL, before ${RNR_KR:-?})"
  logl "check: state device, kernel ${KR:-?}, slot ${SLOT:-?} (expected $KREL in ${RNR_SLOT:-?}, before ${RNR_KR:-?})"
  # (the slot that pass 1 wrote is the one running, or the probe does not say)
  if [ -n "$KR" ] && [ "$KR" = "$KREL" ] && [ "${SLOT:-$RNR_SLOT}" = "$RNR_SLOT" ]; then
    WROTE=yes; PHASE=done; DONE_RC=0
    goodm "$(fill "$M_Q_OK" rel "$KR")"
    SUM_WAY="Способ: рекавери без root ($RECNAME), Apply from ADB, отправок: 1"
    SUM_WHAT="Установлено: ядро v$ZVER ($KREL${ZKSU:+, KernelSU: $ZKSU}), файл $ZNAME — проверено по версии работающего ядра"
    SUM_SLOT="Слот: ${SLOT:-?}"; SUM_BOOT="Проверка: телефон загрузился с ядром $KR"
    step_h 3 "старые копии разделов с телефона — на компьютер (0–2 мин)"
    pull_store "/sdcard/$BACKUP_NAME" 0
    [ "$PS_N" = 0 ] && say "$M_NONE_ON_PHONE"
    finish $RC_OK
  fi
  if [ -n "$KR" ] && [ "$KR" = "$RNR_KR" ]; then
    WROTE=; PHASE=wait
    say "$(fill "$M_NR_P1_OLD" rel "$KR")"
  fi
  return 0
}
# nr_end: the system route is done and there is no root: the options
nr_end() {
  SUM_ON=1; NOFOOTER=1
  case $CMD in
    backup) warnm "$M_NR_END_B";;
    restore*) warnm "$(fill "$M_NR_END_R" term "$M_TERM")"; say "      $(tool_cmd adb) sideload $(shq "$RS_ZIP")";;
    *) warnm "$(fill "$M_NR_END" term "$M_TERM")"; say "      $(tool_cmd adb) sideload $(shq "$ZPATH")";;
  esac
  [ -z "$WROTE" ] && SUM_WHAT="Ничего не записано: root для adb в системе нет, а ADB рекавери работает без root."
  finish "$(stop_rc $RC_FAIL)"
}
# nr_android_end: Android after the system route, still without root: Q2
# / Q3 from here (they reboot into Apply from ADB), else nr_end
nr_android_end() {
  case $CMD in
    restore*)
      if q3_ok && prompt_yes "$(fill "$M_Q3_ASK" go "$M_Q3_GO_A")" 1; then
        step_h 3 "подготовка: переход в рекавери и в режим Apply from ADB (≈1 мин и ваши нажатия)"; H4=1
        b_from_android sideload H_ENTER_SIDELOAD 0
        WHERE=rec; q3_run
      fi;;
    backup) ;;
    *)
      if q2_ok "$FPR" "$KR" "$A_RID"; then
        gate "$KR" "$FPR" "" phone "$A_RID"
        if q2_ask "$M_Q2_GO_A"; then
          step_h 4 "переход в режим установки Apply from ADB (≈1 мин и ваши нажатия)"; H4=1
          b_from_android sideload H_ENTER_SIDELOAD 0
          WHERE=rec; q2_run
        fi
      fi;;
  esac
  nr_end
}

# q_after_sl: after a send of Q2 / Q3: until the phone has left this
# sideload (the recovery shows the installer's result), at most 30 s (a
# transfer that broke off: the installer may still run, T_USER)
q_after_sl() {
  local t=$SECONDS lim=30
  [ "$XFER" = LATE ] && lim=$T_USER
  while [ $((SECONDS - t)) -lt "$lim" ]; do
    state_now; [ "$DSTATE" != sideload ] && return 0
    nap 1
  done
  return 0
}
# q_send <folder> <file> <what> <copy only 1|0> <step> <step text>: one
# send of Q2 / Q3 by Apply from ADB (transfer retries as b_pass), its step
# heading once the phone waits for the file; 1 when the phone is in the
# system instead (it was rebooted: the check decides)
q_send() {
  local d=$1 n=$2 what=$3 copy=$4 sn=$5 st=$6 wb h=H_APPLY_Q said=
  TRY=0
  [ "${Q_SENT:-0}" -gt 0 ] && h=H_APPLY_LOS2
  while :; do
    state_now
    if [ "$DSTATE" != sideload ]; then
      W_POLL=1; W_ALSO=device; wait_phone sideload "$T_USER" "$h" ""
      [ "$WSTATE" = device ] && return 1
    fi
    [ -z "$said" ] && { said=1; step_h "$sn" "$st"; }
    SL_WRITES=; [ "$copy" = 1 ] || SL_WRITES=1
    wb=$WROTE
    do_sideload "$d" "$n" "$what" "$copy"
    [ "$XFER" = NOTREADY ] && continue
    if [ "$XFER" = EARLY ]; then
      WROTE=$wb
      state_now
      if [ "$DSTATE" = sideload ] && [ "$TRY" -lt "$MAX_TRIES" ]; then warnm "$(fill "$M_RETRY" n $((TRY + 1)) max "$MAX_TRIES")"; nap 2; continue; fi
      [ "$TRY" -lt "$MAX_TRIES" ] && continue
      if [ -z "$WROTE" ]; then
        SUM_WHAT="Ничего не записано: файл не удалось передать на телефон."
        fail "$(fill "$M_TRIES_OUT" max "$MAX_TRIES")"
      fi
      # (an earlier send of this run may have written)
      FAIL_TXT=$(fill "$M_TRIES_OUT_Q" max "$MAX_TRIES" rel "${Q_WANT:-$KREL}"); errm "$FAIL_TXT"
      finish $RC_ATTN
    fi
    Q_SENT=$((${Q_SENT:-0} + 1))
    # (between two sends: a stop says what is known)
    if [ -n "$WROTE" ]; then PHASE=q2; else PHASE=wait; fi
    q_after_sl
    return 0
  done
}
# q2_run: Q2: two sends (step 1, step 2) in a recovery without /data: the
# first can only copy (into RAM), the second writes, and a send after a
# write only copies again (the installer: no write without its step-1 copy
# of the same slot); one send when this session already has the step-1
# copy; with /data mounted one send that may write at once, then the
# question about the screen line
q2_run() {
  local n=2 ask= i=1 c sn st mn=3
  # (/data open, or a copy of the slot already in the recovery's RAM: the
  # first send may write at once, the screen tells; pass 1 of this run
  # with /data open: the screen tells before any send)
  if [ -n "$RNR_PASS1W" ]; then n=0
  elif [ -n "$RNR_DATAMNT" ] || [ -n "$RNR_RAMSEEN" ]; then n=1; ask=1
  elif [ -n "$RNR_STEP1" ]; then n=1; fi
  logl "Q2: sends planned $n${ask:+ (+ question)}${RNR_PASS1W:+ (after the question about pass 1)}"
  [ "$Q_CLS" = STOCK ] && mn=2
  if [ -n "$RNR_DATAMNT" ]; then warnm "$(fill "$M_Q2_WARN_D" path "$Q_COPY" n "$mn")"
  elif [ -n "$RNR_STEP1$RNR_RAMSEEN" ]; then warnm "$(fill "$M_Q2_WARN_1" path "$Q_COPY" n "$mn")"
  else warnm "$(fill "$M_Q2_WARN" path "$Q_COPY" n "$mn")"; fi
  # (pass 1 of this run counts: the kernel was sent once already)
  WAY=B; SUM_ON=1; Q_SENT=0; [ -n "$RNR_STEP1$RNR_PASS1W" ] && Q_SENT=1; Q_KIND=install; Q_WANT=$KREL
  [ -z "$SUM_WAS" ] && SUM_WAS=$KR
  q_sum
  SUM_WAY="Способ: рекавери без root ($RECNAME), Apply from ADB"
  [ -n "$RNR_PASS1W" ] && prompt_yes "$M_Q2_PASS1_ASK" 1 && n=1
  [ $n -gt 0 ] && [ -z "$H4" ] && { H4=1; step_h 4 "переход в режим установки Apply from ADB (ваши нажатия)"; }
  while [ $i -le $n ]; do
    c=0; sn=5
    if [ $n = 2 ] && [ $i = 1 ]; then c=1; st="установщик ядра v$ZVER, отправка 1 из 2 — копия слота в памяти телефона, ничего не записывается (≈1–2 мин)"
    elif [ $n = 2 ]; then sn=6; st="установщик ядра v$ZVER, отправка 2 из 2 — запись ядра (≈1–2 мин)"
    elif [ -n "$RNR_STEP1$RNR_PASS1W" ]; then st="установщик ядра v$ZVER — запись ядра (копия из прохода 1 уже в памяти телефона) (≈1–2 мин)"
    else st="установщик ядра v$ZVER (≈1–2 мин)"; fi
    q_send "$ZDIR" "$ZNAME" "ядро v$ZVER" "$c" "$sn" "$st" || break
    if [ -n "$ask" ] && [ $i = 1 ] && prompt_yes "$M_Q2_SCREEN_ASK" 1; then n=2; ask=; fi
    i=$((i + 1))
  done
  SUM_WAY="$SUM_WAY, отправок: $Q_SENT"
  step_h 7 "перезагрузка и проверка версии ядра"
  q_check "$KREL" "$KR"
}
# q3_run: Q3: the restore zip by Apply from ADB, then the reboot and the check
q3_run() {
  WAY=B; SUM_ON=1; Q_SENT=0; Q_KIND=restore; Q_WANT=$RS_KERNEL
  SUM_WAY="Способ: рекавери без root ($RECNAME), Apply from ADB"
  [ -z "$H4" ] && { H4=1; step_h 3 "подготовка: режим Apply from ADB (ваши нажатия)"; }
  q_send "${RS_ZIP%/*}" "$RS_ZNAME" "restore-zip" 0 4 "возврат образов restore-zip'ом через Apply from ADB (≈30 с)"
  step_h 5 "перезагрузка и проверка версии ядра"
  q_check "$RS_KERNEL" "$KR"
}
# q_check <expected release> <release before>: Q2 / Q3 end: the reboot
# (adb reboot after a yes when the recovery's ADB is on, else the tap on
# the phone), the wait for the system and its uname -r and slot; finishes
# (0 the expected kernel runs, 10 the old one, 13 not confirmed)
q_check() {
  local want=$1 was=$2 t kr= sl= bc lim=$T_USER rb= ll left= why= path
  # (right after a sideload adbd restarts: the recovery's ADB, if it is on,
  # comes back in a few seconds, and then adb reboot spares the tap)
  state_now
  if [ "$DSTATE" != recovery ] && [ "$DSTATE" != device ]; then
    W_SOFT=1; W_POLL=1; W_ALSO=device; wait_phone recovery "$T_REC_BACK" "" ""
  fi
  PHASE=boot; BOOTSKIP=
  state_now
  if [ "$DSTATE" = recovery ] && prompt_yes "$M_REBOOT_ASK" 1; then
    logl "> adb reboot"
    run_to 30 "$TMPD/rb.out" "$ADB" -s "$SERIAL" reboot
    SUM_REBOOT=1; rb=1; lim=$T_BOOT
  elif [ "$DSTATE" != device ]; then
    hintm "$H_Q_REBOOT"
  fi
  PHASE=boot
  WSTATE=device
  if [ "$DSTATE" != device ] || [ -n "$rb" ]; then
    say "$(fill "$M_Q_BOOT_WAIT" min "$(( (lim + 59) / 60 ))")"
    # (the phone first leaves the recovery, after adb reboot or the tap:
    # until then "unauthorized" is the recovery's ADB, not the system's)
    t=$SECONDS; ll=$T_LEAVE; [ -z "$rb" ] && ll=$lim
    while [ $((SECONDS - t)) -lt "$ll" ]; do
      state_now
      case $DSTATE in recovery|sideload|unauthorized) ;; *) left=1; break;; esac
      readkey_t 1; check_intr
      case $KEY in ESC|NO) BOOTSKIP=1;; esac
      [ -n "$BOOTSKIP" ] && break
    done
    if [ -n "$BOOTSKIP" ]; then WSTATE=skip
    elif [ -z "$rb" ] && [ -z "$left" ]; then WSTATE=timeout
    else W_ESC=1; W_SOFT=1; W_UNAUTH=$T_UNAUTH; W_POLL=2; wait_phone device "$lim" "" boot; fi
  fi
  if [ "$WSTATE" = device ]; then
    t=$SECONDS
    while [ $((SECONDS - t)) -lt "$T_BOOT" ]; do
      dev_call 20 0 "$P_KRS" >/dev/null 2>&1
      kr=$(kv kr); bc=$(kv bc); sl=$(kv sl)
      if ! probe_ok && lost; then
        W_ESC=1; W_SOFT=1; W_UNAUTH=$T_UNAUTH; W_POLL=2; wait_phone device "$T_BOOT" "" boot
        [ "$WSTATE" = device ] || break
        PHASE=boot
      fi
      [ "$bc" = 1 ] && [ -n "$kr" ] && break
      readkey_t 3; check_intr
      case $KEY in ESC|NO) BOOTSKIP=1;; esac
      [ -n "$BOOTSKIP" ] && { WSTATE=skip; break; }
    done
    [ "$WSTATE" = device ] && [ "$bc" != 1 ] && WSTATE=timeout
  fi
  BOOTSKIP=; PHASE=done
  logl "check: state $WSTATE, kernel ${kr:-?}, slot ${sl:-?} (expected $want in $SLOT, before ${was:-?})"
  NOREBOOT=
  case $WSTATE in
    skip) warnm "$(fill "$M_Q_SKIP" rel "$want")"; SUM_BOOT="Проверка: пропущена"
          SUM_WHAT="Итог не подтверждён: проверка версии ядра пропущена."; finish $RC_ATTN;;
    unauthorized) warnm "$M_BOOT_UNAUTH"; SUM_BOOT="Проверка: телефон загрузился, но версию ядра флешер не увидел"
          SUM_WHAT="Итог не подтверждён: версию ядра флешер не увидел."; finish $RC_ATTN;;
    timeout) if [ "$Q_KIND" = restore ]; then warnm "$(fill "$M_Q3_NOBOOT" t "$(( (lim + 59) / 60 )) мин")"
             else warnm "$(fill "$M_Q_NOBOOT" t "$(( (lim + 59) / 60 )) мин")"; fi
          SUM_BOOT="Проверка: телефон не загрузился в систему за $(( (lim + 59) / 60 )) мин"
          SUM_WHAT="Итог не подтверждён: телефон не загрузился в систему."
          if [ "$Q_KIND" = restore ]; then
            say "  $RS_DIR"; say "$(fill "$M_BACK_FB" term "$M_TERM")"; fastboot_lines "$RS_SLOT" "      " "$RS_DIR"
            SUM_TODO="Если телефон не загружается — запишите образы через fastboot из папки $RS_DIR (команды выше)."
          else
            SUM_TODO="Если телефон не загружается — верните образы из копии $Q_COPY (команды ниже)."
          fi
          finish $RC_ATTN;;
  esac
  if [ "$kr" = "$want" ] && [ "${sl:-$SLOT}" = "$SLOT" ]; then
    WROTE=yes
    if [ "$Q_KIND" = restore ]; then
      goodm "$(fill "$M_Q3_OK" rel "$kr")"; WROTE=
      SUM_WHAT="Возвращено: ядро $RS_KERNEL в слот $RS_SLOT (папка $RS_DIR), проверено по версии работающего ядра"
    else
      goodm "$(fill "$M_Q_OK" rel "$kr")"
      SUM_WHAT="Установлено: ядро v$ZVER ($KREL${ZKSU:+, KernelSU: $ZKSU}), файл $ZNAME — проверено по версии работающего ядра"
      SUM_SLOT="Слот: $SLOT"
    fi
    SUM_BOOT="Проверка: телефон загрузился с ядром $kr"
    finish $RC_OK
  fi
  if [ "$kr" = "$was" ] && [ "${sl:-$SLOT}" = "$SLOT" ]; then
    WROTE=
    SUM_BOOT="Проверка: телефон загрузился с ядром $kr (как до отправки)"
    if [ "$Q_KIND" = restore ]; then
      errm "$(fill "$M_Q3_OLD" rel "$kr")"; SUM_WHAT="Образы не вернулись: телефон загрузился с прежним ядром $kr."
    else
      errm "$(fill "$M_Q_OLD" rel "$kr" ver "$ZVER")"; SUM_WHAT="Ядро v$ZVER не установлено: телефон загрузился со старым ядром $kr."
    fi
    NOFOOTER=1; finish $RC_FAIL
  fi
  [ -n "$sl" ] && [ "$sl" != "$SLOT" ] && why=$(fill "$M_Q_OTHER_SLOT" wslot "$SLOT")
  path=$Q_COPY; [ "$Q_KIND" = restore ] && path=$RS_DIR
  warnm "$(fill "$M_Q_OTHER" got "${kr:-?}" slot "${sl:-?}" want "$want" wslot "$SLOT" why "$why" path "$path")"
  SUM_BOOT="Проверка: телефон загрузился с ядром ${kr:-?} (слот ${sl:-?}), ожидалось $want"
  SUM_WHAT="Итог не подтверждён (см. сообщения выше)."
  finish $RC_ATTN
}

# mk_zip <stage dir> <zip> <entries...>: a new zip of those files (zip,
# python3 or bsdtar on the PC); false when none of them is there
mk_zip() {
  local st=$1 z=$2
  shift 2
  rm -f "$z"
  if command -v zip >/dev/null 2>&1; then
    (cd -- "$st" && zip -q -X "$z" "$@") >/dev/null 2>&1 && return 0
  fi
  if command -v python3 >/dev/null 2>&1 && python3 -I -c 'import zipfile' >/dev/null 2>&1; then
    python3 -I -c 'import os, sys, zipfile
st, z = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(z, "w", zipfile.ZIP_DEFLATED) as o:
    for n in sys.argv[3:]: o.write(os.path.join(st, n), n)' "$st" "$z" "$@" >/dev/null 2>&1 && return 0
  fi
  if command -v bsdtar >/dev/null 2>&1; then
    (cd -- "$st" && bsdtar --format zip -cf "$z" "$@") >/dev/null 2>&1 && return 0
  fi
  rm -f "$z"
  return 1
}
# mk_rz <PC copy folder> <dir name>: its restore zip, made on the PC as the
# installer makes it (restore/ and the tools of the chosen kernel zip, the
# copy's images and SHA256SUMS), with its .sha256; 1 when it cannot be made
mk_rz() {
  local d=$1 dn=$2 st="$TMPD/rz" z k f
  RZ_WHY=fail
  z="$d/$(fill "$RZIP_FMT" dir "$dn")"
  rm -rf "$st"; mkdir -p "$st/META-INF/com/google/android" "$st/tools" || return 1
  zip_cat "$ZPATH" restore/update-binary > "$st/META-INF/com/google/android/update-binary"
  printf '# dummy file; update-binary is a shell script\n' > "$st/META-INF/com/google/android/updater-script"
  zip_cat "$ZPATH" restore/restore.sh > "$st/restore.sh"
  for f in LICENSE LICENSE.taoyao tools/busybox tools/magiskboot; do zip_cat "$ZPATH" "$f" > "$st/$f"; done
  for f in META-INF/com/google/android/update-binary restore.sh LICENSE LICENSE.taoyao tools/busybox tools/magiskboot; do
    [ -s "$st/$f" ] || { logl "restore zip: $f not in $ZNAME"; rm -rf "$st"; return 1; }
  done
  { echo "device=$DEVICE"
    for k in slot kernel date fingerprint boot_ramdisk replaced_by; do echo "$k=$(q info_get "$d/info.txt" $k)"; done
    for f in boot vendor_boot dtbo; do echo "$f.size=$(q fsize "$d/$f.img")"; done; } > "$st/restore.prop"
  for f in SHA256SUMS boot.img vendor_boot.img dtbo.img; do ln -f "$d/$f" "$st/$f" 2>/dev/null || cp -p "$d/$f" "$st/$f" || { rm -rf "$st"; return 1; }; done
  if ! mk_zip "$st" "$z" META-INF/com/google/android/update-binary META-INF/com/google/android/updater-script restore.sh restore.prop \
       LICENSE LICENSE.taoyao tools/busybox tools/magiskboot SHA256SUMS boot.img vendor_boot.img dtbo.img; then
    rm -rf "$st"
    if command -v zip >/dev/null 2>&1 || command -v python3 >/dev/null 2>&1 || command -v bsdtar >/dev/null 2>&1; then logl "restore zip: the zip tool failed"
    else RZ_WHY=tool; logl "restore zip: no zip tool"; fi
    return 1
  fi
  rm -rf "$st"
  printf '%s  %s\n' "$(q sha256_of "$z")" "${z##*/}" > "$z.sha256"
  printf 'restore zip (recovery: adb sideload; or a flasher app): %s\n' "${z##*/}" >> "$d/info.txt"
  logl "restore zip made on the PC: ${z##*/}"
  return 0
}
# a_backup: way A of "copy only" (after the system route from a recovery
# whose ADB has no root): the active slot's partitions read under su (never
# written), pulled, checked, the restore zip made on the PC, filed
a_backup() {
  local dn rd dst cls k free
  WAY=A; SUM_WAY="Способ: из работающей системы с root через USB (флешер прочитал разделы слота)"
  probe_root || fail "$(fill "$M_PHONE_NOANSWER" line "$(cutc 120 < "$TMPD/dc.out")")"
  case $SLOT in _a|_b) ;; *) fail "$M_NO_SLOT";; esac
  free=$(printf '%s\n' "$A_DF" | awk 'NF >= 4 && $4 ~ /^[0-9]+$/ { print int($4 / 1024) }')
  if [ -n "$free" ] && [ "$free" -lt "$STORE_NEED_MB" ]; then fail "$(fill "$M_DATA_SPACE" n "$free")"; fi
  step_h 3 "копия разделов слота $SLOT на телефоне (≈1 мин)"
  dn="$(date +%Y%m%d-%H%M%S)$SLOT"; rd=$PH_WORK/pull/$dn
  SUM_ON=1
  dev_call 300 1 "$(pcmd "$P_A_BACKUP" SLOT "$SLOT" NAME "$dn")"
  if ! grep -q '^COPIED$' "$TMPD/dc.out"; then
    k=$(grep -v '^$' "$TMPD/dc.out" | head -n 1 | cutc 120)
    dev_call 30 1 "$(pcmd "$P_A_ROOTCOPY_RM")" >/dev/null 2>&1
    fail "$(fill "$M_A_BACKUP_FAIL" slot "$SLOT" line "${k:-нет ответа}")"
  fi
  step_h 4 "копия разделов — на компьютер и проверка (≈1 мин)"
  pull_dir "$rd" 0 "" mkrz
  dev_call 30 1 "$(pcmd "$P_A_ROOTCOPY_RM")" >/dev/null 2>&1
  [ -n "$PD_PATH" ] || { SUM_WHAT="Ничего не записано: копию разделов не удалось сохранить на компьютере."; fail "$(fill "$M_A_BACKUP_PULLFAIL" what "${PD_WHAT:-?}")"; }
  PHASE=done
  goodm "$(fill "$M_BACKUP_DONE" path "$PD_PATH")"
  SUM_ON=1; SUM_WHAT="Сохранена копия разделов (ничего не записано)"; SUM_BAKDIR=$PD_PATH; WROTE=
  finish $RC_OK
}

########################################################################
# install, way A (section 9): after the common part of step 2
a_install() {
  local free rel n
  WAY=A; SUM_WAY="Способ: из работающей системы с root через USB, за один проход"
  say "$M_WAY_A"
  probe_root || fail "$(fill "$M_PHONE_NOANSWER" line "$(cutc 120 < "$TMPD/dc.out")")"
  if [ -n "$R_VBS$R_VDS" ]; then check_bl 1; else check_bl 0; fi
  check_slot
  check_battery
  free=$(printf '%s\n' "$A_DF" | awk 'NF >= 4 && $4 ~ /^[0-9]+$/ { print int($4 / 1024) }')
  if [ -n "$free" ] && [ "$free" -lt "$DATA_NEED_MB" ]; then fail "$(fill "$M_DATA_SPACE" n "$free")"; fi
  say "$(fill "$M_NOW_ON" release "${KR:-?}" ver "$ZVER")"
  SUM_WAS=$KR; A_SLOTK=$KR
  # (an installer of an earlier run of the flasher)
  if [ -n "$A_RFRUN" ] || [ -n "$A_UBRC" ]; then a_previous; fi
  step_h 3 "старые копии разделов с телефона — на компьютер (0–2 мин)"
  pull_store "/sdcard/$BACKUP_NAME" 0; n=$PS_N
  pull_store "$PH_WORK/$BACKUP_NAME" 0; n=$((n + PS_N))
  [ "$n" = 0 ] && say "$M_NONE_ON_PHONE"
  # (the gate: the copy this run makes is made and written in one pass)
  gate "$A_SLOTK" "$FPR" "" phone "$A_RID"
  step_h 4 "отправка ядра v$ZVER на телефон (≈10 с)"
  A_SKIPSTART=; A_STEPN=5; A_STEPH="установщик ядра v$ZVER — копия разделов и запись ядра за один проход (≈1–2 мин)"
  a_run kernel "$ZPATH" kernel.zip
  a_after kernel
}
# a_after <kernel>: the end of an (A) run: result, copy, clean up, reboot
a_after() {
  case $A_WATCH in
    2) errm "$M_A_TIMEOUT"; NOREBOOT="установка ещё идёт"
       SUM_WHAT="Итог установки ядра v$ZVER не подтверждён (установка шла дольше 15 минут)."
       SUM_TODO="Не перезагружайте телефон ещё 5 минут, потом запустите флешер снова — он прочитает итог."
       finish $RC_ATTN;;
    1) RESULT=NOLOG;;
    *) a_result;;
  esac
  if [ "$RESULT" = DONE ]; then
    WROTE=yes; PHASE=done
    goodm "$(fill "$M_DONE" ver "$ZVER" slot "${RES_SLOT:-$SLOT}")"
    show_notes "$RES_LOG"
    SUM_WHAT="Установлено: ядро v$ZVER ($KREL${ZKSU:+, KernelSU: $ZKSU}), файл $ZNAME"
    SUM_SLOT="Слот: ${RES_SLOT:-$SLOT} — boot${RES_SLOT:-$SLOT}, vendor_boot${RES_SLOT:-$SLOT}, dtbo${RES_SLOT:-$SLOT} записаны и проверены установщиком"
    step_h 6 "копия разделов — на компьютер и проверка (≈1 мин)"
    done_copy A
    PS_QUIET=1
    pull_store "/sdcard/$BACKUP_NAME" 0
    pull_store "$PH_WORK/$BACKUP_NAME" 0
    PS_QUIET=
    a_clean
    step_h 7 "запись уже сделана на шаге 5 — перезагрузка и проверка"
    reboot_check "$KREL"
    finish "$DONE_RC"
  fi
  # (an abort: AKHOME's log next to the run's copies)
  if fetch_text "$PH_WORK/ak/install.log" "$TMPD/akl.log" 0 && ensure_pulldir; then
    cp -f "$TMPD/akl.log" "$PULLDIR/install-ak-$(date +%Y%m%d-%H%M%S).log" 2>/dev/null
  fi
  if [ "$RESULT" = STEP1 ]; then
    # (not expected in the system: the installer keeps its copy on internal storage)
    warnm "$(fill "$M_STEP1_OK" slot "${RES_SLOT:-$SLOT}")"
    [ -n "$RES_DIR" ] && pull_dir "$RES_DIR" 0
    a_clean
    SUM_WHAT="Ничего не записано: установщик сделал только копию разделов."
    finish $RC_FAIL
  fi
  # (any other end: the copy the installer made, if it names one, goes to
  # the PC too: it holds the slot as it was before this run)
  if [ "$RESULT" != DIRTY ] && [ -n "$RES_DIR" ]; then
    case $RES_DIR in "$REC_TMP/"*) ;; *) SUM_PHONE=$RES_DIR;; esac
    step_h 6 "копия разделов — на компьютер и проверка (≈1 мин)"
    pull_dir "$RES_DIR" 0 || warnm "$(fill "$M_VERIFY_FAILED_DISK" dir "$RES_DIR" what "${PD_WHAT:-?}")"
  fi
  [ "$RESULT" != DIRTY ] && a_clean
  on_result A A
}
# a_previous: an installer started by an earlier run of the flasher is
# running or has ended (9.1): watch it / read its result first
a_previous() {
  local rel
  SUM_ON=1
  if [ -n "$A_RFRUN" ]; then warnm "$M_A_RUNNING"; else say "$M_A_PREVIOUS"; fi
  A_T0P=0; OLD_RUNIDS=
  a_watch 0; A_WATCH=$?
  [ "$A_WATCH" = 0 ] || { A_SKIPSTART=1; a_after kernel; }
  # (a restore zip of an earlier run, not a kernel install: its own result,
  # and the work folder is cleared, so the next run does not read it again)
  sed -n 's/^ui_print \(.*\)$/\1/p' "$TMPD/a.stream" | grep -v '^ui_print$' > "$TMPD/a.rz"
  if grep -Eq "$TXT_RZ_HEAD_RE" "$TMPD/a.rz"; then
    if grep -q "^${RES_PREFIX}${RES_RZ_OK}\$" "$TMPD/a.rz" || grep -qF "$TXT_RZ_OK" "$TMPD/a.rz" || grep -qF "$TXT_RZ_NOOP" "$TMPD/a.rz"; then
      say "$(fill "$M_PREV_RZ" what "$M_PREV_RZ_OK")"
    else
      say "$(fill "$M_PREV_RZ" what "$M_PREV_RZ_FAIL")"
    fi
    logl "earlier run: a restore zip"
    a_clean; WROTE=; PHASE=pre
    return 0
  fi
  a_result
  rel=$(log_release "$TMPD/a.text")
  case $RESULT in
    DONE) say "$(fill "$M_PREV_RESULT" what "$M_PREV_DONE")";;
    CLEAN) say "$(fill "$M_PREV_RESULT" what "$M_PREV_CLEAN")";;
    RESTORED) say "$(fill "$M_PREV_RESULT" what "$M_PREV_ROLLED")";;
    DIRTY) say "$(fill "$M_PREV_RESULT" what "$M_PREV_DIRTY")";;
    *) say "$(fill "$M_PREV_RESULT" what "$M_PREV_UNKNOWN")";;
  esac
  if [ "$RESULT" = DONE ] && [ "$rel" = "$KREL" ]; then
    # (this very kernel is installed already: nothing to do again)
    goodm "$(fill "$M_ALREADY_DONE_A" ver "$ZVER")"
    A_SKIPSTART=1; a_after kernel
  fi
  case $RESULT in
    DONE) A_SLOTK=$rel; done_copy A;;
    DIRTY) WROTE=maybe; on_result A A;;
    INCOMPLETE)
      # (its work folder goes before the stop, so that the next run does not
      # stop at the same earlier run again; the logs on the phone stay. A
      # DIRTY one stays: the slot is still half written)
      a_clean
      WROTE=maybe; on_result A A;;
  esac
  # (nothing of this run is on the phone yet: a stop now is a stop before
  # anything was sent)
  a_clean; PHASE=pre
  return 0
}

########################################################################
# restore (section 14)
# rs_list <STOCK|PREV>: valid folders under both bases, newest first, in
# $TMPD/rs.list ("stamp<TAB>folder")
rs_list() {
  local d z
  scan_known
  : > "$TMPD/rs.list"
  awk -F'\t' -v c="$1" '$1 == c && $10 != "-" && $10 != "MANY" { print $2 "\t" $10 }' "$TMPD/known" > "$TMPD/rs.raw"
  while IFS="$(printf '\t')" read -r d z; do
    [ -f "$d/$z.sha256" ] || continue
    printf '%s\t%s\n' "$(printf '%s' "${d##*/}" | sed -n 's/.*-slot_[ab]-\([0-9]\{8\}-[0-9]\{6\}\).*/\1/p')" "$d" >> "$TMPD/rs.list"
  done < "$TMPD/rs.raw"
  sort -r -o "$TMPD/rs.list" "$TMPD/rs.list"
  RS_N=$(awk 'NF' "$TMPD/rs.list" | wc -l | tr -d ' ')
}
# rs_line <folder>: «<label> — слот _a, ядро <k>, копия от 13.11.2026 13:50»
# (the date of info.txt, which the installer wrote with the copy)
rs_line() {
  local i="$1/info.txt" dt lab=${1##*/}
  lab=${lab%%-slot_*}
  dt=$(q dt_h "$(q info_get "$i" date)")
  # (no date in info.txt: the time in the folder's name)
  [ -z "$dt" ] && dt=$(printf '%s' "${1##*/}" | sed -n 's/.*-slot_[ab]-\([0-9]\{4\}\)\([0-9][0-9]\)\([0-9][0-9]\)-\([0-9][0-9]\)\([0-9][0-9]\)[0-9][0-9].*/\3.\2.\1 \4:\5/p')
  printf '%s — слот %s, ядро %s, копия от %s' "$lab" "$(q info_get "$i" slot)" "$(q info_get "$i" kernel)" "${dt:-?}"
}
# rs_check <folder>: 14.1 checks. RS_DIR RS_ZIP RS_ZNAME RS_SLOT RS_KERNEL
# RS_FPR RS_RID RS_DEP RS_HB RS_HV RS_HD; false with RS_WHAT
rs_check() {
  local d=$1 z n=0 want h p
  RS_WHAT=; RS_DIR=$d; RS_ZIP=
  for z in "$d"/taoyao-restore-*.zip; do [ -f "$z" ] && { n=$((n + 1)); RS_ZIP=$z; }; done
  [ $n = 1 ] || { RS_WHAT="в папке должен быть один restore-zip (найдено: $n)"; return 1; }
  RS_ZNAME=${RS_ZIP##*/}
  [ -f "$RS_ZIP.sha256" ] || { RS_WHAT="нет файла $RS_ZNAME.sha256"; return 1; }
  [ -f "$d/info.txt" ] || { RS_WHAT="нет info.txt"; return 1; }
  RS_SLOT=$(q info_get "$d/info.txt" slot); RS_KERNEL=$(q info_get "$d/info.txt" kernel); RS_FPR=$(q info_get "$d/info.txt" fingerprint)
  RS_RID=$(rid_of "$d/info.txt"); RS_DEP=$(q epoch_of "$(q info_get "$d/info.txt" date)")
  case $RS_SLOT in _a|_b) ;; *) RS_WHAT="info.txt: непонятный слот «$RS_SLOT»"; return 1;; esac
  want=$(tr -d '\r' < "$RS_ZIP.sha256" | awk '{ print $1; exit }')
  h=$(q sha256_of "$RS_ZIP")
  [ -n "$h" ] && [ "$h" = "$want" ] || { RS_WHAT="sha256 $RS_ZNAME не совпадает с $RS_ZNAME.sha256"; return 1; }
  zip_text "$RS_ZIP" restore.prop "$TMPD/rs.prop" || { RS_WHAT="в $RS_ZNAME нет restore.prop"; return 1; }
  [ "$(q info_get "$TMPD/rs.prop" device)" = "$DEVICE" ] || { RS_WHAT="restore-zip не для $DEVICE"; return 1; }
  [ "$(q info_get "$TMPD/rs.prop" slot)" = "$RS_SLOT" ] || { RS_WHAT="restore-zip для другого слота"; return 1; }
  zip_text "$RS_ZIP" SHA256SUMS "$TMPD/rs.sums" || { RS_WHAT="в $RS_ZNAME нет SHA256SUMS"; return 1; }
  RS_HB=$(q sums_get "$TMPD/rs.sums" boot.img); RS_HV=$(q sums_get "$TMPD/rs.sums" vendor_boot.img); RS_HD=$(q sums_get "$TMPD/rs.sums" dtbo.img)
  [ ${#RS_HB} = 64 ] && [ ${#RS_HV} = 64 ] && [ ${#RS_HD} = 64 ] || { RS_WHAT="SHA256SUMS в restore-zip неполный"; return 1; }
  if [ -f "$d/boot.img" ] || [ -f "$d/vendor_boot.img" ] || [ -f "$d/dtbo.img" ]; then
    for p in boot vendor_boot dtbo; do
      [ -f "$d/$p.img" ] || { RS_WHAT="нет $p.img"; return 1; }
      want=$(q sums_get "$TMPD/rs.sums" $p.img)
      [ "$(q sha256_of "$d/$p.img")" = "$want" ] || { RS_WHAT="sha256 $p.img не совпадает с SHA256SUMS"; return 1; }
    done
  else
    [ -n "$RS_QUIET" ] || say "$M_RESTORE_NOIMG"
  fi
  return 0
}
# rs_pick <STOCK|PREV>: the folder to restore (RS_PICK); 1 = back (menu)
rs_pick() {
  local cls=$1 i l d
  RS_PICK=
  rs_list "$cls"
  if [ "$RS_N" = 0 ]; then
    if [ "$cls" = STOCK ]; then errm "$(fill "$M_RESTORE_NONE_STOCK" dir "$BASE/$PC_STOCK")"
    else errm "$M_RESTORE_NONE_PREV"; fi
    [ -n "$MENU" ] && return 1
    finish $RC_FAIL
  fi
  warnm "$M_RESTORE_LIST"
  i=0
  while IFS="$(printf '\t')" read -r l d; do
    [ -n "$d" ] || continue
    i=$((i + 1)); [ $i -le 9 ] || break
    say "  $i  $(rs_line "$d")"
  done < "$TMPD/rs.list"
  bell
  while :; do
    qkey
    case $KEY in
      [1-9]) if [ "$KEY" -le "$i" ]; then RS_PICK=$(sed -n "${KEY}p" "$TMPD/rs.list" | cut -f2-); break; fi;;
      ESC|INT|NO|0) [ -n "$MENU" ] && { logl "restore list: back to the menu"; return 1; }; warn_phase; finish $RC_CANCEL;;
    esac
  done
  logl "restore folder picked: $RS_PICK"
  return 0
}
# hashes_of <slot> <root 0|1>: P_HASH of another slot than SLOT
hashes_of() {
  local s=$SLOT rc
  SLOT=$1; slot_hashes "$2"; rc=$?; SLOT=$s
  return $rc
}
rs_same() { [ "$H_boot" = "$RS_HB" ] && [ "$H_vendor_boot" = "$RS_HV" ] && [ "$H_dtbo" = "$RS_HD" ]; }

# restore_flow <stock|prev> [again]: menu 2 / 3. 1 = back to the menu.
# again = after the system route (rec_noroot): the copy is chosen, from step 2
restore_flow() {
  local cls=STOCK ph=pre
  [ "$1" = prev ] && cls=PREV
  STEPM=5; RESCUE=
  if [ "$2" = again ]; then
    ph=wait; [ "$WROTE" = maybe ] && ph=q2
  else
    STEPN=0
    step_h 1 "выбор и проверка копии на компьютере (секунды)"
    if [ -n "$ARGPATH" ] && [ -d "$ARGPATH" ]; then RS_PICK=$ARGPATH
    else rs_pick "$cls" || return 1; fi
    rs_check "$RS_PICK" || fail "$(fill "$M_RESTORE_BAD" path "$RS_PICK" what "$RS_WHAT")"
    goodm "$(fill "$M_RESTORE_OK_PC" path "$RS_PICK")"
    say "  $(rs_line "$RS_PICK")"
    prompt_yes "$(fill "$M_RESTORE_CONFIRM" slot "$RS_SLOT")" 1 || { [ -n "$MENU" ] && { logl "restore: back to the menu"; return 1; }; warn_phase; finish $RC_CANCEL; }
    BOOTWANT=$RS_KERNEL
  fi
  step_h 2 "поиск телефона и проверки (до 3 мин, пока вы подключаете телефон)"
  [ "$2" = again ] || { find_adb; start_server; }
  wait_phone "device recovery sideload" "$T_DEVICE" NONE "$ph"
  case $WSTATE in
    device)
      WHERE=android
      probe_android; check_taoyao_android
      say "$(fill "$M_PHONE" model "${A_MODEL:-?}" rel "${A_REL:-?}" rom "$A_ROMLBL")"
      check_slot; check_battery
      rs_phone_checks
      root_check
      root_loop
      if [ -n "$HAVE_ROOT" ]; then
        WAY=A; SUM_WAY="Способ: из работающей системы с root через USB"
        if hashes_of "$RS_SLOT" 1 && rs_same; then rs_noop; fi
        RS_BH=$H_boot; RS_BV=$H_vendor_boot; RS_BD=$H_dtbo
        step_h 3 "подготовка: restore-zip на телефон (≈10 с)"
        A_SKIPSTART=; A_STEPN=4; A_STEPH="возврат образов restore-zip'ом (≈30 с)"
        a_run restore "$RS_ZIP" restore.zip
        rz_result A
      fi
      # (the recovery's ADB has no root: Q3 from here, or the options)
      [ -n "$RNR" ] && nr_android_end
      # (stock HyperOS: Xiaomi's recovery cannot install the restore zip;
      # TWRP / OrangeFox instead of it can, as for install and backup)
      if [ -n "$A_STOCKHY" ]; then
        if ! prompt_yes "$M_STOCK_NOROOT" 1; then SUM_ON=1; SUM_WHAT="Ничего не записано."; NOFOOTER=1; finish $RC_FAIL; fi
        step_h 3 "подготовка: переход в рекавери TWRP / OrangeFox (≈1 мин)"
        b_from_android recovery H_TWRP_WAIT 0 M_MAYBE_XIAOMI_REC_W
      else
        step_h 3 "подготовка: переход в рекавери и в режим Apply from ADB (≈1 мин и ваши нажатия)"
        prompt_yes "$M_REBOOT_REC_ASK_R" 1 || { warn_phase; finish $RC_CANCEL; }
        # (into the recovery's menu with ADB: the slot is read before and
        # after the restore zip, the only proof of what it did)
        b_from_android recovery H_ENABLE_ADB_R 1
      fi
      WHERE=rec; H4=1
      [ -n "$FRESHSL" ] && { FRESHSL=; b_wait_rec_start; };;
    sideload) WHERE=rec; b_wait_rec_start;;
    recovery) WHERE=rec;;
  esac
  WAY=B; SUM_WAY="Способ: рекавери, adb sideload"
  rz_flow_b
}
# rs_phone_checks: the slot and the ROM build against the folder (14.2)
rs_phone_checks() {
  if [ -n "$SLOT" ] && [ "$RS_SLOT" != "$SLOT" ] && [ -z "$RS_SLOTASKED" ]; then
    RS_SLOTASKED=1
    prompt_yes "$(fill "$M_RESTORE_OTHERSLOT_ASK" s1 "$RS_SLOT" s2 "$SLOT")" 1 || { warn_phase; finish $RC_CANCEL; }
  fi
  local f=$FPR r=$A_RID v
  [ "$WHERE" = rec ] && { f=; r=; }
  if [ -n "$f$r" ] && [ -z "$RS_ROMSAID" ]; then
    v=$(printf '%s\t%s\t%s\t%s\t%s\n' "$r" "$f" "$RS_RID" "$RS_FPR" "$RS_DEP" | awk -F'\t' "$ROM_AWK"'{ print rc("", $1, $2, "", $3, $4, $5) }')
    logl "restore: the copy's ROM build against the phone's: $v"
    case $v in
      other) RS_ROMSAID=1; warnm "$M_RESTORE_OTHERROM";;
      older) RS_ROMSAID=1; warnm "$(fill "$M_RESTORE_MAYBEROM" how "$M_HOW_OLDER")";;
      fprdiff) RS_ROMSAID=1; warnm "$(fill "$M_RESTORE_MAYBEROM" how "$M_HOW_FPRDIFF")";;
    esac
  fi
  return 0
}
rs_noop() {
  goodm "$(fill "$M_RESTORE_NOOP" slot "$RS_SLOT")"
  SUM_ON=1; SUM_WHAT="Ничего делать не нужно: слот $RS_SLOT уже содержит образы из $RS_DIR"
  if [ "$WHERE" = rec ]; then
    if [ "$RS_SLOT" = "$SLOT" ]; then reboot_check "$RS_KERNEL"; else reboot_check ""; fi
  fi
  finish $RC_OK
}
# rz_flow_b: the restore zip by adb sideload in recovery (one pass)
rz_flow_b() {
  local rc
  if [ -z "$FRESHSL" ]; then
    [ "$DSTATE" = recovery ] || { W_ALSO=device; wait_phone recovery "$T_USER" H_LEAVE_SIDELOAD wait; }
    b_probe restore
    rs_phone_checks
    if hashes_of "$RS_SLOT" 0; then
      rs_same && rs_noop
      RS_BH=$H_boot; RS_BV=$H_vendor_boot; RS_BD=$H_dtbo
    fi
  fi
  [ -z "$H4" ] && step_h 3 "подготовка: режим Apply from ADB (ваши нажатия)"
  # (the tap into Apply from ADB belongs to step 3, also after the reboot
  # from Android into the recovery's menu)
  b_wait_sideload RESTORE wait; H4=1
  step_h 4 "возврат образов restore-zip'ом (≈30 с)"
  # (WROTE=maybe once the restore zip is sent: do_sideload)
  SUM_ON=1
  b_pass RESTORE "${RS_ZIP%/*}" "$RS_ZNAME" "restore-zip"
  rz_result B
}
# rz_result <A|B>: 11.3 / 14.3: the slot's hashes decide, the restore's own
# log and text give the reason
rz_result() {
  local way=$1 rt=0 rl= m cut=${RCUT:-0} out=REFUSED
  [ "$way" = A ] && rt=1
  : > "$TMPD/rz.log"
  if [ "$way" = A ]; then
    sed -n 's/^ui_print \(.*\)$/\1/p' "$TMPD/a.stream" 2>/dev/null | grep -v '^ui_print$' > "$TMPD/rz.log"
    a_clean
  else
    m=$(printf '%s\n' "$R_LOGS" | awk -F: -v p="$REC_TMP/$RLOG_NAME" '{ q = substr($0, index($0, ":") + 1) } q == p { print $1; exit }')
    if [ -n "$m" ] && [ "$m" -ge "$cut" ]; then fetch_text "$REC_TMP/$RLOG_NAME" "$TMPD/rz.log" 0; fi
  fi
  logf "$TMPD/rz.log" "restore "
  if hashes_of "$RS_SLOT" "$rt"; then
    if rs_same; then out=OK
    elif [ -n "$RS_BH" ] && [ "$H_boot" = "$RS_BH" ] && [ "$H_vendor_boot" = "$RS_BV" ] && [ "$H_dtbo" = "$RS_BD" ]; then out=REFUSED
    elif grep -qF "$TXT_RZ_FAIL" "$TMPD/rz.log" || [ -n "$RS_BH" ]; then out=DIRTY
    elif grep -q "^${RES_PREFIX}${RES_RZ_FAIL}\$" "$TMPD/rz.log" && grep -qF "$TXT_NOTHING" "$TMPD/rz.log"; then out=REFUSED
    else out=UNCONFIRMED; fi
  else
    out=UNCONFIRMED
  fi
  logl "restore result: $out"
  case $out in
    OK)
      WROTE=
      if [ -n "$RESCUE" ]; then
        goodm "$(fill "$M_RESCUED" slot "$RS_SLOT")"
        NOREBOOT=; SUM_TODO=; DONE_RC=$RC_ROLLED
        SUM_WHAT="Ядро v$ZVER не установлено: исходные образы возвращены в слот $RS_SLOT restore-zip'ом (проверено по sha256)."
        reboot_check "$RS_KERNEL"
        finish $RC_ROLLED
      fi
      goodm "$(fill "$M_RESTORED" slot "$RS_SLOT" kernel "$RS_KERNEL")"
      SUM_WHAT="Возвращено: ядро $RS_KERNEL в слот $RS_SLOT (папка $RS_DIR)"
      step_h 5 "проверка слота и перезагрузка"
      if [ "$RS_SLOT" = "$SLOT" ]; then reboot_check "$RS_KERNEL"; else reboot_check ""; fi
      finish $RC_OK;;
    REFUSED)
      errm "$M_RESTORE_REFUSED"
      if [ -s "$TMPD/rz.log" ]; then show_reason "$TMPD/rz.log"; else say "$M_RESTORE_REFUSED_NOLOG"; fi
      SUM_WHAT="Возврат не выполнен, ничего не записано."
      [ -n "$RESCUE" ] && return 1
      finish $RC_FAIL;;
    DIRTY)
      errm "$(fill "$M_RESTORE_DIRTY" slot "$RS_SLOT" path "$RS_DIR")"
      say "  $RS_DIR"
      say "$(fill "$M_BACK_FB" term "$M_TERM")"
      fastboot_lines "$RS_SLOT" "      " "$RS_DIR"
      NOREBOOT="слот $RS_SLOT записан не полностью"
      SUM_WHAT="ОШИБКА: возврат записал слот $RS_SLOT не полностью."
      SUM_TODO="Не перезагружайте телефон в систему. Запишите образы через fastboot из папки $RS_DIR (команды выше)."
      [ -n "$RESCUE" ] && return 1
      finish $RC_ATTN;;
    *)
      errm "$(fill "$M_RESTORE_UNCONFIRMED" slot "$RS_SLOT")"
      NOREBOOT="итог возврата не подтверждён"
      SUM_WHAT="Итог возврата не подтверждён."
      [ -n "$RESCUE" ] && return 1
      finish $RC_ATTN;;
  esac
}
# shq <text>: quoted to be typed in bash / zsh ('...', a ' as '\'')
shq() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }
# tool_cmd <adb|fastboot>: that program of the platform-tools in use, with
# its full path, ready to type (its bare name when it is not there)
tool_cmd() {
  local d=${ADB%/*}
  if [ -n "$ADB" ] && [ "$d" != "$ADB" ] && [ -f "$d/$1" ] && [ -x "$d/$1" ]; then shq "$d/$1"; else printf '%s' "$1"; fi
}
# fastboot_lines <slot> [indent] [folder]: the three fastboot commands,
# with full paths when the folder is given (and the Linux udev note)
fastboot_lines() {
  local i=${2:-  } fb p
  fb=$(tool_cmd fastboot)
  for p in boot vendor_boot dtbo; do
    if [ -n "$3" ]; then say "${i}$fb flash $p$1 $(shq "$3/$p.img")"; else say "${i}$fb flash $p$1 $p.img"; fi
  done
  [ -n "$3" ] && [ "$(uname -s 2>/dev/null)" = Linux ] && say "$M_BACK_UDEV"
  return 0
}
# rescue_now <A|B> <PC folder>: after abort-dirty, the restore zip of the
# copy just made, without a reboot (14.4); returns when it did not help
rescue_now() {
  RESCUE=1; RS_BH=; RS_BV=; RS_BD=
  rs_check "$2" || { errm "$(fill "$M_RESTORE_BAD" path "$2" what "$RS_WHAT")"; RESCUE=; return 1; }
  if [ "$1" = A ]; then
    hashes_of "$RS_SLOT" 1 && { RS_BH=$H_boot; RS_BV=$H_vendor_boot; RS_BD=$H_dtbo; }
    A_SKIPSTART=; A_STEPN=; A_STEPH=
    a_run restore "$RS_ZIP" restore.zip
    rz_result A
  else
    hashes_of "$RS_SLOT" 0 && { RS_BH=$H_boot; RS_BV=$H_vendor_boot; RS_BD=$H_dtbo; }
    b_pass RESTORE "${RS_ZIP%/*}" "$RS_ZNAME" "restore-zip"
    rz_result B
  fi
  RESCUE=
  return 1
}

########################################################################
# backup only (section 15)
backup_done() {
  PHASE=done
  goodm "$(fill "$M_BACKUP_DONE" path "${1:-?}")"
  SUM_ON=1; SUM_WHAT="Сохранена копия разделов (ничего не записано)"; SUM_BAKDIR=$1
  WROTE=
  reboot_check "$(q info_get "$1/info.txt" kernel)"
  finish $RC_OK
}
# backup_flow [again]: again = after the system route (rec_noroot): with
# root, way A of "copy only" (a_backup), else the options
backup_flow() {
  local ph=pre
  STEPM=5
  if [ "$1" = again ]; then
    ph=wait; [ "$WROTE" = maybe ] && ph=q2
  else
    STEPN=0
    step_h 1 "проверка файла ядра v$ZVER (секунды)"
    show_zip_info
  fi
  step_h 2 "поиск телефона и проверки (до 3 мин, пока вы подключаете телефон)"
  [ "$1" = again ] || { find_adb; start_server; }
  wait_phone "device recovery sideload" "$T_DEVICE" NONE "$ph"
  case $WSTATE in
    device)
      WHERE=android
      probe_android; check_taoyao_android
      say "$(fill "$M_PHONE" model "${A_MODEL:-?}" rel "${A_REL:-?}" rom "$A_ROMLBL")"
      check_bl 0; check_slot; check_battery
      pull_store "/sdcard/$BACKUP_NAME" 0
      if [ -n "$RNR" ]; then
        root_check; root_loop
        [ -n "$HAVE_ROOT" ] && a_backup
        nr_end
      fi
      say "$M_BACKUP_NEEDS_REC"
      if [ -n "$A_STOCKHY" ]; then
        if ! prompt_yes "$M_STOCK_NOROOT" 1; then
          SUM_ON=1; SUM_WHAT="Ничего не записано."; NOFOOTER=1; finish $RC_FAIL
        fi
        step_h 3 "переход в рекавери TWRP / OrangeFox (≈1 мин)"
        b_from_android recovery H_TWRP_WAIT 0 M_MAYBE_XIAOMI_REC_W
      else
        if ! prompt_yes "$M_REBOOT_REC_ASK_B" 1; then
          if [ -n "$SAVED" ]; then SUM_ON=1; SUM_WHAT="Сохранены копии из памяти телефона (ничего не записано)"; finish $RC_OK; fi
          warn_phase; finish $RC_CANCEL
        fi
        # (into the recovery's menu, not straight into sideload: the flasher
        # must look first whether this recovery would install at once)
        step_h 3 "переход в рекавери и в режим Apply from ADB (≈1 мин и ваши нажатия)"
        b_from_android recovery H_ENABLE_ADB_B 1
      fi
      WHERE=rec; H4=1
      [ -n "$FRESHSL" ] && { FRESHSL=; b_wait_rec_start; };;
    sideload) WHERE=rec; say "$M_WAY_B_REC_BAK"; b_wait_rec_start;;
    recovery) WHERE=rec; say "$M_WAY_B_REC_BAK";;
  esac
  WAY=B; SUM_WAY="Способ: рекавери, adb sideload (только шаг 1: копия)"
  b_install backup
}

########################################################################
# reboot and the boot check (section 16)
# reboot_android: the reboot to the system from the running system:
# Android's own (svc power reboot, as the power menu: the system closes the
# apps and stops its services before init's short shutdown). A plain "adb
# reboot" leaves all of that to init's few seconds: on one phone /data then
# was not unmounted in time, and the next boot checked all of /data (fsck).
# (Not shown yet that svc avoids it: init's shutdown is the same.)
# adb reboot when svc is refused, or when the phone has not left within
# T_SVC (twice that while Android says it is shutting down).
reboot_android() {
  local t rc why=
  say "$M_REBOOTING_SYS"
  logl "> adb shell svc power reboot"
  run_to "$T_SVC" "$TMPD/rb.out" "$ADB" -s "$SERIAL" shell svc power reboot; rc=$?
  logl "< rc=$rc $(tr '\r\n' '  ' < "$TMPD/rb.out" | cutc 200)"
  if grep -qiE 'fail|exception|error|denied|not found|inaccessible|unknown|usage' "$TMPD/rb.out"; then why="svc refused"
  else
    t=$SECONDS
    while :; do
      state_now
      if [ "$DSTATE" != device ]; then logl "svc power reboot: the phone is restarting (${DSTATE:-gone})"; return 0; fi
      if [ $((SECONDS - t)) -ge "$T_SVC" ]; then
        if [ -z "$why" ] && dev_call 15 0 "getprop sys.shutdown.requested" && [ -n "$(tr -d '\r\n ' < "$TMPD/dc.out")" ]; then
          why=slow; t=$SECONDS; logl "svc power reboot: Android is shutting down, waiting once more"; continue
        fi
        why="the phone did not restart in $T_SVC s"; break
      fi
      nap 1
    done
  fi
  logl "svc power reboot: $why: adb reboot"
  say "$M_REBOOT_FALLBACK"
  logl "> adb reboot"
  run_to 30 "$TMPD/rb.out" "$ADB" -s "$SERIAL" reboot
}
reboot_check() {
  local want=$1 t kr bc
  PHASE=done
  if [ -n "$NOREBOOT" ]; then say "$(fill "$M_REBOOT_NOT" why "$NOREBOOT")"; return 0; fi
  echo
  if ! prompt_yes "$M_REBOOT_ASK" 1; then
    if [ "$WHERE" = rec ]; then say "$M_REBOOT_SELF"; else say "$M_REBOOT_SELF_A"; fi
    return 0
  fi
  # (Android's own reboot only from a running system: the phone's state now
  # decides, "device" is Android; from a recovery as before)
  state_now
  if [ "$DSTATE" = device ]; then reboot_android
  else
    logl "> adb reboot"
    run_to 30 "$TMPD/rb.out" "$ADB" -s "$SERIAL" reboot
  fi
  SUM_REBOOT=1
  [ -n "$want" ] || return 0
  PHASE=boot; BOOTSKIP=
  say "$M_BOOT_WAIT"
  # (it leaves first, then comes back booted)
  t=$SECONDS
  while [ $((SECONDS - t)) -lt "$T_LEAVE" ]; do
    state_now
    case $DSTATE in device|recovery|sideload) ;; *) break;; esac
    readkey_t 1; check_intr
    case $KEY in ESC|NO) BOOTSKIP=1;; esac
    [ -n "$BOOTSKIP" ] && break
  done
  if [ -z "$BOOTSKIP" ]; then
    W_ESC=1; W_SOFT=1; W_UNAUTH=$T_UNAUTH; W_POLL=2; wait_phone device "$T_BOOT" "" boot
  else WSTATE=skip; fi
  case $WSTATE in
    skip) BOOTSKIP=; PHASE=done; return 0;;
    unauthorized) warnm "$M_BOOT_UNAUTH"; SUM_BOOT="Загрузка: телефон загрузился (версию ядра проверьте сами)"; return 0;;
    timeout) warnm "$M_BOOT_NONE"; SUM_BOOT="Загрузка: телефон не появился в системе за 5 минут"; return 0;;
  esac
  t=$SECONDS
  while [ $((SECONDS - t)) -lt "$T_BOOT" ]; do
    dev_call 20 0 "$P_KR" >/dev/null 2>&1
    kr=$(kv kr); bc=$(kv bc)
    if ! probe_ok && lost; then
      W_ESC=1; W_SOFT=1; W_UNAUTH=$T_UNAUTH; W_POLL=2; wait_phone device "$T_BOOT" "" boot
      case $WSTATE in skip|timeout|unauthorized) break;; esac
      PHASE=boot
    fi
    [ "$bc" = 1 ] && [ -n "$kr" ] && break
    readkey_t 3; check_intr
    case $KEY in ESC|NO) BOOTSKIP=1;; esac
    [ -n "$BOOTSKIP" ] && { BOOTSKIP=; PHASE=done; return 0; }
  done
  PHASE=done
  if [ -z "$kr" ]; then warnm "$M_BOOT_NONE"; SUM_BOOT="Загрузка: не подтверждена"; return 0; fi
  if [ "$kr" = "$want" ]; then goodm "$(fill "$M_BOOT_OK" rel "$kr")"; SUM_BOOT="Загрузка: телефон загрузился с ядром $kr"
  else warnm "$(fill "$M_BOOT_OTHER" got "$kr" want "$want")"; SUM_BOOT="Загрузка: телефон загрузился с ядром $kr (ожидалось $want)"; fi
  return 0
}

########################################################################
# the final summary (section 17)
# sum_stock_pc: SUM_STOCK = the PC's stock folder of SLOT for this ROM build
# (the boot ramdisk of this run's copy, else the build time, else the
# fingerprint, as the gate matches), else SUM_STOCK_OTHER = the slot's other
# stock folders
sum_stock_pc() {
  local f=$FPR r=$A_RID b= m= i="$SUM_BAKDIR/info.txt"
  if [ -n "$SUM_BAKDIR" ] && [ -f "$i" ]; then
    b=$(q info_get "$i" boot_ramdisk); m=$(q info_get "$i" fingerprint); [ -n "$m" ] && f=$m
    m=$(rid_of "$i"); [ -n "$m" ] && r=$m; m=
  fi
  scan_known
  rom_list STOCK "$SLOT" "$b" "$r" "$f" > "$TMPD/sum.rl"
  m=$(awk -F'\t' '$1 == "same" { print $2; exit }' "$TMPD/sum.rl")
  [ -z "$m" ] && { m=$(awk -F'\t' '$1 == "fpr" { print $2; exit }' "$TMPD/sum.rl"); SUM_STOCK_FPR=$m; }
  if [ -n "$m" ]; then SUM_STOCK=$m; return 0; fi
  SUM_STOCK_OTHER=$(sum_list other); SUM_STOCK_OLDER=$(sum_list older); SUM_STOCK_MAYBE=$(sum_list fprdiff unknown)
  return 0
}
# sum_list <verdict>...: the dirs of $TMPD/sum.rl with those verdicts, "; "-joined
sum_list() { awk -F'\t' -v w=" $* " 'index(w, " " $1 " ") { print $2 }' "$TMPD/sum.rl" | tr '\n' ';' | sed 's/;$//; s/;/; /g'; }
show_summary() {
  local rc=$1 f s rz back
  SUM_SHOWN=1
  echo
  say "================ ИТОГ ================"
  [ -n "$SUM_TODO" ] && errm "ЧТО ДЕЛАТЬ СЕЙЧАС: $SUM_TODO"
  if [ -z "$SUM_WHAT" ]; then
    case $rc in
      0) SUM_WHAT="Готово.";;
      11) if [ -n "$PHASE_SAID" ]; then SUM_WHAT=$M_STOPPED_SAID; else SUM_WHAT="$(phase_msg)"; fi;;
      12) SUM_WHAT="Ядро не установлено: установщик вернул исходные образы.";;
      13) SUM_WHAT="Итог не подтверждён — см. сообщения выше.";;
      *) if [ -n "$WROTE" ]; then SUM_WHAT="Итог не подтверждён — см. сообщения выше."
         elif [ -n "$FAIL_TXT" ]; then SUM_WHAT="Ничего не записано: $(why_short "$FAIL_TXT")."
         else SUM_WHAT="Ничего не записано (см. сообщения выше)."; fi;;
    esac
  fi
  say "$SUM_WHAT"
  [ -n "$SUM_WAY" ] && say "$SUM_WAY"
  [ -n "$SUM_SLOT" ] && say "$SUM_SLOT"
  [ -n "$SUM_WAS" ] && [ "$CMD" != restore-stock ] && [ "$CMD" != restore-prev ] && say "Было: $SUM_WAS"
  [ -n "$SUM_BOOT" ] && say "$SUM_BOOT"
  # (a backup run that neither made nor met stock images: those of the
  # slot on the PC, matched to this ROM build as the gate does)
  [ -z "$SUM_STOCK" ] && [ "$CMD" = backup ] && [ -n "$SLOT" ] && sum_stock_pc
  if [ -n "$SUM_STOCK" ] && [ "$SUM_STOCK" = "$SUM_STOCK_FPR" ]; then say "Стоковые образы (совпали с прошивкой только по отпечатку): $SUM_STOCK"
  elif [ -n "$SUM_STOCK" ]; then say "Стоковые образы: $SUM_STOCK"
  elif [ -n "$SUM_STOCK_OTHER$SUM_STOCK_OLDER$SUM_STOCK_MAYBE" ]; then
    [ -n "$SUM_STOCK_OTHER" ] && say "Стоковые образы этого слота от другой сборки прошивки: $SUM_STOCK_OTHER"
    [ -n "$SUM_STOCK_OLDER" ] && say "Стоковые образы этого слота, скорее всего, от прошлой сборки прошивки: $SUM_STOCK_OLDER"
    [ -n "$SUM_STOCK_MAYBE" ] && say "Стоковые образы этого слота, возможно, другой сборки прошивки: $SUM_STOCK_MAYBE"
  else
    case $CMD in
      restore*) ;;
      *) if [ -n "$WROTE" ] || [ "$CMD" = backup ]; then say "Стоковых образов этой прошивки на компьютере нет."; fi;;
    esac
  fi
  [ -n "$SUM_PREV" ] && say "Прошлая сборка $(q series_of "$(q info_get "$SUM_PREV/info.txt" kernel)"): $SUM_PREV"
  [ -n "$SUM_BAKDIR" ] && [ "$SUM_BAKDIR" != "$SUM_STOCK" ] && [ "$SUM_BAKDIR" != "$SUM_PREV" ] && say "Копия разделов: $SUM_BAKDIR"
  [ -n "$SUM_PHONE" ] && say "Копия на телефоне: $SUM_PHONE"
  [ -n "$SUM_NOTE" ] && warnm "$SUM_NOTE"
  if [ -n "$PULLDIR" ] && [ -d "$PULLDIR" ] && [ -n "$(ls -A "$PULLDIR" 2>/dev/null)" ]; then say "Прочие файлы этого запуска: $PULLDIR"; fi
  # how to go back: the stock folder, else the previous build
  back=$SUM_STOCK; s="Как вернуться на стоковое ядро:"
  [ -z "$back" ] && [ -n "$SUM_PREV" ] && { back=$SUM_PREV; s="Как вернуться на прошлую сборку:"; }
  [ -z "$back" ] && [ -n "$SUM_BAKDIR" ] && { back=$SUM_BAKDIR; s="Как вернуть образы из копии:"; }
  if [ -n "$back" ] && [ "$CMD" != restore-stock ] && [ "$CMD" != restore-prev ]; then
    rz=$(ls "$back"/taoyao-restore-*.zip 2>/dev/null | head -n 1); rz=${rz##*/}
    f=$(q info_get "$back/info.txt" slot)
    say "$s"
    # (the flasher restores only with a restore zip)
    if [ -z "$rz" ]; then :
    elif [ "$back" = "$SUM_STOCK" ]; then say "  • флешер: пункт 2 меню ($LAUNCHER restore-stock);"
    elif [ "$back" = "$SUM_PREV" ]; then say "  • флешер: пункт 3 меню ($LAUNCHER restore-prev);"; fi
    if [ -n "$rz" ]; then
      say "$(fill "$M_BACK_SIDELOAD" term "$M_TERM")"
      say "      $(tool_cmd adb) sideload $(shq "$back/$rz")"
    fi
    say "$(fill "$M_BACK_FB" term "$M_TERM")"
    fastboot_lines "${f:-$SLOT}" "      " "$back"
  fi
  [ -n "$LOG" ] && say "Журнал: $LOG"
  say "======================================"
}

########################################################################
# help, menu, arguments (section 7)
t_help() {
  cat <<EOF
$M_BANNER

Запуск:
  $LAUNCHER                         меню
  $LAUNCHER install [файл.zip]      установить ядро (способ выбирается сам)
  $LAUNCHER install-system [файл]   установить из работающей системы с root
  $LAUNCHER install-recovery [файл] установить через рекавери (adb sideload)
  $LAUNCHER restore-stock [папка]   вернуть стоковое ядро (копия на компьютере)
  $LAUNCHER restore-prev [папка]    вернуть прошлую сборку ядра taoyao
                                            (копии в taoyao-<серия>-backups)
  $LAUNCHER backup [файл.zip]       только сохранить копию разделов
  $LAUNCHER help                    эта справка
  $LAUNCHER <файл.zip>              то же, что install <файл.zip>

Файл ядра (taoyao-6.12-vX.XX.zip или taoyao-6.12-vX.XX-noksu.zip) флешер
ищет рядом с собой и в текущей папке; из нескольких берёт самое новое.
Ответы на вопросы: Enter или Д — да; Esc или Н — нет (в латинской
раскладке: L — да, N — нет; на Y флешер переспросит: это клавиша Н).
Подробно: README-flash-ru.txt.

Коды выхода: 0 — готово; 10 — остановлено, ничего не записано; 11 —
отменено вами; 12 — установщик начал запись и вернул исходные образы;
13 — внимание: состояние слота не подтверждено (см. сообщения).
EOF
}
# parse_args <arguments>: CMD (menu, install, install-system,
# install-recovery, restore-stock, restore-prev, backup, help), ARGPATH
parse_args() {
  local w
  CMD=; ARGPATH=; MENU=
  if [ $# = 0 ]; then CMD=menu; MENU=1; return 0; fi
  w=$(lower "$1"); w=${w#--}
  case $w in
    install|install-system|install-recovery|backup|restore-stock|restore-prev)
      CMD=$w; shift
      if [ $# -gt 0 ]; then ARGPATH=$1; shift; fi
      if [ $# -gt 0 ]; then errm "$(fill "$M_BAD_ARG" arg "$1")"; t_help; exit $RC_FAIL; fi;;
    help|-h|/?|-?|'?'|справка|Справка) CMD=help; return 0;;
    *)
      case $w in
        *.zip) CMD=install; ARGPATH=$1; shift
               [ $# -gt 0 ] && say "$(fill "$M_DROP_MANY" name "${ARGPATH##*/}")";;
        *) errm "$(fill "$M_BAD_ARG" arg "$1")"; t_help; exit $RC_FAIL;;
      esac;;
  esac
  if [ -n "$ARGPATH" ]; then
    case $ARGPATH in /*) ;; *) ARGPATH="$CWD/$ARGPATH";; esac
    if [ ! -e "$ARGPATH" ]; then errm "$(fill "$M_NOT_FOUND" path "$ARGPATH")"; exit $RC_FAIL; fi
    case $CMD in
      restore-*) [ -d "$ARGPATH" ] || { errm "$(fill "$M_NOT_FOUND" path "$ARGPATH")"; exit $RC_FAIL; };;
    esac
  fi
  return 0
}
# zip_search: find, unwrap, choose (section 4); messages
zip_search() {
  local l
  find_zips
  if unwrap_zips; then find_zips; fi
  if [ -n "$ZSKIP" ]; then
    printf '%s' "$ZSKIP" > "$TMPD/zskip"
    while IFS= read -r l; do [ -n "$l" ] && warnm "$l"; done < "$TMPD/zskip"
  fi
  if [ -n "$ZEXPL" ] && [ -n "$ZARG_BAD" ]; then errm "$ZARG_BAD"; finish $RC_FAIL; fi
  ZPATH=
  if [ "$ZOK_N" -gt 0 ]; then
    use_zip "${ZOK_P[0]}" || { errm "$CZ_MSG"; finish $RC_FAIL; }
    show_zip
    return 0
  fi
  warnm "$(fill "$M_ZIP_NONE" path "$HERE")"
  [ -n "$ZNEAR" ] && warnm "$(fill "$M_ZIP_NEAR" list "$ZNEAR")"
  return 1
}
# pick_zip: menu item 5 (several valid zips, newest first)
pick_zip() {
  local i=0
  echo
  say "$M_PICK_ZIP"
  while [ $i -lt "$ZOK_N" ]; do
    say "  $((i + 1))  v${ZOK_V[$i]}  ${ZOK_P[$i]##*/}"
    i=$((i + 1))
  done
  while :; do
    qkey
    case $KEY in
      [1-9]) if [ "$KEY" -le "$ZOK_N" ]; then use_zip "${ZOK_P[$((KEY - 1))]}" && goodm "$(fill "$M_ZIP_FOUND" ver "$ZVER$ZNOKSU" name "$ZNAME")"; return 0; fi;;
      ESC|INT|NO|0) return 0;;
    esac
  done
}
menu() {
  local ns np mx
  while :; do
    rs_list STOCK; ns=$RS_N
    rs_list PREV; np=$RS_N
    mx=4; [ "$ZOK_N" -gt 1 ] && mx=5
    flushkeys
    echo
    say "Что сделать? Нажмите цифру:"
    echo
    if [ -n "$ZPATH" ]; then say "  1  Установить ядро v$ZVER$ZNOKSU ($ZNAME)"
    else say "  1  Установить ядро — файл ядра не найден"; fi
    say "  2  Вернуть стоковое ядро (копий на компьютере: $ns)"
    say "  3  Вернуть прошлую сборку ядра taoyao (копии в taoyao-<серия>-backups)"
    say "     копий на компьютере: $np"
    say "  4  Только сохранить копию разделов (ничего не записывается)"
    [ "$mx" = 5 ] && say "  5  Выбрать другой файл ядра (найдено: $ZOK_N)"
    echo
    say "  0  Выход"
    qkey
    logl "menu key: $KEY"
    case $KEY in
      1) if [ -n "$ZPATH" ]; then CMD=install; return 0; fi; warnm "$(fill "$M_ZIP_NONE" path "$HERE")";;
      2) if [ "$ns" = 0 ]; then errm "$(fill "$M_RESTORE_NONE_STOCK" dir "$BASE/$PC_STOCK")"
         else CMD=restore-stock; restore_flow stock; STEPN=0; fi;;
      3) if [ "$np" = 0 ]; then errm "$M_RESTORE_NONE_PREV"
         else CMD=restore-prev; restore_flow prev; STEPN=0; fi;;
      4) if [ -n "$ZPATH" ]; then CMD=backup; return 0; fi; warnm "$(fill "$M_ZIP_NONE" path "$HERE")";;
      5) [ "$mx" = 5 ] && pick_zip;;
      0|ESC|INT|NO) MENU=; logl "menu: exit"; finish $RC_OK;;
      *) say "Нажмите цифру от 0 до $mx.";;
    esac
    CMD=menu
  done
}

########################################################################
# install (section 7.3 plan, way chosen in section 8)
# install_flow [again]: again = after the system route from a recovery whose
# ADB has no root (rec_noroot): from step 2, the phone in Android
install_flow() {
  local ph=pre
  STEPM=7
  if [ "$1" = again ]; then
    ph=wait; [ "$WROTE" = maybe ] && ph=q2
  else
    STEPN=0
    step_h 1 "проверка файла ядра v$ZVER (секунды)"
    show_zip_info
  fi
  step_h 2 "поиск телефона и проверки (до 3 мин, пока вы подключаете телефон)"
  [ "$1" = again ] || { find_adb; start_server; }
  wait_phone "device recovery sideload" "$T_DEVICE" NONE "$ph"
  case $WSTATE in
    device)
      WHERE=android
      probe_android; check_taoyao_android
      say "$(fill "$M_PHONE" model "${A_MODEL:-?}" rel "${A_REL:-?}" rom "$A_ROMLBL")"
      # (the system route after a pass 1 that may have written: the running kernel tells)
      [ "$1" = again ] && [ "$WROTE" = maybe ] && nr_p1_check
      if [ "$CMD" = install-recovery ]; then
        WAY=B; say "$M_WAY_B_FORCED"
      else
        root_check
        root_loop
        if [ -n "$HAVE_ROOT" ]; then a_install; fi
        if [ "$CMD" = install-system ]; then errm "$M_A_NEEDS_ROOT"; say "$M_ROOT_HOW"; finish $RC_FAIL; fi
        WAY=B
        # (the recovery's ADB has no root: not into it again but Q2, or the options)
        [ -z "$A_STOCKHY" ] && [ -z "$RNR" ] && say "$M_WAY_B_NOROOT"
      fi
      check_bl 0; check_slot; check_battery
      say "$(fill "$M_NOW_ON" release "${KR:-?}" ver "$ZVER")"
      # (after the system route: what the slot held before this run's pass)
      { [ "$1" = again ] && [ -n "$SUM_WAS" ]; } || SUM_WAS=$KR
      step_h 3 "старые копии разделов с телефона — на компьютер (0–2 мин)"
      pull_store "/sdcard/$BACKUP_NAME" 0
      [ "$PS_N" = 0 ] && say "$M_NONE_ON_PHONE"
      [ -n "$RNR" ] && nr_android_end
      # (the gate now, with the kernel and build the system reports: a
      # recovery that opens the internal storage (TWRP / OrangeFox) installs
      # in the very first pass after "adb reboot sideload")
      gate "$KR" "$FPR" "" phone "$A_RID"
      if [ -n "$A_STOCKHY" ]; then
        if ! prompt_yes "$M_STOCK_NOROOT" 1; then SUM_ON=1; SUM_WHAT="Ничего не записано."; NOFOOTER=1; finish $RC_FAIL; fi
        step_h 4 "переход в рекавери TWRP / OrangeFox (≈1 мин)"; H4=1
        b_from_android recovery H_TWRP_WAIT 0 M_MAYBE_XIAOMI_REC_W
      else
        step_h 4 "переход в режим установки Apply from ADB (≈1 мин и ваши нажатия)"; H4=1
        prompt_yes "$M_REBOOT_REC_ASK" 1 || { warn_phase; finish $RC_CANCEL; }
        b_from_android sideload H_ENTER_SIDELOAD 0
      fi;;
    recovery|sideload)
      WHERE=rec
      [ "$CMD" = install-system ] && fail "$M_A_NEEDS_SYSTEM"
      WAY=B; say "$M_WAY_B_REC"
      [ "$WSTATE" = sideload ] && b_wait_rec_start;;
  esac
  WAY=B
  b_install install
}

########################################################################
main() {
  parse_args "$@"
  if [ "$CMD" = help ]; then t_help; exit $RC_OK; fi
  if [ -z "$TTYOK" ]; then echo "$M_NEED_TTY" >&2; exit $RC_FAIL; fi
  build_mask
  [ -t 1 ] && printf '\033]0;%s\007' "$M_BANNER"
  echo
  step "$M_BANNER"
  say "$M_LICENSE1"
  say "$M_LICENSE2"
  # (keys pressed while nothing reads them are not echoed: every read here
  # is one silent key)
  STTYSAVE=$(stty -g </dev/tty 2>/dev/null) && stty -echo </dev/tty 2>/dev/null || STTYSAVE=
  pick_base
  open_log
  take_lock
  logl "platform: $(uname -sr 2>/dev/null), $(uname -m 2>/dev/null), bash $BASH_VERSION"
  logl "arguments: $*"
  say "$(fill "$M_FOLDER" path "$HERE")"
  detect_ziptool
  [ -n "$ZIPTOOL" ] || fail "$M_NO_UNZIP"
  case $CMD in
    menu|install|install-system|install-recovery|backup)
      if ! zip_search && [ "$CMD" != menu ]; then SUM_WHAT=; NOFOOTER=1; finish $RC_FAIL; fi;;
  esac
  [ "$CMD" = menu ] && menu
  case $CMD in
    install|install-system|install-recovery) install_flow;;
    backup) backup_flow;;
    restore-stock) restore_flow stock;;
    restore-prev) restore_flow prev;;
  esac
  finish $RC_OK
}

main "$@"
