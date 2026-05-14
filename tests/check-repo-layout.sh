#!/usr/bin/env bash

set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

required_paths=(
  "README.md"
  "docs/HANDOFF.md"
  "examples/password.example.html"
  "installers/macos/HermesAgentInstaller.command"
  "installers/windows/HermesAgentInstaller.ps1"
  "scripts/package.sh"
  "site/index.html"
  "site/downloads/HermesAgentInstaller.command"
  "site/downloads/HermesAgentInstaller.ps1"
  "site/downloads/HermesAgentInstaller-mac.zip"
  "site/downloads/HermesAgentInstaller-windows.zip"
  ".github/workflows/pages.yml"
)

for path in "${required_paths[@]}"; do
  [[ -e "${ROOT_DIR}/${path}" ]] || {
    echo "missing required path: ${path}" >&2
    exit 1
  }
done

legacy_paths=(
  "HANDOFF.md"
  "mac"
  "windows"
  "web"
  "dist"
  "package.sh"
  "password.example.html"
)

for path in "${legacy_paths[@]}"; do
  [[ ! -e "${ROOT_DIR}/${path}" ]] || {
    echo "legacy path should not exist: ${path}" >&2
    exit 1
  }
done

grep -q 'href="downloads/HermesAgentInstaller.command"' "${ROOT_DIR}/site/index.html"
grep -q 'href="downloads/HermesAgentInstaller.ps1"' "${ROOT_DIR}/site/index.html"

git -C "${ROOT_DIR}" check-ignore -q password.html
git -C "${ROOT_DIR}" check-ignore -q password.txt
for installer in \
  "installers/macos/HermesAgentInstaller.command" \
  "installers/windows/HermesAgentInstaller.ps1" \
  "site/downloads/HermesAgentInstaller.command" \
  "site/downloads/HermesAgentInstaller.ps1"
do
  if grep -q "DeepSeek 模型名" "${ROOT_DIR}/${installer}"; then
    echo "DeepSeek model should use the default without prompting: ${installer}" >&2
    exit 1
  fi
done


echo "repo layout check passed"
