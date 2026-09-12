# Plainwire Relay - all build
#
# Builds every artifact:
#   frontend: haml -> priv/static/index.html, scss -> priv/static/app.css,
#             elm -> priv/static/app.js   (via npm)
#   backend:  rebar3 get-deps + rebar3 compile (Erlang/OTP)

SHELL := /bin/bash

.PHONY: all frontend backend test clean

NPM ?= npm

# --- Outputs -----------------------------------------------------------
HAML_OUT := priv/static/index.html
SCSS_OUT := priv/static/app.css
ELM_OUT  := priv/static/app.js

# scripts/build-elm.sh refuses elm binaries shipped through npm (the "elm"
# npm package currently bundles a nonstandard 0.19.2 build). The project is
# pinned to Elm 0.19.1 (priv/static/elm/elm.json), so fetch the official
# compiler release into _build/tools/ where the script accepts it as native.
ELM_NATIVE := _build/tools/elm
ELM_VERSION := 0.19.1

# The system rebar3 (3.19.0, /usr/bin) cannot boot on the OTP 29 that Homebrew
# puts first on PATH. Fall back to the system Erlang (OTP 25) when the default
# invocation fails, so rebar3 can run.
REBAR3_CMD := $(shell \
	if command -v rebar3 >/dev/null 2>&1 && rebar3 version >/dev/null 2>&1; then \
		echo 'rebar3'; \
	elif command -v /usr/bin/erl >/dev/null 2>&1 && PATH="/usr/bin:$$PATH" rebar3 version >/dev/null 2>&1; then \
		echo 'PATH=/usr/bin:$$PATH rebar3'; \
	else \
		echo 'rebar3'; \
	fi)

# --- Targets -----------------------------------------------------------
all: frontend backend
	@echo "Plainwire build complete."

frontend: $(HAML_OUT) $(SCSS_OUT) $(ELM_OUT)
	@echo "Frontend build complete."

backend:
	@$(REBAR3_CMD) get-deps
	@$(REBAR3_CMD) compile
	@echo "Backend build complete."

test:
	@$(REBAR3_CMD) eunit

clean:
	@rm -rf $(ELM_OUT) $(SCSS_OUT) $(HAML_OUT) $(ELM_NATIVE) elm-stuff priv/static/elm/elm-stuff
	@echo "Cleaned generated artifacts."

# --- Frontend rules ----------------------------------------------------
node_modules/.package-lock.json: package.json package-lock.json
	$(NPM) ci

$(HAML_OUT): priv/static/index.haml node_modules/.package-lock.json
	$(NPM) run build:haml

$(SCSS_OUT): priv/static/style.scss node_modules/.package-lock.json
	$(NPM) run build:scss

$(ELM_NATIVE):
	@mkdir -p $(@D)
	curl -fsSL "https://github.com/elm/compiler/releases/download/$(ELM_VERSION)/binary-for-linux-64-bit.gz" | gzip -d > $@.tmp
	chmod +x $@.tmp
	mv $@.tmp $@

$(ELM_OUT): priv/static/elm/src/Main.elm priv/static/elm/elm.json $(ELM_NATIVE)
	ELM_BIN="$(ELM_NATIVE)" $(NPM) run build:elm