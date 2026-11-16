# taoyao_powerhint612: подмена /vendor/etc/powerhint.json и перезапуск сервиса
# питания. Выполняется ksud на этапе post-mount, до запуска Android; этап
# блокирует загрузку, поэтому скрипт короткий (не больше 35 пауз по 100 мс).
# Разработчики: Meddax и MeruDevTools. Связь: i@meru-ii.ru
MODDIR=${0%/*}
TP_STAGE=post-mount
. "$MODDIR/lib.sh"

mkdir -p "$STATE"
[ -f "$STATE/boot.log" ] && mv -f "$STATE/boot.log" "$STATE/boot.prev.log"
rm -f "$STATE/applied" "$STATE/pending"
log "старт: ядро $(uname -r), boot_id $BOOTID"

inert() {
	_im=$2
	# (ядро 0.20 и новее: файл прошивки работает и без модуля)
	check_kernel && kernel_compat && _im="$_im $KC_NOTE"
	set_status INERT "$1" "$_im"
	exit 0
}

# 2. Модуль уже выключал себя после сбоя: ничего не делать до переустановки.
if [ -f "$STATE/failed" ]; then
	read -r _frs _fbid _fdate < "$STATE/failed"
	set_status BLOCKED "${_frs:-unknown}" "Модуль остановлен после сбоя ($(reason_text "${_frs:-unknown}"), ${_fdate:-дата неизвестна}). Переустановите модуль, чтобы попробовать снова."
	exit 0
fi

# 2a. Прошлые загрузки: подмена была, а итога проверки нет (сбой ядра,
# зависание или перезагрузка раньше, чем service.sh успел проверить). Одну
# такую загрузку прощаем (обычная перезагрузка), после второй подряд — стоп.
_ab=""
_an=0
[ -f "$STATE/attempt" ] && read -r _ab _an < "$STATE/attempt"
case "$_an" in
'' | *[!0-9]*) _an=0 ;;
esac
if [ -n "$_ab" ] && [ "$_ab" != "$BOOTID" ]; then
	log "загрузка $_ab закончилась без итога проверки (подряд: $_an)"
	if [ "$_an" -ge 2 ]; then
		mark_failed unverified_boot
		set_status FAILED unverified_boot "Сбой: $(reason_text unverified_boot). Файл прошивки не подменялся, модуль выключен. Чтобы попробовать снова, переустановите модуль."
		exit 0
	fi
	_next=$((_an + 1))
else
	_next=$_an
	[ "$_next" -ge 1 ] || _next=1
fi

# 3. Только до запуска Android.
android_started && inert late_stage "Скрипт запущен после старта Android: перезапуск сервиса питания сейчас небезопасен, модуль ничего не делает."

# 4-7. Наше ядро, наша прошивка, сервис работает, файл ещё не подменён.
check_kernel || inert not_our_kernel "Ядро не taoyao 6.12 ($(uname -r)): модуль ничего не делает."
if ! check_rom; then
	if [ "$REASON" = config_prop ]; then
		inert config_prop "Задано $DETAIL: сервис читает другой файл, модуль ничего не трогает."
	fi
	inert no_lineage_hal "В прошивке нет lineage-libperfmgr (например, HyperOS): модуль ничего не делает."
fi
_s=$(svc_state)
[ "$_s" = running ] || inert hal_not_running "Сервис питания не запущен (${_s:-нет состояния}): модуль ничего не трогает."

# 7a. Подмена уже есть. Своя — значит, мягкая перезагрузка SukiSU: boot_id и
# привязки сохраняются, этап post-fs-data выполняется снова, Android
# остановлен (soft_reboot.rs:151-217). Чужая — ничего не трогаем.
if is_bound; then
	_br=$(bound_root)
	case "$_br" in
	*/taoyao_powerhint612/powerhint.json)
		_ob=""
		[ -f "$STATE/orig.sha256" ] && read -r _ob ORIG_SHA ORIG_LABEL < "$STATE/orig.sha256"
		if [ "$_ob" = "$BOOTID" ] && payload_ok && cmp -s "$MODDIR/powerhint.json" "$TARGET"; then
			NEW_SHA=$(file_sha "$MODDIR/powerhint.json")
			PID_BEFORE=$(svc_pid)
			PID_AFTER=$PID_BEFORE
			VERIFIED=kept
			log "мягкая перезагрузка: подмена на месте, сервис pid $PID_AFTER"
			echo "$BOOTID $PID_AFTER" > "$STATE/applied"
			set_status APPLIED kept "Мягкая перезагрузка: подмена с прошлого запуска на месте, сервис питания работает с powerhint.json для 6.12."
			exit 0
		fi
		;;
	esac
	case "$_br" in
	*/taoyao_powerhint612/powerhint.json | */taoyao_powerhint612/powerhint.json//deleted)
		# Старая версия файла модуля (обновление и мягкая перезагрузка):
		# снять и подменить заново.
		log "старая подмена этого модуля ($_br): снимаю"
		umount -l "$TARGET" 2>/dev/null || umount "$TARGET" 2>/dev/null
		is_bound && inert already_mounted "/vendor/etc/powerhint.json подменён старой версией модуля, снять подмену не удалось: модуль ничего не трогает. Перезагрузите телефон."
		;;
	*)
		inert already_mounted "/vendor/etc/powerhint.json уже подменён другим модулем (${_br:-?}): модуль ничего не трогает."
		;;
	esac
fi

# 8. Исходный файл: sha256, метка SELinux, число узлов и действий.
ORIG_SHA=$(orig_sha)
ORIG_LABEL=$(get_label "$TARGET")
ORIG_NODES=$(grep -c '"Name"' "$TARGET" 2>/dev/null)
ORIG_ACTIONS=$(grep -c '"PowerHint"' "$TARGET" 2>/dev/null)
echo "$BOOTID $ORIG_SHA $ORIG_LABEL" > "$STATE/orig.sha256"
echo "$ORIG_NODES $ORIG_ACTIONS" > "$STATE/orig.counts"
log "исходный файл: sha256 $ORIG_SHA, метка $ORIG_LABEL, узлов $ORIG_NODES, действий $ORIG_ACTIONS"

# 9-11. Известный файл прошивки, целый файл модуля, нужные узлы ядра.
known_input "$ORIG_SHA" || inert unknown_input "Неизвестная версия /vendor/etc/powerhint.json (sha256 ${ORIG_SHA:-не прочитан}). Нужна новая версия модуля."
payload_ok || inert bad_payload "Файл модуля повреждён. Переустановите модуль."
NEW_SHA=$(file_sha "$MODDIR/powerhint.json")
check_guards || inert "$REASON" "Нет узла или другая таблица частот: $DETAIL. Модуль ничего не трогает."

# 12. Владелец, права и метка SELinux как у файла прошивки.
chown 0:0 "$MODDIR/powerhint.json"
chmod 0644 "$MODDIR/powerhint.json"
chcon "$ORIG_LABEL" "$MODDIR/powerhint.json"
[ "$(stat -c %C "$MODDIR/powerhint.json" 2>/dev/null)" = "$ORIG_LABEL" ] || inert label_failed "Не удалось поставить метку SELinux: подмена не выполнена."

# 13. Подмена. ksud ждёт скрипты этапа не дольше 35 с на все модули
# (init_event.rs:42, module.rs:357-364), поэтому старт Android проверяется
# снова перед подменой и перед перезапуском.
android_started && inert late_stage "Android начал запускаться во время работы скрипта: подмена не выполнена."
mount -o bind "$MODDIR/powerhint.json" "$TARGET"
if ! is_bound || ! cmp -s "$MODDIR/powerhint.json" "$TARGET" || [ "$(stat -c %C "$TARGET" 2>/dev/null)" != "$ORIG_LABEL" ]; then
	is_bound && umount -l "$TARGET"
	inert mount_failed "Не удалось подменить файл: подмена не выполнена."
fi
log "файл подменён"
if android_started; then
	umount -l "$TARGET" 2>/dev/null || umount "$TARGET" 2>/dev/null
	inert late_stage "Android начал запускаться во время работы скрипта: подмена снята, сервис питания не перезапускался."
fi

# 14-15. Перезапуск сервиса питания: он читает файл только при запуске.
echo "$BOOTID $_next" > "$STATE/attempt"
PID_BEFORE=$(svc_pid)
hal_restart
_rc=$?
log "перезапуск: код $_rc, состояние $(svc_state), pid $(svc_pid), было $PID_BEFORE"
case "$_rc" in
1)
	echo "$BOOTID $PID_BEFORE" > "$STATE/pending"
	set_status PENDING restart_deferred "Файл подменён, перезапуск сервиса питания выполнится сразу после этого этапа загрузки; проверка — после загрузки."
	exit 0
	;;
2)
	rollback hal_no_start
	exit 0
	;;
3)
	case "$(hal_log_all)" in
	*"Invalid config"*) rollback invalid_config ;;
	*) rollback hal_crash ;;
	esac
	exit 0
	;;
esac
PID_AFTER=$(svc_pid)
if [ -z "$PID_AFTER" ] || [ "$PID_AFTER" = "$PID_BEFORE" ]; then
	rollback no_new_pid
	exit 0
fi

# 16. Журнал нового процесса: опрос раз в 100 мс, от 3 до 20 раз и не
# дольше 6 секунд (если logcat отвечает медленно).
_n=0
_L=""
_t0=$(date +%s)
while :; do
	_n=$((_n + 1))
	_s=$(svc_state)
	_p=$(svc_pid)
	if [ "$_s" != running ] || [ "$_p" != "$PID_AFTER" ]; then
		case "$(hal_log_all)" in
		*"Invalid config"*) rollback invalid_config ;;
		*) rollback hal_crash ;;
		esac
		exit 0
	fi
	_L=$(hal_log "$PID_AFTER")
	case "$_L" in
	*"Invalid config"*)
		rollback invalid_config
		exit 0
		;;
	*"Initialized HintManager from JSON config: $HAL_CONFIG"*)
		[ "$_n" -ge 3 ] && break
		;;
	esac
	[ "$_n" -ge 20 ] && break
	[ $(($(date +%s) - _t0)) -ge 6 ] && break
	budget_left || break
	nap
done
printf '%s\n' "$_L" > "$STATE/hal-start.log"

# 17. Сколько узлов и действий прочитал сервис.
parse_counts "$_L"
_en=$(expect_get nodes)
_ea=$(expect_get actions)
if [ -n "$NODES" ] && [ "$NODES" = "$ORIG_NODES" ] && [ "$ACTIONS" = "$ORIG_ACTIONS" ] && [ "$NODES" != "$_en" ]; then
	fail_unbind not_seen
	exit 0
fi
if [ -n "$NODES" ] || [ -n "$ACTIONS" ]; then
	if [ "$NODES" != "$_en" ] || [ "$ACTIONS" != "$_ea" ]; then
		rollback unexpected_counts
		exit 0
	fi
	VERIFIED=log
else
	VERIFIED=state
fi
echo "$BOOTID $PID_AFTER" > "$STATE/applied"
set_status APPLIED ok "Подменено: сервис питания перезапущен с powerhint.json для 6.12 ($(ru_num "${_en:-0}" узел узла узлов), $(ru_num "${_ea:-0}" действие действия действий))."
exit 0
