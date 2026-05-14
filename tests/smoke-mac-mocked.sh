#!/usr/bin/env bash

set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

MOCK_HOME="${TMP_DIR}/home"
MOCK_BIN="${TMP_DIR}/bin"
MOCK_LOCAL_BIN="${MOCK_HOME}/.local/bin"
MOCK_INSTALLER="${TMP_DIR}/official-install.sh"
OUTPUT_FILE="${TMP_DIR}/output.log"

mkdir -p "${MOCK_HOME}" "${MOCK_BIN}" "${MOCK_LOCAL_BIN}"

cat > "${MOCK_BIN}/npm" <<'MOCK'
#!/usr/bin/env bash
echo "mock npm $*"
exit 0
MOCK

cat > "${MOCK_BIN}/npx" <<'MOCK'
#!/usr/bin/env bash
echo "mock npx $*"
exit 0
MOCK

cat > "${MOCK_INSTALLER}" <<'MOCK'
#!/usr/bin/env bash
set -Eeuo pipefail

mkdir -p "${HOME}/.local/bin" "${HOME}/.hermes/hermes-agent/venv/bin"

cat > "${HOME}/.hermes/hermes-agent/venv/bin/python" <<'PY'
#!/usr/bin/env bash
exit 0
PY
chmod +x "${HOME}/.hermes/hermes-agent/venv/bin/python"

cat > "${HOME}/.local/bin/hermes" <<'HERMES'
#!/usr/bin/env bash
set -Eeuo pipefail

mkdir -p "${HOME}/.hermes"

case "${1:-}" in
  --version)
    echo "Hermes Agent mock 0.0.0"
    exit 0
    ;;
  config)
    if [[ "${2:-}" == "check" ]]; then
      echo "mock config ok"
      exit 0
    fi
    if [[ "${2:-}" == "set" ]]; then
      if [[ "${3:-}" == "DEEPSEEK_API_KEY" ]]; then
        printf 'DEEPSEEK_API_KEY=%s\n' "${4:-}" > "${HOME}/.hermes/.env"
      else
        printf '%s=%s\n' "${3:-}" "${4:-}" >> "${HOME}/.hermes/config-set.log"
      fi
      echo "mock config set ${3:-}"
      exit 0
    fi
    ;;
  gateway)
    echo "mock gateway ${2:-}"
    exit 0
    ;;
  status)
    echo "mock hermes status ok"
    exit 0
    ;;
  logs)
    echo "mock logs ok"
    exit 0
    ;;
  chat)
    echo "mock chat"
    exit 0
    ;;
esac

echo "mock hermes $*"
exit 0
HERMES
chmod +x "${HOME}/.local/bin/hermes"
MOCK
chmod +x "${MOCK_INSTALLER}" "${MOCK_BIN}/npm" "${MOCK_BIN}/npx"
cp "${MOCK_BIN}/npm" "${MOCK_LOCAL_BIN}/npm"
cp "${MOCK_BIN}/npx" "${MOCK_LOCAL_BIN}/npx"
chmod +x "${MOCK_LOCAL_BIN}/npm" "${MOCK_LOCAL_BIN}/npx"

env -i \
  HOME="${MOCK_HOME}" \
  PATH="${MOCK_BIN}:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
  SHELL="/bin/zsh" \
  HERMES_INSTALL_URL="file://${MOCK_INSTALLER}" \
  HERMES_DEFAULT_DEEPSEEK_MODEL="deepseek-v4-pro" \
  bash "${ROOT_DIR}/installers/macos/HermesAgentInstaller.command" > "${OUTPUT_FILE}" 2>&1 <<'INPUT'
1

test-deepseek-key
n

0
INPUT

grep -q "安装器已完成" "${OUTPUT_FILE}"
grep -q "DeepSeek 配置完成" "${OUTPUT_FILE}"
if grep -q "DeepSeek 模型名" "${OUTPUT_FILE}"; then
  echo "installer should use the default DeepSeek model without prompting" >&2
  exit 1
fi
grep -q "mock gateway start" "${OUTPUT_FILE}"
grep -q "DEEPSEEK_API_KEY=test-deepseek-key" "${MOCK_HOME}/.hermes/.env"
grep -q "model.default=deepseek-v4-pro" "${MOCK_HOME}/.hermes/config-set.log"
grep -q "model.base_url=https://api.deepseek.com/v1" "${MOCK_HOME}/.hermes/config-set.log"

env -i \
  HOME="${MOCK_HOME}" \
  PATH="${MOCK_BIN}:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
  SHELL="/bin/zsh" \
  HERMES_INSTALL_URL="file://${MOCK_INSTALLER}" \
  HERMES_DEFAULT_DEEPSEEK_MODEL="deepseek-v4-pro" \
  bash "${ROOT_DIR}/installers/macos/HermesAgentInstaller.command" > "${OUTPUT_FILE}.health" 2>&1 <<'INPUT'
4

0
INPUT

grep -q "Hermes/Gateway 状态检查" "${OUTPUT_FILE}.health"
grep -q "Hermes 自带状态命令" "${OUTPUT_FILE}.health"
grep -q "mock hermes status ok" "${OUTPUT_FILE}.health"
grep -q "mock gateway status" "${OUTPUT_FILE}.health"
grep -q "mock gateway list" "${OUTPUT_FILE}.health"
grep -q "mock logs ok" "${OUTPUT_FILE}.health"
grep -q "健康检查完成" "${OUTPUT_FILE}.health"

cat >> "${MOCK_HOME}/.hermes/.env" <<'ENV'
FEISHU_APP_ID=bad
FEISHU_APP_SECRET=bad
FEISHU_DOMAIN=feishu
FEISHU_CONNECTION_MODE=websocket
ENV

env -i \
  HOME="${MOCK_HOME}" \
  PATH="${MOCK_BIN}:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
  SHELL="/bin/zsh" \
  HERMES_INSTALL_URL="file://${MOCK_INSTALLER}" \
  HERMES_DEFAULT_DEEPSEEK_MODEL="deepseek-v4-pro" \
  bash "${ROOT_DIR}/installers/macos/HermesAgentInstaller.command" > "${OUTPUT_FILE}.cleanup" 2>&1 <<'INPUT'
6

n
2

0
INPUT

grep -Fq "删除 FEISHU_* 配置" "${OUTPUT_FILE}.cleanup"
if grep -q '^FEISHU_' "${MOCK_HOME}/.hermes/.env"; then
  echo "FEISHU_* entries should have been removed" >&2
  exit 1
fi

echo "mac mocked full install smoke test passed"
