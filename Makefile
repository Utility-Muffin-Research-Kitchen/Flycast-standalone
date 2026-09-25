SHELL := /bin/bash

DOCKER ?= docker
TOOLCHAIN_IMAGE ?= $(shell python3 -c 'import json; print(json.load(open("locks/build-inputs.lock.json"))["mlp1_toolchain_image"])')
BUILD_JOBS ?=
MLP1_BUILD_PROFILE ?= perf

.PHONY: build-mlp1 fetch-upstream fetch-contract-fixtures package-mlp1 \
	verify-mlp1 verify-package-mlp1 smoke-launch-wrapper build-lock-test \
	package-version-test ra-account-contract-test ra-account-fault-test \
	ra-route-test binary-capabilities-test dist-source test-dist-source clean

fetch-upstream:
	./scripts/fetch-upstream.sh

fetch-contract-fixtures:
	./scripts/fetch-contract-fixtures.sh

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

build-lock-test:
	./scripts/build-lock-test.sh

package-version-test:
	./scripts/package-version-test.sh

dist-source: fetch-upstream
	./scripts/fetch-build-inputs.sh
	python3 scripts/dist-source.py create

# Build package-mlp1 first; this target compares it with a fresh offline build.
test-dist-source: dist-source
	bash scripts/dist-source-test.sh

ra-account-contract-test:
	./scripts/ra-account-contract-test.sh

ra-account-fault-test:
	./scripts/ra-account-fault-test.sh

ra-route-test:
	./scripts/ra-route-test.sh

binary-capabilities-test:
	./scripts/binary-capabilities-test.sh

clean:
	rm -rf output/mlp1 output/host
