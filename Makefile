.PHONY: build setup install test test-unit test-integration check fmt lint

IMAGE  := docker.io/library/node:26.5-trixie

PODMAN := podman run --rm \
          -v "$(PWD)":/work \
          -v "$(PWD)/.cache":/root/.npm \
          -w /work \
          $(IMAGE)

# Podman refuses a bind mount whose source is missing, and the npm cache is not
# in the repository. Every target creates it first.
.cache:
	mkdir -p .cache

setup: | .cache
	$(PODMAN) npm install && $(PODMAN) npm ci

install: | .cache
	$(PODMAN) npm ci

test: | .cache
	$(PODMAN) node --test "test/**/*.test.ts"

test-unit: | .cache
	$(PODMAN) node --test "test/*.test.ts"

test-integration: | .cache
	$(PODMAN) node --test "test/integration/*.test.ts"

check: | .cache
	$(PODMAN) npx tsc --noEmit

fmt: | .cache
	$(PODMAN) npx oxfmt "**/*.ts" "!tools/**"

lint: | .cache
	$(PODMAN) npx oxlint
