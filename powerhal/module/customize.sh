# taoyao_powerhint612: проверки при установке. Подключается установщиком
# KernelSU (installer.sh) после распаковки архива в $MODPATH.
# Разработчики: Meddax и MeruDevTools. Связь: i@meru-ii.ru
MODDIR=$MODPATH
TP_STAGE=customize
. "$MODPATH/lib.sh"

[ "$KSU" = true ] || abort "! Нужен KernelSU (SukiSU-Ultra)."
[ "$BOOTMODE" = true ] || abort "! Устанавливайте из приложения SukiSU, не из рекавери."
check_kernel || abort "! Ядро не taoyao 6.12 ($(uname -r)). Модуль не нужен."
# Ядро 0.20 и новее (perf_compat): файл прошивки работает и без модуля, но
# частоты вне таблиц ядра понимает не так, как 5.4. Модуль ставится так же,
# как на 0.19, со всеми проверками.
kernel_compat && ui_print "- $KC_INFO"
if ! check_rom; then
	[ "$REASON" = config_prop ] && abort "! Задано $DETAIL: сервис питания читает другой файл. Модуль не нужен."
	abort "! Прошивка без сервиса питания lineage-libperfmgr (например, HyperOS). Модуль не нужен."
fi
payload_ok || abort "! Архив повреждён: sha256 powerhint.json не совпадает."
NEW_SHA=$(file_sha "$MODPATH/powerhint.json")

# Исходный файл прошивки. Если он уже подменён прежней версией модуля, его
# sha256 и метку записал post-mount.sh этой загрузки до подмены.
_sha=$(orig_sha)
if is_bound || [ "$_sha" = "$NEW_SHA" ]; then
	_live=$NVBASE/modules/$MODID/state/orig.sha256
	_ob=""
	_os=""
	_ol=""
	[ -f "$_live" ] && read -r _ob _os _ol < "$_live"
	[ -n "$_ob" ] && [ "$_ob" = "$BOOTID" ] || abort "! Перезагрузите телефон и установите модуль снова."
	_sha=$_os
	_label=$_ol
else
	_label=$(get_label "$TARGET")
fi
ui_print "- Исходный powerhint.json: sha256 $_sha"
known_input "$_sha" || abort "! Неизвестная версия /vendor/etc/powerhint.json (sha256 $_sha). Модуль рассчитан только на Evolution X 16 и crDroid 16. Пришлите этот sha256 разработчикам: i@meru-ii.ru"
check_guards || abort "! В ядре нет нужного узла или таблица частот другая: $DETAIL"
set_perm "$MODPATH/powerhint.json" 0 0 0644 "${_label:-$DEF_LABEL}" || abort "! Не удалось поставить метку SELinux."
ui_print "- Готово. Перезагрузите телефон. Итог проверки: /data/adb/modules/taoyao_powerhint612/status.txt"
