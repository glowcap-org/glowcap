#!/usr/bin/env bash
set -Eeuo pipefail
trap 'printf "worktree-integration-test: line %s failed: %s\n" "$LINENO" "$BASH_COMMAND" >&2' ERR

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
integrate=${root}/.agents/skills/work/bin/glowcap-integrate
real_git=$(command -v git)
scratch=$(mktemp -d)
trap 'rm -rf "${scratch}"' EXIT

repo=${scratch}/repo
tree=${scratch}/tree1
git init -q -b main "${repo}"
git -C "${repo}" config user.name "glowcap test"
git -C "${repo}" config user.email "test@glowcap.invalid"
# Dev takes only commits the integrator signs, so the fixture owns a signing
# key and the allowed-signers file that verifies it.
ssh-keygen -q -t ed25519 -N '' -C "test@glowcap.invalid" -f "${scratch}/signing-key"
printf 'test@glowcap.invalid namespaces="git" %s\n' "$(cut -d' ' -f1,2 "${scratch}/signing-key.pub")" >"${scratch}/allowed_signers"
git -C "${repo}" config commit.gpgsign false
git -C "${repo}" config gpg.format ssh
git -C "${repo}" config user.signingkey "${scratch}/signing-key"
git -C "${repo}" config gpg.ssh.allowedSignersFile "${scratch}/allowed_signers"
printf 'base\n' >"${repo}/base"
git -C "${repo}" add base
git -C "${repo}" commit -qm base
main_tip=$(git -C "${repo}" rev-parse HEAD)
git -C "${repo}" branch dev

# The worktree designator and branch differ. A flow that derives
# one from the other updates or rebases the wrong ref here.
git -C "${repo}" worktree add -qb feature-work "${tree}" main
printf 'agent\n' >"${tree}/agent"
git -C "${tree}" add agent
git -C "${tree}" commit -qm agent
# The record ci/gates.sh attached to this commit must reach dev through the
# rebase and the signed commit that lands.
git -C "${tree}" notes --ref=refs/notes/evidence add -m '{"outcome":"passed"}' feature-work

# Another worktree has integrated one commit into dev, and a second commit will
# land in the compare-and-swap window below.
git -C "${repo}" switch -qc rival main
printf 'rival one\n' >"${repo}/rival-one"
git -C "${repo}" add rival-one
git -C "${repo}" commit -qm rival-one
first_rival=$(git -C "${repo}" rev-parse HEAD)
git -C "${repo}" update-ref refs/heads/dev "${first_rival}" "${main_tip}"
printf 'rival two\n' >"${repo}/rival-two"
git -C "${repo}" add rival-two
git -C "${repo}" commit -qm rival-two
race_tip=$(git -C "${repo}" rev-parse HEAD)
git -C "${repo}" switch -q main

# Main advances independently of dev. Sync must absorb both shared lines without
# moving either one; publishing must preserve both changes in a linearized,
# fast-forwarded dev result.
printf 'main advance\n' >"${repo}/main-advance"
git -C "${repo}" add main-advance
git -C "${repo}" commit -qm main-advance
advanced_main=$(git -C "${repo}" rev-parse HEAD)

# Sync absorbs the current integration line into this worktree without moving
# the shared ref. This is the clean-start operation: an agent can reach the
# fixed tree before its own commit is ready to publish.
before_sync_dev=$(git -C "${tree}" rev-parse dev)
sync_log=${scratch}/sync.log
if ! (
	cd "${tree}"
	"${integrate}" --sync
) >"${sync_log}" 2>&1; then
	cat "${sync_log}" >&2
	exit 1
fi
[[ $(git -C "${tree}" rev-parse dev) == "${before_sync_dev}" ]]
[[ $(git -C "${tree}" rev-parse main) == "${advanced_main}" ]]
git -C "${tree}" merge-base --is-ancestor "${first_rival}" feature-work
[[ $(git -C "${tree}" show feature-work:main-advance) == "main advance" ]]

# Wrap only the integration invocation. Immediately before its first dev CAS,
# advance dev to the rival's second commit. An unconditional update-ref would
# erase it; the expected-old form must fail, retry, and absorb it.
mkdir "${scratch}/bin"
cat >"${scratch}/bin/git" <<'WRAPPER'
#!/usr/bin/env bash
set -euo pipefail
if [[ ${1:-} == update-ref && ${2:-} == refs/heads/dev && ! -e ${GLOWCAP_TEST_RACE_MARKER} ]]; then
	: >"${GLOWCAP_TEST_RACE_MARKER}"
	"${GLOWCAP_TEST_REAL_GIT}" update-ref refs/heads/dev "${GLOWCAP_TEST_RACE_TIP}" "${4}"
fi
exec "${GLOWCAP_TEST_REAL_GIT}" "$@"
WRAPPER
chmod +x "${scratch}/bin/git"

integrate_log=${scratch}/integrate.log
if ! (
	cd "${tree}"
	PATH="${scratch}/bin:${PATH}" \
		GLOWCAP_TEST_REAL_GIT="${real_git}" \
		GLOWCAP_TEST_RACE_TIP="${race_tip}" \
		GLOWCAP_TEST_RACE_MARKER="${scratch}/raced" \
		"${integrate}"
) >"${integrate_log}" 2>&1; then
	cat "${integrate_log}" >&2
	exit 1
fi

feature_tip=$(git -C "${tree}" rev-parse feature-work)
dev_tip=$(git -C "${tree}" rev-parse dev)
[[ ${feature_tip} == "${dev_tip}" ]]
git -C "${tree}" verify-commit dev 2>/dev/null
[[ $(git -C "${tree}" notes --ref=refs/notes/evidence show dev) == '{"outcome":"passed"}' ]]
[[ $(git -C "${tree}" branch --show-current) == feature-work ]]
[[ $(git -C "${tree}" rev-parse main) == "${advanced_main}" ]]
git -C "${tree}" merge-base --is-ancestor "${race_tip}" dev
[[ $(git -C "${tree}" show dev:main-advance) == "main advance" ]]

# Advancing a checked-out ref leaves its index and files behind. Refuse both
# primary and linked checkouts, preserving even staged and unstaged user work.
for checkout in "${repo}" "${scratch}/dev-checkout"; do
	if [[ ${checkout} == "${repo}" ]]; then
		git -C "${repo}" switch -q dev
	else
		git -C "${repo}" worktree add -q "${checkout}" dev
	fi
	for state in clean dirty; do
		if [[ ${state} == dirty ]]; then
			printf 'staged\n' >"${checkout}/base"
			git -C "${checkout}" add base
			printf 'unstaged\n' >>"${checkout}/base"
		fi
		before_index=$(git -C "${checkout}" write-tree)
		before_file=$(git -C "${checkout}" hash-object base)
		if (cd "${tree}" && "${integrate}") >"${scratch}/checked-out.log" 2>&1; then
			echo "worktree-integration-test: published while dev was checked out" >&2
			exit 1
		fi
		grep -Fq 'dev is checked out' "${scratch}/checked-out.log"
		[[ $(git -C "${checkout}" write-tree) == "${before_index}" ]]
		[[ $(git -C "${checkout}" hash-object base) == "${before_file}" ]]
		[[ $(git -C "${tree}" rev-parse dev) == "${dev_tip}" ]]
		[[ $(git -C "${tree}" rev-parse HEAD) == "${feature_tip}" ]]
		(cd "${tree}" && "${integrate}" --sync >/dev/null)
	done
	# Only this disposable fixture's intentional dirty state is discarded.
	git -C "${checkout}" reset --hard -q HEAD
	if [[ ${checkout} == "${repo}" ]]; then
		git -C "${repo}" switch -q main
	else
		git -C "${repo}" worktree remove "${checkout}"
	fi
done

# Small commits stay on the worktree, and dev takes them as one squash. Without
# a subject the command refuses and moves nothing. With one, dev gains exactly
# one commit holding the branch's tree, and the branch moves onto it.
for name in small-one small-two; do
	printf '%s\n' "${name}" >"${tree}/${name}"
	git -C "${tree}" add "${name}"
	git -C "${tree}" commit -qm "${name}"
done
small_tip=$(git -C "${tree}" rev-parse feature-work)
before_dev=$(git -C "${tree}" rev-parse dev)
if (cd "${tree}" && GIT_COMMITTER_DATE='2001-01-01T00:00:00Z' "${integrate}") >"${scratch}/unnamed.log" 2>&1; then
	echo "worktree-integration-test: published several commits without a subject" >&2
	exit 1
fi
grep -Fq 'name the squashed change with -m' "${scratch}/unnamed.log"
[[ $(git -C "${tree}" rev-parse dev) == "${before_dev}" ]]
[[ $(git -C "${tree}" rev-parse feature-work) == "${small_tip}" ]]
(cd "${tree}" && "${integrate}" -m "Add the small files" >/dev/null)
squash=$(git -C "${tree}" rev-parse dev)
[[ $(git -C "${tree}" rev-parse "${squash}^") == "${before_dev}" ]]
[[ $(git -C "${tree}" rev-parse "${squash}^{tree}") == $(git -C "${tree}" rev-parse "${small_tip}^{tree}") ]]
[[ $(git -C "${tree}" rev-parse feature-work) == "${squash}" ]]
[[ $(git -C "${tree}" log -1 --format=%B "${squash}") == $'Add the small files\n\n- small-one\n- small-two' ]]
git -C "${tree}" verify-commit "${squash}" 2>/dev/null
[[ -z $(git -C "${tree}" status --porcelain) ]]
feature_tip=${squash}

# A single commit publishes as written, so a subject has nothing to name. Its
# author stays the author, and the integrator is the committer who signed.
printf 'single\n' >"${tree}/single"
git -C "${tree}" add single
git -C "${tree}" -c user.name="draft author" -c user.email=draft@glowcap.invalid commit -qm single
single_tip=$(git -C "${tree}" rev-parse HEAD)
if (cd "${tree}" && GIT_COMMITTER_DATE='2001-01-01T00:00:00Z' "${integrate}" -m "Rename") >/dev/null 2>&1; then
	echo "worktree-integration-test: renamed a single commit" >&2
	exit 1
fi
[[ $(git -C "${tree}" rev-parse HEAD) == "${single_tip}" ]]
[[ -z $(git -C "${tree}" status --porcelain) ]]
(cd "${tree}" && "${integrate}" >/dev/null)
feature_tip=$(git -C "${tree}" rev-parse feature-work)
[[ $(git -C "${tree}" rev-parse dev) == "${feature_tip}" ]]
[[ $(git -C "${tree}" log -1 --format=%B dev) == single ]]
[[ $(git -C "${tree}" log -1 --format='%an <%ae> %cn' dev) == 'draft author <draft@glowcap.invalid> glowcap test' ]]
git -C "${tree}" verify-commit dev 2>/dev/null

# Without a reachable signing key nothing lands: dev and the branch's own
# commit stay where they were, and the refusal names the remedy.
printf 'unsigned\n' >"${tree}/unsigned"
git -C "${tree}" add unsigned
git -C "${tree}" commit -qm unsigned
unsigned_tip=$(git -C "${tree}" rev-parse feature-work)
unsigned_tree=$(git -C "${tree}" write-tree)
before_dev=$(git -C "${tree}" rev-parse dev)
git -C "${repo}" config user.signingkey "${scratch}/no-such-key"
# A rebase must change commit identities even on a fast machine. Refusing a
# signature after rebasing must restore the input, not depend on clock timing.
if (cd "${tree}" && GIT_COMMITTER_DATE='2001-01-01T00:00:00Z' "${integrate}") >"${scratch}/unsigned.log" 2>&1; then
	echo "worktree-integration-test: published without a signature" >&2
	exit 1
fi
grep -Fq 'signed at integration' "${scratch}/unsigned.log"
[[ $(git -C "${tree}" rev-parse dev) == "${before_dev}" ]]
[[ $(git -C "${tree}" rev-parse feature-work) == "${unsigned_tip}" ]]
[[ $(git -C "${tree}" write-tree) == "${unsigned_tree}" ]]
[[ -z $(git -C "${tree}" status --porcelain) ]]
git -C "${repo}" config user.signingkey "${scratch}/signing-key"
# Signing can succeed while verification refuses the key. This also leaves
# the original clean input and shared branch intact.
git -C "${repo}" config gpg.ssh.allowedSignersFile "${scratch}/no-trusted-signers"
if (cd "${tree}" && GIT_COMMITTER_DATE='2001-01-01T00:00:00Z' "${integrate}") >"${scratch}/unverified.log" 2>&1; then
	echo "worktree-integration-test: published an unverified signature" >&2
	exit 1
fi
grep -Fq 'signature on the integrated commit does not verify' "${scratch}/unverified.log"
[[ $(git -C "${tree}" rev-parse dev) == "${before_dev}" ]]
[[ $(git -C "${tree}" rev-parse feature-work) == "${unsigned_tip}" ]]
[[ $(git -C "${tree}" write-tree) == "${unsigned_tree}" ]]
[[ -z $(git -C "${tree}" status --porcelain) ]]
git -C "${repo}" config gpg.ssh.allowedSignersFile "${scratch}/allowed_signers"
(cd "${tree}" && "${integrate}" >/dev/null)
feature_tip=$(git -C "${tree}" rev-parse feature-work)
[[ $(git -C "${tree}" rev-parse dev) == "${feature_tip}" ]]

# Two worktrees took the same decision record number from the dev each saw.
# The rebase merges both files, and publish refuses the duplicate on the
# rebased tree without moving either ref. Sync keeps absorbing, because the
# worktree is where the renumber happens.
git -C "${repo}" switch -q dev
mkdir -p "${repo}/docs/decisions/adr"
printf 'rival\n' >"${repo}/docs/decisions/adr/ADR-0003-rival.md"
git -C "${repo}" add docs/decisions/adr/ADR-0003-rival.md
git -C "${repo}" commit -qm rival-adr
git -C "${repo}" switch -q main
mkdir -p "${tree}/docs/decisions/adr"
printf 'mine\n' >"${tree}/docs/decisions/adr/ADR-0003-mine.md"
git -C "${tree}" add docs/decisions/adr/ADR-0003-mine.md
git -C "${tree}" commit -qm mine-adr
before_dev=$(git -C "${tree}" rev-parse dev)
duplicate_tip=$(git -C "${tree}" rev-parse HEAD)
if (cd "${tree}" && GIT_COMMITTER_DATE='2001-01-01T00:00:00Z' "${integrate}") >"${scratch}/duplicate.log" 2>&1; then
	echo "worktree-integration-test: published a duplicate decision record id" >&2
	exit 1
fi
grep -Fq 'decision record id taken twice on the rebased tree: ADR-0003' "${scratch}/duplicate.log"
[[ $(git -C "${tree}" rev-parse dev) == "${before_dev}" ]]
[[ $(git -C "${tree}" rev-parse HEAD) == "${duplicate_tip}" ]]
[[ -z $(git -C "${tree}" status --porcelain) ]]
(cd "${tree}" && "${integrate}" --sync >/dev/null)
git -C "${tree}" mv docs/decisions/adr/ADR-0003-mine.md docs/decisions/adr/ADR-0004-mine.md
git -C "${tree}" commit -qm renumber-adr
(cd "${tree}" && "${integrate}" -m "Add my decision record" >/dev/null)
[[ $(git -C "${tree}" ls-tree --name-only dev docs/decisions/adr/ | sort | tr '\n' ' ') == 'docs/decisions/adr/ADR-0003-rival.md docs/decisions/adr/ADR-0004-mine.md ' ]]
feature_tip=$(git -C "${tree}" rev-parse feature-work)

# Dirty work is not integrated or hidden. The shared ref and current branch stay
# exactly where they were when the command refuses.
printf 'unfinished\n' >"${tree}/unfinished"
before_dev=$(git -C "${tree}" rev-parse dev)
if (cd "${tree}" && "${integrate}" >/dev/null 2>&1); then
	echo "worktree-integration-test: dirty worktree was integrated" >&2
	exit 1
fi
if (cd "${tree}" && "${integrate}" --sync >/dev/null 2>&1); then
	echo "worktree-integration-test: dirty worktree was synced" >&2
	exit 1
fi
[[ $(git -C "${tree}" rev-parse dev) == "${before_dev}" ]]
[[ $(git -C "${tree}" rev-parse feature-work) == "${feature_tip}" ]]

echo "worktree-integration-test: ok"
