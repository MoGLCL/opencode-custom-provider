<#
.SYNOPSIS
  Native Dark-Mode WPF GUI Installer & Universal Provider Configurator for OpenCode Custom Provider.
#>
[CmdletBinding()]
param(
  [string]$ConfigDir = "",
  [ValidateSet("Install", "Uninstall", "Setup")]
  [string]$InitialTab = "Install"
)

$ErrorActionPreference = "Stop"

try {
  Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms
} catch {
  [System.Windows.Forms.MessageBox]::Show(
    "Failed to initialize WPF UI: $($_.Exception.Message)",
    "OpenCode Custom Provider Installer",
    [System.Windows.Forms.MessageBoxButtons]::OK,
    [System.Windows.Forms.MessageBoxIcon]::Error
  ) | Out-Null
  exit 1
}

try {
  $tlsFlags = [System.Net.SecurityProtocolType]::Tls12
  try {
    $tlsFlags = $tlsFlags -bor ([Enum]::Parse([System.Net.SecurityProtocolType], "Tls13"))
  } catch { }
  [System.Net.ServicePointManager]::SecurityProtocol = $tlsFlags
} catch { }

# ---------------------------------------------------------------------------
# Helpers: Paths, OpenCode Version Detection, JSONC & Config Persistence
# ---------------------------------------------------------------------------

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
  } catch { }
  if ($env:LOCALAPPDATA) {
    $candidates = @(
      (Join-Path $env:LOCALAPPDATA "Programs\@opencode-aidesktop\OpenCode.exe"),
      (Join-Path $env:LOCALAPPDATA "Programs\OpenCode\OpenCode.exe")
    )
    foreach ($c in $candidates) {
      if (Test-Path -LiteralPath $c) { return $c }
    }
  }
  return $null
}

function Read-VersionFromAsar([string]$AsarPath) {
  if (-not $AsarPath -or -not (Test-Path -LiteralPath $AsarPath)) { return $null }
  $fs = $null
  $br = $null
  try {
    $fs = [System.IO.File]::OpenRead($AsarPath)
    $br = New-Object System.IO.BinaryReader($fs)
    $hdr = $br.ReadBytes(16)
    if ($hdr.Length -lt 16) { return $null }
    $headerSize = [BitConverter]::ToUInt32($hdr, 4) + 8
    $jsonLen = [BitConverter]::ToUInt32($hdr, 12)
    if ($jsonLen -gt 32MB) { return $null }
    $jsonBytes = $br.ReadBytes([int]$jsonLen)
    $tree = [System.Text.Encoding]::UTF8.GetString($jsonBytes) | ConvertFrom-Json
    $pkgNode = $tree.files.'package.json'
    if (-not $pkgNode) { return $null }
    $offset = [int64]$headerSize + [int64]$pkgNode.offset
    $size = [int]$pkgNode.size
    if ($size -le 0 -or $size -gt 2MB) { return $null }
    $fs.Position = $offset
    $pkgBytes = $br.ReadBytes($size)
    $pkg = [System.Text.Encoding]::UTF8.GetString($pkgBytes) | ConvertFrom-Json
    return [string]$pkg.version
  } catch {
    return $null
  } finally {
    if ($br) { $br.Dispose() }
    if ($fs) { $fs.Dispose() }
  }
}

function Get-OpenCodeVersionInfo([string]$DesktopExe) {
  $verStr = $null
  if ($DesktopExe) {
    $asarPath = Join-Path (Split-Path -Parent $DesktopExe) "resources\app.asar"
    $verStr = Read-VersionFromAsar $asarPath
    if (-not $verStr) {
      try {
        $fvi = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($DesktopExe)
        if ($fvi.ProductVersion) { $verStr = $fvi.ProductVersion.Trim() }
      } catch { }
    }
  }
  if (-not $verStr -and $env:APPDATA) {
    $cliRoot = Join-Path $env:APPDATA "ai.opencode.desktop\cli"
    if (Test-Path -LiteralPath $cliRoot) {
      $dirs = Get-ChildItem -LiteralPath $cliRoot -Directory -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending
      foreach ($d in $dirs) {
        if ($d.Name -match '^(\d+\.\d+\.\d+)') {
          $verStr = $Matches[1]
          break
        }
      }
    }
  }
  if (-not $verStr) {
    try {
      $cmd = Get-Command "opencode" -ErrorAction SilentlyContinue
      if ($cmd) {
        $out = & $cmd.Source --version 2>$null
        if ($out -match '(\d+\.\d+\.\d+)') { $verStr = $Matches[1] }
      }
    } catch { }
  }

  $parsed = $null
  if ($verStr -and ($verStr -match '(\d+)\.(\d+)\.(\d+)')) {
    $parsed = [version]::new([int]$Matches[1], [int]$Matches[2], [int]$Matches[3])
  }
  return [pscustomobject]@{
    RawVersion = $verStr
    Parsed     = $parsed
    DesktopExe = $DesktopExe
    SupportsGuiPlugin = if ($parsed) { $parsed -ge [version]"2.2.0" } else { $null }
    IsLegacyV1        = if ($parsed) { $parsed.Major -lt 2 } else { $false }
  }
}

function Strip-Jsonc([string]$RawText) {
  if ([string]::IsNullOrWhiteSpace($RawText)) { return "{}" }
  $sb = New-Object System.Text.StringBuilder($RawText.Length)
  $inStr = $false
  $esc = $false
  $i = 0
  $len = $RawText.Length
  while ($i -lt $len) {
    $ch = $RawText[$i]
    $next = if ($i + 1 -lt $len) { $RawText[$i + 1] } else { [char]0 }
    if ($inStr) {
      [void]$sb.Append($ch)
      if ($esc) { $esc = $false }
      elseif ($ch -eq '\') { $esc = $true }
      elseif ($ch -eq '"') { $inStr = $false }
      $i++
      continue
    }
    if ($ch -eq '"') {
      $inStr = $true
      [void]$sb.Append($ch)
      $i++
      continue
    }
    if ($ch -eq '/' -and $next -eq '/') {
      $i += 2
      while ($i -lt $len -and $RawText[$i] -ne "`n") { $i++ }
      continue
    }
    if ($ch -eq '/' -and $next -eq '*') {
      $i += 2
      while ($i + 1 -lt $len -and -not ($RawText[$i] -eq '*' -and $RawText[$i + 1] -eq '/')) { $i++ }
      $i += 2
      continue
    }
    [void]$sb.Append($ch)
    $i++
  }

  $stripped = $sb.ToString()
  $out = New-Object System.Text.StringBuilder($stripped.Length)
  $inStr = $false
  $esc = $false
  $sLen = $stripped.Length
  for ($i = 0; $i -lt $sLen; $i++) {
    $ch = $stripped[$i]
    if ($inStr) {
      [void]$out.Append($ch)
      if ($esc) { $esc = $false }
      elseif ($ch -eq '\') { $esc = $true }
      elseif ($ch -eq '"') { $inStr = $false }
      continue
    }
    if ($ch -eq '"') {
      $inStr = $true
      [void]$out.Append($ch)
      continue
    }
    if ($ch -eq ',') {
      $j = $i + 1
      while ($j -lt $sLen -and [char]::IsWhiteSpace($stripped[$j])) { $j++ }
      if ($j -lt $sLen -and ($stripped[$j] -eq '}' -or $stripped[$j] -eq ']')) {
        continue
      }
    }
    [void]$out.Append($ch)
  }
  $res = $out.ToString().Trim()
  if (-not $res) { return "{}" }
  return $res
}

function ConvertTo-OrderedHashtable($Obj) {
  if ($null -eq $Obj) { return $null }
  if ($Obj -is [System.Collections.IDictionary]) {
    $ht = [ordered]@{}
    foreach ($k in $Obj.Keys) { $ht[$k] = ConvertTo-OrderedHashtable $Obj[$k] }
    return $ht
  }
  if ($Obj -is [pscustomobject]) {
    $ht = [ordered]@{}
    foreach ($p in $Obj.PSObject.Properties) { $ht[$p.Name] = ConvertTo-OrderedHashtable $p.Value }
    return $ht
  }
  if ($Obj -is [System.Collections.IEnumerable] -and -not ($Obj -is [string])) {
    $list = New-Object System.Collections.ArrayList
    foreach ($item in $Obj) { [void]$list.Add((ConvertTo-OrderedHashtable $item)) }
    return ,$list
  }
  return $Obj
}

function Resolve-ConfigFilePath([string]$CfgDir) {
  $jsonc = Join-Path $CfgDir "opencode.jsonc"
  $json = Join-Path $CfgDir "opencode.json"
  if (Test-Path -LiteralPath $jsonc) { return $jsonc }
  if (Test-Path -LiteralPath $json) { return $json }
  return $jsonc
}

function Read-OpenCodeConfig([string]$FilePath) {
  if (-not (Test-Path -LiteralPath $FilePath)) {
    return [ordered]@{ '$schema' = "https://opencode.ai/config.json" }
  }
  $raw = Get-Content -LiteralPath $FilePath -Raw -Encoding UTF8
  if ([string]::IsNullOrWhiteSpace($raw)) {
    return [ordered]@{ '$schema' = "https://opencode.ai/config.json" }
  }
  $cleanJson = Strip-Jsonc $raw
  $parsed = $cleanJson | ConvertFrom-Json
  return ConvertTo-OrderedHashtable $parsed
}

function Write-OpenCodeConfig([string]$FilePath, $CfgObj) {
  $dir = Split-Path -Parent $FilePath
  if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
  if (-not $CfgObj.Contains('$schema')) { $CfgObj['$schema'] = "https://opencode.ai/config.json" }
  $json = ($CfgObj | ConvertTo-Json -Depth 20) + "`n"
  $tmp = "$FilePath.$PID.$([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()).tmp"
  [System.IO.File]::WriteAllText($tmp, $json, [System.Text.UTF8Encoding]::new($false))
  Move-Item -LiteralPath $tmp -Destination $FilePath -Force
}

function Parse-TokenInput([string]$RawVal) {
  $s = ($RawVal -replace ',', '').Trim().ToLowerInvariant()
  if (-not $s) { return $null }
  if ($s -match '^(\d+(?:\.\d+)?)\s*([km])?$') {
    $base = [double]$Matches[1]
    if ($base -le 0) { return $null }
    $mult = switch ($Matches[2]) {
      "m" { 1000000 }
      "k" { 1000 }
      default { 1 }
    }
    return [int][Math]::Truncate($base * $mult)
  }
  return $null
}

function Slugify-ProviderId([string]$Val) {
  $s = ([string]$Val).Trim().ToLowerInvariant()
  $s = $s -replace '[^a-z0-9._-]+', '-'
  return $s.Trim('-')
}

function Normalize-BaseUrl([string]$RawUrl) {
  $clean = ([string]$RawUrl).Trim().TrimEnd('/')
  if (-not $clean) { return "" }
  $clean = $clean -replace '/(?:chat/completions|responses|messages|models)$', ''
  return $clean.TrimEnd('/')
}

function Resolve-PluginSourceDir {
  foreach ($cand in @((Join-Path $PSScriptRoot "plugin"), $PSScriptRoot)) {
    if (Test-Path -LiteralPath (Join-Path $cand "gui-experimental.cjs")) {
      return $cand
    }
  }
  return $null
}

# ---------------------------------------------------------------------------
# Protocol Presets for Direct Config Setup
# ---------------------------------------------------------------------------

$ProtocolPresets = @(
  [pscustomobject]@{ Id = "openai-compatible"; Label = "OpenAI Compatible (Chat Completions)"; PkgV2 = "@opencode/ai/providers/openai-compatible"; PkgV1 = "@ai-sdk/openai-compatible" },
  [pscustomobject]@{ Id = "openai-compatible-responses"; Label = "OpenAI Compatible (Responses API)"; PkgV2 = "@opencode/ai/providers/openai-compatible/responses"; PkgV1 = "@ai-sdk/openai-compatible" },
  [pscustomobject]@{ Id = "anthropic"; Label = "Anthropic Compatible (Messages API)"; PkgV2 = "@opencode/ai/providers/anthropic"; PkgV1 = "@ai-sdk/anthropic" },
  [pscustomobject]@{ Id = "openai"; Label = "OpenAI Official Format"; PkgV2 = "@opencode/ai/providers/openai"; PkgV1 = "@ai-sdk/openai" },
  [pscustomobject]@{ Id = "google"; Label = "Google Gemini Compatible"; PkgV2 = "@opencode/ai/providers/google"; PkgV1 = "@ai-sdk/google" }
)

# ---------------------------------------------------------------------------
# WPF XAML Dark UI
# ---------------------------------------------------------------------------

[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="OpenCode Custom Provider - Installer &amp; Configurator"
        Width="860" Height="700" MinWidth="740" MinHeight="580"
        WindowStartupLocation="CenterScreen"
        Background="#0D1117" Foreground="#E6EDF3"
        UseLayoutRounding="True" SnapsToDevicePixels="True"
        FontFamily="Segoe UI">
  <Window.Resources>
    <Style TargetType="TextBox">
      <Setter Property="Background" Value="#161B22"/>
      <Setter Property="Foreground" Value="#E6EDF3"/>
      <Setter Property="CaretBrush" Value="#58A6FF"/>
      <Setter Property="BorderBrush" Value="#30363D"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="8,6"/>
      <Setter Property="FontSize" Value="12.5"/>
      <Setter Property="VerticalContentAlignment" Value="Center"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TextBox">
            <Border Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="6">
              <ScrollViewer x:Name="PART_ContentHost" Margin="2,0"/>
            </Border>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="PasswordBox">
      <Setter Property="Background" Value="#161B22"/>
      <Setter Property="Foreground" Value="#E6EDF3"/>
      <Setter Property="CaretBrush" Value="#58A6FF"/>
      <Setter Property="BorderBrush" Value="#30363D"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="8,6"/>
      <Setter Property="FontSize" Value="12.5"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="PasswordBox">
            <Border Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="6">
              <ScrollViewer x:Name="PART_ContentHost" Margin="2,0"/>
            </Border>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="CheckBox">
      <Setter Property="Foreground" Value="#E6EDF3"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="VerticalContentAlignment" Value="Center"/>
    </Style>
    <Style TargetType="ComboBox">
      <Setter Property="Background" Value="#161B22"/>
      <Setter Property="Foreground" Value="#E6EDF3"/>
      <Setter Property="BorderBrush" Value="#30363D"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="8,5"/>
      <Setter Property="FontSize" Value="12.5"/>
    </Style>
    <Style TargetType="ComboBoxItem">
      <Setter Property="Background" Value="#161B22"/>
      <Setter Property="Foreground" Value="#E6EDF3"/>
      <Setter Property="Padding" Value="8,6"/>
      <Style.Triggers>
        <Trigger Property="IsHighlighted" Value="True">
          <Setter Property="Background" Value="#263040"/>
          <Setter Property="Foreground" Value="#FFFFFF"/>
        </Trigger>
      </Style.Triggers>
    </Style>
    <Style x:Key="BtnBase" TargetType="Button">
      <Setter Property="Foreground" Value="#E6EDF3"/>
      <Setter Property="Background" Value="#21262D"/>
      <Setter Property="BorderBrush" Value="#30363D"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="12,7"/>
      <Setter Property="FontSize" Value="12.5"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bd" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="6" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bd" Property="Opacity" Value="0.88"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter TargetName="bd" Property="Opacity" Value="0.45"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="BtnPrimary" BasedOn="{StaticResource BtnBase}" TargetType="Button">
      <Setter Property="Background" Value="#238636"/>
      <Setter Property="BorderBrush" Value="#2EA043"/>
      <Setter Property="Foreground" Value="#FFFFFF"/>
    </Style>
    <Style x:Key="BtnBlue" BasedOn="{StaticResource BtnBase}" TargetType="Button">
      <Setter Property="Background" Value="#1F6FEB"/>
      <Setter Property="BorderBrush" Value="#388BFD"/>
      <Setter Property="Foreground" Value="#FFFFFF"/>
    </Style>
    <Style x:Key="BtnDanger" BasedOn="{StaticResource BtnBase}" TargetType="Button">
      <Setter Property="Background" Value="#301A1D"/>
      <Setter Property="BorderBrush" Value="#F85149"/>
      <Setter Property="Foreground" Value="#FF7B72"/>
    </Style>
    <Style x:Key="BtnChip" BasedOn="{StaticResource BtnBase}" TargetType="Button">
      <Setter Property="Padding" Value="8,4"/>
      <Setter Property="FontSize" Value="11"/>
      <Setter Property="FontWeight" Value="Normal"/>
    </Style>
    <Style TargetType="TabItem">
      <Setter Property="Foreground" Value="#8B949E"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TabItem">
            <Border x:Name="tabBd" Background="#161B22" BorderBrush="#30363D" BorderThickness="1,1,1,0" CornerRadius="6,6,0,0" Padding="14,8" Margin="0,0,6,0" Cursor="Hand">
              <ContentPresenter ContentSource="Header"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsSelected" Value="True">
                <Setter TargetName="tabBd" Property="Background" Value="#1F2937"/>
                <Setter TargetName="tabBd" Property="BorderBrush" Value="#388BFD"/>
                <Setter Property="Foreground" Value="#FFFFFF"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>

  <Grid Margin="16">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
    </Grid.RowDefinitions>

    <!-- Header -->
    <Border Grid.Row="0" Background="#161B22" BorderBrush="#30363D" BorderThickness="1" CornerRadius="8" Padding="14,12" Margin="0,0,0,10">
      <Grid>
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <StackPanel Grid.Column="0">
          <TextBlock Text="OpenCode Custom Provider - Installer &amp; Manager" FontSize="17" FontWeight="Bold" Foreground="#F0F6FC"/>
          <TextBlock x:Name="TxtSubHeader" Text="Scanning local OpenCode installation..." FontSize="12" Foreground="#8B949E" Margin="0,3,0,0"/>
        </StackPanel>
        <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
          <Border x:Name="BadgePluginVer" Background="#21262D" BorderBrush="#30363D" BorderThickness="1" CornerRadius="5" Padding="9,4" Margin="0,0,8,0">
            <TextBlock x:Name="TxtPluginVerBadge" Text="Plugin v1.0.0" FontSize="11.5" Foreground="#79C0FF"/>
          </Border>
          <Button x:Name="BtnRefreshEnv" Style="{StaticResource BtnBase}" Content="Refresh" Padding="10,5"/>
        </StackPanel>
      </Grid>
    </Border>

    <!-- Version & Compatibility Banner -->
    <Border x:Name="CompatBanner" Grid.Row="1" Background="#141C24" BorderBrush="#388BFD" BorderThickness="1" CornerRadius="8" Padding="12,9" Margin="0,0,0,10">
      <TextBlock x:Name="TxtCompatBanner" TextWrapping="Wrap" FontSize="12.5" Foreground="#C9D1D9" Text="Checking OpenCode version..."/>
    </Border>

    <!-- Main Tabs -->
    <TabControl x:Name="MainTabs" Grid.Row="2" Background="#0D1117" BorderBrush="#30363D" BorderThickness="0,1,0,0">

      <!-- TAB 1: PLUGIN INSTALLER -->
      <TabItem x:Name="TabInstaller" Header="1. Install Desktop Plugin (v2.2+)">
        <ScrollViewer VerticalScrollBarVisibility="Auto" Padding="0,12,0,0">
          <StackPanel>
            <Border Background="#161B22" BorderBrush="#30363D" BorderThickness="1" CornerRadius="8" Padding="14" Margin="0,0,0,12">
              <StackPanel>
                <TextBlock Text="Target OpenCode Configuration Folder" FontSize="13" FontWeight="SemiBold" Foreground="#F0F6FC" Margin="0,0,0,6"/>
                <Grid Margin="0,0,0,8">
                  <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                    <ColumnDefinition Width="Auto"/>
                  </Grid.ColumnDefinitions>
                  <TextBox x:Name="TxtConfigDir" Grid.Column="0" Margin="0,0,8,0"/>
                  <Button x:Name="BtnBrowseConfig" Grid.Column="1" Style="{StaticResource BtnBase}" Content="Browse..." Margin="0,0,8,0"/>
                  <Button x:Name="BtnOpenPluginsFolder" Grid.Column="2" Style="{StaticResource BtnBase}" Content="Open Folder"/>
                </Grid>
                <TextBlock x:Name="TxtPluginDestPreview" FontSize="11.5" Foreground="#8B949E" FontFamily="Consolas"/>
                <CheckBox x:Name="ChkAutoRestart" IsChecked="True" Margin="0,10,0,0"
                          Content="Automatically restart OpenCode Desktop if running (so Settings -> Custom Providers appears immediately)"/>
              </StackPanel>
            </Border>

            <Border Background="#161B22" BorderBrush="#30363D" BorderThickness="1" CornerRadius="8" Padding="14" Margin="0,0,0,12">
              <StackPanel>
                <TextBlock Text="Plugin Actions" FontSize="13" FontWeight="SemiBold" Foreground="#F0F6FC" Margin="0,0,0,10"/>
                <WrapPanel>
                  <Button x:Name="BtnInstallPlugin" Style="{StaticResource BtnPrimary}" Content="Install / Update Plugin" Padding="18,9" Margin="0,0,10,6"/>
                  <Button x:Name="BtnUninstallPlugin" Style="{StaticResource BtnDanger}" Content="Uninstall Plugin" Padding="14,9" Margin="0,0,10,6"/>
                  <Button x:Name="BtnJumpToDirectSetup" Style="{StaticResource BtnBlue}" Content="Open Direct Provider Setup (Works on Older Versions Too)" Padding="14,9" Margin="0,0,0,6"/>
                </WrapPanel>
                <TextBlock Text="No Node.js or npm needed. Installs package.json, index.js, and gui-experimental.cjs and unblocks Windows security flags."
                           FontSize="11.5" Foreground="#8B949E" TextWrapping="Wrap" Margin="0,6,0,0"/>
              </StackPanel>
            </Border>

            <Border Background="#161B22" BorderBrush="#30363D" BorderThickness="1" CornerRadius="8" Padding="14">
              <StackPanel>
                <TextBlock Text="Installer Log" FontSize="13" FontWeight="SemiBold" Foreground="#F0F6FC" Margin="0,0,0,6"/>
                <TextBox x:Name="TxtInstallLog" IsReadOnly="True" TextWrapping="Wrap" AcceptsReturn="True"
                         Height="155" VerticalScrollBarVisibility="Auto" VerticalContentAlignment="Top"
                         Background="#0B0F14" FontFamily="Consolas" FontSize="11.5" Foreground="#A5D6FF"/>
              </StackPanel>
            </Border>
          </StackPanel>
        </ScrollViewer>
      </TabItem>

      <!-- TAB 2: UNIVERSAL DIRECT CONFIGURATOR (ALL OPENCODE VERSIONS) -->
      <TabItem x:Name="TabDirectSetup" Header="2. Direct Provider Setup (All Versions: v1.x / v2.x)">
        <ScrollViewer VerticalScrollBarVisibility="Auto" Padding="0,12,0,0">
          <StackPanel>
            <!-- Format & Load existing -->
            <Border Background="#161B22" BorderBrush="#30363D" BorderThickness="1" CornerRadius="8" Padding="12" Margin="0,0,0,10">
              <Grid>
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="1.2*"/>
                  <ColumnDefinition Width="12"/>
                  <ColumnDefinition Width="1.1*"/>
                  <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <StackPanel Grid.Column="0">
                  <TextBlock Text="Config Schema Format (Auto handles old v1.x &amp; new v2.x)" FontSize="11.5" Foreground="#8B949E" Margin="0,0,0,4"/>
                  <ComboBox x:Name="CmbSchemaMode" SelectedIndex="0">
                    <ComboBoxItem Content="Auto-Detect (Recommended)"/>
                    <ComboBoxItem Content="OpenCode V2 (providers + package + settings)"/>
                    <ComboBoxItem Content="OpenCode Legacy V1 (provider + npm + options)"/>
                  </ComboBox>
                </StackPanel>
                <StackPanel Grid.Column="2">
                  <TextBlock Text="Existing Providers in Config" FontSize="11.5" Foreground="#8B949E" Margin="0,0,0,4"/>
                  <ComboBox x:Name="CmbExistingProviders"/>
                </StackPanel>
                <StackPanel Grid.Column="3" Orientation="Horizontal" VerticalAlignment="Bottom" Margin="8,0,0,0">
                  <Button x:Name="BtnLoadProvider" Style="{StaticResource BtnBase}" Content="Load" Margin="0,0,6,0" Padding="10,6"/>
                  <Button x:Name="BtnDeleteProvider" Style="{StaticResource BtnDanger}" Content="Delete" Padding="10,6"/>
                </StackPanel>
              </Grid>
            </Border>

            <!-- Provider Connection Fields -->
            <Border Background="#161B22" BorderBrush="#30363D" BorderThickness="1" CornerRadius="8" Padding="12" Margin="0,0,0,10">
              <StackPanel>
                <Grid Margin="0,0,0,8">
                  <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="12"/>
                    <ColumnDefinition Width="*"/>
                  </Grid.ColumnDefinitions>
                  <StackPanel Grid.Column="0">
                    <TextBlock Text="Display Name" FontSize="11.5" Foreground="#8B949E" Margin="0,0,0,3"/>
                    <TextBox x:Name="TxtProvName" Text="My Proxy"/>
                  </StackPanel>
                  <StackPanel Grid.Column="2">
                    <TextBlock Text="Provider ID (slug)" FontSize="11.5" Foreground="#8B949E" Margin="0,0,0,3"/>
                    <TextBox x:Name="TxtProvId" Text="my-proxy"/>
                  </StackPanel>
                </Grid>

                <Grid Margin="0,0,0,8">
                  <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="12"/>
                    <ColumnDefinition Width="*"/>
                  </Grid.ColumnDefinitions>
                  <StackPanel Grid.Column="0">
                    <TextBlock Text="API Compatibility" FontSize="11.5" Foreground="#8B949E" Margin="0,0,0,3"/>
                    <ComboBox x:Name="CmbProtocol" SelectedIndex="0"/>
                  </StackPanel>
                  <StackPanel Grid.Column="2">
                    <TextBlock Text="Base URL (always keep /v1 if endpoint uses /v1)" FontSize="11.5" Foreground="#8B949E" Margin="0,0,0,3"/>
                    <TextBox x:Name="TxtBaseUrl" Text="https://api.example.com/v1"/>
                  </StackPanel>
                </Grid>

                <Grid>
                  <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                  </Grid.ColumnDefinitions>
                  <StackPanel Grid.Column="0">
                    <TextBlock x:Name="TxtApiKeyLabel" Text="API Key (or {env:MY_KEY})" FontSize="11.5" Foreground="#8B949E" Margin="0,0,0,3"/>
                    <PasswordBox x:Name="TxtApiKey"/>
                  </StackPanel>
                  <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Bottom" Margin="8,0,0,0">
                    <Button x:Name="BtnFetchModels" Style="{StaticResource BtnBlue}" Content="Test &amp; Fetch Models" Padding="12,7"/>
                  </StackPanel>
                </Grid>
                <TextBlock x:Name="TxtFetchStatus" FontSize="11.5" Foreground="#8B949E" Margin="0,6,0,0" TextWrapping="Wrap"/>
              </StackPanel>
            </Border>

            <!-- Models & Limits & Efforts -->
            <Border Background="#161B22" BorderBrush="#30363D" BorderThickness="1" CornerRadius="8" Padding="12" Margin="0,0,0,10">
              <StackPanel>
                <Grid Margin="0,0,0,8">
                  <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                  </Grid.ColumnDefinitions>
                  <TextBlock x:Name="TxtModelsCount" Text="Models (0)" FontSize="13" FontWeight="SemiBold" Foreground="#F0F6FC" VerticalAlignment="Center"/>
                  <StackPanel Grid.Column="1" Orientation="Horizontal">
                    <TextBox x:Name="TxtManualModelId" Width="210" Margin="0,0,6,0" ToolTip="Comma-separated model IDs"/>
                    <Button x:Name="BtnAddManualModel" Style="{StaticResource BtnBase}" Content="+ Add Model ID" Margin="0,0,6,0"/>
                    <Button x:Name="BtnRemoveSelectedModel" Style="{StaticResource BtnDanger}" Content="Remove Selected"/>
                  </StackPanel>
                </Grid>

                <ListBox x:Name="LstModels" Height="115" Background="#0B0F14" BorderBrush="#30363D" Foreground="#E6EDF3" FontFamily="Consolas" FontSize="12" Margin="0,0,0,10"/>

                <!-- Selected / Batch Limits & Efforts -->
                <Grid Margin="0,0,0,8">
                  <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="12"/>
                    <ColumnDefinition Width="*"/>
                  </Grid.ColumnDefinitions>
                  <StackPanel Grid.Column="0">
                    <TextBlock Text="Context Limit (e.g. 200000 or 1m)" FontSize="11.5" Foreground="#8B949E" Margin="0,0,0,3"/>
                    <TextBox x:Name="TxtCtxLim" Text="200000"/>
                    <WrapPanel Margin="0,5,0,0">
                      <Button x:Name="BtnCtx128k" Style="{StaticResource BtnChip}" Content="128K" Margin="0,0,4,0"/>
                      <Button x:Name="BtnCtx200k" Style="{StaticResource BtnChip}" Content="200K" Margin="0,0,4,0"/>
                      <Button x:Name="BtnCtx400k" Style="{StaticResource BtnChip}" Content="400K" Margin="0,0,4,0"/>
                      <Button x:Name="BtnCtx1m" Style="{StaticResource BtnChip}" Content="1M" Margin="0,0,4,0"/>
                      <Button x:Name="BtnCtxAuto" Style="{StaticResource BtnChip}" Content="Auto"/>
                    </WrapPanel>
                  </StackPanel>
                  <StackPanel Grid.Column="2">
                    <TextBlock Text="Output Limit (e.g. 32000 or 64k)" FontSize="11.5" Foreground="#8B949E" Margin="0,0,0,3"/>
                    <TextBox x:Name="TxtOutLim" Text=""/>
                    <WrapPanel Margin="0,5,0,0">
                      <Button x:Name="BtnOut16k" Style="{StaticResource BtnChip}" Content="16K" Margin="0,0,4,0"/>
                      <Button x:Name="BtnOut32k" Style="{StaticResource BtnChip}" Content="32K" Margin="0,0,4,0"/>
                      <Button x:Name="BtnOut64k" Style="{StaticResource BtnChip}" Content="64K" Margin="0,0,4,0"/>
                      <Button x:Name="BtnOut128k" Style="{StaticResource BtnChip}" Content="128K" Margin="0,0,4,0"/>
                      <Button x:Name="BtnOutAuto" Style="{StaticResource BtnChip}" Content="Auto"/>
                    </WrapPanel>
                  </StackPanel>
                </Grid>

                <TextBlock Text="Reasoning / Effort Variants (includes Xhigh, Max &amp; Ultra)" FontSize="11.5" Foreground="#8B949E" Margin="0,4,0,5"/>
                <WrapPanel Margin="0,0,0,8">
                  <CheckBox x:Name="ChkEffLow" Content="low" IsChecked="True" Margin="0,0,12,4"/>
                  <CheckBox x:Name="ChkEffMed" Content="medium" IsChecked="True" Margin="0,0,12,4"/>
                  <CheckBox x:Name="ChkEffHigh" Content="high" IsChecked="True" Margin="0,0,12,4"/>
                  <CheckBox x:Name="ChkEffXhigh" Content="xhigh" IsChecked="True" Margin="0,0,12,4"/>
                  <CheckBox x:Name="ChkEffMax" Content="max" IsChecked="True" Margin="0,0,12,4"/>
                  <CheckBox x:Name="ChkEffUltra" Content="ultra" IsChecked="True" Margin="0,0,14,4"/>
                  <TextBlock Text="Ultra sends:" Foreground="#8B949E" FontSize="11.5" VerticalAlignment="Center" Margin="0,0,6,4"/>
                  <ComboBox x:Name="CmbUltraTarget" Width="90" SelectedIndex="0" Margin="0,0,12,4">
                    <ComboBoxItem Content="xhigh"/>
                    <ComboBoxItem Content="max"/>
                    <ComboBoxItem Content="ultra"/>
                  </ComboBox>
                </WrapPanel>

                <StackPanel Margin="0,0,0,8">
                  <TextBlock Text="Model API Compatibility Override (e.g. mix Anthropic &amp; OpenAI models in same provider)" FontSize="11.5" Foreground="#8B949E" Margin="0,0,0,3"/>
                  <ComboBox x:Name="CmbModelProtocol" SelectedIndex="0"/>
                </StackPanel>

                <WrapPanel>
                  <Button x:Name="BtnApplySelectedModel" Style="{StaticResource BtnBase}" Content="Apply to Selected Model" Margin="0,0,8,0"/>
                  <Button x:Name="BtnApplyAllModels" Style="{StaticResource BtnBlue}" Content="Apply Limits &amp; Efforts to All Models"/>
                </WrapPanel>
              </StackPanel>
            </Border>

            <!-- Save Footer -->
            <Border Background="#161B22" BorderBrush="#30363D" BorderThickness="1" CornerRadius="8" Padding="12">
              <Grid>
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="*"/>
                  <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <StackPanel Grid.Column="0" VerticalAlignment="Center">
                  <CheckBox x:Name="ChkSetDefaultModel" Content="Set first model as default OpenCode model"/>
                  <TextBlock x:Name="TxtDirectSaveStatus" FontSize="11.5" Foreground="#3FB950" Margin="0,4,0,0" TextWrapping="Wrap"/>
                </StackPanel>
                <Button x:Name="BtnSaveDirectProvider" Grid.Column="1" Style="{StaticResource BtnPrimary}" Content="Save Provider to Config" Padding="18,9"/>
              </Grid>
            </Border>
          </StackPanel>
        </ScrollViewer>
      </TabItem>
    </TabControl>
  </Grid>
</Window>
'@

$reader = New-Object System.Xml.XmlNodeReader $xaml
$window = [Windows.Markup.XamlReader]::Load($reader)

# Bind named controls
$controls = @{}
$nsMgr = New-Object System.Xml.XmlNamespaceManager($xaml.NameTable)
$nsMgr.AddNamespace("x", "http://schemas.microsoft.com/winfx/2006/xaml")
foreach ($node in $xaml.SelectNodes("//*[@x:Name]", $nsMgr)) {
  $name = $node.GetAttribute("Name", "http://schemas.microsoft.com/winfx/2006/xaml")
  $controls[$name] = $window.FindName($name)
}

# Populate Protocols combos
[void]$controls.CmbModelProtocol.Items.Add("Inherit Provider Default")
foreach ($p in $ProtocolPresets) {
  [void]$controls.CmbProtocol.Items.Add($p.Label)
  [void]$controls.CmbModelProtocol.Items.Add($p.Label)
}
$controls.CmbProtocol.SelectedIndex = 0
$controls.CmbModelProtocol.SelectedIndex = 0

function Get-SelectedModelProtocolId {
  $idx = $controls.CmbModelProtocol.SelectedIndex
  if ($idx -ge 1 -and ($idx - 1) -lt $ProtocolPresets.Count) {
    return $ProtocolPresets[$idx - 1].Id
  }
  return "inherit"
}

# State
$script:ResolvedConfigDir = Resolve-OpenCodeConfigDir $ConfigDir
$controls.TxtConfigDir.Text = $script:ResolvedConfigDir
$script:DirectModels = New-Object System.Collections.ArrayList
$script:LoadedExistingMaskKey = ""
$script:IdEditedManually = $false
$script:SyncingModelFields = $false

function Append-Log([string]$Line) {
  $ts = (Get-Date).ToString("HH:mm:ss")
  $controls.TxtInstallLog.AppendText("[$ts] $Line`r`n")
  $controls.TxtInstallLog.ScrollToEnd()
}

function Refresh-DirectModelsList {
  $controls.LstModels.Items.Clear()
  foreach ($m in $script:DirectModels) {
    $ctxTxt = if ($m.contextLimit) { "ctx $($m.contextLimit)" } else { "ctx auto" }
    $outTxt = if ($m.outputLimit) { " | out $($m.outputLimit)" } else { "" }
    $effTxt = if ($m.effortLevels.Count -gt 0) { " | [" + ($m.effortLevels -join "/") + "]" } else { " | [auto]" }
    $protoTxt = if ($m.protocol -and $m.protocol -ne "inherit") { " | $($m.protocol)" } else { "" }
    [void]$controls.LstModels.Items.Add("$($m.id)  ($ctxTxt$outTxt$protoTxt$effTxt)")
  }
  $controls.TxtModelsCount.Text = "Models ($($script:DirectModels.Count))"
}

function Refresh-ExistingProvidersDropdown {
  $controls.CmbExistingProviders.Items.Clear()
  $cfgFile = Resolve-ConfigFilePath $controls.TxtConfigDir.Text.Trim()
  try {
    $cfg = Read-OpenCodeConfig $cfgFile
    $ids = New-Object System.Collections.Generic.List[string]
    if ($cfg.Contains("providers") -and $cfg.providers -is [System.Collections.IDictionary]) {
      foreach ($k in $cfg.providers.Keys) {
        $ent = $cfg.providers[$k]
        if (-not ($ent -is [System.Collections.IDictionary])) { continue }
        $hasPkg = ($ent.Contains("package") -and $ent["package"]) -or ($ent.Contains("npm") -and $ent["npm"])
        $hasUrl = $ent.Contains("settings") -and ($ent["settings"] -is [System.Collections.IDictionary]) -and $ent["settings"].Contains("baseURL") -and $ent["settings"]["baseURL"]
        if (($hasPkg -or $hasUrl) -and -not $ids.Contains($k)) { $ids.Add($k) }
      }
    }
    if ($cfg.Contains("provider") -and $cfg.provider -is [System.Collections.IDictionary]) {
      foreach ($k in $cfg.provider.Keys) { if (-not $ids.Contains($k)) { $ids.Add($k) } }
    }
    foreach ($id in $ids) { [void]$controls.CmbExistingProviders.Items.Add($id) }
    if ($ids.Count -gt 0) { $controls.CmbExistingProviders.SelectedIndex = 0 }
  } catch { }
}

function Refresh-Environment {
  $cfgDir = $controls.TxtConfigDir.Text.Trim()
  if (-not $cfgDir) { $cfgDir = Resolve-OpenCodeConfigDir "" }
  $targetDir = Join-Path (Join-Path $cfgDir "plugins") "custom-provider"
  $controls.TxtPluginDestPreview.Text = "Install path: $targetDir"

  $srcDir = Resolve-PluginSourceDir
  $pkgVer = "1.0.0"
  if ($srcDir -and (Test-Path -LiteralPath (Join-Path $srcDir "package.json"))) {
    try {
      $pkgVer = [string]((Get-Content -LiteralPath (Join-Path $srcDir "package.json") -Raw | ConvertFrom-Json).version)
    } catch { }
  }
  $controls.TxtPluginVerBadge.Text = "Package v$pkgVer"

  $desktopExe = Find-OpenCodeDesktopExe
  $verInfo = Get-OpenCodeVersionInfo $desktopExe
  $installedPkg = Join-Path $targetDir "package.json"
  $instVer = $null
  if (Test-Path -LiteralPath $installedPkg) {
    try { $instVer = [string]((Get-Content -LiteralPath $installedPkg -Raw | ConvertFrom-Json).version) } catch { }
  }
  $running = @(Get-Process -Name "OpenCode", "opencode-cli" -ErrorAction SilentlyContinue).Count -gt 0

  $ocText = if ($verInfo.RawVersion) { "OpenCode v$($verInfo.RawVersion)" } elseif ($desktopExe) { "OpenCode Desktop installed" } else { "OpenCode Desktop not auto-detected" }
  $instText = if ($instVer) { "Plugin v$instVer installed" } else { "Plugin not installed yet" }
  $runText = if ($running) { "OpenCode is currently running" } else { "OpenCode is closed" }
  $controls.TxtSubHeader.Text = "$ocText  |  $instText  |  $runText"

  if ($verInfo.SupportsGuiPlugin -eq $true) {
    $controls.CompatBanner.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#102218")
    $controls.CompatBanner.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#2EA043")
    $controls.TxtCompatBanner.Text = "Compatible: OpenCode v$($verInfo.RawVersion) supports Desktop Settings UI plugins. Install the plugin on Tab 1 (or manage providers directly on Tab 2)."
  } elseif ($verInfo.SupportsGuiPlugin -eq $false) {
    $controls.CompatBanner.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#251D0F")
    $controls.CompatBanner.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#D29922")
    $controls.TxtCompatBanner.Text = "Older OpenCode detected (v$($verInfo.RawVersion)): Desktop Settings UI plugins require OpenCode v2.2.0+. Use Tab 2 ('Direct Provider Setup') right here to configure Custom Providers, Context Limits, and Xhigh/Max/Ultra for ANY version (or update OpenCode to v2.2+/2.3)."
  } else {
    $controls.CompatBanner.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#141C24")
    $controls.CompatBanner.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#388BFD")
    $controls.TxtCompatBanner.Text = "OpenCode Desktop v2.2+ supports Settings UI plugins (Tab 1). If you use CLI only or an older OpenCode build (< 2.2), Tab 2 works across ALL versions (v1.x & v2.x)."
  }

  Refresh-ExistingProvidersDropdown
}

function Invoke-PluginInstallGui {
  $srcDir = Resolve-PluginSourceDir
  if (-not $srcDir) {
    [System.Windows.Forms.MessageBox]::Show("Could not find plugin files (package.json, index.js, gui-experimental.cjs) next to installer. Extract the ZIP archive first.", "Missing Files", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
    return
  }
  $cfgDir = $controls.TxtConfigDir.Text.Trim()
  if (-not $cfgDir) { $cfgDir = Resolve-OpenCodeConfigDir "" }
  $targetDir = Join-Path (Join-Path $cfgDir "plugins") "custom-provider"
  New-Item -ItemType Directory -Path $targetDir -Force | Out-Null

  $reqFiles = @("package.json", "index.js", "gui-experimental.cjs")
  foreach ($f in $reqFiles) {
    $s = Join-Path $srcDir $f
    $d = Join-Path $targetDir $f
    Copy-Item -LiteralPath $s -Destination $d -Force
    try { Unblock-File -LiteralPath $d -ErrorAction SilentlyContinue } catch { }
    if ((Get-Item -LiteralPath $d).Length -ne (Get-Item -LiteralPath $s).Length) {
      throw "Verification mismatch copying $f"
    }
  }
  Append-Log "Installed plugin files to: $targetDir"

  $running = Get-Process -Name "OpenCode", "opencode-cli" -ErrorAction SilentlyContinue
  $desktopExe = Find-OpenCodeDesktopExe
  if ($running -and $controls.ChkAutoRestart.IsChecked) {
    Append-Log "Stopping running OpenCode processes..."
    $running | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 1200
    if ($desktopExe -and (Test-Path -LiteralPath $desktopExe)) {
      Start-Process -FilePath $desktopExe | Out-Null
      Append-Log "Restarted OpenCode Desktop ($desktopExe)."
    } else {
      Append-Log "Stopped OpenCode processes. Launch OpenCode again to see Settings -> Custom Providers."
    }
  } elseif ($running) {
    Append-Log "NOTE: Quit OpenCode Desktop completely from System Tray and reopen it to activate."
  } else {
    Append-Log "Done! Open OpenCode Desktop -> Settings -> Custom Providers."
  }
  Refresh-Environment
}

function Invoke-PluginUninstallGui {
  $cfgDir = $controls.TxtConfigDir.Text.Trim()
  if (-not $cfgDir) { $cfgDir = Resolve-OpenCodeConfigDir "" }
  $targetDir = Join-Path (Join-Path $cfgDir "plugins") "custom-provider"
  if (Test-Path -LiteralPath $targetDir) {
    Remove-Item -LiteralPath $targetDir -Recurse -Force
    Append-Log "Removed plugin directory: $targetDir"
  } else {
    Append-Log "Plugin is not installed at: $targetDir"
  }
  Refresh-Environment
}

function Get-CheckedEffortsFromUI {
  $list = New-Object System.Collections.Generic.List[string]
  if ($controls.ChkEffLow.IsChecked) { $list.Add("low") }
  if ($controls.ChkEffMed.IsChecked) { $list.Add("medium") }
  if ($controls.ChkEffHigh.IsChecked) { $list.Add("high") }
  if ($controls.ChkEffXhigh.IsChecked) { $list.Add("xhigh") }
  if ($controls.ChkEffMax.IsChecked) { $list.Add("max") }
  if ($controls.ChkEffUltra.IsChecked) { $list.Add("ultra") }
  return ,([string[]]$list.ToArray())
}

function Get-UltraTargetFromUI {
  $sel = $controls.CmbUltraTarget.SelectedItem
  if ($sel -and $sel.Content) { return ([string]$sel.Content).Trim().ToLowerInvariant() }
  return "xhigh"
}

# Wire Events
$controls.BtnRefreshEnv.Add_Click({ Refresh-Environment })
$controls.BtnJumpToDirectSetup.Add_Click({ $controls.MainTabs.SelectedIndex = 1 })

$controls.BtnBrowseConfig.Add_Click({
  $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
  $dlg.Description = "Select OpenCode Configuration Folder (default: ~/.config/opencode)"
  if (Test-Path -LiteralPath $controls.TxtConfigDir.Text) { $dlg.SelectedPath = $controls.TxtConfigDir.Text }
  if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
    $controls.TxtConfigDir.Text = $dlg.SelectedPath
    Refresh-Environment
  }
})

$controls.BtnOpenPluginsFolder.Add_Click({
  $pDir = Join-Path $controls.TxtConfigDir.Text.Trim() "plugins"
  if (-not (Test-Path -LiteralPath $pDir)) { New-Item -ItemType Directory -Path $pDir -Force | Out-Null }
  Start-Process "explorer.exe" $pDir
})

$controls.BtnInstallPlugin.Add_Click({
  try {
    Invoke-PluginInstallGui
  } catch {
    Append-Log "ERROR: $($_.Exception.Message)"
    [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "Install Error", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
  }
})

$controls.BtnUninstallPlugin.Add_Click({
  try {
    Invoke-PluginUninstallGui
  } catch {
    Append-Log "ERROR: $($_.Exception.Message)"
  }
})

$controls.TxtProvName.Add_TextChanged({
  if (-not $script:IdEditedManually) {
    $slug = Slugify-ProviderId $controls.TxtProvName.Text
    if ($slug) { $controls.TxtProvId.Text = $slug }
  }
})
$controls.TxtProvId.Add_GotFocus({ $script:IdEditedManually = $true })

# Preset token buttons
$controls.BtnCtx128k.Add_Click({ $controls.TxtCtxLim.Text = "128000" })
$controls.BtnCtx200k.Add_Click({ $controls.TxtCtxLim.Text = "200000" })
$controls.BtnCtx400k.Add_Click({ $controls.TxtCtxLim.Text = "400000" })
$controls.BtnCtx1m.Add_Click({ $controls.TxtCtxLim.Text = "1000000" })
$controls.BtnCtxAuto.Add_Click({ $controls.TxtCtxLim.Text = "" })
$controls.BtnOut16k.Add_Click({ $controls.TxtOutLim.Text = "16000" })
$controls.BtnOut32k.Add_Click({ $controls.TxtOutLim.Text = "32000" })
$controls.BtnOut64k.Add_Click({ $controls.TxtOutLim.Text = "64000" })
$controls.BtnOut128k.Add_Click({ $controls.TxtOutLim.Text = "128000" })
$controls.BtnOutAuto.Add_Click({ $controls.TxtOutLim.Text = "" })

$controls.BtnAddManualModel.Add_Click({
  $raw = $controls.TxtManualModelId.Text.Trim()
  if (-not $raw) { return }
  $ctx = Parse-TokenInput $controls.TxtCtxLim.Text
  $out = Parse-TokenInput $controls.TxtOutLim.Text
  $effs = [string[]](Get-CheckedEffortsFromUI)
  $uTarget = Get-UltraTargetFromUI
  $mProto = Get-SelectedModelProtocolId
  foreach ($part in ($raw -split ',')) {
    $mid = $part.Trim()
    if (-not $mid) { continue }
    $exists = $false
    foreach ($m in $script:DirectModels) { if ($m.id -eq $mid) { $exists = $true; break } }
    if ($exists) { continue }
    [void]$script:DirectModels.Add([pscustomobject]@{
      id           = $mid
      name         = $mid
      protocol     = $mProto
      contextLimit = $ctx
      outputLimit  = $out
      effortLevels = $effs
      ultraTarget  = $uTarget
    })
  }
  $controls.TxtManualModelId.Text = ""
  Refresh-DirectModelsList
})

$controls.BtnRemoveSelectedModel.Add_Click({
  $idx = $controls.LstModels.SelectedIndex
  if ($idx -ge 0 -and $idx -lt $script:DirectModels.Count) {
    $script:DirectModels.RemoveAt($idx)
    Refresh-DirectModelsList
  }
})

function Sync-SelectedModelFromUI([switch]$IncludeLimits) {
  if ($script:SyncingModelFields) { return }
  $idx = $controls.LstModels.SelectedIndex
  if ($idx -lt 0 -or $idx -ge $script:DirectModels.Count) { return }
  $script:SyncingModelFields = $true
  try {
    $m = $script:DirectModels[$idx]
    if ($IncludeLimits) {
      $m.contextLimit = Parse-TokenInput $controls.TxtCtxLim.Text
      $m.outputLimit = Parse-TokenInput $controls.TxtOutLim.Text
    }
    $m.effortLevels = [string[]](Get-CheckedEffortsFromUI)
    $m.ultraTarget = Get-UltraTargetFromUI
    $m.protocol = Get-SelectedModelProtocolId
    Refresh-DirectModelsList
    if ($idx -lt $controls.LstModels.Items.Count) {
      $controls.LstModels.SelectedIndex = $idx
    }
  } finally {
    $script:SyncingModelFields = $false
  }
}

$controls.LstModels.Add_SelectionChanged({
  if ($script:SyncingModelFields) { return }
  $idx = $controls.LstModels.SelectedIndex
  if ($idx -ge 0 -and $idx -lt $script:DirectModels.Count) {
    $script:SyncingModelFields = $true
    try {
      $m = $script:DirectModels[$idx]
      $controls.TxtCtxLim.Text = if ($m.contextLimit) { [string]$m.contextLimit } else { "" }
      $controls.TxtOutLim.Text = if ($m.outputLimit) { [string]$m.outputLimit } else { "" }
      $controls.ChkEffLow.IsChecked = ($m.effortLevels -contains "low")
      $controls.ChkEffMed.IsChecked = ($m.effortLevels -contains "medium")
      $controls.ChkEffHigh.IsChecked = ($m.effortLevels -contains "high")
      $controls.ChkEffXhigh.IsChecked = ($m.effortLevels -contains "xhigh")
      $controls.ChkEffMax.IsChecked = ($m.effortLevels -contains "max")
      $controls.ChkEffUltra.IsChecked = ($m.effortLevels -contains "ultra")
      if ($m.ultraTarget) {
        for ($i = 0; $i -lt $controls.CmbUltraTarget.Items.Count; $i++) {
          if ([string]$controls.CmbUltraTarget.Items[$i].Content -eq $m.ultraTarget) {
            $controls.CmbUltraTarget.SelectedIndex = $i; break
          }
        }
      }
      $selProtoIdx = 0
      if ($m.protocol -and $m.protocol -ne "inherit") {
        for ($i = 0; $i -lt $ProtocolPresets.Count; $i++) {
          if ($ProtocolPresets[$i].Id -eq $m.protocol) { $selProtoIdx = $i + 1; break }
        }
      }
      $controls.CmbModelProtocol.SelectedIndex = $selProtoIdx
    } finally {
      $script:SyncingModelFields = $false
    }
  }
})

foreach ($chk in @($controls.ChkEffLow, $controls.ChkEffMed, $controls.ChkEffHigh, $controls.ChkEffXhigh, $controls.ChkEffMax, $controls.ChkEffUltra)) {
  $chk.Add_Checked({ Sync-SelectedModelFromUI })
  $chk.Add_Unchecked({ Sync-SelectedModelFromUI })
}
$controls.CmbUltraTarget.Add_SelectionChanged({ Sync-SelectedModelFromUI })
$controls.CmbModelProtocol.Add_SelectionChanged({ Sync-SelectedModelFromUI })

$controls.BtnApplySelectedModel.Add_Click({
  $idx = $controls.LstModels.SelectedIndex
  if ($idx -lt 0 -or $idx -ge $script:DirectModels.Count) { return }
  $m = $script:DirectModels[$idx]
  $m.contextLimit = Parse-TokenInput $controls.TxtCtxLim.Text
  $m.outputLimit = Parse-TokenInput $controls.TxtOutLim.Text
  $m.effortLevels = [string[]](Get-CheckedEffortsFromUI)
  $m.ultraTarget = Get-UltraTargetFromUI
  $m.protocol = Get-SelectedModelProtocolId
  Refresh-DirectModelsList
  $controls.LstModels.SelectedIndex = $idx
})

$controls.BtnApplyAllModels.Add_Click({
  $ctx = Parse-TokenInput $controls.TxtCtxLim.Text
  $out = Parse-TokenInput $controls.TxtOutLim.Text
  $effs = [string[]](Get-CheckedEffortsFromUI)
  $uTarget = Get-UltraTargetFromUI
  foreach ($m in $script:DirectModels) {
    $m.contextLimit = $ctx
    $m.outputLimit = $out
    $m.effortLevels = $effs
    $m.ultraTarget = $uTarget
  }
  Refresh-DirectModelsList
})

$controls.BtnFetchModels.Add_Click({
  $rawUrl = Normalize-BaseUrl $controls.TxtBaseUrl.Text
  if (-not ($rawUrl -match '^https?://')) {
    $controls.TxtFetchStatus.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#FF7B72")
    $controls.TxtFetchStatus.Text = "Enter a valid Base URL starting with http:// or https://"
    return
  }
  $controls.TxtBaseUrl.Text = $rawUrl
  $candidates = New-Object System.Collections.Generic.List[string]
  $candidates.Add("$rawUrl/models")
  try {
    $uri = [Uri]$rawUrl
    if ($uri.AbsolutePath.TrimEnd('/') -notmatch '/v\d+(?:alpha|beta)?$') {
      $candidates.Add("$rawUrl/v1/models")
    }
    if ($uri.AbsolutePath -and $uri.AbsolutePath -ne "/" -and -not $uri.AbsolutePath.TrimEnd('/').EndsWith("/v1")) {
      $candidates.Add("$($uri.Scheme)://$($uri.Authority)/v1/models")
    }
  } catch { }

  $keyVal = $controls.TxtApiKey.Password.Trim()
  if (-not $keyVal -and $script:LoadedExistingMaskKey) { $keyVal = $script:LoadedExistingMaskKey }
  $headers = @{ Accept = "application/json" }
  if ($keyVal) {
    $headers["Authorization"] = "Bearer $keyVal"
    if ($controls.CmbProtocol.SelectedIndex -eq 2) {
      $headers["x-api-key"] = $keyVal
      $headers["anthropic-version"] = "2023-06-01"
    }
  }

  $controls.TxtFetchStatus.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#79C0FF")
  $controls.TxtFetchStatus.Text = "Probing models endpoint..."
  $window.Cursor = [System.Windows.Input.Cursors]::Wait
  [System.Windows.Forms.Application]::DoEvents()

  $lastErr = "Request failed"
  $found = $false
  try {
    foreach ($probeUrl in ($candidates | Select-Object -Unique)) {
      try {
        $resp = Invoke-WebRequest -Uri $probeUrl -Method GET -Headers $headers -TimeoutSec 10 -UseBasicParsing
        $body = [string]$resp.Content
        if (-not $body.Trim()) { $lastErr = "Empty response ($($resp.StatusCode))"; continue }
        if ($body -match '^\s*(?:<!doctype|<html\b)') {
          $lastErr = "Endpoint returned HTML webpage instead of JSON (missing /v1?)."
          continue
        }
        $json = $body | ConvertFrom-Json
        $arr = if ($json.data) { $json.data } elseif ($json.models) { $json.models } elseif ($json -is [System.Collections.IEnumerable]) { $json } else { @() }
        $ctxDefault = Parse-TokenInput $controls.TxtCtxLim.Text
        $outDefault = Parse-TokenInput $controls.TxtOutLim.Text
        $effDefault = [string[]](Get-CheckedEffortsFromUI)
        $uDefault = Get-UltraTargetFromUI

        $added = 0
        foreach ($item in $arr) {
          $mid = if ($item.id) { [string]$item.id } elseif ($item.name) { [string]$item.name } else { "" }
          if (-not $mid) { continue }
          $exists = $false
          foreach ($existingM in $script:DirectModels) { if ($existingM.id -eq $mid) { $exists = $true; break } }
          if ($exists) { continue }
          $mCtx = if ($item.context_length) { [int]$item.context_length } elseif ($item.max_model_len) { [int]$item.max_model_len } elseif ($item.inputTokenLimit) { [int]$item.inputTokenLimit } else { $ctxDefault }
          $mOut = if ($item.max_output_tokens) { [int]$item.max_output_tokens } elseif ($item.outputTokenLimit) { [int]$item.outputTokenLimit } else { $outDefault }
          [void]$script:DirectModels.Add([pscustomobject]@{
            id           = $mid
            name         = if ($item.display_name) { [string]$item.display_name } elseif ($item.name) { [string]$item.name } else { $mid }
            protocol     = "inherit"
            contextLimit = $mCtx
            outputLimit  = $mOut
            effortLevels = $effDefault
            ultraTarget  = $uDefault
          })
          $added++
        }
        $suggestedBase = $probeUrl -replace '/models(?:\?.*)?$', ''
        if ($suggestedBase -and $suggestedBase -ne $controls.TxtBaseUrl.Text.Trim()) {
          $controls.TxtBaseUrl.Text = $suggestedBase
        }
        Refresh-DirectModelsList
        $controls.TxtFetchStatus.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#3FB950")
        $controls.TxtFetchStatus.Text = "Connected to $probeUrl - added $added model(s). Select any model or click 'Apply Limits & Efforts to All Models' to customize."
        $found = $true
        break
      } catch {
        $lastErr = $_.Exception.Message
      }
    }
    if (-not $found) {
      $controls.TxtFetchStatus.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#FF7B72")
      $controls.TxtFetchStatus.Text = "Fetch failed: $lastErr"
    }
  } finally {
    $window.Cursor = [System.Windows.Input.Cursors]::Arrow
  }
})

$controls.BtnLoadProvider.Add_Click({
  $selId = [string]$controls.CmbExistingProviders.SelectedItem
  if (-not $selId) { return }
  $cfgFile = Resolve-ConfigFilePath $controls.TxtConfigDir.Text.Trim()
  try {
    $cfg = Read-OpenCodeConfig $cfgFile
    $raw = $null
    if ($cfg.Contains("providers") -and $cfg.providers -is [System.Collections.IDictionary] -and $cfg.providers.Contains($selId)) {
      $raw = $cfg.providers[$selId]
    } elseif ($cfg.Contains("provider") -and $cfg.provider -is [System.Collections.IDictionary] -and $cfg.provider.Contains($selId)) {
      $raw = $cfg.provider[$selId]
    }
    if (-not $raw) { return }
    $controls.TxtProvId.Text = $selId
    $script:IdEditedManually = $true
    $controls.TxtProvName.Text = if ($raw.Contains("name")) { [string]$raw["name"] } else { $selId }

    $pkg = if ($raw.Contains("package")) { [string]$raw["package"] } elseif ($raw.Contains("npm")) { [string]$raw["npm"] } else { "" }
    $pIdx = 0
    for ($i = 0; $i -lt $ProtocolPresets.Count; $i++) {
      if ($ProtocolPresets[$i].PkgV2 -eq $pkg -or $ProtocolPresets[$i].PkgV1 -eq $pkg) { $pIdx = $i; break }
    }
    $controls.CmbProtocol.SelectedIndex = $pIdx

    $sett = if ($raw.Contains("settings")) { $raw["settings"] } elseif ($raw.Contains("options")) { $raw["options"] } else { $null }
    if ($sett -is [System.Collections.IDictionary]) {
      $controls.TxtBaseUrl.Text = if ($sett.Contains("baseURL")) { [string]$sett["baseURL"] } else { "" }
      if ($sett.Contains("apiKey")) {
        $script:LoadedExistingMaskKey = [string]$sett["apiKey"]
        $controls.TxtApiKey.Password = ""
        $controls.TxtApiKeyLabel.Text = "API Key (leave blank to keep existing saved key)"
      }
    }

    $script:DirectModels.Clear()
    if ($raw.Contains("models") -and $raw["models"] -is [System.Collections.IDictionary]) {
      foreach ($mid in $raw["models"].Keys) {
        $mRaw = $raw["models"][$mid]
        if (-not ($mRaw -is [System.Collections.IDictionary])) { continue }
        $mCtx = if ($mRaw.Contains("limit") -and ($mRaw["limit"] -is [System.Collections.IDictionary]) -and $mRaw["limit"].Contains("context")) { [int]$mRaw["limit"]["context"] } else { $null }
        $mOut = if ($mRaw.Contains("limit") -and ($mRaw["limit"] -is [System.Collections.IDictionary]) -and $mRaw["limit"].Contains("output")) { [int]$mRaw["limit"]["output"] } else { $null }
        $effList = New-Object System.Collections.Generic.List[string]
        $uTgt = "xhigh"
        if ($mRaw.Contains("capabilities") -and ($mRaw["capabilities"] -is [System.Collections.IDictionary]) -and $mRaw["capabilities"].Contains("reasoning") -and ($mRaw["capabilities"]["reasoning"] -is [System.Collections.IDictionary]) -and $mRaw["capabilities"]["reasoning"].Contains("effort")) {
          foreach ($e in @($mRaw["capabilities"]["reasoning"]["effort"])) { if ($e -and -not $effList.Contains([string]$e)) { $effList.Add([string]$e) } }
        }
        if ($mRaw.Contains("variants") -and $null -ne $mRaw["variants"]) {
          if ($mRaw["variants"] -is [System.Collections.IDictionary]) {
            foreach ($vk in $mRaw["variants"].Keys) {
              if (-not $effList.Contains([string]$vk)) { $effList.Add([string]$vk) }
              $vEntry = $mRaw["variants"][$vk]
              if ($vk -eq "ultra" -and ($vEntry -is [System.Collections.IDictionary]) -and $vEntry.Contains("reasoningEffort")) { $uTgt = [string]$vEntry["reasoningEffort"] }
            }
          } elseif ($mRaw["variants"] -is [System.Collections.IEnumerable]) {
            foreach ($vItem in @($mRaw["variants"])) {
              if (($vItem -is [System.Collections.IDictionary]) -and $vItem.Contains("id")) {
                $vk = [string]$vItem["id"]
                if (-not $effList.Contains($vk)) { $effList.Add($vk) }
                if ($vk -eq "ultra" -and $vItem.Contains("settings") -and ($vItem["settings"] -is [System.Collections.IDictionary]) -and $vItem["settings"].Contains("reasoningEffort")) {
                  $uTgt = [string]$vItem["settings"]["reasoningEffort"]
                }
              }
            }
          }
        }
        $mPkg = if ($mRaw.Contains("package")) { [string]$mRaw["package"] } elseif ($mRaw.Contains("npm")) { [string]$mRaw["npm"] } else { "" }
        $mProto = "inherit"
        if ($mPkg) {
          foreach ($pr in $ProtocolPresets) {
            if ($pr.PkgV2 -eq $mPkg -or $pr.PkgV1 -eq $mPkg) { $mProto = $pr.Id; break }
          }
        }
        [void]$script:DirectModels.Add([pscustomobject]@{
          id           = $mid
          name         = if ($mRaw.Contains("name")) { [string]$mRaw["name"] } else { $mid }
          protocol     = $mProto
          contextLimit = $mCtx
          outputLimit  = $mOut
          effortLevels = [string[]]$effList.ToArray()
          ultraTarget  = $uTgt
        })
      }
    }
    Refresh-DirectModelsList
    if ($controls.LstModels.Items.Count -gt 0) {
      $controls.LstModels.SelectedIndex = 0
    }
    $controls.TxtDirectSaveStatus.Text = "Loaded '$selId'."
  } catch {
    $controls.TxtDirectSaveStatus.Text = "Load failed: $($_.Exception.Message)"
  }
})

$controls.BtnDeleteProvider.Add_Click({
  $selId = [string]$controls.CmbExistingProviders.SelectedItem
  if (-not $selId) { return }
  $cfgFile = Resolve-ConfigFilePath $controls.TxtConfigDir.Text.Trim()
  try {
    $cfg = Read-OpenCodeConfig $cfgFile
    $changed = $false
    if ($cfg.Contains("providers") -and $cfg.providers -is [System.Collections.IDictionary] -and $cfg.providers.Contains($selId)) {
      $cfg.providers.Remove($selId); $changed = $true
    }
    if ($cfg.Contains("provider") -and $cfg.provider -is [System.Collections.IDictionary] -and $cfg.provider.Contains($selId)) {
      $cfg.provider.Remove($selId); $changed = $true
    }
    if ($changed) {
      Write-OpenCodeConfig $cfgFile $cfg
      Refresh-ExistingProvidersDropdown
      $controls.TxtDirectSaveStatus.Text = "Deleted '$selId' from config."
    }
  } catch {
    $controls.TxtDirectSaveStatus.Text = "Delete failed: $($_.Exception.Message)"
  }
})

$controls.BtnSaveDirectProvider.Add_Click({
  Sync-SelectedModelFromUI
  $provId = Slugify-ProviderId $controls.TxtProvId.Text
  if (-not $provId) {
    $controls.TxtDirectSaveStatus.Text = "Error: Provider ID is required."
    return
  }
  $baseUrl = Normalize-BaseUrl $controls.TxtBaseUrl.Text
  if (-not ($baseUrl -match '^https?://')) {
    $controls.TxtDirectSaveStatus.Text = "Error: Base URL must start with http:// or https://"
    return
  }
  if ($script:DirectModels.Count -eq 0) {
    $controls.TxtDirectSaveStatus.Text = "Error: Add or Fetch at least one model first."
    return
  }

  $cfgDir = $controls.TxtConfigDir.Text.Trim()
  if (-not $cfgDir) { $cfgDir = Resolve-OpenCodeConfigDir "" }
  $cfgFile = Resolve-ConfigFilePath $cfgDir

  try {
    $cfg = Read-OpenCodeConfig $cfgFile
    $verInfo = Get-OpenCodeVersionInfo (Find-OpenCodeDesktopExe)

    $useV1 = $false
    switch ($controls.CmbSchemaMode.SelectedIndex) {
      1 { $useV1 = $false }
      2 { $useV1 = $true }
      default {
        if ($verInfo.IsLegacyV1 -or ($cfg.Contains("provider") -and -not $cfg.Contains("providers"))) {
          $useV1 = $true
        }
      }
    }

    $preset = $ProtocolPresets[$controls.CmbProtocol.SelectedIndex]
    $keyVal = $controls.TxtApiKey.Password.Trim()
    if (-not $keyVal -and $script:LoadedExistingMaskKey) { $keyVal = $script:LoadedExistingMaskKey }
    $provName = if ($controls.TxtProvName.Text.Trim()) { $controls.TxtProvName.Text.Trim() } else { $provId }

    $modelsMap = [ordered]@{}
    $stdSet = @("none", "minimal", "low", "medium", "high", "xhigh", "max")
    foreach ($m in $script:DirectModels) {
      $mObj = [ordered]@{ name = $m.name }
      $mEffPreset = $preset
      if ($m.protocol -and $m.protocol -ne "inherit") {
        foreach ($pr in $ProtocolPresets) {
          if ($pr.Id -eq $m.protocol) {
            $mEffPreset = $pr
            if ($useV1) { $mObj["npm"] = $pr.PkgV1 } else { $mObj["package"] = $pr.PkgV2 }
            break
          }
        }
      }
      $lim = [ordered]@{}
      if ($m.contextLimit -and $m.contextLimit -gt 0) { $lim["context"] = [int]$m.contextLimit }
      if ($m.outputLimit -and $m.outputLimit -gt 0) { $lim["output"] = [int]$m.outputLimit }
      if ($lim.Count -gt 0) { $mObj["limit"] = $lim }

      $effs = @($m.effortLevels)
      if ($useV1) {
        if ($effs.Count -gt 0) {
          $vObj = [ordered]@{}
          foreach ($lvl in $effs) {
            $effSend = if ($lvl -eq "ultra") { if ($m.ultraTarget) { $m.ultraTarget } else { "xhigh" } } else { $lvl }
            $vObj[$lvl] = [ordered]@{ reasoningEffort = $effSend }
          }
          $mObj["variants"] = $vObj
        }
      } else {
        $stdEffs = New-Object System.Collections.ArrayList
        foreach ($lvl in $effs) { if ($stdSet -contains $lvl) { [void]$stdEffs.Add([string]$lvl) } }
        if ($stdEffs.Count -gt 0) {
          $mObj["capabilities"] = [ordered]@{
            reasoning = [ordered]@{
              supported = $true
              effort    = [string[]]$stdEffs.ToArray()
            }
          }
        }
        if ($effs -contains "ultra") {
          $effSend = if ($m.ultraTarget) { $m.ultraTarget } else { if ($mEffPreset.Id -eq "anthropic" -or $mEffPreset.Id -eq "google") { "max" } else { "xhigh" } }
          $incArr = [string[]]@("reasoning.encrypted_content")
          $vSettings = switch ($mEffPreset.Id) {
            "anthropic" { [ordered]@{ thinking = [ordered]@{ type = "adaptive"; display = "summarized" }; effort = $(if ($effSend -eq "ultra") { "max" } else { $effSend }) } }
            "google"    { [ordered]@{ thinkingConfig = [ordered]@{ includeThoughts = $true; thinkingLevel = $(if ($effSend -eq "ultra") { "high" } else { $effSend }) } } }
            "openai"    { [ordered]@{ reasoningEffort = $effSend; reasoningSummary = "auto"; include = $incArr } }
            "openai-compatible-responses" { [ordered]@{ reasoningEffort = $effSend; reasoningSummary = "auto"; include = $incArr } }
            default     { [ordered]@{ reasoningEffort = $effSend } }
          }
          $vArr = New-Object System.Collections.ArrayList
          [void]$vArr.Add([ordered]@{ id = "ultra"; settings = $vSettings })
          $mObj["variants"] = $vArr
        }
      }
      $modelsMap[$m.id] = $mObj
    }

    if ($useV1) {
      if (-not $cfg.Contains("provider") -or -not ($cfg["provider"] -is [System.Collections.IDictionary])) {
        $cfg["provider"] = [ordered]@{}
      }
      $opts = [ordered]@{ baseURL = $baseUrl }
      if ($keyVal) { $opts["apiKey"] = $keyVal }
      $cfg["provider"][$provId] = [ordered]@{
        name    = $provName
        npm     = $preset.PkgV1
        options = $opts
        models  = $modelsMap
      }
    } else {
      if (-not $cfg.Contains("providers") -or -not ($cfg["providers"] -is [System.Collections.IDictionary])) {
        $cfg["providers"] = [ordered]@{}
      }
      $sett = [ordered]@{ baseURL = $baseUrl }
      if ($keyVal) { $sett["apiKey"] = $keyVal }
      $cfg["providers"][$provId] = [ordered]@{
        name     = $provName
        package  = $preset.PkgV2
        settings = $sett
        models   = $modelsMap
      }
    }

    if ($controls.ChkSetDefaultModel.IsChecked) {
      $firstModelId = [string]$script:DirectModels[0].id
      $cfg["model"] = "$provId/$firstModelId"
    }

    Write-OpenCodeConfig $cfgFile $cfg
    Refresh-ExistingProvidersDropdown
    $fmtLabel = if ($useV1) { "Legacy V1 (provider)" } else { "V2 (providers)" }
    $controls.TxtDirectSaveStatus.Text = "Saved '$provName' ($($script:DirectModels.Count) models) in $fmtLabel format to $cfgFile"
  } catch {
    $controls.TxtDirectSaveStatus.Text = "Save error: $($_.Exception.Message)"
  }
})

# Initial State
Refresh-Environment
if ($InitialTab -eq "Setup") {
  $controls.MainTabs.SelectedIndex = 1
} else {
  $controls.MainTabs.SelectedIndex = 0
}
Append-Log "Ready. Click 'Install / Update Plugin' to install into OpenCode."

[void]$window.ShowDialog()
exit 0
