# Сборка образов NVIDIA Jetson AGX Orin: базовый L4T и слои bisquite поверх.
#
# ДВЕ ПОЛОВИНЫ, И ОНИ ЗАПУСКАЮТСЯ НА РАЗНЫХ МАШИНАХ.
#
#   base-*       — станция прошивки, amd64 + Ubuntu 22.04 (jammy).
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

# Тег базового образа в хранилище bisquite. Версия в теге — версия L4T,
# а не наша: образ целиком определяется BSP, из которого собран.
BASE_TAG      ?= jetson-orin-base:36.4.3
CAMERA_TAG    ?= jetson-orin-camera:36.4.3
WORKSTATION_TAG ?= jetson-orin-workstation:36.4.3
# Ресурсы appliance virt-customize для рабочей станции: l4t-pytorch
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
	@echo "Переменные: WORK=$(WORK)  BASE_TAG=$(BASE_TAG)"

# --- Станция прошивки (amd64, jammy) ----------------------------------------

.PHONY: base
base: ## [station] весь путь от BSP до базового образа в хранилище bisquite
	sudo -E WORK=$(WORK) scripts/09-build-jetson-base.sh -t $(BASE_TAG)

.PHONY: base-fresh
base-fresh: ## [station] то же, но с пересборкой дерева BSP с нуля
	sudo -E WORK=$(WORK) scripts/09-build-jetson-base.sh --fresh -t $(BASE_TAG)

.PHONY: base-image-only
base-image-only: ## [station] только шаг 08: .img и .qcow2 из готового дерева
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

.PHONY: camera
camera: ## [board] слой камер Sensing GMSL2 + cloud-init поверх базового
	$(BS) image build -f vmfiles/jetson-orin-camera.vmfile --tag $(CAMERA_TAG)

.PHONY: workstation
workstation: ## [board] рабочая станция робота поверх слоя камер
	$(BS) image build --smp $(BUILD_SMP) --memsize $(BUILD_MEMSIZE) -f vmfiles/jetson-orin-workstation.vmfile --tag $(WORKSTATION_TAG)

.PHONY: images
images: camera workstation ## [board] оба образа подряд

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
