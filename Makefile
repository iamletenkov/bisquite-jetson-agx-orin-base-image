# Сборка образов NVIDIA Jetson AGX Orin: базовый L4T и слои bisquite поверх.
#
# ДВЕ ПОЛОВИНЫ, И ОНИ ЗАПУСКАЮТСЯ НА РАЗНЫХ МАШИНАХ.
#
#   bsp*         — станция прошивки, amd64 + Ubuntu 22.04 (jammy).
#                  Собирает классический образ из BSP: на выходе и .img
#                  для обычной прошивки, и .qcow2 для bisquite.
#   image-*      — arm64-хост (сам Jetson). Слои VMFILE выполняют код
#                  В ГОСТЕ, а libguestfs чужую архитектуру не эмулирует,
#                  поэтому собрать их на amd64 нельзя в принципе.
#
# Перепутать нельзя: цели второй половины на amd64 отказывают на барьере
# архитектуры, и это верное поведение, а не поломка.

SHELL := /bin/bash

# Рабочий каталог сценариев 01-09. Тот же умолчательный путь, что у них.
WORK ?= /srv/jetson

# Теги в хранилище bisquite. Версия в теге — версия L4T, а не наша: образы
# целиком определяются BSP, из которого собраны.
#   BSP_TAG    образ из BSP (scripts/09 + bs image import)
#   BASE_TAG   основной образ робота, vmfiles/jetson-orin-base.vmfile
#   ROBOT_TAG  робот с рабочим столом, vmfiles/jetson-orin-robot.vmfile
BSP_TAG       ?= jetson-orin-bsp:36.4.3
BASE_TAG      ?= jetson-orin-base:36.4.3
ROBOT_TAG     ?= jetson-orin-robot:36.4.3
# Ресурсы appliance virt-customize для основного образа: l4t-pytorch
# компилирует torchvision с CUDA внутри сборки, а умолчание bisquite —
# 1 vCPU и 2 ГБ. 8 и 20000 — замер 2026-09-14 на AGX Orin: слой за 496 с.
BUILD_SMP     ?= 8
BUILD_MEMSIZE ?= 20000

BS ?= bs

.DEFAULT_GOAL := help

.PHONY: help
help: ## показать эту справку
	@echo "Цели (station = станция прошивки amd64, board = arm64-хост):"
	@grep -hE '^[a-zA-Z0-9_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-18s\033[0m %s\n",$$1,$$2}'
	@echo
	@echo "Переменные: WORK=$(WORK)  BSP_TAG=$(BSP_TAG)  BASE_TAG=$(BASE_TAG)  ROBOT_TAG=$(ROBOT_TAG)"

# --- Станция прошивки (amd64, jammy) ----------------------------------------

.PHONY: bsp
bsp: ## [station] весь путь от BSP до образа jetson-orin-bsp в хранилище bisquite
	sudo -E WORK=$(WORK) scripts/09-build-jetson-base.sh -t $(BSP_TAG)

.PHONY: bsp-fresh
bsp-fresh: ## [station] то же, но с пересборкой дерева BSP с нуля
	sudo -E WORK=$(WORK) scripts/09-build-jetson-base.sh --fresh -t $(BSP_TAG)

.PHONY: bsp-image-only
bsp-image-only: ## [station] только шаг 08: .img и .qcow2 из готового дерева
	sudo -E WORK=$(WORK) scripts/08-build-base-image.sh

.PHONY: fetch
fetch: ## [station] шаги 01-02: скачать L4T и драйверы камер
	sudo -E WORK=$(WORK) scripts/01-fetch-l4t.sh
	sudo -E WORK=$(WORK) scripts/02-fetch-camera-drivers.sh

# --- Прошивка платы кабелем (классический путь) ------------------------------
#
# Отдельная цель и отдельное предупреждение: запись в QSPI НЕОБРАТИМА,
# отката на прежнюю версию L4T после неё не остаётся. Сам сценарий ещё раз
# переспросит словом «да».

.PHONY: flash
flash: ## [station] прошить плату кабелем: QSPI + разметка + rootfs (НЕОБРАТИМО)
	sudo -E WORK=$(WORK) scripts/06-flash.sh

.PHONY: flash-rootfs
flash-rootfs: ## [station] перезалить только rootfs на уже прошитой плате
	sudo -E WORK=$(WORK) scripts/07-flash-rootfs-ssh.sh

.PHONY: flash-qspi
flash-qspi: ## [station] ТОЛЬКО загрузчик в QSPI, носители не трогать (НЕОБРАТИМО)
	sudo -E WORK=$(WORK) scripts/10-flash-internal.sh --target qspi

.PHONY: flash-emmc
flash-emmc: ## [station] QSPI + rootfs во внутреннюю eMMC (НЕОБРАТИМО)
	sudo -E WORK=$(WORK) scripts/10-flash-internal.sh --target emmc

# --- Образы bisquite (arm64) --------------------------------------------------

.PHONY: base
base: ## [board] основной образ: камеры, CUDA, TensorRT, GStreamer, OpenCV, PyTorch поверх BSP
	$(BS) image build --smp $(BUILD_SMP) --memsize $(BUILD_MEMSIZE) -f vmfiles/jetson-orin-base.vmfile --tag $(BASE_TAG)

.PHONY: robot
robot: ## [board] робот с рабочим столом, VNC, code-server и Docker поверх основного
	$(BS) image build -f vmfiles/jetson-orin-robot.vmfile --tag $(ROBOT_TAG)

.PHONY: images
images: base robot ## [board] оба образа подряд

# --- Проверки -----------------------------------------------------------------

.PHONY: check
check: ## синтаксис сценариев и разбор VMFILE (VMFILE — только на arm64)
	@for f in scripts/*.sh; do bash -n "$$f" || exit 1; done
	@echo "bash -n: все сценарии разбираются"
	@command -v shellcheck >/dev/null 2>&1 \
		&& { shellcheck -S warning scripts/*.sh && echo "shellcheck: чисто"; } \
		|| echo "shellcheck не установлен — пропущено"
	@for f in vmfiles/*.vmfile; do $(BS) image validate -f "$$f" || exit 1; done

.PHONY: check-manifest
check-manifest: ## разобрать пример манифеста записи
	$(BS) device validate -f device/jetson-orin-robot.yml
