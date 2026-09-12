#!/bin/bash
# Ставит NVIDIA SDK Manager (GUI-заливка Jetson) на станцию прошивки.
#
#     sudo /opt/nvidia-jetpack/90-install-sdkmanager.sh
#
# Что важно знать до установки.
#
# SDK Manager под капотом зовёт ровно тот же l4t_initrd_flash.sh с тем же
# NFS-сервером, что и ручная заливка. Значит, от обрывов на распаковке
# system.img он НЕ спасает — ровно та же
#   nfs: server fc00:1:1:0::1 not responding, still trying
# случится и под GUI. Он избавляет от другого: от ручного скачивания BSP
# и sample rootfs и от возни с ключами вроде -S <размер>. Когда заливка
# всё-таки оборвётся на rootfs — доводить её тем же 07-flash-rootfs-ssh.sh.
#
# Пакет качается БЕЗ авторизации — проверено 2026-09-10. Логин на
# developer.nvidia.com нужен самому SDK Manager при запуске, но не для
# получения .deb.

set -uo pipefail

# Страница-редирект NVIDIA. Версия в скрипте НЕ ЗАШИТА намеренно: прямая
# ссылка на конкретный .deb протухает с каждым релизом (файлы уезжают
# в secure/clients/sdkmanager-<версия>/), а эта страница всегда указывает
# на актуальный. На 2026-09-10 за ней стоит 2.4.1 (Ubuntu 22.04 поддержана).
REDIRECT_URL="https://developer.download.nvidia.com/sdkmanager/redirects/sdkmanager-deb.html"
MANUAL_URL="https://developer.nvidia.com/sdk-manager"

step() { echo; echo "=== $* ==="; }

fail() {
    echo
    echo "ОТКАЗ: $*"
    echo
    echo "Установи SDK Manager вручную: скачай .deb со страницы"
    echo "  $MANUAL_URL"
    echo "и поставь его командой"
    echo "  sudo apt-get install -y ./sdkmanager_<версия>_amd64.deb"
    exit 1
}

[ "$(id -u)" -eq 0 ] || { echo "Нужен root"; exit 1; }

WORKDIR=$(mktemp -d /tmp/sdkmanager.XXXXXX) || { echo "Не создался временный каталог"; exit 1; }
trap 'rm -rf "$WORKDIR"' EXIT

step "1. Уже установлен?"
if command -v sdkmanager >/dev/null 2>&1; then
    echo "  sdkmanager уже в PATH: $(command -v sdkmanager)"
    dpkg-query -W -f '  пакет: ${Package} ${Version}\n' sdkmanager 2>/dev/null
    echo "  Переустановка не требуется. Удалить: apt-get remove sdkmanager"
    exit 0
fi
echo "  нет, ставим"

step "2. Скачиваю страницу-редирект"
echo "  $REDIRECT_URL"
if ! curl -fsSL --retry 3 --retry-delay 2 -o "$WORKDIR/redirect.html" "$REDIRECT_URL"; then
    fail "страница-редирект не скачалась (нет сети или NVIDIA сменила адрес)"
fi
[ -s "$WORKDIR/redirect.html" ] || fail "страница-редирект пуста"

step "3. Достаю ссылку на .deb"
# В HTML лежит строка вида
#   var target = "https://developer.nvidia.com/downloads/sdkmanager/secure/clients/sdkmanager-2.4.1.13536/sdkmanager_2.4.1-13536_amd64.deb";
# Регулярка берёт первый же https-URL, оканчивающийся на .deb, и обрывается
# на кавычке — разбирать HTML целиком тут не за чем, ссылка на странице одна.
DEB_URL=$(grep -oE 'https://[^"]+\.deb' "$WORKDIR/redirect.html" | head -n 1)
if [ -z "$DEB_URL" ]; then
    echo "  первые строки полученной страницы:"
    head -c 400 "$WORKDIR/redirect.html" | sed 's/^/    /'
    echo
    fail "в странице-редиректе не нашлось ссылки на .deb (изменился формат страницы)"
fi
echo "  $DEB_URL"

DEB_FILE="$WORKDIR/$(basename "$DEB_URL")"

step "4. Скачиваю пакет (~127 МБ)"
if ! curl -fL --retry 3 --retry-delay 2 -o "$DEB_FILE" "$DEB_URL"; then
    fail "пакет не скачался: $DEB_URL"
fi
[ -s "$DEB_FILE" ] || fail "скачанный файл пуст: $DEB_FILE"
echo "  размер: $(stat -c%s "$DEB_FILE") байт"

step "5. Проверяю, что это действительно deb"
# Дешёвая, но решающая проверка: deb — это ar-архив, и его первые семь байт
# всегда "!<arch>". Без неё на apt-get уехала бы HTML-страница с ошибкой
# (портал отдаёт 200 и текст, когда ссылка протухла), и отказ пришёл бы
# невнятным сообщением dpkg вместо понятного объяснения.
MAGIC=$(head -c 7 "$DEB_FILE")
if [ "$MAGIC" != '!<arch>' ]; then
    echo "  ожидалось '!<arch>', получено: $(head -c 64 "$DEB_FILE" | tr -d '\0' | head -c 64)"
    fail "скачанный файл не является deb-пакетом"
fi
echo "  OK: сигнатура ar на месте"
command -v file >/dev/null 2>&1 && file -b "$DEB_FILE" | sed 's/^/  /'

step "6. Устанавливаю"
# Именно apt-get install ./file.deb, а не dpkg -i: apt подтянет зависимости
# сам, а у SDK Manager их много (libgconf, libcanberra-gtk, libnss3 и далее).
# dpkg -i оставил бы полураспакованный пакет и сломанное дерево зависимостей.
apt-get update
if ! DEBIAN_FRONTEND=noninteractive apt-get install -y "$DEB_FILE"; then
    fail "apt-get не установил пакет $DEB_FILE"
fi

step "ГОТОВО"
command -v sdkmanager >/dev/null 2>&1 \
    && echo "sdkmanager: $(command -v sdkmanager)" \
    || echo "ВНИМАНИЕ: пакет поставлен, но sdkmanager не найден в PATH"
cat <<'EOF'

Запуск — от обычного пользователя (не от root), с графической сессией:
      sdkmanager
При первом запуске он попросит логин на developer.nvidia.com — для
скачивания BSP он нужен, для скачивания самого пакета не был.

Оговорка, ради которой стоит дочитать: SDK Manager зовёт тот же
l4t_initrd_flash.sh с тем же NFS-сервером. От обрыва на распаковке
system.img он не спасает — GUI избавляет от скачивания BSP и от возни
с ключами, но не от главной проблемы. Оборвалось на rootfs — доводи
скриптом 07-flash-rootfs-ssh.sh, не начиная заливку заново.
EOF
