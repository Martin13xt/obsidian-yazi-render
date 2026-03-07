[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Test-IsMacOS {
  if ($env:OS -eq "Windows_NT") {
    return $false
  }
  $isMacVar = Get-Variable -Name IsMacOS -Scope Global -ErrorAction SilentlyContinue
  if ($null -ne $isMacVar) {
    return [bool]$isMacVar.Value
  }
  $unameCmd = Get-Command uname -ErrorAction SilentlyContinue
  if ($null -ne $unameCmd) {
    try {
      return ((& $unameCmd.Source).Trim() -eq "Darwin")
    } catch {
      return $false
    }
  }
  return $false
}

function Get-DefaultCacheRoot {
  if (Test-IsMacOS) {
    return [System.IO.Path]::Combine($HOME, "Library", "Caches", "obsidian-yazi")
  }
  if ($env:XDG_CACHE_HOME -and $env:XDG_CACHE_HOME.Trim()) {
    return [System.IO.Path]::Combine($env:XDG_CACHE_HOME.TrimEnd('/','\'), "obsidian-yazi")
  }
  return [System.IO.Path]::Combine($HOME, ".cache", "obsidian-yazi")
}

function Expand-HomePath([string]$Value) {
  if ($Value -eq "~") {
    return $HOME
  }
  if ($Value.StartsWith('~/') -or $Value.StartsWith('~\')) {
    return [System.IO.Path]::Combine($HOME, $Value.Substring(2))
  }
  return $Value
}

function Resolve-AbsolutePath([string]$Value) {
  if (-not $Value) {
    throw "Refusing cleanup for empty cache root."
  }
  $expanded = Expand-HomePath $Value
  if (-not [System.IO.Path]::IsPathRooted($expanded)) {
    throw "Refusing cleanup for non-absolute cache root: '$expanded'"
  }
  return [System.IO.Path]::GetFullPath($expanded)
}

function Parse-NonNegativeInt([string]$Value, [int]$Fallback) {
  if (-not $Value) {
    return $Fallback
  }
  try {
    $parsed = [int]$Value
    if ($parsed -lt 0) {
      return $Fallback
    }
    return $parsed
  } catch {
    return $Fallback
  }
}

function Remove-ExpiredFiles([string]$Path, [string]$Filter, [datetime]$Cutoff, [switch]$Recurse) {
  if (-not (Test-Path -LiteralPath $Path)) {
    return 0
  }
  $items = Get-ChildItem -LiteralPath $Path -File -Filter $Filter -Recurse:$Recurse -ErrorAction SilentlyContinue |
    Where-Object { $_.LastWriteTime -lt $Cutoff }
  $count = @($items).Count
  if ($count -gt 0) {
    $items | Remove-Item -Force
  }
  return $count
}

$cacheRootSetting = if ($env:OBSIDIAN_YAZI_CACHE -and $env:OBSIDIAN_YAZI_CACHE.Trim()) {
  $env:OBSIDIAN_YAZI_CACHE
} else {
  Get-DefaultCacheRoot
}

$cacheRoot = Resolve-AbsolutePath $cacheRootSetting
$ttlDays = Parse-NonNegativeInt $env:OBSIDIAN_YAZI_TTL_DAYS 3
$lockTtlMin = Parse-NonNegativeInt $env:OBSIDIAN_YAZI_LOCK_TTL_MIN 15
$sentinelName = ".obsidian-yazi-cache"
$sentinelPath = [System.IO.Path]::Combine($cacheRoot, $sentinelName)

$homePath = [System.IO.Path]::GetFullPath($HOME)
$rootPath = [System.IO.Path]::GetPathRoot($cacheRoot)
if ([string]::IsNullOrWhiteSpace($cacheRoot) -or $cacheRoot -eq $rootPath -or $cacheRoot -eq $homePath) {
  throw "Refusing cleanup for unsafe cache root: '$cacheRoot'"
}
if (-not (Test-Path -LiteralPath $sentinelPath -PathType Leaf)) {
  throw "Refusing cleanup: sentinel not found at $sentinelPath"
}

if ($ttlDays -gt 365) {
  Write-Warning "TTL_DAYS too large ($ttlDays). Clamping to 365."
  $ttlDays = 365
}

$imgDir = [System.IO.Path]::Combine($cacheRoot, "img")
$modeDir = [System.IO.Path]::Combine($cacheRoot, "mode")
$lockDir = [System.IO.Path]::Combine($cacheRoot, "locks")
$logDir = [System.IO.Path]::Combine($cacheRoot, "log")
$requestDir = [System.IO.Path]::Combine($cacheRoot, "requests")

$null = New-Item -ItemType Directory -Path $imgDir -Force
$null = New-Item -ItemType Directory -Path $modeDir -Force
$null = New-Item -ItemType Directory -Path $lockDir -Force
$null = New-Item -ItemType Directory -Path $logDir -Force
$null = New-Item -ItemType Directory -Path $requestDir -Force

$ttlCutoff = (Get-Date).AddDays(-$ttlDays)
$lockCutoff = (Get-Date).AddMinutes(-$lockTtlMin)

$totalCleaned = 0
$totalCleaned += Remove-ExpiredFiles $imgDir "*.png" $ttlCutoff
$totalCleaned += Remove-ExpiredFiles $imgDir "*.meta.json" $ttlCutoff
$totalCleaned += Remove-ExpiredFiles $lockDir "*.lock" $lockCutoff
$totalCleaned += Remove-ExpiredFiles $lockDir ".curl-auth-*.header" $lockCutoff
$totalCleaned += Remove-ExpiredFiles $logDir "*" $ttlCutoff
$totalCleaned += Remove-ExpiredFiles $requestDir "*" $ttlCutoff -Recurse

Write-Output "$totalCleaned files cleaned up"
exit 0
