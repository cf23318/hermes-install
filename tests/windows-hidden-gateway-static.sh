#!/usr/bin/env bash

set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

check_installer() {
  local path="$1"
  local file="${ROOT_DIR}/${path}"
  [[ -f "${file}" ]] || {
    echo "missing installer: ${path}" >&2
    exit 1
  }

  grep -q "function Backup-GatewayServiceArtifacts" "${file}" || {
    echo "missing gateway backup function: ${path}" >&2
    exit 1
  }
  grep -q "function Install-HiddenGatewayTask" "${file}" || {
    echo "missing hidden gateway task function: ${path}" >&2
    exit 1
  }
  grep -q "pythonw.exe" "${file}" || {
    echo "hidden gateway task should use pythonw.exe: ${path}" >&2
    exit 1
  }
  grep -q "Hermes_Gateway_hidden.pyw" "${file}" || {
    echo "missing hidden gateway wrapper script: ${path}" >&2
    exit 1
  }
  grep -q "gateway.hidden.log" "${file}" || {
    echo "hidden gateway stdout should go to a log file: ${path}" >&2
    exit 1
  }
  grep -q "gateway.hidden.error.log" "${file}" || {
    echo "hidden gateway stderr should go to a log file: ${path}" >&2
    exit 1
  }
  grep -q "CREATE_NO_WINDOW" "${file}" || {
    echo "hidden gateway wrapper should set CREATE_NO_WINDOW: ${path}" >&2
    exit 1
  }
  grep -q "DETACHED_PROCESS" "${file}" || {
    echo "hidden gateway wrapper should set DETACHED_PROCESS: ${path}" >&2
    exit 1
  }
  grep -q "proc.wait()" "${file}" || {
    echo "hidden gateway wrapper should keep the Scheduled Task running while Gateway runs: ${path}" >&2
    exit 1
  }
  grep -q "Register-ScheduledTask" "${file}" || {
    echo "hidden gateway task should register Scheduled Task: ${path}" >&2
    exit 1
  }
  grep -q "Start-ScheduledTask" "${file}" || {
    echo "hidden gateway task should start via Scheduled Task: ${path}" >&2
    exit 1
  }

  local start_gateway
  start_gateway="$(sed -n '/function Start-Gateway {/,/^}/p' "${file}")"
  grep -q "Install-HiddenGatewayTask" <<<"${start_gateway}" || {
    echo "Start-Gateway should install the hidden gateway task: ${path}" >&2
    exit 1
  }
  if grep -q '& \$hermes gateway install' <<<"${start_gateway}"; then
    echo "Start-Gateway should not call Hermes visible gateway install directly: ${path}" >&2
    exit 1
  fi
  if grep -q '& \$hermes gateway start' <<<"${start_gateway}"; then
    echo "Start-Gateway should not call Hermes visible gateway start directly: ${path}" >&2
    exit 1
  fi
}

check_installer "site/downloads/HermesAgentInstaller-windows-v2.ps1"

echo "windows hidden gateway v2 static check passed"
