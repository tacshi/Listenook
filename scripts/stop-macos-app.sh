#!/usr/bin/env bash
set -euo pipefail

EXECUTABLE="${1:?usage: stop-macos-app.sh /path/to/App.app/Contents/MacOS/executable}"

running_pids() {
  while IFS= read -r LINE; do
    LINE="${LINE#"${LINE%%[![:space:]]*}"}"
    PID="${LINE%%[[:space:]]*}"
    COMMAND="${LINE#"$PID"}"
    COMMAND="${COMMAND#"${COMMAND%%[![:space:]]*}"}"
    if [[ "$COMMAND" == "$EXECUTABLE" || "$COMMAND" == "$EXECUTABLE "* ]]; then
      printf '%s\n' "$PID"
    fi
  done < <(ps -axww -o pid= -o command=)
}

PIDS=()
while IFS= read -r PID; do
  PIDS+=("$PID")
done < <(running_pids)
if [[ ${#PIDS[@]} -eq 0 ]]; then
  exit 0
fi

kill -TERM "${PIDS[@]}" 2>/dev/null || true
for _ in {1..50}; do
  if ! bash "$(dirname "${BASH_SOURCE[0]}")/is-macos-app-running.sh" "$EXECUTABLE"; then
    exit 0
  fi
  sleep 0.1
done

echo "Debug app did not close gracefully; forcing it to stop." >&2
PIDS=()
while IFS= read -r PID; do
  PIDS+=("$PID")
done < <(running_pids)
if [[ ${#PIDS[@]} -gt 0 ]]; then
  kill -KILL "${PIDS[@]}" 2>/dev/null || true
fi
for _ in {1..20}; do
  if ! bash "$(dirname "${BASH_SOURCE[0]}")/is-macos-app-running.sh" "$EXECUTABLE"; then
    exit 0
  fi
  sleep 0.1
done

echo "Unable to stop the running debug app: $EXECUTABLE" >&2
exit 1
