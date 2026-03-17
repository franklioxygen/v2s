#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_PATH="$ROOT_DIR/v2s.xcodeproj"
PROJECT_FILE="$PROJECT_PATH/project.pbxproj"
SCHEME="v2s"
APP_NAME="v2s"
DERIVED_DATA_PATH="$ROOT_DIR/.build/release"
DIST_DIR="$ROOT_DIR/dist"
APP_SIGN_IDENTITY="${APP_SIGN_IDENTITY:-}"
PKG_SIGN_IDENTITY="${PKG_SIGN_IDENTITY:-}"
APP_ENTITLEMENTS_PATH="${APP_ENTITLEMENTS_PATH:-}"
NOTARYTOOL_KEYCHAIN_PROFILE="${NOTARYTOOL_KEYCHAIN_PROFILE:-}"
NOTARYTOOL_KEYCHAIN_PATH="${NOTARYTOOL_KEYCHAIN_PATH:-}"
NOTARYTOOL_APPLE_ID="${NOTARYTOOL_APPLE_ID:-}"
NOTARYTOOL_TEAM_ID="${NOTARYTOOL_TEAM_ID:-}"
NOTARYTOOL_APP_PASSWORD="${NOTARYTOOL_APP_PASSWORD:-}"
NOTARYTOOL_KEY_PATH="${NOTARYTOOL_KEY_PATH:-}"
NOTARYTOOL_KEY_ID="${NOTARYTOOL_KEY_ID:-}"
NOTARYTOOL_ISSUER="${NOTARYTOOL_ISSUER:-}"
NOTARYTOOL_TIMEOUT="${NOTARYTOOL_TIMEOUT:-15m}"
PROJECT_FILE_BACKUP=""
ROLLBACK_ON_EXIT=0
NOTARYTOOL_AUTH_ARGS=()

cleanup() {
  local exit_code=$?

  if [[ $ROLLBACK_ON_EXIT -eq 1 && -n "$PROJECT_FILE_BACKUP" && -f "$PROJECT_FILE_BACKUP" ]]; then
    mv "$PROJECT_FILE_BACKUP" "$PROJECT_FILE"
  elif [[ -n "$PROJECT_FILE_BACKUP" && -f "$PROJECT_FILE_BACKUP" ]]; then
    rm -f "$PROJECT_FILE_BACKUP"
  fi

  exit "$exit_code"
}

trap cleanup EXIT

usage() {
  cat <<'EOF'
Usage: ./scripts/release.sh [patch|minor|major|x.y.z] [--notes-file FILE]

Examples:
  ./scripts/release.sh
  ./scripts/release.sh minor
  ./scripts/release.sh 1.2.0 --notes-file /absolute/path/to/release-notes.md

The script will:
  1. Require a clean git worktree on the default branch.
  2. Bump MARKETING_VERSION and CURRENT_PROJECT_VERSION in the Xcode project.
  3. Build a Release app with code signing disabled.
  4. Sign the app with Developer ID Application.
  5. Build, sign, notarize, and staple dist/v2s-<version>.pkg.
  6. Commit the version bump, create/push tag v<version>, and publish a GitHub release.

Required environment:
  APP_SIGN_IDENTITY            Optional if exactly one "Developer ID Application" identity exists.
  PKG_SIGN_IDENTITY            Optional if exactly one "Developer ID Installer" identity exists.

Notary authentication (choose one mode):
  NOTARYTOOL_KEYCHAIN_PROFILE  Preferred. Stored via: xcrun notarytool store-credentials
  NOTARYTOOL_KEYCHAIN_PATH     Optional with keychain profile.

  OR

  NOTARYTOOL_APPLE_ID
  NOTARYTOOL_TEAM_ID
  NOTARYTOOL_APP_PASSWORD

  OR

  NOTARYTOOL_KEY_PATH
  NOTARYTOOL_KEY_ID
  NOTARYTOOL_ISSUER            Optional for individual API keys, required for team API keys.

Optional environment:
  APP_ENTITLEMENTS_PATH        Path to a custom entitlements plist for the app signature.
  NOTARYTOOL_TIMEOUT           Wait timeout for notarization (default: 15m).
EOF
}

fail() {
  printf 'error: %s\n' "$1" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "Missing required command: $1"
}

trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

extract_setting() {
  local key="$1"

  perl -ne "if (/${key} = ([^;]+);/) { print \$1; exit }" "$PROJECT_FILE"
}

is_semver() {
  [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

find_matching_identities() {
  local prefix="$1"

  security find-identity -v -p basic 2>/dev/null \
    | sed -n 's/.*"\(.*\)"/\1/p' \
    | while IFS= read -r identity; do
        [[ "$identity" == "$prefix"* ]] && printf '%s\n' "$identity"
      done
}

resolve_identity() {
  local current_value="$1"
  local prefix="$2"
  local label="$3"
  local match_count=0
  local resolved=""

  if [[ -n "$current_value" ]]; then
    while IFS= read -r identity; do
      [[ "$identity" == "$current_value" ]] && resolved="$identity"
    done < <(find_matching_identities "$prefix")

    [[ -n "$resolved" ]] || fail "${label} identity not found in keychain: ${current_value}"
    printf '%s\n' "$resolved"
    return
  fi

  while IFS= read -r identity; do
    resolved="$identity"
    match_count=$((match_count + 1))
  done < <(find_matching_identities "$prefix")

  case "$match_count" in
    0)
      fail "No ${label} identity found in keychain. Install a ${prefix} certificate or set ${label^^}_IDENTITY."
      ;;
    1)
      printf '%s\n' "$resolved"
      ;;
    *)
      fail "Multiple ${label} identities found. Set ${label^^}_IDENTITY explicitly."
      ;;
  esac
}

configure_notary_auth() {
  if [[ -n "$NOTARYTOOL_KEYCHAIN_PROFILE" ]]; then
    NOTARYTOOL_AUTH_ARGS=(--keychain-profile "$NOTARYTOOL_KEYCHAIN_PROFILE")
    [[ -n "$NOTARYTOOL_KEYCHAIN_PATH" ]] && NOTARYTOOL_AUTH_ARGS+=(--keychain "$NOTARYTOOL_KEYCHAIN_PATH")
    return
  fi

  if [[ -n "$NOTARYTOOL_KEY_PATH" || -n "$NOTARYTOOL_KEY_ID" || -n "$NOTARYTOOL_ISSUER" ]]; then
    [[ -n "$NOTARYTOOL_KEY_PATH" ]] || fail "NOTARYTOOL_KEY_PATH is required when using API key auth."
    [[ -n "$NOTARYTOOL_KEY_ID" ]] || fail "NOTARYTOOL_KEY_ID is required when using API key auth."
    [[ -f "$NOTARYTOOL_KEY_PATH" ]] || fail "Notary API key file not found: ${NOTARYTOOL_KEY_PATH}"

    NOTARYTOOL_AUTH_ARGS=(--key "$NOTARYTOOL_KEY_PATH" --key-id "$NOTARYTOOL_KEY_ID")
    [[ -n "$NOTARYTOOL_ISSUER" ]] && NOTARYTOOL_AUTH_ARGS+=(--issuer "$NOTARYTOOL_ISSUER")
    return
  fi

  if [[ -n "$NOTARYTOOL_APPLE_ID" || -n "$NOTARYTOOL_TEAM_ID" || -n "$NOTARYTOOL_APP_PASSWORD" ]]; then
    [[ -n "$NOTARYTOOL_APPLE_ID" ]] || fail "NOTARYTOOL_APPLE_ID is required when using Apple ID auth."
    [[ -n "$NOTARYTOOL_TEAM_ID" ]] || fail "NOTARYTOOL_TEAM_ID is required when using Apple ID auth."
    [[ -n "$NOTARYTOOL_APP_PASSWORD" ]] || fail "NOTARYTOOL_APP_PASSWORD is required when using Apple ID auth."

    NOTARYTOOL_AUTH_ARGS=(
      --apple-id "$NOTARYTOOL_APPLE_ID"
      --team-id "$NOTARYTOOL_TEAM_ID"
      --password "$NOTARYTOOL_APP_PASSWORD"
    )
    return
  fi

  fail "Notary credentials are not configured. Set NOTARYTOOL_KEYCHAIN_PROFILE, Apple ID auth env vars, or API key auth env vars."
}

bump_version() {
  local current="$1"
  local bump="$2"
  local major
  local minor
  local patch

  if is_semver "$bump"; then
    printf '%s\n' "$bump"
    return
  fi

  IFS='.' read -r major minor patch <<< "$current"

  case "$bump" in
    patch)
      patch=$((patch + 1))
      ;;
    minor)
      minor=$((minor + 1))
      patch=0
      ;;
    major)
      major=$((major + 1))
      minor=0
      patch=0
      ;;
    *)
      fail "Unsupported bump '${bump}'. Use patch, minor, major, or an explicit x.y.z version."
      ;;
  esac

  printf '%s.%s.%s\n' "$major" "$minor" "$patch"
}

assert_clean_worktree() {
  if [[ -n "$(git -C "$ROOT_DIR" status --porcelain)" ]]; then
    fail "Working tree is not clean. Commit or stash changes before releasing."
  fi
}

assert_default_branch() {
  local current_branch
  local default_branch

  current_branch="$(git -C "$ROOT_DIR" branch --show-current)"
  default_branch="$(git -C "$ROOT_DIR" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##')"

  [[ -n "$current_branch" ]] || fail "Could not determine current branch."
  [[ -n "$default_branch" ]] || fail "Could not determine origin default branch."

  if [[ "$current_branch" != "$default_branch" ]]; then
    fail "Release must run from '${default_branch}'. Current branch is '${current_branch}'."
  fi
}

assert_tag_available() {
  local tag="$1"

  if git -C "$ROOT_DIR" rev-parse --verify --quiet "refs/tags/${tag}" >/dev/null; then
    fail "Tag '${tag}' already exists locally."
  fi

  if git -C "$ROOT_DIR" ls-remote --exit-code --tags origin "refs/tags/${tag}" >/dev/null 2>&1; then
    fail "Tag '${tag}' already exists on origin."
  fi
}

apply_version_bump() {
  local version="$1"
  local build_number="$2"

  perl -0pi -e "s/MARKETING_VERSION = [^;]+;/MARKETING_VERSION = ${version};/g" "$PROJECT_FILE"
  perl -0pi -e "s/CURRENT_PROJECT_VERSION = [^;]+;/CURRENT_PROJECT_VERSION = ${build_number};/g" "$PROJECT_FILE"
}

build_release_app() {
  rm -rf "$DERIVED_DATA_PATH"

  xcodebuild \
    -project "$PROJECT_PATH" \
    -scheme "$SCHEME" \
    -configuration Release \
    -derivedDataPath "$DERIVED_DATA_PATH" \
    CODE_SIGNING_ALLOWED=NO \
    build
}

package_release() {
  local version="$1"
  local package_identifier="$2"
  local pkg_sign_identity="$3"
  local app_path="$DERIVED_DATA_PATH/Build/Products/Release/${APP_NAME}.app"
  local unsigned_pkg_path="$DIST_DIR/${APP_NAME}-${version}-unsigned.pkg"
  local pkg_path="$DIST_DIR/${APP_NAME}-${version}.pkg"
  local checksum_path="$DIST_DIR/${APP_NAME}-${version}.sha256"

  [[ -d "$app_path" ]] || fail "Expected app bundle not found at ${app_path}"

  mkdir -p "$DIST_DIR"
  rm -f "$unsigned_pkg_path" "$pkg_path" "$checksum_path"

  pkgbuild \
    --component "$app_path" \
    --install-location /Applications \
    --identifier "$package_identifier" \
    --version "$version" \
    "$unsigned_pkg_path"

  productsign \
    --sign "$pkg_sign_identity" \
    "$unsigned_pkg_path" \
    "$pkg_path"

  rm -f "$unsigned_pkg_path"

  pkgutil --check-signature "$pkg_path" >/dev/null

  (
    cd "$DIST_DIR"
    shasum -a 256 "$(basename "$pkg_path")" > "$(basename "$checksum_path")"
  )

  printf '%s\n' "$pkg_path"
}

sign_path() {
  local path="$1"
  shift

  codesign --force --timestamp --sign "$APP_SIGN_IDENTITY" "$@" "$path"
}

sign_release_app() {
  local app_path="$1"

  [[ -d "$app_path" ]] || fail "Expected app bundle not found at ${app_path}"
  [[ -z "$APP_ENTITLEMENTS_PATH" || -f "$APP_ENTITLEMENTS_PATH" ]] || fail "Entitlements file not found: ${APP_ENTITLEMENTS_PATH}"

  while IFS= read -r path; do
    sign_path "$path"
  done < <(
    find "$app_path/Contents" -type f \( -name '*.dylib' -o -name '*.so' \) -print | sort
  )

  while IFS= read -r path; do
    sign_path "$path"
  done < <(
    find "$app_path/Contents" \
      -type d \
      \( -name '*.framework' -o -name '*.bundle' -o -name '*.app' -o -name '*.appex' -o -name '*.xpc' \) \
      -print \
      | awk -F/ '{print NF "\t" $0}' \
      | sort -rn \
      | cut -f2-
  )

  if [[ -n "$APP_ENTITLEMENTS_PATH" ]]; then
    sign_path "$app_path" --options runtime --entitlements "$APP_ENTITLEMENTS_PATH"
  else
    sign_path "$app_path" --options runtime
  fi

  codesign --verify --deep --strict --verbose=2 "$app_path"
}

notarize_and_staple_pkg() {
  local pkg_path="$1"

  xcrun notarytool submit \
    "$pkg_path" \
    "${NOTARYTOOL_AUTH_ARGS[@]}" \
    --wait \
    --timeout "$NOTARYTOOL_TIMEOUT"

  xcrun stapler staple "$pkg_path"
  xcrun stapler validate "$pkg_path"
}

main() {
  local bump="patch"
  local notes_file=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help)
        usage
        exit 0
        ;;
      --notes-file)
        [[ $# -ge 2 ]] || fail "--notes-file requires a file path."
        notes_file="$2"
        shift 2
        ;;
      patch|minor|major)
        bump="$1"
        shift
        ;;
      *)
        if is_semver "$1"; then
          bump="$1"
          shift
        else
          fail "Unknown argument: $1"
        fi
        ;;
    esac
  done

  require_cmd git
  require_cmd gh
  require_cmd perl
  require_cmd codesign
  require_cmd pkgbuild
  require_cmd pkgutil
  require_cmd productsign
  require_cmd shasum
  require_cmd xcodebuild
  require_cmd xcrun

  [[ -f "$PROJECT_FILE" ]] || fail "Xcode project file not found: ${PROJECT_FILE}"
  [[ -z "$notes_file" || -f "$notes_file" ]] || fail "Release notes file not found: ${notes_file}"
  xcrun notarytool --version >/dev/null 2>&1 || fail "xcrun notarytool is unavailable in the active Xcode toolchain."
  xcrun stapler help >/dev/null 2>&1 || fail "xcrun stapler is unavailable in the active Xcode toolchain."

  gh auth status >/dev/null 2>&1 || fail "GitHub CLI is not authenticated. Run 'gh auth login' first."

  APP_SIGN_IDENTITY="$(trim "$(resolve_identity "$APP_SIGN_IDENTITY" "Developer ID Application:" "app_sign")")"
  PKG_SIGN_IDENTITY="$(trim "$(resolve_identity "$PKG_SIGN_IDENTITY" "Developer ID Installer:" "pkg_sign")")"
  configure_notary_auth

  assert_clean_worktree
  assert_default_branch

  local current_version
  local current_build
  local next_version
  local next_build
  local bundle_identifier
  local package_identifier
  local tag
  local release_asset
  local checksum_asset

  current_version="$(extract_setting "MARKETING_VERSION")"
  current_build="$(extract_setting "CURRENT_PROJECT_VERSION")"
  bundle_identifier="$(extract_setting "PRODUCT_BUNDLE_IDENTIFIER")"

  [[ -n "$current_version" ]] || fail "Could not read MARKETING_VERSION from ${PROJECT_FILE}"
  [[ -n "$current_build" ]] || fail "Could not read CURRENT_PROJECT_VERSION from ${PROJECT_FILE}"
  [[ -n "$bundle_identifier" ]] || fail "Could not read PRODUCT_BUNDLE_IDENTIFIER from ${PROJECT_FILE}"
  is_semver "$current_version" || fail "MARKETING_VERSION must be semantic version x.y.z. Found: ${current_version}"
  [[ "$current_build" =~ ^[0-9]+$ ]] || fail "CURRENT_PROJECT_VERSION must be numeric. Found: ${current_build}"

  next_version="$(bump_version "$current_version" "$bump")"
  next_build="$((current_build + 1))"
  package_identifier="${bundle_identifier}.pkg"
  tag="v${next_version}"

  assert_tag_available "$tag"

  printf 'Releasing %s (build %s -> %s)\n' "$next_version" "$current_build" "$next_build"

  PROJECT_FILE_BACKUP="${PROJECT_FILE}.release.bak"
  cp "$PROJECT_FILE" "$PROJECT_FILE_BACKUP"
  ROLLBACK_ON_EXIT=1

  apply_version_bump "$next_version" "$next_build"
  build_release_app
  sign_release_app "$DERIVED_DATA_PATH/Build/Products/Release/${APP_NAME}.app"
  release_asset="$(package_release "$next_version" "$package_identifier" "$PKG_SIGN_IDENTITY")"
  notarize_and_staple_pkg "$release_asset"
  checksum_asset="${release_asset%.pkg}.sha256"

  git -C "$ROOT_DIR" add "$PROJECT_FILE"
  git -C "$ROOT_DIR" commit -m "chore(release): ${tag}"
  git -C "$ROOT_DIR" tag -a "$tag" -m "$tag"
  git -C "$ROOT_DIR" push origin HEAD
  git -C "$ROOT_DIR" push origin "$tag"
  ROLLBACK_ON_EXIT=0

  if [[ -n "$notes_file" ]]; then
    gh release create "$tag" "$release_asset" "$checksum_asset" --title "$tag" --notes-file "$notes_file" --verify-tag
  else
    gh release create "$tag" "$release_asset" "$checksum_asset" --title "$tag" --generate-notes --verify-tag
  fi

  printf 'Published %s\n' "$tag"
  printf 'Installer: %s\n' "$release_asset"
}

main "$@"
