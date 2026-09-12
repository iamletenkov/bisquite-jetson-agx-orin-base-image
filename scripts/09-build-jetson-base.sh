#!/bin/bash
# Шаг 9: ОДНА команда от сырого BSP до образа, зарегистрированного в bisquite.
#
#     sudo /opt/nvidia-jetpack/09-build-jetson-base.sh --fresh -t jetson-orin-base:36.4.3
#
# Ничего нового не делает — вызывает по порядку 01, 02, 03, 04 (с -U) и 08,
# затем `bs image import`. Каждый шаг сохраняет свои гарантии и свою
# идемпотентность в точности как при ручном прогоне; этот скрипт только
# избавляет от необходимости помнить порядок и различия между ними.
#
# ПОЧЕМУ -U (04 без учётки), а не как раньше с -u/-p:
# базовый образ уезжает на ВЕСЬ флот. Учётка "jetson"/"jetson", впечённая
# в него сценарием на один экземпляр, была бы вендорской заглушкой на
# каждой прошитой плате разом — а флоу оператора (как на amd64) в том,
# что креды кладёт cloud-init при ЗАПИСИ конкретного носителя, из манифеста.
# В образе остаётся только root, oem-config всё равно снят (см. -U в 04).
#
# ПОЧЕМУ --fresh ОБЯЗАТЕЛЕН, если дерево уже прошло 03/04 без -U:
# 03 необратим (apply_binaries накатывается один раз), и учётку, уже
# созданную прежним прогоном 04, снять нечем — только начать дерево заново.
# Без --fresh скрипт использует то дерево, что уже есть, каким бы оно ни
# было — это осознанный путь повторной сборки БЕЗ пересборки BSP (минуты
# вместо 20-45), но тогда состав учёток остаётся тем, что было раньше.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="${WORK:-/srv/jetson}"
LFT="$WORK/Linux_for_Tegra"

FRESH=0
TAG=""
HOSTNAME_ARG=""

usage() {
    cat <<'USAGE'
Использование:
  09-build-jetson-base.sh [--fresh] -t ИМЯ:ТЕГ [-n ИМЯ_ХОСТА]

  --fresh  снести дерево BSP и собрать заново (нужно, если прежний прогон
           04 создавал пользователя — см. комментарий в шапке файла).
           Без флага переиспользуется то, что уже лежит в $WORK.
  -t       тег, под которым результат ляжет в хранилище bisquite
           (обязательно, например jetson-orin-base:36.4.3)
  -n       имя хоста в /etc/hostname образа (необязательно)

Переменные окружения — те же, что читают 01-08: WORK, CAMERA_SRC,
CAMERA_PKG_REL, BOARD_TARGET, BOARD_SKU, ROOTFS_DEV, OUT_RAW, OUT_QCOW2.
См. их собственные --help / шапки файлов.
USAGE
}

while [ $# -gt 0 ]; do
    case "$1" in
        --fresh) FRESH=1; shift ;;
        -t) TAG="${2:-}"; shift 2 ;;
        -n) HOSTNAME_ARG="${2:-}"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "ОШИБКА: неизвестный аргумент: $1"; echo; usage; exit 1 ;;
    esac
done

[ -n "$TAG" ] || { echo "ОШИБКА: -t обязателен (тег для bs image import)."; echo; usage; exit 1; }
[ "$(id -u)" -eq 0 ] || { echo "Нужен root (sudo bash $0 ...)"; exit 1; }

step() { echo; echo "############ $* ############"; }
fail() { echo; echo "ОТКАЗ: $*"; exit 1; }

step "0. Инструменты этого скрипта"
# Предупреждение, а не отказ: шаги 0-6 (сборка образа) от bisquite не
# зависят вовсе, только шаг 7 (регистрация) — а у него самого есть мягкий
# fallback (см. шаг 7 ниже). Отказывать здесь значило бы срывать 20-45
# минут сборки из-за того, чего эта сборка ещё не касается: bisquite
# нужен станции с камнем на шее только в самом конце.
if ! command -v bs >/dev/null 2>&1; then
    echo "ПРЕДУПРЕЖДЕНИЕ: команды 'bs' нет в PATH — bisquite на этом хосте"
    echo "  не установлен (make dev-uv?). Образ соберётся, но шаг 7 не"
    echo "  зарегистрирует его — только напечатает путь к файлу."
fi

if [ "$FRESH" -eq 1 ]; then
    step "1. --fresh: сношу дерево BSP"
    # Загрузки (downloads/, camera-drivers/) НЕ трогаем — SHA1 у них уже
    # сверен, качать заново нечего. Сносим только Linux_for_Tegra, потому
    # что именно его 03 отказывается трогать повторно.
    if [ -d "$LFT" ]; then
        echo "удаляю $LFT ($(du -sh "$LFT" 2>/dev/null | cut -f1))..."
        rm -rf "$LFT"
    else
        echo "дерева и так нет — сносить нечего"
    fi
else
    echo "--fresh не задан — если в $LFT уже накатан 04 с учёткой,"
    echo "она останется в образе. Смотри вывод шага 04 ниже."
fi

step "2. 01-fetch-l4t.sh — BSP, sample rootfs, оверлеи"
"$SCRIPT_DIR/01-fetch-l4t.sh" || fail "01-fetch-l4t.sh вернул код $?"

step "3. 02-fetch-camera-drivers.sh — драйверы Sensing"
"$SCRIPT_DIR/02-fetch-camera-drivers.sh" || fail "02-fetch-camera-drivers.sh вернул код $?"

step "4. 03-prepare-bsp.sh — распаковка, apply_binaries"
if [ -e "$LFT/rootfs/.applied-binaries" ]; then
    # 03 сам откажет на этой метке (apply_binaries необратим) — проверяем
    # ЗДЕСЬ, а не даём ему упасть, чтобы напечатать по делу, а не его текст
    # "ОСТАНОВ" не к месту в середине чужого пайплайна.
    echo "apply_binaries уже накатан ($(cat "$LFT/rootfs/.applied-binaries")) — пропускаю"
    echo "(нужно заново — перезапусти с --fresh)"
else
    "$SCRIPT_DIR/03-prepare-bsp.sh" || fail "03-prepare-bsp.sh вернул код $?"
fi

step "5. 04-customize-rootfs.sh -U — без учётки, только root"
# -U не даёт задать hostname (04 связывает -n с созданием пользователя) —
# и образу флота свой hostname не нужен: его выставит cloud-init при
# записи конкретного носителя, отдельно для каждой платы.
if [ -n "$HOSTNAME_ARG" ]; then
    echo "ПРЕДУПРЕЖДЕНИЕ: -n игнорируется вместе с -U — 04 не умеет"
    echo "  задавать hostname без создания пользователя, а образу флота"
    echo "  свой hostname и не нужен: его выставит cloud-init при записи."
fi
"$SCRIPT_DIR/04-customize-rootfs.sh" -U || fail "04-customize-rootfs.sh вернул код $?"

step "6. 08-build-base-image.sh — образ диска, PARTUUID, qcow2"
"$SCRIPT_DIR/08-build-base-image.sh" || fail "08-build-base-image.sh вернул код $?"

step "7. bs image import — регистрация в хранилище bisquite"
QCOW2="${OUT_QCOW2:-$WORK/jetson-orin-base.qcow2}"
[ -s "$QCOW2" ] || fail "нет $QCOW2 — шаг 08 должен был его создать"
if bs image import --help >/dev/null 2>&1; then
    bs image import "$QCOW2" --tag "$TAG" || fail "bs image import вернул код $?"
    IMPORTED=1
else
    # На момент написания этого шага команда ещё не существует в bisquite —
    # образ уже готов, регистрация станет доступна отдельным релизом.
    # Не роняем иначе полностью успешную сборку из-за этого.
    echo "ПРЕДУПРЕЖДЕНИЕ: 'bs image import' в этой версии bisquite не найден."
    echo "  Образ собран и лежит здесь: $QCOW2"
    echo "  Зарегистрировать вручную, когда команда появится:"
    echo "    bs image import $QCOW2 --tag $TAG"
    IMPORTED=0
fi

step "ГОТОВО"
if [ "$IMPORTED" -eq 1 ]; then
    echo "Образ в хранилище bisquite под тегом: $TAG"
else
    echo "Образ собран (не зарегистрирован — см. предупреждение выше): $QCOW2"
fi
echo
echo "Дальше — обычный VMFILE:"
echo "  FROM $TAG"
echo "  LABEL arch=arm64"
echo
echo "Камеры, cloud-init и правка загрузочного конфига — ОТДЕЛЬНЫЙ слой"
echo "поверх этого образа (VMFILE на arm64-хосте с KVM), не часть базы."
