#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
build_dir="${TARGETFLOW_TEST_BUILD_DIR:-$repo_dir/build/test-release}"
output_dir="$repo_dir/dist"
architecture="${TARGETFLOW_TEST_ARCH:-$(uname -m)}"
identity="${TARGETFLOW_SIGNING_IDENTITY:-}"
identity_file="$repo_dir/scripts/local-signing-identity"
if [[ -z "$identity" && -f "$identity_file" ]]; then
  IFS= read -r identity < "$identity_file" || [[ -n "$identity" ]]
fi
if [[ -z "$identity" || "$identity" == "-" ]]; then
  printf '%s\n' 'A persistent code-signing certificate is required to keep the signing identity stable across updates.' \
    'Set TARGETFLOW_SIGNING_IDENTITY or scripts/local-signing-identity to its SHA-1 fingerprint.' \
    'A self-signed code-signing certificate works; Developer ID is not required for this release package.' >&2
  exit 1
fi

case "$architecture" in
  arm64|x86_64) ;;
  *) printf 'Unsupported architecture: %s\n' "$architecture" >&2; exit 1 ;;
esac

xcodebuild -project "$repo_dir/Dayflow/Dayflow.xcodeproj" \
  -scheme Dayflow -configuration Release -destination 'generic/platform=macOS' \
  -derivedDataPath "$build_dir" ARCHS="$architecture" ONLY_ACTIVE_ARCH=NO \
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$identity" \
  ENABLE_DEBUG_DYLIB=NO build

app_path="$build_dir/Build/Products/Release/TargetFlow.app"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app_path/Contents/Info.plist")"
mkdir -p "$output_dir"
dmg_path="$output_dir/TargetFlow-$version-$architecture.dmg"
if [[ -e "$dmg_path" ]]; then
  printf 'Output already exists: %s\nMove it aside before packaging again.\n' "$dmg_path" >&2
  exit 1
fi

stage_dir="$(mktemp -d -t targetflow-release-package)"
trap 'rm -rf "$stage_dir"' EXIT
ditto "$app_path" "$stage_dir/TargetFlow.app"
codesign --verify --deep --strict --verbose=2 "$stage_dir/TargetFlow.app"
requirement="$(codesign -d -r- "$stage_dir/TargetFlow.app" 2>&1)"
if [[ "$requirement" != *'identifier "local.targetflow.app"'* || "$requirement" != *'certificate'* || "$requirement" == *'cdhash'* ]]; then
  printf 'Refusing to package an app without a stable certificate-based identity:\n%s\n' "$requirement" >&2
  exit 1
fi
ln -s /Applications "$stage_dir/Applications"
cp "$repo_dir/docs/release-install.txt" "$stage_dir/READ ME FIRST.txt"

hdiutil create -volname "Target Flow $version" -srcfolder "$stage_dir" \
  -format UDZO -ov "$dmg_path"
hdiutil verify "$dmg_path"
(cd "$output_dir" && shasum -a 256 "$(basename "$dmg_path")") > "$dmg_path.sha256"
printf '\nRelease package: %s\nCertificate signed; not notarized. Architecture: %s\n' "$dmg_path" "$architecture"
