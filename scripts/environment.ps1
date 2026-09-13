# Compatibility for existing build automation; never echo credential values.
Get-ChildItem Env:MEOWSTT_* -ErrorAction SilentlyContinue | ForEach-Object {
  $Name = $_.Name -replace '^MEOWSTT_', 'LISTENOOK_'
  if ($null -eq [Environment]::GetEnvironmentVariable($Name, 'Process')) {
    [Environment]::SetEnvironmentVariable($Name, $_.Value, 'Process')
  }
}
