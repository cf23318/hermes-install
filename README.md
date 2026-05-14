# Hermes Agent 内部安装器

这个目录包含 macOS 和 Windows 原生版 Hermes Agent 安装器。目标是让同事通过尽量少的步骤完成安装：

1. macOS 下载 `site/downloads/HermesAgentInstaller.command`；Windows 下载 `site/downloads/HermesAgentInstaller.ps1`
2. macOS 双击 `HermesAgentInstaller.command`；Windows 在 PowerShell 中运行 `HermesAgentInstaller.ps1`
3. 输入自己的 DeepSeek API Key。为避免 Windows 终端隐藏输入时粘贴失败，安装器会明文显示 Key 输入内容，请确认周围无人观看
4. 按提示选择聊天工具；推荐使用飞书

安装器会做这些事：

- 检测系统代理和环境变量代理
- 将代理仅应用到当前安装进程，不永久修改 Git 全局配置
- 下载并执行 Hermes Agent 官方安装脚本：macOS 使用 `install.sh`，Windows 使用 `install.ps1`
- 跳过官方 `hermes setup` provider 选择向导，避免默认选到非 DeepSeek
- 接管 Camoufox 浏览器资源下载，显式开启 Node 的环境变量代理支持，并提供超时诊断
- 自动补装国内聊天工具依赖：飞书 `lark-oapi`、钉钉 `dingtalk-stream` / `alibabacloud-dingtalk`、企业微信/微信所需的 `aiohttp` / `cryptography` / `qrcode`
- 配置 `DEEPSEEK_API_KEY`
- 设置默认 provider 为 `deepseek`，默认模型为 `deepseek-v4-pro`，并固定 `model.base_url` 为 `https://api.deepseek.com/v1`
- 启动 `hermes gateway setup` 引导用户选择聊天工具，安装器会提示推荐飞书
- 安装并启动后台 Gateway 服务，让聊天工具消息能自动进入 Hermes
- 提供 Hermes/Gateway 状态与错误日志检查、软卸载、完全卸载、重新配置 Key、重新配置聊天工具、单独修复浏览器工具/聊天网关、关闭 Hermes/Gateway 功能

## 测试重装

双击安装器后选择：

```text
8) 卸载 Hermes（用于测试重装）
```

建议先用“软卸载”，它会删除 Hermes 程序和安装目录，但尽量保留 `~/.hermes/.env`。如果要模拟新用户环境，再选择“完全卸载”，它会删除整个 `~/.hermes`，包括 Key、聊天工具配置、日志和会话。

## 日志

macOS 安装日志会写到：

```text
~/Library/Logs/hermes-agent-installer/
```

排查用户安装失败时，优先让用户提供最新的 `install-*.log`。

Windows 安装日志会写到：

```text
%LOCALAPPDATA%\hermes\installer-logs\
```

## 打包

仓库维护时只需要运行打包脚本：

```bash
./scripts/package.sh
```

它会重新生成 macOS 和 Windows 两个直接下载文件，并保留 zip 备用产物。生成结果会放在 `site/downloads/`，由 GitHub Pages 直接分发。

## 内部复制页

`password.html` 是本地内部使用的“复制信息”页面，用来替代旧的 `password.txt`。需要更新 DeepSeek Key，或更新非扫码/手动凭据方式使用的飞书 App ID、App Secret 时，直接修改这个 HTML 页面。

真实的 `password.html` 已被 `.gitignore` 排除，不能提交到公开仓库。公开仓库只保留 `examples/password.example.html` 作为占位示例。

## 注意事项

- DeepSeek 的真实模型 ID 需要和 Hermes 当前版本保持一致。脚本默认使用 `deepseek-v4-pro`，普通安装向导不再要求用户手动填写模型名；内部测试需要覆盖时，可在运行前设置 `HERMES_DEFAULT_DEEPSEEK_MODEL`。
- 聊天工具配置不是纯静默安装，官方流程需要 `hermes gateway setup` 扫码、OAuth 或输入平台密钥。
- 推荐选择飞书。飞书默认走扫码/向导流程，通常不需要手动准备 App ID / App Secret；只有选择非扫码/手动凭据方式时才需要从 `https://open.feishu.cn/app?lang=zh-CN` 获取。
- 如果安装器检测到残留的飞书配置不完整或疑似无效，可以选择删除 `.env` 里的 `FEISHU_*` 配置，继续使用其他聊天工具。
- 飞书配置完成后，官方向导会回到“选择聊天工具”的列表；看到 `Done` 是默认项时直接按回车结束即可。
- Windows 终端里粘贴 Key/Secret 推荐使用右键粘贴或 `Ctrl+Shift+V`；如果隐藏输入写入了控制字符，安装器会提示重新明文输入。
- 安装器不强制写入飞书配置；用户可以选择 Hermes 支持的其他聊天工具。
- Windows 版本是原生 PowerShell 安装器，不使用 WSL2。

Windows 推荐启动方式：

```powershell
cd "$env:USERPROFILE\Downloads"
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
.\HermesAgentInstaller.ps1
```
