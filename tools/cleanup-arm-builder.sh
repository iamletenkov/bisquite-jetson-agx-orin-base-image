#!/usr/bin/env bash
# Прибрать за сборкой на arm64-узле: временные файлы, кеши, по желанию —
# исходники и окружение bisquite.
#
#     bash tools/cleanup-arm-builder.sh            промежуточное и кеши
#     bash tools/cleanup-arm-builder.sh --dry-run  только показать, что удалит
#     bash tools/cleanup-arm-builder.sh --all      плюс исходники и окружение
#
# ЧЕГО ЭТОТ СКРИПТ НЕ ДЕЛАЕТ НИКОГДА — не трогает собранные образы.
# Удалить образ значит выбросить часы сборки, и решение об этом принимает
# оператор командой `bs image rm <тег>`, глядя на список. Молча освобождать
# место за счёт результата работы — худший вид уборки.
set -euo pipefail

BISQUITE_SRC="${BISQUITE_SRC:-$HOME/bisquite}"
DATA_DIR="${BISQUITE_DATA_DIR:-$HOME/.local/share/bisquite}"
BS="${BS:-$BISQUITE_SRC/.venv/bin/bs}"

DRY=0
ALL=0
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY=1 ;;
        --all)     ALL=1 ;;
        -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
        *) echo "неизвестный аргумент: $arg"; exit 1 ;;
    esac
done

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
step() { echo; echo -e "${GREEN}=== $* ===${NC}"; }
warn() { echo -e "${YELLOW}ВНИМАНИЕ:${NC} $*"; }

free_before=$(df --output=avail -k "$HOME" | tail -1)

# Показать и (если не сухой прогон) удалить каталог целиком.
drop_dir() {
    local path="$1" why="$2" size
    [ -e "$path" ] || { printf '  %-52s %s\n' "$path" "нет"; return; }
    size="$(du -sh "$path" 2>/dev/null | cut -f1)"
    printf '  %-52s %-8s %s\n' "$path" "$size" "$why"
    [ "$DRY" -eq 1 ] && return
    rm -rf -- "$path"
}

step "1. Временный каталог bisquite"
# Он всегда <DATA_DIR>/tmp и переменной не настраивается (get_tmp_root).
# Сюда ложатся распакованные базы и промежуточные qcow2; после оборванной
# сборки тут остаются десятки гигабайт, на которые никто не смотрит.
drop_dir "$DATA_DIR/tmp" "промежуточные файлы сборки"
[ "$DRY" -eq 1 ] || mkdir -p "$DATA_DIR/tmp"

step "2. Кеш и потерянные манифесты хранилища"
if [ -x "$BS" ]; then
    if [ "$DRY" -eq 1 ]; then
        echo "  (сухой прогон) выполнилось бы: bs image prune --cache"
        BISQUITE_DATA_DIR="$DATA_DIR" "$BS" image ls 2>/dev/null | head -20 || true
    else
        BISQUITE_DATA_DIR="$DATA_DIR" "$BS" image prune --cache || warn "prune вернул ошибку"
    fi
else
    warn "нет $BS — хранилище не чищу"
fi

step "3. Мусор сборки в домашнем каталоге"
drop_dir "$HOME/.cache/uv"        "кеш загрузок uv"
drop_dir "$HOME/.cache/pip"       "кеш pip"
drop_dir "/tmp/lgtt.log"          "журнал libguestfs-test-tool"

if [ "$ALL" -eq 1 ]; then
    step "4. Исходники и окружение bisquite (--all)"
    # После этого собирать на узле нечем — снаряжать заново
    # скриптом provision-arm-builder.sh.
    drop_dir "$BISQUITE_SRC" "исходники и .venv"
    drop_dir "$HOME/.local/share/uv" "интерпретаторы, поставленные uv"
    warn "узел больше не умеет собирать. Вернуть: bash tools/provision-arm-builder.sh"
else
    step "4. Исходники bisquite"
    echo "  оставлены ($BISQUITE_SRC) — снести целиком: --all"
fi

step "ИТОГ"
free_after=$(df --output=avail -k "$HOME" | tail -1)
if [ "$DRY" -eq 1 ]; then
    echo "сухой прогон — ничего не удалено"
else
    echo "освобождено: $(( (free_after - free_before) / 1024 )) МБ"
fi
df -h "$HOME" | tail -1
echo
echo "Образы НЕ трогались. Список и удаление — руками:"
echo "    $BS image ls"
echo "    $BS image rm <тег>"
