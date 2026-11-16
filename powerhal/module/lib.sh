# taoyao_powerhint612: общие функции. Подключается скриптами модуля после
# MODDIR=${0%/*} (customize.sh: MODDIR=$MODPATH). Только POSIX sh / busybox ash.
# Разработчики: Meddax и MeruDevTools. Связь: i@meru-ii.ru
TP_ROOT=""

SVC=vendor.power-hal-aidl
HALBIN=$TP_ROOT/vendor/bin/hw/android.hardware.power-service.lineage-libperfmgr
TARGET=$TP_ROOT/vendor/etc/powerhint.json
HAL_CONFIG=/vendor/etc/powerhint.json
STATE=$MODDIR/state
STATUS=$MODDIR/status.txt
DEF_LABEL=u:object_r:vendor_configs_file:s0
NAP_BUDGET=35
BOOTID=$(cat "$TP_ROOT/proc/sys/kernel/random/boot_id" 2>/dev/null)
TP_VER=$(sed -n 's/^version=//p' "$MODDIR/module.prop" 2>/dev/null)
TP_STAGE=${TP_STAGE:-?}
NAPS=0
REASON=""
DETAIL=""
ORIG_SHA=""
ORIG_LABEL=""
ORIG_NODES=""
ORIG_ACTIONS=""
NEW_SHA=""
PID_BEFORE=""
PID_AFTER=""
NODES=""
ACTIONS=""
OLDWARN=""
WFAIL=""
WPATHS=""
VERIFIED=""

nap() {
	NAPS=$((NAPS + 1))
	usleep 100000 2>/dev/null || sleep 0.1 2>/dev/null || sleep 1
}

budget_left() {
	[ "$NAPS" -lt "$NAP_BUDGET" ]
}

log() {
	{ echo "$(date '+%F %T') [$TP_STAGE] $*" >> "$STATE/boot.log"; } 2>/dev/null
}

ru_num() {
	_n=$1
	_a=$((_n % 10))
	_b=$((_n % 100))
	if [ "$_a" -eq 1 ] && [ "$_b" -ne 11 ]; then
		echo "$_n $2"
	elif [ "$_a" -ge 2 ] && [ "$_a" -le 4 ] && { [ "$_b" -lt 12 ] || [ "$_b" -gt 14 ]; }; then
		echo "$_n $3"
	else
		echo "$_n $4"
	fi
}

reason_text() {
	case "$1" in
	invalid_config) echo "сервис питания отверг файл (Invalid config)" ;;
	hal_no_start) echo "сервис питания не запустился" ;;
	no_new_pid) echo "сервис питания не перезапустился" ;;
	hal_crash) echo "сервис питания упал" ;;
	hal_crash_loop) echo "сервис питания перезапускается снова и снова" ;;
	hal_stopped) echo "сервис питания остановлен" ;;
	not_seen) echo "сервис питания прочитал файл прошивки, а не файл модуля" ;;
	not_restarted) echo "сервис питания так и не перезапустился с файлом модуля" ;;
	unexpected_counts) echo "сервис питания прочитал неожиданное число узлов и действий" ;;
	unverified_boot) echo "две загрузки подряд с подменой оборвались до проверки (перезагрузка, зависание или сбой ядра)" ;;
	*) echo "$1" ;;
	esac
}

# set_status РЕЗУЛЬТАТ ПРИЧИНА "текст" [ключ=значение...]
set_status() {
	_r=$1
	_rs=$2
	_msg=$3
	shift 3
	_tmp=$STATUS.tmp.$$
	{
		echo "module=taoyao_powerhint612"
		echo "version=$TP_VER"
		echo "boot_id=$BOOTID"
		echo "time=$(date '+%F %T')"
		echo "stage=$TP_STAGE"
		echo "result=$_r"
		echo "reason=$_rs"
		echo "message=$_msg"
		echo "kernel=$(uname -r)"
		echo "orig_sha256=$ORIG_SHA"
		echo "orig_label=$ORIG_LABEL"
		echo "new_sha256=$NEW_SHA"
		echo "hal_pid_before=$PID_BEFORE"
		echo "hal_pid_after=$PID_AFTER"
		echo "nodes_parsed=$NODES"
		echo "actions_parsed=$ACTIONS"
		echo "old_path_warnings=$OLDWARN"
		echo "write_failures=$WFAIL"
		echo "failed_paths=$WPATHS"
		echo "verified=$VERIFIED"
		for _kv in "$@"; do
			echo "$_kv"
		done
	} > "$_tmp" 2>/dev/null && mv -f "$_tmp" "$STATUS"
	ksud module config set -t override.description "$_msg" > /dev/null 2>&1
	log "итог: $_r $_rs: $_msg"
	return 0
}

# Значение ключа из прежнего status.txt (для service.sh).
st_get() {
	sed -n "s/^$1=//p" "$STATUS" 2>/dev/null | head -n 1
}

check_kernel() {
	case "$(uname -r)" in
	6.12*) ;;
	*) return 1 ;;
	esac
	[ -d "$TP_ROOT/sys/kernel/taoyao" ]
}

# Ядро taoyao 0.20 и новее само отвечает на записи сервиса питания в узлы
# ядра 5.4 (/sys/kernel/taoyao/perf_compat, «1»): файл прошивки работает и
# без модуля, ошибок записи нет. Но частоты, которых нет в таблицах, ядро
# 6.12 понимает не так, как 5.4: ограничение частоты CPU (scaling_max_freq)
# округляет вниз (cpufreq.c, CPUFREQ_RELATION_H), а нижний порог GPU не из
# уровней KGSL не ставит вовсе (kgsl_pwrscale.c). Модуль ставит эти значения,
# как на 5.4, поэтому на таком ядре работает так же, как на 0.19. «0» —
# поддержка в ядре есть, но узлы ещё не готовы или bwmon не загрузился.
kernel_compat() {
	_kc=$TP_ROOT/sys/kernel/taoyao/perf_compat
	[ -e "$_kc" ] || return 1
	[ "$(cat "$_kc" 2>/dev/null)" = 1 ]
}

KC_INFO="Ядро taoyao 0.20 и новее само поддерживает узлы сервиса питания ядра 5.4: файл прошивки работает и без модуля, без ошибок записи. Модуль нужен для точных частот: ограничения частоты CPU и нижние пороги GPU, которых нет в таблицах частот, ядро 6.12 понимает не так, как 5.4 (ограничение CPU округляет вниз, такой порог GPU не ставит), а модуль ставит их, как было на 5.4."
KC_NOTE="Ядро само поддерживает узлы сервиса питания ядра 5.4 (taoyao 0.20 и новее): файл прошивки работает и без модуля."

svc_state() {
	getprop "init.svc.$SVC"
}

svc_pid() {
	getprop "init.svc_debug_pid.$SVC"
}

# PID родителя этого скрипта. ksud запускает скрипт своим потомком
# (module.rs exec_script_with); 1 — ksud уже вышел, init продолжает загрузку.
parent_pid() {
	_ps=$(cat "$TP_ROOT/proc/$$/stat" 2>/dev/null)
	_ps=${_ps##*) }
	set -- $_ps
	echo "${2:-}"
}

# Android уже запускается: перезапуск сервиса питания небезопасен.
android_started() {
	[ -n "$KSU_LATE_LOAD" ] && return 0
	[ "$(getprop sys.boot_completed)" = 1 ] && return 0
	case "$(getprop init.svc.zygote)" in
	running | restarting) return 0 ;;
	esac
	[ "$(parent_pid)" = 1 ] && return 0
	return 1
}

check_rom() {
	REASON=""
	DETAIL=""
	if [ ! -f "$HALBIN" ] || [ -z "$(svc_state)" ]; then
		REASON=no_lineage_hal
		return 1
	fi
	_c=$(getprop vendor.powerhal.config)
	case "$_c" in
	'' | powerhint.json) ;;
	*)
		REASON=config_prop
		DETAIL="vendor.powerhal.config=$_c"
		return 1
		;;
	esac
	_d=$(getprop vendor.powerhal.config.debug)
	case "$_d" in
	1 | y | yes | on | true)
		REASON=config_prop
		DETAIL="vendor.powerhal.config.debug=$_d"
		return 1
		;;
	esac
	return 0
}

is_bound() {
	awk -v t="$TARGET" '$5 == t { f = 1 } END { exit !f }' "$TP_ROOT/proc/self/mountinfo" 2>/dev/null
}

# Что привязано поверх /vendor/etc/powerhint.json: поле root (4) mountinfo
# последней привязки, например /adb/modules/taoyao_powerhint612/powerhint.json
# (с //deleted, если файл модуля заменён обновлением).
bound_root() {
	awk -v t="$TARGET" '$5 == t { r = $4 } END { print r }' "$TP_ROOT/proc/self/mountinfo" 2>/dev/null
}

file_sha() {
	sha256sum "$1" 2>/dev/null | cut -d' ' -f1
}

orig_sha() {
	file_sha "$TARGET"
}

get_label() {
	_l=$(stat -c %C "$1" 2>/dev/null)
	case "$_l" in
	u:object_r:*) echo "$_l" ;;
	*) echo "$DEF_LABEL" ;;
	esac
}

known_input() {
	case "$1" in
	'' | *[!0-9a-f]*) return 1 ;;
	esac
	[ ${#1} -eq 64 ] || return 1
	grep -q "^$1 " "$MODDIR/known-inputs.txt" 2>/dev/null
}

payload_ok() {
	_exp=$(cut -d' ' -f1 "$MODDIR/powerhint.json.sha256" 2>/dev/null)
	_got=$(file_sha "$MODDIR/powerhint.json")
	[ -n "$_exp" ] && [ "$_exp" = "$_got" ]
}

# guards.txt: "<операция> <путь> [<аргумент>]", операции exists, has, first,
# ge, eq.
check_guards() {
	REASON=""
	DETAIL=""
	[ -r "$MODDIR/guards.txt" ] || { REASON=bad_payload; DETAIL=guards.txt; return 1; }
	while read -r _op _p _a; do
		case "$_op" in
		'' | '#'*) continue ;;
		esac
		_f=$TP_ROOT$_p
		if [ ! -e "$_f" ]; then
			REASON=missing_node
			DETAIL=$_p
			return 1
		fi
		case "$_op" in
		exists) ;;
		has)
			_v=$(cat "$_f" 2>/dev/null)
			case " $(echo $_v) " in
			*" $_a "*) ;;
			*)
				REASON=table_mismatch
				DETAIL="$_p:$_a"
				return 1
				;;
			esac
			;;
		first)
			_v=$(cat "$_f" 2>/dev/null)
			_v=$(echo $_v)
			if [ "${_v%% *}" != "$_a" ]; then
				REASON=table_mismatch
				DETAIL="$_p:${_v%% *}!=$_a"
				return 1
			fi
			;;
		ge)
			_v=$(cat "$_f" 2>/dev/null)
			case "$_v" in
			'' | *[!0-9]*) _v=-1 ;;
			esac
			if [ "$_v" -lt "$_a" ]; then
				REASON=table_mismatch
				DETAIL="$_p:$_v<$_a"
				return 1
			fi
			;;
		eq)
			_v=$(cat "$_f" 2>/dev/null)
			if [ "$_v" != "$_a" ]; then
				REASON=table_mismatch
				DETAIL="$_p:$_v!=$_a"
				return 1
			fi
			;;
		*)
			REASON=bad_payload
			DETAIL="guards.txt: $_op"
			return 1
			;;
		esac
	done < "$MODDIR/guards.txt"
	return 0
}

expect_get() {
	sed -n "s/^$1=//p" "$MODDIR/expect.txt" 2>/dev/null | head -n 1
}

# wait_state СОСТОЯНИЕ N: опрос раз в 100 мс, не больше N раз.
wait_state() {
	_i=0
	while :; do
		[ "$(svc_state)" = "$1" ] && return 0
		[ "$_i" -ge "$2" ] && return 1
		budget_left || return 1
		_i=$((_i + 1))
		nap
	done
}

# 0: перезапущен; 1: init не обработал ctl во время этапа загрузки, команды
# stop и start стоят в очереди; 2: не запустился; 3: упал сразу после запуска.
hal_restart() {
	setprop ctl.stop "$SVC"
	if wait_state stopped 30; then
		setprop ctl.start "$SVC"
		_i=0
		while :; do
			case "$(svc_state)" in
			running) return 0 ;;
			restarting) return 3 ;;
			esac
			[ "$_i" -ge 30 ] && return 2
			budget_left || return 2
			_i=$((_i + 1))
			nap
		done
	fi
	setprop ctl.start "$SVC"
	return 1
}

hal_log_all() {
	timeout 3 logcat -d -b all -v threadtime -s libperfmgr powerhal-libperfmgr 2> /dev/null
}

hal_log() {
	hal_log_all | awk -v p="$1" '$3 == p'
}

parse_counts() {
	NODES=$(printf '%s\n' "$1" | sed -n 's/.*[: ]\([0-9][0-9]*\) Nodes parsed successfully.*/\1/p' | tail -n 1)
	ACTIONS=$(printf '%s\n' "$1" | sed -n 's/.*[: ]\([0-9][0-9]*\) actions parsed successfully.*/\1/p' | tail -n 1)
	OLDWARN=$(printf '%s\n' "$1" | grep -c 'old node path format detected')
}

# state/attempt "<boot_id> <n>": подмена с перезапуском сервиса выполнена, а
# итога проверки (OK, WARN, FAILED) ещё нет; n — сколько таких загрузок подряд.
verdict_done() {
	rm -f "$STATE/attempt"
}

mark_failed() {
	touch "$MODDIR/disable"
	echo "$1 $BOOTID $(date '+%F %T')" > "$STATE/failed"
	rm -f "$STATE/applied" "$STATE/pending"
	verdict_done
}

rollback() {
	_rb=$1
	log "откат: $_rb (состояние $(svc_state), pid $(svc_pid))"
	if is_bound; then
		umount -l "$TARGET" 2>/dev/null || umount "$TARGET" 2>/dev/null
	fi
	hal_restart
	_hrc=$?
	PID_AFTER=$(svc_pid)
	log "перезапуск с файлом прошивки: код $_hrc, состояние $(svc_state), pid $PID_AFTER"
	mark_failed "$_rb"
	set_status FAILED "$_rb" "Сбой: $(reason_text "$_rb"). Подмена снята, сервис питания перезапущен с файлом прошивки, модуль выключен. Чтобы попробовать снова, переустановите модуль."
}

# Сервис уже работает с файлом прошивки: снять подмену без перезапуска.
fail_unbind() {
	_rb=$1
	log "снятие подмены без перезапуска: $_rb"
	if is_bound; then
		umount -l "$TARGET" 2>/dev/null || umount "$TARGET" 2>/dev/null
	fi
	mark_failed "$_rb"
	set_status FAILED "$_rb" "Сбой: $(reason_text "$_rb"). Подмена снята, модуль выключен; сервис питания работает с файлом прошивки. Чтобы попробовать снова, переустановите модуль."
}
