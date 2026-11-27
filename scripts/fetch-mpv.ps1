# Downloads the libmpv build for Windows listed in scripts/mpv-libraries.txt into
# vendor\mpv\windows, checking its SHA-256. scripts/build-windows.ps1 runs it.
$ErrorActionPreference = "Stop"
$Root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$Dest = Join-Path $Root "vendor\mpv\windows"
$Downloads = Join-Path $Root "vendor\mpv\.downloads"
$Stamp = Join-Path $Dest ".fetched"

$Wanted = Get-Content -LiteralPath (Join-Path $PSScriptRoot "mpv-libraries.txt") |
  Where-Object { $_ -and -not $_.StartsWith("#") } |
  ForEach-Object { $Fields = $_ -split "\s+"; if ($Fields[0] -eq "windows") { [pscustomobject]@{ Sum = $Fields[1]; Url = $Fields[2] } } }
if (-not $Wanted) { throw "No libmpv is listed for windows." }
$Key = ($Wanted | ForEach-Object { "$($_.Sum) $($_.Url)" }) -join "`n"
if ((Test-Path -LiteralPath $Stamp) -and ((Get-Content -LiteralPath $Stamp -Raw) -eq $Key)) { return }

New-Item -ItemType Directory -Force -Path $Downloads | Out-Null
$Staging = "$Dest.partial"
if (Test-Path $Staging) { Remove-Item $Staging -Recurse -Force }
New-Item -ItemType Directory -Force -Path $Staging | Out-Null
foreach ($Item in $Wanted) {
  $File = Join-Path $Downloads ([IO.Path]::GetFileName($Item.Url))
  if (-not (Test-Path -LiteralPath $File) -or (Get-FileHash -Algorithm SHA256 -LiteralPath $File).Hash -ne $Item.Sum) {
    Write-Output "Downloading $([IO.Path]::GetFileName($Item.Url))"
    Invoke-WebRequest -Uri $Item.Url -OutFile "$File.part"
    Move-Item -Force "$File.part" $File
  }
  if ((Get-FileHash -Algorithm SHA256 -LiteralPath $File).Hash -ne $Item.Sum) {
    throw "$([IO.Path]::GetFileName($Item.Url)) does not match its checksum."
  }
  Expand-Archive -LiteralPath $File -DestinationPath $Staging -Force
}
if (Test-Path $Dest) { Remove-Item $Dest -Recurse -Force }
Move-Item $Staging $Dest
Set-Content -LiteralPath $Stamp -Value $Key -NoNewline
Write-Output "libmpv for windows is in $Dest"
