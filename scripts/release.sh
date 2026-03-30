#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_PATH="$ROOT_DIR/v2s.xcodeproj"
PROJECT_FILE="$PROJECT_PATH/project.pbxproj"
VERSION_SOURCE_FILE="$ROOT_DIR/Sources/V2SApp/App/AppModel.swift"
PROJECT_FILE_BACKUP=""
VERSION_SOURCE_FILE_BACKUP=""
ROLLBACK_ON_EXIT=0

cleanup() {
  local exit_code=$?

  if [[ $ROLLBACK_ON_EXIT -eq 1 && -n "$PROJECT_FILE_BACKUP" && -f "$PROJECT_FILE_BACKUP" ]]; then
    mv "$PROJECT_FILE_BACKUP" "$PROJECT_FILE"
  elif [[ -n "$PROJECT_FILE_BACKUP" && -f "$PROJECT_FILE_BACKUP" ]]; then
    rm -f "$PROJECT_FILE_BACKUP"
  fi

  if [[ $ROLLBACK_ON_EXIT -eq 1 && -n "$VERSION_SOURCE_FILE_BACKUP" && -f "$VERSION_SOURCE_FILE_BACKUP" ]]; then
    mv "$VERSION_SOURCE_FILE_BACKUP" "$VERSION_SOURCE_FILE"
  elif [[ -n "$VERSION_SOURCE_FILE_BACKUP" && -f "$VERSION_SOURCE_FILE_BACKUP" ]]; then
    rm -f "$VERSION_SOURCE_FILE_BACKUP"
  fi

  exit "$exit_code"
}

trap cleanup EXIT

usage() {
  cat <<'EOF'
Usage: ./scripts/release.sh [patch|minor|major|x.y.z]

Examples:
  ./scripts/release.sh
  ./scripts/release.sh minor
  ./scripts/release.sh 1.2.0

The script will:
  1. Require a clean git worktree on the default branch.
  2. Bump MARKETING_VERSION and CURRENT_PROJECT_VERSION in the Xcode project.
  3. Commit the version bump, create and push tag v<version>.
  4. GitHub Actions will handle the build, packaging, and release creation.
EOF
}

fail() {
  printf 'error: %s\n' "$1" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "Missing required command: $1"
}

extract_setting() {
  local key="$1"

  perl -ne "if (/${key} = ([^;]+);/) { print \$1; exit }" "$PROJECT_FILE"
}

is_semver() {
  [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
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
  perl -0pi -e 's/static let marketingVersion = "[^"]+"/static let marketingVersion = "'"${version}"'"/g' "$VERSION_SOURCE_FILE"
  perl -0pi -e 's/static let buildNumber = "[^"]+"/static let buildNumber = "'"${build_number}"'"/g' "$VERSION_SOURCE_FILE"
}

main() {
  local bump="patch"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help)
        usage
        exit 0
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
  require_cmd perl

  [[ -f "$PROJECT_FILE" ]] || fail "Xcode project file not found: ${PROJECT_FILE}"
  [[ -f "$VERSION_SOURCE_FILE" ]] || fail "Version source file not found: ${VERSION_SOURCE_FILE}"

  assert_clean_worktree
  assert_default_branch

  local current_version
  local current_build
  local next_version
  local next_build
  local tag

  current_version="$(extract_setting "MARKETING_VERSION")"
  current_build="$(extract_setting "CURRENT_PROJECT_VERSION")"

  [[ -n "$current_version" ]] || fail "Could not read MARKETING_VERSION from ${PROJECT_FILE}"
  [[ -n "$current_build" ]] || fail "Could not read CURRENT_PROJECT_VERSION from ${PROJECT_FILE}"
  is_semver "$current_version" || fail "MARKETING_VERSION must be semantic version x.y.z. Found: ${current_version}"
  [[ "$current_build" =~ ^[0-9]+$ ]] || fail "CURRENT_PROJECT_VERSION must be numeric. Found: ${current_build}"

  next_version="$(bump_version "$current_version" "$bump")"
  next_build="$((current_build + 1))"
  tag="v${next_version}"

  assert_tag_available "$tag"

  printf 'Releasing %s (build %s -> %s)\n' "$next_version" "$current_build" "$next_build"

  PROJECT_FILE_BACKUP="${PROJECT_FILE}.release.bak"
  VERSION_SOURCE_FILE_BACKUP="${VERSION_SOURCE_FILE}.release.bak"
  cp "$PROJECT_FILE" "$PROJECT_FILE_BACKUP"
  cp "$VERSION_SOURCE_FILE" "$VERSION_SOURCE_FILE_BACKUP"
  ROLLBACK_ON_EXIT=1

  apply_version_bump "$next_version" "$next_build"

  git -C "$ROOT_DIR" add "$PROJECT_FILE" "$VERSION_SOURCE_FILE"
  git -C "$ROOT_DIR" commit -m "chore(release): ${tag}"
  git -C "$ROOT_DIR" tag -a "$tag" -m "$tag"
  git -C "$ROOT_DIR" push origin HEAD
  git -C "$ROOT_DIR" push origin "$tag"
  ROLLBACK_ON_EXIT=0

  printf 'Pushed %s — GitHub Actions will build and publish the release.\n' "$tag"
}

main "$@"
