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
