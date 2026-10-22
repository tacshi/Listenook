param(
  [Parameter(Position = 0)]
  [string]$Version,
  [ValidateSet("x64", "arm64")]
  [string]$Arch = "x64",
  [switch]$AllowBranch
)

$ErrorActionPreference = "Stop"
$Root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
Set-Location $Root

$BuildParameters = @{
  Mode = "release"
  Arch = $Arch
}

if ($Version) {
  if ($Version -notmatch '^\d+\.\d+\.\d+$') {
    throw "Version must be x.y.z: $Version"
  }

  $ReleaseBranch = "main"
  if (-not $AllowBranch) {
    $Branch = (git rev-parse --abbrev-ref HEAD).Trim()
    if ($Branch -ne $ReleaseBranch) {
      throw "Releases must be built from $ReleaseBranch (current: $Branch)."
    }
    if (git status --porcelain) {
      throw "The working tree is dirty. Commit or stash changes before releasing."
    }
    git fetch origin $ReleaseBranch
    if ($LASTEXITCODE -ne 0) { throw "Could not fetch origin/$ReleaseBranch." }
    $LocalCommit = (git rev-parse HEAD).Trim()
    $RemoteCommit = (git rev-parse "origin/$ReleaseBranch").Trim()
    if ($LocalCommit -ne $RemoteCommit) {
      throw "Local $ReleaseBranch must exactly match origin/$ReleaseBranch."
    }
  }

  $BuildNumber = (git rev-list --count HEAD).Trim()
  $Commit = (git rev-parse HEAD).Trim()
  $Dirty = [bool](git status --porcelain)
  $BuildParameters.BuildName = $Version
  $BuildParameters.BuildNumber = $BuildNumber
}

& (Join-Path $PSScriptRoot "build-windows.ps1") @BuildParameters
if ($LASTEXITCODE -ne 0) { throw "Windows release build failed." }

if (-not $Version) { exit 0 }

$Installer = Join-Path $Root "build\Listenook-$Version-windows-$Arch-release-setup.exe"
if (-not (Test-Path -LiteralPath $Installer -PathType Leaf)) {
  throw "Missing installer: $Installer"
}

$Sidecar = "$Installer.build.json"
$Metadata = [ordered]@{
  version = $Version
  build = [int]$BuildNumber
  commit = $Commit
  architecture = $Arch
  dirty = $Dirty
}
$Metadata | ConvertTo-Json | Set-Content -LiteralPath $Sidecar -Encoding ascii
Write-Host "Installer: $Installer"
Write-Host "Provenance: $Sidecar"
