[CmdletBinding(SupportsShouldProcess)]
param([string]$SavedGamesDcs)

# Copyright (c) 2026 FabryAngio. All rights reserved. See LICENSE.
$ErrorActionPreference = 'Stop'
$Product = 'DCS F10 To Waypoint'
$Version = '1.1.0'

if ([string]::IsNullOrWhiteSpace($SavedGamesDcs)) {
    $profilePath = if ($env:USERPROFILE) { $env:USERPROFILE } else { [Environment]::ExpandEnvironmentVariables('%USERPROFILE%') }
    $SavedGamesDcs = @(
        (Join-Path $profilePath 'Saved Games\DCS'),
        (Join-Path $profilePath 'Saved Games\DCS.openbeta')
    ) | Where-Object { Test-Path -LiteralPath $_ -PathType Container } | Select-Object -First 1
    if (-not $SavedGamesDcs) {
        throw 'Saved Games\DCS was not found. Run DCS once or pass -SavedGamesDcs with the correct path.'
    }
} elseif (-not (Test-Path -LiteralPath $SavedGamesDcs -PathType Container)) {
    throw "DCS Saved Games folder not found: $SavedGamesDcs"
}

if (Get-Process -Name DCS -ErrorAction SilentlyContinue) {
    throw 'DCS is running. Close it completely and run the installer again.'
}

$sourceBridge = Join-Path $PSScriptRoot 'dcs\DCS_F10ToWaypoint.lua'
$sourceHook = Join-Path $PSScriptRoot 'dcs\DCS_F10ToWaypointGameGUI.lua'
foreach ($source in @($sourceBridge, $sourceHook)) {
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
        throw "Required file not found: $source. Extract the complete release archive first."
    }
}

$scripts = Join-Path $SavedGamesDcs 'Scripts'
$hooks = Join-Path $scripts 'Hooks'
$destinationDir = Join-Path $scripts 'DCS_F10ToWaypoint'
$destinationBridge = Join-Path $destinationDir 'DCS_F10ToWaypoint.lua'
$destinationHook = Join-Path $hooks 'DCS_F10ToWaypointGameGUI.lua'
$exportLua = Join-Path $scripts 'Export.lua'
$configDir = Join-Path $SavedGamesDcs 'Config'
$autoexecCfg = Join-Path $configDir 'autoexec.cfg'
$backupDir = Join-Path $scripts 'F10W-Backups'
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
$loader = 'pcall(function() local lfs=require("lfs"); dofile(lfs.writedir()..[[Scripts\DCS_F10ToWaypoint\DCS_F10ToWaypoint.lua]]) end) -- F10W-MANAGED'

function Backup-File([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return }
    New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
    $name = '{0}.{1}.bak' -f [IO.Path]::GetFileName($Path), $stamp
    Copy-Item -LiteralPath $Path -Destination (Join-Path $backupDir $name) -Force
}

if ($PSCmdlet.ShouldProcess($destinationDir, "Install $Product $Version")) {
    New-Item -ItemType Directory -Path $destinationDir -Force | Out-Null
    Backup-File $destinationBridge
    Copy-Item -LiteralPath $sourceBridge -Destination $destinationBridge -Force
}
if ($PSCmdlet.ShouldProcess($destinationHook, 'Install the in-game overlay')) {
    New-Item -ItemType Directory -Path $hooks -Force | Out-Null
    Backup-File $destinationHook
    Copy-Item -LiteralPath $sourceHook -Destination $destinationHook -Force
}

# Migrate older names without leaving two hooks or two Export bridges active.
$legacyFiles = @(
    (Join-Path $scripts 'Hooks\DCS_MarkerToWaypointGameGUI.lua'),
    (Join-Path $scripts 'Hooks\DynamicWaypointAvionicsGameGUI.lua'),
    (Join-Path $scripts 'DCS_MarkerToWaypoint\DCS_MarkerToWaypoint.lua'),
    (Join-Path $scripts 'DynamicWaypointAvionics\DynamicWaypointAvionics.lua')
)
foreach ($path in $legacyFiles) {
    if (Test-Path -LiteralPath $path -PathType Leaf) { Backup-File $path }
}
$legacyDirectories = @(
    (Join-Path $scripts 'DCS_MarkerToWaypoint'),
    (Join-Path $scripts 'DynamicWaypointAvionics')
)
foreach ($path in $legacyFiles) {
    if ((Test-Path -LiteralPath $path -PathType Leaf) -and $PSCmdlet.ShouldProcess($path, 'Remove superseded file')) {
        Remove-Item -LiteralPath $path -Force
    }
}
foreach ($path in $legacyDirectories) {
    if ((Test-Path -LiteralPath $path -PathType Container) -and $PSCmdlet.ShouldProcess($path, 'Remove superseded directory')) {
        Remove-Item -LiteralPath $path -Recurse -Force
    }
}

$existingExport = if (Test-Path -LiteralPath $exportLua) { Get-Content -LiteralPath $exportLua -Raw } else { '' }
$updatedExport = [regex]::Replace($existingExport, '(?m)^.*(?:F10W|M2W|DWA)-MANAGED.*(?:\r?\n)?', '')
$updatedExport = $updatedExport.TrimEnd("`r", "`n")
if ($updatedExport.Length -gt 0) { $updatedExport += "`r`n" }
$updatedExport += "$loader`r`n"
if ($updatedExport -ne $existingExport -and $PSCmdlet.ShouldProcess($exportLua, 'Update only the managed loader line')) {
    New-Item -ItemType Directory -Path $scripts -Force | Out-Null
    Backup-File $exportLua
    [IO.File]::WriteAllText($exportLua, $updatedExport, [Text.UTF8Encoding]::new($false))
}

# The overlay needs only the local userhooks API. Mission/scripting access is not used.
$existingAutoexec = if (Test-Path -LiteralPath $autoexecCfg) { Get-Content -LiteralPath $autoexecCfg -Raw } else { '' }
$updatedAutoexec = $existingAutoexec
# Previous releases added exactly this two-state permission for their marker
# reader. Remove that legacy assignment during migration; preserve any custom
# allow_dostring_in list containing additional values.
$updatedAutoexec = [regex]::Replace($updatedAutoexec,
    '(?m)^\s*net\.allow_dostring_in\s*=\s*\{\s*["'']mission["'']\s*,\s*["'']scripting["'']\s*\}\s*(?:--.*)?\r?\n?', '')
if ($updatedAutoexec -match '(?m)^\s*net\.allow_unsafe_api\s*=\s*\{[^}]*\}') {
    $updatedAutoexec = [regex]::Replace($updatedAutoexec, '(?m)^(\s*net\.allow_unsafe_api\s*=\s*\{)([^}]*)(\})', {
        param($match)
        if ($match.Groups[2].Value -match '["'']userhooks["'']') { return $match.Value }
        $values = $match.Groups[2].Value.Trim()
        if ($values.Length -gt 0 -and -not $values.EndsWith(',')) { $values += ',' }
        return $match.Groups[1].Value + $values + ' "userhooks" ' + $match.Groups[3].Value
    }, 1)
} else {
    if ($updatedAutoexec.Length -gt 0 -and -not $updatedAutoexec.EndsWith("`n")) { $updatedAutoexec += "`r`n" }
    $updatedAutoexec += "if not net then net = {} end`r`nnet.allow_unsafe_api = { `"userhooks`" }`r`n"
}
if ($updatedAutoexec -ne $existingAutoexec -and $PSCmdlet.ShouldProcess($autoexecCfg, 'Allow the local DCS user hook')) {
    New-Item -ItemType Directory -Path $configDir -Force | Out-Null
    Backup-File $autoexecCfg
    [IO.File]::WriteAllText($autoexecCfg, $updatedAutoexec, [Text.UTF8Encoding]::new($false))
}

if ($WhatIfPreference) {
    Write-Host 'Preview completed: no files were modified.'
} else {
    Write-Host "$Product $Version installed in: $SavedGamesDcs"
    Write-Host 'Start DCS, enter a supported aircraft, and press Ctrl+Shift+M to open the overlay.'
    Write-Host 'Then open F10: Left Alt + left click the desired point and press COPY to see it appear immediately.'
}
