#!/bin/bash
# Шаг 6: ЗАЛИВКА уже собранных образов на плату (--flash-only).
#
#     sudo /opt/nvidia-jetpack/06-flash.sh
#
# ЭТО НЕОБРАТИМО. Записывается:
#   - загрузчик в QSPI-NOR на модуле;
#   - разметка и APP-раздел на внешнем NVMe;
#   - ЗАГРУЗОЧНЫЕ РАЗДЕЛЫ eMMC (mmcblk0boot*/mmcblk0).
# Последнее — не домысел: в логе прошлой заливки видно
#     "Starting to flash to emmc" -> "Successfully flash the emmc".
# То есть «мы грузимся с NVMe, значит eMMC цела» — неверно, и отката
# на прежнюю версию L4T после этого шага нет.
#
# Как это работает: плата поднимается по RCM в initrd-ядро, включает RNDIS
# и забирает образы с хоста. Задействовано И то, и другое:
#   - NFS — каталог tools/kernel_flash/tmp экспортируется на localhost;
#     запись в /etc/exports скрипт L4T добавляет и убирает сам;
#   - SSH по IPv6 (fc00:1:1:0::2) — управление процессом на стороне платы.
# Отсюда и предполётные проверки ниже: почти всё, что срывало заливку,
# срывало её через NFS.
#
# Работаем НАТИВНО на станции: init-система настоящая, nfsdcld и rpc_pipefs
# поднимает systemd. Ради этого станция и существует.

set -uo pipefail

WORK="${WORK:-/srv/jetson}"
LFT="$WORK/Linux_for_Tegra"
LOG="$WORK/06-flash.log"

# Те же значения, что в 05: заливка обязана идти теми же параметрами, какими
# собирались образы, иначе l4t_initrd_flash ищет не те файлы.
APP_SIZE="${APP_SIZE:-40GiB}"
BOARD_TARGET="${BOARD_TARGET:-jetson-agx-orin-devkit}"
MIN_FREE_GIB="${MIN_FREE_GIB:-15}"

# Адрес платы в RNDIS-сети, поднимаемой заливкой. Нужен только для подсказки
# про ufw — сам адрес задаёт L4T, не мы.
BOARD_ADDR="fc00:1:1:0::2"

step() { echo; echo "=== $* ==="; }

[ "$(id -u)" -eq 0 ] || { echo "Нужен root"; exit 1; }

# Скрипты L4T читают $USER, а не только id -u.
export USER="${USER:-root}"
export HOME="${HOME:-/root}"

# --------------------------------------------------------------------------
step "1. Артефакты на месте?"
fail=0
for f in bootloader/recovery.img \
         tools/kernel_flash/images/internal/flash.idx \
         tools/kernel_flash/initrdflashparam.txt; do
    printf '  %-52s ' "$f"
    if [ -s "$LFT/$f" ]; then echo "OK"; else echo "НЕТ"; fail=1; fi
done
printf '  %-52s ' "tools/kernel_flash/images/external/"
if [ -d "$LFT/tools/kernel_flash/images/external" ]; then
    echo "OK ($(du -sh "$LFT/tools/kernel_flash/images/external" | cut -f1))"
else
    echo "НЕТ"; fail=1
fi
[ "$fail" -eq 0 ] || { echo; echo "ОСТАНОВ: образов нет — сначала 05-generate-images.sh."; exit 1; }

step "2. Плата в recovery (APX)?"
if lsusb | grep -q '0955:7023'; then
    echo "OK: $(lsusb | grep '0955:7023')"
else
    echo "ОСТАНОВ: APX (0955:7023) не найден."
    # Через `lsusb | grep ... || echo` это не пишется: код возврата даёт
    # последняя команда конвейера, и ветка «нет вовсе» не сработала бы никогда.
    usb_list=$(lsusb | grep '0955:')
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

step "3. Межсетевой экран"
# Частая причина отказа монтирования: плата стучится к хосту по NFS с адреса
# fc00:1:1:0::2, а ufw режет входящее. Проявляется это не отказом ufw,
# а зависанием заливки на «Waiting for target to boot-up», то есть выглядит
# как что угодно, только не как файрвол.
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi '^Status: active'; then
    cat <<HINT
  ПРЕДУПРЕЖДЕНИЕ: ufw активен. Разреши плате доступ к NFS одним из способов:

      sudo ufw allow from $BOARD_ADDR to any port nfs

  либо, на время заливки:

      sudo ufw disable      # и sudo ufw enable после

  Продолжить можно и так — если правило уже стоит, всё в порядке.
HINT
    ufw status 2>/dev/null | head -10 | sed 's/^/    /'
else
    echo "ufw не активен (или не установлен) — препятствий нет"
fi

step "3.5 Утилиты, без которых заливка встанет на середине"
# Полный список проверяет шаг 05 — там он и должен стоять, отказ стоит секунд
# до начала работы. Здесь повторяются только те четыре, что зовутся УЖЕ ПОСЛЕ
# начала записи: их отсутствие оставит плату с переписанным QSPI и пустым APP.
miss=""
check_bin() {   # утилита пакет
    printf '  %-12s ' "$1"
    if command -v "$1" >/dev/null 2>&1; then
        echo "OK"
    else
        echo "НЕТ -> $2"
        miss="$miss $2"
    fi
}
check_bin exportfs  nfs-kernel-server
check_bin showmount nfs-common
check_bin sshpass   sshpass
check_bin zstd      zstd
if [ -n "$miss" ]; then
    echo "Доустанавливаю:$miss"
    export DEBIAN_FRONTEND=noninteractive
    apt-get -qq update
    # shellcheck disable=SC2086
    apt-get -qq install -y --no-install-recommends $miss
    for b in exportfs showmount sshpass zstd; do
        command -v "$b" >/dev/null 2>&1 || { echo "ОСТАНОВ: $b так и не появился"; exit 1; }
    done
    echo "все на месте"
fi

step "4. NFS-сервер"
# На живой системе systemd поднимает вместе с nfs-server и nfsdcld (учёт
# lease у NFSv4), и монтирует rpc_pipefs отдельным юнитом. Именно этого
# не хватало в chroot-станции, где распаковка system.img рвалась посреди
# работы, а плата писала в dmesg
#     NFS: state manager: check lease failed on NFSv4 server ... error 13
if ! systemctl is-active --quiet nfs-server 2>/dev/null; then
    echo "nfs-server не запущен — поднимаю"
    systemctl start nfs-server 2>&1 | sed 's/^/  /'
    sleep 2
fi
if systemctl is-active --quiet nfs-server 2>/dev/null; then
    echo "nfs-server        : активен"
else
    echo "ОСТАНОВ: nfs-server не поднимается. Заливка без него невозможна."
    systemctl status nfs-server --no-pager -l 2>&1 | tail -15 | sed 's/^/  /'
    exit 1
fi
# Плата монтирует именно NFSv4 (v3 поверх IPv6 её клиент не умеет вовсе),
# поэтому nfsdcld обязателен, а не желателен.
if pgrep -x nfsdcld >/dev/null 2>&1; then
    echo "nfsdcld           : работает (pid $(pgrep -x nfsdcld | tr '\n' ' '))"
else
    echo "nfsdcld           : НЕ работает — пробую поднять"
    systemctl start nfsdcld 2>&1 | sed 's/^/  /'
    sleep 1
    pgrep -x nfsdcld >/dev/null 2>&1 \
        && echo "                    поднялся" \
        || echo "                    ПРЕДУПРЕЖДЕНИЕ: заливка может оборваться на system.img"
fi
if mountpoint -q /var/lib/nfs/rpc_pipefs; then
    echo "rpc_pipefs        : смонтирован"
else
    echo "rpc_pipefs        : НЕ смонтирован — монтирую"
    mount -t rpc_pipefs sunrpc /var/lib/nfs/rpc_pipefs 2>&1 | sed 's/^/  /'
    mountpoint -q /var/lib/nfs/rpc_pipefs \
        && echo "                    OK" \
        || echo "                    ПРЕДУПРЕЖДЕНИЕ: nfsdcld без него молча умирает"
fi
echo "потоки nfsd       : $(cat /proc/fs/nfsd/threads 2>/dev/null || echo '?')"
if ! showmount -e localhost >/dev/null 2>&1; then
    # Ровно эту проверку делает сам L4T (l4t_network_flash.func) и выходит
    # с кодом 114, если она не прошла. Пустой список экспортов — нормально,
    # экспорт добавит он сам; важно, что RPC MOUNT (100005) отвечает.
    echo "ПРЕДУПРЕЖДЕНИЕ: showmount -e localhost не отвечает — L4T выйдет с кодом 114."
    echo "  Попробуй: systemctl restart nfs-server"
fi

step "5. Свободное место"
# Нехватка места на хосте уже была названа причиной срыва монтирования NFS:
# заливка копирует образы в tools/kernel_flash/tmp, и место кончается уже
# после старта, когда плата ждёт данные.
avail_bytes=$(df -B1 --output=avail "$WORK" 2>/dev/null | tail -1 | tr -d ' ')
avail_gib=$(( ${avail_bytes:-0} / 1024 / 1024 / 1024 ))
echo "в $WORK свободно ${avail_gib} GiB (нужно минимум ${MIN_FREE_GIB})"
if [ "$avail_gib" -lt "$MIN_FREE_GIB" ]; then
    echo "ОСТАНОВ: места мало. Освободи место — иначе заливка оборвётся на середине."
    exit 1
fi

step "6. USB: autosuspend и помехи"
# udev-правило из расширения гасит autosuspend для 0955:* навсегда, но плата
# за сеанс трижды меняет PID (7020 -> 7023 APX -> 7035 initrd) и наблюдалась
# миграция между шинами, так что проверяем по факту, а не по наличию файла
# правила. Разрыв USB-линка посреди записи QSPI — худшее, что тут возможно.
n_on=0; n_fixed=0
for f in /sys/bus/usb/devices/*/power/control; do
    [ -r "$f" ] || continue
    if [ "$(cat "$f" 2>/dev/null)" = "on" ]; then
        n_on=$((n_on+1))
    elif [ -w "$f" ] && echo on > "$f" 2>/dev/null; then
        n_fixed=$((n_fixed+1))
    fi
done
echo "autosuspend       : уже снят у $n_on устройств, снял ещё у $n_fixed"
if systemctl is-active --quiet ModemManager 2>/dev/null; then
    systemctl stop ModemManager && echo "ModemManager      : остановлен на время заливки"
else
    echo "ModemManager      : не запущен"
fi
# Плата и хост говорят по IPv6 в RNDIS-сети; выключенный IPv6 обрывает
# управляющий канал, хотя USB при этом «работает».
echo "disable_ipv6.all  : $(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null) (нужен 0)"

step "7. Уборка временного от прошлых прогонов"
# images/ и bootloader/signed НЕ трогаем — там результат шага 05, залить
# больше нечем. Убираем только tmp и стухшие записи в /etc/exports:
# наслоение моего состояния на состояние L4T — лишняя переменная там,
# где и так много движущихся частей.
rm -rf "$LFT/tools/kernel_flash/tmp"
if [ -f /etc/exports ]; then
    sed -i '/Linux_for_Tegra\/tools\/kernel_flash\/tmp/d;/# Entry added by NVIDIA initrd flash tool/d' /etc/exports
    command -v exportfs >/dev/null 2>&1 && exportfs -ra >/dev/null 2>&1
fi
unset TMPDIR || true
echo "убрано; TMPDIR = [${TMPDIR:-}] (обязано быть пусто)"

step "8. ПОДТВЕРЖДЕНИЕ"
cat <<WARN
Сейчас начнётся ЗАПИСЬ НА ПЛАТУ. Это НЕОБРАТИМО:
  - переписывается загрузчик в QSPI-NOR на модуле;
  - создаётся разметка и APP-раздел $APP_SIZE на внешнем NVMe (nvme0n1);
  - ОБНОВЛЯЮТСЯ ЗАГРУЗОЧНЫЕ РАЗДЕЛЫ eMMC (mmcblk0) — отката на прежнюю
    версию L4T после этого не остаётся.

Во время заливки НЕЛЬЗЯ:
  - выдёргивать USB-кабель;
  - выключать питание платы;
  - прерывать скрипт по Ctrl+C.

Займёт 20-40 минут. Полезно открыть в соседнем окне:  sudo dmesg -Tw
WARN
printf '\nВведи "да" для запуска: '
read -r answer
[ "$answer" = "да" ] || { echo "Отменено — на плату ничего не записано."; exit 1; }

step "9. Заливка (--flash-only), 20-40 минут"
echo "APP_SIZE = $APP_SIZE ; цель = $BOARD_TARGET ; лог = $LOG"
cd "$LFT" || exit 1
set -x
./tools/kernel_flash/l4t_initrd_flash.sh \
    --flash-only \
    --external-device nvme0n1p1 \
    -c tools/kernel_flash/flash_l4t_t234_nvme.xml \
    -p "-c bootloader/generic/cfg/flash_t234_qspi.xml" \
    -S "$APP_SIZE" \
    --showlogs --network usb0 \
    "$BOARD_TARGET" external 2>&1 | tee "$LOG"
RC=${PIPESTATUS[0]}
set +x

step "10. ИТОГ"
echo "код возврата: $RC"
if [ "$RC" -eq 0 ]; then
    cat <<'OK'

Заливка завершилась успешно. Дальше:

  1. Выведи плату из recovery: обесточить и подать питание заново,
     БЕЗ зажатой кнопки Force Recovery.
  2. Дай ей загрузиться и проверь НА ПЛАТЕ:
        cat /etc/nv_tegra_release   # ждём R36 REVISION: 4.3
        uname -r                    # ждём 5.15.148-tegra
        lsblk                       # / должен быть на nvme0n1p1, НЕ на mmcblk0p1
  3. Пользователь и пароль — те, что заданы в 04-customize-rootfs.sh;
     мастера первичной настройки быть не должно.
  4. Драйверы камер лежат в /opt/sensing, но НЕ установлены: ставит их
     ./install.sh, затем нужен DTB-оверлей и перезагрузка, и только
     потом ./quick_bring_up.sh. Порядок и диагностика —
     в разделе «Камеры» файла /opt/nvidia-jetpack/README.md.
OK
else
    cat <<'FAIL'

Заливка НЕ удалась. Прежде чем что-то менять — прочти это.

Обрыв на распаковке system.img — ИЗВЕСТНАЯ ПРОБЛЕМА САМОГО L4T, а не
следствие станции. Выглядит так:

    EXT4-fs (nvme0n1p1): mounted filesystem
    nfs: server fc00:1:1:0::1 not responding, still trying
    nfs: server ... timed out          <- и уже не восстанавливается

Пользователи Orin сообщают об успехе после нескольких попыток, так что
повторный запуск 06-flash.sh — нормальный первый ход, а не отчаяние.

ЕСТЬ ОБХОД. Если плата сейчас в initrd (0955:7035), она жива и доступна
по SSH: загрузчик, разделы и GPT уже записаны, не хватает только
содержимого APP. Разверни rootfs SSH-потоком, минуя NFS:

    sudo /opt/nvidia-jetpack/07-flash-rootfs-ssh.sh

Тот же объём по тому же кабелю проходил SSH-потоком с первого раза.
Плату при этом НЕ обесточивай — из initrd она выйдет и обход станет
недоступен, придётся начинать заливку заново.
FAIL
    echo
    echo "Состояние USB сейчас:"
    usb_list=$(lsusb | grep '0955:')
    if [ -n "$usb_list" ]; then
        echo "$usb_list" | sed 's/^/  /'
        echo "  (7035 = initrd, обход через 07 доступен; пусто = плата вышла из режима заливки)"
    else
        echo "  устройств 0955:* нет"
    fi
    echo
    echo "Строки лога вокруг падения:"
    grep -nE 'Timeout|ERROR|error|failed|Waiting for target' "$LOG" 2>/dev/null | tail -25 | sed 's/^/  /'
fi
echo
echo "Полный лог: $LOG"
exit "$RC"
