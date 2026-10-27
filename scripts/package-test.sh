#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
build_dir="${TARGETFLOW_TEST_BUILD_DIR:-$repo_dir/build/test-release}"
output_dir="$repo_dir/dist"
architecture="${TARGETFLOW_TEST_ARCH:-$(uname -m)}"

case "$architecture" in
  arm64|x86_64) ;;
  *) printf 'Unsupported architecture: %s\n' "$architecture" >&2; exit 1 ;;
esac

xcodebuild -project "$repo_dir/Dayflow/Dayflow.xcodeproj" \
  -scheme Dayflow -configuration Release -destination 'generic/platform=macOS' \
  -derivedDataPath "$build_dir" ARCHS="$architecture" ONLY_ACTIVE_ARCH=NO \
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- \
  ENABLE_DEBUG_DYLIB=NO build

app_path="$build_dir/Build/Products/Release/TargetFlow.app"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app_path/Contents/Info.plist")"
mkdir -p "$output_dir"
dmg_path="$output_dir/TargetFlow-$version-test-$architecture.dmg"
if [[ -e "$dmg_path" ]]; then
  printf 'Output already exists: %s\nMove it aside before packaging again.\n' "$dmg_path" >&2
  exit 1
fi

stage_dir="$(mktemp -d -t targetflow-test-package)"
trap 'rm -rf "$stage_dir"' EXIT
ditto "$app_path" "$stage_dir/TargetFlow.app"
codesign --verify --deep --strict --verbose=2 "$stage_dir/TargetFlow.app"
ln -s /Applications "$stage_dir/Applications"
cp "$repo_dir/docs/test-release-install.txt" "$stage_dir/READ ME FIRST.txt"

hdiutil create -volname "Target Flow $version Test" -srcfolder "$stage_dir" \
  -format UDZO -ov "$dmg_path"
hdiutil verify "$dmg_path"
(cd "$output_dir" && shasum -a 256 "$(basename "$dmg_path")") > "$dmg_path.sha256"
printf '\nTest package: %s\nAd-hoc signed; not notarized. Architecture: %s\n' "$dmg_path" "$architecture"
