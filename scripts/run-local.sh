#!/bin/bash
set -euo pipefail

repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
build_dir="${TARGETFLOW_BUILD_DIR:-$repo_dir/build/local}"
identity_file="$repo_dir/scripts/local-signing-identity"
identity="${TARGETFLOW_SIGNING_IDENTITY:-}"
if [[ -z "$identity" && -f "$identity_file" ]]; then
  IFS= read -r identity < "$identity_file" || [[ -n "$identity" ]]
fi
app_path="/Applications/TargetFlow.app"

stop_running_app() {
  local current_uid
  current_uid="$(/usr/bin/id -u)"
  if ! /usr/bin/pgrep -u "$current_uid" -x TargetFlow >/dev/null; then
    return 0
  fi

  # A normal Quit request only hides this menu-bar app. TERM ends the process.
  printf '%s\n' 'Stopping Target Flow before installing…'
  /usr/bin/pkill -TERM -u "$current_uid" -x TargetFlow || true
  local attempt
  for ((attempt = 0; attempt < 60; attempt++)); do
    if ! /usr/bin/pgrep -u "$current_uid" -x TargetFlow >/dev/null; then
      return 0
    fi
    /bin/sleep 0.5
  done

  if /usr/bin/pgrep -u "$current_uid" -x TargetFlow >/dev/null; then
    printf '%s\n' 'Target Flow did not exit within 30 seconds. Installation cancelled; the installed app has not been replaced.' >&2
    return 1
  fi
}

if [[ "${1:-}" != "" && "${1:-}" != "--build-only" ]]; then
  printf 'Usage: bash scripts/run-local.sh [--build-only]\n' >&2
  exit 2
fi

if [[ -z "$identity" ]]; then
  printf '%s\n' 'No persistent signing identity configured.' \
    'Set TARGETFLOW_SIGNING_IDENTITY or save a certificate SHA-1 in scripts/local-signing-identity.' \
    'List available identities with: security find-identity -v -p codesigning' >&2
  exit 1
fi

if [[ "$identity" == "-" ]]; then
  printf '%s\n' 'Using ad-hoc signing. Rebuilding can invalidate screen-recording permission.' \
    'For repeated development, set TARGETFLOW_SIGNING_IDENTITY to your code-signing certificate.' >&2
fi

xcodebuild -project "$repo_dir/Dayflow/Dayflow.xcodeproj" \
  -scheme Dayflow -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath "$build_dir" CODE_SIGNING_ALLOWED=YES \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$identity" ENABLE_DEBUG_DYLIB=NO build

built_app="$build_dir/Build/Products/Debug/TargetFlow.app"
/usr/bin/codesign --verify --deep --strict "$built_app"
if [[ "${1:-}" == "--build-only" ]]; then
  printf 'Built and verified: %s\n' "$built_app"
  exit 0
fi

if [[ -e "$app_path" ]]; then
  installed_id=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$app_path/Contents/Info.plist")
  if [[ "$installed_id" != "local.targetflow.app" ]]; then
    printf 'Refusing to replace a different application: %s\n' "$app_path" >&2
    exit 1
  fi
fi
# Use a clean bundle so removed build products cannot remain in the installation.
stage_dir=$(/usr/bin/mktemp -d /Applications/.targetflow-install.XXXXXX)
trap '/bin/rm -rf "$stage_dir"' EXIT
/usr/bin/ditto "$built_app" "$stage_dir/TargetFlow.app"
/usr/bin/codesign --verify --deep --strict "$stage_dir/TargetFlow.app"
stop_running_app
if [[ -e "$app_path" ]]; then
  /bin/mv "$app_path" "$stage_dir/previous.app"
fi
if ! /bin/mv "$stage_dir/TargetFlow.app" "$app_path"; then
  if [[ -d "$stage_dir/previous.app" ]]; then
    /bin/mv "$stage_dir/previous.app" "$app_path"
  fi
  exit 1
fi
# Refresh the installed bundle's icon metadata after replacing it, even when the
# development build keeps the same version number.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$app_path"
/usr/bin/open "$app_path"
