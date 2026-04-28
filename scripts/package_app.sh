#!/bin/zsh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PRODUCT_NAME="NTPClock"
APP_NAME="番茄时钟.app"
APP_DIR="${ROOT_DIR}/dist/${APP_NAME}"
CONTENTS_DIR="${APP_DIR}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"
INFO_PLIST_SOURCE="${ROOT_DIR}/App/Info.plist"

cd "${ROOT_DIR}"

swift build -c release

BINARY_PATH="$(find "${ROOT_DIR}/.build" -type f -path "*/release/${PRODUCT_NAME}" | head -n 1)"

if [[ -z "${BINARY_PATH}" ]]; then
    echo "Release binary for ${PRODUCT_NAME} was not found." >&2
    exit 1
fi

rm -rf "${APP_DIR}"
mkdir -p "${MACOS_DIR}" "${RESOURCES_DIR}"

cp "${INFO_PLIST_SOURCE}" "${CONTENTS_DIR}/Info.plist"
cp "${BINARY_PATH}" "${MACOS_DIR}/${PRODUCT_NAME}"
chmod +x "${MACOS_DIR}/${PRODUCT_NAME}"

echo "Packaged app bundle at ${APP_DIR}"