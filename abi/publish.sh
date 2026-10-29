#!/usr/bin/env bash
#
# Publish the Umia ABIs to npm.
#
# Naming: internally this package is @umia/abi, the workspace name the
# rest of the monorepo (shared/chain et al.) imports. It can't be published under
# that scope because the @umia org is unavailable on npm, so it ships UNSCOPED as
# `umia-abi`. The name and the entrypoints (src/*.ts in-repo, dist/*.js when
# published) are swapped only for the duration of `bun publish` and reverted
# afterwards (via a trap, so it reverts even if publish fails). The committed
# package.json therefore always reads @umia/abi and points at src/.
#
# Usage: bump `version` in package.json and commit first, then `./publish.sh`.
# Extra args are forwarded to `bun publish` (e.g. `./publish.sh --dry-run`).
set -euo pipefail

cd "$(dirname "$0")" # abi/

# Clean-tree check via porcelain (catches staged + unstaged + untracked; plain
# `git diff --quiet` misses staged changes and new files).
require_clean() {
	[ -z "$(git status --porcelain -- .)" ] || {
		echo "$1"
		exit 1
	}
}

require_clean "✖ uncommitted changes in abi/: commit first"

# Codegen forces a clean via-IR forge build, so reuse dist/ when a previous run
# already built this exact commit (e.g. retrying after an expired OTP).
STAMP=dist/.built-from
HEAD_SHA="$(git rev-parse HEAD)"
if [ -z "$(git status --porcelain -- ..)" ] && [ "$(cat "$STAMP" 2>/dev/null)" = "$HEAD_SHA" ]; then
	echo "→ dist/ already built from ${HEAD_SHA:0:9}, skipping codegen + build"
else
	bun run codegen
	require_clean "✖ ABIs were stale: run 'bun run codegen', commit, then retry"

	bun run typecheck
	bun run build
	echo "$HEAD_SHA" >"$STAMP"
fi

# Ask for the OTP only now, so a slow build can't expire it.
args=("$@")
if [[ " $* " != *" --otp"* ]] && [ -t 0 ]; then
	read -rsp "npm OTP (blank for browser auth): " otp
	echo
	if [ -n "$otp" ]; then args+=("--otp=$otp"); fi
fi

# Rewrite the manifest for npm (name + dist entrypoints), publish, then always
# restore the committed one. See publish-manifest.ts for why the swap exists.
trap 'git checkout -- package.json' EXIT
bun run publish-manifest.ts
bun publish ${args[@]+"${args[@]}"}
