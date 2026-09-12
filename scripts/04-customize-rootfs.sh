#!/bin/bash
# Шаг 4: подготовка rootfs Jetson ДО генерации system.img.
#
#     sudo /opt/nvidia-jetpack/04-customize-rootfs.sh -u jetson -p 'пароль' [-n orin]
#
# Правка Linux_for_Tegra/rootfs/ перед сборкой образа официально поддерживается
# NVIDIA — это штатный способ внести в систему то, что иначе пришлось бы
# доставлять на уже прошитой плате, с монитором, клавиатурой и сетью.
#
# Порядок в цепочке: 03 распаковал BSP и накатил apply_binaries, здесь дерево
# доводится до готовности, 05 превращает его в system.img. Запускать после 05
# бессмысленно: образ уже собран, правка дерева в него не попадёт.
#
# Работаем НАТИВНО, на самой станции (Ubuntu 22.04). Никакого промежуточного
# chroot в jammy тут нет и быть не должно — станция и есть jammy. Единственный
# chroot — в целевой arm64-rootfs через qemu-aarch64-static.

set -uo pipefail

WORK="${WORK:-/srv/jetson}"
LFT="$WORK/Linux_for_Tegra"
ROOTFS="$LFT/rootfs"
CAMERA_SRC="${CAMERA_SRC:-$WORK/camera-drivers}"   # сюда кладёт скрипт 02
CAMERA_DST="$ROOTFS/opt/sensing"
# Скрипт 02 клонирует ВЕСЬ репозиторий Sensing: там пакеты под несколько
# версий JetPack, собранные Image и DTB и история git. Внутрь образа едет
# только одна папка — иначе system.img распухает на гигабайты, а на плате
# невозможно понять, какая из версий драйверов настоящая.
#
# Умолчание обязано совпадать с 02-fetch-camera-drivers.sh: там же записано,
# почему пакет _GMSL2x8_, а не _YUV_ (с YUV камера SG2-AR0233C-5200-G2A
# не работает — sensor_probe detect error на всех восьми портах). Разойдутся
# умолчания — 02 скачает один пакет, а на плату уедет другой.
CAMERA_PKG_REL="${CAMERA_PKG_REL:-Jetson AGX Orin Devkit/SG8A-AGON-G2Y-A1/JetPack6.2/SG8A_AGON_G2Y_A1_AGX_Orin_GMSL2x8_JP6.2_L4TR36.4.3}"

# Пакеты для работы с камерами: v4l-utils даёт v4l2-ctl (перечислить сенсоры,
# выставить формат), gstreamer — конвейер для проверки картинки, v4l2loopback
# нужен, когда поток надо отдать второму потребителю.
CAMERA_PACKAGES="v4l-utils gstreamer1.0-tools gstreamer1.0-plugins-good gstreamer1.0-plugins-bad v4l2loopback-utils"

step() { echo; echo "=== $* ==="; }

# Стоит ли пакет в ЦЕЛЕВОМ дереве. Спрашиваем базу dpkg нативно, через
# --admindir, а не через `chroot dpkg-query`: ответ нужен и тогда, когда
# эмуляция aarch64 не работает, — именно в этом случае важнее всего честно
# сказать, что в образе нет ничего. Формат базы тот же: rootfs L4T 36.x —
# это jammy, как и сама станция. Любой сбой опроса читается как
# «не установлен», то есть в сторону лишней работы, а не тихого пропуска.
pkg_installed() {
    [ -d "$ROOTFS/var/lib/dpkg" ] || return 1
    dpkg-query --admindir="$ROOTFS/var/lib/dpkg" -W -f='${Status}' "$1" 2>/dev/null \
        | grep -q 'install ok installed'
}

usage() {
    cat <<'USAGE'
Использование:
  04-customize-rootfs.sh -u ПОЛЬЗОВАТЕЛЬ -p ПАРОЛЬ [-n ИМЯ_ХОСТА]

  -u   имя пользователя, создаваемого в системе платы
  -p   его пароль
  -n   имя хоста платы (необязательно; по умолчанию — как решит L4T)
  -U   НЕ создавать пользователя вовсе — в системе остаётся только root.
       Несовместим с -u/-p. Для образов, куда учётку кладёт cloud-init
       при записи (bs device write), а не вендорский скрипт при сборке:
       базовый образ флота не должен нести ничьи конкретные креды.

Ровно одно из двух: либо -u и -p ВМЕСТЕ (обязательны друг с другом),
либо -U одна. Умолчаний у -u и -p нет намеренно: пароль, зашитый в скрипт,
попал бы в репозиторий и оттуда в каждый собранный образ. Учётные данные
задаёт оператор в момент сборки конкретной платы; для образа, который
разойдётся на флот, это -U.

Обход oem-config (мастера первичной настройки) происходит в ОБОИХ режимах
одинаково: он не привязан к созданию пользователя, это отдельный симлинк
default.target -> nv-oem-config.target, который снимается независимо.

Переменные окружения:
  WORK        рабочий каталог станции (умолчание /srv/jetson)
  CAMERA_SRC  распакованные драйверы камер (умолчание $WORK/camera-drivers)
  CAMERA_PKG_REL
              путь к пакету драйверов внутри клона Sensing. Умолчание —
              пакет GMSL2x8 под SG8A-AGON-G2Y-A1 и JetPack 6.2; менять его
              нужно при смене камер, и тем же значением в 02-fetch-camera-
              drivers.sh
USAGE
}

USER_NAME=""
PASSWORD=""
HOSTNAME_ARG=""
SKIP_USER=0

while getopts ":u:p:n:Uh" opt; do
    case "$opt" in
        u) USER_NAME="$OPTARG" ;;
        p) PASSWORD="$OPTARG" ;;
        n) HOSTNAME_ARG="$OPTARG" ;;
        U) SKIP_USER=1 ;;
        h) usage; exit 0 ;;
        :) echo "ОШИБКА: у -$OPTARG нет значения"; echo; usage; exit 1 ;;
        \?) echo "ОШИБКА: неизвестный ключ -$OPTARG"; echo; usage; exit 1 ;;
    esac
done

if [ "$SKIP_USER" -eq 1 ]; then
    if [ -n "$USER_NAME" ] || [ -n "$PASSWORD" ]; then
        echo "ОШИБКА: -U несовместим с -u/-p — либо учётка, либо её нет."
        echo
        usage
        exit 1
    fi
elif [ -z "$USER_NAME" ] || [ -z "$PASSWORD" ]; then
    echo "ОШИБКА: -u и -p обязательны (или используй -U, чтобы не создавать"
    echo "  пользователя вовсе)."
    echo
    usage
    exit 1
fi

[ "$(id -u)" -eq 0 ] || { echo "Нужен root"; exit 1; }

step "0. Проверка дерева BSP"
[ -d "$LFT" ] || { echo "ОСТАНОВ: нет $LFT — сначала 03-prepare-bsp.sh"; exit 1; }
[ -x "$ROOTFS/bin/bash" ] || { echo "ОСТАНОВ: rootfs не распакован — сначала 03-prepare-bsp.sh"; exit 1; }
[ -e "$ROOTFS/.applied-binaries" ] || {
    echo "ОСТАНОВ: apply_binaries.sh не накатан на это дерево."
    echo "Кастомизировать rootfs до него бессмысленно: он перезапишет часть файлов."
    exit 1
}
# Бинд-монтирование хостового /dev в целевой rootfs — то, чего здесь быть
# не должно: ниже стоит rm узлов /dev/random и /dev/urandom, и поверх
# смонтированного /dev он снёс бы их у СТАНЦИИ.
if mountpoint -q "$ROOTFS/dev" 2>/dev/null; then
    echo "ОСТАНОВ: $ROOTFS/dev смонтирован. Отмонтируй его: umount $ROOTFS/dev"
    exit 1
fi
echo "OK: $LFT"

# --------------------------------------------------------------------------
step "1. Пользователь и отключение oem-config"
# l4t_create_default_user.sh делает ДВЕ вещи, и вторая важнее первой:
# создаёт пользователя И снимает мастер первичной настройки (oem-config).
# Без него плата на первой загрузке останавливается на экране «выберите язык
# и часовой пояс» и ждёт человека с монитором и клавиатурой — то есть
# заливка вслепую, «прошил и поставил на полку», не работает вовсе.
# Ключ -a включает автологин созданного пользователя.
cd "$LFT" || exit 1

if [ "$SKIP_USER" -eq 1 ]; then
    # Пользователя не создаём вовсе — но oem-config снять всё равно надо,
    # иначе первая загрузка встанет на мастер настройки без сети и монитора.
    # l4t_create_default_user.sh делает это строкой
    # `rm -f etc/systemd/system/default.target` как ПОБОЧНЫЙ эффект создания
    # учётки; здесь та же строка — ЕДИНСТВЕННОЕ, что нам от него нужно.
    NON_ROOT=$(awk -F: '$3 >= 1000 && $3 != 65534 {print $1}' "$ROOTFS/etc/passwd" 2>/dev/null)
    if [ -n "$NON_ROOT" ]; then
        echo "ПРЕДУПРЕЖДЕНИЕ: -U просили, но в дереве уже есть учётка(и): $NON_ROOT"
        echo "  -U их не удаляет — дерево не чистое. Начни заново с 03-prepare-bsp.sh,"
        echo "  если нужен образ ровно с одним root."
    else
        echo "пользователя не создаю (-U) — в системе останется только root"
    fi
    rm -f "$ROOTFS/etc/systemd/system/default.target"
elif grep -q "^${USER_NAME}:" "$ROOTFS/etc/passwd" 2>/dev/null; then
    echo "пользователь '$USER_NAME' в rootfs уже есть — повторно не создаю"
    echo "(если нужен другой пароль — начни дерево заново с 03-prepare-bsp.sh)"
else
    CREATE_ARGS=(-u "$USER_NAME" -p "$PASSWORD" -a)
    [ -n "$HOSTNAME_ARG" ] && CREATE_ARGS+=(-n "$HOSTNAME_ARG")
    # --accept-license есть не во всех версиях BSP; без него скрипт в части
    # выпусков останавливается на подтверждении лицензии и ждёт ввода,
    # то есть автоматический прогон подвисает. Добавляем, только если ключ
    # реально объявлен в этом BSP, а не «на всякий случай».
    if grep -q -- '--accept-license' tools/l4t_create_default_user.sh 2>/dev/null; then
        CREATE_ARGS+=(--accept-license)
    fi
    echo "запускаю: tools/l4t_create_default_user.sh -u $USER_NAME -p *** ${CREATE_ARGS[*]:4}"
    ./tools/l4t_create_default_user.sh "${CREATE_ARGS[@]}"
    rc=$?
    if [ "$rc" -ne 0 ]; then
        echo "ОСТАНОВ: l4t_create_default_user.sh вернул $rc"
        exit 1
    fi
    grep -q "^${USER_NAME}:" "$ROOTFS/etc/passwd" \
        || { echo "ОСТАНОВ: скрипт отработал, но пользователя в rootfs/etc/passwd нет"; exit 1; }
    echo "пользователь '$USER_NAME' создан"
fi

# Проверяем результат по факту, а не по имени файла-маркера: имена юнитов
# oem-config между выпусками L4T менялись, а вопрос всегда один — взведён ли
# мастер первичной настройки.
#
# Факт — это ОДИН симлинк: /etc/systemd/system/default.target ->
# nv-oem-config.target, он перекрывает штатный
# /lib/systemd/system/default.target -> graphical.target. Именно его снимает
# tools/l4t_create_default_user.sh («remove default.target symlink to bypass
# oem config setup»). А сами юниты nv-oem-config.* лежат в rootfs ВСЕГДА,
# поэтому прежний поиск по имени (`find -name '*oem-config*'`) давал ложную
# тревогу на каждом прогоне: файлы есть, а мастер не взведён — проверено
# 2026-09-11 на прошитой плате (default.target отсутствует,
# `systemctl get-default` = graphical.target, nv-oem-config.service inactive).
OEM_LEFT=""
OEM_DEFAULT_TARGET="$ROOTFS/etc/systemd/system/default.target"
if [ -L "$OEM_DEFAULT_TARGET" ]; then
    # readlink БЕЗ -f: цель симлинка абсолютна внутри дерева платы
    # (/lib/systemd/system/nv-oem-config.target), и -f разрешал бы её
    # по корню СТАНЦИИ, то есть смотрел бы не туда.
    OEM_TARGET_LINK="$(readlink "$OEM_DEFAULT_TARGET")"
    case "$(basename "$OEM_TARGET_LINK")" in
        *oem-config*) OEM_LEFT="default.target -> $OEM_TARGET_LINK" ;;
    esac
elif [ -e "$OEM_DEFAULT_TARGET" ]; then
    # Не симлинк, а подложенный файл юнита — такое же переопределение
    # штатного default.target, поэтому смотрим в содержимое.
    if grep -q 'oem-config' "$OEM_DEFAULT_TARGET" 2>/dev/null; then
        OEM_LEFT="default.target (файл юнита, ссылается на oem-config)"
    fi
fi

if [ -n "$OEM_LEFT" ]; then
    echo "ПРЕДУПРЕЖДЕНИЕ: мастер первичной настройки взведён — $OEM_LEFT"
    echo "Первая загрузка потребует монитор и клавиатуру."
    echo "Поправить: rm -f $OEM_DEFAULT_TARGET"
elif [ -e "$OEM_DEFAULT_TARGET" ] || [ -L "$OEM_DEFAULT_TARGET" ]; then
    echo "oem-config не взведён: default.target ведёт не на него" \
         "($(readlink "$OEM_DEFAULT_TARGET" 2>/dev/null || echo 'файл юнита'))"
else
    echo "oem-config не взведён: /etc/systemd/system/default.target нет,"
    echo "  значит действует штатный /lib/systemd/system/default.target -> graphical.target"
fi

# --------------------------------------------------------------------------
step "2. Пакеты для камер внутрь rootfs (эмуляция aarch64)"
# Две правки дерева, которые нужны ВСЕГДА, а не только когда работает
# эмуляция: каждая ломает apt и внутри chroot, и потом на самой плате.

# (а) /dev/null. В распакованном sample rootfs это обычный пустой файл
# с правами 644, а не символьное устройство. apt-key работает от
# непривилегированного пользователя _apt, пишет в /dev/null и получает
# Permission denied, а наружу это выходит ЛОЖНЫМ сообщением
# «E: gpgv, gpgv2 or gpgv1 required for verification, but neither seems
# installed» — при том, что /usr/bin/gpgv в дереве есть. Подписи в итоге
# не проверяются, apt-get update падает (замер 2026-09-11).
#
# Узел остаётся в дереве, в конце шага он НЕ снимается — в отличие от
# /dev/random и /dev/urandom ниже. Довод: random/urandom создаёт
# эмулированный apt, в исходном дереве их не было, и они ломают упаковку
# в system.img; /dev/null же есть в любом нормальном rootfs, на загруженной
# плате он всё равно перекрыт devtmpfs, а снять его значило бы вернуть
# в дерево тот самый битый файл-заглушку — и следующий chroot (повторный
# прогон 04, ручная правка оператором) наступил бы на то же место.
mkdir -p "$ROOTFS/dev"
if [ -c "$ROOTFS/dev/null" ]; then
    echo "/dev/null в rootfs: символьное устройство — как надо"
else
    rm -f "$ROOTFS/dev/null"
    if mknod -m 666 "$ROOTFS/dev/null" c 1 3; then
        echo "/dev/null в rootfs: создан узел c 1 3 (был обычный файл — из-за него apt-key ломал проверку подписей)"
    else
        # Узел не создался (root есть — значит дело в файловой системе дерева).
        # Возвращаем пустой файл: дерево остаётся ровно таким, каким было,
        # и в chroot «>/dev/null» хотя бы не отказывает с «нет такого файла».
        : > "$ROOTFS/dev/null" 2>/dev/null || true
        chmod 666 "$ROOTFS/dev/null" 2>/dev/null || true
        echo "ПРЕДУПРЕЖДЕНИЕ: не удалось создать узел $ROOTFS/dev/null —"
        echo "  apt в chroot будет ложно жаловаться на отсутствие gpgv"
    fi
fi

# (б) <SOC> в источнике apt NVIDIA. В
# /etc/apt/sources.list.d/nvidia-l4t-apt-source.list лежит буквальный шаблон
# «jetson/<SOC>»: подстановку делает postinst пакета nvidia-l4t-apt-source,
# а под qemu он до неё не доходит. Итог — apt возвращает 100 («does not have
# a Release file»), а так как ниже стоит «apt-get update && apt-get install»,
# установка не запускается ВООБЩЕ и пакеты камер молча не попадают в образ
# (замер 2026-09-11).
#
# Значение берём из самого postinst, а не хардкодим: t234 — это Tegra234,
# то есть именно Orin, а расширение называется nvidia-jetpack, и на другой
# плате (Xavier — t194, TX2 — t186) верным было бы другое. postinst лежит
# в этом же дереве и является тем самым кодом NVIDIA, который должен был
# отработать, — поэтому он и есть источник истины. Фолбэк t234 стоит потому,
# что вся цепочка станции (01-03 и CAMERA_PKG_REL) прибита к AGX Orin
# на JetPack 6.2.
NV_APT_LIST="$ROOTFS/etc/apt/sources.list.d/nvidia-l4t-apt-source.list"
if [ -f "$NV_APT_LIST" ] && grep -q '<SOC>' "$NV_APT_LIST"; then
    NV_POSTINST="$ROOTFS/var/lib/dpkg/info/nvidia-l4t-apt-source.postinst"
    NV_SOC=""
    if [ -f "$NV_POSTINST" ]; then
        NV_SOC=$(sed -n 's|.*s/<SOC>/\([a-z0-9][a-z0-9]*\)/g.*|\1|p' "$NV_POSTINST" | head -1)
    fi
    if [ -n "$NV_SOC" ]; then
        echo "источник apt NVIDIA: SOC взят из postinst пакета — $NV_SOC"
    else
        NV_SOC="t234"
        echo "ПРЕДУПРЕЖДЕНИЕ: подстановку <SOC> в postinst не нашёл — беру $NV_SOC (Tegra234, AGX Orin)"
    fi
    sed -i "s/<SOC>/$NV_SOC/g" "$NV_APT_LIST"
    sed -n '/^deb /p' "$NV_APT_LIST" | sed 's|^|  |'
elif [ -f "$NV_APT_LIST" ]; then
    echo "источник apt NVIDIA: <SOC> уже подставлен"
fi

# Установка пакетов — шаг НЕОБЯЗАТЕЛЬНЫЙ по последствиям: те же пакеты
# ставятся и на плате, apt там работает. Поэтому отсутствие binfmt —
# предупреждение и пропуск, а не останов: ронять подготовку прошивки
# из-за необязательного удобства значило бы менять цену отказа местами.
SKIP_PKGS=0
if [ ! -e /proc/sys/fs/binfmt_misc/qemu-aarch64 ]; then
    echo "ПРЕДУПРЕЖДЕНИЕ: binfmt для aarch64 не зарегистрирован"
    echo "  (/proc/sys/fs/binfmt_misc/qemu-aarch64 отсутствует)"
    # binfmt-support здесь НЕ советуем намеренно: именно его конфликт
    # с systemd-binfmt стоял первым в списке отказов 2026-09-09
    # («chroot: failed to run command 'dpkg': Exec format error»).
    # Регистрацию на станцию кладёт install.sh расширения —
    # /etc/binfmt.d/qemu-aarch64.conf, его применяет systemd-binfmt.
    echo "  Поправить на станции:"
    echo "    ls /etc/binfmt.d/qemu-aarch64.conf   # должен быть от расширения"
    echo "    systemctl restart systemd-binfmt"
    SKIP_PKGS=1
elif [ ! -x "$ROOTFS/usr/bin/qemu-aarch64-static" ]; then
    # apply_binaries кладёт интерпретатор внутрь дерева сам; если его там нет,
    # переносим свой — регистрация binfmt указывает на путь ВНУТРИ chroot.
    if [ -x /usr/bin/qemu-aarch64-static ]; then
        cp -f /usr/bin/qemu-aarch64-static "$ROOTFS/usr/bin/qemu-aarch64-static"
        echo "qemu-aarch64-static скопирован в rootfs"
    else
        echo "ПРЕДУПРЕЖДЕНИЕ: qemu-aarch64-static нет ни в rootfs, ни на станции"
        SKIP_PKGS=1
    fi
fi

if [ "$SKIP_PKGS" -eq 0 ]; then
    # Грабля: TMPDIR, унаследованный от станции, указывает на путь, которого
    # внутри chroot не существует, и первый же mktemp в постустановочном
    # скрипте падает. Не «поправить», а не задавать вовсе.
    unset TMPDIR || true
    echo "TMPDIR = [${TMPDIR:-}]  (обязано быть пусто)"

    # Грабля: узлы /dev/random и /dev/urandom, оставшиеся от прерванных
    # прогонов под qemu, ломают последующую упаковку дерева. Снимаем их
    # и до, и после работы — дерево должно уходить в 05 чистым.
    rm -f "$ROOTFS/dev/random" "$ROOTFS/dev/urandom"

    # /proc нужен apt и постустановочным скриптам; /sys и /dev НЕ монтируем —
    # см. проверку в шаге 0.
    mkdir -p "$ROOTFS/proc"
    PROC_MOUNTED=0
    if ! mountpoint -q "$ROOTFS/proc"; then
        mount -t proc proc "$ROOTFS/proc" && PROC_MOUNTED=1
    fi

    ARCH_IN_ROOTFS=$(chroot "$ROOTFS" /bin/bash -c "uname -m" 2>/dev/null)
    echo "uname -m внутри rootfs: [${ARCH_IN_ROOTFS:-пусто}]  (ждём aarch64)"
    if [ "$ARCH_IN_ROOTFS" != "aarch64" ]; then
        echo "ПРЕДУПРЕЖДЕНИЕ: эмуляция не работает — пакеты пропущены."
        echo "  Их можно поставить на плате после прошивки:"
        echo "  sudo apt-get install -y $CAMERA_PACKAGES"
        SKIP_PKGS=1
    fi
fi

if [ "$SKIP_PKGS" -eq 0 ]; then
    # Идемпотентность: спрашиваем dpkg, что уже стоит, и ставим только
    # недостающее. Повторный запуск скрипта не должен ни дублировать записи,
    # ни платить получасом эмулированного apt за ничего.
    missing=""
    for p in $CAMERA_PACKAGES; do
        if pkg_installed "$p"; then
            printf '  %-32s уже стоит\n' "$p"
        else
            printf '  %-32s нужен\n' "$p"
            missing="$missing $p"
        fi
    done

    if [ -z "$missing" ]; then
        echo "все пакеты уже в rootfs — apt не запускаю"
    else
        # policy-rc.d возвращает 101 — «запускать сервисы запрещено».
        # Без него postinst попытается стартовать демонов под qemu, где нет
        # ни systemd, ни настоящего ядра, и часть пакетов останется
        # в состоянии «настройка не завершена».
        POLICY="$ROOTFS/usr/sbin/policy-rc.d"
        POLICY_MADE=0
        if [ ! -e "$POLICY" ]; then
            printf '#!/bin/sh\nexit 101\n' > "$POLICY"
            chmod +x "$POLICY"
            POLICY_MADE=1
        fi

        # resolv.conf в rootfs — симлинк на stub-resolv.conf systemd-resolved,
        # внутри chroot он никуда не ведёт, и apt не резолвит зеркала.
        # Подменяем на время работы и ОБЯЗАТЕЛЬНО возвращаем: оставленный
        # обычный файл сломал бы resolved уже на плате.
        RESOLV="$ROOTFS/etc/resolv.conf"
        RESOLV_BAK="$ROOTFS/etc/resolv.conf.04-backup"
        RESOLV_SAVED=0
        if [ -e "$RESOLV" ] || [ -L "$RESOLV" ]; then
            mv -f "$RESOLV" "$RESOLV_BAK" && RESOLV_SAVED=1
        fi
        cp -f /etc/resolv.conf "$RESOLV" 2>/dev/null || echo "nameserver 8.8.8.8" > "$RESOLV"

        echo
        echo "ставлю:$missing  (под эмуляцией это медленно, 5-20 минут)"
        chroot "$ROOTFS" /usr/bin/env -u TMPDIR \
            DEBIAN_FRONTEND=noninteractive LC_ALL=C \
            PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
            /bin/bash -c "apt-get -qq update && apt-get -y install --no-install-recommends$missing"
        apt_rc=$?

        [ "$RESOLV_SAVED" -eq 1 ] && mv -f "$RESOLV_BAK" "$RESOLV"
        [ "$POLICY_MADE" -eq 1 ] && rm -f "$POLICY"

        if [ "$apt_rc" -ne 0 ]; then
            echo "ПРЕДУПРЕЖДЕНИЕ: apt внутри rootfs вернул $apt_rc."
            echo "  Прошивке это не мешает — доставь недостающее уже на плате."
        else
            echo "пакеты установлены"
        fi
    fi

    # Дерево уходит дальше без узлов, которые мог создать эмулированный apt.
    rm -f "$ROOTFS/dev/random" "$ROOTFS/dev/urandom"
    if [ "${PROC_MOUNTED:-0}" -eq 1 ]; then
        umount "$ROOTFS/proc" 2>/dev/null || umount -l "$ROOTFS/proc" 2>/dev/null
    fi
fi

# --------------------------------------------------------------------------
step "3. Драйверы камер в /opt/sensing"
# Кладём заранее, чтобы после прошивки плата не зависела от сети: пакет
# Sensing тянется с их зеркала, а на столе у прошитой платы сети может
# не быть вовсе.
CAMERA_PKG=""
if [ ! -d "$CAMERA_SRC" ]; then
    echo "ПРЕДУПРЕЖДЕНИЕ: $CAMERA_SRC не найден — драйверы камер НЕ попадут в образ."
    echo "  Прогони 02-fetch-camera-drivers.sh, если камеры нужны."
elif [ -f "$CAMERA_SRC/quick_bring_up.sh" ]; then
    # Оператор указал CAMERA_SRC прямо на пакет — берём как есть.
    CAMERA_PKG="$CAMERA_SRC"
elif [ -d "$CAMERA_SRC/$CAMERA_PKG_REL" ]; then
    CAMERA_PKG="$CAMERA_SRC/$CAMERA_PKG_REL"
else
    # Структура репозитория у Sensing между релизами менялась, поэтому
    # ищем по признаку, а не по пути: каталог, в котором лежит
    # quick_bring_up.sh. .git исключаем явно — там встречаются те же имена
    # в объектах рабочего дерева соседних веток.
    mapfile -t FOUND < <(find "$CAMERA_SRC" -name 'quick_bring_up.sh' -not -path '*/.git/*' -printf '%h\n' | sort -u)
    if [ "${#FOUND[@]}" -eq 0 ]; then
        echo "ПРЕДУПРЕЖДЕНИЕ: в $CAMERA_SRC нет quick_bring_up.sh — пакет драйверов не опознан."
        echo "  Ждали: $CAMERA_PKG_REL"
    elif [ "${#FOUND[@]}" -eq 1 ]; then
        CAMERA_PKG="${FOUND[0]}"
        echo "пакет опознан поиском: ${CAMERA_PKG#"$CAMERA_SRC"/}"
    else
        # Молча выбрать один из нескольких — значит увезти на плату
        # драйверы не под ту камеру и узнать об этом уже на столе.
        # Фильтр по версии L4T однозначности НЕ даёт: под одну плату и одну
        # версию JetPack у Sensing лежат четыре пакета (YUV, GMSL2x8,
        # AR2020MX4_VB1940X4, SDV11NM1x2_SHW3Gx4), и все четыре содержат
        # L4TR36.4.3. Поэтому он только сужает список, а выбирает оператор:
        # взять «последний подошедший» значило бы с равной вероятностью
        # увезти неработающий YUV.
        L4T_MATCH=()
        for d in "${FOUND[@]}"; do
            case "$d" in *L4TR36.4.3*) L4T_MATCH+=("$d") ;; esac
        done
        if [ "${#L4T_MATCH[@]}" -eq 1 ]; then
            CAMERA_PKG="${L4T_MATCH[0]}"
            echo "кандидатов несколько, единственный под L4T 36.4.3: ${CAMERA_PKG#"$CAMERA_SRC"/}"
        elif [ "${#L4T_MATCH[@]}" -gt 1 ]; then
            echo "ПРЕДУПРЕЖДЕНИЕ: под L4T 36.4.3 подходит несколько пакетов —"
            echo "  они отличаются набором камер, и выбрать за оператора нельзя:"
            printf '    %s\n' "${L4T_MATCH[@]#"$CAMERA_SRC"/}"
            echo "  Укажи нужный явно: CAMERA_PKG_REL='...' $0 -u ... -p ..."
        else
            echo "ПРЕДУПРЕЖДЕНИЕ: кандидатов несколько, ни один не про L4T 36.4.3:"
            printf '    %s\n' "${FOUND[@]#"$CAMERA_SRC"/}"
            echo "  Укажи нужный явно: CAMERA_PKG_REL='...' $0 -u ... -p ..."
        fi
    fi
fi

if [ -n "$CAMERA_PKG" ]; then
    mkdir -p "$CAMERA_DST"
    # Идемпотентность через замену, а не через докладывание: cp поверх
    # существующего каталога оставил бы файлы прошлой версии драйверов,
    # и понять, какая из них поедет на плату, было бы нельзя.
    rm -rf "$CAMERA_DST"
    mkdir -p "$CAMERA_DST"
    # Копируем СОДЕРЖИМОЕ пакета, а не сам каталог: на плате ждут
    # /opt/sensing/quick_bring_up.sh, а не /opt/sensing/<длинное имя>/...
    cp -a "$CAMERA_PKG/." "$CAMERA_DST/"
    # Права на скрипты теряются при выкладке через zip и веб-архивы,
    # а quick_bring_up.sh зовёт соседние скрипты по имени.
    find "$CAMERA_DST" -name '*.sh' -exec chmod +x {} + 2>/dev/null
    if [ -f "$CAMERA_DST/quick_bring_up.sh" ]; then
        echo "quick_bring_up.sh: /opt/sensing/quick_bring_up.sh (+x)"
    else
        echo "ПРЕДУПРЕЖДЕНИЕ: quick_bring_up.sh не оказался в корне /opt/sensing"
    fi
    echo "источник   : ${CAMERA_PKG#"$CAMERA_SRC"/}"
    echo "скопировано: $(du -sh "$CAMERA_DST" | cut -f1) в /opt/sensing"
fi

# --------------------------------------------------------------------------
step "ИТОГ"
echo "rootfs:            $ROOTFS"
if [ "$SKIP_USER" -eq 1 ]; then
    echo "пользователь:      нет — только root (-U)"
else
    echo "пользователь:      $USER_NAME (автологин включён)"
fi
[ -n "$HOSTNAME_ARG" ] && echo "имя хоста:         $HOSTNAME_ARG"
if [ -n "$OEM_LEFT" ]; then
    echo "oem-config:        ОСТАЛСЯ (см. предупреждение выше)"
else
    echo "oem-config:        отключён — первая загрузка идёт сразу в систему"
fi
# Печатаем ФАКТ, а не содержимое CAMERA_PACKAGES: до 2026-09-11 здесь стояла
# сама переменная, и при провале apt табличка показывала пакеты как
# установленные. На живой прошивке это стоило разбора уже у платы.
CAM_HAVE=""
CAM_MISSING=""
for p in $CAMERA_PACKAGES; do
    if pkg_installed "$p"; then
        CAM_HAVE="$CAM_HAVE $p"
    else
        CAM_MISSING="$CAM_MISSING $p"
    fi
done
if [ -n "$CAM_HAVE" ]; then
    echo "пакеты камер, есть:$CAM_HAVE"
else
    echo "пакеты камер, есть: НИ ОДНОГО"
fi
if [ -n "$CAM_MISSING" ]; then
    echo "пакеты камер, НЕТ:$CAM_MISSING"
    if [ "$SKIP_PKGS" -ne 0 ]; then
        echo "  (шаг установки пропущен — см. предупреждение выше)"
    fi
    echo "  доставить на плате: sudo apt-get install -y$CAM_MISSING"
fi
if [ -d "$CAMERA_DST" ]; then
    echo "/opt/sensing:      $(find "$CAMERA_DST" -type f | wc -l) файлов, $(du -sh "$CAMERA_DST" | cut -f1)"
else
    echo "/opt/sensing:      пусто"
fi
echo
echo "Дальше — 05-generate-images.sh (плата должна быть в recovery)."
