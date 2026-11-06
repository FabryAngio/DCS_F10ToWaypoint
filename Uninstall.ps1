[CmdletBinding(SupportsShouldProcess)]
param([string]$SavedGamesDcs)

# Copyright (c) 2026 FabryAngio. All rights reserved. See LICENSE.
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($SavedGamesDcs)) {
    $profilePath = if ($env:USERPROFILE) { $env:USERPROFILE } else { [Environment]::ExpandEnvironmentVariables('%USERPROFILE%') }
    $SavedGamesDcs = @(
        (Join-Path $profilePath 'Saved Games\DCS'),
        (Join-Path $profilePath 'Saved Games\DCS.openbeta')
    ) | Where-Object { Test-Path -LiteralPath $_ -PathType Container } | Select-Object -First 1
    if (-not $SavedGamesDcs) { throw 'Saved Games\DCS was not found.' }
} elseif (-not (Test-Path -LiteralPath $SavedGamesDcs -PathType Container)) {
    throw "DCS Saved Games folder not found: $SavedGamesDcs"
}
if (Get-Process -Name DCS -ErrorAction SilentlyContinue) {
    throw 'DCS is running. Close it completely and run the uninstaller again.'
}

$scripts = Join-Path $SavedGamesDcs 'Scripts'
$exportLua = Join-Path $scripts 'Export.lua'
$backupDir = Join-Path $scripts 'F10W-Backups'
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
function Backup-File([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return }
    New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
    Copy-Item -LiteralPath $Path -Destination (Join-Path $backupDir ("{0}.{1}.bak" -f [IO.Path]::GetFileName($Path), $stamp)) -Force
}

if (Test-Path -LiteralPath $exportLua -PathType Leaf) {
    $existing = Get-Content -LiteralPath $exportLua -Raw
    $updated = [regex]::Replace($existing, '(?m)^.*(?:F10W|M2W|DWA)-MANAGED.*(?:\r?\n)?', '')
    if ($updated -ne $existing -and $PSCmdlet.ShouldProcess($exportLua, 'Remove only the managed loader line')) {
        Backup-File $exportLua
        [IO.File]::WriteAllText($exportLua, $updated, [Text.UTF8Encoding]::new($false))
    }
}

$files = @(
    (Join-Path $scripts 'Hooks\DCS_F10ToWaypointGameGUI.lua'),
    (Join-Path $scripts 'Hooks\DCS_MarkerToWaypointGameGUI.lua'),
    (Join-Path $scripts 'Hooks\DynamicWaypointAvionicsGameGUI.lua')
)
$directories = @(
    (Join-Path $scripts 'DCS_F10ToWaypoint'),
    (Join-Path $scripts 'DCS_MarkerToWaypoint'),
    (Join-Path $scripts 'DynamicWaypointAvionics')
)
foreach ($path in $files) {
    if ((Test-Path -LiteralPath $path -PathType Leaf) -and $PSCmdlet.ShouldProcess($path, 'Remove installed hook')) {
        Remove-Item -LiteralPath $path -Force
    }
}
foreach ($path in $directories) {
    if ((Test-Path -LiteralPath $path -PathType Container) -and $PSCmdlet.ShouldProcess($path, 'Remove installed script directory')) {
        Remove-Item -LiteralPath $path -Recurse -Force
    }
}

if ($WhatIfPreference) {
    Write-Host 'Preview completed: no files were removed.'
} else {
    Write-Host 'DCS F10 To Waypoint was removed. Export.lua backups were preserved.'
}
