#!/bin/sh
# Sourced by the release launcher. Embedded mode eagerly executes optional
# erlcass NIF initialization even when the Scylla subsystem is disabled.
# Load modules on demand so PostgreSQL can run without that native driver.
CODE_LOADING_MODE=interactive
