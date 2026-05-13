param()

$ErrorActionPreference = "Stop"

$InstallUrl = $env:HERMES_INSTALL_URL
if ([string]::IsNullOrWhiteSpace($InstallUrl)) {
    $InstallUrl = "https://raw.githubusercontent.com/NousResearch/hermes-agent/main/scripts/install.ps1"
}

$DefaultDeepSeekModel = $env:HERMES_DEFAULT_DEEPSEEK_MODEL
if ([string]::IsNullOrWhiteSpace($DefaultDeepSeekModel)) {
    $DefaultDeepSeekModel = "deepseek-v4-pro"
}

$FeishuAppConsoleUrl = "https://open.feishu.cn/app?lang=zh-CN"
$HermesHome = Join-Path $env:LOCALAPPDATA "hermes"
$InstallDir = Join-Path $HermesHome "hermes-agent"
$LogDir = Join-Path $HermesHome "installer-logs"
$LogFile = Join-Path $LogDir ("install-{0}.log" -f (Get-Date -Format "yyyyMMdd-HHmmss"))

New-Item -ItemType Directory -Force -Path $LogDir | Out-Null

Start-Transcript -Path $LogFile -Append | Out-Null

function Write-Title {
    param([string]$Text)
    Write-Host ""
    Write-Host "============================================================"
    Write-Host $Text
    Write-Host "============================================================"
}

function Write-Info {
    param([string]$Text)
    Write-Host "[INFO] $Text" -ForegroundColor Cyan
}

function Write-Warn2 {
    param([string]$Text)
    Write-Host "[WARN] $Text" -ForegroundColor Yellow
}

function Fail {
    param([string]$Text)
    Write-Host "[ERROR] $Text" -ForegroundColor Red
    Write-Host "日志位置: $LogFile"
    Read-Host "按回车退出"
    Stop-Transcript | Out-Null
    exit 1
}

function Pause-Installer {
    Write-Host ""
    Write-Host "日志位置: $LogFile"
    Read-Host "按回车继续"
}

function Get-Utf8NoBomEncoding {
    return New-Object -TypeName System.Text.UTF8Encoding -ArgumentList $false
}

function Get-Utf8BomEncoding {
    return New-Object -TypeName System.Text.UTF8Encoding -ArgumentList $true
}

function Convert-ScriptToUtf8Bom {
    param([string]$Path)

    $content = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
    [System.IO.File]::WriteAllText($Path, $content, (Get-Utf8BomEncoding))
}

function Patch-OfficialInstallerScript {
    param([string]$Path)

    $content = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
    $before = 'if (Test-Path "$InstallDir\package.json") {'
    $after = 'if ($false -and (Test-Path "$InstallDir\package.json")) {'

    if ($content.Contains($before)) {
        $content = $content.Replace($before, $after)
        [System.IO.File]::WriteAllText($Path, $content, (Get-Utf8BomEncoding))
        Write-Info "已让官方安装脚本跳过 browser tools，后续由本安装器接管，避免 npm/browser 下载卡死。"
    } else {
        Write-Warn2 "未找到官方 browser tools 片段；将继续执行官方脚本。"
    }
}

function Get-ConfiguredProxy {
    foreach ($name in @("HTTPS_PROXY", "https_proxy", "HTTP_PROXY", "http_proxy", "ALL_PROXY", "all_proxy")) {
        $value = [Environment]::GetEnvironmentVariable($name, "Process")
        if (-not [string]::IsNullOrWhiteSpace($value)) { return $value }
    }

    try {
        $proxy = [System.Net.WebRequest]::GetSystemWebProxy()
        $target = [Uri]"https://github.com/"
        $proxyUri = $proxy.GetProxy($target)
        if ($proxyUri -and $proxyUri.AbsoluteUri -ne $target.AbsoluteUri) {
            return $proxyUri.AbsoluteUri.TrimEnd("/")
        }
    } catch {}

    return ""
}

function Mask-Secret {
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return "" }
    $masked = $Text -replace '(https?://)[^/@]+@', '$1***:***@'
    $masked = $masked -replace '(socks5h?://)[^/@]+@', '$1***:***@'
    return $masked
}

function Set-InstallerProxy {
    param([string]$Proxy)

    if ([string]::IsNullOrWhiteSpace($Proxy)) { return }

    $env:HTTP_PROXY = $Proxy
    $env:HTTPS_PROXY = $Proxy
    $env:http_proxy = $Proxy
    $env:https_proxy = $Proxy
    $env:ALL_PROXY = $Proxy
    $env:all_proxy = $Proxy
    $env:NO_PROXY = "localhost,127.0.0.1,::1"
    $env:no_proxy = $env:NO_PROXY
    $env:npm_config_proxy = $Proxy
    $env:npm_config_https_proxy = $Proxy
    $env:npm_config_noproxy = $env:NO_PROXY
    $env:NODE_USE_ENV_PROXY = "1"
    $env:GIT_TERMINAL_PROMPT = "0"

    # .NET HTTP clients used by Invoke-WebRequest / Invoke-RestMethod.
    [System.Net.WebRequest]::DefaultWebProxy = New-Object System.Net.WebProxy($Proxy)
    [System.Net.WebRequest]::DefaultWebProxy.Credentials = [System.Net.CredentialCache]::DefaultNetworkCredentials

    Write-Info "代理已仅对当前安装进程生效: $(Mask-Secret $Proxy)"
}

function Configure-Proxy {
    Write-Title "代理检测"

    $detected = Get-ConfiguredProxy
    if ([string]::IsNullOrWhiteSpace($detected)) {
        Write-Warn2 "没有检测到系统代理或环境变量代理。"
        $manual = Read-Host "如果国内网络无法访问 GitHub，请输入代理地址；直接回车跳过"
        if (-not [string]::IsNullOrWhiteSpace($manual)) { Set-InstallerProxy $manual }
        return
    }

    Write-Info "检测到代理: $(Mask-Secret $detected)"
    $answer = Read-Host "是否使用这个代理完成安装？[Y/n/m 手动输入]"
    if ([string]::IsNullOrWhiteSpace($answer)) { $answer = "Y" }

    if ($answer -match "^[Yy]") {
        Set-InstallerProxy $detected
        return
    }

    if ($answer -match "^[Mm]") {
        $manual = Read-Host "请输入代理地址，例如 http://127.0.0.1:7890 或 socks5://127.0.0.1:1080"
        if (-not [string]::IsNullOrWhiteSpace($manual)) { Set-InstallerProxy $manual }
        return
    }

    Write-Warn2 "本次安装不使用代理。"
}

function Get-HermesCommand {
    $candidates = @(
        (Join-Path $InstallDir "venv\Scripts\hermes.exe"),
        (Join-Path $env:USERPROFILE ".local\bin\hermes.exe")
    )
    foreach ($candidate in $candidates) {
        if (Test-Path $candidate) { return $candidate }
    }

    $cmd = Get-Command hermes -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }

    return ""
}

function Get-PythonCommand {
    $candidate = Join-Path $InstallDir "venv\Scripts\python.exe"
    if (Test-Path $candidate) { return $candidate }
    return ""
}

function Get-UvCommand {
    $cmd = Get-Command uv -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }

    $candidates = @(
        (Join-Path $env:USERPROFILE ".local\bin\uv.exe"),
        (Join-Path $env:USERPROFILE ".cargo\bin\uv.exe")
    )
    foreach ($candidate in $candidates) {
        if (Test-Path $candidate) { return $candidate }
    }

    return ""
}

function Get-NpmCommand {
    $cmd = Get-Command npm.cmd -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }

    $cmd = Get-Command npm -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }

    return ""
}

function Get-NpxCommand {
    $cmd = Get-Command npx.cmd -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }

    $cmd = Get-Command npx -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }

    return ""
}

function Stop-HermesProcesses {
    Write-Title "停止旧 Hermes 进程"

    $hermes = Get-HermesCommand
    if (-not [string]::IsNullOrWhiteSpace($hermes)) {
        Write-Info "尝试停止 Hermes Gateway。"
        & $hermes gateway stop 2>$null
    }

    $escapedInstallDir = [regex]::Escape($InstallDir)
    $escapedHermesHome = [regex]::Escape($HermesHome)
    $processes = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
        ($_.CommandLine -match $escapedInstallDir) -or
        ($_.ExecutablePath -match $escapedInstallDir) -or
        ($_.CommandLine -match $escapedHermesHome -and $_.Name -match '^(python|pythonw|hermes|ha)\.exe$')
    })

    foreach ($proc in $processes) {
        if ($proc.ProcessId -eq $PID) { continue }
        Write-Warn2 "停止占用 Hermes 目录的进程: $($proc.Name) PID=$($proc.ProcessId)"
        try {
            Stop-Process -Id $proc.ProcessId -Force -ErrorAction Stop
        } catch {
            Write-Warn2 "无法停止进程 PID=$($proc.ProcessId): $_"
        }
    }
}

function Get-EnvPath {
    return Join-Path $HermesHome ".env"
}

function Get-ConfigPath {
    return Join-Path $HermesHome "config.yaml"
}

function Get-EnvValueExists {
    param([string]$Key)

    $envPath = Get-EnvPath
    if (-not (Test-Path $envPath)) { return $false }
    foreach ($line in Get-Content $envPath -ErrorAction SilentlyContinue) {
        if ($line -match ("^" + [regex]::Escape($Key) + "=(.+)$")) {
            return -not [string]::IsNullOrWhiteSpace($Matches[1])
        }
    }
    return $false
}

function Get-EnvValue {
    param([string]$Key)

    $envPath = Get-EnvPath
    if (-not (Test-Path $envPath)) { return "" }
    foreach ($line in Get-Content $envPath -ErrorAction SilentlyContinue) {
        if ($line -match ("^" + [regex]::Escape($Key) + "=(.*)$")) {
            return $Matches[1]
        }
    }
    return ""
}

function Test-SecretLooksInvalid {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) { return $true }
    if ($Value.Length -lt 8) { return $true }
    if ($Value -match "[\x00-\x1F\x7F]") { return $true }
    return $false
}

function Assert-SecretLooksValid {
    param(
        [string]$Key,
        [string]$Value
    )

    if (Test-SecretLooksInvalid $Value) {
        Fail "$Key 看起来不是有效值。常见原因是在 Windows 终端里按 Ctrl+V 没有真正粘贴，而是写入了控制字符。请用右键粘贴、Ctrl+Shift+V，或直接用记事本编辑 .env。"
    }
}

function Set-EnvValue {
    param(
        [string]$Key,
        [string]$Value
    )

    New-Item -ItemType Directory -Force -Path $HermesHome | Out-Null
    $envPath = Get-EnvPath
    $lines = @()
    if (Test-Path $envPath) {
        $lines = @(Get-Content $envPath -ErrorAction SilentlyContinue)
    }

    $found = $false
    $newLines = foreach ($line in $lines) {
        if ($line -match ("^" + [regex]::Escape($Key) + "=")) {
            $found = $true
            "$Key=$Value"
        } else {
            $line
        }
    }
    if (-not $found) {
        $newLines += "$Key=$Value"
    }

    [System.IO.File]::WriteAllLines($envPath, [string[]]$newLines, (Get-Utf8NoBomEncoding))
}

function Remove-EnvPrefix {
    param([string]$Prefix)

    $envPath = Get-EnvPath
    if (-not (Test-Path $envPath)) { return }

    Copy-Item $envPath "$envPath.bak.$(Get-Date -Format 'yyyyMMdd-HHmmss')" -Force
    $newLines = @(Get-Content $envPath -ErrorAction SilentlyContinue | Where-Object {
        -not $_.StartsWith($Prefix)
    })
    [System.IO.File]::WriteAllLines($envPath, [string[]]$newLines, (Get-Utf8NoBomEncoding))
}

function Invoke-OfficialInstaller {
    Write-Title "安装 Hermes Agent"

    $tmpScript = Join-Path $env:TEMP ("hermes-install-{0}.ps1" -f ([guid]::NewGuid().ToString("N")))
    $existingHermes = Get-HermesCommand
    if ((-not [string]::IsNullOrWhiteSpace($existingHermes)) -or (Test-Path $InstallDir)) {
        Write-Info "检测到已有 Hermes，将在原目录就地修复/更新，不会创建第二份安装。"
        Write-Info "已有 .env 和 config.yaml 会尽量保留；后续步骤只会按需更新 DeepSeek/聊天工具配置。"
    }
    Write-Info "下载官方安装脚本: $InstallUrl"

    try {
        Invoke-WebRequest -Uri $InstallUrl -OutFile $tmpScript -UseBasicParsing
        Convert-ScriptToUtf8Bom $tmpScript
        Patch-OfficialInstallerScript $tmpScript
    } catch {
        Fail "下载安装脚本失败。请检查代理或网络。错误: $_"
    }

    Write-Info "开始执行官方 Windows 原生安装脚本。"
    Write-Info "跳过官方 hermes setup 向导，后续由本安装器配置 DeepSeek 和聊天工具。"

    try {
        & $tmpScript -SkipSetup
        $officialExitCode = $LASTEXITCODE
    } finally {
        Remove-Item -Force $tmpScript -ErrorAction SilentlyContinue
    }

    if ($officialExitCode -ne 0) {
        Fail "官方安装脚本执行失败，退出码: $officialExitCode。请先关闭正在运行的 Hermes/Cursor/PowerShell 后重试。"
    }

    $hermes = Get-HermesCommand
    if ([string]::IsNullOrWhiteSpace($hermes)) {
        Fail "安装脚本执行完成，但没有找到 hermes 命令。"
    }

    Write-Info "Hermes 安装完成: $hermes"
}

function Invoke-ProcessWithTimeout {
    param(
        [string]$FilePath,
        [string[]]$Arguments,
        [string]$WorkingDirectory,
        [int]$TimeoutSeconds,
        [string]$Label,
        [string]$LogPath
    )

    $stdoutPath = "$LogPath.out"
    $stderrPath = "$LogPath.err"
    $process = Start-Process -FilePath $FilePath `
        -ArgumentList $Arguments `
        -WorkingDirectory $WorkingDirectory `
        -RedirectStandardOutput $stdoutPath `
        -RedirectStandardError $stderrPath `
        -NoNewWindow `
        -PassThru

    $elapsed = 0
    while (-not $process.HasExited) {
        Start-Sleep -Seconds 15
        $process.Refresh()
        $elapsed += 15
        if (-not $process.HasExited) {
            Write-Info "$Label 仍在进行，已等待 ${elapsed}s。"
        }
        if ($elapsed -ge $TimeoutSeconds) {
            Write-Warn2 "$Label 超过 ${TimeoutSeconds}s，准备停止。"
            try { $process.Kill() } catch {}
            return 124
        }
    }

    $process.WaitForExit()
    $process.Refresh()
    return $process.ExitCode
}

function Show-CommandLogSnippet {
    param([string]$LogPath)

    foreach ($path in @("$LogPath.err", "$LogPath.out")) {
        if (Test-Path $path) {
            $text = Get-Content $path -Raw -ErrorAction SilentlyContinue
            if (-not [string]::IsNullOrWhiteSpace($text)) {
                $snippet = if ($text.Length -gt 1600) { $text.Substring(0, 1600) + "..." } else { $text }
                foreach ($line in $snippet -split "`n") {
                    Write-Host "  $line" -ForegroundColor DarkGray
                }
                Write-Info "完整日志: $path"
            }
        }
    }
}

function Test-LogLooksSuccessful {
    param(
        [string]$LogPath,
        [string[]]$SuccessPatterns
    )

    $combined = ""
    foreach ($path in @("$LogPath.err", "$LogPath.out")) {
        if (Test-Path $path) {
            $combined += "`n"
            $combined += (Get-Content $path -Raw -ErrorAction SilentlyContinue)
        }
    }

    foreach ($pattern in $SuccessPatterns) {
        if ($combined -match $pattern) { return $true }
    }
    return $false
}

function Test-PlaywrightChromiumInstalled {
    $playwrightDir = Join-Path $env:LOCALAPPDATA "ms-playwright"
    if (-not (Test-Path $playwrightDir)) { return $false }

    $chromium = Get-ChildItem -Path $playwrightDir -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^chromium' } |
        Select-Object -First 1
    return ($null -ne $chromium)
}

function Get-BrowserToolsSignature {
    $packageLock = Join-Path $InstallDir "package-lock.json"
    $packageJson = Join-Path $InstallDir "package.json"

    if (Test-Path $packageLock) {
        return (Get-FileHash -Algorithm SHA256 $packageLock).Hash
    }
    if (Test-Path $packageJson) {
        return (Get-FileHash -Algorithm SHA256 $packageJson).Hash
    }
    return "no-package"
}

function Test-NpmDependenciesCurrent {
    $marker = Join-Path $HermesHome ".browser-tools-npm.sha256"
    $nodeModules = Join-Path $InstallDir "node_modules"
    if (-not (Test-Path $nodeModules)) { return $false }
    if (-not (Test-Path $marker)) { return $false }
    return ((Get-BrowserToolsSignature) -eq (Get-Content $marker -Raw).Trim())
}

function Set-NpmDependenciesCurrent {
    $marker = Join-Path $HermesHome ".browser-tools-npm.sha256"
    New-Item -ItemType Directory -Force -Path $HermesHome | Out-Null
    [System.IO.File]::WriteAllText($marker, (Get-BrowserToolsSignature), (Get-Utf8NoBomEncoding))
}

function Install-BrowserTools {
    Write-Title "安装 Hermes 浏览器工具"

    if (-not (Test-Path $InstallDir)) {
        Fail "未找到 Hermes 安装目录: $InstallDir"
    }
    if (-not (Test-Path (Join-Path $InstallDir "package.json"))) {
        Write-Warn2 "未找到 package.json，跳过浏览器工具安装。"
        return
    }

    $npm = Get-NpmCommand
    if ([string]::IsNullOrWhiteSpace($npm)) {
        Fail "未找到 npm，不能安装浏览器工具。"
    }

    $env:NODE_USE_ENV_PROXY = "1"
    $env:npm_config_ignore_scripts = "false"

    if (Test-NpmDependenciesCurrent) {
        Write-Info "Node 依赖已是当前版本，跳过 npm install。"
    } else {
        Write-Info "安装 Node 依赖（忽略 postinstall，避免浏览器资源下载卡死在 npm 阶段）。"
        $npmLog = Join-Path $env:TEMP ("hermes-npm-browser-{0}" -f (Get-Random))
        $npmCode = Invoke-ProcessWithTimeout $npm @("install", "--ignore-scripts") $InstallDir 900 "npm install" $npmLog
        if ($npmCode -ne 0) {
            if (Test-LogLooksSuccessful $npmLog @("found 0 vulnerabilities", "up to date", "added \d+ packages")) {
                Write-Warn2 "npm install 返回码异常，但日志显示已安装完成，继续下一步。"
                Set-NpmDependenciesCurrent
            } else {
            Show-CommandLogSnippet $npmLog
            Fail "Node 依赖安装失败或超时。请检查代理是否允许 npm registry 访问。"
            }
        } else {
            Set-NpmDependenciesCurrent
        }
    }

    $npx = Get-NpxCommand
    if ([string]::IsNullOrWhiteSpace($npx)) {
        Fail "未找到 npx，不能安装 Playwright Chromium。"
    }

    if (Test-PlaywrightChromiumInstalled) {
        Write-Info "检测到 Playwright Chromium 已安装，跳过下载。"
        Write-Info "Hermes 浏览器工具安装完成。"
        return
    }

    Write-Info "开始下载 Playwright Chromium。这个文件通常较大，国内网络可能需要几分钟。"
    Write-Info "如果这里超过 15 分钟失败，请检查代理是否允许 CDN/GitHub 大文件下载。"
    $pwLog = Join-Path $env:TEMP ("hermes-playwright-{0}" -f (Get-Random))
    $pwCode = Invoke-ProcessWithTimeout $npx @("playwright", "install", "chromium") $InstallDir 900 "Playwright Chromium 下载" $pwLog
    if ($pwCode -ne 0) {
        if (Test-PlaywrightChromiumInstalled) {
            Write-Warn2 "Playwright 返回码异常，但检测到 Chromium 已安装，继续。"
        } else {
        if (Test-LogLooksSuccessful $pwLog @("Chromium .* downloaded", "Downloaded Chromium", "chromium.*installed")) {
            Write-Warn2 "Playwright 返回码异常，但日志显示 Chromium 已安装完成，继续。"
        } else {
        Show-CommandLogSnippet $pwLog
        Fail "Playwright Chromium 安装失败或超时。Hermes 主程序可能已安装，但浏览器工具不可用。"
        }
        }
    }

    Write-Info "Hermes 浏览器工具安装完成。"
}

function Ensure-UvInstalled {
    Write-Title "检查 uv"

    $uv = Get-UvCommand
    if (-not [string]::IsNullOrWhiteSpace($uv)) {
        Write-Info "uv 已存在: $uv"
        $env:Path = "$(Split-Path $uv -Parent);$env:Path"
        return
    }

    $tmpScript = Join-Path $env:TEMP ("uv-install-{0}.ps1" -f ([guid]::NewGuid().ToString("N")))
    Write-Info "提前安装 uv，避免官方脚本在 Windows PowerShell 5.1 中执行远程 PowerShell 脚本。"

    try {
        Invoke-WebRequest -Uri "https://astral.sh/uv/install.ps1" -OutFile $tmpScript -UseBasicParsing
        Convert-ScriptToUtf8Bom $tmpScript
        & $tmpScript
    } catch {
        Write-Warn2 "提前安装 uv 失败，后续将交给官方安装脚本继续尝试。错误: $_"
    } finally {
        Remove-Item -Force $tmpScript -ErrorAction SilentlyContinue
    }

    $userLocalBin = Join-Path $env:USERPROFILE ".local\bin"
    $cargoBin = Join-Path $env:USERPROFILE ".cargo\bin"
    $env:Path = "$userLocalBin;$cargoBin;$env:Path"

    $uv = Get-UvCommand
    if (-not [string]::IsNullOrWhiteSpace($uv)) {
        Write-Info "uv 安装完成: $uv"
    } else {
        Fail "仍未检测到 uv。请检查代理或网络后重新运行安装器。"
    }
}

function Install-FeishuDependencies {
    Write-Title "安装国内聊天工具依赖"

    $python = Get-PythonCommand
    if ([string]::IsNullOrWhiteSpace($python)) {
        Fail "未找到 Hermes Python venv，不能安装聊天工具依赖。"
    }

    $missingPackages = @()

    & $python -c "import importlib.util; raise SystemExit(0 if importlib.util.find_spec('lark_oapi') else 1)" 2>$null
    if ($LASTEXITCODE -ne 0) {
        $missingPackages += "lark-oapi>=1.5.3"
    }

    & $python -c "import importlib.util; raise SystemExit(0 if importlib.util.find_spec('dingtalk_stream') else 1)" 2>$null
    if ($LASTEXITCODE -ne 0) {
        $missingPackages += "dingtalk-stream>=0.24.3"
    }

    & $python -c "import importlib.util; raise SystemExit(0 if importlib.util.find_spec('alibabacloud_dingtalk') else 1)" 2>$null
    if ($LASTEXITCODE -ne 0) {
        $missingPackages += "alibabacloud-dingtalk>=2.2.42"
    }

    & $python -c "import importlib.util; raise SystemExit(0 if importlib.util.find_spec('aiohttp') else 1)" 2>$null
    if ($LASTEXITCODE -ne 0) {
        $missingPackages += "aiohttp>=3.13.3"
    }

    & $python -c "import importlib.util; raise SystemExit(0 if importlib.util.find_spec('cryptography') else 1)" 2>$null
    if ($LASTEXITCODE -ne 0) {
        $missingPackages += "cryptography"
    }

    & $python -c "import importlib.util; raise SystemExit(0 if importlib.util.find_spec('qrcode') else 1)" 2>$null
    if ($LASTEXITCODE -ne 0) {
        $missingPackages += "qrcode>=7.4.2"
    }

    if ($missingPackages.Count -eq 0) {
        Write-Info "飞书、钉钉、企业微信、微信所需依赖已安装。"
        return
    }

    $uv = Get-Command uv -ErrorAction SilentlyContinue
    if (-not $uv) {
        $uvPath = Join-Path $env:USERPROFILE ".local\bin\uv.exe"
        if (Test-Path $uvPath) {
            $uv = New-Object PSObject -Property @{ Source = $uvPath }
        }
    }
    if (-not $uv) {
        Fail "未找到 uv，不能自动安装聊天工具依赖。"
    }
    Write-Info "安装缺失依赖: $($missingPackages -join ', ')"
    $uvExe = $uv.Source
    $uvArgs = @("pip", "install", "--python", $python) + $missingPackages
    & $uvExe @uvArgs
    if ($LASTEXITCODE -ne 0) { Fail "聊天工具依赖安装失败。" }
}

function Configure-DeepSeek {
    Write-Title "配置 DeepSeek"

    $hermes = Get-HermesCommand
    if ([string]::IsNullOrWhiteSpace($hermes)) {
        Fail "未找到 hermes，不能配置模型。"
    }

    $key = ""
    if (Get-EnvValueExists "DEEPSEEK_API_KEY") {
        $keep = Read-Host "检测到已有 DeepSeek API Key，是否保留？[Y/n]"
        if ([string]::IsNullOrWhiteSpace($keep)) { $keep = "Y" }
        if ($keep -match "^[Yy]") {
            Write-Info "保留已有 DeepSeek API Key。"
        } else {
            Write-Warn2 "为了避免 Windows 终端隐藏输入时粘贴失败，下面的 Key 会明文显示。请确认周围无人观看。"
            $key = Read-Host "请输入新的 DeepSeek API Key"
            Assert-SecretLooksValid "DEEPSEEK_API_KEY" $key
        }
    } else {
        Write-Warn2 "为了避免 Windows 终端隐藏输入时粘贴失败，下面的 Key 会明文显示。请确认周围无人观看。"
        $key = Read-Host "请输入你的 DeepSeek API Key"
        Assert-SecretLooksValid "DEEPSEEK_API_KEY" $key
    }

    $model = Read-Host "DeepSeek 模型名 [$DefaultDeepSeekModel]"
    if ([string]::IsNullOrWhiteSpace($model)) { $model = $DefaultDeepSeekModel }

    if (-not [string]::IsNullOrWhiteSpace($key)) {
        & $hermes config set DEEPSEEK_API_KEY $key
        if ($LASTEXITCODE -ne 0) {
            Write-Warn2 "hermes config set 写 Key 失败，改为直接写入 .env。"
            Set-EnvValue "DEEPSEEK_API_KEY" $key
        }
    }

    $configOk = $true
    & $hermes config set model.provider deepseek
    if ($LASTEXITCODE -ne 0) { $configOk = $false }
    & $hermes config set model.default $model
    if ($LASTEXITCODE -ne 0) { $configOk = $false }
    & $hermes config set model.base_url "https://api.deepseek.com/v1"
    if ($LASTEXITCODE -ne 0) { $configOk = $false }
    & $hermes config set model.api_key '${DEEPSEEK_API_KEY}'
    if ($LASTEXITCODE -ne 0) { $configOk = $false }

    if (-not $configOk) {
        Write-Warn2 "hermes config set DeepSeek 模型配置失败，改为直接写入 config.yaml。"
        $configPath = Get-ConfigPath
        if (Test-Path $configPath) {
            Copy-Item $configPath "$configPath.bak.$(Get-Date -Format 'yyyyMMdd-HHmmss')" -Force
        }
        $content = @"
model:
  provider: "deepseek"
  default: "$model"
  base_url: "https://api.deepseek.com/v1"
  api_key: "`${DEEPSEEK_API_KEY}"
terminal:
  backend: local
group_sessions_per_user: true
"@
        [System.IO.File]::WriteAllText($configPath, $content, (Get-Utf8NoBomEncoding))
    }

    Write-Info "DeepSeek 配置完成。"
}

function Test-MessagingConfigured {
    $envPath = Get-EnvPath
    if (-not (Test-Path $envPath)) { return $false }
    $keys = @(
        "TELEGRAM_BOT_TOKEN", "DISCORD_BOT_TOKEN", "SLACK_BOT_TOKEN", "SLACK_APP_TOKEN",
        "MATRIX_HOMESERVER", "MATTERMOST_URL", "WHATSAPP_ENABLED", "SIGNAL_PHONE_NUMBER",
        "EMAIL_ADDRESS", "TWILIO_ACCOUNT_SID", "DINGTALK_CLIENT_ID", "FEISHU_APP_ID",
        "WECOM_BOT_ID", "WECOM_CORP_ID", "WEIXIN_TOKEN", "BLUEBUBBLES_SERVER_URL",
        "QQ_APP_ID", "YUANBAO_TOKEN", "GOOGLE_CHAT_SPACE", "IRC_SERVER",
        "LINE_CHANNEL_ACCESS_TOKEN", "TEAMS_APP_ID"
    )
    foreach ($key in $keys) {
        if (Get-EnvValueExists $key) { return $true }
    }
    return $false
}

function Test-FeishuFullyConfigured {
    return ((Get-EnvValueExists "FEISHU_APP_ID") -and (Get-EnvValueExists "FEISHU_APP_SECRET"))
}

function Repair-FeishuSecretIfInvalid {
    if (-not ((Get-EnvValueExists "FEISHU_APP_ID") -or (Get-EnvValueExists "FEISHU_APP_SECRET"))) {
        return
    }

    $appId = Get-EnvValue "FEISHU_APP_ID"
    $appSecret = Get-EnvValue "FEISHU_APP_SECRET"
    $needsRepair = (Test-SecretLooksInvalid $appId) -or (Test-SecretLooksInvalid $appSecret)
    if (-not $needsRepair) { return }

    Write-Warn2 "检测到本机已有飞书配置，但 App ID/App Secret 不完整或疑似无效。"
    Write-Warn2 "如果你这次不使用飞书，可以删除这些 FEISHU_* 配置，避免后续误判。"
    Write-Host ""
    Write-Host "1) 继续使用飞书，手动填写 App ID/App Secret"
    Write-Host "2) 不使用飞书，删除 FEISHU_* 配置"
    Write-Host "3) 暂不处理"
    $choice = Read-Host "请选择 [1-3]"

    switch ($choice) {
        "1" {
            Write-Info "只有选择非扫码/手动凭据方式时才需要 App ID 和 App Secret。"
            Write-Info "飞书开放平台: $FeishuAppConsoleUrl"
            Write-Warn2 "下面改为明文输入，便于复制粘贴。请确认周围无人观看。"

            $newAppId = Read-Host "请输入飞书 App ID（通常以 cli_ 开头，直接回车保留现有值）"
            if (-not [string]::IsNullOrWhiteSpace($newAppId)) {
                Assert-SecretLooksValid "FEISHU_APP_ID" $newAppId
                Set-EnvValue "FEISHU_APP_ID" $newAppId
            }

            $newSecret = Read-Host "请输入飞书 App Secret（明文显示）"
            Assert-SecretLooksValid "FEISHU_APP_SECRET" $newSecret
            Set-EnvValue "FEISHU_APP_SECRET" $newSecret
            break
        }
        "2" {
            Remove-EnvPrefix "FEISHU_"
            Write-Info "已删除 FEISHU_* 配置。"
            break
        }
        default {
            Write-Warn2 "暂不处理飞书配置。如果后续不使用飞书，建议删除 .env 里的 FEISHU_* 项。"
            break
        }
    }
}

function Configure-Messaging {
    Write-Title "聊天工具配置"

    $hermes = Get-HermesCommand
    if ([string]::IsNullOrWhiteSpace($hermes)) {
        Fail "未找到 hermes，不能配置聊天工具。"
    }

    if (Test-MessagingConfigured) {
        if (Test-FeishuFullyConfigured) {
            Write-Info "检测到已有飞书 App ID/App Secret。"
        }
        $answer = Read-Host "检测到已有聊天工具配置，是否重新打开配置向导？[y/N]"
        if ([string]::IsNullOrWhiteSpace($answer)) { $answer = "N" }
        if ($answer -notmatch "^[Yy]") {
            Write-Info "保留现有聊天工具配置，不重复配置。"
            Repair-FeishuSecretIfInvalid
            return
        }
    }

    Write-Info "接下来会启动 Hermes 官方聊天工具配置向导。"
    Write-Info "推荐选择 Feishu / Lark（飞书），适合国内团队；也可以选择 Telegram、Slack、企业微信等。"
    Write-Info "飞书默认走扫码/向导流程，通常不需要手动准备 App ID 和 App Secret；只有选择非扫码/手动凭据方式时才需要。"
    Write-Info "配置完成后，官方向导会回到聊天工具列表。看到 Done 为默认项时，直接按回车结束。"
    $answer2 = Read-Host "现在启动聊天工具配置向导？[Y/n]"
    if ([string]::IsNullOrWhiteSpace($answer2)) { $answer2 = "Y" }
    if ($answer2 -match "^[Yy]") {
        & $hermes gateway setup
        if ($LASTEXITCODE -ne 0) {
            Write-Warn2 "聊天工具配置向导没有正常结束，可稍后重新运行本安装器。"
        }
    } else {
        Write-Warn2 "已跳过聊天工具配置向导。"
    }

    Repair-FeishuSecretIfInvalid
}

function Start-Gateway {
    Write-Title "启动聊天网关"

    $hermes = Get-HermesCommand
    if ([string]::IsNullOrWhiteSpace($hermes)) {
        Fail "未找到 hermes，不能启动 gateway。"
    }

    $serviceInstalled = $true
    Write-Info "尝试安装或刷新 Windows 后台服务（Scheduled Task，用于开机自启）。"
    & $hermes gateway install
    if ($LASTEXITCODE -ne 0) {
        $serviceInstalled = $false
        Write-Warn2 "gateway install 没有正常完成。常见原因是 Windows 拒绝创建 Scheduled Task 或公司策略限制。"
        Write-Warn2 "继续尝试启动当前会话的 Gateway；如果成功，本次可用，但不会保证开机自启。"
    }

    & $hermes gateway start
    if ($LASTEXITCODE -ne 0) {
        & $hermes gateway restart
    }
    if ($LASTEXITCODE -ne 0) {
        Write-Warn2 "后台服务启动失败，尝试普通后台进程。"
        $logDir = Join-Path $HermesHome "logs"
        New-Item -ItemType Directory -Force -Path $logDir | Out-Null
        Start-Process -FilePath $hermes -ArgumentList @("gateway", "run", "--replace") `
            -RedirectStandardOutput (Join-Path $logDir "gateway.log") `
            -RedirectStandardError (Join-Path $logDir "gateway.error.log") `
            -WindowStyle Hidden
    }

    & $hermes gateway status
    & $hermes gateway list

    if ($serviceInstalled) {
        Write-Info "Gateway 已启动，并已尝试配置开机自启。"
    } else {
        Write-Warn2 "Gateway 当前已尝试启动，但开机自启未安装成功。重启电脑后可能需要重新运行菜单 7 或手动执行 hermes gateway install。"
    }
}

function Run-Checks {
    Write-Title "环境检查"

    Write-Info "Windows: $([System.Environment]::OSVersion.VersionString)"
    Write-Info "HermesHome: $HermesHome"

    $proxy = Get-ConfiguredProxy
    if (-not [string]::IsNullOrWhiteSpace($proxy)) {
        Write-Info "当前可用代理: $(Mask-Secret $proxy)"
    } else {
        Write-Warn2 "当前没有检测到代理。"
    }

    try {
        Invoke-WebRequest -Uri $InstallUrl -UseBasicParsing -Method Head -TimeoutSec 10 | Out-Null
        Write-Info "官方安装脚本 URL 可访问。"
    } catch {
        Write-Warn2 "官方安装脚本 URL 暂时不可访问，国内网络通常需要代理。"
    }

    $uv = Get-UvCommand
    if (-not [string]::IsNullOrWhiteSpace($uv)) {
        Write-Info "uv: $uv"
    } else {
        Write-Warn2 "未找到 uv。"
    }

    $npm = Get-NpmCommand
    if (-not [string]::IsNullOrWhiteSpace($npm)) {
        Write-Info "npm: $npm"
    } else {
        Write-Warn2 "未找到 npm。"
    }

    $npx = Get-NpxCommand
    if (-not [string]::IsNullOrWhiteSpace($npx)) {
        Write-Info "npx: $npx"
    } else {
        Write-Warn2 "未找到 npx。"
    }

    $git = Get-Command git -ErrorAction SilentlyContinue
    if ($git) {
        Write-Info "git: $($git.Source)"
        & git --version
    } else {
        Write-Warn2 "未找到 git。官方安装脚本可能会安装 Hermes 自带 Git。"
    }

    $hermes = Get-HermesCommand
    if (-not [string]::IsNullOrWhiteSpace($hermes)) {
        Write-Info "hermes: $hermes"
        & $hermes --version
        & $hermes config check
    } else {
        Write-Warn2 "未找到 hermes。"
    }

    if (Get-EnvValueExists "DEEPSEEK_API_KEY") {
        Write-Info "已配置 DEEPSEEK_API_KEY。"
    } else {
        Write-Warn2 "未找到 DEEPSEEK_API_KEY。"
    }

    if (Test-FeishuFullyConfigured) {
        Write-Info "已配置飞书 App ID/App Secret。"
    } elseif (Test-MessagingConfigured) {
        Write-Info "已检测到聊天工具配置。"
    } else {
        Write-Info "未检测到聊天工具配置。"
    }
}

function Uninstall-Hermes {
    Write-Title "卸载 Hermes"

    Write-Warn2 "软卸载会删除 Hermes 程序，尽量保留配置。"
    Write-Warn2 "完全卸载会删除 $HermesHome，包括 Key、聊天工具配置、日志和会话。"
    Write-Host ""
    Write-Host "1) 软卸载（用于测试重装，保留配置）"
    Write-Host "2) 完全卸载（删除所有 Hermes 本地配置）"
    Write-Host "3) 返回"
    $choice = Read-Host "请选择 [1-3]"

    switch ($choice) {
        "1" {
            Stop-HermesProcesses
            Remove-HermesProgramFiles
            Write-Info "软卸载完成。"
            break
        }
        "2" {
            $confirm = Read-Host "确认删除 $HermesHome？请输入 DELETE 确认"
            if ($confirm -eq "DELETE") {
                Stop-HermesProcesses
                Remove-Item -Recurse -Force $HermesHome -ErrorAction SilentlyContinue
                Remove-HermesEntryPoints
                Write-Info "完全卸载完成。"
            } else {
                Write-Warn2 "未确认，已取消完全卸载。"
            }
            break
        }
        default {
            break
        }
    }
}

function Remove-HermesEntryPoints {
    $localBin = Join-Path $env:USERPROFILE ".local\bin"
    $entryPoints = @(
        (Join-Path $localBin "hermes.exe"),
        (Join-Path $localBin "ha.exe"),
        (Join-Path $localBin "hermes.cmd"),
        (Join-Path $localBin "ha.cmd"),
        (Join-Path $localBin "hermes"),
        (Join-Path $localBin "ha")
    )

    foreach ($path in $entryPoints) {
        Remove-Item -Force $path -ErrorAction SilentlyContinue
    }
}

function Remove-HermesProgramFiles {
    $paths = @(
        $InstallDir,
        (Join-Path $HermesHome "repo"),
        (Join-Path $HermesHome "venv"),
        (Join-Path $HermesHome "node"),
        (Join-Path $HermesHome "git")
    )

    foreach ($path in $paths) {
        Remove-Item -Recurse -Force $path -ErrorAction SilentlyContinue
    }

    Remove-HermesEntryPoints
}

function Install-Or-Repair {
    Configure-Proxy
    Stop-HermesProcesses
    Ensure-UvInstalled
    Invoke-OfficialInstaller
    Install-BrowserTools
    Install-FeishuDependencies
    Configure-DeepSeek
    Configure-Messaging
    Start-Gateway
    Run-Checks

    Write-Title "完成"
    Write-Info "安装器已完成。"
    Write-Info "聊天测试: hermes chat"
    Write-Info "启动聊天网关: hermes gateway"
    Write-Info "日志位置: $LogFile"
}

function Stop-HermesMenu {
    Stop-HermesProcesses
    Write-Info "Hermes/Gateway 已尝试关闭。"
}

function Main-Menu {
    while ($true) {
        Write-Title "Hermes Agent Windows 原生安装器"
        Write-Host "1) 安装/修复 Hermes，并配置 DeepSeek 与聊天工具（推荐飞书）"
        Write-Host "2) 启动/重启 Hermes/Gateway"
        Write-Host "3) 关闭 Hermes/Gateway"
        Write-Host "4) 检查当前环境"
        Write-Host "5) 只重新配置 DeepSeek Key/模型"
        Write-Host "6) 只配置聊天工具（推荐飞书）"
        Write-Host "7) 只安装/修复浏览器工具"
        Write-Host "8) 卸载 Hermes（用于测试重装）"
        Write-Host "0) 退出"
        $choice = Read-Host "请选择 [0-8]"

        switch ($choice) {
            "1" { Install-Or-Repair; Pause-Installer }
            "2" { Configure-Proxy; Stop-HermesProcesses; Install-FeishuDependencies; Start-Gateway; Pause-Installer }
            "3" { Stop-HermesMenu; Pause-Installer }
            "4" { Configure-Proxy; Run-Checks; Pause-Installer }
            "5" { Configure-DeepSeek; Pause-Installer }
            "6" { Configure-Proxy; Install-FeishuDependencies; Configure-Messaging; Start-Gateway; Pause-Installer }
            "7" { Configure-Proxy; Install-BrowserTools; Pause-Installer }
            "8" { Uninstall-Hermes; Pause-Installer }
            "0" { Stop-Transcript | Out-Null; exit 0 }
            default { Write-Warn2 "无效选择。" }
        }
    }
}

try {
    Main-Menu
} catch {
    Write-Host ""
    Write-Host "[ERROR] 安装器异常: $_" -ForegroundColor Red
    Write-Host "日志位置: $LogFile"
    Read-Host "按回车退出"
    Stop-Transcript | Out-Null
    exit 1
}
