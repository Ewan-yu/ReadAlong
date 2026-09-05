[CmdletBinding()]
param(
    [switch]$Restart
)

$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$serviceRoot = Join-Path $projectRoot 'parent_tool'
$webRoot = Join-Path $serviceRoot 'web'
$webIndex = Join-Path $webRoot 'dist\index.html'
$python = 'D:\Program Files\Anaconda3\envs\readalong\python.exe'
$healthUrl = 'http://127.0.0.1:8760/api/health'
$appUrl = 'http://127.0.0.1:8760'

function Show-StartError([string]$message) {
    Add-Type -AssemblyName PresentationFramework
    [void][System.Windows.MessageBox]::Show(
        $message,
        'ReadAlong 家长端未能启动',
        [System.Windows.MessageBoxButton]::OK,
        [System.Windows.MessageBoxImage]::Error
    )
}

function Test-ParentToolHealthy {
    try {
        $health = Invoke-RestMethod -Uri $healthUrl -TimeoutSec 2
        return $health.status -eq 'ok'
    } catch {
        return $false
    }
}

function Test-WebBuildCurrent {
    if (-not (Test-Path -LiteralPath $webIndex -PathType Leaf)) {
        return $false
    }

    $inputs = @(
        Get-ChildItem -LiteralPath (Join-Path $webRoot 'src') -Recurse -File
        Get-Item -LiteralPath (Join-Path $webRoot 'package.json')
        Get-Item -LiteralPath (Join-Path $webRoot 'pnpm-lock.yaml')
        Get-ChildItem -LiteralPath $webRoot -File -Filter 'tsconfig*.json'
        Get-ChildItem -LiteralPath $webRoot -File -Filter 'vite.config.*'
    )
    $latestInput = $inputs | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
    $built = Get-Item -LiteralPath $webIndex
    return $null -ne $latestInput -and $built.LastWriteTimeUtc -ge $latestInput.LastWriteTimeUtc
}

function Update-WebBuild([switch]$Force) {
    if (-not $Force -and (Test-WebBuildCurrent)) {
        return
    }

    $pnpm = Get-Command 'pnpm.cmd' -ErrorAction SilentlyContinue
    if ($null -ne $pnpm) {
        $packageManager = $pnpm.Source
        $packageManagerArguments = @('build')
    } else {
        $corepack = Get-Command 'corepack.cmd' -ErrorAction SilentlyContinue
        if ($null -eq $corepack) {
            $corepackPath = 'C:\Program Files\nodejs\corepack.cmd'
            if (Test-Path -LiteralPath $corepackPath -PathType Leaf) {
                $corepack = Get-Item -LiteralPath $corepackPath
            }
        }
        if ($null -eq $corepack) {
            throw "家长端网页需要重新构建，但找不到 pnpm 或 Corepack。`n`n请安装项目要求的 Node.js/pnpm 后重试。"
        }
        $packageManager = if ($corepack.PSObject.Properties['Source']) {
            $corepack.Source
        } else {
            $corepackPath
        }
        $packageManagerArguments = @('pnpm', 'build')
    }

    Push-Location $webRoot
    try {
        & $packageManager @packageManagerArguments
        if ($LASTEXITCODE -ne 0) {
            throw "家长端网页构建失败（退出码 $LASTEXITCODE）。"
        }
    } finally {
        Pop-Location
    }
}

function Stop-ParentTool {
    $occupied = @(Get-NetTCPConnection -LocalPort 8760 -State Listen -ErrorAction SilentlyContinue)
    foreach ($listener in $occupied) {
        $processId = [int]$listener.OwningProcess
        $commandLine = (Get-CimInstance Win32_Process -Filter "ProcessId = $processId").CommandLine
        if ($commandLine -notmatch 'app\.main(?::app)?') {
            throw "8760 端口已被其他程序占用，拒绝停止进程 $processId。"
        }
        Stop-Process -Id $processId -Force
    }

    for ($attempt = 1; $attempt -le 20; $attempt++) {
        if (-not (Get-NetTCPConnection -LocalPort 8760 -State Listen -ErrorAction SilentlyContinue)) {
            return
        }
        Start-Sleep -Milliseconds 250
    }
    throw '家长端旧进程未能释放 8760 端口。'
}

try {
    if (-not (Test-Path -LiteralPath $python -PathType Leaf)) {
        throw "找不到 readalong Python 环境：`n$python`n`n请按启动指南恢复 Conda 环境后重试。"
    }
    if (-not (Test-Path -LiteralPath $serviceRoot -PathType Container)) {
        throw "找不到家长端目录：`n$serviceRoot"
    }

    Update-WebBuild -Force:$Restart

    if ($Restart -and (Test-ParentToolHealthy)) {
        Stop-ParentTool
    }

    if (-not (Test-ParentToolHealthy)) {
        $occupied = Get-NetTCPConnection -LocalPort 8760 -State Listen -ErrorAction SilentlyContinue
        if ($occupied) {
            throw "8760 端口已被其他程序占用。`n`n请先按《家长端服务启动指南》停止旧进程后再试。"
        }

        Start-Process -FilePath $python `
            -ArgumentList @('-m', 'uvicorn', 'app.main:app', '--host', '127.0.0.1', '--port', '8760') `
            -WorkingDirectory $serviceRoot `
            -WindowStyle Hidden

        $ready = $false
        for ($attempt = 1; $attempt -le 30; $attempt++) {
            Start-Sleep -Seconds 1
            if (Test-ParentToolHealthy) {
                $ready = $true
                break
            }
        }
        if (-not $ready) {
            throw "家长端在 30 秒内未就绪。`n`n请检查 GPU、VoxCPM 模型和服务日志。"
        }
    }

    $launchUrl = "$appUrl/?build=$([DateTime]::UtcNow.Ticks)"
    Start-Process $launchUrl
} catch {
    Show-StartError $_.Exception.Message
    exit 1
}
