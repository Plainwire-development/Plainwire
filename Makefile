# GNU Make 4.3+ (use gmake on FreeBSD). Help is intentionally the default.
SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c
.DEFAULT_GOAL := help
.DELETE_ON_ERROR:

NPM ?= npm
NODE ?= node
PYTHON ?= python3
REBAR3 ?= rebar3
PROFILE ?= default
NATIVE ?= 0
# GNU Make otherwise supplies the historical f77 default.
ifeq ($(origin FC),default)
FC := gfortran
endif
FC ?= gfortran
CC ?= cc
export FC CC

ifeq ($(filter $(PROFILE),default cluster),)
$(error PROFILE must be default or cluster)
endif
ifeq ($(filter $(NATIVE),0 1),)
$(error NATIVE must be 0 or 1)
endif
ifneq ($(filter clean,$(MAKECMDGOALS)),)
ifneq ($(words $(MAKECMDGOALS)),1)
$(error Run clean separately from build targets)
endif
endif

VERSION := $(strip $(shell cat VERSION))
REBAR := $(REBAR3) $(if $(filter cluster,$(PROFILE)),as cluster)
RELEASE_ROOT := _build/$(PROFILE)/rel/plainwire_relay
FRONTEND_INPUTS := $(wildcard web/*.js scripts/build-*.mjs priv/static/*.scss priv/static/*.less priv/static/less-plugins/*.js priv/static/elm/src/*.elm) priv/static/index.haml priv/static/elm/elm.json scripts/build-haml.sh scripts/build-elm.sh VERSION Makefile
FRONTEND_OUTPUTS := priv/static/index.html priv/static/app.css priv/static/app.js priv/static/markdown.js priv/static/highlight-all.js
NATIVE_TARGET := $(if $(filter 1,$(NATIVE)),native)
NATIVE_TEST := $(if $(filter 1,$(NATIVE)),test-native)

.PHONY: help doctor deps frontend backend native build verify test-health test-browser test-native test-backend test check release source package run clean browsers
# Rebar invocations and test servers are sequenced even with make -j.
.NOTPARALLEL: check test test-browser test-backend

help:
	@printf '%s\n' \
	  'Plainwire $(VERSION)' \
	  '  make doctor            Check local build prerequisites' \
	  '  make build             Build frontend and backend' \
	  '  make build NATIVE=1    Also compile the Fortran call-health worker' \
	  '  make native            Build only the native worker' \
	  '  make browsers          Explicitly install test Chromium' \
	  '  make check NATIVE=1    Syntax, browser, RTP, numerical and EUnit checks' \
	  '  make release NATIVE=1  Check and assemble an Erlang runtime release' \
	  '  make package NATIVE=1  Check, release, and archive with SHA-256' \
	  '  make source           Build frontend and archive portable source only' \
	  '  make run              Start the development server (requires PostgreSQL)' \
	  '  make clean            Remove build/test output; preserve data and secrets' \
	  'Options: PROFILE=default|cluster NATIVE=0|1 CC=cc FC=gfortran' \
	  'Clustering is optional; see docs/CLUSTERING.md before enabling it.'

doctor:
	@missing=0; for tool in "$(NODE)" "$(NPM)" "$(PYTHON)" erl "$(REBAR3)" $(if $(filter 1,$(NATIVE)),"$(CC)" "$(FC)"); do \
	  if command -v "$$tool" >/dev/null; then printf 'Found: %s\n' "$$tool"; else printf 'Missing: %s\n' "$$tool"; missing=1; fi; done; \
	  printf 'Tests also need Chromium; make browsers installs it. Production needs PostgreSQL and HTTPS.\n'; exit $$missing

node_modules/.plainwire-deps: package.json package-lock.json
	$(NPM) ci
	@touch $@

deps: node_modules/.plainwire-deps

# Grouped outputs prevent overlapping builds under -j and rebuild if any
# generated file is removed. Changing a source or lockfile invalidates them.
$(FRONTEND_OUTPUTS) &: $(FRONTEND_INPUTS) node_modules/.plainwire-deps
	$(NPM) run build
	@touch $(FRONTEND_OUTPUTS)

frontend: $(FRONTEND_OUTPUTS)

backend:
	$(REBAR) compile

priv/bin/pw-media-quality: native/media_quality/worker.c native/media_quality/quality.f90 scripts/build-media-quality.sh
	./scripts/build-media-quality.sh

native: priv/bin/pw-media-quality
build: frontend backend $(NATIVE_TARGET)

verify:
	./scripts/verify-source.sh

test-health:
	$(NODE) test/browser/call-health.mjs

test-browser: frontend
	$(NPM) run test:browser
	$(NPM) run test:rtc

test-native: native
	$(PYTHON) test/native_quality.py

test-backend: backend $(NATIVE_TARGET)
	PLAINWIRE_TEST_NATIVE=$(NATIVE) $(REBAR) eunit

test: test-health test-browser $(NATIVE_TEST) test-backend
check: verify frontend test

release: check
	$(REBAR) release
	@test -x "$(RELEASE_ROOT)/bin/plainwire_relay"
ifeq ($(NATIVE),0)
	@rm -f "$(RELEASE_ROOT)/lib/plainwire_relay-$(VERSION)/priv/bin/pw-media-quality"
else
	@test -x "$(RELEASE_ROOT)/lib/plainwire_relay-$(VERSION)/priv/bin/pw-media-quality"
endif
	@printf 'Checked release: %s\n' "$(RELEASE_ROOT)"

# A source archive is not proof that the full release build passed.
source: verify frontend
	$(PYTHON) scripts/archive.py source

package: release source
	$(PYTHON) scripts/archive.py release --profile "$(PROFILE)"

browsers: deps
	./node_modules/.bin/playwright install chromium

run: build
	./scripts/start.sh

clean:
	rm -rf -- _build test-results priv/static/elm/elm-stuff
	rm -f -- priv/bin/pw-media-quality
