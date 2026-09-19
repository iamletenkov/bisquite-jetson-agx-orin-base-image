# shellcheck shell=bash
# Разбор ответов платы Jetson. Отдельным файлом, чтобы проверять на строках,
# снятых с живых плат. Этот же файл уезжает на плату по ssh вместе с пробой.
#
# ВЕРСИЯ ПРОШИВКИ ≠ ВЕРСИЯ СИСТЕМЫ. Живой Nano 2026-09-18: прошивка R32.7.4,
# rootfs R32.6.1. /etc/nv_tegra_release говорит только про систему.

# «# R32 (release), REVISION: 6.1, …» -> 32.6.1
parse_nv_tegra_release() { sed -nE '1s/^# R([0-9]+) \(release\), REVISION: ([0-9.]+),.*/\1.\2/p'; }
# l4t_payload_updater_t210 -v: «# R32 , REVISION: 7.4» -> 32.7.4
parse_t210_updater() { sed -nE 's/^# R([0-9]+) , REVISION: ([0-9.]+).*/\1.\2/p' | head -1; }
# nvbootctrl dump-slots-info (R35+): «Current version: 36.4.3». У R32 на t194
# такой строки нет — пустой ответ честнее угаданного.
parse_slots_info() { sed -nE 's/^Current version: ([0-9.]+).*/\1/p' | head -1; }
# Номер детали модуля из EEPROM: «699-13701-0000-500 J.0» — источник FAB и
# ревизии. TNSPEC на платах с нашими образами для этого не годится.
parse_eeprom_pn() { grep -aoE '699-[0-9]{5}-[0-9]{4}-[0-9]{3} [A-Z]\.[0-9]' | head -1; }

# Номер детали МОДУЛЯ из списка идентификаторов платы. В device tree лежат и
# модуль, и несущая: у AGX Xavier plugin-manager/ids = 2822-0000-600 (несущая
# p2822) и 2888-0001-400 (модуль p2888), и первый по алфавиту — несущая. Поэтому
# берётся первый идентификатор с префиксом известного МОДУЛЯ Jetson:
#   2888 AGX Xavier, 3701 AGX Orin, 3448 Nano, 3668 Xavier NX,
#   3767 Orin NX/Nano, 2180 TX1, 3310 TX2, 3489 TX2i/TX2 4GB.
# Несущие (2822, 3449, 3509, 3737, 3768 и прочие) не берутся никогда. Нет
# модуля в списке — пустой ответ: он честнее несущей под заголовком «МОДУЛЬ».
# Вход — идентификаторы через пробел, перевод строки или NUL.
pick_module_id() {
    tr '\0 \t' '\n\n\n' | sed -nE '/^p?(2888|3701|3448|3668|3767|2180|3310|3489)-/{s/^p//;p}' | sed -n 1p
}

# Выбор номера модуля и его источника: EEPROM модуля (FAB и ревизия), затем
# /proc/device-tree/chosen/ids, затем имена в chosen/plugin-manager/ids.
#   select_module <pn из EEPROM> <dt ids> <plugin-manager ids> -> «номер<TAB>источник»
# Ни в одном источнике модуля нет — «?<TAB>-».
select_module() {
    local pn
    if [ -n "${1:-}" ]; then printf '%s\teeprom\n' "$1"; return; fi
    pn="$(printf '%s\n' "${2:-}" | pick_module_id)"
    if [ -n "$pn" ]; then printf '%s\tdt-ids\n' "$pn"; return; fi
    pn="$(printf '%s\n' "${3:-}" | pick_module_id)"
    if [ -n "$pn" ]; then printf '%s\tplugin-mgr\n' "$pn"; return; fi
    printf '?\t-\n'
}
