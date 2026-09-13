#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
exec "${MAKE:-make}" -C "$ROOT" release "NATIVE=${PLAINWIRE_BUILD_MEDIA_QUALITY:-0}" "PROFILE=${PLAINWIRE_BUILD_PROFILE:-default}"
