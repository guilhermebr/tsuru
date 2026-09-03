# Copyright 2012 tsuru authors. All rights reserved.
# Use of this source code is governed by a BSD-style
# license that can be found in the LICENSE file.

SHELL         = /bin/bash -o pipefail
BUILD_DIR     = build
TSR_BIN       = $(BUILD_DIR)/tsurud
PLATFORMS_DIR = /tmp/platforms
TSR_SRC       = ./cmd/tsurud
GIT_TAG_VER   := $(shell git describe --tags --abbrev=0 2>/dev/null || echo "$${TSURU_BUILD_VERSION:-dev}")

# Everything except ./integration, which needs a live cluster.
PKGS = $(shell go list ./... | grep -v "github.com/tsuru/tsuru/integration")

# Keep GOLANGCI_LINT_VERSION in sync with .github/workflows/ci.yaml.
GOLANGCI_LINT_VERSION ?= v2.11.4
YAMLFMT_VERSION       ?= v0.9.0
SWAGGER_VERSION       ?= v0.30.3
API_DOCS_VERSION      ?= v0.0.1

# Version-keyed paths so the pinned version runs regardless of what is on PATH.
TOOLS_DIR     := $(abspath $(BUILD_DIR)/tools)
GOLANGCI_LINT  = $(TOOLS_DIR)/golangci-lint-$(GOLANGCI_LINT_VERSION)/golangci-lint
YAMLFMT        = $(TOOLS_DIR)/yamlfmt-$(YAMLFMT_VERSION)/yamlfmt
SWAGGER        = $(TOOLS_DIR)/swagger-$(SWAGGER_VERSION)/swagger
API_DOCS       = $(TOOLS_DIR)/tsuru-api-docs-$(API_DOCS_VERSION)/tsuru-api-docs

$(GOLANGCI_LINT):
	GOBIN=$(dir $@) go install github.com/golangci/golangci-lint/v2/cmd/golangci-lint@$(GOLANGCI_LINT_VERSION)

$(YAMLFMT):
	GOBIN=$(dir $@) go install github.com/google/yamlfmt/cmd/yamlfmt@$(YAMLFMT_VERSION)

$(SWAGGER):
	GOBIN=$(dir $@) go install github.com/go-swagger/go-swagger/cmd/swagger@$(SWAGGER_VERSION)

$(API_DOCS):
	GOBIN=$(dir $@) go install github.com/tsuru/tsuru-api-docs@$(API_DOCS_VERSION)

.PHONY: install-gotooling
install-gotooling: $(GOLANGCI_LINT) $(YAMLFMT) $(SWAGGER) $(API_DOCS) ## Install every pinned tool into build/tools

.PHONY: tools-clean
tools-clean: ## Remove the installed tools so the next run reinstalls them
	rm -rf $(TOOLS_DIR)

.DELETE_ON_ERROR:

.PHONY: help
help: ## Show this help
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n"} \
		/^[a-zA-Z_0-9.$$/-]+:.*?##/ { printf "  \033[36m%-24s\033[0m %s\n", $$1, $$2 } \
		/^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) }' $(MAKEFILE_LIST)
	@echo ""

.PHONY: all test race docs install tsurud $(TSR_BIN)

##@ Test

all: test ## Alias for `make test`

_go_test:
	go clean ./...
	go list ./... | grep -v "github.com/tsuru/tsuru/integration" | while read -r f; do \
		( go test  $$f -check.v || go test $$f ) || exit 1; \
	done

_tsurud_dry:
	go build -o tsurud ./cmd/tsurud
	./tsurud api --dry --config ./etc/tsuru.conf
	rm -f tsurud

test: _go_test _tsurud_dry ## Run the unit tests, then a tsurud config check

test-pkg: ## Test one package: PKG=./api [CHECK=<gocheck regex>] [RUN=<go test regex>]
	@test -n "$(PKG)" || { echo "usage: make test-pkg PKG=./api [CHECK=Name] [RUN=Name]"; exit 1; }
	go test -count=1 $(if $(or $(CHECK),$(RUN)),-v) $(PKG) \
		$(if $(CHECK),-check.v -check.f "$(CHECK)") \
		$(if $(RUN),-run "$(RUN)")

race: ## Run the unit tests under the race detector (what CI runs)
	go clean -testcache
	go test -race $(PKGS)

##@ Lint

lint: metalint yamllint ## Run every linter
	misc/check-contributors.sh

vet: ## Run go vet
	go vet $(PKGS)

.PHONY: ci-checks
ci-checks: vet check-handlers check-events check-contributors check-api-doc validate-api-spec ## Run the scripted CI gates in one shot

.PHONY: check-handlers check-events check-contributors
check-handlers: ## Every API handler must call permission.Check
	./misc/check-handlers.sh

check-events: ## Every non-GET handler must create an event
	./misc/check-events.sh

check-contributors: ## New authors must be listed in CONTRIBUTORS
	./misc/check-contributors.sh

metalint: $(GOLANGCI_LINT) ## Run golangci-lint
	$(GOLANGCI_LINT) run --timeout=10m ./...

yamlfmt: $(YAMLFMT) ## Format the yaml files
	$(YAMLFMT) .

yamllint: $(YAMLFMT) ## Check the yaml is valid and correctly formatted
	@echo "yamlfmt --quiet --lint ."
	@$(YAMLFMT) --quiet --lint . \
		|| ( echo "Please run 'make yamlfmt' to fix it (if a format error)" && exit 1 )

##@ Modernize

.PHONY: fix fix-diff
fix: ## Apply the Go modernizer fixes in place, then check the tree still builds
	go fix $(PKGS)
	go vet $(PKGS)

fix-diff: ## Show the Go modernizer fixes as a diff, without applying them
	go fix -diff $(PKGS)

##@ Docs

api-doc: $(API_DOCS) ## Regenerate docs/handlers.yml
	@$(API_DOCS) | grep -v missing > docs/handlers.yml

check-api-doc: $(API_DOCS) ## Fail if any handler is undocumented
	@exit $$($(API_DOCS) | grep missing | wc -l)

##@ Build

release:
	@if [ ! $(version) ]; then \
		echo "version parameter is required... use: make release version=<value>"; \
		exit 1; \
	fi

	$(eval SED := $(shell which gsed || which sed))
	$(eval PATCH := $(shell echo $(version) | $(SED) "s/^\([0-9]\{1,\}\.[0-9]\{1,\}\.[0-9]\{1,\}\).*/\1/"))
	$(eval MINOR := $(shell echo $(PATCH) | $(SED) "s/^\([0-9]\{1,\}\.[0-9]\{1,\}\).*/\1/"))
	@if [ $(MINOR) == $(PATCH) ]; then \
		echo "invalid version"; \
		exit 1; \
	fi

	@echo "Releasing tsuru $(version) version."
	@echo "Replacing version string."
	@$(SED) -i 's/const Version = ".*"/const Version = "$(version)"/' api/server.go
	@$(SED) -i 's/version: ".*"/version: "$(MINOR)"/' docs/reference/api.yaml

install: ## Install all binaries
	go install ./...

serve: run-tsurud-api

run: run-tsurud-api

binaries: tsurud

tsurud: $(TSR_BIN) ## Build tsurud into build/

$(TSR_BIN):
	CGO_ENABLED=0 go build -trimpath -ldflags '-s -w -X github.com/tsuru/tsuru/api.GitHash=$(shell git rev-parse HEAD) -X github.com/tsuru/tsuru/api.Version=$(GIT_TAG_VER)' -o $(TSR_BIN) $(TSR_SRC)

run-tsurud-api: $(TSR_BIN)
	$(TSR_BIN) api

run-tsurud-token: $(TSR_BIN)
	$(TSR_BIN) token

.PHONY: validate-api-spec
validate-api-spec: $(SWAGGER) ## Validate the OpenAPI spec
	$(SWAGGER) validate ./docs/reference/api.yaml

test-ci-integration:
	if [ -z "$$INTEGRATION_KUBECONFIG" ]; then \
		echo "INTEGRATION_KUBECONFIG is not set"; \
		exit 1; \
	fi
	git clone https://github.com/tsuru/platforms /tmp/platforms
	TSURU_INTEGRATION_examplesdir="/tmp/platforms/examples" \
	TSURU_INTEGRATION_enabled=1 TSURU_INTEGRATION_verbose=2 TSURU_INTEGRATION_maxconcurrency=4 \
	TSURU_INTEGRATION_platforms="python,go" \
	TSURU_INTEGRATION_no_rollback="true" \
	TSURU_INTEGRATION_provisioners="minikube" \
	go test -v -timeout 120m github.com/tsuru/tsuru/integration

clone_platforms:
	@if [ -d "$(PLATFORMS_DIR)" ]; then \
		echo "Directory $(PLATFORMS_DIR) exists."; \
	else \
		echo "Cloning platforms..."; \
		git clone https://github.com/tsuru/platforms $(PLATFORMS_DIR); \
	fi

local.test-ci-integration: clone_platforms
	if [ -z "$$INTEGRATION_KUBECONFIG" ]; then \
		echo "INTEGRATION_KUBECONFIG is not set"; \
		exit 1; \
	fi
	#git clone https://github.com/tsuru/platforms /tmp/platforms
	TSURU_INTEGRATION_examplesdir="/tmp/platforms/examples" \
	TSURU_INTEGRATION_enabled=1 TSURU_INTEGRATION_verbose=2 TSURU_INTEGRATION_maxconcurrency=1 \
	TSURU_INTEGRATION_platforms="python,go" \
	TSURU_INTEGRATION_no_rollback="false" \
	TSURU_INTEGRATION_provisioners="minikube" \
	TSURU_INTEGRATION_targetaddr="http://127.0.0.1:8080" \
	TSURU_INTEGRATION_adminuser="admin@admin.com" \
	TSURU_INTEGRATION_adminpassword="admin@123" \
	TSURU_INTEGRATION_local="true" \
	CLUSTER_PROVIDER=minikube \
	DEBUG="true" \
	go test -v -timeout 120m github.com/tsuru/tsuru/integration -check.v | tee ./test-output.log

generate-test-certs:
	openssl genrsa -out ./app/testdata/private.key 1024
	openssl req -new -x509 -sha256 -key ./app/testdata/private.key -subj '/CN=app.io' -addext 'subjectAltName = DNS:app.io' -out ./app/testdata/certificate.crt -days 3650
	cp ./app/testdata/private.key ./api/testdata/key.pem
	cp ./app/testdata/certificate.crt ./api/testdata/cert.pem


###
### LOCAL DEVELOPMENT
###
### See https://docs.tsuru.io/stable/contributing/development.html for more
### information on how to setup your local development environment.

# Docker binary. If you are using podman, you can change this to podman when
# running make commands. Example: make local DOCKER=podman
DOCKER ?= docker

# Kubernetes version used with minikube
K8S_VERSION = v1.32.0

# Tsuru local host
# This is used to configure the insecure registry in minikube as well as in the
# tsurud and buildkit configuration file.
TSURU_HOST_IP   ?= 100.64.100.100
TSURU_HOST_PORT ?= 8080

# Root user information
# Admin user information that can be used in the local development setup.
TSURU_ROOT_USER ?= admin@admin.com
TSURU_ROOT_PASS ?= admin@123

# Local development script
# This script will be used to setup the local development environment.
LOCAL_DEV ?= ./misc/local-dev.sh

# Host information
# This is used to determine which local development setup to use.
HOST_PLATFORM := $(shell uname -s)
HOST_ARCH     := $(shell uname -m)

ifeq ($(HOST_PLATFORM),Darwin)

# For MacsOS, you can use the qemu2 driver with minikube.
# It is recommended to use the socket_vmnet network to avoid issues with the default bridge network.
# Reference: https://minikube.sigs.k8s.io/docs/drivers/qemu/#known-issues
# 
# NOTE: Only tested on Apple M series Macs.
local.cluster:
	@$(LOCAL_DEV) setup-loopback $(TSURU_HOST_IP)
	@if ! minikube status &>/dev/null; then \
		echo "Starting local kubernetes cluster for mac mseries..."; \
		minikube start \
			--insecure-registry="$(TSURU_HOST_IP):5000" \
			--driver=qemu2 \
			--network=socket_vmnet \
			--kubernetes-version=$(K8S_VERSION); \
	fi

else

local.cluster:
	@$(LOCAL_DEV) setup-loopback $(TSURU_HOST_IP)
	@if ! minikube status &>/dev/null; then \
		echo "Starting local kubernetes cluster for linux..."; \
		minikube start \
			--insecure-registry="$(TSURU_HOST_IP):5000" \
			--driver=docker \
			--kubernetes-version=$(K8S_VERSION); \
	fi

endif

# Local development setup
# Setup local development environment for tsuru. It only needs to be run once.
# If the setup is already done, you can skip this step and use `make local.run`
local.setup: local.cluster
	@echo "Setting up local tsuru development environment..."
	@$(LOCAL_DEV) render-templates $(TSURU_HOST_IP) $(TSURU_HOST_PORT)
	@$(DOCKER) compose --profile tsurud-api up -d
	@$(LOCAL_DEV) setup-tsuru-user $(TSURU_ROOT_USER) $(TSURU_ROOT_PASS)
	@$(LOCAL_DEV) setup-tsuru-target $(TSURU_HOST_IP) $(TSURU_HOST_PORT)
	@$(LOCAL_DEV) setup-tsuru-cluster $(TSURU_HOST_IP)
	@$(DOCKER) stop tsuru-api >/dev/null
	@echo ""
	@echo "Setup complete. You don't need to run this step next time."
	@echo "To start the local development environment, run 'make local.run'."
	@touch ".local-setup"

local.prerun:
	@if [ ! -f ".local-setup" ]; then \
		echo "Environment not ready. Please run make 'local.setup' first.";  \
		exit 1; \
	fi

# Local development run
# Start the local development environment for tsuru.
local.run: local.prerun local.cluster
	@echo "Starting local tsuru development environment..."
	$(DOCKER) compose up -d
	go build -o $(TSR_BIN) $(TSR_SRC)
	$(TSR_BIN) api -c "./etc/tsurud.conf"

# Local development stop
# Stop the local development environment for tsuru.
local.stop:
	@echo "Stopping local tsuru development environment..."
	@$(DOCKER) compose --profile tsurud-api down
	@minikube stop
	@$(LOCAL_DEV) cleanup-loopback $(TSURU_HOST_IP)

# Local development cleanup
# Clear the local development environment for tsuru.
local.cleanup: local.stop
	@echo "Clearing local tsuru development environment..."
	@$(DOCKER) compose down --volumes --rmi all
	@minikube delete
	@find ./etc ! -name '*.template' ! -name 'tsuru.conf' -mindepth 1 | \
		xargs -I{} echo rm {}
	@rm -f .local-setup

.PHONY: local.setup local.cluster local.precluster local.run local.stop local.cleanup


.PHONY: install-swagger
install-swagger: $(SWAGGER) ## Install the pinned swagger binary


PROTOC ?= protoc
.PHONY: generate
generate-grpc:
	$(PROTOC) --go_out=. --go_opt=paths=source_relative \
		--go-grpc_out=. --go-grpc_opt=paths=source_relative \
		types/tag/service.proto

connect-db:
	@$(DOCKER) compose exec mongo bash -c 'mongosh "mongodb://mongo:27017'
