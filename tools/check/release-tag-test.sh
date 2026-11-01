#!/usr/bin/env bash
# Exercise tools/release-tag.sh against a local origin and a stub gh: the ordinary
# signed tag push and each refusal, which leaves no tag on origin.
# No GitHub credentials or network are used.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
release=${root}/tools/release-tag.sh
scratch=$(mktemp -d)
trap 'rm -rf "${scratch}"' EXIT
repo=${scratch}/local
origin=${scratch}/origin.git
bin=${scratch}/bin
mkdir -p "${bin}"

# The stub answers the requests the front and require-main-check make.
cat >"${bin}/gh" <<'STUB'
#!/usr/bin/env bash
case "$*" in
	"repo view --json nameWithOwner -q .nameWithOwner") echo test-org/glowcap ;;
	*"/compare/"*) printf '{"status":"identical"}' ;;
	*"check.yml/runs"*) cat "${GLOWCAP_TEST_RUNS}" ;;
	*"/jobs?per_page=100"*) printf '{"jobs":[{"name":"gates","status":"completed","conclusion":"success"},{"name":"macos-runtime","status":"completed","conclusion":"success"}]}' ;;
	*) echo "gh stub: unexpected $*" >&2; exit 1 ;;
esac
STUB
chmod +x "${bin}/gh"
export PATH=${bin}:${PATH}
export GLOWCAP_TEST_RUNS=${scratch}/runs.json

write_runs() { # commit conclusion
	printf '{"workflow_runs":[{"id":7,"run_attempt":1,"head_sha":"%s","event":"push","head_branch":"dev","status":"completed","conclusion":"%s","html_url":"https://example.invalid/runs/7","head_repository":{"full_name":"test-org/glowcap"}}]}' "$1" "$2" >"${GLOWCAP_TEST_RUNS}"
}

git init -qb dev "${repo}"
git -C "${repo}" config user.name "glowcap test"
git -C "${repo}" config user.email "test@glowcap.invalid"
git -C "${repo}" config commit.gpgsign false
ssh-keygen -q -t ed25519 -N '' -C "test@glowcap.invalid" -f "${scratch}/signing-key"
printf 'test@glowcap.invalid namespaces="git" %s\n' "$(cut -d' ' -f1,2 "${scratch}/signing-key.pub")" >"${scratch}/allowed_signers"
git -C "${repo}" config gpg.format ssh
# The host may route ssh signing through an agent that prompts; the fixture signs with the file.
git -C "${repo}" config gpg.ssh.program ssh-keygen
git -C "${repo}" config user.signingkey "${scratch}/signing-key"
git -C "${repo}" config gpg.ssh.allowedSignersFile "${scratch}/allowed_signers"
mkdir -p "${repo}/bindings"
printf '{"abi_version": "0.9.0"}\n' >"${repo}/bindings/c-abi-resolve.json"
printf '# Changelog\n\n## [Unreleased]\n\n## [0.9.0] - 2026-01-01\n\n- First.\n' >"${repo}/CHANGELOG.md"
git -C "${repo}" add -A
git -C "${repo}" commit -qm "release 0.9.0"
git -C "${repo}" branch main
git init -q --bare "${origin}"
git -C "${repo}" remote add origin "${origin}"
git -C "${repo}" push -q origin main dev
commit=$(git -C "${repo}" rev-parse main)

refuse() { # version expected-message [tagged]: a refusal leaves origin's tags as they were
	local output
	if output=$(cd "${repo}" && "${release}" "$1" 2>&1); then
		echo "expected a refusal for $1, got: ${output}" >&2
		exit 1
	fi
	case ${output} in
		*"$2"*) ;;
		*) echo "unexpected refusal for $1: ${output}" >&2; exit 1 ;;
	esac
	[[ $(git --git-dir="${origin}" tag -l "v$1") == "${3:-}" ]]
}

refuse 0.9 "not a prerelease version"
refuse 0.9.1 "states 0.9.0, not 0.9.1"
write_runs "${commit}" failure
refuse 0.9.0 "no successful full validation"
# Nothing is signed before validation passes.
[[ -z $(git -C "${repo}" tag -l v0.9.0) ]]
write_runs "${commit}" success
# A stale local tag at another commit is never moved or pushed.
git -C "${repo}" commit -q --allow-empty -m other
git -C "${repo}" tag v0.9.0 HEAD
refuse 0.9.0 "points at"
git -C "${repo}" tag -d v0.9.0 >/dev/null

output=$(cd "${repo}" && "${release}" 0.9.0)
case ${output} in
	*"pushed v0.9.0 at ${commit}, validated by https://example.invalid/runs/7"*) ;;
	*) echo "unexpected output: ${output}" >&2; exit 1 ;;
esac
[[ $(git --git-dir="${origin}" rev-parse "v0.9.0^{commit}") == "${commit}" ]]
git -C "${repo}" verify-tag v0.9.0 2>/dev/null
refuse 0.9.0 "already on origin" v0.9.0

# A promoted bump without its changelog section is refused before signing.
printf '{"abi_version": "0.9.1"}\n' >"${repo}/bindings/c-abi-resolve.json"
git -C "${repo}" commit -qam "bump without notes"
git -C "${repo}" push -q origin dev:main
write_runs "$(git -C "${repo}" rev-parse dev)" success
refuse 0.9.1 "no [0.9.1] section"
[[ -z $(git -C "${repo}" tag -l v0.9.1) ]]
