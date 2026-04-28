#!/bin/zsh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_PATH="${ROOT_DIR}/dist/番茄时钟.app"
ARCHIVE_PATH="${ROOT_DIR}/dist/番茄时钟-macOS.zip"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"

"${ROOT_DIR}/scripts/package_app.sh"

if [[ "${SIGN_IDENTITY}" == "-" ]]; then
    echo "Using ad-hoc signing for local distribution."
    codesign --force --deep --sign - "${APP_PATH}"
else
    echo "Signing with identity: ${SIGN_IDENTITY}"
    codesign --force --deep --options runtime --timestamp --sign "${SIGN_IDENTITY}" "${APP_PATH}"
fi

codesign --verify --deep --strict --verbose=2 "${APP_PATH}"

rm -f "${ARCHIVE_PATH}"
ditto -c -k --sequesterRsrc --keepParent "${APP_PATH}" "${ARCHIVE_PATH}"

echo "Archive created at ${ARCHIVE_PATH}"
