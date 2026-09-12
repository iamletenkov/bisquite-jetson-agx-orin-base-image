#!/bin/bash
# Шаг 8: сборка БАЗОВОГО образа диска (qcow2) из подготовленного дерева BSP.
#
#     sudo /opt/nvidia-jetpack/08-build-base-image.sh
#
# Что это и зачем.
#
# У NVIDIA нет базового образа Jetson в виде qcow2 — того, чем для amd64
# служит готовый cloud-образ Debian/Ubuntu. Есть только BSP и sample rootfs,
# из которых образ надо собрать. Этот шаг собирает его один раз на версию
# L4T, дальше поверх него кладут прикладные слои (bisquite VMFILE) и пишут
# результат на носители флота.
#
# ПЛАТА НЕ НУЖНА, и это не удача, а свойство инструмента: в отличие от шага 05,
# jetson-disk-image-creator.sh передаёт BOARDID/BOARDSKU/FAB переменными
# окружения и ставит BUILD_SD_IMAGE=1, поэтому flash.sh не читает EEPROM
# модуля. Проверено по его коду (create_signed_images).
#
# Но данные модуля знать всё равно надо, и одно из них creator НЕ заполняет:
# для jetson-agx-orin-devkit у него зашит только boardid=3701, а boardsku
# пуст, и flash.sh отказывает с `Error: Unrecognized module SKU`. Обходится
# патчем копии creator'а — см. BOARD_SKU и шаг 3.
#
# Почему не system.img из шага 05: это образ ОДНОГО раздела APP, без GPT и без
# служебных разделов. С него нельзя загрузиться и его нельзя записать на диск
# как есть.

set -uo pipefail

WORK="${WORK:-/srv/jetson}"
LFT="$WORK/Linux_for_Tegra"
BOARD_TARGET="${BOARD_TARGET:-jetson-agx-orin-devkit}"

# Ревизия в терминах creator'а. Для AGX Orin единственное принимаемое
# значение — `default` (список печатает его usage), и оно уезжает в
# flash.sh как FAB=. Передашь число — creator отвергнет аргументы и
# напечатает usage.
BOARD_REVISION="${BOARD_REVISION:-default}"

# SKU МОДУЛЯ — то, без чего flash.sh отказывает с
#   Error: Unrecognized module SKU
# причём SKU там ПУСТОЙ, а не неизвестный: сообщение вводит в заблуждение
# точно так же, как на шаге 05 без платы.
#
# Это дефект creator'а: в его ветке `jetson-agx-orin-devkit` заполнен
# только boardid=3701, а boardsku не заполнен вовсе — хотя у соседнего
# orin-nano рядом стоит boardsku="0005". Обходим патчем копии, см. шаг 3.
#
# Замерено 2026-09-11 на AGX Orin Developer Kit: с BOARDSKU=0000 сборка
# идёт и при FAB=default, то есть лечит дело именно SKU, а не FAB —
# проверено раздельно, обе комбинации прогнаны.
#
# Откуда взять значение для другого модуля: его печатает любой прогон
# flash.sh с подключённой платой (шаг 05) строкой
#   Board ID(3701) version(500) sku(0000) revision(J.0)
BOARD_SKU="${BOARD_SKU:-0000}"
# У creator'а есть только SD и USB; ветки под NVMe нет вовсе. Выбор влияет на
# то, какое имя устройства он впишет в root= (USB -> /dev/sda1), а мы это
# значение всё равно заменяем на PARTUUID — см. шаг 4 ниже.
ROOTFS_DEV="${ROOTFS_DEV:-USB}"
OUT_RAW="${OUT_RAW:-$WORK/jetson-orin-base.img}"
OUT_QCOW2="${OUT_QCOW2:-$WORK/jetson-orin-base.qcow2}"
MIN_FREE_GIB="${MIN_FREE_GIB:-30}"

CREATOR="$LFT/tools/jetson-disk-image-creator.sh"

step() { echo; echo "=== $* ==="; }
fail() { echo; echo "ОТКАЗ: $*"; exit 1; }

# ГРАБЛЯ, та же что в 03 и 05: TMPDIR оператора утекает внутрь chroot, которого
# по этому пути там нет, и mktemp в постустановочных сценариях падает.
# Чистим точечно, без env -i: скрипты L4T проверяют $USER и на пустом окружении
# ломаются раньше, чем помогают.
unset TMPDIR || true
export USER="${USER:-$(id -un)}"

[ "$(id -u)" -eq 0 ] || fail "нужен root (sudo bash $0)"

step "1. Предпосылки хоста"

# Архитектура. На aarch64 подготовка rootfs и apt идут НАТИВНО — без qemu, без
# binfmt и без граблей эмуляции (см. шаг 04). На amd64 собрать тоже можно, но
# только если эмуляция уже настроена, поэтому там предупреждение, а не отказ:
# дерево к этому шагу уже подготовлено, и chroot здесь больше не нужен.
HOST_ARCH=$(uname -m)
case "$HOST_ARCH" in
    aarch64)
        echo "архитектура : $HOST_ARCH (нативно, эмуляция не нужна)"
        ;;
    x86_64)
        echo "архитектура : $HOST_ARCH"
        echo "  ПРЕДУПРЕЖДЕНИЕ: дерево BSP должно быть подготовлено заранее"
        echo "  (шаги 03-04 под qemu). Сам этот шаг chroot в гостя не делает."
        ;;
    *)
        fail "непонятная архитектура хоста: $HOST_ARCH"
        ;;
esac

# Дистрибутив. Требование жёсткое, и оно не про вкус:
#   1. recovery_copy_binlist.txt фильтрует список копируемых бинарей буквально
#      как grep -E "^(jammy|all)" — на другом кодовом имени часть файлов
#      не попадёт в recovery.img;
#   2. ota_make_recovery_img_dtb.sh зовёт `ssh-keygen -t dsa`, а OpenSSH
#      выбросил DSA в 9.8. На jammy стоит 8.9 и вызов проходит.
# Отказ громкий и в первую минуту: на новее recovery.img не собирается, а
# сообщает об этом ПУСТАЯ строка "command is failed" — check_error вызван без
# аргумента, вывод погашен в /dev/null. Это стоило целого дня 2026-09-10.
CODENAME=$(. /etc/os-release 2>/dev/null && echo "${VERSION_CODENAME:-}")
if [ "$CODENAME" != "jammy" ]; then
    echo "дистрибутив : ${CODENAME:-неизвестен}"
    fail "нужен Ubuntu 22.04 (jammy). См. комментарий выше о binlist и DSA."
fi
echo "дистрибутив : $CODENAME"

# DSA проверяем исполнением, а не версией: сборки с вырезанным алгоритмом
# встречаются и на подходящей версии.
DSA_TMP=$(mktemp -d)
if ssh-keygen -q -t dsa -N "" -f "$DSA_TMP/k" >/dev/null 2>&1; then
    echo "ssh-keygen  : dsa поддерживается"
else
    rm -rf "$DSA_TMP"
    fail "ssh-keygen -t dsa не работает — recovery.img не соберётся"
fi
rm -rf "$DSA_TMP"

for c in qemu-img sgdisk losetup blkid; do
    command -v "$c" >/dev/null 2>&1 || fail "нет утилиты $c"
done
echo "утилиты     : qemu-img sgdisk losetup blkid на месте"

step "2. Дерево BSP"

[ -x "$CREATOR" ] || fail "нет $CREATOR — дерево BSP неполное, начни с 01-fetch-l4t.sh"
[ -d "$LFT/rootfs/etc" ] || fail "нет $LFT/rootfs — начни с 03-prepare-bsp.sh"
if [ ! -e "$LFT/rootfs/.applied-binaries" ]; then
    fail "в rootfs нет метки .applied-binaries — apply_binaries не выполнялся (шаг 03)"
fi
echo "дерево      : $LFT"
echo "метка       : $(cat "$LFT/rootfs/.applied-binaries")"
echo "rootfs      : $(du -sh "$LFT/rootfs" 2>/dev/null | cut -f1)"

FREE_GIB=$(df -BG --output=avail "$WORK" | tail -1 | tr -dc '0-9')
[ "${FREE_GIB:-0}" -ge "$MIN_FREE_GIB" ] \
    || fail "свободно ${FREE_GIB} GB, нужно минимум ${MIN_FREE_GIB}"
echo "свободно    : ${FREE_GIB} GB"

step "3. Сборка образа диска (плата НЕ нужна)"
echo "цель        : $BOARD_TARGET, ревизия $BOARD_REVISION, SKU $BOARD_SKU, устройство $ROOTFS_DEV"
echo "выход       : $OUT_RAW"

# Патчим КОПИЮ creator'а, а не оригинал: ему нужно подставить boardsku,
# которого он для AGX Orin не заполняет (см. комментарий у BOARD_SKU).
# Копия, а не правка на месте, потому что патченный оригинал в чужом дереве —
# сюрприз для того, кто придёт следом; а дерево вдобавок пересоздаётся
# распаковкой в шаге 03, и правка терялась бы молча.
#
# КОПИЯ ЛЕЖИТ В $LFT/tools/, и это обязательно: creator вычисляет путь
# к дереву ОТ СВОЕГО РАСПОЛОЖЕНИЯ (он рассчитывает быть в Linux_for_Tegra/
# tools/). Копия рядом с логами в $WORK давала
#   ERROR: /srv/flash.sh is not found
# — он принимал /srv за корень дерева. Замер 2026-09-11.
#
# Ревизия передаётся штатным ключом -r и уезжает в flash.sh как FAB=.
# SKU штатного ключа не имеет вовсе — отсюда sed по копии.
CREATOR_PATCHED="$LFT/tools/.jetson-disk-image-creator.patched.sh"
cp -f "$CREATOR" "$CREATOR_PATCHED" || fail "не скопировался creator"
# Привязка к строке с boardid именно нашей цели, а не к первой попавшейся:
# в файле есть ветки и других плат, и подставить SKU не туда значило бы
# собрать образ под чужой модуль.
python3 - "$CREATOR_PATCHED" "$BOARD_TARGET" "$BOARD_SKU" <<'PATCH' || fail "патч creator'а не применился"
import re
import sys

path, target, sku = sys.argv[1], sys.argv[2], sys.argv[3]
src = open(path, encoding="utf-8").read()

# Берём ветку case ЦЕЛИКОМ — от "<target>)" до ";;", — а не до строки
# с boardid: иначе проверка «уже пропатчено» смотрела бы во фрагмент,
# который заканчивается ДО вставленной строки, и всегда говорила «нет».
branch = re.compile(r"\t\t" + re.escape(target) + r"\)\n(?:.*?)\t\t\t;;\n", re.S)
found = branch.search(src)
if not found:
    sys.exit(f"не нашёл ветку {target} в case")
if re.search(r'boardsku="[^"]*"', found.group(0)):
    sys.exit(0)  # уже заполнен — патч не нужен

anchor = re.search(r'\t\t\tboardid="[0-9]+"\n', found.group(0))
if not anchor:
    sys.exit(f"в ветке {target} нет строки boardid")
at = found.start() + anchor.end()
open(path, "w", encoding="utf-8").write(src[:at] + f'\t\t\tboardsku="{sku}"\n' + src[at:])
PATCH
grep -A3 "^\s*${BOARD_TARGET})\$" "$CREATOR_PATCHED" | grep -q "boardsku=\"$BOARD_SKU\"" \
    || echo "  ПРЕДУПРЕЖДЕНИЕ: boardsku в копии не подтверждён — смотри вывод flash.sh ниже"
echo "creator     : $CREATOR_PATCHED (копия с подставленным boardsku)"
echo

# Размер APP creator считает сам: du -ms rootfs + 10% + 100 МБ. Поэтому образ
# выходит компактным (порядка 9-10 ГБ на нашем дереве), а не под размер
# целевого диска — расширять APP при первой загрузке будет growpart, для чего
# APP и лежит физически последним (служебные разделы идут ПЕРЕД ним, несмотря
# на то, что APP в таблице GPT числится первым).
rm -f "$OUT_RAW"
if ! "$CREATOR_PATCHED" -o "$OUT_RAW" -b "$BOARD_TARGET" -r "$BOARD_REVISION" -d "$ROOTFS_DEV"; then
    fail "jetson-disk-image-creator.sh не собрал образ"
fi
[ -s "$OUT_RAW" ] || fail "образ $OUT_RAW пуст"
echo
echo "собран      : $(stat -c%s "$OUT_RAW") байт"

step "4. root= переписывается на PARTUUID"
# Зачем. creator вписывает в extlinux.conf имя устройства (для -d USB это
# /dev/sda1). Такой образ загрузится с USB и НЕ загрузится с M.2, где корень
# называется nvme0n1p1. PARTUUID принадлежит разделу, а не шине: он переживает
# dd и одинаково верен на обоих носителях — значит ОДИН образ годится и для
# теста с USB-переходника, и для установки в слот робота.
#
# Раздел ищем по PARTLABEL=APP, а не по номеру: у creator'а своя нумерация
# (порядок записей в GPT не равен физическому порядку), и номер APP меняется
# между раскладками.
LOOP=""
MNT=""
cleanup_loop() {
    [ -n "$MNT" ] && mountpoint -q "$MNT" && umount "$MNT" 2>/dev/null
    [ -n "$MNT" ] && rmdir "$MNT" 2>/dev/null
    [ -n "$LOOP" ] && losetup -d "$LOOP" 2>/dev/null
    return 0
}
trap cleanup_loop EXIT

LOOP=$(losetup --show -f -P "$OUT_RAW") || fail "losetup не подключил образ"
udevadm settle 2>/dev/null || sleep 1

APP_PART=""
for p in "$LOOP"p*; do
    [ -b "$p" ] || continue
    if [ "$(blkid -s PARTLABEL -o value "$p" 2>/dev/null)" = "APP" ]; then
        APP_PART="$p"
        break
    fi
done
[ -n "$APP_PART" ] || fail "в образе нет раздела с PARTLABEL=APP"

APP_PARTUUID=$(blkid -s PARTUUID -o value "$APP_PART")
[ -n "$APP_PARTUUID" ] || fail "у $APP_PART нет PARTUUID"
echo "раздел APP  : $APP_PART"
echo "PARTUUID    : $APP_PARTUUID"

MNT=$(mktemp -d)
mount "$APP_PART" "$MNT" || fail "не смонтировался $APP_PART"

EXTLINUX="$MNT/boot/extlinux/extlinux.conf"
[ -f "$EXTLINUX" ] || fail "в образе нет $EXTLINUX"
echo "было        : $(grep -m1 -o 'root=[^ ]*' "$EXTLINUX")"
# Меняем и root=/dev/..., и уже стоящий root=PARTUUID=... — второй случай
# нужен для повторного прогона по тому же образу.
#
# Разделитель '#', а НЕ '|': внутри шаблона стоит альтернация, и с '|'
# в роли разделителя sed прочитал бы её как конец выражения.
sed -i -E "s#root=(/dev/[A-Za-z0-9]+|PARTUUID=[0-9a-fA-F-]+)#root=PARTUUID=$APP_PARTUUID#g" "$EXTLINUX"
echo "стало       : $(grep -m1 -o 'root=[^ ]*' "$EXTLINUX")"
grep -q "root=PARTUUID=$APP_PARTUUID" "$EXTLINUX" || fail "правка root= не применилась"

sync
umount "$MNT" && rmdir "$MNT" && MNT=""
losetup -d "$LOOP" && LOOP=""
trap - EXIT

step "5. Конвертация в qcow2"
rm -f "$OUT_QCOW2"
qemu-img convert -p -f raw -O qcow2 "$OUT_RAW" "$OUT_QCOW2" \
    || fail "qemu-img convert не справился"
echo
qemu-img info "$OUT_QCOW2" | sed 's/^/  /'

step "6. Что получилось"
echo "raw         : $OUT_RAW ($(stat -c%s "$OUT_RAW") байт)"
echo "qcow2       : $OUT_QCOW2 ($(stat -c%s "$OUT_QCOW2") байт)"
echo "PARTUUID    : $APP_PARTUUID"
echo
echo "разделы в образе:"
sgdisk -p "$OUT_RAW" 2>/dev/null | tail -n +8 | sed 's/^/  /'

step "ГОТОВО"
cat <<HINT
Базовый образ собран. Дальше — в хранилище bisquite:

  bs image import $OUT_QCOW2 --tag jetson-orin-base:36.4.3

и поверх него обычный VMFILE:

  FROM jetson-orin-base:36.4.3
  LABEL arch=arm64

Проверить образ до записи:
  virt-inspector -a $OUT_QCOW2 | head -40
HINT
