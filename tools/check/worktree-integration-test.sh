#!/usr/bin/env bash
set -euo pipefail

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
git -C "${repo}" config commit.gpgsign false
printf 'base\n' >"${repo}/base"
git -C "${repo}" add base
git -C "${repo}" commit -qm base
main_tip=$(git -C "${repo}" rev-parse HEAD)
git -C "${repo}" branch dev

# The worktree designator and branch deliberately differ. A flow that derives
# one from the other updates or rebases the wrong ref here.
git -C "${repo}" worktree add -qb feature-work "${tree}" main
printf 'agent\n' >"${tree}/agent"
git -C "${tree}" add agent
git -C "${tree}" commit -qm agent

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
(
	cd "${tree}"
	"${integrate}" --sync
)
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

(
	cd "${tree}"
	PATH="${scratch}/bin:${PATH}" \
		GLOWCAP_TEST_REAL_GIT="${real_git}" \
		GLOWCAP_TEST_RACE_TIP="${race_tip}" \
		GLOWCAP_TEST_RACE_MARKER="${scratch}/raced" \
		"${integrate}"
)

feature_tip=$(git -C "${tree}" rev-parse feature-work)
dev_tip=$(git -C "${tree}" rev-parse dev)
[[ ${feature_tip} == "${dev_tip}" ]]
[[ $(git -C "${tree}" branch --show-current) == feature-work ]]
[[ $(git -C "${tree}" rev-parse main) == "${advanced_main}" ]]
git -C "${tree}" merge-base --is-ancestor "${race_tip}" dev
[[ $(git -C "${tree}" show dev:main-advance) == "main advance" ]]

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
if (cd "${tree}" && "${integrate}") >"${scratch}/unnamed.log" 2>&1; then
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
[[ -z $(git -C "${tree}" status --porcelain) ]]
feature_tip=${squash}

# A single commit publishes as written, so a subject has nothing to name.
printf 'single\n' >"${tree}/single"
git -C "${tree}" add single
git -C "${tree}" commit -qm single
if (cd "${tree}" && "${integrate}" -m "Rename") >/dev/null 2>&1; then
	echo "worktree-integration-test: renamed a single commit" >&2
	exit 1
fi
(cd "${tree}" && "${integrate}" >/dev/null)
feature_tip=$(git -C "${tree}" rev-parse feature-work)
[[ $(git -C "${tree}" rev-parse dev) == "${feature_tip}" ]]
[[ $(git -C "${tree}" log -1 --format=%s dev) == single ]]

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
