#!/usr/bin/env bash
# Снарядить Jetson как сборочный узел arm64 для слоёв bisquite.
#
#     bash tools/provision-arm-builder.sh
#
# ЗАЧЕМ ОТДЕЛЬНЫЙ УЗЕЛ. Слои VMFILE (`EXTENSION`, `INSTALL`, `RUN_COMMAND`)
# выполняют код ВНУТРИ ГОСТЯ, а libguestfs чужую архитектуру не эмулирует —
# значит собрать arm64-образ можно только на arm64-машине. Шаги BSP (01-09)
# к этому отношения не имеют: их инструментарий собран под x86 и быстрее
# всего идёт на станции прошивки.
#
# ЧТО ЭТОТ СКРИПТ НЕ ДЕЛАЕТ. Он не превращает робота в машину разработки:
# ни Node, ни фронтенда, ни MCP-обвязки. Только то, без чего `bs image build`
# не работает. Убрать за собой — `tools/cleanup-arm-builder.sh`.
set -euo pipefail

BISQUITE_REPO="${BISQUITE_REPO:-https://github.com/iamletenkov/bisquite.git}"
BISQUITE_SRC="${BISQUITE_SRC:-$HOME/bisquite}"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
step() { echo; echo -e "${GREEN}=== $* ===${NC}"; }
warn() { echo -e "${YELLOW}ВНИМАНИЕ:${NC} $*"; }
fail() { echo -e "${RED}ОТКАЗ:${NC} $*"; exit 1; }

# ---------------------------------------------------------------- преграды
step "0. Проверки"

[ "$(uname -m)" = "aarch64" ] || fail "это не arm64 ($(uname -m)). Слои VMFILE тут не соберутся в принципе."
[ "$(id -u)" -ne 0 ] || fail "запускать от обычного пользователя: окружение и хранилище bisquite заводятся в его \$HOME."
command -v sudo >/dev/null || fail "нужен sudo"

if [ -e /etc/nv_tegra_release ]; then
    echo "L4T: $(head -1 /etc/nv_tegra_release)"
    IS_L4T=1
else
    warn "/etc/nv_tegra_release нет — это не Jetson. Правка supermin ниже не понадобится."
    IS_L4T=0
fi
echo "ядро: $(uname -r)"
echo "ядер: $(nproc), память: $(free -g | awk '/Mem/{print $2}') ГБ"
df -h "$HOME" | tail -1

# KVM — не украшение. Без него libguestfs поднимает appliance под полной
# эмуляцией TCG: замер на Jetson Nano — 2 мин 42 с против 11,8 с, то есть
# примерно в 14 раз медленнее. Сборка образа робота на таком узле
# непрактична, поэтому отсутствие /dev/kvm — предупреждение с последствиями,
# а не мелочь.
step "1. KVM"
if [ -c /dev/kvm ]; then
    echo "/dev/kvm есть: $(stat -c '%A %U:%G' /dev/kvm)"
    kvm_group="$(stat -c %G /dev/kvm)"
    if id -nG | tr ' ' '\n' | grep -qx "$kvm_group"; then
        echo "пользователь $(id -un) уже в группе $kvm_group"
    else
        echo "добавляю $(id -un) в группу $kvm_group"
        sudo usermod -aG "$kvm_group" "$(id -un)"
        warn "группа достанется только новым сессиям — перелогинься перед сборкой."
    fi
else
    warn "/dev/kvm НЕТ — appliance пойдёт под эмуляцией, сборка будет примерно в 14 раз медленнее."
fi

# ------------------------------------------------------------- исходники
# ВАЖНО: репозиторий bisquite ЗАКРЫТЫЙ, и у сборочных узлов парка нет ни
# ключей GitHub, ни токенов. Клон по https там падает на
#   fatal: could not read Username for 'https://github.com'
# — то есть «нет исходников» здесь нормальное состояние, а не поломка, и
# отвечать на него надо инструкцией, а не трассировкой git.
step "2. Исходники bisquite -> $BISQUITE_SRC"
if [ -d "$BISQUITE_SRC/.git" ] || [ -f "$BISQUITE_SRC/pyproject.toml" ]; then
    echo "исходники уже на месте"
    git -C "$BISQUITE_SRC" pull --ff-only 2>/dev/null \
        || echo "  (обновить из сети не вышло — работаю с тем, что доставлено)"
elif git clone "$BISQUITE_REPO" "$BISQUITE_SRC" 2>/dev/null; then
    echo "склонировано из $BISQUITE_REPO"
else
    cat <<EOF

ОТКАЗ: исходников bisquite нет, и склонировать их отсюда нечем.
Репозиторий закрытый, а у этого узла нет ни ключа, ни токена GitHub.

Доставь их с машины, где они есть (исключения обязательны — .venv чужой
архитектуры не заработает, а .scratchpad содержит настоящие секреты):

    rsync -a --info=progress2 \\
        --exclude .venv --exclude .scratchpad --exclude .mcp.json \\
        --exclude node_modules --exclude htmlcov --exclude release \\
        --exclude '.*_cache' \\
        <путь>/bisquite/ $(id -un)@$(hostname -I | awk '{print $1}'):$BISQUITE_SRC/

и запусти скрипт заново.
EOF
    exit 1
fi
git -C "$BISQUITE_SRC" log --oneline -1 2>/dev/null || echo "(не git-чекаут — истории нет)"

# -------------------------------------------------------- системные пакеты
# Своего списка здесь нет намеренно: он есть у самого bisquite и сторожится
# его тестом (tests/test_install_deps_core_coverage.py). Вторая копия
# разъехалась бы с первой, как уже разъезжались копии в этом проекте.
step "3. Системные зависимости (make install-deps-core)"
make -C "$BISQUITE_SRC" install-deps-core

# ------------------------------------------------------- Python и окружение
# bisquite требует Python 3.14, а в jammy его нет и не будет. uv — штатный
# для проекта путь на таких хостах, цель dev-uv описана в его Makefile.
step "4. Окружение bisquite (make dev-uv)"
if [ -x "$BISQUITE_SRC/.venv/bin/bs" ]; then
    echo "окружение уже есть: $("$BISQUITE_SRC/.venv/bin/bs" --version 2>/dev/null || echo 'версия не печатается')"
else
    make -C "$BISQUITE_SRC" dev-uv
fi
[ -x "$BISQUITE_SRC/.venv/bin/bs" ] || fail "после dev-uv нет $BISQUITE_SRC/.venv/bin/bs"

# ------------------------------------------------------- supermin на L4T
#
# ГЛАВНАЯ ГРАБЛЯ ЭТОГО СКРИПТА. supermin (его зовёт libguestfs) ищет ядро
# для appliance по шаблону `vmlinu?-*`, а ядро L4T называется /boot/Image —
# под шаблон не подходит, и сборка падает на «supermin: no kernel found».
#
# Лечится подкладкой обычного ядра Ubuntu, и ставить его пакет ЧЕРЕЗ APT
# НЕЛЬЗЯ: постинсталл linux-image-* зовёт nv-update-extlinux, который
# переписывает /boot/extlinux/extlinux.conf — вместе с записью JetsonIO и
# оверлеем камер. На роботе с камерами это означает плату, которая после
# перезагрузки не видит камеры, а на плате без монитора — плату, которую
# чинить нечем.
#
# Поэтому: качаем deb, распаковываем dpkg -x (постинсталл НЕ выполняется),
# кладём ядро и модули руками.
step "5. Ядро для appliance supermin"
if [ "$IS_L4T" -eq 0 ]; then
    echo "не L4T — пропуск"
elif compgen -G "/boot/vmlinuz-*" > /dev/null; then
    echo "подходящее ядро уже лежит: $(ls /boot/vmlinuz-* | tr '\n' ' ')"
else
    KPKG="$(apt-cache depends linux-image-generic 2>/dev/null \
            | awk '/Depends: linux-image-[0-9]/{print $2; exit}')"
    [ -n "$KPKG" ] || fail "не нашёл пакет linux-image-* в apt — нечего подкладывать supermin"
    echo "пакет: $KPKG (скачиваем, НЕ устанавливаем)"

    TMPK="$(mktemp -d)"
    trap 'rm -rf -- "$TMPK"' EXIT
    ( cd "$TMPK" && apt-get download "$KPKG" ) || fail "apt-get download $KPKG не прошёл"
    dpkg -x "$TMPK"/"$KPKG"_*.deb "$TMPK/root"

    KVER="$(basename "$(ls -d "$TMPK/root/lib/modules/"*/ | head -1)")"
    [ -n "$KVER" ] || fail "в пакете нет /lib/modules/<версия>"
    echo "версия ядра из пакета: $KVER"

    sudo cp -f "$TMPK/root/boot/vmlinuz-$KVER" /boot/
    sudo cp -a "$TMPK/root/lib/modules/$KVER" /lib/modules/
    sudo depmod "$KVER"
    echo "положено: /boot/vmlinuz-$KVER и /lib/modules/$KVER"

    # extlinux.conf трогать нечем — пакет не устанавливался, постинсталла не было.
    echo "extlinux.conf не изменён (пакет не устанавливался):"
    grep -c '' /boot/extlinux/extlinux.conf 2>/dev/null | sed 's/^/  строк: /' || true
fi

# --------------------------------------------------- источник расширений
#
# Без него слой `EXTENSION` не соберётся: резолвер ищет расширения только
# в кеше <DATA_DIR>/extensions/ и в сеть за ними не ходит НИКОГДА — ни при
# сборке, ни при валидации. Наполняет кеш отдельная явная команда.
#
# Источник объявляем `type: path` на подмодуль этого репозитория, а не `git`:
# у сборочных узлов парка нет ключей GitHub, а у Jetson Nano GitHub по ssh
# недоступен вовсе. Путь обязан быть абсолютным — extensions.yaml лежит
# в каталоге данных, и относительный указывал бы не туда.
step "6. Источник расширений"
EXT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/bisquite-extensions"
DATA_DIR="${BISQUITE_DATA_DIR:-$HOME/.local/share/bisquite}"
if [ ! -d "$EXT_DIR/extensions" ]; then
    warn "нет $EXT_DIR — подмодуль не инициализирован (git submodule update --init), расширения не подключаю"
else
    mkdir -p "$DATA_DIR/data"
    cat > "$DATA_DIR/data/extensions.yaml" <<YAML
# Заведено tools/provision-arm-builder.sh.
# type: path, потому что у сборочных узлов нет ключей GitHub.
sources:
  - name: core
    type: path
    path: $EXT_DIR
YAML
    echo "объявлен источник core -> $EXT_DIR"
    BISQUITE_DATA_DIR="$DATA_DIR" "$BISQUITE_SRC/.venv/bin/bs" extension sync \
        || warn "bs extension sync не прошёл — без него сборка не найдёт ни одного расширения"
    BISQUITE_DATA_DIR="$DATA_DIR" "$BISQUITE_SRC/.venv/bin/bs" extension ls 2>/dev/null | head -5 || true
fi

# ПОСЛЕ КАЖДОЙ ПРАВКИ РАСШИРЕНИЙ НУЖЕН ПОВТОРНЫЙ `bs extension sync`:
# сборка читает КЕШ, а не источник. Без этого правка не доедет и промолчит.

# ------------------------------------------------------------- проверка
step "7. Проверка"
BS="$BISQUITE_SRC/.venv/bin/bs"
"$BS" self-check || warn "self-check нашёл недостающее — смотри таблицу выше"

echo
echo "libguestfs-test-tool (на KVM — секунды, без него — минуты):"
if command -v libguestfs-test-tool >/dev/null; then
    if timeout 600 libguestfs-test-tool > /tmp/lgtt.log 2>&1; then
        grep -E '^===== TEST FINISHED OK' /tmp/lgtt.log || echo "прошёл"
    else
        warn "libguestfs-test-tool не прошёл — подробности в /tmp/lgtt.log"
        tail -15 /tmp/lgtt.log
    fi
else
    warn "libguestfs-test-tool не установлен"
fi

step "ГОТОВО"
cat <<EOF
Сборочный узел снаряжён.

  bs        : $BS
  хранилище : \${BISQUITE_DATA_DIR:-\$HOME/.local/share/bisquite}
  исходники : $BISQUITE_SRC

Собирать слои:
  $BS image build --smp $(nproc) --memsize 16000 -f <vmfile> --tag <тег>

Прибрать за собой:
  bash tools/cleanup-arm-builder.sh          промежуточное и кеши
  bash tools/cleanup-arm-builder.sh --all    плюс исходники и окружение
EOF
