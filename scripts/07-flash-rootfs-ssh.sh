#!/bin/bash
# Разворачивает rootfs в APP-раздел платы ПО SSH, минуя NFS.
#
#     sudo /opt/nvidia-jetpack/07-flash-rootfs-ssh.sh
#
# Зачем этот шаг вообще существует.
#
# К моменту его запуска на плате прошито уже всё, кроме содержимого APP:
# QSPI, загрузочные разделы, GPT на NVMe, A/B kernel, kernel-dtb, recovery,
# esp. Не хватает только корневой файловой системы. А заливка стабильно
# рвётся именно на ней, потому что NFS-сервер перестаёт отвечать под
# нагрузкой распаковки system.img:
#
#   [  53] EXT4-fs (nvme0n1p1): mounted filesystem
#   [ 234] nfs: server fc00:1:1:0::1 not responding, still trying
#   [ 267] nfs: server ... timed out          <- и уже не восстанавливается
#
# Это известная проблема L4T, а не особенность конкретной станции: она
# воспроизводилась и при NFS-сервере, поднятом на живом хосте под systemd
# (nfsdcld жив, rpc_pipefs смонтирован, 16 потоков nfsd). Тот же объём,
# отданный SSH-потоком, проходит с первого раза — проверено вживую
# 2026-09-09: развёрнуто 6.6 ГБ, все ключевые файлы на месте.
#
# Что мы, собственно, повторяем. l4t_flash_from_kernel.sh на этом месте
# делает ровно четыре вещи:
#
#   mkfs -F APP ; mount APP tmp ; tar -x -I 'zstd -T0' ... ; sync ; umount
#
# Их и делаем, но образ отдаём через SSH, а не через NFS-монтирование.
# Опции tar взяты дословно из COMMON_TAR_OPTIONS в логе заливки: менять их
# нельзя, иначе поедут владельцы файлов, xattr и метки SELinux/capabilities.

set -uo pipefail

# Каталог, куда распакован BSP. Переопределяется переменной окружения:
# остальные скрипты станции пользуются тем же умолчанием.
WORK="${WORK:-/srv/jetson}"
IMG="$WORK/Linux_for_Tegra/tools/kernel_flash/images/external/system.img"

# Адреса из l4t_initrd_flash.sh: плата поднимает USB-сеть с фиксированным
# link-local-подобным префиксом fc00:1:1:0::/64, хост берёт ::1, плата ::2.
BOARD=fc00:1:1:0::2
HOSTADDR=fc00:1:1:0::1
APP=/dev/nvme0n1p1

# Таймауты намеренно большие. Распаковка 2.2 ГБ -> 6.9 ГБ идёт минутами,
# в это время плата не отвечает на keepalive: ServerAliveCountMax=1000 при
# интервале 20 секунд даёт запас в несколько часов, и соединение не рвётся
# на самом длинном шаге. ConnectTimeout=60 — потому что USB-сеть платы
# поднимается не мгновенно после перехода в initrd.
SSHOPT="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=60 -o ServerAliveInterval=20 -o ServerAliveCountMax=1000"

step() { echo; echo "=== $* ==="; }

[ "$(id -u)" -eq 0 ] || { echo "Нужен root"; exit 1; }
[ -s "$IMG" ] || {
    echo "ОСТАНОВ: нет $IMG"
    echo "  Образ создаёт l4t_initrd_flash.sh на этапе подготовки; проверь \$WORK (сейчас $WORK)."
    exit 1
}

step "1. Плата в initrd flashing mode?"
if lsusb | grep -q '0955:7035'; then
    echo "OK: $(lsusb | grep '0955:7035')"
else
    echo "ОСТАНОВ: платы в initrd flashing mode (0955:7035) нет."
    lsusb | grep '0955:' || echo "  устройств 0955:* нет вовсе"
    echo
    echo "В этот режим плату оставляет 06-flash.sh: он грузит её по RCM"
    echo "и переводит в initrd. Причём оставляет даже тогда, когда сам"
    echo "падает на распаковке system.img, — а падает он там почти всегда."
    echo "Прогони 06-flash.sh, дождись обрыва на NFS и сразу запусти этот"
    echo "скрипт, не обесточивая плату."
    exit 1
fi

step "2. Адрес хоста на USB-интерфейсе платы"
# Скрипт L4T снимает адрес с интерфейса при выходе, поэтому после обрыва
# заливки его надо назначить заново.
#
# Перебираем /sys/class/net и ОБЯЗАТЕЛЬНО отсеиваем не-симлинки: в этом
# каталоге лежит обычный файл bonding_masters, и попытка спросить про него
# udevadm/readlink даёт мусорную ругань в вывод. Интерфейс платы опознаём
# по тому, что его устройство сидит на шине USB, — привязываться к
# конкретному PCI-адресу USB-контроллера нельзя, он свой на каждой станции.
IFACE=""
for n in /sys/class/net/*; do
    [ -L "$n" ] || continue
    name=$(basename "$n")
    # Предсказуемые имена USB-сетевух: enx<mac> и usb0/usb1.
    case "$name" in enx*|usb*) ;; *) continue ;; esac
    # Путь устройства в sysfs проходит через usb-контроллер.
    readlink -f "$n" | grep -q '/usb[0-9]*/' && IFACE="$name"
done

if [ -z "$IFACE" ]; then
    echo "ОСТАНОВ: USB-сетевого интерфейса платы нет."
    echo "  Видимые интерфейсы:"
    ip -br link | sed 's/^/    /'
    echo "  Плата поднимает его сама в initrd; если его нет — проверь кабель"
    echo "  USB-C и то, что 0955:7035 действительно виден в lsusb."
    exit 1
fi
echo "  интерфейс: $IFACE"
ip -6 a show "$IFACE" | grep -q 'fc00:1:1' || ip a add "$HOSTADDR/64" dev "$IFACE"
ip -br a show "$IFACE" | sed 's/^/  /'

# Одна точка вызова команд на плате. На физической станции chroot не нужен:
# sshpass и ssh стоят прямо в системе (их ставит install.sh расширения).
sshb() { sshpass -p root ssh $SSHOPT "root@$BOARD" "$1"; }

step "3. Связь с платой"
sshb 'echo OK; uname -r' | sed 's/^/  /' || { echo "ОСТАНОВ: плата не отвечает"; exit 1; }

step "4. Освобождаю APP от прошлых попыток"
# Оборванная заливка оставляет раздел смонтированным; форматировать его
# в таком виде нельзя.
sshb 'for m in $(mount | grep nvme0n1p1 | cut -d" " -f3); do umount "$m" 2>/dev/null; done; mount | grep -c nvme0n1p1' \
    | sed 's/^/  смонтировано после отмонтирования: /'

step "5. Форматирую APP заново"
echo "  (после оборванной распаковки в разделе лежит несколько ГБ мусора)"
if sshb 'command -v mke2fs >/dev/null 2>&1'; then
    sshb "mke2fs -t ext4 -F -q $APP && echo OK" | sed 's/^/  /'
else
    # Известная проблема: в initrd платы mke2fs может отсутствовать вовсе
    # ("mke2fs: command not found"). Это НЕ повод останавливаться: распаковка
    # ляжет поверх прежнего содержимого, а прежнее содержимое — это тот же
    # самый архив, только развёрнутый не до конца. Практически безвредно,
    # но раздел при этом не чист, и знать об этом надо.
    echo "  ВНИМАНИЕ: в initrd платы нет mke2fs — форматирование пропущено."
    echo "  Распаковка ляжет ПОВЕРХ прежнего содержимого раздела."
    echo "  Практически безвредно (тот же архив), но раздел не чист:"
    echo "  файлы, удалённые между версиями BSP, останутся."
fi

step "6. Монтирую APP"
sshb "mkdir -p /tmp/app && mount $APP /tmp/app && df -h /tmp/app | tail -1" | sed 's/^/  /' \
    || { echo "ОСТАНОВ: не смонтировался $APP"; exit 1; }

step "7. Передаю и распаковываю (2.2 ГБ -> 6.9 ГБ), несколько минут"
echo "  Образ идёт SSH-потоком: NFS не участвует."
SIZE=$(stat -c%s "$IMG")
echo "  размер: $SIZE байт"
# Опции tar — дословно COMMON_TAR_OPTIONS из лога заливки. Не трогать.
if sshpass -p root ssh $SSHOPT "root@$BOARD" \
      "tar -x -I 'zstd -T0' -p --warning=no-timestamp --numeric-owner \
         --xattrs --xattrs-include='*' -C /tmp/app" < "$IMG"; then
    echo "  распаковка завершилась без ошибки"
else
    rc=$?
    echo "  ОШИБКА распаковки, код $rc"
    sshb 'dmesg | tail -15' | sed 's/^/    /'
    sshb 'umount /tmp/app 2>/dev/null' >/dev/null 2>&1
    exit "$rc"
fi

step "8. sync и проверка"
sshb 'sync; echo "--- содержимое корня:"; ls /tmp/app | head -20; echo "--- занято:"; df -h /tmp/app | tail -1' | sed 's/^/  /'
echo
echo "--- ключевые файлы:"
# Эти четыре файла — минимальный признак того, что развернулся именно
# rootfs L4T, а не половина архива: релиз BSP, ядро, таблица монтирования
# и конфигурация загрузчика.
sshb 'for f in etc/nv_tegra_release boot/Image etc/fstab boot/extlinux/extlinux.conf; do printf "  %-38s " "$f"; [ -e "/tmp/app/$f" ] && echo есть || echo НЕТ; done'

step "9. Отмонтирую"
sshb 'sync; umount /tmp/app && echo "отмонтирован"' | sed 's/^/  /'

step "ГОТОВО"
cat <<'EOF'
Если в шаге 8 есть etc/nv_tegra_release и boot/Image — rootfs на месте.

Дальше:
  1. Обесточь плату.
  2. ОТСОЕДИНИ USB-C кабель от станции. Это не формальность: часть плат
     AGX Orin уходит в recovery (APX) сама, от одного факта подключённого
     кабеля к порту рядом с 40-пиновым разъёмом. С кабелем плата вместо
     загрузки снова окажется в APX, и будет казаться, что прошивка не удалась.
  3. Подай питание. Force Recovery НЕ нажимать.
  4. Дай загрузиться и проверь на плате:
        cat /etc/nv_tegra_release   # ждём R36 REVISION: 4.3
        uname -r                    # ждём 5.15.148-tegra
        lsblk                       # / на nvme0n1p1
EOF
