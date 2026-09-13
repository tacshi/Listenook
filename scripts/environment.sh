#!/usr/bin/env bash
# Compatibility for existing automation. Explicit new values win; values are never logged.
listenook_import_legacy_environment() {
  local legacy name
  while IFS= read -r legacy; do
    case "$legacy" in
      MEOWSTT_*)
        name="LISTENOOK_${legacy#MEOWSTT_}"
        if ! printenv "$name" >/dev/null 2>&1; then
          export "$name=${!legacy}"
        fi
        ;;
    esac
  done < <(compgen -e)
}
listenook_import_legacy_environment
