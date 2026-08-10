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

  $Out = Join-Path $Root "dist"
  New-Item -ItemType Directory -Force -Path $Out | Out-Null
  $Base = "MeowSTT-$Version-windows-$Arch-$Mode"
  $Zip = Join-Path $Out "$Base-portable.zip"
  if (Test-Path $Zip) { Remove-Item $Zip -Force }
  Compress-Archive -Path (Join-Path $Build "*") -DestinationPath $Zip -CompressionLevel Optimal

  $MsixArgs = @(
    "run", "msix:create", "--build-windows", "false", "--architecture", $Arch,
    "--$Mode", "--output-path", $Out, "--output-name", $Base,
    "--install-certificate", "false"
  )
  if ($env:MEOWSTT_WINDOWS_PFX) {
    $MsixArgs += @("--certificate-path", $env:MEOWSTT_WINDOWS_PFX)
    if ($env:MEOWSTT_WINDOWS_PFX_PASSWORD) {
      $MsixArgs += @("--certificate-password", $env:MEOWSTT_WINDOWS_PFX_PASSWORD)
    }
    if ($env:MEOWSTT_WINDOWS_PUBLISHER) {
      $MsixArgs += @("--publisher", $env:MEOWSTT_WINDOWS_PUBLISHER)
    }
  }
  & dart @MsixArgs
  if ($LASTEXITCODE -ne 0) { throw "MSIX packaging failed." }

  $Checksums = Join-Path $Out "$Base.sha256"
  Get-ChildItem $Out -File -Filter "$Base*" | Where-Object { $_.FullName -ne $Checksums } | ForEach-Object {
    $Hash = (Get-FileHash $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    "$Hash  $($_.Name)"
  } | Set-Content $Checksums -Encoding ascii
  Write-Output "Artifacts: $Out"
} finally {
  Pop-Location
}
