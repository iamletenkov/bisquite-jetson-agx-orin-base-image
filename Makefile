# Сборка образов NVIDIA Jetson: базовый L4T и слои bisquite поверх.
#
# ДВЕ ПОЛОВИНЫ, И ОНИ ЗАПУСКАЮТСЯ НА РАЗНЫХ МАШИНАХ.
#
#   bsp*         — станция прошивки, amd64 + Ubuntu 22.04 (jammy), либо сам
#                  Jetson (шаги 01-08 идут и на aarch64, см. README).
#                  Собирает классический образ из BSP: на выходе и .img
#                  для обычной прошивки, и .qcow2 для bisquite.
#   base/robot   — arm64-хост (сам Jetson). Слои VMFILE выполняют код
#                  В ГОСТЕ, а libguestfs чужую архитектуру не эмулирует,
#                  поэтому собрать их на amd64 нельзя в принципе.
#
# Перепутать нельзя: цели второй половины на amd64 отказывают на барьере
# архитектуры, и это верное поведение, а не поломка.
#
# ПЛАТА ВЫБИРАЕТСЯ ПЕРЕМЕННОЙ BOARD, А НЕ ПРАВКОЙ ФАЙЛОВ:
#
#     make bsp                      # AGX Orin (умолчание)
#     make BOARD=xavier-agx bsp     # AGX Xavier
#
# Профили живут в подмодуле, рядом со скриптами, которые их читают:
# scripts/boards/<плата>.env. Список — `make boards`.

SHELL := /bin/bash

BOARD ?= orin-agx
BOARD_ENV := scripts/boards/$(BOARD).env

# Рабочий каталог сценариев 01-10. ПУСТО ПО УМОЛЧАНИЮ, и это намеренно:
# каталог задаёт профиль платы (у Orin /srv/jetson, у Xavier
# /srv/jetson-xavier), потому что деревья BSP разных версий L4T в одном
# каталоге затирают друг друга. Заданный здесь WORK сильнее профиля.
WORK ?=

# Профиль подаётся окружением и переживает sudo только с ключом -E.
LOAD_BOARD = $(if $(WORK),export WORK=$(WORK);) set -a; . $(BOARD_ENV); set +a;

# Теги в хранилище bisquite. Версия в теге — версия L4T, а не наша: образы
# целиком определяются BSP, из которого собраны. Здесь, а не в профиле:
# профиль уезжает в образ станции и описывает прошивку, а теги и VMFILE —
# это про хранилище bisquite, до которого станции дела нет.
ifeq ($(BOARD),orin-agx)
BSP_TAG      ?= jetson-orin-bsp:36.4.3
BASE_TAG     ?= jetson-orin-base:36.4.3
ROBOT_TAG    ?= jetson-orin-robot:36.4.3
VMFILE_BASE  ?= vmfiles/jetson-orin-base.vmfile
VMFILE_ROBOT ?= vmfiles/jetson-orin-robot.vmfile
DEVICE_YML   ?= device/jetson-orin-robot.yml
endif
ifeq ($(BOARD),xavier-agx)
BSP_TAG      ?= jetson-xavier-bsp:35.6.5
BASE_TAG     ?= jetson-xavier-base:35.6.5
ROBOT_TAG    ?= jetson-xavier-robot:35.6.5
VMFILE_BASE  ?= vmfiles/jetson-xavier-base.vmfile
VMFILE_ROBOT ?= vmfiles/jetson-xavier-robot.vmfile
DEVICE_YML   ?= device/jetson-xavier-robot.yml
endif

# Ресурсы appliance virt-customize для основного образа: l4t-pytorch
# компилирует torchvision с CUDA внутри сборки, а умолчание bisquite —
# 1 vCPU и 2 ГБ. 8 и 20000 — замер 2026-09-14 на AGX Orin: слой за 496 с.
BUILD_SMP     ?= 8
BUILD_MEMSIZE ?= 20000

BS ?= bs

.DEFAULT_GOAL := help

.PHONY: help
help: ## показать эту справку
	@echo "Цели (station = станция прошивки или arm64-узел, board = arm64-хост):"
	@grep -hE '^[a-zA-Z0-9_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-18s\033[0m %s\n",$$1,$$2}'
	@echo
	@echo "Плата:      BOARD=$(BOARD)  (профиль $(BOARD_ENV))"
	@echo "Переменные: WORK=$(if $(WORK),$(WORK),из профиля)  BSP_TAG=$(BSP_TAG)  BASE_TAG=$(BASE_TAG)  ROBOT_TAG=$(ROBOT_TAG)"

.PHONY: boards
boards: ## показать доступные профили плат
	@for f in scripts/boards/*.env; do \
		printf '  \033[36m%-14s\033[0m %s\n' "$$(basename $$f .env)" "$$(sed -n '1s/^# Профиль платы: //p' $$f)"; \
	done

# --- Преграды ----------------------------------------------------------------
#
# Обе стоят до любой работы: отсутствующий подмодуль и опечатка в BOARD дают
# внятный отказ, а не «файл не найден» из середины двухчасового прогона.

.PHONY: check-submodule
check-submodule:
	@test -e scripts/09-build-jetson-base.sh || { \
		echo "ОТКАЗ: scripts/ — ссылка в подмодуль bisquite-extensions, а он пуст."; \
		echo "Выполни:  git submodule update --init"; exit 1; }

.PHONY: check-board
check-board: check-submodule
	@test -f "$(BOARD_ENV)" || { \
		echo "ОТКАЗ: нет профиля $(BOARD_ENV)"; \
		echo "Доступные:"; $(MAKE) -s boards; exit 1; }
	@test -n "$(BSP_TAG)" || { \
		echo "ОТКАЗ: для BOARD=$(BOARD) в Makefile не объявлены теги образов."; \
		echo "Профиль станции есть, а слоёв bisquite под эту плату ещё нет."; exit 1; }

# --- Изготовление базового образа из BSP -------------------------------------

.PHONY: bsp
bsp: check-board ## [station] весь путь от BSP до образа в хранилище bisquite
	$(LOAD_BOARD) sudo -E scripts/09-build-jetson-base.sh -t $(BSP_TAG)

.PHONY: bsp-fresh
bsp-fresh: check-board ## [station] то же, но с пересборкой дерева BSP с нуля
	$(LOAD_BOARD) sudo -E scripts/09-build-jetson-base.sh --fresh -t $(BSP_TAG)

.PHONY: bsp-image-only
bsp-image-only: check-board ## [station] только шаг 08: .img и .qcow2 из готового дерева
	$(LOAD_BOARD) sudo -E scripts/08-build-base-image.sh

.PHONY: fetch
fetch: check-board ## [station] шаги 01-02: скачать L4T и драйверы камер
	$(LOAD_BOARD) sudo -E scripts/01-fetch-l4t.sh
	$(LOAD_BOARD) sudo -E scripts/02-fetch-camera-drivers.sh

# --- Прошивка платы кабелем (классический путь) ------------------------------
#
# Отдельная цель и отдельное предупреждение: запись в загрузочную область
# НЕОБРАТИМА, отката на прежнюю версию L4T после неё не остаётся. Сам
# сценарий ещё раз переспросит словом «да».

.PHONY: flash
flash: check-board ## [station] прошить плату кабелем: загрузчик + разметка + rootfs (НЕОБРАТИМО)
	$(LOAD_BOARD) sudo -E scripts/06-flash.sh

.PHONY: flash-rootfs
flash-rootfs: check-board ## [station] перезалить только rootfs на уже прошитой плате
	$(LOAD_BOARD) sudo -E scripts/07-flash-rootfs-ssh.sh

.PHONY: flash-qspi
flash-qspi: check-board ## [station] ТОЛЬКО загрузчик в QSPI, носители не трогать (НЕОБРАТИМО)
	$(LOAD_BOARD) sudo -E scripts/10-flash-internal.sh --target qspi

.PHONY: flash-emmc
flash-emmc: check-board ## [station] загрузчик + rootfs во внутреннюю eMMC (НЕОБРАТИМО)
	$(LOAD_BOARD) sudo -E scripts/10-flash-internal.sh --target emmc

# --- Образы bisquite (arm64) --------------------------------------------------

.PHONY: base
base: check-board ## [board] основной образ: камеры, CUDA, TensorRT, GStreamer, OpenCV, PyTorch поверх BSP
	@test -f "$(VMFILE_BASE)" || { echo "ОТКАЗ: нет $(VMFILE_BASE) — слоёв под BOARD=$(BOARD) ещё не написано"; exit 1; }
	$(BS) image build --smp $(BUILD_SMP) --memsize $(BUILD_MEMSIZE) -f $(VMFILE_BASE) --tag $(BASE_TAG)

.PHONY: robot
robot: check-board ## [board] робот с рабочим столом, VNC, code-server и Docker поверх основного
	@test -f "$(VMFILE_ROBOT)" || { echo "ОТКАЗ: нет $(VMFILE_ROBOT) — слоёв под BOARD=$(BOARD) ещё не написано"; exit 1; }
	$(BS) image build -f $(VMFILE_ROBOT) --tag $(ROBOT_TAG)

.PHONY: images
images: base robot ## [board] оба образа подряд

# --- Проверки -----------------------------------------------------------------

.PHONY: check
check: check-submodule ## синтаксис сценариев, разбор профилей и VMFILE (VMFILE — только на arm64)
	@for f in scripts/*.sh; do bash -n "$$f" || exit 1; done
	@echo "bash -n: все сценарии разбираются"
	@for f in scripts/boards/*.env; do bash -n "$$f" || exit 1; done
	@echo "bash -n: все профили разбираются"
	@command -v shellcheck >/dev/null 2>&1 \
		&& { shellcheck -S warning scripts/*.sh && echo "shellcheck: чисто"; } \
		|| echo "shellcheck не установлен — пропущено"
	@for f in vmfiles/*.vmfile; do $(BS) image validate -f "$$f" || exit 1; done

.PHONY: check-manifest
check-manifest: check-board ## разобрать пример манифеста записи
	$(BS) device validate -f $(DEVICE_YML)
