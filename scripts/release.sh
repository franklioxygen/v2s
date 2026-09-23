#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_PATH="$ROOT_DIR/v2s.xcodeproj"
PROJECT_FILE="$PROJECT_PATH/project.pbxproj"
VERSION_SOURCE_FILE="$ROOT_DIR/Sources/V2SApp/App/AppModel.swift"
RELEASE_WORKFLOW_NAME="Release"
RELEASE_WORKFLOW_PATH=".github/workflows/release.yml"
WORKFLOW_ACTIVATION_POLL_ATTEMPTS=30
WORKFLOW_ACTIVATION_POLL_SECONDS=2
WORKFLOW_RUN_POLL_ATTEMPTS=20
WORKFLOW_RUN_POLL_SECONDS=3
PROJECT_FILE_BACKUP=""
VERSION_SOURCE_FILE_BACKUP=""
ROLLBACK_ON_EXIT=0
# How to finish or undo a release that failed after the version bump was committed.
RECOVERY_HINT=""

cleanup() {
  local exit_code=$?

  if [[ $exit_code -ne 0 && -n "$RECOVERY_HINT" ]]; then
    printf '\n%s\n' "$RECOVERY_HINT" >&2
  fi

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

current_utc_timestamp() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

resolve_default_branch() {
  git -C "$ROOT_DIR" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##'
}

resolve_repo_name() {
  gh repo view --json nameWithOwner --jq .nameWithOwner
}

active_release_workflow_id() {
  local repo="$1"

  gh api "repos/${repo}/actions/workflows" \
    --jq ".workflows[] | select(.path == \"$RELEASE_WORKFLOW_PATH\" and .state == \"active\") | .id" \
    2>/dev/null | head -n 1
}

wait_for_release_workflow() {
  local repo="$1"
  local workflow_id=""
  local attempt

  for ((attempt = 1; attempt <= WORKFLOW_ACTIVATION_POLL_ATTEMPTS; attempt++)); do
    workflow_id="$(active_release_workflow_id "$repo")"
    if [[ -n "$workflow_id" ]]; then
      printf '%s\n' "$workflow_id"
      return 0
    fi

    sleep "$WORKFLOW_ACTIVATION_POLL_SECONDS"
  done

  fail "GitHub did not register ${RELEASE_WORKFLOW_PATH} as an active workflow in time."
}

recent_release_workflow_run_url() {
  local repo="$1"
  local workflow_id="$2"
  local since="$3"

  gh api "repos/${repo}/actions/workflows/${workflow_id}/runs?per_page=20" \
    --jq ".workflow_runs[] | select(.created_at >= \"$since\") | .html_url" \
    2>/dev/null | head -n 1
}

wait_for_release_workflow_run() {
  local repo="$1"
  local workflow_id="$2"
  local since="$3"
  local run_url=""
  local attempt

  for ((attempt = 1; attempt <= WORKFLOW_RUN_POLL_ATTEMPTS; attempt++)); do
    run_url="$(recent_release_workflow_run_url "$repo" "$workflow_id" "$since")"
    if [[ -n "$run_url" ]]; then
      printf '%s\n' "$run_url"
      return 0
    fi

    sleep "$WORKFLOW_RUN_POLL_SECONDS"
  done

  return 1
}

dispatch_release_workflow() {
  local tag="$1"
  local default_branch="$2"

  gh workflow run "$RELEASE_WORKFLOW_NAME" --ref "$default_branch" -f tag="$tag" >/dev/null
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
  default_branch="$(resolve_default_branch)"

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
  require_cmd gh
  require_cmd perl

  [[ -f "$PROJECT_FILE" ]] || fail "Xcode project file not found: ${PROJECT_FILE}"
  [[ -f "$VERSION_SOURCE_FILE" ]] || fail "Version source file not found: ${VERSION_SOURCE_FILE}"

  gh auth status >/dev/null 2>&1 || fail "GitHub CLI is not authenticated. Run 'gh auth login' first."

  assert_clean_worktree
  assert_default_branch

  local current_version
  local current_build
  local next_version
  local next_build
  local tag
  local default_branch
  local repo
  local workflow_id
  local run_url
  local tag_push_started_at
  local dispatch_started_at

  current_version="$(extract_setting "MARKETING_VERSION")"
  current_build="$(extract_setting "CURRENT_PROJECT_VERSION")"
  default_branch="$(resolve_default_branch)"
  repo="$(resolve_repo_name)"

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
  # The commit now holds the bump. Restoring the backups from here on would leave the
  # worktree behind HEAD, so later failures print how to recover instead.
  ROLLBACK_ON_EXIT=0
  RECOVERY_HINT="$(printf '%s\n' \
    "The release commit for ${tag} was created locally but not pushed." \
    "To undo it: git tag -d ${tag}; git reset --hard HEAD~1")"

  git -C "$ROOT_DIR" tag -a "$tag" -m "$tag"
  RECOVERY_HINT="$(printf '%s\n' \
    "The release commit and tag ${tag} were created locally but not pushed." \
    "To finish:  git push origin HEAD && git push origin ${tag}" \
    "To undo it: git tag -d ${tag}; git reset --hard HEAD~1")"

  git -C "$ROOT_DIR" push origin HEAD
  RECOVERY_HINT="$(printf '%s\n' \
    "The release commit for ${tag} is on origin, but the tag was not pushed." \
    "To finish: git push origin ${tag}" \
    "If no release workflow starts, run: gh workflow run ${RELEASE_WORKFLOW_NAME} --ref ${default_branch} -f tag=${tag}")"

  workflow_id="$(wait_for_release_workflow "$repo")"
  printf 'Release workflow is active on GitHub (id %s).\n' "$workflow_id"

  tag_push_started_at="$(current_utc_timestamp)"
  git -C "$ROOT_DIR" push origin "$tag"
  RECOVERY_HINT="$(printf '%s\n' \
    "Tag ${tag} is on origin, but no release workflow run was confirmed." \
    "Check the Actions tab, or run: gh workflow run ${RELEASE_WORKFLOW_NAME} --ref ${default_branch} -f tag=${tag}")"

  run_url="$(wait_for_release_workflow_run "$repo" "$workflow_id" "$tag_push_started_at" || true)"

  if [[ -z "$run_url" ]]; then
    printf 'No release workflow run appeared after pushing %s; dispatching workflow manually.\n' "$tag"
    dispatch_started_at="$(current_utc_timestamp)"
    dispatch_release_workflow "$tag" "$default_branch"
    run_url="$(wait_for_release_workflow_run "$repo" "$workflow_id" "$dispatch_started_at" || true)"
    [[ -n "$run_url" ]] || fail "Release workflow did not appear after manual dispatch for ${tag}."
  fi

  printf 'Pushed %s — GitHub Actions will build and publish the release.\n' "$tag"
  printf 'Workflow: %s\n' "$run_url"
}

main "$@"
