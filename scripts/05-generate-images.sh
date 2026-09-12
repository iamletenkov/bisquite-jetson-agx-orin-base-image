#!/bin/bash
# Шаг 5: генерация образов БЕЗ записи на плату (--no-flash).
#
#     sudo /opt/nvidia-jetpack/05-generate-images.sh
#
# Разделение «сначала собрать, потом залить» — не удобство, а способ дёшево
# платить за ошибку: генерация занимает 15-40 минут и ничего не пишет на
# плату, заливка (06) занимает 20-40 минут и необратима. Пересобрать образы
# можно сколько угодно раз, отменить запись в QSPI нельзя.
#
# ПЛАТА ВСЁ РАВНО ДОЛЖНА БЫТЬ В RECOVERY (APX, 0955:7023), хотя запись
# и не выполняется. Причина: flash.sh заполняет BOARDID/BOARDSKU/FAB/BOARDREV
# чтением EEPROM модуля и делает это ТОЛЬКО когда плата доступна. Без платы
# поля остаются пустыми, и конфиг модуля отвечает
#     Error: Unrecognized module SKU
# — с ПУСТЫМ sku, а не с неизвестным. Отсюда и берётся это сообщение, которое
# на первый взгляд выглядит как «неподдерживаемая плата».
#
# ⚠ НЕ ЗАПУСКАЙ flash.sh НАПРЯМУЮ В ЭТОМ РАБОЧЕМ КАТАЛОГЕ.
# Он перезаписывает промежуточные артефакты (подписанные dtb в bootloader/),
# после чего l4t_initrd_flash.sh падает на
#     Unexpected error in updating: ..._with_odm.dtb
# Проверено 2026-09-09. Чинится только удалением $LFT и повторным 03.
#
# Работаем НАТИВНО на станции (Ubuntu 22.04). Никакого chroot: ради ухода
# от него станция и строилась.

set -uo pipefail

WORK="${WORK:-/srv/jetson}"
LFT="$WORK/Linux_for_Tegra"
LOG="$WORK/05-generate.log"

# Размер APP-раздела на внешнем носителе.
#
# Вынесено в переменную намеренно. Значение 40GiB перенесено с прошлых
# попыток, а дефолтная конфигурация L4T рассчитана на носитель >=64 ГБ;
# на терабайтном NVMe это оставляет диск почти пустым, и правильное число
# стоит ЗАМЕРИТЬ под конкретный носитель, а не наследовать по инерции.
# Переопределяется из окружения:  APP_SIZE=200GiB sudo -E ./05-generate-images.sh
APP_SIZE="${APP_SIZE:-40GiB}"

# Минимум свободного места под промежуточные образы: system.img в двух видах
# (raw + sparse) плюс подписанные загрузчики.
MIN_FREE_GIB="${MIN_FREE_GIB:-40}"

BOARD_TARGET="${BOARD_TARGET:-jetson-agx-orin-devkit}"

step() { echo; echo "=== $* ==="; }

recovery_hint() {
    cat <<'HINT'
  Как перевести плату в recovery (APX):
    1. Обесточить плату.
    2. Подать питание.
    3. Зажать и держать Force Recovery — СРЕДНЯЯ кнопка.
    4. Нажать и отпустить Reset — ПРАВАЯ кнопка.
    5. Отпустить Force Recovery.
  Кабель — в USB-C рядом с 40-пиновым разъёмом (не в тот, что у Ethernet).
  Проверка:  lsusb | grep 0955:
HINT
}

[ "$(id -u)" -eq 0 ] || { echo "Нужен root"; exit 1; }

# Скрипты L4T читают $USER (а не только id -u) и при пустом значении
# сбиваются на проверке прав. Под sudo переменная есть; страхуемся на случай
# запуска из окружения, где её вычистили.
export USER="${USER:-root}"
export HOME="${HOME:-/root}"

# --------------------------------------------------------------------------
# Все предполётные проверки идут ДО долгой работы. Смысл ровно один: отказ
# должен стоить секунды, а не сорок минут ожидания и половину артефактов.
# --------------------------------------------------------------------------

step "1. Дерево BSP на месте"
[ -d "$LFT" ] || { echo "ОСТАНОВ: нет $LFT — сначала 03-prepare-bsp.sh"; exit 1; }
[ -x "$LFT/tools/kernel_flash/l4t_initrd_flash.sh" ] || {
    echo "ОСТАНОВ: нет tools/kernel_flash/l4t_initrd_flash.sh — дерево BSP неполное"; exit 1; }
[ -e "$LFT/rootfs/.applied-binaries" ] || {
    echo "ОСТАНОВ: apply_binaries не накатан — сначала 03-prepare-bsp.sh"; exit 1; }
if ! grep -q '^[a-zA-Z]' "$LFT/rootfs/etc/passwd" 2>/dev/null; then
    echo "ОСТАНОВ: rootfs/etc/passwd пуст или нечитаем"; exit 1
fi
echo "OK: $LFT"
# Мягкое напоминание: без 04 система на плате встретит оператора мастером
# первичной настройки. Это не ошибка сборки, поэтому предупреждение, а не отказ.
if find "$LFT/rootfs/etc/systemd/system" -name '*oem-config*' 2>/dev/null | grep -q .; then
    echo "ПРЕДУПРЕЖДЕНИЕ: oem-config в rootfs НЕ отключён — похоже, 04 не прогонялся."
    echo "  Первая загрузка потребует монитор и клавиатуру."
fi

step "2. Плата в recovery (APX)?"
if lsusb | grep -q '0955:7023'; then
    echo "OK: $(lsusb | grep '0955:7023')"
elif lsusb | grep -q '0955:7035'; then
    echo "ОСТАНОВ: плата в initrd flashing mode (0955:7035) — она осталась после"
    echo "прерванной заливки. Перезагрузи её в recovery."
    recovery_hint
    exit 1
elif lsusb | grep -q '0955:'; then
    echo "ОСТАНОВ: плата видна, но НЕ в recovery:"
    lsusb | grep '0955:' | sed 's/^/  /'
    echo
    echo "7020 — это ЗАГРУЖЕННАЯ система L4T, а не recovery. Для чтения EEPROM"
    echo "нужен 7023 (APX), иначе BOARDID/BOARDSKU/FAB останутся пустыми."
    recovery_hint
    exit 1
else
    echo "ОСТАНОВ: устройств 0955:* на USB нет вовсе. Проверь кабель и питание платы."
    recovery_hint
    exit 1
fi

step "3. Утилиты, которые ищут сами скрипты L4T"
# Список собран не на глаз: это все аргументы `command -v` в
# tools/kernel_flash/*.sh, tools/*.sh и flash.sh, плюс cpp — его зовёт уже
# не оболочка, а tegraflash.py через run_cpp_tool() (препроцессирует .dts
# перед dtc). Отсутствие cpp даёт не понятный отказ, а голый
# FileNotFoundError из subprocess.Popen где-то в середине сборки.
# Ловить их по одной — значит платить прогоном за каждую.
need_install=""
check_bin() {   # утилита пакет
    printf '  %-12s ' "$1"
    if command -v "$1" >/dev/null 2>&1; then
        echo "OK"
    else
        echo "НЕТ -> $2"
        need_install="$need_install $2"
    fi
}
check_bin zstd       zstd
check_bin abootimg   abootimg
check_bin exportfs   nfs-kernel-server
check_bin sshpass    sshpass
check_bin uuidgen    uuid-runtime
check_bin xmllint    libxml2-utils
check_bin xmlstarlet xmlstarlet
check_bin ssh-keygen openssh-client
check_bin lz4        lz4
check_bin sgdisk     gdisk
check_bin parted     parted
check_bin cpio       cpio
check_bin cpp        cpp
check_bin dtc        device-tree-compiler

if [ -n "$need_install" ]; then
    echo
    echo "Доустанавливаю:$need_install"
    export DEBIAN_FRONTEND=noninteractive
    apt-get -qq update
    # shellcheck disable=SC2086
    apt-get -qq install -y --no-install-recommends $need_install
    for b in zstd abootimg exportfs sshpass uuidgen xmllint xmlstarlet ssh-keygen lz4 sgdisk parted cpio cpp dtc; do
        command -v "$b" >/dev/null 2>&1 || { echo "ОСТАНОВ: $b так и не появился"; exit 1; }
    done
    echo "все на месте"
fi

step "4. Поддержка DSA в ssh-keygen"
# Отдельная проверка ради одного конкретного отказа, который иначе выглядит
# как пустая строка «command is failed» без каких-либо подробностей:
#   ota_make_recovery_img_dtb.sh:112 зовёт `ssh-keygen -t dsa`,
#   check_error там вызван БЕЗ аргумента, а вывод погашен в /dev/null.
# OpenSSH выбросил DSA в 9.8 — на Debian 13 (10.0p2) ключ не создаётся вовсе,
# recovery.img не собирается, и заливка потом встаёт намертво.
# На Ubuntu 22.04 стоит OpenSSH 8.9, где DSA ещё на месте: проверка тут
# сторожит не сегодняшний день, а обновление станции.
echo "openssh : $(ssh -V 2>&1)"
probe=$(mktemp -d)
if ssh-keygen -t dsa -N "" -f "$probe/dsa" >/dev/null 2>&1; then
    echo "dsa     : поддерживается — recovery.img соберётся"
    rm -rf "$probe"
else
    echo "dsa     : ОТКАЗ. Причина:"
    ssh-keygen -t dsa -N "" -f "$probe/dsa2" 2>&1 | head -3 | sed 's/^/  /'
    rm -rf "$probe"
    echo
    echo "ОСТАНОВ: recovery.img собрать не получится, генерация упадёт с пустым"
    echo "'command is failed'. Станция обязана быть на OpenSSH < 9.8 (Ubuntu 22.04)."
    exit 1
fi

step "5. Свободное место"
avail_bytes=$(df -B1 --output=avail "$WORK" 2>/dev/null | tail -1 | tr -d ' ')
avail_gib=$(( ${avail_bytes:-0} / 1024 / 1024 / 1024 ))
echo "в $WORK свободно ${avail_gib} GiB (нужно минимум ${MIN_FREE_GIB})"
if [ "$avail_gib" -lt "$MIN_FREE_GIB" ]; then
    echo "ОСТАНОВ: места не хватит. Освободи место или укажи другой WORK."
    echo "Нехватка проявляется не отказом, а обрывом в середине сборки system.img."
    exit 1
fi

step "6. Уборка от прошлых прогонов"
# Оставленный ramdisk_tmp и стухшие записи в /etc/exports ломают повтор.
# tools/kernel_flash/images и bootloader/signed НЕ трогаем здесь: их
# перезапишет сама генерация, а до её старта они — единственное, что
# осталось бы при отказе на предполётных проверках.
rm -rf "$LFT/bootloader/ramdisk_tmp" "$LFT/tools/kernel_flash/tmp"
if [ -f /etc/exports ]; then
    sed -i '/Linux_for_Tegra\/tools\/kernel_flash\/tmp/d;/# Entry added by NVIDIA initrd flash tool/d' /etc/exports
fi
# Грабля: узлы устройств, оставшиеся в целевом дереве от прерванных прогонов
# под qemu, ломают упаковку rootfs в system.img.
rm -f "$LFT/rootfs/dev/random" "$LFT/rootfs/dev/urandom"
# Грабля: TMPDIR станции утекает в nvidia-l4t-initrd, который делает chroot
# в целевое дерево, — а такого пути внутри нет, и mktemp падает.
unset TMPDIR || true
echo "убрано; TMPDIR = [${TMPDIR:-}] (обязано быть пусто)"

step "7. Генерация образов (--no-flash), 15-40 минут"
echo "APP_SIZE = $APP_SIZE ; цель = $BOARD_TARGET ; лог = $LOG"
cd "$LFT" || exit 1
set -x
./tools/kernel_flash/l4t_initrd_flash.sh \
    --no-flash \
    --external-device nvme0n1p1 \
    -c tools/kernel_flash/flash_l4t_t234_nvme.xml \
    -p "-c bootloader/generic/cfg/flash_t234_qspi.xml" \
    -S "$APP_SIZE" \
    --showlogs --network usb0 \
    "$BOARD_TARGET" external 2>&1 | tee "$LOG"
RC=${PIPESTATUS[0]}
set +x

step "8. Что получилось (независимо от кода возврата)"
echo "код возврата l4t_initrd_flash.sh: $RC"
echo
show() {   # путь пояснение
    printf '  %-50s ' "$1"
    if [ -d "$LFT/$1" ]; then
        echo "есть ($(du -sh "$LFT/$1" 2>/dev/null | cut -f1))"
    elif [ -s "$LFT/$1" ]; then
        echo "есть ($(stat -c%s "$LFT/$1") байт)"
    else
        echo "НЕТ"
    fi
}
show tools/kernel_flash/images/
show tools/kernel_flash/images/external/
show bootloader/signed/
show tools/kernel_flash/images/internal/flash.idx
show tools/kernel_flash/initrdflashparam.txt
show bootloader/recovery.img

step "9. recovery.img — ключевой артефакт"
# Именно на нём вставала попытка 2026-09-09: без recovery.img заливка
# доходит до «Waiting for target to boot-up... Timeout» и не идёт дальше.
# Подмена его на boot.img проверялась и давала мёртвую плату — обход,
# который выглядит рабочим ровно до первой загрузки.
if [ -s "$LFT/bootloader/recovery.img" ]; then
    sz=$(stat -c%s "$LFT/bootloader/recovery.img")
    echo "recovery.img собран: $((sz / 1024 / 1024)) МБ (ожидаемый порядок — около 64 МБ)"
else
    echo "recovery.img НЕ собран. Строки лога вокруг падения:"
    grep -nE 'BASE_KERNEL_VERSION|Making Recovery|command is failed|recovery' "$LOG" 2>/dev/null | tail -20 | sed 's/^/  /'
    echo
    echo "Чаще всего это грабля с DSA (см. шаг 4). Заливать нечего — 06 запускать нельзя."
fi

step "ИТОГ"
df -h "$WORK" | tail -1
echo "Полный лог: $LOG"
if [ "$RC" -eq 0 ] && [ -s "$LFT/bootloader/recovery.img" ]; then
    echo
    echo "Образы готовы. Дальше — 06-flash.sh (НЕОБРАТИМО пишет на плату)."
    echo "Напоминание: flash.sh напрямую в этом каталоге не запускать."
fi
exit "$RC"
