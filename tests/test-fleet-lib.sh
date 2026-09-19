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

echo "проверок: $total, не прошло: $fails"
[ "$fails" -eq 0 ]
