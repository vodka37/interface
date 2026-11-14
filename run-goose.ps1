[CmdletBinding()]
param(
    [ValidateSet("auto", "adb", "ui")]
    [string]$Mode,
    [string]$AdbPath,
    [string]$Serial,
    [string]$WindowTitle,
    [Nullable[int]]$Cycles,
    [Nullable[int]]$IntervalMs,
    [string]$ConfigPath
)

$ErrorActionPreference = "Stop"

$parameters = @{}
foreach ($name in $PSBoundParameters.Keys) {
    $parameters[$name] = $PSBoundParameters[$name]
}
if (-not $parameters.ContainsKey("ConfigPath")) {
    $parameters.ConfigPath = Join-Path $PSScriptRoot "config.json"
}

# Windows PowerShell 5.1 treats a UTF-8 file without BOM as an ANSI file.
# Read the localized implementation explicitly as UTF-8 before parsing it.
$implementationPath = Join-Path $PSScriptRoot "shake-goose.ps1"
$source = Get-Content -LiteralPath $implementationPath -Raw -Encoding UTF8
$implementation = [ScriptBlock]::Create($source)
& $implementation @parameters
exit $LASTEXITCODE
