#!/usr/bin/env bash
# tools/release-tag.sh <version>: sign and push the release tag of a promoted version.
#
# The maintainer runs it from any worktree of the repository, on the host that
# holds the signing key. It fetches main from origin and requires that main's
# commit states <version> in bindings/c-abi-resolve.json, carries the version's
# CHANGELOG.md section, has no v<version> tag on origin, and passed full
# validation (tools/check/require-main-check.py, through gh). Then it signs
# v<version> at that commit, verifies the signature, and pushes the tag. The
# push is the one effect, and the release workflow takes over from there.
# It writes nothing to the worktree. A refusal exits 1 before the push, and a
# tag it signed stays local for the retry.
# tools/check/release-tag-test.sh exercises it against a local origin and a
# stub gh under infrastructure-check.
set -euo pipefail

die() {
	echo "release-tag: $*" >&2
	exit 1
}

[[ $# -eq 1 ]] || die "usage: tools/release-tag.sh <version>"
version=$1
[[ ${version} =~ ^0\.[0-9]+\.[0-9]+$ ]] || die "${version} is not a prerelease version such as 0.1.2"
tag=v${version}

tools_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
git rev-parse --show-toplevel >/dev/null 2>&1 || die "not inside a Git worktree"

git fetch -q origin +refs/heads/main:refs/remotes/origin/main || die "cannot fetch main from origin"
commit=$(git rev-parse refs/remotes/origin/main)

if [[ -n $(git ls-remote --tags origin "refs/tags/${tag}") ]]; then
	die "${tag} is already on origin; a published version is never replaced, so a defect takes the next patch version"
fi
stated=$(git show "${commit}:bindings/c-abi-resolve.json" |
	python3 -c 'import json, sys; print(json.load(sys.stdin)["abi_version"])') || die "cannot read the version main states"
[[ ${stated} == "${version}" ]] ||
	die "main (${commit}) states ${stated}, not ${version}; land \`zig build set-version -Dversion=${version}\` on dev and let promotion move main first"
git show "${commit}:CHANGELOG.md" | grep -q "^## \[${version}\]" || die "CHANGELOG.md on main has no [${version}] section"

repository=$(gh repo view --json nameWithOwner -q .nameWithOwner) || die "gh cannot name the repository; run gh auth login first"
run_url=$(GITHUB_REPOSITORY="${repository}" python3 "${tools_root}/tools/check/require-main-check.py" "${commit}") ||
	die "main (${commit}) has no successful full validation, so the release workflow would refuse the tag"

if existing=$(git rev-parse -q --verify "refs/tags/${tag}^{commit}"); then
	[[ ${existing} == "${commit}" ]] || die "local tag ${tag} points at ${existing}, not main's ${commit}; inspect and delete it, then retry"
else
	git tag -s "${tag}" "${commit}" -m "glowcap ${version}" ||
		die "signing failed; make the signing key reachable (forward the agent that holds it) and retry"
fi
git verify-tag "${tag}" 2>/dev/null || die "the signature on ${tag} does not verify; name the key in gpg.ssh.allowedSignersFile and retry"
git push -q origin "refs/tags/${tag}" || die "pushing ${tag} failed; the signed tag is kept locally, retry"
echo "release-tag: pushed ${tag} at ${commit}, validated by ${run_url}"
echo "release-tag: the release workflow publishes it: https://github.com/${repository}/actions/workflows/release.yml"
