#!/bin/bash
# Шаг 2: драйверы камер Sensing SG8A-AGON-G2Y-A1 под JetPack 6.2 (L4T 36.4.3).
#
#     bash /opt/nvidia-jetpack/02-fetch-camera-drivers.sh
#
# Идемпотентен: уже склонированный репозиторий подтягивается git pull.
# Root не нужен — пишем только в $WORK.
#
# Что за железо: плата-адаптер SG8A-AGON-G2Y-A1 (8 портов GMSL2) и камеры
# Sensing SG2-AR0233C-5200-G2A на сенсоре AR0233.
#
# ПОЧЕМУ ПАКЕТ GMSL2x8, А НЕ YUV. Под JetPack6.2 у Sensing на эту плату лежат
# четыре пакета, и различаются они серединой имени: _YUV_, _GMSL2x8_,
# _AR2020MX4_VB1940X4_, _SDV11NM1x2_SHW3Gx4_. Здесь был зашит _YUV_ — по имени
# он выглядит «тем самым», потому что камера отдаёт YUV422, — и с ним камера
# НЕ РАБОТАЕТ: на всех восьми портах "sensor_probe camera sgx-yuv-gmsl2-N
# detect error", /dev/video* создаются, но поток пустой (Signal lost,
# одинаковые кадры ~41 КБ). Проверено на живой плате 2026-09-11: с _GMSL2x8_
# та же камера опознаётся и даёт живое видео 1280x960 UYVY.
#
# Пакеты не «одно и то же, собранное дважды» — расходятся по существу:
#   - Version.md: 20260317 против 20251217 у YUV, новее на три месяца;
#   - разное /boot/Image (md5 9af0ed04804d823a9ae6fe5a6e55c9d8 против
#     ff01c6c4b01c3a7c59d669ce6241d5ab при одинаковом размере 42304000);
#   - I2C-адреса камер 0x20..0x23, а у YUV 0x1a..0x1d;
#   - sgx-yuv-gmsl2.ko принимает GMSLMODE_0=/GMSLMODE_1= (режим линка
#     GMSL1 / GMSL2 6G / GMSL2 3G задаётся по портам); в YUV режим жёстко 6G;
#   - для AR0233 ставится sensor_mode=1,trig_mode=0,trig_pin=0x00020007,
#     а YUV ставил trig_pin=0xffff0007;
#   - есть pwm-gpio.ko и sgcam-gmsl2.ko, исходники dts/, четыре разных .dtbo
#     и generate_camera_overlay.py — генератор оверлея под набор камер;
#   - в Readme_yuv.md есть таблица соответствия разъёмов, которой в YUV нет.
# Имя файла оверлея у обоих пакетов ОДНО И ТО ЖЕ
# (tegra234-camera-yuv-gmsl2x8-overlay.dtbo, 72304 байта против 66964),
# поэтому при переходе не надо править extlinux.conf — но и отличить пакеты
# по имени оверлея нельзя. Не возвращай _YUV_ обратно.
#
# В меню quick_bring_up.sh из пакета GMSL2x8 наша камера — пункт
# "3 : SG2-AR0233-5200-G-Hxxx". Прежняя оговорка про "-5300-" (GW5300 против
# GW5200 — модель ISP, а не сенсора) относилась к меню YUV-пакета и здесь
# не применяется: имя пункта совпадает с маркировкой камеры.
#
# Про соседние ветки: в репозитории лежат также JetPack6.2.1 (L4T 36.4.4)
# и JetPack7.2.1. Переход на них — отдельная задача: другой L4T тянет за
# собой другой BSP в 01-fetch-l4t.sh и другую пару Image/DTB. Не смешивать.

set -euo pipefail

WORK="${WORK:-/srv/jetson}"
REPO_URL=https://github.com/SENSING-Technology/nvidia-jetson-camera-drivers
DEST="$WORK/camera-drivers"

# Путь к пакету внутри репозитория. В именах есть пробелы — все обращения
# к нему обязаны быть в кавычках, иначе ломается молча и не там, где заметно.
#
# Переменная, а не константа, и имя у неё то же, что в 04-customize-rootfs.sh,
# намеренно. Четыре пакета в этом каталоге отличаются набором камер, а не
# версией L4T: смена камеры — это смена пакета, и переопределять её должен
# оператор, а не правка скрипта. Общее имя переменной держит шаги
# согласованными: 02 качает, 04 кладёт в rootfs, и если умолчания разойдутся,
# на плату уедет не тот пакет, который проверяли.
CAMERA_PKG_REL="${CAMERA_PKG_REL:-Jetson AGX Orin Devkit/SG8A-AGON-G2Y-A1/JetPack6.2/SG8A_AGON_G2Y_A1_AGX_Orin_GMSL2x8_JP6.2_L4TR36.4.3}"
# Каталог версии JetPack — нужен только для диагностики, когда пакета нет.
JETPACK_DIR="$(dirname "$CAMERA_PKG_REL")"

step() { echo; echo "=== $* ==="; }

command -v git >/dev/null 2>&1 || { echo "ОСТАНОВ: нет git"; exit 1; }

step "0. Рабочий каталог $WORK"
if ! mkdir -p "$WORK" 2>/dev/null || [ ! -w "$WORK" ]; then
    echo "ОСТАНОВ: не могу писать в $WORK"
    echo "    sudo install -d -o \"\$(id -un)\" -g \"\$(id -gn)\" $WORK"
    exit 1
fi

step "1. Репозиторий Sensing -> $DEST"
if [ -d "$DEST/.git" ]; then
    echo "уже склонирован, обновляю"
    # fetch + reset --hard, а НЕ git pull --ff-only.
    #
    # --ff-only стоял здесь по верному доводу («лучше громкий отказ, чем
    # молчаливый merge-коммит в чужом репозитории»), но ловил не то: у
    # Sensing апстрим периодически переписывает историю целиком (замер
    # 2026-09-12 — `6db3fb3...0454830 (forced update)`, Version.md по датам
    # похож на регулярный ребилд, а не разовую случайность). На --depth 1
    # клоне это выглядит одинаково что при чужом force-push, что при наших
    # гипотетических локальных коммитах: `fatal: Not possible to
    # fast-forward, aborting`, и разово собранный образ станции падал бы
    # на этом шаге при каждом апдейте апстрима.
    #
    # Реальная цель прежнего кода — не «слить», а «не притвориться, что
    # слил, если это не так». `reset --hard` после `fetch` достигает её
    # честнее: дерево гарантированно становится точной копией удалённой
    # ветки, а не результатом угаданного мержа. Историю мы и так не
    # используем (--depth 1 в clone ниже), поэтому «отбросить локальное расхождение»
    # здесь равнозначно «взять то, что реально нужно» — сам артефакт.
    git -C "$DEST" fetch --depth 1 origin main
    git -C "$DEST" reset --hard origin/main
elif [ -e "$DEST" ]; then
    echo "ОСТАНОВ: $DEST существует, но это не git-репозиторий."
    echo "Убери его и запусти скрипт заново: rm -rf $DEST"
    exit 1
else
    # --depth 1: в репозитории лежат собранные Image и DTB под несколько
    # версий JetPack, полная история тянет лишние гигабайты, а нужна нам
    # ровно одна ревизия — текущая.
    git clone --depth 1 "$REPO_URL" "$DEST"
fi
echo "HEAD: $(git -C "$DEST" log -1 --format='%h %ad %s' --date=short)"

step "2. Проверка целевого каталога"
TARGET="$DEST/$CAMERA_PKG_REL"
if [ ! -d "$TARGET" ] || [ ! -f "$TARGET/quick_bring_up.sh" ]; then
    echo "ОСТАНОВ: не нашёл драйверы под нашу плату."
    echo "  ждали каталог : $CAMERA_PKG_REL"
    echo "  и в нём файл  : quick_bring_up.sh"
    echo
    echo "Структура репозитория у Sensing меняется между релизами —"
    echo "смотри, что реально лежит рядом, и укажи пакет явно:"
    echo "    CAMERA_PKG_REL='<путь от корня клона>' $0"
    echo
    if [ -d "$DEST/$JETPACK_DIR" ]; then
        echo "Содержимое \"$JETPACK_DIR\":"
        ls -1 "$DEST/$JETPACK_DIR" | sed 's/^/    /'
    elif [ -d "$DEST/Jetson AGX Orin Devkit/SG8A-AGON-G2Y-A1" ]; then
        echo "Каталога \"$JETPACK_DIR\" нет. Рядом лежат:"
        ls -1 "$DEST/Jetson AGX Orin Devkit/SG8A-AGON-G2Y-A1" | sed 's/^/    /'
    elif [ -d "$DEST/Jetson AGX Orin Devkit" ]; then
        echo "Каталога SG8A-AGON-G2Y-A1 нет. Рядом лежат:"
        ls -1 "$DEST/Jetson AGX Orin Devkit" | sed 's/^/    /'
    else
        echo "Верхний уровень репозитория:"
        ls -1 "$DEST" | sed 's/^/    /'
    fi
    exit 1
fi
echo "OK: $CAMERA_PKG_REL"

step "3. Что лежит в пакете драйверов"
ls -1 "$TARGET" | sed 's/^/    /'
echo
echo "размер: $(du -sh "$TARGET" | cut -f1)"

step "ГОТОВО"
echo "Пакет драйверов: $TARGET"
echo
echo "Он не ставится сейчас: 04-customize-rootfs.sh кладёт его внутрь"
echo "rootfs (в /opt/sensing), чтобы на плате он был сразу и без сети."
echo "Дальше — 03-prepare-bsp.sh."
