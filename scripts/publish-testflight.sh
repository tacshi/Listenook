#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/publish-testflight.sh <version> <build> [--allow-branch]

Build Listenook for iOS and publish it to its internal TestFlight group. The
version looks like 1.2.3 and the build is a positive integer, one the
version hasn't had.

The build is of a published commit: main must be checked out, with a clean
Git worktree, at the commit origin/main is at. --allow-branch builds from
another branch instead, which origin must have at the same commit.

It needs asc signed in to App Store Connect (asc auth login), the nsh CLI,
and an Apple Distribution identity in the keychain. The App Store profile is
the newest one on this Mac for app.capyvibe.listenook whose certificate is in
the keychain; without one, asc installs Apple's, or makes one.

Environment:
  ASC_APP_ID        The App Store Connect app (default: the one whose bundle
                    ID is app.capyvibe.listenook)
  ASC_TESTFLIGHT_GROUP
                    The internal group to give the build to
                    (default "Listenook Testers")
  ASC_TESTFLIGHT_TIMEOUT
                    How long to wait for the upload and Apple's processing
                    (default 45m)
  LISTENOOK_IOS_PROFILE
                    The App Store .mobileprovision to sign with, over the
                    one found.
  LISTENOOK_IOS_SIGN_IDENTITY
                    The identity to sign with, over the profile's one in the
                    keychain.
EOF
}

log() {
  printf '==> %s\n' "$*"
}

die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "$1 not found in PATH."
}

if [[ $# -eq 1 && ("$1" == -h || "$1" == --help) ]]; then
  usage
  exit 0
fi
ALLOW_BRANCH=false
ARGS=()
for arg in "$@"; do
  case "${arg}" in
    --allow-branch) ALLOW_BRANCH=true ;;
    -*) die "Unknown option: ${arg} (use --help)" ;;
    *) ARGS+=("${arg}") ;;
  esac
done
[[ ${#ARGS[@]} -eq 2 ]] || die "Usage: $0 <version> <build> [--allow-branch] (use --help)"
[[ "${ARGS[0]}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
  die "The version must look like 1.2.3, not ${ARGS[0]}."
[[ "${ARGS[1]}" =~ ^[1-9][0-9]*$ ]] ||
  die "The build must be a positive integer, not ${ARGS[1]}."
export BUILD_NAME="${ARGS[0]}"
export BUILD_NUMBER="${ARGS[1]}"

for tool in asc git nsh python3 unzip plutil security codesign xcodebuild xcrun ditto sw_vers; do
  require_command "${tool}"
done

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
[[ "$(uname -s)" == Darwin ]] || die "iOS builds must run on macOS."

TESTFLIGHT_GROUP="${ASC_TESTFLIGHT_GROUP:-Listenook Testers}"
TIMEOUT="${ASC_TESTFLIGHT_TIMEOUT:-45m}"
PACKAGE="${OUT}/nsh/ios-testflight"
IPA="${OUT}/${APP_NAME}-${VERSION}-${BUILD_NUMBER}-ios-testflight.ipa"

signing() {
  python3 -I - "$@" <<'SIGNING'
import base64, datetime, glob, hashlib, json, os, plistlib, re, subprocess, sys

mode, app, args = sys.argv[1], sys.argv[2], sys.argv[3:]
keychain = {}
listing = subprocess.run(["security", "find-identity", "-v", "-p", "codesigning"], capture_output=True, text=True).stdout
for line in listing.splitlines():
    match = re.match(r'\s*\d+\)\s+([0-9A-F]{40})\s+"(.+)"$', line)
    if match:
        keychain[match.group(1)] = match.group(2)

if mode == "certificates":
    for certificate in json.load(open(args[0]))["data"]:
        content = certificate["attributes"].get("certificateContent")
        if content and hashlib.sha1(base64.b64decode(content)).hexdigest().upper() in keychain:
            print(certificate["id"])
    sys.exit()

if mode == "remote":
    listing = json.load(open(args[0]))
    identifiers = {i["id"]: i["attributes"].get("identifier") for i in listing.get("included", []) if i["type"] == "bundleIds"}
    for profile in listing["data"]:
        bundle = profile["relationships"]["bundleId"]["data"]["id"]
        if profile["attributes"]["profileState"] == "ACTIVE" and identifiers.get(bundle) == app:
            print(profile["id"])
    sys.exit()

paths = args
if not paths:
    for folder in ("~/Library/Developer/Xcode/UserData/Provisioning Profiles", "~/Library/MobileDevice/Provisioning Profiles"):
        paths += glob.glob(os.path.join(os.path.expanduser(folder), "*.mobileprovision"))
now = datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None)
found = []
for path in paths:
    try:
        profile = plistlib.loads(subprocess.run(["security", "cms", "-D", "-i", path], capture_output=True, check=True).stdout)
    except Exception:
        continue
    rights = profile.get("Entitlements", {})
    _, _, covered = rights.get("application-identifier", "").partition(".")
    fits = covered == app or covered == "*" or (covered.endswith("*") and app.startswith(covered[:-1]))
    if not fits or rights.get("get-task-allow") or "ProvisionedDevices" in profile or profile.get("ProvisionsAllDevices"):
        continue
    if profile.get("ExpirationDate", datetime.datetime.max) < now:
        continue
    for certificate in profile.get("DeveloperCertificates", []):
        sha = hashlib.sha1(certificate).hexdigest().upper()
        if sha in keychain:
            found.append((covered == app, profile.get("CreationDate") or datetime.datetime.min, path, sha, keychain[sha]))
if found:
    _, _, path, sha, name = max(found)
    print(f"{path}\t{sha}\t{name}")
SIGNING
}

install_store_profile() {
  local id bundle certificates
  asc profiles list --profile-type IOS_APP_STORE --profile-state ACTIVE --include bundleId --paginate --output json >"${WORK_DIR}/profiles.json"
  for id in $(signing remote "${APP_ID}" "${WORK_DIR}/profiles.json"); do
    log "Installing App Store profile ${id}..."
    asc profiles local install --id "${id}" --force >/dev/null
  done
  [[ -z "$(signing local "${APP_ID}")" ]] || return 0

  bundle="$(asc bundle-ids list --identifier "${APP_ID}" --output json |
    python3 -I -c 'import json,sys; print(next(iter(b["id"] for b in json.load(sys.stdin)["data"]), ""))')"
  [[ -n "${bundle}" ]] || die "The Apple Developer account has no bundle ID ${APP_ID}."
  asc certificates list --certificate-type DISTRIBUTION,IOS_DISTRIBUTION --paginate \
    --fields certificateContent,certificateType,displayName --output json >"${WORK_DIR}/certificates.json"
  certificates="$(signing certificates "${APP_ID}" "${WORK_DIR}/certificates.json" | paste -sd, -)"
  [[ -n "${certificates}" ]] ||
    die "No Apple Distribution certificate of the account is in this Mac's keychain. Make one in Xcode (Settings > Accounts > Manage Certificates)."
  log "Making an App Store profile for ${APP_ID}..."
  id="$(asc profiles create --name "${APP_NAME} App Store $(date +%Y%m%d%H%M%S)" --profile-type IOS_APP_STORE \
    --bundle "${bundle}" --certificate "${certificates}" --output json |
    python3 -I -c 'import json,sys; print(json.load(sys.stdin)["data"]["id"])')"
  asc profiles local install --id "${id}" --force >/dev/null
}

resolve_signing() {
  local found
  if [[ -n "${LISTENOOK_IOS_PROFILE:-}" ]]; then
    [[ -f "${LISTENOOK_IOS_PROFILE}" ]] || die "Provisioning profile not found: ${LISTENOOK_IOS_PROFILE}"
    found="$(signing local "${APP_ID}" "${LISTENOOK_IOS_PROFILE}")"
    [[ -n "${found}" || -n "${LISTENOOK_IOS_SIGN_IDENTITY:-}" ]] ||
      die "${LISTENOOK_IOS_PROFILE} isn't an App Store profile for ${APP_ID} whose certificate is in the keychain."
    PROFILE="${LISTENOOK_IOS_PROFILE}"
  else
    found="$(signing local "${APP_ID}")"
    if [[ -z "${found}" ]]; then
      install_store_profile
      found="$(signing local "${APP_ID}")"
    fi
    [[ -n "${found}" ]] || die "No App Store profile for ${APP_ID} could be found or made. Set LISTENOOK_IOS_PROFILE."
    PROFILE="${found%%$'\t'*}"
  fi
  IDENTITY="${LISTENOOK_IOS_SIGN_IDENTITY:-$(printf '%s' "${found}" | cut -f2)}"
  log "Signing as $(printf '%s' "${found}" | cut -f3) with $(basename "${PROFILE}")."
}

add_build_details() {
  local plist="$1" sdk sdk_build xcode xcode_build major minor patch
  sdk="$(xcrun --sdk iphoneos --show-sdk-version)"
  sdk_build="$(xcrun --sdk iphoneos --show-sdk-build-version)"
  xcode="$(xcodebuild -version | awk '/^Xcode / { print $2 }')"
  xcode_build="$(xcodebuild -version | awk '/^Build version / { print $3 }')"
  [[ -n "${sdk}" && -n "${sdk_build}" && -n "${xcode}" && -n "${xcode_build}" ]] ||
    die "Could not read the Xcode and iOS SDK versions."
  IFS=. read -r major minor patch <<<"${xcode}"
  plutil -replace BuildMachineOSBuild -string "$(sw_vers -buildVersion)" "${plist}"
  plutil -replace DTCompiler -string com.apple.compilers.llvm.clang.1_0 "${plist}"
  plutil -replace DTPlatformBuild -string "${sdk_build}" "${plist}"
  plutil -replace DTPlatformName -string iphoneos "${plist}"
  plutil -replace DTPlatformVersion -string "${sdk}" "${plist}"
  plutil -replace DTSDKBuild -string "${sdk_build}" "${plist}"
  plutil -replace DTSDKName -string "iphoneos${sdk}" "${plist}"
  plutil -replace DTXcode -string "$(printf '%02d%d%d' "${major}" "${minor:-0}" "${patch:-0}")" "${plist}"
  plutil -replace DTXcodeBuild -string "${xcode_build}" "${plist}"
}

info_value() {
  plutil -extract "$1" raw -o - "${APP_DIR}/Info.plist" 2>/dev/null || true
}

cd "${ROOT}"

[[ -z "$(git status --porcelain)" ]] ||
  die "The worktree isn't clean. Commit or stash the changes before publishing."
BRANCH="$(git branch --show-current)"
[[ -n "${BRANCH}" ]] || die "HEAD is detached, so no branch of origin has its commit. Check out main."
[[ "${BRANCH}" == main || "${ALLOW_BRANCH}" == true ]] ||
  die "TestFlight builds are cut from main, and this is ${BRANCH} (--allow-branch to override)."
REMOTE="$(git ls-remote origin "refs/heads/${BRANCH}")" || die "Could not reach origin."
COMMIT="$(git rev-parse HEAD)"
[[ "${REMOTE%%[[:space:]]*}" == "${COMMIT}" ]] ||
  die "HEAD is not what origin/${BRANCH} is. Push or pull first, so the build is of a published commit."
log "${APP_NAME} ${VERSION} (${BUILD_NUMBER}) from ${BRANCH} at $(git rev-parse --short HEAD)."

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/listenook-testflight.XXXXXX")"
trap 'rm -rf "${WORK_DIR}"' EXIT

log "Checking App Store Connect..."
asc auth doctor >/dev/null || die "asc isn't signed in to App Store Connect. Run asc auth doctor to see why."
if [[ -n "${ASC_APP_ID:-}" ]]; then
  asc apps view --id "${ASC_APP_ID}" --output json |
    python3 -I -c 'import json,sys; d=json.load(sys.stdin)["data"]; print(json.dumps({"data": [d]}))' >"${WORK_DIR}/apps.json"
else
  asc apps list --bundle-id "${APP_ID}" --output json >"${WORK_DIR}/apps.json"
fi
ASC_APP_ID="$(python3 -I - "${WORK_DIR}/apps.json" "${APP_ID}" <<'CHECK_APP'
import json, sys

apps, bundle_id = json.load(open(sys.argv[1]))["data"], sys.argv[2]
if not apps:
    sys.exit(f"Error: App Store Connect has no app for {bundle_id}. Make it there, or set ASC_APP_ID.")
app = apps[0]
if app["attributes"]["bundleId"] != bundle_id:
    sys.exit(f"Error: App Store Connect app {app['id']} is {app['attributes']['bundleId']}, not {bundle_id}. Set ASC_APP_ID to Listenook's.")
print(app["id"])
CHECK_APP
)"
asc testflight groups list --app "${ASC_APP_ID}" --internal --paginate --output json >"${WORK_DIR}/groups.json"
python3 -I - "${WORK_DIR}/groups.json" "${TESTFLIGHT_GROUP}" <<'CHECK_GROUP'
import json, sys

groups, group = json.load(open(sys.argv[1]))["data"], sys.argv[2]
if not any(group in (g["id"], g["attributes"].get("name")) for g in groups):
    names = ", ".join(g["attributes"].get("name", g["id"]) for g in groups) or "none"
    sys.exit(f'Error: Listenook has no internal TestFlight group "{group}" (it has: {names}). Create it, or set ASC_TESTFLIGHT_GROUP.')
CHECK_GROUP

resolve_signing

log "Building ${APP_NAME} ${VERSION} (${BUILD_NUMBER})..."
start_log ios-testflight
nsh_package ios "${PACKAGE}" --sign "${IDENTITY}" --profile "${PROFILE}"
STAGED="${WORK_DIR}/stage/Payload/${APP_NAME}.app"
mkdir -p "$(dirname "${STAGED}")"
ditto "${PACKAGE}/${APP_NAME}.app" "${STAGED}"
add_build_details "${STAGED}/Info.plist"
EXECUTABLE="$(plutil -extract CFBundleExecutable raw -o - "${STAGED}/Info.plist")"
[[ -f "${PACKAGE}/${EXECUTABLE}.entitlements" ]] || die "nsh left no ${EXECUTABLE}.entitlements in ${PACKAGE}."
codesign --force --sign "${IDENTITY}" --entitlements "${PACKAGE}/${EXECUTABLE}.entitlements" "${STAGED}" >"${WORK_DIR}/resign.txt" 2>&1 ||
  die "Signing ${APP_NAME}.app again failed: $(cat "${WORK_DIR}/resign.txt")"
rm -f "${IPA}"
ditto -c -k --norsrc --keepParent "${WORK_DIR}/stage/Payload" "${IPA}"

unzip -q "${IPA}" -d "${WORK_DIR}/ipa"
APPS=("${WORK_DIR}"/ipa/Payload/*.app)
[[ ${#APPS[@]} -eq 1 && -d "${APPS[0]}" ]] || die "Expected one app in ${IPA}."
APP_DIR="${APPS[0]}"

[[ "$(info_value CFBundleIdentifier)" == "${APP_ID}" ]] ||
  die "The IPA is $(info_value CFBundleIdentifier), not ${APP_ID}."
[[ "$(info_value CFBundleShortVersionString)" == "${VERSION}" ]] ||
  die "The IPA's version is $(info_value CFBundleShortVersionString), not ${VERSION}."
[[ "$(info_value CFBundleVersion)" == "${BUILD_NUMBER}" ]] ||
  die "The IPA's build is $(info_value CFBundleVersion), not ${BUILD_NUMBER}."
[[ "$(info_value ITSAppUsesNonExemptEncryption)" == "false" ]] ||
  die "The IPA must say ITSAppUsesNonExemptEncryption = false (nsh.json ios.infoPlist)."
[[ "$(info_value UIRequiredDeviceCapabilities.0)" == "arm64" ]] ||
  die "The IPA must require arm64 in UIRequiredDeviceCapabilities (nsh.json ios.infoPlist)."
[[ "$(info_value DTPlatformName)" == "iphoneos" && "$(info_value DTSDKName)" == "iphoneos$(xcrun --sdk iphoneos --show-sdk-version)" && -n "$(info_value DTXcode)" ]] ||
  die "The IPA's Info.plist lacks the Xcode and SDK it was built with (DTPlatformName, DTSDKName, DTXcode)."
for key in "CFBundleIcons.CFBundlePrimaryIcon.CFBundleIconName" "CFBundleIcons~ipad.CFBundlePrimaryIcon.CFBundleIconName"; do
  [[ "$(info_value "${key}")" == "AppIcon" ]] ||
    die "The IPA's Info.plist names no AppIcon at ${key}."
done
for icon in Assets.car AppIcon60x60@2x.png AppIcon76x76@2x~ipad.png; do
  [[ -f "${APP_DIR}/${icon}" ]] || die "The IPA has no ${icon}, so it would have no icon."
done
codesign --verify --strict --deep "${APP_DIR}" 2>"${WORK_DIR}/codesign.txt" ||
  die "The IPA's signature doesn't verify: $(cat "${WORK_DIR}/codesign.txt")"
codesign -d --entitlements - --xml "${APP_DIR}" 2>/dev/null >"${WORK_DIR}/entitlements.plist"
[[ "$(plutil -extract get-task-allow raw -o - "${WORK_DIR}/entitlements.plist" 2>/dev/null || echo false)" == false ]] ||
  die "The IPA is signed for development (get-task-allow), not for the App Store."
log "Built ${IPA#"${ROOT}"/}, with its icon."

[[ "$(git rev-parse HEAD)" == "${COMMIT}" && -z "$(git status --porcelain --untracked-files=no)" ]] ||
  die "The checkout changed while ${APP_NAME} ${VERSION} (${BUILD_NUMBER}) was built from ${COMMIT}, so the build isn't that commit's. Nothing was published."

log "Publishing ${VERSION} (${BUILD_NUMBER}) to ${TESTFLIGHT_GROUP}..."
asc publish testflight \
  --app "${ASC_APP_ID}" \
  --ipa "${IPA}" \
  --version "${VERSION}" \
  --build-number "${BUILD_NUMBER}" \
  --group "${TESTFLIGHT_GROUP}" \
  --wait \
  --timeout "${TIMEOUT}" \
  --output table

log "Published ${VERSION} (${BUILD_NUMBER}), a build of ${COMMIT}, to TestFlight."
