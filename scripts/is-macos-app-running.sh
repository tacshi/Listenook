#!/usr/bin/env bash
set -euo pipefail

EXECUTABLE="${1:?usage: is-macos-app-running.sh /path/to/App.app/Contents/MacOS/executable}"

while IFS= read -r COMMAND; do
  if [[ "$COMMAND" == "$EXECUTABLE" || "$COMMAND" == "$EXECUTABLE "* ]]; then
    exit 0
  fi
done < <(ps -axww -o command=)

exit 1
