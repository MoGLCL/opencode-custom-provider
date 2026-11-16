<#
.SYNOPSIS
  Installs or uninstalls the Custom Provider GUI plugin for OpenCode Desktop & CLI.

.EXAMPLE
  .\install.ps1
  .\install.ps1 -Uninstall
  .\install.ps1 -ConfigDir "D:\custom\.config\opencode" -Quiet
#>
[CmdletBinding()]
param(
  [string]$ConfigDir = "",
  [switch]$Uninstall,
  [switch]$Quiet,
  [switch]$RestartOpenCode
)

$ErrorActionPreference = "Stop"

try {
  [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
} catch {
  # Non-interactive host may disallow changing OutputEncoding
}

function Write-Info([string]$msg) {
  if (-not $Quiet) { Write-Host $msg }
}

function Write-Ok([string]$msg) {
  if (-not $Quiet) { Write-Host $msg -ForegroundColor Green }
}

function Write-Warn([string]$msg) {
  if (-not $Quiet) { Write-Host $msg -ForegroundColor Yellow }
}

function Resolve-OpenCodeConfigDir([string]$ExplicitDir) {
  $userHome = if ($env:USERPROFILE) { $env:USERPROFILE } else { $HOME }
  if ($ExplicitDir -and $ExplicitDir.Trim()) {
    return [System.IO.Path]::GetFullPath($ExplicitDir.Trim())
  }
  if ($env:OPENCODE_CONFIG_DIR -and $env:OPENCODE_CONFIG_DIR.Trim()) {
    return [System.IO.Path]::GetFullPath($env:OPENCODE_CONFIG_DIR.Trim())
  }
  if ($env:XDG_CONFIG_HOME -and $env:XDG_CONFIG_HOME.Trim()) {
    return Join-Path ([System.IO.Path]::GetFullPath($env:XDG_CONFIG_HOME.Trim())) "opencode"
  }
  return Join-Path (Join-Path $userHome ".config") "opencode"
}

function Find-OpenCodeDesktopExe {
  try {
    $running = Get-Process -Name "OpenCode" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($running -and $running.Path -and (Test-Path -LiteralPath $running.Path)) {
      return $running.Path
    }
  } catch {
    # Ignore restricted process path inspection
  }
  if ($env:LOCALAPPDATA) {
    $defaultExe = Join-Path $env:LOCALAPPDATA "Programs\@opencode-aidesktop\OpenCode.exe"
    if (Test-Path -LiteralPath $defaultExe) {
      return $defaultExe
    }
  }
  return $null
}

$OpenCodeConfigDir = Resolve-OpenCodeConfigDir -ExplicitDir $ConfigDir
$PluginsDir = Join-Path $OpenCodeConfigDir "plugins"
$TargetDir = Join-Path $PluginsDir "custom-provider"

Write-Info ""
Write-Info "===================================================="
Write-Info "  OpenCode Custom Provider Plugin Installer"
Write-Info "===================================================="
Write-Info "Config dir : $OpenCodeConfigDir"
Write-Info "Target dir : $TargetDir"
Write-Info ""

if ($Uninstall) {
  if (Test-Path -LiteralPath $TargetDir) {
    Remove-Item -LiteralPath $TargetDir -Recurse -Force
    Write-Ok "[OK] Uninstalled custom-provider plugin from:"
    Write-Ok "     $TargetDir"
  } else {
    Write-Warn "[INFO] Plugin is not installed at: $TargetDir"
  }

  $runningProcs = Get-Process -Name "OpenCode", "opencode-cli" -ErrorAction SilentlyContinue
  if ($runningProcs) {
    Write-Warn ""
    Write-Warn "OpenCode is currently running. Restart it (Quit from System Tray) to apply removal."
  }
  exit 0
}

# Locate source plugin directory (.\plugin or script root)
$PluginSrcDir = $null
foreach ($candidate in @((Join-Path $PSScriptRoot "plugin"), $PSScriptRoot)) {
  if (Test-Path -LiteralPath (Join-Path $candidate "gui-experimental.cjs")) {
    $PluginSrcDir = $candidate
    break
  }
}

$RequiredFiles = @("package.json", "index.js", "gui-experimental.cjs")
if (-not $PluginSrcDir) {
  throw "Could not find plugin files (package.json, index.js, gui-experimental.cjs) next to install.ps1. If you opened a ZIP file without extracting it, extract all files first and try again."
}

foreach ($file in $RequiredFiles) {
  $srcFile = Join-Path $PluginSrcDir $file
  if (-not (Test-Path -LiteralPath $srcFile)) {
    throw "Required plugin file missing: $srcFile"
  }
  if ((Get-Item -LiteralPath $srcFile).Length -le 0) {
    throw "Required plugin file is empty: $srcFile"
  }
}

$pkgMeta = Get-Content -LiteralPath (Join-Path $PluginSrcDir "package.json") -Raw -Encoding UTF8 | ConvertFrom-Json
$pluginVersion = if ($pkgMeta.version) { [string]$pkgMeta.version } else { "1.0.0" }
$isUpgrade = Test-Path -LiteralPath $TargetDir

New-Item -ItemType Directory -Path $TargetDir -Force | Out-Null

foreach ($file in $RequiredFiles) {
  $srcFile = Join-Path $PluginSrcDir $file
  $dstFile = Join-Path $TargetDir $file
  Copy-Item -LiteralPath $srcFile -Destination $dstFile -Force
  try {
    Unblock-File -LiteralPath $dstFile -ErrorAction SilentlyContinue
  } catch {
    # Non-fatal if filesystem doesn't support Zone.Identifier streams
  }
}

# Clean up any accidental non-standard files left inside TargetDir? Keep user edits minimal; just verify required files.
foreach ($file in $RequiredFiles) {
  $dstFile = Join-Path $TargetDir $file
  $srcLen = (Get-Item -LiteralPath (Join-Path $PluginSrcDir $file)).Length
  if (-not (Test-Path -LiteralPath $dstFile)) {
    throw "Verification failed: missing copied file $dstFile"
  }
  $dstLen = (Get-Item -LiteralPath $dstFile).Length
  if ($dstLen -ne $srcLen) {
    throw "Verification failed: size mismatch for $file (expected $srcLen, got $dstLen)"
  }
}

$actionWord = if ($isUpgrade) { "Updated" } else { "Installed" }
Write-Ok "[OK] $actionWord Custom Provider plugin v$pluginVersion"
Write-Ok "     Location: $TargetDir"

# Check if user's opencode config defines a conflicting explicit custom-provider path
foreach ($cfgName in @("opencode.jsonc", "opencode.json")) {
  $cfgPath = Join-Path $OpenCodeConfigDir $cfgName
  if (Test-Path -LiteralPath $cfgPath) {
    $rawCfg = Get-Content -LiteralPath $cfgPath -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
    if ($rawCfg -and ($rawCfg -match '"plugin"\s*:') -and ($rawCfg -match 'custom-provider') -and ($rawCfg -notmatch 'plugins[/\\]+custom-provider')) {
      Write-Warn ""
      Write-Warn "[NOTE] Found an explicit custom-provider entry in $cfgPath."
      Write-Warn "       If the old version still loads, remove the stale path from the `"plugin`" array."
    }
    break
  }
}

$desktopExe = Find-OpenCodeDesktopExe
$runningOpenCode = Get-Process -Name "OpenCode", "opencode-cli" -ErrorAction SilentlyContinue

if ($runningOpenCode) {
  $shouldRestart = [bool]$RestartOpenCode
  if (-not $shouldRestart -and -not $Quiet -and [Environment]::UserInteractive -and -not [Console]::IsInputRedirected) {
    Write-Info ""
    $answer = Read-Host "OpenCode is currently running. Restart OpenCode Desktop now to load the plugin? [y/N]"
    if ($answer -match '^(y|yes)$') {
      $shouldRestart = $true
    }
  }

  if ($shouldRestart) {
    Write-Info "Stopping running OpenCode processes..."
    Get-Process -Name "OpenCode", "opencode-cli" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 1200
    if ($desktopExe -and (Test-Path -LiteralPath $desktopExe)) {
      Write-Info "Starting OpenCode Desktop..."
      Start-Process -FilePath $desktopExe | Out-Null
      Write-Ok "[OK] OpenCode Desktop restarted!"
    } else {
      Write-Ok "[OK] Stopped background OpenCode processes. Launch OpenCode again to activate."
    }
  } else {
    Write-Warn ""
    Write-Warn "IMPORTANT: OpenCode is currently running."
    Write-Warn "To activate the plugin, completely QUIT OpenCode Desktop"
    Write-Warn "(right-click the OpenCode icon in the System Tray -> Quit) and reopen it."
  }
} else {
  Write-Info ""
  if ($desktopExe) {
    Write-Info "Next step: Open OpenCode Desktop -> Settings -> Custom Providers"
  } else {
    Write-Info "Next step: Open OpenCode -> Settings -> Custom Providers"
  }
}

Write-Info ""
Write-Info "Features available after opening OpenCode:"
Write-Info "  - Settings -> Custom Providers (add, edit, delete, import JSON)"
Write-Info "  - Auto-discover models via Test & Fetch Models"
Write-Info "  - Supports OpenAI Chat/Responses, Anthropic Messages, Gemini & custom endpoints"
Write-Info ""
exit 0
