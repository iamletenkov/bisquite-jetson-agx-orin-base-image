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
lacks() { local n="$1" pat="$2" out; shift 2; out="$("$@" 2>&1)"; if printf '%s\n' "$out" | grep -q -- "$pat"; then bad "$n"; else ok "$n"; fi; }
lacks  "fresh=0 дерево не сносит"         "--fresh"                   make -n build jetson=agx-xavier l4t=35.6.5 fresh=0
lacks  "fresh= пустое — тоже"             "--fresh"                   make -n build jetson=agx-xavier l4t=35.6.5 fresh=
says   "результат в out/<плата>-<релиз>"  "out/agx-xavier-35.6.5"     make -n build jetson=agx-xavier l4t=35.6.5
says   "to=bootloader зовёт шаг 14"       "14-flash-bootloader.sh"    make -n flash jetson=agx-xavier l4t=35.6.5 to=bootloader
says   "list печатает платы"              "agx-orin"                  make -s list
# scripts/ подменён: профиль — настоящий (ссылками), сценарии — печатают, что
# получили; sudo — сквозной. Ни одна проверка ниже не дотянется до настоящих
# 06/10, даже если Makefile сломается.
mt="$(mktemp -d)"; trap 'rm -rf -- "$mt"' EXIT
mkdir -p "$mt/s" "$mt/bin"
for f in profile.sh boards releases pairs; do ln -s "$PWD/scripts/$f" "$mt/s/$f"; done
for f in 06-flash.sh 07-flash-rootfs-ssh.sh 09-build-jetson-base.sh 10-flash-internal.sh; do
  printf '#!/bin/sh\necho "ЗАПУЩЕН %s DRY_RUN=${DRY_RUN:-} WORK=$WORK OUT_RAW=$OUT_RAW OUT_QCOW2=$OUT_QCOW2"\n' "$f" > "$mt/s/$f"
done
printf '#!/bin/sh\n[ "$1" = -E ] && shift\nexec "$@"\n' > "$mt/bin/sudo"; chmod +x "$mt/bin/sudo"
stubbed() { env PATH="$mt/bin:$PATH" "$@" S="$mt/s" OUT="$mt/out" </dev/null; }

says   "DRY_RUN с to=nvme — отказ"      "DRY_RUN поддержан только"  stubbed DRY_RUN=1 make -s flash jetson=agx-xavier l4t=35.6.5 to=nvme
says   "DRY_RUN с to=internal — отказ"  "DRY_RUN поддержан только"  stubbed make -s flash jetson=agx-xavier l4t=35.6.5 to=internal DRY_RUN=1
fails_ "…и это отказ, а не успех"       stubbed DRY_RUN=1 make -s flash jetson=agx-xavier l4t=35.6.5 to=nvme
nvme_dry() { stubbed DRY_RUN=1 make -s flash jetson=agx-xavier l4t=35.6.5 to=nvme; }
nvme_dry_ran() { local out; out="$(nvme_dry 2>&1)"; printf '%s\n' "$out" | grep -q ЗАПУЩЕН; }
fails_ "…и 06 не запускается"           nvme_dry_ran
says   "DRY_RUN с to=rootfs доходит до 07 с DRY_RUN=1" "ЗАПУЩЕН 07-flash-rootfs-ssh.sh DRY_RUN=1" stubbed DRY_RUN=1 make -s flash jetson=agx-xavier l4t=35.6.5 to=rootfs

# Унаследованные WORK/OUT_RAW/OUT_QCOW2 (оболочка станции от прежнего
# порядка работы) не должны доехать до сценария.
env_of_09() { stubbed WORK=/elsewhere OUT_RAW=/elsewhere/raw.img OUT_QCOW2=/elsewhere/x.qcow2 \
    make -s build jetson=agx-xavier l4t=35.6.5; }
says   "унаследованный WORK не доезжает" "WORK=/srv/l4t/agx-xavier@35.6.5 " env_of_09
says   "…и OUT_RAW тоже"                 "OUT_RAW=/srv/l4t/agx-xavier@35.6.5/system.img" env_of_09
says   "…и OUT_QCOW2 тоже"               "OUT_QCOW2=$mt/out/agx-xavier-35.6.5/system.qcow2" env_of_09

echo "проверок: $total, не прошло: $fails"
[ "$fails" -eq 0 ]
