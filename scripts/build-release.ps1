param(
  [ValidateSet("x64", "arm64")]
  [string]$Arch = "x64"
)
& (Join-Path $PSScriptRoot "build-windows.ps1") -Mode release -Arch $Arch
exit $LASTEXITCODE
