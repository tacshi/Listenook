param(
  [Parameter(Mandatory = $true)]
  [ValidateSet("x64", "arm64")]
  [string]$Arch
)

$ErrorActionPreference = "Stop"
$Root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$Version = "1.5.0"
$Destination = Join-Path $Root ".tools\flac\windows\$Arch"
$Executable = Join-Path $Destination "flac.exe"
$ExpectedMachine = if ($Arch -eq "x64") { 0x8664 } else { 0xAA64 }

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

function Confirm-Encoder([string]$Directory) {
  $Candidate = Join-Path $Directory "flac.exe"
  if (-not (Test-Path -LiteralPath $Candidate -PathType Leaf)) { return $false }
  return (Get-PeMachine $Candidate) -eq $ExpectedMachine
}

function Copy-Encoder([string]$Source) {
  New-Item -ItemType Directory -Force -Path $Destination | Out-Null
  Copy-Item -LiteralPath (Join-Path $Source "flac.exe") -Destination $Destination -Force
  $Library = Join-Path $Source "libFLAC.dll"
  if (Test-Path -LiteralPath $Library -PathType Leaf) {
    Copy-Item -LiteralPath $Library -Destination $Destination -Force
  } else {
    $StaleLibrary = Join-Path $Destination "libFLAC.dll"
    if (Test-Path -LiteralPath $StaleLibrary -PathType Leaf) {
      Remove-Item -LiteralPath $StaleLibrary -Force
    }
  }
}

function Resolve-CMake {
  $Command = Get-Command cmake.exe -ErrorAction SilentlyContinue
  if ($Command) { return $Command.Source }
  $VsWhere = Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio\Installer\vswhere.exe"
  if (Test-Path -LiteralPath $VsWhere -PathType Leaf) {
    $Candidate = & $VsWhere -latest -products "*" -find "Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe" |
      Select-Object -First 1
    if ($Candidate -and (Test-Path -LiteralPath $Candidate -PathType Leaf)) {
      return $Candidate
    }
  }
  throw "CMake is required to build the Windows ARM64 FLAC encoder. Install the Visual Studio C++ CMake tools."
}

$Downloads = Join-Path $Root ".tools\flac\downloads\$Version"
New-Item -ItemType Directory -Force -Path $Downloads | Out-Null
$SourceArchive = Join-Path $Downloads "flac-$Version.tar.xz"
$SourceUrl = "https://github.com/xiph/flac/releases/download/$Version/flac-$Version.tar.xz"
$SourceSha256 = "f2c1c76592a82ffff8413ba3c4a1299b6c7ab06c734dee03fd88630485c2b920"
if (-not (Test-Path -LiteralPath $SourceArchive -PathType Leaf)) {
  Invoke-WebRequest -Uri $SourceUrl -OutFile $SourceArchive
}
$ActualSourceHash = (Get-FileHash -LiteralPath $SourceArchive -Algorithm SHA256).Hash.ToLowerInvariant()
if ($ActualSourceHash -ne $SourceSha256) {
  throw "FLAC source archive checksum mismatch: expected $SourceSha256, got $ActualSourceHash"
}

if (Confirm-Encoder $Destination) {
  Write-Output $Destination
  exit 0
}

if ($env:MEOWSTT_FLAC_DIR) {
  $Override = (Resolve-Path -LiteralPath $env:MEOWSTT_FLAC_DIR).Path
  if (-not (Confirm-Encoder $Override)) {
    throw "MEOWSTT_FLAC_DIR does not contain a native $Arch flac.exe: $Override"
  }
  Copy-Encoder $Override
  Write-Output $Destination
  exit 0
}

if ($Arch -eq "x64") {
  $Archive = Join-Path $Downloads "flac-$Version-win.zip"
  $Url = "https://github.com/xiph/flac/releases/download/$Version/flac-$Version-win.zip"
  $Sha256 = "53f1500f0d6e7c61379d7fee50d4a9f7f504c650009506d9ba015530d76c0dde"
  if (-not (Test-Path -LiteralPath $Archive -PathType Leaf)) {
    Invoke-WebRequest -Uri $Url -OutFile $Archive
  }
  $Actual = (Get-FileHash -LiteralPath $Archive -Algorithm SHA256).Hash.ToLowerInvariant()
  if ($Actual -ne $Sha256) {
    throw "FLAC Windows archive checksum mismatch: expected $Sha256, got $Actual"
  }
  $Extracted = Join-Path $Downloads "windows"
  $Source = Join-Path $Extracted "flac-$Version-win\Win64"
  if (-not (Test-Path -LiteralPath (Join-Path $Source "flac.exe") -PathType Leaf)) {
    if (Test-Path -LiteralPath $Extracted -PathType Container) {
      Remove-Item -LiteralPath $Extracted -Recurse -Force
    }
    Expand-Archive -LiteralPath $Archive -DestinationPath $Extracted
  }
  Copy-Encoder $Source
} else {
  $CMake = Resolve-CMake
  $SourceParent = Join-Path $Downloads "source"
  $Source = Join-Path $SourceParent "flac-$Version"
  if (-not (Test-Path -LiteralPath (Join-Path $Source "CMakeLists.txt") -PathType Leaf)) {
    if (Test-Path -LiteralPath $SourceParent -PathType Container) {
      Remove-Item -LiteralPath $SourceParent -Recurse -Force
    }
    New-Item -ItemType Directory -Force -Path $SourceParent | Out-Null
    & tar.exe -xf $SourceArchive -C $SourceParent
    if ($LASTEXITCODE -ne 0) { throw "Could not extract the FLAC source archive." }
  }
  $Build = Join-Path $Root ".tools\flac\build\windows-arm64-$Version"
  & $CMake -S $Source -B $Build -A ARM64 `
    -DBUILD_PROGRAMS=ON `
    -DBUILD_CXXLIBS=OFF `
    -DBUILD_EXAMPLES=OFF `
    -DBUILD_TESTING=OFF `
    -DBUILD_DOCS=OFF `
    -DINSTALL_MANPAGES=OFF `
    -DWITH_OGG=OFF `
    -DBUILD_SHARED_LIBS=OFF
  if ($LASTEXITCODE -ne 0) { throw "Could not configure the ARM64 FLAC encoder." }
  & $CMake --build $Build --config Release --target flacapp
  if ($LASTEXITCODE -ne 0) { throw "Could not build the ARM64 FLAC encoder." }
  $Built = Get-ChildItem -LiteralPath $Build -Recurse -Filter "flac.exe" -File |
    Where-Object { (Get-PeMachine $_.FullName) -eq $ExpectedMachine } |
    Select-Object -First 1
  if (-not $Built) { throw "The ARM64 FLAC build did not produce flac.exe." }
  New-Item -ItemType Directory -Force -Path $Destination | Out-Null
  Copy-Item -LiteralPath $Built.FullName -Destination $Executable -Force
  $StaleLibrary = Join-Path $Destination "libFLAC.dll"
  if (Test-Path -LiteralPath $StaleLibrary -PathType Leaf) {
    Remove-Item -LiteralPath $StaleLibrary -Force
  }
}

if (-not (Confirm-Encoder $Destination)) {
  throw "The prepared FLAC encoder is not native ${Arch}: $Executable"
}
Write-Output $Destination
