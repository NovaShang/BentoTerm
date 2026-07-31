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

if [ "${1:-}" = "--apps" ]; then
    step "macOS app builds" xcodebuild build \
        -project BentoTerm.xcodeproj -scheme BentoTermMac -configuration Debug \
        -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -quiet
    step "iOS app builds" xcodebuild build \
        -project BentoTerm.xcodeproj -scheme BentoTermiOS -configuration Debug \
        -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO -quiet
else
    printf '\n(skipping Xcode app builds — pass --apps to include them)\n'
fi

if [ "$fail" -eq 0 ]; then
    printf '\n\033[32mall checks passed\033[0m\n'
else
    printf '\n\033[31msome checks failed\033[0m\n'
fi
exit "$fail"
