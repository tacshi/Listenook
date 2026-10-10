param(
  [Parameter(Mandatory = $true)]
  [ValidateSet("debug", "release")]
  [string]$Mode,
  [ValidateSet("x64", "arm64")]
  [string]$Arch = "x64",
  [string]$BuildName,
  [string]$BuildNumber
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "environment.ps1")
$Root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$HostArch = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
$ExpectedHost = if ($Arch -eq "x64") { "AMD64" } else { "ARM64" }
if ($HostArch -ne $ExpectedHost) {
  throw "Flutter selects the Windows host architecture. Build $Arch on a native $ExpectedHost Windows host (current: $HostArch)."
}

$VersionLine = Select-String -Path (Join-Path $Root "pubspec.yaml") -Pattern '^version:\s*([^+\s]+)'
$Version = if ($BuildName) { $BuildName } else { $VersionLine.Matches[0].Groups[1].Value }
$Configuration = if ($Mode -eq "release") { "Release" } else { "Debug" }

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
  $FlutterArgs = @("build", "windows", "--$Mode")
  if ($BuildName) { $FlutterArgs += @("--build-name", $BuildName) }
  if ($BuildNumber) { $FlutterArgs += @("--build-number", $BuildNumber) }
  & flutter @FlutterArgs
  if ($LASTEXITCODE -ne 0) { throw "Flutter Windows build failed." }

  $Build = Join-Path $Root "build\windows\$Arch\runner\$Configuration"
  if (-not (Test-Path $Build)) {
    $Build = Join-Path $Root "build\windows\runner\$Configuration"
  }
  if (-not (Test-Path (Join-Path $Build "Listenook.exe"))) {
    throw "Missing native build product: $Build\Listenook.exe"
  }

  # Incremental builds retain the old runner; keep it out of portable packages
  # and installers, which copy every file in the build directory.
  foreach ($LegacyBinary in @("MeowSTT.exe", "MeowSTT.pdb")) {
    $LegacyBinaryPath = Join-Path $Build $LegacyBinary
    if (Test-Path -LiteralPath $LegacyBinaryPath -PathType Leaf) {
      Remove-Item -LiteralPath $LegacyBinaryPath -Force
    }
  }

  $Encoder = & (Join-Path $PSScriptRoot "fetch-flac.ps1") -Arch $Arch
  $EncoderDest = Join-Path $Build "flac"
  $LegacyHelperDest = Join-Path $Build "ffmpeg"
  $NoticeDest = Join-Path $Build "third_party"
  if (Test-Path -LiteralPath $LegacyHelperDest -PathType Container) {
    Remove-Item -LiteralPath $LegacyHelperDest -Recurse -Force
  }
  if (Test-Path -LiteralPath $EncoderDest -PathType Container) {
    Remove-Item -LiteralPath $EncoderDest -Recurse -Force
  }
  New-Item -ItemType Directory -Force -Path $EncoderDest, $NoticeDest | Out-Null
  Copy-Item (Join-Path $Encoder "flac.exe") $EncoderDest -Force
  $FlacLibrary = Join-Path $Encoder "libFLAC.dll"
  if (Test-Path -LiteralPath $FlacLibrary -PathType Leaf) {
    Copy-Item $FlacLibrary $EncoderDest -Force
  }
  Copy-Item (Join-Path $Root "assets\third_party\*") $NoticeDest -Force
  $LegacyManifest = Join-Path $NoticeDest "ffmpeg-manifest.json"
  if (Test-Path -LiteralPath $LegacyManifest -PathType Leaf) {
    Remove-Item -LiteralPath $LegacyManifest -Force
  }
  Copy-Item (Join-Path $Root "packaging\flac\manifest.json") (Join-Path $NoticeDest "flac-manifest.json") -Force
  Copy-Item (Join-Path $Root ".tools\flac\downloads\1.5.0\flac-1.5.0.tar.xz") $NoticeDest -Force

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
  $ExpectedMachine = if ($Arch -eq "x64") { 0x8664 } else { 0xAA64 }
  $NativeBinaries = @("Listenook.exe", "flac\flac.exe")
  if (Test-Path -LiteralPath (Join-Path $Build "flac\libFLAC.dll") -PathType Leaf) {
    $NativeBinaries += "flac\libFLAC.dll"
  }
  foreach ($Binary in $NativeBinaries) {
    $Machine = Get-PeMachine (Join-Path $Build $Binary)
    if ($Machine -ne $ExpectedMachine) {
      throw "Architecture mismatch in $Binary`: expected $([Convert]::ToString($ExpectedMachine, 16)), got $([Convert]::ToString($Machine, 16))."
    }
  }
  if ($Mode -eq "release") {
    foreach ($Binary in $NativeBinaries) {
      Invoke-CodeSign (Join-Path $Build $Binary)
    }
  }

  $Out = Join-Path $Root "dist"
  New-Item -ItemType Directory -Force -Path $Out | Out-Null
  $Base = "Listenook-$Version-windows-$Arch-$Mode"
  $Zip = Join-Path $Out "$Base-portable.zip"
  if ($Mode -eq "debug") {
    $Portable = Join-Path $Out "$Base-portable"
    $PortableStage = Join-Path $Out ".$Base-portable.staging"
    if (Test-Path $Zip) { Remove-Item $Zip -Force }
    if (Test-Path $PortableStage) { Remove-Item $PortableStage -Recurse -Force }
    Copy-Item -LiteralPath $Build -Destination $PortableStage -Recurse -Force
    if (Test-Path $Portable) { Remove-Item $Portable -Recurse -Force }
    Move-Item -LiteralPath $PortableStage -Destination $Portable
  } else {
    if (Test-Path $Zip) { Remove-Item $Zip -Force }
    Compress-Archive -Path (Join-Path $Build "*") -DestinationPath $Zip -CompressionLevel Optimal
  }

  $LegacyMsix = Join-Path $Out "$Base.msix"
  if (Test-Path $LegacyMsix) { Remove-Item $LegacyMsix -Force }
  if ($Mode -eq "release") {
    $InnoCompiler = Resolve-InnoCompiler
    $SetupBase = "$Base-setup"
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
      "/DSetupIcon=$(Join-Path $Root 'windows\runner\resources\app_icon.ico')",
      (Join-Path $Root "packaging\windows\Listenook.iss")
    )
    & $InnoCompiler @InnoArgs
    if ($LASTEXITCODE -ne 0) { throw "Inno Setup packaging failed." }
    if (-not (Test-Path -LiteralPath $Setup -PathType Leaf)) {
      throw "Missing Inno Setup installer: $Setup"
    }
    Invoke-CodeSign $Setup
  }

  Write-Output "Artifacts: $Out"
} finally {
  Pop-Location
}
