SHELL := /usr/bin/env bash

# Shared configuration contract. Override via environment
# or a gitignored .env at the repo root (non-secret settings only).
REPO_URL       ?= https://github.com/readyon-matheus-santos/argocd-migration-poc.git
GITHUB_LOGIN   ?= $(shell gh api user --jq .login 2>/dev/null)
GIT_BRANCH     ?= main

-include .env
export REPO_URL GITHUB_LOGIN GIT_BRANCH

.PHONY: workload-cluster bootstrap repo-secret teardown clean status preflight seed lint scenario-% assert-%

preflight:
	@bash bootstrap/preflight.sh

bootstrap: preflight
	@bash bootstrap/cluster-up.sh
	@bash bootstrap/install-argocd.sh
	@$(MAKE) repo-secret
	@bash bootstrap/apply-root-app.sh
	@bash bootstrap/wait-for-root.sh
	@bash scripts/seed.sh

workload-cluster:
	@bash bootstrap/workload-cluster-up.sh

seed:
	@bash scripts/seed.sh

lint:
	@bash scripts/lint.sh

repo-secret:
	@bash bootstrap/repo-secret.sh

teardown:
	@bash bootstrap/teardown.sh

clean: teardown
	@rm -rf .cache runs

status:
	@bash bootstrap/status.sh

scenario-%:
	@bash scripts/run.sh $*

assert-%:
	@bash scripts/assert.sh $*

prepare-%:
	@PREPARE_ONLY=1 bash scripts/run.sh $*
