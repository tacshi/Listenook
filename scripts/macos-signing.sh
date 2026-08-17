#!/usr/bin/env bash

resolve_meowstt_debug_sign_identity() {
  local root="${1:?MeowSTT repository root is required}"
  if [[ -n "${MEOWSTT_MAC_DEBUG_SIGN_IDENTITY:-}" ]]; then
    printf '%s\n' "$MEOWSTT_MAC_DEBUG_SIGN_IDENTITY"
    return
  fi
  if [[ -n "${MEOWSTT_MAC_SIGN_IDENTITY:-}" ]]; then
    printf '%s\n' "$MEOWSTT_MAC_SIGN_IDENTITY"
    return
  fi
  if [[ -n "${DEVELOPER_ID_APPLICATION:-}" ]]; then
    printf '%s\n' "$DEVELOPER_ID_APPLICATION"
    return
  fi

  local identities developer_identities reference team matched count
  identities="$(security find-identity -v -p codesigning 2>/dev/null || true)"
  developer_identities="$(
    printf '%s\n' "$identities" \
      | grep '"Developer ID Application:' \
      || true
  )"

  for reference in \
    "$root/build/macos/Build/Products/Release/MeowSTT.app" \
    "/Applications/MeowSTT.app"; do
    [[ -d "$reference" ]] || continue
    team="$(
      codesign -dv --verbose=4 "$reference" 2>&1 \
        | sed -n 's/^TeamIdentifier=//p' \
        | head -n 1
    )"
    [[ -n "$team" && "$team" != "not set" ]] || continue
    matched="$(
      printf '%s\n' "$developer_identities" \
        | grep -F "($team)" \
        | head -n 1 \
        || true
    )"
    if [[ -n "$matched" ]]; then
      printf '%s\n' "$matched" | sed -n 's/^[^"]*"\([^"]*\)".*/\1/p'
      return
    fi
  done

  count="$(
    printf '%s\n' "$developer_identities" \
      | sed '/^[[:space:]]*$/d' \
      | wc -l \
      | tr -d ' '
  )"
  if [[ "$count" == "1" ]]; then
    printf '%s\n' "$developer_identities" \
      | sed -n 's/^[^"]*"\([^"]*\)".*/\1/p'
    return
  fi
  printf '%s\n' '-'
}

meowstt_sign_app_bundle() {
  local app="${1:?app bundle is required}"
  local identity="${2:?signing identity is required}"
  local entitlements="${3:?entitlements path is required}"
  local mode="${4:?build mode is required}"
  local component
  local component_sign_args=(--force --sign "$identity")
  if [[ "$identity" != "-" ]]; then
    component_sign_args+=(--options runtime)
    if [[ "$mode" == "release" ]]; then component_sign_args+=(--timestamp); fi
  fi
  local component_roots=("$app/Contents/Frameworks" "$app/Contents/MacOS")
  if [[ -d "$app/Contents/Helpers" ]]; then
    component_roots+=("$app/Contents/Helpers")
  fi
  if [[ -d "$app/Contents/Library/LoginItems" ]]; then
    component_roots+=("$app/Contents/Library/LoginItems")
  fi
  while IFS= read -r -d '' component; do
    codesign "${component_sign_args[@]}" "$component" || return 1
  done < <(
    find "${component_roots[@]}" -depth \
      \( -type d -name '*.framework' -o -type d -name '*.appex' \
      -o -type d -name '*.xpc' -o -type d -name '*.app' \
      -o -type f -name '*.dylib' \
      -o -type f -name 'MeowSTTSpeechWorker' \) -print0
  )

  local sign_args=(--force --sign "$identity" --entitlements "$entitlements")
  if [[ "$identity" != "-" ]]; then
    sign_args+=(--options runtime)
    if [[ "$mode" == "release" ]]; then sign_args+=(--timestamp); fi
  fi
  codesign "${sign_args[@]}" "$app" || return 1
  codesign --verify --deep --strict "$app"
}
