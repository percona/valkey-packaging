.PHONY: build build-hardened build-rpm run stop clean logs test test-hardened test-rpm help all \
        build-admin build-admin-rpm build-admin-hardened test-admin test-admin-rpm test-admin-hardened \
        buildx-admin buildx-admin-hardened \
        build-bundle build-bundle-hardened build-bundle-rpm test-bundle test-bundle-hardened test-bundle-rpm \
        build-mod build-mods build-mod-json build-mod-bloom build-mod-search build-mod-ldap build-mod-audit \
        test-mod test-mods test-mod-json test-mod-bloom test-mod-search test-mod-ldap test-mod-audit \
        buildx-mod buildx-mods buildx-mod-json buildx-mod-bloom buildx-mod-search buildx-mod-ldap buildx-mod-audit

IMAGE_NAME := perconalab/valkey
BUNDLE_IMAGE_NAME := perconalab/valkey-bundle
VALKEY_VERSION := 9.1.3
REPO_CHANNEL ?= experimental

TAG_HARDENED := $(VALKEY_VERSION)-hardened
TAG_RPM := $(VALKEY_VERSION)

# --- Module artifact images (thin, self-contained; injected in k8s) ----------
MOD_IMAGE_PREFIX := perconalab/valkey-mod
ADMIN_IMAGE_NAME := perconalab/valkey-admin

# valkey-admin is a separate product on its own version line.
VALKEY_ADMIN_VERSION := 1.2.0
TAG_ADMIN            := $(VALKEY_ADMIN_VERSION)
TAG_ADMIN_HARDENED   := $(VALKEY_ADMIN_VERSION)-hardened

MOD_VERSION_json   := 1.0.3
MOD_VERSION_bloom  := 1.0.1
MOD_VERSION_search := 1.2.1
MOD_VERSION_ldap   := 1.1.1
MOD_VERSION_audit  := 1.0.0

MOD_SOURCE_json   := https://github.com/valkey-io/valkey-json
MOD_SOURCE_bloom  := https://github.com/valkey-io/valkey-bloom
MOD_SOURCE_search := https://github.com/valkey-io/valkey-search
MOD_SOURCE_ldap   := https://github.com/valkey-io/valkey-ldap
MOD_SOURCE_audit  := https://github.com/percona/valkey-audit

MODULE ?= json

# Multi-arch (buildx) settings for module images. A multi-arch image cannot be
# loaded into the local image store, so buildx targets push to the registry by
# default; override MOD_OUTPUT (e.g. '--output type=oci,dest=out.tar') to avoid
# pushing. Requires `docker buildx` and a registry login for --push.
PLATFORMS  ?= linux/amd64,linux/arm64
MOD_OUTPUT ?= --push

help:
	@echo "Valkey Docker Images"
	@echo ""
	@echo "Available targets:"
	@echo "  build          - Build both images (hardened + RPM)"
	@echo "  build-hardened - Build hardened DHI image (Dockerfile.hardened)"
	@echo "  build-rpm      - Build RPM/UBI9 image (Dockerfile)"
	@echo "  build-bundle   - Build both bundle images (server + all modules)"
	@echo "  test           - Test both images"
	@echo "  test-hardened  - Test hardened image"
	@echo "  test-rpm       - Test RPM image"
	@echo "  test-bundle    - Test both bundle images"
	@echo "  build-mods     - Build all 5 thin module artifact images (json/bloom/search/ldap/audit)"
	@echo "  test-mods      - Inject each module into a stock server and verify it loads"
	@echo "  buildx-mods    - Build+push all 5 module images multi-arch (amd64+arm64; needs buildx)"
	@echo "  build-admin    - Build both valkey-admin images (UBI9 + hardened)"
	@echo "  test-admin     - Test both valkey-admin images"
	@echo "  buildx-admin   - Build+push the valkey-admin UBI9 image multi-arch"
	@echo "  run            - Start Valkey container with docker-compose"
	@echo "  stop           - Stop Valkey container"
	@echo "  logs           - Show container logs"
	@echo "  clean          - Remove containers, volumes, and images"
	@echo "  all            - Build and test both images"
	@echo ""
	@echo "Variables:"
	@echo "  REPO_CHANNEL   - Percona repo channel (default: experimental)"
	@echo "                   Usage: make build REPO_CHANNEL=release"

build: build-hardened build-rpm

build-hardened:
	@echo "Building hardened Valkey image (DHI)..."
	docker build --build-arg REPO_CHANNEL=$(REPO_CHANNEL) -t $(IMAGE_NAME):$(TAG_HARDENED) -f Dockerfile.hardened .

build-rpm:
	@echo "Building RPM Valkey image (UBI9)..."
	docker build --build-arg REPO_CHANNEL=$(REPO_CHANNEL) -t $(IMAGE_NAME):$(TAG_RPM) -f Dockerfile .

test: test-hardened test-rpm

test-hardened:
	VALKEY_VERSION=$(VALKEY_VERSION) ./test-image.sh $(IMAGE_NAME):$(TAG_HARDENED) hardened

test-rpm:
	VALKEY_VERSION=$(VALKEY_VERSION) ./test-image.sh $(IMAGE_NAME):$(TAG_RPM) rpm

# --- Bundle images (server + all modules: json/bloom/search/ldap) ---------
build-bundle: build-bundle-hardened build-bundle-rpm

build-bundle-hardened:
	@echo "Building hardened Valkey Bundle image (DHI)..."
	docker build --build-arg REPO_CHANNEL=$(REPO_CHANNEL) -t $(BUNDLE_IMAGE_NAME):$(TAG_HARDENED) -f Dockerfile.bundle.hardened .

build-bundle-rpm:
	@echo "Building RPM Valkey Bundle image (UBI9)..."
	docker build --build-arg REPO_CHANNEL=$(REPO_CHANNEL) -t $(BUNDLE_IMAGE_NAME):$(TAG_RPM) -f Dockerfile.bundle .

test-bundle: test-bundle-hardened test-bundle-rpm

test-bundle-hardened:
	VALKEY_VERSION=$(VALKEY_VERSION) ./test-image.sh $(BUNDLE_IMAGE_NAME):$(TAG_HARDENED) bundle-hardened

test-bundle-rpm:
	VALKEY_VERSION=$(VALKEY_VERSION) ./test-image.sh $(BUNDLE_IMAGE_NAME):$(TAG_RPM) bundle-rpm

# --- Module artifact images -------------------------------------------------
# Build one module image:  make build-mod MODULE=search
build-mod:
	docker build \
	  --build-arg MODULE=$(MODULE) \
	  --build-arg MODULE_VERSION=$(MOD_VERSION_$(MODULE)) \
	  --build-arg MODULE_SOURCE=$(MOD_SOURCE_$(MODULE)) \
	  --build-arg REPO_CHANNEL=$(REPO_CHANNEL) \
	  -t $(MOD_IMAGE_PREFIX)-$(MODULE):$(MOD_VERSION_$(MODULE)) \
	  -f Dockerfile.module .

build-mod-json:   ; $(MAKE) build-mod MODULE=json
build-mod-bloom:  ; $(MAKE) build-mod MODULE=bloom
build-mod-search: ; $(MAKE) build-mod MODULE=search
build-mod-ldap:   ; $(MAKE) build-mod MODULE=ldap
build-mod-audit:  ; $(MAKE) build-mod MODULE=audit
build-mods: build-mod-json build-mod-bloom build-mod-search build-mod-ldap build-mod-audit

# Inject a module into a stock server and assert it loads.
# Override the server image with SRV_IMAGE=... (e.g. the hardened tag).
test-mod:
	VALKEY_VERSION=$(VALKEY_VERSION) ./test-module-inject.sh \
	  $(MOD_IMAGE_PREFIX)-$(MODULE):$(MOD_VERSION_$(MODULE)) $(MODULE) $(SRV_IMAGE)

test-mod-json:   ; $(MAKE) test-mod MODULE=json
test-mod-bloom:  ; $(MAKE) test-mod MODULE=bloom
test-mod-search: ; $(MAKE) test-mod MODULE=search
test-mod-ldap:   ; $(MAKE) test-mod MODULE=ldap
test-mod-audit:  ; $(MAKE) test-mod MODULE=audit
test-mods: test-mod-json test-mod-bloom test-mod-search test-mod-ldap test-mod-audit

# Multi-arch module images (amd64+arm64). Needs docker buildx; pushes a manifest
# list to the registry (multi-arch can't be loaded locally). Build one arch for
# local testing with the plain build-mod target instead.
buildx-mod:
	docker buildx build \
	  --platform $(PLATFORMS) \
	  --build-arg MODULE=$(MODULE) \
	  --build-arg MODULE_VERSION=$(MOD_VERSION_$(MODULE)) \
	  --build-arg MODULE_SOURCE=$(MOD_SOURCE_$(MODULE)) \
	  --build-arg REPO_CHANNEL=$(REPO_CHANNEL) \
	  -t $(MOD_IMAGE_PREFIX)-$(MODULE):$(MOD_VERSION_$(MODULE)) \
	  -f Dockerfile.module $(MOD_OUTPUT) .

buildx-mod-json:   ; $(MAKE) buildx-mod MODULE=json
buildx-mod-bloom:  ; $(MAKE) buildx-mod MODULE=bloom
buildx-mod-search: ; $(MAKE) buildx-mod MODULE=search
buildx-mod-ldap:   ; $(MAKE) buildx-mod MODULE=ldap
buildx-mod-audit:  ; $(MAKE) buildx-mod MODULE=audit
buildx-mods: buildx-mod-json buildx-mod-bloom buildx-mod-search buildx-mod-ldap buildx-mod-audit

# --- Valkey Admin images (web UI) -------------------------------------------
build-admin: build-admin-rpm build-admin-hardened

build-admin-rpm:
	@echo "Building RPM Valkey Admin image (UBI9)..."
	docker build \
	  --build-arg REPO_CHANNEL=$(REPO_CHANNEL) \
	  --build-arg ADMIN_VERSION=$(VALKEY_ADMIN_VERSION) \
	  -t $(ADMIN_IMAGE_NAME):$(TAG_ADMIN) -f Dockerfile.admin .

build-admin-hardened:
	@echo "Building hardened Valkey Admin image (DHI)..."
	docker build \
	  --build-arg REPO_CHANNEL=$(REPO_CHANNEL) \
	  --build-arg ADMIN_VERSION=$(VALKEY_ADMIN_VERSION) \
	  -t $(ADMIN_IMAGE_NAME):$(TAG_ADMIN_HARDENED) -f Dockerfile.admin.hardened .

test-admin: test-admin-rpm test-admin-hardened

test-admin-rpm:
	VALKEY_ADMIN_VERSION=$(VALKEY_ADMIN_VERSION) \
	  ./test-admin-image.sh $(ADMIN_IMAGE_NAME):$(TAG_ADMIN) rpm

test-admin-hardened:
	VALKEY_ADMIN_VERSION=$(VALKEY_ADMIN_VERSION) \
	  ./test-admin-image.sh $(ADMIN_IMAGE_NAME):$(TAG_ADMIN_HARDENED) hardened

# Multi-arch admin images (amd64+arm64). Needs docker buildx; pushes a manifest
# list to the registry, since a multi-arch image cannot be loaded locally.
buildx-admin:
	docker buildx build \
	  --platform $(PLATFORMS) \
	  --build-arg REPO_CHANNEL=$(REPO_CHANNEL) \
	  --build-arg ADMIN_VERSION=$(VALKEY_ADMIN_VERSION) \
	  -t $(ADMIN_IMAGE_NAME):$(TAG_ADMIN) -f Dockerfile.admin $(MOD_OUTPUT) .

buildx-admin-hardened:
	docker buildx build \
	  --platform $(PLATFORMS) \
	  --build-arg REPO_CHANNEL=$(REPO_CHANNEL) \
	  --build-arg ADMIN_VERSION=$(VALKEY_ADMIN_VERSION) \
	  -t $(ADMIN_IMAGE_NAME):$(TAG_ADMIN_HARDENED) -f Dockerfile.admin.hardened $(MOD_OUTPUT) .

run:
	@echo "Starting Valkey..."
	docker-compose up -d
	@echo "Waiting for container to be healthy..."
	@sleep 5
	@docker-compose ps

stop:
	@echo "Stopping Valkey..."
	docker-compose down

logs:
	docker-compose logs -f valkey

clean:
	@echo "Cleaning up..."
	docker-compose down -v
	docker rmi $(IMAGE_NAME):$(TAG_HARDENED) || true
	docker rmi $(IMAGE_NAME):$(TAG_RPM) || true
	@echo "Cleanup complete!"

all: build test
	@echo "All builds and tests complete!"
