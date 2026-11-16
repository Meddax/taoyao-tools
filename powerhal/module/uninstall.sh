# taoyao_powerhint612: удаление. ksud выполняет его на этапе post-fs-data
# следующей загрузки, до скриптов этапов; подмены тогда обычно уже нет.
# Разработчики: Meddax и MeruDevTools. Связь: i@meru-ii.ru
MODDIR=${0%/*}
TP_STAGE=uninstall
. "$MODDIR/lib.sh"
is_bound && umount -l "$TARGET"
exit 0
