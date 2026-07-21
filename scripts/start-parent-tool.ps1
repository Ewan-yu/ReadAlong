[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$serviceRoot = Join-Path $projectRoot 'parent_tool'
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

try {
    if (-not (Test-Path -LiteralPath $python -PathType Leaf)) {
        throw "找不到 readalong Python 环境：`n$python`n`n请按启动指南恢复 Conda 环境后重试。"
    }
    if (-not (Test-Path -LiteralPath $serviceRoot -PathType Container)) {
        throw "找不到家长端目录：`n$serviceRoot"
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

    Start-Process $appUrl
} catch {
    Show-StartError $_.Exception.Message
    exit 1
}
