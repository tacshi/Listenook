param(
  [Parameter(Mandatory = $true, Position = 0)]
  [ValidateSet("debug", "release")]
  [string]$Mode,
  [string]$Version,
  [switch]$AllowBranch
)

# Builds the Windows app with `nsh package` and signs it when a certificate
# is configured (LISTENOOK_WINDOWS_PFX).
#
#   build-windows.ps1 debug                    build\Listenook-x64-debug
#   build-windows.ps1 release                  the installer and updater archive
#   build-windows.ps1 release -Version 1.2.3   the same for a published release:
#                                              built from a clean main that
#                                              matches origin, with a record of
#                                              the commit for scripts/publish.sh.
#                                              Build it before or after
#                                              publish.sh sets the version.
#
# A release needs Inno Setup 6 or 7.

$ErrorActionPreference = "Stop"
$Root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
# nsh packages Windows apps for x64 only.
$Arch = "x64"
$HostArch = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
if (-not (Get-Command nsh -ErrorAction SilentlyContinue)) {
  throw "The nsh CLI is required: https://github.com/longbridge/nsh"
}

$Manifest = Get-Content -LiteralPath (Join-Path $Root "nsh.json") -Raw | ConvertFrom-Json
$Name = $Manifest.name
$BuildNumber = $null
if ($Version) {
  if ($Mode -ne "release") { throw "-Version is for release builds." }
  if ($Version -notmatch '^\d+\.\d+\.\d+$') { throw "Version must be x.y.z: $Version" }
  if (-not $AllowBranch) {
    $Branch = (git -C $Root rev-parse --abbrev-ref HEAD).Trim()
    if ($Branch -ne "main") { throw "Releases must be built from main (current: $Branch)." }
    if (git -C $Root status --porcelain) {
      throw "The working tree is dirty. Commit or stash changes before releasing."
    }
    git -C $Root fetch origin main
    if ($LASTEXITCODE -ne 0) { throw "Could not fetch origin/main." }
    if ((git -C $Root rev-parse HEAD).Trim() -ne (git -C $Root rev-parse origin/main).Trim()) {
      throw "Local main must exactly match origin/main."
    }
  }
  $BuildNumber = [int](git -C $Root rev-list --count HEAD).Trim()
  # scripts/publish.sh sets the version in a commit of its own. Built before
  # that commit exists, this takes the number that commit will have, so that
  # every platform of the release has the same one.
  if ($Manifest.version -ne $Version) { $BuildNumber += 1 }
} else {
  $Version = $Manifest.version
}

function Resolve-InnoCompiler {
  if ($env:LISTENOOK_ISCC) {
    if (-not (Test-Path -LiteralPath $env:LISTENOOK_ISCC -PathType Leaf)) {
      throw "LISTENOOK_ISCC does not point to ISCC.exe: $env:LISTENOOK_ISCC"
    }
    return (Resolve-Path -LiteralPath $env:LISTENOOK_ISCC).Path
  }
  $Command = Get-Command ISCC.exe -ErrorAction SilentlyContinue
  if ($Command) { return $Command.Source }
  $Candidates = @()
  foreach ($BaseDirectory in @(${env:ProgramFiles(x86)}, $env:ProgramFiles)) {
    if (-not $BaseDirectory) { continue }
    foreach ($MajorVersion in @(7, 6)) {
      $Candidates += Join-Path $BaseDirectory "Inno Setup $MajorVersion\ISCC.exe"
    }
  }
  foreach ($Candidate in $Candidates) {
    if (Test-Path -LiteralPath $Candidate -PathType Leaf) {
      return (Resolve-Path -LiteralPath $Candidate).Path
    }
  }
  throw "Inno Setup 6 or 7 is required for Windows release builds. Install it, add ISCC.exe to PATH, or set LISTENOOK_ISCC."
}

function Resolve-SignTool {
  if ($env:LISTENOOK_SIGNTOOL) {
    if (-not (Test-Path -LiteralPath $env:LISTENOOK_SIGNTOOL -PathType Leaf)) {
      throw "LISTENOOK_SIGNTOOL does not point to signtool.exe: $env:LISTENOOK_SIGNTOOL"
    }
    return (Resolve-Path -LiteralPath $env:LISTENOOK_SIGNTOOL).Path
  }
  $Command = Get-Command signtool.exe -ErrorAction SilentlyContinue
  if ($Command) { return $Command.Source }
  $SdkBin = "${env:ProgramFiles(x86)}\Windows Kits\10\bin"
  $ToolArch = if ($HostArch -eq "ARM64") { "arm64" } else { "x64" }
  if (Test-Path -LiteralPath $SdkBin -PathType Container) {
    $Candidate = Get-ChildItem -LiteralPath $SdkBin -Directory |
      Sort-Object Name -Descending |
      ForEach-Object { Join-Path $_.FullName "$ToolArch\signtool.exe" } |
      Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } |
      Select-Object -First 1
    if ($Candidate) { return $Candidate }
  }
  throw "signtool.exe is required when LISTENOOK_WINDOWS_PFX is set. Install the Windows SDK, add signtool.exe to PATH, or set LISTENOOK_SIGNTOOL."
}

$SignTool = $null
function Invoke-CodeSign([string]$Path) {
  if (-not $env:LISTENOOK_WINDOWS_PFX) { return }
  if (-not (Test-Path -LiteralPath $env:LISTENOOK_WINDOWS_PFX -PathType Leaf)) {
    throw "LISTENOOK_WINDOWS_PFX does not exist: $env:LISTENOOK_WINDOWS_PFX"
  }
  if (-not $SignTool) { $SignTool = Resolve-SignTool }
  $SignArgs = @("sign", "/fd", "SHA256", "/f", $env:LISTENOOK_WINDOWS_PFX)
  if ($env:LISTENOOK_WINDOWS_PFX_PASSWORD) {
    $SignArgs += @("/p", $env:LISTENOOK_WINDOWS_PFX_PASSWORD)
  }
  if ($env:LISTENOOK_WINDOWS_TIMESTAMP_URL) {
    $SignArgs += @("/tr", $env:LISTENOOK_WINDOWS_TIMESTAMP_URL, "/td", "SHA256")
  }
  $SignArgs += $Path
  & $SignTool @SignArgs
  if ($LASTEXITCODE -ne 0) { throw "Code signing failed: $Path" }
}

Push-Location $Root
try {
  $Package = Join-Path $Root "build\nsh\windows-$Arch"
  if (Test-Path $Package) { Remove-Item $Package -Recurse -Force }
  $PackageArgs = @("package", "--target", "windows", "--out", $Package, "--app-version", $Version)
  # What About shows, whatever version Cargo.toml has when this is built.
  $env:LISTENOOK_VERSION = $Version
  if ($BuildNumber) { $PackageArgs += @("--build", $BuildNumber) }
  & nsh @PackageArgs
  if ($LASTEXITCODE -ne 0) { throw "nsh package failed." }

  $Build = Join-Path $Package $Name
  $Executable = Join-Path $Build "$Name.exe"
  if (-not (Test-Path -LiteralPath $Executable -PathType Leaf)) {
    throw "Missing build product: $Executable"
  }
  $NoticeDest = Join-Path $Build "third_party"
  New-Item -ItemType Directory -Force -Path $NoticeDest | Out-Null
  Copy-Item (Join-Path $Root "packaging\notices\APACHE-2.0.txt") $NoticeDest -Force

  function Get-PeMachine([string]$Path) {
    $Stream = [System.IO.File]::OpenRead($Path)
    try {
      $Reader = New-Object System.IO.BinaryReader($Stream)
      $Stream.Position = 0x3c
      $PeOffset = $Reader.ReadInt32()
      $Stream.Position = $PeOffset + 4
      return $Reader.ReadUInt16()
    } finally {
      $Stream.Dispose()
    }
  }
  $Machine = Get-PeMachine $Executable
  if ($Machine -ne 0x8664) {
    throw "Architecture mismatch in $Name.exe: expected 8664, got $([Convert]::ToString($Machine, 16))."
  }
  if ($Mode -eq "release") { Invoke-CodeSign $Executable }

  $Out = Join-Path $Root "build"
  New-Item -ItemType Directory -Force -Path $Out | Out-Null
  if ($Mode -eq "debug") {
    $Portable = Join-Path $Out "$Name-$Arch-debug"
    $PortableStage = Join-Path $Out ".$Name-$Arch-debug.staging"
    if (Test-Path $PortableStage) { Remove-Item $PortableStage -Recurse -Force }
    Copy-Item -LiteralPath $Build -Destination $PortableStage -Recurse -Force
    if (Test-Path $Portable) { Remove-Item $Portable -Recurse -Force }
    Move-Item -LiteralPath $PortableStage -Destination $Portable
    Write-Output "Built $Portable"
    return
  }

  # What the in-app updater downloads, under the name `nsh update-manifest`
  # reads the platform from. It is made again here, laid out as nsh laid
  # it out, so that it holds the signed executable and the notices.
  $UpdateName = "$Name-$Version-windows-x86_64.zip"
  $Packaged = Join-Path $Package $UpdateName
  if (-not (Test-Path -LiteralPath $Packaged -PathType Leaf)) {
    throw "nsh package did not write the updater archive: $Packaged (is ""updater"" set in nsh.json?)"
  }
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  $Existing = [System.IO.Compression.ZipFile]::OpenRead($Packaged)
  try {
    $InFolder = [bool]($Existing.Entries | Where-Object { $_.FullName -like "$Name/*" -or $_.FullName -like "$Name\*" } | Select-Object -First 1)
  } finally {
    $Existing.Dispose()
  }
  $UpdateArchive = Join-Path $Out $UpdateName
  if (Test-Path $UpdateArchive) { Remove-Item $UpdateArchive -Force }
  [System.IO.Compression.ZipFile]::CreateFromDirectory(
    $Build, $UpdateArchive, [System.IO.Compression.CompressionLevel]::Optimal, $InFolder)

  $InnoCompiler = Resolve-InnoCompiler
  $SetupBase = "$Name-$Version-windows-$Arch-$Mode-setup"
  $Setup = Join-Path $Out "$SetupBase.exe"
  if (Test-Path $Setup) { Remove-Item $Setup -Force }
  $Publisher = if ($env:LISTENOOK_WINDOWS_PUBLISHER) { $env:LISTENOOK_WINDOWS_PUBLISHER } else { "Capyvibe" }
  $InnoArgs = @(
    "/Qp",
    "/DAppVersion=$Version",
    "/DAppArch=$Arch",
    "/DAppPublisher=$Publisher",
    "/DBuildDir=$Build",
    "/DOutputDir=$Out",
    "/DOutputBaseName=$SetupBase",
    "/DSetupIcon=$(Join-Path $Root 'packaging\windows\app_icon.ico')",
    (Join-Path $Root "packaging\windows\Listenook.iss")
  )
  & $InnoCompiler @InnoArgs
  if ($LASTEXITCODE -ne 0) { throw "Inno Setup packaging failed." }
  if (-not (Test-Path -LiteralPath $Setup -PathType Leaf)) {
    throw "Missing Inno Setup installer: $Setup"
  }
  Invoke-CodeSign $Setup

  if ($BuildNumber) {
    # Where the installer came from, for the machine that publishes it.
    [ordered]@{
      version = $Version
      build = [int]$BuildNumber
      commit = (git -C $Root rev-parse HEAD).Trim()
      architecture = $Arch
      dirty = [bool](git -C $Root status --porcelain)
    } | ConvertTo-Json | Set-Content -LiteralPath "$Setup.build.json" -Encoding ascii
  }
  Write-Output "Built $Setup"
  Write-Output "Built $UpdateArchive"
} finally {
  Pop-Location
}
