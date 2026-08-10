param(
  [Parameter(Mandatory = $true)]
  [ValidateSet("x64", "arm64")]
  [string]$Arch
)

$ErrorActionPreference = "Stop"
$Root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$Destination = Join-Path $Root ".tools\ffmpeg\windows\$Arch"
New-Item -ItemType Directory -Force -Path $Destination | Out-Null

if ($env:MEOWSTT_FFMPEG_DIR) {
  Copy-Item (Join-Path $env:MEOWSTT_FFMPEG_DIR "ffmpeg.exe") $Destination -Force
  Copy-Item (Join-Path $env:MEOWSTT_FFMPEG_DIR "ffprobe.exe") $Destination -Force
  Write-Output $Destination
  exit 0
}

$Manifest = Get-Content (Join-Path $Root "packaging\ffmpeg\manifest.json") -Raw | ConvertFrom-Json
$Entry = $Manifest.windows.$Arch
$Archive = Join-Path $Destination "ffmpeg.zip"
$Expected = $Entry.archive.sha256.ToLowerInvariant()
if (-not (Test-Path $Archive) -or (Get-FileHash $Archive -Algorithm SHA256).Hash.ToLowerInvariant() -ne $Expected) {
  Invoke-WebRequest -Uri $Entry.archive.url -OutFile "$Archive.download"
  $Actual = (Get-FileHash "$Archive.download" -Algorithm SHA256).Hash.ToLowerInvariant()
  if ($Actual -ne $Expected) {
    Remove-Item "$Archive.download" -Force
    throw "FFmpeg archive checksum mismatch: $Actual"
  }
  Move-Item "$Archive.download" $Archive -Force
}

$Extracted = Join-Path $Destination "extracted"
if (Test-Path $Extracted) { Remove-Item $Extracted -Recurse -Force }
Expand-Archive -Path $Archive -DestinationPath $Extracted -Force
$FFmpeg = Get-ChildItem $Extracted -Filter ffmpeg.exe -Recurse | Select-Object -First 1
$FFprobe = Get-ChildItem $Extracted -Filter ffprobe.exe -Recurse | Select-Object -First 1
if (-not $FFmpeg -or -not $FFprobe) { throw "The pinned FFmpeg archive is missing ffmpeg.exe or ffprobe.exe." }
Copy-Item $FFmpeg.FullName (Join-Path $Destination "ffmpeg.exe") -Force
Copy-Item $FFprobe.FullName (Join-Path $Destination "ffprobe.exe") -Force
Write-Output $Destination
