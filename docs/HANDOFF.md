# Hermes Agent 内部安装器交接文档

## 项目目标

这个项目用于在公司内部推广 Hermes Agent，目标用户约 100 人，设备包含 macOS 和 Windows，部分 Windows 设备不支持 WSL2，并且大多数用户在中国大陆网络环境下使用。

核心目标：

- 用户通过网页下载对应系统的安装器源文件。
- 尽量一键完成 Hermes Agent 安装、代理配置、DeepSeek 配置、聊天工具配置和 Gateway 启动。
- 用户主要只需要输入自己的 DeepSeek API Key，并按向导配置聊天工具。
- 默认模型使用 DeepSeek 官方 endpoint。
- 聊天工具推荐飞书，但不强制飞书，用户也可以选择 Hermes 支持的其他平台。
- 安装器要可重复运行，重复运行应表现为“修复/更新”，不能生成多份安装或破坏已有配置。

## 当前分发产物

网页下载入口位于：

```text
site/index.html
```

直接下载文件位于：

```text
site/downloads/HermesAgentInstaller.command
site/downloads/HermesAgentInstaller.ps1
```

备用 zip 也会生成，但当前网页主推直接源文件：

```text
site/downloads/HermesAgentInstaller-mac.zip
site/downloads/HermesAgentInstaller-windows.zip
```

打包命令：

```bash
./scripts/package.sh
```

`scripts/package.sh` 会：

- 复制 mac 安装器到 `site/downloads/HermesAgentInstaller.command`
- 复制 Windows 安装器到 `site/downloads/HermesAgentInstaller.ps1`
- 保留两个 zip 备用
- 强制 Windows `.ps1` 使用 UTF-8 BOM，避免 Windows PowerShell 5.1 乱码解析

## 用户使用方式

### macOS

1. 下载 `HermesAgentInstaller.command`
2. 双击运行
3. 如果 macOS 安全限制拦截，右键文件并选择“打开”
4. 选择菜单项执行安装/修复

注意：直接下载 `.command` 时，部分浏览器或服务器可能不保留可执行权限。如果双击打不开，可以执行：

```bash
chmod +x HermesAgentInstaller.command
```

### Windows

1. 下载 `HermesAgentInstaller.ps1`
2. 右击文件，选择“使用 PowerShell 运行”
3. 如果执行策略拦截，打开 PowerShell 后执行：

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
.\HermesAgentInstaller.ps1
```

不使用 WSL2，不依赖 CMD 启动器。

## 当前主菜单

macOS 和 Windows 菜单已尽量保持一致：

```text
1) 安装/修复 Hermes，并配置 DeepSeek 与聊天工具（推荐飞书）
2) 启动/重启 Hermes/Gateway
3) 关闭 Hermes/Gateway
4) 检查 Hermes/Gateway 状态与错误日志
5) 只重新配置 DeepSeek Key
6) 只配置聊天工具（推荐飞书）
7) 只安装/修复浏览器工具
8) 卸载 Hermes（用于测试重装）
0) 退出
```

`1)` 会先停止旧 Hermes/Gateway 进程，再执行安装/修复，最后启动 Gateway。

`2)` 会先停止旧进程，再安装/检查聊天工具依赖并启动新的 Gateway。

`3)` 用于关闭 Hermes/Gateway，并清理占用安装目录的残留进程。

`4)` 会优先调用 Hermes 自带命令检查状态：

```text
hermes --version
hermes status
hermes config check
hermes gateway status
hermes gateway list
hermes logs
```

如果 `hermes logs` 不可用或超时，会读取本地日志目录，并扫描 `ERROR`、`Traceback`、`invalid`、`unauthorized`、`allowlist`、`app_id`、`app_secret`、`timeout`、`failed` 等常见错误关键词。

## 安装目录和配置目录

### macOS

```text
~/.hermes
~/.hermes/hermes-agent
~/.local/bin/hermes
```

日志：

```text
~/Library/Logs/hermes-agent-installer/
```

### Windows

```text
%LOCALAPPDATA%\hermes
%LOCALAPPDATA%\hermes\hermes-agent
%LOCALAPPDATA%\hermes\.env
%LOCALAPPDATA%\hermes\config.yaml
```

日志：

```text
%LOCALAPPDATA%\hermes\installer-logs\
%LOCALAPPDATA%\hermes\logs\
```

## DeepSeek 配置

安装器会配置：

```yaml
model:
  provider: "deepseek"
  default: "deepseek-v4-pro"
  base_url: "https://api.deepseek.com/v1"
  api_key: "${DEEPSEEK_API_KEY}"
```

API Key 写入：

```text
DEEPSEEK_API_KEY=...
```

注意：

- 之前遇到过 DeepSeek 请求打到 OpenRouter endpoint 导致 401 的问题，所以必须显式设置 `model.base_url=https://api.deepseek.com/v1`。
- Key 输入已改成明文输入，避免 Windows 终端隐藏输入时 `Ctrl+V` 写入控制字符。
- 安装器会校验 Key 是否过短或包含控制字符。

## 聊天工具与依赖

推荐飞书，但不强制。Hermes 支持多个平台，国内重点关注：

- 飞书 / Lark
- 企业微信 / WeCom
- 钉钉 / DingTalk
- 微信 / Weixin
- QQ
- 元宝 / Yuanbao

当前安装器会补装国内聊天工具常用依赖：

```text
lark-oapi>=1.5.3
dingtalk-stream>=0.24.3
alibabacloud-dingtalk>=2.2.42
aiohttp>=3.13.3
cryptography
qrcode>=7.4.2
```

这些依赖只设置最低版本，不设置最高版本，让安装时尽量使用可用最新版。

## 飞书配置注意事项

飞书推荐走 Hermes 官方向导里的默认扫码流程，普通用户通常不需要提前打开飞书开放平台，也不需要手动准备 App ID / App Secret。

只有用户选择非扫码/手动凭据方式时，才需要从飞书开放平台获取：

```text
https://open.feishu.cn/app?lang=zh-CN
```

手动凭据配置项包括：

```text
FEISHU_APP_ID
FEISHU_APP_SECRET
FEISHU_DOMAIN=feishu
FEISHU_CONNECTION_MODE=websocket
```

常见错误：

```text
app_id or app_secret is invalid
```

原因通常是：

- 填错了 App ID / App Secret
- 把 Verification Token、Encrypt Key、Bot ID 当成 App Secret
- Windows 终端粘贴失败，把控制字符写入 `.env`

如果安装器检测到本机残留的 `FEISHU_*` 配置不完整或疑似无效，会让用户选择：

- 继续使用飞书，并手动填写 App ID / App Secret
- 不使用飞书，删除 `.env` 里的 `FEISHU_*` 配置
- 暂不处理

飞书开放平台链接只在选择“继续使用飞书，手动填写 App ID/App Secret”时展示，避免默认扫码用户误以为必须创建应用。

正确处理：

```powershell
notepad "$env:LOCALAPPDATA\hermes\.env"
```

确认：

```text
FEISHU_APP_ID=cli_xxx
FEISHU_APP_SECRET=真实AppSecret
FEISHU_DOMAIN=feishu
FEISHU_CONNECTION_MODE=websocket
```

测试阶段建议加：

```text
GATEWAY_ALLOW_ALL_USERS=true
FEISHU_ALLOW_ALL_USERS=true
```

否则可能出现：

```text
No user allowlists configured. All unauthorized users will be denied.
```

## 代理处理

安装器会检测系统代理或环境变量代理。

macOS：

- 优先读取环境变量
- 再用 `scutil --proxy` 读取系统 HTTP/HTTPS/SOCKS 代理

Windows：

- 优先读取环境变量
- 再用 `.NET SystemWebProxy` 检测系统代理

设置的环境变量包括：

```text
HTTP_PROXY
HTTPS_PROXY
http_proxy
https_proxy
ALL_PROXY
all_proxy
NO_PROXY
no_proxy
npm_config_proxy
npm_config_https_proxy
npm_config_noproxy
NODE_USE_ENV_PROXY=1
GIT_TERMINAL_PROMPT=0
```

代理只对当前安装进程生效，不永久修改 Git 全局配置。

代理日志会脱敏，避免带用户名密码的代理泄露。

## 浏览器工具处理

这是最大坑之一。

官方安装脚本在 Node/browser tools 阶段容易卡住，特别是在中国网络环境下。

### macOS

处理方式：

- 官方安装脚本运行时设置 `npm_config_ignore_scripts=true`
- 避免官方 postinstall 自动下载浏览器资源
- 安装器后续自己接管：

```bash
npm install --ignore-scripts
npx camoufox-js fetch
```

并加 15 分钟 watchdog。

跳过逻辑：

- 如果 `node_modules` 存在，且 `package-lock.json` / `package.json` 校验值和上次成功安装一致，则跳过 `npm install`
- 如果检测到 `~/Library/Caches/camoufox/Camoufox.app`，则跳过 Camoufox 下载

### Windows

官方 Windows 安装脚本也会在 browser tools 阶段跑：

```text
npm install
npx playwright install chromium
```

处理方式：

- 下载官方 `install.ps1` 后自动 patch，让官方脚本跳过 browser tools
- 安装器自己接管：

```powershell
npm install --ignore-scripts
npx playwright install chromium
```

并加 15 分钟超时。

跳过逻辑：

- 如果 `node_modules` 存在，且 `package-lock.json` / `package.json` 校验值和上次成功安装一致，则跳过 `npm install`
- 如果 `%LOCALAPPDATA%\ms-playwright` 下已有 Chromium，则跳过 Chromium 下载

## Windows PowerShell 编码坑

Windows PowerShell 5.1 会把 UTF-8 无 BOM 的 `.ps1` 当成系统 ANSI 编码读取，导致中文、特殊字符甚至官方脚本内容乱码，出现大量莫名其妙的语法错误。

处理方式：

- `scripts/package.sh` 强制 `installers/windows/HermesAgentInstaller.ps1` 和 `site/downloads/HermesAgentInstaller.ps1` 保存为 UTF-8 BOM
- 下载官方 `install.ps1` 后，立即转存为 UTF-8 BOM 再执行
- 下载 `uv` 安装脚本后，也转存为 UTF-8 BOM 再执行

## Windows uv 安装坑

官方脚本内部会用类似：

```powershell
irm https://astral.sh/uv/install.ps1 | iex
```

这在 PowerShell 5.1 里也可能遇到编码/解析问题。

处理方式：

- 安装器先自己下载 `uv` 安装脚本
- 转 UTF-8 BOM
- 再执行
- 如果仍检测不到 `uv`，直接停止，不让官方脚本继续走 `irm | iex`

## Windows Gateway 自启坑

Windows 上 `hermes gateway install` 会尝试创建 Scheduled Task。

很多公司电脑或普通用户环境会失败：

```text
schtasks /Create failed: 拒绝访问
```

这不代表 Hermes 安装失败，只代表开机自启失败。

安装器会继续尝试：

```text
hermes gateway start
hermes gateway restart
```

如果仍失败，会用普通后台进程启动：

```text
hermes gateway run --replace
```

用户看到：

```text
Gateway is running
Running manually, not as a system service
```

表示当前可用，但重启电脑后可能需要重新运行菜单 `2)` 启动/重启 Gateway。

## Gateway 调试流程

如果飞书/聊天工具没反应，优先前台运行 Gateway。

### Windows PowerShell

```powershell
Get-CimInstance Win32_Process |
  Where-Object { $_.CommandLine -like "*hermes-agent*" -or $_.CommandLine -like "*gateway*" } |
  Select-Object ProcessId, Name, CommandLine
```

杀掉残留 Gateway：

```powershell
Stop-Process -Id 进程ID -Force
```

前台启动：

```powershell
& "$env:LOCALAPPDATA\hermes\hermes-agent\venv\Scripts\hermes.exe" gateway run --replace
```

保持窗口打开，再去飞书发消息。

如果前台无日志：

- 飞书事件没有进来
- App ID/App Secret 可能错误
- 飞书机器人事件/权限/连接模式配置不对

如果看到用户被拒绝：

- 配置 allowlist
- 或测试阶段设置 `GATEWAY_ALLOW_ALL_USERS=true`

## 重复安装/修复逻辑

`1)` 可以重复运行。

不会创建第二份 Hermes，因为官方安装脚本固定安装目录：

macOS：

```text
~/.hermes/hermes-agent
```

Windows：

```text
%LOCALAPPDATA%\hermes\hermes-agent
```

重复运行会在同一目录就地修复/更新。

安装器会：

- 先停止旧 Hermes/Gateway 进程
- 保留 `.env` / `config.yaml`
- 重新执行官方安装脚本
- 按需跳过已安装的浏览器工具
- 按需跳过已有聊天依赖
- 检查/修复 DeepSeek 和聊天工具配置

## 卸载逻辑

菜单 `8)` 进入卸载。

软卸载：

- 删除程序/源码/venv/node/git 等安装文件
- 尽量保留 `.env` / `config.yaml`

完全卸载：

- 删除整个 Hermes home
- 删除 Key、聊天工具配置、日志、会话

Windows 会额外清理：

```text
%USERPROFILE%\.local\bin\hermes.exe
%USERPROFILE%\.local\bin\ha.exe
%USERPROFILE%\.local\bin\hermes.cmd
%USERPROFILE%\.local\bin\ha.cmd
```

## 文件结构

```text
README.md
docs/HANDOFF.md
installers/macos/HermesAgentInstaller.command
installers/windows/HermesAgentInstaller.ps1
scripts/package.sh
site/index.html
site/downloads/
examples/password.example.html
tests/smoke-mac-mocked.sh
```

`password.html` 是本地内部使用的“复制信息”页面，用来替代旧的 `password.txt`。如果里面的 Key、App ID 或 App Secret 发生变化，直接更新这个 HTML 页面，不再维护单独的 `password.txt`。

真实的 `password.html` 已被 `.gitignore` 排除，不能提交到公开仓库。公开仓库只保留 `examples/password.example.html` 作为占位示例。

`tests/smoke-mac-mocked.sh` 是本地测试脚本，不给最终用户。

## 验证命令

基础校验：

```bash
bash -n installers/macos/HermesAgentInstaller.command scripts/package.sh tests/smoke-mac-mocked.sh
bash tests/check-repo-layout.sh
bash tests/smoke-mac-mocked.sh
./scripts/package.sh
```

确认 Windows `.ps1` 是 UTF-8 BOM：

```bash
python3 - <<'PY'
from pathlib import Path
print(Path("site/downloads/HermesAgentInstaller.ps1").read_bytes().startswith(b"\xef\xbb\xbf"))
PY
```

确认 zip 内容：

```bash
unzip -l site/downloads/HermesAgentInstaller-mac.zip
unzip -l site/downloads/HermesAgentInstaller-windows.zip
```

## 维护建议

- Windows 相关变更后，一定要确认 `.ps1` 仍是 UTF-8 BOM。
- 不要重新引入 `.cmd` 作为主入口，目前只保留 PowerShell 单文件方案。
- 不要在 Windows 里使用隐藏输入收集 Key/Secret，用户粘贴容易写入控制字符。
- 不要让官方 browser tools 阶段直接执行，容易卡死或误判。
- 依赖补装只设最低版本，不限制最高版本，除非出现明确兼容问题。
- 数据库相关操作目前没有涉及；如果后续接入数据库，必须优先考虑性能，避免重查询或大批量操作压垮弱服务器。
