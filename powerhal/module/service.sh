# taoyao_powerhint612: проверка после загрузки. Не блокирует загрузку
# (ksud запускает этап service без ожидания: init_event.rs:212).
# Разработчики: Meddax и MeruDevTools. Связь: i@meru-ii.ru
MODDIR=${0%/*}
TP_STAGE=service
. "$MODDIR/lib.sh"

# 1. Только если post-mount этой загрузки подменил файл. Если он ещё работает
# (ksud перестаёт ждать скрипты через 35 с), ждём его итога до 30 с.
_w=0
while [ ! -f "$STATE/applied" ] && [ ! -f "$STATE/pending" ] && [ ! -f "$STATE/failed" ] && [ "$_w" -lt 30 ]; do
	_ab=""
	[ -f "$STATE/attempt" ] && read -r _ab _an < "$STATE/attempt"
	[ "$_ab" = "$BOOTID" ] || break
	[ "$_w" -eq 0 ] && log "post-mount ещё работает, жду"
	sleep 1
	_w=$((_w + 1))
done
if [ -f "$STATE/applied" ]; then
	_mode=applied
	_f=$STATE/applied
elif [ -f "$STATE/pending" ]; then
	_mode=pending
	_f=$STATE/pending
else
	exit 0
fi
read -r _fb _fp < "$_f"
[ "$_fb" = "$BOOTID" ] || exit 0

ORIG_SHA=$(st_get orig_sha256)
ORIG_LABEL=$(st_get orig_label)
NEW_SHA=$(st_get new_sha256)
PID_BEFORE=$(st_get hal_pid_before)
PID_AFTER=$(st_get hal_pid_after)
NODES=$(st_get nodes_parsed)
ACTIONS=$(st_get actions_parsed)
OLDWARN=$(st_get old_path_warnings)
VERIFIED=$(st_get verified)
_en=$(expect_get nodes)
_ea=$(expect_get actions)
log "проверка после загрузки ($_mode)"

# 2. Ждём конца загрузки: 3 минуты опроса раз в 2 с, затем до 30 минут раз в
# 10 с (первая загрузка после очистки данных бывает долгой). NodeLooper и
# все записи в узлы начинаются только по vendor.powerhal.init, то есть по
# sys.boot_completed=1 (init.target.rc:176-178, service.cpp:77-79). Если
# сервис падает, отвергнув файл (Invalid config), — откат сразу.
_i=0
while [ "$(getprop sys.boot_completed)" != 1 ] && [ "$_i" -lt 270 ]; do
	if [ "$(svc_state)" = restarting ]; then
		case "$(hal_log_all)" in
		*"Invalid config"*)
			rollback invalid_config
			exit 0
			;;
		esac
	fi
	if [ "$_i" -lt 90 ]; then
		sleep 2
	else
		sleep 10
	fi
	_i=$((_i + 1))
done
if [ "$(getprop sys.boot_completed)" != 1 ]; then
	# Итога нет: state/attempt остаётся, следующая загрузка его учтёт.
	set_status WARN boot_not_completed "Загрузка Android не завершилась за 33 минуты: сервис питания ещё не писал в узлы, проверка не выполнена."
	exit 0
fi
sleep 15

# 3. Сервис жив?
case "$(svc_state)" in
stopped)
	rollback hal_stopped
	exit 0
	;;
restarting)
	rollback hal_crash
	exit 0
	;;
esac
_P=$(svc_pid)
sleep 10
_restarts=0
_P2=$(svc_pid)
if [ "$_P2" != "$_P" ]; then
	case "$(hal_log_all)" in
	*"Invalid config"*)
		rollback invalid_config
		exit 0
		;;
	esac
	sleep 10
	_P3=$(svc_pid)
	if [ "$_P3" != "$_P2" ]; then
		rollback hal_crash_loop
		exit 0
	fi
	# Один перезапуск допустим (правило прошивки перезапускает сервис при
	# перезапуске zygote: android.hardware.power-service.lineage-libperfmgr.rc:15-19).
	# Откат — только если журнал нового процесса есть и числа не те.
	_sn=$NODES
	_sa=$ACTIONS
	_so=$OLDWARN
	parse_counts "$(hal_log "$_P2")"
	if [ -n "$NODES$ACTIONS" ]; then
		if [ "$NODES" != "$_en" ] || [ "$ACTIONS" != "$_ea" ]; then
			rollback hal_crash
			exit 0
		fi
		VERIFIED=log
	else
		NODES=$_sn
		ACTIONS=$_sa
		OLDWARN=$_so
		VERIFIED=state
	fi
	_restarts=1
	_P=$_P2
fi
PID_AFTER=$_P

# Отложенный перезапуск: новый процесс должен был прочитать файл модуля.
if [ "$_mode" = pending ]; then
	if [ -z "$_P" ] || [ "$_P" = "$_fp" ]; then
		fail_unbind not_restarted
		exit 0
	fi
	_L=$(hal_log "$_P")
	printf '%s\n' "$_L" > "$STATE/hal-start.log"
	parse_counts "$_L"
	if [ -n "$NODES" ]; then
		{ read -r _on _oa < "$STATE/orig.counts"; } 2>/dev/null
		if [ "$NODES" = "$_en" ] && [ "$ACTIONS" = "$_ea" ]; then
			VERIFIED=log
		elif [ "$NODES" = "$_on" ] && [ "$ACTIONS" = "$_oa" ]; then
			fail_unbind not_seen
			exit 0
		else
			rollback unexpected_counts
			exit 0
		fi
	else
		VERIFIED=state
	fi
fi

case "$(hal_log_all)" in
*"Invalid config"*)
	rollback invalid_config
	exit 0
	;;
esac

if ! is_bound; then
	verdict_done
	set_status WARN unmounted "Подмену кто-то снял; сервис работает с ранее прочитанным файлом." "restarts=$_restarts"
	exit 0
fi

# Ошибки записи в узлы.
hal_log "$_P" | sed -n 's/.*Failed to write to node: \([^ ]*\) with value.*/\1/p' | LC_ALL=C sort -u > "$STATE/write-fail.txt"
WFAIL=$(grep -c . "$STATE/write-fail.txt")
WPATHS=$(tr '\n' ' ' < "$STATE/write-fail.txt" | sed 's/ $//')
verdict_done
if [ "$WFAIL" -gt 0 ]; then
	set_status WARN write_failures "Работает, но сервис не может записать: $WPATHS. Пришлите status.txt." "restarts=$_restarts"
	exit 0
fi
set_status OK ok "Работает: сервис питания использует powerhint.json для 6.12, ошибок записи нет." "restarts=$_restarts"
exit 0
