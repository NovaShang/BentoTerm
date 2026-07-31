#!/usr/bin/env bash
# One command for "is the tree still good?".
#
#   ./scripts/verify.sh          packages + terminology (fast, ~30s)
#   ./scripts/verify.sh --apps   also builds both Xcode targets (slow)
#
# The tmux round-trip tests inside the SwiftTmux suite start their own server on
# a private `-L` socket with `-f /dev/null`, so they never see, resize, or kill
# anything in your real tmux — and they don't depend on your ~/.tmux.conf.
set -uo pipefail

cd "$(dirname "$0")/.."

fail=0
step() {
    local name="$1"; shift
    printf '\n\033[1m▸ %s\033[0m\n' "$name"
    if "$@"; then
        printf '\033[32m✓ %s\033[0m\n' "$name"
    else
        printf '\033[31m✘ %s\033[0m\n' "$name"
        fail=1
    fi
}

step "terminology" ./scripts/check-terminology.sh
step "swift-tmux tests" swift test --package-path swift-tmux
step "bento-terminal-core tests" swift test --package-path bento-terminal-core

# First available iPhone simulator UDID, or empty if the toolchain has none.
pick_simulator() {
    xcrun simctl list devices available 2>/dev/null \
        | grep -E '^[[:space:]]+iPhone' \
        | head -1 \
        | sed -E 's/.*\(([0-9A-Fa-f-]{36})\).*/\1/'
}

if [ "${1:-}" = "--apps" ]; then
    step "macOS app builds" xcodebuild build \
        -project BentoTerm.xcodeproj -scheme BentoTermMac -configuration Debug \
        -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -quiet
    step "iOS app builds" xcodebuild build \
        -project BentoTerm.xcodeproj -scheme BentoTermiOS -configuration Debug \
        -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO -quiet

    # The iOS unit tests live in an Xcode target, not a SwiftPM package, so
    # `swift test` above never sees them — they need a booted simulator, which
    # is why they ride with --apps instead of the fast default path. Without
    # this step BentoTermTests can stop compiling entirely (it did, for four
    # commits after the module rename) while everything else reports green.
    SIM_UDID="$(pick_simulator)"
    if [ -z "$SIM_UDID" ]; then
        # A missing simulator is an environment gap, not a broken tree: warn
        # loudly but leave `fail` alone. A test that actually FAILS still
        # goes through `step` below and turns the run red.
        printf '\n\033[33m⚠ no iOS simulator available — skipping iOS unit tests\033[0m\n'
        printf '  (install one via Xcode ▸ Settings ▸ Components)\n'
    else
        step "iOS unit tests" xcodebuild test \
            -project BentoTerm.xcodeproj -scheme BentoTermiOS -configuration Debug \
            -destination "id=$SIM_UDID" CODE_SIGNING_ALLOWED=NO -quiet
    fi
else
    printf '\n(skipping Xcode app builds — pass --apps to include them)\n'
fi

if [ "$fail" -eq 0 ]; then
    printf '\n\033[32mall checks passed\033[0m\n'
else
    printf '\n\033[31msome checks failed\033[0m\n'
fi
exit "$fail"
