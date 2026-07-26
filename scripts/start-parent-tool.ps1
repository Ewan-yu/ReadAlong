[CmdletBinding()]
param()

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

function Update-WebBuild {
    if (Test-WebBuildCurrent) {
        return
    }

    $pnpm = Get-Command 'pnpm.cmd' -ErrorAction SilentlyContinue
    if ($null -eq $pnpm) {
        throw "家长端网页需要重新构建，但找不到 pnpm.cmd。`n`n请安装项目要求的 pnpm 后重试。"
    }

    Push-Location $webRoot
    try {
        & $pnpm.Source build
        if ($LASTEXITCODE -ne 0) {
            throw "家长端网页构建失败（退出码 $LASTEXITCODE）。"
        }
    } finally {
        Pop-Location
    }
}

try {
    if (-not (Test-Path -LiteralPath $python -PathType Leaf)) {
        throw "找不到 readalong Python 环境：`n$python`n`n请按启动指南恢复 Conda 环境后重试。"
    }
    if (-not (Test-Path -LiteralPath $serviceRoot -PathType Container)) {
        throw "找不到家长端目录：`n$serviceRoot"
    }

    Update-WebBuild

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

    Start-Process $appUrl
} catch {
    Show-StartError $_.Exception.Message
    exit 1
}
