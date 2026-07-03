#!/bin/bash
# Restore tracked resource.json files when only volatile Designer metadata changed.

set -euo pipefail

APPLY=0
if [ "${1:-}" = "--apply" ]; then
    APPLY=1
elif [ "${1:-}" = "--dry-run" ] || [ "${1:-}" = "" ]; then
    APPLY=0
else
    echo "usage: $0 [--dry-run|--apply]" >&2
    exit 2
fi

REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"

NORMALIZER="$REPO_ROOT/scripts/git-diff/normalize-ignition-resource-json.py"

volatile_only_count=0
skipped_count=0

while IFS= read -r -d '' path; do
    if ! git diff --cached --quiet -- "$path"; then
        echo "skip staged: $path"
        skipped_count=$((skipped_count + 1))
        continue
    fi

    if cmp -s \
        <("$NORMALIZER" "$path") \
        <(git show "HEAD:$path" | "$NORMALIZER" -); then
        volatile_only_count=$((volatile_only_count + 1))
        if [ "$APPLY" -eq 1 ]; then
            git restore --worktree -- "$path"
            echo "restored: $path"
        else
            echo "volatile-only: $path"
        fi
    fi
done < <(git diff --name-only --diff-filter=M -z -- \
    'services/config/resources/**/resource.json' \
    'projects/**/resource.json')

if [ "$volatile_only_count" -eq 0 ]; then
    echo "No volatile-only resource.json changes found."
elif [ "$APPLY" -eq 0 ]; then
    echo "Run $0 --apply to restore these files."
fi

if [ "$skipped_count" -gt 0 ]; then
    echo "Skipped $skipped_count staged file(s)."
fi
