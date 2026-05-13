#!/usr/bin/env bash

set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIST_DIR="${ROOT_DIR}/dist"

MAC_INSTALLER="${ROOT_DIR}/mac/HermesAgentInstaller.command"
WINDOWS_INSTALLER="${ROOT_DIR}/windows/HermesAgentInstaller.ps1"

mkdir -p "${DIST_DIR}"

package_mac() {
  local zip_path="${DIST_DIR}/HermesAgentInstaller-mac.zip"
  local direct_path="${DIST_DIR}/HermesAgentInstaller.command"
  [[ -f "${MAC_INSTALLER}" ]] || { echo "缺少: ${MAC_INSTALLER}" >&2; exit 1; }

  chmod +x "${MAC_INSTALLER}"
  cp "${MAC_INSTALLER}" "${direct_path}"
  chmod +x "${direct_path}"
  rm -f "${zip_path}"
  (
    cd "${ROOT_DIR}/mac"
    zip -q -r "${zip_path}" "HermesAgentInstaller.command"
  )
  echo "已生成: ${zip_path}"
  echo "已生成: ${direct_path}"
}

package_windows() {
  local zip_path="${DIST_DIR}/HermesAgentInstaller-windows.zip"
  local direct_path="${DIST_DIR}/HermesAgentInstaller.ps1"
  [[ -f "${WINDOWS_INSTALLER}" ]] || { echo "缺少: ${WINDOWS_INSTALLER}" >&2; exit 1; }

  python3 - "${WINDOWS_INSTALLER}" "${direct_path}" <<'PY'
from pathlib import Path
import sys

src = Path(sys.argv[1])
dst = Path(sys.argv[2])
text = src.read_text(encoding="utf-8-sig")
src.write_text(text, encoding="utf-8-sig")
dst.write_text(text, encoding="utf-8-sig")
PY
  rm -f "${zip_path}"
  (
    cd "${ROOT_DIR}/windows"
    zip -q -r "${zip_path}" "HermesAgentInstaller.ps1"
  )
  echo "已生成: ${zip_path}"
  echo "已生成: ${direct_path}"
}

case "${1:-all}" in
  mac)
    package_mac
    ;;
  windows)
    package_windows
    ;;
  all)
    package_mac
    package_windows
    ;;
  *)
    echo "用法: $0 [mac|windows|all]" >&2
    exit 1
    ;;
esac
