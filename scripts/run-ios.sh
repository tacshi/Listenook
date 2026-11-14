#!/usr/bin/env bash
# Builds a development-signed app, installs it on iPhones and iPads and
# launches it.
#
#   scripts/run-ios.sh                 lists the paired devices and asks
#   scripts/run-ios.sh --device UDID   a named device (repeat for several)
#   scripts/run-ios.sh --all           every device that is reachable now
#   scripts/run-ios.sh --no-launch     install without launching
#
# Asked which devices, answer with numbers ("1", "1,3", "1 3"), "a" for
# all, or Enter for those connected. Devices that cannot be reached now
# are listed too, marked [not reachable]: they can still be picked.
#
# Signing: LISTENOOK_IOS_DEV_SIGN_IDENTITY (an "Apple Development: …"
# identity) and LISTENOOK_IOS_DEV_PROFILE (a development .mobileprovision).
# Without them, the newest development profile on this Mac that covers the
# app, and the identity of its team, are used.
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

REQUESTED=()
ALL=false
LAUNCH=true
while [[ $# -gt 0 ]]; do
  case "$1" in
    --device) REQUESTED+=("${2:?--device requires a UDID}"); shift 2 ;;
    --all) ALL=true; shift ;;
    --no-launch) LAUNCH=false; shift ;;
    -h|--help) sed -n '2,17p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) echo "Unknown option: $1 (use --help)" >&2; exit 2 ;;
    *) REQUESTED+=("$1"); shift ;;
  esac
done

die() { echo "Error: $*" >&2; exit 1; }

NAMES=()
UDIDS=()
REACHABLE=()
discover() {
  local json line reachable udid name
  json="$(mktemp)"
  echo "Looking for devices…"
  xcrun devicectl list devices --timeout 20 --json-output "$json" >/dev/null 2>&1 ||
    { rm -f "$json"; die "could not list the devices paired with this Mac."; }
  while IFS=$'\t' read -r reachable udid name; do
    [[ -n "$udid" ]] || continue
    REACHABLE+=("$reachable"); UDIDS+=("$udid"); NAMES+=("$name")
  done < <(python3 - "$json" <<'PY'
import json, sys

rows = []
for device in json.load(open(sys.argv[1]))["result"]["devices"]:
    hardware = device.get("hardwareProperties", {})
    properties = device.get("deviceProperties", {})
    connection = device.get("connectionProperties", {})
    if hardware.get("reality") == "simulated" or hardware.get("platform") != "iOS":
        continue
    udid = hardware.get("udid") or device.get("identifier")
    name = properties.get("name")
    if not udid or not name:
        continue
    reachable = properties.get("bootState") == "booted" or connection.get("transportType") is not None
    kind = hardware.get("deviceType") or "iOS"
    version = properties.get("osVersionNumber")
    label = f"{name} ({kind}{', iOS ' + version if version else ''})"
    rows.append((not reachable, name.lower(), "1" if reachable else "0", udid, label))
for _, _, reachable, udid, label in sorted(rows):
    print(f"{reachable}\t{udid}\t{label}")
PY
  )
  rm -f "$json"
  (( ${#UDIDS[@]} > 0 )) || die "no iPhone or iPad is paired with this Mac."
}

CHOSEN=()
choose() {
  local index="$1" existing
  for existing in ${CHOSEN[@]+"${CHOSEN[@]}"}; do
    [[ "$existing" == "$index" ]] && return 0
  done
  CHOSEN+=("$index")
}
choose_reachable() {
  local i
  for i in "${!UDIDS[@]}"; do
    if [[ "${REACHABLE[$i]}" == 1 ]]; then choose "$i"; fi
  done
  (( ${#CHOSEN[@]} > 0 ))
}
find_device() {
  local i
  for i in "${!UDIDS[@]}"; do
    if [[ "${UDIDS[$i]}" == "$1" || "${NAMES[$i]%% (*}" == "$1" ]]; then
      echo "$i"
      return 0
    fi
  done
  return 1
}
parse_answer() {
  local answer="$1" token
  local picked=()
  if [[ -z "${answer// /}" ]]; then
    choose_reachable && return 0
    echo "No device is reachable now: pick one by number to try it anyway."
    return 1
  fi
  if [[ "$answer" == a || "$answer" == all ]]; then
    for token in "${!UDIDS[@]}"; do choose "$token"; done
    return 0
  fi
  for token in ${answer//,/ }; do
    [[ "$token" =~ ^[0-9]+$ ]] && (( token >= 1 && token <= ${#UDIDS[@]} )) || return 1
    picked+=("$(( token - 1 ))")
  done
  (( ${#picked[@]} > 0 )) || return 1
  for token in "${picked[@]}"; do choose "$token"; done
}
select_devices() {
  local i suffix requested answer
  discover
  if (( ${#REQUESTED[@]} > 0 )); then
    for requested in "${REQUESTED[@]}"; do
      i="$(find_device "$requested")" || die "'$requested' is not a device paired with this Mac."
      choose "$i"
    done
  elif [[ "$ALL" == true ]]; then
    choose_reachable || die "no device is reachable now. Pass --device UDID to try one anyway."
  elif [[ ! -t 0 ]]; then
    choose_reachable || die "no device is reachable now. Pass --device UDID (repeatable) or --all."
  else
    echo "Devices:"
    for i in "${!UDIDS[@]}"; do
      suffix=""
      [[ "${REACHABLE[$i]}" == 1 ]] || suffix="   [not reachable]"
      printf '  %d) %s — %s%s\n' "$(( i + 1 ))" "${NAMES[$i]}" "${UDIDS[$i]}" "$suffix"
    done
    while true; do
      printf 'Select [1-%d, comma separated, "a" for all, Enter for connected]: ' "${#UDIDS[@]}"
      read -r answer
      parse_answer "$answer" && break
      [[ -z "${answer// /}" ]] || echo "Invalid selection."
    done
  fi
  for i in "${CHOSEN[@]}"; do
    echo "Target: ${NAMES[$i]} — ${UDIDS[$i]}"
  done
}

find_profile() {
  python3 - "$APP_ID" <<'PY'
import datetime, glob, os, plistlib, subprocess, sys

app = sys.argv[1]
found = []
folders = ["~/Library/Developer/Xcode/UserData/Provisioning Profiles", "~/Library/MobileDevice/Provisioning Profiles"]
for folder in folders:
    for path in glob.glob(os.path.join(os.path.expanduser(folder), "*.mobileprovision")):
        try:
            decoded = subprocess.run(["security", "cms", "-D", "-i", path], capture_output=True, check=True).stdout
            profile = plistlib.loads(decoded)
        except Exception:
            continue
        rights = profile.get("Entitlements", {})
        identifier = rights.get("application-identifier", "")
        team, _, covered = identifier.partition(".")
        fits = covered == app or covered == "*" or (covered.endswith("*") and app.startswith(covered[:-1]))
        if not fits or not rights.get("get-task-allow") or "ProvisionedDevices" not in profile:
            continue
        if profile.get("ExpirationDate") and profile["ExpirationDate"] < datetime.datetime.now():
            continue
        found.append((covered == app, profile.get("CreationDate"), path, team))
if found:
    _, _, path, team = max(found)
    print(f"{path}\t{team}")
PY
}

resolve_signing() {
  PROFILE="${LISTENOOK_IOS_DEV_PROFILE:-}"
  IDENTITY="${LISTENOOK_IOS_DEV_SIGN_IDENTITY:-}"
  local team="" found
  if [[ -z "$PROFILE" ]]; then
    found="$(find_profile)"
    [[ -n "$found" ]] || die "no development provisioning profile for $APP_ID is on this Mac.
Set LISTENOOK_IOS_DEV_PROFILE to one, or let Xcode make one (open any project
with this bundle id and a device selected)."
    PROFILE="${found%%$'\t'*}"
    team="${found##*$'\t'}"
  fi
  [[ -f "$PROFILE" ]] || die "provisioning profile not found: $PROFILE"
  if [[ -z "$IDENTITY" ]]; then
    IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null |
      sed -n 's/^[^"]*"\(Apple Development:[^"]*\)".*/\1/p' |
      { if [[ -n "$team" ]]; then grep -F "($team)" || true; else cat; fi; } | head -n 1)"
    [[ -n "$IDENTITY" ]] || IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null |
      sed -n 's/^[^"]*"\(Apple Development:[^"]*\)".*/\1/p' | head -n 1)"
    [[ -n "$IDENTITY" ]] || die "no \"Apple Development\" signing identity is in the keychain.
Set LISTENOOK_IOS_DEV_SIGN_IDENTITY to one."
  fi
  echo "Signing as: $IDENTITY"
  echo "Profile: $(basename "$PROFILE")"
}

select_devices
resolve_signing
start_log ios-run
PACKAGE="$OUT/nsh/ios-run"
echo "Building $APP_NAME $VERSION for iOS"
nsh_package ios "$PACKAGE" --sign "$IDENTITY" --profile "$PROFILE"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
unzip -q "$PACKAGE/$APP_NAME.ipa" -d "$STAGE"

FAILED=()
for i in "${CHOSEN[@]}"; do
  echo "Installing on ${NAMES[$i]}"
  if ! quiet xcrun devicectl device install app --device "${UDIDS[$i]}" "$STAGE/Payload/$APP_NAME.app"; then
    FAILED+=("${NAMES[$i]}")
    continue
  fi
  if [[ "$LAUNCH" == true ]]; then
    quiet xcrun devicectl device process launch --terminate-existing --device "${UDIDS[$i]}" "$APP_ID" ||
      FAILED+=("${NAMES[$i]} (launch: is it unlocked?)")
  fi
done
if (( ${#FAILED[@]} > 0 )); then
  printf 'Error: failed on %d of %d devices: %s\n' "${#FAILED[@]}" "${#CHOSEN[@]}" \
    "$(printf '%s, ' "${FAILED[@]}" | sed 's/, $//')" >&2
  exit 1
fi
echo "Done."
