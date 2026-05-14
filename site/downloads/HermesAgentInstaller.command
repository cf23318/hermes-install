#!/usr/bin/env bash

set -Eeuo pipefail

INSTALL_URL="${HERMES_INSTALL_URL:-https://raw.githubusercontent.com/NousResearch/hermes-agent/main/scripts/install.sh}"
DEFAULT_DEEPSEEK_MODEL="${HERMES_DEFAULT_DEEPSEEK_MODEL:-deepseek-v4-pro}"
FEISHU_APP_CONSOLE_URL="https://open.feishu.cn/app?lang=zh-CN"
LOG_DIR="${HOME}/Library/Logs/hermes-agent-installer"
LOG_FILE="${LOG_DIR}/install-$(date +%Y%m%d-%H%M%S).log"
HERMES_HOME="${HOME}/.hermes"

mkdir -p "${LOG_DIR}"
touch "${LOG_FILE}"

export PATH="${HOME}/.local/bin:${HOME}/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

exec > >(tee -a "${LOG_FILE}") 2>&1

print_title() {
  printf "\n============================================================\n"
  printf "%s\n" "$1"
  printf "============================================================\n"
}

info() {
  printf "[INFO] %s\n" "$1"
}

warn() {
  printf "[WARN] %s\n" "$1"
}

fail() {
  printf "[ERROR] %s\n" "$1"
  printf "日志位置: %s\n" "${LOG_FILE}"
  read -r -p "按回车退出..." _
  exit 1
}

pause() {
  printf "\n日志位置: %s\n" "${LOG_FILE}"
  read -r -p "按回车继续..." _
}

need_macos() {
  if [[ "$(uname -s)" != "Darwin" ]]; then
    fail "这个安装器只支持 macOS。Windows 版本后续单独做。"
  fi
}

mask_secret() {
  sed -E 's#(https?://)[^/@]+@#\1***:***@#g; s#(socks5h?://)[^/@]+@#\1***:***@#g'
}

current_proxy_from_env() {
  local proxy="${https_proxy:-${HTTPS_PROXY:-${http_proxy:-${HTTP_PROXY:-${all_proxy:-${ALL_PROXY:-}}}}}}"
  printf "%s" "${proxy}"
}

proxy_from_scutil() {
  local output http_enabled http_host http_port https_enabled https_host https_port socks_enabled socks_host socks_port
  output="$(scutil --proxy 2>/dev/null || true)"

  http_enabled="$(printf "%s\n" "${output}" | awk '/HTTPEnable/ {print $3; exit}')"
  http_host="$(printf "%s\n" "${output}" | awk '/HTTPProxy/ {print $3; exit}')"
  http_port="$(printf "%s\n" "${output}" | awk '/HTTPPort/ {print $3; exit}')"

  https_enabled="$(printf "%s\n" "${output}" | awk '/HTTPSEnable/ {print $3; exit}')"
  https_host="$(printf "%s\n" "${output}" | awk '/HTTPSProxy/ {print $3; exit}')"
  https_port="$(printf "%s\n" "${output}" | awk '/HTTPSPort/ {print $3; exit}')"

  socks_enabled="$(printf "%s\n" "${output}" | awk '/SOCKSEnable/ {print $3; exit}')"
  socks_host="$(printf "%s\n" "${output}" | awk '/SOCKSProxy/ {print $3; exit}')"
  socks_port="$(printf "%s\n" "${output}" | awk '/SOCKSPort/ {print $3; exit}')"

  if [[ "${https_enabled}" == "1" && -n "${https_host}" && -n "${https_port}" ]]; then
    printf "http://%s:%s" "${https_host}" "${https_port}"
  elif [[ "${http_enabled}" == "1" && -n "${http_host}" && -n "${http_port}" ]]; then
    printf "http://%s:%s" "${http_host}" "${http_port}"
  elif [[ "${socks_enabled}" == "1" && -n "${socks_host}" && -n "${socks_port}" ]]; then
    printf "socks5h://%s:%s" "${socks_host}" "${socks_port}"
  fi
}

configure_proxy() {
  print_title "代理检测"

  local detected
  detected="$(current_proxy_from_env)"
  if [[ -z "${detected}" ]]; then
    detected="$(proxy_from_scutil)"
  fi

  if [[ -n "${detected}" ]]; then
    info "检测到代理: $(printf "%s" "${detected}" | mask_secret)"
    read -r -p "是否使用这个代理完成安装？[Y/n/m 手动输入] " answer
    answer="${answer:-Y}"
    case "${answer}" in
      y|Y|yes|YES)
        export_proxy "${detected}"
        ;;
      m|M)
        read -r -p "请输入代理地址，例如 http://127.0.0.1:7890 或 socks5h://127.0.0.1:1080: " manual_proxy
        [[ -n "${manual_proxy}" ]] && export_proxy "${manual_proxy}"
        ;;
      *)
        warn "本次安装不使用代理。"
        ;;
    esac
  else
    warn "没有检测到系统代理或环境变量代理。"
    read -r -p "如果国内网络无法访问 GitHub，请输入代理地址；直接回车跳过: " manual_proxy
    [[ -n "${manual_proxy}" ]] && export_proxy "${manual_proxy}"
  fi
}

export_proxy() {
  local proxy="$1"
  export http_proxy="${proxy}"
  export https_proxy="${proxy}"
  export HTTP_PROXY="${proxy}"
  export HTTPS_PROXY="${proxy}"
  export all_proxy="${proxy}"
  export ALL_PROXY="${proxy}"
  export NO_PROXY="${NO_PROXY:-localhost,127.0.0.1,::1}"
  export no_proxy="${no_proxy:-${NO_PROXY}}"

  # Common tools used by install scripts respect env vars, but these make npm explicit.
  export npm_config_proxy="${proxy}"
  export npm_config_https_proxy="${proxy}"
  export npm_config_noproxy="${NO_PROXY}"
  export NODE_USE_ENV_PROXY=1
  export GIT_TERMINAL_PROMPT=0

  info "代理已仅对当前安装进程生效: $(printf "%s" "${proxy}" | mask_secret)"
}

find_hermes() {
  if command -v hermes >/dev/null 2>&1; then
    command -v hermes
  elif [[ -x "${HOME}/.local/bin/hermes" ]]; then
    printf "%s" "${HOME}/.local/bin/hermes"
  else
    return 1
  fi
}

stop_hermes_processes() {
  print_title "停止旧 Hermes 进程"

  local hermes_bin pid cmd self_pid parent_pid
  hermes_bin="$(find_hermes || true)"
  if [[ -n "${hermes_bin}" ]]; then
    info "尝试停止 Hermes Gateway。"
    "${hermes_bin}" gateway stop >/dev/null 2>&1 || true
  fi

  self_pid="$$"
  parent_pid="${PPID:-}"

  while IFS= read -r line; do
    pid="${line%% *}"
    [[ -n "${pid}" ]] || continue
    [[ "${pid}" == "${self_pid}" || "${pid}" == "${parent_pid}" ]] && continue

    cmd="${line#* }"
    [[ -n "${cmd}" ]] || continue

    if [[ "${cmd}" == *"${HERMES_HOME}"* ]]; then
      warn "停止占用 Hermes 目录的进程: PID=${pid} ${cmd}"
      kill "${pid}" 2>/dev/null || true
    fi
  done < <(ps -axo pid=,command= 2>/dev/null || true)

  sleep 2

  while IFS= read -r line; do
    pid="${line%% *}"
    [[ -n "${pid}" ]] || continue
    [[ "${pid}" == "${self_pid}" || "${pid}" == "${parent_pid}" ]] && continue

    cmd="${line#* }"
    [[ -n "${cmd}" ]] || continue

    if [[ "${cmd}" == *"${HERMES_HOME}"* ]]; then
      warn "进程仍未退出，强制停止: PID=${pid} ${cmd}"
      kill -9 "${pid}" 2>/dev/null || true
    fi
  done < <(ps -axo pid=,command= 2>/dev/null || true)
}

stop_hermes_menu() {
  stop_hermes_processes
  info "Hermes/Gateway 已尝试关闭。"
}

env_file_value_exists() {
  local key="$1"
  [[ -f "${HERMES_HOME}/.env" ]] && awk -F= -v k="${key}" '$1 == k && length($2) > 0 { found=1 } END { exit found ? 0 : 1 }' "${HERMES_HOME}/.env"
}

env_file_value() {
  local key="$1"
  [[ -f "${HERMES_HOME}/.env" ]] || return 0
  awk -F= -v k="${key}" '$1 == k { sub(/^[^=]*=/, ""); print; exit }' "${HERMES_HOME}/.env"
}

secret_looks_invalid() {
  local value="$1"
  [[ -n "${value}" ]] || return 0
  (( ${#value} >= 8 )) || return 0
  if printf "%s" "${value}" | LC_ALL=C grep -q '[[:cntrl:]]'; then
    return 0
  fi
  return 1
}

assert_secret_valid() {
  local key="$1"
  local value="$2"
  if secret_looks_invalid "${value}"; then
    fail "${key} 看起来不是有效值。常见原因是终端粘贴没有成功，而是写入了控制字符。请重新输入，或直接编辑 ~/.hermes/.env。"
  fi
}

download_and_run_official_installer() {
  print_title "安装 Hermes Agent"

  local tmp_script
  tmp_script="$(mktemp -t hermes-install.XXXXXX.sh)"
  if find_hermes >/dev/null 2>&1 || [[ -d "${HERMES_HOME}/hermes-agent" ]]; then
    info "检测到已有 Hermes，将在原目录就地修复/更新，不会创建第二份安装。"
    info "已有 ~/.hermes/.env 和 config.yaml 会尽量保留；后续步骤只会按需更新 DeepSeek/聊天工具配置。"
  fi
  info "下载安装脚本: ${INSTALL_URL}"

  if ! curl -fL --connect-timeout 20 --retry 3 --retry-delay 2 "${INSTALL_URL}" -o "${tmp_script}"; then
    rm -f "${tmp_script}"
    fail "下载安装脚本失败。请检查代理或网络。"
  fi

  chmod 700 "${tmp_script}"
  info "开始执行官方安装脚本。"
  info "跳过官方 hermes setup 向导，后续由本安装器默认配置 DeepSeek，避免用户误选其他 provider。"
  info "npm postinstall 下载浏览器资源容易卡住，先关闭自动 postinstall，后面由本安装器接管 Camoufox 下载。"
  npm_config_ignore_scripts=true bash "${tmp_script}" --skip-setup
  rm -f "${tmp_script}"

  if ! find_hermes >/dev/null 2>&1; then
    fail "安装脚本执行完成，但没有找到 hermes 命令。"
  fi

  info "Hermes 安装完成: $(find_hermes)"
}

run_with_watchdog() {
  local timeout_seconds="$1"
  local label="$2"
  shift 2

  "$@" &
  local child_pid=$!
  local elapsed=0
  local interval=15

  while kill -0 "${child_pid}" 2>/dev/null; do
    sleep "${interval}"
    elapsed=$((elapsed + interval))
    info "${label} 仍在进行，已等待 ${elapsed}s。"
    if (( elapsed >= timeout_seconds )); then
      warn "${label} 超过 ${timeout_seconds}s，准备停止。"
      kill "${child_pid}" 2>/dev/null || true
      sleep 2
      kill -9 "${child_pid}" 2>/dev/null || true
      wait "${child_pid}" 2>/dev/null || true
      return 124
    fi
  done

  wait "${child_pid}"
}

browser_tools_signature() {
  local agent_dir="$1"
  (
    cd "${agent_dir}"
    if [[ -f package-lock.json ]]; then
      cksum package-lock.json
    elif [[ -f package.json ]]; then
      cksum package.json
    else
      printf "no-package"
    fi
  )
}

npm_dependencies_current() {
  local agent_dir="$1"
  local marker="${HERMES_HOME}/.browser-tools-npm.cksum"
  [[ -d "${agent_dir}/node_modules" && -f "${marker}" ]] || return 1
  [[ "$(browser_tools_signature "${agent_dir}")" == "$(cat "${marker}" 2>/dev/null)" ]]
}

mark_npm_dependencies_current() {
  local agent_dir="$1"
  browser_tools_signature "${agent_dir}" > "${HERMES_HOME}/.browser-tools-npm.cksum"
}

camoufox_installed() {
  [[ -d "${HOME}/Library/Caches/camoufox/Camoufox.app" ]] || [[ -d "${HOME}/.cache/camoufox" ]]
}

install_browser_tools() {
  print_title "安装 Hermes 浏览器工具"

  local agent_dir="${HERMES_HOME}/hermes-agent"
  [[ -d "${agent_dir}" ]] || fail "未找到 Hermes 源码目录: ${agent_dir}"

  if ! command -v npm >/dev/null 2>&1; then
    fail "未找到 npm，不能安装 Hermes 浏览器工具。"
  fi

  (
    cd "${agent_dir}"
    export NODE_USE_ENV_PROXY=1
    export npm_config_ignore_scripts=false
    if npm_dependencies_current "${agent_dir}"; then
      info "Node 依赖已是当前版本，跳过 npm install。"
    else
      info "安装 Node 依赖（忽略 postinstall，避免 camoufox 自动下载卡死）。"
      npm install --ignore-scripts
      mark_npm_dependencies_current "${agent_dir}"
    fi

    if camoufox_installed; then
      info "检测到 Camoufox 浏览器资源已安装，跳过下载。"
    else
      info "开始通过代理下载 Camoufox 浏览器资源。这个文件通常较大，国内网络可能需要几分钟。"
      info "如果这里超过 15 分钟失败，请检查代理是否允许 GitHub release 大文件下载。"
      run_with_watchdog 900 "Camoufox 下载" npx camoufox-js fetch
    fi
  ) || fail "浏览器工具安装失败。Hermes 主程序可能已安装，但 Camoufox 浏览器资源没有完成。"

  info "Hermes 浏览器工具安装完成。"
}

install_feishu_dependencies() {
  print_title "安装国内聊天工具依赖"

  local agent_dir="${HERMES_HOME}/hermes-agent"
  local python_bin="${agent_dir}/venv/bin/python"
  local missing_packages=()
  [[ -x "${python_bin}" ]] || fail "未找到 Hermes Python venv: ${python_bin}"

  if ! "${python_bin}" - <<'PY' >/dev/null 2>&1
import importlib.util
raise SystemExit(0 if importlib.util.find_spec("lark_oapi") else 1)
PY
  then
    missing_packages+=("lark-oapi>=1.5.3")
  fi

  if ! "${python_bin}" - <<'PY' >/dev/null 2>&1
import importlib.util
raise SystemExit(0 if importlib.util.find_spec("dingtalk_stream") else 1)
PY
  then
    missing_packages+=("dingtalk-stream>=0.24.3")
  fi

  if ! "${python_bin}" - <<'PY' >/dev/null 2>&1
import importlib.util
raise SystemExit(0 if importlib.util.find_spec("alibabacloud_dingtalk") else 1)
PY
  then
    missing_packages+=("alibabacloud-dingtalk>=2.2.42")
  fi

  if ! "${python_bin}" - <<'PY' >/dev/null 2>&1
import importlib.util
raise SystemExit(0 if importlib.util.find_spec("aiohttp") else 1)
PY
  then
    missing_packages+=("aiohttp>=3.13.3")
  fi

  if ! "${python_bin}" - <<'PY' >/dev/null 2>&1
import importlib.util
raise SystemExit(0 if importlib.util.find_spec("cryptography") else 1)
PY
  then
    missing_packages+=("cryptography")
  fi

  if ! "${python_bin}" - <<'PY' >/dev/null 2>&1
import importlib.util
raise SystemExit(0 if importlib.util.find_spec("qrcode") else 1)
PY
  then
    missing_packages+=("qrcode>=7.4.2")
  fi

  if (( ${#missing_packages[@]} == 0 )); then
    info "飞书、钉钉、企业微信、微信所需依赖已安装。"
    return 0
  fi

  if ! command -v uv >/dev/null 2>&1; then
    fail "未找到 uv，不能自动安装聊天工具依赖。"
  fi

  info "安装缺失依赖: ${missing_packages[*]}"
  uv pip install --python "${python_bin}" "${missing_packages[@]}"
  info "国内聊天工具依赖安装完成。"
}

configure_deepseek() {
  print_title "配置 DeepSeek"

  local key model hermes_bin
  hermes_bin="$(find_hermes || true)"
  [[ -n "${hermes_bin}" ]] || fail "未找到 hermes，不能配置模型。"

  if env_file_value_exists "DEEPSEEK_API_KEY"; then
    read -r -p "检测到已有 DeepSeek API Key，是否保留？[Y/n] " keep_key
    keep_key="${keep_key:-Y}"
    if [[ "${keep_key}" =~ ^[Yy]$ ]]; then
      key=""
      info "保留已有 DeepSeek API Key。"
    else
      warn "为了避免隐藏输入时粘贴失败，下面的 Key 会明文显示。请确认周围无人观看。"
      read -r -p "请输入新的 DeepSeek API Key: " key
      assert_secret_valid "DEEPSEEK_API_KEY" "${key}"
    fi
  else
    warn "为了避免隐藏输入时粘贴失败，下面的 Key 会明文显示。请确认周围无人观看。"
    read -r -p "请输入你的 DeepSeek API Key: " key
    assert_secret_valid "DEEPSEEK_API_KEY" "${key}"
  fi

  read -r -p "DeepSeek 模型名 [${DEFAULT_DEEPSEEK_MODEL}]: " model
  model="${model:-${DEFAULT_DEEPSEEK_MODEL}}"

  mkdir -p "${HERMES_HOME}"
  chmod 700 "${HERMES_HOME}"

  if [[ -n "${key}" ]]; then
    if "${hermes_bin}" config set DEEPSEEK_API_KEY "${key}"; then
      info "DeepSeek API Key 已通过 hermes config 写入。"
    else
      warn "hermes config set 写 Key 失败，改为直接写入 ~/.hermes/.env。"
      upsert_env_value "${HERMES_HOME}/.env" "DEEPSEEK_API_KEY" "${key}"
    fi
  fi

  if "${hermes_bin}" config set model.provider "deepseek" \
    && "${hermes_bin}" config set model.default "${model}" \
    && "${hermes_bin}" config set model.base_url "https://api.deepseek.com/v1" \
    && "${hermes_bin}" config set model.api_key '${DEEPSEEK_API_KEY}'; then
    info "默认 provider 已设置为 deepseek，默认模型已设置为 ${model}，base_url 已设置为官方 DeepSeek endpoint。"
  else
    warn "hermes config set DeepSeek 模型配置失败，改为写入最小 config.yaml。"
    backup_file "${HERMES_HOME}/config.yaml"
    cat > "${HERMES_HOME}/config.yaml" <<EOF
model:
  provider: "deepseek"
  default: "${model}"
  base_url: "https://api.deepseek.com/v1"
  api_key: "\${DEEPSEEK_API_KEY}"
terminal:
  backend: local
group_sessions_per_user: true
EOF
  fi

  chmod 600 "${HERMES_HOME}/.env" 2>/dev/null || true
  info "DeepSeek 配置完成。"
}

upsert_env_value() {
  local file="$1"
  local key="$2"
  local value="$3"
  mkdir -p "$(dirname "${file}")"
  touch "${file}"
  chmod 600 "${file}" 2>/dev/null || true

  local escaped_value
  escaped_value="$(printf "%s" "${value}" | sed 's/[\/&]/\\&/g')"
  if grep -q "^${key}=" "${file}" 2>/dev/null; then
    sed -i.bak "s/^${key}=.*/${key}=${escaped_value}/" "${file}"
    rm -f "${file}.bak"
  else
    printf "%s=%s\n" "${key}" "${value}" >> "${file}"
  fi
}

backup_file() {
  local file="$1"
  if [[ -f "${file}" ]]; then
    cp "${file}" "${file}.bak.$(date +%Y%m%d-%H%M%S)"
    info "已备份: ${file}"
  fi
}

remove_env_prefix() {
  local prefix="$1"
  local file="${HERMES_HOME}/.env"
  local tmp_file
  [[ -f "${file}" ]] || return 0

  backup_file "${file}"
  tmp_file="$(mktemp "${HERMES_HOME}/.env.XXXXXX")"
  awk -v prefix="${prefix}" 'index($0, prefix) != 1 { print }' "${file}" > "${tmp_file}"
  chmod 600 "${tmp_file}" 2>/dev/null || true
  mv "${tmp_file}" "${file}"
}

env_file_has_key() {
  local key="$1"
  [[ -f "${HERMES_HOME}/.env" ]] && grep -q "^${key}=" "${HERMES_HOME}/.env"
}

feishu_fully_configured() {
  env_file_value_exists "FEISHU_APP_ID" && env_file_value_exists "FEISHU_APP_SECRET"
}

repair_feishu_secret_if_invalid() {
  if ! env_file_value_exists "FEISHU_APP_ID" && ! env_file_value_exists "FEISHU_APP_SECRET"; then
    return 0
  fi

  local app_id app_secret new_app_id new_secret
  app_id="$(env_file_value "FEISHU_APP_ID")"
  app_secret="$(env_file_value "FEISHU_APP_SECRET")"

  if ! secret_looks_invalid "${app_id}" && ! secret_looks_invalid "${app_secret}"; then
    return 0
  fi

  warn "检测到本机已有飞书配置，但 App ID/App Secret 不完整或疑似无效。"
  warn "如果你这次不使用飞书，可以删除这些 FEISHU_* 配置，避免后续误判。"
  printf "\n"
  printf "1) 继续使用飞书，手动填写 App ID/App Secret\n"
  printf "2) 不使用飞书，删除 FEISHU_* 配置\n"
  printf "3) 暂不处理\n"
  read -r -p "请选择 [1-3]: " choice

  case "${choice}" in
    1)
      info "只有选择非扫码/手动凭据方式时才需要 App ID 和 App Secret。"
      info "飞书开放平台: ${FEISHU_APP_CONSOLE_URL}"
      warn "下面改为明文输入，便于复制粘贴。请确认周围无人观看。"

      read -r -p "请输入飞书 App ID（通常以 cli_ 开头，直接回车保留现有值）: " new_app_id
      if [[ -n "${new_app_id}" ]]; then
        assert_secret_valid "FEISHU_APP_ID" "${new_app_id}"
        upsert_env_value "${HERMES_HOME}/.env" "FEISHU_APP_ID" "${new_app_id}"
      fi

      read -r -p "请输入飞书 App Secret（明文显示）: " new_secret
      assert_secret_valid "FEISHU_APP_SECRET" "${new_secret}"
      upsert_env_value "${HERMES_HOME}/.env" "FEISHU_APP_SECRET" "${new_secret}"
      ;;
    2)
      remove_env_prefix "FEISHU_"
      info "已删除 FEISHU_* 配置。"
      ;;
    *)
      warn "暂不处理飞书配置。如果后续不使用飞书，建议删除 .env 里的 FEISHU_* 项。"
      ;;
  esac
}

messaging_configured() {
  [[ -f "${HERMES_HOME}/.env" ]] || return 1
  awk -F= '
    $1 ~ /^(TELEGRAM_BOT_TOKEN|DISCORD_BOT_TOKEN|SLACK_BOT_TOKEN|SLACK_APP_TOKEN|MATRIX_HOMESERVER|MATTERMOST_URL|WHATSAPP_ENABLED|SIGNAL_PHONE_NUMBER|EMAIL_ADDRESS|TWILIO_ACCOUNT_SID|DINGTALK_CLIENT_ID|FEISHU_APP_ID|WECOM_BOT_ID|WECOM_CORP_ID|WEIXIN_TOKEN|BLUEBUBBLES_SERVER_URL|QQ_APP_ID|YUANBAO_TOKEN|GOOGLE_CHAT_SPACE|IRC_SERVER|LINE_CHANNEL_ACCESS_TOKEN|TEAMS_APP_ID)$/ && length($2) > 0 { found=1 }
    END { exit found ? 0 : 1 }
  ' "${HERMES_HOME}/.env"
}

configure_messaging() {
  print_title "聊天工具配置"

  local hermes_bin
  hermes_bin="$(find_hermes || true)"
  [[ -n "${hermes_bin}" ]] || fail "未找到 hermes，不能配置聊天工具。"

  mkdir -p "${HERMES_HOME}"

  if messaging_configured; then
    info "检测到已有聊天工具配置。"
    if feishu_fully_configured; then
      info "其中飞书 App ID 和 App Secret 已存在。"
    fi
    read -r -p "是否重新打开聊天工具配置向导？[y/N] " answer
    answer="${answer:-N}"
    if [[ ! "${answer}" =~ ^[Yy]$ ]]; then
      info "保留现有聊天工具配置，不重复配置。"
      repair_feishu_secret_if_invalid
      return 0
    fi
  fi

  info "接下来会启动 Hermes 官方聊天工具配置向导。"
  info "推荐选择 10. Feishu / Lark（飞书），适合国内团队；也可以按自己的需要选择 Telegram、Slack、企业微信等。"
  info "飞书默认走扫码/向导流程，通常不需要手动准备 App ID 和 App Secret；只有选择非扫码/手动凭据方式时才需要。"
  info "配置完成后，官方向导会回到聊天工具列表。看到 Done 为默认项时，直接按回车结束。"
  read -r -p "现在启动聊天工具配置向导？[Y/n] " answer
  answer="${answer:-Y}"
  if [[ "${answer}" =~ ^[Yy]$ ]]; then
    "${hermes_bin}" gateway setup || warn "聊天工具配置向导没有正常结束，可稍后从菜单重新执行。"
  else
    warn "已跳过聊天工具配置向导。稍后可运行本安装器选择“只配置聊天工具”。"
  fi

  repair_feishu_secret_if_invalid
}

ensure_gateway_service_started() {
  print_title "启动聊天网关"

  local hermes_bin
  hermes_bin="$(find_hermes || true)"
  [[ -n "${hermes_bin}" ]] || fail "未找到 hermes，不能启动 gateway。"

  info "安装或刷新 macOS 后台服务。"
  "${hermes_bin}" gateway install || warn "gateway install 没有正常完成，尝试直接 start。"

  info "启动或重启 Hermes Gateway。"
  "${hermes_bin}" gateway start || "${hermes_bin}" gateway restart || fail "Hermes Gateway 启动失败。"

  "${hermes_bin}" gateway status || true
  "${hermes_bin}" gateway list || true
}

run_checks() {
  print_title "环境检查"

  need_macos
  info "macOS: $(sw_vers -productVersion 2>/dev/null || true)"
  info "CPU: $(uname -m)"
  info "Shell: ${SHELL:-unknown}"
  info "PATH: ${PATH}"

  local proxy
  proxy="$(current_proxy_from_env)"
  [[ -n "${proxy}" ]] && info "当前环境代理: $(printf "%s" "${proxy}" | mask_secret)" || warn "当前环境没有代理变量。"

  if command -v curl >/dev/null 2>&1; then
    info "curl: $(command -v curl)"
    if curl -Is --connect-timeout 10 "${INSTALL_URL}" >/dev/null 2>&1; then
      info "安装脚本 URL 可访问。"
    else
      warn "安装脚本 URL 暂时不可访问，国内网络通常需要代理。"
    fi
  else
    warn "未找到 curl。"
  fi

  if command -v git >/dev/null 2>&1; then
    info "git: $(git --version)"
  else
    warn "未找到 git。官方安装脚本可能会安装或要求安装。"
  fi

  local hermes_bin
  hermes_bin="$(find_hermes || true)"
  if [[ -n "${hermes_bin}" ]]; then
    info "hermes: ${hermes_bin}"
    "${hermes_bin}" --version || true
    "${hermes_bin}" config check || true
  else
    warn "未找到 hermes。"
  fi

  if [[ -f "${HERMES_HOME}/.env" ]]; then
    grep -q '^DEEPSEEK_API_KEY=' "${HERMES_HOME}/.env" && info "已配置 DEEPSEEK_API_KEY。" || warn "未在 ~/.hermes/.env 找到 DEEPSEEK_API_KEY。"
    if feishu_fully_configured; then
      info "已配置飞书 App ID/App Secret。"
    elif grep -q '^FEISHU_CONNECTION_MODE=' "${HERMES_HOME}/.env"; then
      warn "检测到飞书连接模式，但还没检测到 FEISHU_APP_ID/FEISHU_APP_SECRET。"
    else
      info "未检测到飞书配置；如果选择了其他聊天工具，可忽略。"
    fi
  else
    warn "未找到 ~/.hermes/.env。"
  fi
}

run_hermes_health_command() {
  local label="$1"
  shift

  info "执行: ${label}"
  if "$@"; then
    return 0
  fi

  local code=$?
  warn "${label} 返回异常，退出码: ${code}"
  return "${code}"
}

show_hermes_processes() {
  print_title "Hermes/Gateway 进程检查"

  local found=0 line pid cmd
  while IFS= read -r line; do
    pid="${line%% *}"
    cmd="${line#* }"
    [[ -n "${pid}" && -n "${cmd}" ]] || continue
    if [[ "${cmd}" == *"${HERMES_HOME}"* || "${cmd}" == *"hermes gateway"* ]]; then
      info "运行中进程: PID=${pid} ${cmd}"
      found=1
    fi
  done < <(ps -axo pid=,command= 2>/dev/null || true)

  if [[ "${found}" == "0" ]]; then
    warn "未发现明显的 Hermes/Gateway 运行进程。"
  fi
}

collect_log_files() {
  local dir file count=0
  for dir in "${HERMES_HOME}/logs" "${LOG_DIR}"; do
    [[ -d "${dir}" ]] || continue
    while IFS= read -r file; do
      printf "%s\n" "${file}"
      count=$((count + 1))
      (( count >= 6 )) && return 0
    done < <(find "${dir}" -type f \( -name "*.log" -o -name "install-*" \) 2>/dev/null | sort -r)
  done
}

show_recent_log_files() {
  print_title "最近 Hermes 日志片段"

  local file found=0
  while IFS= read -r file; do
    [[ -f "${file}" ]] || continue
    found=1
    info "日志文件: ${file}"
    tail -n 80 "${file}" 2>/dev/null || true
  done < <(collect_log_files)

  if [[ "${found}" == "0" ]]; then
    warn "未找到 Hermes 日志文件。"
  fi
}

scan_recent_log_errors() {
  print_title "最近日志错误关键词"

  local file found_logs=0 found_errors=0
  while IFS= read -r file; do
    [[ -f "${file}" ]] || continue
    found_logs=1
    if grep -Ein "error|traceback|exception|invalid|unauthorized|denied|allowlist|app_id|app_secret|timeout|failed" "${file}" 2>/dev/null | tail -n 40; then
      found_errors=1
    fi
  done < <(collect_log_files)

  if [[ "${found_logs}" == "0" ]]; then
    warn "没有日志可扫描。"
  elif [[ "${found_errors}" == "0" ]]; then
    info "最近日志没有匹配到常见错误关键词。"
  else
    warn "上面列出了最近日志里的可疑错误关键词，请结合时间点排查。"
  fi
}

run_health_check() {
  print_title "Hermes/Gateway 状态检查"

  need_macos

  local hermes_bin
  hermes_bin="$(find_hermes || true)"
  if [[ -z "${hermes_bin}" ]]; then
    warn "未找到 hermes 命令，Hermes 可能尚未安装。"
    show_hermes_processes
    show_recent_log_files
    scan_recent_log_errors
    info "健康检查完成：未找到 hermes 命令。"
    return 0
  fi

  info "hermes: ${hermes_bin}"
  print_title "Hermes 自带状态命令"
  run_hermes_health_command "hermes --version" "${hermes_bin}" --version || true
  run_hermes_health_command "hermes status" "${hermes_bin}" status || true
  run_hermes_health_command "hermes config check" "${hermes_bin}" config check || true
  run_hermes_health_command "hermes gateway status" "${hermes_bin}" gateway status || true
  run_hermes_health_command "hermes gateway list" "${hermes_bin}" gateway list || true

  show_hermes_processes

  print_title "Hermes 自带日志命令"
  if ! run_with_watchdog 30 "hermes logs" "${hermes_bin}" logs; then
    warn "hermes logs 不可用或执行超时，改为读取本地日志文件。"
    show_recent_log_files
  fi

  scan_recent_log_errors
  info "健康检查完成。"
}

uninstall_hermes() {
  print_title "卸载 Hermes"

  warn "软卸载会删除 Hermes 程序/源码，尽量保留 ~/.hermes/.env。"
  warn "完全卸载会删除整个 ~/.hermes，包括 Key、聊天工具配置、日志和会话。"
  printf "\n"
  printf "1) 软卸载（用于测试重装，保留配置）\n"
  printf "2) 完全卸载（删除所有 Hermes 本地配置）\n"
  printf "3) 返回\n"
  read -r -p "请选择 [1-3]: " choice

  case "${choice}" in
    1)
      stop_hermes_processes
      rm -rf "${HERMES_HOME}/hermes-agent" "${HERMES_HOME}/repo" "${HERMES_HOME}/venv"
      rm -f "${HOME}/.local/bin/hermes" "${HOME}/.local/bin/ha"
      info "软卸载完成。"
      ;;
    2)
      read -r -p "确认删除 ${HERMES_HOME}？请输入 DELETE 确认: " confirm
      if [[ "${confirm}" == "DELETE" ]]; then
        stop_hermes_processes
        rm -rf "${HERMES_HOME}"
        rm -f "${HOME}/.local/bin/hermes" "${HOME}/.local/bin/ha"
        info "完全卸载完成。"
      else
        warn "未确认，已取消完全卸载。"
      fi
      ;;
    *)
      return 0
      ;;
  esac
}

install_or_repair() {
  need_macos
  configure_proxy
  stop_hermes_processes
  download_and_run_official_installer
  install_browser_tools
  install_feishu_dependencies
  configure_deepseek
  configure_messaging
  ensure_gateway_service_started
  run_checks

  print_title "完成"
  info "安装器已完成。"
  info "聊天测试: hermes chat"
  info "启动聊天网关: hermes gateway"
  info "日志位置: ${LOG_FILE}"
}

main_menu() {
  while true; do
    print_title "Hermes Agent macOS 安装器"
    printf "1) 安装/修复 Hermes，并配置 DeepSeek 与聊天工具（推荐飞书）\n"
    printf "2) 启动/重启 Hermes/Gateway\n"
    printf "3) 关闭 Hermes/Gateway\n"
    printf "4) 检查 Hermes/Gateway 状态与错误日志\n"
    printf "5) 只重新配置 DeepSeek Key/模型\n"
    printf "6) 只配置聊天工具（推荐飞书）\n"
    printf "7) 只安装/修复浏览器工具 Camoufox\n"
    printf "8) 卸载 Hermes（用于测试重装）\n"
    printf "0) 退出\n"
    read -r -p "请选择 [0-8]: " choice

    case "${choice}" in
      1) install_or_repair; pause ;;
      2) configure_proxy; stop_hermes_processes; install_feishu_dependencies; ensure_gateway_service_started; pause ;;
      3) stop_hermes_menu; pause ;;
      4) run_health_check; pause ;;
      5) configure_deepseek; pause ;;
      6) configure_proxy; install_feishu_dependencies; configure_messaging; ensure_gateway_service_started; pause ;;
      7) configure_proxy; install_browser_tools; pause ;;
      8) uninstall_hermes; pause ;;
      0) exit 0 ;;
      *) warn "无效选择。" ;;
    esac
  done
}

main_menu
