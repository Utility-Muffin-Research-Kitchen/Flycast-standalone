SHELL := /bin/bash

DOCKER ?= docker
TOOLCHAIN_IMAGE ?= ghcr.io/utility-muffin-research-kitchen/mlp1-toolchain:local
BUILD_JOBS ?=
MLP1_BUILD_PROFILE ?= perf

.PHONY: build-mlp1 fetch-upstream package-mlp1 verify-mlp1 \
	verify-package-mlp1 smoke-launch-wrapper clean

fetch-upstream:
	./scripts/fetch-upstream.sh

build-mlp1:
	DOCKER="$(DOCKER)" \
	TOOLCHAIN_IMAGE="$(TOOLCHAIN_IMAGE)" \
	BUILD_JOBS="$(BUILD_JOBS)" \
	MLP1_BUILD_PROFILE="$(MLP1_BUILD_PROFILE)" \
	./build-mlp1.sh

verify-mlp1: build-mlp1
	DOCKER="$(DOCKER)" \
	TOOLCHAIN_IMAGE="$(TOOLCHAIN_IMAGE)" \
	./scripts/verify-mlp1-binary.sh

package-mlp1: build-mlp1
	./package-mlp1.sh

verify-package-mlp1:
	./scripts/verify-mlp1-package.sh

smoke-launch-wrapper:
	./scripts/smoke-launch-wrapper.sh

clean:
	rm -rf output/mlp1
