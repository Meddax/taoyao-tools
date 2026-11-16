#!/system/bin/sh
# Сборщик логов MeruDevTools для Xiaomi Mi 12 Lite (taoyao), версия 0.20 (2026-11-14)
# SPDX-License-Identifier: LicenseRef-MeruDevTools
# © 2026 Meddax (meru_ii) и команда MeruDevTools. Лицензия: LICENSE.txt
#
# taoyao-check.sh: check and diagnostics of the taoyao 6.12 kernel, run on
# the phone as root. Everything it shows or writes for the user is Russian
# (UTF-8, no BOM; every non-ASCII character sits inside quotes or comments);
# file names, mode words, raw log contents and these comments are not.
#
# It only reads files, logs and properties. What it changes: its own files
# (/sdcard/taoyao-check*, /sdcard/taoyao-charge*, /data/local/tmp/taoyao-*),
# the logcat buffer sizes in "prep" (never cleared), and in "charge" a
# wakelock and marker lines in the kernel log. It never writes mixer
# controls, settings or properties. debugfs is read where it is mounted
# already; "mic" mounts it for the run (for the DAPM chain of the
# microphone), "deep" too (developer only: the QRTR name-server log, the UIM
# pins, clocks and regulators), and so does TAOYAO_DEBUGFS=1 in every mode
# (also through run-check; TAOYAO_DEBUGFS=0 never mounts it); it is
# unmounted again at the end only if this run mounted it. User builds that
# launched on Android 12 or later usually unmount debugfs after boot: outside
# "mic", "deep" (and TAOYAO_DEBUGFS=1) the deferred probes, wakeup sources and
# the other debugfs reads are then skipped, and the report says so.
#
# Start (as root):
#   from a PC: run-check.bat (Windows) / run-check.sh (Linux, macOS) push it
#   to /data/local/tmp and run it, or by hand:
#     adb push taoyao-check.sh /data/local/tmp/
#     adb shell "su -c 'sh /data/local/tmp/taoyao-check.sh [mode]'"
#   on the phone (Termux + su, or a root terminal app):
#     su, then  sh /sdcard/Download/taoyao-check.sh [mode]
#
# Modes (case-insensitive; a leading "--" is ignored):
#   (none)   the check: about 5 minutes on the phone (build 15: 289 s)
#   prep     saves this boot's kernel log as it is now (once per boot:
#            /data/local/tmp/taoyao-dmesg-early.txt, masked, boot_id on its
#            first line), enlarges the logcat buffers (main 32 MB, system
#            16 MB, radio 8 MB; nothing is cleared), stores a start mark (wall
#            time, uptime, boot_id: /data/local/tmp/taoyao-prep.txt) for
#            "logcat -T", starts a background kernel-log capture without
#            the FastRPC spam (64 MB at most, /data/local/tmp/taoyao-kmsg.txt,
#            its pid in taoyao-kmsg.pid; only that process tree is ever
#            stopped) and saves the media interrupt counts, then exits.
#            Reproduce the problem, then run the check: raw/logcat-since-
#            prep.txt, kmsg-follow.txt and the interrupt rises (section 19).
#   hotspot  watches 60 s instead of 10: turn the hotspot on at the prompt,
#            wait until it is on or has failed, turn it off again. A SoftAP
#            interface (wlan1) that disappears right after it was created is
#            an error. Wi-Fi logs more after: cmd wifi set-verbose-logging enabled
#   mic      watches 45 s: at the prompt the user records 10-15 s of speech
#            in a recorder app. Every second it samples the open capture
#            PCM substreams (state, hw_ptr: do frames flow), and the DAPM
#            widgets of the TX path if debugfs is mounted; once a capture is
#            running it reads the TX mixer controls (read only). Afterwards
#            section 13b: which PCM recorded, frames/s, where the TX chain
#            (front end - CDC DMA TX - AIF CAP - DEC MUX - SMIC MUX - ADC -
#            MIC BIAS) is off, the HAL's mixer paths against the controls,
#            the kernel and HAL lines of the window. Files: mic.txt, mic/.
#   deep     also reads every readable attribute under /sys/devices
#            (skipping self-tests, calibration, measurements, dumps, resets,
#            firmware, raw data and register access), so drivers that fail
#            or crash on a plain read show up: 100 files per head process
#            (a batch that takes 10 s or more is read again file by file, so
#            a file that blocks over 2 s is named),
#            the batch's list in /data/local/tmp/taoyao-check-lastread.txt and
#            a "taoyao-check deep: batch N <path>" line in the kernel log
#            every 5 batches (pstore keeps it over a crash). The report and
#            archive are written once before the sweep; a crash loses nothing
#            and the next run names the batch it stopped in. It mounts
#            debugfs for the run. Combines with hotspot or mic. Only when the
#            developer asks: 15-40 minutes, may reboot.
#   charge [minutes]
#            no checks: logs charging for that long (default 40, 1-1440) in
#            its own session, so USB can be unplugged right after the start.
#            It holds the wakelock taoyao-check-charge (it expires 5 minutes
#            after the planned end even if the logger is killed), follows the
#            kernel log (a "taoyao-check charge:" line marks every change of
#            usb/online), polls usb/online and pd_verifed every second and
#            samples battery, USB, PD, charge pump and thermal nodes every
#            10 s. At the end: /sdcard/taoyao-charge.txt and .tar.gz, and
#            /data/local/tmp/taoyao-charge-result.txt. Its pid is in
#            /data/local/tmp/taoyao-charge.pid while it runs (kill it to stop
#            early: the results are written then).
#   help     the Russian help.
#
# How a check (none, hotspot, mic, deep) runs: the foreground shell (the
# monitor) takes the lock /data/local/tmp/taoyao-check.lock (pid: the
# worker once it runs, before that the monitor; wpid: the worker; mpid: the
# monitor; dpid: the watchdog; mode, start, id, outdir, w, beat, dbgm; a
# second run while one is alive
# exits 4; a stale one is reported in the new report and its folder packed
# as prev-interrupted/), starts the worker in its own session
# (TAOYAO_WORKER=1, HUP ignored (PIPE too when it runs inline), output to
# /data/local/tmp/taoyao-check-run.log) and shows that log every second.
# A dropped adb connection or a closed pipe ends only the monitor; Ctrl-C
# in a phone terminal stops the worker, which packs what it has. The worker
# starts a watchdog (TAOYAO_WATCHDOG, own session): when the heartbeat
# (lock/beat, written by every section) is older than 180 s (deep: 600 s)
# or the run passes 20 minutes (deep: 60), it records the stuck child
# (cmdline, wchan, kernel stack), kills the worker and packs a partial
# archive. While a check runs, taoyao-check-hotspot.pid / taoyao-check-mic.pid
# hold the worker's pid in those modes (for older wrappers).
#
# Outputs: /sdcard/taoyao-check.tar.gz (send this) and taoyao-check.txt (the
# report: banner, kernel/phone line, ОШИБКА / ВНИМАНИЕ / ОК counts, notes,
# summary, results, details); the previous pair is renamed
# taoyao-check-previous.*. If /sdcard cannot be written or has less than
# 50 MB free: /data/local/tmp/taoyao-check-out/ (0755, files 0644, so adb
# pull works as shell). /data/local/tmp/taoyao-check-result.txt, one line,
# TAB-separated: ok|partial|fail, archive path, bytes, script version,
# time, reason, run id (taoyao-check-YYYYMMDD-HHMMSS). The archive also has
# summary.txt, raw/collectors.txt (every whole-system collector: seconds,
# exit code, bytes, cut), raw/timing.txt (uptime at each section), the
# hand-reading files (sim-timeline, fastrpc, audio-state, wifi-hotspot,
# sensors ...), dumpsys/, sys/, proc/, dropbox.txt, anr.txt, hal.txt,
# raw/avc-run.txt (the SELinux denials of the run's own time) and, with the
# KernelSU module taoyao_powerhint612 installed, hal/powerhint612-*.txt.
#
# Exit codes: 0 archive written; 1 archive partial or not written; 2 bad
# script file or usage; 3 not root; 4 another check is running; 5 no space
# (or /data/local/tmp not writable); 130 interrupted (partial archive).
#
# Bootstrap (the lines up to "fi #" below; each ends in " #", so a CR of a
# CRLF copy stays inside a comment): system PATH first (a Termux su keeps
# Termux's PATH and LD_PRELOAD), LC_ALL=C, a refusal when the script comes
# through stdin, the root check, then a copy without CR and BOM to
# /data/local/tmp/taoyao-check-run.sh (replaced only by rename, so a running
# copy keeps its file), checked for the last line "# конец taoyao-check.sh"
# (a cut download), and an exec of that copy under /system/bin/sh.
# Test hooks (PC harness only): TY_TMP, TY_SH, TY_PATH, TY_ASOUND,
# TY_ASOC, TY_MIXPATHS, TY_SYS (charge, deep), TY_KMSG, TY_WDLIM.
#
# What a check compares: the running kernel against what the installed ROM
# expects, so the same script works on stock HyperOS, crDroid and Evolution X:
# every device in its ueventd.rc files, every /sys, /proc and /dev path its
# init scripts write or chmod, every sysfs/proc path its SELinux policy labels
# (genfscon), its kernel module list, its vendor services, the cgroup
# controllers and task-profile attributes, the PCM ids of its
# audio_platform_info and the mixer controls of its mixer paths (if tinymix
# is installed). On top of that: the kernel log (panics, warnings, stalls,
# errors by subsystem, spam; the first WARNING's "cut here" block goes to
# raw/first-warning.txt), the previous boot's kernel log in pstore, crashes,
# SELinux denials, devicetree nodes without a driver, deferred probes, the
# qrtr.ko load order, remote processors, ION/FastRPC, the TEE and the GPU,
# audio, camera, display, input, sensors, battery, thermal, suspend, hung
# tasks, wakeup-source labels, CPU, memory, interrupt storms, modem and SIM,
# network, Wi-Fi and hotspot, the IPA UAPI layout (ipam.uapi_stock), USB,
# binder, the kernel configuration and every sysctl. Not taoyao, or not a
# 6.12 kernel: it runs anyway and says so; the port-only checks (qrtr.ko
# order, ipam/uapi_stock, ION heap count) then go to the details as
# "сравнение".
#
# Kernel build: from build 18 uname -r carries it (6.12.96-taoyao-v0.18);
# builds 15-17 all say 6.12.96-taoyao #1, so the build date of uname -v is
# looked up in KBUILDS (zip time of each CI build; the kernel is built in
# the 45 minutes before it).
#
# Developer notes (not printed): QCRIL logs the UIM card status only after
#   setprop persist.vendor.radio.adb_log_on 1   (and a reboot);
# the TFA98xx amplifiers log their per-stream trace only with
#   tfa98xx_dlkm.trace_level=1   (a load-time parameter);
# SukiSU's "AVC log spoofing" replaces the SELinux denials in the log.
# Suspend can only be tested unplugged: prep, unplug USB, screen off for 10
# minutes, plug in, run the check (section 18, kmsg-follow.txt).
#
# Privacy: serial numbers (also the panel's, msm_drm.cell_id), IMEI-like
# properties, the fingerprint sensor's and camera modules' chip IDs, the
# IPv6 address secret, MAC and IP addresses, e-mail addresses, host names
# and user@host (also the kernel's builder) are filtered out or masked; in
# logcat every line that can name a Wi-Fi network or carry its key is left
# out (also the package lists system_server writes in hash order, which
# would tell which apps the app<N> are) and every run of 11 or more digits is
# replaced, in the radio and
# telephony logs every run of 5 or more digits and every long hex string; in
# telephony dumps every line naming a number, card or cell. In every
# collected file, in one last pass before packing (scrub): every MAC address
# in full (also the WLAN driver's half-hidden aa:bb:cc:**:**:ff, and what is
# left of one in a corrupted saved log), the names the kernel's audit
# records write in hex (an app's thread: decoded and masked, else <hex>) and
# a user app's thread names in its audit records (<thread>), the cell
# identities (CID, LAC, TAC, PCI, PSC, (E/U/NR)ARFCN, channel numbers, BSIC:
# they locate the phone; the operator stays), the phone's serial number,
# saved Wi-Fi networks and hotspot name, quoted network names in Wi-Fi's log
# lines, device and Bluetooth names, paired Bluetooth device names, and the
# package names of the user's own apps: each one becomes app<N> (N from a
# list shuffled once per run, so one app is the same appN in every file of
# one archive, also in prev-interrupted/), also as its process name (the
# last 15 characters), its app zygote, its other java namespaces, the class
# after "appN/" (appN/cls), its distinctive words as whole words, and the
# NFC label, wake lock tag and USB accessory filter that system services
# write for it. The kernel's licence copies (kernel-license/) are not touched.
# Not masked: system and vendor packages and the well-known android,
# com.android, com.google, Xiaomi, Qualcomm and LineageOS ones, which the
# diagnosis needs. The list of real names stays in the owner-only scratch
# folder and is never packed.
# Tombstones (also the text ones in dropbox) stop before their memory dumps;
# fixed-name files in /data/local/tmp are removed before they are created
# (noclobber), so a planted link is not followed.
#
# ---- bootstrap: keep every line one command ending in " #" (and no empty line up to here) ----
TYTMP=${TY_TMP:-/data/local/tmp}; TYSH=${TY_SH:-/system/bin/sh}; TYTD=${TMPDIR:-} #
PATH=${TY_PATH:-/product/bin:/apex/com.android.runtime/bin:/system_ext/bin:/system/bin:/system/xbin:/odm/bin:/vendor/bin}; export PATH; unset LD_PRELOAD LD_LIBRARY_PATH TMPDIR ENV BASH_ENV; LC_ALL=C; export LC_ALL #
case "${0##*/}" in sh|mksh|bash|dash|ash|busybox|su|-*) echo "Скрипт нужно запускать файлом: sh /sdcard/Download/taoyao-check.sh (а не через «| sh» или «sh < файл»)."; exit 2;; esac #
if [ -z "$TAOYAO_RX" ]; then #
  case "$0" in /*) TYO=$0;; *) TYO=$PWD/$0;; esac #
  [ -r "$0" ] || { echo "Файл скрипта не читается: '$TYO'."; exit 2; } #
  TYH=; for a in "$@"; do case "${a#--}" in [Hh][Ee][Ll][Pp]|-[Hh][Ee][Ll][Pp]|[Hh]|-[Hh]|'-?'|'/?'|"справка"|"Справка"|"СПРАВКА") TYH=1;; esac; done #
  if [ -z "$TYH" ] && [ "$(id -u 2>/dev/null)" != 0 ]; then echo "Нужны права root."; echo "  В Termux: введите su, разрешите доступ в SukiSU / KernelSU / Magisk / APatch, затем:"; echo "    sh '$TYO' $*"; echo "  С компьютера используйте run-check.bat или run-check.sh: они сами запросят root для «Оболочки» (Shell)."; exit 3; fi #
  TYB=$(printf '\357\273\277'); [ -x "$TYSH" ] || TYSH=$(command -v sh) #
  if [ -n "$TYH" ]; then #
    TYCR=; { grep -q "$(printf '\r')" "$0" || head -c 3 "$0" | grep -q "^$TYB"; } 2>/dev/null && TYCR=1 #
    TYHC=; [ -n "$TYCR" ] && for d in "$TYTMP" "$TYTD" "$HOME"; do [ -n "$d" ] && [ -d "$d" ] && [ -w "$d" ] || continue; TYHC=$d/taoyao-check-help.$$.sh; rm -f "$TYHC" 2>/dev/null; { tr -d '\r' < "$0" | ( set -C; sed "1s/^$TYB//" > "$TYHC" ); } 2>/dev/null && [ -s "$TYHC" ] && break; rm -f "$TYHC" 2>/dev/null; TYHC=; done #
    [ -n "$TYHC" ] && { TAOYAO_RX=1 TAOYAO_SELF=$TYO "$TYSH" "$TYHC" "$@"; TYR=$?; rm -f "$TYHC"; exit $TYR; } #
    [ -n "$TYCR" ] && { echo "Сборщик логов MeruDevTools для Xiaomi Mi 12 Lite (taoyao), версия 0.$(sed -n 's/^TYVER=\([0-9]*\).*/\1/p' "$0" | head -n 1)"; echo "Режимы: без слова — обычная проверка; prep, hotspot, mic, deep (можно deep hotspot, deep mic), charge [минуты], help."; echo "Запуск (нужны права root): su, затем  sh /sdcard/Download/taoyao-check.sh [режим]"; echo "Полная справка не показана: файл сохранён с концами строк Windows. После su эта же команда покажет её."; exit 0; } #
  fi #
  if [ -z "$TYH" ]; then #
    TYP=$TYTMP/taoyao-check-run.sh.$$; rm -f "$TYP" 2>/dev/null #
    { tr -d '\r' < "$0" | ( set -C; sed "1s/^$TYB//" > "$TYP" ); } 2>/dev/null && [ -s "$TYP" ] && mv -f "$TYP" "$TYTMP/taoyao-check-run.sh" 2>/dev/null || { rm -f "$TYP" 2>/dev/null; echo "Не удалось записать файл в $TYTMP (память телефона заполнена?). Освободите место и запустите снова."; exit 5; } #
    tail -n 1 "$TYTMP/taoyao-check-run.sh" | grep -q '^# конец taoyao-check' || { echo "Файл скрипта неполный (скачан не до конца): скачайте taoyao-check.sh заново."; exit 2; } #
    TAOYAO_RX=1 TAOYAO_SELF=$TYO exec "$TYSH" "$TYTMP/taoyao-check-run.sh" "$@" #
  fi #
fi #
# ---- end of the bootstrap ----

# toybox grep reports "Binary file ... matches" instead of the lines when an
# invalid UTF-8 byte is near the start of its input (the oldest ring-buffer
# record, a pstore console after a crash): always text (toybox, busybox and
# GNU grep all take -a); the function reaches pipelines and $(...), not
# "timeout grep" or "sh -c" (those pass -a themselves)
grep() { command grep -a "$@"; }
NL='
'
[ -x "$TYSH" ] || TYSH=$(command -v sh)
TYVER=20; TYDATE=2026-11-14
TYNAME="Сборщик логов MeruDevTools для Xiaomi Mi 12 Lite (taoyao)"
TYBAN="$TYNAME, версия 0.$TYVER ($TYDATE)"
SELF=$0; ORIG=${TAOYAO_SELF:-$0}
# the SHA-256 of the copy that runs (without CR and BOM: the same as the
# published file), in the report's header and the summary
TYSHA=$(sha256sum "$SELF" 2>/dev/null | cut -d' ' -f1)
# the zip time of each CI build (UTC): its kernel was built up to 45 minutes before
KBUILDS='15:202611121910 16:202611122213 17:202611130143'

usage() { echo "Режимы: без слова — обычная проверка; prep, hotspot, mic, deep (можно deep hotspot, deep mic), charge [минуты], help."; }
showhelp() {
  cat <<EOF
$TYBAN

Запуск (нужны права root):
  с компьютера: run-check.bat (Windows) или bash run-check.sh (Linux, macOS) —
    они сами кладут скрипт в /data/local/tmp, запускают его и забирают архив;
  на телефоне (Termux или другой терминал с root): su, затем
    sh /sdcard/Download/taoyao-check.sh [режим]

Режимы:
  без слова        обычная проверка, около 5 минут
  prep             подготовка: сохранить журнал начала загрузки и включить запись
                   журнала ядра в фоне; потом повторите проблему и запустите
                   обычную проверку
  hotspot          проверка точки доступа: по подсказке «>>>» включите её, а когда
                   включится (или не включится) — выключите; около 6 минут
  mic              проверка микрофона: по подсказке «>>>» запишите 10–15 секунд
                   речи в «Диктофоне»; около 6 минут
  deep             глубокая проверка — только по просьбе разработчика: читает все
                   файлы /sys и может перезагрузить телефон; 15–40 минут.
                   Можно вместе: deep hotspot, deep mic
  charge [минуты]  журнал зарядки в фоне, по умолчанию 40 минут (от 1 до 1440);
                   USB после запуска можно отключить
  help             эта справка

Результат: /sdcard/taoyao-check.tar.gz — отправьте разработчику этот один файл
(отчёт для чтения — /sdcard/taoyao-check.txt; зарядка — /sdcard/taoyao-charge.tar.gz).
Номера, IMEI, имена сетей Wi-Fi и устройств, адреса и названия установленных
вами приложений в архиве скрыты (приложения — как app1, app2…).
EOF
}
PREP=; DEEP=; HS=; MIC=; CHG=; CHGM=; HELP=; prev=; MODES=
for a in "$@"; do
  a=$(printf '%s' "$a" | tr 'ABCDEFGHIJKLMNOPQRSTUVWXYZ' 'abcdefghijklmnopqrstuvwxyz'); a=${a#--}
  case "$a" in
    prep|deep|hotspot|mic|charge) ;;
    help|-h|h|-help|'-?'|'/?'|"справка"|"Справка"|"СПРАВКА") HELP=1; continue;;
    *[!0-9]*|'') echo "Непонятный параметр «$a»."; usage; exit 2;;
    *) if [ "$prev" = charge ] && [ -z "$CHGM" ]; then CHGM=$a; prev=$a; continue; fi
       echo "Число «$a» можно указать только сразу после charge (это минуты)."; usage; exit 2;;
  esac
  case "$a" in prep) PREP=1;; deep) DEEP=1;; hotspot) HS=1;; mic) MIC=1;; charge) CHG=1;; esac
  prev=$a
  case " $MODES " in *" $a "*) ;; *) MODES="${MODES:+$MODES }$a";; esac
done
if [ -n "$HELP" ]; then showhelp; exit 0; fi
if [ -n "$PREP" ] && [ "$MODES" != prep ]; then echo "prep запускается только отдельно: он лишь готовит журналы."; usage; exit 2; fi
if [ -n "$HS" ] && [ -n "$MIC" ]; then echo "hotspot и mic нельзя запускать вместе: запустите их по очереди."; usage; exit 2; fi
if [ -n "$CHG" ]; then
  if [ "$MODES" != charge ]; then echo "charge запускается только отдельно: он лишь записывает зарядку."; usage; exit 2; fi
  CHGM=${CHGM:-40}
  # (leading zeros: 08 would be octal in the shell's arithmetic)
  CHGM=$(echo "$CHGM" | sed 's/^0*//')
  if [ -z "$CHGM" ] || [ ${#CHGM} -gt 4 ] || [ "$CHGM" -gt 1440 ]; then echo "charge: число минут — от 1 до 1440."; usage; exit 2; fi
fi
if [ "$(id -u)" != 0 ]; then
  echo "Нужны права root."
  echo "  В Termux: введите su, разрешите доступ в SukiSU / KernelSU / Magisk / APatch, затем:"
  echo "    sh '$ORIG'${MODES:+ $MODES}${CHGM:+ $CHGM}"
  echo "  С компьютера используйте run-check.bat или run-check.sh: они сами запросят root для «Оболочки» (Shell)."
  exit 3
fi
WIN=10; [ -n "$HS" ] && WIN=60; [ -n "$MIC" ] && WIN=45
MODESTR=$MODES; [ -n "$MODESTR" ] || MODESTR="обычная проверка"

# (the masks come first: prep already writes a masked kernel log)
# MAC addresses (also BSSIDs and Bluetooth addresses) in full, also as the
# WLAN driver writes them half hidden (aa:**:**:**:bb:cc, aa:bb:cc:**:**:ff)
# and as other tools do (XX:XX:XX:XX:bb:cc): any six pairs of hex digits, *
# or x joined by colons; and what is left of one that a corrupted saved log
# (pstore after a crash) broke up: three or more pairs before ":**" (the
# vendor part of aa:bb:cc:**:"*:ff), two or more after "**:"
MAC='s/[0-9a-fA-F*xX]\{2\}\(:[0-9a-fA-F*xX]\{2\}\)\{5\}/xx:xx:xx:xx:xx:xx/g; s/[0-9a-fA-F]\{2\}\(:[0-9a-fA-F]\{2\}\)\{2,\}:\*\*/xx:xx:xx:**/g; s/\*\*\(:[0-9a-fA-F]\{2\}\)\{2,\}/**:xx:xx/g'
# cell identities (they locate the phone; mcc, mnc and the operator stay):
# Java (CellIdentityLte:{ mCi=... mPci=... mTac=... }, PhysicalChannelConfig's
# mPhysicalCellId and channel numbers), HIDL/AIDL
# (.cellIdentity = {.lte = {.ci = ..., .pci = ...}}) and key=value forms;
# twice, for fields one after another
CELLM='s/(m(Ci|Cid|Pci|Tac|Lac|Psc|Earfcn|Uarfcn|Arfcn|NrArfcn|Nrarfcn|Nci|Bsic|GlobalCellId|CellId|PhysicalCellId|ChannelNumber|DownlinkChannelNumber|UplinkChannelNumber|DownlinkFrequency|UplinkFrequency))=[^ ,;}]*/\1=N/g; s/(\.(ci|cid|pci|tac|lac|psc|earfcn|uarfcn|arfcn|nrarfcn|nci|bsic|cellId)) = -?[0-9]+/\1 = N/g; s/(^|[ ,{(;])(ci|cid|pci|tac|lac|psc|earfcn|uarfcn|arfcn|nrarfcn|nci|bsic|cellId|cellid|lteCellId)=(-?[0-9]+|0x[0-9a-fA-F]+)([^0-9a-fA-Fx:.]|$)/\1\2=N\4/g'
# properties left out (serial numbers, IMEI-like values, MAC addresses, the
# IPv6 address secret, the fingerprint sensor's and camera modules' chip IDs
# (fp.uid, fuseID), the adb Wi-Fi GUID (it carries the serial number), device
# and host names a user can set)
PRIV='serial|stable_secret|imei|meid|iccid|msisdn|imsi|cpuid|btaddr|bt_addr|bdaddr|wifimac|wlan.*mac|mac_addr|macaddr|\.psn|\.sn\]|ril\.oem\.|phone.number|ro\.boot\.hwc_sn|guid|uuid|fuseid|fp\.uid|device_name|hostname|adapter_?name|net\.bt\.name'
# androidboot.serialno and friends on the command line (msm_drm.cell_id: the
# panel's serial number)
CMDMASK='s/((serial|cpuid|imei|meid|sn|macaddr|mac|cell_id)[a-z_]*)=[^ ]*/\1=x/g'
# IP addresses (never collected): IPv6 with 3+ colons, IPv4
IPS='s/inet6 [0-9a-fA-F:]+/inet6 x/g; s/inet [0-9.]+/inet x/g; s/([0-9a-fA-F]{0,4}:){3,7}[0-9a-fA-F]{0,4}/ipv6/g; s/([0-9]{1,3}\.){3}[0-9]{1,3}/ipv4/g'
# host names (DHCP clients of the hotspot, tethering dumps)
HOSTM='s/([Hh]ost[Nn]ame[=:] *)[^ ,;)}]+/\1x/g'
# logcat: lines that can name a Wi-Fi network or carry its key are left out
# (wpa_supplicant and Wi-Fi write the network as "SSID", 'SSID' or in a
# config key "SSID"WPA_PSK); so are the package lists that system_server
# writes at boot in hash order (StorageManagerService "has / does not have
# legacy storage", PackageManager "No change is needed for package",
# SuspensionManager's list, and the backup journal, which also names removed
# apps): with the user's apps as app<N>, their places in such a list would
# tell which apps they are. E-mail addresses (accounts) and runs of 11 or more digits (IMEI,
# IMSI, ICCID, phone numbers) are masked
LDROP='ssid|passphrase|psk|password|configkey|id_str=|has legacy storage|have legacy storage|No change is needed for package|SuspensionManager: .*,|ProcessedPackagesJournal'
LMASK='s/[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}/<email>/g; s/([^0-9A-Za-z])[1-9][0-9]{10,}/\1N/g'
# the Wi-Fi network name in the WLAN driver's kernel log lines ("Connecting to
# <ssid> <bssid> rssi", "with <bssid> "<ssid>" is", "ssid:<ssid>"), the serial
# numbers of USB devices
KSSID='s/(Connecting to ).* ([^ ]+ rssi )/\1<ssid> \2/; s/( with [^ ]+ )".*"( is )/\1"<ssid>"\2/; s/([Ss][Ss][Ii][Dd][:=] ?)("[^"]*"|[^ ,]+)/\1<ssid>/g; s/(SerialNumber: ).*/\1x/'
# the builder of the kernel: "Linux version <rel> (<user>@<host>) ..." (a
# self-built kernel carries the builder's login and host)
KUH='s/(Linux version [^ ]+ \()[^)@ ]+@[^) ]+/\1x@x/'
# user@host in dumps (adb keys, shells, hosts) that the e-mail mask misses
USERHOST='s/(^|[^A-Za-z0-9._%+-])[A-Za-z0-9._-]+@[A-Za-z0-9][A-Za-z0-9-]*([^A-Za-z0-9.@:-]|$)/\1<user@host>\2/g'
# /proc/bootconfig: androidboot.serialno = "..." and friends
BOOTCFG='s/^([a-z0-9_.]*(serial|cpuid|imei|meid|sn|macaddr|mac|cell_id|oled_wp|wp_info)[a-z0-9_.]*) *= *.*/\1 = "x"/'
# telephony dumps: lines naming a number, a card identity or a cell are left out
TELDROP='number|msisdn|iccid|imsi|imei|meid|[^a-z]eid|cardstring|cardid|mcc.?mnc.?[0-9]{5}|cellidentity|cellinfo|mci=|[^a-z]ci=|tac=|lac=|cid=|nci=|pci=|bsic|psc=|latitude|longitude|location|address|e164|sip:|tel:|carrierid.*name|displayname|groupuuid'
# SoftAP interface names; FastRPC daemons (process names)
APIF='wlan[1-9]|ap[0-9]|swlan[0-9]|softap[0-9]'
RPCD='adsprpcd cdsprpcd audioadsprpcd sscrpcd'
# IP addresses in the kernel log: IPv4 not inside a version string
# (v5.2.1.153, apk-5.9.10.1; twice, for addresses one after another), IPv6
# after inet6/addr/v6 or shaped as a global, ULA or link-local address (not
# SCSI ids such as 0:0:0:1 or half-hidden MAC addresses)
KIP4='s/(^|[^0-9A-Za-z.-])([0-9]{1,3}\.){3}[0-9]{1,3}([^0-9A-Za-z.]|$)/\1ipv4\3/g'
KIP6='s/((inet6|addr|v6|ip6|ipv6|IPv6)[=: ]+)[0-9a-fA-F]{0,4}(:[0-9a-fA-F]{0,4}){2,7}/\1ipv6/g; s/(^|[^0-9A-Za-z:.])(2[0-9a-fA-F]{3}|[fF][cdeCDE][0-9a-fA-F]{2})(:[0-9a-fA-F]{0,4}){2,7}([^0-9A-Za-z:.]|$)/\1ipv6\4/g'
# kmask: kernel log filter: MAC addresses, the serial number and friends that
# the "Kernel command line:" line at boot carries, Wi-Fi network names, USB
# serial numbers, IP addresses and host names
kmask() { sed "$MAC" | sed -E "$CMDMASK; $KSSID; $KUH; $KIP4; $KIP4; $KIP6; $KIP6; $HOSTM"; }
# lmask: logcat filter (main, system, crash, events); nmask: network dumps
# (and phone numbers written with separators, +7 999 123-45-67, in the
# message after logcat's threadtime prefix)
PHONEAWK='{ p = ""; s = $0
  if (match(s, /^ *([0-9][0-9-]* +)?[0-9][0-9:.]* +[0-9]+ +[0-9]+ [VDIWEFS] [^:]*: /)) { p = substr(s, 1, RLENGTH); s = substr(s, RLENGTH + 1) }
  gsub(/\+?[0-9][0-9 ()-][0-9 ()-][0-9 ()-][0-9 ()-][0-9 ()-][0-9 ()-][0-9 ()-][0-9 ()-]+[0-9]/, "N", s); print p s }'
lmask() { grep -viE "$LDROP" | sed "$MAC" | sed -E "$IPS; $HOSTM; $LMASK; $USERHOST" | awk "$PHONEAWK"; }
nmask() { sed "$MAC" | sed -E "$IPS; $HOSTM"; }
# propmask: key=value files without the private keys; telmask: telephony
# dumps (lines with numbers, cards, cells out, then the radio mask)
propmask() { grep -viE "^[^=]*($PRIV)[^=]*=" | sed "$MAC"; }
telmask() { grep -viE "$TELDROP" | awk -f $MASKF | nmask; }
# btmask: bluetooth_manager without the HCI snoop summary, device names and
# the lines of calls and phone books (HFP numbers, CLCC, the PBAP owner); the
# text before or after a masked address in a device line is a name
btmask() {
  awk '/BTSNOOP_LOG_SUMMARY|BEGIN:BTSNOOP/ { skip = 1 } skip && /END:BTSNOOP|^--- END/ { skip = 0; next } !skip' |
    grep -viE 'name|alias|uuid|number|clcc|owner|phonebook|vcard' | sed "$MAC" |
    sed -E "$IPS; $HOSTM; $LMASK; $USERHOST" |
    sed -E 's/(xx:xx:xx:xx:xx:xx *\[[^]]*\]).*/\1 <name>/; s/([Dd]evice[^:]*: *)[^(]+ \((xx:xx:xx:xx:xx:xx)/\1<name> (\2/g'
}
# dmask: a dump of a system service: logcat's filter plus the user's app names
# (no phone-number pass: it would eat the number columns of the dumps' tables)
dmask() { grep -viE "$LDROP" | sed "$MAC" | sed -E "$IPS; $HOSTM; $LMASK; $USERHOST" | appmask; }

KMSG=/data/local/tmp/taoyao-kmsg.txt
# interrupt counts of the media blocks (video, camera CSID/IFE/ICP/CCI,
# SLIMbus): prep saves them here, the next run prints how much each rose
IRQP=/data/local/tmp/taoyao-irq-prep.txt
MEDIRQ='msm_vidc|csid|ife|[[:space:]]a5([[:space:]]|$)|cci|slim|GICv3 636[[:space:]]'
SPAM='fastrpc_buf_alloc: invalid allocation size|fastrpc_set_process_info'
# a remote processor (modem, ADSP, CDSP, WPSS) crashed or was restarted: what
# remoteproc_core.c and qcom_q6v5.c print then. Not "SSR" or "ramdump": every
# boot logs "IPA SSR support = True" (rmnet_ipa) and "SSR notifier registered"
# (adsprpc)
RPCRASH='crash detected in|handling crash #|fatal error|watchdog received|subsystem crashed|subsys-restart|Restart sequence requested'
# the kernel log saved early in this boot (by prep, or by a boot script that
# writes the same format: first line "# taoyao-dmesg-early boot_id=<id>
# uptime=<s>", then the masked kernel log): the 2 MB ring buffer keeps about
# an hour, so the boot's lines may be gone by the time the check runs
KEARLY=/data/local/tmp/taoyao-dmesg-early.txt
BOOTID=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)
# our files
TMPD=$TYTMP/taoyao-check-tmp
LOCK=$TYTMP/taoyao-check.lock
LOG=$TYTMP/taoyao-check-run.log
RESF=$TYTMP/taoyao-check-result.txt
HSPID=$TYTMP/taoyao-check-hotspot.pid
MICPID=$TYTMP/taoyao-check-mic.pid
KPID=$TYTMP/taoyao-kmsg.pid
PREPF=$TYTMP/taoyao-prep.txt
CHGPID=$TYTMP/taoyao-charge.pid
CHGRES=$TYTMP/taoyao-charge-result.txt
# the path the deep sweep is reading (left behind if the phone dies on it)
LAST=$TYTMP/taoyao-check-lastread.txt
# test hooks: sound card files, ASoC debugfs, the mixer paths file
ASND=${TY_ASOUND:-/proc/asound}
ASOC=${TY_ASOC:-/sys/kernel/debug/asoc}

# ---- helpers used by every part (monitor, worker, watchdog) ----
# wnew <file>: stdin into a new file with a fixed name in /data/local/tmp
# (uid shell can write there: an old file or a planted link is removed
# first, and noclobber does not follow one planted meanwhile)
wnew() { rm -f "$1" 2>/dev/null; ( set -C; cat > "$1" ) 2>/dev/null; }
# outdirok <dir>: the fallback folder as a real directory (not a link), 0755
outdirok() { [ -L "$1" ] && rm -f "$1"; mkdir -p "$1" 2>/dev/null && [ ! -L "$1" ] && chmod 755 "$1" 2>/dev/null; }
# appmask: the user's own app package names replaced by app<N> (the list and
# the awk program are written by the worker into TMPD: the watchdog's partial
# report uses them too; scrub does the same in its last pass over the files)
APPF=$TMPD/userapps.txt; APPAWK=$TMPD/appmask.awk; TECHW=$TMPD/techw.txt
appmask() { if [ -s $APPF ] && [ -s $APPAWK ]; then awk -v af=$APPF -v sp=$TMPD/sysapps.txt -v tw=$TECHW -f $APPAWK; else cat; fi; }
# result tags; tcount/tlist <tag>: count / list the report lines with it
TAG_E='[ОШИБКА]'; TAG_W='[ВНИМАНИЕ]'; TAG_O='[ОК]'
fail() { echo "$TAG_E $1: $2" >> $R; }
warn() { echo "$TAG_W $1: $2" >> $R; }
ok()   { echo "$TAG_O $1: $2" >> $R; }
tcount() { awk -v t="$1" 'index($0, t) == 1 { n++ } END { print n + 0 }' $R 2>/dev/null || echo 0; }
tlist()  { awk -v t="$1" 'index($0, t) == 1' $R 2>/dev/null; }
# kok/lok: an OK that rests on the kernel log / logcat: only when it was read
kok() { if [ "$KLOG" = 1 ]; then ok "$@"; else det "не проверено (журнал ядра не прочитан): $1: $2"; fi; }
lok() { if [ "$LLOG" = 1 ]; then ok "$@"; else det "не проверено (logcat не прочитан): $1: $2"; fi; }
# cmpn: a port-only check on another kernel or phone: details only
cmpn() { det "сравнение (не порт 6.12 на taoyao): $*"; }
# (mksh's echo expands backslash sequences: text with a backslash goes
# through printf)
det()  { case "$*" in *\\*) printf '%s\n' "$*";; *) echo "$*";; esac >> $DET; }
# heartbeat in the lock (the watchdog reads it): epoch|section no|name|HH:MM|uptime
beat() { echo "$(date +%s)|$SECN|${1:-$SECNAME}|$(date +%H:%M)|$(up)" > $LOCK/beat 2>/dev/null; }
# section header in the details, progress line, heartbeat, timing
SECN=0; SECNAME=
sec() {
  SECN=$((SECN + 1)); SECNAME=$1
  echo "" >> $DET; echo "################ $1" >> $DET
  echo "[$SECN/$SECT] $1…"
  beat "$1"
  echo "$(up) $1" >> $W/raw/timing.txt
}
# tomb <file> <lines>: a tombstone's header, abort message, registers and
# backtrace: it stops at the first memory or code dump, so what the crashed
# process had in memory, its open files and its log lines stay out
# (tombf: the same as a filter, for the text tombstones in dropbox)
TOMBEND='^ *(memory near |code around |memory map|open files:|--------- (tail end of |beginning of )?log )'
tomb() { awk -v n="$2" -v e="$TOMBEND" 'NR > n || $0 ~ e { exit } { print }' "$1"; }
tombf() { awk -v n="$1" -v e="$TOMBEND" 'NR > n || $0 ~ e { exit } { print }'; }
# tmo <seconds> <command...>: under timeout, with a KILL 5 s later where the
# timeout supports -k (a child stuck in the kernel still cannot be killed:
# the watchdog covers that)
# (no word splitting of a variable here: rdb and micsample call it with IFS set to a newline)
TMOK=; timeout -k 1 2 true 2>/dev/null && TMOK=1
tmo() { if [ -n "$TMOK" ]; then timeout -k 5 "$@"; else timeout "$@"; fi; }
# rd <file>: read a sysfs/proc file, at most 3 s
rd()   { timeout 3 cat "$1" 2>/dev/null; }
# exists <path-or-glob>: true if at least one match exists
exists() { for e in $1; do [ -e "$e" ] && return 0; done; return 1; }
# dsys <service> [args]: dumpsys through a file, never straight into a filter:
# a HAL that writes its dump into a pipe that grep -m or head has closed gets
# SIGPIPE and dies (grep -m1 on dumpsys media.camera killed the camera
# provider). Each dump is taken once per run (dumpsys -t 10: the service's
# own limit; 45 s in all) and then read from its file; a dump another job
# is taking (the background dumps) is waited for.
dsys() {
  dsf=$TMPD/dsys-$(echo "$*" | sed 's/[^A-Za-z0-9._]/_/g').txt
  if [ ! -f "$dsf" ]; then
    if mkdir "$dsf.lk" 2>/dev/null; then
      tmo 45 dumpsys -t 10 "$@" > "$dsf.part" 2>/dev/null; mv -f "$dsf.part" "$dsf"; rmdir "$dsf.lk" 2>/dev/null
    else
      dsw=0; while [ ! -f "$dsf" ] && [ -d "$dsf.lk" ] && [ $dsw -lt 120 ]; do sleep 0.5; dsw=$((dsw + 1)); done
    fi
  fi
  cat "$dsf" 2>/dev/null
}
# up: seconds since boot; pstart <pid>: start of a process in s since boot
# (/proc/<pid>/stat field 22); ns2s <ns>: ro.boottime.* ns as seconds
# (pstart2 and ns2s2 with two decimals, for the timeline)
up() { cut -d' ' -f1 /proc/uptime; }
HZ=$(getconf CLK_TCK 2>/dev/null); HZ=${HZ:-100}
pstart()  { [ -r /proc/$1/stat ] && sed 's/.*) //' /proc/$1/stat | awk -v hz=$HZ '{ printf "%.0f", $20 / hz }'; }
pstart2() { [ -r /proc/$1/stat ] && sed 's/.*) //' /proc/$1/stat | awk -v hz=$HZ '{ printf "%.2f", $20 / hz }'; }
ns2s()  { [ -n "$1" ] && awk -v n="$1" 'BEGIN { printf "%.0f", n / 1000000000 }'; }
ns2s2() { [ -n "$1" ] && awk -v n="$1" 'BEGIN { printf "%.2f", n / 1000000000 }'; }
# grab <file> <command>: run the command in a subshell (the functions above
# work there) and keep its stdout and stderr in <file> (not "r": in Android's
# mksh that is a built-in alias of fc -e -)
grab() { gf=$1; shift; beat; { printf '# %s\n' "$*"; ( eval "$*" ); } > "$W/$gf" 2>&1; }
# palive <pid>: one of our processes (running, not a zombie, our script)
palive() {
  [ -n "$1" ] && [ -d /proc/$1 ] && ! grep -q ') Z ' /proc/$1/stat 2>/dev/null &&
    tr '\0' ' ' 2>/dev/null < /proc/$1/cmdline | grep -q 'taoyao-check'
}
# dfk <path>: kB free on its file system
dfk() { df -k "$1" 2>/dev/null | awk 'NR > 1 && NF >= 4 { a = $(NF - 2) } END { print a + 0 }'; }
# mb <bytes>: megabytes, one decimal, with a comma
mb() { awk -v b="${1:-0}" 'BEGIN { s = sprintf("%.1f", b / 1048576); sub(/\./, ",", s); print s }'; }
# pl <n> <one> <few> <many>: "<n> <word>" in the Russian plural (1 вид, 2 вида, 5 видов)
pl() {
  pl_n=${1:-0}; pl_m=$((pl_n % 100)); pl_d=$((pl_n % 10))
  if [ $pl_m -ge 11 ] && [ $pl_m -le 14 ]; then pl_w=$4
  elif [ $pl_d = 1 ]; then pl_w=$2
  elif [ $pl_d -ge 2 ] && [ $pl_d -le 4 ]; then pl_w=$3
  else pl_w=$4; fi
  printf '%s %s' "$pl_n" "$pl_w"
}

# scrub: the last pass over every collected text file before it is packed
# (a sed for MAC addresses, one for cell identities and one awk per file, no
# fork per line): MAC addresses in full, cell identities, the phone's own
# names (the serial number, the Wi-Fi networks saved on it and its hotspot
# name, its device and Bluetooth names and the names of paired Bluetooth
# devices), any quoted text in the lines of Wi-Fi's services (a network name
# that is not saved on the phone) and the user's own apps (app<N>). The lists
# ($TMPD/scrub-list.txt, $TMPD/userapps.txt, made by the worker, owner-only)
# are never packed. Not touched: the kernel's licence copies (kernel-license/,
# byte for byte as the kernel has them); the kernel's config keeps its words.
# A file the pass fails on is not packed as it was: its text is replaced. A
# heartbeat every 20 files (many apps make the pass slow)
SECF=$TMPD/scrub-list.txt
SCRUBF=$TMPD/scrub.awk
WSSID='/(Wifi[A-Za-z]*|ClientModeImpl|SupplicantSta[A-Za-z]*|TelephonyCountryDetector)[^:]*: /s/"[^"]*"/"<ssid>"/g'
scrub() {
  [ -s $SCRUBF ] || return 0
  find $W -type f > $TMPD/scrub-files.txt 2>/dev/null
  sn=0
  while IFS= read -r sf; do
    case "$sf" in */kernel-license/*) continue;; *.txt|*/pstore/console-*|*/pstore/dmesg-*) ;; *) continue;; esac
    kwo=1; case "$sf" in */raw/config.txt) kwo=0;; esac
    sn=$((sn + 1)); [ -z "$CHG" ] && [ $((sn % 20)) = 1 ] && beat "запись архива: скрываю личные данные"
    { sed "$MAC" "$sf" | sed -E "$CELLM; $CELLM; $WSSID" | awk -v sf=$SECF -v af=$APPF -v sp=$TMPD/sysapps.txt -v tw=$TECHW -v kwo=$kwo -f $SCRUBF > "$sf.s" && mv -f "$sf.s" "$sf"; } ||
      { rm -f "$sf.s"; echo "(файл удалён из архива: не удалось скрыть в нём личные данные)" > "$sf"; }
  done < $TMPD/scrub-files.txt
}

# ---- the phone and the kernel ----
ID_DEV=$(getprop ro.product.vendor.device); [ -n "$ID_DEV" ] || ID_DEV=$(getprop ro.product.device)
ID_MODEL=$(getprop ro.product.model); ID_SKU=$(getprop ro.boot.product.hardware.sku)
ID_DTM=$(tr -d '\0' 2>/dev/null < /proc/device-tree/model)
ID_ROM=$(getprop ro.build.display.id); ID_AND=$(getprop ro.build.version.release)
DEVOK=
case "$ID_DEV" in taoyao) DEVOK=1;; esac
case "$ID_SKU" in taoyao*) DEVOK=1;; esac
case "$ID_DTM" in *taoyao*|*Taoyao*|*TAOYAO*) DEVOK=1;; esac
REL=$(uname -r)
KSER=$(printf '%s\n' "$REL" | sed -n 's/^\([0-9][0-9]*\.[0-9][0-9]*\).*/\1/p')
KVER=$(uname -v 2>/dev/null)
# the build date of uname -v ("#1 SMP PREEMPT Thu Nov 12 19:06:17 UTC 2026"):
# "DD.MM.YYYY HH:MM TZ;<build from KBUILDS>;<1: newer than this script>"
KINFO=$(awk -v v="$KVER" -v tb="$KBUILDS" -v td="$(echo $TYDATE | tr -d -)2359" '
  function leap(y) { return (y % 4 == 0 && (y % 100 != 0 || y % 400 == 0)) }
  function mins(y, mo, d, h, mi,   i, c) { c = 0; for (i = 2000; i < y; i++) c += leap(i) ? 366 : 365
    split("31 28 31 30 31 30 31 31 30 31 30 31", ml, " "); if (leap(y)) ml[2] = 29
    for (i = 1; i < mo; i++) c += ml[i]; return ((c + d - 1) * 24 + h) * 60 + mi }
  function st(s) { return mins(substr(s, 1, 4) + 0, substr(s, 5, 2) + 0, substr(s, 7, 2) + 0, substr(s, 9, 2) + 0, substr(s, 11, 2) + 0) }
  BEGIN { n = split(v, f, " ")
    for (i = 1; i + 3 <= n; i++) {
      if (f[i] !~ /^(Mon|Tue|Wed|Thu|Fri|Sat|Sun)$/) continue
      m = index("JanFebMarAprMayJunJulAugSepOctNovDec", f[i + 1]); if (!m || (m - 1) % 3) continue
      m = (m + 2) / 3; d = f[i + 2] + 0; if (split(f[i + 3], t, ":") < 2) continue
      y = ""; tz = ""; for (j = i + 4; j <= n && j <= i + 5; j++) { if (f[j] ~ /^[0-9][0-9][0-9][0-9]$/) y = f[j]; else if (y == "") tz = f[j] }
      if (y == "") continue
      km = mins(y + 0, m, d, t[1] + 0, t[2] + 0)
      b = ""; k = split(tb, e, " "); for (j = 1; j <= k; j++) { split(e[j], x, ":"); z = st(x[2]); if (km <= z && km >= z - 45) b = x[1] }
      printf "%02d.%02d.%d %02d:%02d%s;%s;%d\n", d, m, y, t[1], t[2], (tz == "" ? "" : " " tz), b, (b == "" && km > st(td)) ? 1 : 0; exit }
  }')
KDATE=${KINFO%%;*}; KBUILD=${KINFO#*;}; KNEWER=${KBUILD#*;}; KBUILD=${KBUILD%;*}
# (a build number in uname -r wins, and then only it says whether this
# script is older than the kernel: a build is made after the script it ships
# with; "#N" of uname -v counts local rebuilds, never a build number)
case "$REL" in *-v0.[0-9]*) kb=${REL##*-v0.}; kb=${kb%%[!0-9]*}; [ -n "$kb" ] && { KBUILD=$kb; KNEWER=0; };; esac
KLINE="Ядро: $REL, собрано ${KDATE:-?}, сборка ${KBUILD:+0.}${KBUILD:-неизвестна}"
PORT=; [ "$KSER" = 6.12 ] && [ -n "$DEVOK" ] && PORT=1
DEVNOTE=; [ -z "$DEVOK" ] && DEVNOTE="ВНИМАНИЕ: это не Xiaomi Mi 12 Lite (taoyao), а ${ID_MODEL:-?} (${ID_DEV:-?}): результаты не про ваш телефон."
KNOTE=; [ "$KSER" != 6.12 ] && KNOTE="Ядро $REL — не порт 6.12: запуск для сравнения (проверки порта — в подробностях как «сравнение»)."
KOLD=
if [ "$KNEWER" = 1 ] || { [ -n "$KBUILD" ] && [ "$KBUILD" -gt "$TYVER" ] 2>/dev/null; }; then KOLD="Сборщик логов 0.$TYVER вышел раньше этого ядра: если в папке с ядром (ссылка в теме) есть сборщик новее, возьмите его."; fi
PHLINE="Телефон: ${ID_MODEL:-?} (${ID_DEV:-?}); прошивка: ${ID_ROM:-?} (Android ${ID_AND:-?})"
# started from an app (Termux): the root shell stays in the app's cgroup,
# and Android's phantom-process killer may end it while the app is in the
# background
APPCTX=
grep -qE 'uid_1[0-9][0-9][0-9][0-9]' /proc/self/cgroup 2>/dev/null && APPCTX=1
ap=$$; ai=0
while [ $ai -lt 12 ] && [ "${ap:-1}" -gt 1 ] 2>/dev/null; do
  case "$(tr '\0' ' ' 2>/dev/null < /proc/$ap/cmdline)" in *com.termux*) APPCTX=1; break;; esac
  ap=$(sed 's/.*) //' /proc/$ap/stat 2>/dev/null | cut -d' ' -f2); ai=$((ai + 1))
done
appwarn() {
  [ -n "$APPCTX" ] || return 0
  echo "Запуск из приложения (Termux или другой терминал): не сворачивайте его и не выключайте экран до конца"
  echo "(Android может закрыть программу, которая работает в фоне). Чтобы Android не усыпил Termux: termux-wake-lock (экран всё равно не выключайте)."
  [ -n "$HS$MIC" ] && echo "В режиме $MODES вернитесь в терминал сразу после того, как сделаете то, что просит подсказка «>>>»."
  echo "Надёжнее запускать с компьютера: run-check.bat или run-check.sh."
}
# outpaths: report and archive in OUTDIR (/sdcard, else the fallback folder)
outpaths() { REPORT=$OUTDIR/taoyao-check.txt; OUT=$OUTDIR/taoyao-check.tar.gz; }
# lockalive: the run that holds the lock is alive (its worker, else its monitor)
lockalive() {
  la_p=$(cat $LOCK/wpid 2>/dev/null); [ -n "$la_p" ] || la_p=$(cat $LOCK/pid 2>/dev/null)
  palive "$la_p"
}
# busyexit: another run is alive: what it is, where its result goes, exit 4
busyexit() {
  bm=$(cat $LOCK/mode 2>/dev/null); bs=$(cat $LOCK/start 2>/dev/null); bo=$(cat $LOCK/outdir 2>/dev/null)
  bt=$(date -d @${bs:-0} +%H:%M 2>/dev/null)
  echo "Проверка уже идёт (с ${bt:-?}, режим: ${bm:-?}). Дождитесь её конца — результат будет в ${bo:-/sdcard}/taoyao-check.tar.gz."
  echo "Остановить её: su -c 'kill $la_p'"
  exit 4
}
# mkreport [note]: taoyao-check.txt in W from the results and details so far
mkreport() {
  NFAIL=$(tcount "$TAG_E"); NWARN=$(tcount "$TAG_W"); NOK=$(tcount "$TAG_O")
  {
    echo "$TYBAN"
    echo "$KLINE; $PHLINE; режим: $MODESTR; запуск: $N; sha256 скрипта: ${TYSHA:-?}"
    echo "ОШИБКА $NFAIL   ВНИМАНИЕ $NWARN   ОК $NOK"
    for mn in "$DEVNOTE" "$KNOTE" "$KOLD" "$PREVNOTE" "$1"; do [ -n "$mn" ] && echo "$mn"; done
    echo
    echo "################################ сводка"
    if [ -s $W/summary.txt ]; then appmask < $W/summary.txt; else echo "(сводка не записана: проверка не дошла до конца)"; fi
    echo
    echo "################################ результаты"
    { tlist "$TAG_E"; tlist "$TAG_W"; tlist "$TAG_O"; } | appmask
    echo
    echo "################################ подробности"
    [ -f "$DET" ] && appmask < $DET
  } > $W/taoyao-check.txt
}
# result <status> <archive> <bytes> <reason>: the one-line result file
result() {
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$TYVER" "$(date '+%Y-%m-%d %H:%M:%S')" "$4" "$N" | wnew $RESF.part &&
    mv -f $RESF.part $RESF && chmod 644 $RESF 2>/dev/null
}
# packout <ok|partial> <reason>: scrub, the report and the archive into
# OUTDIR, the result file; PKST (ok, partial or fail) and PKB (bytes)
packout() {
  scrub
  rm -f $OUT.part $REPORT.part
  cp $W/taoyao-check.txt $REPORT.part 2>/dev/null && mv -f $REPORT.part $REPORT
  if ( cd $TYTMP && tar -czf $OUT.part $N ) 2>/dev/null && mv -f $OUT.part $OUT; then
    PKST=$1; PKB=$(wc -c < $OUT); PKB=$((PKB + 0))
    [ "$OUTDIR" = /sdcard ] || chmod 644 $OUT $REPORT 2>/dev/null
  else
    rm -f $OUT.part; PKST=fail; PKB=0
  fi
  result "$PKST" "$OUT" "$PKB" "$2"
  [ "$PKST" != fail ]
}
# finalblock <status> <reason>: what to send, at the very end of the output
finalblock() {
  echo
  if [ "$1" = fail ]; then
    echo "===== Архив не создан: $2."
    echo "      Отправьте разработчику снимок экрана с этими строками (и, если есть, $REPORT). ====="
    return 0
  fi
  if [ "$1" = partial ]; then echo "===== НЕПОЛНЫЙ архив ($2). Отправьте разработчику этот файл: $OUT ($(mb $PKB) МБ)"
  else echo "===== ГОТОВО. Отправьте разработчику ОДИН файл: $OUT ($(mb $PKB) МБ)"; fi
  if [ -n "$TAOYAO_WRAPPER" ]; then echo "      run-check сам заберёт его на компьютер."
  elif [ "$OUTDIR" = /sdcard ]; then echo "      В проводнике телефона: Внутренняя память → taoyao-check.tar.gz."
  else echo "      Память /sdcard была недоступна, поэтому архив лежит в $OUTDIR; run-check заберёт его сам, а в Termux его можно скопировать: su -c 'cp $OUT /sdcard/Download/'"; fi
  [ -n "$PREVSEND" ] && echo "      Архив прошлого (не завершённого) запуска сохранён как taoyao-check-previous.tar.gz — отправьте и его."
  if grep -qF "$TAG_E установка:" $R 2>/dev/null; then echo "      Строки ОШИБКА и ВНИМАНИЕ — для разработчика; только ОШИБКА «установка» — для вас: в ней сказано, как вернуть прежнее ядро."
  else echo "      Строки ОШИБКА и ВНИМАНИЕ — для разработчика, делать ничего не нужно."; fi
  echo "      Номера, IMEI, имена Wi-Fi, адреса и названия ваших приложений в архиве скрыты. ====="
}
# wdpack <reason>: a partial report and archive of a worker that is gone or
# was stopped (by the watchdog or by its own INT/TERM trap); once per run
wdpack() {
  mkdir $LOCK/packing 2>/dev/null || return 1
  [ -d "$W" ] || { result fail "" 0 "$1"; finalblock fail "$1"; return 1; }
  [ -f "$R" ] || : > $R; [ -f "$DET" ] || : > $DET
  mkreport "НЕПОЛНЫЙ ОТЧЁТ: $1."
  packout partial "$1"
  echo; echo "ОШИБКА $NFAIL   ВНИМАНИЕ $NWARN   ОК $NOK"
  finalblock "$PKST" "$1"
}
# beatdesc: the section the run is in, from the heartbeat ("«16. ...», 12:41")
beatdesc() { awk -F'|' '{ printf "«%s», %s", $3, $4 }' "${1:-$LOCK/beat}" 2>/dev/null; }
# kids <pid> [skip]: every descendant of a process, deepest first, without
# <skip> and its own descendants (toybox timeout puts its command in a
# process group of its own, so a group kill misses it); killtree <pid>: TERM
# to the process and all its descendants
kids() {
  kd_r=$1; kd_x=${2:-0}
  for sp in /proc/[0-9]*/stat; do read -r sl 2>/dev/null < $sp || continue; set -- ${sl##*) }; echo "${sp#/proc/} $2"; done 2>/dev/null |
    sed 's|/stat||' | awk -v r="$kd_r" -v x="$kd_x" '{ pp[$1] = $2 } END { for (p in pp) { d = 0; q = p; while (q in pp && q != r && q != x && d < 20) { q = pp[q]; d++ } if (q == r && p != r) print d, p } }' |
    sort -rn | cut -d' ' -f2
}
killtree() { kt_l=$(kids "$1"); kill "$1" 2>/dev/null; for kt_p in $kt_l; do kill "$kt_p" 2>/dev/null; done; }
# stuckinfo <pid>: the deepest descendant of a process: "cmdline (wchan w)";
# its kernel stack goes to the details
stuckinfo() {
  for sp in /proc/[0-9]*/stat; do read -r sl 2>/dev/null < $sp || continue; set -- ${sl##*) }; echo "${sp#/proc/} $2" ; done 2>/dev/null |
    sed 's|/stat||' > $TMPD/ps.txt 2>/dev/null
  # (the deepest one that is not a zombie and has a command line: a finished
  # background job of the worker may still be listed)
  sd=; ss=
  for sp in $(awk -v r="$1" '{ pp[$1] = $2 } END { for (p in pp) { d = 0; q = p; while (q in pp && q != r && d < 20) { q = pp[q]; d++ } if (q == r) print d, p } }' $TMPD/ps.txt 2>/dev/null | sort -rn | cut -d' ' -f2); do
    grep -q ') Z ' /proc/$sp/stat 2>/dev/null && continue
    sc=$(tr '\0' ' ' 2>/dev/null < /proc/$sp/cmdline)
    [ -n "$sc" ] || continue
    # (our own subshells last: the command they wait for is what hangs)
    case "$sc" in *taoyao-check*) [ -n "$ss" ] || ss=$sp; continue;; esac
    sd=$sp; break
  done
  [ -n "$sd" ] || sd=$ss; [ -n "$sd" ] || sd=$1
  sc=$(tr '\0' ' ' 2>/dev/null < /proc/$sd/cmdline | cut -c1-120); sw=$(cat /proc/$sd/wchan 2>/dev/null)
  # (the file it has open in /sys or /proc: one head reads 100 files in deep)
  sf=; for sfd in /proc/$sd/fd/*; do sfl=$(readlink $sfd 2>/dev/null); case "$sfl" in /sys/*|/proc/*|${TY_SYS:-/sys}/*) sf=$sfl;; esac; done
  { echo "--- завис: pid $sd: $sc${sf:+, читает $sf} (wchan ${sw:--})"; timeout 3 cat /proc/$sd/stack 2>/dev/null | head -12; } >> $DET 2>/dev/null
  echo "${sc:-pid $sd}${sf:+, читает $sf} (wchan ${sw:--})"
}

# ---- the watchdog of a check (started by the worker, own session) ----
if [ -n "$TAOYAO_WATCHDOG" ]; then
  # (PIPE not ignored: an ignored signal is inherited by every command, and
  # each "cmd | head" would then print "write error: Broken pipe"; the
  # output goes to a file)
  trap '' HUP INT
  exec < /dev/null
  WP=$TAOYAO_WATCHDOG; echo $$ > $LOCK/dpid
  T=$(cat $LOCK/id 2>/dev/null); N=taoyao-check-$T; W=$TYTMP/$N
  OUTDIR=$(cat $LOCK/outdir 2>/dev/null); OUTDIR=${OUTDIR:-/sdcard}; outpaths
  R=$TMPD/report.txt; DET=$TMPD/details.txt
  PREVNOTE=$(cat $LOCK/prevnote 2>/dev/null)
  LIM=180; CAP=$((1200 + WIN)); [ -n "$DEEP" ] && { LIM=600; CAP=$((3600 + WIN)); }
  # (test hook: a shorter heartbeat limit for a PC harness)
  [ -n "$TY_WDLIM" ] && LIM=$TY_WDLIM
  S0=$(cat $LOCK/start 2>/dev/null); S0=${S0:-$(date +%s)}
  while :; do
    sleep 2
    [ "$(cat $LOCK/wpid 2>/dev/null)" = "$WP" ] || exit 0
    if ! palive "$WP"; then
      sleep 2
      [ "$(cat $LOCK/wpid 2>/dev/null)" = "$WP" ] || exit 0
      wdpack "проверка оборвалась на разделе $(beatdesc) (процесс завершён системой)"
      [ -f $LOCK/dbgm ] && umount /sys/kernel/debug 2>/dev/null
      rm -f $HSPID $MICPID; rm -rf $W $TMPD $LOCK
      exit 0
    fi
    now=$(date +%s); b=$(cut -d'|' -f1 $LOCK/beat 2>/dev/null); b=${b:-$S0}
    if [ $((now - b)) -gt $LIM ] || [ $((now - S0)) -gt $CAP ]; then
      if [ $((now - b)) -gt $LIM ]; then why="завис на разделе $(beatdesc): $(stuckinfo $WP)"
      else why="превышено время проверки ($(( (now - S0) / 60 )) мин), раздел $(beatdesc)"; fi
      echo "$why" > $LOCK/why
      echo; echo "Проверка не отвечает больше $LIM с — останавливаю её и записываю то, что собрано."
      wk=$(kids $WP $$)
      kill -s TERM -- -$WP 2>/dev/null; kill -s TERM $WP 2>/dev/null
      i=0; while palive "$WP" && [ $i -lt 15 ]; do sleep 1; i=$((i + 1)); done
      kill -s KILL -- -$WP 2>/dev/null; kill -s KILL $WP 2>/dev/null
      # (the worker's commands in process groups of their own)
      for p in $wk; do kill -s KILL $p 2>/dev/null; done
      sleep 1
      wdpack "$why"
      # (only a debugfs this run mounted)
      [ -f $LOCK/dbgm ] && umount /sys/kernel/debug 2>/dev/null
      rm -f $HSPID $MICPID; rm -rf $W $TMPD $LOCK
      exit 0
    fi
  done
fi

# ---- prep (foreground, short) ----
if [ -n "$PREP" ]; then
  echo "$TYBAN"
  echo "Подготовка (prep)."
  [ -n "$DEVNOTE" ] && echo "$DEVNOTE"
  lockalive && busyexit
  [ "$(dfk $TYTMP)" -ge 204800 ] || { echo "Память телефона заполнена: освободите хотя бы 200 МБ и запустите снова."; exit 5; }
  appwarn
  # the boot log first, before prep's capture (once per boot: a second prep
  # keeps the first save, which reaches further back)
  if [ -n "$BOOTID" ] && head -1 $KEARLY 2>/dev/null | grep -q "boot_id=$BOOTID "; then
    echo "Журнал ядра начала этой загрузки уже был сохранён раньше."
  else
    ( umask 077; { echo "# taoyao-dmesg-early boot_id=$BOOTID uptime=$(cut -d' ' -f1 /proc/uptime) "; tmo 30 dmesg 2>/dev/null | kmask; } | wnew $KEARLY.part ) && mv -f $KEARLY.part $KEARLY
    echo "Журнал ядра с начала загрузки (с $(sed -n '2s/^\[ *\([0-9]*\)\..*/\1/p' $KEARLY) с после включения) сохранён."
  fi
  # bigger buffers (nothing is cleared: the start mark below gives the
  # window since prep, logcat -T)
  logcat -G 16M 2>/dev/null
  logcat -b main -G 32M 2>/dev/null
  logcat -b radio -G 8M 2>/dev/null
  echo "$(date '+%m-%d %H:%M:%S.000')|$(up)|$BOOTID" | wnew $PREPF
  # our earlier capture only (its process group), never another dmesg -w
  op=$(cat $KPID 2>/dev/null)
  if [ -n "$op" ] && [ -d /proc/$op ] && tr '\0' ' ' 2>/dev/null < /proc/$op/cmdline | grep -q 'taoyao-kmsg'; then
    kill -s TERM -- -$op 2>/dev/null; kill -s TERM $op 2>/dev/null
  fi
  rm -f $KMSG $KPID
  setsid "$TYSH" -c "set -C; echo \$\$ > $KPID; trap '' HUP; dmesg -w | grep -avE '$SPAM' | head -c 67108864 > $KMSG # taoyao-kmsg" </dev/null >/dev/null 2>&1 &
  grep -E "$MEDIRQ" /proc/interrupts 2>/dev/null | wnew $IRQP
  sleep 1
  if [ -s $KPID ]; then echo "Готово: журнал ядра записывается в фоне, буферы logcat увеличены."
  else echo "Готово, но фоновая запись журнала ядра не запустилась (нет setsid?): проверка покажет только текущий журнал."; fi
  echo "Теперь повторите проблему на телефоне (включите звук, откройте камеру, отправьте SMS…)."
  if [ -n "$TAOYAO_WRAPPER" ]; then echo "Потом запустите обычную проверку (run-check, пункт 1)."
  else echo "Потом запустите обычную проверку: sh '$ORIG'"; fi
  exit 0
fi

# ---- charge: the launcher (the logger itself runs further below) ----
if [ -n "$CHG" ] && [ -z "$TAOYAO_CHARGE_BG" ]; then
  echo "$TYBAN"
  [ -n "$DEVNOTE" ] && echo "$DEVNOTE"
  op=$(cat $CHGPID 2>/dev/null)
  if [ -n "$op" ] && palive "$op" && tr '\0' ' ' 2>/dev/null < /proc/$op/cmdline | grep -q 'charge'; then
    echo "Журнал зарядки уже записывается (pid $op). Дождитесь его конца или остановите его: su -c 'kill $op'"
    exit 4
  fi
  [ "$(dfk $TYTMP)" -ge 102400 ] || { echo "Память телефона заполнена: освободите хотя бы 100 МБ и запустите снова."; exit 5; }
  OUTDIR=/sdcard
  { ( : > /sdcard/.taoyao-check-probe ) 2>/dev/null && rm -f /sdcard/.taoyao-check-probe && [ "$(dfk /sdcard)" -ge 51200 ]; } || { OUTDIR=$TYTMP/taoyao-check-out; outdirok $OUTDIR; }
  appwarn
  rm -f $CHGPID $CHGRES
  if ! command -v setsid > /dev/null 2>&1; then echo "Журнал зарядки не запустился: на телефоне нет команды setsid."; exit 1; fi
  TAOYAO_CHARGE_BG=1 TAOYAO_OUTDIR=$OUTDIR setsid "$TYSH" "$SELF" charge $CHGM < /dev/null > /dev/null 2>&1 &
  i=0
  while [ ! -s $CHGPID ] && [ $i -lt 20 ]; do sleep 0.5; i=$((i + 1)); done
  cp=$(cat $CHGPID 2>/dev/null)
  if [ -z "$cp" ]; then echo "Журнал зарядки не запустился."; exit 1; fi
  echo "Журнал зарядки записывается в фоне $CHGM мин, примерно до $(date -d @$(( $(date +%s) + CHGM * 60 )) +%H:%M 2>/dev/null)."
  echo "USB можно отключить сейчас; подключайте и отключайте зарядку, как нужно."
  if [ -n "$TAOYAO_WRAPPER" ]; then echo "Когда время выйдет, подключите телефон и заберите журнал: run-check charge-pull (пункт 6 меню)."
  else echo "Когда время выйдет, результат будет в $OUTDIR/taoyao-charge.tar.gz — отправьте этот файл разработчику."; fi
  echo "Остановить раньше (результат тоже запишется): su -c 'kill $cp'"
  exit 0
fi

# ---- a check: the monitor (foreground) ----
if [ -z "$CHG" ] && [ -z "$TAOYAO_WORKER" ]; then
  echo "$TYBAN"
  echo "Режим: $MODESTR. $KLINE."
  echo "$PHLINE."
  for mn in "$DEVNOTE" "$KNOTE" "$KOLD"; do [ -n "$mn" ] && echo "$mn"; done
  lockalive && busyexit
  op=$(cat $HSPID 2>/dev/null)
  if [ -n "$op" ] && [ ! -d $LOCK ] && palive "$op"; then la_p=$op; echo "Идёт проверка точки доступа, запущенная раньше."; busyexit; fi
  SPMIN=102400; [ -n "$DEEP" ] && SPMIN=204800
  [ "$(dfk $TYTMP)" -ge $SPMIN ] || { echo "Память телефона заполнена: освободите хотя бы $((SPMIN / 1024)) МБ и запустите снова."; exit 5; }
  OUTDIR=/sdcard; OUTNOTE=
  if ! { ( : > /sdcard/.taoyao-check-probe ) 2>/dev/null && rm -f /sdcard/.taoyao-check-probe && [ "$(dfk /sdcard)" -ge 51200 ]; }; then
    OUTDIR=$TYTMP/taoyao-check-out
    outdirok $OUTDIR
    OUTNOTE="Память /sdcard недоступна (телефон не разблокирован после включения?) или заполнена: результат будет в $OUTDIR."
    echo "$OUTNOTE"
  fi
  outpaths
  # the lock: one check at a time; a stale one (its run is dead) is taken
  # over: its note and its folder go into this run
  STALE=; i=0
  while ! mkdir $LOCK 2>/dev/null; do
    lockalive && busyexit
    i=$((i + 1)); [ $i -gt 5 ] && { echo "Не удалось занять $LOCK."; exit 4; }
    mv $LOCK $LOCK.stale.$$ 2>/dev/null && STALE=$LOCK.stale.$$
  done
  # (pid: the worker writes its own pid here once it runs; mpid stays the monitor)
  echo $$ > $LOCK/pid; echo $$ > $LOCK/mpid
  PREVNOTE=; PREVSEND=
  if [ -n "$STALE" ]; then
    PREVNOTE="Предыдущая проверка (режим: $(cat $STALE/mode 2>/dev/null)) не завершилась: она остановилась на разделе $(beatdesc $STALE/beat); возможно, телефон перезагрузился. Её файлы — в prev-interrupted/ этого архива."
    sw=$(cat $STALE/w 2>/dev/null); [ -n "$sw" ] && [ -d "$sw" ] && echo "$sw" > $LOCK/prevw
    echo "$PREVNOTE" > $LOCK/prevnote
    rm -rf $STALE
  fi
  rm -rf $LOCK.stale.* 2>/dev/null
  # the previous result (one generation); the pack of a deep run that did
  # not finish is the one to send as well
  [ -f $LAST ] && PREVSEND=1 && echo 1 > $LOCK/prevsend
  for x in tar.gz txt; do [ -f $OUTDIR/taoyao-check.$x ] && mv -f $OUTDIR/taoyao-check.$x $OUTDIR/taoyao-check-previous.$x; done
  # leftovers of earlier runs (only our own; a stale run's folder is kept for the worker)
  pw=$(cat $LOCK/prevw 2>/dev/null)
  # (the interrupted run's app list: its files in prev-interrupted/ keep
  # their app<N>, the worker puts it first in the new list)
  rm -f $TYTMP/taoyao-prev-userapps.txt
  [ -n "$pw" ] && [ -f $APPF ] && ( umask 077; mv -f $APPF $TYTMP/taoyao-prev-userapps.txt ) 2>/dev/null
  for x in $TYTMP/taoyao-check-2* $TYTMP/taoyao-diag-2* $TYTMP/taoyao-diag-tmp $TMPD $RESF $LOG; do
    [ -e "$x" ] || continue; [ "$x" = "$pw" ] && continue; rm -rf "$x"
  done
  T=$(date +%Y%m%d-%H%M%S); N=taoyao-check-$T
  echo "$MODESTR" > $LOCK/mode; date +%s > $LOCK/start; echo "$T" > $LOCK/id; echo "$OUTDIR" > $LOCK/outdir
  echo "Папка этого запуска: $N"
  case "$MODES" in
    *deep*) echo "Режим deep — только по просьбе разработчика: он читает все файлы /sys и может перезагрузить телефон; займёт 15–40 минут.";;
    *hotspot*|*mic*) echo "Займёт около 6 минут. Следуйте подсказкам, которые начинаются с «>>>». Не отключайте USB.";;
    *) echo "Займёт около 5 минут. Не отключайте USB и не трогайте телефон.";;
  esac
  appwarn
  ( umask 022; : | wnew $LOG )
  if command -v setsid > /dev/null 2>&1; then
    TAOYAO_WORKER=1 TAOYAO_RUNID=$T TAOYAO_OUTDIR=$OUTDIR setsid "$TYSH" "$SELF" $MODES < /dev/null >> $LOG 2>&1 &
    i=0; while { [ ! -s $LOCK/wpid ] || [ ! -s $LOCK/dpid ]; } && [ $i -lt 20 ]; do sleep 0.5; i=$((i + 1)); done
    WP=$(cat $LOCK/wpid 2>/dev/null); DP=$(cat $LOCK/dpid 2>/dev/null)
    if [ -z "$WP" ]; then
      echo "Проверка не запустилась в фоне:"; cat $LOG; rm -rf $LOCK; exit 1
    fi
    echo "Проверка идёт в фоне: если USB отключится, она продолжится сама."
    if [ -n "$TAOYAO_WRAPPER" ]; then echo "run-check сам дождётся конца и заберёт архив."
    else echo "Дождитесь строки «ГОТОВО» (Ctrl-C здесь остановит проверку; то, что собрано, запишется)."; fi
    echo
    # Ctrl-C in a phone terminal: stop the worker (it packs what it has); a
    # dropped adb connection or a closed pipe ends only this shell
    # (the worker's trap runs once its current command ends; one that takes
    # longer than 3 s is stopped with its whole process group)
    MI=; MIG=; MIT=0
    trap 'MI=1; MIT=$(date +%s); echo; echo "Останавливаю проверку — архив с тем, что уже собрано, будет записан…"; kill -s TERM $WP 2>/dev/null' INT
    n=0
    while :; do
      c=$(wc -l 2>/dev/null < $LOG); c=$((${c:-0} + 0))
      if [ "$c" -gt "$n" ]; then sed -n "$((n + 1)),${c}p" $LOG; n=$c; fi
      # (every descendant first, the watchdog's tree not: a command that
      # timeout put in a group of its own would outlive a group kill)
      if [ -n "$MI" ] && [ -z "$MIG" ] && [ $(( $(date +%s) - MIT )) -ge 3 ] && [ ! -d $LOCK/packing ]; then
        MIG=1; for p in $(kids $WP $DP); do kill -s TERM $p 2>/dev/null; done; kill -s TERM -- -$WP 2>/dev/null
      fi
      palive "$WP" || palive "$DP" || break
      sleep 1
    done
    sed -n "$((n + 1)),\$p" $LOG 2>/dev/null
    rm -f $LOG
    st=$(cut -f1 $RESF 2>/dev/null)
    [ -n "$MI" ] && exit 130
    case "$st" in ok) exit 0;; *) exit 1;; esac
  fi
  # no setsid: the check runs in this shell (a dropped adb connection then
  # ends it: HUP and PIPE are ignored, so it still writes its results)
  TAOYAO_WORKER=1; TAOYAO_RUNID=$T; TAOYAO_OUTDIR=$OUTDIR; TAOYAO_INLINE=1
fi

# ---- the worker of a check / the charge logger: folders ----
exec < /dev/null
if [ -n "$CHG" ]; then
  # the charge logger: its own folders (a check run meanwhile does not touch
  # them), and its output in its scratch folder (run-log.txt in the archive)
  trap '' HUP
  T=$(date +%Y%m%d-%H%M%S)
  N=taoyao-charge-$T
  W=$TYTMP/$N
  TMPD=$TYTMP/taoyao-charge-tmp
  SECF=$TMPD/scrub-list.txt; SCRUBF=$TMPD/scrub.awk
  OUTDIR=${TAOYAO_OUTDIR:-/sdcard}; RESF=$CHGRES
  REPORT=$OUTDIR/taoyao-charge.txt
  OUT=$OUTDIR/taoyao-charge.tar.gz
  rm -rf $TYTMP/taoyao-charge-2* $TMPD
  ( umask 077; mkdir -p $W $TMPD ) || exit 1
  echo $$ | wnew $CHGPID
  exec > $TMPD/run.log 2>&1
else
  # (the setsid worker writes into a file: PIPE stays default for its
  # commands; run inline, its output is the adb pipe that a drop closes)
  trap '' HUP; [ -n "$TAOYAO_INLINE" ] && trap '' PIPE
  T=${TAOYAO_RUNID:-$(date +%Y%m%d-%H%M%S)}
  OUTDIR=${TAOYAO_OUTDIR:-/sdcard}; outpaths
  N=taoyao-check-$T
  W=$TYTMP/$N
  [ -d $LOCK ] || { mkdir $LOCK 2>/dev/null; echo "$T" > $LOCK/id; date +%s > $LOCK/start; echo "$OUTDIR" > $LOCK/outdir; echo "$MODESTR" > $LOCK/mode; }
  # (pid too: older wrappers and "kill <pid>" reach the worker, not the
  # monitor that a dropped adb connection ends)
  echo $$ > $LOCK/wpid; echo $$ > $LOCK/pid; echo "$W" > $LOCK/w
  [ -n "$HS" ] && echo $$ | wnew $HSPID
  [ -n "$MIC" ] && echo $$ | wnew $MICPID
  PREVNOTE=$(cat $LOCK/prevnote 2>/dev/null); PREVSEND=$(cat $LOCK/prevsend 2>/dev/null)
  ( umask 077; mkdir -p $TMPD ) && mkdir -p $W/raw $W/pstore || { echo "Не удалось создать $W."; result fail "" 0 "нет места в $TYTMP"; rm -rf $LOCK; exit 5; }
  pw=$(cat $LOCK/prevw 2>/dev/null)
  [ -n "$pw" ] && [ -d "$pw" ] && mv "$pw" $W/prev-interrupted 2>/dev/null
  R=$TMPD/report.txt
  DET=$TMPD/details.txt
  : > $R; : > $DET
  # sections in this run (the progress line [k/n])
  SECT=34; [ -n "$MIC" ] && SECT=$((SECT + 1)); [ -n "$DEEP" ] && SECT=$((SECT + 1))
  # the watchdog
  if command -v setsid > /dev/null 2>&1; then
    TAOYAO_WORKER= TAOYAO_WATCHDOG=$$ setsid "$TYSH" "$SELF" $MODES < /dev/null >> $LOG 2>&1 &
  else
    ( trap '' HUP; TAOYAO_WORKER= TAOYAO_WATCHDOG=$$ exec "$TYSH" "$SELF" $MODES ) < /dev/null >> $LOG 2>&1 &
  fi
  # the end, however it comes: our pid files and the lock (if still ours)
  trap 'wexit' EXIT
  trap 'wint' INT TERM
fi
# wexit: the worker's end (also after wint): children, pid files, the lock
wexit() {
  [ -n "$IPM" ] && kill $IPM 2>/dev/null
  [ -n "$MSP" ] && kill $MSP 2>/dev/null
  [ -n "$BGD" ] && killtree $BGD
  [ -n "$DBGM" ] && umount /sys/kernel/debug 2>/dev/null
  [ -n "$TAOYAO_INLINE" ] && rm -f $LOG
  [ "$(cat $HSPID 2>/dev/null)" = $$ ] && rm -f $HSPID
  [ "$(cat $MICPID 2>/dev/null)" = $$ ] && rm -f $MICPID
  if [ "$(cat $LOCK/wpid 2>/dev/null)" = $$ ]; then rm -rf $TMPD; rm -rf $LOCK; fi
}
# wint: INT or TERM (Ctrl-C in a phone terminal through the monitor, or the
# watchdog): pack what there is, with the reason
wint() {
  trap '' INT TERM
  # (the background dumps first, while their commands are still their
  # descendants: once a timeout is gone, its command belongs to init)
  [ -n "$BGD" ] && killtree $BGD
  [ -n "$IPM" ] && kill $IPM 2>/dev/null
  [ -n "$MSP" ] && kill $MSP 2>/dev/null
  why=$(cat $LOCK/why 2>/dev/null); [ -n "$why" ] || why="прервано на разделе «$SECNAME»"
  rm -f $LAST
  if [ -n "$PACKED" ]; then
    echo; echo "Глубокая проверка прервана: отчёт и архив, записанные перед ней, остались ($OUT)."
    result partial "$OUT" "$(wc -c 2>/dev/null < $OUT)" "$why (до глубокой проверки)"
  elif wdpack "$why"; then :; fi
  [ -d "$W" ] && [ -d $LOCK/packing ] && rm -rf $W
  exit 130
}
# privacy filter for the radio and telephony log: keeps the prefix (time, pid,
# tid, level, tag); in the message masks long hex strings (ICCID, ATR, EID),
# phone numbers written with separators and every run of 5+ digits
MASKF=$TMPD/mask.awk
cat > $MASKF <<'EOF'
{
  p = ""; s = $0
  if (match(s, /^ *([0-9][0-9-]* +)?[0-9][0-9:.]* +[0-9]+ +[0-9]+ [VDIWEFS] [^:]*: /)) {
    p = substr(s, 1, RLENGTH); s = substr(s, RLENGTH + 1)
  }
  gsub(/[0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f]+/, "H", s)
  gsub(/\+?[0-9][0-9 ()-][0-9 ()-][0-9 ()-][0-9 ()-][0-9 ()-][0-9 ()-][0-9 ()-][0-9 ()-]+[0-9]/, "N", s)
  gsub(/[0-9][0-9][0-9][0-9][0-9]+/, "N", s)
  print p s
}
EOF
# scrub: the phone's own names, replaced in every collected text file before
# it is packed (pack): the serial number, the Wi-Fi networks saved on it and
# its hotspot name (the WLAN driver and Wi-Fi log them), its device and
# Bluetooth names and the names of paired Bluetooth devices, longest first (a
# short name inside a longer one would otherwise leave the rest of it). The
# list stays in $TMPD (owner-only, removed at the end) and is never packed.
SECF=$TMPD/scrub-list.txt
SCRUBF=$TMPD/scrub.awk
( umask 077
  { getprop ro.serialno; getprop ro.boot.serialno
    timeout 10 settings get global device_name; timeout 10 settings get secure bluetooth_name
    sed -n 's/^Name = //p' /data/misc/bluedroid/bt_config.conf
    for f in /data/misc/apexdata/com.android.wifi/*.xml /data/misc_ce/0/apexdata/com.android.wifi/*.xml /data/misc/wifi/*.xml; do
      [ -f "$f" ] && sed -nE 's/.*<string name="(SSID|WifiSsid)">(.*)<\/string>.*/\2/p' "$f"
    done | sed -e 's/&quot;/"/g; s/&apos;/'"'"'/g; s/&lt;/</g; s/&gt;/>/g; s/&amp;/\&/g' -e 's/^"\(.*\)"$/\1/'
  } 2>/dev/null | sort -u | awk '{ print length($0) "\t" $0 }' | sort -rn | cut -f2- > $SECF )
# the user's own apps: third-party packages (pm list packages -3, else cmd
# package), plus the apps in /data/app that are not system apps (pm list
# packages -s: also those of other users and work profiles; all of them if pm
# does not answer), without the well-known families the diagnosis needs
# (android, com.android, com.google, Xiaomi, Qualcomm, CodeAurora,
# LineageOS). Shuffled once: the line number is the N of app<N> (the same app
# is the same appN in every file of this archive, and N says nothing about
# the name). After an interrupted run, its list comes first (the monitor kept
# it: its files in prev-interrupted/ keep their numbers). Owner-only, never
# packed; set again here: the charge logger has its own TMPD. The system
# packages stay in sysapps.txt (the words that are no app's own, below).
APPF=$TMPD/userapps.txt
APPAWK=$TMPD/appmask.awk
SYSAPPF=$TMPD/sysapps.txt; TECHW=$TMPD/techw.txt
( umask 077
  tmo 20 pm list packages -3 2>/dev/null | sed -n 's/^package://p' > $TMPD/apps-3.txt
  [ -s $TMPD/apps-3.txt ] || tmo 20 cmd package list packages -3 2>/dev/null | sed -n 's/^package://p' > $TMPD/apps-3.txt
  tmo 20 pm list packages -s 2>/dev/null | sed -n 's/^package://p' > $TMPD/apps-s.txt
  [ -s $TMPD/apps-s.txt ] || tmo 20 cmd package list packages -s 2>/dev/null | sed -n 's/^package://p' > $TMPD/apps-s.txt
  # (/data/app/~~<id>/<package>-<id>/, older /data/app/<package>-<n>/; directories only)
  ls -d /data/app/*/*/ /data/app/*/ 2>/dev/null | sed 's|/$||; s|.*/||; s/-.*//' > $TMPD/apps-d.txt
  awk -v sf=$TMPD/apps-s.txt 'BEGIN { while ((getline l < sf) > 0) { sys[l] = 1; ns++ } }
    FILENAME ~ /apps-d\.txt$/ && ns && ($0 in sys) { next }
    /^(android|com\.android|com\.google|com\.xiaomi|com\.miui|com\.mi|com\.qualcomm|com\.qti|vendor\.qti|org\.codeaurora|org\.lineageos)(\.|$)/ { next }
    /^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z0-9_]+)+$/ && !/^vmdl/ && !seen[$0]++' $TMPD/apps-3.txt $TMPD/apps-d.txt |
    awk 'BEGIN { srand() } { printf "%d\t%s\n", rand() * 1000000, $0 }' | sort -n | cut -f2- > $TMPD/apps-new.txt
  PAPPF=$TYTMP/taoyao-prev-userapps.txt
  { [ -z "$CHG" ] && [ -f $PAPPF ] && [ ! -L $PAPPF ] && cat $PAPPF; cat $TMPD/apps-new.txt; } | awk 'NF && !seen[$0]++' > $APPF
  [ -z "$CHG" ] && rm -f $PAPPF
  mv -f $TMPD/apps-s.txt $SYSAPPF; rm -f $TMPD/apps-3.txt $TMPD/apps-d.txt $TMPD/apps-new.txt )
# the app masking (appmask, and scrub's last pass): every dotted name that is
# a user package (ua), or one followed by ".<more>", its java namespace (the
# first two parts of a package of 3 or more, when no system package uses that
# namespace: ux), its process name in the kernel and in logcat tags (Android
# keeps the LAST 15 characters of a longer name: t15, a dot-less one as a
# word; also the first 15: u15) or its app zygote (<package>_zygote) becomes
# app<N>; a system package (spk) and the names under it never do. After appN a
# "/<class>" (a component name) becomes "/cls". Then, in any case and as a
# whole word (also after "lib" and at a camelCase step: libwhatsapp.so,
# WhatsAppService), the distinctive words of the user's packages (kw: a part
# after the first, of 6 or more letters, that is in no system package's name,
# no common or technical word (the stop list; tw: the words found in the
# kernel's config and modules and in the HAL manifests) and not ours): the
# label "WhatsApp" (sp: the system packages, pm list packages -s). dumpw=1
# prints the candidate words and stops (to build tw); kwo=0 leaves the words
# out (the kernel's config)
cat > $TMPD/appcore.awk <<'EOF'
function tail15(p,   q) { q = substr(p, length(p) - 14); sub(/^[^A-Za-z]+/, "", q); return q }
function addkw(w, a,   k, x) {
  kw[w] = a; kl[++nk] = w
  for (k = nk; k > 1 && length(kl[k]) > length(kl[k - 1]); k--) { x = kl[k]; kl[k] = kl[k - 1]; kl[k - 1] = x }
}
BEGIN {
  na = 0
  while ((getline l < af) > 0) { if (l == "" || (l in ua)) continue; na++; ua[l] = "app" na; ord[na] = l }
  close(af)
  # (the system packages: spk, their namespaces, their first and last 15
  # characters, and their parts in one string)
  sys = " "
  if (na && sp != "") {
    while ((getline l < sp) > 0) {
      if (l == "") continue
      spk[l] = 1; n2 = split(l, pc, "."); if (n2 >= 3) sysns[pc[1] "." pc[2]] = 1
      if (length(l) > 15) { st15[tail15(l)] = 1; q = substr(l, 1, 15); sub(/\.$/, "", q); sf15[q] = 1 }
      n2 = split(tolower(l), pc, "."); for (j = 1; j <= n2; j++) sys = sys pc[j] " "
    }
    close(sp)
  }
  # (fl: a part every masked name contains, its java namespace or else its
  # first 15 characters, and its last 15: a line without one is passed on as
  # it is; index(), not a regex: BWK awk is slow on long alternations)
  nf = 0
  for (i = 1; i <= na; i++) {
    p = ord[i]
    if (length(p) > 15) {
      q = substr(p, 1, 15); sub(/\.$/, "", q); if (!(q in u15) && !(q in sf15) && !(q in spk)) u15[q] = ua[p]
      q = tail15(p)
      if (q != "" && !(q in st15) && !(q in spk) && !(q in ua)) {
        if (index(q, ".")) { if (!(q in t15)) t15[q] = ua[p]; if (!(q in fs)) { fs[q] = 1; fl[++nf] = q } }
        else if (length(q) >= 6) tl[tolower(q)] = ua[p]
      }
    }
    if (split(p, pc, ".") >= 3) { q = pc[1] "." pc[2]; if (!(q in ua) && !(q in ux) && !(q in sysns) && !(q in spk)) ux[q] = ua[p] }
    else { q = p; if (length(q) > 15) { q = substr(q, 1, 15); sub(/\.$/, "", q) } }
    if (!(q in fs)) { fs[q] = 1; fl[++nf] = q }
  }
  n2 = split("android mobile messenger client google launcher service services manager player camera gallery browser viewer editor reader market provider plugin widget widgets wallpaper keyboard dialer contacts messaging message messages calendar weather settings system update updater backup social premium official online offline studio helper center security secret private public shared common default sample example simple assistant network wireless bluetooth display screen battery sensor sensors stream record recorder scanner cleaner remote control monitor tracker wallet payment express delivery shopping travel navigation driver compass flashlight calculator converter unlock locker beauty selfie filter sticker stickers ringtone podcast translate dictionary health fitness notification notifications download downloader install installer account accounts storage memory thermal kernel module xiaomi qualcomm lineage overlay theme themes launch native webview chrome firefox application applications another chance follow matrix vector finance community global github gitlab notify charging charger reboot recovery privileged telephony tethering hotspot vibrator haptic package packages content external internal vendor product config configuration framework runtime process worker channel bridge engine loader access secure privacy permission photos picture pictures gallery documents document explorer office internet window windows status search store gaming games dialog lockscreen device devices connect connection server proxy cloud location audio video media radio modem touch sound voice speech tools toolbox utility utils debug release kernelsu ksunext sukisu magisk apatch wireguard dropbox chromium termux shizuku lsposed xposed meddax meru_ii merudevtools taoyao", st, " ")
  for (j = 1; j <= n2; j++) sw[st[j]] = 1
  if (tw != "") { while ((getline l < tw) > 0) tech[l] = 1; close(tw) }
  # (kl: the words, longest first: one inside another is replaced as the longer)
  nk = 0
  for (i = 1; i <= na; i++) {
    n2 = split(tolower(ord[i]), pc, ".")
    for (j = 2; j <= n2; j++) {
      w = pc[j]
      if (length(w) < 6 || w !~ /^[a-z][a-z0-9_]*$/ || (w in sw) || (w in kw) || (w in tech) || index(sys, w)) continue
      addkw(w, ua[ord[i]])
    }
  }
  if (dumpw) { for (i = 1; i <= nk; i++) print kl[i]; exit }
  for (w in tl) if (!(w in kw)) addkw(w, tl[w])
}
# wb: the word at p..q-1 of s (l: s in lower case) stands alone: before it the
# start, a character that is no letter or digit, "lib", or a step from a small
# letter or digit to a capital; after it the end, no letter or digit, or a
# capital after a small letter or digit
function wb(s, l, p, q) {
  if (p > 1 && substr(l, p - 1, 1) ~ /[a-z0-9]/ && !(p > 3 && substr(l, p - 3, 3) == "lib") && !(substr(s, p, 1) ~ /[A-Z]/ && substr(s, p - 1, 1) ~ /[a-z0-9]/)) return 0
  if (substr(l, q, 1) ~ /[a-z0-9]/ && !(substr(s, q, 1) ~ /[A-Z]/ && substr(s, q - 1, 1) ~ /[a-z0-9]/)) return 0
  return 1
}
function kmask(s,   l, o, ol, i, w, p, q, h) {
  if (!nk || kwo == "0") return s
  l = tolower(s); h = 0
  for (i = 1; i <= nk; i++) if (index(l, kl[i])) { h = 1; break }
  if (!h) return s
  for (i = 1; i <= nk; i++) {
    w = kl[i]; if (!index(l, w)) continue
    o = ""; ol = ""
    while ((p = index(l, w)) > 0) {
      q = p + length(w)
      if (wb(s, l, p, q)) { o = o substr(s, 1, p - 1) kw[w]; ol = ol substr(l, 1, p - 1) kw[w] }
      else { o = o substr(s, 1, q - 1); ol = ol substr(l, 1, q - 1) }
      s = substr(s, q); l = substr(l, q)
    }
    s = o s; l = ol l
  }
  return s
}
function ahit(t,   r, q) {
  if (t in ua) return ua[t]
  if (t in spk) return ""
  if (t in ux) return ux[t]
  q = t; if (sub(/_zygote$/, "", q) && (q in ua)) return ua[q]
  if (t in u15) return u15[t]
  if (t in t15) return t15[t]
  r = t
  while (sub(/\.[^.]*$/, "", r) && index(r, ".")) { if (r in ua) return ua[r]; if (r in spk) return ""; if (r in ux) return ux[r] }
  return ""
}
function amask(s,   o, t, h, i) {
  h = 0; for (i = 1; i <= nf; i++) if (index(s, fl[i])) { h = 1; break }
  if (!h) return kmask(s)
  o = ""
  while (match(s, /[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z0-9_]+)+/)) {
    t = substr(s, RSTART, RLENGTH); o = o substr(s, 1, RSTART - 1); s = substr(s, RSTART + RLENGTH)
    h = ahit(t)
    if (h != "") {
      t = h
      if (substr(s, 1, 1) == "/" && match(s, /^\/[A-Za-z0-9_.]*\.[A-Z][A-Za-z0-9_$]*/)) { t = t "/cls"; s = substr(s, RLENGTH + 1) }
    }
    o = o t
  }
  return kmask(o s)
}
EOF
{ cat $TMPD/appcore.awk; echo '{ print amask($0) }'; } > $APPAWK
# the technical words (tw): the candidate words of the user's packages that
# the kernel's config, its modules or the HAL manifests contain
( umask 077; : > $TECHW
  awk -v af=$APPF -v sp=$SYSAPPF -v dumpw=1 -f $TMPD/appcore.awk > $TMPD/appwords.txt 2>/dev/null
  if [ -s $TMPD/appwords.txt ]; then
    { tmo 10 zcat /proc/config.gz; cut -d' ' -f1 /proc/modules
      cat /system/etc/vintf/*.xml /system/etc/vintf/manifest/*.xml /system_ext/etc/vintf/*.xml /vendor/etc/vintf/*.xml /vendor/etc/vintf/manifest/*.xml /odm/etc/vintf/*.xml; } 2>/dev/null |
      awk -v cf=$TMPD/appwords.txt 'BEGIN { while ((getline l < cf) > 0) c[l] = 1 } { $0 = tolower($0); for (w in c) if (index($0, w)) { print w; delete c[w] } }' > $TECHW
  fi
  rm -f $TMPD/appwords.txt )
# scrub's awk: the phone's own names (strings shorter than 4 characters,
# all-digit ones shorter than 8 and "null" are not replaced; serial-like
# ones, 8 or more letters and digits, in any case; the replacement is never
# searched again), then the apps, and what system services write about a
# user's app next to its app<N>: the label of its NFC payment service
# ("ComponentInfo{appN/cls}, UID: n, description: <label>") and the tag of
# its wake lock in the power log ("(appN) - ACQ <tag>"). First, in audit
# records, the names the kernel writes in hex (comm=, name=, path=, exe=,
# proctitle=: a name with a blank, a quote or a control character, such as
# an app's thread "WhatsApp Worker"): decoded, and kept as comm="..." only
# when the app masking changed it or each of its words is a generic one
# (the stop list, thread words); else comm=<hex>. And in the audit records
# of a user app's domain (untrusted_app, isolated_app, sdk_sandbox,
# ephemeral_app) its thread's plain name (comm="..."): kept when each of its
# words (also split at capitals) is a generic one, else comm="<thread>" (a
# library's or SDK's thread name can tell which app it is)
{ cat $TMPD/appcore.awk; cat <<'EOF'
function appthread(s,   h, d, c, nw, w, j) {
  if (!match(s, /comm="[^"]*"/)) return s
  h = substr(s, RSTART, RLENGTH); d = substr(h, 7, length(h) - 7)
  if (d ~ /(^|[^A-Za-z0-9])app[0-9]+([^0-9]|$)|^<[a-z]+>$/) return s
  if (na && amask(d) != d) return s
  c = d; gsub(/[A-Z]/, " &", c)
  nw = split(tolower(c), w, /[^a-z]+/)
  for (j = 1; j <= nw; j++) if (length(w[j]) >= 3 && !(w[j] in sw) && !(w[j] in thw)) return substr(s, 1, RSTART - 1) "comm=\"<thread>\"" substr(s, RSTART + RLENGTH)
  return s
}
function hexname(s,   o, k, h, d, i, c, m, nw, w, j, g) {
  o = ""
  while (match(s, /(comm|name|path|exe|proctitle)=[0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F]+/)) {
    o = o substr(s, 1, RSTART - 1); h = substr(s, RSTART, RLENGTH); s = substr(s, RSTART + RLENGTH)
    k = substr(h, 1, index(h, "=")); h = substr(h, length(k) + 1)
    d = ""; g = (length(h) % 2 == 0)
    for (i = 1; g && i < length(h); i += 2) {
      c = hx[substr(h, i, 1)] * 16 + hx[substr(h, i + 1, 1)]
      if (c < 32 || c > 126 || c == 34) g = 0; else d = d sprintf("%c", c)
    }
    if (g) {
      m = na ? amask(d) : d
      if (m == d) {
        nw = split(tolower(d), w, /[^a-z]+/)
        for (j = 1; j <= nw; j++) if (length(w[j]) >= 3 && !(w[j] in sw) && !(w[j] in thw)) { g = 0; break }
      }
    }
    o = o k (g ? "\"" m "\"" : "<hex>")
  }
  return o s
}
BEGIN {
  for (i = 0; i < 16; i++) hx[substr("0123456789ABCDEF", i + 1, 1)] = i
  n2 = split("worker workers thread threads netlink highpri lowpri binder hwbinder async asynctask task tasks pool render renderthread main signal catcher heap timer queue handler host sideload jit finalizer daemon reference reaper compositor chrome gpu sqlite okhttp dispatcher executor scheduler sync loader cache input event events looper rpc ipc io net dns watchdog profile saver default dispatch modul module coroutine coroutines child daemons getprop setprop mount umount toybox toolbox busybox logcat dumpsys settings uname which stat", thl, " ")
  for (j = 1; j <= n2; j++) thw[thl[j]] = 1
  while ((getline l < sf) > 0) {
    if (length(l) < 4 || l == "null" || (l ~ /^[0-9]+$/ && length(l) < 8)) continue
    s[++n] = l
    if (l ~ /^[0-9A-Za-z]+$/ && length(l) >= 8) {
      uu = toupper(l); if (uu != l) s[++n] = uu; uu = tolower(l); if (uu != l) s[++n] = uu
    }
  }
}
{
  if ((index($0, "avc:") || index($0, "audit(")) && match($0, /(comm|name|path|exe|proctitle)=[0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F]/)) $0 = hexname($0)
  if ((index($0, "avc:") || index($0, "audit(")) && index($0, "comm=\"") && match($0, /(scontext|subj)=u:r:(untrusted_app|isolated_app|sdk_sandbox|ephemeral_app)/)) $0 = appthread($0)
  for (i = 1; i <= n; i++) {
    if (!index($0, s[i])) continue
    o = ""; r = $0
    while ((p = index(r, s[i])) > 0) { o = o substr(r, 1, p - 1) "<masked>"; r = substr(r, p + length(s[i])) }
    $0 = o r
  }
  if (na) {
    $0 = amask($0)
    if (index($0, "ComponentInfo{app") && match($0, /ComponentInfo\{app[0-9]+[^}]*\}.*description: /)) {
      a = substr($0, 1, RSTART + RLENGTH - 1); b = substr($0, RSTART + RLENGTH); i = index(b, ", Static AID"); if (!i) i = index(b, ", ")
      $0 = a "<label>" (i ? substr(b, i) : "")
    }
    if (index($0, ") - ") && match($0, /\(app[0-9]+\) - (ACQ|REL) /)) { a = substr($0, 1, RSTART + RLENGTH - 1); b = substr($0, RSTART + RLENGTH); sub(/^[^ ]+/, "<tag>", b); $0 = a b }
  }
  print
}
EOF
} > $SCRUBF
# qrtr_scan: where qrtr.ko is in the load order and which QMI clients were
# loaded before it. QMI clients need AF_QIPCRTR when they probe: one loaded
# before qrtr.ko gets EAFNOSUPPORT/-EPROBE_DEFER from qmi_handle_init or
# pdr_handle_alloc (soc:qcom,msm_fastrpc stayed unbound that way); stock 5.4
# has CONFIG_QRTR=y. /proc/modules lists the newest module first. Clients: the
# users of qmi_helpers and pdr_interface without the message-table libraries,
# plus known QMI users. Sets QPOS (line of qrtr in /proc/modules, empty if it
# is no module), NMOD (modules loaded) and QLATE (clients loaded before it).
qrtr_scan() {
  QPOS=$(grep -n '^qrtr ' $W/raw/modules.txt | cut -d: -f1); NMOD=$(grep -c . $W/raw/modules.txt); QLATE=
  [ -z "$QPOS" ] && return 0
  seen=" "
  for m in $(awk '$1 == "qmi_helpers" || $1 == "pdr_interface" { print $4 }' $W/raw/modules.txt | tr ',' ' ') \
           frpc_adsprpc q6_pdr_dlkm apr_dlkm qti_pmic_glink icnss2 ipam rmnet_core slim_qcom_ngd_ctrl qcom_sysmon \
           qti_qmi_sensor qti_qmi_sensor_v2 qti_qmi_cdev snd_usb_audio_qmi; do
    case "$m" in -|qmi_helpers|pdr_interface|qcom_pdr_msg|wlan_firmware_service|"["*) continue;; esac
    case "$seen" in *" $m "*) continue;; esac
    seen="$seen$m "
    mp=$(grep -n "^$m " $W/raw/modules.txt | cut -d: -f1)
    [ -n "$mp" ] && [ "$mp" -gt "$QPOS" ] && QLATE="$QLATE $m"
  done
  return 0
}

########################################################################
# charge: the logger itself (started in its own session by "charge" above);
# no checks. The nodes and field names of the charging logs so far
# (chg67.sh), plus up= (seconds since boot, as in the kernel log).
if [ -n "$CHG" ]; then
  trap '' HUP
  # (TY_SYS and TY_KMSG only for a test on a PC: a fake sysfs and kmsg)
  SYS=${TY_SYS:-/sys}; KMD=${TY_KMSG:-/dev/kmsg}
  Q=$SYS/class/qcom-battery; B=$SYS/class/power_supply/battery; U=$SYS/class/power_supply/usb
  WL=taoyao-check-charge
  SMP=$W/samples.txt; EVT=$W/events.txt; KRAW=$TMPD/kmsg-raw.txt
  # cv <node>: its value on one line (empty if it cannot be read)
  cv() { rd "$1" | tr -d '\n'; }
  # kmk <text>: a marker line in the kernel log
  kmk() { { echo "taoyao-check charge: $*" > $KMD; } 2>/dev/null; }
  # alive <pid>: running and not a zombie
  alive() { kill -0 "$1" 2>/dev/null && ! grep -q ') Z ' /proc/$1/stat 2>/dev/null; }
  # the thermal zones and the battery cooling device, looked up once
  tzp() { for z in $SYS/class/thermal/thermal_zone*; do [ "$(rd $z/type)" = "$1" ] && { echo $z; return 0; }; done; }
  ZQ=$(tzp quiet_therm); ZC=$(tzp charger_therm0); ZN=$(tzp conn_therm); ZX=$(tzp xo-therm-usr)
  CD=; for c in $SYS/class/thermal/cooling_device*; do [ "$(rd $c/type)" = battery ] && CD=$c; done
  # one sample (on: usb/online as the poll read it)
  chgs() {
    echo "$(date +%T) up=$(up) cap=$(cv $B/capacity) dec=$(cv $Q/soc_decimal) rate=$(cv $Q/soc_decimal_rate) st=$(cv $B/status) vbat=$(cv $B/voltage_now) ibat=$(cv $B/current_now) tbat=$(cv $B/temp) cc=$(cv $B/charge_counter) fcc=$(cv $B/constant_charge_current) lvl=$(cv $B/charge_control_limit) cdev=${CD:+$(cv $CD/cur_state)} ttf=$(cv $B/time_to_full_now) on=$on type=$(cv $U/type) rt=$(cv $Q/real_type) qct=$(cv $U/quick_charge_type) pmax=$(cv $Q/power_max) apdo=$(cv $Q/apdo_max) pdv=$(cv $Q/pd_verifed) vp=$(cv $Q/verify_process) auth=$(cv $Q/authentic) fcm=$(cv $Q/fastchg_mode) vbus=$(cv $U/voltage_now) ibus=$(cv $U/current_now) icl=$(cv $U/input_current_limit) imax=$(cv $U/current_max) vmax=$(cv $U/voltage_max) urt=$(cv $Q/usb_real_type) cpok=$(cv $Q/bq2597x_chip_ok) cpok2=$(cv $Q/bq2597x_slave_chip_ok) cpv=$(cv $Q/bq2597x_bus_voltage) cpi=$(cv $Q/bq2597x_bus_current) cpi2=$(cv $Q/bq2597x_slave_bus_current) svid=$(cv $Q/adapter_svid) aid=$(cv $Q/adapter_id) dr=$(cv $SYS/class/typec/port0/data_role) isusp=$(cv $Q/input_suspend) sc=$(cv $SYS/class/thermal/thermal_message/sconfig) ss=$(cv $SYS/class/thermal/thermal_message/screen_state) vs=$(cv $SYS/class/thermal/thermal_message/board_sensor_temp) quiet=${ZQ:+$(cv $ZQ/temp)} chgt=${ZC:+$(cv $ZC/temp)} conn=${ZN:+$(cv $ZN/temp)} xo=${ZX:+$(cv $ZX/temp)}"
  }
  # the summary of the samples and events (a value with blanks, such as
  # st=Not charging, continues up to the next name=)
  chgsum() {
    awk -v evf=$EVT -v dur="$1" '
      function num(v) { return v ~ /^-?[0-9]+(\.[0-9]+)?$/ }
      function put(k, v) {
        if (k == "vbat") vb = v
        else if (k == "ibat") ib = v
        else if (k == "cap") { if (num(v)) { if (c0 == "") c0 = v; c1 = v } }
        else if (k == "qct") { if (v != "" && !(v in qs)) { qs[v] = 1; ql = ql (ql == "" ? "" : ", ") v } }
        else if (k == "apdo") { if (num(v) && (am == "" || v + 0 > am + 0)) am = v }
        else if (k == "lvl") { if (num(v)) { if (lmin == "" || v + 0 < lmin + 0) lmin = v; if (lmax == "" || v + 0 > lmax + 0) lmax = v } }
        else if (k == "tbat" || k == "quiet" || k == "chgt" || k == "conn" || k == "xo") {
          if (num(v) && (!(k in tm) || v + 0 > tm[k] + 0)) { tm[k] = v; tmt[k] = t }
        }
      }
      $1 ~ /^[0-9][0-9]:[0-9][0-9]:[0-9][0-9]$/ {
        ns++; t = $1; vb = ""; ib = ""; k = ""; v = ""
        for (i = 2; i <= NF; i++) {
          p = index($i, "=")
          if (p > 1) { if (k != "") put(k, v); k = substr($i, 1, p - 1); v = substr($i, p + 1) }
          else if (k != "") v = v " " $i
        }
        if (k != "") put(k, v)
        if (num(vb) && num(ib)) {
          a = ib + 0; if (a < 0) a = -a
          w = (vb + 0) * a / 1e12
          if (!wn || w > wm) { wn = 1; wm = w; wt = t; wv = vb; wi = ib }
        }
      }
      END {
        # plug-ins and pd_verifed from the events (polled every second)
        plug = ""; inpd = 0; pdl = ""; pdres = ""; on0 = ""
        while ((getline l < evf) > 0) {
          split(l, f, " ")
          if (substr(l, 1, 2) == "# ") {
            on0 = l; sub(/.*usb online=/, "", on0); sub(/ .*/, "", on0)
            pv = l; sub(/.*pd_verifed=/, "", pv); sub(/ .*/, "", pv)
            if (on0 == "1") { plug = 0; plugat = "" }
            if (pv == "1") { inpd = 1; pdres = "уже 1 в начале записи" }
            continue
          }
          et = f[3]; sub(/^t=/, "", et); et += 0
          to = l; sub(/.*->/, "", to)
          if (index(l, " usb online ")) {
            if (to == "1") { nin++; plug = et; plugat = f[1]; inpd = 0 }
            else {
              nout++
              if (plug != "" && !inpd) pdl = pdl "; отключён в " f[1] ", через " (et - plug) " с " (plugat == "" ? "после начала" : "после подключения") ", pd_verifed так и не стал 1"
              plug = ""
            }
          } else if (index(l, " pd_verifed ")) {
            if (to == "1" && !inpd) {
              inpd = 1
              if (plug == "") pdl = pdl "; 1 в " f[1] ", когда USB был отключён"
              else if (plugat == "") pdl = pdl "; 1 в " f[1] ", через " (et - plug) " с после начала (USB уже был подключён)"
              else pdl = pdl "; 1 в " f[1] ", через " (et - plug) " с после подключения в " plugat
            } else if (to != "1") inpd = 0
          }
        }
        if (plug != "" && !inpd && pdres == "") pdl = pdl "; не стал 1 до конца (" (plugat == "" ? "подключён с начала" : "подключён в " plugat) ")"
        sub(/^; /, "", pdl)
        if (pdl == "") pdl = (pdres != "") ? pdres : ((on0 == "1" || nin) ? "ни разу не был 1" : "ни разу не был 1 (USB ни разу не подключался)")
        else if (pdres != "") pdl = pdres "; " pdl
        printf "замеров:                 %d за %s, заряд %s%% -> %s%%\n", ns, dur, (c0 == "" ? "-" : c0), (c1 == "" ? "-" : c1)
        printf "подключения USB:         %d раз, отключения: %d (подключён в начале: %s)\n", nin, nout, (on0 == "" ? "-" : on0)
        if (wn) printf "наибольшая мощность:     %.2f Вт в %s (voltage_now %.3f В, current_now %.3f А)\n", wm, wt, wv / 1e6, wi / 1e6
        else print "наибольшая мощность:     - (нет voltage_now / current_now)"
        print "quick_charge_type:       " (ql == "" ? "-" : ql)
        print "наибольший apdo_max:     " (am == "" ? "-" : am)
        print "pd_verifed:              " pdl
        print "charge_control_limit:    " (lmin == "" ? "-" : "от " lmin " до " lmax)
        s = ""; split("tbat quiet chgt conn xo", ks, " "); split("battery quiet_therm charger_therm0 conn_therm xo-therm-usr", kn, " ")
        for (i = 1; i <= 5; i++) {
          if (!(ks[i] in tm)) continue
          s = s (s == "" ? "" : ", ") sprintf("%s %.1f °C (%s)", kn[i], tm[ks[i]] / (ks[i] == "tbat" ? 10 : 1000), tmt[ks[i]])
        }
        print "наибольшая температура:  " (s == "" ? "-" : s)
      }' $SMP
  }
  # the end (also when stopped by kill): the report and the archive, then
  # the wakelock is released
  chgend() {
    trap '' INT TERM
    S1=$(date +%s)
    kmk "done${STOPPED:+ (stopped early)}"
    sleep 1
    kill $KP 2>/dev/null
    chgsum "$(( (S1 - S0) / 60 )) мин $(( (S1 - S0) % 60 )) с" > $TMPD/summary.txt 2>&1
    {
      echo "$TYBAN — журнал зарядки"
      echo "$KLINE; $PHLINE; запуск: $N"
      echo "записано $(( (S1 - S0) / 60 )) мин $(( (S1 - S0) % 60 )) с из $CHGM мин${STOPPED:+ (остановлено раньше)}; замер каждые 10 с, usb/online и pd_verifed каждую секунду; wakelock: $WLS"
      echo
      echo "################ сводка"
      cat $TMPD/summary.txt
      echo
      echo "################ события (t: секунды от начала; up: от включения, как в журнале ядра)"
      cat $EVT
      echo
      echo "################ замеры"
      cat $SMP
    } > $W/taoyao-charge.txt
    kmask < $KRAW > $W/kmsg.txt
    tmo 60 logcat -d -b main,system -v threadtime 2>/dev/null | lmask > $W/logcat.txt
    cp $TMPD/run.log $W/run-log.txt 2>/dev/null
    scrub
    cp $W/taoyao-charge.txt $REPORT
    rm -f $OUT.part
    if ( cd $TYTMP && tar -czf $OUT.part $N ) && mv -f $OUT.part $OUT; then
      rm -rf $W
      [ "$OUTDIR" = /sdcard ] || chmod 644 $OUT $REPORT 2>/dev/null
      result ok "$OUT" "$(wc -c < $OUT)" "${STOPPED:+остановлено раньше}"
    else
      rm -f $OUT.part; echo "Архив не создан: файлы остались в $W"
      result fail "" 0 "архив не создан (tar), файлы в $W"
    fi
    { echo $WL > $SYS/power/wake_unlock; } 2>/dev/null
    rm -f $CHGPID
    rm -rf $TMPD
  }
  echo "$TYBAN: журнал зарядки на $CHGM мин с $(date '+%F %T'), pid $$, файлы в $W"
  # the wakelock ends by itself 5 minutes after the planned end, should the
  # logger be killed hard (nanoseconds as text: mksh computes in 32 bits)
  WLS="не взят (нет $SYS/power/wake_lock)"
  { echo "$WL $((CHGM * 60 + 300))000000000" > $SYS/power/wake_lock; } 2>/dev/null && WLS="$WL взят"
  dmesg -w > $KRAW 2>&1 &
  KP=$!
  STOPPED=; S0=$(date +%s); END=$((S0 + CHGM * 60)); NS=$S0
  trap 'STOPPED=1; chgend; exit 0' INT TERM
  kmk "start, $CHGM min, pid $$"
  on0=$(cv $U/online); pv0=$(cv $Q/pd_verifed)
  echo "# $(date +%T) up=$(up) t=0 start: usb online=${on0:--} pd_verifed=${pv0:--}" > $EVT
  : > $SMP
  while [ "$(date +%s)" -lt "$END" ]; do
    now=$(date +%s); on=$(cv $U/online); pv=$(cv $Q/pd_verifed)
    if [ "$on" != "$on0" ]; then
      kmk "usb online ${on0:--}->${on:--}"
      echo "$(date +%T) up=$(up) t=$((now - S0)) usb online ${on0:--}->${on:--}" >> $EVT
      on0=$on
    fi
    if [ "$pv" != "$pv0" ]; then
      echo "$(date +%T) up=$(up) t=$((now - S0)) pd_verifed ${pv0:--}->${pv:--}" >> $EVT
      pv0=$pv
    fi
    if [ "$now" -ge "$NS" ]; then
      chgs >> $SMP
      NS=$((NS + 10)); [ "$NS" -le "$now" ] && NS=$((now + 10))
      # a check run ends every "dmesg -w" it finds (that of prep): follow again
      if ! alive $KP; then
        echo "=== $(date +%T) dmesg -w завершился: запущен снова (весь буфер журнала ядра повторяется ещё раз)" >> $KRAW
        dmesg -w >> $KRAW 2>&1 &
        KP=$!
      fi
    fi
    sleep 1
  done
  chgend
  exit 0
fi

T0=$(up)
# (wall clock, for logcat -T: the logs of the run itself are saved again at the end)
TSTART=$(date '+%m-%d %H:%M:%S.000')
echo "Начало проверки: режим $MODESTR, папка $N."
[ -n "$PREVNOTE" ] && echo "$PREVNOTE"
# debugfs: read only where it is mounted already; mic (the DAPM chain), deep
# (developer only: its debugfs reads) and TAOYAO_DEBUGFS=1 mount it for the
# run and unmount it at the end (TAOYAO_DEBUGFS=0: never)
DBGM=; DBGFS=; DBGWAS=
if grep -q " /sys/kernel/debug " /proc/mounts 2>/dev/null; then DBGFS=1
elif { [ -n "$TAOYAO_DEBUGFS" ] || [ -n "$MIC" ] || [ -n "$DEEP" ]; } && [ "$TAOYAO_DEBUGFS" != 0 ] && mount -t debugfs debugfs /sys/kernel/debug 2>/dev/null; then DBGM=1; DBGFS=1; DBGWAS=1; echo 1 > $LOCK/dbgm
fi
# a deep sweep that did not finish: the phone crashed, hung or rebooted while
# reading this batch of paths (or this one path, read alone after a batch
# blocked; an interrupted run removes the file)
PREVLAST=; PREVLN=0
if [ -f $LAST ]; then PREVLAST=$(head -1 $LAST 2>/dev/null); PREVLN=$(grep -c . $LAST 2>/dev/null); cp $LAST $TMPD/prev-lastread.txt 2>/dev/null; rm -f $LAST; fi
IPM=; PACKED=; MSP=; BGD=; KLOG=1; LLOG=1; RLOG=1
# pgone <pid>: gone or a zombie; waitgone <pid> <half seconds>: wait that
# long at most (a child stuck in the kernel cannot be waited for)
pgone() { [ ! -d /proc/$1 ] || grep -q ') Z ' /proc/$1/stat 2>/dev/null; }
waitgone() { wg=0; while ! pgone "$1" && [ $wg -lt "$2" ]; do sleep 0.5; wg=$((wg + 1)); done; pgone "$1" && wait "$1" 2>/dev/null; return 0; }

########################################################################
# watch window first, so that the logs below include what happened in it:
# FastRPC daemon pids at its start and end, network interfaces during it;
# in mic mode the capture streams (micsample, section 13b)
netstate() {
  echo "== $1 (с включения $(up) с)"
  tmo 10 ip -o link 2>&1 | sed "$MAC" | sed -E "$IPS" | cut -c1-160
  echo "ipv6 conf: $(ls /proc/sys/net/ipv6/conf 2>/dev/null | tr '\n' ' ')"
  command -v iw >/dev/null && { echo "iw dev:"; tmo 10 iw dev 2>&1 | grep -viE 'ssid' | sed "$MAC"; }
}
# mic mode: the open capture substreams and (with debugfs) the TX path's
# DAPM widgets, once a second, "@ <uptime>" before each sample
MICD=$W/mic
MICDW=; MICRUN=0; MICMX=; MICSVC=
if [ -n "$MIC" ]; then
  mkdir -p $MICD
  # the PCM devices that capture on their own (ultrasound, hostless, listen, proxy)
  MICSVC=" $(sed -nE 's/^[0-9]+-0*([0-9]+): .*(Hostless|USTX|USRX|[Uu]ltrasound|Listen [0-9]|AFE-PROXY).*/\1/p' $ASND/pcm 2>/dev/null | tr '\n' ' ')"
  : > $MICD/pcm-samples.txt; : > $MICD/dapm-samples.txt
  # the DAPM widgets that matter (FE, CDC DMA TX, AIF CAP, DEC/SMIC MUX, ADC, DMIC, MIC BIAS, bias levels)
  if [ -d "$ASOC" ]; then
    tmo 20 find "$ASOC" -path '*/dapm/*' -type f 2>/dev/null | awk -F/ '{ w = $NF }
      w == "bias_level" || w ~ /^(MM_UL[0-9]+|VOICEMMODE[0-9]_(UL|DL)|VOIP_UL|(TX|VA)_CDC_DMA_TX_[0-9]+|MultiMedia[0-9]+ Mixer)$/ ||
      w ~ /^(TX|VA)[ _]|ADC[0-9]|DMIC|AMIC|SWR_|DEC[0-9]|SMIC|MIC BIAS|_CAP|VDD_BUCK|MCLK|WCD_TX/ { print }' > $MICD/dapm-list.txt
    [ -s $MICD/dapm-list.txt ] && MICDW=1
  fi
fi
micsample() {
  ms_t=$(up); ms_f=; ms_r=
  for ms_s in $ASND/card*/pcm*c/sub*/status; do
    [ -f "$ms_s" ] || continue
    read -r ms_l 2>/dev/null < "$ms_s" || continue
    case "$ms_l" in closed*|"") continue;; esac
    ms_f="$ms_f$NL$ms_s$NL${ms_s%/status}/hw_params"
    # (a user's capture: not the always-on ultrasound, hostless, listen or proxy PCMs)
    ms_d=${ms_s%c/sub*/status}; ms_d=${ms_d##*/pcm}
    case "$ms_l" in *RUNNING*) case "$MICSVC" in *" $ms_d "*) ;; *) ms_r=1;; esac;; esac
  done
  if [ -n "$ms_f" ]; then
    { echo "@ $ms_t"; OIFS=$IFS; IFS=$NL; set -f; tmo 3 grep -aH . $ms_f 2>/dev/null; set +f; IFS=$OIFS; } | sed "s|^$ASND/||" >> $MICD/pcm-samples.txt
  else echo "@ $ms_t" >> $MICD/pcm-samples.txt; fi
  if [ -n "$MICDW" ]; then
    { echo "@ $ms_t"; OIFS=$IFS; IFS=$NL; set -f; tmo 3 grep -aH -v '^ ' $(cat $MICD/dapm-list.txt) 2>/dev/null; set +f; IFS=$OIFS; } | sed "s|^$ASOC/[^/]*/||" >> $MICD/dapm-samples.txt
  fi
  # a capture running for 2 samples: the TX mixer controls once (read only)
  if [ -n "$ms_r" ]; then MICRUN=$((MICRUN + 1)); else MICRUN=0; fi
  [ "$MICRUN" -ge 2 ] && [ -z "$MICMX" ] && { MICMX=$(up); micmixer > $MICD/mixer-tx.txt 2>&1; }
}
# micmixer: the TX controls of the mixer while a capture runs (read only):
# "name<TAB>value"; AOSP tinymix lists every control with its value,
# tinyalsa 2.x lists names ("controls") and gives values with "get"
MICTX='^(TX|VA)[ _]|ADC[0-9]|DMIC|AMIC|SWR_|DEC[0-9]|SMIC|MIC BIAS|MultiMedia[0-9]+ Mixer (TX|VA)_CDC|(TX|VA)_CDC_DMA|BCS|ChMap|IIR|_CAP'
micmixer() {
  mm_tm=$(command -v tinymix || ls /vendor/bin/tinymix /system/bin/tinymix 2>/dev/null | head -1)
  [ -n "$mm_tm" ] || { echo "# нет tinymix"; return 0; }
  echo "# $(up) с: элементы микшера TX во время записи (только чтение, $mm_tm)"
  tmo 20 $mm_tm -D 0 controls < /dev/null > $TMPD/mm-list.txt 2>/dev/null
  if awk -F'\t' 'NF >= 4 && $1 ~ /^[0-9]+$/ { n++ } END { exit !n }' $TMPD/mm-list.txt; then
    awk -F'\t' 'NF >= 4 && $1 ~ /^[0-9]+$/ { n = $4; sub(/ +$/, "", n); print n }' $TMPD/mm-list.txt | grep -E "$MICTX" | head -120 > $TMPD/mm-names.txt
    while IFS= read -r mm_n; do
      printf '%s\t%s\n' "$mm_n" "$(tmo 5 $mm_tm -D 0 get "$mm_n" < /dev/null 2>&1 | head -1)"
    done < $TMPD/mm-names.txt
  else
    tmo 60 $mm_tm -D 0 < /dev/null > $TMPD/mm-all.txt 2>/dev/null
    awk -F'\t' 'NF >= 4 && $1 ~ /^[0-9]+$/ { s = $4; for (i = 5; i <= NF; i++) s = s " " $i
        n = substr(s, 1, 40); v = substr(s, 41); sub(/ +$/, "", n); sub(/^ +/, "", v); print n "\t" v }' $TMPD/mm-all.txt | grep -E "$MICTX"
  fi
}
sec "0. Наблюдение: процессы FastRPC и сеть${HS:+, точка доступа}${MIC:+, микрофон} ($WIN с)"
det "(записи наблюдения — raw/net-start.txt, raw/net-samples.txt, raw/ipmon.txt, raw/rpcd-start.txt; разбор — в разделах 12, 20b${MIC:+ и 13b})"
for n in $RPCD; do echo "$n $(pidof $n 2>/dev/null)"; done > $W/raw/rpcd-start.txt
netstate "сеть в начале наблюдения" > $W/raw/net-start.txt
# (not under timeout: killing the timeout would leave ip running; it is killed below)
ip -timestamp monitor link address > $TMPD/ipmon.txt 2>&1 &
IPM=$!
if [ -n "$HS" ]; then
  det "(hostapd и SoftApManager пишут больше после: cmd wifi set-verbose-logging enabled)"
  echo ">>> ВКЛЮЧИТЕ точку доступа СЕЙЧАС; когда она включится (или не включится) — ВЫКЛЮЧИТЕ её <<<"
elif [ -n "$MIC" ]; then
  # the kernel log's last time stamp: the window's kernel lines come after it
  MICKM=$(tmo 30 dmesg 2>/dev/null | tail -n 1 | sed -n 's/^\[ *\([0-9]*\.[0-9]*\)\].*/\1/p')
  MICT0=$(date '+%m-%d %H:%M:%S.000')
  echo ">>> Откройте «Диктофон» (или другое приложение для записи), начните запись СЕЙЧАС и говорите 10–15 секунд, затем остановите запись <<<"
fi
prev=; i=0
: > $W/raw/net-samples.txt
while [ $i -lt $((WIN * 2)) ]; do
  cur=$(ls /sys/class/net 2>/dev/null | tr '\n' ' ')
  [ "$cur" != "$prev" ] && echo "$(up) $cur" >> $W/raw/net-samples.txt
  prev=$cur; i=$((i + 1))
  if [ $((i % 2)) = 0 ]; then
    beat
    [ -n "$MIC" ] && micsample
    [ $WIN -gt 10 ] && [ $((i % 20)) = 0 ] && [ $i -lt $((WIN * 2)) ] && echo "   … осталось $((WIN - i / 2)) с"
  fi
  sleep 0.5
done
kill $IPM 2>/dev/null; waitgone $IPM 6; IPM=
grep -vE '^ +(link/|valid_lft|altname)' $TMPD/ipmon.txt | sed "$MAC" | sed -E "$IPS" | cut -c1-200 > $W/raw/ipmon.txt
for n in $RPCD; do echo "$n $(pidof $n 2>/dev/null)"; done > $W/raw/rpcd-end.txt
netstate "сеть в конце наблюдения" > $W/raw/net-end.txt
[ $WIN -gt 10 ] && echo "Наблюдение закончено, дальше проверка идёт сама."

########################################################################
# raw data used by several sections; whether each log could be read at all
# (KLOG, LLOG, RLOG: an empty log is an error, and its checks say "не проверено")
sec "Журналы: ядро, logcat, свойства, модули"
det "(журналы — в raw/: dmesg.txt, logcat.txt, events.txt, props.txt, modules.txt; журнал radio — radio-log.txt)"
tmo 30 dmesg 2>$TMPD/dmesg.err | kmask > $W/raw/dmesg.txt
if [ "$(grep -c . $W/raw/dmesg.txt)" -lt 50 ]; then
  KLOG=0
  fail "журнал" "журнал ядра не прочитан ($(head -1 $TMPD/dmesg.err | cut -c1-100)): проверки по журналу ядра не выполнены, «нет ошибок» в них ничего не значит"
fi
grep -vE "$SPAM" $W/raw/dmesg.txt > $W/raw/dmesg-nospam.txt
# (whole words: not "ramoops", "invalidation", "not found" inside a word;
# the summary also counts them without the expected ones: those section 21
# leaves out, and PEXP: dummy regulators, absent optional properties, the
# staging-driver notice, logd's audit decoding, the fallback lines)
PEXP='using dummy regulator|vote-index not found|Error loading vote values|module is from the staging directory|UEFI not found|logd: HexToBytes|Falling back to sysfs fallback|regulatory\.db'
grep -iE '(^|[^a-z])(error|fail|unable|timeout|timed out|defer|bug:|warn|call trace|panic|not found|returned -)|(^|[^a-z])(oops|invalid)([^a-z]|$)' $W/raw/dmesg-nospam.txt | grep -v 'avc:' > $W/raw/dmesg-problems.txt
tmo 60 logcat -d -b main,system,crash -v threadtime 2>/dev/null | lmask > $W/raw/logcat.txt
if [ "$(grep -c . $W/raw/logcat.txt)" -lt 50 ]; then
  LLOG=0
  fail "журнал" "журнал приложений (logcat) пуст или не прочитан: проверки по нему не выполнены"
fi
tmo 60 logcat -d -b events -v threadtime 2>/dev/null | lmask > $W/raw/events.txt
tmo 60 logcat -d -b crash -v threadtime 2>/dev/null | lmask > $W/raw/logcat-crash.txt
awk '$5 == "E" || $5 == "F"' $W/raw/logcat.txt > $W/raw/logcat-errors.txt
getprop | grep -viE "$PRIV" | sed "$MAC" > $W/raw/props.txt
cat /proc/modules > $W/raw/modules.txt 2>/dev/null
# the radio log and the main/system log with seconds since boot (-v monotonic:
# suspend not counted, so equal to uptime until the first suspend), masked
tmo 60 logcat -d -b radio -v threadtime -v monotonic 2>/dev/null | awk -f $MASKF | nmask > $TMPD/radio.txt
if [ "$(grep -c . $TMPD/radio.txt)" -lt 5 ]; then RLOG=0; det "журнал radio пуст: проверки SIM по нему не выполнены"; fi
# (without libc's "property name length ... >= 31" lines: they come from this
# script's own getprop of long names, in an earlier run)
tmo 60 logcat -d -b main,system -v threadtime -v monotonic 2>/dev/null | grep -viE "$LDROP" | grep -v 'The property name length for ' | awk -f $MASKF | nmask > $TMPD/mainsys.txt
LCUP=$(up)
# where the main and system buffers begin (s since boot: the first line
# after logcat's "beginning of" marker), and the tag with the most lines in
# main/system: a main log that starts long after boot has lost the boot's
# HAL lines (sound, camera, sensors, Wi-Fi), and the checks that read them
# cannot see that
MAIN0=$(awk '/^-+ beginning of main/ { m = 1; next } /^-+ beginning of / { m = 0; next } m && $1 ~ /^[0-9]+\.[0-9]+$/ { printf "%d", $1; exit }' $TMPD/mainsys.txt)
SYS0=$(awk '/^-+ beginning of system/ { m = 1; next } /^-+ beginning of / { m = 0; next } m && $1 ~ /^[0-9]+\.[0-9]+$/ { printf "%d", $1; exit }' $TMPD/mainsys.txt)
LTOP=$(awk '$5 ~ /^[VDIWEF]$/ { t = $6; sub(/:$/, "", t); c[t]++; n++ } END { for (t in c) print c[t], t; print n + 0, "-" }' $W/raw/logcat.txt | sort -rn | awk '$2 == "-" { n = $1; next } k < 3 { o = o (k++ ? ", " : "") $2 " " $1 } END { if (o != "") print o " (из " n ")" }')
det "журнал main (logcat) начинается на ${MAIN0:-?} с после включения, system — на ${SYS0:-?} с${LTOP:+; больше всего строк в main и system: $LTOP}"
[ -n "$MAIN0" ] && [ "$MAIN0" -gt 60 ] && det "журнал main начинается только на $MAIN0 с: строки служб и HAL за начало загрузки (звук, камера, датчики, Wi-Fi) уже вытеснены, и проверки по ним их не видят (prep увеличивает буфер main для следующего раза)"
# since prep (its start mark, this boot only): the window of the reproduced problem
if [ -f $PREPF ]; then
  IFS='|' read -r pm_t pm_u pm_b < $PREPF
  if [ -n "$BOOTID" ] && [ "$pm_b" = "$BOOTID" ]; then
    tmo 60 logcat -d -b main,system,crash -v threadtime -T "$pm_t" 2>/dev/null | lmask > $W/raw/logcat-since-prep.txt
    det "prep: метка $pm_t (через ${pm_u%.*} с после включения); logcat с неё: raw/logcat-since-prep.txt ($(grep -c . $W/raw/logcat-since-prep.txt) строк)"
  else
    rm -f $PREPF
  fi
fi
# the kernel log saved early in this boot (prep, or a boot script): into the
# archive without its first line (the boot_id); one of another boot is removed
KE0=
if [ -f $KEARLY ]; then
  if [ -n "$BOOTID" ] && head -1 $KEARLY | grep -q "boot_id=$BOOTID "; then
    KE0=$(head -1 $KEARLY | sed -n 's/.* uptime=\([0-9]*\).*/\1/p')
    { echo "# the kernel log as saved at ${KE0:-?} s after boot (prep or a boot script; masked)"; sed 1d $KEARLY; } > $W/raw/dmesg-early.txt
  else
    rm -f $KEARLY
  fi
fi
# the kernel-log capture prep started (KMSG): this boot's only while its
# process runs or prep's mark is of this boot (prep writes both); one left
# from another boot would give that boot's times (the modem's start, QRTR
# limits, hung tasks) as this one's, so it is removed unread
if [ -f $KMSG ]; then
  kp=$(cat $KPID 2>/dev/null)
  if [ -n "$kp" ] && [ -d /proc/$kp ] && tr '\0' ' ' 2>/dev/null < /proc/$kp/cmdline | grep -q 'taoyao-kmsg'; then :
  elif [ -f $PREPF ] && [ -n "$BOOTID" ] && [ "$pm_b" = "$BOOTID" ]; then :
  else det "запись журнала ядра после prep — от прошлой загрузки (метки prep этой загрузки нет): не используется и удалена"; rm -f $KMSG $KPID; fi
fi
RC_FILES=$(ls /vendor/etc/init/*.rc /vendor/etc/init/hw/*.rc /odm/etc/init/*.rc /vendor/odm/etc/init/*.rc 2>/dev/null)
# (Evolution X installs one in /vendor/etc as well)
UEV_FILES=$(ls /vendor/ueventd.rc /vendor/etc/ueventd.rc /odm/ueventd.rc /vendor/odm/ueventd.rc /ueventd.rc /system/etc/ueventd.rc 2>/dev/null)
# the ROM type by the zip's rules (AnyKernel3/tools/ty-lib.sh, ty_romtype),
# for the IPA UAPI layout (section 20c) and the wakeup-source labels (18):
# IPAWANT=Y for Xiaomi's own vendor (stock HyperOS), N for a custom ROM's
# vendor; IPAROM says which. The vendor build decides. Only Xiaomi's own
# vendor has the MIUI/HyperOS version in ro.vendor.build.version.incremental;
# not the fingerprint (Evolution X and crDroid copy stock's), not ro.miui.*
# (Evolution X sets ro.miui.notch). The partitions' build.prop first, else
# getprop.
IPSYS="/mi_ext/etc/build.prop /mnt/vendor/mi_ext/etc/build.prop /product/etc/build.prop /system/build.prop /system_ext/etc/build.prop /odm/etc/build.prop"
# iprop <vendor|system> <name>...: first of the properties set; IPRP, IPRPN
iprop() {
  ip_s=$1; shift
  if [ "$ip_s" = vendor ]; then ip_fl=/vendor/build.prop; else ip_fl=$IPSYS; fi
  ip_any=
  for ip_f in $ip_fl; do
    [ -r "$ip_f" ] || continue
    ip_any=1
    for ip_n in "$@"; do
      ip_v=$(grep "^$ip_n=" "$ip_f" | tail -n1 | cut -d= -f2-)
      [ -n "$ip_v" ] && { IPRP=$ip_v; IPRPN=$ip_n; return 0; }
    done
  done
  [ -n "$ip_any" ] && return 1
  for ip_n in "$@"; do
    ip_v=$(getprop $ip_n)
    [ -n "$ip_v" ] && { IPRP=$ip_v; IPRPN=$ip_n; return 0; }
  done
  return 1
}
iv=; im=; ic=
iprop vendor ro.vendor.build.version.incremental && iv=$IPRP
iprop system ro.mi.os.version.incremental ro.mi.os.version.name ro.mi.os.version.code && im=$IPRP
if iprop system ro.evolution.version; then ic="Evolution X $IPRP"
elif iprop system ro.crdroid.version; then ic="crDroid $IPRP"
elif iprop system ro.lineage.version ro.lineage.build.version ro.lineage.device ro.modversion; then ic="прошивка на основе LineageOS ($IPRPN=$IPRP)"
fi
IPAWANT=?
if [ -n "$iv" ] && echo "$iv" | grep -qE '^(V|OS)[0-9]+(\.[0-9]+){3}\.[A-Z]{4,}$'; then
  IPAWANT=Y
  if [ -n "$im" ]; then IPAROM="стоковая HyperOS $im, vendor Xiaomi $iv"
  elif [ -n "$ic" ]; then IPAROM="$ic на vendor Xiaomi $iv"
  else IPAROM="vendor Xiaomi $iv (MIUI или HyperOS)"
  fi
elif [ -n "$ic" ]; then
  IPAWANT=N; IPAROM="$ic, vendor собран вместе с прошивкой (${iv:-vendor не прочитан})"
  [ -n "$im" ] && IPAROM="$IPAROM; свойства HyperOS $im не учитываются"
elif [ -n "$im" ]; then IPAROM="свойства HyperOS ($im), но сборка vendor ${iv:-(нет)} — не от Xiaomi"
elif [ -n "$iv" ]; then IPAROM="сборка vendor $iv — не от Xiaomi, и свойств кастомной прошивки нет"
else IPAROM="нет свойств сборки vendor"
fi
if [ -r /vendor/build.prop ] && [ ! -e /vendor/bin/ipacm ]; then IPAWANT=N; IPAROM="$IPAROM; нет /vendor/bin/ipacm"; fi


########################################################################
# port-only checks (qrtr.ko order, ipam/uapi_stock, ION heap count): results
# on the 6.12 port on taoyao, details ("сравнение") on anything else
pfail() { if [ -n "$PORT" ]; then fail "$@"; else cmpn "$1: $2"; fi; }
pwarn() { if [ -n "$PORT" ]; then warn "$@"; else cmpn "$1: $2"; fi; }
pok()   { if [ -n "$PORT" ]; then ok "$@"; else cmpn "$1: $2"; fi; }

# ---- whole-system collectors: each masked, under a time limit, cut to a
# size, and listed in raw/collectors.txt ----
COLX=$W/raw/collectors.txt
echo "# файл, секунды, код выхода, байт (обрезано / зависло)" > $COLX
# colrec <file> <t0> <rc> <cut>: one line in the index
colrec() {
  cr_b=$(wc -c 2>/dev/null < "$W/$1"); cr_b=$((${cr_b:-0} + 0))
  awk -v f="$1" -v a="$2" -v b="$(up)" -v rc="$3" -v n="$cr_b" -v c="$4" \
    'BEGIN { printf "%-34s %6.1f с  код=%-3s %9d байт%s\n", f, b - a, rc, n, (c == "" ? "" : "  " c) }' >> $COLX
}
# capto <src> <file> <max KB>: the source cut to the size into $W/<file>; CUT says how much
capto() {
  ct_n=$(wc -c 2>/dev/null < "$1"); ct_n=$((${ct_n:-0} + 0)); CUT=
  mkdir -p "$(dirname "$W/$2")"
  if [ "$ct_n" -gt $(( $3 * 1024 )) ]; then
    head -c $(( $3 * 1024 )) "$1" > "$W/$2"
    { echo; echo "### обрезано до $3 КБ (всего $((ct_n / 1024)) КБ)"; } >> "$W/$2"
    CUT="обрезано: $3 из $((ct_n / 1024)) КБ"; rm -f "$1"
  else mv -f "$1" "$W/$2"; fi
}
# col <file> <seconds> <max KB> <mask> <command...>: an external command under
# timeout (on the producer: the mask reads its finished output, so nothing
# that writes into a pipe is cut off halfway); <mask> is a function or "cat"
col() {
  cl_f=$1; cl_t=$2; cl_k=$3; cl_m=$4; shift 4
  cl_0=$(up); beat
  tmo "$cl_t" "$@" < /dev/null > $TMPD/col.raw 2>&1; cl_rc=$?
  { printf '# %s\n' "$*"; $cl_m < $TMPD/col.raw; } > $TMPD/col.out 2>&1
  rm -f $TMPD/col.raw
  capto $TMPD/col.out "$cl_f" "$cl_k"
  colrec "$cl_f" "$cl_0" "$cl_rc" "$CUT"
}
# colf <file> <max KB> <mask> <path or glob>...: each file as "=== path" and its text (3 s per file)
colf() {
  cf_f=$1; cf_k=$2; cf_m=$3; shift 3
  cf_0=$(up); beat
  for cf_p in "$@"; do for cf_x in $cf_p; do [ -f "$cf_x" ] || continue; echo "=== $cf_x"; rd "$cf_x"; echo; done; done | $cf_m > $TMPD/colf.out 2>&1
  capto $TMPD/colf.out "$cf_f" "$cf_k"
  colrec "$cf_f" "$cf_0" 0 "$CUT"
}
# rdb <list> <seconds>: the files of the list as "<path>:<line>" (grep -H, one
# process per 100 files, no fork per file); a file that cannot be read gives
# grep's own "grep: <path>: <error>" line in place (awk's getline is no use
# here: BWK awk and mawk abort at the first EIO or EINVAL that sysfs and
# /proc return). A group that blocks longer than <seconds> is read again
# file by file, 3 s each, so only the file that blocks is lost (RDBHANG).
# With [budget seconds]: once the list has taken that long, the rest is
# listed as skipped.
rdb() {
  rb_s=$2; rb_b=${3:-0}; RDBHANG=; rb_t0=$(date +%s)
  rm -f $TMPD/rdb.chunk.*
  awk -v p=$TMPD/rdb.chunk 'NR % 100 == 1 { if (f != "") close(f); f = sprintf("%s.%04d", p, ++n) } { print > f }' "$1"
  for rb_c in $TMPD/rdb.chunk.*; do
    [ -f "$rb_c" ] || continue
    beat
    if [ "$rb_b" -gt 0 ] && [ $(( $(date +%s) - rb_t0 )) -ge "$rb_b" ]; then
      sed 's/$/: (пропущено: время на эту папку вышло)/' "$rb_c"; RDBHANG="$RDBHANG (время вышло)"; rm -f "$rb_c"; continue
    fi
    OIFS=$IFS; IFS=$NL; set -f
    tmo "$rb_s" grep -aH '' $(cat "$rb_c") < /dev/null > $TMPD/rdb.out 2>&1; rb_rc=$?
    set +f; IFS=$OIFS
    if [ $rb_rc = 124 ] || [ $rb_rc = 137 ]; then
      : > $TMPD/rdb.out
      while IFS= read -r rb_f; do
        if [ "$rb_b" -gt 0 ] && [ $(( $(date +%s) - rb_t0 )) -ge "$rb_b" ]; then echo "$rb_f: (пропущено: время на эту папку вышло)" >> $TMPD/rdb.out; continue; fi
        tmo 3 grep -aH '' "$rb_f" < /dev/null >> $TMPD/rdb.out 2>&1; rb_r=$?
        if [ $rb_r = 124 ] || [ $rb_r = 137 ]; then echo "$rb_f: (чтение заняло больше 3 с, пропущено)" >> $TMPD/rdb.out; RDBHANG="$RDBHANG $rb_f"; fi
      done < "$rb_c"
    fi
    cat $TMPD/rdb.out
    rm -f "$rb_c"
  done
  rm -f $TMPD/rdb.out
}
# colr <file> <seconds per 100 files> <max KB> <mask> <list file> [budget seconds]
colr() {
  cr_f=$1; cr_t=$2; cr_k=$3; cr_m=$4; cr_l=$5; cr_b=${6:-0}
  cr_0=$(up)
  # (rdb not in a pipeline: RDBHANG must reach this shell)
  rdb "$cr_l" "$cr_t" "$cr_b" > $TMPD/colr.raw
  { printf '# grep -H, файлов: %s\n' "$(grep -c . "$cr_l")"; $cr_m < $TMPD/colr.raw; } > $TMPD/colr.out
  rm -f $TMPD/colr.raw
  capto $TMPD/colr.out "$cr_f" "$cr_k"
  colrec "$cr_f" "$cr_0" 0 "$CUT${RDBHANG:+  зависло на:$RDBHANG}"
}
# attrs <extra deny ERE> <folder>...: the readable regular files directly in
# the folders, without the names of DENYA (reads that do something:
# measurements and self-tests (AW8622x f0, cont, lra_resistance,
# vbat_monitor; Goodix get_rawdata), raw scans, register access, dumps,
# serial numbers and chip ids)
DENYA='serial|_sn$|uid$|uuid|die_info|fuse|cell_id|wp_info|lockdown|imei|mac_?addr|address|secret|key|calib|cali$|test|inspect|raw|dump|reset|reg$|_reg|rw$|_rw|cmd$|^f0|cont$|resistance|vbat|trigger_|update|upgrade|flash|snapshot|^ram$|rtp$|activate|reboot|shutdown|panic|wakeup_device_list|uevent$|modalias$|descriptors$|config$|^rom$|nvmem|eeprom|trans_table'
attrs() {
  at_x=$1; shift
  tmo 30 find "$@" -maxdepth 1 -type f -perm -400 2>/dev/null |
    awk -v d="$DENYA" -v x="$at_x" '{ n = $0; sub(/.*\//, "", n); n = tolower(n); if (n ~ d) next; if (x != "" && n ~ x) next; print }'
}
# dropbox_pick <dir> <n>: the newest <n> text entries of each tag that
# matters (crashes, ANRs, watchdog, boot, last kernel log, recovery, fsck),
# oldest first, as "<tag> <ms> <file>"; binary entries (.dat, protobuf
# tombstones) and dropped ones (.lost) are never read
DBTAGS='^(SYSTEM_(BOOT|RESTART|LAST_KMSG|RECOVERY_LOG|RECOVERY_KMSG|FSCK|AUDIT|TOMBSTONE|SHUTDOWN)|system_server_(crash|native_crash|anr|watchdog|wtf|lowmem|pre_watchdog)|system_app_(crash|native_crash|anr)|data_app_(crash|native_crash|anr)|keymaster|storage_trim|BOOT_WARN|.*(kmsg|panic|kernel|watchdog).*)$'
dropbox_pick() {
  ls "$1" 2>/dev/null | sed -n 's/^\(.*\)@\([0-9][0-9]*\)\.txt\(\.gz\)\{0,1\}$/\1 \2 &/p' |
    awk -v t="$DBTAGS" '$1 ~ t' | sort -k1,1 -k2,2n |
    awk -v n="$2" '{ k[$1]++; l[$1, k[$1]] = $0 } END { for (t in k) for (i = (k[t] > n ? k[t] - n + 1 : 1); i <= k[t]; i++) print l[t, i] }' |
    sort -k2,2n
}
# dropbox_dump <dir> <n> <KB per entry>: those entries, "=== <tag> <date>" and
# the text (gzip ones through zcat); kernel logs through kmask, the rest
# through the private-property filter, logcat's filter and the app names;
# tombstones (SYSTEM_TOMBSTONE, *_native_crash: the whole text tombstone)
# only up to their first memory dump, as tomb() (no memory contents, memory
# map, open files or the process's log lines)
dropbox_dump() {
  dropbox_pick "$1" "$2" | while read -r db_t db_ms db_f; do
    # (milliseconds as text: mksh computes in 32 bits)
    db_d=$(date -d @${db_ms%???} '+%F %T' 2>/dev/null)
    echo "=== $db_t ${db_d:-$db_ms} ($db_f)"
    case "$db_f" in *.gz) tmo 10 zcat "$1/$db_f" 2>/dev/null;; *) rd "$1/$db_f";; esac | head -c $(( $3 * 1024 )) > $TMPD/db1.txt
    case "$db_t" in
      *KMSG*|*kmsg*) kmask < $TMPD/db1.txt;;
      *TOMBSTONE*|*native_crash*) tombf 400 < $TMPD/db1.txt | propmask | grep -viE 'tel:|sip:|msisdn|iccid|imsi|imei|number=' | lmask | appmask;;
      *) propmask < $TMPD/db1.txt | grep -viE 'tel:|sip:|msisdn|iccid|imsi|imei|number=' | lmask | appmask;;
    esac
    echo
  done
  rm -f $TMPD/db1.txt
}
# the dumps of the hardware-facing services, in the background while the
# checks run (dsys keeps each dump once; a section that needs the same dump
# waits for it): masked copies in dumpsys/
BGLIST='media.camera media.audio_flinger media.audio_policy audio sensorservice display SurfaceFlinger power battery thermalservice vibrator_manager usb input media.metrics cpuinfo meminfo telephony.registry bluetooth_manager'
bgtel() { telmask | appmask; }
# usbmask: dumpsys usb, and in a user app's accessory filter (package_name=
# app<N>) the maker, model and class names (they name the app's brand)
usbmask() { dmask | awk '/package_name=app[0-9]/ { k = 12 } k > 0 { k--; if ($0 ~ /^ *(manufacturer|model|class_name)=/) sub(/=.*/, "=x") } { print }'; }
bgdumps() {
  for bs in $BGLIST; do
    bs0=$(up)
    dsys $bs > $TMPD/bg.raw 2>/dev/null
    case $bs in telephony.registry) bm=bgtel;; bluetooth_manager) bm=btmask;; usb) bm=usbmask;; *) bm=dmask;; esac
    { echo "# dumpsys -t 10 $bs"; $bm < $TMPD/bg.raw; } > $TMPD/bg.out 2>&1
    bk=512; [ $bs = SurfaceFlinger ] && bk=1024; [ -n "$DEEP" ] && bk=$((bk * 2))
    capto $TMPD/bg.out dumpsys/$bs.txt $bk
    colrec dumpsys/$bs.txt "$bs0" 0 "$CUT"
  done
  rm -f $TMPD/bg.raw
}
( bgdumps ) > /dev/null 2>&1 &
BGD=$!
########################################################################
sec "1. Ядро: основное"
det "версия: $REL; $KLINE"; det "$(kmask < /proc/version)"; det "время с включения: $(cut -d' ' -f1 /proc/uptime) с (/proc/uptime; второе число там — простой всех ядер вместе: $(cut -d' ' -f2 /proc/uptime) с)"
det "soc_id: $(rd /sys/devices/soc0/soc_id) (у SM7325 — 475); телефон: ${ID_MODEL:-?} (${ID_DEV:-?}, sku ${ID_SKU:-?}, devicetree «${ID_DTM:-?}»)"
CMD=$(cat /proc/cmdline); CL=$(printf '%s' "$CMD" | wc -c)
det "командная строка ядра ($CL байт): $(echo "$CMD" | sed -E "$CMDMASK" | sed "$MAC")"
if [ "$CL" -ge 2047 ]; then fail "ядро" "командная строка ядра — $CL байт: ядро обрезало её на 2047"; else ok "ядро" "командная строка ядра: $CL байт"; fi
# (androidboot.* come on the command line or, with bootconfig, in /proc/bootconfig)
case "$CMD $(cat /proc/bootconfig 2>/dev/null)" in *androidboot.force_normal_boot=1*|*androidboot.mode=*|*'androidboot.force_normal_boot = "1"'*|*'androidboot.mode = '*) ;; *) warn "ядро" "в командной строке нет androidboot.force_normal_boot=1 (телефон загружен в recovery?)";; esac
TAINT=$(rd /proc/sys/kernel/tainted); TAINT=${TAINT:-0}
det "tainted (флаги «испорченности» ядра): $TAINT"
# bits: 0 P proprietary, 1 F forced, 4 M machine check, 7 D died (oops), 9 W warning, 12 O out-of-tree, 13 E unsigned, 14 L soft lockup
# W: the first WARNING's "cut here" block (to its "---[ end trace" line, at
# most 150 lines) of this boot's kernel log and of the previous boot's
# (pstore console) goes to raw/first-warning.txt; its WARNING line and the top
# of its call trace to the details
WMSG=
if [ $(( (TAINT >> 9) & 1 )) = 1 ]; then
  cutblk() { awk '!n && index($0, "------------[ cut here ]------------") { n = 1 } n { print; if (index($0, "---[ end trace") || ++c >= 150) exit }'; }
  # trace5: the first 5 function names of the call trace (innermost first)
  trace5() { awk '/Call [Tt]race:/ { t = 1; next }
    t { s = $0; sub(/^\[ *[0-9.]+\]/, "", s); sub(/^\[ *[CT][0-9]+\]/, "", s); sub(/^[ \t]+/, "", s)
        if (s ~ /^<[A-Z]+>$/) next
        if (s !~ /^[A-Za-z0-9_.$]+\+0x/) { if (n) exit; next }
        sub(/\+0x.*/, "", s); o = o (n++ ? " <- " : "") s; if (n >= 5) exit }
    END { print o }'; }
  # wline: its WARNING line (else the line after "cut here"), without the time
  wline() { awk 'NR == 2 { l = $0 } /WARNING:/ { l = $0; exit } END { print l }' "$1" | sed -E 's/^\[ *[0-9.]+\] *//' | cut -c1-200; }
  cutblk < $W/raw/dmesg.txt > $TMPD/warn-k.txt
  : > $TMPD/warn-p.txt; WPF=
  for f in /sys/fs/pstore/console-*; do
    [ -f "$f" ] || continue
    kmask < "$f" | cutblk > $TMPD/warn-p.txt
    [ -s $TMPD/warn-p.txt ] && { WPF=${f##*/}; break; }
  done
  if [ -s $TMPD/warn-k.txt ] || [ -s $TMPD/warn-p.txt ]; then
    { if [ -s $TMPD/warn-k.txt ]; then echo "== эта загрузка: первый блок «cut here» журнала ядра"; cat $TMPD/warn-k.txt; echo; fi
      if [ -s $TMPD/warn-p.txt ]; then echo "== прошлая загрузка: первый блок «cut here» из pstore/$WPF"; cat $TMPD/warn-p.txt; fi
    } | kmask > $W/raw/first-warning.txt
  fi
  if [ -s $TMPD/warn-k.txt ]; then
    WMSG=": первое — в raw/first-warning.txt"
    det "первое предупреждение ядра (raw/first-warning.txt): $(wline $TMPD/warn-k.txt)"
    det "  стек вызовов: $(trace5 < $TMPD/warn-k.txt)"
  else
    WMSG=": его блока «cut here» в журнале ядра уже нет${WPF:+ (в raw/first-warning.txt — первое предупреждение прошлой загрузки)}"
    det "журнал ядра уже не доходит до первого предупреждения (его блока «cut here»)"
  fi
  if [ -s $TMPD/warn-p.txt ]; then
    det "первое предупреждение прошлой загрузки (pstore/$WPF): $(wline $TMPD/warn-p.txt)"
    det "  стек вызовов: $(trace5 < $TMPD/warn-p.txt)"
  fi
fi
for b in 7:"было падение ядра (oops, D)" 9:"было предупреждение ядра (WARNING, W)" 14:"было зависание процессора (soft lockup, L)" 5:"повреждённая страница памяти (bad page, B)" 4:"аппаратная ошибка (machine check, M)"; do
  bit=${b%%:*}; msg=${b#*:}
  [ "$bit" = 9 ] && msg="$msg$WMSG"
  [ $(( (TAINT >> bit) & 1 )) = 1 ] && fail "ядро" "tainted: $msg"
done
SEL=$(getenforce 2>/dev/null)
[ "$SEL" = Enforcing ] && ok SELinux "включён (Enforcing)" || warn SELinux "не в режиме Enforcing: ${SEL:-не прочитано}"
det "причина загрузки: $(getprop sys.boot.reason) / $(getprop ro.boot.bootreason)"
# verified boot: the kernel's command line (or bootconfig) says what the
# bootloader passed; the property can be spoofed (a ROM or a root module
# sets "green" for app checks): both when they differ
VBK=$(printf '%s\n' "$CMD" | tr ' ' '\n' | sed -n 's/^androidboot\.verifiedbootstate=//p' | tail -n 1)
[ -n "$VBK" ] || VBK=$(sed -n 's/^androidboot\.verifiedbootstate *= *"\{0,1\}\([a-z]*\)"\{0,1\}.*/\1/p' /proc/bootconfig 2>/dev/null | tail -n 1)
VBP=$(getprop ro.boot.verifiedbootstate)
if [ -n "$VBK" ] && [ -n "$VBP" ] && [ "$VBK" != "$VBP" ]; then VBS="$VBK (ядро); свойство подменено (прошивкой или модулем root): $VBP"
elif [ -n "$VBK" ]; then VBS="$VBK (ядро)"
else VBS="${VBP:-?} (свойство; в командной строке ядра и bootconfig его нет)"; fi
VBD=$(printf '%s\n' "$CMD" | tr ' ' '\n' | sed -n 's/^androidboot\.vbmeta\.device_state=//p' | tail -n 1)
det "проверка загрузки (verified boot): $VBS${VBD:+, загрузчик $VBD}, verity: $(getprop ro.boot.veritymode)"
[ "$(getprop sys.boot_completed)" = 1 ] && ok "загрузка" "загрузка завершена" || fail "загрузка" "sys.boot_completed не равен 1"
# the kernel's notice of its authors (port kernels from 0.19): one line at
# boot ("taoyao: Linux 6.12 port for Xiaomi Mi 12 Lite (taoyao) by Meddax
# (meru_ii) and the MeruDevTools team"), /sys/kernel/taoyao/license (authors
# and the GPL-2.0 notice, small) and license_merudevtools (our licence in
# full, about 110 KB, a binary attribute: copied, never printed). Older
# kernels have neither: nothing is said then.
TYLIC=/sys/kernel/taoyao
if [ -n "$PORT" ] && [ -n "$KBUILD" ] && [ "$KBUILD" -ge 19 ] 2>/dev/null; then
  if [ -r $TYLIC/license ] && grep -q 'Meddax (meru_ii)' $TYLIC/license 2>/dev/null; then
    det "Порт: Meddax (meru_ii) и команда MeruDevTools (сведения в ядре: $TYLIC/license; копии — в kernel-license/)"
  else
    warn "ядро" "в ядре нет сведений об авторах: это не официальная сборка или файл недоступен ($TYLIC/license)"
  fi
  mkdir -p $W/kernel-license
  for f in license license_merudevtools; do [ -r $TYLIC/$f ] && tmo 10 cat $TYLIC/$f > $W/kernel-license/$f.txt 2>/dev/null; done
  rmdir $W/kernel-license 2>/dev/null
  kl=$(grep -m1 'taoyao: Linux 6.12 port for ' $W/raw/dmesg.txt | sed -E 's/^\[ *[0-9.]+\] *//' | cut -c1-400)
  [ -n "$kl" ] && det "строка ядра при загрузке: $kl"
fi
# the installer's logs (the zip from 0.19 writes stable lines: "taoyao-run:
# <stamp>-<pid>" first, then "taoyao-backup:", "taoyao-slot:", "taoyao-kernel:",
# "taoyao-result: step1|done|abort-clean|abort-restored|abort-dirty"): next to
# each backup, <store>/taoyao-6.12-backup/<dir>/install-<stamp>.log and
# info.txt (the three stores are one storage seen three ways: each file once,
# by its folder and name), and the newest one as taoyao-6.12-last.log in the
# recovery's /tmp (the restore zip: taoyao-restore-last.log, there or, run in
# a flasher app, in /data/local/tmp). The newest 3
# logs and every info.txt go to install/, masked (CR line ends removed; a log
# over 1 MB as its first 512 KB and last 64 KB: the taoyao- lines are there);
# the newest is judged. An interrupted write (abort-dirty) is judged against
# this boot: a log from before it, of the slot the phone now runs from, was
# fixed since; of the other slot, that slot is broken; from this boot (a
# flasher app), the phone must not restart before the images are on a PC. A
# newer restore zip log (taoyao-restore-last.log: in the recovery's /tmp, or
# in /data/local/tmp when it ran in a flasher app) decides instead.
imask() { tr -d '\r' | sed "$MAC" | sed -E "$KIP4; $KIP4; $KIP6; $KIP6; $HOSTM; $LMASK; $USERHOST" | appmask; }
# utcloc <YYYYMMDD-HHMMSS in UTC>: "DD.MM.YYYY HH:MM (HH:MM UTC)" in the
# phone's time zone (date -d @<epoch>), or "DD.MM.YYYY HH:MM UTC"
utcloc() {
  ul_e=$(printf '%s\n' "$1" | awk '/^[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9]/ {
      y = substr($0, 1, 4) + 0; m = substr($0, 5, 2) + 0; d = substr($0, 7, 2) + 0; h = substr($0, 10, 2) + 0; mi = substr($0, 12, 2) + 0
      c = 0; for (i = 1970; i < y; i++) c += (i % 4 == 0 && (i % 100 != 0 || i % 400 == 0)) ? 366 : 365
      split("31 28 31 30 31 30 31 31 30 31 30 31", ml, " "); if (y % 4 == 0 && (y % 100 != 0 || y % 400 == 0)) ml[2] = 29
      for (i = 1; i < m; i++) c += ml[i]
      printf "%.0f %02d.%02d.%d %02d:%02d\n", ((c + d - 1) * 24 + h) * 3600 + mi * 60, d, m, y, h, mi }')
  [ -n "$ul_e" ] || { printf '%s\n' "$1"; return 0; }
  ul_l=$(date -d "@${ul_e%% *}" '+%d.%m.%Y %H:%M' 2>/dev/null)
  if [ -n "$ul_l" ] && [ "$ul_l" != "${ul_e#* }" ]; then echo "$ul_l (${ul_e##* } UTC)"; else echo "${ul_e#* } UTC"; fi
}
# icopy <file>: imask, a large log cut to its start and end
icopy() {
  if [ "$(wc -c < "$1" 2>/dev/null)" -gt 1048576 ] 2>/dev/null; then { head -c 524288 "$1"; echo; echo "… (обрезано)"; tail -c 65536 "$1"; } | imask
  else imask < "$1"; fi
}
for d in /sdcard /storage/emulated/0 /data/media/0; do
  for f in $d/taoyao-6.12-backup/*/install-*.log $d/taoyao-6.12-backup/*/info.txt; do
    [ -f "$f" ] || continue
    b=${f%/*}; echo "${b##*/}/${f##*/} $f"
  done
done 2>/dev/null | awk '!seen[$1]++' > $TMPD/inst.txt
{ awk '$1 ~ /\/install-[0-9]+-[0-9]+\.log$/ { k = $1; sub(/.*\/install-/, "", k); sub(/\.log$/, "", k); print k, $2 }' $TMPD/inst.txt
  # (an old log without a "taoyao-run:" line: its time, and once if it is a
  # copy of one next to a backup)
  for f in /tmp/taoyao-6.12-last.log /dev/tmp/taoyao-6.12-last.log; do
    [ -f "$f" ] || continue
    k=$(sed -n 's/^taoyao-run: \([0-9]*-[0-9]*\)-.*/\1/p' "$f" | head -1)
    if [ -z "$k" ]; then
      dup=; for g in $(awk '$1 ~ /\/install-/ { print $2 }' $TMPD/inst.txt); do cmp -s "$f" "$g" && dup=1 && break; done
      [ -n "$dup" ] && continue
      k=$(date -u -d @$(stat -c %Y "$f" 2>/dev/null || echo 0) +%Y%m%d-%H%M%S 2>/dev/null)
    fi
    echo "$k $f"
  done; } | sort -r | awk '!seen[$1]++' | head -3 > $TMPD/inst-logs.txt
if [ -s $TMPD/inst-logs.txt ] || [ -s $TMPD/inst.txt ]; then
  mkdir -p $W/install
  while read -r k f; do icopy "$f" > $W/install/install-$k.txt; done < $TMPD/inst-logs.txt
  awk '$1 ~ /\/info\.txt$/ { k = $1; sub(/\/info\.txt$/, "", k); print k, $2 }' $TMPD/inst.txt | while read -r k f; do imask < "$f" > $W/install/$k-info.txt; done
  read -r in_k in_f < $TMPD/inst-logs.txt
  if [ -n "$in_f" ]; then
    in_l=$W/install/install-$in_k.txt
    # (the stamp is UTC: the installer's busybox date, also in a running
    # system, ignores Android's time zone; shown in the phone's time too)
    in_d=$(utcloc "$in_k")
    in_r=$(sed -n 's/^taoyao-result: //p' $in_l | tail -1); in_kr=$(sed -n 's/^taoyao-kernel: //p' $in_l | tail -1)
    in_s=$(sed -n 's/^taoyao-slot: //p' $in_l | tail -1); in_b=$(sed -n 's/^taoyao-backup: //p' $in_l | tail -1)
    in_w="последняя установка ядра (${in_d:-$in_k}${in_kr:+, ядро $in_kr}${in_s:+, слот $in_s})"
    in_o=; grep -q '^taoyao-run: ' $in_l || in_o=1
    # (a restore zip log newer than this install: its result decides)
    in_rr=; in_rf=
    for f in /tmp/taoyao-restore-last.log /dev/tmp/taoyao-restore-last.log /data/local/tmp/taoyao-restore-last.log; do
      [ -f "$f" ] || continue
      in_rk=$(tr -d '\r' < "$f" | sed -n 's/^taoyao-run: \([0-9]*-[0-9]*\)-.*/\1/p' | head -1)
      [ -n "$in_rk" ] && [ "$(printf '%s\n%s\n' "$in_rk" "$in_k" | sort -r | head -1)" = "$in_rk" ] && [ "$in_rk" != "$in_k" ] && { in_rr=$(tr -d '\r' < "$f" | sed -n 's/^taoyao-result: //p' | tail -1); in_rf=$f; }
      break
    done
    in_e=; [ -s "$in_f" ] || in_e=1
    if [ -n "$in_e" ]; then
      det "журнал установки пуст: install/install-$in_k.txt (${in_d:-$in_k})"
    elif [ -n "$in_rr" ]; then
      case "$in_rr" in
        restored) det "$in_w: итог — ${in_r:-нет}; потом прежнее ядро вернули zip-файлом восстановления (taoyao-result: restored; install/restore-last.txt)";;
        *) fail "установка" "$in_w: итог — ${in_r:-нет}; потом восстановление zip-файлом не удалось (taoyao-result: ${in_rr:-нет}): проверьте, какое ядро в слоте, а если телефон не загружается — прошейте прежние образы в режиме fastboot (журнал — install/restore-last.txt)";;
      esac
    elif [ -n "$in_o" ]; then
      det "журнал установки старого формата (zip до 0.19, ${in_d:-$in_k}): install/install-$in_k.txt; последние строки:"
      grep . $in_l | tail -5 | cut -c1-200 >> $DET
    else
      case "$in_r" in
        done) det "$in_w: завершена (taoyao-result: done); журнал — install/install-$in_k.txt";;
        step1) det "$in_w: шаг 1 из 2 — копия слота только в памяти (RAM), ядро не записано; журнал — install/install-$in_k.txt";;
        abort-clean) det "$in_w: прервана до записи, ничего не записано (taoyao-result: abort-clean); журнал — install/install-$in_k.txt";;
        abort-restored) warn "установка" "$in_w прервалась, и слот восстановлен из копии: работает прежнее ядро (причина — в install/install-$in_k.txt)";;
        abort-dirty)
          # (the log file's time against the boot, not its name: the name is
          # the installer's stamp in UTC)
          in_m=$(stat -c %Y "$in_f" 2>/dev/null); in_b0=$(( $(date +%s) - $(cut -d. -f1 /proc/uptime) )); in_cs=$(getprop ro.boot.slot_suffix)
          in_bp=$(printf '%s\n' "${in_b:-/sdcard/taoyao-6.12-backup}" | sed 's#^/data/media/0/#/sdcard/#; s#^/storage/emulated/0/#/sdcard/#')
          in_fb="fastboot flash boot$in_s boot.img, fastboot flash vendor_boot$in_s vendor_boot.img, fastboot flash dtbo$in_s dtbo.img"
          if [ -n "$in_m" ] && [ "$in_m" -lt "$in_b0" ] && [ -n "$in_s" ] && [ "$in_s" = "$in_cs" ]; then
            det "$in_w: прервалась на записи, но телефон с тех пор загрузился с этого слота ($in_cs) — слот исправлен (журнал — install/install-$in_k.txt)"
          elif [ -n "$in_m" ] && [ "$in_m" -lt "$in_b0" ] && [ -n "$in_s" ] && [ -n "$in_cs" ]; then
            fail "установка" "$in_w прервалась на записи: слот $in_s не загрузится, телефон сейчас работает со слота $in_cs. Не переключайтесь на слот $in_s. Скопируйте папку $in_bp на компьютер (adb pull $in_bp) и в режиме fastboot прошейте образы из неё: $in_fb (журнал — install/install-$in_k.txt)"
          elif [ -n "$in_m" ] && [ "$in_m" -lt "$in_b0" ]; then
            fail "установка" "$in_w прервалась на записи, и слот вернуть не удалось. Скопируйте папку $in_bp на компьютер (adb pull $in_bp) и в режиме fastboot прошейте образы из неё: $in_fb (журнал — install/install-$in_k.txt)"
          else
            fail "установка" "$in_w прервалась на записи, и слот вернуть не удалось. Не перезагружайте телефон, пока не скопируете папку $in_bp на компьютер (adb pull $in_bp); потом в режиме fastboot прошейте образы из неё: $in_fb (журнал — install/install-$in_k.txt)"
          fi;;
        *) warn "установка" "$in_w оборвалась без итога (в журнале нет строки taoyao-result): проверьте, то ли ядро в слоте (install/install-$in_k.txt)";;
      esac
    fi
    det "журналов установки найдено: $(grep -c '/install-' $TMPD/inst.txt), записей info.txt: $(grep -c '/info\.txt ' $TMPD/inst.txt) (в архиве — последние журналы и все info.txt: install/)"
  fi
else
  det "журналов установки нет (папки taoyao-6.12-backup нет: ядро ставили не zip-файлом или папку удалили)"
fi
# every key of every info.txt (newest first; later installers add keys, all
# are shown as they are; a date without a zone is the installer's UTC), and
# for the newest install's copy its ROM keys against the ROM now, read as
# the installer reads them (the partitions' build.prop first: iprop): ro.*
# properties, the build time (rom_build_utc, *date_utc: ro.build.date.utc),
# rom_build_date, rom_build_inc and rom_version; not the fingerprint (in a
# running system it can be spoofed)
in_ib=${in_b##*/}
for f in $(ls -r $W/install/*-info.txt 2>/dev/null); do
  ik=${f##*/}; ik=${ik%-info.txt}
  det "info.txt копии $ik:"
  awk '/^[A-Za-z][A-Za-z0-9_.-]*=/ { k = $0; sub(/=.*/, "", k); v = substr($0, length(k) + 2); if (k == "date" && v != "" && v !~ /UTC/) v = v " (UTC)"; print "  " k "=" v }' "$f" | cut -c1-300 | head -40 >> $DET
  [ -n "$in_ib" ] && [ "$ik" = "$in_ib" ] || continue
  # (a copy of the other slot: that slot's ROM, not the running one's)
  is_s=$(sed -n 's/^slot=//p' "$f" | head -n 1); is_c=$(getprop ro.boot.slot_suffix)
  if [ -n "$is_s" ] && [ -n "$is_c" ] && [ "$is_s" != "$is_c" ]; then det "  копия слота $is_s, а телефон загружен со слота $is_c: с прошивкой сейчас не сравнивается"; continue; fi
  grep -E '^[A-Za-z][A-Za-z0-9_.-]*=' "$f" | head -60 > $TMPD/info-rom.txt
  while IFS= read -r il; do
    ik=${il%%=*}; iv=${il#*=}; ips2=
    case "$ik" in
      ro.*) ips=$ik;;
      rom_build_utc|*date[._]utc) ips="ro.build.date.utc ro.system.build.date.utc";;
      rom_build_date) ips="ro.build.date ro.system.build.date";;
      rom_build_inc) ips="ro.build.version.incremental ro.system.build.version.incremental";;
      # (as the installer asks, ty_romid: the custom ROM's version in every
      # file first, HyperOS's only then: a custom ROM flashed over HyperOS
      # can leave its mi_ext)
      rom_version) ips="ro.evolution.build.version ro.crdroid.build.version ro.lineage.build.version ro.lineage.version ro.modversion"; ips2=ro.mi.os.version.incremental;;
      *) continue;;
    esac
    [ -n "$iv" ] && [ "$iv" != - ] || continue
    IPRP=; IPRPN=; iprop system $ips || { [ -n "$ips2" ] && iprop system $ips2; } || { IPRP=$(getprop ${ips%% *}); IPRPN=${ips%% *}; }
    [ -n "$IPRP" ] || continue
    if [ "$IPRP" = "$iv" ]; then det "  $ik: как у прошивки сейчас ($IPRPN)"
    else det "  $ik: при установке «$iv», сейчас $IPRPN=«$IPRP» (прошивку с тех пор меняли)"; fi
  done < $TMPD/info-rom.txt
done
# the newest install log's own keys ("taoyao-<key>: <value>"; later
# installers add some, such as rom-build: the ROM build's time in UTC)
[ -n "$in_l" ] && [ -s "$in_l" ] && det "ключи журнала установки: $(grep -E '^taoyao-[a-z0-9-]+: ' "$in_l" | cut -c1-160 | head -20 | tr '\n' ';' | sed 's/;$//; s/;/; /g')"
for f in /tmp/taoyao-restore-last.log /dev/tmp/taoyao-restore-last.log /data/local/tmp/taoyao-restore-last.log; do
  [ -f "$f" ] || continue
  mkdir -p $W/install; icopy "$f" > $W/install/restore-last.txt
  det "восстановление прежнего ядра (restore zip): taoyao-result: $(sed -n 's/^taoyao-result: //p' $W/install/restore-last.txt | tail -1); install/restore-last.txt"
  break
done

########################################################################
sec "2. Журнал ядра"
L=$W/raw/dmesg.txt
first=$(head -1 $L | sed -E 's/^\[ *([0-9]+)\..*/\1/')
KEW=; [ -s $W/raw/dmesg-early.txt ] && KEW="; в raw/dmesg-early.txt — журнал ядра, сохранённый на ${KE0:-?} с"
[ -n "$first" ] && [ "$first" -gt 5 ] 2>/dev/null && warn "журнал" "журнал ядра начинается с ${first} с: начало загрузки вытеснено из буфера (см. проверку на спам)$KEW"
# not counted as timeouts: q6lsm's "panic_on_timeout debugfs flag is
# created", qcacld's "Psoc idle timeout elapsed" (Wi-Fi off: the firmware is
# shut down when idle), init reaping a process named "timeout" (toybox
# timeout, of this script among others), the display's "poll timeout" of a
# resource reservation on screen wake (harmless, every build has it) and this
# script's own marks (a deep batch's first file can be named *timeout)
TOX='panic_on_timeout debugfs flag|Psoc idle timeout|name: \(timeout\)|sde_rm_reserve:[0-9]+\] poll timeout|taoyao-check (deep|charge): '
# kscan <kernel log> [label]: panics, oopses, warnings, stalls, failed
# probes and firmware loads, crashes of the remote processors, faults and
# timeouts (here, and at the end over the lines the run itself added, with
# the label "во время проверки: ")
kscan() {
ks_f=$1; ks_l=$2
for p in "Kernel panic" "Internal error: Oops" "BUG: " "Unable to handle kernel" "Call trace:" "WARNING: CPU" "scheduling while atomic" "sleeping function called from invalid context" "possible circular locking" "INFO: task .* blocked for more than" "rcu_preempt detected stalls|rcu_sched self-detected stall|RCU detected stall" "soft lockup" "hard LOCKUP" "Out of memory: Killed" "KASAN|UBSAN" "list_add corruption|list_del corruption" "refcount_t: " "Unknown symbol|disagrees about version of symbol|module verification failed" "probe with driver .* failed|probe of .* failed with error|failed to probe" "ueventd: firmware: could not find firmware for|firmware: failed to load|loading .* timed out" "watchdog: .*bark|Watchdog bark" "$RPCRASH" "SMMU fault|smmu.*Unhandled context fault|context fault" "timed out|timeout"; do
  case "$p" in
    "timed out|timeout") grep -E -e "$p" $ks_f | grep -vE -e "$TOX" > $TMPD/l2.txt;;
    "ueventd: firmware"*) grep -E -e "$p" $ks_f | grep -v 'regulatory\.db' > $TMPD/l2.txt;;
    *) grep -E -e "$p" $ks_f > $TMPD/l2.txt;;
  esac
  c=$(grep -c . $TMPD/l2.txt)
  [ "$c" -gt 0 ] || continue
  case "$p" in
    "timed out|timeout"|"probe with driver"*|"ueventd: firmware"*) warn "журнал" "$ks_l$c × «$p»";;
    *) fail "журнал" "$ks_l$c × «$p»";;
  esac
  det "--- $ks_l$p"; head -15 $TMPD/l2.txt >> $DET
done
}
kscan $W/raw/dmesg-nospam.txt
# firmware: the kernel's own search path has none of the files (they are in
# /vendor/firmware_mnt/image and /vendor/firmware), so every request logs
# "Direct firmware load for X failed with error -2" and then, with
# force_sysfs_fallback=1 on the command line, "Falling back to sysfs fallback
# for: X": ueventd then serves the file. Only a direct load that no fallback
# follows counts (a final failure is "firmware: failed to load" above);
# regulatory.db is expected: no ROM ships it, qcacld keeps its own
# regulatory data
awk '/Direct firmware load for [^ ]+ failed/ { s = $0; sub(/.*Direct firmware load for /, "", s); sub(/ failed.*/, "", s); nd++; pend[s]++; next }
     /Falling back to sysfs fallback for: / { s = $0; sub(/.*Falling back to sysfs fallback for: /, "", s); sub(/[ \t].*/, "", s); nf++; if (pend[s] > 0) pend[s]--; next }
     END { printf "D %d %d\n", nd, nf; for (s in pend) if (pend[s] > 0) print "N", s, pend[s] }' $W/raw/dmesg-nospam.txt > $TMPD/fw-direct.txt
fwd=$(sed -n 's/^D //p' $TMPD/fw-direct.txt)
det "прошивки: прямых загрузок не удалось — ${fwd% *}, через запасной путь sysfs пошли — ${fwd#* } (их отдаёт ueventd из /vendor/firmware*: так и должно быть)"
{ grep -q '^N regulatory\.db ' $TMPD/fw-direct.txt || grep -q 'failed to load regulatory\.db' $W/raw/dmesg-nospam.txt; } && det "прошивки: regulatory.db не найден (ожидаемо: его нет ни в одной прошивке, драйвер WLAN использует свои данные)"
fwn=$(awk '$1 == "N" && $2 != "regulatory.db" { printf " %s", $2 }' $TMPD/fw-direct.txt)
[ -n "$fwn" ] && warn "журнал" "прошивки:$fwn: прямая загрузка не удалась, а запасной путь sysfs (ueventd) не последовал"
det "--- самые частые сообщения ядра (числа свёрнуты)"
sed -E 's/^\[ *[0-9.]+\] *//; s/0x[0-9a-fA-F]+/0x#/g; s/[0-9]+/#/g' $L | sort | uniq -c | sort -rn | head -25 >> $DET
top=$(sed -E 's/^\[ *[0-9.]+\] *//; s/[0-9]+/#/g' $L | sort | uniq -c | sort -rn | head -1)
topn=$(echo "$top" | awk '{print $1}')
[ -n "$topn" ] && [ "$topn" -gt 500 ] && fail "журнал" "спам в журнале: $topn × «$(echo "$top" | sed -E 's/^ *[0-9]+ //' | cut -c1-120)»"
det "--- строки ошибок по драйверам (числа свёрнуты)"
grep -iE "error|fail|unable|invalid" $W/raw/dmesg-nospam.txt | sed -E 's/^\[ *[0-9.]+\] *//; s/0x[0-9a-fA-F]+/0x#/g; s/[0-9]+/#/g' | sort | uniq -c | sort -rn | head -60 >> $DET
# the previous boot's kernel log (pstore/ramoops, copied into the archive)
for f in /sys/fs/pstore/*; do
  [ -f "$f" ] || continue
  case "${f##*/}" in
    console-*|dmesg-*) kmask < "$f" > "$W/pstore/${f##*/}";;
    # pmsg: the previous boot's userspace logs, unmasked: only as text below
    pmsg-*) ;;
    *) cp -p "$f" $W/pstore/;;
  esac
done
# (pmsg-ramoops itself is not copied: logcat -L reads it as text; a user
# build's Android writes no main/system log there, so it stays empty)
PMSGN=
if exists '/sys/fs/pstore/pmsg-*'; then
  tmo 20 logcat -L -d -b main,system,crash -v threadtime 2>/dev/null | lmask > $W/pstore/logcat-last-boot.txt
  [ -s $W/pstore/logcat-last-boot.txt ] || { rm -f $W/pstore/logcat-last-boot.txt; PMSGN="pmsg пуст (в сборках user Android не пишет туда журналы main/system), в архив не входит"; }
  [ -n "$PMSGN" ] || PMSGN="pmsg — в pstore/logcat-last-boot.txt (logcat -L)"
fi
det "pstore: $(ls /sys/fs/pstore 2>/dev/null | tr '\n' ' ')${PMSGN:+($PMSGN)}"
# the check of /data at this boot (ro.boottime.init.fsck.data, ms) and how
# the previous boot shut down (pstore: init's "Umount /data failed, try to
# use ioctl to shutdown" and powerctl_shutdown_time_ms:<ms>:<code>, code 2 =
# an unmount timeout): information, no warning; a long fsck delays all that
# starts after /data is mounted (modem, Wi-Fi, sound), so every boot time
# in this report is later by as much
FSCKN=; SHUTN=; FSCKS=; SHUTS=
fsk=$(getprop ro.boottime.init.fsck.data)
if [ -n "$fsk" ] && [ "$fsk" -gt 2000 ] 2>/dev/null; then
  fsks=$(awk -v m="$fsk" 'BEGIN { s = sprintf("%.1f", m / 1000); sub(/\./, ",", s); print s }')
  FSCKN="проверка /data при этой загрузке (fsck) заняла $fsks с (ro.boottime.init.fsck.data=$fsk): всё, что запускается после монтирования /data (модем, Wi-Fi, звук), началось на столько же позже, и все времена загрузки в отчёте сдвинуты; так бывает после выключения, при котором /data не был отмонтирован"
  FSCKS="$fsks с при этой загрузке (fsck): все времена загрузки в отчёте сдвинуты на столько же"
fi
psd=$(cat $W/pstore/console-* 2>/dev/null | grep -m1 -oE 'powerctl_shutdown_time_ms:[0-9]+:[0-9]+')
psr=$(cat $W/pstore/console-* 2>/dev/null | grep -m1 -oE "Received sys.powerctl='[^']*' from pid: [0-9]+ \([^)]*\)" | sed -E "s/Received sys.powerctl='([^']*)' from pid: [0-9]+ \(([^)]*)\)/\1, от \2/")
if cat $W/pstore/console-* 2>/dev/null | grep -q 'Umount /data failed' || [ "${psd##*:}" = 2 ]; then
  SHUTN="прошлое выключение${psr:+ ($psr)}: init не успел отмонтировать /data и выключил его через ioctl — обычный запасной путь Android${psd:+, выключение заняло $(echo "$psd" | cut -d: -f2) мс}; после такого выключения при загрузке может пройти полная проверка /data"
  SHUTS="прошлое${psr:+ ($psr)}: /data не отмонтирован вовремя, init выключил его через ioctl (запасной путь Android)"
elif [ -n "$psd" ]; then det "прошлое выключение${psr:+ ($psr)}: $psd (код ${psd##*:}; 2 — /data не отмонтирован вовремя)"; fi
[ -n "$FSCKN" ] && det "$FSCKN"
[ -n "$SHUTN" ] && det "$SHUTN"
pc=$(cat /sys/fs/pstore/console-ramoops* /sys/fs/pstore/dmesg-ramoops* 2>/dev/null | grep -m1 -E 'Kernel panic - not syncing|Internal error: Oops|Unable to handle kernel|Watchdog bark|watchdog bite|Fatal exception' | sed -E 's/^\[ *[0-9.]+\] *//' | cut -c1-140)
[ -n "$pc" ] && warn pstore "прошлая загрузка закончилась падением ядра: «$pc» (pstore/ в архиве)"
# the previous boot's kernel log (pstore console, masked copy): its kernel,
# whether it was a recovery boot, and its warnings, hung tasks and failed
# probes (always: not only when this boot is tainted)
PSPRB='WARNING: CPU|blocked for more than|Call trace|probe with driver .* failed|probe of .* failed with error'
for f in $W/pstore/console-*; do
  [ -f "$f" ] || continue
  pvl=$(grep -m1 'Linux version ' "$f")
  pv=$(printf '%s\n' "$pvl" | sed -nE 's/.*Linux version ([^ ]+).*/\1/p'); pb=$(printf '%s\n' "$pvl" | grep -oE '#[0-9]+ [A-Z]+[^)]*$' | cut -c1-60)
  prec=; grep -qE '\] recovery: ' "$f" && prec=", загрузка recovery"
  det "прошлая загрузка (pstore/${f##*/}): ядро ${pv:-?} ${pb:+($pb)}${prec:+; это была загрузка recovery}"
  pw=$(grep -c 'WARNING: CPU' "$f"); ph=$(grep -c 'blocked for more than' "$f"); pp=$(grep -cE 'probe with driver .* failed|probe of .* failed with error' "$f")
  if [ $((pw + ph + pp)) -gt 0 ]; then
    warn pstore "прошлая загрузка (ядро ${pv:-?}$prec): предупреждений ядра — $pw, зависших задач — $ph, неудачных probe — $pp (pstore/${f##*/}; первые строки — в подробностях)"
    det "--- прошлая загрузка: предупреждения, зависания, стеки, неудачные probe (первые 12)"
    grep -E "$PSPRB" "$f" | head -12 | cut -c1-200 >> $DET
  fi
done
if [ -n "$PREVLAST" ]; then
  if [ "${PREVLN:-0}" -gt 1 ]; then fail sysfs "прошлая глубокая проверка (deep) не закончилась: телефон упал, завис или перезагрузился, читая один из $PREVLN файлов, начиная с $PREVLAST (список — raw/prev-lastread.txt)"
    cp $TMPD/prev-lastread.txt $W/raw/prev-lastread.txt 2>/dev/null
  else fail sysfs "прошлая глубокая проверка (deep) не закончилась: телефон упал, завис или перезагрузился, читая $PREVLAST"; fi
fi

########################################################################
sec "3. Устройства: отложенные probe, узлы devicetree без драйвера"
DEF=$(rd /sys/kernel/debug/devices_deferred)
# DEFOK: nothing is deferred now, so every probe deferral in the kernel log
# (-517, the DSP loaders' "fail to get rproc" / "rproc not found" while they
# wait for their remoteproc) was resolved; such lines are then not counted as
# problems (DEFX)
DEFOK=; DEFX='-517|EPROBE_DEFER|fail to get rproc|rproc not found'
if [ -n "$DEF" ]; then
  echo "$DEF" | while read -r d rest; do [ -n "$d" ] && fail "устройства" "отложено навсегда (deferred probe): $d $rest"; done
  det "$DEF"
elif [ -e /sys/kernel/debug/devices_deferred ]; then
  DEFOK=1
  ok "устройства" "отложенных устройств нет"
else
  det "нет debugfs (/sys/kernel/debug/devices_deferred): отложенные probe не проверены"
fi
# platform devices with a devicetree node and no driver: the candidates by
# builtin tests, then the status and compatible of all of them in one read
# each (NULs as blanks; enabled = no status, "okay" or "ok")
: > $TMPD/nodrv.txt
for d in /sys/bus/platform/devices/*; do
  [ -e "$d/driver" ] && continue
  [ -e "$d/of_node" ] || continue
  echo "$d" >> $TMPD/nodrv.txt
done
OIFS=$IFS; IFS=$NL; set -f
tmo 20 grep -aH '' $(sed 's|$|/of_node/status|' $TMPD/nodrv.txt) 2>/dev/null < /dev/null | tr '\0' ' ' > $TMPD/nodrv-st.txt
tmo 20 grep -aH '' $(sed 's|$|/of_node/compatible|' $TMPD/nodrv.txt) 2>/dev/null < /dev/null | tr '\0' ' ' > $TMPD/nodrv-co.txt
set +f; IFS=$OIFS
n=$(awk -v sf=$TMPD/nodrv-st.txt -v cf=$TMPD/nodrv-co.txt -v df=$DET 'BEGIN {
    while ((getline l < sf) > 0) { p = index(l, "/of_node/status:"); if (p) { d = substr(l, 1, p - 1); v = substr(l, p + 16); sub(/ +$/, "", v); st[d] = v } }
    while ((getline l < cf) > 0) { p = index(l, "/of_node/compatible:"); if (p) { d = substr(l, 1, p - 1); v = substr(l, p + 20); sub(/ +$/, "", v); co[d] = co[d] (co[d] == "" ? "" : " ") v } } }
  { d = $0; if ((d in st) && st[d] != "okay" && st[d] != "ok") next; c = co[d]; if (c == "") next
    if (c ~ /^simple-bus|simple-bus|^syscon|regulator-fixed|qcom,iommu-debug|thermal-zones|fixed-clock|qcom,msm-dai-|qcom,msm-pcm/) next
    n++; sub(/.*\//, "", d); print "без драйвера: " d "  [" c "]" >> df }
  END { print n + 0 }' $TMPD/nodrv.txt)
[ "$n" -gt 0 ] && warn "устройства" "платформенных устройств, включённых в devicetree, без драйвера: $n (список — в подробностях)" || ok "устройства" "у всех включённых платформенных устройств с compatible есть драйвер"
n=0
for d in /sys/bus/i2c/devices/*-* /sys/bus/spi/devices/spi* /sys/bus/spmi/devices/*-*; do
  [ -e "$d" ] || continue
  [ -e "$d/driver" ] && continue
  case "${d##*/}" in i2c-[0-9]*|spi-[0-9]*|spmi-[0-9]*) continue;; esac
  n=$((n+1)); det "без драйвера: $d $(rd "$d/name")"
done
[ $n -gt 0 ] && warn "устройства" "устройств i2c/spi/spmi без драйвера: $n" || ok "устройства" "у всех устройств i2c/spi/spmi есть драйвер"

########################################################################
sec "4. Модули ядра"
det "загружено: $(wc -l < $W/raw/modules.txt)"
ML=/vendor/lib/modules/modules.load
if [ -f $ML ]; then
  miss=0
  for m in $(sed 's/.*\///; s/\.ko$//' $ML); do
    mm=$(echo $m | tr '-' '_')
    grep -q "^$mm " $W/raw/modules.txt && continue
    [ -d /sys/module/$mm ] && continue
    miss=$((miss+1)); det "модуля из списка прошивки нет (имя из 5.4, он может быть встроен или переименован): $m"
  done
  [ $miss -gt 0 ] && warn "модули" "не загружены модули из списка прошивки (/vendor/lib/modules): $miss (подробности)" || ok "модули" "все модули из списка прошивки есть"
else
  ok "модули" "прошивка без своих модулей (нет /vendor/lib/modules/modules.load); загружено модулей из vendor_boot: $(wc -l < $W/raw/modules.txt)"
fi
qrtr_scan
# the modules vendor_boot loads: the newest install log of this kernel names
# their count ("<n> in modules.load"); two of them netmgrd may unload
# (section 20)
NMODL=; [ -n "$in_l" ] && [ "$in_kr" = "$REL" ] && NMODL=$(sed -n 's/.* \([0-9][0-9]*\) in modules\.load.*/\1/p' "$in_l" | tail -n 1)
[ -n "$NMODL" ] && det "в modules.load vendor_boot — $NMODL модулей (журнал установки этого ядра), загружено сейчас: $NMOD"
if [ -z "$QPOS" ]; then
  if [ -d /sys/module/qrtr ] || zcat /proc/config.gz 2>/dev/null | grep -q '^CONFIG_QRTR=y'; then pok "модули" "qrtr встроен в ядро"
  else pfail "модули" "qrtr не загружен: нет QRTR/QMI вообще (модем, DSP, служба прошивки Wi-Fi)"; fi
else
  det "qrtr — модуль $((NMOD - QPOS + 1)) из $NMOD по порядку загрузки"
  if [ -n "$QLATE" ]; then pfail "модули" "qrtr.ko загружен после клиентов QMI:$QLATE (их QMI/PDR не создаются или откладываются при probe; в стоке qrtr встроен)"
  else pok "модули" "qrtr.ko загружен раньше всех клиентов QMI"; fi
fi
c=$(grep -cE "Unknown symbol|disagrees about version|module verification failed|init failed with|failed to load module|modprobe: .* failed" $W/raw/dmesg-nospam.txt)
[ $c -gt 0 ] && fail "модули" "в журнале ядра $c ошибок загрузки модулей" && grep -E "Unknown symbol|disagrees about version|module verification failed|init failed with|failed to load module" $W/raw/dmesg-nospam.txt | head -20 >> $DET

########################################################################
# the taoyao list for sections 5-7: the paths the ROM's ueventd rules, init
# scripts, post-boot script and SELinux policy name that are missing on
# taoyao by design. E: expected (hardware taoyao does not have, another SoC's
# or board's node, a legacy or userspace-only interface, a node that exists
# only at runtime (a USB host device, the rndis function) or under another
# instance name; also missing on stock 5.4). M: known gap (a 5.4 interface
# that 6.12 does not have: WALT and core_ctl, the 5.4 bw_hwmon/memlat
# devfreq, the native audio codec devices, synx, ramdump, rmnet_shs,
# coresight). From an Evolution X run of build 15 against the verdicts of
# the port's ROM ABI tables (rom-abi/check-*.tsv). A line: class, directory
# ("%/" is /sys/devices/platform/soc/), names in it; a ueventd /sys rule is
# <path>/<attribute>. Anything missing that is not here is "unexpected".
ABIEXP=$TMPD/abi-expected.txt
cat > $ABIEXP <<'ABIEOF'
E /dev/ cvp* diag hidraw* kvm membuf mhi_*_pipe_4 mtp_usb ppp qvr_external_sensor_ioctl radio0 tty0 uio1 uio2
E /dev/ v4l-touch*
M /dev/ msm_aac msm_aac_in msm_alac msm_amrnb msm_amrnb_in msm_amrwb msm_amrwb_in msm_amrwbplus msm_ape
M /dev/ msm_evrc msm_evrc_in msm_hweffects msm_multi_aac msm_qcelp msm_qcelp_in msm_wma msm_wmapro ramdump*
M /dev/ synx_device
E /dev/bus/usb/ *
E /dev/cpuctl/background/ cpu.rt_runtime_us
M /dev/cpuctl/background/ cpu.uclamp.colocate
E /dev/cpuctl/foreground/ cpu.rt_runtime_us
M /dev/cpuctl/foreground/ cpu.uclamp.colocate cpu.uclamp.sched_boost_no_override
E /dev/cpuctl/rt/ cpu.rt_runtime_us
E /dev/cpuctl/top-app/ cpu.rt_runtime_us
M /dev/cpuctl/top-app/ cpu.uclamp.colocate cpu.uclamp.sched_boost_no_override
E /dev/cpuset/audio-app/ cpus
E /dev/cpuset/camera-background/ cpus
E /dev/cpuset/camera-background/background/ cpus
E /dev/dma_heap/ system system-secure system-uncached
E /dev/graphics/ *
E /dev/stune/background/ cgroup.procs
E /dev/stune/top-app/ cgroup.procs
E /proc/ allocinfo lowmemorykiller timer_stats uid uid_concurrent_active_time uid_concurrent_policy_time
E /proc/ uid_cpupower uid_time_in_state vendor_sched
M /proc/ shs
E /proc/ath_pktlog/ cld
E /proc/cpu/ alignment
E /proc/debug/ fwdump
E /proc/device-tree/ avf
E /proc/net/ xt_qtaguid
E /proc/net/xt_qtaguid/ ctrl
E /proc/sys/kernel/ deny_new_usb hotplug
M /proc/sys/kernel/ sched_busy_hyst_ns sched_busy_hysteresis_enable_cpus
M /proc/sys/kernel/ sched_coloc_busy_hysteresis_enable_cpus sched_conservative_pl sched_downmigrate
M /proc/sys/kernel/ sched_group_downmigrate sched_group_upmigrate sched_latency_ns
M /proc/sys/kernel/ sched_min_task_util_for_boost sched_min_task_util_for_colocation sched_prefer_spread
M /proc/sys/kernel/ sched_task_unfilter_period sched_tunable_scaling sched_upmigrate
M /proc/sys/kernel/ sched_wakeup_granularity_ns sched_walt_rotate_big_tasks
E /proc/sys/vm/ extra_free_kbytes min_free_order_shift
M /proc/sys/vm/ kswapd_threads
M /proc/sys/walt/ sched_busy_hyst_ns sched_busy_hysteresis_enable_cpus sched_min_task_util_for_boost
M /proc/sys/walt/ sched_min_task_util_for_colocation sched_min_task_util_for_uclamp
E /sys/ android_touch
E /sys/block/mmcblk0/bdi/ read_ahead_kb
E /sys/block/mmcblk0rpmb/bdi/ read_ahead_kb
E /sys/block/sda/queue/iosched/ slice_idle
E /sys/block/sdb/queue/iosched/ slice_idle
E /sys/block/sdc/queue/iosched/ slice_idle
E /sys/block/sdd/queue/iosched/ slice_idle
E /sys/block/sde/queue/iosched/ slice_idle
E /sys/block/sdf/queue/iosched/ slice_idle
E /sys/block/zram0/ use_dedup
E /sys/bus/ esoc
E /sys/bus/msm_subsys/devices/subsys0/ restart_level
E /sys/bus/msm_subsys/devices/subsys1/ restart_level
E /sys/bus/msm_subsys/devices/subsys3/ restart_level
E /sys/bus/msm_subsys/devices/subsys4/ restart_level
E /sys/bus/msm_subsys/devices/subsys8/ restart_level
E /sys/bus/platform/devices/soc:fingerprint_fpc/ device_prepare finger_irq fingerdown_wait hw_reset irq
E /sys/bus/platform/devices/soc:fingerprint_fpc/ irq_enable power_cfg request_vreg simulate_irq vendor
E /sys/bus/platform/devices/soc:fingerprint_fpc/ wakeup_enable
E /sys/bus/thunderbolt/ devices
E /sys/class/ gpu lcd_bias sensors switch
E /sys/class/backlight/panel1-backlight/ brightness max_brightness
E /sys/class/drm/card0-DSI-1/ mipi_reg
E /sys/class/leds/vibrator/ trigger
E /sys/class/mi_display/disp-DSI-1/ disp_count
E /sys/class/net/rndis0/queues/rx-0/ rps_cpus
E /sys/class/qcom-battery/ is_old_hw reverse_chg_mode slave_authentic
E /sys/class/rfkill/rfkill2/ state
E /sys/class/rfkill/rfkill3/ state
E /sys/class/typec/ usbc0
E /sys/class/usb_notify/usb_control/ disable
M /sys/devices/ cs_etm
E /sys/devices/platform/ battery_current_limit
E /sys/devices/platform/dummy_hcd.0/usb1/ wakeup
E /sys/devices/platform/nfc-power/ nfc_power
E %/ 2c00000.qcom,kgsl-3d0 soc:fingerprint_fpc soc:fp_fpc1020 soc:qcom,gpubw soc:qcom,ipa_fws@1e08000
M %/ soc:qcom,cpu-cpu-llcc-bw soc:qcom,cpu-llcc-ddr-bw
E %/1610000.qcom,msm-eud/ extcon
E %/1628000.qcom,msm-eud/ extcon
E %/17300000.qcom,lpass/ wakeup
E %/17300000.qcom,lpass/subsys0/ name restart_level
E %/17300000.qcom,lpass/subsys4/ name restart_level
E %/17300000.qcom,lpass/subsys5/ name restart_level
E %/17300000.qcom,lpass/subsys6/ name restart_level wakeup
E %/17300000.qcom,lpass/subsys7/ name restart_level
M %/18590100.qcom,cpu0-cpu-l3-lat/ devfreq
E %/18590100.qcom,cpu1-cpu-l3-lat/ devfreq
E %/18590100.qcom,cpu2-cpu-l3-lat/ devfreq
E %/18590100.qcom,cpu3-cpu-l3-lat/ devfreq
M %/18590100.qcom,cpu4-cpu-l3-lat/ devfreq
E %/18590100.qcom,cpu5-cpu-l3-lat/ devfreq
E %/18590100.qcom,cpu6-cpu-l3-lat/ devfreq
M %/18590100.qcom,cpu7-cpu-l3-lat/ devfreq
M %/18590100.qcom,cpu7-cpu-l3-latfloor/ devfreq
M %/18590100.qcom,snoop-l3-bw/ devfreq
E %/188101c.qcom,spss/ wakeup
E %/188101c.qcom,spss/subsys10/ name restart_level
E %/188101c.qcom,spss/subsys5/ name restart_level wakeup
E %/188101c.qcom,spss/subsys7/ name restart_level
E %/188101c.qcom,spss/subsys8/ name restart_level
E %/188101c.qcom,spss/subsys9/ name restart_level
E %/1c00000.qcom,pcie/ wakeup
E %/1c00000.qcom,pcie/pci0000:00/0000:00:00.0/0000:01:00.0/ net
E %/1c00000.qcom,pcie/pci0000:00/0000:00:00.0/0000:01:00.0/1103_00.01.00/ wakeup
E %/1c00000.qcom,pcie/pci0000:00/0000:00:00.0/0000:01:00.0/net/wlan*/queues/rx-*/ rps_cpus
E %/1c08000.qcom,pcie/ wakeup
E %/1c08000.qcom,pcie/pci0001:00/0001:00:00.0/0001:01:00.0/0306_01.01.00_IP_HW0/ net
E %/1c40000.qcom,spmi/spmi-0/spmi0-02/1c40000.qcom,spmi:qcom,pm7250b@2:qcom,qpnp-smb5/ extcon
E %/1c40000.qcom,spmi/spmi-0/spmi0-02/1c40000.qcom,spmi:qcom,pm7250b@2:qcom,usb-pdphy@1700/ extcon
E %/1c40000.qcom,spmi/spmi-0/spmi0-02/1c40000.qcom,spmi:qcom,pmi632@2:qcom,qpnp-smb5/ extcon
E %/1d84000.ufshc/host0/target0:0:0/0:0:0:6/ scsi_generic
E %/1d84000.ufshc/host0/target0:0:0/0:0:0:7/ scsi_generic
E %/3700000.qcom,lpass/subsys3/ wakeup
E %/3700000.qcom,lpass/subsys4/ wakeup
E %/3700000.qcom,lpass/subsys5/ wakeup
E %/4080000.qcom,mss/subsys3/ name restart_level wakeup
E %/4080000.qcom,mss/subsys4/ name restart_level wakeup
E %/4080000.qcom,mss/subsys6/ name restart_level
E %/4080000.qcom,mss/subsys8/ wakeup
E %/4080000.qcom,mss/subsys9/ wakeup
E %/4e00000.ssusb/ mode usb_data_enabled
E %/5c00000.qcom,ssc/ wakeup
E %/5c00000.qcom,ssc/subsys4/ name restart_level
E %/5c00000.qcom,ssc/subsys6/ name restart_level
E %/5c00000.qcom,ssc/subsys7/ name restart_level wakeup
E %/5c00000.qcom,ssc/subsys8/ name restart_level
E %/5c00000.qcom,ssc/subsys9/ name restart_level
E %/5e00000.qcom,mdss_mdp/drm/card0/sde-crtc-0/ retire_frame_event
E %/5e00000.qcom,mdss_mdp/drm/card0/sde-crtc-1/ retire_frame_event
E %/5e00000.qcom,mdss_mdp/drm/card0/sde-crtc-2/ retire_frame_event
M %/6002000.stm/ coresight-stm
M %/6048000.tmc/ coresight-tmc-etr
M %/6b05000.tmc/ coresight-tmc-etf
M %/6b0f000.csr/ coresight-swao-csr
E %/800f000.qcom,spmi/spmi-0/spmi0-03/800f000.qcom,spmi:qcom,pmi8998@3:qcom,leds@d000/ leds
E %/884000.i2c/i2c-3/3-0028/ wakeup
E %/890000.qcom,qup_uart/ wakeup
E %/8c00000.hsusb/ wakeup
E %/984000.i2c/i2c-0/0-0028/ wakeup
E %/988000.i2c/i2c-1/1-0038/ trusted_touch_enable trusted_touch_event trusted_touch_type
E %/988000.spi/spi_master/spi0/spi0.0/ wakeup
E %/98900000.qcom,turing/ wakeup
E %/98900000.qcom,turing/subsys1/ name restart_level
E %/98900000.qcom,turing/subsys4/ wakeup
E %/98900000.qcom,turing/subsys5/ name restart_level
E %/98900000.qcom,turing/subsys6/ name restart_level
E %/98900000.qcom,turing/subsys7/ name restart_level
E %/98900000.qcom,turing/subsys8/ name restart_level
E %/990000.i2c/i2c-0/0-0038/ trusted_touch_enable trusted_touch_event trusted_touch_type
E %/990000.i2c/i2c-0/0-0049/ trusted_touch_enable trusted_touch_event trusted_touch_type
E %/990000.i2c/i2c-2/2-005a/ wakeup
E %/990000.qcom,qup_uart/ wakeup
E %/998000.i2c/i2c-0/0-005a/ wakeup
E %/a300000.qcom,turing/subsys5/ wakeup
E %/a300000.qcom,turing/subsys6/ wakeup
E %/a600000.ssusb/a600000.dwc3/xhci-hcd.2.auto/ usb
E %/a800000.ssusb/ mode usb_data_enabled wakeup
E %/a800000.ssusb/a800000.dwc3/udc/ a800000.dwc3
E %/a84000.i2c/i2c-1/1-0028/ wakeup
E %/a84000.i2c/i2c-3/3-0028/ wakeup
E %/a84000.i2c/i2c-3/3-005a/ wakeup
E %/a8c000.spi/spi_master/spi1/spi1.0/ wakeup
E %/a94000.i2c/i2c-0/0-0062/ trusted_touch_enable trusted_touch_event
E %/a94000.i2c/i2c-2/2-0062/ trusted_touch_enable trusted_touch_event
E %/aab0000.qcom,venus/ wakeup
E %/aab0000.qcom,venus/subsys0/ wakeup
E %/aab0000.qcom,venus/subsys10/ wakeup
E %/aab0000.qcom,venus/subsys3/ name restart_level
E %/aab0000.qcom,venus/subsys4/ name restart_level
E %/aab0000.qcom,venus/subsys5/ name restart_level wakeup
E %/aab0000.qcom,venus/subsys6/ wakeup
E %/aab0000.qcom,venus/subsys7/ wakeup
E %/aab0000.qcom,venus/subsys9/ wakeup
E %/abb0000.qcom,cvpss/subsys1/ name restart_level
E %/abb0000.qcom,cvpss/subsys3/ name restart_level
E %/abb0000.qcom,evass/ wakeup
E %/abb0000.qcom,evass/subsys1/ wakeup
E %/ae00000.qcom,mdss_mdp/c900000.qcom,mdss_mdp:qcom,mdss_fb_primary/ leds
E %/ae00000.qcom.qcom,mdss_mdp/ caps
E %/ae94000.qcom,mdss_dsi_ctrl0/uio/uio1/ name
E %/b0000000.qcom,cnss-qca6490/ fs_ready wakeup
E %/b0000000.qcom,cnss-qca6490/subsys10/ name restart_level wakeup
E %/b0000000.qcom,cnss-qca6490/subsys2/ name restart_level
E %/b0000000.qcom,cnss-qca6490/subsys4/ wakeup
E %/b0000000.qcom,cnss-qca6490/subsys5/ wakeup
E %/b0000000.qcom,cnss-qca6490/subsys6/ wakeup
E %/b0000000.qcom,cnss-qca6490/subsys7/ wakeup
E %/b0000000.qcom,cnss-qca6490/subsys8/ wakeup
E %/b0000000.qcom,cnss-qca6490/subsys9/ name restart_level wakeup
E %/c17a000.i2c/i2c-6/6-005a/ leds
E %/c1b5000.i2c/i2c-7/7-0030/ leds
E %/c440000.qcom,spmi/spmi-0/0-00/c440000.qcom,spmi:qcom,pmk8350@0:pon_hlos@1300/ wakeup
E %/c440000.qcom,spmi/spmi-0/0-00/c440000.qcom,spmi:qcom,pmk8350@0:pon_pbs@800/ wakeup
E %/c440000.qcom,spmi/spmi-0/0-00/c440000.qcom,spmi:qcom,pmk8350@0:rtc@6100/ wakeup
E %/c440000.qcom,spmi/spmi-0/0-00/c440000.qcom,spmi:qcom,pmk8350@0:rtc@6100/rtc/rtc0/ wakeup
E %/c440000.qcom,spmi/spmi-0/0-02/c440000.qcom,spmi:qcom,pm8350c@2:qcom,leds@ef00/leds/ blue green red
E %/c440000.qcom,spmi/spmi-0/0-03/c440000.qcom,spmi:qcom,pm7325b@3:qcom,vibrator@df00/leds/ vibrator
E %/c440000.qcom,spmi/spmi-0/0-09/c440000.qcom,spmi:qcom,pm7250b@3:qcom,vibrator@5300/leds/ vibrator
E %/c440000.qcom,spmi/spmi-0/spmi0-00/c440000.qcom,spmi:qcom,pm6150@0:qcom,qpnp-smb5/ extcon
E %/c440000.qcom,spmi/spmi-0/spmi0-00/c440000.qcom,spmi:qcom,pm6150@0:qcom,usb-pdphy@1700/ extcon
E %/c440000.qcom,spmi/spmi-0/spmi0-00/c440000.qcom,spmi:qcom,pmk8350@0:pon_pbs@800/ wakeup
E %/c440000.qcom,spmi/spmi-0/spmi0-02/c440000.qcom,spmi:qcom,pm7250b@2:qcom,qpnp-smb5/ extcon
E %/c440000.qcom,spmi/spmi-0/spmi0-02/c440000.qcom,spmi:qcom,pm7250b@2:qcom,usb-pdphy@1700/ extcon
E %/c440000.qcom,spmi/spmi-0/spmi0-02/c440000.qcom,spmi:qcom,pm8150b@2:qcom,qpnp-smb5/ extcon
E %/c440000.qcom,spmi/spmi-0/spmi0-02/c440000.qcom,spmi:qcom,pm8150b@2:qcom,usb-pdphy@1700/ extcon
E %/c440000.qcom,spmi/spmi-0/spmi0-03/c440000.qcom,spmi:qcom,pm7325b@3:qcom,vibrator@df00/leds/ vibrator
E %/c440000.qcom,spmi/spmi-0/spmi0-03/c440000.qcom,spmi:qcom,pm8350b@3:qcom,amoled-ecm@f900/ hwmon
E %/c440000.qcom,spmi/spmi-0/spmi0-03/c440000.qcom,spmi:qcom,pm8350b@3:qcom,amoled/ wakeup
E %/c440000.qcom,spmi/spmi-0/spmi0-08/c440000.qcom,spmi:qcom,pm7250b@2:qcom,power-on@800/ wakeup
E %/c440000.qcom,spmi/spmi-0/spmi0-09/c440000.qcom,spmi:qcom,pm7250b@3:qcom,vibrator@5300/leds/ vibrator
M %/soc:dummy_source/ coresight-modem-diag
E %/soc:extcon_usb1/ extcon
E %/soc:fingerprint_fpc/wakeup/ wakeup
E %/soc:goodix_fp/ wakeup
M %/soc:hwevent/ coresight-hwevent
M %/soc:qcom,cpu-cpu-llcc-bw/ devfreq
M %/soc:qcom,cpu-llcc-ddr-bw/ devfreq
M %/soc:qcom,cpu0-cpu-ddr-latfloor/ devfreq
M %/soc:qcom,cpu0-cpu-llcc-lat/ devfreq
M %/soc:qcom,cpu0-llcc-ddr-lat/ devfreq
M %/soc:qcom,cpu4-cpu-ddr-latfloor/ devfreq
M %/soc:qcom,cpu4-cpu-ddr-qoslat/ devfreq
M %/soc:qcom,cpu4-cpu-llcc-lat/ devfreq
M %/soc:qcom,cpu4-cpu-llcc-latfloor/ devfreq
M %/soc:qcom,cpu4-llcc-ddr-lat/ devfreq
M %/soc:qcom,cpu7-cpu-ddr-latfloor/ devfreq
M %/soc:qcom,cpu7-cpu-ddr-qoslatfloor/ devfreq
E %/soc:qcom,cpubw/ devfreq
E %/soc:qcom,dsi-display-primary/ acl cabc dc fod_hbm fod_ui hbm
E %/soc:qcom,gpubw/ devfreq
E %/soc:qcom,ipa_fws/ wakeup
E %/soc:qcom,ipa_fws/subsys0/ name restart_level wakeup
E %/soc:qcom,ipa_fws/subsys1/ wakeup
E %/soc:qcom,ipa_fws/subsys2/ name restart_level
E %/soc:qcom,ipa_fws/subsys3/ wakeup
E %/soc:qcom,kgsl-hyp/ wakeup
E %/soc:qcom,kgsl-hyp/subsys2/ name restart_level wakeup
E %/soc:qcom,kgsl-hyp/subsys3/ name restart_level wakeup
E %/soc:qcom,kgsl-hyp/subsys4/ name restart_level wakeup
E %/soc:qcom,kgsl-hyp/subsys6/ name restart_level
E %/soc:qcom,l3-cpu0/ devfreq
E %/soc:qcom,l3-cpu2/ devfreq
E %/soc:qcom,l3-cpu4/ devfreq
E %/soc:qcom,l3-cpu6/ devfreq
E %/soc:qcom,llccbw/ devfreq
E %/soc:qcom,memlat-cpu0/ devfreq
E %/soc:qcom,memlat-cpu2/ devfreq
E %/soc:qcom,memlat-cpu4/ devfreq
E %/soc:qcom,memlat-cpu6/ devfreq
E %/soc:qcom,mincpubw/ devfreq
E %/soc:qcom,msm-audio-apr/soc:qcom,msm-audio-apr:qcom,q6core-audio/soc:qcom,msm-audio-apr:qcom,q6core-audio:bolero-cdc/rx-macro/rx_swr_ctrl/ wakeup
E %/soc:qcom,msm-audio-apr/soc:qcom,msm-audio-apr:qcom,q6core-audio/soc:qcom,msm-audio-apr:qcom,q6core-audio:bolero-cdc/va-macro/va_swr_ctrl/ wakeup
E %/soc:qcom,msm-audio-apr/soc:qcom,msm-audio-apr:qcom,q6core-audio/soc:qcom,msm-audio-apr:qcom,q6core-audio:bolero-cdc/wsa-macro/wsa_swr_ctrl/ wakeup
E %/soc:qcom,msm-ext-disp/ extcon
E %/soc:qcom,msm-ext-disp/extcon/extcon0/ cable.1
E %/soc:qcom,msm-ext-disp/extcon/extcon1/ cable.1
E %/soc:qcom,qbt_handler/ wakeup
E %/soc:qcom,smp2p-cdsp/ wakeup
E %/soc:qcom,smp2p-dsps/ wakeup
E %/soc:qcom,smp2p-mpss/ wakeup
E %/soc:qcom,smp2p-npu/ wakeup
E %/soc:qcom,spcom/ wakeup
E %/soc:qcom,trustedvm@d0800000/ wakeup
E %/soc:qcom,trustedvm@d0800000/subsys0/ wakeup
E %/soc:qcom,trustedvm@d0800000/subsys1/ wakeup
E %/soc:qcom,trustedvm@d0800000/subsys2/ name restart_level wakeup
E %/soc:qcom,trustedvm@d0800000/subsys3/ name restart_level
E %/soc:qcom,wpss@8a00000/subsys3/ wakeup
E %/soc:qcom,wpss@8a00000/subsys4/ wakeup
E /sys/devices/platform/trusty.*/ trusty_version
E /sys/devices/soc/ 8c0000.qcom,msm-cam caa0000.qcom,jpeg caa4000.qcom,fd soc:bt_wcn3990
E /sys/devices/soc/800f000.qcom,spmi/spmi-0/spmi0-02/800f000.qcom,spmi:qcom,pmi8998@2:qcom,qpnp-smb2/power_supply/battery/ capacity
E /sys/devices/soc/800f000.qcom,spmi/spmi-0/spmi0-02/800f000.qcom,spmi:qcom,pmi8998@2:qcom,usb-pdphy@1700/usbpd0/ typec
E /sys/devices/soc/800f000.qcom,spmi/spmi-0/spmi0-02/800f000.qcom,spmi:qcom,pmi8998@2:qpnp,fg/power_supply/bms/ capacity
E /sys/devices/soc/a800000.ssusb/a800000.dwc3/xhci-hcd.0.auto/ usb1 usb2
E /sys/devices/soc/c1b7000.i2c/i2c-9/ 9-0008
E /sys/devices/soc/soc:hbtp/ secure_touch secure_touch_enable secure_touch_userspace
E /sys/devices/soc/soc:qcom,cpubw/ devfreq
E /sys/devices/soc/soc:qcom,memlat-cpu0/ devfreq
E /sys/devices/soc/soc:qcom,memlat-cpu2/ devfreq
E /sys/devices/soc/soc:qcom,memlat-cpu4/ devfreq
E /sys/devices/soc/soc:qcom,memlat-cpu6/ devfreq
E /sys/devices/soc/soc:qcom,mincpubw/ devfreq
M /sys/devices/system/cpu/cpu0/core_ctl/ enable
M /sys/devices/system/cpu/cpu4/ sched_load_boost
M /sys/devices/system/cpu/cpu4/core_ctl/ busy_down_thres busy_up_thres min_cpus not_preferred offline_delay_ms
M /sys/devices/system/cpu/cpu4/core_ctl/ task_thres
M /sys/devices/system/cpu/cpu5/ sched_load_boost
M /sys/devices/system/cpu/cpu6/ sched_load_boost
M /sys/devices/system/cpu/cpu7/ sched_load_boost
M /sys/devices/system/cpu/cpu7/core_ctl/ busy_down_thres busy_up_thres min_cpus nr_prev_assist_thresh
M /sys/devices/system/cpu/cpu7/core_ctl/ offline_delay_ms task_thres
M /sys/devices/system/cpu/cpu_boost/ input_boost_freq input_boost_ms
M /sys/devices/system/cpu/cpufreq/policy0/schedutil/ down_rate_limit_us hispeed_freq pl rtg_boost_freq
M /sys/devices/system/cpu/cpufreq/policy0/schedutil/ up_rate_limit_us
M /sys/devices/system/cpu/cpufreq/policy4/schedutil/ down_rate_limit_us hispeed_freq hispeed_load pl
M /sys/devices/system/cpu/cpufreq/policy4/schedutil/ rtg_boost_freq up_rate_limit_us
M /sys/devices/system/cpu/cpufreq/policy7/schedutil/ down_rate_limit_us hispeed_freq hispeed_load pl
M /sys/devices/system/cpu/cpufreq/policy7/schedutil/ rtg_boost_freq up_rate_limit_us
M /sys/devices/system/cpu/memlat/c0_memlat/ cpu0-cpu-l3-lat
M /sys/devices/system/cpu/memlat/c4_memlat/ cpu4-cpu-l3-lat
M /sys/devices/system/cpu/memlat/c7_memlat/ cpu7-cpu-l3-lat
E /sys/devices/system/soc/soc0/ id
E /sys/devices/virtual/ switch wahoo_laser
E /sys/devices/virtual/block/ ublk zram1
E /sys/devices/virtual/block/zram1/ uevent
E /sys/devices/virtual/cvp/cvp/ boot
E /sys/devices/virtual/diag/diag/ wakeup
E /sys/devices/virtual/fts/ touch_aoi
E /sys/devices/virtual/graphics/ fb0 fb1
E /sys/devices/virtual/graphics/fb0/ acl aco cabc color_enhance hbm hist_event reading_mode rgb sre
E /sys/devices/virtual/input/ ftm4_touch
E /sys/devices/virtual/input/input*/ enable poll_delay
M /sys/devices/virtual/misc/msm_aac/ wakeup
M /sys/devices/virtual/misc/msm_alac/ wakeup
M /sys/devices/virtual/misc/msm_amrnb/ wakeup
M /sys/devices/virtual/misc/msm_amrwb/ wakeup
M /sys/devices/virtual/misc/msm_amrwbplus/ wakeup
M /sys/devices/virtual/misc/msm_ape/ wakeup
M /sys/devices/virtual/misc/msm_evrc/ wakeup
M /sys/devices/virtual/misc/msm_g711alaw/ wakeup
M /sys/devices/virtual/misc/msm_g711mlaw/ wakeup
M /sys/devices/virtual/misc/msm_mp3/ wakeup
M /sys/devices/virtual/misc/msm_multi_aac/ wakeup
M /sys/devices/virtual/misc/msm_qcelp/ wakeup
M /sys/devices/virtual/misc/msm_wma/ wakeup
M /sys/devices/virtual/misc/msm_wmapro/ wakeup
E /sys/devices/virtual/misc/uhid/*/leds/*/ brightness multi_intensity
E /sys/devices/virtual/net/bond0/bonding/ queue_id
E /sys/devices/virtual/net/bond0/queues/rx-0/ rps_cpus
E /sys/devices/virtual/npu/msm_npu/ pwr
E /sys/devices/virtual/timed_output/ vibrator
E /sys/devices/virtual/timed_output/vibrator/ enable
E /sys/devices/virtual/usb_composite/*/ enable
M /sys/devices/virtual/workqueue/kgsl-events/ cpumask nice
E /sys/firmware/acpi/ tables
E /sys/firmware/devicetree/base/ avf
E /sys/kernel/ boot_slpi ipv4 mem-offline memory_state_time qvr_external_sensor uevent_helper vendor_sched
E /sys/kernel/ wcd_cpe0
E /sys/kernel/boot_slpi/ boot ssr
E /sys/kernel/debug/pmic-votable/USB_ICL/ force_active force_val
E /sys/kernel/hbtp/ display_pwr
E /sys/kernel/irq_helper/ irq_blacklist_on
E /sys/kernel/load_guestvm/ boot_guestvm
E /sys/kernel/slab/zs_handle/ store_user
E /sys/kernel/slab/zspage/ store_user
E /sys/kernel/wcd_cpe0/ fw_name
E /sys/kernel/wdsp0/ boot
E /sys/module/ diagchar lowmemorykiller lpm_levels lpm_stats msm_thermal
M /sys/module/ cpu_boost subsystem_restart
E /sys/module/diagchar/parameters/ timestamp_switch
E /sys/module/lpm_levels/parameters/ sleep_disabled
E /sys/module/msm_thermal/core_control/ cpus_offlined
M /sys/module/rmnet_perf/ parameters
E /sys/power/ autosleep
ABIEOF
# abicls <missing list>: the list with each line's class in front ("E ",
# "M " or "U "); the path is what follows the first ": " up to " (", with a
# blank (ueventd: path and attribute) read as "/"
abicls() {
  awk -v ef=$ABIEXP 'BEGIN { while ((getline l < ef) > 0) { n = split(l, a, " "); if (n < 3) continue
                               d = a[2]; sub(/^%\//, "/sys/devices/platform/soc/", d); for (i = 3; i <= n; i++) x[d a[i]] = a[1] } }
    { k = $0; sub(/^[^:]*: /, "", k); sub(/ +\(.*$/, "", k); gsub(/ /, "/", k); sub(/\/+$/, "", k)
      print ((k in x) ? x[k] : "U"), $0 }' "$1"
}
# abidet <classified list>: to the details, unexpected first
abidet() { grep '^U ' "$1" >> $DET; grep '^M ' "$1" >> $DET; grep '^E ' "$1" >> $DET; }

########################################################################
sec "5. Узлы устройств и правила sysfs из ueventd.rc"
nm=0; ns=0
for f in $UEV_FILES; do
  det "--- $f"
  grep -E '^[[:space:]]*/dev/' $f | awk '{print $1}' | sort -u | while read -r p; do
    exists "$p" || { echo "нет /dev: $p ($f)" >> $W/raw/uevent-missing.txt; }
  done
  grep -E '^[[:space:]]*/sys/' $f | awk '{print $1" "$2}' | sort -u | while read -r p a; do
    found=0; for e in $p; do [ -e "$e/$a" ] && { found=1; break; }; done
    [ $found = 1 ] || echo "нет /sys: $p $a ($f)" >> $W/raw/uevent-missing.txt
  done
done
ue=0; um=0; uu=0
if [ -f $W/raw/uevent-missing.txt ]; then
  abicls $W/raw/uevent-missing.txt > $TMPD/uev-cls.txt && mv -f $TMPD/uev-cls.txt $W/raw/uevent-missing.txt
  nm=$(grep -c ' нет /dev' $W/raw/uevent-missing.txt); ns=$(grep -c ' нет /sys' $W/raw/uevent-missing.txt)
  ue=$(grep -c '^E ' $W/raw/uevent-missing.txt); um=$(grep -c '^M ' $W/raw/uevent-missing.txt); uu=$(grep -c '^U ' $W/raw/uevent-missing.txt)
  det "правил /dev без узла: $nm, правил /sys без узла: $ns; из них ожидаемо $ue, известные пробелы $um, неожиданно $uu (буква в начале строки: U — неожиданно, M — известный пробел, E — ожидаемо)"
  abidet $W/raw/uevent-missing.txt
fi
if [ "$uu" -gt 0 ]; then warn ueventd "$uu правил ueventd прошивки не находят узла и не входят в список taoyao (ожидаемо $ue, известные пробелы $um, неожиданно $uu; подробности)"
elif [ "$nm" = 0 ] && [ "$ns" = 0 ]; then ok ueventd "каждое правило ueventd находит свой узел"
else ok ueventd "каждое правило ueventd находит узел, кроме списка taoyao: ожидаемо $ue (оборудования нет у taoyao, другие SoC), известные пробелы $um, неожиданных нет"; fi

########################################################################
sec "6. Пути /sys /proc /dev из init-скриптов прошивки"
: > $W/raw/rc-paths.txt
set -f
for f in $RC_FILES; do
  grep -nE '^[[:space:]]*(write|chmod|chown|mkdir|symlink|copy|rm)[[:space:]]' $f 2>/dev/null | while IFS= read -r line; do
    ln=${line%%:*}; cmd=${line#*:}
    set -- $cmd
    case "$1" in
      write) p=$2;; chmod) p=$3;; chown) p=$4;; *) continue;;
    esac
    case "$p" in /sys/*|/proc/*|/dev/*) ;; *) continue;; esac
    case "$p" in *'${'*|*'$'*) continue;; esac
    echo "$p ${f##*/}:$ln" >> $W/raw/rc-paths.txt
  done
done
set +f
miss=0
sort -u -k1,1 $W/raw/rc-paths.txt | while read -r p where; do
  exists "$p" || echo "нет: $p  ($where)"
done > $W/raw/rc-missing.txt
abicls $W/raw/rc-missing.txt > $TMPD/rc-cls.txt && mv -f $TMPD/rc-cls.txt $W/raw/rc-missing.txt
miss=$(grep -c . $W/raw/rc-missing.txt)
ie=$(grep -c '^E ' $W/raw/rc-missing.txt); im=$(grep -c '^M ' $W/raw/rc-missing.txt); iu=$(grep -c '^U ' $W/raw/rc-missing.txt)
det "проверено разных путей: $(sort -u -k1,1 $W/raw/rc-paths.txt | grep -c .); нет $miss (ожидаемо $ie, известные пробелы $im, неожиданно $iu)"
abidet $W/raw/rc-missing.txt
if [ "$iu" -gt 0 ]; then warn init "$iu путей /sys /proc /dev из init-скриптов прошивки не существуют и их нет в списке taoyao (ожидаемо $ie, известные пробелы $im, неожиданно $iu; подробности)"
elif [ "$miss" -gt 0 ]; then ok init "все пути из init-скриптов прошивки существуют, кроме списка taoyao: ожидаемо $ie, известные пробелы $im (WALT), неожиданных нет"
else ok init "все пути из init-скриптов прошивки существуют"; fi
# the vendor's post-boot tuning script (init.qti.kernel.rc runs it once at
# boot; the one for yupik, else whichever the vendor has): the /sys, /proc
# and /dev files its echo lines write (not those built from variables)
PBF=$(ls /vendor/bin/init.kernel.post_boot-yupik.sh 2>/dev/null); [ -z "$PBF" ] && PBF=$(ls /vendor/bin/init.kernel.post_boot*.sh 2>/dev/null)
: > $W/raw/postboot-missing.txt; npb=0
for f in $PBF; do
  grep -oE 'echo [^>|;&]*> *"?/(sys|proc|dev)/[^ ;|&"]+' $f 2>/dev/null | sed -E 's/.*> *"?//' | grep -v '[$]' | sort -u > $TMPD/postboot.txt
  npb=$((npb + $(grep -c . $TMPD/postboot.txt)))
  while read -r p; do exists "$p" || echo "нет: $p  (${f##*/})"; done < $TMPD/postboot.txt >> $W/raw/postboot-missing.txt
done
if [ -n "$PBF" ]; then
  abicls $W/raw/postboot-missing.txt > $TMPD/pb-cls.txt && mv -f $TMPD/pb-cls.txt $W/raw/postboot-missing.txt
  pbm=$(grep -c . $W/raw/postboot-missing.txt)
  pe=$(grep -c '^E ' $W/raw/postboot-missing.txt); pm=$(grep -c '^M ' $W/raw/postboot-missing.txt); pu=$(grep -c '^U ' $W/raw/postboot-missing.txt)
  det "--- скрипт post-boot $(echo $PBF): пишет путей $npb, нет $pbm (ожидаемо $pe, известные пробелы $pm, неожиданно $pu)"
  abidet $W/raw/postboot-missing.txt
  if [ "$pu" -gt 0 ]; then warn init "$pu из $npb путей /sys /proc /dev, которые пишет скрипт post-boot прошивки, не существуют и их нет в списке taoyao (ожидаемо $pe, известные пробелы $pm, неожиданно $pu; подробности)"
  else ok init "скрипт post-boot прошивки пишет $npb путей: нет $pbm, все из списка taoyao (ожидаемо $pe, известные пробелы $pm: WALT, core_ctl, настройки schedutil из 5.4; неожиданных нет)"; fi
fi

########################################################################
sec "7. Пути SELinux genfscon из политики"
: > $W/raw/genfs-missing.txt
tot=0
# (the paths are quoted in plat and system_ext, not in stock HyperOS's
# vendor_sepolicy.cil; genfscon labels by string prefix, so a path counts as
# there if anything starts with it)
for cil in /vendor/etc/selinux/vendor_sepolicy.cil /odm/etc/selinux/odm_sepolicy.cil /system/etc/selinux/plat_sepolicy.cil \
           /system_ext/etc/selinux/system_ext_sepolicy.cil /product/etc/selinux/product_sepolicy.cil; do
  [ -f $cil ] || continue
  grep -oE '\(genfscon (sysfs|proc) "?[^" ()]+' $cil | sed -E 's/\(genfscon (sysfs|proc) "?/\1 /' | sort -u > $TMPD/genfs.txt
  gn=0; gx=0
  while read -r fs p; do
    gn=$((gn+1))
    case $fs in sysfs) q=/sys$p;; proc) q=/proc$p;; esac
    [ -e "$q" ] || ls -d "$q"* >/dev/null 2>&1 || { gx=$((gx+1)); echo "нет пути с меткой: $q (${cil##*/})" >> $W/raw/genfs-missing.txt; }
  done < $TMPD/genfs.txt
  tot=$((tot+gn)); det "$cil: записей genfscon $gn, нет $gx"
done
abicls $W/raw/genfs-missing.txt > $TMPD/genfs-cls.txt && mv -f $TMPD/genfs-cls.txt $W/raw/genfs-missing.txt
gm=$(grep -c . $W/raw/genfs-missing.txt)
ge=$(grep -c '^E ' $W/raw/genfs-missing.txt); gk=$(grep -c '^M ' $W/raw/genfs-missing.txt); gu=$(grep -c '^U ' $W/raw/genfs-missing.txt)
det "проверено путей genfscon: $tot; нет $gm (ожидаемо $ge, известные пробелы $gk, неожиданно $gu)"; abidet $W/raw/genfs-missing.txt
if [ "$gu" -gt 0 ]; then warn genfs "$gu из $tot путей sysfs/proc с метками политики не существуют даже как префикс и их нет в списке taoyao (ожидаемо $ge, известные пробелы $gk, неожиданно $gu): файлы, что там есть, получают общую метку (подробности)"
elif [ "$gm" -gt 0 ]; then ok genfs "все $tot путей genfscon существуют, кроме списка taoyao: ожидаемо $ge, известные пробелы $gk, неожиданных нет"
else ok genfs "все $tot путей genfscon существуют"; fi

########################################################################
sec "8. Службы"
if [ -n "$RC_FILES" ]; then grep -hE '^service ' $RC_FILES 2>/dev/null | awk '{print $2}' | sort -u; fi > $W/raw/vendor-services.txt
nr=0
while read -r s; do
  st=$(getprop init.svc.$s)
  case "$st" in restarting) fail "службы" "$s перезапускается по кругу"; nr=$((nr+1));; esac
done < $W/raw/vendor-services.txt
# keys and credential storage (QTEE through smcinvoke/qseecom): /data's
# credential-encrypted storage unlocks only through them
for s in keystore2 vendor.keymaster-4-1 vendor.qseecomd; do
  st=$(getprop init.svc.$s)
  [ -z "$st" ] && continue
  [ "$st" = running ] && ok "ключи" "$s работает" || fail "ключи" "$s в состоянии «$st»: от неё зависят ключи и зашифрованная память"
done
ce=$(getprop sys.user.0.ce_available)
[ "$ce" = true ] && ok "ключи" "зашифрованная память пользователя 0 разблокирована" || warn "ключи" "sys.user.0.ce_available=«$ce» (так бывает до первой разблокировки после включения; иначе не сработали keymaster/QTEE)"
# (the one check of smcinvoke/qseecom errors: section 12b points here; any
# case, the qseecom driver prefixes its lines with "QSEECOM:")
QTEEE='invalid rootenv op|smcinvoke.*(fail|err)|qseecom.*(fail|err)'
NQTEEE=$(grep -ciE "$QTEEE" $W/raw/dmesg-nospam.txt)
[ "$NQTEEE" -gt 0 ] && { warn "ключи" "в журнале ядра $NQTEEE ошибок smcinvoke/qseecom"; grep -iE "$QTEEE" $W/raw/dmesg-nospam.txt | sed -E 's/^\[ *[0-9.]+\] *//' | sort | uniq -c | sort -rn | head -10 >> $DET; }
# crash loops seen in the kernel log (init logs every service exit there;
# raw/service-exits.txt has them all). Not counted: exits init caused itself
# (its "Sending signal N to service 'x' (pid P)" comes first: a stop or
# restart, Wi-Fi or the hotspot turned off) and clean exits (status 0:
# oneshot and on-demand services)
sed -nE "s/.*init: Sending signal [0-9]+ to service '[^']+' \(pid ([0-9]+)\).*/K \1/p; s/.*init: Service '([^']+)' \(pid ([0-9]+)\) (received signal [0-9]+|exited with status [0-9]+).*/E \2 \1 \3/p" $W/raw/dmesg-nospam.txt > $TMPD/svc-exits.txt
awk '$1 == "E" { $1 = $2 = ""; sub(/^ +/, ""); print }' $TMPD/svc-exits.txt | sort | uniq -c | sort -rn > $W/raw/service-exits.txt
awk '$1 == "K" { k[$2] = 1; next } $1 == "E" && !($2 in k) && $NF != "0" { $1 = $2 = ""; sub(/^ +/, ""); print }' $TMPD/svc-exits.txt | sort | uniq -c | sort -rn > $TMPD/svc-crashes.txt
while read -r c s why; do
  [ "$c" -ge 3 ] && fail "службы" "$s завершалась $(pl $c "раз" "раза" "раз") ($why)"
done < $TMPD/svc-crashes.txt
cat $W/raw/service-exits.txt >> $DET
[ $nr = 0 ] && ok "службы" "ни одна служба vendor сейчас не перезапускается по кругу (служб vendor: $(grep -c . $W/raw/vendor-services.txt))"

########################################################################
sec "9. Сбои: tombstones, ANR, журнал сбоев"
BOOT=$(( $(date +%s) - $(cut -d. -f1 /proc/uptime) ))
# a tombstone is this boot's if the running kernel wrote it (its header line
# "Kernel Release: '<uname -r>'", since Android 12) and it is dated after the
# boot. Early in the boot the clock still reads 1970 until Android sets it
# (taoyao's /dev nodes carry 1970-01-24): one dated before 2001 counts if its
# kernel release is this one (it may then also be from an earlier boot of
# the same kernel). Those of another kernel are only listed in the details.
nt=0
for f in $(ls -t /data/tombstones/tombstone_* 2>/dev/null | grep -v '\.pb$'); do
  tmt=$(stat -c %Y $f 2>/dev/null || echo 0)
  tkr=$(grep -m1 '^Kernel Release: ' $f | sed -E "s/^Kernel Release: '?([^']*)'?.*/\1/")
  cmdl=$(grep -m1 '^Cmdline:' $f | cut -d' ' -f2-)
  sig=$(grep -m1 '^signal ' $f | sed -E 's/, fault addr.*//; s/, sender .*//' | cut -c1-80)
  tdt=$(date -d @$tmt '+%d.%m.%Y %H:%M' 2>/dev/null)
  if [ -n "$tkr" ] && [ "$tkr" != "$REL" ]; then
    det "от ядра $tkr (прошлая загрузка, ${tdt:-?}): $f ($cmdl: $sig)"
    continue
  fi
  early=
  if [ "$tmt" -lt "$BOOT" ]; then
    if [ "$tmt" -lt 1000000000 ] && [ -n "$tkr" ]; then
      early=", дата до 2001 года: записан в начале загрузки этого ядра"
    elif [ "$tmt" -lt 1000000000 ]; then
      det "дата до 2001 года, нет строки Kernel Release: $f ($cmdl: $sig; записан до установки часов при загрузке — в этой загрузке или раньше)"
      continue
    else
      det "старше этой загрузки (${tdt:-?}): $f${tkr:+ (ядро $tkr)}"
      continue
    fi
  fi
  nt=$((nt + 1))
  top=$(grep -m1 -E '^ +#00 pc' $f | awk '{print $4}')
  fail "сбои" "$cmdl: $sig в $top ($(basename $f)$early)"
  det "=== $f"; tomb $f 60 >> $DET
done
# native crashes in logcat (this boot, or since "prep") against the
# tombstones counted above
nfs=$(grep -cE ' F libc +: Fatal signal ' $W/raw/logcat.txt)
if [ "$nfs" -gt "$nt" ]; then
  warn "сбои" "в logcat $nfs нативных падений (Fatal signal), а tombstone этой загрузки и этого ядра — только $nt (остальные удалены по ротации или не записаны, или датированы 1970 без строки Kernel Release; подробности)"
  det "--- нативные падения в logcat"
  grep -E ' F libc +: Fatal signal | F DEBUG +: (pid: [0-9]+, tid: [0-9]+, name: .*>>> .* <<<|Cmdline: )' $W/raw/logcat.txt | head -40 >> $DET
fi
ca=$(grep -c 'FATAL EXCEPTION' $W/raw/logcat.txt)
[ "$ca" -gt 0 ] && warn "сбои" "в logcat $ca падений Java" && grep -A3 'FATAL EXCEPTION' $W/raw/logcat.txt | head -40 >> $DET
for a in $(ls /data/anr 2>/dev/null); do [ "$(stat -c %Y /data/anr/$a 2>/dev/null || echo 0)" -ge "$BOOT" ] && warn "сбои" "ANR $a"; done

########################################################################
sec "10. Отказы SELinux"
# the kernel log, logcat (auditd) and the events log carry the same denial:
# once per audit serial (the number after the colon in audit(<time>:<n>));
# one without a serial (servicemanager's own denials: a kernel log line and
# auditd's logcat line) once per permission, process, name and class. With
# a first file avc.txt (the end of the run), its denials are only noted
AVCAWK=$TMPD/avc.awk
cat > $AVCAWK <<'EOF'
{ if (match($0, /audit\([0-9.]+:[0-9]+\)/)) { k = substr($0, RSTART, RLENGTH); sub(/.*:/, "", k); k = "a" k }
  else {
    k = "k"; if (match($0, /\{[^}]*\}/)) k = k substr($0, RSTART, RLENGTH)
    k = k "|"; if (match($0, / pid=[0-9]+/)) k = k substr($0, RSTART, RLENGTH)
    k = k "|"; if (match($0, / (name|interface)=[^ ]+/)) k = k substr($0, RSTART, RLENGTH)
    k = k "|"; if (match($0, /tclass=[a-z_]+/)) k = k substr($0, RSTART, RLENGTH)
  }
  if (seen[k]++) next
  if (old != "" && FILENAME == old) next
  print }
EOF
{ grep -h 'avc:  denied' $W/raw/dmesg-nospam.txt; grep -h 'avc:  denied' $W/raw/logcat.txt; grep 'avc:  denied' $W/raw/events.txt; } > $TMPD/avc-all.txt
awk -f $AVCAWK $TMPD/avc-all.txt > $W/raw/avc.txt
det "строк отказов: $(grep -c . $TMPD/avc-all.txt), уникальных (по номеру audit, а без номера — по процессу, имени и классу): $(grep -c . $W/raw/avc.txt)"
# (the target can be a process domain, u:r:<domain>, as well as a type)
AVCSED='s/.*avc:  denied  \{ ([^}]*) \}.*scontext=u:r:([^:]+):s0.*tcontext=u:(object_)?r:([^:]+):s0.*tclass=([a-z_]+).*/\2 \4 \5 { \1}/p'
sed -nE "$AVCSED" $W/raw/avc.txt | sort | uniq -c | sort -rn > $W/raw/avc-grouped.txt
# records the kernel's audit rate limit dropped (audit: audit_lost=N, the
# total so far): the last value, and where it jumped by more than 20; the
# denials listed are then a lower bound. alost <kernel log>...: last|time|jumps
alost() {
  cat "$@" 2>/dev/null | awk '/audit: audit_lost=[0-9]/ { t = $0; if (!sub(/^\[ */, "", t)) next; sub(/\].*/, "", t); v = $0; sub(/.*audit_lost=/, "", v); sub(/[^0-9].*/, "", v); v += 0
      if (n && v - pv > 20) j = j sprintf("%s%d -> %d (%.1f-%.1f с)", (j == "" ? "" : ", "), pv, v, pt, t)
      pv = v; pt = t; n++ }
    END { if (n) printf "%d|%.1f|%s\n", pv, pt, j }'
}
AL=$(alost $W/raw/dmesg-nospam.txt); AVLB=
if [ -n "$AL" ]; then
  # (the | quoted: mksh, the phone's sh, reads a bare | in a pattern as "or")
  al_j=${AL##*\|}; al_v=${AL%%\|*}; al_t=${AL#*\|}; al_t=${al_t%%\|*}
  AVLB="; записей аудита ядро не сохранило: $al_v (audit_lost), так что отказов могло быть больше"
  det "записи аудита, которые ядро не сохранило из-за ограничения частоты (audit_lost): $al_v к $al_t с${al_j:+; скачки больше 20: $al_j}. Отказы ниже — нижняя граница"
fi
# apps (root and emulator probes of banking apps, browsers, GMS): info only;
# the daemons' denials count
APPDOM='^(untrusted_app|isolated_app|sdk_sandbox)|^(ephemeral_app|gmscore_app|priv_app)$'
awk -v ad="$APPDOM" '$2 !~ ad' $W/raw/avc-grouped.txt > $TMPD/avc-daemon.txt
awk -v ad="$APPDOM" '$2 ~ ad' $W/raw/avc-grouped.txt > $TMPD/avc-app.txt
na=$(grep -c . $W/raw/avc-grouped.txt); nd=$(grep -c . $TMPD/avc-daemon.txt); nap=$(grep -c . $TMPD/avc-app.txt)
det "разных отказов: $na (служб: $(pl $nd "вид" "вида" "видов"), приложений: $(pl $nap "вид" "вида" "видов"))"
# denials of daemons on generic labels (a kernel path or device the ROM's
# policy does not know; apps probing /proc get them on any kernel), with the
# path of each sysfs file found by its inode: the wakeup sources' files
# first (system_suspend reads them), then one search of /sys (directories
# only, no file is read; at most 20 inodes). Known gaps: system_suspend on
# the files of ssr(wpss) under wpss@8a00000/subsysN/wakeup/ (the ROM's
# policy has no label for it, stock has the same gap; port kernels from
# 0.20 put it on wpss@8a00000/wakeup/, which the policy labels, so there it
# is no longer known) and under the display's ae00000.qcom,mdss_mdp (section 18).
# avcgen <avc file> <prefix>: <prefix>-gen.txt, <prefix>-genr.txt
# (TAB-separated: domain, label, class, name, path or inode, K for a known
# gap, its text), <prefix>-gen-new.txt and <prefix>-gen-known.txt (the kinds,
# "domain label class", with a denial that is not a known gap, and with
# known gaps only); the inode map avc-ino.txt grows from call to call
GENT='sysfs|device|proc|debugfs|sysfs_devices_system_cpu|unlabeled'
AVKW=1; [ -n "$PORT" ] && [ -n "$KBUILD" ] && [ "$KBUILD" -ge 20 ] 2>/dev/null && AVKW=
AVWK=; : > $TMPD/avc-ino.txt
avcgen() {
  ag_p=$2
  sed -nE 's/.*avc:  denied  \{ [^}]*\}.*scontext=u:r:([^:]+):s0.*tcontext=u:object_r:([^:]+):s0.*tclass=([a-z_]+).*/\1 \2 \3 &/p' "$1" |
    awk -v ad="$APPDOM" -v gt="^($GENT)\$" '$1 !~ ad && $2 ~ gt { nm = "-"; dv = "-"; ino = "-"
        if (match($0, /name="[^"]*"/)) nm = substr($0, RSTART + 6, RLENGTH - 7)
        if (match($0, /dev="[^"]*"/)) dv = substr($0, RSTART + 5, RLENGTH - 6)
        if (match($0, /ino=[0-9]+/)) ino = substr($0, RSTART + 4, RLENGTH - 4)
        gsub(/ /, "_", nm); print $1, $2, $3, nm, dv, ino }' > $ag_p-gen.txt
  if grep -q ' sysfs [0-9][0-9]*$' $ag_p-gen.txt; then
    if [ -z "$AVWK" ] && awk '$5 == "sysfs" && $4 ~ /^(name|active_count|event_count|wakeup_count|expire_count|active_time_ms|total_time_ms|max_time_ms|last_change_ms|prevent_suspend_time_ms)$/ { f = 1 } END { exit !f }' $ag_p-gen.txt; then
      AVWK=1
      for w in /sys/class/wakeup/wakeup*; do
        [ -e "$w" ] || continue
        wp=$(readlink -f "$w"); ls -i "$wp/" 2>/dev/null | awk -v p="$wp" 'NF == 2 { print $1, p "/" $2 }'
      done >> $TMPD/avc-ino.txt
    fi
    # (the inodes found so far read in BEGIN: the file may be empty)
    awk -v rf=$TMPD/avc-ino.txt 'BEGIN { while ((getline l < rf) > 0) { split(l, x, " "); r[x[1]] = 1 } }
      $5 == "sysfs" && $6 ~ /^[0-9]+$/ && !($6 in r) && !s[$6]++ { print $6 }' $ag_p-gen.txt | head -20 > $TMPD/avc-unres.txt
    if [ -s $TMPD/avc-unres.txt ]; then
      # (digits and -inum/-o only: split as words)
      fa=$(awk '{ printf "%s-inum %s ", (NR > 1 ? "-o " : ""), $1 }' $TMPD/avc-unres.txt)
      tmo 30 find /sys -xdev \( $fa \) 2>/dev/null | head -40 | while IFS= read -r fp; do echo "$(ls -id "$fp" 2>/dev/null | awk '{ print $1 }') $fp"; done >> $TMPD/avc-ino.txt
    fi
  fi
  awk -v rf=$TMPD/avc-ino.txt -v kw="$AVKW" 'BEGIN { while ((getline l < rf) > 0) { k = l; sub(/ .*/, "", k); if (!(k in p)) p[k] = substr(l, length(k) + 2) } }
    { path = ($5 == "sysfs" && ($6 in p)) ? p[$6] : ""; kn = ""
      if (kw && $1 == "system_suspend" && path ~ /\/soc:qcom,wpss@8a00000\/subsys[0-9]+\/wakeup\/wakeup[0-9]+\//) kn = "известный пробел политики прошивки: источник пробуждения ssr(wpss), в стоке так же"
      else if ($1 == "system_suspend" && path ~ /\/ae00000\.qcom,mdss_mdp\/wakeup\//) kn = "известный пробел ядра: источник пробуждения дисплея (раздел 18)"
      printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n", $1, $2, $3, $4, (path == "" ? ($5 == "sysfs" ? "ino=" $6 : "dev=" $5) : path), (kn == "" ? "-" : "K"), kn }' $ag_p-gen.txt > $ag_p-genr.txt
  awk -F'\t' -v nf=$ag_p-gen-new.txt -v kf=$ag_p-gen-known.txt '{ k = $1 " " $2 " " $3; if ($6 == "K") kn[k] = 1; else un[k] = 1 }
    END { printf "" > nf; printf "" > kf; for (k in un) print k > nf; for (k in kn) if (!(k in un)) print k > kf }' $ag_p-genr.txt
}
avcgen $W/raw/avc.txt $TMPD/avc
gen=$(grep -c . $TMPD/avc-gen-new.txt)
awk -F'\t' '{ c[$1 " " $4 " -> " $5 ($7 == "" ? "" : "   [" $7 "]")]++ } END { for (k in c) print c[k], k }' $TMPD/avc-genr.txt | sort -rn | head -40 > $W/raw/avc-generic-names.txt
# the kinds of daemon denials this ROM has had on every build so far (the
# ROM's own policy, the same with any kernel): listed, not warned about; a
# kind that is not here (or the run is on another ROM) is "new"
cat > $TMPD/avc-known.txt <<'EOF'
hal_dvs_default default_android_hwservice hwservice_manager
hal_sensors_default default_prop file
hal_wifi_default persist_vendor_debug_wifi_prop file
init debugfs_bootreceiver_tracing dir
mi_thermald property_socket sock_file
rild default_prop file
rild vendor_default_prop property_service
rild vendor_pd_locater_dbg_prop file
system_server adb_data_file dir
system_server custom_version_prop file
system_server priv_app process
toolbox adb_data_file dir
vendor_dpmd default_android_hwservice hwservice_manager
vendor_hal_capabilityconfigstore_qti_default vendor_cap_configstore_dbg_prop file
vendor_hal_citsensorservice_xiaomi_default system_server binder
vendor_hal_citsensorservice_xiaomi_default vendor_sysfs_udfps dir
vendor_hal_gnss_qti vendor_pd_locater_dbg_prop file
vendor_init default_prop property_service
vendor_poweroffalarm_app default_prop file
vendor_qtidataservices_app default_prop file
EOF
awk -v kf=$TMPD/avc-known.txt -v gk=$TMPD/avc-gen-known.txt -v ko=$TMPD/avc-daemon-known.txt -v no=$TMPD/avc-daemon-new.txt 'BEGIN { while ((getline l < kf) > 0) k[l] = 1; while ((getline l < gk) > 0) k[l] = 1; printf "" > ko; printf "" > no }
  { if (($2 " " $3 " " $4) in k) print > ko; else print > no }' $TMPD/avc-daemon.txt
ndn=$(grep -c . $TMPD/avc-daemon-new.txt); ndk=$(grep -c . $TMPD/avc-daemon-known.txt)
det "--- отказы служб, новые (их нет в списке известных для этой прошивки)"; cat $TMPD/avc-daemon-new.txt >> $DET
det "--- отказы служб, известные (политика прошивки, на прошлых сборках так же)"; cat $TMPD/avc-daemon-known.txt >> $DET
det "--- отказы доменов приложений (untrusted_app*, isolated_app*, sdk_sandbox*, ephemeral_app, gmscore_app, priv_app: только для сведения)"; cat $TMPD/avc-app.txt >> $DET
[ "$gen" -gt 0 ] && warn SELinux "$(pl $gen "вид" "вида" "видов") отказов служб на общих метках (sysfs/device/proc/debugfs: путь в ядре или имя устройства не совпадает с тем, что размечает политика; пути — raw/avc-generic-names.txt)"
npt=; [ "$nap" -gt 0 ] && npt=" (у приложений $(pl $nap "вид" "вида" "видов"), для сведения)"
nkt=; [ "$ndk" -gt 0 ] && nkt="; известных — $ndk"
if [ "$ndn" -gt 0 ]; then warn SELinux "$(pl $ndn "новый вид" "новых вида" "новых видов") отказов служб$nkt$npt (подробности; пути — в raw/avc.txt)$AVLB"
elif [ "$ndk" -gt 0 ]; then kok SELinux "новых отказов у служб нет: только известные ($(pl $ndk "вид" "вида" "видов"): политика прошивки, на прошлых сборках так же)$npt$AVLB"
elif [ "$nap" -gt 0 ]; then kok SELinux "отказов у служб нет (у приложений $(pl $nap "вид" "вида" "видов"), для сведения: подробности)$AVLB"
else kok SELinux "отказов нет$AVLB"; fi
det "--- файлы за отказами служб на общих метках (число, служба, имя -> путь по номеру inode)"; cat $W/raw/avc-generic-names.txt >> $DET

########################################################################
sec "11. Удалённые процессоры (DSP, модем)"
for p in /sys/class/remoteproc/*; do
  [ -e $p ] || continue
  nm=$(rd $p/name); st=$(rd $p/state); rec=$(rd $p/recovery)
  [ "$st" = running ] && ok remoteproc "$nm работает" || fail remoteproc "$nm в состоянии «$st»"
  det "$nm: состояние $st, recovery $rec, coredump $(rd $p/coredump)"
  [ "$rec" = disabled ] && warn remoteproc "$nm: восстановление (recovery) выключено (его падение тогда роняет телефон или оставляет процессор мёртвым до перезагрузки)"
done
for s in /sys/bus/msm_subsys/devices/*; do
  [ -e $s ] || continue
  sn=$(rd $s/name); cc=$(rd $s/crash_count)
  det "${s##*/}: $sn $(rd $s/state) crash_count $cc restart_level $(rd $s/restart_level)"
  [ -n "$cc" ] && [ "$cc" -gt 0 ] 2>/dev/null && warn remoteproc "$sn падал $(pl $cc "раз" "раза" "раз") за эту загрузку"
done
c=$(grep -cE "$RPCRASH" $W/raw/dmesg-nospam.txt)
[ "$c" -gt 0 ] && warn remoteproc "в журнале ядра $c строк о падениях и перезапусках удалённых процессоров" && grep -E "$RPCRASH" $W/raw/dmesg-nospam.txt | head -20 >> $DET
# the PD mapper's service files: the protection domains of each remote
# processor (the ADSP's audio and sensors PDs among them) that pd-mapper
# serves to PDR
det "--- файлы служб PD mapper (/vendor/firmware_mnt/image/*.jsn)"
if exists '/vendor/firmware_mnt/image/*.jsn'; then ls -l /vendor/firmware_mnt/image/*.jsn >> $DET 2>&1
else det "нет: в /vendor/firmware_mnt/image нет файлов .jsn (не смонтирован?)"; fi

########################################################################
sec "12. Общая память: ION, кучи DMA-BUF, FastRPC"
[ -e /dev/ion ] && ok ION "/dev/ion есть" || warn ION "нет /dev/ion (библиотеки vendor из 5.4 используют ION)"
dh=$(ls /dev/dma_heap 2>/dev/null | tr '\n' ' '); det "dma_heap: ${dh:-нет /dev/dma_heap}"
grep -E "ion_alloc_fd failed|rpcmem_ion_alloc|rpc contig allocation failed|ION_IOC_ALLOC" $W/raw/logcat.txt | sed -E 's/^[0-9-]+ [0-9:.]+ +[0-9]+ +[0-9]+ //; s/fd [0-9]+/fd #/' | sort | uniq -c | sort -rn | head -10 > $W/raw/ion-fail.txt
if [ -s $W/raw/ion-fail.txt ]; then
  fail ION "выделение памяти ION в программах не удаётся: $(head -1 $W/raw/ion-fail.txt | sed -E 's/^ *//' | cut -c1-160)"
  cat $W/raw/ion-fail.txt >> $DET
fi
# ION in numbers: the sysfs totals (total_pools_kb only shown: what the pools
# hold varies), CMA, the heaps msm_ion created at boot (taoyao's devicetree
# has 8; checked only while the kernel log reaches back to boot)
[ -e /sys/kernel/ion/total_heaps_kb ] && det "ION: total_heaps_kb $(rd /sys/kernel/ion/total_heaps_kb), total_pools_kb $(rd /sys/kernel/ion/total_pools_kb)"
cma=$(awk '$1 == "CmaTotal:" { print $2, $3 }' /proc/meminfo); det "CmaTotal: ${cma:-нет в /proc/meminfo}"
nih=$(grep -cE 'ION heap .* created' $W/raw/dmesg.txt)
det "созданные кучи ION ($nih): $(sed -nE 's/.*ION heap ([^ ]+) .*created.*/\1/p' $W/raw/dmesg.txt | tr '\n' ' ')"
ik0=$(head -1 $W/raw/dmesg.txt | sed -nE 's/^\[ *([0-9]+)\..*/\1/p')
if [ "$nih" -lt 8 ]; then
  if [ -n "$ik0" ] && [ "$ik0" -lt 30 ]; then pwarn ION "в журнале ядра только $nih строк «ION heap ... created» (в devicetree taoyao 8 куч): выделение из отсутствующей кучи не удастся (имена — в подробностях)"
  else det "журнал ядра начинается с ${ik0:-?} с: строк «ION heap ... created» начала загрузки может уже не быть, число куч не проверено"; fi
fi
# what libion and the DMA-BUF heap wrapper (libdmabufheap) report failed
IONLF='libion alloc failed|ion_alloc_fd failed|MapDmabufHeapNameToIonHeap fail|CreateDmabufHeapBufferAllocator fail'
c=$(grep -cE "$IONLF" $W/raw/logcat.txt)
if [ "$c" -gt 0 ]; then
  warn ION "в logcat $c неудачных выделений или поисков куч ION / DMA-BUF (libion, libdmabufheap; примеры — в подробностях)"
  det "--- ошибки куч ION / DMA-BUF в logcat (первые 5 из $c)"; grep -E "$IONLF" $W/raw/logcat.txt | head -5 | cut -c1-240 >> $DET
fi
for d in adsp cdsp sdsp; do
  c=$(grep -cE "$d[a-z_]*rpcd.*(apps_dev_init failed|remote_handle_open failed|open_dev .* failed)" $W/raw/logcat.txt)
  [ "$c" -gt 0 ] && fail FastRPC "${d}rpcd: $c неудачных сеансов FastRPC (процесс на стороне DSP не запускается)"
done
ls -l /dev/adsprpc-smd* /dev/fastrpc* 2>/dev/null >> $DET
# the compute node must be bound and its context banks probed, or every DSP
# session falls back to no SMMU and fails
FD=/sys/bus/platform/devices/soc:qcom,msm_fastrpc
if [ -e $FD ]; then
  ncb=$(ls -d $FD/of_node/qcom,msm_fastrpc_compute_cb* 2>/dev/null | wc -l)
  bcb=0
  for cb in /sys/bus/platform/devices/*msm_fastrpc_compute_cb*; do [ -e "$cb/driver" ] && bcb=$((bcb + 1)); done
  if [ -e $FD/driver ]; then
    drv=$(readlink $FD/driver)
    ok FastRPC "soc:qcom,msm_fastrpc привязан к драйверу ${drv##*/}"
    [ "$bcb" -lt "$ncb" ] && fail FastRPC "привязано только $bcb из $ncb банков контекста FastRPC (qcom,msm-fastrpc-compute-cb)"
  else
    fail FastRPC "у soc:qcom,msm_fastrpc нет драйвера: нет банков контекста, и каждый сеанс DSP не удаётся (audio PD, sensors PD, SNPE камеры)"
  fi
  det "банки контекста FastRPC: привязано $bcb из $ncb в devicetree"
else
  exists '/sys/bus/platform/devices/*fastrpc*' || warn FastRPC "нет платформенного устройства FastRPC"
fi
[ -f /sys/kernel/debug/adsprpc/global ] && { det "--- /sys/kernel/debug/adsprpc/global"; timeout 3 head -c 8192 /sys/kernel/debug/adsprpc/global >> $DET; }
# stkf <stack file>: the first frames of a kernel stack (/proc/<pid>/stack),
# innermost first, without the scheduler's own frames, offsets and modules
stkf() {
  rd "$1" | awk '{ s = $0; sub(/^\[<[^>]*>\] */, "", s); sub(/\+0x[0-9a-fA-F]+\/0x[0-9a-fA-F]+/, "", s); sub(/ \[[A-Za-z0-9_]+\]$/, "", s) }
    s == "" || s == "__switch_to" || s == "__schedule" || s == "schedule" { next }
    { o = o (n++ ? " <- " : "") s; if (n >= 6) exit } END { print o }'
}
# pstk <pid>: the State: line of /proc/<pid>/status and the first stack
# frames of the process and of each of its threads (the first 32 shown) to
# the details; wchan alone does not tell where a FastRPC call waits (the wait
# functions are inlined). PSTD: its threads in D state (uninterruptible), as
# "tid:comm", read again after 1 s so that a short wait does not count.
pstk() {
  PSTD=
  if [ ! -d /proc/$1 ]; then det "  процесса $1 уже нет"; return 0; fi
  det "  pid $1 $(grep -m1 '^State:' /proc/$1/status 2>/dev/null | tr -s ' \t' ' '); стек: $(stkf /proc/$1/stack)"
  pk_n=0
  for pk_t in /proc/$1/task/*; do
    [ -d "$pk_t" ] || continue
    pk_n=$((pk_n + 1)); pk_i=${pk_t##*/}; pk_c=$(rd $pk_t/comm)
    pk_s=$(sed -n 's/^State:[[:space:]]*//p' $pk_t/status 2>/dev/null | head -1)
    case "$pk_s" in D*) PSTD="$PSTD $pk_i:$(echo "$pk_c" | tr ' ' '_')";; esac
    [ "$pk_i" = "$1" ] && continue
    if [ $pk_n -le 32 ]; then det "    поток $pk_i ($pk_c) ${pk_s:--}: $(stkf $pk_t/stack)"
    elif [ $pk_n = 33 ]; then det "    (остальные потоки не показаны)"; fi
  done
  [ -z "$PSTD" ] && return 0
  sleep 1
  pk_d=
  for pk_x in $PSTD; do
    case "$(sed -n 's/^State:[[:space:]]*//p' /proc/$1/task/${pk_x%%:*}/status 2>/dev/null)" in D*) pk_d="$pk_d $pk_x";; esac
  done
  PSTD=$pk_d
}
# a daemon whose pid changes over the watch is in a crash loop; the audio and
# sensors daemons in D state wait in the kernel for a DSP that does not
# answer (sscrpcd waits uninterruptibly for the ADSP's reply: the hung-task
# watchdog reports it after 120 s, and it keeps the phone from suspending)
for n in $RPCD; do
  p0=$(sed -n "s/^$n //p" $W/raw/rpcd-start.txt); p1=$(sed -n "s/^$n //p" $W/raw/rpcd-end.txt)
  det "$n: pid [$p0] -> [$p1] за $WIN с$(for p in $p1; do printf ' (%s wchan %s)' $p "$(rd /proc/$p/wchan)"; done)"
  [ -n "$p0$p1" ] && [ "$p0" != "$p1" ] && fail FastRPC "$n перезапустился за $WIN с наблюдения (pid «$p0» -> «$p1»): падает по кругу"
  case "$n" in sscrpcd|audioadsprpcd) ;; *) continue;; esac
  for p in $(pidof $n 2>/dev/null); do
    pstk $p
    [ -n "$PSTD" ] && warn FastRPC "$n (pid $p) в состоянии D (потоки$PSTD): непрерываемо ждёт в ядре ответа DSP, который не приходит (состояние и стеки — в подробностях)"
  done
done

########################################################################
sec "12b. TEE и GPU"
# QTEE shared memory: qtee_shmbridge carves its pool at boot ("shmbridge pool
# of size"); qseecom and smcinvoke take their buffers from it
grep -m1 'shmbridge pool of size' $W/raw/dmesg.txt >> $DET || det "в журнале ядра нет строки «shmbridge pool of size»"
c=$(grep -c 'Failed to alloc memory from shmbridge pool' $W/raw/dmesg-nospam.txt)
[ "$c" -gt 0 ] && { fail TEE "в журнале ядра $c × «Failed to alloc memory from shmbridge pool»: вызовы QTEE (keymaster, gatekeeper, приложения qseecom) не проходят"; grep 'Failed to alloc memory from shmbridge pool' $W/raw/dmesg-nospam.txt | head -5 >> $DET; }
det "ошибок smcinvoke/qseecom в журнале ядра: ${NQTEEE:-0} (проверено в разделе 8, «ключи»)"
# the QTEE services: state and pid now and again just before the final pack
# (at the end of the script); a pid that changed is a restart during the run
TEESVC='vendor.qseecomd vendor.keymaster-4-1 vendor.gatekeeper-1-0 vendor.ssgtzd vendor.qteeconnector-hal-1-0 keystore2'
teesvc() {
  for ts_s in $TEESVC; do
    ts_st=$(getprop init.svc.$ts_s); [ -z "$ts_st" ] && continue
    ts_p=$(getprop init.svc_debug_pid.$ts_s); echo "$ts_s $ts_st ${ts_p:--}"
  done
}
TEET0=$(up); teesvc > $W/raw/tee-svc-start.txt
det "службы QTEE на $TEET0 с (имя, состояние, pid): $(tr '\n' ';' < $W/raw/tee-svc-start.txt)"
# GPU: the ROM's Adreno blobs and its power HAL expect the 642L
KG=/sys/class/kgsl/kgsl-3d0
if [ -d $KG ]; then
  gpm=$(rd $KG/gpu_model)
  [ "$gpm" = Adreno642Lv1 ] && ok GPU "gpu_model $gpm" || warn GPU "gpu_model — «$gpm», а не Adreno642Lv1 (библиотеки GPU прошивки рассчитаны на 642L)"
  det "kgsl-3d0: gpu_model ${gpm:--}, force_rail_on $(rd $KG/force_rail_on), force_clk_on $(rd $KG/force_clk_on), force_no_nap $(rd $KG/force_no_nap)"
else
  warn GPU "нет $KG: нет устройства GPU KGSL"
fi
# the power HAL (libperfmgr) writes its nodes on every boost; a node it
# cannot open it tries again on every pass of its loop (twice a second),
# for as long as the phone runs: its write failures per node
# (raw/perfmgr-fail.txt: count, node, class) and per second over the time
# logcat holds them. Expected before kernel 0.20 (E): the WALT sysctls
# (/proc/sys/kernel/sched_*, /proc/sys/walt; 6.12 has no WALT) and the 5.4
# bw_hwmon / memlat devfreq devices (/sys/class/devfreq/soc:qcom,*; replaced
# by the DCVS framework); from 0.20 the kernel takes those writes (its
# compatibility nodes, below), so none is expected then. A failed write to a
# cpufreq, schedutil or kgsl node is a boost that does not happen (W).
# Others: details (O).
grep 'Failed to write to node: ' $W/raw/logcat.txt > $TMPD/pmf.txt
sed -nE 's/.*Failed to write to node: ([^ ]+).*/\1/p' $TMPD/pmf.txt | sed 's/,$//' | sort | uniq -c | sort -rn |
  awk '{ c = "O"; if ($2 ~ /^\/proc\/sys\/(kernel\/sched_|walt\/)|^\/sys\/class\/devfreq\/soc:qcom,/) c = "E"; else if ($2 ~ /cpufreq|schedutil|kgsl/) c = "W"; print $1, $2, c }' > $W/raw/perfmgr-fail.txt
pfe=$(awk '$3 == "E" { n += $1 } END { print n + 0 }' $W/raw/perfmgr-fail.txt)
pfo=$(awk '$3 == "O" { n += $1 } END { print n + 0 }' $W/raw/perfmgr-fail.txt)
pfw=$(awk '$3 == "W" { n += $1; k++ } END { print n + 0, k + 0 }' $W/raw/perfmgr-fail.txt)
pfn=$(grep -c . $W/raw/perfmgr-fail.txt); pft=$((pfe + pfo + ${pfw% *}))
# (the span of the failures in logcat's threadtime clock, MM-DD HH:MM:SS.mmm;
# PFR: "<failures per second> <per node per second> <span s>")
PFR=$(awk -v nn="$pfn" '{ split($2, t, ":"); s = t[1] * 3600 + t[2] * 60 + t[3]; if (NR == 1) a = s; b = s; n++ }
  END { d = b - a; if (d < 0) d += 86400; if (n < 2 || d < 1) exit; r = n / d; printf "%.1f %.1f %.0f\n", r, (nn > 0 ? r / nn : 0), d }' $TMPD/pmf.txt | tr . ,)
PFRT=
if [ -n "$PFR" ]; then
  pf_r=${PFR%% *}; pf_d=${PFR##* }; pf_n=${PFR#* }; pf_n=${pf_n%% *}
  PFRT="$pf_r в секунду за $pf_d с"
  case "$pf_n" in 1,[5-9]|2,[0-4]) PFRT="$PFRT: каждый из $pfn узлов — около 2 раз в секунду (HAL повторяет неудачную запись в каждом проходе своего цикла, дважды в секунду, всё время работы телефона)";; *) PFRT="$PFRT, на узел — $pf_n в секунду";; esac
fi
if [ -s $W/raw/perfmgr-fail.txt ]; then
  pfx="ожидаемо: в 6.12 их нет"; [ -n "$PORT" ] && [ -n "$KBUILD" ] && [ "$KBUILD" -ge 20 ] 2>/dev/null && pfx="с ядра 0.20 их быть не должно: узлы совместимости, ниже"
  det "неудачные записи HAL питания (libperfmgr) в logcat: $pft${PFRT:+ ($PFRT)}; в узлы cpufreq/schedutil/kgsl — ${pfw% *}, в узлы WALT и devfreq из 5.4 — $pfe ($pfx), в другие — $pfo (число, узел, класс):"
  head -30 $W/raw/perfmgr-fail.txt >> $DET
else
  det "неудачных записей HAL питания (libperfmgr) в logcat нет"
fi
if [ "${pfw% *}" -gt 0 ]; then
  pfg=$(awk '$3 == "W" && $2 ~ /kgsl/ { n += $1 } END { print n + 0 }' $W/raw/perfmgr-fail.txt)
  [ "$pfg" -gt 0 ] && warn GPU "в logcat $pfg неудачных записей HAL питания в узлы kgsl (ускорение GPU не срабатывает; raw/perfmgr-fail.txt)"
  [ $((${pfw% *} - pfg)) -gt 0 ] && warn "процессор" "в logcat $((${pfw% *} - pfg)) неудачных записей HAL питания в узлы cpufreq/schedutil (ускорение процессора не срабатывает; raw/perfmgr-fail.txt)"
fi
# the kernel's compatibility nodes for a 5.4 power HAL config (kernels from
# 0.20): the marker /sys/kernel/taoyao/perf_compat ("1"), the bw_hwmon
# devfreq devices soc:qcom,cpu-cpu-llcc-bw and soc:qcom,cpu-llcc-ddr-bw and
# the WALT sysctls as stubs that take the HAL's writes; listed with their
# mode, SELinux label and value (read only: nothing is written)
PCF=$(rd /sys/kernel/taoyao/perf_compat | tr -d ' \n')
PCN='soc:qcom,cpu-cpu-llcc-bw soc:qcom,cpu-llcc-ddr-bw'
PCW='sched_prefer_spread sched_min_task_util_for_colocation sched_min_task_util_for_boost sched_busy_hysteresis_enable_cpus sched_busy_hyst_ns'
pcd=0; pcm=; pcs=0; pcx=
for d in $PCN; do if [ -d /sys/class/devfreq/$d ]; then pcd=$((pcd + 1)); else pcm="$pcm $d"; fi; done
for w in $PCW; do if [ -e /proc/sys/kernel/$w ]; then pcs=$((pcs + 1)); else pcx="$pcx $w"; fi; done
PCSUM="perf_compat=${PCF:-нет}; устройства devfreq из 5.4: $pcd из 2; заглушки WALT: $pcs из 5"
det "узлы совместимости для HAL питания из 5.4: $PCSUM${pcm:+; нет devfreq:$pcm}${pcx:+; нет sysctl:$pcx}"
if [ $((pcd + pcs)) -gt 0 ] || [ -n "$PCF" ]; then
  for d in $PCN; do
    [ -d /sys/class/devfreq/$d ] || continue
    for f in min_freq bw_hwmon/hyst_trigger_count bw_hwmon/hyst_length bw_hwmon/hist_memory; do
      [ -e /sys/class/devfreq/$d/$f ] && det "  $(ls -lLZ /sys/class/devfreq/$d/$f 2>/dev/null | awk '{ print $1, $5 }') /sys/class/devfreq/$d/$f = $(rd /sys/class/devfreq/$d/$f | head -c 80)"
    done
  done
  for w in $PCW; do [ -e /proc/sys/kernel/$w ] && det "  $(ls -lZ /proc/sys/kernel/$w 2>/dev/null | awk '{ print $1, $5 }') /proc/sys/kernel/$w = $(rd /proc/sys/kernel/$w | head -c 80)"; done
fi
# (the marker: "1" once all those nodes are up, "0" while the built-in code
# has not all of them; no file: a kernel without that code)
if [ -n "$PORT" ] && [ -n "$KBUILD" ] && [ "$KBUILD" -ge 20 ] 2>/dev/null; then
  if [ "$PCF" = 1 ]; then
    if [ -n "$pcm$pcx" ]; then warn "процессор" "perf_compat=1, но узлов совместимости для HAL питания нет:$pcm$pcx"
    else ok "процессор" "узлы совместимости для HAL питания из 5.4 на месте ($PCSUM)"; fi
  elif [ "$PCF" = 0 ]; then warn "процессор" "perf_compat=0: ядро не подняло все узлы совместимости для HAL питания из 5.4 (${pcm:+нет devfreq:$pcm; }${pcx:+нет sysctl:$pcx; }устройства devfreq из 5.4: $pcd из 2, заглушки WALT: $pcs из 5), часть записей HAL может не приниматься"
  elif [ -e /sys/kernel/taoyao/perf_compat ]; then warn "ядро" "/sys/kernel/taoyao/perf_compat не читается («${PCF:-пусто}»; в ядрах с 0.20 — «1»: узлы совместимости для HAL питания из 5.4)"
  else warn "ядро" "нет /sys/kernel/taoyao/perf_compat (в ядрах с 0.20 — «1»: узлы совместимости для HAL питания из 5.4): это не официальная сборка"; fi
  [ "$pfe" -gt 0 ] && warn "процессор" "HAL питания не может записать в узлы WALT и devfreq из 5.4: $pfe неудачных записей${PFRT:+ (${PFRT%%:*})}, а ядро 0.$KBUILD должно их принимать (raw/perfmgr-fail.txt)"
fi
# the KernelSU module taoyao_powerhint612 (optional): it replaces
# /vendor/etc/powerhint.json with one for 6.12 and writes its result into
# status.txt (result, reason, message, boot_id, the HAL's parsed nodes and
# actions, write failures, the SHA-256 of the ROM's file and of its own);
# copied to hal/ with module.prop and the end of its boot.log. The SHA-256
# of the file the HAL reads says which one it got.
PHM=/data/adb/modules/taoyao_powerhint612; PHS=$PHM/status.txt; PHSUM=
PJS=$(sha256sum /vendor/etc/powerhint.json 2>/dev/null | cut -d' ' -f1)
if [ -d $PHM ] || [ -d /data/adb/modules_update/taoyao_powerhint612 ]; then
  mkdir -p $W/hal
  [ -f $PHS ] && imask < $PHS | cut -c1-400 > $W/hal/powerhint612-status.txt
  [ -f $PHM/module.prop ] && imask < $PHM/module.prop > $W/hal/powerhint612-module.prop.txt
  [ -f $PHM/state/boot.log ] && tail -n 200 $PHM/state/boot.log | imask | cut -c1-400 > $W/hal/powerhint612-boot.log.txt
  phv() { sed -n "s/^$1=//p" $PHS 2>/dev/null | head -n 1; }
  ph_v=$(sed -n 's/^version=//p' $PHM/module.prop 2>/dev/null | head -n 1)
  ph_r=$(phv result); ph_rs=$(phv reason); ph_m=$(phv message); ph_b=$(phv boot_id); ph_t=$(phv time)
  ph_np=$(phv nodes_parsed); ph_ap=$(phv actions_parsed); ph_wf=$(phv write_failures); ph_fp=$(phv failed_paths)
  ph_os=$(phv orig_sha256); ph_ns=$(phv new_sha256)
  # (after a failure the module itself creates disable and state/failed
  # "<reason> <boot_id> <time>", and stays off until it is reinstalled:
  # KernelSU then never runs it, so its status.txt is of that boot; disable
  # without state/failed is the owner's choice in the root manager)
  ph_sf=; [ -f $PHM/state/failed ] && ph_sf=$(head -n 1 $PHM/state/failed 2>/dev/null | cut -c1-120)
  ph_x=; { [ -n "$ph_sf" ] || [ "$ph_r" = FAILED ] || [ "$ph_r" = BLOCKED ]; } && ph_x=1
  ph_f=; [ -f $PHM/disable ] && { if [ -n "$ph_x" ]; then ph_f="выключил себя после сбоя"; else ph_f="выключен в менеджере root"; fi; }
  [ -f $PHM/remove ] && ph_f="будет удалён при перезагрузке"
  [ -d /data/adb/modules_update/taoyao_powerhint612 ] && ph_f="${ph_f:+$ph_f; }новая версия ставится при перезагрузке"
  ph_w="модуль taoyao_powerhint612${ph_v:+ $ph_v}"
  ph_c="узлов ${ph_np:-?}, действий ${ph_ap:-?}, ошибок записи ${ph_wf:-?}${ph_fp:+ ($ph_fp)}"
  ph_j=; [ -n "$PJS" ] && { if [ "$PJS" = "$ph_ns" ]; then ph_j="HAL читает файл модуля"; elif [ "$PJS" = "$ph_os" ]; then ph_j="HAL читает файл прошивки"; fi; }
  ph_jt=$ph_j; [ -z "$ph_j" ] && [ -n "$ph_os$ph_ns" ] && [ -n "$PJS" ] && ph_jt="powerhint.json не совпадает ни с файлом модуля, ни с файлом прошивки из status.txt"
  # (the time: the module's own clock, time=, has no zone (in its early
  # stage, before Android's zone is loaded, it is UTC), so the file's time
  # as well, in the phone's zone)
  ph_tl=; [ -f $PHS ] && ph_tl=$(date -d "@$(stat -c %Y $PHS 2>/dev/null)" '+%d.%m.%Y %H:%M' 2>/dev/null)
  ph_tt="${ph_tl:-${ph_t:-?}}${ph_tl:+${ph_t:+ (в status.txt: $ph_t)}}"; ph_tw="${ph_tl:-${ph_t:-время неизвестно}}"
  det "$ph_w${ph_f:+ ($ph_f)}: result=${ph_r:--} reason=${ph_rs:--}, $ph_c; запись от $ph_tt${ph_jt:+; $ph_jt}${ph_sf:+; state/failed: $ph_sf} (hal/powerhint612-status.txt)"
  [ -n "$ph_m" ] && det "  сообщение модуля: $ph_m"
  # (on a kernel whose own nodes take the HAL's writes, perf_compat=1, the
  # module is not needed: its failure is no problem then)
  ph_kc=; [ "$PCF" = 1 ] && ph_kc=1
  if [ ! -f $PHS ]; then det "$ph_w: status.txt нет — модуль ещё не запускался (установлен, а телефон после этого не перезагружали?)"
  elif [ -f $PHM/remove ]; then :
  elif [ -n "$ph_x" ]; then
    ph_xr=${ph_rs:-${ph_sf%% *}}
    if [ -n "$ph_kc" ]; then det "$ph_w выключил себя после сбоя ($ph_tw, reason=${ph_xr:-?}); на этом ядре он не нужен: узлы для HAL питания даёт ядро (perf_compat=1)"
    else warn "HAL питания" "$ph_w выключил себя после сбоя ($ph_tw): ${ph_m:-$ph_xr} (reason=${ph_xr:-?}; HAL работает с файлом прошивки, модуль снова включится только после переустановки)"; fi
  elif [ -f $PHM/disable ]; then :
  elif [ -n "$BOOTID" ] && [ -n "$ph_b" ] && [ "$ph_b" != "$BOOTID" ]; then warn "HAL питания" "$ph_w: его status.txt — от прошлой загрузки ($ph_tw): в этой загрузке модуль не запускался (KernelSU его не загрузил?)"; ph_r="${ph_r:-?}, status.txt от прошлой загрузки"
  else
    case "$ph_r" in
      OK) ok "HAL питания" "$ph_w работает: HAL использует powerhint.json для 6.12 ($ph_c)";;
      WARN) warn "HAL питания" "$ph_w: ${ph_m:-предупреждение} (reason=$ph_rs; $ph_c)";;
      INERT) det "$ph_w ничего не делает на этом ядре или прошивке: ${ph_m:-$ph_rs}";;
      APPLIED|PENDING) det "$ph_w: файл подменён, проверка модуля после загрузки ещё не закончена (${ph_m:-$ph_rs})";;
      *) det "$ph_w: непонятный итог «$ph_r» в status.txt";;
    esac
  fi
  PHSUM="$ph_w: ${ph_r:-нет status.txt}${ph_rs:+ ($ph_rs)}${ph_f:+, $ph_f}"
fi
det "powerhint.json, который читает HAL (/vendor/etc): sha256 ${PJS:-не прочитан}${ph_j:+ — $ph_j}"

########################################################################
sec "13. Звук"
# where the sound went last (speaker, wired, Bluetooth A2DP offload ...)
dsys media.audio_flinger | grep -E 'CFG_EVENT_(CREATE|RELEASE)_AUDIO_PATCH' | tail -6 | sed -E 's/^ +//' | while IFS= read -r l; do det "маршрут звука: $l"; done
cards=$(grep -c '^ *[0-9]' $ASND/cards 2>/dev/null); cards=${cards:-0}
[ "$cards" -gt 0 ] && ok "звук" "звуковые карты: $(grep -E '^ *[0-9]' $ASND/cards | tr -s ' ' | tr '\n' ' ')" || fail "звук" "нет звуковой карты"
cat $ASND/pcm > $W/raw/pcm.txt 2>/dev/null
# the two files the audio HAL loads (hardware/qcom/audio hal/msm8974/
# platform.c; stock's audio.primary.lahaina.so names the same files): by the
# card name <target>-<card>-<form factor>-snd-card (lahaina-yupikidp-snd-card)
# from /vendor/etc/audio/sku_<ro.boot.product.vendor.sku> (sku_yupik), else
# /vendor/etc: audio_platform_info_<card>.xml (yupikidp), else _intcodec,
# else the plain name; the first of mixer_paths_<card>_<form factor>,
# _<target>_<card>, _<variant>, _<card> and mixer_paths.xml. Not just the
# first file found: stock's vendor also carries other SoCs' sku_lahaina and
# sku_shima, and audio_platform_info_intcodec.xml (Evolution X) maps other ids.
SNDN=$(sed -n 's/^ *0 \[[^]]*\]: .* - //p' $ASND/cards 2>/dev/null | head -1)
sn_t=$(echo "$SNDN" | cut -d- -f1); sn_c=$(echo "$SNDN" | cut -d- -f2); sn_f=$(echo "$SNDN" | cut -d- -f3); sn_v=$(echo "$SNDN" | cut -d- -f4)
ACD=/vendor/etc; SKU=$(getprop ro.boot.product.vendor.sku); [ -n "$SKU" ] && [ -d /vendor/etc/audio/sku_$SKU ] && ACD=/vendor/etc/audio/sku_$SKU
PI=; MP=
if [ -n "$sn_c" ]; then
  for f in $ACD/audio_platform_info_$sn_c.xml $ACD/audio_platform_info_intcodec.xml $ACD/audio_platform_info.xml; do [ -f $f ] && { PI=$f; break; }; done
  for f in $ACD/mixer_paths_${sn_c}_$sn_f.xml $ACD/mixer_paths_${sn_t}_$sn_c.xml ${sn_v:+$ACD/mixer_paths_$sn_v.xml} $ACD/mixer_paths_$sn_c.xml $ACD/mixer_paths.xml; do [ -f $f ] && { MP=$f; break; }; done
fi
[ -z "$PI" ] && PI=$(ls /vendor/etc/audio/sku_*/audio_platform_info*.xml /vendor/etc/audio_platform_info*.xml /odm/etc/audio_platform_info*.xml 2>/dev/null | head -1)
[ -z "$MP" ] && MP=$(ls /vendor/etc/audio/sku_*/mixer_paths*.xml /vendor/etc/mixer_paths*.xml /odm/etc/mixer_paths*.xml 2>/dev/null)
# (test hook: a mixer paths file of a PC harness)
[ -n "$TY_MIXPATHS" ] && MP=$TY_MIXPATHS
det "звуковая карта $SNDN; настройки HAL из $ACD"
# Xiaomi's audio_platform_info_yupikidp.xml (the same in Evolution X) gives
# five use cases an id one below the kernel's front end; stock 5.4 numbers
# the front ends as this kernel does, so the same ids are off there too.
# STOCKNUM=1: the kernel has stock's numbering (33 Primary MI2S TX Hostless,
# 41 MultiMedia31, 43 AFE-PROXY TX1, compress device 44); then those five
# are details, not FAILs (with another numbering they stay FAILs)
STOCKNUM=0
grep -q '^00-33: Primary MI2S_TX Hostless' $W/raw/pcm.txt && grep -q '^00-41: MultiMedia31' $W/raw/pcm.txt &&
  grep -q '^00-43: AFE-PROXY TX1' $W/raw/pcm.txt && [ -e /dev/snd/comprC0D44 ] && STOCKNUM=1
det "нумерация front end как в стоке 5.4 (STOCKNUM): $STOCKNUM"
if [ -n "$PI" ]; then
  det "audio_platform_info: $PI"
  grep -oE '<usecase name="[A-Z0-9_]+" type="(in|out)" id="-?[0-9]+"' $PI | sed -E 's/<usecase name="([^"]+)" type="([^"]+)" id="([^"]+)"/\1 \2 \3/' | while read -r uc t id; do
    [ "$id" -lt 0 ] 2>/dev/null && continue
    case "$STOCKNUM:$uc:$t:$id" in
      1:USECASE_AUDIO_PLAYBACK_OFFLOAD3:out:43|1:USECASE_AUDIO_PLAYBACK_FM:in:44|1:USECASE_AUDIO_RECORD_AFE_PROXY2:in:42|1:USECASE_AUDIO_PLAYBACK_WITH_HAPTICS:out:40|1:USECASE_AUDIO_PLAYBACK_HAPTICS:out:41)
        echo "$uc $t id $id: id из XML Xiaomi на один меньше, чем в ядре (в стоке 5.4 нумерация такая же; подходящий id — $((id + 1))): для сведения" >> $DET
        continue;;
    esac
    case "$uc" in *OFFLOAD*|*COMPRESS*)
      if [ -e /dev/snd/comprC0D$id ]; then echo "$uc $t -> compress-устройство comprC0D$id" >> $DET
      else fail "звук" "$uc ($t) использует compress-устройство $id, но /dev/snd/comprC0D$id нет"; fi
      continue;;
    esac
    line=$(grep -E "^00-$(printf '%02d' $id): " $W/raw/pcm.txt)
    if [ -z "$line" ]; then
      fail "звук" "$uc ($t) использует PCM $id, которого нет"
    else
      dir=playback; dirr="воспроизведения"; [ $t = in ] && { dir=capture; dirr="записи"; }
      echo "$line" | grep -q "$dir" || fail "звук" "$uc ($t) использует PCM $id = «$(echo "$line" | cut -d: -f2 | sed 's/^ //')», а у него нет $dirr"
      echo "$uc $t -> $line" >> $DET
    fi
  done
fi
TM=$(command -v tinymix || ls /vendor/bin/tinymix /system/bin/tinymix 2>/dev/null | head -1)
det "пути микшера: $(echo $MP)"
if [ -n "$TM" ] && [ -n "$MP" ]; then
  # the control list (ctl TAB type TAB num TAB name ...): tinyalsa 2.x prints
  # it for "controls" (the name padded to 40, TAB, device); AOSP's tinymix
  # (stock HyperOS has it in /system/bin) takes no command, reports
  # "controls" as an unknown control and writes each control's values into
  # the name's field ("%-40s " then the values)
  timeout 20 $TM -D 0 controls > $TMPD/mixer.txt 2>/dev/null
  MXRC=0
  awk -F'\t' 'NF >= 4 && $1 ~ /^[0-9]+$/ { n++ } END { exit !n }' $TMPD/mixer.txt || { timeout 60 $TM -D 0 > $TMPD/mixer.txt 2>/dev/null; MXRC=$?; }
  awk -F'\t' 'NF >= 4 && $1 ~ /^[0-9]+$/ { print $4 }' $TMPD/mixer.txt > $W/raw/mixer-controls.txt
  grep -ohE '<ctl name="[^"]+"' $MP | sed -E 's/<ctl name="([^"]+)"/\1/' | sort -u > $W/raw/mixer-used.txt
  if [ "$MXRC" = 124 ] || [ ! -s $W/raw/mixer-controls.txt ]; then
    det "tinymix не выдал список элементов (или не уложился в 60 с): проверка элементов микшера пропущена"
  else
    # a control exists if a listed name field is it (trailing blanks cut), or
    # its first 40 characters are, or (a name of 40 or more characters, which
    # the old tinymix does not pad) the field starts with it and a blank
    awk 'FNR == NR { t = $0; sub(/ +$/, "", t); have[t] = 1; t = substr($0, 1, 40); sub(/ +$/, "", t); have[t] = 1
                     if (length($0) > 40) long[++nl] = $0; next }
         !($0 in have) { if (length($0) >= 40) for (i = 1; i <= nl; i++) if (index(long[i], $0 " ") == 1) next
                         print "нет элемента микшера: " $0 }' \
      $W/raw/mixer-controls.txt $W/raw/mixer-used.txt > $W/raw/mixer-missing.txt
    [ -s $W/raw/mixer-missing.txt ] && { warn "звук" "$(grep -c . $W/raw/mixer-missing.txt) элементов микшера из путей микшера прошивки не существуют (подробности)"; cat $W/raw/mixer-missing.txt >> $DET; }
  fi
else
  det "нет tinymix: проверка элементов микшера пропущена"
fi
APPTYPE=
if [ -n "$TM" ]; then
  APPTYPE=$(timeout 10 $TM -D 0 'App Type Config' 2>&1 | head -3)
  case "$APPTYPE" in *[Uu]sage*|*nvalid*|*rror*|*nknown*|"") APPTYPE=$(timeout 10 $TM -D 0 get 'App Type Config' 2>&1 | head -3);; esac
  det "App Type Config (чтение в ядре возвращает нули и на 5.4, и на 6.12 — это не проверка того, что записал HAL): $(echo "$APPTYPE" | head -1 | cut -c1-200)"
fi
# open streams (play something while the check runs to see them)
for s in $ASND/card*/pcm*/sub*; do
  [ -e "$s/hw_params" ] || continue
  hw=$(rd $s/hw_params)
  [ -z "$hw" ] || [ "$hw" = closed ] && continue
  stt=$(rd $s/status | sed -n 's/^state: *//p')
  det "открытый поток ${s#$ASND/} ($(rd ${s%/sub*}/info | sed -n 's/^id: //p')): состояние $stt, $(echo "$hw" | tr '\n' ' ')"
  [ "$stt" = XRUN ] && warn "звук" "PCM ${s#$ASND/} в состоянии XRUN (поток прервался)"
done
# (not counted under AFE: the TFA98xx DSP config of a stream whose AFE
# topology has no TFADSP module, below)
for p in "adm open failed|adm_open.*failed" "afe_port_start.*failed|AFE.*failed" "q6asm.*failed|asm.*open failed" "ASoC: error" "msm_pcm_playback_prepare: stream reg failed" "App type not available" "number of app types .* is invalid"; do
  c=$(grep -E -e "$p" $W/raw/dmesg-nospam.txt | grep -vc 'AFE_PARAM_ID_TFADSP_RX_CFG failed'); [ "$c" -gt 0 ] && fail "звук" "ядро: $c × «$p»"
done
# AFE_PARAM_ID_TFADSP_RX_CFG fails (EBADPARAM) when the stream on AFE port
# 0x1000 has a topology without the TFA98xx DSP module: the earpiece amp's
# ultrasound-proximity and voice streams (stock too). Only one on the
# speaker topology 0x1000ff00 is a fault. The topology is the last one
# afe_get_cal_topology_id logged for port 0x1000 before the failure.
tfa=$(awk '/afe_get_cal_topology_id: port_id = 0x1000 / { t = $0; sub(/.*topology_id = /, "", t); sub(/[ ,].*/, "", t); next }
  /AFE_PARAM_ID_TFADSP_RX_CFG failed/ { if (t == "0x1000ff00") b++; else if (t == "") u++; else e++ }
  END { printf "%d %d %d", b, e, u }' $W/raw/dmesg-nospam.txt)
tfab=${tfa%% *}; tfae=${tfa#* }; tfau=${tfae#* }; tfae=${tfae%% *}
[ "$tfab" -gt 0 ] && fail "звук" "ядро: $tfab × «AFE_PARAM_ID_TFADSP_RX_CFG failed» на топологии динамика 0x1000ff00: настройка DSP усилителя TFA98xx отклонена"
tfaut=; [ "$tfau" -gt 0 ] && tfaut=", $tfau × без строки топологии перед ней"
[ $((tfae + tfau)) -gt 0 ] && det "AFE_PARAM_ID_TFADSP_RX_CFG failed: $tfae × на потоках разговорного динамика и ультразвука (топология без TFADSP, в стоке так же: ожидаемо)$tfaut"
# the ultrasound proximity (Elliptic): its pseudo port (0x8001) starts and
# stops with the in-call proximity and screen-off detection; the kernel
# rejecting it leaves the screen on at the ear
c=$(grep -cE 'afe_(start|stop)_pseudo_port: AFE port index\[|ultrasound_(rx|tx)_port: enable=[01] ret=-' $W/raw/dmesg-nospam.txt)
[ "$c" -gt 0 ] && fail "звук" "ультразвуковой датчик приближения: $c × отказ запуска или остановки псевдопорта AFE (датчик приближения при звонке, гашение экрана; afe_*_pseudo_port, ultrasound_*_port в журнале ядра)"
det "ультразвуковой датчик приближения: «Opened device elliptic0» $(pl $(grep -c 'Opened device elliptic0' $W/raw/dmesg-nospam.txt) "раз" "раза" "раз"), ошибок псевдопорта: $c"
# the HAL: "Could not get ctl ... Audio Stream [Capture ]N App Type Cfg" for a
# hostless front end N (33 Primary MI2S TX Hostless, 48 Hostless_USTX):
# hostless PCMs have no App Type control, on 5.4 too; not counted
PHL=" $(sed -nE 's/^00-0*([0-9]+): .*Hostless.*/\1/p' $W/raw/pcm.txt | tr '\n' ' ')"
for p in "pcm_prepare returned" "Could not get ctl for mixer cmd" "cannot set hw params" "pcm_open failed|cannot open device"; do
  grep -E -e "$p" $W/raw/logcat.txt | awk -v hl="$PHL" '/Could not get ctl for mixer cmd/ && match($0, /Audio Stream (Capture )?[0-9]+ App Type Cfg/) {
      s = substr($0, RSTART, RLENGTH); gsub(/[^0-9]/, "", s); if (index(hl, " " (s + 0) " ")) next }
    { print }' > $TMPD/hal-err.txt
  c=$(grep -c . $TMPD/hal-err.txt); [ "$c" -gt 0 ] && fail "звук" "HAL: $c × «$p» ($(head -1 $TMPD/hal-err.txt | sed -E 's/^.*: //' | cut -c1-100))"
  case "$p" in "Could not get ctl"*)
    hlc=$(( $(grep -cE -e "$p" $W/raw/logcat.txt) - c ))
    [ "$hlc" -gt 0 ] && det "HAL: $hlc × «Could not get ctl ... App Type Cfg» у front end без хоста (PCM$PHL): у них нет элемента App Type, и на 5.4 тоже; не считается";;
  esac
done
# the TFA98xx amplifier driver logs its per-stream trace (hw_params, mute,
# DSP start, calibration) only with trace_level bit 0: tfa98xx_dlkm.trace_level=1
# when the module loads (the parameter is read-only afterwards)
TFAP=/sys/module/tfa98xx_dlkm/parameters/trace_level
if [ -e $TFAP ]; then TFAL=$(rd $TFAP)
elif [ -d /sys/module/tfa98xx_dlkm ]; then TFAL="нет (нет параметра trace_level)"
else TFAL="нет (tfa98xx_dlkm не загружен)"; fi
det "усилители TFA98xx: $TFAP = $TFAL (подробный журнал потоков — только с trace_level=1 при загрузке: tfa98xx_dlkm.trace_level=1)"

########################################################################
# the microphone (mic mode): what the 45 s window sampled (micsample), the
# kernel and HAL lines of the window, the mixer paths of the HAL's input
# device against the TX controls read while the capture ran
if [ -n "$MIC" ]; then
sec "13b. Микрофон"
MICF=$W/mic.txt
# PCM device classes from /proc/asound/pcm: "<dev> <class> <id>"
awk '{ d = $1; sub(/:$/, "", d); sub(/^[0-9]+-0*/, "", d); if (d == "") d = 0
       id = $0; sub(/^[^:]*: */, "", id); sub(/ *:.*/, "", id)
       c = "rec"
       if (id ~ /Hostless_US|USTX|USRX|[Uu]ltrasound/) c = "us"
       else if (id ~ /Listen [0-9]/) c = "listen"
       else if (id ~ /VoiceMMode|VoLTE|CS-Voice|QCHAT|VoWLAN|^Voice/) c = "voice"
       else if (id ~ /^VoIP/) c = "voip"
       else if (id ~ /AFE-PROXY/) c = "proxy"
       else if (id ~ /Hostless/) c = "hostless"
       else if (id ~ /NOIRQ|MMAP/) c = "mmap"
       print d, c, id }' $W/raw/pcm.txt > $MICD/pcm-class.txt
# per capture substream: key|dev|class|id|first|last|states|frames/s|rate|channels|format|running samples
awk -v cf=$MICD/pcm-class.txt '
  BEGIN { while ((getline l < cf) > 0) { split(l, a, " "); id = l; sub(/^[^ ]+ [^ ]+ /, "", id); cls[a[1]] = a[2]; nm[a[1]] = id } }
  /^@ / { t = $2; next }
  { p = index($0, ":"); if (!p) next; path = substr($0, 1, p - 1); rest = substr($0, p + 1)
    k = path; sub(/\/(status|hw_params)$/, "", k)
    dev = k; sub(/^card[0-9]+\/pcm/, "", dev); sub(/c\/.*/, "", dev); dev = dev + 0
    q = index(rest, ":"); f = substr(rest, 1, q - 1); v = substr(rest, q + 1); gsub(/^ +| +$/, "", f); gsub(/^ +| +$/, "", v)
    if (!(k in seen)) { seen[k] = 1; ord[++nk] = k; first[k] = t; kd[k] = dev }
    last[k] = t
    if (f == "state") { if (!index(" " st[k] " ", " " v " ")) st[k] = st[k] (st[k] == "" ? "" : " ") v; if (v == "RUNNING") nrun[k]++ }
    else if (f == "hw_ptr") { v += 0; if ((k in hp) && t > ht[k] && v >= hp[k]) { fr[k] += v - hp[k]; dt[k] += t - ht[k] }; hp[k] = v; ht[k] = t }
    else if (f == "rate") rate[k] = v + 0
    else if (f == "channels") ch[k] = v
    else if (f == "format") fm[k] = v
  }
  END { for (i = 1; i <= nk; i++) { k = ord[i]; d = kd[k]
      r = (dt[k] > 0) ? fr[k] / dt[k] : -1
      printf "%s|%s|%s|%s|%s|%s|%s|%.0f|%s|%s|%s|%d\n", k, d, ((d in cls) ? cls[d] : "?"), ((d in nm) ? nm[d] : "?"), first[k], last[k], st[k], r, rate[k], ch[k], fm[k], nrun[k] } }' $MICD/pcm-samples.txt > $MICD/capture.txt
nsmp=$(grep -c '^@ ' $MICD/pcm-samples.txt)
det "микрофон: замеров за $WIN с: $nsmp; потоков записи: $(grep -c . $MICD/capture.txt)"
nuser=0; nflow=0; MICFE=
while IFS='|' read -r mk md mc mid mt0 mt1 msts mr mrate mch mfm mnr; do
  case "$mc" in us|listen|hostless|proxy) det "микрофон: служебный поток записи $mk («$mid», класс $mc): $msts"; continue;; esac
  nuser=$((nuser + 1))
  [ -z "$MICFE" ] && MICFE=$mid
  det "микрофон: поток записи $mk («$mid»): с $mt0 по $mt1 с, состояния: $msts, ${mrate:-?} Гц, каналов ${mch:-?}, ${mfm:-?}; кадров в секунду: $mr"
  if [ "${mnr:-0}" -ge 2 ] && [ "${mr:--1}" -le 0 ] 2>/dev/null; then
    fail "микрофон" "поток записи $mk («$mid») работает (RUNNING), но данные не идут: hw_ptr не растёт — DSP или бэкенд TX не отдаёт кадры"
  elif [ "${mr:--1}" -gt 0 ] 2>/dev/null; then
    nflow=$((nflow + 1))
    if [ -n "$mrate" ] && [ "$mrate" -gt 0 ] 2>/dev/null && [ "$mr" -lt $((mrate / 2)) ]; then
      warn "микрофон" "данные записи идут медленно: $mk («$mid»), около $mr кадров в секунду при $mrate Гц (обрывы?)"
    else
      ok "микрофон" "данные записи идут: $mk («$mid»), около $mr кадров в секунду (${mrate:-?} Гц, каналов ${mch:-?}); тишину так не увидеть — если запись беззвучная, смотрите цепочку TX и микшер"
    fi
  fi
  case " $msts " in *" XRUN "*) warn "микрофон" "поток записи $mk («$mid») был в состоянии XRUN (приложение не успевало забирать данные)";; esac
done < $MICD/capture.txt
[ "$nuser" = 0 ] && warn "микрофон" "за $WIN с наблюдения ни одно приложение не начало запись (поток записи PCM не открывался): запись не начали, или звук пишется не через ALSA (USB- или Bluetooth-микрофон)"
# the TX chain in DAPM (debugfs): the sample with the most widgets on
MICBR=
if [ -n "$MICDW" ] && [ -s $MICD/dapm-samples.txt ]; then
  awk '/^@ / { if (n > bn) { bn = n; b = s }; s = $0 "\n"; n = 0; next } { s = s $0 "\n"; if ($0 ~ /: On /) n++ } END { if (n > bn) { bn = n; b = s }; printf "%s", b }' $MICD/dapm-samples.txt > $MICD/dapm-peak.txt
  case "$MICFE" in
    MultiMedia[0-9]*) fe=MM_UL$(echo "$MICFE" | sed -n 's/^MultiMedia\([0-9]*\).*/\1/p');;
    VoiceMMode[0-9]*) fe=VOICEMMODE$(echo "$MICFE" | sed -n 's/^VoiceMMode\([0-9]*\).*/\1/p')_UL;;
    VoIP*) fe=VOIP_UL;;
    *) fe=MM_UL1;;
  esac
  awk -v fe="$fe" '
    /^@ / { next }
    { p0 = index($0, "/dapm/"); if (!p0) next
      comp = substr($0, 1, p0 - 1); rest = substr($0, p0 + 6); p = index(rest, ":")
      w = substr(rest, 1, p - 1); line = substr(rest, p + 1)
      if (w == "bias_level") { bl = bl (bl == "" ? "" : ", ") comp "=" line; next }
      st = (line ~ /: On /) ? 1 : 0
      s = ""
      if (w == fe) s = 1
      else if (w ~ /^(TX|VA)_CDC_DMA_TX_[0-9]+$/) s = 2
      else if (w ~ /^(TX|VA)_AIF[0-9] CAP$/) s = 3
      else if (w ~ /^(TX|VA) DEC[0-9] MUX$/) s = 4
      else if (w ~ /^((TX|VA) SMIC MUX[0-9]+|(TX|VA) SWR_(MIC|ADC|DMIC)[0-9]+)$/) s = 5
      else if (w ~ /^(ADC[0-9]|DMIC[0-9]|ADC[0-9]_MIXER)$/) s = 6
      else if (w ~ /MIC BIAS[0-9]$/) s = 7
      if (s == "") next
      seen[s] = 1
      if (st) on[s] = on[s] (on[s] == "" ? "" : ", ") w; else off[s] = off[s] (off[s] == "" ? "" : ", ") w
    }
    END {
      split("поток (front end)|бэкенд CDC DMA TX|интерфейс TX кодека (AIF CAP)|дециматор (DEC MUX)|вход макроса TX (SMIC MUX)|АЦП кодека WCD937x (ADC/DMIC)|питание микрофона (MIC BIAS)", nm, "|")
      br = 0
      for (i = 1; i <= 7; i++) {
        if (!seen[i]) { printf "S%d %s: нет виджета\n", i, nm[i]; continue }
        printf "S%d %s: вкл.: %s; выкл.: %s\n", i, nm[i], (on[i] == "" ? "-" : on[i]), (off[i] == "" ? "-" : off[i])
        if (on[i] == "" && !br) { br = i; brn = nm[i] }
      }
      print "BREAK " br " " brn
      print "BIAS " bl
    }' $MICD/dapm-peak.txt > $MICD/tx-chain.txt
  MICBR=$(sed -n 's/^BREAK \([0-9]*\).*/\1/p' $MICD/tx-chain.txt)
  brn=$(sed -n 's/^BREAK [0-9]* //p' $MICD/tx-chain.txt)
  sed -n 's/^S/  S/p' $MICD/tx-chain.txt | while IFS= read -r l; do det "микрофон: цепочка TX:$l"; done
  if [ "$nuser" -gt 0 ]; then
    if [ "${MICBR:-0}" = 1 ]; then warn "микрофон" "в DAPM front end записи ($fe) выключен, хотя поток записи был открыт (цепочка TX — в подробностях)"
    elif [ "${MICBR:-0}" -gt 1 ]; then fail "микрофон" "цепочка TX оборвана: «$brn» выключен(а), хотя всё до этого включено (виджеты DAPM — в подробностях и mic.txt)"
    else ok "микрофон" "цепочка TX в DAPM включена от front end ($fe) до MIC BIAS"; fi
  fi
else
  det "микрофон: DAPM не прочитан (debugfs не смонтирован: $ASOC нет) — состояние цепочки TX не проверено"
fi
# the window's logs: the kernel after the mark, the HAL since the window's start
det "микрофон: окно записи — с $MICT0 (журнал ядра — после метки ${MICKM:-?} с)"
tmo 30 dmesg 2>/dev/null | awk -v m="${MICKM:-0}" '{ t = $0; sub(/^\[ */, "", t); sub(/\].*/, "", t) } t + 0 > m + 0' | kmask > $MICD/kernel.txt
cat > $TMPD/maskp.awk <<'EOF'
# phone numbers in logcat messages (the threadtime prefix is kept): written
# with separators (+7 999 123-45-67, 8 (999) 123 45 67)
{
  p = ""; s = $0
  if (match(s, /^ *([0-9][0-9-]* +)?[0-9][0-9:.]* +[0-9]+ +[0-9]+ [VDIWEFS] [^:]*: /)) {
    p = substr(s, 1, RLENGTH); s = substr(s, RLENGTH + 1)
  }
  gsub(/\+?[0-9][0-9 ()-][0-9 ()-][0-9 ()-][0-9 ()-][0-9 ()-][0-9 ()-][0-9 ()-][0-9 ()-]+[0-9]/, "N", s)
  print p s
}
EOF
tmo 60 logcat -d -b main,system -v threadtime -T "${MICT0:-$TSTART}" 2>/dev/null |
  grep -iE 'audio_hw|audio_route|msm8974_platform|AudioRecord|AudioFlinger|AudioPolicy|APM_|ahal|agm|pal_|soundtrigger|record|Codec2|MediaRecorder|tinyalsa|hardware_info|acdb' | lmask | awk -f $TMPD/maskp.awk | appmask > $MICD/logcat.txt
MICKE='afe.*(fail|err)|adm.*(fail|err)|q6asm.*(fail|err)|asm.*open failed|swr.*(fail|err|timeout)|wcd.*(fail|err)|bolero.*(fail|err)|(tx|va)_macro.*(fail|err)|msm_pcm.*(fail|err)|ASoC: .*error|dapm.*(fail|err)'
grep -iE "$MICKE" $MICD/kernel.txt | grep -v 'AFE_PARAM_ID_TFADSP_RX_CFG' > $TMPD/mic-kerr.txt
c=$(grep -c . $TMPD/mic-kerr.txt)
[ "$c" -gt 0 ] && fail "микрофон" "ядро во время записи: строк ошибок звука $c (первая: «$(head -1 $TMPD/mic-kerr.txt | sed -E 's/^\[ *[0-9.]+\] *//' | cut -c1-120)»)"
mport=$(grep -oE 'port_id = 0x[0-9a-fA-F]+' $MICD/kernel.txt | sort | uniq -c | tr -s ' ' | tr '\n' ';')
det "микрофон: порты AFE в журнале ядра за время записи: ${mport:-нет строк}"
for p in 'pcm_open failed' 'cannot open device' 'pcm_read.*(fail|error)' 'start_input_stream.*(fail|error)' 'Could not get ctl' 'failed to (open|start)' 'AudioRecord.*(error|fail)' 'obtainBuffer timed out' 'Invalid input'; do
  # (not "Could not get ctl ... App Type Cfg": hostless front ends have no App Type control, section 13)
  grep -E -e "$p" $MICD/logcat.txt | grep -v 'App Type Cfg' > $TMPD/mic-herr.txt
  c=$(grep -c . $TMPD/mic-herr.txt)
  [ "$c" -gt 0 ] && fail "микрофон" "HAL во время записи: $c × «$p» ($(head -1 $TMPD/mic-herr.txt | sed -E 's/^.*: //' | cut -c1-100))"
done
# the HAL's input device and mixer paths of the window: their controls
# against what was read while the capture ran
mdevs=$( { sed -n 's/.*enable_snd_device: snd_device([0-9]*: \([^)]*\)).*/\1/p' $MICD/logcat.txt; sed -n 's/.*input device from(.*) to (\([0-9]*\): \([^,]*\),.*/\2/p' $MICD/logcat.txt; } | grep -i 'mic' | sort -u | tr '\n' ' ' | sed 's/ $//')
mroutes=$(sed -n 's/.*apply mixer and update path: \([^ ]*\).*/\1/p' $MICD/logcat.txt | grep -E 'record|voice|voip|call|capture' | grep -v 'vi-record' | sort -u | tr '\n' ' ' | sed 's/ $//')
det "микрофон: устройства ввода HAL: ${mdevs:-не видно в logcat}; пути: ${mroutes:-не видно в logcat}"
MP1=$(echo $MP | cut -d' ' -f1)
if [ -s $MICD/mixer-tx.txt ] && [ -n "$MP1" ] && [ -n "$mdevs$mroutes" ]; then
  awk -v want="$(echo $mroutes $mdevs | tr ' ' ',')" '
    FNR == 1 { fi++ }
    /<path name="[^"]*" *>/ { n = $0; sub(/.*<path name="/, "", n); sub(/".*/, "", n); if (cur == "") { cur = n; body[n] = ""; next } }
    cur != "" && /<path name="[^"]*" *\/>/ { n = $0; sub(/.*<path name="/, "", n); sub(/".*/, "", n); body[cur] = body[cur] "\001P" n; next }
    cur != "" && /<ctl name="/ { n = $0; sub(/.*<ctl name="/, "", n); sub(/".*/, "", n); v = $0; if (sub(/.*value="/, "", v)) sub(/".*/, "", v); else v = "?"; body[cur] = body[cur] "\001C" n "\002" v; next }
    cur != "" && /<\/path>/ { cur = ""; next }
    function walk(p, d,   k, i, a, e, x) { if (d > 8 || !(p in body)) return; k = split(body[p], a, "\001")
      for (i = 2; i <= k; i++) { e = substr(a[i], 2); if (substr(a[i], 1, 1) == "P") walk(e, d + 1); else { split(e, x, "\002"); if (!(x[1] in val)) o[++no] = x[1]; val[x[1]] = x[2] } } }
    END { k = split(want, w, ","); for (i = 1; i <= k; i++) if (w[i] != "") walk(w[i], 0); for (i = 1; i <= no; i++) print o[i] "\t" val[o[i]] }' "$MP1" > $MICD/path-ctls.txt
  awk -F'\t' 'function norm(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); if (index(s, ">")) { s = substr(s, index(s, ">") + 1); sub(/[ ,\t].*/, "", s) }
                                 sub(/[ ,\t].*/, "", s); if (s == "On") s = 1; if (s == "Off") s = 0; return s }
    FNR == NR { a[$1] = norm($2); next }
    ($1 in a) { n++; e = norm($2); if (a[$1] != e) { m++; printf "%s = %s (путь задаёт %s)\n", $1, a[$1], e } }
    END { printf "#%d %d\n", n + 0, m + 0 }' $MICD/mixer-tx.txt $MICD/path-ctls.txt > $MICD/mixer-cmp.txt
  mn=$(sed -n 's/^#\([0-9]*\) .*/\1/p' $MICD/mixer-cmp.txt); mm=$(sed -n 's/^#[0-9]* \([0-9]*\)/\1/p' $MICD/mixer-cmp.txt)
  if [ "${mm:-0}" -gt 0 ]; then
    warn "микрофон" "элементы микшера во время записи не совпадают с путями прошивки ($mroutes${mroutes:+ }$mdevs): $(grep -v '^#' $MICD/mixer-cmp.txt | head -4 | tr '\n' ';' | sed 's/;$//')"
  elif [ "${mn:-0}" -gt 0 ]; then
    ok "микрофон" "элементы микшера во время записи совпадают с путями прошивки ($mroutes${mroutes:+ }$mdevs; элементов: $mn)"
  else det "микрофон: ни одного элемента путей $mroutes${mroutes:+ }$mdevs среди прочитанных элементов TX"; fi
elif [ ! -s $MICD/mixer-tx.txt ]; then
  det "микрофон: элементы микшера TX не прочитаны (запись не шла 2 секунды подряд или нет tinymix)"
fi
# mic.txt: the same, for reading
{
  echo "$TYBAN — проверка микрофона"
  echo "$KLINE; $PHLINE; запуск: $N"
  echo
  echo "== потоки записи PCM за $WIN с (ключ|устройство|класс|имя|с|по|состояния|кадров в секунду|Гц|каналов|формат|замеров RUNNING)"
  cat $MICD/capture.txt
  echo
  echo "== цепочка TX в DAPM (самый «включённый» замер)"
  if [ -s $MICD/tx-chain.txt ]; then cat $MICD/tx-chain.txt; else echo "не прочитана (нет debugfs)"; fi
  echo
  echo "== элементы микшера TX во время записи (с ${MICMX:-?} с) и пути прошивки"
  echo "устройства ввода HAL: ${mdevs:--}; пути: ${mroutes:--}; файл путей: ${MP1:--}"
  [ -s $MICD/mixer-cmp.txt ] && grep -v '^#' $MICD/mixer-cmp.txt
  echo
  echo "== ошибки ядра за время записи"
  cat $TMPD/mic-kerr.txt
  echo
  echo "== файлы: mic/pcm-samples.txt, dapm-samples.txt, dapm-peak.txt, mixer-tx.txt, path-ctls.txt, kernel.txt, logcat.txt"
} > $MICF 2>/dev/null
fi

########################################################################
sec "14. Камера"
# (through a file: the dump starts with an empty line, and $(...) of its
# first bytes is empty on every phone; dumpsys -t 10 prints text on a timeout)
CAMD=$TMPD/camera.txt
dsys media.camera > $CAMD
NCAM=$(grep -m1 'Number of camera devices' $CAMD | grep -oE '[0-9]+$')
if ! grep -q '[^[:space:]]' $CAMD 2>/dev/null; then warn "камера" "служба камеры не ответила (dumpsys media.camera пуст или не уложился в 45 с): число камер не проверено"
elif [ -z "$NCAM" ] && grep -q 'DUMP TIMEOUT' $CAMD; then warn "камера" "служба камеры не ответила за 10 с (dumpsys media.camera): число камер не проверено"
elif [ -n "$NCAM" ] && [ "$NCAM" -gt 0 ]; then ok "камера" "камер: $NCAM"
else fail "камера" "служба камеры сообщает о ${NCAM:-0} камерах"; fi
det "узлов video: $(ls /dev/video* /dev/v4l-subdev* 2>/dev/null | wc -l)"
for v in /sys/class/video4linux/*; do det "$(rd $v/name)"; done
# sensor probes run when the camera provider starts, a few seconds after boot
pr=$(grep -oE 'Probe success,slot:[0-9]+,slave_addr:0x[0-9a-fA-F]+,sensor_id:0x[0-9a-fA-F]+' $W/raw/dmesg.txt | sort -u)
np=$(printf '%s\n' "$pr" | grep -c 'slot:'); det "найденные датчики камер ($np): $(echo $pr)"
d0=$(head -1 $W/raw/dmesg.txt | sed -nE 's/^\[ *([0-9]+)\..*/\1/p')
if [ -n "$d0" ] && [ "$d0" -lt 30 ]; then
  [ "$np" -ge 4 ] && kok "камера" "найдены все 4 датчика камер" || warn "камера" "найдено только $np из 4 датчиков камер (слоты: $(printf '%s\n' "$pr" | grep -oE 'slot:[0-9]+' | tr '\n' ' '))"
fi
# (not counted: "Client=... is not started" at close, "cam cci err" from the
# probe of the macro module variant this phone does not have (listed below),
# "no valid IFE TPG HW" (no test pattern generator, harmless) and, once all 4
# sensors have probed, a probe-time CCI NACK block: the NACK, the failed CCI
# and sensor reads, ending within 2 s in "cam_sensor_subdev_ioctl ... Failed
# in Driver cmd: -19" (-ENODEV: an alternate sensor that is not fitted))
CAMOK=; [ "$np" -ge 4 ] && CAMOK=1
: > $TMPD/cam-nack.txt
grep -E "CAM_ERR" $W/raw/dmesg-nospam.txt | grep -vE 'is not started|cam cci err|no valid IFE TPG HW' | awk -v ok4="$CAMOK" -v df=$TMPD/cam-nack.txt '
  function ts(t) { sub(/^\[ */, "", t); sub(/\].*/, "", t); return t + 0 }
  function flush(  i) { for (i = 1; i <= nb; i++) print b[i]; nb = 0 }
  ok4 && /cam_cci_irq: .*NACK ERROR/ { flush(); nb = 1; b[1] = $0; t0 = ts($0); next }
  nb && /CAM-(CCI|SENSOR):/ && ts($0) - t0 < 2 {
    b[++nb] = $0
    if ($0 ~ /cam_sensor_subdev_ioctl: .*Failed in Driver cmd: -19/) { for (i = 1; i <= nb; i++) print b[i] > df; nb = 0 }
    next }
  { flush(); print }
  END { flush() }' > $TMPD/camerr.txt
c=$(wc -l < $TMPD/camerr.txt); [ "$c" -gt 0 ] && warn "камера" "в журнале ядра $c строк CAM_ERR" && sed -E 's/^\[ *[0-9.]+\] *//' $TMPD/camerr.txt | sort | uniq -c | sort -rn | head -20 >> $DET
[ -s $TMPD/cam-nack.txt ] && { det "CCI NACK при поиске датчика, которого нет в телефоне (кончается -19; все 4 датчика найдены), не считается:"; sed -E 's/^\[ *[0-9.]+\] *//' $TMPD/cam-nack.txt >> $DET; }
grep -E 'cam cci err' $W/raw/dmesg-nospam.txt | sed -E 's/^\[ *[0-9.]+\] *//' | sort | uniq -c | head -10 >> $DET
# the main log (CamX, the camera HAL, cameraserver log there): it holds far
# less time than the system log, and once it has wrapped the camera HAL's
# errors are gone (prep clears and enlarges it); its first line in s since
# boot (the line after logcat's "beginning of main")
ml0=$(awk '/beginning of main/ { if ((getline l) > 0) { split(l, f, " "); if (f[1] ~ /^[0-9]+\.[0-9]+$/) printf "%d", f[1] }; exit }' $TMPD/mainsys.txt)
if [ -n "$ml0" ] && [ "$ml0" -gt 120 ]; then
  if [ -f $PREPF ]; then det "журнал main начинается через $ml0 с после включения (после prep см. raw/logcat-since-prep.txt)"
  else warn logcat "журнал main начинается через $ml0 с после включения: строки HAL камеры (и других HAL) до этого уже потеряны; запустите prep (он увеличит буфер), затем повторите проблему"; fi
fi
# how much time the main log held when it was read: a buffer that other
# programs fill fast keeps only seconds
mcov=; [ -n "$ml0" ] && [ -n "$LCUP" ] && mcov=$(( ${LCUP%.*} - ml0 ))
[ -n "$mcov" ] && [ "$mcov" -lt 60 ] && det "ВНИМАНИЕ: журнал main (в него пишут HAL камеры, звука, датчиков) при чтении хранил только последние $mcov с (с $ml0 с после включения): более ранние строки уже вытеснены. Чтобы ошибка попала в журнал, запустите проверку сразу после того, как она случилась (лучше — сначала prep: он увеличит буфер)"
# (CAM_ACQUIRE_DEV: the kernel's line of a camera opened by an app)
[ "$KLOG" = 1 ] && ! grep -q 'CAM_ACQUIRE_DEV' $W/raw/dmesg.txt && det "камера за время записи журнала ядра не открывалась: съёмка не проверена (откройте камеру незадолго до проверки)"
# CSI-2 receive and path errors between a sensor and the ISP
CSIDE='CSID:[0-9]+ (RX_ERROR|CPHY_PH_CRC|ERROR_CRC|ERROR_ECC|UNBOUNDED_FRAME|[A-Z]+_PATH_ERROR)'
c=$(grep -cE "$CSIDE" $W/raw/dmesg-nospam.txt)
[ "$c" -gt 0 ] && { fail "камера" "$c ошибок CSI-2/CSID во время работы камеры (линии датчика или настройки CSIPHY)"; grep -oE "$CSIDE[A-Z0-9_]*" $W/raw/dmesg-nospam.txt | sort | uniq -c >> $DET; }

########################################################################
sec "14b. Видео"
grep -E 'vpu20_1v|venus|msm_vidc.*(fw|firmware)' $W/raw/dmesg.txt | sed -E 's/^\[ *[0-9.]+\] *//' | head -8 >> $DET
c=$(grep -cE 'Failed to load Venus FW|firmware download failed|SFR Message from FW|HFI_EVENT_SYS_ERROR|SYS_ERROR received' $W/raw/dmesg-nospam.txt)
[ "$c" -gt 0 ] && { fail "видео" "$c ошибок прошивки видео (не загрузилась, SFR или SYS_ERROR)"; grep -E 'Failed to load Venus FW|firmware download failed|SFR Message from FW|HFI_EVENT_SYS_ERROR|SYS_ERROR received' $W/raw/dmesg-nospam.txt | sed -E 's/^\[ *[0-9.]+\] *//' | sort | uniq -c | head -10 >> $DET; }
det "аппаратные кодеки с момента включения: $(dsys media.metrics | grep -oE 'c2\.qti\.[a-z0-9.]+' | sort | uniq -c | sort -rn | head -8 | tr -s ' ' | tr '\n' ' ')"

########################################################################
sec "15. Дисплей, ввод, датчики"
for c in /sys/class/drm/card*-*; do [ -e $c/status ] && det "${c##*/}: $(rd $c/status) $(rd $c/enabled)"; done
grep -qx connected /sys/class/drm/card*-DSI-*/status 2>/dev/null && ok "дисплей" "панель DSI подключена" || warn "дисплей" "в /sys/class/drm нет подключённого разъёма DSI"
for b in /sys/class/backlight/*; do [ -e $b ] && det "подсветка ${b##*/}: $(rd $b/brightness)/$(rd $b/max_brightness)"; done
dsys display | grep -E 'supportedModes|mActiveModeId|renderFrameRate' | head -5 >> $DET
# (Bluetooth and USB input devices carry MAC addresses in Phys and Uniq, USB
# ones also their serial number in Uniq)
sed "$MAC" /proc/bus/input/devices 2>/dev/null | sed -E 's/^(U: Uniq=).+/\1x/' > $W/raw/input.txt
# (goodix_ts or fts_ts; not the fingerprint HAL's uinput-goodix)
TSN=$(grep -iE 'N: Name="[^"]*(goodix|fts|focal|touch)' $W/raw/input.txt | grep -viE 'N: Name="uinput' | head -1 | cut -d'"' -f2)
[ -n "$TSN" ] && ok "ввод" "сенсорный экран: $TSN" || fail "ввод" "нет устройства ввода сенсорного экрана"
grep -qE 'N: Name="(pmic_pwrkey|qpnp_pon|pm8941_pwrkey|.*pwrkey)' $W/raw/input.txt && ok "ввод" "кнопка питания" || fail "ввод" "нет устройства ввода кнопки питания"
grep -qE 'N: Name="gpio-keys' $W/raw/input.txt && ok "ввод" "gpio-keys (громкость вверх)" || warn "ввод" "нет устройства gpio-keys"
grep 'N: Name=' $W/raw/input.txt >> $DET
# taoyao has the SSC sensors (accelerometer, gyroscope, magnetometer, light,
# and the virtual ones on top) besides proximity, touch and UDFPS: fewer than
# 8 means the ADSP sensors PD (sscrpcd through FastRPC) did not come up
SSV=$TMPD/sensorservice.txt
dsys sensorservice > $SSV
sed -n '/^Sensor List:/,/^Fusion States:/p' $SSV | grep -E '^0x' | cut -d'|' -f1-4 > $W/raw/sensors.txt
NSENS=$(grep -m1 -oE '[0-9]+ h/w sensors' $SSV | grep -oE '^[0-9]+')
miss=
for t in accelerometer gyroscope magnetic_field light; do grep -q "android\.sensor\.$t(" $W/raw/sensors.txt || miss="$miss $t"; done
if [ ! -s $SSV ]; then warn "датчики" "служба датчиков не ответила (dumpsys sensorservice пуст или не уложился в 45 с): датчики не проверены"
elif [ -z "$NSENS" ]; then fail "датчики" "служба датчиков не показывает ни одного аппаратного датчика"
elif [ "$NSENS" -lt 8 ]; then fail "датчики" "аппаратных датчиков только $NSENS (нет:${miss:- ни одного из основных}); датчики SSC идут из sensors PD на ADSP через sscrpcd и FastRPC"
elif [ -n "$miss" ]; then fail "датчики" "аппаратных датчиков $NSENS, но нет:$miss"
else ok "датчики" "аппаратных датчиков: $NSENS"; fi
cat $W/raw/sensors.txt >> $DET
# no SSC sensors: where sscrpcd waits (wchan, the FastRPC frames of its
# threads' kernel stacks; its State and first frames are in section 12) and
# what the kernel logged about the sensors PD and its PDR (protection-domain
# restart) registration, also in the prep capture: the lookups added, the
# PDR callbacks, a lookup that failed (LOCATOR_ERR: "PD state not tracked")
# and a PDR that could not be set up (fastrpc_setup_service_locator, called
# by fastrpc_setup_pdr, logs "failed for")
if [ -z "$NSENS" ] || [ -n "$miss" ]; then
  det "--- датчиков SSC нет: sscrpcd и sensors PD на ADSP"
  ssp=$(pidof sscrpcd 2>/dev/null)
  [ -z "$ssp" ] && det "sscrpcd не запущен"
  for p in $ssp; do
    swc=$(rd /proc/$p/wchan)
    det "sscrpcd pid $p: wchan ${swc:--}, состояние $(sed 's/.*) //' /proc/$p/stat 2>/dev/null | cut -d' ' -f1), с $(pstart $p) с"
    case "$swc" in *fastrpc*) warn "датчики" "sscrpcd заблокирован в ядре (wchan $swc): его вызов FastRPC к sensors PD на ADSP не возвращается (стеки — в подробностях)";; esac
    nst=0
    for t in /proc/$p/task/*; do
      [ -e "$t/stack" ] || continue
      fr=$(rd $t/stack | grep -iE 'fastrpc|adsprpc' | head -3 | sed -E 's/^\[<[^>]*>\] *//; s/\+0x[0-9a-fA-F]+\/0x[0-9a-fA-F]+//' | tr '\n' ',' | sed 's/,$//; s/,/, /g')
      [ -z "$fr" ] && continue
      nst=$((nst + 1)); det "  поток ${t##*/} ($(rd $t/comm)): $fr"
    done
    [ "$nst" = 0 ] && det "  ни один его поток не в вызове FastRPC (/proc/$p/task/*/stack)"
  done
  SPDE='sensor_pd|sensors_pdr|is (up|down) for PDR|PDR:|pdr_add_lookup enabled|fastrpc_pdr_cb|PD state not tracked|fastrpc_setup_(pdr|service_locator).*failed'
  { cat $W/raw/dmesg-nospam.txt; [ -f $KMSG ] && kmask < $KMSG; } | grep -E "$SPDE" | sort -u > $TMPD/sensor-pd.txt
  spk=; [ -f $KMSG ] && spk=" и запись prep"
  det "журнал ядра$spk, sensors PD и PDR (строк: $(grep -c . $TMPD/sensor-pd.txt), первые 20):"
  head -20 $TMPD/sensor-pd.txt | cut -c1-220 >> $DET
fi

########################################################################
sec "16. Батарея и зарядка"
for p in /sys/class/power_supply/*; do
  [ -e $p ] || continue
  det "== ${p##*/}"
  for a in $p/*; do
    [ -f $a ] && [ -r $a ] || continue
    case ${a##*/} in uevent|*reset*|*_now_avg_*) continue;; esac
    v=$(timeout 3 cat $a 2>&1); rc=$?
    case ${a##*/} in *serial*|*romid*|*_sn) [ $rc = 0 ] && v="(прочитано, не показано)";; esac
    if [ $rc != 0 ]; then echo "ошибка чтения: $a: $v" >> $W/raw/psy-errors.txt; else det "${a##*/}=$v"; fi
  done
done
# the wireless supply is registered for parity with 5.4 (taoyao has no
# coil): with online=0 its readings answer ENODATA ("No data available"),
# expected; any other read error counts
if [ -f $W/raw/psy-errors.txt ]; then
  pwo=$(rd /sys/class/power_supply/wireless/online)
  if [ "$pwo" = 0 ]; then
    grep -E '^ошибка чтения: /sys/class/power_supply/wireless/[^:]+: .*No data available' $W/raw/psy-errors.txt | sed 's/^ошибка чтения: \([^:]*\):.*/\1/' | while read -r a; do
      det "${a#/sys/class/power_supply/}: ENODATA (беспроводная зарядка зарегистрирована для совместимости с 5.4, катушки нет: wireless/online=0; ожидаемо)"; done
    grep -vE '^ошибка чтения: /sys/class/power_supply/wireless/[^:]+: .*No data available' $W/raw/psy-errors.txt > $TMPD/psy-err.txt
  else cp $W/raw/psy-errors.txt $TMPD/psy-err.txt; fi
  [ -s $TMPD/psy-err.txt ] && warn "батарея" "$(grep -c . $TMPD/psy-err.txt) атрибутов power_supply не читаются (подробности)" && cat $TMPD/psy-err.txt >> $DET
fi
cap=$(rd /sys/class/power_supply/battery/capacity); tmp=$(rd /sys/class/power_supply/battery/temp)
[ -n "$cap" ] && ok "батарея" "заряд $cap%, температура $((${tmp:-0}/10)) °C, состояние $(rd /sys/class/power_supply/battery/status)" || fail "батарея" "нет уровня заряда батареи"
[ -n "$tmp" ] && { [ "$tmp" -lt -200 ] || [ "$tmp" -gt 600 ]; } && fail "батарея" "температура батареи $tmp (в десятых °C) неправдоподобна"

########################################################################
sec "17. Температура"
bad=0; nz=0
for z in /sys/class/thermal/thermal_zone*; do
  [ -e $z ] || continue
  nz=$((nz+1)); ty=$(rd $z/type); t=$(rd $z/temp)
  if [ -z "$t" ]; then bad=$((bad+1)); det "нет температуры: ${z##*/} $ty"; continue; fi
  if [ "$t" -lt -40000 ] || [ "$t" -gt 125000 ]; then bad=$((bad+1)); det "неправдоподобно: ${z##*/} $ty $t"; fi
  [ "$t" -gt 85000 ] && [ "$t" -le 125000 ] && warn "температура" "$ty горячий: $((t/1000)) °C"
done
det "зон: $nz"
[ $bad -gt 0 ] && warn "температура" "температурных зон без температуры или с неправдоподобной: $bad из $nz (подробности)" || ok "температура" "все $(pl $nz "температурная зона" "температурные зоны" "температурных зон") — с правдоподобной температурой"
for c in /sys/class/thermal/cooling_device*; do [ -e $c ] && det "$(rd $c/type) $(rd $c/cur_state)/$(rd $c/max_state)"; done
# Xiaomi's thermal_message class: what mi_thermald reads and sets (screen
# state, the board's virtual sensor, the thermal config, the CPU limits it
# asked for); read only
if [ -d /sys/class/thermal/thermal_message ]; then
  det "--- /sys/class/thermal/thermal_message"
  timeout 5 grep -r . /sys/class/thermal/thermal_message/ 2>/dev/null | sed 's|^/sys/class/thermal/thermal_message/||' | cut -c1-200 | head -40 >> $DET
fi

########################################################################
sec "18. Сон и простой"
ms=$(rd /sys/power/mem_sleep); det "mem_sleep: $ms"
ss=$(rd /sys/power/suspend_stats/success); sf=$(rd /sys/power/suspend_stats/fail)
det "сон (suspend): success=$ss fail=$sf last_failed_dev=$(rd /sys/power/suspend_stats/last_failed_dev) last_failed_errno=$(rd /sys/power/suspend_stats/last_failed_errno)"
# wakeup sources active for the whole run so far (active_time_ms: how long
# one has been active without a break, 0 while it is not): with one of them
# the phone cannot suspend and system_suspend does not even try. While USB
# is connected that is the USB controller's, a600000.ssusb: then no suspend
# since boot is "not attempted", not a failure (the header says how to test
# suspend unplugged)
RUNMS=$(awk -v a="$T0" -v b="$(up)" 'BEGIN { printf "%d", (b - a) * 1000 }')
WHELD=$(for w in /sys/class/wakeup/wakeup*; do [ -e "$w" ] && echo "$(rd $w/name) $(rd $w/active_time_ms)"; done |
  awk -v m="$RUNMS" 'NF >= 2 { t = $NF; $NF = ""; sub(/ +$/, ""); if (t + 0 > 0 && t + 0 >= m) printf "%s %s (активен %d с)", (n++ ? "," : ""), $0, t / 1000 }' | sed "$MAC")
WUSB=; case "$WHELD" in *usb*) WUSB=$(echo "$WHELD" | tr ')' '\n' | grep usb | sed 's/^[, ]*//; s/$/)/' | head -2 | tr '\n' ' ' | sed 's/ $//');; esac
[ -n "$WHELD" ] && det "источники пробуждения, активные с начала проверки (все $((RUNMS / 1000)) с до этого раздела):$WHELD"
SUSPT="чтобы проверить сон без USB: запустите prep, отключите USB, выключите экран на 10 минут, подключите и запустите проверку"
[ -n "$sf" ] && [ "$sf" -gt 0 ] && warn "сон" "$sf неудачных попыток уснуть (последнее помешавшее устройство: $(rd /sys/power/suspend_stats/last_failed_dev))"
if [ -n "$ss" ] && [ "$ss" -gt 0 ]; then
  if [ -n "$WUSB" ]; then ok "сон" "удачных засыпаний: $ss (пока подключён USB, их нет: $WUSB)"
  else ok "сон" "удачных засыпаний: $ss"; fi
elif [ -n "$WUSB" ]; then warn "сон" "засыпания не было (подключён USB): $WUSB не давал телефону уснуть с начала проверки (все $((RUNMS / 1000)) с до этого раздела); $SUSPT"
elif [ -n "$WHELD" ]; then warn "сон" "засыпания не было: источник(и) пробуждения$WHELD не давали телефону уснуть с начала проверки (все $((RUNMS / 1000)) с до этого раздела; источник, который никогда не отпускается, не даёт телефону спать)"
else warn "сон" "удачных засыпаний ещё не было (выключите экран на некоторое время и запустите снова)"; fi
# idle residency of every CPU (name:usage/time in us for each state)
for cpu in /sys/devices/system/cpu/cpu[0-9]*; do
  [ -d $cpu/cpuidle ] || continue
  ci=; for s in $cpu/cpuidle/state*; do [ -e $s ] && ci="$ci $(rd $s/name):$(rd $s/usage)/$(rd $s/time)"; done
  det "${cpu##*/} простой (состояние:раз/время мкс):$ci"
done
# what woke the phone last and how long it slept (wakeup_reasons), the
# interrupt that aborted or ended the last suspend (pm_wakeup_irq), and the
# power domains' idle states (the CPU cluster's CLUSTER_PD among them)
pwi=$(rd /sys/power/pm_wakeup_irq | tr '\n' ' '); det "pm_wakeup_irq: ${pwi:-- (не записано)}"
for f in last_resume_reason last_suspend_time; do [ -e /sys/kernel/wakeup_reasons/$f ] || continue; wr=$(rd /sys/kernel/wakeup_reasons/$f | tr '\n' ' ' | cut -c1-200); det "wakeup_reasons/$f: ${wr:-пусто (засыпания ещё не было)}"; done
if [ -f /sys/kernel/debug/pm_genpd/pm_genpd_summary ]; then
  det "--- /sys/kernel/debug/pm_genpd/pm_genpd_summary"; rd /sys/kernel/debug/pm_genpd/pm_genpd_summary | head -60 | cut -c1-160 >> $DET
  for g in /sys/kernel/debug/pm_genpd/*/idle_states; do
    [ -f "$g" ] || continue
    gn=${g%/idle_states}; gn=${gn##*/}
    gi=$(rd "$g" | sed 1d | tr -s ' \t' ' ' | tr '\n' ';' | cut -c1-200)
    [ -n "$gi" ] && det "genpd $gn состояния простоя: $gi"
  done
fi
for f in /sys/kernel/debug/qcom_stats/* /sys/power/system_sleep/stats /sys/power/rpmh_stats/master_stats; do [ -f $f ] && { det "== $f"; rd $f >> $DET; }; done
if [ -f /sys/kernel/debug/qcom_stats/aosd ]; then
  c=$(rd /sys/kernel/debug/qcom_stats/aosd | grep -m1 -iE '^count' | grep -oE '[0-9]+')
  if [ -z "$c" ]; then :
  elif [ "$c" -gt 0 ]; then ok "сон" "глубокий сон AOSS достигнут $(pl $c "раз" "раза" "раз")"
  elif [ -z "$ss" ] || [ "$ss" = 0 ] && [ -n "$WHELD" ]; then det "глубокий сон AOSS ни разу не достигнут (засыпания не было: источник пробуждения был активен с начала проверки)"
  else warn "сон" "глубокий сон AOSS ни разу не достигнут"; fi
fi
# tasks stuck in D state (uninterruptible): the hung-task watchdog reports
# them after 120 s, and one that does not freeze makes every suspend fail
# (sscrpcd waits that way for an ADSP that does not answer); also in the
# prep capture
HUNGE='blocked for more than|Freezing of tasks failed|Freezing user space processes failed'
{ cat $W/raw/dmesg-nospam.txt; [ -f $KMSG ] && kmask < $KMSG; } | grep -E "$HUNGE" | sort -u > $TMPD/hung.txt
c=$(grep -c . $TMPD/hung.txt)
if [ "$c" -gt 0 ]; then
  ht=$(sed -nE 's/.*INFO: task (.+):[0-9]+ blocked for more than.*/\1/p' $TMPD/hung.txt | sort -u | head -5 | tr '\n' ' ' | sed 's/ $//')
  warn "зависания" "в журнале ядра $c строк о зависших задачах или сбоях заморозки${ht:+ (заблокированы: $ht)}: задача, застрявшая в состоянии D, мешает сну (примеры — в подробностях)"
  det "--- зависшие задачи и сбои заморозки (первые 10 из $c)"; head -10 $TMPD/hung.txt | cut -c1-220 >> $DET
fi
rd /sys/kernel/debug/wakeup_sources | sed 1d | sort -k7 -n -r | head -15 > $W/raw/wakeup-top.txt
det "--- источники пробуждения по total_time (столбец 7 — всего мс удержания; последний столбец — prevent_suspend_time)"; cat $W/raw/wakeup-top.txt >> $DET
# the SELinux label of every wakeup source: system_suspend reads the name and
# counters of each /sys/class/wakeup/wakeupN and may read only sysfs_wakeup,
# which the policy gives by device path (genfscon .../wakeup): one under a
# path it does not know stays sysfs (denials, missing from the wakeup stats)
{ echo "# имя, настоящий путь, метка"
  for w in /sys/class/wakeup/wakeup*; do
    [ -e "$w" ] || continue
    wp=$(readlink -f "$w"); wl=$(ls -dZ "$wp" 2>/dev/null | awk '{ print $1 }')
    echo "$(rd "$w/name") $wp ${wl:-?}"
  done; } | sed "$MAC" > $W/raw/wakeup-labels.txt
nwl=$(grep -vc '^#' $W/raw/wakeup-labels.txt)
# (the alarmtimer source sits on the rtc class device, .../rtc0/wakeupN, as on
# 5.4: stock HyperOS's policy labels .../rtc0/wakeup/ with a trailing slash,
# so there it is sysfs_rtc, as with the stock kernel: expected; the ROM type
# as in section 20c)
: > $TMPD/wakeup-exp.txt; : > $TMPD/wakeup-known.txt
# known gaps, in the details: ssr(wpss) on the WPSS subsystem
# (.../subsys2/wakeup/wakeupN; the ROM's policy has no label for it, stock
# has the same gap) and the display's ae00000.qcom,mdss_mdp (a wakeup source
# only on 6.12; a kernel fix is pending)
awk -v stock="$IPAWANT" -v ex=$TMPD/wakeup-exp.txt -v kn=$TMPD/wakeup-known.txt '!/^#/ && $NF !~ /:sysfs_wakeup:/ {
    if (stock == "Y" && $1 == "alarmtimer" && $2 ~ /\/rtc[0-9]+\/wakeup[0-9]+$/ && $NF ~ /:sysfs_rtc:/) print > ex
    else if ($1 == "ssr(wpss)" && $2 ~ /\/subsys[0-9]+\/wakeup\/wakeup[0-9]+$/) print "пробел в политике прошивки (в стоке тоже):", $0 > kn
    else if ($1 == "ae00000.qcom,mdss_mdp") print "известный пробел ядра (исправление готовится):", $0 > kn
    else print }' $W/raw/wakeup-labels.txt > $TMPD/wakeup-bad.txt
nwb=$(grep -c . $TMPD/wakeup-bad.txt); nwe=$(grep -c . $TMPD/wakeup-exp.txt); nwk=$(grep -c . $TMPD/wakeup-known.txt)
WEXP=; [ "$nwe" -gt 0 ] && WEXP="; у alarmtimer (rtc0/wakeupN) метка sysfs_rtc — ожидаемо на стоковой HyperOS"
[ "$nwk" -gt 0 ] && WEXP="$WEXP; известные пробелы: $(awk '{ printf "%s%s", (n++ ? ", " : ""), $(NF - 2) }' $TMPD/wakeup-known.txt)"
[ "$nwe" -gt 0 ] && { det "--- метка sysfs_rtc, ожидаемо на стоковой HyperOS (её политика размечает только .../rtc0/wakeup/; имя, путь, метка)"; cat $TMPD/wakeup-exp.txt >> $DET; }
[ "$nwk" -gt 0 ] && { det "--- источники пробуждения без метки sysfs_wakeup: известные пробелы (имя, путь, метка)"; cat $TMPD/wakeup-known.txt >> $DET; }
if [ "$nwl" = 0 ]; then det "в /sys/class/wakeup ничего нет"
elif [ "$nwb" -gt 0 ]; then
  warn "пробуждение" "$nwb из $nwl источников пробуждения в /sys/class/wakeup без метки sysfs_wakeup: system_suspend не может их читать (подробности, raw/wakeup-labels.txt$WEXP)"
  det "--- источники пробуждения без метки sysfs_wakeup (имя, путь, метка)"; cat $TMPD/wakeup-bad.txt >> $DET
elif [ $((nwe + nwk)) -gt 0 ]; then ok "пробуждение" "все остальные $((nwl - nwe - nwk)) источников пробуждения в /sys/class/wakeup с меткой sysfs_wakeup$WEXP"
else ok "пробуждение" "все $nwl источников пробуждения в /sys/class/wakeup с меткой sysfs_wakeup"; fi
# Xiaomi's power debug class (mi_power_debug, built in): only listed, never
# written (a write to its wakeup_device_list returns 0: the writer retries
# for ever)
if [ -d /sys/class/power_debug ]; then det "--- ls -l /sys/class/power_debug"; ls -l /sys/class/power_debug >> $DET 2>&1
else det "нет /sys/class/power_debug (mi_power_debug)"; fi

########################################################################
sec "19. Процессор, память, прерывания"
on=$(rd /sys/devices/system/cpu/online); [ "$on" = 0-7 ] && ok "процессор" "работают ядра 0-7" || warn "процессор" "работают ядра процессора: $on"
for p in /sys/devices/system/cpu/cpufreq/policy*; do
  [ -e $p ] || continue
  det "${p##*/}: $(rd $p/scaling_governor) $(rd $p/cpuinfo_min_freq)-$(rd $p/cpuinfo_max_freq) cur $(rd $p/scaling_cur_freq) limits $(rd $p/scaling_min_freq)-$(rd $p/scaling_max_freq)"
done
mt=$(grep MemTotal /proc/meminfo | awk '{print $2}'); det "MemTotal $mt кБ"
# the load average counts tasks in D state too: a task stuck there (the
# power key's longpress kthread) keeps it at 1 or more on an idle phone.
# The tasks in D state now (pid, name, wchan; kernel threads included),
# read again after 1 s so that a short wait does not count
det "loadavg: $(cat /proc/loadavg 2>/dev/null)"
dst=
for st in /proc/[0-9]*/stat; do
  read -r l 2>/dev/null < "$st" || continue
  case "$l" in *") D "*) dst="$dst ${l%% *}";; esac
done
dl=
if [ -n "$dst" ]; then
  sleep 1
  for pd in $dst; do
    read -r l 2>/dev/null < /proc/$pd/stat || continue
    case "$l" in *") D "*) ;; *) continue;; esac
    cm=$(printf '%s\n' "$l" | sed 's/^[0-9]* [(]//; s/[)] [A-Z] .*//' | tr ' ' '_')
    dl="$dl $pd:$cm[$(rd /proc/$pd/wchan)]"
  done
fi
if [ -n "$dl" ]; then
  warn "процессор" "задачи в состоянии D (непрерываемое ожидание дольше 1 с; поднимают load average и могут мешать сну):$dl"
else det "задач в состоянии D нет"; fi
grep -q zram /proc/swaps && ok "память" "подкачка zram работает" || warn "память" "нет подкачки zram"
[ -e /proc/pressure/memory ] && ok "память" "PSI есть (для lmkd)" || fail "память" "нет /proc/pressure/memory: lmkd нужен PSI"
cat /proc/interrupts > $W/raw/irq1.txt; sleep 5; cat /proc/interrupts > $W/raw/irq2.txt
# a device interrupt over 500/s is a storm; the per-CPU timer and the IPIs
# (3000/s and 2000/s on an idle taoyao while this runs) only over 8000/s
awk 'NR==FNR { if (NR>1) { s=0; for (i=2;i<=9;i++) s+=$i; a[$1]=s }; next }
     FNR>1 { s=0; for (i=2;i<=9;i++) s+=$i; d=(s-a[$1])/5; lim = ($1 ~ /^IPI/ || $NF == "arch_timer") ? 8000 : 500
             if (d>lim) { $2=$3=$4=$5=$6=$7=$8=$9=""; printf "%d/с %s\n", d, $0 } }' $W/raw/irq1.txt $W/raw/irq2.txt | sort -rn > $W/raw/irq-storm.txt
grep -E "$MEDIRQ" $W/raw/irq2.txt > $W/raw/irq-media.txt
if [ -f $IRQP ]; then
  # (a camera open adds hundreds on ife and a5, a few on csid; tens on csid are CSI-2 errors)
  awk 'NR == FNR { s = 0; for (i = 2; i <= 9; i++) s += $i; a[$1] = s; next }
       { s = 0; for (i = 2; i <= 9; i++) s += $i; n = ""; for (i = 10; i <= NF; i++) n = n " " $i
         if ($1 in a) printf "%s %d -> %d (+%d)%s\n", $1, a[$1], s, s - a[$1], n; else printf "%s - -> %d%s\n", $1, s, n }' $IRQP $W/raw/irq-media.txt > $W/raw/irq-media-delta.txt
  det "прерывания медиаблоков с момента prep:"; cat $W/raw/irq-media-delta.txt >> $DET
fi
if [ -s $W/raw/irq-storm.txt ]; then
  while read -r rate rest; do warn "прерывания" "$rate прерываний: $(echo $rest | cut -c1-90)"; done < $W/raw/irq-storm.txt
else
  ok "прерывания" "ни у одного устройства нет больше 500 прерываний в секунду"
fi

########################################################################
sec "20. Сеть, модем, Bluetooth, NFC, USB"
tmo 10 ip link 2>/dev/null | sed "$MAC" > $W/raw/iplink.txt
grep -q 'wlan0' $W/raw/iplink.txt && ok Wi-Fi "wlan0 есть" || fail Wi-Fi "нет wlan0"
det "$(grep -oE '^[0-9]+: [^:]+' $W/raw/iplink.txt | tr '\n' ' ')"
grep -q rmnet $W/raw/iplink.txt && ok "мобильные данные" "интерфейсы rmnet есть" || warn "мобильные данные" "нет интерфейса rmnet"
# rmnet_shs, rmnet_offload, rmnet_perf (the data path's steering and
# offload): the vendor wants them when persist.vendor.data.<x>_ko_load is 1
# (stock keeps them loaded); one that is not loaded then, with the kernel
# log's line of its unload ("Exiting rmnet SHS module", "rmnet_offload
# exiting": netmgrd unloads them at boot when it cannot use them). Unloaded
# by netmgrd on a ROM with its own vendor (Evolution X and others) is
# expected there: the data path works without them (an OK with the reason).
rmq=; rmu=
for rk in shs:rmnet_shs offload:rmnet_offload perf:rmnet_perf; do
  [ "$(getprop persist.vendor.data.${rk%%:*}_ko_load)" = 1 ] || continue
  rmn=${rk#*:}
  grep -q "^$rmn " $W/raw/modules.txt && continue
  [ -d /sys/module/$rmn ] && continue
  case $rmn in rmnet_shs) rme='Exiting rmnet SHS module';; rmnet_offload) rme='rmnet_offload exiting';; *) rme='rmnet_perf.*exit';; esac
  rml=$(grep -m1 -E "$rme" $W/raw/dmesg.txt | sed -nE 's/^\[ *([0-9]+\.[0-9][0-9])[0-9]*\][^:]*: */\1 s: /p')
  if [ -n "$rml" ] && [ "$IPAWANT" != Y ]; then rmu="$rmu, $rmn (на ${rml%% s:*} с)"
  else rmq="$rmq; $rmn (persist.vendor.data.${rk%%:*}_ko_load=1${rml:+; выгружен в $rml})"; fi
done
[ -n "$rmu" ] && ok "мобильные данные" "${rmu#, } выгружены службой netmgrd при загрузке: так и бывает на прошивках со своим vendor (Evolution X и др.), данные идут без них"
[ -n "$rmq" ] && warn "мобильные данные" "не загружены, хотя vendor их ждёт: ${rmq#; }"
# gsm.sim.state has one state per slot (LOADED,ABSENT); NOT_READY is no
# READY, a locked card is one the modem sees. Every slot ABSENT (SIMABS) is
# no error by itself: it is decided in 20a, after the QRTR and QMI checks
# (a card the modem saw once, a card error, a QRTR limit or a missing UIM
# service: ОШИБКА; else no card is inserted). SIMP: the radio log has a card
# PRESENT.
sims=$(getprop gsm.sim.state)
SIMABS=; [ -n "$sims" ] && [ -z "$(printf '%s,' "$sims" | sed 's/ABSENT,//g')" ] && SIMABS=1
SIMP=; grep -q 'CARDSTATE_PRESENT' $TMPD/radio.txt 2>/dev/null && SIMP=1
# when the SIM became usable: the first active subscription in the system
# log (system_server's "Smart5gService: active subs changed, was: [], now:
# [<id>]"), in s since boot: from the monotonic main/system log, else from
# logcat's wall clock against the boot time (BOOT, section 9). A SIM that is
# in the phone at boot is active within about a minute.
SIMA=$(awk '/active subs changed, was: \[\], now: \[[0-9]/ { if ($1 ~ /^[0-9]+\.[0-9]+$/) printf "%d", $1; exit }' $TMPD/mainsys.txt)
if [ -z "$SIMA" ]; then
  sl=$(grep -m1 -E 'active subs changed, was: \[\], now: \[[0-9]' $W/raw/logcat.txt | awk '{ print $1, $2 }')
  [ -n "$sl" ] && SIMA=$(awk -v t="$sl" -v b="$(date -d @$BOOT '+%Y %m %d %H %M %S' 2>/dev/null)" '
    function doy(y, m, d,   i, c) { split("31 28 31 30 31 30 31 31 30 31 30 31", ml, " "); if (y % 4 == 0 && (y % 100 != 0 || y % 400 == 0)) ml[2] = 29
                                    c = 0; for (i = 1; i < m; i++) c += ml[i]; return c + d }
    BEGIN { if (split(b, B, " ") < 6 || split(t, T, "[- :]") < 5) exit
            bs = doy(B[1], B[2] + 0, B[3]) * 86400 + B[4] * 3600 + B[5] * 60 + B[6]
            ts = doy(B[1], T[1] + 0, T[2]) * 86400 + T[3] * 3600 + T[4] * 60 + T[5]
            if (ts < bs - 86400) ts += doy(B[1], 12, 31) * 86400
            if (ts >= bs) printf "%d", ts - bs }')
fi
# SIMG: a subscription that was active at some time ("was: [<id>...]", also
# its loss "was: [1], now: []"): the card was there, even when the radio log
# no longer has its PRESENT answer
SIMG=$(cat $TMPD/mainsys.txt $W/raw/logcat.txt 2>/dev/null | grep -m1 -E 'active subs changed, was: \[[0-9]')
SIMT="подписка SIM стала активной через ${SIMA:-?} с после включения"
if [ -z "$SIMA" ]; then
  rs0=$(grep -m1 -E '^ *[0-9]+\.[0-9]+ ' $TMPD/radio.txt 2>/dev/null | awk '{ printf "%d", $1 }')
  if [ -n "$SIMABS" ] && grep -qE 'CARDSTATE_(ERROR|RESTRICTED)' $TMPD/radio.txt 2>/dev/null; then SIMT="активной SIM не было (модем видел карту, но не смог её прочитать)"
  elif [ -n "$SIMABS" ] && [ -z "$SIMP$SIMG" ] && [ -n "$rs0" ] && [ "$rs0" -le 60 ] && grep -q '< GET_SIM_STATUS' $TMPD/radio.txt; then SIMT="активной SIM не было (карты модем не видел)"
  elif [ -n "$SIMABS" ] && [ -z "$SIMP$SIMG" ] && [ -n "$rs0" ] && [ "$rs0" -le 60 ]; then SIMT="активной SIM в журналах нет (модем о карте не отвечал)"
  elif [ -n "$SIMABS" ] && [ -z "$SIMP$SIMG" ]; then SIMT="активной SIM в журналах нет (журнал radio начинается с ${rs0:-?} с: была ли карта раньше, не проверено)"
  elif [ -n "$SIMABS" ] && [ -n "$SIMG" ]; then SIMT="подписка SIM была активна, потом пропала (журнал system)"
  elif [ "$LLOG" = 0 ]; then SIMT="когда она стала активной, не проверено (logcat не прочитан)"
  else SIMT="когда она стала активной, в журнале system уже нет"; fi
fi
det "SIM: $SIMT"
# airplane mode (asked only when the SIM is not READY/LOADED)
APM=; case ",$sims," in *,READY,*|*,LOADED,*) ;; *) [ "$(tmo 10 settings get global airplane_mode_on 2>/dev/null)" = 1 ] && { APM=1; det "SIM: включён режим полёта"; };; esac
[ -z "$SIMABS" ] && case ",$sims," in
  *,READY,*|*,LOADED,*)
    if [ -n "$SIMA" ] && [ "$SIMA" -gt 120 ]; then warn SIM "состояние SIM $sims, но SIM стала активной только через $SIMA с после включения (первая активная подписка в журнале system; обычно это около минуты: SIM вставили или включили позже?)"
    else ok SIM "состояние SIM $sims; $SIMT"; fi;;
  *,PIN_REQUIRED,*|*,PUK_REQUIRED,*|*,NETWORK_LOCKED,*|*,PERM_DISABLED,*) warn SIM "состояние SIM $sims: модем видит карту, но она заблокирована (разблокируйте её и запустите снова)";;
  *,CARD_IO_ERROR,*|*,CARD_RESTRICTED,*) fail SIM "состояние SIM $sims: модем видит карту, но не может с ней работать";;
  ,,) fail SIM "нет свойства gsm.sim.state: телефония (com.android.phone) не запустилась";;
  *) if [ -n "$APM" ]; then warn SIM "включён режим полёта: состояние SIM «$sims», SIM не проверена"
     else fail SIM "состояние SIM «$sims»: модем не сообщил, есть ли карта (служба SIM модема не ответила или радио выключено)"; fi;;
esac
det "прошивка модема (baseband): $(getprop gsm.version.baseband)"
grep -E ' E ' $TMPD/radio.txt | sed -E 's/^ *[0-9.]+ +[0-9]+ +[0-9]+ //' | sort | uniq -c | sort -rn | head -20 >> $DET
# wificond logs "Could not read interface state for wlan1" on every SoftAP
# teardown, a normal hotspot OFF too (the HAL removes the interface first):
# only a teardown less than 3 s after wificond created it is a failed start
q=$(awk '
  function sec(t, a) { split(t, a, ":"); return a[1] * 3600 + a[2] * 60 + a[3] }
  function ifn(s, k) { sub(".*" k, "", s); sub(/[^A-Za-z0-9_.-].*/, "", s); return s }
  / wificond: createApInterface: .*iface_name / { c[ifn($0, "iface_name ")] = sec($2); next }
  / wificond: Could not read interface state for / {
    s = ifn($0, "interface state for "); if (!(s in c)) next
    d = sec($2) - c[s]; if (d < 0) d += 86400
    if (d < 3) n++
    delete c[s]
  }
  END { print n + 0 }' $W/raw/logcat.txt)
# HSF: a hotspot FAIL is reported already (the history below then only goes
# to the details)
HSF=; HSOK=
[ "$q" -gt 0 ] && { fail "точка доступа" "wificond удалил интерфейс SoftAP меньше чем через 3 с после создания ($(pl $q "раз" "раза" "раз") в logcat): точка доступа не может запуститься"; HSF=1; }
bt=$(tmo 10 settings get global bluetooth_on 2>/dev/null); det "bluetooth_on=$bt"
# (not /dev/sn*: that matches /dev/snd)
exists '/dev/nq-nci' || exists '/dev/nfc-nci' || exists '/dev/sn1[0-9]0*' || exists '/dev/pn5*' && ok NFC "узел устройства NFC есть" || warn NFC "нет узла устройства NFC (/dev/nq-nci)"
# the NXP NFC driver: commands it rejects, eSE cold resets that fail
NFCE='NxpDrv:.*bad cmd|cold reset denied|failed to send ese cold reset|no cold reset rsp|rsp read err'
c=$(grep -cE "$NFCE" $W/raw/dmesg-nospam.txt)
[ "$c" -gt 0 ] && { warn NFC "в журнале ядра $c ошибок драйвера NFC (отклонённые команды, неудачный холодный сброс eSE; примеры — в подробностях)"; det "--- ошибки драйвера NFC (первые 5 из $c)"; grep -E "$NFCE" $W/raw/dmesg-nospam.txt | head -5 >> $DET; }
uc=$(getprop sys.usb.config); us=$(getprop sys.usb.state); det "usb: config=${uc:--} state=${us:--}"
for p in /sys/class/typec/port*; do [ -e $p ] || continue; pdr=$(rd $p/data_role); ppr=$(rd $p/power_role); det "${p##*/}: данные ${pdr:--}, питание ${ppr:--}"; done
exists '/sys/class/typec/port*' && ok USB "порт Type-C зарегистрирован" || warn USB "нет порта Type-C в /sys/class/typec"
# the charging current the USB PHY passes on from the gadget's vbus votes
# (phy-msm-snps-hs: "Avail curr from USB = <mA>"; votes under 100 mA are
# dropped, as on stock 5.4)
c=$(grep -c 'Avail curr from USB' $W/raw/dmesg-nospam.txt)
det "--- «Avail curr from USB» в журнале ядра (строк: $c, последние 5)"; grep 'Avail curr from USB' $W/raw/dmesg-nospam.txt | tail -5 >> $DET
# the USB Ethernet adapters' modules (the kernel ships 8)
ue=
for m in usbnet mii r8152 r8153_ecm asix ax88179_178a cdc_ether cdc_ncm; do
  if grep -q "^$m " $W/raw/modules.txt; then ue="$ue $m=загружен"
  elif [ -d /sys/module/$m ]; then ue="$ue $m=встроен"
  else ue="$ue $m=нет"; fi
done
det "модули USB Ethernet (/proc/modules):$ue"

########################################################################
sec "20a. Модем и SIM: хронология, службы, rmtfs, QMI"
# the radio log has seconds since boot (see above); sim-timeline.txt has the details
r0=$(grep -m1 -E '^ *[0-9]+\.[0-9]+ ' $TMPD/radio.txt | awk '{ printf "%d", $1 }')
cs=$(grep -m1 -E '< GET_SIM_STATUS' $TMPD/radio.txt)
cs_t=$(printf '%s\n' "$cs" | awk 'NF { printf "%d", $1 }'); cs_s=$(printf '%s\n' "$cs" | grep -oE 'CARDSTATE_[A-Z]+' | head -1)
pr_t=$(grep -m1 -E 'CARDSTATE_PRESENT' $TMPD/radio.txt | awk '{ printf "%d", $1 }')
PRS="карты PRESENT не было"; [ -n "$pr_t" ] && PRS="первая карта PRESENT — на $pr_t с"
det "журнал radio — с ${r0:-?} с; первый ответ о статусе SIM — на ${cs_t:-?} с (${cs_s:-нет}); $PRS"
if [ -z "$r0" ]; then
  det "нет журнала radio с метками времени: время появления SIM не проверено"
elif [ "$r0" -gt 60 ]; then
  det "журнал radio начинается через $r0 с после включения (буфер переполнился или очищен): время появления SIM не проверено; запустите проверку сразу после включения"
elif [ -n "$SIMABS" ]; then
  # (no card now: judged at the end of this section)
  [ -n "$pr_t" ] && det "SIM: карта PRESENT была на $pr_t с после включения (первый ответ о статусе: ${cs_s:-?} на ${cs_t:-?} с)"
elif [ -n "$cs_t" ] && [ -n "$pr_t" ] && [ "$cs_s" != CARDSTATE_PRESENT ] && [ $((pr_t - cs_t)) -gt 20 ]; then
  warn SIM "SIM определилась поздно: карта $cs_s на $cs_t с после включения, PRESENT только на $pr_t с"
elif [ "$cs_s" = CARDSTATE_PRESENT ]; then
  ok SIM "карта PRESENT с первого ответа о статусе на $cs_t с после включения"
elif [ -n "$cs_t" ] && [ -n "$pr_t" ]; then
  # dual SIM: the first answer can be the empty slot
  ok SIM "карта PRESENT на $pr_t с после включения, в пределах 20 с от первого ответа о статусе ($cs_s на $cs_t с)"
fi
grep -iE '< (DEVICE_IMEI|DEVICE_IDENTITY|GET_IMEI)' $TMPD/radio.txt | grep -qi error && warn "модем" "модем ответил на запрос IMEI ошибкой"
[ -z "$(getprop gsm.version.baseband | tr -d ', ')" ] && warn "модем" "нет версии прошивки модема: qcrild не смог опросить модем"
# modem-side daemons: running, and not restarted since their first start
for s in vendor.qrtr-ns vendor.pd_mapper vendor.rmt_storage vendor.tftp_server vendor.qcrild vendor.qcrild2; do
  st=$(getprop init.svc.$s); [ -z "$st" ] && continue
  f0=$(ns2s $(getprop ro.boottime.$s)); pid=$(getprop init.svc_debug_pid.$s); ps=$(pstart $pid)
  det "$s: $st, первый запуск на ${f0:-?} с, pid ${pid:--} с ${ps:--} с"
  if [ "$st" != running ]; then fail "модем" "$s в состоянии «$st»"
  elif [ -n "$f0" ] && [ -n "$ps" ] && [ $((ps - f0)) -gt 10 ]; then warn "модем" "$s перезапускался: первый запуск на $f0 с, нынешний процесс — с $ps с"; fi
done
# rmt_storage serves the modem's file system through the UIO named rmtfs
rmtfs=
for u in /sys/class/uio/uio*; do
  [ -e "$u" ] || continue
  un=$(rd $u/name); det "${u##*/}: $un addr $(rd $u/maps/map0/addr) size $(rd $u/maps/map0/size)"
  [ "$un" = rmtfs ] && rmtfs=${u##*/}
done
if [ -n "$(getprop init.svc.vendor.rmt_storage)" ]; then
  if [ -z "$rmtfs" ]; then
    fail "модем" "нет устройства UIO с именем rmtfs: rmt_storage не может обслуживать файловую систему модема (msm_sharedmem, qcom,sharedmem-uio)"
  else
    ok "модем" "UIO $rmtfs — это rmtfs"
    p=$(getprop init.svc_debug_pid.vendor.rmt_storage)
    pm=; [ -n "$p" ] && pm=$(cat /proc/$p/maps 2>/dev/null)
    [ -n "$pm" ] && { echo "$pm" | grep -q "/dev/$rmtfs" || warn "модем" "rmt_storage (pid $p) не отобразил /dev/$rmtfs"; }
  fi
fi
# QMI services: qrtr-lookup if the ROM has it, else the kernel name-server log
# (reading an ipc_logging log moves the kernel's read pointer: it is read once
# here, and a second run sees only newer lines)
QLU=$(command -v qrtr-lookup || ls /vendor/bin/qrtr-lookup 2>/dev/null)
QNS=/sys/kernel/debug/ipc_logging/qrtr_ns/log
# QTI's qrtr-lookup writes its table to /data/vendor/qrtr/qrtr-lookup.txt
# (stock's init.qcom.rc makes that folder), not to stdout; without the folder
# (Evolution X) it only prints "open(): No such file or directory". A table
# counts only with its header (columns: service version instance node port;
# node 0 = the modem). QSRC=lookup when one was read.
QLUF=/data/vendor/qrtr/qrtr-lookup.txt
QSRC=
if [ -n "$QLU" ]; then
  tmo 5 $QLU > $W/raw/qrtr-lookup.txt 2>&1
  if grep -q 'Service Version Instance' $W/raw/qrtr-lookup.txt; then QSRC=lookup
  elif [ -d /data/vendor/qrtr ] && grep -q 'Service Version Instance' $QLUF 2>/dev/null; then cat $QLUF > $W/raw/qrtr-lookup.txt; QSRC=lookup
  elif [ -d /data/vendor/qrtr ]; then det "qrtr-lookup не дал списка служб ($(head -1 $W/raw/qrtr-lookup.txt | cut -c1-80)), и в $QLUF его нет: используется журнал сервера имён ядра"
  else det "qrtr-lookup не дал списка служб ($(head -1 $W/raw/qrtr-lookup.txt | cut -c1-80)): программа QTI пишет $QLUF, а в прошивке нет /data/vendor/qrtr; используется журнал сервера имён ядра"; fi
fi
# the kernel name-server log, always (sim-timeline.txt uses it as well)
[ -r $QNS ] && timeout 5 cat $QNS > $TMPD/qrtr_ns.txt 2>/dev/null
# (qn0f: its first line, in s since boot. The log is a ring of 4 pages
# (32 in port kernels from 0.20) that the NEW_LOOKUP lines fill, and a read
# moves its start (a second run sees only newer lines): a UIM service (0xb)
# missing from it means something only when the log starts before the
# modem came up, MUP: the last "remote processor <modem> is now up" of the
# kernel log (also the one saved early or followed by prep in this boot),
# and the modem's other services (node 0) registered after that are in it
# (QNSMOD). Only then is a missing
# UIM an error (QUIMNO); else the UIM service is "не проверена". UIMST: the
# verdict for the summary)
qn0f=$(sed -nE '1s/^\[ *([0-9]+\.[0-9]+).*/\1/p' $TMPD/qrtr_ns.txt 2>/dev/null | awk '{ printf "%.2f", $1 }')
MUP=$(grep -hE 'remote processor [^ ]*(mss|modem)[^ ]* is now up' $W/raw/dmesg-early.txt $W/raw/dmesg.txt $KMSG 2>/dev/null | sed -nE 's/^\[ *([0-9]+\.[0-9]+)\].*/\1/p' | sort -n | tail -n 1 | awk '{ printf "%.2f", $1 }')
QNSCOV=; QNSMOD=0; QUIMNO=; UIMST=
[ -n "$qn0f" ] && [ -n "$MUP" ] && awk -v a="$qn0f" -v b="$MUP" 'BEGIN { exit !(a + 0 < b + 0) }' && QNSCOV=1
[ -n "$QNSCOV" ] && QNSMOD=$(awk -v m="$MUP" '/server_add: \[0x[0-9a-f]+:0x[0-9a-f]+\]@\[0x0:/ { t = $0; sub(/^\[ */, "", t); sub(/[^0-9.].*/, "", t); if (t + 0 >= m + 0) n++ } END { print n + 0 }' $TMPD/qrtr_ns.txt)
[ -n "$QNSCOV" ] && [ "$QNSMOD" -gt 0 ] && ! grep -qE 'server_add: \[0xb:' $TMPD/qrtr_ns.txt && QUIMNO=1
if [ -n "$QNSCOV" ]; then QNSWHY="журнал сервера имён ядра начинается на $qn0f с, раньше включения модема ($MUP с), но ни одной службы модема (узел 0) после этого в нём нет"
elif [ -n "$MUP" ]; then qnp=4; [ -n "$PORT" ] && [ -n "$KBUILD" ] && [ "$KBUILD" -ge 20 ] 2>/dev/null && qnp=32
  QNSWHY="журнал сервера имён ядра начинается на ${qn0f:-?} с, а модем включился на $MUP с: ранние записи журнал уже вытеснил (в нём $qnp страницы, и их заполняют строки NEW_LOOKUP) или их прочитал прошлый запуск"
else QNSWHY="журнал сервера имён ядра начинается на ${qn0f:-?} с, а когда включился модем, по журналу ядра не видно (строки «is now up» в нём уже нет)"; fi
if [ "$QSRC" = lookup ]; then
  if grep -qE '^ *11 +[0-9]+ +[0-9]+ +0 ' $W/raw/qrtr-lookup.txt; then ok "модем" "служба QMI UIM модема (11) зарегистрирована (qrtr-lookup)"; UIMST="зарегистрирована (qrtr-lookup)"
  else fail "модем" "в таблице qrtr-lookup нет службы QMI UIM (11) на узле 0: служба UIM модема не поднялась"; UIMST="НЕ зарегистрирована (qrtr-lookup)"; fi
elif grep -qE 'server_add: \[0xb:' $TMPD/qrtr_ns.txt 2>/dev/null; then ok "модем" "служба QMI UIM модема (0xb) зарегистрирована (журнал сервера имён ядра)"; UIMST="зарегистрирована (журнал сервера имён ядра)"
elif printf '%s' "$sims" | grep -qE 'LOADED|READY|PIN_REQUIRED|PUK_REQUIRED|NETWORK_LOCKED|PERM_DISABLED'; then
  ok "модем" "UIM отвечает: состояние SIM $sims (таблицы qrtr-lookup нет; UIM 0xb в оставшейся части журнала сервера имён нет)"; UIMST="отвечает (состояние SIM $sims)"
elif grep -q 'CARDSTATE_PRESENT' $TMPD/radio.txt 2>/dev/null; then ok "модем" "UIM отвечает: в журнале radio есть карта PRESENT (таблицы qrtr-lookup нет)"; UIMST="отвечает (в журнале radio есть карта PRESENT)"
elif [ ! -r $QNS ]; then
  # (Evolution X: no /data/vendor/qrtr for qrtr-lookup, and debugfs unmounted)
  if [ -z "$DBGFS" ]; then det "список служб QMI не проверен: таблицы qrtr-lookup нет, а журнал сервера имён ядра не прочитан — debugfs не смонтирован (для проверки SIM запустите с TAOYAO_DEBUGFS=1), состояние SIM «$sims»"
  else det "список служб QMI не проверен: таблицы qrtr-lookup нет, а журнала сервера имён в ядре нет ($QNS), состояние SIM «$sims»"; fi
elif [ ! -s $TMPD/qrtr_ns.txt ]; then
  det "список служб QMI не проверен: таблицы qrtr-lookup нет, а журнал сервера имён ядра пуст (его прочитал прошлый запуск?), состояние SIM «$sims»"
elif [ -n "$QUIMNO" ]; then
  fail "модем" "служба QMI UIM модема (0xb) не зарегистрировалась: журнал сервера имён ядра начинается на $qn0f с, раньше включения модема ($MUP с), другие службы модема в нём есть ($QNSMOD), а UIM — нет"; UIMST="НЕ зарегистрировалась (журнал сервера имён ядра)"
else
  det "служба SIM модема (QMI UIM, 0xb) не проверена: таблицы qrtr-lookup нет, а по журналу сервера имён ядра судить нельзя — $QNSWHY; состояние SIM «$sims»"
fi
[ -z "$UIMST" ] && { if [ -s $TMPD/qrtr_ns.txt ]; then UIMST="не проверена ($QNSWHY)"; elif [ -z "$DBGFS" ]; then UIMST="не проверена (нет таблицы qrtr-lookup, debugfs не смонтирован)"; else UIMST="не проверена (нет таблицы qrtr-lookup и журнала сервера имён ядра)"; fi; }
# the QRTR name server (net/qrtr/ns.c) drops a NEW_LOOKUP or NEW_SERVER over its
# limits without an answer: the QMI client never hears of its service, and
# libqmi_cci logs "No RX for lookup" when it gives up waiting
ql=$( { cat $W/raw/dmesg.txt; [ -f $KMSG ] && kmask < $KMSG; } | grep -E 'exceeds max lookup limit|exceeds max server limit|exceed max node limit' | sort -u)
k0=$(head -1 $W/raw/dmesg.txt | sed -nE 's/^\[ *([0-9]+)\..*/\1/p')
if [ -n "$ql" ]; then
  fail "модем" "qrtr: достигнут предел сервера имён (сообщений: $(printf '%s\n' "$ql" | wc -l)): клиенты QMI могут не найти свои службы (SIM, SMS, данные)"
  printf '%s\n' "$ql" | head -5 >> $DET
else
  if [ -n "$k0" ] && [ "$k0" -lt 30 ]; then kok "модем" "с момента включения пределы сервера имён QRTR не достигались"
  else det "журнал ядра начинается с ${k0:-?} с: пределы сервера имён QRTR проверены только с этого места (запустите проверку сразу после включения или после prep)"; fi
fi
qw=$( { cat $W/raw/dmesg.txt; [ -f $KMSG ] && kmask < $KMSG; } | grep -E 'qrtr_ns_worker\(\): failed while handling packet' | sort -u)
[ -n "$qw" ] && { warn "модем" "qrtr: сервер имён не смог обработать $(printf '%s\n' "$qw" | wc -l) пакетов"; printf '%s\n' "$qw" | head -5 >> $DET; }
qn=$(cat $TMPD/mainsys.txt $TMPD/radio.txt 2>/dev/null | grep -c 'No RX for lookup')
[ "$qn" -gt 0 ] && { warn "модем" "QMI: поисков служб без ответа — $qn («No RX for lookup» в logcat): клиент ждал службу, которая так и не появилась"; cat $TMPD/mainsys.txt $TMPD/radio.txt | grep 'No RX for lookup' | head -5 >> $DET; }
# every slot ABSENT (section 20): in this order, a card error in the radio
# log, a card the modem saw (PRESENT, an active subscription, also one the
# system log saw go away) and lost, a QRTR limit or a missing UIM service
# (where it can be checked: qrtr-lookup's table, "No RX for lookup 11", the
# kernel's name-server log when it starts at boot; the old SIM bug of this
# port looked like ABSENT,ABSENT): ОШИБКА; else the modem sees no card:
# ВНИМАНИЕ, which names what could not be checked
if [ -n "$SIMABS" ]; then
  slt="оба слота пусты"; case "$sims" in *,*) ;; *) slt="слот пуст";; esac
  er=$(grep -m1 -E 'CARDSTATE_(ERROR|RESTRICTED)' $TMPD/radio.txt)
  er_s=$(printf '%s\n' "$er" | grep -oE 'CARDSTATE_(ERROR|RESTRICTED)' | head -1); er_t=$(printf '%s\n' "$er" | awk 'NF { printf "%d", $1 }')
  # (per slot: PRESENT in a card status answer, then ABSENT)
  lost=$(awk '/< GET_SIM_STATUS/ && match($0, /CARDSTATE_[A-Z]+/) { s = substr($0, RSTART + 10, RLENGTH - 10); ph = "?"
      if (match($0, /\[PHONE[0-9]\]/)) ph = substr($0, RSTART + 6, 1) + 1
      if (s == "PRESENT") { seen[ph] = 1; delete gone[ph] } else if (s == "ABSENT" && (ph in seen)) gone[ph] = int($1) }
    END { for (p in gone) printf "%sслот %s на %d с", (n++ ? ", " : ""), p, gone[p] }' $TMPD/radio.txt)
  quim=
  if [ "$QSRC" = lookup ] && ! grep -qE '^ *11 +[0-9]+ +[0-9]+ +0 ' $W/raw/qrtr-lookup.txt; then quim="служба SIM модема (QMI UIM, 11) не зарегистрирована (qrtr-lookup)"
  elif cat $TMPD/mainsys.txt $TMPD/radio.txt 2>/dev/null | grep -qE 'No RX for lookup (11|0xb|0x0b)([^0-9a-fx]|$)'; then quim="служба SIM модема (QMI UIM) так и не нашлась («No RX for lookup 11» в logcat)"
  elif [ "$QSRC" != lookup ] && [ -n "$QUIMNO" ]; then quim="служба SIM модема (QMI UIM, 0xb) не зарегистрировалась (её нет в журнале сервера имён ядра, а он начинается на $qn0f с, раньше включения модема на $MUP с)"; fi
  # (uimok: the UIM service is seen, by qrtr-lookup or in the name-server log)
  uimok=; if [ "$QSRC" = lookup ]; then grep -qE '^ *11 +[0-9]+ +[0-9]+ +0 ' $W/raw/qrtr-lookup.txt && uimok=1
  else grep -qE 'server_add: \[0xb:' $TMPD/qrtr_ns.txt 2>/dev/null && uimok=1; fi
  seen=; [ -n "$pr_t" ] && seen="PRESENT на $pr_t с"; [ -n "$SIMA" ] && seen="${seen:+$seen, }подписка активна с $SIMA с"
  [ -z "$SIMA" ] && [ -n "$SIMG" ] && seen="${seen:+$seen, }активная подписка в журнале system"
  if [ -n "$er_s" ]; then fail SIM "модем сообщил о карте ${er_s#CARDSTATE_} (на ${er_t:-?} с после включения), а сейчас $slt («$sims»): карта есть, но не читается (контакты, лоток или сама карта)"
  elif [ -n "$SIMP" ] || [ -n "$SIMA" ] || [ -n "$SIMG" ]; then fail SIM "SIM-карта пропала: модем видел её (${seen:-PRESENT}${lost:+; пропала: $lost}), а сейчас $slt («$sims»)"
  elif [ -n "$ql" ] || [ -n "$quim" ]; then fail SIM "$slt («$sims»), но ${quim:-сервер имён QRTR достигал предела}: модем мог не дойти до службы SIM, и вставленная карта не видна (так выглядела старая ошибка этого порта)"
  else
    # (not a fact that the tray is empty: the modem does not see a card; what
    # could not be checked is named)
    sl2="ни в одном из двух слотов"; case "$sims" in *,*) ;; *) sl2="в слоте";; esac
    unv=; { [ "$RLOG" = 0 ] || [ -z "$cs_t" ] || [ -z "$r0" ] || [ "$r0" -gt 60 ]; } && unv="была ли карта раньше"
    [ -z "$uimok" ] && unv="${unv:+$unv и }дошёл ли модем до службы SIM"
    warn SIM "модем не видит SIM-карту $sl2 («$sims»): если карты нет — так и должно быть; SIM, SMS и мобильный интернет не проверены${unv:+; не проверено, $unv (подробности)}"
    if [ -n "$cs_t" ]; then det "SIM: модем ответил, что карты нет $sl2 (с первого ответа на $cs_t с). Если карта вставлена — это ошибка: запустите проверку ещё раз через 30 минут и пришлите оба архива"
    else det "SIM: модем о карте не отвечал (в журнале radio нет ответа GET_SIM_STATUS), а gsm.sim.state — «$sims». Если карта вставлена — это ошибка: запустите проверку ещё раз через 30 минут и пришлите оба архива"; fi
    [ -n "$r0" ] && [ "$r0" -gt 60 ] && det "SIM: журнал radio начинается только с $r0 с: была ли карта раньше, не проверено"
    { [ -z "$k0" ] || [ "$k0" -ge 30 ]; } && [ -z "$uimok" ] && det "SIM: журнал ядра начинается с ${k0:-?} с: пределы сервера имён QRTR до этого не проверены"
    if [ -z "$uimok" ]; then
      if [ -s $TMPD/qrtr_ns.txt ]; then det "SIM: служба SIM модема (UIM) не проверена: $QNSWHY"
      elif [ -n "$DBGFS" ]; then det "SIM: служба SIM модема (UIM) не проверена: нет таблицы qrtr-lookup и журнала сервера имён ядра"
      else det "SIM: служба SIM модема (UIM) не проверена: нет таблицы qrtr-lookup, а журнал сервера имён ядра не прочитан — debugfs не смонтирован (запустите проверку с TAOYAO_DEBUGFS=1)"; fi
    fi
  fi
fi

########################################################################
sec "20b. Wi-Fi и точка доступа"
cat $W/raw/net-start.txt >> $DET
det "наборы интерфейсов за $WIN с наблюдения (секунды от включения, интерфейсы):"; cat $W/raw/net-samples.txt >> $DET
# SoftAP interfaces created and deleted during the watch (ip monitor; times
# from its Timestamp lines, -1 if there are none). Only link messages count
# ("15: wlan1: <...>"; address messages have no colon after the name). A link
# message for an interface that was there when the watch started is a state
# change, not a creation: turning off a hotspot that was on takes wlan1 down
# and deletes it within milliseconds, which must not count as a failed start.
pre=$(sed -n '1s/^[^ ]* //p' $W/raw/net-samples.txt)
awk -v ap="^($APIF)\$" -v pre="$pre" '
  BEGIN { n = split(pre, p, " "); for (i = 1; i <= n; i++) had[p[i]] = 1 }
  /^Timestamp:/ { split($5, a, ":"); t = a[1] * 3600 + a[2] * 60 + a[3] + $7 / 1000000; ht = 1; next }
  $1 ~ /^[0-9]+:$/ || $1 == "Deleted" {
    del = ($1 == "Deleted"); s = del ? $3 : $2
    if (s !~ /:$/) next
    sub(/:$/, "", s); sub(/@.*/, "", s)
    if (s !~ ap) next
    if (!del) { if (!(s in add) && !(s in had)) { add[s] = t; print "added", s } }
    else if (s in add) {
      d = -1; if (ht) { d = t - add[s]; if (d < 0) d += 86400 }
      printf "deleted %s %.3f\n", s, d; delete add[s]
    }
    else if (s in had) { print "removed", s, "(он был ещё до начала наблюдения)"; delete had[s] }
  }' $W/raw/ipmon.txt > $W/raw/ap-events.txt
cat $W/raw/ap-events.txt >> $DET
quick=$(awk '$1 == "deleted" && $3 >= 0 && $3 < 3 { printf " %s (%.2f с)", $2, $3 }' $W/raw/ap-events.txt)
unk=$(awk '$1 == "deleted" && $3 < 0 { printf " %s", $2 }' $W/raw/ap-events.txt)
# 1 if a SoftAP interface lived 3 s or more, or was still there at the end
kept=$(awk '$1 == "added" { n[$2]++ } $1 == "deleted" { n[$2]--; if ($3 >= 3) k = 1 } END { for (i in n) if (n[i] > 0) k = 1; print k + 0 }' $W/raw/ap-events.txt)
if [ -n "$quick" ] && [ "$kept" = 1 ]; then
  warn "точка доступа" "интерфейс SoftAP удалён сразу после создания:$quick, но другой продержался 3 с или больше (повторная попытка или включение дважды; raw/ap-events.txt)"
elif [ -n "$quick" ]; then
  fail "точка доступа" "интерфейс SoftAP удалён сразу после создания:$quick; точка доступа не может запуститься"; HSF=1
elif [ -n "$unk" ]; then
  warn "точка доступа" "интерфейс SoftAP создан и удалён во время наблюдения, но ip monitor не дал меток времени:$unk (сколько он жил, неизвестно; raw/ipmon.txt, raw/net-samples.txt)"
elif grep -q '^added' $W/raw/ap-events.txt; then
  HSOK=1
  ok "точка доступа" "интерфейс SoftAP поднялся во время наблюдения и не был удалён в течение 3 с: $(awk '$1 == "added" { printf "%s ", $2 }' $W/raw/ap-events.txt)"
elif [ -n "$HS" ] && grep -q '^removed' $W/raw/ap-events.txt; then
  warn "точка доступа" "интерфейс SoftAP уже был поднят в начале наблюдения и удалён во время него: чтобы проверить запуск, включайте точку доступа только после подсказки"
elif [ -n "$HS" ]; then
  warn "точка доступа" "за $WIN с наблюдения интерфейс SoftAP не появился (точку доступа включали?)"
fi
# a hotspot turned on outside the watch: the tethering service and netd keep
# their logs since boot (dumpsys tethering: "adding IpServer for: wlan1",
# then "[wlan1] ERROR ..." when the start fails; dumpsys netd: the failed
# tetherInterfaceAdd). Masked like tether.txt.
dsys tethering | grep -viE "$LDROP" | nmask | grep -E "adding IpServer for: ($APIF)([^0-9]|\$)|\[($APIF)\] ERROR" > $TMPD/tether-hist.txt
dsys netd | grep -viE "$LDROP" | nmask | grep -E "tetherInterfaceAdd\(($APIF)\) -> ServiceSpecificException" > $TMPD/netd-hist.txt
grep -E "\[($APIF)\] ERROR (Error Tethering|start serving fail|Setting IPv4 address .*No such device)" $TMPD/tether-hist.txt > $TMPD/tether-err.txt
the=$(grep -c . $TMPD/tether-err.txt); ths=$(grep -c 'adding IpServer for' $TMPD/tether-hist.txt); tne=$(grep -c . $TMPD/netd-hist.txt)
if [ $((the + tne)) -gt 0 ]; then
  # (the time is the line's first field: the tethering log's ISO time, netd's MM-DD hh:mm:ss)
  tht="служба раздачи записала $the ошибок запуска SoftAP на $ths запусков с момента включения (первая — $(head -1 $TMPD/tether-err.txt | awk '{ print $1 }'): $(head -1 $TMPD/tether-err.txt | sed -E 's/^ *[^ ]+ - //' | cut -c1-120)); netd: неудачных tetherInterfaceAdd — $tne$( [ "$tne" -gt 0 ] && echo " (первый — $(head -1 $TMPD/netd-hist.txt | awk '{ print $1, $2 }'))")"
  if [ -n "$HSF" ]; then det "точка доступа с момента включения: $tht"
  elif [ -n "$HSOK" ]; then warn "точка доступа" "во время наблюдения она поднялась, но раньше: $tht"
  else fail "точка доступа" "$tht; запустите режим hotspot и включите точку доступа во время наблюдения, чтобы в отчёт попал журнал ядра"; HSF=1; fi
  det "--- журнал раздачи и netd с момента включения (интерфейсы SoftAP, первые 30 строк)"; head -30 $TMPD/tether-hist.txt >> $DET; head -10 $TMPD/netd-hist.txt >> $DET
fi
# the WLAN driver refusing to start the SoftAP: "START AP: mode SAP(1) <MHz>",
# then "sap_validate_chan: SAP can't start (<why>)" and "Start bss Failed".
# "no MCC": the AP's channel differs from the station's (wlan0, vdev 0, its
# frequency from send_vdev_start_cmd_tlv), and the firmware does not run two
# channels at once
awk '/send_vdev_start_cmd_tlv: vdev_id 0 freq [0-9]+/ { f = $0; sub(/.*vdev_id 0 freq /, "", f); sub(/[^0-9].*/, "", f); sta = f; next }
  /START AP: mode / { f = $0; sub(/.*START AP: mode [^ ]+ /, "", f); sub(/[^0-9].*/, "", f); ap = f; na++; next }
  /sap_validate_chan: SAP can.t start/ { r = $0; sub(/.*sap_validate_chan: /, "", r); sub(/ *$/, "", r); nr++; why = r; next }
  /Start bss Failed/ { t = $0; sub(/^\[ */, "", t); sub(/\].*/, "", t); if (!nb++) t1 = t; tl = t; k = ap ":" sta; if (!(k in c)) o[++no] = k; c[k]++ }
  END { if (!nb) exit
        s = ""; for (i = 1; i <= no; i++) { split(o[i], a, ":"); s = s (i > 1 ? ", " : "") c[o[i]] " раз с точкой доступа на " (a[1] == "" ? "?" : a[1]) " МГц и подключением Wi-Fi на " (a[2] == "" ? "?" : a[2]) " МГц" }
        printf "%d|%d|%d|%d|%d|%s|%s\n", nb, na, nr, t1, tl, (why == "" ? "-" : why), s }' $W/raw/dmesg-nospam.txt > $TMPD/sap-fail.txt
if [ -s $TMPD/sap-fail.txt ]; then
  IFS='|' read -r sapb sapa sapr sap1 sap2 sapw saps < $TMPD/sap-fail.txt
  fail "точка доступа" "драйвер WLAN отклонил $sapb из $sapa запусков SoftAP («$sapw» $sapr раз, затем «Start bss Failed»; с $sap1 по $sap2 с после включения): $saps"
  det "--- запуски SoftAP, отклонённые драйвером WLAN (первые 12 строк)"
  grep -E 'START AP: mode |sap_validate_chan: SAP can.t start|Start bss Failed' $W/raw/dmesg-nospam.txt | head -12 | cut -c1-200 >> $DET
fi
det "строк ошибок wlan в журнале ядра: $(grep -ciE 'wlan: \[[0-9]+:E:|hdd.*(fail|err)|sap.*(fail|err)' $W/raw/dmesg-nospam.txt)"
# the WLAN driver (qcacld) reads WCNSS_qcom_cfg.ini through the firmware
# loader when Wi-Fi is turned on; the places it and the ROMs use, and whether
# each exists and resolves (a symlink to a missing file does not)
for wi in /vendor/firmware/wlan/qca_cld/WCNSS_qcom_cfg.ini /vendor/firmware/wlan/qca_cld/qca6750/WCNSS_qcom_cfg.ini /vendor/firmware/wlan/qca_cld/wlan/WCNSS_qcom_cfg.ini; do
  if [ -e "$wi" ]; then det "ini WLAN: $(ls -lL "$wi" 2>&1)$([ -L "$wi" ] && echo " (ссылка на $(readlink "$wi"))")"
  elif [ -L "$wi" ]; then det "ini WLAN: $wi — ссылка на $(readlink "$wi"), которая никуда не ведёт"
  else det "ini WLAN: $wi нет"; fi
done
WOFF=
case "$(dsys wifi | grep -m1 '^Wi-Fi is')" in *disabled*) WOFF=1;; esac
grep -q 'wlan0' $W/raw/iplink.txt || WOFF=1
# wlan.ko tries wlan/qca_cld/WCNSS_qcom_cfg.ini, then qca_cld/qca6750/ and
# qca_cld/wlan/, and after a fallback logs "<root ini> cannot be read, using
# <file>". On stock the root ini is a dangling link, so the read and parse
# errors of the files tried before such a line are expected (X); only those
# that no such line follows count (E; "Failed to parse cfg": none could be
# used); U: the fallback lines
awk 'index($0, "cannot be read, using") { for (i = 1; i <= np; i++) print "X " p[i]; np = 0; print "U " $0; next }
     /Failed to parse cfg/ { for (i = 1; i <= np; i++) print "E " p[i]; np = 0; print "E " $0; next }
     /qcom_cfg\.ini/ && tolower($0) ~ /fail|err|unable|invalid|not found|cannot/ { p[++np] = $0 }
     END { for (i = 1; i <= np; i++) print "E " p[i] }' $W/raw/dmesg-nospam.txt > $TMPD/wlan-ini-all.txt
sed -n 's/^E //p' $TMPD/wlan-ini-all.txt > $TMPD/wlan-ini.txt
sed -n 's/^X //p' $TMPD/wlan-ini-all.txt > $TMPD/wlan-ini-exp.txt
nwx=$(grep -c '^X ' $TMPD/wlan-ini-all.txt); nwu=$(grep -c '^U ' $TMPD/wlan-ini-all.txt)
if [ "$nwu" -gt 0 ]; then
  det "запасной ini WLAN ($nwu раз; $nwx строк ошибок файлов, проверенных до него, ожидаемы): $(sed -n 's/^U //p' $TMPD/wlan-ini-all.txt | tail -1 | sed -E 's/^\[ *[0-9.]+\] *//' | cut -c1-200)"
fi
if [ -s $TMPD/wlan-ini.txt ]; then
  det "--- ошибки ini WLAN в журнале ядра (первые 5 из $(grep -c . $TMPD/wlan-ini.txt))"
  head -5 $TMPD/wlan-ini.txt | cut -c1-220 >> $DET
  [ -n "$WOFF" ] && fail Wi-Fi "Wi-Fi выключен, и драйвер WLAN не смог прочитать свой WCNSS_qcom_cfg.ini (строк в журнале ядра: $(grep -c . $TMPD/wlan-ini.txt); какие ini есть — в подробностях)"
elif [ "$nwu" -gt 0 ]; then
  kok Wi-Fi "драйвер WLAN прочитал ini из запасного места: $(sed -n 's/^U //p' $TMPD/wlan-ini-all.txt | tail -1 | sed 's/.*, using //' | cut -c1-100) (основной WCNSS_qcom_cfg.ini не читается — как в стоке)"
fi
# the board data (BDF) and regulatory database (REGDB) icnss2 hands to the
# WLAN firmware: by hardware region (ro.boot.hwc) bd_l9gl.elf (global),
# bd_l9in.elf (India) or bd_l9.elf, and regdb_xiaomi.bin. Without the BDF the
# firmware does not start; without the REGDB it goes on with its own.
det "ro.boot.hwc (регион оборудования): $(getprop ro.boot.hwc)"
for d in /vendor/firmware/wlan/qca_cld /vendor/firmware/wlan/qca_cld/qca6750; do
  if [ -d $d ]; then det "--- ls -l $d"; ls -l $d >> $DET 2>&1; else det "нет $d"; fi
done
FMQ=/vendor/firmware_mnt/image/qca6750
if exists "$FMQ/bd_l9* $FMQ/bdwlan* $FMQ/regdb*"; then det "--- ls -l $FMQ (bd_l9*, bdwlan*, regdb*)"; ls -l $FMQ/bd_l9* $FMQ/bdwlan* $FMQ/regdb* 2>/dev/null >> $DET
else det "в $FMQ нет bd_l9*, bdwlan* и regdb*"; fi
for b in BDF REGDB; do
  c=$(grep -c "Failed to load $b" $W/raw/dmesg-nospam.txt)
  [ "$c" -gt 0 ] || continue
  bl=$(grep -m1 "Failed to load $b" $W/raw/dmesg-nospam.txt | sed -E 's/^\[ *[0-9.]+\] *//' | cut -c1-120)
  if [ $b = BDF ]; then fail Wi-Fi "$c × «Failed to load BDF»: нет данных платы WLAN, прошивка не может запуститься ($bl; файлы — в подробностях)"
  else warn Wi-Fi "$c × «Failed to load REGDB»: прошивка WLAN работает со своими данными о частотах ($bl; файлы — в подробностях)"; fi
done

########################################################################
sec "20c. Раскладка UAPI IPA для ipacm прошивки (ipam.uapi_stock)"
# ipacm talks to the IPA driver (ipam) in the layout of the kernel headers it
# was built with: Evolution X and crDroid build it from LineageOS 5.4 headers
# (ipam's native layout, uapi_stock=N), stock HyperOS ships Xiaomi's own build
# (Xiaomi's 5.4 headers: uapi_stock=Y, which the zip writes into vendor_boot's
# modules.options). The ROM type (IPAWANT, IPAROM) is worked out before
# section 1 (section 18 uses it too).
det "прошивка для драйвера IPA: $IPAROM; ей нужен uapi_stock=$IPAWANT"
IPAP=/sys/module/ipam/parameters/uapi_stock
IPAU="нет (старое ядро)"; [ -d /sys/module/ipam ] || IPAU="ipam не загружен"
if [ ! -d /sys/module/ipam ]; then
  pwarn IPA "модуль ipam не загружен: нет IPA (ускорение точки доступа и раздачи); прошивка: $IPAROM"
elif [ ! -e $IPAP ]; then
  pwarn IPA "у ipam нет параметра uapi_stock: старое ядро 6.12, которое говорит с ipacm только в раскладке Evolution X / crDroid; прошейте свежий zip (прошивка: $IPAROM)"
else
  iu=$(rd $IPAP)
  case "$iu" in Y|y|1) iu=Y;; N|n|0) iu=N;; esac
  det "ipam uapi_stock=$iu"; IPAU=$iu
  case "$IPAWANT:$iu" in
    Y:Y|N:N) pok IPA "uapi_stock=$iu, как нужно этой прошивке ($IPAROM)";;
    Y:N) pfail IPA "uapi_stock=N, а у этой прошивки ipacm от Xiaomi ($IPAROM): ipam понимает её команды IPA в неправильной раскладке, поэтому точка доступа, USB-модем и их ускорение не работают. Прошейте zip ещё раз на этой прошивке (он пишет options ipam uapi_stock=1 в vendor_boot), удалив перед этим файл taoyao-ipa-native (в zip, /tmp, /sdcard), если он есть";;
    N:Y) pfail IPA "uapi_stock=Y, а ipacm этой прошивки собран по заголовкам LineageOS ($IPAROM): ipam переводит его команды как от Xiaomi и портит их, поэтому точка доступа, USB-модем и их ускорение не работают. Удалите taoyao-ipa-stock (в zip, /tmp, /sdcard) и прошейте zip ещё раз на этой прошивке";;
    *) pwarn IPA "uapi_stock=$iu, но тип прошивки не распознан ($IPAROM): нельзя сказать, правильно ли это";;
  esac
fi

########################################################################
sec "21. Ошибки по подсистемам (журнал ядра)"
# The patterns run case-insensitive; toybox grep has no \b, so a word start
# is (^|[^a-z]). Each subsystem leaves out lines known to be harmless (xp):
# the geni probe banners and their default bus votes, the WLAN driver's own
# REGULATORY module and regulatory.db, the firmware loader's direct attempt
# before the sysfs fallback, the remoteproc driver qcom_q6v5_pas (it is not
# audio), the TFA98xx DSP-ready polling, the TFADSP config of streams
# without the TFA module (section 13), the WLAN driver's known noise
# (WLNOISE), FastRPC's minidump CMA line, sdhci in the Bluetooth match; with
# nothing deferred now, every probe deferral (DEFX, section 3)
FWX='Direct firmware load|Falling back to sysfs'
WLNOISE='is_service_enabled_tlv: WMI service|htc_rx_completion_handler: Received initial wake up|CHANNEL_WIDTH ATTR is NULL|power attr and opm attr is null|DBS is not supported by HW|flow pool id: [0-9]+ is inactive|Fcc rules not sent by fw|TX_POWER_LIMIT is not enabled|band: 2 not supported|dp_get_vdev_priv_obj: vdev is null|cfr is disabled|pdev is NULL|txrx_peer NULL|Spatial Reuse disabled|peer is null|Peer object not found|htc_wait_target: Target Ready|htc_setup_target_buffer_assignments|__cds_get_context: Module ID|Cannot malloc 0 bytes @ policy_mgr_init_dbs_hw_mode|max_conc_cxns|wlan_ipa_(setup|cleanup)_iface|in the middle of WPS/EAPOL|Scan not allowed|Invalid MAC addr|dp_peer_map_ast|SWLM feature is disabled|RX refill buffer pool support is disabled|FST params after CMEM|wrong supported band|cdp_ipa_set_uc_tx_partition_base invalid instance|init_deinit_populate_.*(twt|sap_coex).* failed|reg_get_band_from_cur_chan_list|get_usable_channel|No data requested|nl_srv_bcast: send msg to cld80211 fails|failed to update gateway|tdls_set_tdls_offchannelmode|roam_result or idx error|send_action_oui_cmd_tlv|action_oui_send_config|pdev reg component is NULL|error taking pdev ref cnt|null vdev, vdev_id|Processing SYS MC STOP|dp_srng_deinit|bus bandwidth timer running in disconnected|target_if_deinit_dbr_ring|Skipping wake event configuration|wma_vdev_set_cck_param: invalid index|reg_run_11d_state_machine: Invalid vdev|sme_indicate_chan_info_event: vdev not found|STA disconnect failed|is not in Created|Failed to create device link|FW not ready to WOW|hdd_cfr_disconnect: CFR private object is NULL|reg_soc_vars_reset_on_failure: Set country code failed|tgt_reg_chan_list_ext_update_handler: Failed to process master ext channel list'
# lines that ended well, left out in every subsystem (SUBOK): a direct
# firmware load the sysfs fallback then served (as in section 2; not when
# the fallback failed for that file too: ueventd's "firmware: could not
# find firmware for", or an older kernel's "firmware: failed to load"), and
# a probe deferral of a device that is bound to its driver now
awk '/Direct firmware load for [^ ]+ failed/ { s = $0; sub(/.*Direct firmware load for /, "", s); sub(/ failed.*/, "", s); n[s]++; l[s, n[s]] = $0; next }
     /Falling back to sysfs fallback for: / { s = $0; sub(/.*Falling back to sysfs fallback for: /, "", s); sub(/[ \t].*/, "", s); if (n[s] > d[s]) { d[s]++; ok[s, d[s]] = 1 }; next }
     /firmware: failed to load / { s = $0; sub(/.*firmware: failed to load /, "", s); sub(/[ \t(].*/, "", s); bad[s] = 1 }
     /ueventd: firmware: could not find firmware for / { s = $0; sub(/.*could not find firmware for /, "", s); sub(/[ \t].*/, "", s); bad[s] = 1 }
     END { for (k in l) { split(k, x, SUBSEP); if ((k in ok) && !(x[1] in bad)) print l[k] } }' $W/raw/dmesg-nospam.txt > $TMPD/sub-ok.txt
awk 'tolower($0) ~ /deferring probe|probe deferral|deferred probe|eprobe_defer/ { s = $0; sub(/^\[[^]]*\] */, "", s); if (split(s, f, " ") >= 2 && f[2] ~ /^[A-Za-z0-9_.:@,+-]+:$/) { d = f[2]; sub(/:$/, "", d); print d "\t" $0 } }' $W/raw/dmesg-nospam.txt > $TMPD/defer-lines.txt
for dd in $(cut -f1 $TMPD/defer-lines.txt | sort -u | head -50); do
  for db in /sys/bus/*/devices/$dd; do [ -e "$db/driver" ] && { awk -F'\t' -v d="$dd" '$1 == d { print substr($0, length(d) + 2) }' $TMPD/defer-lines.txt >> $TMPD/sub-ok.txt; break; }; done
done
for p in "i2c:i2c[_-]geni.*(err|fail|timeout|NACK)|i2c-msm-geni.*(err|fail|timeout|NACK)|i2c.*(NACK|timeout|timed out|error)" "spi:spi[_-]geni.*(err|fail|timeout)|spi-msm-geni.*(err|fail|timeout)|spi.*(timeout|timed out|error)" "regulator:(^|[^a-z_])regulator[^y].*(fail|error|unable)|Failed to enable|rpmh-regulator.*err" \
         "clock:clk.*(fail|stuck|error)|gdsc.*(fail|stuck|timeout)" "interconnect:icc.*(fail|err)|interconnect.*fail" "pinctrl:pinctrl.*(fail|err)|pin [0-9]+ is not|could not request pin" \
         "ufs/block:ufshcd.*(err|fail|timeout)|blk_update_request: I/O error|I/O error, dev" "filesystem:EXT4-fs error|F2FS-fs.*(error|panic|inconsistent)|erofs.*(err|corrupt)|dm-verity.*(corrupt|fail)|device-mapper.*(error|fail)" \
         "drm/display:\[drm.*ERROR|sde_.*(err|fail)|dsi_.*(err|fail)|msm_drm.*(err|fail)|mdss.*fail" "gpu:kgsl.*(fail|err|fault|hang)|adreno.*(fault|hang|err)" "usb:dwc3.*(err|fail)|usb.*(fail|error -)|ucsi.*(err|fail)|typec.*fail" \
         "wlan:wlan: \[[0-9]+:E:|cnss.*(fail|err)|icnss.*(fail|err)" "bluetooth:Bluetooth: .*(fail|err)|(^|[^a-z])hci[0-9]+:.*(fail|err)|(^|[^a-z])bt[_-][a-z_]*.*(fail|err)|btpower.*(fail|err)" "glink/qmi:glink.*(fail|err)|qmi.*(fail|err)|qrtr.*(fail|err)|pmic_glink.*(fail|err)" \
         "iommu:arm-smmu.*((^|[^a-z])fault|err)|iommu.*((^|[^a-z])fault|fail)|context fault" "audio:q6(afe|asm|adm|core|voice|lsm)[a-z_]*.*(fail|err)|apr.*(fail|err)|afe.*(fail|err)|adm.*(fail|err)|asoc.*error|wcd.*(fail|err)|swr.*(fail|err)|tfa.*(fail|err)|not in powerdown" \
         "camera:CAM_ERR|cam_.*(fail|err)" "power/charger:battery_charger.*(fail|err)|qti_battery.*(fail|err)|bcl.*(fail|err)|charger.*(fail|error)" "thermal:thermal.*(fail|err)|tsens.*(fail|err)" \
         "memory:page allocation failure|Out of memory|lowmemorykiller|oom-kill|(^|[^a-z])ion[ _:].*(fail|err)|dma_heap.*(fail|err)|(^|[^a-z])cma.*(fail|err)" "selinux/init:^\[ *[0-9.]+\] init: .*(failed|Unable|Could not|cannot)|ueventd: .*(failed|Unable)" \
         "input/touch:goodix.*(fail|err)|fts.*(fail|err)|xiaomi_touch.*(fail|err)|input.*(fail|err)" "fingerprint/nfc:goodix_fp.*(fail|err)|nfc.*(fail|err)|nq-nci.*(fail|err)|sn1.*(fail|err)" \
         "remoteproc/ssr:remoteproc.*(fail|err|crash)|subsys.*(fail|err)|(^|[^a-z])pil.*(fail|err)|sysmon.*(fail|err)|(^|[^a-z])pdr[ _:].*(fail|err)|pd-mapper.*(fail|err)|failed to receive [a-z]+ ssr"; do
  name=${p%%:*}; pat=${p#*:}
  # (wlan: not the expected read errors of the ini files tried before a
  # fallback, section 20b)
  src=$W/raw/dmesg-nospam.txt
  [ "$name" = wlan ] && [ -s $TMPD/wlan-ini-exp.txt ] && { grep -vxF -f $TMPD/wlan-ini-exp.txt $src > $TMPD/dmesg-wlan.txt; src=$TMPD/dmesg-wlan.txt; }
  case $name in
    i2c|spi) xp='vote-index not found|Error loading vote values|I2C probed|Bus frequency is set|spi_geni_probe: completed';;
    regulator) xp='regulatory|dummy regulator';;
    gpu|remoteproc/ssr) xp=$FWX;;
    wlan) xp=$WLNOISE;;
    bluetooth) xp='sdhci';;
    audio) xp="qcom_q6v5_pas|tfa98xx_dsp_system_stable|(error|err)=0 |AFE_PARAM_ID_TFADSP_RX_CFG failed|$FWX";;
    memory) xp='fastrpc_device_init: CMA alloc failed';;
    camera) xp='no valid IFE TPG HW|is not started|cam cci err';;
    # (the same lines as on build 15: the display probe deferred once, the
    # ESD line at info level, no hardware fences on yupik; fw_devlink's
    # inferred sync-state link of pmic_glink; the AIDL audio services this
    # ROM's audioserver.rc starts and the ROM does not have)
    drm/display) xp='resources required for display probe not present: rc=-517|\[info\]esd err irq|disabling hwfence|power vote failed, disabling hw-fencing';;
    glink/qmi) xp='pmic_glink.*Failed to create device link';;
    selinux/init) xp="service (vendor\.audio-hal-aidl|vendor\.audio-effect-hal-aidl|vendor\.audio-hal-4-0-msd|audio_proxy_service) not found";;
    *) xp=;;
  esac
  [ -n "$DEFOK" ] && xp="${xp:+$xp|}$DEFX"
  grep -iE -e "$pat" $src > $TMPD/sub-all.txt
  if [ -n "$xp" ]; then grep -viE -e "$xp" $TMPD/sub-all.txt > $TMPD/sub.txt; else cp $TMPD/sub-all.txt $TMPD/sub.txt; fi
  # lines whole groups of which sections 13 and 14 judged already: the AFE
  # error lines of a TFADSP config failure (the 3 lines before it), the
  # probe-time CCI NACK block of a sensor that is not fitted
  : > $TMPD/sub-x.txt
  case $name in
    audio) awk '{ l[NR % 4] = $0 }
           /AFE_PARAM_ID_TFADSP_RX_CFG failed/ { for (i = 1; i <= 3; i++) { x = l[(NR + 4 - i) % 4]; if (x ~ /afe_callback: .*returned error|afe_apr_send_pkt: DSP returned error|afe_spk_prot_prepare: .*failed/) print x } }' $src > $TMPD/sub-x.txt;;
    camera) cat $TMPD/cam-nack.txt > $TMPD/sub-x.txt 2>/dev/null;;
  esac
  [ -s $TMPD/sub-ok.txt ] && cat $TMPD/sub-ok.txt >> $TMPD/sub-x.txt
  [ -s $TMPD/sub-x.txt ] && { grep -vxF -f $TMPD/sub-x.txt $TMPD/sub.txt > $TMPD/sub2.txt; mv -f $TMPD/sub2.txt $TMPD/sub.txt; }
  # remoteproc: "failed to receive <x> ssr <event> event" is fine when the
  # next line of the same remoteproc is "Retrying legacy EVENT_REQ" (the
  # other DSP rejects the new request and takes the old one) and no "Failed
  # to send event" follows anywhere
  if [ "$name" = remoteproc/ssr ] && ! grep -q 'Failed to send event' $src; then
    awk 'p != "" { if (index($0, "Retrying legacy EVENT_REQ") && index($0, pd)) print p; p = "" }
         /failed to receive [a-z]+ ssr / { p = $0; pd = $0; sub(/^\[[^]]*\] */, "", pd); sub(/: failed to receive.*/, "", pd) }' $src > $TMPD/ssr-ok.txt
    [ -s $TMPD/ssr-ok.txt ] && { grep -vxF -f $TMPD/ssr-ok.txt $TMPD/sub.txt > $TMPD/sub2.txt; mv -f $TMPD/sub2.txt $TMPD/sub.txt; }
  fi
  c0=$(grep -c . $TMPD/sub-all.txt); c=$(grep -c . $TMPD/sub.txt)
  [ "$c0" -gt 0 ] || continue
  [ "$c" -gt 0 ] && warn "журнал/$name" "строк ошибок: $c"
  det "--- $name: строк ошибок $c (пропущено как ожидаемые: $((c0 - c)))"
  sed -E 's/^\[ *[0-9.]+\] *//; s/0x[0-9a-fA-F]+/0x#/g; s/[0-9]+/#/g' $TMPD/sub.txt | sort | uniq -c | sort -rn | head -12 >> $DET
done

########################################################################
sec "22. cgroups и профили задач прошивки"
: > $W/raw/cg-missing.txt
# the files libprocessgroup loads, in its order (a later definition of an
# attribute replaces an earlier one): system, the one of the API level the
# phone launched with (ro.product.first_api_level), vendor
API=$(getprop ro.product.first_api_level)
CGJ=; TPJ=
for f in /system/etc/cgroups.json ${API:+/system/etc/task_profiles/cgroups_$API.json} /vendor/etc/cgroups.json; do [ -f $f ] && CGJ="${CGJ:+$CGJ }$f"; done
for f in /system/etc/task_profiles.json ${API:+/system/etc/task_profiles/task_profiles_$API.json} /vendor/etc/task_profiles.json; do [ -f $f ] && TPJ="${TPJ:+$TPJ }$f"; done
det "cgroups.json: ${CGJ:-нет}"; det "task_profiles: ${TPJ:-нет} (ro.product.first_api_level ${API:--})"
o=; for f in /system/etc/task_profiles/*.json /system/etc/task_profiles_*.json /system_ext/etc/task_profiles*.json; do
  [ -f "$f" ] || continue
  case " $CGJ $TPJ " in *" $f "*) ;; *) o="$o ${f##*/}";; esac
done
[ -n "$o" ] && det "не загружаются libprocessgroup (другие уровни API или файлы, которые AOSP не читает):$o"
# jobj <file>: the JSON with one object per line (newlines removed, a line
# break at every brace), so that the keys of an object are on one line
# however the file is laid out; JV: jv(line, key), the value of a key there
jobj() { tr -d '\r\n' < "$1" | tr '{}' '\n\n'; }
JV='function jv(s, k,   p) { p = index(s, "\"" k "\""); if (!p) return ""; s = substr(s, p + length(k) + 2); sub(/^[ \t]*:[ \t]*/, "", s)
  if (substr(s, 1, 1) == "\"") { s = substr(s, 2); sub(/".*/, "", s); return s }
  sub(/[ \t,].*/, "", s); return s }'
# cgroups.json: "C <controller> <1 if optional>"
for f in $CGJ; do jobj $f | awk "$JV"' { c = jv($0, "Controller"); if (c != "") print "C", c, (jv($0, "Optional") == "true" ? 1 : 0) }'; done > $TMPD/cg-ctl.txt
# task profiles: "A <attribute> <controller> <File> <FileV2|-> <file>" (the
# last definition of each), "U <attribute> <profile>" for each SetAttribute,
# "J <controller> <path> <profile>" for each JoinCgroup
for f in $TPJ; do echo "@FILE $f"; jobj $f; echo; done | awk "$JV"'
  /^@FILE / { src = $2; prof = ""; next }
  { n = jv($0, "Name"); c = jv($0, "Controller"); fl = jv($0, "File"); f2 = jv($0, "FileV2"); pa = jv($0, "Path") }
  index($0, "\"Actions\"") { prof = n; next }
  c != "" && fl != "" { if (!(n in ac)) ord[++na] = n; ac[n] = c; af[n] = fl; a2[n] = (f2 == "" ? "-" : f2); as[n] = src; next }
  c != "" && pa != "" { print "J", c, pa, (prof == "" ? "-" : prof); next }
  n != "" && index($0, "\"Value\"") { print "U", n, (prof == "" ? "-" : prof) }
  END { for (i = 1; i <= na; i++) { n = ord[i]; print "A", n, ac[n], af[n], a2[n], as[n] } }' > $TMPD/tp.txt
# mount point of a controller: cgroup v1 mounts carry the controller name in
# their options; cgdir <controller>: "<dir> 1" for v1, "<v2 root> 2" for
# cgroup v2 (listed in its cgroup.controllers; the v2 freezer is
# cgroup.freeze); "cgroup2" is libprocessgroup's name of the v2 root itself
# (the "Cgroups2" block of cgroups.json, attribute CgroupProcs)
# (the v2 root: /sys/fs/cgroup if it is a cgroup2 mount, else the first one)
CG2=$(awk '$3 == "cgroup2" { if ($2 == "/sys/fs/cgroup") { r = $2; exit } if (r == "") r = $2 } END { if (r != "") print r }' /proc/mounts)
cgmnt() {
  awk -v c="$1" '$3=="cgroup" { n=split($4,o,","); for (i=1;i<=n;i++) if (o[i]==c) print $2 }' /proc/mounts | head -1
}
cgdir() {
  if [ "$1" = cgroup2 ]; then [ -n "$CG2" ] && echo "$CG2 2"; return 0; fi
  cg_m=$(cgmnt $1)
  if [ -n "$cg_m" ]; then echo "$cg_m 1"
  elif [ -n "$CG2" ] && grep -qw "$1" $CG2/cgroup.controllers 2>/dev/null; then echo "$CG2 2"
  elif [ "$1" = freezer ] && [ -n "$CG2" ] && exists "$CG2/*/cgroup.freeze"; then echo "$CG2 2"
  fi
}
# the ROM's files and the kernel's view, for reading by hand (small, no personal data)
mkdir -p $W/raw/cgroups
for f in $CGJ $TPJ; do cp "$f" "$W/raw/cgroups/$(echo "${f#/}" | tr '/' '-')" 2>/dev/null; done
{ echo "== /proc/cgroups"; cat /proc/cgroups; for f in cgroup.controllers cgroup.subtree_control; do [ -n "$CG2" ] && { echo "== $CG2/$f"; cat $CG2/$f; }; done; } > $W/raw/cgroups/state.txt 2>&1
# every controller of cgroups.json and of the task profiles (CGB: problems
# that are the kernel's, as ОШИБКА or ВНИМАНИЕ)
nctl=0; CGB=0
for c in $(awk '$1 == "C" || $1 == "J" { print $2 } $1 == "A" { print $3 }' $TMPD/cg-ctl.txt $TMPD/tp.txt | sort -u); do
  nctl=$((nctl + 1))
  cgd=$(cgdir $c)
  if [ -n "$cgd" ]; then det "контроллер $c — ${cgd% *} (cgroup v${cgd##* })"; continue; fi
  cna=$(awk -v c="$c" '$1 == "A" && $3 == c' $TMPD/tp.txt | grep -c .)
  cnj=$(awk -v c="$c" '$1 == "J" && $2 == c' $TMPD/tp.txt | grep -c .)
  inj=$(awk -v c="$c" '$1 == "C" && $2 == c { print ($3 ? "необязательный" : "в списке") }' $TMPD/cg-ctl.txt | head -1)
  if [ "$cna" = 0 ] && [ "$cnj" = 0 ]; then
    if [ "$inj" = "необязательный" ]; then det "контроллер $c не смонтирован (в cgroups.json необязательный, и ни один профиль задач его не использует)"
    else echo "контроллер $c (cgroups.json) не смонтирован" >> $W/raw/cg-missing.txt; CGB=$((CGB + 1)); fail cgroups "контроллер $c из cgroups.json не смонтирован: в ядре его нет"; fi
    continue
  fi
  cjp=$(awk -v c="$c" '$1 == "J" && $2 == c { print $4 }' $TMPD/tp.txt | sort -u | head -3 | tr '\n' ' ' | sed 's/ $//')
  echo "контроллер $c не смонтирован (атрибутов: $cna, действий JoinCgroup: $cnj${cjp:+, в $cjp}; cgroups.json: ${inj:-нет в списке})" >> $W/raw/cg-missing.txt
  CGB=$((CGB + 1))
  fail cgroups "контроллер $c не смонтирован, а профили задач его используют (атрибутов: $cna, действий JoinCgroup: $cnj${cjp:+, в $cjp}; cgroups.json: ${inj:-нет в списке})"
done
# every attribute (of a mounted controller; the file of a cgroup v2
# controller is FileV2 if the attribute has one): in the controller's root or
# in a child group (some exist only below the root). Not the kernel's:
# a memcg v1 file (no FileV2) while the ROM keeps memory on cgroup v2 (a
# vendor task_profiles.json from a memcg v1 ROM, Xiaomi's stock vendor file:
# no kernel has those files on v2; one no profile sets: details, lmkd runs on
# PSI), and a file in a child group the ROM's init never made (cpuset
# audio-app: userspace creates those groups) that no profile sets
grep '^A ' $TMPD/tp.txt > $TMPD/tp-attr.txt
natt=$(grep -c . $TMPD/tp-attr.txt)
CGV1=; CGV1F=; CGV1D=; CGCS=
while read -r k an ac af a2 asrc; do
  cgd=$(cgdir $ac); [ -z "$cgd" ] && continue
  m=${cgd% *}; f=$af; [ "${cgd##* }" = 2 ] && [ "$a2" != - ] && f=$a2
  if exists "$m/$f" || exists "$m/*/$f" || exists "$m/*/*/$f"; then det "атрибут $an: $ac $f"; continue; fi
  up=$(awk -v n="$an" '$1 == "U" && $2 == n { print $3 }' $TMPD/tp.txt | sort -u)
  nup=$(printf '%s\n' "$up" | grep -c .)
  ups=$(printf '%s\n' "$up" | head -3 | tr '\n' ' ' | sed 's/ $//'); [ "$nup" -gt 3 ] && ups="$ups ..."
  echo "нет атрибута профиля задач $an: $ac $f в $m (задан в $asrc; его ставят профилей: $nup${up:+: $(echo $up)})" >> $W/raw/cg-missing.txt
  if [ "$ac" = memory ] && [ "${cgd##* }" = 2 ] && [ "$a2" = - ]; then
    if [ "$nup" -gt 0 ] || [ ! -e /proc/pressure/memory ]; then
      CGV1="$CGV1, $an"; case " $CGV1F " in *" $asrc "*) ;; *) CGV1F="$CGV1F $asrc";; esac
    else CGV1D="$CGV1D, $an"; fi
    continue
  fi
  case "$f" in */*) if [ "$nup" = 0 ] && [ ! -d "$m/${f%/*}" ]; then CGCS="$CGCS, $an ($m/${f%/*})"; continue; fi;; esac
  CGB=$((CGB + 1))
  if [ "$nup" -gt 0 ]; then fail cgroups "атрибута профиля задач $an ($ac $f) нет в $m: его ставят $(pl $nup "профиль" "профиля" "профилей") ($ups)"
  else warn cgroups "атрибута профиля задач $an ($ac $f) нет в $m (ни один профиль его не ставит; нативный код, например lmkd, может читать его по имени)"; fi
done < $TMPD/tp-attr.txt
[ -n "$CGV1" ] && warn cgroups "профили задач прошивки (${CGV1F# }) рассчитаны на старую схему памяти memcg v1: атрибутов ${CGV1#, } нет, потому что память в этой прошивке на cgroup v2 (таких файлов там нет ни в одном ядре) — это особенность прошивки, не ядра"
[ -n "$CGV1D" ] && det "атрибуты памяти memcg v1 без FileV2, которые не ставит ни один профиль: ${CGV1D#, } — lmkd работает по PSI (/proc/pressure/memory), они ему не нужны"
[ -n "$CGCS" ] && det "подгруппы, которые создаёт сама прошивка (её init), а эта не создала: ${CGCS#, }; ни один профиль их не ставит (звук и камера от этого не зависят)"
cat $W/raw/cg-missing.txt >> $DET
# libprocessgroup's second kill pass on a group it has just removed: harmless
nck=$(cat $W/raw/dmesg-nospam.txt $W/raw/logcat.txt 2>/dev/null | grep -cE 'libprocessgroup: Failed to (write|open) .*/cgroup\.(kill|procs): No such file')
[ "$nck" -gt 0 ] && det "libprocessgroup: «No such file» на cgroup.kill/cgroup.procs — $nck: безвредная гонка (группа процесса уже удалена: перед этим «Removed cgroup»)"
if [ -z "$CGJ$TPJ" ]; then warn cgroups "в /system/etc и /vendor/etc нет cgroups.json и task_profiles.json: ничего не проверено"
elif [ "$CGB" = 0 ]; then
  cgx=; [ -n "$CGV1$CGV1D" ] && cgx=" атрибутов памяти memcg v1"; [ -n "$CGCS" ] && cgx="${cgx:+$cgx и} подгрупп, которые создаёт прошивка"
  ok cgroups "все контроллеры ($nctl) и атрибуты профилей задач ($natt) из cgroups.json и task_profiles.json прошивки на месте${cgx:+, кроме$cgx (подробности)}"
fi

########################################################################
sec "23. Конфигурация ядра (требования Android)"
if [ -e /proc/config.gz ]; then
  zcat /proc/config.gz > $W/raw/config.txt 2>/dev/null
  for o in ANDROID_BINDER_IPC ANDROID_BINDERFS PSI CGROUP_BPF BPF_SYSCALL BPF_JIT BPF_JIT_ALWAYS_ON SECURITY_SELINUX SECCOMP SECCOMP_FILTER \
           FUSE_FS DM_VERITY FS_ENCRYPTION FS_VERITY USERFAULTFD MEMCG CGROUP_SCHED UCLAMP_TASK UCLAMP_TASK_GROUP CPUSETS \
           NETFILTER_XT_MATCH_BPF NET_CLS_BPF NET_ACT_BPF INET_DIAG_DESTROY STATIC_USERMODEHELPER ZRAM ZSMALLOC BLK_INLINE_ENCRYPTION \
           DMABUF_SYSFS_STATS ASHMEM PSTORE_RAM RTC_CLASS SND_SOC IKCONFIG_PROC; do
    grep -qE "^CONFIG_$o=(y|m)" $W/raw/config.txt && det "есть CONFIG_$o" || { case $o in ASHMEM|DMABUF_SYSFS_STATS|STATIC_USERMODEHELPER) warn "конфигурация" "CONFIG_$o не включён";; *) fail "конфигурация" "CONFIG_$o не включён";; esac; }
  done
  ok "конфигурация" "проверена по требованиям Android к ядру"
else
  warn "конфигурация" "нет /proc/config.gz: конфигурация не проверена"
fi

########################################################################
sec "24. Binder"
ls /dev/binderfs 2>/dev/null | tr '\n' ' ' >> $DET; det ""
# the failed-transaction log is a ring of the last 32: entries with ret
# 29189 (BR_DEAD_REPLY: the target died, apps being killed) are normal; ret
# 29201 (BR_FAILED_REPLY) with -28 (ENOSPC) or -12 (ENOMEM) is a full
# binder buffer or no memory
for f in /dev/binderfs/binder_logs/failed_transaction_log /sys/kernel/debug/binder/failed_transaction_log; do
  [ -f $f ] || continue
  c=$(grep -c . $f); bd=$(grep -c 'ret 29189/' $f); bf=$(grep -cE 'ret 29201/-(28|12) ' $f)
  det "== $f (записей: $c из кольца на 32; BR_DEAD_REPLY умершему адресату — $bd, BR_FAILED_REPLY с ENOSPC/ENOMEM — $bf)"; tail -20 $f >> $DET
  [ $((c - bd)) -gt 20 ] && warn binder "записано $((c - bd)) неудачных транзакций binder, не считая ответов умершим адресатам"
  [ "$bf" -gt 0 ] && warn binder "$bf транзакций binder не прошли с ENOSPC или ENOMEM (BR_FAILED_REPLY: буфер binder переполнен или нет памяти)"
  break
done
c=$(grep -cE "binder: .*(failed|out of memory|BR_FAILED_REPLY)" $W/raw/dmesg-nospam.txt); [ "$c" -gt 50 ] && warn binder "в журнале ядра $c строк об ошибках binder"

########################################################################
sec "25. Все sysctl (/proc/sys)"
# one grep per 100 files (values saved, read errors named by grep itself);
# a group that blocks is read again file by file (rdb). Not stable_secret
# (EIO until an IPv6 address secret is set, by design); host and domain
# names, ids and secrets are not kept.
tmo 30 find /proc/sys -type f -perm -400 2>/dev/null | grep -v '/stable_secret$' > $TMPD/sysctl.lst
n=$(grep -c . $TMPD/sysctl.lst)
rdb $TMPD/sysctl.lst 20 > $TMPD/sysctl.raw
{ sed -n 's/^grep: //p' $TMPD/sysctl.raw; grep ': (чтение заняло больше 3 с, пропущено)$' $TMPD/sysctl.raw; } > $W/raw/sysctl-errors.txt
grep -v '^grep: ' $TMPD/sysctl.raw | grep -v ': (чтение заняло больше 3 с, пропущено)$' | grep -viE '^[^:]*(hostname|domainname|uuid|boot_id|secret|random/)' > $W/raw/sysctl.txt
rm -f $TMPD/sysctl.raw
e=$(grep -c . $W/raw/sysctl-errors.txt)
det "прочитано файлов sysctl: $n (значения: raw/sysctl.txt)"; head -40 $W/raw/sysctl-errors.txt >> $DET
[ "$e" -gt 0 ] && warn sysctl "не читаются файлы sysctl: $e из $n (подробности)" || ok sysctl "прочитаны все читаемые файлы sysctl: $n"

########################################################################
# whole-system data: /proc, the /sys trees of the hardware, HAL inventory,
# dropbox, ANR traces, the whole radio log, the service dumps (taken in the
# background since the start); every file masked, time-bounded and cut to a
# size, and listed in raw/collectors.txt
sec "26. Системные данные"
mkdir -p $W/proc $W/sys $W/hal
# kpmask: /proc files with serial numbers, boot config, command line, builder
kpmask() { grep -viE '^serial[[:space:]]*:' | sed -E "$BOOTCFG; $CMDMASK; $KUH" | sed "$MAC"; }
colf proc/memory.txt 1024 cat /proc/meminfo /proc/vmstat /proc/buddyinfo /proc/pagetypeinfo /proc/zoneinfo /proc/swaps '/proc/pressure/*'
colf proc/sched.txt 512 cat /proc/loadavg /proc/stat /proc/schedstat /proc/softirqs /proc/interrupts
colf proc/kernel.txt 512 kpmask /proc/cpuinfo /proc/devices /proc/filesystems /proc/misc /proc/partitions /proc/mounts /proc/bootconfig /proc/cmdline /proc/version /proc/sys/kernel/tainted
colf proc/slabinfo.txt 512 cat /proc/slabinfo
colf proc/net.txt 256 nmask /proc/net/dev /proc/net/snmp /proc/net/netstat /proc/net/sockstat /proc/net/softnet_stat /proc/net/wireless /proc/net/protocols
# /sys: the readable files directly in each folder (attrs, without the reads
# that measure, test, dump or reset: DENYA), 100 files per grep
attrs '' /sys/class/devfreq/*/ > $TMPD/al.txt; colr sys/devfreq.txt 20 256 cat $TMPD/al.txt
attrs '' /sys/devices/system/cpu/cpufreq/policy*/ /sys/devices/system/cpu/cpufreq/policy*/stats/ > $TMPD/al.txt; colr sys/cpufreq.txt 20 256 cat $TMPD/al.txt
attrs '' /sys/class/thermal/thermal_zone*/ /sys/class/thermal/cooling_device*/ > $TMPD/al.txt; colr sys/thermal.txt 20 512 cat $TMPD/al.txt
attrs '' /sys/class/kgsl/kgsl-3d0/ /sys/class/kgsl/kgsl-3d0/devfreq/ > $TMPD/al.txt; colr sys/kgsl.txt 20 128 cat $TMPD/al.txt
attrs '' /sys/class/regulator/*/ > $TMPD/al.txt; colr sys/regulator.txt 20 256 cat $TMPD/al.txt
UFS=/sys/devices/platform/soc/1d84000.ufshc
attrs '' $UFS/ $UFS/health_descriptor/ $UFS/device_descriptor/ $UFS/attributes/ $UFS/flags/ $UFS/power_info/ /sys/fs/f2fs/*/ > $TMPD/al.txt; colr sys/storage.txt 20 256 cat $TMPD/al.txt
attrs '' /sys/devices/soc0/ /sys/bootinfo/ /sys/hwid/ /sys/class/mi_display/*/ /sys/class/touch/*/ > $TMPD/al.txt; colr sys/xiaomi.txt 20 256 propmask $TMPD/al.txt
# qcom-battery: each read is a request to the ADSP that waits up to 1 s for
# the answer: its own file, 30 s in all at most; without the wireless ones
# (no wireless charging on taoyao; wireless_fw_version asks the ADSP for a
# firmware version)
attrs '^wireless|^wls|wlscharge|fw_ver' /sys/class/qcom-battery/ > $TMPD/al.txt; colr sys/qcom-battery.txt 15 128 propmask $TMPD/al.txt 30
attrs '' /sys/class/drm/card0-*/ /sys/class/backlight/*/ > $TMPD/al.txt; colr sys/display.txt 20 256 cat $TMPD/al.txt
attrs '' /sys/class/typec/*/ /sys/class/power_supply/*/ /sys/class/udc/*/ > $TMPD/al.txt; colr sys/usb-power.txt 20 512 cat $TMPD/al.txt
tmo 30 find /sys/module -path '*/parameters/*' -type f -perm -400 2>/dev/null |
  awk -v d="$DENYA" '{ n = $0; sub(/.*\//, "", n); if (tolower(n) ~ d) next; print }' > $TMPD/al.txt; colr sys/module-params.txt 20 512 cat $TMPD/al.txt
tmo 20 find $ASND/ -type f ! -name 'prealloc*' 2>/dev/null > $TMPD/al.txt; colr proc/asound.txt 20 512 cat $TMPD/al.txt
col sys/net-routes.txt 10 128 nmask ip route show table all
col sys/net-stats.txt 10 256 nmask ip -s link
# the HAL inventory
col hal/lshal.txt 30 512 dmask lshal
col hal/service-list.txt 20 256 dmask service list
colf hal/vintf.txt 1024 cat /vendor/etc/vintf/manifest.xml '/vendor/etc/vintf/manifest/*.xml' '/odm/etc/vintf/manifest*.xml' /system/etc/vintf/manifest.xml /system_ext/etc/vintf/manifest.xml /vendor/etc/vintf/compatibility_matrix.xml
# the whole radio log (masked as the radio checks read it; no cell identities)
r0t=$(up); grep -viE 'cellidentity|cellinfo|latitude|longitude' $TMPD/radio.txt > $TMPD/radio.out 2>/dev/null
capto $TMPD/radio.out radio-log.txt 4096; colrec radio-log.txt "$r0t" 0 "$CUT"
# dropbox (system_server crashes, ANRs, watchdogs, older boots' kernel log,
# fsck, recovery) and the newest ANR traces
DBN=3; DBK=2048; [ -n "$DEEP" ] && { DBN=10; DBK=8192; }
d0t=$(up); beat; dropbox_dump /data/system/dropbox $DBN 64 > $TMPD/dropbox.out 2>/dev/null
capto $TMPD/dropbox.out dropbox.txt $DBK; colrec dropbox.txt "$d0t" 0 "$CUT"
a0t=$(up)
for f in $(ls -t /data/anr 2>/dev/null | head -3); do
  [ -f "/data/anr/$f" ] || continue
  echo "=== /data/anr/$f"; tmo 5 head -c 262144 "/data/anr/$f" 2>/dev/null | dmask; echo
done > $TMPD/anr.out
capto $TMPD/anr.out anr.txt 1024; colrec anr.txt "$a0t" 0 "$CUT"
# deep: the debugfs summaries (clocks, regulators, interconnect)
if [ -n "$DEEP" ] && [ -n "$DBGFS" ]; then
  col debug/clk_summary.txt 30 2048 cat cat /sys/kernel/debug/clk/clk_summary
  col debug/regulator_summary.txt 30 1024 cat cat /sys/kernel/debug/regulator/regulator_summary
  col debug/interconnect_summary.txt 30 1024 cat cat /sys/kernel/debug/interconnect/interconnect_summary
fi
# the background service dumps: at most 150 s more
if [ -n "$BGD" ]; then
  i=0; while ! pgone $BGD && [ $i -lt 300 ]; do [ $((i % 10)) = 0 ] && beat; sleep 0.5; i=$((i + 1)); done
  if pgone $BGD; then wait $BGD 2>/dev/null; else killtree $BGD; det "снимки dumpsys в фоне не закончились за 150 с: остановлены"; fi
  BGD=
fi
det "системные данные: файлов $(grep -vc '^#' $COLX), $(awk '!/^#/ { for (i = 1; i < NF; i++) if ($(i + 1) == "байт") n += $i } END { printf "%d", n / 1024 }' $COLX) КБ (raw/collectors.txt)"

########################################################################
# files to read by hand (what taoyao-diag.sh used to collect)
sec "Файлы для разработчика"
det "(файлы для чтения вручную — в корне архива: sim-timeline.txt, fastrpc.txt, audio-state.txt, wifi-hotspot.txt, sensors-list.txt и другие)"
grab services.txt "getprop | grep -E '^\[init\.svc\.' ; echo; getprop | grep -E 'boot_completed|bootreason|boot\.reason|bpf|netd|selinux|vendor\.usb|sys\.usb' | grep -viE '$PRIV'"
grab tombstones.txt 'ls -l /data/tombstones /data/anr 2>/dev/null'
grab tombstones-latest.txt 'for f in $(ls -t /data/tombstones/tombstone_* 2>/dev/null | grep -v "\.pb$" | head -3); do echo "=== $f"; tomb $f 200 | appmask; done'
grab unbound-platform.txt 'for d in /sys/bus/platform/devices/*; do [ -e "$d/driver" ] || echo "${d##*/}"; done'
grab remoteproc.txt 'for p in /sys/class/remoteproc/*; do echo "$(rd $p/name) state=$(rd $p/state) recovery=$(rd $p/recovery) coredump=$(rd $p/coredump) fw=$(rd $p/firmware)"; done; for s in /sys/bus/msm_subsys/devices/*; do [ -e $s ] && echo "${s##*/} $(rd $s/name) $(rd $s/state) crash_count=$(rd $s/crash_count) restart_level=$(rd $s/restart_level) firmware_name=$(rd $s/firmware_name)"; done'
# (by index: closed blobs read fixed zones, so a renumbering shows here)
grab thermal.txt 'echo "# index type temp mode policy"; for z in /sys/class/thermal/thermal_zone*; do [ -e $z ] || continue; echo "${z##*zone} $(rd $z/type) $(rd $z/temp) $(rd $z/mode) $(rd $z/policy)"; done; echo; echo "zones the closed blobs read by index (displayfeature 3, libgf_hal 74, audio HAL 87):"; for i in 3:displayfeature 74:libgf_hal 87:audio_HAL; do z=/sys/class/thermal/thermal_zone${i%%:*}; echo "thermal_zone${i%%:*} (${i#*:}): $(rd $z/type || echo missing) $(rd $z/temp)"; done; echo; for c in /sys/class/thermal/cooling_device*; do echo "$(rd $c/type) $(rd $c/cur_state)/$(rd $c/max_state)"; done'
grab suspend.txt 'echo "mem_sleep: $(rd /sys/power/mem_sleep)"; echo "state: $(rd /sys/power/state)"; timeout 5 grep -ar . /sys/power/suspend_stats 2>/dev/null; rd /sys/kernel/debug/suspend_stats; echo; for f in /sys/kernel/debug/qcom_stats/* /sys/power/system_sleep/stats /sys/power/rpmh_stats/master_stats; do [ -f $f ] && { echo "== $f"; rd $f; }; done'
grab wakeup.txt 'rd /sys/kernel/debug/wakeup_sources | head -1; rd /sys/kernel/debug/wakeup_sources | sed 1d | sort -k7 -n -r'
grab cpu.txt 'echo "online: $(rd /sys/devices/system/cpu/online)"; for p in /sys/devices/system/cpu/cpufreq/policy*; do echo "$p $(rd $p/scaling_governor) cur=$(rd $p/scaling_cur_freq) $(rd $p/scaling_min_freq)-$(rd $p/scaling_max_freq)"; done; for c in /sys/devices/system/cpu/cpu[0-9]*; do for s in $c/cpuidle/state*; do [ -e $s ] && echo "${c##*/} $(rd $s/name) usage=$(rd $s/usage) time=$(rd $s/time)"; done; done; echo "loadavg: $(cat /proc/loadavg)"'
grab memory.txt 'cat /proc/meminfo; echo; cat /proc/swaps; rd /sys/block/zram0/comp_algorithm'
grab input.txt 'cat $W/raw/input.txt; tmo 10 getevent -pl 2>/dev/null | head -400'
grab display.txt 'ls /sys/class/drm; for c in /sys/class/drm/card*-*; do echo "$c status=$(rd $c/status) enabled=$(rd $c/enabled)"; done; for b in /sys/class/backlight/*; do echo "$b $(rd $b/brightness)/$(rd $b/max_brightness)"; done; ls /sys/class/mi_display 2>/dev/null; dsys display | grep -m5 -E "mDisplayInfos|DisplayDeviceInfo|refreshRate" | dmask'
grab sound.txt 'cat $ASND/cards; echo; cat $ASND/pcm; echo; ls /dev/snd'
grab dev.txt 'ls -lZ /dev 2>/dev/null; echo; ls -lZ /dev/input /dev/snd 2>/dev/null'
grab camera.txt 'ls -l /dev/video* /dev/v4l-subdev* /dev/media* 2>/dev/null; for v in /sys/class/video4linux/*; do echo "$v $(rd $v/name)"; done; dsys media.camera | grep -m20 -E "Number of camera devices|Camera ID|Device [0-9]+ is|status" | dmask'
grab misc-hw.txt 'ls -lZ /dev/goodix_fp /dev/nq-nci /dev/ir_spi /dev/aw8622x* /dev/elliptic* /dev/ashmem /dev/binderfs 2>/dev/null; echo; ls /sys/class/leds; echo; dsys vibrator_manager | head -20 | dmask; echo; ls /sys/bootinfo /sys/hwid 2>/dev/null; rd /sys/bootinfo/powerup_reason'
grab net.txt "tmo 10 ip link 2>/dev/null | sed '$MAC'; echo; tmo 10 ip addr 2>/dev/null | grep -E '^[0-9]|inet ' | sed -E '$IPS'; echo; dsys connectivity --short | grep -vE 'SSID|ssid' | nmask | head -40"
grab wireless.txt 'for p in /sys/class/rfkill/*; do echo "$(rd $p/name) $(rd $p/type) state=$(rd $p/state)"; done; dsys wifi | grep -m2 -E "^Wi-Fi is"; dsys bluetooth_manager | grep -m3 -E "^  enabled:|^  state:"; getprop | grep -E "gsm\.(sim\.state|network\.type|operator\.alpha)\]"'
grab usb.txt 'getprop sys.usb.config; getprop sys.usb.state; ls /config/usb_gadget/g1/functions 2>/dev/null; for p in /sys/class/typec/port*; do echo "$p data=$(rd $p/data_role) power=$(rd $p/power_role)"; done'
grab storage.txt 'grep -E " (/|/data|/metadata|/vendor|/system|/product|/odm) " /proc/mounts; tmo 10 df -h /data 2>/dev/null'
grab ion.txt 'ls -l /dev/ion /dev/dma_heap 2>/dev/null; ls /sys/kernel/debug/ion 2>/dev/null; cat /sys/kernel/debug/ion/heaps/* 2>/dev/null | head -100; ls /sys/kernel/ion 2>/dev/null; ls /sys/bus/platform/drivers | grep -iE "ion|heap"; ls /sys/devices/platform/soc | grep -iE "ion|heap"'
grab audio.txt "{ dsys media.audio_flinger | head -400; echo; dsys media.audio_policy | head -300; } | dmask; echo; grep -iE 'audio|ahal|tfa|acdb|pcm|mixer|q6|afe|asm|adm|soundtrigger|elliptic|ultrasound|agm|pal_|msm8974|platform_info|hardware_info|spkr|speaker|wcd|bolero|a2dp|btfm|slim|encoder' $W/raw/logcat.txt | grep -viE 'audioadsprpcd|ActivityManager|rpcmem' | tail -4000"
# camera-log.txt: by the log tag (field 6 of logcat's threadtime lines), and
# the errors of those processes that name synx, ION, DMA-BUF or allocations
CAMLOGAWK='NR == FNR { if ($6 ~ CT) cp[$3] = 1; next }
  $6 ~ CT || (($3 in cp) && ($5 == "E" || $5 == "F") && tolower($0) ~ /synx|ion_|dma.?buf|alloc/)'
CAMTAGS='^(CamX|CHIUSECASE|CamxHAL|CameraService|Camera3-|CameraProvider|CameraDevice|Camera2Client|QCamera|MiCamera|mivi|vendor\.qti\.camera|android\.hardware\.camera)'
grab camera-log.txt 'awk -v CT="$CAMTAGS" "$CAMLOGAWK" $W/raw/logcat.txt $W/raw/logcat.txt | tail -4000 > $TMPD/caml.txt; if [ -s $TMPD/caml.txt ]; then cat $TMPD/caml.txt; else echo "(строк камеры в журнале нет: камеру за это время не открывали, или журнал main уже вытеснен)"; fi'
grab radio.txt "getprop | grep -iE 'gsm\.|ril|radio|baseband|modem|sim|uim|telephony|persist\.vendor\.radio' | grep -viE '$PRIV' | sed -E 's/[0-9]{6,}/N/g'; echo; grep -iE 'uim|sim|icc|card|slot|uicc|qcril|qmi|error|fail|absent|sms|ims|modem|subscription|imsa|ril_' $TMPD/radio.txt | tail -6000"
grab tether.txt "grep -iE 'tether|hostapd|softap|ipserver|ipacm|offload|wificond|hotspot|dnsmasq|bpf' $W/raw/logcat.txt | grep -viE 'ssid|passphrase|psk' | sed -E '$IPS' | tail -3000; echo; dsys tethering | grep -viE 'ssid|passphrase|psk' | nmask | head -600"

# SIM and modem timeline. Times: "uptime" = seconds since boot; the radio and
# main/system logs here use -v monotonic (seconds since boot, not counting
# suspend: equal to uptime until the first suspend); the kernel log and
# ipc_logging count seconds since boot without suspend as well.
# rfirst <label> <ERE> [ERE to leave out]: the first radio line that matches
rfirst() {
  if [ -n "$3" ]; then l=$(grep -iE "$2" $TMPD/radio.txt | grep -viE "$3" | head -1 | cut -c1-230)
  else l=$(grep -m1 -iE "$2" $TMPD/radio.txt | cut -c1-230); fi
  printf '%s: %s\n' "$1" "${l:--}"
}
{
  NOW=$(up)
  echo "с включения сейчас: $NOW с   включён (по часам): $(date -d @$(( $(date +%s) - ${NOW%.*} )) '+%m-%d %H:%M:%S' 2>/dev/null)   снимок: $(date '+%m-%d %H:%M:%S')"
  echo "system_server запущен на $(getprop sys.system_server.start_uptime) мс; состояние SIM сейчас: $(getprop gsm.sim.state); сеть: $(getprop gsm.network.type)"
  echo "SIM: $SIMT${SIMA:+ (журнал system: первая активная подписка)}"
  echo
  echo "== свойства модема"
  getprop | grep -E '^\[(ro\.boot\.(baseband|hwc|hwlevel|hwversion|product\.hardware\.sku|product\.vendor\.sku|radio[a-z0-9._]*|multisim[a-z0-9._]*)|ro\.baseband|gsm\.version\.(baseband|ril-impl)|gsm\.sim\.state|gsm\.network\.type|gsm\.operator\.alpha|persist\.radio\.multisim\.config|persist\.vendor\.radio\.(adb_log_on|multisim[a-z0-9._]*)|ro\.telephony\.default_network|ro\.vendor\.radio[a-z0-9._]*|persist\.radio\.modem_[a-z_]*datetime)\]' | grep -viE "$PRIV"
  echo
  echo "== службы модема: первый запуск (ro.boottime), текущий процесс и его запуск, в секундах от включения"
  for s in $(getprop | sed -nE 's/^\[init\.svc\.([^]]*(qrtr|pd_mapper|pd-mapper|rmt_storage|tftp|per_mgr|per_proxy|qcrild|ril-daemon|ipacm|dataqti|dataadpl|port-bridge|cnss|mdm_helper|ssr_setup|imsqmidaemon|ims_rtp|imsdatadaemon)[^]]*)\].*/\1/p'); do
    pid=$(getprop init.svc_debug_pid.$s)
    printf '%-34s %-10s первый %8s   pid %-6s с %8s\n' "$s" "$(getprop init.svc.$s)" "$(ns2s2 $(getprop ro.boottime.$s))" "${pid:--}" "$(pstart2 $pid)"
  done
  echo "строки init (только пока журнал ядра доходит до начала загрузки):"
  grep -E "init: .*(starting service|Service) '[^']*(qrtr|pd_mapper|rmt_storage|tftp|per_mgr|qcrild|cnss)" $W/raw/dmesg.txt | head -40 > $TMPD/initl.txt
  if [ -s $TMPD/initl.txt ]; then cat $TMPD/initl.txt; else echo "  нет строк (журнал ядра их не сохранил: init пишет туда с ограничением частоты)"; fi
  echo
  echo "== UIO (rmt_storage отображает буфер файловой системы модема через UIO с именем rmtfs)"
  for u in /sys/class/uio/uio*; do
    [ -e "$u" ] || { echo "устройств /sys/class/uio нет"; break; }
    echo "${u##*/}: name=$(rd $u/name) version=$(rd $u/version) dev=$(readlink -f $u 2>/dev/null)"
    for m in $u/maps/map*; do [ -e "$m" ] && echo "  ${m##*/}: name=$(rd $m/name) addr=$(rd $m/addr) size=$(rd $m/size) offset=$(rd $m/offset)"; done
  done
  ls -lZ /dev/uio* 2>&1
  p=$(getprop init.svc_debug_pid.vendor.rmt_storage)
  [ -n "$p" ] && echo "rmt_storage (pid $p) отображает: $(grep -E '/dev/uio' /proc/$p/maps 2>/dev/null | awk '{print $6}' | sort -u | tr '\n' ' ')"
  echo
  echo "== удалённые процессоры и SSR"
  for r in /sys/class/remoteproc/*; do [ -e "$r" ] && echo "${r##*/}: $(rd $r/name) state=$(rd $r/state) recovery=$(rd $r/recovery) coredump=$(rd $r/coredump)"; done
  for s in /sys/bus/msm_subsys/devices/*; do [ -e "$s" ] && echo "${s##*/}: $(rd $s/name) $(rd $s/state) crash_count=$(rd $s/crash_count) restart_level=$(rd $s/restart_level)"; done
  echo
  echo "== службы QRTR (UIM = 0xb/11, NAS 0x3, DMS 0x2, WDS 0x1, VOICE 0x9, WMS 0x5, PBM 0xc, RMTFS 0xe, SSCTL 0x2b, SERVREG_LOC 0x40, SERVREG_NOTIF 0x42; узел 0 — модем)"
  if [ "$QSRC" = lookup ]; then
    cat $W/raw/qrtr-lookup.txt
  elif [ -f $TMPD/qrtr_ns.txt ]; then
    [ -s $W/raw/qrtr-lookup.txt ] && echo "qrtr-lookup: $(head -1 $W/raw/qrtr-lookup.txt | cut -c1-100) (программа QTI пишет $QLUF; в прошивке нет /data/vendor/qrtr)"
    echo "таблицы qrtr-lookup нет; журнал сервера имён ядра (старые записи могли уйти):"
    for id in b 3 2 1 9 5 e 2b 40 42; do
      l=$(grep -m1 -E "server_add: \[0x$id:" $TMPD/qrtr_ns.txt | sed -E 's/^\[ *([0-9]+\.[0-9][0-9][0-9])[0-9]*\/[^]]*\] */\1 /')
      printf '  служба 0x%-3s впервые зарегистрирована: %s\n' "$id" "${l:--}"
    done
    # ns.c logs server_add, and every control packet it receives as cmd:0x<type>
    # (0x3 BYE = a node went down, 0x5 DEL_SERVER); server_del itself logs nothing
    echo "  server_add, DEL_SERVER (cmd:0x5) и BYE узла (cmd:0x3), последние 200:"
    grep -E 'server_add|cmd:0x[35] ' $TMPD/qrtr_ns.txt | sed -E 's/^\[ *([0-9]+\.[0-9][0-9][0-9])[0-9]*\/[^]]*\] */\1 /' | tail -200
    # (the log is 4 pages and wraps within minutes; lookups closed again count too)
    echo "  строк NEW_LOOKUP (cmd:0xa) в оставшейся части журнала: $(grep -c 'cmd:0xa ' $TMPD/qrtr_ns.txt)"
  elif [ -z "$DBGFS" ]; then
    echo "таблицы qrtr-lookup нет; журнал сервера имён ядра не прочитан: debugfs не смонтирован (для проверки запустите с TAOYAO_DEBUGFS=1)"
  else
    echo "таблицы qrtr-lookup нет; журнала сервера имён в ядре нет ($QNS)"
  fi
  echo
  echo "== выводы UIM со стороны APPS (UIM1 gpio109-112, UIM0 gpio113-116; выводы наличия карты 112 и 116)"
  # (only valid lines are read: the TrustZone pins 32-33, 48-51, 56-59 are outside the gpiochip valid mask)
  if [ -z "$DBGFS" ]; then echo "не прочитаны: debugfs не смонтирован (/sys/kernel/debug/gpio)"
  else timeout 5 grep -aE '^ *gpio(109|11[0-6]) *:' /sys/kernel/debug/gpio 2>/dev/null || echo "нет /sys/kernel/debug/gpio"; fi
  echo
  echo "== журнал ядра: модем, rmtfs, QRTR, glink, PDR (первая строка журнала — на $(head -1 $W/raw/dmesg.txt | sed -E 's/^\[ *([0-9.]+)\].*/\1/') с)"
  grep -iE 'msm_sharedmem|qcom_scm_assign_mem|uio|remoteproc|4080000|mss|modem|sysmon|ssctl|qrtr|glink|pdr|smp2p|memshare|subsys|rmtfs|tftp' $W/raw/dmesg-nospam.txt | head -300
  [ -f $KMSG ] && { echo "-- из записи после prep:"; grep -iE 'uio|remoteproc|4080000|mss|modem|sysmon|ssctl|qrtr|pdr|subsys' $KMSG | kmask | tail -200; }
  echo
  echo "== журнал radio: главные события (первое появление; время в секундах от включения)"
  echo "журнал radio начинается с: $(grep -m1 -E '^ *[0-9]' $TMPD/radio.txt | awk '{print $1}') с (если намного позже ~10 с, буфер переполнился или был очищен: запустите проверку сразу после включения)"
  rfirst "qcrild RIL_Init"                          'RIL_Init'
  rfirst "RIL подключён"                            'UNSOL_RIL_CONNECTED'
  rfirst "радио доступно"                           'RADIO_AVAILABLE|RADIO_STATE_CHANGED|radioStateChanged: ?[0-9]' 'mRadioIndication|== NULL'
  rfirst "первый ответ о статусе SIM"               '< GET_SIM_STATUS'
  rfirst "первое уведомление о статусе SIM"         'UNSOL_RESPONSE_SIM_STATUS_CHANGED|simStatusChanged'
  rfirst "первый статус слота"                      '< GET_SLOT_STATUS|SLOT_STATUS_CHANGED'
  rfirst "первая карта PRESENT"                     'CARDSTATE_PRESENT'
  rfirst "первая карта ERROR/RESTRICTED"            'CARDSTATE_(ERROR|RESTRICTED)'
  rfirst "первая SIM LOADED/READY"                  'updateSimState: phoneId=[0-9], state=(LOADED|READY)|SIM_STATE_(LOADED|READY)|STATE_CHANGED (LOADED|READY)|simState=(LOADED|READY)' 'FeatureContainer|imsFeature'
  rfirst "статус карты QCRIL UIM (adb_log_on)"      'qcril_uim|QMI_UIM_|card_error'
  rfirst "ответ на запрос IMEI (значение не пишется)" '< (DEVICE_IMEI|DEVICE_IDENTITY|GET_IMEI)'
  rfirst "ответ о версии модема"                    '< BASEBAND_VERSION'
  rfirst "первая регистрация голоса"                '< VOICE_REGISTRATION_STATE'
  rfirst "первая регистрация данных"                '< DATA_REGISTRATION_STATE'
  rfirst "перезапуск модема по RIL"                 'MODEM_RESTART|MODEM_RESET|modemReset'
  echo
  echo "== изменения состояния карты и SIM (по каждому слоту)"
  awk '{
    t = $1; ph = "PHONE?"
    if (match($0, /\[PHONE[0-9]\]/)) ph = substr($0, RSTART + 1, RLENGTH - 2)
    else if (match($0, /phoneId[=-]? ?[0-9]/)) ph = "PHONE" substr($0, RSTART + RLENGTH - 1, 1)
    if ($0 ~ /< GET_SIM_STATUS/ && match($0, /CARDSTATE_[A-Z]+/)) { v = "карта " substr($0, RSTART + 10, RLENGTH - 10); k = "c" ph }
    else if (match($0, /updateSimState: phoneId=[0-9], state=[A-Z_]+/)) { v = "SIM " substr($0, RSTART + 33, RLENGTH - 33); k = "s" ph }
    else next
    if (last[k] != v) { print t, ph, v; last[k] = v }
  }' $TMPD/radio.txt
  echo
  echo "== службы модема в logcat (main/system)"
  grep -iE 'rmt_storage|RMTS|tftp_server|tftp|pd-mapper|pd_mapper|qrtr|per_mgr|per_proxy|pm-service|ssr_setup|QCCI|qmi_cci|No RX for lookup' $TMPD/mainsys.txt | grep -v 'The property name length for ' | tail -300
  echo
  echo "== SMS и IMS (отправьте SMS перед запуском проверки; номера скрыты)"
  getprop | grep -E '^\[(vendor|persist\.vendor)\.ims' | grep -viE "$PRIV" | sed -E 's/[0-9]{6,}/N/g'
  grep -E 'SEND_SMS|IMS_SEND_SMS|sendSms|SmsDispatcher|ImsSmsDispatcher|SMS_ACK|SMS_ACKNOWLEDGE|errorCode|IMS_REGISTRATION_STATE|ImsRegistration|onImsRegistered|onImsUnregistered|imsReg' $TMPD/radio.txt $TMPD/mainsys.txt 2>/dev/null | sed 's/^[^:]*://' | sort -n | tail -400
  echo
  echo "== журнал radio: события UIM, карты, слота, QMI, подписки, состояния радио"
  grep -iE 'uim|card.?stat|cardstate|icc.?card|sim.?stat|simstate|slot|uicc|subscription|qmi|qcril|RIL_Init|RIL_CONNECTED|RADIO_STATE|RADIO_AVAILABLE|RADIO_POWER|BASEBAND|DEVICE_IMEI|DEVICE_IDENTITY|REGISTRATION_STATE|MODEM_RESTART|MODEM_RESET' $TMPD/radio.txt | tail -3000
} > $W/sim-timeline.txt 2>&1

# FastRPC
{
  echo "== soc:qcom,msm_fastrpc и его банки контекста (qcom,msm-fastrpc-compute-cb)"
  if [ -e $FD ]; then
    drv=$(readlink $FD/driver 2>/dev/null)
    if [ -n "$drv" ]; then echo "soc:qcom,msm_fastrpc driver=${drv##*/}"; else echo "soc:qcom,msm_fastrpc driver=НЕТ (не привязан)"; fi
    echo "узлов compute-cb в devicetree: $(ls -d $FD/of_node/qcom,msm_fastrpc_compute_cb* 2>/dev/null | wc -l)"
  else
    echo "нет платформенного устройства soc:qcom,msm_fastrpc"
  fi
  for d in /sys/bus/platform/devices/*fastrpc*; do
    [ -e "$d" ] || continue
    drv=$(readlink $d/driver 2>/dev/null); grp=$(readlink $d/iommu_group 2>/dev/null)
    echo "${d##*/} driver=${drv##*/} iommu_group=${grp##*/}"
  done
  echo "платформенные драйверы: $(ls /sys/bus/platform/drivers 2>/dev/null | grep -iE 'rpc' | tr '\n' ' ')"
  echo
  echo "== узлы устройств"
  ls -lZ /dev/adsprpc-smd* /dev/fastrpc* 2>&1
  echo
  echo "== /sys/kernel/debug/adsprpc («global» появляется, когда банк контекста прошёл probe)"
  ls /sys/kernel/debug/adsprpc 2>&1 | head -60
  [ -f /sys/kernel/debug/adsprpc/global ] && timeout 3 head -c 16384 /sys/kernel/debug/adsprpc/global
  echo
  echo "== процессы за $WIN с наблюдения (pid в начале и в конце)"
  for n in $RPCD; do
    p0=$(sed -n "s/^$n //p" $W/raw/rpcd-start.txt); p1=$(sed -n "s/^$n //p" $W/raw/rpcd-end.txt)
    st="стабилен"; [ "$p0" != "$p1" ] && st="ИЗМЕНИЛСЯ"; [ -z "$p0$p1" ] && st="не запущен"
    echo "$n: начало [$p0] конец [$p1] $st"
    for p in $p1; do echo "  pid $p состояние $(sed 's/.*) //' /proc/$p/stat 2>/dev/null | cut -d' ' -f1) wchan $(rd /proc/$p/wchan) с $(pstart2 $p) с"; done
  done
  getprop | grep -E '^\[init\.svc\.[^]]*(rpcd|sensors|audiopd|dspservice)'
  echo
  echo "== журнал ядра (adsprpc, PDR; спам только считается)"
  echo "строк спама ($SPAM): $(grep -cE "$SPAM" $W/raw/dmesg.txt)"
  grep -iE 'adsprpc|fastrpc|pdr|audio_pd|sensor_pd|servreg|service.?locator|context bank' $W/raw/dmesg-nospam.txt | tail -300
  echo
  echo "== logcat"
  grep -iE 'apps_dev_init|remote_handle|fastrpc|rpcmem|adsprpc|dspservice|sscrpcd|cdsprpcd|adsprpcd|audioadsprpcd' $W/raw/logcat.txt | tail -400
} > $W/fastrpc.txt 2>&1

# audio: App Type Config, open streams, q6/adm/afe kernel lines
{
  echo "== App Type Config (tinymix); чтение в ядре возвращает нули и на 5.4, и на 6.12 —"
  echo "== это не проверка того, что записал HAL (это проверяется по «App type not available» ниже)"
  if [ -n "$TM" ]; then echo "$APPTYPE" | cut -c1-600; else echo "нет tinymix"; fi
  echo
  echo "== открытые потоки PCM (включите звук во время проверки)"
  for s in $ASND/card*/pcm*/sub*; do
    [ -e "$s/hw_params" ] || continue
    hw=$(rd $s/hw_params)
    [ -z "$hw" ] || [ "$hw" = closed ] && continue
    echo "-- ${s#$ASND/} $(grep -m1 '^id:' ${s%/sub*}/info 2>/dev/null)"
    echo "$hw"; rd $s/status
  done
  echo
  echo "== ядро: q6 / ADM / AFE / ASM / app type / маршрутизация (последние 300)"
  grep -iE 'q6|adm_|afe_|asm_|app type|app_type|msm_pcm|msm-pcm|routing|asoc|apr|btfm|slim_stream|0x400e|enc_cfg|encoder' $W/raw/dmesg-nospam.txt | grep -viE 'tfa98' | tail -300
  echo
  echo "== ядро: усилители (последние 80; подробный журнал TFA98xx — только с tfa98xx_dlkm.trace_level=1, сейчас: $TFAL)"
  grep -iE 'tfa98|aw88' $W/raw/dmesg.txt | tail -80
} > $W/audio-state.txt 2>&1

# Wi-Fi / hotspot: the interfaces over the watch, kernel wlan log, Wi-Fi and
# tethering logcat (SSIDs, passphrases, MAC and IP addresses removed)
{
  cat $W/raw/net-start.txt
  echo
  echo "== /sys/class/net за $WIN с наблюдения (секунды от включения, интерфейсы; строка на каждое изменение)"
  cat $W/raw/net-samples.txt
  echo
  echo "== ip -timestamp monitor link address во время наблюдения"
  tail -400 $W/raw/ipmon.txt
  echo
  echo "== события интерфейсов SoftAP (из ip monitor; deleted <имя> <сколько секунд жил>)"
  cat $W/raw/ap-events.txt
  echo
  cat $W/raw/net-end.txt
  echo
  echo "== журнал ядра: wlan / cnss / icnss / qcacld / cfg80211 (последние 800)"
  grep -iE 'wlan|cnss|icnss|qcacld|hdd|cfg80211|nl80211|wpss|ipa_wdi|softap|hostapd' $W/raw/dmesg-nospam.txt | grep -viE 'ssid' | sed -E "$IPS" | tail -800
  echo
  echo "== logcat: SoftAP, HAL, hostapd, wificond, раздача (последние 1500)"
  grep -iE 'SoftAp|WifiNative|HostapdHal|hostapd|wificond|IpServer|Tethering|createApIface|ApIface|WifiVendorHal|wifi_hal|wlan1|setupInterfaceForSoftAp' $W/raw/logcat.txt | grep -viE 'ssid|passphrase|psk|password' | sed -E "$IPS" | tail -1500
  echo
  echo "== dumpsys wifi: SoftApManager"
  dsys wifi | sed -n '/SoftApManager/,/^$/p' | grep -viE 'ssid|passphrase|psk|password|key' | nmask | head -300
  echo
  echo "== dumpsys wifi: HalDeviceManager (какой запрос создал или удалил интерфейс AP)"
  dsys wifi | sed -n '/HalDeviceManager/,/^$/p' | grep -viE 'ssid|passphrase|psk|password|key' | nmask | head -200
  echo
  echo "== код страны и возможности SoftAP (каналы, которые может выбрать система)"
  tmo 5 cmd wifi get-country-code 2>/dev/null | head -3
  dsys wifi | grep -iE -A30 'SoftApCapability' | grep -viE 'ssid|passphrase|psk|password|key' | nmask | head -80
  echo
  echo "== dumpsys netd: вызовы раздачи"
  dsys netd | grep -iE 'tether|wlan1|ipfwd|networkAddInterface|interfaceSetCfg' | nmask | tail -200
} > $W/wifi-hotspot.txt 2>&1

# sensors: the list the sensor service registered, and the SSC side
{ echo "# dumpsys sensorservice | head -120"; head -120 $SSV; } > $W/sensors.txt
{
  grep -m1 -E 'h/w sensors' $SSV || echo "в dumpsys sensorservice нет строки «h/w sensors»"
  echo
  echo "== список датчиков (имя | производитель | версия | тип)"
  cat $W/raw/sensors.txt
  echo
  echo "== типы"
  sed -n '/^Sensor List:/,/^Fusion States:/p' $SSV | grep -oE 'type: [A-Za-z0-9._]+' | sort | uniq -c
  echo
  echo "== сторона SSC (vendor.sensors запускает sscrpcd, а тот — sensors PD на ADSP через FastRPC)"
  getprop | grep -E '^\[init\.svc\.[^]]*(sensor|ssc)'
  for p in $(pidof sscrpcd 2>/dev/null); do echo "sscrpcd pid $p состояние $(sed 's/.*) //' /proc/$p/stat 2>/dev/null | cut -d' ' -f1) wchan $(rd /proc/$p/wchan) с $(pstart2 $p) с"; done
  echo
  echo "== logcat (датчики, последние 400)"
  grep -iE 'sns_|ssc_|libssc|sscrpcd|sensors-hal|sensors\.ssc|SensorService|ALSProbe|citsensor|sensor_pd|sensorspd' $W/raw/logcat.txt | tail -400
} > $W/sensors-list.txt 2>&1

# the background kernel-log capture of prep ends here (its own process
# group only); one that stopped early is said so
if [ -f $KMSG ]; then
  kp=$(cat $KPID 2>/dev/null)
  if [ -n "$kp" ] && [ -d /proc/$kp ] && tr '\0' ' ' 2>/dev/null < /proc/$kp/cmdline | grep -q 'taoyao-kmsg'; then
    kill -s TERM -- -$kp 2>/dev/null; kill -s TERM $kp 2>/dev/null
    # (grep writes out what it still holds once dmesg is gone)
    sleep 1
  else
    det "запись журнала ядра после prep остановилась раньше времени (последняя строка — на $(tail -n 1 $KMSG | sed -n 's/^\[ *\([0-9]*\)\..*/\1/p') с после включения): kmsg-follow.txt неполный"
  fi
  kmask < $KMSG > $W/kmsg-follow.txt
  rm -f $KMSG $KPID
fi
rm -f $IRQP $PREPF

# summary (mksummary: written here, and again after the deep sweep with its line)
DEEPSUM=
mksummary() {
{
  echo "$TYBAN"
  echo "$KLINE"
  echo "$PHLINE"
  echo "скрипт: sha256 ${TYSHA:-?}"
  for mn in "$DEVNOTE" "$KNOTE" "$KOLD" "$PREVNOTE" "$OUTNOTE"; do [ -n "$mn" ] && echo "$mn"; done
  echo "ядро:               $REL, с включения $(up) с"
  echo "прошивка:           $(getprop ro.build.display.id) (Android $(getprop ro.build.version.release), vendor $(getprop ro.vendor.build.version.incremental))"
  echo "загрузка:           завершена=$(getprop sys.boot_completed) (причина $(getprop sys.boot.reason))"
  echo "verified boot:      ${VBS:-?}"
  [ -n "$FSCKS" ] && echo "проверка /data:     $FSCKS"
  [ -n "$SHUTS" ] && echo "выключение:         $SHUTS"
  echo "SELinux:            ${SEL:-?}"
  echo "журналы:            ядро $([ "$KLOG" = 1 ] && echo "прочитано" || echo "НЕ прочитано"), logcat $([ "$LLOG" = 1 ] && echo "прочитан${MAIN0:+, main с $MAIN0 с}" || echo "НЕ прочитан"), radio $([ "$RLOG" = 1 ] && echo "прочитан" || echo "пуст"); debugfs $(if [ -n "$DBGWAS" ]; then echo 'подключён на время проверки'; elif [ -n "$DBGFS" ]; then echo есть; else echo 'не смонтирован (часть проверок пропущена)'; fi)"
  # (of modules.load in vendor_boot: the count the newest install log of
  # this kernel names; netmgrd's unloads: section 20)
  rmn=$(printf '%s' "$rmu" | sed -E 's/ \(на [^)]*\)//g; s/^, //')
  rmc=0; [ -n "$rmn" ] && rmc=$(printf '%s\n' "$rmn" | tr ',' '\n' | grep -c .)
  echo "модулей загружено:  $NMOD${NMODL:+ из $NMODL}${rmn:+, $rmc выгружены netmgrd ($rmn)}"
  if [ -n "$QPOS" ]; then echo "qrtr.ko:            модуль $((NMOD - QPOS + 1)) из $NMOD по порядку загрузки; клиенты QMI до него:${QLATE:- нет}"
  else echo "qrtr.ko:            не загружаемый модуль (встроен или отсутствует)"; fi
  # (as section 3 read it: debugfs a run mounted is unmounted before the last summary)
  if [ -n "$DEF" ]; then echo "отложенных:         $(printf '%s\n' "$DEF" | grep -c .)"
  elif [ -n "$DEFOK" ]; then echo "отложенных:         0"
  else echo "отложенных:         не проверено (нет debugfs)"; fi
  # (without the expected: what section 21 found ended well, resolved
  # deferrals, the timeouts section 2 does not count, and PEXP)
  ndp=$(grep -c . $W/raw/dmesg-problems.txt); ndr=
  [ -n "$DEFOK" ] && ndr=$(grep -cE -e "$DEFX" $W/raw/dmesg-problems.txt)
  { if [ -s $TMPD/sub-ok.txt ]; then grep -vxF -f $TMPD/sub-ok.txt $W/raw/dmesg-problems.txt; else cat $W/raw/dmesg-problems.txt; fi; } | grep -vE -e "$PEXP|$TOX" |
    { if [ -n "$DEFOK" ]; then grep -vE -e "$DEFX"; else cat; fi; } > $TMPD/dmesg-problems-x.txt
  ndq=$(grep -c . $TMPD/dmesg-problems-x.txt)
  kw0=$(head -1 $W/raw/dmesg.txt | sed -nE 's/^\[ *([0-9]+)\..*/\1/p'); kw1=$(tail -n 1 $W/raw/dmesg.txt | sed -nE 's/^\[ *([0-9]+)\..*/\1/p')
  echo "проблем в журнале:  $ndp, без ожидаемого: $ndq${ndr:+ (отложенных probe, уже решённых: $ndr)}${kw1:+ (журнал ядра с ${kw0:-?} по $kw1 с)}"
  echo "отказов SELinux:    $(grep -c . $W/raw/avc.txt) (уникальных; служб: новых видов ${ndn:-?}, известных ${ndk:-?}; приложений: ${nap:-?} видов)${AVEND:+; $AVEND}${al_v:+; ядро не сохранило записей аудита: $al_v}"
  echo "pstore:             $(ls /sys/fs/pstore 2>/dev/null | tr '\n' ' ')${PMSGN:+($PMSGN)}"
  echo "netd:               $(getprop init.svc.netd)   bpf: $(getprop bpf.progs_loaded)"
  echo "mem_sleep:          $(rd /sys/power/mem_sleep)"
  echo "SIM / сеть:         $(getprop gsm.sim.state) / $(getprop gsm.network.type)"
  echo "SIM по времени:     журнал radio с ${r0:-?} с; первый статус карты ${cs_t:-?} с ${cs_s#CARDSTATE_}; $PRS; $SIMT"
  echo "служба SIM (UIM):   ${UIMST:-не проверена}"
  if [ -n "$in_e" ]; then echo "установка ядра:     ${in_d:-$in_k}: журнал пуст"
  elif [ -n "$in_o" ]; then echo "установка ядра:     ${in_d:-$in_k}: журнал старого формата (zip до 0.19)"
  elif [ -n "$in_k" ]; then echo "установка ядра:     ${in_d:-$in_k}${in_kr:+, $in_kr}${in_s:+, слот $in_s}: ${in_r:-без итога}${in_rr:+; потом восстановление: $in_rr}"; fi
  echo "uio:                $(for u in /sys/class/uio/uio*; do [ -e $u ] && printf '%s=%s ' ${u##*/} "$(rd $u/name)"; done)"
  echo "Wi-Fi / Bluetooth:  $(case "$(grep -m1 '^Wi-Fi is' $W/wireless.txt)" in *enabled*) echo включён;; *disabled*) echo выключен;; *) echo '?';; esac) / $(case "$(grep -m1 '^  enabled:' $W/wireless.txt)" in *true*) echo включён;; *false*) echo выключен;; *) echo '?';; esac)"
  api=$(grep -ohwE "$APIF" $W/raw/net-samples.txt $W/raw/ipmon.txt 2>/dev/null | sort -u | tr '\n' ' ')
  echo "интерфейсы AP:      ${api:-нет }(за $WIN с наблюдения)"
  echo "IPA uapi:           uapi_stock=$IPAU; прошивке нужен $IPAWANT ($IPAROM)"
  echo "батарея:            $(rd /sys/class/power_supply/battery/capacity)% $(rd /sys/class/power_supply/battery/status), usb online $(rd /sys/class/power_supply/usb/online)"
  echo "HAL питания:        $PCSUM; неудачных записей libperfmgr: ${pft:-0}${PFRT:+ (${PFRT%%:*})}${PHSUM:+; $PHSUM}; powerhint.json sha256 ${PJS:-?}${ph_j:+ ($ph_j)}"
  echo "звуковых карт:      $cards"
  [ -n "$MIC" ] && echo "микрофон:           потоков записи: ${nuser:-0}, с данными: ${nflow:-0}; цепочка TX: $([ -s ${MICD:-/nonexistent}/tx-chain.txt ] && sed -n 's/^BREAK 0.*/включена/p; s/^BREAK [1-9][0-9]* \(.*\)/оборвана на «\1»/p' $MICD/tx-chain.txt || echo 'не прочитана')"
  echo "камер:              ${NCAM:-нет}"
  echo "датчиков:           ${NSENS:-нет} аппаратных"
  echo "fastrpc:            $(sed -n '2p' $W/fastrpc.txt); привязано банков контекста: ${bcb:-0}; процессы: $(grep -E '^[a-z]+rpcd: ' $W/fastrpc.txt | sed -E 's/: начало.*\] /=/' | tr '\n' ' ')"
  echo "remoteproc:         $(for p in /sys/class/remoteproc/*; do [ -e $p ] && printf '%s=%s/%s ' "$(rd $p/name)" "$(rd $p/state)" "$(rd $p/recovery)"; done)(состояние/recovery)"
  echo "службы не в running/stopped:"
  getprop | grep -E '^\[init\.svc\.' | grep -vE '\[(running|stopped)\]' | sed 's/^/  /'
  # (not "has died: cch": a cached process that lmkd or the LRU ended; not
  # InputBundleManager's "restarting=false"; not ActivityManager's
  # "(Re)scheduling restart of crashed service": the service of an app whose
  # process lmkd ended, counted apart)
  echo "падения в logcat (Fatal signal, FATAL EXCEPTION, ANR, am_crash):"
  { grep -E 'FATAL EXCEPTION|Fatal signal|ANR in |crashed|(^|[^A-Za-z])restarting([^=A-Za-z]|$)' $W/raw/logcat.txt | grep -vE 'cheduling restart of crashed service'; grep -E ' am_(crash|anr|native_crash)' $W/raw/events.txt; } 2>/dev/null | awk '{ $1=$2=""; print }' | cut -c1-220 | appmask | sort | uniq -c | sort -rn | head -15
  echo "процессов, выгруженных из памяти (lmkd, кэш; это не падения): $(grep -cE 'has died: cch|lowmemorykiller: Kill' $W/raw/logcat.txt 2>/dev/null); перезапусков их служб («Scheduling restart of crashed service», обычно после выгрузки): $(grep -c 'cheduling restart of crashed service' $W/raw/logcat.txt 2>/dev/null)"
  [ -n "$DEEPSUM" ] && echo "deep:               $DEEPSUM"
} > $W/summary.txt 2>&1
}
mksummary

# endlogs: the logs of the run itself (the snapshot above was taken at its
# start; a run takes minutes, and what happens meanwhile, such as a hotspot
# turned on after the watch, would be lost): the end of the kernel log and
# main/system since the start, masked as above
# (final: also how much of the run the main log still holds)
endlogs() {
  tmo 30 dmesg 2>/dev/null | tail -4000 | kmask > $W/raw/dmesg-end.txt
  tmo 60 logcat -d -b main,system -v threadtime -T "$TSTART" 2>/dev/null | lmask > $W/raw/logcat-end.txt
  [ "$1" = final ] || return 0
  me=$(awk '/beginning of main/ { if ((getline l) > 0) { split(l, f, " "); print f[2] }; exit }' $W/raw/logcat-end.txt)
  [ -n "$me" ] && awk -v a="${TSTART#* }" -v b="$me" 'BEGIN { split(a, x, ":"); split(b, y, ":"); d = (y[1] * 3600 + y[2] * 60 + y[3]) - (x[1] * 3600 + x[2] * 60 + x[3]); if (d < 0) d += 86400; exit !(d > 60) }' &&
    det "журнал main в конце проверки начинается только с ${me%.*} (проверка началась в ${TSTART#* }): начало проверки в raw/logcat-end.txt не сохранилось"
  return 0
}

########################################################################
if [ -n "$DEEP" ]; then
# written now, so that a crash during the sweep loses nothing
beat "запись архива перед глубокой проверкой"
endlogs
mkreport "(записан перед глубокой проверкой: если более нового отчёта нет, телефон упал во время неё; следующий запуск скажет, на каком файле)"
packout partial "записан перед глубокой проверкой" && PACKED=1
sec "27. deep: чтение всех атрибутов /sys/devices"
: > $W/raw/sysfs-errors.txt
n=0
# (not: firmware, raw data, dumps, self-tests, calibration, measurements
# (AW8622x f0, cont, lra_resistance, vbat_monitor), register access, resets,
# updates, the Goodix touch scans (get_rawdata, diffdata), triggers; not the
# UFS HID group and the W-LUNs' dyn_cap_needed_attribute: this UFS 2.2 part
# rejects those queries, and each read logs a query error)
tmo 120 find ${TY_SYS:-/sys}/devices -type f -perm -400 2>/dev/null | grep -viE '/(firmware|rom|config|eeprom|nvmem|raw[^/]*|[^/]*raw[^/]*|[^/]*dump[^/]*|[^/]*test[^/]*|[^/]*inspect[^/]*|[^/]*calib[^/]*|[^/]*cali|[^/]*reset[^/]*|[^/]*fw[^/]*|[^/]*update[^/]*|[^/]*upgrade[^/]*|[^/]*diag[^/]*|[^/]*data|f0[^/]*|[^/]*cont|[^/]*resistance[^/]*|vbat[^/]*|[^/]*rtp[^/]*|activate|[^/]*trigger[^/]*|[^/]*reg|[^/]*rw|[^/]*cmd|resource[0-9]*|descriptors|modalias|uevent|dyn_cap_needed_attribute)$|\.ufshc/hid/' > $W/raw/sysfs-list.txt
nl=$(grep -c . $W/raw/sysfs-list.txt)
det "атрибутов для чтения: $nl"
# 100 files per head (no fork per file, as rdb): head reads at most 4 KB of
# each and names the file of each error ("head: <path>: <error>"); a batch
# that blocks for 60 s, or takes 10 s or more (a file in it is slow), is read
# again file by file, 2 s each, so a file that blocks longer is named (as
# when each file was read alone). The batch's list
# is in LAST (a crash: the next run names it), its uptime and first path in
# deep-batches.txt (the kernel's errors are matched to it), and every 5th
# batch leaves a line in the kernel log (pstore keeps it over a crash)
KMD=${TY_KMSG:-/dev/kmsg}; DT0=$(up); DE0=$(date +%s)
rm -f $TMPD/deep.chunk.*; : > $TMPD/deep-batches.txt; : > $TMPD/deep-slow.txt; : > $TMPD/deep-berr.txt
awk -v p=$TMPD/deep.chunk 'NR % 100 == 1 { if (f != "") close(f); f = sprintf("%s.%05d", p, ++n) } { print > f }' $W/raw/sysfs-list.txt
b=0
for c in $TMPD/deep.chunk.*; do
  [ -f "$c" ] || continue
  b=$((b + 1))
  [ -L $LAST ] && rm -f $LAST
  cat "$c" > $LAST
  read -r bf < "$c"
  bu0=$(up)
  echo "$bu0 $b $bf" >> $TMPD/deep-batches.txt
  [ $((b % 5)) = 1 ] && { echo "taoyao-check deep: batch $b $bf" >> $KMD; } 2>/dev/null
  OIFS=$IFS; IFS=$NL; set -f
  tmo 60 head -c 4096 $(cat "$c") < /dev/null > /dev/null 2> $TMPD/deep.err; rc=$?
  set +f; IFS=$OIFS
  bs0=${bu0%.*}; bs1=$(up); bs1=${bs1%.*}; bsl=
  case "$bs0$bs1" in ''|*[!0-9]*) ;; *) [ $((bs1 - bs0)) -ge 10 ] && bsl=$((bs1 - bs0));; esac
  if [ $rc = 124 ] || [ $rc = 137 ] || [ -n "$bsl" ]; then
    bst="$bsl с"; { [ $rc = 124 ] || [ $rc = 137 ]; } && bst="дольше 60 с, прервана"
    echo "пачка $b ($bst), с $bf" >> $TMPD/deep-slow.txt
    : > $TMPD/deep.err
    while IFS= read -r f; do
      echo "$f" > $LAST
      timeout 2 head -c 4096 "$f" < /dev/null > /dev/null 2>> $TMPD/deep.err
      [ $? = 124 ] && echo "timeout: $f" >> $W/raw/sysfs-errors.txt
    done < "$c"
  fi
  sed -n 's/^head: //p' $TMPD/deep.err >> $W/raw/sysfs-errors.txt
  sed -n "s/^head: /$b /p" $TMPD/deep.err >> $TMPD/deep-berr.txt
  n=$((n + $(grep -c . "$c")))
  rm -f "$c"
  beat
  [ $((b % 20)) = 0 ] && echo "   … прочитано $n из $nl"
done
rm -f $LAST $TMPD/deep.err
DT1=$(up); DE1=$(date +%s)
# the errors: expected ones (runtime PM answers EIO on autosuspend_delay_ms
# when a device does not use autosuspend; a thermal zone without
# power-allocator parameters, msm_hdcp min_level_change and cam-req-mgr's
# debug_node answer EIO by design), the known one (the PMR735A ADC channels
# on pmk8350_vadc: that PMIC is not fitted, each read waits about 0.5 s and
# fails; fixed in the next kernel version), and the rest by device. Also
# expected: the standard answers of attributes that have no value now (a
# network interface that is down or virtual: carrier, speed, duplex ...
# EINVAL, phys_port_* EOPNOTSUPP, the transmit queues' xps_cpus and
# traffic_class ENOENT; queue/wbt_lat_usec with WBT off; UFS 4.1 attributes
# on this UFS; memlat's hlos_cpucp_offset without CPUCP; the wireless
# charger's voltage_now ENODATA with no pad; the ultrasonic proximity
# sensor's sampling_frequency)
DEXP='/power/autosuspend_delay_ms: |/thermal_zone[0-9]+/(k_po|k_pu|k_i|k_d|sustainable_power|slope|offset|integral_cutoff): |/msm_hdcp/min_level_change: |cam-req-mgr/debug_node: |/net/[^/]+/(carrier|dormant|speed|duplex|name_assign_type|testing): Invalid argument$|/net/[^/]+/phys_(port_id|port_name|switch_id): Operation not supported|/net/[^/]+/queues/tx-[0-9]+/(xps_cpus|xps_rxqs|traffic_class): No such file or directory$|/queue/wbt_lat_usec: Invalid argument$|\.ufshc/device_lvl_exception_(count|id): Operation not supported|/memlat_settings/hlos_cpucp_offset: No such device$|/power_supply/wireless/voltage_now: No data available$|/us_prox\.[0-9]+/iio:device[0-9]+/in_proximity_sampling_frequency: Invalid argument$'
DKNOWN='pmr735a_[a-z0-9_]+_input: '
grep -vE '^timeout:' $W/raw/sysfs-errors.txt | grep -E "$DEXP" > $TMPD/deep-exp.txt
grep -vE '^timeout:' $W/raw/sysfs-errors.txt | grep -E "$DKNOWN" > $TMPD/deep-known.txt
grep -vE '^timeout:' $W/raw/sysfs-errors.txt | grep -vE "$DEXP" | grep -vE "$DKNOWN" > $TMPD/deep-other.txt
to=$(grep -c '^timeout:' $W/raw/sysfs-errors.txt); er=$(grep -vc '^timeout:' $W/raw/sysfs-errors.txt)
nexp=$(grep -c . $TMPD/deep-exp.txt); nkn=$(grep -c . $TMPD/deep-known.txt)
eio=$(grep -cE 'I/O error|Input/output error' $TMPD/deep-other.txt)
det "прочитано атрибутов: $n за $(awk -v a="$DT0" -v b="$DT1" 'BEGIN { printf "%d", b - a }') с; без ошибок: $((n - er - to)), с ошибкой: $er (ожидаемо: $nexp, известная ошибка ядра: $nkn), зависли: $to"
nsl=$(grep -c . $TMPD/deep-slow.txt)
[ "$nsl" -gt 0 ] && { det "--- медленные пачки (10 с и дольше; перечитаны по одному файлу, по 2 с на файл): $nsl"; head -20 $TMPD/deep-slow.txt >> $DET; }
det "--- ошибки чтения по видам (все)"
sed -E 's/.*: //' $W/raw/sysfs-errors.txt | sort | uniq -c | sort -rn | head -20 >> $DET
grep -E '^timeout:' $W/raw/sysfs-errors.txt | head -30 >> $DET
det "--- ошибки чтения, кроме ожидаемых (первые 60; EIO и прочие, без «нет прав»)"
{ grep -E 'I/O error|Input/output error' $TMPD/deep-other.txt; grep -vE 'I/O error|Input/output error' $TMPD/deep-other.txt | grep -viE 'Permission denied|Operation not permitted'; } | head -60 >> $DET
if [ "$nkn" -gt 0 ]; then
  det "--- известная ошибка ядра (исправление — в следующей версии ядра; на работу телефона не влияет): каналы АЦП PMR735A на pmk8350_vadc при чтении ждут около 0,5 с и дают ошибку — этой микросхемы в taoyao нет"
  cat $TMPD/deep-known.txt >> $DET
fi
det "--- ожидаемые ошибки (не считаются): $nexp"
sed -E 's/: [^:]*$//; s#.*/(power/autosuspend_delay_ms)$#\1#; s#.*/thermal_zone[0-9]+/.*#thermal_zone*/<параметры power-allocator>#; s#.*/(msm_hdcp/min_level_change)$#\1#; s#.*[/,](cam-req-mgr/debug_node)$#\1#; s#.*/net/[^/]+/(queues/tx-[0-9]+/)?([a-z_]+)$#net/*/\1\2 (интерфейс выключен или виртуальный)#; s#.*/(queue/wbt_lat_usec)$#\1 (WBT выключен)#; s#.*/(device_lvl_exception_(count|id))$#ufshc/\1 (атрибут UFS 4.1)#; s#.*/(memlat_settings/hlos_cpucp_offset)$#\1#; s#.*/(wireless/voltage_now)$#\1 (нет беспроводной зарядки)#; s#.*/(in_proximity_sampling_frequency)$#us_prox/\1#' $TMPD/deep-exp.txt | sort | uniq -c | sort -rn >> $DET
[ "$to" -gt 0 ] && fail sysfs "атрибутов, которые блокируют чтение (дольше 2 с): $to (подробности)"
if [ "$eio" -gt 0 ]; then
  eiod=$(grep -E 'I/O error|Input/output error' $TMPD/deep-other.txt | sed -E 's/: [^:]*$//; s#/[^/]*$##; s#.*/##' | sort | uniq -c | sort -rn | head -5 | awk '{ printf "%s%s (%d)", (n++ ? ", " : ""), $2, $1 }')
  warn sysfs "атрибутов с ошибкой ввода-вывода (EIO, не считая ожидаемых): $eio; по устройствам: $eiod (подробности)"
fi
dkn=; [ "$nkn" -gt 0 ] && dkn=", известная ошибка ядра (АЦП PMR735A, исправление — в следующей версии): $nkn"
ok sysfs "прочитано атрибутов: $n; с ошибкой: $er, из них ожидаемо: $nexp$dkn (raw/sysfs-errors.txt)"
# anything the sweep made the kernel print: WARN/BUG, and the error lines
# from the sweep's start, each with the batch read then (UFS -22 queries and
# the PMR735A ADC are known)
tmo 30 dmesg 2>/dev/null | kmask > $W/raw/dmesg-after-deep.txt
c=$(grep -cE "Call trace:|WARNING: CPU|BUG: |Unable to handle" $W/raw/dmesg-after-deep.txt)
c0=$(grep -cE "Call trace:|WARNING: CPU|BUG: |Unable to handle" $W/raw/dmesg.txt)
[ "$c" -gt "$c0" ] && fail sysfs "чтение атрибутов вызвало предупреждения или падения ядра: $((c - c0)) (raw/dmesg-after-deep.txt)"
# (the kernel's clock stops in suspend, /proc/uptime does not: from this
# sweep's first mark in the kernel log on, each mark gives the offset of the
# two clocks; without a mark the sweep's start is taken as it is)
m1=$(grep -n 'taoyao-check deep: batch 1 ' $W/raw/dmesg-after-deep.txt | tail -1 | cut -d: -f1)
# (each line with the files of that batch that gave a read error
# (deep-berr.txt): the unexpected ones, else the expected ones other than
# the runtime PM and thermal zone answers, which the kernel never logs;
# else the batch's first file)
grep -vE "$DEXP" $TMPD/deep-berr.txt > $TMPD/deep-berr-x.txt
grep -E "$DEXP" $TMPD/deep-berr.txt | grep -vE '/power/autosuspend_delay_ms: |/thermal_zone[0-9]+/' > $TMPD/deep-berr-e.txt
awk -v t0="$DT0" -v m1="${m1:-0}" -v bf=$TMPD/deep-batches.txt -v ef=$TMPD/deep-berr-x.txt -v af=$TMPD/deep-berr-e.txt 'BEGIN { while ((getline l < bf) > 0) { nb++; split(l, x, " "); bt[nb] = x[1] + 0; bn[nb] = x[2]; bp[nb] = substr(l, length(x[1] x[2]) + 3); ub[x[2]] = x[1] + 0 }
    while ((getline l < ef) > 0) { k = l; sub(/ .*/, "", k); if (ne[k]++ < 3) { f = substr(l, length(k) + 2); sub(/: [^:]*$/, "", f); be[k] = be[k] (be[k] == "" ? "" : ", ") f } }
    while ((getline l < af) > 0) { k = l; sub(/ .*/, "", k); if (!(k in be) && na[k]++ < 3) { f = substr(l, length(k) + 2); sub(/: [^:]*$/, "", f); ba[k] = ba[k] (ba[k] == "" ? "" : ", ") f } } }
  { t = $0; if (!match(t, /^\[ *[0-9]+\.[0-9]+\]/)) next; t = substr(t, 2, RLENGTH - 2) + 0 }
  m1 > 0 && NR < m1 { next }
  /taoyao-check deep: batch [0-9]+ / { k = $0; sub(/.*taoyao-check deep: batch /, "", k); sub(/ .*/, "", k); if (k in ub) { off = ub[k] - t; mk = 1 }; next }
  { if (mk) t += off; else if (t < t0) next }
  tolower($0) ~ /error|fail|fault|timed out|timeout|unable|invalid/ && $0 !~ /taoyao-check deep:|pmr735a|ufshcd_query_attr|Query RSP|ufshcd_dev_cmd_completion|avc:/ {
    k = 0; for (i = 1; i <= nb; i++) if (bt[i] <= t) k = i
    w = ""; if (k) w = (bn[k] in be) ? "ошибку чтения дал " be[bn[k]] : ((bn[k] in ba) ? "ошибку чтения дал " ba[bn[k]] : "других ошибок чтения в ней нет, первый файл " bp[k])
    print $0 (k ? "   [пачка " bn[k] ": " w "]" : "") }' $W/raw/dmesg-after-deep.txt > $TMPD/deep-kerr.txt
nke=$(grep -c . $TMPD/deep-kerr.txt)
det "--- строки ошибок ядра во время обхода: $nke (первые 40; в скобках — пачка файлов, которую читали тогда (по 100 файлов), и файлы этой пачки, давшие ошибку чтения)"
head -40 $TMPD/deep-kerr.txt | cut -c1-300 >> $DET
DEEPSUM="прочитано атрибутов $n за $(awk -v a="$DT0" -v b="$DT1" 'BEGIN { printf "%d", b - a }') с; с ошибкой $er (ожидаемо $nexp, АЦП PMR735A $nkn); зависли $to; EIO не по списку $eio; строк ошибок ядра $nke"
mksummary
fi

########################################################################
# the QTEE services of section 12b again: a pid that changed since then is a
# restart during the run (raw/tee-services.txt: name, state and pid then and now)
TEET1=$(up); teesvc > $W/raw/tee-svc-end.txt
awk -v ef=$W/raw/tee-svc-end.txt 'BEGIN { while ((getline l < ef) > 0) { split(l, a, " "); e[a[1]] = a[2] " " a[3] } }
  { print $1, $2, $3, (($1 in e) ? e[$1] : "- -") }' $W/raw/tee-svc-start.txt > $W/raw/tee-services.txt
det ""; det "################ 12b (в конце проверки). службы QTEE с $TEET0 с по $TEET1 с (имя: состояние pid -> состояние pid)"
while read -r ts_s st0 p0 st1 p1; do
  det "$ts_s: $st0 $p0 -> $st1 $p1"
  [ "$p0" != "$p1" ] && warn TEE "$ts_s перезапустилась во время проверки (pid $p0 -> $p1, $st0 -> $st1)"
done < $W/raw/tee-services.txt

########################################################################
T1=$(up)
TOOK=$(awk -v a="$T0" -v b="$T1" 'BEGIN { printf "%d", b - a }')
beat "запись архива"
echo "Записываю отчёт и архив…"
endlogs final
# what the run itself added to the logs (the checks above read them as they
# were at its start): the problem lines of section 2 over the kernel log's
# lines after the last one of raw/dmesg.txt, the SELinux denials since then
# (by audit serial and key against raw/avc.txt; raw/avc-run.txt), counted
# apart for the deep sweep's time (by the audit record's clock), and
# audit_lost again
beat "журналы за время проверки"
tmo 30 dmesg 2>/dev/null | kmask > $TMPD/dmesg-now.txt
kl1=$(tail -n 1 $W/raw/dmesg.txt | sed -nE 's/^\[ *([0-9]+\.[0-9]+)\].*/\1/p')
# (without the time of the first read's last line, nothing of the kernel
# log can be told to be newer: the pass over it is skipped)
if [ -n "$kl1" ]; then
  awk -v t="$kl1" '{ s = $0; if (!sub(/^\[ */, "", s)) next; sub(/\].*/, "", s); if (s + 0 > t + 0) print }' $TMPD/dmesg-now.txt | grep -vE "$SPAM" > $TMPD/dmesg-run.txt
  det ""; det "################ журналы за время проверки (журнал ядра после $kl1 с: $(grep -c . $TMPD/dmesg-run.txt) строк; logcat с начала проверки: raw/logcat-end.txt)"
  kscan $TMPD/dmesg-run.txt "во время проверки: "
else
  : > $TMPD/dmesg-run.txt
  det ""; det "################ журналы за время проверки (logcat с начала проверки: raw/logcat-end.txt; журнал ядра не проверен: в первом чтении нет строки со временем)"
fi
# (a camera an app opened meanwhile: face unlock, the camera app)
ncs=$(grep -c 'CAM_START_DEV Success' $TMPD/dmesg-run.txt)
[ "$ncs" -gt 0 ] && det "камера за время проверки запускалась $(pl $ncs "раз" "раза" "раз") (CAM_START_DEV; датчики: $(grep -oE 'CAM_START_DEV Success, sensor_id:0x[0-9a-fA-F]+' $TMPD/dmesg-run.txt | sed 's/.*sensor_id://' | sort -u | tr '\n' ' ')); строк CAM_ERR за это время: $(grep -c 'CAM_ERR' $TMPD/dmesg-run.txt)"
{ grep -h 'avc:  denied' $TMPD/dmesg-run.txt; grep -h 'avc:  denied' $W/raw/logcat-end.txt 2>/dev/null; } > $TMPD/avc-end-all.txt
awk -v old=$W/raw/avc.txt -f $AVCAWK $W/raw/avc.txt $TMPD/avc-end-all.txt > $W/raw/avc-run.txt
sed -nE "$AVCSED" $W/raw/avc-run.txt | sort | uniq -c | sort -rn > $TMPD/avc-run-grouped.txt
# (the collector's own domain: su of KernelSU and SukiSU, magisk)
avr=$(grep -c . $W/raw/avc-run.txt)
avd=$(awk -v ad="$APPDOM" '$2 !~ ad && $2 !~ /^(su|magisk)$/ { n += $1 } END { print n + 0 }' $TMPD/avc-run-grouped.txt)
ava=$(awk -v ad="$APPDOM" '$2 ~ ad { n += $1 } END { print n + 0 }' $TMPD/avc-run-grouped.txt)
avs=$(awk '$2 ~ /^(su|magisk)$/ { n += $1 } END { print n + 0 }' $TMPD/avc-run-grouped.txt)
avdeep=
if [ -n "$DE0" ] && [ -n "$DE1" ]; then
  avdeep=$(awk -v a="$DE0" -v b="$DE1" 'match($0, /audit\([0-9]+/) { t = substr($0, RSTART + 6, RLENGTH - 6) + 0; if (t >= a && t <= b + 1) n++ } END { print n + 0 }' $W/raw/avc-run.txt)
fi
AVEND="позже, за время проверки: $avr (служб $avd, приложений $ava, сборщика $avs)${avdeep:+, из них во время deep: $avdeep}"
det "отказы SELinux после первого чтения журналов: $AVEND (raw/avc-run.txt)"
[ -s $TMPD/avc-run-grouped.txt ] && head -30 $TMPD/avc-run-grouped.txt >> $DET
# (a kind of daemon denial that neither the first pass nor the known list
# had, nor a known gap on a generic label: the same inode search as section 10)
avcgen $W/raw/avc-run.txt $TMPD/avc-run
[ -s $TMPD/avc-run-genr.txt ] && { det "--- файлы за отказами служб на общих метках за время проверки"; awk -F'\t' '{ c[$1 " " $4 " -> " $5 ($7 == "" ? "" : "   [" $7 "]")]++ } END { for (k in c) print c[k], k }' $TMPD/avc-run-genr.txt | sort -rn | head -20 >> $DET; }
awk -v ad="$APPDOM" -v kf=$TMPD/avc-known.txt -v gk=$TMPD/avc-run-gen-known.txt -v gf=$W/raw/avc-grouped.txt 'BEGIN { while ((getline l < kf) > 0) k[l] = 1; while ((getline l < gk) > 0) k[l] = 1; while ((getline l < gf) > 0) { split(l, x, " "); k[x[2] " " x[3] " " x[4]] = 1 } }
  $2 !~ ad && $2 !~ /^(su|magisk)$/ && !(($2 " " $3 " " $4) in k)' $TMPD/avc-run-grouped.txt > $TMPD/avc-run-new.txt
nrn=$(grep -c . $TMPD/avc-run-new.txt)
[ "$nrn" -gt 0 ] && warn SELinux "за время проверки — $(pl $nrn "новый вид" "новых вида" "новых видов") отказов служб, которых не было при первом чтении журналов (raw/avc-run.txt)"
AL2=$(alost $TMPD/dmesg-now.txt)
if [ -n "$AL2" ] && [ "${AL2%%\|*}" != "${al_v:-}" ]; then
  al2j=${AL2##*\|}; al2t=${AL2#*\|}; al2t=${al2t%%\|*}
  det "audit_lost в конце проверки: ${AL2%%\|*} к $al2t с (при первом чтении: ${al_v:-0})${al2j:+; скачки больше 20: $al2j}"
  al_v=${AL2%%\|*}
fi
# debugfs: unmounted now if this run mounted it (nothing reads it after
# this: the summary takes the deferred probes from section 3)
if [ -n "$DBGM" ]; then
  if umount /sys/kernel/debug 2>/dev/null; then det "debugfs отключён (его подключила эта проверка)"; DBGM=; rm -f $LOCK/dbgm
  else det "debugfs отключить не удалось (занят?): $(grep -c ' /sys/kernel/debug ' /proc/mounts) монтирование осталось; при выходе сборщик попробует ещё раз"; fi
fi
mksummary
mkreport "(проверка заняла $TOOK с)"
if packout ok ""; then rm -rf $W
else echo "Архив не создан: файлы остались в $W"; fi
[ -n "$DBGM" ] && umount /sys/kernel/debug 2>/dev/null; DBGM=; rm -f $LOCK/dbgm
echo
echo "ОШИБКА $NFAIL   ВНИМАНИЕ $NWARN   ОК $NOK   (проверка заняла $TOOK с)"
tlist "$TAG_E" | appmask | head -10
[ "$NFAIL" -gt 10 ] && echo "   … и ещё $((NFAIL - 10)) — в отчёте"
if [ "$PKST" = fail ]; then finalblock fail "не удалось записать архив в $OUTDIR (память заполнена?)"; exit 1; fi
finalblock ok ""
exit 0
# конец taoyao-check.sh (версия 0.20)
