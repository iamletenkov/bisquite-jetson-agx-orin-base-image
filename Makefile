# Образы NVIDIA Jetson: qcow2 для bisquite и пакет загрузчика из одной сборки.
#
#   make build  jetson=agx-xavier l4t=35.6.5 [fresh=1]
#   make flash  jetson=agx-xavier l4t=35.6.5 to=bootloader
#   make verify jetson=agx-orin   l4t=39.2
#   make matrix | make list | make check
#
# Спека: bisquite/docs/specs/2026-09-19-jetson-build-and-bootloader.md

SHELL := /bin/bash

jetson ?=
l4t    ?=
to     ?=
fresh  ?=
OUT    ?= $(CURDIR)/out
S      := scripts

# Профиль грузится в той же строке рецепта, что и sudo -E: иначе окружение
# пары до сценария не доедет. OUT_DIR задаётся ДО load_profile: тот вычисляет
# от него OUT_QCOW2, и заданный после qcow2 лёг бы в $WORK/out, а манифест
# искал бы его здесь. OUT_OWNER — владелец клона: при `sudo -E make` внутренний
# sudo от root выставил бы SUDO_UID=0, и out/ стал бы root'овым.
# WORK/OUT_RAW/OUT_QCOW2 снимаются: load_profile уважает уже заданные, а
# оболочка станции от прежнего порядка работы (`. boards/…env`) экспортирует
# WORK=/srv/jetson — сборка и прошивка ушли бы в дерево другой пары.
LOAD = unset WORK OUT_RAW OUT_QCOW2 && export OUT_DIR="$(OUT)/$(jetson)-$(l4t)" OUT_OWNER="$$(stat -c %u:%g .)" && . $(S)/profile.sh && load_profile "$(jetson)" "$(l4t)" &&

.DEFAULT_GOAL := help
.PHONY: help check-submodule list build flash verify verify-all matrix check

help: ## эта справка
	@grep -hE '^[a-z-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-12s\033[0m %s\n",$$1,$$2}'

check-submodule:
	@test -e $(S)/profile.sh || { echo "ОТКАЗ: scripts/ пуст — git submodule update --init"; exit 1; }

list: check-submodule ## объявленные платы и релизы
	@. $(S)/profile.sh && _profile_list

build: check-submodule ## qcow2 + пакет загрузчика + манифест в out/<плата>-<релиз>/
	@$(LOAD) sudo -E bash $(S)/09-build-jetson-base.sh $(if $(fresh),--fresh)

flash: check-submodule ## to=bootloader|internal|nvme|rootfs — НЕОБРАТИМО
	@case "$(to)" in \
	  bootloader) $(LOAD) sudo -E bash $(S)/14-flash-bootloader.sh ;; \
	  internal)   $(LOAD) sudo -E bash $(S)/10-flash-internal.sh --target emmc ;; \
	  nvme)       $(LOAD) sudo -E bash $(S)/06-flash.sh ;; \
	  rootfs)     $(LOAD) sudo -E bash $(S)/07-flash-rootfs-ssh.sh ;; \
	  *) echo "ОТКАЗ: нужно to=bootloader|internal|nvme|rootfs, получено '$(to)'"; exit 1 ;; \
	esac

verify: check-submodule ## доказать пару по BSP (тарболл потоком, на диск не кладётся)
	@$(LOAD) VERIFY_DIR="$(CURDIR)/verified" bash $(S)/15-verify-pair.sh

verify-all: check-submodule ## то же по всем совместимым парам
	@rc=0; for p in $$(. $(S)/profile.sh && _profile_pairs); do \
	  $(MAKE) -s verify jetson=$${p%@*} l4t=$${p#*@} || rc=1; done; exit $$rc

matrix: check-submodule ## таблица «плата × релиз × статус»
	@VERIFY_DIR="$(CURDIR)/verified" STATUS_FILE="$(CURDIR)/status.tsv" bash $(S)/16-matrix.sh

check: check-submodule ## синтаксис, shellcheck, тесты
	@for f in tools/*.sh tests/*.sh; do bash -n "$$f" || exit 1; done
	@shellcheck -S warning tools/*.sh tests/*.sh
	@for t in tests/test-*.sh; do bash "$$t" || exit 1; done
