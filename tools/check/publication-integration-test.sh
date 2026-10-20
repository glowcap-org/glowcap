#!/usr/bin/env bash
# Exercise the maintainer's publication and fetch procedure with local remotes.
# No GitHub credentials, network service, or working repository refs are used.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
integrate=${root}/.agents/skills/work/bin/glowcap-integrate
scratch=$(mktemp -d)
trap 'rm -rf "${scratch}"' EXIT
repo=${scratch}/local
forge=${scratch}/forge
origin=${scratch}/origin.git

git init -qb maintenance "${repo}"
git -C "${repo}" config user.name "glowcap test"
git -C "${repo}" config user.email "test@glowcap.invalid"
git -C "${repo}" config commit.gpgsign false
# The integrator signs what lands on dev, so the maintainer's fixture owns a
# key and the allowed-signers file that verifies it.
ssh-keygen -q -t ed25519 -N '' -C "test@glowcap.invalid" -f "${scratch}/signing-key"
printf 'test@glowcap.invalid namespaces="git" %s\n' "$(cut -d' ' -f1,2 "${scratch}/signing-key.pub")" >"${scratch}/allowed_signers"
git -C "${repo}" config gpg.format ssh
git -C "${repo}" config user.signingkey "${scratch}/signing-key"
git -C "${repo}" config gpg.ssh.allowedSignersFile "${scratch}/allowed_signers"
printf 'base\n' >"${repo}/base"
git -C "${repo}" add base
git -C "${repo}" commit -qm base
git -C "${repo}" branch main
git -C "${repo}" branch dev
git init -q --bare "${origin}"
# The hosted rulesets refuse anything but a fast-forward; the bare origin
# stands in for them.
git --git-dir="${origin}" config receive.denyNonFastForwards true
git -C "${repo}" remote add origin "${origin}"
git -C "${repo}" push -q origin main dev

# An outside contribution arrives as a branch. It lands on dev through the
# integrator from a review worktree: one signed commit that keeps its author.
git clone -q --branch dev "${origin}" "${forge}"
git -C "${forge}" config user.name "outside contributor"
git -C "${forge}" config user.email "contributor@glowcap.invalid"
git -C "${forge}" config commit.gpgsign false
git -C "${forge}" switch -qc incoming
printf 'contribution\n' >"${forge}/contribution"
git -C "${forge}" add contribution
git -C "${forge}" commit -qm contribution
git -C "${forge}" push -q origin incoming
git -C "${repo}" fetch -q origin refs/heads/incoming:refs/heads/review/incoming
git -C "${repo}" worktree add -q "${scratch}/review" review/incoming
(cd "${scratch}/review" && "${integrate}" >/dev/null)
contribution=$(git -C "${repo}" rev-parse refs/heads/dev)
[[ $(git -C "${repo}" show -s --format='%ae %ce' "${contribution}") == 'contributor@glowcap.invalid test@glowcap.invalid' ]]
git -C "${repo}" verify-commit "${contribution}" 2>/dev/null
git -C "${repo}" push -q origin dev

# main is a fast-forward of dev: the candidate publishes under its own hash
# while dev moves on.
candidate=${contribution}
git -C "${repo}" switch -qc work dev
printf 'next\n' >"${repo}/next"
git -C "${repo}" add next
git -C "${repo}" commit -qm next
next=$(git -C "${repo}" rev-parse HEAD)
git -C "${repo}" update-ref refs/heads/dev "${next}" "${candidate}"
git -C "${repo}" switch -q maintenance
git -C "${repo}" push -q origin dev
git -C "${repo}" merge-base --is-ancestor "${candidate}" refs/heads/dev
git -C "${repo}" push -q origin "${candidate}:refs/heads/main"
[[ $(git --git-dir="${origin}" rev-parse refs/heads/main) == "${candidate}" ]]
git -C "${repo}" fetch -q --atomic origin refs/heads/main:refs/heads/main refs/heads/dev:refs/heads/dev
[[ $(git -C "${repo}" rev-parse main) == "${candidate}" ]]
[[ $(git -C "${repo}" rev-parse dev) == "${next}" ]]

# A commit that does not descend from main is refused, so main never takes a
# merge, a squash, or a rewrite of what the checks ran on.
git -C "${forge}" fetch -q origin
git -C "${forge}" switch -qc stray "${candidate}^"
printf 'stray\n' >"${forge}/stray"
git -C "${forge}" add stray
git -C "${forge}" commit -qm stray
if git -C "${forge}" push -q origin stray:main >"${scratch}/stray-refusal.log" 2>&1; then
    echo "publication-integration-test: main took a commit that is not a fast-forward" >&2
    exit 1
fi
[[ $(git --git-dir="${origin}" rev-parse refs/heads/main) == "${candidate}" ]]

# Even an up-to-date fetch must refuse a checked-out integration target.
git -C "${repo}" switch -q dev
before_index=$(git -C "${repo}" write-tree)
if git -C "${repo}" fetch -q --atomic origin refs/heads/main:refs/heads/main refs/heads/dev:refs/heads/dev >"${scratch}/checked-out.log" 2>&1; then
    echo "publication-integration-test: fetched into a checked-out branch" >&2
    exit 1
fi
[[ $(git -C "${repo}" write-tree) == "${before_index}" ]]
[[ $(git -C "${repo}" rev-parse dev) == "${next}" ]]
git -C "${repo}" switch -q maintenance

# A local integration races a hosted merge. Refuse divergent dev and leave main
# unchanged too, although that ref could fast-forward independently.
git -C "${forge}" switch -q dev
git -C "${forge}" merge --ff-only -q origin/dev
printf 'hosted\n' >"${forge}/hosted"
git -C "${forge}" add hosted
git -C "${forge}" commit -qm hosted
git -C "${forge}" push -q origin dev
git -C "${forge}" switch -q main
printf 'published\n' >"${forge}/published"
git -C "${forge}" add published
git -C "${forge}" commit -qm published
git -C "${forge}" push -q origin main
git -C "${repo}" switch -q work
printf 'local\n' >"${repo}/local"
git -C "${repo}" add local
git -C "${repo}" commit -qm local
before_dev=$(git -C "${repo}" rev-parse HEAD)
git -C "${repo}" update-ref refs/heads/dev "${before_dev}" "${next}"
before_main=$(git -C "${repo}" rev-parse main)
hosted_dev=$(git --git-dir="${origin}" rev-parse dev)
if git -C "${repo}" push -q origin refs/heads/dev:refs/heads/dev >"${scratch}/push-refusal.log" 2>&1; then
    echo "publication-integration-test: pushed divergent dev" >&2
    exit 1
fi
[[ $(git --git-dir="${origin}" rev-parse dev) == "${hosted_dev}" ]]
[[ $(git -C "${repo}" rev-parse dev) == "${before_dev}" ]]
if git -C "${repo}" fetch -q --atomic origin refs/heads/main:refs/heads/main refs/heads/dev:refs/heads/dev >"${scratch}/refusal.log" 2>&1; then
    echo "publication-integration-test: fetched divergent dev" >&2
    exit 1
fi
[[ $(git -C "${repo}" rev-parse dev) == "${before_dev}" ]]
[[ $(git -C "${repo}" rev-parse main) == "${before_main}" ]]

echo "publication-integration-test: ok"
