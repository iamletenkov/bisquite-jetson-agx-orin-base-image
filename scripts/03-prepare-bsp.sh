#!/bin/bash
# Шаг 3: разворачивание BSP — распаковка, оверлей QSPI, apply_binaries.sh,
# подмена libnvisppg.so из оверлея камер.
#
#     sudo bash /opt/nvidia-jetpack/03-prepare-bsp.sh
#
# Здесь всё выполняется НАТИВНО на станции: она и есть Ubuntu 22.04, ради
# которой станцию заводили. Прежний обходной путь — jammy-chroot на Debian 13 —
# больше не нужен, и вложенности chroot тут нет ровно одной штукой меньше.
# Что осталось от той истории: apply_binaries.sh сам делает chroot внутрь
# aarch64-rootfs, поэтому qemu-user-static и binfmt нужны по-прежнему.
#
# Итог шага — дерево $WORK/Linux_for_Tegra с готовым rootfs. Повторный запуск
# по уже готовому дереву ОТКЛОНЯЕТСЯ: apply_binaries необратим.

set -euo pipefail

WORK="${WORK:-/srv/jetson}"
DL="$WORK/downloads"
LFT="$WORK/Linux_for_Tegra"

BSP_FILE=Jetson_Linux_r36.4.3_aarch64.tbz2
RFS_FILE=Tegra_Linux_Sample-Root-Filesystem_r36.4.3_aarch64.tbz2
OV_QSPI_FILE=overlay_mb1bct_36.x.tbz2
OV_CAM_FILE=overlay_camera_36.4.3.tbz2

BSP_SHA1=3eb3c5a19a417313383c3bce297e07274a237e36
RFS_SHA1=0bdb4e655d48bdf7e7bd98d3b7b69480576bfd7e

# Ожидаемые MD5 библиотеки ISP. Совпали — значит подменяем именно то и
# именно на то; разошлись — оверлей или BSP другой ревизии, и молча
# копировать нельзя.
LIBISP_OVERLAY_MD5=5cccbf56e6e56f7f00fb09891517d67e
LIBISP_STOCK_MD5=bc9fe35d290fe21402c363cedeebdfff

step() { echo; echo "=== $* ==="; }

# ГРАБЛЯ: TMPDIR, унаследованный от окружения оператора (или от sudo с
# приватным /tmp), указывает на путь, которого внутри chroot нет, и
# nvidia-l4t-initrd падает на mktemp с "failed to create directory".
# Лечится не подстановкой другого пути, а отсутствием переменной вовсе.
#
# И сразу оговорка, почему тут нет `env -i`: скрипты L4T проверяют $USER,
# и пустое окружение ломает их раньше, чем помогает. Чистим точечно.
unset TMPDIR || true
echo "TMPDIR = [${TMPDIR:-}]   (обязано быть пусто)"
export USER="${USER:-$(id -un)}"

[ "$(id -u)" -eq 0 ] || { echo "ОСТАНОВ: нужен root (sudo bash $0)"; exit 1; }

# --------------------------------------------------- 0. барьеры до работы
step "0. Проверки перед долгими операциями"

# Барьер повторного запуска стоит ПЕРВЫМ. apply_binaries.sh распаковывает
# в rootfs десятки deb-пакетов и правит символические ссылки; накатывать
# его дважды — не «идемпотентно», а порча дерева. Начинать заново можно
# только с чистого места.
if [ -e "$LFT/rootfs/.applied-binaries" ]; then
    echo "ОСТАНОВ: apply_binaries уже накатан на это дерево"
    echo "  метка: $(cat "$LFT/rootfs/.applied-binaries")"
    echo
    echo "Повторять его нельзя. Чтобы собрать дерево начисто:"
    echo "    sudo rm -rf $LFT"
    echo "    sudo bash $0"
    exit 1
fi

for f in "$BSP_FILE" "$RFS_FILE" "$OV_QSPI_FILE" "$OV_CAM_FILE"; do
    [ -f "$DL/$f" ] || {
        echo "ОСТАНОВ: нет $DL/$f — сначала 01-fetch-l4t.sh"
        exit 1
    }
done

# Суммы пересчитываются и здесь, хотя их считал шаг 01. Дёшево (десяток
# секунд на 2.4 GB) против получаса apply_binaries поверх мусора — и
# закрывает случай «между шагами файл дописали, обрезали или подменили».
echo "Пересчитываю SHA1 (~10 c)..."
recheck() {
    local got
    got=$(sha1sum "$DL/$1" | cut -d' ' -f1)
    printf '%-58s ' "$1"
    if [ "$got" = "$2" ]; then
        echo "OK"
    else
        echo "НЕ СОВПАЛА"
        echo "  ждали: $2"
        echo "  вышло: $got"
        echo "ОСТАНОВ: перекачай файл (rm $DL/$1 && bash 01-fetch-l4t.sh)"
        exit 1
    fi
}
recheck "$BSP_FILE" "$BSP_SHA1"
recheck "$RFS_FILE" "$RFS_SHA1"

# binfmt нужен потому, что apply_binaries.sh делает chroot в aarch64-дерево
# и зовёт там dpkg. Без регистрации это "Exec format error" — только позже
# и на полпути. На живой Ubuntu регистрацию держит systemd-binfmt, ей
# достаточно установленного qemu-user-static (его ставит install.sh).
if [ ! -e /proc/sys/fs/binfmt_misc/qemu-aarch64 ]; then
    echo "ОСТАНОВ: qemu-aarch64 не зарегистрирован в binfmt_misc."
    echo "    sudo apt-get install -y qemu-user-static"
    echo "    sudo systemctl restart systemd-binfmt"
    exit 1
fi
grep -q '^enabled' /proc/sys/fs/binfmt_misc/qemu-aarch64 || {
    echo "ОСТАНОВ: регистрация qemu-aarch64 выключена:"
    cat /proc/sys/fs/binfmt_misc/qemu-aarch64
    exit 1
}
echo "binfmt: $(sed -n '2p' /proc/sys/fs/binfmt_misc/qemu-aarch64)"

# Место: BSP + rootfs + результат apply_binaries — порядка 25 GB.
avail_gb=$(df -BG --output=avail "$WORK" | tail -1 | tr -dc '0-9')
echo "свободно в $WORK: ${avail_gb} GB"
[ "${avail_gb:-0}" -ge 30 ] \
    || echo "ВНИМАНИЕ: меньше 30 GB. Дереву нужно ~25 GB, образам на шаге 05 — ещё."

# ------------------------------------------------------------- 1. BSP
step "1. Распаковка BSP (~683 MB, bzip2 однопоточный — пара минут)"
mkdir -p "$WORK"
if [ -d "$LFT/bootloader" ]; then
    echo "Linux_for_Tegra уже распакован — пропускаю"
else
    # -p обязателен: в дереве есть файлы с выставленными правами и
    # владельцами, и без них flash.sh соберёт неправильный образ.
    tar -xpf "$DL/$BSP_FILE" -C "$WORK"
fi
[ -x "$LFT/apply_binaries.sh" ] || { echo "ОСТАНОВ: нет $LFT/apply_binaries.sh"; exit 1; }

# --------------------------------------------------------- 2. оверлей QSPI
step "2. Оверлей QSPI (фикс таймингов mb1, обязателен)"
# Распаковывается в тот же родительский каталог, что и BSP: внутри архива
# путь начинается с ./Linux_for_Tegra/..., то есть он ложится поверх дерева
# сам. Операция чисто файловая, повторный прогон безвреден.
tar -xpf "$DL/$OV_QSPI_FILE" -C "$WORK"
QSPI_DTS="$LFT/bootloader/generic/BCT/tegra234-mb1-bct-device-p3701-0000.dts"
[ -f "$QSPI_DTS" ] || {
    echo "ОСТАНОВ: после оверлея нет $QSPI_DTS"
    echo "Состав оверлея изменился — проверь его руками (tar tf)."
    exit 1
}
ls -l "$QSPI_DTS"

# ------------------------------------------------------------ 3. rootfs
step "3. Распаковка sample rootfs (~1.8 GB, 5-10 минут)"
if [ -x "$LFT/rootfs/bin/bash" ]; then
    echo "rootfs уже распакован — пропускаю"
else
    mkdir -p "$LFT/rootfs"
    tar -xpf "$DL/$RFS_FILE" -C "$LFT/rootfs"
fi

step "4. Ранняя проверка эмуляции внутри целевого rootfs"
# Дешёвый отказ до получасовой операции: если тут ответ не aarch64,
# apply_binaries упадёт на том же самом, только позже и грязнее.
arch=$(chroot "$LFT/rootfs" /bin/bash -c "uname -m")
echo "uname -m внутри rootfs: $arch"
[ "$arch" = "aarch64" ] || { echo "ОСТАНОВ: ждали aarch64"; exit 1; }

# ------------------------------------------------------- 5. dev-узлы
step "5. Снимаю узлы, оставшиеся от прерванных прогонов"
# ГРАБЛЯ: apply_binaries делает mknod для /dev/random и /dev/urandom и
# падает с "mknod: File exists", если они уже есть. А есть они ровно
# после прерванного прогона — то есть отказ приходит именно тогда, когда
# оператор повторяет попытку. Снимаем ПЕРЕД каждым запуском.
rm -f "$LFT/rootfs/dev/random" "$LFT/rootfs/dev/urandom"
echo "rootfs/dev/{random,urandom} удалены"

step "6. apply_binaries.sh (10-30 минут под эмуляцией)"
echo "TMPDIR = [${TMPDIR:-}]   (обязано быть пусто)"
cd "$LFT"
./apply_binaries.sh

# --------------------------------------------------- 7. оверлей камер
step "7. Подмена libnvisppg.so из оверлея камер"
# Порядок здесь несущий: подмена делается ПОСЛЕ apply_binaries, потому что
# apply_binaries раскладывает штатный nvidia-l4t-camera и затирает файл.
# Сделаешь до — получишь тихо потерянную правку и неработающий ISP.
#
# Сам оверлей ничего не устанавливает: библиотека лежит в КОРНЕ
# Linux_for_Tegra внутри архива, а не в rootfs, и копируется руками.
TMPOV=$(mktemp -d "$WORK/.overlay-camera.XXXXXX")
trap 'rm -rf "$TMPOV"' EXIT
tar -xpf "$DL/$OV_CAM_FILE" -C "$TMPOV"

SRC="$TMPOV/Linux_for_Tegra/libnvisppg.so"
DST="$LFT/rootfs/usr/lib/aarch64-linux-gnu/tegra/libnvisppg.so"
[ -f "$SRC" ] || { echo "ОСТАНОВ: в оверлее нет $SRC"; exit 1; }
[ -f "$DST" ] || { echo "ОСТАНОВ: в rootfs нет $DST — apply_binaries отработал не до конца?"; exit 1; }

md5_src=$(md5sum "$SRC" | cut -d' ' -f1)
md5_dst=$(md5sum "$DST" | cut -d' ' -f1)
echo "из оверлея : $md5_src   (ждём $LIBISP_OVERLAY_MD5)"
echo "штатная    : $md5_dst   (ждём $LIBISP_STOCK_MD5)"
[ "$md5_src" = "$LIBISP_OVERLAY_MD5" ] \
    || echo "ВНИМАНИЕ: оверлей другой ревизии, чем проверенный нами."
# Штатная сумма может отличаться и законно — если скрипт перезапущен по
# уже подменённому файлу. Такой случай не отказ, а «уже сделано».
if [ "$md5_dst" = "$LIBISP_OVERLAY_MD5" ]; then
    echo "штатная уже равна оверлейной — подмена была сделана раньше"
elif [ "$md5_dst" != "$LIBISP_STOCK_MD5" ]; then
    echo "ВНИМАНИЕ: штатная библиотека не той ревизии, что мы видели."
fi

cp -f "$SRC" "$DST"
echo "после копии: $(md5sum "$DST" | cut -d' ' -f1)"

# ------------------------------------------------------------- 8. метка
step "8. Метка готовности дерева"
# Она же — барьер шага 0 при повторном запуске.
date -Iseconds > "$LFT/rootfs/.applied-binaries"
cat "$LFT/rootfs/.applied-binaries"

step "ГОТОВО"
du -sh "$LFT"
df -h "$WORK" | tail -1
echo
echo "Дальше — 04-customize-rootfs.sh (пользователь, пакеты, драйверы камер)."
