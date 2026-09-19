#!/usr/bin/env bash
# Инвентаризация парка Jetson: что стоит на каждой плате. ТОЛЬКО ЧИТАЕТ.
#
#     tools/fleet-firmware.sh report hosts.txt
#
# hosts.txt — по строке `пользователь@хост`; # — комментарий. Нужен вход по
# ключу; версия прошивки читается через `sudo -n` — без sudo без пароля
# колонка покажет «?».
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ "${1:-}" != report ] || [ ! -f "${2:-}" ]; then
    echo "использование: $0 report <hosts.txt>"
    exit 1
fi

PROBE="$(cat "$HERE/fleet-lib.sh")
$(cat <<'EOF'
sys="$(parse_nv_tegra_release < /etc/nv_tegra_release 2>/dev/null)"
tn="$(awk '/^TNSPEC/ {print $2}' /etc/nv_boot_control.conf 2>/dev/null)"
mod="$(select_module \
    "$(sudo -n cat /sys/bus/i2c/devices/0-0050/eeprom 2>/dev/null | parse_eeprom_pn)" \
    "$(tr '\0' ' ' < /proc/device-tree/chosen/ids 2>/dev/null)" \
    "$(ls /proc/device-tree/chosen/plugin-manager/ids 2>/dev/null)")"
pn="${mod%%$'\t'*}" src="${mod#*$'\t'}"
if command -v l4t_payload_updater_t210 >/dev/null 2>&1; then
    fw="$(sudo -n l4t_payload_updater_t210 -v 2>/dev/null | parse_t210_updater)"
else
    fw="$(sudo -n nvbootctrl dump-slots-info 2>/dev/null | parse_slots_info)"
fi
printf '%s\t%s\t%s\t%s\t%s\n' "${sys:-?}" "${fw:-?}" "${pn:-?}" "${src:--}" "${tn:-?}"
EOF
)"

fmt='%-24s %-8s %-9s %-24s %-10s %s\n'
# shellcheck disable=SC2059
printf "$fmt" ХОСТ СИСТЕМА ПРОШИВКА МОДУЛЬ ИСТОЧНИК TNSPEC
grep -vE '^[[:space:]]*(#|$)' "$2" | while read -r host; do
    row="$(timeout 40 ssh -o BatchMode=yes -o ConnectTimeout=8 "$host" 'bash -s' <<<"$PROBE" 2>/dev/null)"
    if [ -z "$row" ]; then
        # shellcheck disable=SC2059
        printf "$fmt" "$host" "нет входа" "" "" "" ""
        continue
    fi
    IFS=$'\t' read -r sys fw pn src tn <<<"$row"
    # shellcheck disable=SC2059
    printf "$fmt" "$host" "$sys" "$fw" "$pn" "$src" "$tn"
done
