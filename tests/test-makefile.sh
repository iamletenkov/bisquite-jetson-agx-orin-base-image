#!/usr/bin/env bash
# Тесты Makefile: отказы до sudo и состав команд. Ни одна проверка не
# запускает сборку или прошивку — только отказы и `make -n`.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
fails=0; total=0
ok()  { total=$((total+1)); echo "  ok   $1"; }
bad() { total=$((total+1)); fails=$((fails+1)); echo "  FAIL $1"; }
# Вывод сначала копится в переменную, а не льётся в `grep -q` напрямую:
# grep -q закрывает канал сразу после первого совпадения, и если совпадение
# приходится не на последнюю строку, ещё пишущий make получает SIGPIPE и
# сам считает это отказом рецепта (exit 2) — под `pipefail` этот код
# перекрывает успешный grep, и проверка врёт "не сработало" при верной строке.
says()  { local n="$1" pat="$2" out; shift 2; out="$("$@" 2>&1)"; if printf '%s\n' "$out" | grep -q -- "$pat"; then ok "$n"; else bad "$n"; fi; }
fails_() { local n="$1"; shift; if "$@" >/dev/null 2>&1; then bad "$n (не отказал)"; else ok "$n"; fi; }

fails_ "build без аргументов"             make -s build
says   "…и объясняет, чего не хватает"    "нужны оба значения" make -s build
says   "неизвестная плата"                "не объявлена"       make -s build jetson=nope l4t=35.6.5
says   "xavier на 36.4.3 — несовместимо"  "не поддерживает"    make -s build jetson=agx-xavier l4t=36.4.3
says   "flash без to="                    "to=bootloader"      make -s flash jetson=agx-xavier l4t=35.6.5
says   "build зовёт шаг 09"               "09-build-jetson-base.sh"   make -n build jetson=agx-xavier l4t=35.6.5
says   "fresh=1 превращается в --fresh"   "--fresh"                   make -n build jetson=agx-xavier l4t=35.6.5 fresh=1
says   "результат в out/<плата>-<релиз>"  "out/agx-xavier-35.6.5"     make -n build jetson=agx-xavier l4t=35.6.5
says   "to=bootloader зовёт шаг 14"       "14-flash-bootloader.sh"    make -n flash jetson=agx-xavier l4t=35.6.5 to=bootloader
says   "list печатает платы"              "agx-orin"                  make -s list

echo "проверок: $total, не прошло: $fails"
[ "$fails" -eq 0 ]
