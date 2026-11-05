#!/usr/bin/env bash
# Build an isolated native preview and replay real saved recordings locally or over SSH.
set -euo pipefail
repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
remote_host=""
output_dir=""
prepared=0
skip_build=0
id_namespace=0
view_only=0
retry_batches=""
background=0
from_snapshot=""
windows=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --host) remote_host="$2"; shift 2 ;;
    --output) output_dir="$2"; shift 2 ;;
    --from-snapshot) from_snapshot="$2"; shift 2 ;;
    --prepared) prepared=1; shift ;;
    --view-only) view_only=1; prepared=1; shift ;;
    --background) background=1; shift ;;
    --retry-batch) retry_batches="${retry_batches:+$retry_batches,}$2"; shift 2 ;;
    --id-namespace) id_namespace="$2"; shift 2 ;;
    --skip-build) skip_build=1; shift ;;
    --window) windows+=("$2"); shift 2 ;;
    -h|--help)
      printf '%s\n' 'Usage: bash scripts/replay-recording.sh [--host MacBookPro] [--output /absolute/run/directory] [--skip-build] [--prepared|--view-only] [--background] [--from-snapshot /saved/replay] [--retry-batch ID] [--id-namespace N] --window START,END [--window START,END ...]' \
        'Dates must include timezone offsets. --prepared resumes/views an existing isolated snapshot without recreating it.'
      exit 0 ;;
    *) printf 'Unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done
if [[ "$prepared" == 0 && ${#windows[@]} == 0 ]]; then
  printf '%s\n' 'At least one --window START,END is required.' >&2
  exit 2
fi
if [[ "$prepared" == 1 && -z "$output_dir" ]]; then
  printf '%s\n' '--prepared requires --output pointing to an existing replay directory.' >&2
  exit 2
fi
if [[ -n "$from_snapshot" && "$prepared" == 1 ]]; then
  printf '%s\n' '--from-snapshot creates a new analysis run and cannot be combined with --prepared or --view-only.' >&2
  exit 2
fi
if [[ -n "$retry_batches" && ( "$prepared" != 1 || "$view_only" == 1 ) ]]; then
  printf '%s\n' '--retry-batch requires --prepared and cannot be combined with --view-only.' >&2
  exit 2
fi
build_dir="${TARGETFLOW_REPLAY_BUILD_DIR:-$repo_dir/build/local}"
if [[ "$skip_build" == 0 ]]; then
  printf '%s\n' 'Building native replay preview…'
  xcodebuild -project "$repo_dir/Dayflow/Dayflow.xcodeproj" -scheme Dayflow \
    -configuration Release -destination 'generic/platform=macOS' -derivedDataPath "$build_dir" \
    ARCHS=arm64 ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO ENABLE_DEBUG_DYLIB=NO build \
    > /tmp/targetflow-replay-build.log 2>&1 || {
      printf '%s\n' 'Build failed. See /tmp/targetflow-replay-build.log' >&2
      exit 1
    }
fi
built_app="$build_dir/Build/Products/Release/TargetFlow.app"
if [[ ! -d "$built_app" ]]; then
  printf 'Built application missing: %s\n' "$built_app" >&2
  exit 1
fi
run_stamp="$(date +%Y%m%d-%H%M%S)-$$"
stage_dir="$(mktemp -d /tmp/targetflow-replay-package.XXXXXX)"
trap 'rm -rf "$stage_dir"' EXIT
app_path="$stage_dir/TargetFlowReplay.app"
ditto "$built_app" "$app_path"
# Do not override PRODUCT_NAME in xcodebuild: it renames SwiftPM resource bundles.
# Package a separate executable and identity after the normal target is built.
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier local.targetflow.preview.replay.r$run_stamp" "$app_path/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleName TargetFlowReplay' "$app_path/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleDisplayName TargetFlow 回放预览' "$app_path/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleExecutable TargetFlowReplay' "$app_path/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :TargetFlowReplayPreview bool true' "$app_path/Contents/Info.plist"
if [[ "$view_only" == 1 ]]; then
  /usr/libexec/PlistBuddy -c 'Add :TargetFlowReplayViewOnly bool true' "$app_path/Contents/Info.plist"
else
  /usr/libexec/PlistBuddy -c 'Add :TargetFlowReplayViewOnly bool false' "$app_path/Contents/Info.plist"
fi
/usr/libexec/PlistBuddy -c 'Delete :CFBundleURLTypes' "$app_path/Contents/Info.plist" 2>/dev/null || true
mv "$app_path/Contents/MacOS/TargetFlow" "$app_path/Contents/MacOS/TargetFlowReplay"
codesign --force --deep --sign - --entitlements "$repo_dir/Dayflow/Dayflow/Dayflow.entitlements" "$app_path"
codesign --verify --deep --strict "$app_path"
cp "$repo_dir/scripts/prepare-recording-replay.py" "$stage_dir/prepare.py"
cat > "$stage_dir/launch.sh" <<'LAUNCH'
#!/usr/bin/env bash
set -euo pipefail
run_dir="$1"
prepared="$2"
view_only="$3"
retry_batches="$4"
background="$5"
shift 5
package_dir="$(cd "$(dirname "$0")" && pwd)"
if [[ "$prepared" == 0 ]]; then
  python3 "$package_dir/prepare.py" --output "$run_dir" "$@"
fi
[[ "$run_dir" == /* && -f "$run_dir/manifest.json" && -f "$run_dir/replay-preferences.plist" ]] || {
  printf '%s\n' 'A valid prepared replay directory and preferences seed are required.' >&2
  exit 1
}
if [[ -e "$run_dir/TargetFlowReplay.app" ]]; then
  printf '%s\n' 'Replay app already exists in this run. Reopen it with its original launch command or use a fresh run.' >&2
  exit 1
fi
ditto "$package_dir/TargetFlowReplay.app" "$run_dir/TargetFlowReplay.app"
codesign --verify --deep --strict "$run_dir/TargetFlowReplay.app"
open_options=(-n)
if [[ "$background" == 1 ]]; then open_options+=(-g -j); fi
/usr/bin/open "${open_options[@]}" \
  --env "TARGETFLOW_UI_PREVIEW_DATA_DIR=$run_dir" \
  --env "TARGETFLOW_REPLAY_MANIFEST=$run_dir/manifest.json" \
  --env "TARGETFLOW_REPLAY_VIEW_ONLY=$view_only" \
  --env "TARGETFLOW_REPLAY_RETRY_BATCH_IDS=$retry_batches" \
  --stdout "$run_dir/app.log" --stderr "$run_dir/app-error.log" \
  "$run_dir/TargetFlowReplay.app"
printf '\nReplay app: %s\nProgress/report: %s\n' "$run_dir/TargetFlowReplay.app" "$run_dir/report.json"
LAUNCH
arguments=(--id-namespace "$id_namespace")
if [[ -n "$from_snapshot" ]]; then arguments+=(--source-data "$from_snapshot"); fi
for window in "${windows[@]+"${windows[@]}"}"; do
  arguments+=(--window "$window")
done
if [[ -n "$remote_host" ]]; then
  remote_home="$(ssh "$remote_host" 'printf "%s" "$HOME"')"
  output_dir="${output_dir:-$remote_home/Downloads/TargetFlow-Replay-$run_stamp}"
  remote_stage="/tmp/targetflow-replay-$run_stamp"
  ditto -c -k --keepParent "$app_path" "$stage_dir/app.zip"
  ssh "$remote_host" "mkdir -m 700 '$remote_stage'"
  scp "$stage_dir/app.zip" "$stage_dir/prepare.py" "$stage_dir/launch.sh" "$remote_host:$remote_stage/"
  # %q preserves paths/windows as shell arguments rather than interpolated code.
  printf -v remote_command '%q ' /bin/bash -c 'ditto -x -k "$1/app.zip" "$1"; shift; exec /bin/bash "$@"' _ \
    "$remote_stage" "$remote_stage/launch.sh" "$output_dir" "$prepared" "$view_only" "$retry_batches" "$background" "${arguments[@]+"${arguments[@]}"}"
  ssh "$remote_host" "$remote_command"
else
  output_dir="${output_dir:-$HOME/Downloads/TargetFlow-Replay-$run_stamp}"
  /bin/bash "$stage_dir/launch.sh" "$output_dir" "$prepared" "$view_only" "$retry_batches" "$background" "${arguments[@]+"${arguments[@]}"}"
fi
