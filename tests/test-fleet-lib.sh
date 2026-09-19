#!/usr/bin/env bash
# Разбор ответов плат на строках, снятых с живых плат, а не придуманных.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
. tools/fleet-lib.sh
fails=0; total=0
eq() { total=$((total+1)); if [ "$2" = "$3" ]; then echo "  ok   $1"; else fails=$((fails+1)); echo "  FAIL $1: '$2' != '$3'"; fi; }

eq "nano: система"   "$(echo '# R32 (release), REVISION: 6.1, GCID: 27863751, BOARD: t210ref, EABI: aarch64' | parse_nv_tegra_release)" 32.6.1
eq "xavier: система" "$(echo '# R32 (release), REVISION: 5.1, GCID: 26202423, BOARD: t186ref, EABI: aarch64' | parse_nv_tegra_release)" 32.5.1
eq "orin: система"   "$(echo '# R36 (release), REVISION: 4.3, GCID: 38968081, BOARD: generic, EABI: aarch64' | parse_nv_tegra_release)" 36.4.3
eq "nano: прошивка"  "$(printf 'NV3\n# R32 , REVISION: 7.4\nBOARDID=3448 BOARDSKU=0000 FAB=300\n20230608212504\n' | parse_t210_updater)" 32.7.4
eq "orin: прошивка"  "$(printf 'Current version: 36.4.3\nCapsule update status: 0\n' | parse_slots_info)" 36.4.3
eq "xavier R32: версии нет" "$(printf 'Current bootloader slot: B\nActive bootloader slot: B\n' | parse_slots_info)" ""
eq "orin: EEPROM"    "$(printf 'xx699-13701-0000-500 J.0\nH1421722061767\n' | parse_eeprom_pn)" "699-13701-0000-500 J.0"

# Выбор модуля. Несущая 2822-0000-600 — ответ живого AGX Xavier
# (agx@192.168.2.38, прогон задачи 18), модуль — по профилю agx-xavier
# (p2888-0001, FAB 400). Несущая идёт первой по алфавиту — в этом и был дефект.
xavier_ids=$'2822-0000-600\n2888-0001-400'
eq "xavier: модуль, а не несущая 2822" "$(printf '%s\n' "$xavier_ids" | pick_module_id)" 2888-0001-400
eq "nano: модуль 3448, а не несущая 3449" "$(printf '3449-0000-400\n3448-0000-400\n' | pick_module_id)" 3448-0000-400
eq "nano: порядок не важен"          "$(printf '3448-0000-400\n3449-0000-400\n' | pick_module_id)" 3448-0000-400
eq "chosen/ids через NUL и с префиксом p" "$(printf 'p2822-0000-600\0p2888-0001-400\0' | pick_module_id)" 2888-0001-400
eq "orin: 3701 среди несущей 3737"   "$(printf '3737-0000-500 3701-0000-500' | pick_module_id)" 3701-0000-500
eq "только несущая — пусто"          "$(printf '2822-0000-600\n' | pick_module_id)" ""
eq "select: EEPROM первым"           "$(select_module '699-13701-0000-500 J.0' '' "$xavier_ids")" "$(printf '699-13701-0000-500 J.0\teeprom')"
eq "select: xavier без EEPROM — plugin-mgr, модуль" "$(select_module '' '' "$xavier_ids")" "$(printf '2888-0001-400\tplugin-mgr')"
eq "select: dt-ids раньше plugin-mgr" "$(select_module '' '3448-0000-400' "$xavier_ids")" "$(printf '3448-0000-400\tdt-ids')"
eq "select: в dt-ids одна несущая — дальше" "$(select_module '' '2822-0000-600' "$xavier_ids")" "$(printf '2888-0001-400\tplugin-mgr')"
eq "select: модуля нет нигде — ?"    "$(select_module '' '' '2822-0000-600')" "$(printf '?\t-')"

# Оркестровка report: ssh подменён локальным bash, sudo — отказом. Проба
# на этой машине не находит ни device tree, ни EEPROM: модуль «?», источник «-».
fk="$(mktemp -d)"; trap 'rm -rf -- "$fk"' EXIT
printf '#!/bin/sh\nexec bash -s\n' > "$fk/ssh"; printf '#!/bin/sh\nexit 1\n' > "$fk/sudo"; chmod +x "$fk/ssh" "$fk/sudo"
echo 'x@host' > "$fk/hosts"
rep="$(PATH="$fk:$PATH" bash tools/fleet-firmware.sh report "$fk/hosts" 2>&1)"
eq "report: колонка ИСТОЧНИК в заголовке" "$(awk 'NR==1{print $5}' <<<"$rep")" ИСТОЧНИК
eq "report: строка хоста — модуль и источник" "$(awk 'NR==2{print $1, $4, $5}' <<<"$rep")" "x@host ? -"

echo "проверок: $total, не прошло: $fails"
[ "$fails" -eq 0 ]
