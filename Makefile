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
USERS ?= 1000
DURATION ?= 60
RATE ?= 0
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

.PHONY: help doctor deps frontend backend native build verify test-health test-rtc-contract test-ui-contract test-admin-contract test-integrations-contract test-storage-contract test-storage-tools test-v21-contract test-scalability-contract test-release-contract test-sdks test-browser test-native test-backend test check release source package run clean browsers load load-soak load-live load-live-selftest load-doctor load-gleam-check
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
	  '  make source           Compile frontend/backend and archive portable source only' \
	  '  make load USERS=10000 Stress realtime fanout with fake users (DURATION=60 RATE=auto)' \
	  '  make load-10000       Convenience alias for USERS=10000' \
	  '  make load-soak        Ten-minute sustained fake-user stress run' \
	  '  make load-live        Authenticated HTTP/WebSocket staging load test' \
	  '  make load-live-selftest Validate the live load generator on loopback' \
	  '  make load-doctor      Check host limits for USERS before a large run' \
	  '  make run              Start the development server (requires PostgreSQL)' \
	  '  make clean            Remove build/test output; preserve data and secrets' \
	  'Options: PROFILE=default|cluster NATIVE=0|1 CC=cc FC=gfortran' \
	  'Clustering is optional; see docs/CLUSTERING.md before enabling it.'

doctor:
	@missing=0; for tool in "$(NODE)" "$(NPM)" "$(PYTHON)" erl "$(REBAR3)" $(if $(filter 1,$(NATIVE)),"$(CC)" "$(FC)"); do \
	  if command -v "$$tool" >/dev/null; then printf 'Found: %s\n' "$$tool"; else printf 'Missing: %s\n' "$$tool"; missing=1; fi; done; \
	  if command -v erl >/dev/null 2>&1; then otp=$$(erl -noshell -eval 'io:format("~s",[erlang:system_info(otp_release)]),halt().' 2>/dev/null); major=$${otp%%.*}; \
	    if [ -n "$$major" ] && [ "$$major" -ge 27 ] 2>/dev/null; then printf 'Erlang/OTP: %s (supported)\n' "$$otp"; else printf 'Unsupported Erlang/OTP: %s (Plainwire requires OTP 27+)\n' "$$otp"; missing=1; fi; fi; \
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

test-rtc-contract:
	$(NPM) run test:rtc-contract

test-ui-contract:
	$(NPM) run test:ui-contract

test-admin-contract:
	$(NPM) run test:admin-contract

test-integrations-contract:
	$(NPM) run test:integrations-contract

test-storage-contract:
	$(NPM) run test:storage-contract

test-storage-tools:
	$(NPM) run test:storage-tools

test-v21-contract:
	$(NPM) run test:v21-contract

test-scalability-contract:
	$(NPM) run test:scalability-contract

test-sdks:
	./scripts/test-bot-sdks.sh

test-release-contract:
	$(NPM) run test:release-contract

test-browser: frontend test-rtc-contract test-ui-contract test-admin-contract test-integrations-contract test-storage-contract test-storage-tools test-v21-contract test-scalability-contract test-release-contract
	$(NPM) run test:browser
	$(NODE) test/browser/settings-responsive.mjs
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

# A source archive contains authoritative inputs only; generated UI bundles are rebuilt by `make build`.
# It is not proof that the host-specific release build passed.
source: verify frontend backend
	$(PYTHON) scripts/archive.py source

package: release source
	$(PYTHON) scripts/archive.py release --profile "$(PROFILE)"

browsers: deps
	./node_modules/.bin/playwright install chromium

run: build
	./scripts/start.sh

load: backend
	@[[ "$(USERS)" =~ ^[0-9]+$$ ]] && [ "$(USERS)" -ge 10 ] || { echo 'USERS must be an integer >= 10'; exit 2; }
	@[[ "$(DURATION)" =~ ^[0-9]+$$ ]] && [ "$(DURATION)" -ge 1 ] || { echo 'DURATION must be an integer >= 1 second'; exit 2; }
	@[[ "$(RATE)" =~ ^[0-9]+$$ ]] || { echo 'RATE must be a non-negative integer (0 = automatic)'; exit 2; }
	mkdir -p _build/load
	erlc -Werror -o _build/load tools/load/pw_load_sim.erl
	erl -noshell -pa _build/load _build/$(PROFILE)/lib/*/ebin -eval 'case pw_load_sim:run($(USERS), $(DURATION), $(RATE)) of {ok, _} -> halt(0); {error, _} -> halt(1) end.'

load-%:
	@$(MAKE) --no-print-directory load USERS=$* DURATION=$(DURATION) RATE=$(RATE) PROFILE=$(PROFILE)

load-soak:
	@$(MAKE) --no-print-directory load USERS=$(USERS) DURATION=600 RATE=$(RATE) PROFILE=$(PROFILE)

load-live:
	$(PYTHON) tools/load/live_load.py --users "$(USERS)" --duration "$(DURATION)" --rate "$(RATE)"

load-live-selftest:
	./scripts/test-live-load-harness.sh

load-doctor:
	./scripts/load-doctor.sh "$(USERS)"

load-gleam-check:
	@command -v gleam >/dev/null || { echo 'gleam is required for the typed load-model check'; exit 2; }
	cd tools/load/gleam && gleam check

clean:
	rm -rf -- _build test-results priv/static/elm/elm-stuff
	rm -f -- priv/bin/pw-media-quality
