#!/usr/bin/env bash
# Сборщик логов MeruDevTools для Xiaomi Mi 12 Lite (taoyao), версия 0.20
# SPDX-License-Identifier: LicenseRef-MeruDevTools
# © 2026 Meddax (meru_ii) и команда MeruDevTools. Лицензия: LICENSE.txt
# Linux and macOS part: finds adb, waits for the phone, checks root, pushes
# taoyao-check.sh to /data/local/tmp, runs it, waits for a check that goes on
# in the background on the phone, then fetches and verifies the archive.
#   bash run-check.sh            menu
#   bash run-check.sh <mode>     prep | hotspot | mic | deep | deep hotspot |
#                                charge [minutes] | charge-pull | help
# bash 3.2 subset (macOS /bin/bash), UTF-8 without BOM, LF line ends. Every
# command sent to the phone is one adb argument without a single quote.
# Exit codes: 0 done, 10 failure (explained on screen), 11 cancelled,
# 130 Ctrl-C without a terminal to confirm it.

# (dash, zsh or "sh run-check.sh": start again under bash, not in POSIX mode)
if [ -z "${BASH_VERSION-}" ]; then
  command -v bash >/dev/null 2>&1 || { echo "Нужен bash. Установите его и запустите: bash run-check.sh"; exit 10; }
  exec bash "$0" "$@"
fi
case ":${SHELLOPTS-}:" in
  *:posix:*) [ -z "${MERUDEV_REEXEC-}" ] && MERUDEV_REEXEC=1 exec bash +o posix "$0" "$@";;
esac

# (byte-wise text tools: invalid UTF-8 in a phone log line must not make BSD
# sed or grep drop it; the Russian text is printed as bytes either way)
export LC_ALL=C

VER=0.20
BRAND='Сборщик логов MeruDevTools для Xiaomi Mi 12 Lite (taoyao)'
RC_OK=0; RC_FAIL=10; RC_CANCEL=11
LAUNCHER='bash run-check.sh'
PT_URL='https://developer.android.com/tools/releases/platform-tools'
DLT=/data/local/tmp
ADB_USER=${ADB-}

case $0 in
  */*) HERE=$(cd -- "${0%/*}" 2>/dev/null && pwd -P);;
  *) HERE=$(pwd -P);;
esac
[ -n "$HERE" ] || { echo "Не удаётся определить папку скрипта."; exit 10; }

if [ -t 1 ] && [ "${TERM-dumb}" != dumb ] && [ -z "${NO_COLOR-}" ]; then
  C0=$'\033[0m'; CC=$'\033[36m'; CY=$'\033[33m'; CR=$'\033[31m'; CG=$'\033[32m'
else
  C0=; CC=; CY=; CR=; CG=
fi

# keys: only with a terminal on stdin (no prompts and no menu otherwise)
TTYOK=
if [ -t 0 ] && { : </dev/tty; } 2>/dev/null; then TTYOK=1; fi

T=$(mktemp -d "${TMPDIR:-/tmp}/merudev.XXXXXX" 2>/dev/null) || { echo "Не удаётся создать временную папку."; exit 10; }

LOG=; LOGBUF=; LOCKD=; OUT=; BASE=; ADB=; SERIAL=; ADBROOT=; ADBPID=
INTR=; PHASE=; MENU=; MODE=; WORDS=; CHGMIN=; BG=
START=; BOOTID=; RUNIDS=; REMOTERC=; FETCHED=; EXTRA=; SHOWNPHONE=
SERIALS=; PREVSEEN=; FRES=; FREASON=; REBOOTED=
PTSTAGE=; PTSTAGE2=; PTERR=; PTVER=; PTOLD=; PTDST=

########################################################################
# masking for run-check.log: serials, home folder, user and computer name,
# MAC and IP addresses, e-mail and user@host
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
    # (also an address the phone masked only in part, e.g. aa:bb:cc:**:**:ff)
    printf '%s\n' 's/([0-9A-Fa-f*]{2}:){5}[0-9A-Fa-f*]{2}/xx:xx:xx:xx:xx:xx/g'
    printf '%s\n' 's/[A-Za-z0-9._%+-]+@[A-Za-z0-9._-]+/<user@host>/g'
    printf '%s\n' 's/([0-9]{1,3}\.){3}[0-9]{1,3}/ipv4/g'
    # (twice: a pass takes the character after an address, so an address
    # right after it is left for the second one)
    printf '%s\n' 's/(^|[^0-9A-Za-z:.])[0-9a-fA-F]{1,4}(:[0-9a-fA-F]{0,4}){3,7}([^0-9A-Za-z:]|$)/\1ipv6\3/g'
    printf '%s\n' 's/(^|[^0-9A-Za-z:.])[0-9a-fA-F]{1,4}(:[0-9a-fA-F]{0,4}){3,7}([^0-9A-Za-z:]|$)/\1ipv6\3/g'
  } > "$T/mask.sed"
}
mask() { sed -E -f "$T/mask.sed" 2>/dev/null; }
# cutc <bytes>: the first line of stdin cut to that many bytes, but never
# inside a UTF-8 character (LC_ALL=C: cut -c and ${s:0:n} count bytes)
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
  case " $SERIALS " in *" $1 "*) return 0;; esac
  SERIALS="$SERIALS $1"; build_mask
}

# logl <text>: into run-check.log only (masked, with the time)
logl() {
  local ts; ts=$(date '+%H:%M:%S')
  if [ -n "$LOG" ]; then
    printf '%s\n' "$1" | mask | sed "s/^/$ts /" >> "$LOG" 2>/dev/null
  else
    LOGBUF="$LOGBUF$ts $1
"
  fi
}
# on the screen and in the log: say (plain), step (cyan), warnm (yellow),
# errm (red), goodm (green)
say()   { printf '%s\n' "$1"; logl "$1"; }
step()  { printf '%s%s%s\n' "$CC" "$1" "$C0"; logl "$1"; }
warnm() { printf '%s%s%s\n' "$CY" "$1" "$C0"; logl "$1"; }
errm()  { printf '%s%s%s\n' "$CR" "$1" "$C0"; logl "$1"; }
goodm() { printf '%s%s%s\n' "$CG" "$1" "$C0"; logl "$1"; }

########################################################################
# texts
t_help() {
  printf '%s\n' "Использование: $LAUNCHER [режим]
  без параметров     меню
  prep               подготовка: запись журналов в фоне; потом повторите проблему
                     и запустите $LAUNCHER ещё раз (пункт 1 меню)
  hotspot            проверка точки доступа (по подсказке включить и выключить её)
  mic                проверка микрофона (по подсказкам)
  deep               глубокая проверка (15–40 минут); можно вместе: deep hotspot, deep mic
  charge [минуты]    журнал зарядки, по умолчанию 40 минут (от 1 до 1440)
  charge-pull        забрать журнал зарядки
  help               эта справка
Результаты сохраняются рядом со скриптом, в папке taoyao-check-<дата-время>."
}
t_menu() {
  printf '%s\n' "
Что сделать? Нажмите цифру:

  1  Обычная проверка — 5–7 минут. Лучше всего в первые минуты после включения телефона.
  2  Подготовка (prep) — включает запись журналов; потом вы повторяете проблему,
     и сразу запускается обычная проверка.
  3  Точка доступа (hotspot) — проверка раздачи Wi-Fi: по подсказке включить и выключить её.
  4  Микрофон (mic) — проверка микрофона по подсказкам.
  5  Зарядка (charge) — журнал зарядки; после запуска телефон отключают от компьютера.
  6  Забрать журнал зарядки (charge-pull) — когда зарядка закончилась.
  7  Глубокая проверка (deep) — 15–40 минут, читает все параметры драйверов.

  0  Выход"
}
# the licence notice (clause 2.4 of LICENSE.txt): the first lines of every
# run, before any question and any adb command; on the screen and in
# run-check.log
T_LIC1='Лицензия MeruDevTools — LICENSE.txt рядом со скриптом. Продолжая, вы принимаете её условия.'
T_LIC2='License: LICENSE.txt (MeruDevTools License). By continuing you accept it.'
show_license() {
  say "$T_LIC1"; say "$T_LIC2"
  [ -f "$HERE/LICENSE.txt" ] || warnm "ВНИМАНИЕ: нет файла лицензии LICENSE.txt: архив неполный, скачайте его заново."
  return 0
}
t_wait_none() {
  printf '%s\n' "Телефон не найден. Проверьте:
  • телефон включён и разблокирован;
  • кабель подключён прямо к компьютеру и передаёт данные (некоторые кабели только заряжают);
  • на телефоне включена «Отладка по USB». Как включить: Настройки → «О телефоне» → 7 раз нажмите на «Версия ОС» (HyperOS) или «Номер сборки» (crDroid, Evolution X); затем откройте «Для разработчиков» (HyperOS: «Расширенные настройки» → «Для разработчиков»; crDroid, Evolution X: «Система» → «Для разработчиков») и включите «Отладка по USB»."
  [ "$(uname -s 2>/dev/null)" = Darwin ] && echo "Если Mac спросит «Разрешить подключение аксессуара?», нажмите «Разрешить»."
  echo "Жду подключения телефона… (до $1 мин)"
}
T_UNAUTH='Телефон подключён, но этот компьютер ещё не разрешён. На экране телефона появится вопрос «Разрешить отладку по USB?»: поставьте галочку «Всегда разрешать с этого компьютера» и нажмите «Разрешить» (или «OK»). Если вопроса нет — разблокируйте экран, отключите и снова подключите кабель. Не помогло — в разделе «Для разработчиков» отзовите разрешения отладки по USB (пункт называется примерно «Отозвать авторизацию отладки по USB») и подключите кабель снова.'
T_AUTHORIZING='Телефон подключается…'
T_OFFLINE='Телефон виден, но не отвечает. Отключите и снова подключите кабель. Если не поможет — выключите и снова включите «Отладку по USB».'
T_RECOVERY='Телефон загружен в режим восстановления (recovery). Перезагрузите его в обычную систему и запустите скрипт снова.'
T_SIDELOAD='Телефон в режиме установки прошивки (sideload). Дождитесь конца установки, перезагрузите телефон в систему и запустите скрипт снова.'
T_FASTBOOT='Телефон в режиме fastboot. Перезагрузите его в систему: удерживайте кнопку питания около 15 секунд.'
T_NOPERM='Нет прав на доступ к телефону по USB. Установите правила udev для Android (Debian/Ubuntu: sudo apt install android-sdk-platform-tools-common; Fedora: sudo dnf install android-tools; Arch: sudo pacman -S android-udev), отключите и снова подключите кабель и запустите скрипт снова.'
T_ROOT_HOW='  • SukiSU-Ultra или KernelSU: откройте приложение-менеджер → вкладка «Суперпользователь» → в меню ⋮ включите показ системных приложений → найдите «Shell» (com.android.shell) → включите доступ.
  • Magisk: Magisk → Настройки → «Доступ суперпользователя» → «Приложения и ADB».
  • Если root на телефоне нет совсем, собрать логи не получится.'
T_ROOT_NOSU="Нет прав root для adb (команда su недоступна).
$T_ROOT_HOW"
T_CANCEL='Остановлено.'
T_PRIV='В архиве скрыты серийные номера, IMEI и ICCID, номера телефонов, MAC- и IP-адреса, имена сетей Wi-Fi, адреса e-mail, имена устройств и номера сотовых вышек, а названия установленных вами приложений заменены на app1, app2… Перед отправкой архив можно просмотреть.'
# (the keys of every yes/no question: see readans)
T_YN='(Д или Enter — да, Н или Esc — нет)'

mode_ru() {  # the check named in messages (genitive)
  case " $WORDS " in
    *" hotspot "*) echo "точки доступа";;
    *" mic "*) echo "микрофона";;
    *) echo "";;
  esac
}

########################################################################
# exit, cleanup, Ctrl-C
cleanup() {
  [ -n "$ADBPID" ] && kill "$ADBPID" 2>/dev/null
  [ -n "$LOCKD" ] && rm -rf "$LOCKD"
  # (stopped between the two renames of the platform-tools folder: the old
  # one comes back)
  if [ -n "$PTOLD" ] && [ ! -e "$PTDST" ] && [ ! -L "$PTDST" ]; then mv "$PTOLD" "$PTDST" 2>/dev/null; fi
  [ -n "$PTSTAGE" ] && rm -rf "$PTSTAGE"
  [ -n "$PTSTAGE2" ] && rm -rf "$PTSTAGE2"
  rm -rf "$T"
}
trap cleanup EXIT
trap 'INTR=1' INT
trap 'logl "terminated (TERM)"; exit 143' TERM
trap 'logl "terminated (HUP)"; exit 129' HUP

flushkeys() { [ -n "$TTYOK" ] || return 0; while IFS= read -r -s -n 1 -t 1 _k </dev/tty; do :; done 2>/dev/null; }
# readkey: KEY = ENTER, ESC, SEQ, INT or the character. Short reads in a
# loop: bash goes on with a read after a trapped SIGINT (the key after Ctrl+C
# would answer), so Ctrl+C is noticed between them; no terminal any more (a
# read that fails at once, three times): ESC. An arrow, Delete, Home, End,
# PgUp/PgDn or F key sends Esc with more bytes right after it: SEQ, an
# unknown key, not Esc (bash 3.2 waits whole seconds only)
ESCT=1; [ "${BASH_VERSINFO[0]:-3}" -ge 4 ] 2>/dev/null && ESCT=0.2
readkey() {
  local k= s f=0 c
  while :; do
    s=$SECONDS
    IFS= read -r -s -n 1 -t 1 k </dev/tty 2>/dev/null && break
    if [ -n "$INTR" ]; then INTR=; KEY=INT; return 0; fi
    if [ "$SECONDS" = "$s" ]; then f=$((f + 1)); [ $f -ge 3 ] && { KEY=ESC; return 0; }; else f=0; fi
  done
  if [ -n "$INTR" ]; then INTR=; KEY=INT; return 0; fi
  if [ -z "$k" ]; then KEY=ENTER
  elif [ "$k" = $'\e' ]; then
    # (a CSI sequence ends with a byte from @ to ~, an SS3 one after one more
    # byte: the key typed next is not eaten)
    KEY=ESC
    if IFS= read -r -s -n 1 -t $ESCT k </dev/tty 2>/dev/null; then
      KEY=SEQ
      if [ "$k" = '[' ]; then
        while IFS= read -r -s -n 1 -t $ESCT k </dev/tty 2>/dev/null; do
          [ -z "$k" ] && break
          printf -v c '%d' "'$k"; [ "$c" -ge 64 ] && [ "$c" -le 126 ] && break
        done
      elif [ "$k" = O ]; then IFS= read -r -s -n 1 -t $ESCT k </dev/tty 2>/dev/null; fi
    fi
  elif [ "$k" = $'\003' ]; then KEY=INT
  else KEY=$k; fi
}
# readans: readkey for an answer; ANS = YES (Enter, Д/д, or L/l: the Д key
# in the Latin layout), NO (Esc, Н/н, N/n), AGAIN (Y/y: on a Russian
# keyboard it shares its key with Н, so it could mean either), INT (Ctrl+C)
# or OTHER; KEY holds the key (a Cyrillic letter as its two UTF-8 bytes)
readans() {
  local k2
  readkey
  case $KEY in $'\320'|$'\321') k2=; IFS= read -r -s -n 1 -t 1 k2 </dev/tty 2>/dev/null; KEY=$KEY$k2;; esac
  case $KEY in
    ENTER|Д|д|L|l) ANS=YES;;
    ESC|Н|н|N|n) ANS=NO;;
    Y|y) ANS=AGAIN;;
    INT) ANS=INT;;
    *) ANS=OTHER;;
  esac
}
# ask_ans <default> [yes word] [no word]: 0 yes, 1 no, 2 Ctrl+C; Y and
# other keys ask again; without a terminal: the default
ask_ans() {
  local y=${2:-да} n=${3:-нет}
  [ -n "$TTYOK" ] || return "${1:-1}"
  while :; do
    readans
    case $ANS in
      YES) logl "answer: $KEY (yes)"; return 0;;
      NO) logl "answer: $KEY (no)"; return 1;;
      INT) logl "answer: Ctrl+C"; return 2;;
      AGAIN) say "Непонятно: на этой клавише и Y, и Н. Нажмите Enter — $y, Esc — $n.";;
      *) say "Нажмите Д или Enter — $y, Н или Esc — $n.";;
    esac
  done
}
# ask_yes <default> [yes word] [no word]: 0 yes, 1 no; Ctrl+C stops the run
ask_yes() {
  ask_ans "$@"
  case $? in 0) return 0;; 2) cancel_now;; esac
  return 1
}
# prompt_yes <text> <default> [yes word] [no word]: keys pressed before are
# dropped, then the question (yellow), then ask_yes
prompt_yes() { local q=$1; shift; flushkeys; warnm "$q"; ask_yes "$@"; }

finish() {
  local rc=$1
  [ -n "$ADBPID" ] && { kill "$ADBPID" 2>/dev/null; ADBPID=; }
  logl "exit code $rc"
  # prep and charge write no archive: a folder with only the log goes
  if [ "$rc" = 0 ] && [ -n "$OUT" ] && [ -z "$FETCHED" ]; then
    [ "$(ls -A "$OUT" 2>/dev/null)" = run-check.log ] && rm -rf "$OUT"
  fi
  if [ -n "$MENU" ]; then
    echo
    flushkeys
    printf '%s' "Нажмите любую клавишу, чтобы закрыть окно."
    readkey; echo
  fi
  exit "$rc"
}
fail() { [ -n "$1" ] && errm "$1"; show_failed; finish $RC_FAIL; }
show_failed() {
  echo
  if [ -n "$LOG" ]; then
    errm "Не получилось. Прикрепите к сообщению на форуме файл:
  $LOG
В нём нет серийного номера телефона и имени пользователя компьютера."
    open_folder "$OUT" ""
  else
    errm "Не получилось."
  fi
}

# stop_phone_check: ask the phone to stop a check that runs in the background:
# TERM to its worker (lock/wpid; lock/pid, hotspot and mic pid files for
# older phone scripts), which packs what it has; after 5 s its process group
# too (a command that hangs), unless it is packing already; then up to 30 s
# for it to end. 0: stopped, 2: told to stop but still packing, 1: nothing
# was running (or the phone did not answer)
stop_phone_check() {
  [ -n "$SERIAL" ] || return 1
  local cmd="set -f; d=$DLT; s=; for f in \$d/taoyao-check.lock/wpid \$d/taoyao-check.lock/pid \$d/taoyao-check-hotspot.pid \$d/taoyao-check-mic.pid; do p=\$(cat \$f 2>/dev/null); case \" \$s \" in *\" \$p \"*) continue;; esac; [ x\$p != x ] && kill -0 \$p 2>/dev/null && xargs -0 < /proc/\$p/cmdline 2>/dev/null | grep -q taoyao-check && kill \$p 2>/dev/null && s=\"\$s \$p\"; done; [ \"x\$s\" = x ] && exit 0; echo SENT; i=0; a=1; while [ \$i -lt 30 ]; do a=; for p in \$s; do [ -d /proc/\$p ] && ! grep -q State:.Z /proc/\$p/status 2>/dev/null && a=1; done; [ x\$a = x ] && break; [ \$i = 5 ] && [ ! -d \$d/taoyao-check.lock/packing ] && for p in \$s; do kill -s TERM -- -\$p 2>/dev/null; done; sleep 1; i=\$((i + 1)); done; [ x\$a = x ] && echo STOPPED; exit 0"
  dev_call 45 1 "$cmd" >/dev/null 2>&1
  grep -q STOPPED "$T/dc.out" 2>/dev/null && return 0
  grep -q SENT "$T/dc.out" 2>/dev/null && return 2
  return 1
}

cancel_now() {
  [ -n "$ADBPID" ] && { kill "$ADBPID" 2>/dev/null; ADBPID=; }
  echo
  case $PHASE in
    run)
      say "Останавливаю проверку на телефоне…"
      stop_phone_check
      case $? in
        0) warnm "Остановлено. Проверка на телефоне тоже остановлена.";;
        2) warnm "Остановлено. Проверка на телефоне останавливается и запишет то, что успела собрать.";;
        *) warnm "Остановлено. Если проверка на телефоне ещё идёт, она закончится сама и запишет результат.";;
      esac;;
    hs)
      echo "check $START $BOOTID" > "$BASE/.run-check-pending" 2>/dev/null
      warnm "Скрипт больше не ждёт. Проверка продолжается на телефоне и через пару минут сама запишет результат. Чтобы забрать его, запустите $LAUNCHER ещё раз (без параметров) — он предложит забрать результат.";;
    chg)
      warnm "Скрипт больше не ждёт. Журнал зарядки продолжает записываться на телефоне; заберите его позже (пункт 6).";;
    *) warnm "$T_CANCEL";;
  esac
  logl "cancelled by the user (phase ${PHASE:-none})"
  if [ -z "$TTYOK" ]; then finish 130; fi
  finish $RC_CANCEL
}
# check_intr: called in every wait; Ctrl-C asks before it stops
check_intr() {
  local q
  [ -n "$INTR" ] || return 0
  INTR=
  [ -n "$TTYOK" ] || cancel_now
  echo
  case $PHASE in
    run) q="Остановить проверку? $T_YN";;
    hs) q="Не ждать окончания проверки? Она продолжится на телефоне. $T_YN";;
    chg) q="Не ждать конца записи зарядки? Она продолжится на телефоне. $T_YN";;
    *) q="Остановить сбор логов? $T_YN";;
  esac
  if prompt_yes "$q" 0; then cancel_now; fi
  say "Продолжаю."
  return 0
}
# nap <seconds>: sleep, but react to Ctrl-C
nap() {
  local i=0 n=$(( $1 * 5 ))
  while [ $i -lt $n ]; do sleep 0.2; i=$((i + 1)); check_intr; done
}

########################################################################
# run_to <seconds> <outfile> <command...>: stdout and stderr to outfile,
# stdin from /dev/null; 124 after the time limit
run_to() {
  local lim=$1 of=$2 pid i=0 rc
  shift 2
  "$@" </dev/null >"$of" 2>&1 &
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

# dev_call <seconds> <root 0|1> <command>: adb shell; output in $T/dc.out
dev_call() {
  local lim=$1 root=$2 cmd=$3 full rc
  case $cmd in *"'"*) echo "Внутренняя ошибка сборщика: кавычка в команде для телефона" >&2; finish $RC_FAIL;; esac
  full=$cmd
  [ "$root" = 1 ] && [ -z "$ADBROOT" ] && full="su -c '$cmd'"
  logl "> adb shell $full"
  run_to "$lim" "$T/dc.out" "$ADB" -s "$SERIAL" shell "$full"; rc=$?
  logl "< rc=$rc $(head -c 3000 "$T/dc.out")"
  return $rc
}
# lost: the last adb call failed because the phone is gone
lost() {
  grep -qiE "device '.*' not found|no devices/emulators found|device offline|device unauthorized|error: closed|protocol fault|connection reset|failed to get feature set|no device" "$T/dc.out" 2>/dev/null
}
# kv <key> [file]: value of a key=value line
kv() { awk -v k="$1" 'index($0, k "=") == 1 { print substr($0, length(k) + 2); exit }' "${2:-$T/dc.out}" | tr -d '\r'; }

hhmm() { date -d "@$1" +%H:%M 2>/dev/null || date -r "$1" +%H:%M 2>/dev/null; }
dmyhm() { date -d "@$1" '+%d.%m.%Y %H:%M' 2>/dev/null || date -r "$1" '+%d.%m.%Y %H:%M' 2>/dev/null; }
elapsed() { local s=$1; if [ "$s" -ge 60 ]; then echo "$((s / 60)) мин $((s % 60)) с"; else echo "$s с"; fi; }

open_folder() {  # <folder> <file to select>
  [ -n "$MENU" ] || return 0
  case $(uname -s 2>/dev/null) in
    Darwin) if [ -n "$2" ]; then open -R "$2" >/dev/null 2>&1; else open "$1" >/dev/null 2>&1; fi;;
    *) if [ -n "${DISPLAY-}${WAYLAND_DISPLAY-}" ] && command -v xdg-open >/dev/null 2>&1; then
         xdg-open "$1" >/dev/null 2>&1 &
       fi;;
  esac
  return 0
}

########################################################################
# arguments
BADARG=
parse_args() {
  local w lw prev= deep= hs= mic= prep= chg= pull= n=0
  MODE=; WORDS=; CHGMIN=; BADARG=
  # ("deep hotspot" typed in quotes is two words)
  set -f
  # shellcheck disable=SC2048
  set -- $*
  set +f
  for w in "$@"; do
    lw=$(printf '%s' "$w" | tr '[:upper:]' '[:lower:]')
    case $lw in --*) lw=${lw#--};; esac
    case $lw in
      help|-h|h|'/?'|'-?'|'?'|'справка'|'Справка'|'СПРАВКА') MODE=help; return 0;;
      prep) prep=1;;
      deep) deep=1;;
      hotspot) hs=1;;
      mic) mic=1;;
      charge) chg=1;;
      charge-pull|chargepull) pull=1;;
      *[!0-9]*|'') BADARG=$w; return 1;;
      *) if [ "$prev" = charge ] && [ -z "$CHGMIN" ]; then CHGMIN=$lw; prev=$lw; continue; fi
         BADARG=$w; return 1;;
    esac
    prev=$lw
  done
  n=0
  [ -n "$prep" ] && n=$((n + 1)); [ -n "$chg" ] && n=$((n + 1)); [ -n "$pull" ] && n=$((n + 1))
  [ -n "$deep$hs$mic" ] && n=$((n + 1))
  if [ $n -gt 1 ]; then BADARG=combo; return 1; fi
  if [ -n "$hs" ] && [ -n "$mic" ]; then BADARG=hsmic; return 1; fi
  if [ -n "$chg" ]; then
    CHGMIN=$(printf '%s' "${CHGMIN:-40}" | sed 's/^0*//')
    if [ -z "$CHGMIN" ] || [ ${#CHGMIN} -gt 4 ] || [ "$CHGMIN" -gt 1440 ]; then BADARG=minutes; return 1; fi
    MODE=charge; WORDS="charge $CHGMIN"; return 0
  fi
  [ -n "$CHGMIN" ] && { BADARG=minutes; return 1; }
  [ -n "$prep" ] && { MODE=prep; WORDS=prep; return 0; }
  [ -n "$pull" ] && { MODE=charge-pull; WORDS=; return 0; }
  WORDS=
  [ -n "$deep" ] && WORDS="deep"
  [ -n "$hs" ] && WORDS="${WORDS:+$WORDS }hotspot"
  [ -n "$mic" ] && WORDS="${WORDS:+$WORDS }mic"
  MODE=check
  BG=; [ -n "$hs$mic" ] && BG=1
  return 0
}

# ask_minutes: the number typed key by key (digits, Backspace); Enter (or
# Д, L) takes it, empty: 40; Esc, Н, N or Ctrl+C: 1 (leave)
ask_minutes() {
  local s
  flushkeys
  printf '%s\n' "Сколько минут записывать зарядку? Введите число от 1 до 1440 и нажмите Enter (просто Enter — 40 минут):"
  while :; do
    printf '> '; s=
    while :; do
      readans
      case $ANS in
        YES) echo; break;;
        NO|INT) echo; logl "answer: $KEY (no minutes)"; return 1;;
        AGAIN) echo; say "Непонятно: на этой клавише и Y, и Н. Введите число и нажмите Enter, Esc — выйти."; printf '> %s' "$s";;
        *) case $KEY in
             [0-9]) [ ${#s} -lt 4 ] && { s=$s$KEY; printf '%s' "$KEY"; };;
             $'\177'|$'\b') [ -n "$s" ] && { s=${s%?}; printf '\b \b'; };;
           esac;;
      esac
    done
    [ -z "$s" ] && s=40
    s=$(printf '%s' "$s" | sed 's/^0*//')
    if [ -n "$s" ] && [ "$s" -ge 1 ] && [ "$s" -le 1440 ]; then CHGMIN=$s; logl "minutes: $s"; return 0; fi
    say "Нужно число от 1 до 1440."
  done
}

# menu: a digit; Esc (or Н, N) and Ctrl+C leave
menu() {
  local rc
  t_menu
  while :; do
    readans
    case $ANS in NO|INT) KEY=0;; esac
    case $KEY in
      1) MODE=check; WORDS=; BG=;;
      2) MODE=prep; WORDS=prep; BG=;;
      3) MODE=check; WORDS=hotspot; BG=1;;
      4) MODE=check; WORDS=mic; BG=1;;
      5) ask_minutes || { MODE=exit; return 0; }; MODE=charge; WORDS="charge $CHGMIN"; BG=;;
      6) MODE=charge-pull; WORDS=; BG=;;
      7) echo
         flushkeys
         warnm "Глубокая проверка займёт 15–40 минут. Телефон может зависнуть или перезагрузиться — это тоже нужный результат. Начать? $T_YN"
         ask_ans 1; rc=$?
         case $rc in
           0) MODE=check; WORDS=deep; BG=;;
           2) MODE=exit;;
           *) t_menu; continue;;
         esac;;
      0) MODE=exit;;
      *) say "Нажмите цифру от 0 до 7."; continue;;
    esac
    logl "menu: ${KEY} -> $MODE $WORDS"
    return 0
  done
}

########################################################################
# adb
ver_ok() {  # <x.y.z>: 1.0.39 or newer
  local a b c
  IFS=. read -r a b c <<< "$1"
  case "$a$b$c" in ''|*[!0-9]*) return 1;; esac
  [ "$a" -gt 1 ] && return 0
  [ "$a" -lt 1 ] && return 1
  [ "$b" -gt 0 ] && return 0
  [ "$c" -ge 39 ]
}
find_adb() {
  local p rc v inst seen=" " oldv= oldp= os ud m
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
    run_to 10 "$T/ver" "$p" version; rc=$?
    if [ $rc = 137 ] && [ "$os" = Darwin ]; then
      logl "adb candidate killed by macOS (quarantine? xattr -d com.apple.quarantine): $p"; continue
    fi
    if [ $rc != 0 ]; then logl "adb candidate failed (rc $rc): $p $(head -c 300 "$T/ver")"; continue; fi
    v=$(sed -n 's/^Android Debug Bridge version \([0-9][0-9.]*\).*/\1/p' "$T/ver" | head -n 1)
    inst=$(sed -n 's/^Installed as //p' "$T/ver" | head -n 1 | tr -d '\r')
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
  m=errm; [ $rc = 3 ] && m=warnm
  echo
  if [ -n "$oldv" ]; then
    $m "Найден только старый adb (версия $oldv: $oldp). С ним сбор логов работает ненадёжно. Скачайте свежий: $PT_URL — и распакуйте папку platform-tools рядом со скриптом: тогда будет использован он."
  elif [ "$os" = Darwin ]; then
    $m "Не найдена программа adb. Установите её одной командой: brew install --cask android-platform-tools — или скачайте «SDK Platform-Tools for Mac»: $PT_URL и положите папку platform-tools рядом с run-check.sh."
  else
    $m "Не найдена программа adb. Установите пакет (Debian/Ubuntu: sudo apt install adb; Fedora: sudo dnf install android-tools; Arch: sudo pacman -S android-tools) или скачайте «SDK Platform-Tools for Linux»: $PT_URL и положите папку platform-tools рядом с run-check.sh."
  fi
  if [ $rc = 3 ]; then
    echo
    warnm "adb не скачан — поставьте его, как написано выше, и запустите скрипт снова."
    logl "cancelled: the adb download was declined"
    finish $RC_CANCEL
  fi
  fail ""
}
start_server() {
  local rc
  run_to 30 "$T/ss" "$ADB" start-server; rc=$?
  logl "adb start-server: rc $rc $(head -c 500 "$T/ss")"
  if grep -q "doesn't match this client" "$T/ss"; then
    warnm "Другая программа на компьютере запускает свою версию adb, и они мешают друг другу. Если телефон будет «пропадать», закройте программы для работы с телефоном и запустите скрипт снова."
  fi
  if [ $rc != 0 ]; then
    fail "Не удалось запустить службу adb ($(grep -v '^\*' "$T/ss" | head -n 1)). Закройте другие программы, которые работают с телефоном по USB, и запустите скрипт снова. Не помогло — перезагрузите компьютер."
  fi
}

########################################################################
# adb from Google: with no usable adb, SDK Platform-Tools are downloaded
# from dl.google.com on this computer once the user agrees to Google's terms
# (Google's adb is not part of our ZIP), checked, and put into platform-tools
# next to the script, or into a per-user folder when the script folder is
# read-only or its platform-tools folder cannot be replaced.
# TAOYAO_ADB_DOWNLOAD=1 downloads without the question, =0 never;
# TAOYAO_PT_URL replaces the download folder for tests (https://dl.google.com
# only, or a local server on 127.0.0.1 or localhost).
PT_TERMS='https://developer.android.com/studio/terms'
PT_BASE='https://dl.google.com/android/repository'
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
       warnm "Непонятное значение TAOYAO_ADB_DOWNLOAD=«$(printf '%s' "$TAOYAO_ADB_DOWNLOAD" | cutc 40)»: нужно 1 (скачивать adb) или 0 (не скачивать)."
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
  prompt_yes "$q" 1 скачать "не скачивать" && return 0
  return 3
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
  "$@" </dev/null >"$of" 2>&1 &
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
# message in $T/dl.log (which run-check.log keeps as it is); PTKIND net (no
# internet, DNS, proxy, timeout, TLS), disk, or empty
pt_why() {
  local t=$1 rc=$2 l h= k=
  PTKIND=
  l=$(grep -v '^[[:space:]]*$' "$T/dl.log" 2>/dev/null | tail -n 1 | sed 's/^[0-9][0-9-]* [0-9][0-9:]* //' | cutc 200)
  if [ "$t:$rc" = curl:22 ] || [ "$t:$rc" = wget:8 ]; then
    h=$(grep -o 'error: [0-9][0-9][0-9]\|ERROR [0-9][0-9][0-9]' "$T/dl.log" 2>/dev/null | tail -n 1 | grep -o '[0-9][0-9][0-9]$')
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
      28) if grep -qi 'too slow' "$T/dl.log" 2>/dev/null; then k=slow; else k=time; fi;;
      35|51|53|54|58|59|60|64|66|77|80|82|83|90|91) k=tls;;
      16|18|52|55|56|92) k=cut;;
    esac
  else
    case $rc in
      3) k=disk;;
      5) k=tls;;
      4) if grep -qi 'resolv\|name or service\|name resolution' "$T/dl.log" 2>/dev/null; then k=dns
         elif grep -qi 'refused' "$T/dl.log" 2>/dev/null; then k=conn
         elif grep -qi 'timed out' "$T/dl.log" 2>/dev/null; then k=time
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
    pt_run 900 "$T/dl.log" curl -fsSL --proto "=$p" --proto-redir "=$p" --connect-timeout 30 \
      --speed-limit 1024 --speed-time 60 --max-filesize 209715200 -o "$2" "$1"; rc=$?
  else
    t=wget
    logl "> wget $1"
    pt_run 900 "$T/dl.log" wget --timeout=60 --tries=1 --max-redirect=5 --progress=dot:mega -O "$2" "$1"; rc=$?
  fi
  PTFILE=
  logl "< rc=$rc $(grep -v '^[[:space:]]*$' "$T/dl.log" | tail -n 3 | head -c 600)"
  # (curl refuses a redirect to http:// with exit code 1; wget follows it)
  if { [ $t = wget ] && [ $rc = 0 ] && [ $p = https ] && grep -qi '^Location: *http:' "$T/dl.log"; } ||
     { [ $t = curl ] && [ $rc = 1 ] && grep -qi 'protocol.*not supported\|disabled' "$T/dl.log"; }; then
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
      unzip) unzip -Z1 "$z" > "$T/ptlist" 2>/dev/null;;
      python3) python3 -I -c 'import sys, zipfile
for n in zipfile.ZipFile(sys.argv[1]).namelist(): print(n)' "$z" > "$T/ptlist" 2>/dev/null;;
      bsdtar) bsdtar -tf "$z" > "$T/ptlist" 2>/dev/null;;
    esac && [ -s "$T/ptlist" ] && { use=$t; break; }
    logl "$t: cannot list the archive"
  done
  [ -n "$use" ] || { PTERR="архив не открывается"; return 1; }
  while IFS= read -r l; do
    case $l in platform-tools/*) ;; *) bad=$l; break;; esac
    case /$l/ in */../*|*\\*) bad=$l; break;; esac
    [ "$l" = platform-tools/adb ] && have=1
  done < "$T/ptlist"
  if [ -n "$bad" ]; then
    logl "archive entry outside platform-tools/: $bad"
    PTERR="в архиве есть файлы вне папки platform-tools"; return 1
  fi
  [ -n "$have" ] || { PTERR="в архиве нет platform-tools/adb"; return 1; }
  PTWHERE=unpack
  mkdir -p "$d" 2>/dev/null || { PTERR="не удаётся создать временную папку"; return 1; }
  case $use in
    unzip) run_to 120 "$T/ptx" unzip -q -o "$z" -d "$d";;
    python3) run_to 120 "$T/ptx" python3 -I -m zipfile -e "$z" "$d";;
    bsdtar) run_to 120 "$T/ptx" bsdtar -xf "$z" -C "$d";;
  esac
  rc=$?
  logl "$use: rc $rc $(head -c 300 "$T/ptx")"
  [ $rc = 0 ] && [ -f "$d/platform-tools/adb" ] && return 0
  # (the real reason: a damaged archive, a full disk, or the tool's message)
  if [ $rc = 124 ]; then PTERR="распаковка не закончилась за 2 мин"
  elif grep -qi 'no space\|disk full\|quota' "$T/ptx" 2>/dev/null; then PTERR="нет места на диске"
  elif [ $rc = 0 ] || grep -qi 'crc\|bad zip\|badzip\|corrupt\|invalid\|truncated\|damaged' "$T/ptx" 2>/dev/null; then
    PTWHERE=check; PTERR="архив повреждён"
  else
    PTERR=$(grep -v '^[[:space:]]*$' "$T/ptx" | tail -n 1 | cutc 200)
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
      run_to 30 "$T/cs" codesign --verify --strict "$a"; rc=$?
      logl "codesign --verify: rc $rc $(head -c 300 "$T/cs")"
      [ $rc = 0 ] || { PTERR="цифровая подпись adb недействительна"; return 1; }
      run_to 30 "$T/cs" codesign -dvv "$a"
      v=$(grep '^Authority=' "$T/cs" | head -n 1)
      logl "codesign: $v"
      # (the signer itself, e.g. "Developer ID Application: Google LLC (TEAMID)")
      printf '%s\n' "$v" | grep -Eq '^Authority=[^:]+: Google LLC \([A-Z0-9]+\)$' || { PTERR="adb подписан не Google LLC"; return 1; }
    else
      logl "codesign not found: the signature of adb is not checked"
    fi
  fi
  run_to 10 "$T/ptv" "$a" version; rc=$?
  v=$(sed -n 's/^Android Debug Bridge version \([0-9][0-9.]*\).*/\1/p' "$T/ptv" | head -n 1)
  logl "downloaded adb: rc $rc $(head -c 300 "$T/ptv")"
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
# pt_mverr: why mv failed ($T/mv), short and in Russian; the message itself
# goes to run-check.log
pt_mverr() {
  local l
  l=$(head -n 1 "$T/mv" 2>/dev/null)
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
    if ! mv "$dst" "$old" 2>"$T/mv"; then
      PTERR="не удаётся заменить старую папку «$dst» ($(pt_mverr))"
      return 1
    fi
    PTOLD=$old; PTDST=$dst
  fi
  if ! mv "$src" "$dst" 2>"$T/mv"; then
    PTERR="не удаётся положить папку platform-tools в «$par» ($(pt_mverr))"
    if [ -n "$had" ] && ! mv "$old" "$dst" 2>/dev/null; then
      warnm "Старая папка platform-tools сейчас называется «$old» — переименуйте её обратно в platform-tools."
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
    warnm "Не все файлы из старой папки platform-tools удалось перенести в новую — старая папка сохранена как «$keep»."
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
    run_to 15 "$T/ks" "$5" kill-server; rc=$?
    logl "old adb server stopped: $5 kill-server, rc $rc $(head -c 200 "$T/ks")"
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
  if [ $rc = 2 ]; then echo; warnm "Автоматическая загрузка adb недоступна: $PTERR."; return 1; fi
  if [ $rc != 0 ]; then echo; errm "$PTERR"; return 1; fi
  if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
    echo; warnm "Автоматическая загрузка adb недоступна: на компьютере нет программы curl или wget."; return 1
  fi
  if ! command -v unzip >/dev/null 2>&1 && ! command -v python3 >/dev/null 2>&1 && ! command -v bsdtar >/dev/null 2>&1; then
    echo; warnm "Автоматическая загрузка adb недоступна: на компьютере нет программы unzip."; return 1
  fi
  pt_ask "$oldv"; rc=$?
  [ $rc = 0 ] || return $rc
  # (next to the script; a folder there that cannot be written: per-user)
  ud=$(pt_user_dir); up=${ud%/*}
  par=$HERE; st="$par/.platform-tools-dl.$$"
  if ! pt_stage "$st"; then
    if [ -z "$ud" ] || ! pt_stage "$up/.platform-tools-dl.$$"; then
      errm "Не удаётся создать папку для adb ни рядом со скриптом, ни в папке пользователя."
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
      if [ -n "$disk" ]; then hint=" Освободите место на диске и запустите скрипт снова."
      elif [ -n "$net" ]; then hint=" Проверьте подключение к интернету; на рабочем компьютере загрузку может запрещать прокси-сервер или антивирус."
      else hint=" Попробуйте позже."; fi
      errm "Не удалось скачать Android SDK Platform-Tools ($m).$hint"
      pt_drop; return 1
    fi
    e1=$PTERR
    warnm "Не удалось скачать ($PTERR). Пробую ещё раз…"
    n=$((n + 1)); nap 3
  done
  say "Проверяю скачанный архив…"
  pt_install "$st/platform-tools.zip" "$st" "$par" "$oldv" "$oldp"; rc=$?
  # (the platform-tools folder next to the script cannot be replaced, e.g. a
  # program still uses it: the per-user folder, which is searched too)
  if [ $rc != 0 ] && [ "$PTWHERE" = place ] && [ "$par" = "$HERE" ] && [ -n "$ud" ]; then
    warnm "Не получилось положить adb рядом со скриптом: $PTERR. Сохраняю его в папку пользователя."
    if pt_stage "$up/.platform-tools-dl.$$"; then
      PTSTAGE2="$up/.platform-tools-dl.$$"
      if pt_install "$st/platform-tools.zip" "$PTSTAGE2" "$up" "$oldv" "$oldp"; then rc=0; par=$up; fi
    fi
  fi
  if [ $rc != 0 ]; then
    case $PTWHERE in
      check) errm "Скачанный архив не прошёл проверку: $PTERR. Он удалён, ничего не установлено.";;
      unpack) errm "Не удалось распаковать скачанный архив ($PTERR). Он удалён, ничего не установлено.";;
      *) errm "Не удаётся установить adb: $PTERR. Закройте программы, которые используют папку platform-tools, и запустите скрипт снова.";;
    esac
    pt_drop; return 1
  fi
  pt_drop
  ADB="$par/platform-tools/adb"; ADBVER=$PTVER
  logl "adb: $ADB (version $ADBVER, downloaded)"
  goodm "Готово: Android SDK Platform-Tools скачаны и проверены (adb $ADBVER)."
  if [ "$par" != "$HERE" ] && [ -n "$ro" ]; then
    say "В папку со скриптами нельзя записывать, поэтому adb сохранён в «$par/platform-tools» — там он найдётся и в следующий раз."
  elif [ "$par" != "$HERE" ]; then
    say "adb сохранён в «$par/platform-tools» — там он найдётся и в следующий раз."
  fi
  return 0
}

# one look at "adb devices -l": DSTATE (none, device, unauthorized, ...),
# SERIAL candidates; DLIST for the "several devices" message
scan_devices() {
  local re='^([^[:space:]]+)[[:space:]]+(no permissions|device|unauthorized|offline|recovery|sideload|bootloader|rescue|authorizing|connecting|host)([[:space:]].*)?$'
  local rem='model:([^[:space:]]+)' red='device:([^[:space:]]+)'
  local l s st rest model dn n=0 nt=0 tser= tst= aser= ast= one= onest=
  DSTATE=none; DLIST=; DSER=
  run_to 10 "$T/dev" "$ADB" devices -l
  while IFS= read -r l; do
    l=${l%$'\r'}
    [[ $l =~ $re ]] || continue
    s=${BASH_REMATCH[1]}; st=${BASH_REMATCH[2]}; rest=${BASH_REMATCH[3]}
    add_serial "$s"
    model=; dn=
    [[ $rest =~ $rem ]] && model=${BASH_REMATCH[1]}
    [[ $rest =~ $red ]] && dn=${BASH_REMATCH[1]}
    n=$((n + 1)); one=$s; onest=$st
    DLIST="$DLIST  ${model:-?} (${dn:-?}), серийный номер ${s:0:2}…
"
    if [ -n "${ANDROID_SERIAL-}" ] && [ "$s" = "$ANDROID_SERIAL" ]; then aser=$s; ast=$st; fi
    if [ "$dn" = taoyao ]; then nt=$((nt + 1)); tser=$s; tst=$st; fi
  done < "$T/dev"
  logl "devices: $n ($(sed 's/[[:space:]].*//' "$T/dev" | grep -v '^List' | tr '\n' ' '))"
  if [ -n "${ANDROID_SERIAL-}" ]; then
    if [ -n "$aser" ]; then DSER=$aser; DSTATE=$ast; else DSTATE=serialgone; fi
    return 0
  fi
  if [ $n = 0 ]; then DSTATE=none; return 0; fi
  if [ $n = 1 ]; then DSER=$one; DSTATE=$onest; return 0; fi
  if [ $nt = 1 ]; then DSER=$tser; DSTATE=$tst; MULTIPICK=1; return 0; fi
  DSTATE=multi
}

# wait_device [limit seconds]: until one phone is in state "device"
wait_device() {
  local lim=${1:-180} t0=$SECONDS last= offt= rec= fbt= el nextel=15
  PHASE=wait
  while :; do
    MULTIPICK=
    scan_devices
    if [ "$DSTATE" != "$last" ]; then
      logl "device state: $DSTATE"
      case $DSTATE in
        device) ;;
        none) t_wait_none $((lim / 60));;
        unauthorized) warnm "$T_UNAUTH";;
        authorizing|connecting) say "$T_AUTHORIZING";;
        offline) warnm "$T_OFFLINE";;
        recovery|rescue) fail "$T_RECOVERY";;
        sideload) fail "$T_SIDELOAD";;
        bootloader) fail "$T_FASTBOOT";;
        "no permissions") fail "$T_NOPERM";;
        serialgone) fail "Переменная ANDROID_SERIAL указывает на устройство, которого сейчас нет. Подключите его или удалите эту переменную.";;
        multi) fail "Подключено несколько Android-устройств (или запущен эмулятор):
${DLIST}Оставьте подключённым только Xiaomi Mi 12 Lite и запустите скрипт снова (или задайте переменную ANDROID_SERIAL).";;
        host) say "$T_AUTHORIZING";;
      esac
      last=$DSTATE
    fi
    if [ "$DSTATE" = device ]; then
      SERIAL=$DSER
      [ -n "$MULTIPICK" ] && say "Подключено несколько устройств; выбран Xiaomi Mi 12 Lite."
      PHASE=
      return 0
    fi
    el=$((SECONDS - t0))
    # offline for 20 s: one reconnect
    if [ "$DSTATE" = offline ]; then
      [ -z "$offt" ] && offt=$SECONDS
      if [ -z "$rec" ] && [ $((SECONDS - offt)) -ge 20 ]; then
        rec=1; run_to 10 "$T/rc" "$ADB" reconnect offline; logl "adb reconnect offline: $(head -c 200 "$T/rc")"
      fi
    else offt=; fi
    # no device for 20 s: a phone in fastboot? (fastboot next to adb)
    if [ "$DSTATE" = none ] && [ -z "$fbt" ] && [ $el -ge 20 ] && [ -x "${ADB%/*}/fastboot" ]; then
      fbt=1
      run_to 5 "$T/fb" "${ADB%/*}/fastboot" devices
      grep -q 'fastboot' "$T/fb" && fail "$T_FASTBOOT"
    fi
    if [ $el -ge "$nextel" ] && [ $el -lt "$lim" ]; then
      say "… жду $(elapsed $el)"
      nextel=$((nextel + 15))
    fi
    if [ $el -ge "$lim" ]; then
      if [ -n "$TTYOK" ]; then
        if prompt_yes "Телефон так и не подключился за $((lim / 60)) мин. Подождать ещё? (Д или Enter — подождать, Н или Esc — выйти)" 1 подождать выйти; then t0=$SECONDS; nextel=15; last=; continue; fi
        finish $RC_CANCEL
      fi
      fail "Телефон так и не подключился за $((lim / 60)) мин. Проверьте пункты выше и запустите скрипт снова."
    fi
    nap 2
  done
}

# root: ADBROOT when adb shell already runs as root, else su -c id
root_check() {
  local try out rc waited
  dev_call 20 0 "id -u"
  if [ "$(tr -d '\r\n ' < "$T/dc.out")" = 0 ]; then
    ADBROOT=1; say "Права root: adb уже работает от root."; return 0
  fi
  ADBROOT=
  while :; do
    try=1
    while [ $try -le 3 ]; do
      logl "> adb shell su -c id (try $try)"
      "$ADB" -s "$SERIAL" shell "su -c id" </dev/null >"$T/su.out" 2>&1 &
      ADBPID=$!; waited=0
      while kill -0 "$ADBPID" 2>/dev/null; do
        sleep 0.2; waited=$((waited + 1)); check_intr
        [ $waited = 25 ] && say "Жду ответа на запрос прав root на экране телефона…"
        if [ $waited -ge 150 ]; then kill "$ADBPID" 2>/dev/null; sleep 1; kill -9 "$ADBPID" 2>/dev/null; break; fi
      done
      wait "$ADBPID" 2>/dev/null; rc=$?; ADBPID=
      [ $waited -ge 150 ] && rc=124
      out=$(tr -d '\r' < "$T/su.out")
      logl "< rc=$rc $out"
      case $out in *uid=0*) say "Права root: есть."; return 0;; esac
      if printf '%s' "$out" | grep -qiE "device '.*' not found|no devices|device offline|error: closed"; then
        wait_device; continue
      fi
      if [ $rc = 127 ] || printf '%s' "$out" | grep -qiE 'not found|inaccessible|No such file'; then
        break
      fi
      if [ $try -lt 3 ]; then
        warnm "Запрос прав root отклонён или остался без ответа. Если на телефоне появилось окно «Запрос суперпользователя» для Shell — нажмите «Разрешить» (лучше «навсегда»). Пробую ещё раз через 5 секунд… (попытка $((try + 1)) из 3)"
        nap 5
      fi
      try=$((try + 1))
    done
    if [ $rc = 127 ] || printf '%s' "$out" | grep -qiE 'not found|inaccessible|No such file'; then
      echo
      errm "$T_ROOT_NOSU"
    else
      errm "Не удалось получить права root ($(printf '%s\n' "$out" | cutc 120)). Проверьте настройки root:"
      say "$T_ROOT_HOW"
    fi
    if [ -n "$TTYOK" ]; then
      if prompt_yes "Проверить ещё раз? (Д или Enter — проверить, Н или Esc — выйти)" 1 проверить выйти; then continue; fi
      finish $RC_CANCEL
    fi
    fail ""
  done
}

I1='set -f; for p in ro.product.device ro.product.vendor.device ro.product.model ro.build.version.release ro.build.display.id sys.boot_completed sys.user.0.ce_available; do echo $p=$(getprop $p); done; echo kr=$(uname -r); echo kv=$(uname -v); echo boot=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null); echo now=$(date +%s); echo df=$(df -k /data 2>/dev/null | tail -n 1); [ -d /sdcard/Android ] && echo sd=1; echo end=1'

# kernel line: build N from "-v0.N" in uname -r (build 18 on), else from the
# build date (builds 15-17 all say 6.12.96-taoyao #1)
kernel_line() {
  local kr=$1 kv=$2 b= mon d hm y key mm k
  case $kr in *-v0.[0-9]*) b=${kr##*-v0.}; b=${b%%[!0-9]*};; esac
  # "#1 SMP PREEMPT Thu Nov 12 19:06:17 UTC 2026"
  set -- $kv
  mon=; d=; hm=; y=
  while [ $# -ge 4 ]; do
    case $1 in Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)
      case $2 in [0-9]|[0-9][0-9]) mon=$1; d=$2; hm=$3; shift 3
        while [ $# -gt 0 ]; do case $1 in [12][0-9][0-9][0-9]) y=$1; break;; esac; shift; done
        break;; esac;;
    esac
    shift
  done
  KDATE=
  if [ -n "$y" ]; then
    mm=0; for k in Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec; do mm=$((mm + 1)); [ "$k" = "$mon" ] && break; done
    [ ${#d} = 1 ] && d=0$d; [ ${#mm} = 1 ] && mm=0$mm
    KDATE="$d.$mm.$y ${hm%:*} UTC"
    key="$y$mm$d$(printf '%s' "${hm%:*}" | tr -d ':')"
    if [ -z "$b" ]; then
      # (zip times of builds 15-17; the kernel is built a few minutes before)
      if [ "$key" -gt 202611121740 ] && [ "$key" -le 202611121910 ]; then b=15
      elif [ "$key" -gt 202611122043 ] && [ "$key" -le 202611122213 ]; then b=16
      elif [ "$key" -gt 202611130013 ] && [ "$key" -le 202611130143 ]; then b=17; fi
    fi
  fi
  printf 'Ядро: %s' "$kr"
  [ -n "$KDATE" ] && printf ', собрано %s' "$KDATE"
  if [ -n "$b" ]; then printf ' (сборка 0.%s)' "$b"; else printf ' (номер сборки не определён)'; fi
  printf '\n'
}

# phone_info: one call without root; taoyao, boot completed, storage
# unlocked, free space; sets START (phone clock) and BOOTID
phone_info() {
  local dev vdev model rel rom bc ce kr kver sd df av waited=0 shown=
  while :; do
    if ! dev_call 20 0 "$I1" || [ -z "$(kv end)" ]; then
      lost && { wait_device; continue; }
      fail "Телефон не ответил ($(cutc 120 < "$T/dc.out"))."
    fi
    dev=$(kv ro.product.device); vdev=$(kv ro.product.vendor.device); model=$(kv ro.product.model)
    rel=$(kv ro.build.version.release); rom=$(kv ro.build.display.id)
    bc=$(kv sys.boot_completed); ce=$(kv sys.user.0.ce_available); sd=$(kv sd)
    kr=$(kv kr); kver=$(kv kv); BOOTID=$(kv boot); START=$(kv now); df=$(kv df)
    if [ "$bc" != 1 ]; then
      [ -z "$shown" ] && { shown=boot; say "Телефон ещё загружается — жду окончания загрузки… (до 5 минут)"; }
    elif [ "$ce" != true ] && [ "$sd" != 1 ]; then
      [ "$shown" != lock ] && { shown=lock; warnm "Разблокируйте экран телефона (PIN-код, пароль или графический ключ): пока телефон не разблокирован после включения, его память недоступна. Жду… (до 5 минут)"; }
    else
      break
    fi
    if [ $waited -ge 300 ]; then
      fail "Телефон не загрузился или не был разблокирован за 5 минут."
    fi
    nap 5; waited=$((waited + 5))
    [ $((waited % 30)) = 0 ] && say "… жду $(elapsed $waited)"
  done
  if [ "$dev" != taoyao ] && [ "$vdev" != taoyao ]; then
    case $kr in *taoyao*) ;;
      *) errm "Подключено устройство «${model:-?}» (${dev:-?}), а этот сборщик — только для Xiaomi Mi 12 Lite (taoyao)."
         if [ -n "$TTYOK" ]; then
           prompt_yes "Всё равно продолжить? $T_YN" 1 || finish $RC_FAIL
         else
           fail "Остановлено."
         fi;;
    esac
  fi
  if [ -z "$SHOWNPHONE" ]; then
    SHOWNPHONE=1
    say "Телефон: Xiaomi Mi 12 Lite (${model:-?}), Android ${rel:-?}, прошивка ${rom:-?}"
    say "$(kernel_line "$kr" "$kver")"
    case $kr in 6.12.*) ;; *) warnm "Внимание: на телефоне ядро $kr, а сборщик рассчитан на ядро 6.12. Проверка всё равно выполнится.";; esac
  fi
  # df: "<fs> <size> <used> <avail> <use%> <mount>"
  av=$(printf '%s' "$df" | awk '{ print $4 }')
  case $av in ''|*[!0-9]*) ;;
    *) [ "$av" -lt 204800 ] && warnm "Внимание: на телефоне свободно всего $((av / 1024)) МБ. Для проверки нужно около 200 МБ — освободите место, иначе архив может не записаться.";;
  esac
  case $SERIAL in *:*|*._adb-tls-connect.*)
    case " $WORDS " in *" hotspot "*|*" deep "*) warnm "Телефон подключён к adb по сети, а не кабелем. Для проверки точки доступа и глубокой проверки лучше подключить кабель.";; esac;;
  esac
  return 0
}

ready_phone() { wait_device; root_check; phone_info; }

# busy probe: background checks (lock: its worker, lock/wpid; lock/pid for an
# older phone script; hotspot, mic) and the charge logger
P1="set -f; d=$DLT; for k in check.lock check-hotspot check-mic charge; do f=\$d/taoyao-\$k.pid; [ \$k = check.lock ] && { f=\$d/taoyao-check.lock/wpid; [ -s \$f ] || f=\$d/taoyao-check.lock/pid; }; p=\$(cat \$f 2>/dev/null); a=0; c=; m=; md=; if [ x\$p != x ] && kill -0 \$p 2>/dev/null && ! grep -q State:.Z /proc/\$p/status 2>/dev/null; then a=1; c=\$(xargs -0 < /proc/\$p/cmdline 2>/dev/null); fi; [ -f \$f ] && m=\$(stat -c %Y \$f 2>/dev/null); [ \$k = check.lock ] && md=\$(cat \$d/taoyao-check.lock/mode 2>/dev/null); echo P:\$k:\$p:\$a:\$m:\$md:\$c; done; echo now=\$(date +%s)"
# probe: fills BUSYCHK (a check running: lock, hotspot or mic), BUSYCHKT
# (its start, phone clock), CHGALIVE, CHGPIDV, CHGSTART, CHGM, CHGPF
# (charge pid file present), PNOW; false when the phone did not answer
probe() {
  local l tag k p a m md c
  BUSYCHK=; BUSYCHKT=; BUSYPID=; CHGALIVE=; CHGPIDV=; CHGSTART=; CHGM=; CHGPF=; PNOW=
  dev_call 20 1 "$P1" || return 1
  PNOW=$(kv now)
  [ -n "$PNOW" ] || return 1
  while IFS=: read -r tag k p a m md c; do
    [ "$tag" = P ] || continue
    c=" ${c%$'\r'} "
    if [ "$a" = 1 ]; then
      case $c in *taoyao-check*) ;; *) a=0;; esac
    fi
    case $k in
      check.lock) [ "$a" = 1 ] && { BUSYCHK=${md:-check}; BUSYCHKT=$m; BUSYPID=$p; };;
      check-hotspot) case $c in *" hotspot "*) ;; *) a=0;; esac
                     [ "$a" = 1 ] && [ -z "$BUSYCHK" ] && { BUSYCHK=hotspot; BUSYCHKT=$m; BUSYPID=$p; };;
      check-mic) case $c in *" mic "*) ;; *) a=0;; esac
                 [ "$a" = 1 ] && [ -z "$BUSYCHK" ] && { BUSYCHK=mic; BUSYCHKT=$m; BUSYPID=$p; };;
      charge) [ -n "$m" ] && CHGPF=1
              case $c in *" charge "*) ;; *) a=0;; esac
              if [ "$a" = 1 ]; then
                CHGALIVE=1; CHGPIDV=$p; CHGSTART=$m
                CHGM=$(printf '%s\n' $c | grep -E '^[0-9]+$' | tail -n 1)
              fi;;
    esac
  done < "$T/dc.out"
  logl "probe: check=${BUSYCHK:-none} charge=${CHGALIVE:-0}"
  return 0
}
busy_name() {
  case $1 in
    *hotspot*) echo "проверка точки доступа";;
    *mic*) echo "проверка микрофона";;
    *deep*) echo "глубокая проверка";;
    *prep*) echo "подготовка";;
    *) echo "проверка";;
  esac
}

# wait_bg [limit seconds]: while a check runs on in the background
wait_bg() {
  local lim=${1:-1200} t0=$SECONDS next=0 el
  PHASE=hs
  while :; do
    if ! probe; then
      if lost; then
        warnm "Связь с телефоном прервалась — проверка продолжается на телефоне. Подключите кабель снова, как только сможете."
        wait_device 600; PHASE=hs; continue
      fi
      nap 5; continue
    fi
    [ -z "$BUSYCHK" ] && { PHASE=; return 0; }
    # (deep: the phone's own watchdog allows 60 minutes and the watch window)
    case $BUSYCHK in *deep*) [ "$lim" -lt 4000 ] && lim=4000;; esac
    el=$((SECONDS - t0))
    if [ $el -ge $next ]; then
      say "$(busy_name "$BUSYCHK" | sed 's/^п/П/; s/^г/Г/') ещё идёт на телефоне ($(elapsed $el)). Жду её окончания…"
      next=$((next + 30))
    fi
    if [ $el -ge "$lim" ]; then
      PHASE=
      fail "$(busy_name "$BUSYCHK" | sed 's/^п/П/; s/^г/Г/') идёт слишком долго. Скрипт перестаёт ждать; запустите его позже — он предложит забрать результат."
    fi
    nap 5
  done
}

########################################################################
# fetch: <check|charge> [fresh 1|0]
F1() {
  local k=$1
  echo "set -f; r=$DLT/taoyao-$k-result.txt; sed -n 1s/^/res=/p \$r 2>/dev/null; echo resm=\$(stat -c %Y \$r 2>/dev/null); x=\$(head -n 1 \$r 2>/dev/null | cut -f2); for f in \$x /sdcard/taoyao-$k.tar.gz $DLT/taoyao-check-out/taoyao-$k.tar.gz; do echo st=\$(stat -c %s:%Y \$f 2>/dev/null):\$f; [ -e \$f.part ] && echo part=\$f; done; echo now=\$(date +%s)"
}
pull_one() {  # <remote> <local file>: adb pull, 5 min
  local rc
  rm -f "$2"
  logl "> adb pull $1"
  run_to 300 "$T/pull.out" "$ADB" -s "$SERIAL" pull "$1" "$2"; rc=$?
  logl "< rc=$rc $(tail -n 3 "$T/pull.out")"
  return $rc
}
# verify <local file> <kind> <size>: size, gzip and tar listing, top folder
verify() {
  local f=$1 k=$2 sz=$3 lsz top
  VWHAT=
  [ -f "$f" ] || { VWHAT="файла нет"; return 1; }
  lsz=$(wc -c < "$f" | tr -d ' ')
  if [ -n "$sz" ] && [ "$lsz" != "$sz" ]; then VWHAT="размер $lsz вместо $sz"; return 1; fi
  if ! run_to 60 "$T/list" tar -tzf "$f"; then VWHAT="архив не читается: $(grep -v '^taoyao-' "$T/list" | cutc 100)"; return 1; fi
  top=$(head -n 1 "$T/list" | sed 's|^\./||' | cut -d/ -f1)
  case $top in taoyao-$k-[0-9]*) ;; *) VWHAT="неожиданное содержимое ($top)"; return 1;; esac
  if ! grep -q "^\(\./\)\{0,1\}$top/taoyao-$k.txt\$" "$T/list"; then VWHAT="в архиве нет отчёта"; return 1; fi
  VTOP=$top
  case " $RUNIDS " in *" $top "*) ;; *) [ -n "$RUNIDS" ] && logl "archive folder $top is not among the run ids seen ($RUNIDS)";; esac
  return 0
}
fetch() {
  local k=$1 fresh=${2:-1} l res= resm= path= size= mt= part= now st f sz m i rp name waited=0 lsz
  PHASE=wait; FRES=; FREASON=
  step "Забираю результаты…"
  while :; do
    dev_call 20 1 "$(F1 "$k")" || { lost && { wait_device 600; continue; }; fail "Телефон не ответил."; }
    res=$(kv res); resm=$(kv resm); now=$(kv now); part=$(kv part)
    path=; size=; mt=
    # the result file of this run names the archive (also a fallback folder)
    if [ -n "$res" ] && [ -n "$resm" ] && { [ "$fresh" = 0 ] || [ "$resm" -ge $((START - 5)) ]; }; then
      rp=$(printf '%s' "$res" | tr '\t' '\n' | grep -m1 '^/.*\.tar\.gz$')
      FRES=$(printf '%s\n' "$res" | cut -f1); FREASON=$(printf '%s\n' "$res" | cut -f6)
      logl "result file: $(printf '%s' "$res" | tr '\t' ' ')"
    else rp=; fi
    while IFS= read -r l; do
      case $l in st=*) ;; *) continue;; esac
      l=${l#st=}; l=${l%$'\r'}
      st=${l%%/*}; f=/${l#*/}
      sz=${st%%:*}; m=${st#*:}; m=${m%%:*}
      [ -n "$sz" ] && [ -n "$m" ] || continue
      if [ -n "$rp" ] && [ "$f" != "$rp" ]; then continue; fi
      if [ -z "$path" ] || { [ -n "$mt" ] && [ "$m" -gt "$mt" ]; }; then path=$f; size=$sz; mt=$m; fi
    done < "$T/dc.out"
    if [ -n "$part" ] && [ $waited -lt 120 ]; then
      [ $waited = 0 ] && say "Архив ещё записывается на телефоне…"
      nap 5; waited=$((waited + 5)); continue
    fi
    break
  done
  if [ -z "$path" ]; then
    if [ "$k" = charge ]; then errm "Журнал зарядки не записал архив."; else errm "Проверка не записала архив."; fi
    [ "$FRES" = fail ] && [ -n "$FREASON" ] && say "Причина (сообщение телефона): $FREASON."
    return 1
  fi
  if [ "$fresh" = 1 ] && [ -n "$START" ] && [ "$mt" -lt $((START - 5)) ]; then
    errm "На телефоне только архив от прошлого запуска ($(dmyhm "$mt")) — новый не записан."; return 1
  fi
  name=taoyao-$k.tar.gz
  i=1
  while [ $i -le 2 ]; do
    if [ $i = 1 ]; then
      pull_one "$path" "$OUT/$name"
    else
      # second try: a copy that adb can read (also for a root-only folder)
      if dev_call 30 1 "rm -f $DLT/taoyao-check-pull.tar.gz; cp $path $DLT/taoyao-check-pull.tar.gz && chmod 644 $DLT/taoyao-check-pull.tar.gz && echo COPIED" && grep -q COPIED "$T/dc.out"; then
        pull_one "$DLT/taoyao-check-pull.tar.gz" "$OUT/$name"
        dev_call 20 1 "rm -f $DLT/taoyao-check-pull.tar.gz" >/dev/null
      else
        pull_one "$path" "$OUT/$name"
      fi
    fi
    if verify "$OUT/$name" "$k" "$size"; then break; fi
    logl "verify failed: $VWHAT"
    if [ $i = 1 ]; then warnm "Архив скачан не полностью. Пробую ещё раз…"; fi
    i=$((i + 1))
  done
  if [ $i -gt 2 ]; then
    rm -f "$OUT/$name.bad"; [ -f "$OUT/$name" ] && mv -f "$OUT/$name" "$OUT/$name.bad"
    errm "Архив скачан, но он повреждён или неполный ($VWHAT)."; return 1
  fi
  # the report next to it (one try, no check)
  pull_one "${path%/*}/taoyao-$k.txt" "$OUT/taoyao-$k.txt" || rm -f "$OUT/taoyao-$k.txt"
  # an unfinished earlier run that the phone kept as taoyao-check-previous:
  # fetched too when the phone said so
  if [ "$k" = check ] && [ -n "$PREVSEEN" ]; then
    if pull_one "${path%/*}/taoyao-check-previous.tar.gz" "$OUT/taoyao-check-previous.tar.gz" &&
       run_to 60 "$T/plist" tar -tzf "$OUT/taoyao-check-previous.tar.gz"; then
      EXTRA="Также приложите архив прошлого (не завершённого) запуска: $OUT/taoyao-check-previous.tar.gz"
    fi
  fi
  ARCHIVE="$OUT/$name"; ARCHMT=$mt
  FETCHED=1
  lsz=$(wc -c < "$ARCHIVE" | tr -d ' ')
  ARCHSZ=$(awk -v b="$lsz" 'BEGIN { if (b >= 104858) printf "%.1f МБ", b / 1048576; else printf "%d КБ", (b + 1023) / 1024 }' | tr . ,)
  PHASE=
  return 0
}
show_done() {
  echo
  goodm "Готово.
Прикрепите к сообщению на форуме этот файл:
  $ARCHIVE  ($ARCHSZ)"
  [ -n "$1" ] && say "$1"
  [ -n "$EXTRA" ] && say "$EXTRA"
  [ -f "${ARCHIVE%/*}/taoyao-check.txt" ] && say "Отчёт, который можно прочитать: ${ARCHIVE%/*}/taoyao-check.txt"
  [ -f "${ARCHIVE%/*}/taoyao-charge.txt" ] && say "Отчёт, который можно прочитать: ${ARCHIVE%/*}/taoyao-charge.txt"
  say "$T_PRIV"
  open_folder "$OUT" "$ARCHIVE"
}

########################################################################
# output folder and log
# pick_base: the results go next to the script, or to ~/Desktop/MeruDevTools
pick_base() {
  local alt
  if mkdir "$HERE/.run-check-probe.$$" 2>/dev/null; then rmdir "$HERE/.run-check-probe.$$"; BASE=$HERE; return 0; fi
  alt="${HOME-/tmp}/MeruDevTools"; [ -d "${HOME-}/Desktop" ] && alt="$HOME/Desktop/MeruDevTools"
  mkdir -p "$alt" 2>/dev/null || { errm "Не удаётся создать папку для результатов."; exit $RC_FAIL; }
  BASE=$alt
  warnm "Не удаётся создать папку для результатов в «$HERE»: нет прав на запись. Результаты будут в «$BASE». Лучше перенести папку со скриптами, например, на Рабочий стол."
}
new_out() {  # <prefix>
  local name
  name="$1-$(date +%Y%m%d-%H%M%S)"
  OUT="$BASE/$name"
  mkdir -p "$OUT" 2>/dev/null || { errm "Не удаётся создать папку $OUT."; exit 10; }
  LOG="$OUT/run-check.log"
  : > "$LOG"
  if [ -n "$LOGBUF" ]; then printf '%s' "$LOGBUF" | mask >> "$LOG"; LOGBUF=; fi
}
take_lock() {
  local d="$BASE/.run-check.lock" op
  if ! mkdir "$d" 2>/dev/null; then
    op=$(cat "$d/pid" 2>/dev/null)
    if [ -n "$op" ] && kill -0 "$op" 2>/dev/null; then
      errm "Сборщик уже запущен в другом окне. Дождитесь его окончания или закройте то окно."
      MENU=; finish $RC_FAIL
    fi
    rm -rf "$d"; mkdir "$d" 2>/dev/null || return 0
  fi
  echo $$ > "$d/pid"; LOCKD=$d
}

########################################################################
# one run on the phone
run_live() {  # <limit seconds>
  local lim=$1 cmd n=0 c last t0 next l alive rc
  # (TAOYAO_DEBUGFS=1 or 0 on the computer, only when the developer asks: 1,
  # the phone mounts debugfs for the run and unmounts it at the end; 0, it
  # never mounts it, also in the modes that do so by themselves)
  local dbg=
  case ${TAOYAO_DEBUGFS-} in 0|1) dbg=" TAOYAO_DEBUGFS=$TAOYAO_DEBUGFS";; esac
  cmd="TAOYAO_WRAPPER=1$dbg sh $DLT/taoyao-check.sh${WORDS:+ $WORDS} 2>&1; echo MERUDEV_RC=\$?"
  [ -z "$ADBROOT" ] && cmd="su -c '$cmd'"
  logl "> adb shell $cmd"
  PHASE=run; REMOTERC=
  : > "$T/run.out"
  "$ADB" -s "$SERIAL" shell "$cmd" </dev/null >"$T/run.out" 2>&1 &
  ADBPID=$!
  t0=$SECONDS; last=$SECONDS; next=60
  while :; do
    alive=; kill -0 "$ADBPID" 2>/dev/null && alive=1
    c=$(wc -l < "$T/run.out" | tr -d ' ')
    if [ "$c" -gt "$n" ]; then
      sed -n "$((n + 1)),${c}p" "$T/run.out" > "$T/run.new"; n=$c; last=$SECONDS; next=60
      show_lines "$T/run.new"
    fi
    [ -z "$alive" ] && break
    if [ $((SECONDS - last)) -ge $next ]; then
      say "… проверка идёт ($(elapsed $((SECONDS - t0)))). Не отключайте телефон."
      next=$((next + 60))
    fi
    if [ $((SECONDS - t0)) -ge "$lim" ]; then
      kill "$ADBPID" 2>/dev/null
      errm "Проверка идёт уже $(elapsed $((SECONDS - t0))) — намного дольше обычного. Скрипт перестаёт ждать."
      stop_phone_check >/dev/null 2>&1
      break
    fi
    sleep 1
    check_intr
  done
  wait "$ADBPID" 2>/dev/null; rc=$?; ADBPID=
  # the rest, also a last line without a newline
  c=$(wc -l < "$T/run.out" | tr -d ' ')
  { sed -n "$((n + 1)),\$p" "$T/run.out"; } > "$T/run.new"
  [ -s "$T/run.new" ] && show_lines "$T/run.new"
  logl "adb shell ended: rc $rc, remote rc ${REMOTERC:-unknown}"
  PHASE=
  RUNSECS=$((SECONDS - t0))
  return 0
}
show_lines() {
  local l id t
  while IFS= read -r l || [ -n "$l" ]; do
    l=${l%$'\r'}
    case $l in MERUDEV_RC=*) REMOTERC=${l#MERUDEV_RC=}; continue;; esac
    t=$(printf '%s' "$l" | sed 's/^[[:space:]]*//')
    case $t in
      '>>>'*) printf '%s%s%s\n' "$CY" "$l" "$C0";;
      '[ОШИБКА]'*) printf '%s%s%s\n' "$CR" "$l" "$C0";;
      '[ВНИМАНИЕ]'*) printf '%s%s%s\n' "$CY" "$l" "$C0";;
      *) printf '%s\n' "$l";;
    esac
    case $l in *taoyao-check-previous.tar.gz*) PREVSEEN=1;; esac
    case $l in *taoyao-check-2[0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9]*|*taoyao-charge-2[0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9]*)
      for id in $(printf '%s\n' "$l" | grep -oE 'taoyao-(check|charge)-[0-9]{8}-[0-9]{6}'); do
        case " $RUNIDS " in *" $id "*) ;; *) RUNIDS="${RUNIDS:+$RUNIDS }$id";; esac
      done;;
    esac
  done < "$1"
  mask < "$1" | sed "s/^/$(date '+%H:%M:%S') | /" >> "$LOG" 2>/dev/null
}

push_script() {
  local rc
  step "Отправляю taoyao-check.sh на телефон…"
  logl "> adb push taoyao-check.sh $DLT/taoyao-check.sh"
  run_to 60 "$T/push.out" "$ADB" -s "$SERIAL" push "$HERE/taoyao-check.sh" "$DLT/taoyao-check.sh"; rc=$?
  logl "< rc=$rc $(tail -n 2 "$T/push.out")"
  [ $rc = 0 ] && return 0
  fail "Не удалось отправить файл на телефон ($(grep -i 'error' "$T/push.out" | cutc 150)). Отключите и снова подключите кабель и запустите скрипт ещё раз."
}

# after a run that lost its adb connection: wait for the phone, see if it
# rebooted (boot_id), wait for a background check, fetch
after_drop() {
  local oldboot=$BOOTID lim=600 rebooted=
  case " $WORDS " in *" deep "*) lim=900;; esac
  run_to 10 "$T/dev" "$ADB" devices
  if ! awk -v s="$SERIAL" '$1 == s && $2 == "device" { f = 1 } END { exit !f }' "$T/dev" 2>/dev/null; then
    if [ -n "$BG" ]; then
      warnm "Связь с телефоном прервалась — проверка $(mode_ru) продолжается на телефоне. Подключите кабель снова, как только сможете."
    else
      warnm "Связь с телефоном прервалась. Подключите его снова — жду до $((lim / 60)) минут…"
    fi
    wait_device "$lim"
  fi
  root_check
  local keep=$START
  phone_info
  START=$keep
  if [ -n "$oldboot" ] && [ "$BOOTID" != "$oldboot" ]; then
    rebooted=1
    case " $WORDS " in
      *" deep "*) warnm "Похоже, телефон упал во время глубокой проверки — это важный результат. Заберу архив, который проверка записала перед глубоким чтением.";;
      *) warnm "Телефон перезагрузился во время проверки.";;
    esac
  fi
  [ -z "$rebooted" ] && wait_bg
  if fetch check 1; then
    if [ -n "$rebooted" ]; then
      case " $WORDS " in *" deep "*) DONENOTE="(Этот архив записан перед глубоким чтением: глубокая проверка не закончилась.)";; esac
    fi
    return 0
  fi
  # (a check that the reboot cut off writes nothing; the next check packs
  # its files as prev-interrupted/)
  if [ -n "$rebooted" ]; then
    case " $WORDS " in *" deep "*) ;; *) REBOOTED=1; say "Запустите проверку ещё раз: в её архив попадут и файлы прерванного запуска.";; esac
  fi
  return 1
}

########################################################################
# main
parse_args "$@"; prc=$?
if [ "$MODE" = help ]; then
  echo "$BRAND, версия $VER"; show_license; echo; t_help; exit 0
fi
build_mask
echo "$BRAND, версия $VER"
logl "$BRAND, версия $VER"
show_license
logl "bash $BASH_VERSION, $(uname -sr 2>/dev/null); args: $*"
if [ $prc != 0 ]; then
  case $BADARG in
    combo) errm "prep, charge и charge-pull запускаются только по одному.";;
    hsmic) errm "hotspot и mic нельзя запускать вместе: запустите их по очереди.";;
    minutes) errm "После charge можно указать число минут от 1 до 1440.";;
    *) errm "Непонятный параметр «$BADARG».";;
  esac
  echo; t_help; exit $RC_FAIL
fi
[ $# = 0 ] && [ -n "$TTYOK" ] && MENU=1
say "Папка со скриптами: $HERE"

if [ ! -f "$HERE/taoyao-check.sh" ]; then
  errm "Рядом со скриптом нет файла taoyao-check.sh. Распакуйте весь ZIP-архив в одну папку и запускайте $LAUNCHER оттуда."
  exit $RC_FAIL
fi
DVER=$(head -n 5 "$HERE/taoyao-check.sh" | sed -n 's/.*Сборщик логов MeruDevTools.*версия[[:space:]]*\([0-9A-Za-z.]*\).*/\1/p' | head -n 1)
if [ "$DVER" != "$VER" ]; then
  warnm "Внимание: $LAUNCHER (версия $VER) и taoyao-check.sh (версия ${DVER:-неизвестна}) из разных выпусков. Лучше скачать сборщик заново целиком. Продолжаю."
fi

if [ -n "$MENU" ]; then
  menu
  [ "$MODE" = exit ] && exit 0
fi

case $MODE in charge|charge-pull) PFX=taoyao-charge;; *) PFX=taoyao-check;; esac
pick_base
take_lock
new_out "$PFX"
logl "mode: $MODE ${WORDS}"

find_adb
start_server
step "adb: $ADB (версия $ADBVER)"

while :; do   # (prep in the menu, or a deep crash, go round once more)
  ready_phone
  DONENOTE=

  # a check whose wait was cancelled earlier: offer its result
  if [ -f "$BASE/.run-check-pending" ]; then
    read -r pk pst pboot < "$BASE/.run-check-pending" 2>/dev/null
    rm -f "$BASE/.run-check-pending"
    if [ -n "$MENU" ] && [ "$pboot" = "$BOOTID" ] && probe && [ -z "$BUSYCHK" ]; then
      dev_call 20 1 "$(F1 check)"
      pm=$(sed -n 's/^st=[0-9]*:\([0-9]*\):\/sdcard\/.*/\1/p' "$T/dc.out" | head -n 1)
      if [ -n "$pm" ] && [ -n "$pst" ] && [ "$pm" -ge $((pst - 5)) ]; then
        if prompt_yes "На телефоне есть результат проверки, которую вы не дождались ($(dmyhm "$pm")). Забрать его? $T_YN" 1; then
          keep=$START; START=$pst
          if fetch check 1; then show_done ""; finish $RC_OK; fi
          START=$keep
          fail ""
        fi
      fi
    fi
  fi

  if ! probe; then fail "Телефон не ответил."; fi

  # charge-pull: wait for the logger, then fetch
  if [ "$MODE" = charge-pull ]; then
    if [ -z "$CHGALIVE" ]; then
      if [ -n "$CHGPF" ]; then
        fail "Запись зарядки прервалась (телефон перезагружался или выключался), и её результаты не сохранились. Запустите запись заново (пункт 5)."
      fi
    else
      PHASE=chg
      t0=$SECONDS; next=0
      cm=${CHGM:-40}
      left=$(( cm * 60 - (PNOW - ${CHGSTART:-$PNOW}) )); [ $left -lt 0 ] && left=0
      lim=$((left + 600)); [ -z "$CHGM" ] && lim=900
      warnm "Журнал зарядки ещё записывается: осталось около $(( (left + 59) / 60 )) мин (примерно до $(hhmm $(( $(date +%s) + left )))). Результат заберётся сам, окно не закрывайте.${TTYOK:+ Чтобы остановить запись сейчас, нажмите Enter.}"
      while :; do
        if [ -n "$TTYOK" ]; then
          k=; IFS= read -r -s -n 1 -t 5 k </dev/tty 2>/dev/null; krc=$?
          check_intr
          if [ $krc = 0 ] && [ -z "$k" ]; then
            if prompt_yes "Остановить запись зарядки сейчас? Результаты сохранятся. $T_YN" 1; then
              case $CHGPIDV in ''|*[!0-9]*) ;; *) dev_call 20 1 "kill $CHGPIDV";; esac
              say "Останавливаю запись…"
            fi
          fi
        else
          nap 5
        fi
        if ! probe; then lost && { wait_device 600; PHASE=chg; }; continue; fi
        [ -z "$CHGALIVE" ] && break
        el=$((SECONDS - t0))
        if [ $el -ge $next ] && [ $el -gt 0 ]; then
          left=$(( cm * 60 - (PNOW - ${CHGSTART:-$PNOW}) )); [ $left -lt 0 ] && left=0
          say "… журнал зарядки ещё записывается: осталось около $(( (left + 59) / 60 )) мин."
        fi
        [ $el -ge $next ] && next=$((next + 60))
        if [ $el -ge $lim ]; then
          PHASE=; fail "Журнал зарядки пишется дольше, чем должен. Скрипт перестаёт ждать; запустите charge-pull позже."
        fi
      done
      PHASE=
      sleep 2
    fi
    if fetch charge 0; then
      [ -n "$ARCHMT" ] && DONENOTE="(Журнал зарядки записан $(dmyhm "$ARCHMT").)"
      show_done "$DONENOTE"; finish $RC_OK
    fi
    if [ -z "$CHGPF" ] && [ "$FRES" != fail ]; then
      fail "На телефоне нет журнала зарядки. Сначала запустите запись (пункт 5), а после зарядки — пункт 6."
    fi
    fail ""
  fi

  # a check still running on the phone (started earlier): wait and fetch
  if [ -n "$BUSYCHK" ] && [ "$MODE" != charge ]; then
    bmin=0; [ -n "$BUSYCHKT" ] && bmin=$(( (PNOW - BUSYCHKT) / 60 ))
    if [ -n "$TTYOK" ]; then
      prompt_yes "На телефоне ещё идёт $(busy_name "$BUSYCHK"), запущенная раньше (уже $bmin мин). Дождаться её и забрать результат? $T_YN" 1 || finish $RC_CANCEL
    else
      warnm "На телефоне ещё идёт $(busy_name "$BUSYCHK"), запущенная раньше. Жду её окончания и заберу результат…"
    fi
    START=$BUSYCHKT
    [ -z "$START" ] && START=$PNOW
    wait_bg
    if fetch check 1; then show_done ""; finish $RC_OK; fi
    fail ""
  fi
  if [ -n "$CHGALIVE" ]; then
    if [ "$MODE" = charge ]; then
      left=$(( ${CHGM:-40} * 60 - (PNOW - ${CHGSTART:-$PNOW}) )); [ $left -lt 0 ] && left=0
      fail "Журнал зарядки уже записывается (осталось около $(( (left + 59) / 60 )) мин, примерно до $(hhmm $(( $(date +%s) + left )))). Когда он закончится, подключите телефон и выберите пункт 6 «Забрать журнал зарядки» (или: $LAUNCHER charge-pull)."
    fi
    left=$(( ${CHGM:-40} * 60 - (PNOW - ${CHGSTART:-$PNOW}) )); [ $left -lt 0 ] && left=0
    say "На телефоне записывается журнал зарядки (осталось около $(( (left + 59) / 60 )) мин) — он продолжит работу."
  fi

  push_script

  case $MODE in
    prep) step "Подготовка: телефон начнёт записывать журнал ядра в фоне и увеличит буферы журналов приложений (ничего не удаляется). Это меньше минуты."; LIM=300;;
    charge) step "Запускаю запись зарядки на $CHGMIN мин…"; LIM=120;;
    check)
      case " $WORDS " in
        *" hotspot "*)
          step "Проверка точки доступа (займёт 6–8 минут)."
          say "Разблокируйте телефон и откройте шторку с кнопкой «Точка доступа». Через несколько секунд после начала появится строка, которая начинается с «>>>», — тогда включите точку доступа, дождитесь, пока она включится (или покажет ошибку), и выключите её. На это есть 60 секунд."
          say "Если при этом прервётся связь по USB — ничего страшного: проверка доработает на телефоне, а этот скрипт её дождётся."
          if [ -n "$MENU" ]; then prompt_yes "Нажмите Enter, когда будете готовы (Esc — отмена)." 1 начать отмена || finish $RC_CANCEL; fi;;
        *" mic "*)
          step "Проверка микрофона: следуйте подсказкам ниже — строкам, которые начинаются с «>>>»."
          if [ -n "$MENU" ]; then prompt_yes "Нажмите Enter, когда будете готовы (Esc — отмена)." 1 начать отмена || finish $RC_CANCEL; fi;;
        *" deep "*)
          step "Глубокая проверка. Не отключайте кабель. Если телефон зависнет больше чем на 5 минут, одновременно зажмите «Громкость вниз» и кнопку питания примерно на 10 секунд — он перезагрузится и сохранит журнал сбоя. После загрузки разблокируйте телефон: скрипт заберёт то, что успело записаться.";;
        *) step "Обычная проверка займёт 5–7 минут. Не отключайте кабель и не закрывайте это окно. Если проблема со звуком — включите музыку на телефоне до запуска.";;
      esac
      case " $WORDS " in *" deep "*) LIM=7200;; *) LIM=1800;; esac;;
  esac

  RUNIDS=; PREVSEEN=
  run_live "$LIM"

  case $MODE in
    prep)
      if [ "$REMOTERC" != 0 ]; then
        fail "Подготовка на телефоне не выполнилась (код ${REMOTERC:-неизвестен}) — причина в сообщении выше."
      fi
      if [ -n "$MENU" ]; then
        echo
        flushkeys
        goodm "Подготовка готова."
        say "Теперь повторите проблему на телефоне (включите звук, откройте камеру, отправьте SMS…). Кабель на это время можно отключить — например, чтобы проверить сон: выключите экран на 10 минут."
        say "Когда закончите, подключите телефон и нажмите здесь Enter — запустится обычная проверка. Esc — выйти (обычную проверку можно запустить позже, пункт 1)."
        if ask_yes 1 "обычная проверка" выйти; then MODE=check; WORDS=; BG=; continue; fi
        finish $RC_OK
      fi
      goodm "Подготовка готова. Теперь повторите проблему на телефоне, затем запустите $LAUNCHER и выберите пункт 1 «Обычная проверка»."
      finish $RC_OK;;
    charge)
      if [ "$REMOTERC" = 0 ] && probe && [ -n "$CHGALIVE" ]; then
        e=$(( $(date +%s) + CHGMIN * 60 ))
        echo
        goodm "Запись зарядки запущена на $CHGMIN мин (примерно до $(hhmm $e)).
 1. Отключите кабель от компьютера.
 2. Поставьте телефон на зарядку, которую проверяете (её можно отключать и подключать снова).
 3. После $(hhmm $e) подключите телефон к компьютеру, запустите $LAUNCHER и выберите пункт 6 «Забрать журнал зарядки» (или: $LAUNCHER charge-pull).
Это окно можно закрыть."
        finish $RC_OK
      fi
      fail "Запись зарядки не запустилась — причина в сообщениях выше.";;
  esac

  # check modes
  if [ -z "$REMOTERC" ]; then
    if after_drop; then show_done "$DONENOTE"
      case " $WORDS " in *" deep "*)
        if [ -n "$MENU" ] && [ -n "$DONENOTE" ]; then
          echo
          if prompt_yes "Чтобы в отчёт попал журнал сбоя, сейчас стоит запустить обычную проверку. Запустить? $T_YN" 1; then
            EXTRA="Также приложите архив глубокой проверки: $ARCHIVE"
            MODE=check; WORDS=; BG=; new_out taoyao-check; FETCHED=; continue
          fi
        fi;;
      esac
      finish $RC_OK
    fi
    # (the phone rebooted during a check that is not deep: offer it again)
    if [ -n "$REBOOTED" ] && [ -n "$MENU" ]; then
      echo
      if prompt_yes "Запустить проверку ещё раз сейчас? $T_YN" 1; then
        REBOOTED=; MODE=check; new_out taoyao-check; FETCHED=; continue
      fi
    fi
    fail ""
  fi
  case $REMOTERC in
    0) ;;
    2|3|4|5) fail "Проверка на телефоне не запустилась (код $REMOTERC) — причина в сообщении выше.";;
    *) [ -z "$RUNIDS" ] && fail "Проверка на телефоне не запустилась (код $REMOTERC) — причина в сообщении выше."
       DONENOTE="(Проверка закончилась с ошибкой (код $REMOTERC): архив может быть неполным.)";;
  esac
  wait_bg
  if fetch check 1; then show_done "$DONENOTE"; finish $RC_OK; fi
  fail ""
done
