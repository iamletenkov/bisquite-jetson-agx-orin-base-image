#!/usr/bin/env bash
# Выборочная прошивка ВНУТРЕННИХ носителей платы: только QSPI либо QSPI+eMMC.
#
#     sudo /opt/nvidia-jetpack/10-flash-internal.sh --target qspi
#     sudo /opt/nvidia-jetpack/10-flash-internal.sh --target emmc
#
# ЧЕМ ОТЛИЧАЕТСЯ ОТ 06. Шаг 06 заливает плату целиком под загрузку
# с ВНЕШНЕГО NVMe: QSPI, загрузочные разделы и rootfs на nvme0n1.
# Здесь — два более узких случая:
#
#   --target qspi   только загрузчик в QSPI-NOR. Носители не трогаются
#                   вовсе. Это то, что нужно, когда у платы «чужой»
#                   JetPack и её надо привести к нашему, не переписывая
#                   диск: загрузчик и rootfs обязаны быть из одного
#                   набора, иначе плата не загрузится (между JP5 и JP6
#                   сменилась вся загрузочная цепочка).
#
#   --target emmc   QSPI плюс rootfs во ВНУТРЕННЮЮ eMMC (mmcblk0).
#                   Осмысленно, когда внешнего диска нет вовсе.
#
# ПОЧЕМУ ОТДЕЛЬНЫЙ КОНФИГ ПЛАТЫ ДЛЯ QSPI, А НЕ ФЛАГ. В BSP есть
# p3737-0000-p3701-0000-qspi.conf — ровно наш носитель и модуль. Внутри
# он объявляет EMMC_CFG=flash_t234_qspi.xml, NO_ROOTFS=1 и
# NO_RECOVERY_IMG=1, то есть образы rootfs и recovery не генерируются
# в принципе. Это путь, документированный NVIDIA
# (tools/kernel_flash/README_initrd_flash.txt, «generate qspi only
# images»), а не наша самодеятельность поверх общего конфига.
#
# ⚠️ НЕ ПРОГНАН НА ЖЕЛЕЗЕ. Команды собраны по README самого BSP и по
# конфигам, которые в нём лежат; сверка сделана чтением, а не запуском.
# Первый прогон делай с монитором, подключённым к плате.
set -euo pipefail

WORK="${WORK:-/srv/jetson}"
LFT="$WORK/Linux_for_Tegra"
LOG="${LOG:-$WORK/10-flash-internal.log}"

# Конфиг «только QSPI» именно для p3737-0000 + p3701-0000 (AGX Orin Devkit).
# На другом модуле нужен свой — список: ls $LFT/*-qspi.conf
QSPI_TARGET="${QSPI_TARGET:-p3737-0000-p3701-0000-qspi}"
BOARD_TARGET="${BOARD_TARGET:-jetson-agx-orin-devkit}"

TARGET=""
usage() {
    cat <<'USAGE'
Использование:
  10-flash-internal.sh --target qspi|emmc

  --target qspi   только загрузчик в QSPI-NOR, носители не трогаются
  --target emmc   QSPI плюс rootfs во внутреннюю eMMC (mmcblk0)

Переменные окружения: WORK (умолчание /srv/jetson), QSPI_TARGET,
BOARD_TARGET, LOG.

Плата должна быть в recovery (APX) и подключена кабелем к USB-C рядом
с 40-пиновым разъёмом.
USAGE
}

while [ $# -gt 0 ]; do
    case "$1" in
        --target) TARGET="${2:-}"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "ОШИБКА: неизвестный аргумент: $1"; echo; usage; exit 1 ;;
    esac
done

case "$TARGET" in
    qspi|emmc) ;;
    "") echo "ОШИБКА: --target обязателен."; echo; usage; exit 1 ;;
    *) echo "ОШИБКА: --target принимает qspi или emmc, получено: $TARGET"; exit 1 ;;
esac

step() { echo; echo "=== $* ==="; }

[ "$(id -u)" -eq 0 ] || { echo "ОШИБКА: нужен root (sudo)."; exit 1; }

step "1. Дерево BSP на месте?"
[ -d "$LFT" ] || { echo "ОСТАНОВ: нет $LFT — прогони 01 и 03."; exit 1; }
echo "OK: $LFT"
if [ "$TARGET" = qspi ]; then
    [ -f "$LFT/$QSPI_TARGET.conf" ] || {
        echo "ОСТАНОВ: нет $LFT/$QSPI_TARGET.conf"
        echo "  доступные конфиги «только QSPI»:"
        ls "$LFT"/*-qspi.conf 2>/dev/null | sed 's|.*/|    |' || echo "    ни одного"
        exit 1
    }
    echo "конфиг QSPI: $QSPI_TARGET.conf"
fi

step "2. Плата в recovery (APX)?"
if lsusb | grep -q '0955:7023'; then
    echo "OK: $(lsusb | grep '0955:7023')"
else
    echo "ОСТАНОВ: APX (0955:7023) не найден."
    usb_list=$(lsusb | grep '0955:' || true)
    if [ -n "$usb_list" ]; then
        echo "$usb_list" | sed 's/^/  /'
    else
        echo "  устройств 0955:* нет вовсе"
    fi
    cat <<'HINT'

  Как перевести плату в recovery (APX):
    1. Обесточить плату.
    2. Подать питание.
    3. Зажать и держать Force Recovery — СРЕДНЯЯ кнопка.
    4. Нажать и отпустить Reset — ПРАВАЯ кнопка.
    5. Отпустить Force Recovery.
  Кабель — в USB-C рядом с 40-пиновым разъёмом.

  0955:7035 означает, что плата уже в initrd после прерванной заливки:
  её надо перезагрузить в recovery заново.
HINT
    exit 1
fi

step "3. Есть ли чем войти в eMMC-систему?"
if [ "$TARGET" = emmc ]; then
    # ЗАЧЕМ ЭТА ПРОВЕРКА. В eMMC уезжает rootfs из дерева BSP как есть —
    # без cloud-init, потому что cloud-init в базовом образе не стоит
    # (его ставит слой bisquite, а сюда слои не применяются). Значит
    # учётка может появиться только на шаге 04.
    #
    # А шаг 04 с флагом -U учётку НЕ создаёт вовсе и пароль root НЕ ставит
    # (shadow он не трогает; в sample rootfs NVIDIA root заблокирован).
    # Для образа флота это верно — креды приходят из манифеста записи. Но
    # для eMMC это система, в которую невозможно войти НИКАК: ни по ssh,
    # ни с консоли. Аварийный носитель, в который не залогиниться, хуже,
    # чем его отсутствие: он выглядит рабочим ровно до того момента, когда
    # понадобился.
    ROOTFS_TREE="$LFT/rootfs"
    [ -f "$ROOTFS_TREE/etc/passwd" ] || {
        echo "ОСТАНОВ: нет $ROOTFS_TREE/etc/passwd — дерево не подготовлено (шаги 03, 04)."
        exit 1
    }
    HUMANS=$(awk -F: '$3 >= 1000 && $3 != 65534 {print $1}' "$ROOTFS_TREE/etc/passwd" 2>/dev/null || true)
    if [ -n "$HUMANS" ]; then
        echo "OK: учётка(и) в дереве — $(echo "$HUMANS" | tr '\n' ' ')"
    else
        cat <<'STOP'
ОСТАНОВ: в дереве rootfs нет ни одной обычной учётной записи.

  Похоже, шаг 04 запускали с флагом -U (он создан для образа флота, где
  учётку заводит cloud-init при записи носителя). В eMMC cloud-init не
  приедет, и войти в такую систему будет нельзя ни по ssh, ни с консоли:
  пользователя нет, а пароль root не задан.

  Что сделать:
    sudo WORK=$WORK ./04-customize-rootfs.sh -u rescue -p <пароль>

  и запустить этот скрипт заново. Учётка нужна именно аварийная — eMMC
  тут запасной путь на случай отказа основного диска.
STOP
        exit 1
    fi
fi

step "4. TMPDIR"
# Та же грабля, что в 05 и 06: TMPDIR станции утекает в nvidia-l4t-initrd,
# который делает chroot в целевое дерево, — такого пути внутри нет,
# и mktemp падает уже в середине.
unset TMPDIR || true
echo "убрано; TMPDIR = [${TMPDIR:-}] (обязано быть пусто)"

step "5. ПОДТВЕРЖДЕНИЕ"
if [ "$TARGET" = qspi ]; then
    cat <<WARN
Сейчас будет переписан ЗАГРУЗЧИК В QSPI-NOR на модуле. Это НЕОБРАТИМО:
отката на прежнюю версию L4T не остаётся.

Носители НЕ трогаются: конфиг $QSPI_TARGET объявляет NO_ROOTFS=1,
то есть образ rootfs не генерируется вовсе.

⚠️ После этого плата загрузится только с носителя, чей rootfs из того же
набора L4T. Если на диске лежит система от другого JetPack — она не
поднимется, и это ожидаемо, а не поломка.
WARN
else
    cat <<WARN
Сейчас будут переписаны ЗАГРУЗЧИК В QSPI-NOR и ВНУТРЕННЯЯ eMMC
(mmcblk0) целиком. Это НЕОБРАТИМО: и прежний загрузчик, и всё
содержимое eMMC пропадут.
WARN
fi
cat <<'WARN'

Во время заливки НЕЛЬЗЯ:
  - выдёргивать USB-кабель;
  - выключать питание платы;
  - прерывать скрипт по Ctrl+C.

Полезно открыть в соседнем окне:  sudo dmesg -Tw
WARN
printf '\nВведи "да" для запуска: '
read -r answer
[ "$answer" = "да" ] || { echo "Отменено — на плату ничего не записано."; exit 1; }

step "6. Заливка"
cd "$LFT" || exit 1
set -x
if [ "$TARGET" = qspi ]; then
    ./tools/kernel_flash/l4t_initrd_flash.sh \
        --showlogs --network usb0 \
        "$QSPI_TARGET" internal 2>&1 | tee "$LOG"
else
    ./tools/kernel_flash/l4t_initrd_flash.sh \
        --showlogs --network usb0 \
        "$BOARD_TARGET" internal 2>&1 | tee "$LOG"
fi
RC=${PIPESTATUS[0]}
set +x

step "7. ИТОГ"
echo "код возврата: $RC"
echo "лог: $LOG"
if [ "$RC" -eq 0 ]; then
    echo
    echo "Готово. Плату можно вывести из recovery (обесточить и подать питание)."
    if [ "$TARGET" = qspi ]; then
        echo "Проверить версию на загруженной системе: cat /etc/nv_tegra_release"
    fi
fi
exit "$RC"
