# Approve agent tools with Atryum — OpenShift / Helm deployment targets.
# See README.md for prerequisites, install, demo walkthrough, and uninstall.

SHELL := /bin/bash
.DEFAULT_GOAL := help

CHART_DIR ?= ./chart
RELEASE   ?= quickstart
NAMESPACE ?= atryum-quickstart
HELM_ARGS ?=

ATRYUM_IMAGE ?= validmind/atryum
ATRYUM_TAG   ?= 0.10.0
DEMO_IMAGE   ?= validmind/atryum-finance-demo
DEMO_TAG     ?= latest

# OpenShift apps wildcard domain, used to compute stable Route hosts and
# Atryum's public_base_url. Auto-detected; override if detection fails.
# Deferred (?=) and only expanded by targets that talk to the cluster, so
# offline targets (env-init, lint, …) never wait on oc; the request itself
# is capped at 5s.
CLUSTER_DOMAIN ?= $(shell oc get ingresses.config/cluster -o jsonpath='{.spec.domain}' --request-timeout=5s 2>/dev/null)

# Source .env for helm/oc recipes (MODEL_API_KEY, MODEL_NAME, MODEL_ENDPOINT).
define with_env
	set -a; \
	if [[ -f .env ]]; then source .env; else echo "Warning: .env not found — run: make env-init" >&2; fi; \
	set +a; \
	$(1)
endef

# The user-supplied LLM credential (OpenAI or compatible) drives both Atryum's
# AI-evaluation judge and the demo agents.
# Recursive (=), NOT :=, so CLUSTER_DOMAIN's oc call only runs when a target
# actually expands these.
HELM_MODEL_SETS = \
	--set-string model.api_key="$${MODEL_API_KEY}" \
	--set-string model.name="$${MODEL_NAME:-gpt-4o}" \
	--set-string model.endpoint="$${MODEL_ENDPOINT}"

HELM_SETS = \
	--set-string clusterDomain="$(CLUSTER_DOMAIN)" \
	--set-string atryum.image.repository="$(ATRYUM_IMAGE)" \
	--set-string atryum.image.tag="$(ATRYUM_TAG)" \
	--set-string demo.image.repository="$(DEMO_IMAGE)" \
	--set-string demo.image.tag="$(DEMO_TAG)" \
	$(HELM_MODEL_SETS)

.PHONY: help env-init env-check env-verify namespace lint template \
	install configure wait status urls logs logs-configure uninstall cleanup-namespace

help: ## Show available targets
	@awk 'BEGIN {FS = ":.*##"; printf "Usage: make [target]\n\nTargets:\n"} \
		/^[a-zA-Z0-9_.-]+:.*##/ {printf "  %-20s %s\n", $$1, $$2} \
		/^##@/ {printf "\n%s\n", substr($$0, 5)}' $(MAKEFILE_LIST)
	@echo ""
	@echo "Common variables (override on the command line):"
	@echo "  NAMESPACE=$(NAMESPACE)"
	@echo "  RELEASE=$(RELEASE)"
	@echo "  ATRYUM_IMAGE=$(ATRYUM_IMAGE):$(ATRYUM_TAG)"
	@echo "  DEMO_IMAGE=$(DEMO_IMAGE):$(DEMO_TAG)"
	@echo "  CLUSTER_DOMAIN   (auto-detected from the cluster at install time; override if detection fails)"

##@ Setup

env-init: ## Copy .env.example to .env
	@test -f .env || cp .env.example .env
	@echo "Created .env — set MODEL_API_KEY (OpenAI or compatible) before installing."

env-check: ## Ensure .env exists (creates from .env.example when missing)
	@test -f .env || cp .env.example .env

env-verify: env-check ## Fail if MODEL_API_KEY is missing or a placeholder
	@$(call with_env, \
	if [[ -z "$${MODEL_API_KEY}" || "$${MODEL_API_KEY}" == changeme* ]]; then \
		echo "Set MODEL_API_KEY in .env (OpenAI or compatible API key)"; exit 1; \
	fi; \
	if [[ -n "$${MODEL_ENDPOINT}" && -z "$${MODEL_NAME}" ]]; then \
		echo "MODEL_ENDPOINT is set — also set MODEL_NAME to the served model's name"; exit 1; \
	fi)
	@echo ".env looks good."

namespace: ## Create or select the OpenShift project
	@oc get project "$(NAMESPACE)" >/dev/null 2>&1 || oc new-project "$(NAMESPACE)" >/dev/null
	@oc project "$(NAMESPACE)" >/dev/null
	@echo "Using project $(NAMESPACE)"

##@ Install

install: env-verify namespace ## Install Atryum + demo and seed agents, charters, and rules
	@$(call with_env,helm upgrade --install "$(RELEASE)" "$(CHART_DIR)" \
		--namespace "$(NAMESPACE)" \
		--create-namespace \
		$(HELM_SETS) $(HELM_ARGS))
	@$(MAKE) wait
	@$(MAKE) urls

configure: env-verify ## Re-run the configuration Job (re-seeds agents, charters, rules)
	@$(call with_env,helm upgrade "$(RELEASE)" "$(CHART_DIR)" \
		--namespace "$(NAMESPACE)" \
		--reuse-values \
		$(HELM_MODEL_SETS))
	@$(MAKE) logs-configure

wait: ## Wait until Atryum and the demo are ready
	@oc rollout status deploy/$(RELEASE)-atryum -n "$(NAMESPACE)"
	@oc rollout status deploy/$(RELEASE)-demos -n "$(NAMESPACE)" 2>/dev/null || true
	@oc wait --for=condition=complete job/$(RELEASE)-configure -n "$(NAMESPACE)" --timeout=600s 2>/dev/null || true

##@ Operate

urls: ## Print the Atryum and demo dashboard URLs
	@echo "Atryum UI      : https://$$(oc get route $(RELEASE)-atryum -n '$(NAMESPACE)' -o jsonpath='{.spec.host}' 2>/dev/null || echo '<no route>')"
	@echo "Demo dashboard : https://$$(oc get route $(RELEASE)-demos -n '$(NAMESPACE)' -o jsonpath='{.spec.host}' 2>/dev/null || echo '<no route>')"

status: ## Show pods, jobs, and routes in the namespace
	@oc get pods,jobs,routes -n "$(NAMESPACE)"

logs: ## Tail Atryum's logs
	@oc logs -f deploy/$(RELEASE)-atryum -n "$(NAMESPACE)"

logs-configure: ## Show logs from the configuration Job
	@oc logs -f job/$(RELEASE)-configure -n "$(NAMESPACE)"

##@ Development

lint: ## helm lint the chart
	@helm lint "$(CHART_DIR)" --set model.api_key=lint-placeholder

template: env-check ## Render the chart locally for inspection
	@$(call with_env,helm template "$(RELEASE)" "$(CHART_DIR)" \
		--namespace "$(NAMESPACE)" \
		$(HELM_SETS) $(HELM_ARGS))

##@ Uninstall

uninstall: ## Remove the Helm release (keeps the namespace and PVC)
	@helm uninstall "$(RELEASE)" --namespace "$(NAMESPACE)"

cleanup-namespace: ## Delete the entire namespace (removes ALL data)
	@oc delete project "$(NAMESPACE)"
