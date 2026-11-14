#!/usr/bin/env bash
#
# Fail if the published address book has drifted from contracts.json.
#
# `bun run codegen` regenerates it, but that path needs a full forge build and
# only runs on contract changes; a PR that edits contracts.json alone would
# otherwise ship a stale addresses.json. This check needs neither forge nor
# solc, so it runs in App CI on every contracts.json change.
set -euo pipefail

cd "$(dirname "$0")"

if [ -z "${CONTRACTS_JSON:-}" ] && [ ! -f ../contracts.json ]; then
    echo "skipped: no contracts.json next to this checkout (set CONTRACTS_JSON to an absolute path to check one)"
    exit 0
fi

GENERATED=(abi/addresses.json abi/src/generated-addresses.ts)

# Run the generator directly rather than through `bun --filter`, which exits 0
# even when the inner script dies; that would leave the tree unchanged and make
# the diff below pass for the wrong reason.
(cd abi && bun run src/gen-addresses.ts)

# Include newly generated files and staged changes: a worktree-only diff can
# report success even when the generated address book is absent from HEAD.
generated_status=$(git status --porcelain --untracked-files=all -- "${GENERATED[@]}")
if [ -n "$generated_status" ]; then
    echo "Published address book is out of date!"
    echo ""
    printf '%s\n' "$generated_status"
    echo ""
    echo "Run 'cd $PWD/abi && bun run addresses' and commit the result."
    exit 1
fi

echo "Published address book is up to date."
