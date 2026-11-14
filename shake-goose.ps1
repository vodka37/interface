[CmdletBinding()]
param(
    [ValidateSet("auto", "adb", "ui")]
    [string]$Mode,
    [string]$AdbPath,
    [string]$Serial,
    [string]$WindowTitle,
    [Nullable[int]]$Cycles,
    [Nullable[int]]$IntervalMs,
    [string]$ConfigPath = (Join-Path $PSScriptRoot "config.json")
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Get-Config {
    param([string]$Path)

    $defaults = @{
        mode = "auto"
        adbPath = ""
        serial = "127.0.0.1:5555"
        windowTitle = "抓大鹅"
        cycles = 4
        intervalMs = 100
    }

    if (Test-Path -LiteralPath $Path) {
        try {
            $loaded = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
        }
        catch {
            throw "配置文件无法读取：$Path。请确认它是有效的 JSON。`n$($_.Exception.Message)"
        }

        foreach ($name in @("mode", "adbPath", "serial", "windowTitle", "cycles", "intervalMs")) {
            if ($null -ne $loaded.PSObject.Properties[$name]) {
                $defaults[$name] = $loaded.$name
            }
        }
    }

    return $defaults
}

function Find-Adb {
    param([string]$ConfiguredPath)

    if ($ConfiguredPath) {
        if (Test-Path -LiteralPath $ConfiguredPath -PathType Leaf) {
            return (Resolve-Path -LiteralPath $ConfiguredPath).Path
        }
        throw "配置的 adbPath 不存在：$ConfiguredPath"
    }

    $command = Get-Command adb.exe -ErrorAction SilentlyContinue
    if (-not $command) {
        $command = Get-Command adb -ErrorAction SilentlyContinue
    }
    if ($command) {
        return $command.Source
    }

    $candidates = New-Object System.Collections.Generic.List[string]
    try {
        $installPath = (Get-ItemProperty -LiteralPath "HKLM:\SOFTWARE\Tencent\Androws" -ErrorAction Stop).InstallPath
        $version = (Get-ItemProperty -LiteralPath "HKLM:\SOFTWARE\Tencent\Androws\Androws" -ErrorAction Stop).Version
        if ($installPath -and $version) {
            $candidates.Add((Join-Path $installPath "Application\$version\adb.exe"))
        }
    }
    catch {
        # Older builds do not necessarily expose these registry keys.
    }

    foreach ($root in @($env:ProgramFiles, ${env:ProgramFiles(x86)})) {
        if (-not $root) {
            continue
        }
        $pattern = Join-Path $root "Tencent\Androws\Application\*\adb.exe"
        Get-ChildItem -Path $pattern -File -ErrorAction SilentlyContinue |
            Sort-Object FullName -Descending |
            ForEach-Object { $candidates.Add($_.FullName) }
    }

    return $candidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
}

function Invoke-Adb {
    param(
        [string]$Executable,
        [string[]]$Arguments
    )

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $Executable
    $startInfo.Arguments = ($Arguments -join " ")
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    [void]$process.Start()
    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()
    $process.WaitForExit()

    return [pscustomobject]@{
        ExitCode = $process.ExitCode
        Output = (($stdout + "`n" + $stderr).Trim())
    }
}

function Connect-Adb {
    param(
        [string]$Executable,
        [string]$Target
    )

    [void](Invoke-Adb -Executable $Executable -Arguments @("connect", $Target))
    $state = Invoke-Adb -Executable $Executable -Arguments @("-s", $Target, "get-state")
    return $state.ExitCode -eq 0 -and $state.Output -match "(?m)^device$"
}

function Invoke-AdbShake {
    param(
        [string]$Executable,
        [string]$Target,
        [int]$Repeat,
        [int]$DelayMs
    )

    foreach ($index in 1..$Repeat) {
        foreach ($value in @("18:0:0", "-18:0:0", "0:9.81:0")) {
            $result = Invoke-Adb -Executable $Executable -Arguments @(
                "-s", $Target, "emu", "sensor", "set", "acceleration", $value
            )
            if ($result.ExitCode -ne 0) {
                return $false
            }
            Start-Sleep -Milliseconds $DelayMs
        }
    }
    return $true
}

function Initialize-UiAutomation {
    Add-Type -AssemblyName UIAutomationClient
    Add-Type -AssemblyName UIAutomationTypes
    if (-not ("GooseShaker.NativeWindow" -as [type])) {
        Add-Type @"
using System;
using System.Runtime.InteropServices;
namespace GooseShaker {
    public static class NativeWindow {
        [DllImport("user32.dll")]
        public static extern bool SetForegroundWindow(IntPtr hWnd);
    }
}
"@
    }
}

function Find-NamedElement {
    param(
        [Windows.Automation.AutomationElement]$Root,
        [string[]]$Names
    )

    $elements = $Root.FindAll(
        [Windows.Automation.TreeScope]::Descendants,
        [Windows.Automation.Condition]::TrueCondition
    )
    foreach ($element in $elements) {
        try {
            $name = $element.Current.Name
            if (-not $element.Current.IsOffscreen -and
                ($Names | Where-Object { $name -eq $_ -or $name -like "*$_*" })) {
                return $element
            }
        }
        catch {
            # UI trees can change while being enumerated.
        }
    }
    return $null
}

function Invoke-UiElement {
    param([Windows.Automation.AutomationElement]$Element)

    $pattern = $null
    if ($Element.TryGetCurrentPattern(
        [Windows.Automation.InvokePattern]::Pattern,
        [ref]$pattern
    )) {
        ([Windows.Automation.InvokePattern]$pattern).Invoke()
        return
    }

    if ($Element.TryGetCurrentPattern(
        [Windows.Automation.LegacyIAccessiblePattern]::Pattern,
        [ref]$pattern
    )) {
        ([Windows.Automation.LegacyIAccessiblePattern]$pattern).DoDefaultAction()
        return
    }

    throw "控件「$($Element.Current.Name)」不支持自动点击。"
}

function Find-AndrowsWindow {
    param([string]$Title)

    $desktop = [Windows.Automation.AutomationElement]::RootElement
    $windows = $desktop.FindAll(
        [Windows.Automation.TreeScope]::Children,
        [Windows.Automation.Condition]::TrueCondition
    )

    # Prefer the game window. The store and game can both use an Androws process.
    foreach ($window in $windows) {
        try {
            if ($window.Current.Name -like "*$Title*") {
                return $window
            }
        }
        catch {
            # Ignore windows that disappear during discovery.
        }
    }

    foreach ($window in $windows) {
        try {
            $process = Get-Process -Id $window.Current.ProcessId -ErrorAction SilentlyContinue
            if ($process -and $process.ProcessName -like "Androws*") {
                return $window
            }
        }
        catch {
            # Ignore windows that disappear during discovery.
        }
    }
    return $null
}

function Invoke-UiShake {
    param([string]$Title)

    Initialize-UiAutomation
    $window = Find-AndrowsWindow -Title $Title
    if (-not $window) {
        throw "未找到应用宝中的「$Title」窗口。请先启动应用宝并打开游戏。"
    }

    [void][GooseShaker.NativeWindow]::SetForegroundWindow(
        [IntPtr]$window.Current.NativeWindowHandle
    )

    $shake = Find-NamedElement -Root $window -Names @("摇一摇")
    if (-not $shake) {
        $toolbox = Find-NamedElement -Root $window -Names @("工具箱")
        if (-not $toolbox) {
            throw "已找到游戏窗口，但没有识别到「工具箱」。请确认应用宝顶部导航栏可见。"
        }
        Invoke-UiElement -Element $toolbox
        Start-Sleep -Milliseconds 350

        $shake = Find-NamedElement `
            -Root ([Windows.Automation.AutomationElement]::RootElement) `
            -Names @("摇一摇")
    }

    if (-not $shake) {
        throw "已打开「工具箱」，但没有识别到「摇一摇」。请确认当前应用宝版本支持该功能。"
    }
    Invoke-UiElement -Element $shake
}

try {
    $config = Get-Config -Path $ConfigPath
    if (-not $Mode) { $Mode = [string]$config.mode }
    if (-not $AdbPath) { $AdbPath = [string]$config.adbPath }
    if (-not $Serial) { $Serial = [string]$config.serial }
    if (-not $WindowTitle) { $WindowTitle = [string]$config.windowTitle }
    if ($null -eq $Cycles) { $Cycles = [int]$config.cycles }
    if ($null -eq $IntervalMs) { $IntervalMs = [int]$config.intervalMs }

    if ($Mode -notin @("auto", "adb", "ui")) {
        throw "mode 必须是 auto、adb 或 ui。"
    }
    if ($Cycles -lt 1 -or $Cycles -gt 20) {
        throw "cycles 必须在 1 到 20 之间。"
    }
    if ($IntervalMs -lt 30 -or $IntervalMs -gt 1000) {
        throw "intervalMs 必须在 30 到 1000 之间。"
    }

    $adb = $null
    if ($Mode -ne "ui") {
        $adb = Find-Adb -ConfiguredPath $AdbPath
        if ($adb -and (Connect-Adb -Executable $adb -Target $Serial)) {
            if (Invoke-AdbShake `
                -Executable $adb `
                -Target $Serial `
                -Repeat $Cycles `
                -DelayMs $IntervalMs) {
                Write-Host "颠锅完成（ADB 传感器）。" -ForegroundColor Green
                exit 0
            }
        }

        if ($Mode -eq "adb") {
            throw "ADB 传感器注入不可用。请确认开发者模式、ADB 连接和模拟器传感器接口；或改用 auto/ui 模式。"
        }
    }

    Invoke-UiShake -Title $WindowTitle
    Write-Host "颠锅完成（应用宝「摇一摇」）。" -ForegroundColor Green
    exit 0
}
catch {
    Write-Host "一键颠锅失败：$($_.Exception.Message)" -ForegroundColor Red
    Write-Host "排查：先打开应用宝和抓大鹅；新版应用宝需在「设置」中连续点击「性能」7次并开启开发者模式。" -ForegroundColor Yellow
    exit 1
}
