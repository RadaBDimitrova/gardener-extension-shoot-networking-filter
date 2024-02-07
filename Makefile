# SPDX-FileCopyrightText: 2021 SAP SE or an SAP affiliate company and Gardener contributors
#
# SPDX-License-Identifier: Apache-2.0

ENSURE_GARDENER_MOD         := $(shell go get github.com/gardener/gardener@$$(go list -m -f "{{.Version}}" github.com/gardener/gardener))
GARDENER_HACK_DIR           := $(shell go list -m -f "{{.Dir}}" github.com/gardener/gardener)/hack
EXTENSION_PREFIX            := gardener-extension
NAME                        := shoot-networking-filter
REGISTRY                    := europe-docker.pkg.dev/gardener-project/public/gardener
IMAGE_PREFIX                := $(REGISTRY)/extensions
REPO_ROOT                   := $(shell dirname $(realpath $(lastword $(MAKEFILE_LIST))))
HACK_DIR                    := $(REPO_ROOT)/hack
VERSION                     := $(shell cat "$(REPO_ROOT)/VERSION")
EFFECTIVE_VERSION           := $(VERSION)-$(shell git rev-parse HEAD)
LD_FLAGS                    := "-w $(shell bash $(GARDENER_HACK_DIR)/get-build-ld-flags.sh k8s.io/component-base $(REPO_ROOT)/VERSION $(EXTENSION_PREFIX)-$(NAME))"
LEADER_ELECTION             := false
IGNORE_OPERATION_ANNOTATION := true
NON_SHOOT_NAME              := gardener-runtime-networking-filter

ifneq ($(strip $(shell git status --porcelain 2>/dev/null)),)
	EFFECTIVE_VERSION := $(EFFECTIVE_VERSION)-dirty
endif

#########################################
# Tools                                 #
#########################################

TOOLS_DIR := hack/tools
include $(GARDENER_HACK_DIR)/tools.mk

.PHONY: start
start:
	@LEADER_ELECTION_NAMESPACE=garden go run \
		-ldflags $(LD_FLAGS) \
		./cmd/$(EXTENSION_PREFIX)-$(NAME) \
		--ignore-operation-annotation=$(IGNORE_OPERATION_ANNOTATION) \
		--leader-election=$(LEADER_ELECTION) \
		--config=./example/00-config.yaml \
		--gardener-version="v1.39.0"

#################################################################
# Rules related to binary build, Docker image build and release #
#################################################################

.PHONY: install
install:
	@LD_FLAGS=$(LD_FLAGS) EFFECTIVE_VERSION=$(EFFECTIVE_VERSION) \
	bash $(GARDENER_HACK_DIR)/install.sh ./...

.PHONY: docker-login
docker-login:
	@gcloud auth activate-service-account --key-file .kube-secrets/gcr/gcr-readwrite.json

.PHONY: docker-images
docker-images:
	@docker build --build-arg EFFECTIVE_VERSION=$(EFFECTIVE_VERSION) -t $(IMAGE_PREFIX)/$(NAME):$(VERSION) -t $(IMAGE_PREFIX)/$(NAME):latest -f Dockerfile -m 6g --target $(EXTENSION_PREFIX)-$(NAME) .
	@docker build --build-arg EFFECTIVE_VERSION=$(EFFECTIVE_VERSION) -t $(IMAGE_PREFIX)/$(NON_SHOOT_NAME):$(VERSION) -t $(IMAGE_PREFIX)/$(NON_SHOOT_NAME):latest -f Dockerfile -m 6g --target $(NON_SHOOT_NAME) .

#####################################################################
# Rules for verification, formatting, linting, testing and cleaning #
#####################################################################

.PHONY: tidy
tidy:
	@go mod tidy
	@mkdir -p $(REPO_ROOT)/.ci/hack && cp $(GARDENER_HACK_DIR)/.ci/* $(GARDENER_HACK_DIR)/generate-controller-registration.sh $(REPO_ROOT)/.ci/hack/ && chmod +xw $(REPO_ROOT)/.ci/hack/*
	@cp $(GARDENER_HACK_DIR)/cherry-pick-pull.sh $(HACK_DIR)/cherry-pick-pull.sh && chmod +xw $(HACK_DIR)/cherry-pick-pull.sh

.PHONY: clean
clean:
	@$(shell find ./example -type f -name "controller-registration.yaml" -exec rm '{}' \;)
	@bash $(GARDENER_HACK_DIR)/clean.sh ./cmd/... ./pkg/... ./test/...

.PHONY: check-generate
check-generate:
	@bash $(GARDENER_HACK_DIR)/check-generate.sh $(REPO_ROOT)

.PHONY: check
check: $(GOIMPORTS) $(GOLANGCI_LINT) $(HELM) $(YQ)
	@bash $(GARDENER_HACK_DIR)/check.sh --golangci-lint-config=./.golangci.yaml ./cmd/... ./pkg/... ./test/...
	@bash $(GARDENER_HACK_DIR)/check-charts.sh ./charts

.PHONY: generate
generate: $(CONTROLLER_GEN) $(GEN_CRD_API_REFERENCE_DOCS) $(HELM) $(YQ) $(VGOPATH)
	@VGOPATH=$(VGOPATH) REPO_ROOT=$(REPO_ROOT) GARDENER_HACK_DIR=$(GARDENER_HACK_DIR) hack/update-codegen.sh
	@VGOPATH=$(VGOPATH) REPO_ROOT=$(REPO_ROOT) GARDENER_HACK_DIR=$(GARDENER_HACK_DIR) bash $(GARDENER_HACK_DIR)/generate-sequential.sh ./charts/... ./cmd/... ./pkg/... ./test/...
	@$(MAKE) format

.PHONY: format
format: $(GOIMPORTS) $(GOIMPORTSREVISER)
	@bash $(GARDENER_HACK_DIR)/format.sh ./cmd ./pkg ./test

.PHONY: test
test:
	@SKIP_FETCH_TOOLS=1 bash $(GARDENER_HACK_DIR)/test.sh ./cmd/... ./pkg/...

.PHONY: test-cov
test-cov:
	@SKIP_FETCH_TOOLS=1 bash $(GARDENER_HACK_DIR)/test-cover.sh ./cmd/... ./pkg/...

.PHONY: test-clean
test-clean:
	@bash $(GARDENER_HACK_DIR)/test-cover-clean.sh

.PHONY: verify
verify: check format test

.PHONY: verify-extended
verify-extended: check-generate check format test test-cov test-clean

.PHONY: test-e2e-local
test-e2e-local: $(KIND) $(YQ) $(GINKGO)
	@$(REPO_ROOT)/hack/test-e2e-provider-local.sh --procs=3
