#!/usr/bin/env bash
#
# Bulletproof bootstrap for `pnpm tauri ios dev` on a fresh checkout of this
# plugin. Pre-populates every git clone the iOS build will trigger, configures
# git for the `file://` transport submodules require, and wipes stale
# SwiftPM workspace state — so the build itself spends time on compile,
# not on network or stale lockfiles. Idempotent, retrying, parallelized.
#
# Five things this handles:
#
#   1. **SwiftPM transitive deps** (32 repos: amplify-swift, aws-sdk-swift,
#      aws-crt-swift, smithy-swift, the apple/swift-* family, etc.). Cloned
#      with `git clone --mirror` (full history, all blobs, no `--filter`)
#      into the user-level SwiftPM cache and the plugin's per-project
#      Index-Build cache.
#
#   2. **aws-crt-swift git submodules** (12 repos: aws-c-*, aws-checksums,
#      s2n-tls, plus s2n-tls's own aws-verification-model-for-libcrypto
#      sub-submodule). Cloned into a side cache and exposed to git via
#      global `url.<local>.insteadOf <github>` config rewrites, so when
#      SwiftPM's checkout runs `git submodule update --init --recursive`,
#      git transparently uses the local mirrors. s2n-tls is shallow-cloned
#      (depth=1000) — its full history is large and slow, but the pinned
#      submodule SHA is in recent history.
#
#   3. **`protocol.file.allow=always`** in the global git config. CVE-2022-39253
#      blocks `file://` transport in submodule clones by default — but our
#      `insteadOf` rewrites resolve to local file paths, so submodule update
#      fails with `fatal: transport 'file' not allowed` without this. We're
#      explicitly trusting our own pre-cloned mirrors.
#
#   4. **Wipe SwiftPM workspace state** so the next build re-resolves cleanly.
#      Includes Package.resolved, workspace-state.json, the plugin's own
#      ios/.build/, and the SwiftPM fingerprint file for amplify-ui-swift-
#      liveness. (The amplify-ui-swift-liveness macOS-12 platform fix is now
#      handled by vendoring the source at vendor/amplify-ui-swift-liveness/
#      and using a path-based dep — see ios/Package.swift. Bypasses
#      SwiftPM's fingerprint cache entirely.)
#
#   5. **Parallel clones + retry on transient failure**. Up to 6 concurrent
#      clones (saturates a 100 Mbps line). Each retries up to 3 times with
#      cleanup between attempts. Detects + repairs partial-cloned leftovers
#      (`--filter=blob:none`) from earlier script versions which break
#      `git checkout` for aws-sdk-swift specifically.
#
# Why not partial clones (`--filter=blob:none`): we tried. SwiftPM's
# resolution accepted them but `swift-rs`'s nested `swift build` does
# `git checkout` of aws-sdk-swift via `git clone --separate-git-dir`, which
# loses the partial-clone promisor config. Result: thousands of "unable to
# read sha1 file" errors at scale on aws-sdk-swift specifically. Full
# mirror clones are the only reliable path.
#
# Usage:
#   ./bootstrap-ios-caches.sh                   # populate everything, skip existing
#   ./bootstrap-ios-caches.sh --force           # wipe and re-clone everything
#   ./bootstrap-ios-caches.sh --user-only       # skip plugin index-build cache
#   ./bootstrap-ios-caches.sh --skip-submodules # skip submodule mirrors + git config rewrites
#   ./bootstrap-ios-caches.sh --jobs N          # change parallel-clone cap (default 6)
#   ./bootstrap-ios-caches.sh --undo            # remove the global git config changes this script made
#

set -euo pipefail
set -o pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PLUGIN_DIR=$(cd "$SCRIPT_DIR/.." && pwd)

USER_CACHE="$HOME/Library/Caches/org.swift.swiftpm/repositories"
INDEX_CACHE="$PLUGIN_DIR/ios/.build/index-build/repositories"
SUBMODULE_CACHE="$HOME/Library/Caches/swiftpm-submodule-mirrors"
LOG_DIR="$(mktemp -d -t bootstrap-ios-caches.XXXXXX)"
STOP_FLAG="$LOG_DIR/.monitor-stop"
MONITOR_PID=""
# NOTE: previous versions of this script tried to fix amplify-ui-swift-liveness
# 1.4.4's upstream Package.swift bug (declares only iOS, depends on macOS 12)
# by patching the cached bare repo's tag. SwiftPM's *fingerprint cache* at
# ~/Library/org.swift.swiftpm/security/fingerprints/ defeats every variant
# of that approach — SwiftPM cross-checks resolved revisions against the
# fingerprint, regardless of what `Package.resolved` or the bare repo says.
# The plugin now vendors amplify-ui-swift-liveness's source at
# vendor/amplify-ui-swift-liveness/ and references it via a path-based
# dep, which bypasses fingerprint validation entirely. So this script no
# longer needs to do any cache surgery for amplify-ui-swift-liveness.

cleanup_monitor() {
  if [ -n "$MONITOR_PID" ]; then
    touch "$STOP_FLAG" 2>/dev/null || true
    kill "$MONITOR_PID" 2>/dev/null || true
    wait "$MONITOR_PID" 2>/dev/null || true
  fi
}
trap cleanup_monitor EXIT INT TERM

FORCE=0
USER_ONLY=0
SKIP_SUBMODULES=0
UNDO=0
MAX_PARALLEL=6
while [ $# -gt 0 ]; do
  case "$1" in
    --force) FORCE=1; shift ;;
    --user-only) USER_ONLY=1; shift ;;
    --skip-submodules) SKIP_SUBMODULES=1; shift ;;
    --undo) UNDO=1; shift ;;
    --jobs) MAX_PARALLEL="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,68p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "unknown arg: $1" >&2
      exit 2
      ;;
  esac
done

# ---------------------------------------------------------------------------
# 1. SwiftPM transitive-dep mirror clones
# ---------------------------------------------------------------------------
SWIFTPM_REPOS=(
  "https://github.com/aws-amplify/amplify-swift|amplify-swift-b09f4240"
  "https://github.com/aws-amplify/amplify-swift-utils-notifications.git|amplify-swift-utils-notifications-67b43356"
  "https://github.com/aws-amplify/amplify-ui-swift-liveness|amplify-ui-swift-liveness-2c84baec"
  "https://github.com/awslabs/aws-crt-swift|aws-crt-swift-648c53ed"
  "https://github.com/awslabs/aws-sdk-swift|aws-sdk-swift-fc21a3a0"
  "https://github.com/smithy-lang/smithy-swift|smithy-swift-a8bdf756"
  "https://github.com/apple/swift-nio.git|swift-nio-a9bb6d62"
  "https://github.com/apple/swift-nio-extras.git|swift-nio-extras-ee9c8e34"
  "https://github.com/apple/swift-nio-http2.git|swift-nio-http2-440d95c6"
  "https://github.com/apple/swift-nio-ssl.git|swift-nio-ssl-3eddd832"
  "https://github.com/apple/swift-nio-transport-services.git|swift-nio-transport-services-195621bb"
  "https://github.com/apple/swift-algorithms.git|swift-algorithms-bf5a01cd"
  "https://github.com/apple/swift-asn1.git|swift-asn1-7065ad2c"
  "https://github.com/apple/swift-async-algorithms.git|swift-async-algorithms-c3a8d752"
  "https://github.com/apple/swift-atomics.git|swift-atomics-7429e549"
  "https://github.com/apple/swift-certificates.git|swift-certificates-b091bbdc"
  "https://github.com/apple/swift-collections|swift-collections-9a58d5cf"
  "https://github.com/apple/swift-configuration.git|swift-configuration-80a4e428"
  "https://github.com/apple/swift-crypto.git|swift-crypto-7e0614ea"
  "https://github.com/apple/swift-distributed-tracing.git|swift-distributed-tracing-85e5637e"
  "https://github.com/apple/swift-http-structured-headers.git|swift-http-structured-headers-efdd7ab3"
  "https://github.com/apple/swift-http-types.git|swift-http-types-ddff8b60"
  "https://github.com/apple/swift-log.git|swift-log-ba8887eb"
  "https://github.com/apple/swift-numerics.git|swift-numerics-d936ec6c"
  "https://github.com/apple/swift-service-context.git|swift-service-context-29630b35"
  "https://github.com/apple/swift-system|swift-system-5815d4b7"
  "https://github.com/swift-server/async-http-client.git|async-http-client-afefb790"
  "https://github.com/swift-server/swift-service-lifecycle|swift-service-lifecycle-0ea726b6"
  "https://github.com/attaswift/BigInt|BigInt-7b87d7d1"
  "https://github.com/stephencelis/SQLite.swift.git|SQLite.swift-bde2929d"
  "https://github.com/swiftlang/swift-toolchain-sqlite|swift-toolchain-sqlite-0b780d78"
  "https://github.com/Brendonovich/swift-rs|swift-rs-16819c90"
)

# ---------------------------------------------------------------------------
# 2. aws-crt-swift submodules (matched exactly to their .gitmodules entries —
#    URL form with/without `.git` matters for `insteadOf` exact-match)
# ---------------------------------------------------------------------------
SUBMODULE_REPOS=(
  "https://github.com/awslabs/aws-c-common.git"
  "https://github.com/awslabs/aws-c-io.git"
  "https://github.com/aws/s2n-tls.git"
  "https://github.com/awslabs/aws-c-compression.git"
  "https://github.com/awslabs/aws-c-http.git"
  "https://github.com/awslabs/aws-c-auth.git"
  "https://github.com/awslabs/aws-c-cal"
  "https://github.com/awslabs/aws-c-sdkutils"
  "https://github.com/awslabs/aws-checksums"
  "https://github.com/awslabs/aws-c-event-stream"
  "https://github.com/awslabs/aws-c-mqtt.git"
  "https://github.com/awslabs/aws-verification-model-for-libcrypto.git"
)

# ---------------------------------------------------------------------------
# Common helpers
# ---------------------------------------------------------------------------

ensure_no_active_build() {
  if pgrep -f 'tauri ios dev|xcodebuild.*rekognition-liveness' >/dev/null 2>&1; then
    echo "error: an iOS build appears to be running. Stop pnpm tauri ios dev / Xcode build first, then re-run this script." >&2
    exit 3
  fi
}

# SwiftPM-aware IDE daemons (SourceKitService for VSCode/Cursor/Xcode) re-
# resolve Swift packages in the background whenever they detect changes,
# which can race our patch_amplify_liveness_manifest step and recreate the
# Package.resolved lockfiles we just deleted — pinning the OLD upstream
# SHA. Kill them before patching; they'll restart automatically when the
# IDE next opens a Swift file.
kill_swift_indexers() {
  local killed=0
  for pat in 'sourcekit-lsp' 'SourceKitService' 'swift-package' 'swift-build.*rekognition-liveness'; do
    if pgrep -f "$pat" >/dev/null 2>&1; then
      pkill -f "$pat" 2>/dev/null && killed=$((killed+1)) || true
    fi
  done
  if [ "$killed" -gt 0 ]; then
    sleep 1
    echo "  killed $killed swift indexer process(es); IDEs will restart them when needed"
  fi
}

short_label() {
  local id=$1
  echo "${id%-[a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9]}"
}

REFRESH_SEC=5
PHASE_IDS=()
PHASE_TOTAL=0
PHASE_LABEL=""

monitor_loop() {
  while [ ! -f "$STOP_FLAG" ]; do
    local now done_count=0 active_count=0 queued_count=0
    local active_block=""
    now=$(date +%H:%M:%S)
    local id
    for id in "${PHASE_IDS[@]}"; do
      local log="$LOG_DIR/$id.log"
      if [ ! -f "$log" ]; then
        queued_count=$((queued_count+1))
        continue
      fi
      if grep -q '^# DONE\|^# GIVE UP' "$log" 2>/dev/null; then
        done_count=$((done_count+1))
        continue
      fi
      active_count=$((active_count+1))
      local last
      last=$(tail -1 "$log" 2>/dev/null | tr '\r' '\n' | grep -v '^$' | tail -1)
      last=$(echo "$last" | sed -E 's/[[:space:]]+$//' | cut -c1-100)
      active_block+=$(printf '  %-30s %s\n' "$(short_label "$id" | cut -c1-30)" "$last")$'\n'
    done
    printf '\n=== %s @ %s — %d/%d done | %d active | %d queued ===\n' \
      "$PHASE_LABEL" "$now" "$done_count" "$PHASE_TOTAL" "$active_count" "$queued_count"
    printf '%s' "$active_block"
    sleep "$REFRESH_SEC"
  done
}

start_monitor() {
  PHASE_LABEL=$1
  shift
  PHASE_IDS=("$@")
  PHASE_TOTAL=${#PHASE_IDS[@]}
  rm -f "$STOP_FLAG"
  monitor_loop &
  MONITOR_PID=$!
}

stop_monitor() {
  touch "$STOP_FLAG"
  wait "$MONITOR_PID" 2>/dev/null || true
  unset MONITOR_PID
  MONITOR_PID=""
}

# Clone with retry. Up to 3 attempts; wipes and re-tries on failure so we
# don't end up with half-populated dirs. `clone_args` lets the caller pass
# extra flags like `--depth=1000` for shallow clones.
clone_full() {
  local url=$1 dir=$2 log_name=$3 clone_args=${4:-}
  local id
  id=$(basename "$dir")
  local log="$LOG_DIR/$log_name.log"

  if [ -d "$dir" ] && [ "$FORCE" -eq 0 ]; then
    if git -C "$dir" config --get remote.origin.partialclonefilter >/dev/null 2>&1; then
      { echo "skipped (partial-cloned previously, re-run with --force)"; echo "# DONE skipped"; } >"$log"
      return 0
    fi
    { echo "skipped (already present)"; echo "# DONE skipped"; } >"$log"
    return 0
  fi
  [ -d "$dir" ] && rm -rf "$dir"

  : >"$log"
  local attempt
  for attempt in 1 2 3; do
    local started_at
    started_at=$(date +%s)
    if git clone --mirror $clone_args \
          -c core.symlinks=true \
          -c core.fsmonitor=false \
          -c core.longpaths=true \
          "$url" "$dir" --progress >>"$log" 2>&1; then
      local ended_at elapsed
      ended_at=$(date +%s)
      elapsed=$((ended_at - started_at))
      echo "# DONE ${elapsed}s" >>"$log"
      return 0
    fi
    echo "# FAIL attempt $attempt/3" >>"$log"
    rm -rf "$dir"
    [ "$attempt" -lt 3 ] && sleep 5
  done
  echo "# GIVE UP" >>"$log"
  return 1
}

run_parallel_clones() {
  local label=$1 base_dir=$2
  shift 2
  local entries=("$@")
  echo "==> $label  (${#entries[@]} clones, up to $MAX_PARALLEL in parallel — refresh every ${REFRESH_SEC}s)"

  local ids=()
  local entry
  for entry in "${entries[@]}"; do
    if [[ "$entry" == *"|"* ]]; then
      ids+=("${entry#*|}")
    else
      ids+=("$(basename "$entry")")
    fi
  done

  start_monitor "$label" "${ids[@]}"

  local url id
  for entry in "${entries[@]}"; do
    if [[ "$entry" == *"|"* ]]; then
      url=${entry%%|*}
      id=${entry#*|}
    else
      url=$entry
      id=$(basename "$entry")
    fi
    while (( $(jobs -r | wc -l) >= MAX_PARALLEL )); do
      sleep 0.5
    done
    # s2n-tls is the one submodule whose full history is impractically large
    # to clone over GitHub's single-stream throttle. depth=1000 catches the
    # pinned commit on its main branch (verified for the version aws-crt-swift
    # currently pins). If a future aws-crt-swift bumps to a commit older than
    # that, the build will fail at `git submodule update --init --recursive`
    # with "not our ref" — fix is to deepen here.
    local extra=""
    case "$url" in
      *s2n-tls*) extra='--depth=1000 --no-tags' ;;
    esac
    clone_full "$url" "$base_dir/$id" "$id" "$extra" &
  done
  wait

  stop_monitor

  local done_count=0 fail_count=0
  for id in "${ids[@]}"; do
    if grep -q '^# GIVE UP' "$LOG_DIR/$id.log" 2>/dev/null; then
      fail_count=$((fail_count+1))
    else
      done_count=$((done_count+1))
    fi
  done
  echo "==> $label complete: $done_count ok, $fail_count failed"
}

# Self-collision-safe submodule mirror clone: the global `insteadOf` rule for
# this URL (set by a previous run of this script) would otherwise rewrite our
# `git clone <url>` into `git clone <local-empty-dir>` and "succeed" with an
# empty repo. So we unset the rule, clone, then re-set the rule.
clone_submodule_safely() {
  local url=$1 target=$2
  local extra=""
  case "$url" in
    *s2n-tls*) extra='--depth=1000 --no-tags' ;;
  esac

  if [ -d "$target" ] && [ "$FORCE" -eq 0 ]; then
    echo "  [SKIP] $(basename "$target") (already present)"
    git config --global --replace-all "url.$target.insteadOf" "$url"
    return 0
  fi

  git config --global --unset-all "url.$target.insteadOf" 2>/dev/null || true
  [ -d "$target" ] && rm -rf "$target"
  echo "  [CLONE] $url"
  if git clone --mirror $extra \
        -c core.symlinks=true \
        -c core.fsmonitor=false \
        -c core.longpaths=true \
        "$url" "$target" >/dev/null 2>&1; then
    git config --global --replace-all "url.$target.insteadOf" "$url"
    echo "  [DONE]  $(basename "$target")"
  else
    echo "  [FAIL]  $(basename "$target")" >&2
    return 1
  fi
}

# ---------------------------------------------------------------------------
# Patch the amplify-ui-swift-liveness Package.swift (upstream bug: declares
# only iOS 14, depends on amplify-swift which requires macOS 12; SwiftPM
# resolution refuses). We force-update the highest version tag in the local
# bare-repo cache to point to a custom commit with `.macOS(.v12)` added.
# SwiftPM resolves tags from the local cache, so it picks up our patched
# version transparently.
# ---------------------------------------------------------------------------
# Wipe SwiftPM workspace state under the plugin tree. Run when bootstrap has
# materially changed the cache state and we need SwiftPM to re-resolve from
# scratch on the next build. Includes Package.resolved, workspace-state.json,
# the plugin's own ios/.build dir (Xcode index-build cache), and the
# swift-rs per-target checkouts that depend on amplify-ui-swift-liveness.
wipe_swiftpm_workspace_state() {
  pkill -f 'SourceKitService|sourcekit-lsp|swift-package' 2>/dev/null || true
  sleep 1
  find "$PLUGIN_DIR" -name 'Package.resolved' -delete 2>/dev/null || true
  find "$PLUGIN_DIR" -name 'workspace-state.json' -delete 2>/dev/null || true
  rm -rf "$PLUGIN_DIR/ios/.build" 2>/dev/null || true
  find "$PLUGIN_DIR" -path '*/swift-rs/*/checkouts/amplify-ui-swift-liveness' -prune -exec rm -rf {} \; 2>/dev/null || true
  find "$PLUGIN_DIR" -path '*/swift-rs/*/checkouts/aws-crt-swift' -prune -exec rm -rf {} \; 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# --undo: reverse the global git config changes this script made
# ---------------------------------------------------------------------------
if [ "$UNDO" -eq 1 ]; then
  echo "==> Removing url.<local>.insteadOf entries pointing into $SUBMODULE_CACHE"
  git config --global --get-regexp "^url\..*${SUBMODULE_CACHE//\//\\/}.*\.insteadof$" 2>/dev/null \
    | awk '{print $1}' \
    | while read -r key; do
        echo "  unset: $key"
        git config --global --unset-all "$key" 2>/dev/null || true
      done
  echo "==> Unsetting protocol.file.allow"
  git config --global --unset-all protocol.file.allow 2>/dev/null || true

  echo "Done."
  echo "  Mirrors at $SUBMODULE_CACHE remain on disk (\`rm -rf $SUBMODULE_CACHE\` to free)."
  echo "  amplify-ui-swift-liveness is vendored at vendor/amplify-ui-swift-liveness/ — path-based, no cache surgery, no undo needed."
  echo "  To wipe the SwiftPM cache entirely: \`rm -rf $USER_CACHE\` (re-run bootstrap to repopulate)."
  exit 0
fi

ensure_no_active_build

started_total=$(date +%s)
echo "Logs: $LOG_DIR"
echo

# ---------------------------------------------------------------------------
# Phase 0: git config — must run before any submodule clone path is tested
# ---------------------------------------------------------------------------
echo "==> Configuring git for local-mirror submodule clones"
prev=$(git config --global --get protocol.file.allow 2>/dev/null || echo "(unset, defaults to 'user')")
git config --global protocol.file.allow always
echo "  protocol.file.allow: $prev → always (CVE-2022-39253 mitigation; required for insteadOf-redirected submodule clones)"
echo

# ---------------------------------------------------------------------------
# Phase 1: SwiftPM caches
# ---------------------------------------------------------------------------
mkdir -p "$USER_CACHE"
run_parallel_clones "Seeding SwiftPM user cache" "$USER_CACHE" "${SWIFTPM_REPOS[@]}"

if [ "$USER_ONLY" -eq 0 ]; then
  echo
  mkdir -p "$INDEX_CACHE"
  echo "==> Mirroring SwiftPM cache to plugin index-build cache (local copy from user cache)"
  for entry in "${SWIFTPM_REPOS[@]}"; do
    suffix=${entry#*|}
    src="$USER_CACHE/$suffix"
    dst="$INDEX_CACHE/$suffix"
    if [ -d "$dst" ] && [ "$FORCE" -eq 0 ]; then
      if git -C "$dst" config --get remote.origin.partialclonefilter >/dev/null 2>&1; then
        echo "  [REPLACE] $suffix (was partial-cloned)"
        rm -rf "$dst"
      else
        echo "  [SKIP] $suffix (already present)"
        continue
      fi
    fi
    [ -d "$dst" ] && rm -rf "$dst"
    if [ -d "$src" ]; then
      cp -r "$src" "$dst"
      echo "  [COPY] $suffix"
    else
      echo "  [MISS] $suffix not in user cache (will be cloned lazily by SwiftPM)"
    fi
  done
fi

# ---------------------------------------------------------------------------
# Phase 1.5: per-target swift-rs caches (third cache layer; partial-clone repair)
# ---------------------------------------------------------------------------
echo
echo "==> Scanning per-target swift-rs caches for partial-cloned repos"
SR_REPOS_DIRS=$(find "$PLUGIN_DIR" -path '*/swift-rs/*/repositories' -type d 2>/dev/null)
SR_FIXED=0
for sr_root in $SR_REPOS_DIRS; do
  for repo_dir in "$sr_root"/*/; do
    [ -d "$repo_dir" ] || continue
    name=$(basename "$repo_dir")
    if git -C "$repo_dir" config --get remote.origin.partialclonefilter >/dev/null 2>&1; then
      if [ -d "$USER_CACHE/$name" ]; then
        echo "  fixing $repo_dir (was partial)"
        rm -rf "$repo_dir"
        cp -r "$USER_CACHE/$name" "$repo_dir"
        sr_checkouts_dir="$(dirname "$sr_root")/checkouts"
        short_name=${name%-[a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9]}
        if [ -d "$sr_checkouts_dir/$short_name" ]; then
          rm -rf "$sr_checkouts_dir/$short_name"
        fi
        SR_FIXED=$((SR_FIXED+1))
      else
        echo "  WARN: $repo_dir is partial but no replacement in user cache" >&2
      fi
    fi
  done
done
if [ "$SR_FIXED" -gt 0 ]; then
  echo "  fixed $SR_FIXED partial-cloned repo(s); touching plugin build files to invalidate cargo cache"
  touch "$PLUGIN_DIR/build.rs" "$PLUGIN_DIR/src/lib.rs" 2>/dev/null || true
else
  echo "  none found"
fi

# ---------------------------------------------------------------------------
# Phase 2: aws-crt-swift submodule mirrors + insteadOf rules
# ---------------------------------------------------------------------------
if [ "$SKIP_SUBMODULES" -eq 0 ]; then
  echo
  echo "==> Seeding aws-crt-swift submodule mirrors at $SUBMODULE_CACHE (sequential — git config rules require ordering)"
  mkdir -p "$SUBMODULE_CACHE"
  for url in "${SUBMODULE_REPOS[@]}"; do
    dir_name=$(basename "$url")
    target="$SUBMODULE_CACHE/$dir_name"
    clone_submodule_safely "$url" "$target"
  done
fi

# ---------------------------------------------------------------------------
# Phase 3: wipe SwiftPM workspace state so next build re-resolves cleanly
# ---------------------------------------------------------------------------
# Earlier versions of this script also force-patched amplify-ui-swift-liveness's
# tag in the cache. That approach is gone — the plugin now vendors the patched
# source at vendor/amplify-ui-swift-liveness/ and references it via path-based
# dep, sidestepping SwiftPM's fingerprint cache entirely. We still wipe stale
# workspace state so the next resolve sees the new path-based dep wiring.
echo
echo "==> Wiping SwiftPM workspace state under the plugin tree"
kill_swift_indexers
wipe_swiftpm_workspace_state
echo "  done"
# Also wipe the SwiftPM fingerprint file for amplify-ui-swift-liveness — it
# was the reason the old patch-the-tag approach kept failing. Harmless even
# now (path-based deps don't use it); reduces confusion when debugging.
rm -f ~/Library/org.swift.swiftpm/security/fingerprints/amplify-ui-swift-liveness-*.json 2>/dev/null || true

ended_total=$(date +%s)
elapsed_total=$((ended_total - started_total))
echo
echo "Done in ${elapsed_total}s."
echo "  - SwiftPM user cache:       ${#SWIFTPM_REPOS[@]} repos at $USER_CACHE"
[ "$USER_ONLY" -eq 0 ] && echo "  - Plugin index-build cache: ${#SWIFTPM_REPOS[@]} repos at $INDEX_CACHE"
if [ "$SKIP_SUBMODULES" -eq 0 ]; then
  echo "  - Submodule mirrors:        ${#SUBMODULE_REPOS[@]} repos at $SUBMODULE_CACHE"
  echo "  - Global git config:        url.X.insteadOf rewrites + protocol.file.allow=always"
fi
[ "$SKIP_PATCH" -eq 0 ] && echo "  - amplify-ui Package.swift: highest tag in cache patched with .macOS(.v12)"
echo "  - Per-clone logs:           $LOG_DIR"
echo
echo "Now run \`pnpm tauri ios dev\` from examples/tauri-plugin-rekognition-liveness-demo. SwiftPM"
echo "resolution + checkout uses local mirrors; submodule update uses local"
echo "mirrors via insteadOf; the upstream Amplify Package.swift bug is patched"
echo "in the bare-repo tag. The build proceeds straight to swift compile."
