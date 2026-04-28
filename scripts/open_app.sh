#!/bin/zsh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_PATH="${ROOT_DIR}/dist/番茄时钟.app"

if [[ ! -d "${APP_PATH}" ]]; then
    echo "Packaged app was not found at ${APP_PATH}. Building it now..."
    "${ROOT_DIR}/scripts/package_app.sh"
fi

open "${APP_PATH}"
