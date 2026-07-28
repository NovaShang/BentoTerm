#!/usr/bin/env bash
# Guards the "use the real name" rule from docs/onboarding-design.md's successor
# plan: user-facing strings must name the actual tmux object, not a private
# metaphor. A private vocabulary only breaks when it leaks — the user meets
# `session`, `window`, `pane` in `tmux ls`, in tmux(1), and in every other
# terminal, so Bento says the same words.
#
# Checks string literals only; comments (which legitimately discuss the old
# names and iTerm2's opposite convention) are skipped. Run from the repo root.
set -uo pipefail

cd "$(dirname "$0")/.."

SOURCES=(Bento/Sources BentoMenubar/Sources bento-terminal-core/Sources)

# term<TAB>why
BANNED=$(cat <<'EOF'
[Ww]orkspace	tmux calls it a session; say "session"
AI worker	they are CLI agents; say "agent"
remote control	every device is a tmux client; say "client"
Split Vertical	ambiguous (tmux -v stacks, iTerm2 "vertical" is side-by-side); say "Split Right (-h)" / "Split Down (-v)"
Split Horizontal	ambiguous (tmux -h is side-by-side, iTerm2 "horizontal" stacks); say "Split Right (-h)" / "Split Down (-v)"
EOF
)

fail=0
while IFS=$'\t' read -r term why; do
    [ -z "$term" ] && continue
    # String literals only, skipping comment lines and the telemetry wire value
    # (an event name is a stored key, not user-facing copy — renaming it would
    # silently split the metric series).
    hits=$(grep -rn --include='*.swift' -E "\"[^\"]*(${term})[^\"]*\"" "${SOURCES[@]}" 2>/dev/null \
        | grep -v '/Tests\?/' \
        | grep -vE '^[^:]+:[0-9]+: *///?' \
        | grep -v 'workspace_created' \
        || true)
    if [ -n "$hits" ]; then
        echo "✘ banned in user-facing strings: /${term}/ — ${why}"
        echo "$hits" | sed 's/^/    /'
        fail=1
    fi
done <<< "$BANNED"

if [ "$fail" -eq 0 ]; then
    echo "✓ terminology: user-facing strings use tmux's own names"
fi
exit "$fail"
