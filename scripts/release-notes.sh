# shellcheck shell=bash

# Prints the change subjects of one commit body, if it is a squash merge.
#
# GitHub writes a squash merge's body as one "* <subject>" line per branch
# commit, each followed by a blank line and then that commit's own body. A
# commit body may itself hold "* " list items; those wrap onto further lines,
# so only a "* " line that stands alone as a paragraph is a subject.
squash_subjects() {
  awk '
    function flush() {
      if (lines == 1 && first ~ /^\*[[:space:]]+/) {
        sub(/^\*[[:space:]]+/, "", first)
        print first
      }
      lines = 0
    }
    /^[[:space:]]*$/ { flush(); next }
    { if (lines == 0) first = $0; lines++ }
    END { flush() }
  '
}

collect_release_note_subjects() {
  local log_args=("$@")
  local sha bullets

  while IFS= read -r sha; do
    bullets="$(git log -1 --pretty=tformat:'%b' "$sha" | squash_subjects)"
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
  # bullets. Prefer those subjects over the wrapper pull-request title. A
  # change that landed through more than one pull request is listed once.
  collect_release_note_subjects "$@" \
    | grep -viE '^(chore|ci|build|test|style|refactor|docs)(\([^)]*\))?!?:' \
    | grep -viE '^(release|bump|merge|wip)([[:space:]]|$)' \
    | grep -vE '^(fixup|squash|amend)!' \
    | sed -E 's/^[a-zA-Z]+(\([^)]*\))?!?:[[:space:]]*//' \
    | sed -E 's/[[:space:]]*\(#[0-9]+\)$//' \
    | awk '!seen[$0]++' \
    | sed -E 's/^/- /' \
    > "$notes_file" || true
}
