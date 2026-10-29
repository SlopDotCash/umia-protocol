#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

GENERATED=(
    abi/src/generated.ts
    abi/src/generated-addresses.ts
    abi/addresses.json
    abi/json
)

# Run codegen directly rather than through `bun --filter`, which exits 0 even
# when the inner script dies. A crashed wagmi/forge run would leave the tree
# unchanged and make the diff below pass for the wrong reason.
(cd abi && bun run codegen)

if ! git diff --quiet -- "${GENERATED[@]}"; then
    echo "ABI codegen is out of date!"
    echo ""
    git diff --stat -- "${GENERATED[@]}"
    echo ""
    echo "Run 'cd $PWD/abi && bun run codegen' and commit the result."
    exit 1
fi

echo "ABI codegen is up to date."
