param(
  [Parameter(Mandatory = $true)]
  [ValidateSet("debug", "release")]
  [string]$Mode,
  [ValidateSet("x64", "arm64")]
  [string]$Arch = "x64"
)

$ErrorActionPreference = "Stop"
$Root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$HostArch = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
$ExpectedHost = if ($Arch -eq "x64") { "AMD64" } else { "ARM64" }
if ($HostArch -ne $ExpectedHost) {
  throw "Flutter selects the Windows host architecture. Build $Arch on a native $ExpectedHost Windows host (current: $HostArch)."
}

$VersionLine = Select-String -Path (Join-Path $Root "pubspec.yaml") -Pattern '^version:\s*([^+\s]+)'
$Version = $VersionLine.Matches[0].Groups[1].Value
$Configuration = if ($Mode -eq "release") { "Release" } else { "Debug" }

function Resolve-InnoCompiler {
  if ($env:MEOWSTT_ISCC) {
    if (-not (Test-Path -LiteralPath $env:MEOWSTT_ISCC -PathType Leaf)) {
      throw "MEOWSTT_ISCC does not point to ISCC.exe: $env:MEOWSTT_ISCC"
    }
    return (Resolve-Path -LiteralPath $env:MEOWSTT_ISCC).Path
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
  throw "Inno Setup 6 or 7 is required for Windows release builds. Install it, add ISCC.exe to PATH, or set MEOWSTT_ISCC."
}

function Resolve-SignTool {
  if ($env:MEOWSTT_SIGNTOOL) {
    if (-not (Test-Path -LiteralPath $env:MEOWSTT_SIGNTOOL -PathType Leaf)) {
      throw "MEOWSTT_SIGNTOOL does not point to signtool.exe: $env:MEOWSTT_SIGNTOOL"
    }
    return (Resolve-Path -LiteralPath $env:MEOWSTT_SIGNTOOL).Path
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
  throw "signtool.exe is required when MEOWSTT_WINDOWS_PFX is set. Install the Windows SDK, add signtool.exe to PATH, or set MEOWSTT_SIGNTOOL."
}

$SignTool = $null
function Invoke-CodeSign([string]$Path) {
  if (-not $env:MEOWSTT_WINDOWS_PFX) { return }
  if (-not (Test-Path -LiteralPath $env:MEOWSTT_WINDOWS_PFX -PathType Leaf)) {
    throw "MEOWSTT_WINDOWS_PFX does not exist: $env:MEOWSTT_WINDOWS_PFX"
  }
  if (-not $SignTool) { $SignTool = Resolve-SignTool }
  $SignArgs = @("sign", "/fd", "SHA256", "/f", $env:MEOWSTT_WINDOWS_PFX)
  if ($env:MEOWSTT_WINDOWS_PFX_PASSWORD) {
    $SignArgs += @("/p", $env:MEOWSTT_WINDOWS_PFX_PASSWORD)
  }
  if ($env:MEOWSTT_WINDOWS_TIMESTAMP_URL) {
    $SignArgs += @("/tr", $env:MEOWSTT_WINDOWS_TIMESTAMP_URL, "/td", "SHA256")
  }
  $SignArgs += $Path
  & $SignTool @SignArgs
  if ($LASTEXITCODE -ne 0) { throw "Code signing failed: $Path" }
}

Push-Location $Root
try {
  & flutter build windows "--$Mode"
  if ($LASTEXITCODE -ne 0) { throw "Flutter Windows build failed." }

  $Build = Join-Path $Root "build\windows\$Arch\runner\$Configuration"
  if (-not (Test-Path $Build)) {
    $Build = Join-Path $Root "build\windows\runner\$Configuration"
  }
  if (-not (Test-Path (Join-Path $Build "MeowSTT.exe"))) {
    throw "Missing native build product: $Build\MeowSTT.exe"
  }

  $Helper = & (Join-Path $PSScriptRoot "fetch-ffmpeg.ps1") -Arch $Arch
  $HelperDest = Join-Path $Build "ffmpeg"
  $NoticeDest = Join-Path $Build "third_party"
  New-Item -ItemType Directory -Force -Path $HelperDest, $NoticeDest | Out-Null
  Copy-Item (Join-Path $Helper "ffmpeg.exe") $HelperDest -Force
  Copy-Item (Join-Path $Helper "ffprobe.exe") $HelperDest -Force
  Copy-Item (Join-Path $Root "assets\third_party\*") $NoticeDest -Force
  Copy-Item (Join-Path $Root "packaging\ffmpeg\manifest.json") (Join-Path $NoticeDest "ffmpeg-manifest.json") -Force

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
  foreach ($Binary in @("MeowSTT.exe", "ffmpeg\ffmpeg.exe", "ffmpeg\ffprobe.exe")) {
    $Machine = Get-PeMachine (Join-Path $Build $Binary)
    if ($Machine -ne $ExpectedMachine) {
      throw "Architecture mismatch in $Binary`: expected $([Convert]::ToString($ExpectedMachine, 16)), got $([Convert]::ToString($Machine, 16))."
    }
  }
  if ($Mode -eq "release") {
    Invoke-CodeSign (Join-Path $Build "MeowSTT.exe")
  }

  $Out = Join-Path $Root "dist"
  New-Item -ItemType Directory -Force -Path $Out | Out-Null
  $Base = "MeowSTT-$Version-windows-$Arch-$Mode"
  $Zip = Join-Path $Out "$Base-portable.zip"
  if (Test-Path $Zip) { Remove-Item $Zip -Force }
  Compress-Archive -Path (Join-Path $Build "*") -DestinationPath $Zip -CompressionLevel Optimal

  $LegacyMsix = Join-Path $Out "$Base.msix"
  if (Test-Path $LegacyMsix) { Remove-Item $LegacyMsix -Force }
  if ($Mode -eq "release") {
    $InnoCompiler = Resolve-InnoCompiler
    $SetupBase = "$Base-setup"
    $Setup = Join-Path $Out "$SetupBase.exe"
    if (Test-Path $Setup) { Remove-Item $Setup -Force }
    $Publisher = if ($env:MEOWSTT_WINDOWS_PUBLISHER) { $env:MEOWSTT_WINDOWS_PUBLISHER } else { "MeowSTT" }
    $InnoArgs = @(
      "/Qp",
      "/DAppVersion=$Version",
      "/DAppArch=$Arch",
      "/DAppPublisher=$Publisher",
      "/DBuildDir=$Build",
      "/DOutputDir=$Out",
      "/DOutputBaseName=$SetupBase",
      "/DSetupIcon=$(Join-Path $Root 'windows\runner\resources\app_icon.ico')",
      (Join-Path $Root "packaging\windows\MeowSTT.iss")
    )
    & $InnoCompiler @InnoArgs
    if ($LASTEXITCODE -ne 0) { throw "Inno Setup packaging failed." }
    if (-not (Test-Path -LiteralPath $Setup -PathType Leaf)) {
      throw "Missing Inno Setup installer: $Setup"
    }
    Invoke-CodeSign $Setup
  }

  $Checksums = Join-Path $Out "$Base.sha256"
  Get-ChildItem $Out -File -Filter "$Base*" | Where-Object { $_.FullName -ne $Checksums } | ForEach-Object {
    $Hash = (Get-FileHash $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    "$Hash  $($_.Name)"
  } | Set-Content $Checksums -Encoding ascii
  Write-Output "Artifacts: $Out"
} finally {
  Pop-Location
}
