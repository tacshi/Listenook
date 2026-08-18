# shellcheck shell=bash

collect_release_note_subjects() {
  local log_args=("$@")
  local sha bullets

  while IFS= read -r sha; do
    bullets="$(
      git log -1 --pretty=tformat:'%b' "$sha" \
        | sed -nE 's/^\*[[:space:]]+//p'
    )"
    if [[ -n "$bullets" ]]; then
      printf '%s\n' "$bullets"
    else
      git log -1 --pretty=tformat:'%s' "$sha"
    fi
  done < <(git log --no-merges --pretty=tformat:'%H' "${log_args[@]}")
}

write_release_notes() {
  local notes_file="$1"
  shift

  # GitHub squash merges retain the branch's commit subjects as "* ..." body
  # bullets. Prefer those subjects over the wrapper pull-request title.
  collect_release_note_subjects "$@" \
    | grep -viE '^(chore|ci|build|test|style|refactor|docs)(\([^)]*\))?!?:' \
    | grep -viE '^(release|bump|merge|wip)([[:space:]]|$)' \
    | sed -E 's/^[a-zA-Z]+(\([^)]*\))?!?:[[:space:]]*//' \
    | sed -E 's/[[:space:]]*\(#[0-9]+\)$//' \
    | sed -E 's/^/- /' \
    > "$notes_file" || true
}
