SHELL := /bin/bash

IMAGE ?= myos-build
CONTAINER_ENGINE ?= $(shell command -v podman 2>/dev/null || command -v docker 2>/dev/null)
ROOT := $(CURDIR)
# Host Ollama dir whose models get bundled into the ISO. From WSL, point it
# at the Windows install: make iso OLLAMA_HOME=/mnt/c/Users/<you>/.ollama
OLLAMA_HOME ?= $(HOME)/.ollama

.DEFAULT_GOAL := help

.PHONY: help doctor image protos daemon pkgs iso run-qemu run-qemu-bios run-vmware test clean

help:
	@echo "MyOS M0 build commands"
	@echo "  make doctor          Check host prerequisites"
	@echo "  make image           Build the Arch Linux toolchain container"
	@echo "  make protos          Lint the canonical protobuf API"
	@echo "  make daemon          Build and test the Rust daemon skeleton"
	@echo "  make pkgs            Build MyOS pacman packages and local repo"
	@echo "  make iso             Build the bootable x86_64 ISO"
	@echo "  make run-qemu        Boot the newest ISO with UEFI"
	@echo "  make run-qemu-bios   Boot the newest ISO with legacy BIOS"
	@echo "  make run-vmware      Generate a VMware VMX for the newest ISO"
	@echo "  make test            Run source, proto, and Rust tests"

doctor:
	@./scripts/doctor.sh

image:
	@test -n "$(CONTAINER_ENGINE)" || (echo "Install Podman or start Docker Desktop" >&2; exit 1)
	$(CONTAINER_ENGINE) build -t $(IMAGE) -f ci/archlinux-build.Containerfile .

protos: image
	$(CONTAINER_ENGINE) run --rm -v "$(ROOT):/src" -w /src $(IMAGE) buf lint

daemon: image
	$(CONTAINER_ENGINE) run --rm -v "$(ROOT):/src" -w /src/daemon $(IMAGE) cargo test --workspace

pkgs: image
	$(CONTAINER_ENGINE) run --rm -v "$(ROOT):/src" -w /src $(IMAGE) bash ./scripts/build-packages.sh

iso: image
	$(CONTAINER_ENGINE) volume create myos-pacman-cache >/dev/null
	$(CONTAINER_ENGINE) run --rm --privileged -v "$(ROOT):/src" -v "$(OLLAMA_HOME):/root/.ollama_host" -v "myos-pacman-cache:/var/cache/pacman/pkg" -w /src $(IMAGE) bash ./scripts/build-iso.sh

run-qemu:
	@./scripts/run-qemu.sh uefi

run-qemu-bios:
	@./scripts/run-qemu.sh bios

run-vmware:
	@./scripts/run-vmware.sh

test: image
	$(CONTAINER_ENGINE) run --rm -v "$(ROOT):/src" -w /src $(IMAGE) bash ./scripts/test.sh

clean:
	rm -rf out work .cache
