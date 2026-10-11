# Dot-source after setting $Root. Resolves the exact Flutter SDK pinned in
# .fvmrc: desktop builds need the master-channel SDK for Flutter's multi-window
# API (lib/core/windowing/), and the Flutter on PATH is usually stable.
function Resolve-ListenookFlutter([string]$ProjectRoot) {
  $pin = (Get-Content -Raw (Join-Path $ProjectRoot '.fvmrc') | ConvertFrom-Json).flutter
  $sdk = Join-Path $ProjectRoot '.fvm\flutter_sdk'
  $executable = Join-Path $sdk 'bin\flutter.bat'

  function Test-PinnedSdk {
    if (-not (Test-Path $executable)) { return $false }
    $revision = & git -C $sdk rev-parse HEAD 2>$null
    return $LASTEXITCODE -eq 0 -and "$revision".Trim() -eq $pin
  }

  if (-not (Test-PinnedSdk)) {
    $fvmCommand = Get-Command fvm -ErrorAction SilentlyContinue |
      Select-Object -First 1
    $fvm = if ($fvmCommand) { $fvmCommand.Source } else { $null }
    if (-not $fvm) {
      # dart pub global activate installs the shim here but does not put this
      # directory on PATH automatically on Windows.
      $pubCache = if ($env:PUB_CACHE) {
        $env:PUB_CACHE
      } else {
        Join-Path $env:LOCALAPPDATA 'Pub\Cache'
      }
      $shim = Join-Path $pubCache 'bin\fvm.bat'
      if (Test-Path -LiteralPath $shim -PathType Leaf) { $fvm = $shim }
    }
    if (-not $fvm) {
      throw 'Install FVM (dart pub global activate fvm) to use the Flutter SDK pinned in .fvmrc.'
    }
    Push-Location $ProjectRoot
    try {
      & $fvm install --setup | Out-Host
      if ($LASTEXITCODE -ne 0) { throw 'Could not install the pinned Flutter SDK.' }
      & $fvm use --skip-pub-get --force | Out-Host
      if ($LASTEXITCODE -ne 0) { throw 'Could not select the pinned Flutter SDK.' }
    } finally {
      Pop-Location
    }
  }
  if (-not (Test-PinnedSdk)) {
    throw "The Flutter SDK in $sdk does not match .fvmrc ($pin)."
  }
  return $executable
}

$script:ListenookFlutter = Resolve-ListenookFlutter $Root
