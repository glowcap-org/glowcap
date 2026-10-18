#!/usr/bin/env bash
# Exercise the maintainer's publication and fetch procedure with local remotes.
# No GitHub credentials, network service, or working repository refs are used.
set -euo pipefail

scratch=$(mktemp -d)
trap 'rm -rf "${scratch}"' EXIT
repo=${scratch}/local
forge=${scratch}/forge
origin=${scratch}/origin.git

git init -qb maintenance "${repo}"
git -C "${repo}" config user.name "glowcap test"
git -C "${repo}" config user.email "test@glowcap.invalid"
git -C "${repo}" config commit.gpgsign false
printf 'base\n' >"${repo}/base"
git -C "${repo}" add base
git -C "${repo}" commit -qm base
git -C "${repo}" branch main
git -C "${repo}" branch dev
git init -q --bare "${origin}"
git -C "${repo}" remote add origin "${origin}"
git -C "${repo}" push -q origin main dev

# The forge accepts an outside contribution, preserving its author and commit.
git clone -q --branch dev "${origin}" "${forge}"
git -C "${forge}" config user.name "outside contributor"
git -C "${forge}" config user.email "contributor@glowcap.invalid"
git -C "${forge}" config commit.gpgsign false
git -C "${forge}" switch -qc incoming
printf 'contribution\n' >"${forge}/contribution"
git -C "${forge}" add contribution
git -C "${forge}" commit -qm contribution
contribution=$(git -C "${forge}" rev-parse HEAD)
git -C "${forge}" switch -q dev
git -C "${forge}" merge --no-ff -qm 'Accept contribution' incoming
git -C "${forge}" push -q origin dev

# Adopt hosted changes without checking out or rewriting either shared branch.
git -C "${repo}" fetch -q --atomic origin refs/heads/main:refs/heads/main refs/heads/dev:refs/heads/dev
git -C "${repo}" merge-base --is-ancestor "${contribution}" dev
[[ $(git -C "${repo}" show -s --format=%ae "${contribution}") == contributor@glowcap.invalid ]]

# A promotion names a fixed commit even while the local integration line moves.
candidate=$(git -C "${repo}" rev-parse refs/heads/dev)
git -C "${repo}" push -q --force-with-lease=refs/heads/promote/test: origin "${candidate}:refs/heads/promote/test"
# Retrying after an interrupted PR creation leaves the same candidate intact.
git -C "${repo}" push -q --force-with-lease=refs/heads/promote/test: origin "${candidate}:refs/heads/promote/test"
git -C "${repo}" switch -qc work dev
printf 'next\n' >"${repo}/next"
git -C "${repo}" add next
git -C "${repo}" commit -qm next
next=$(git -C "${repo}" rev-parse HEAD)
git -C "${repo}" update-ref refs/heads/dev "${next}" "${candidate}"
git -C "${repo}" switch -q maintenance
git -C "${repo}" push -q origin dev
if git -C "${repo}" push -q --force-with-lease=refs/heads/promote/test: origin "${next}:refs/heads/promote/test" >"${scratch}/snapshot-refusal.log" 2>&1; then
    echo "publication-integration-test: replaced an existing promotion candidate" >&2
    exit 1
fi
[[ $(git --git-dir="${origin}" rev-parse refs/heads/promote/test) == "${candidate}" ]]

# A normal promotion merge preserves the reviewed commits as ancestors.
git -C "${forge}" fetch -q origin
git -C "${forge}" switch -qc main origin/main
git -C "${forge}" merge --no-ff -qm 'Promote candidate' origin/promote/test
git -C "${forge}" push -q origin main
git -C "${repo}" fetch -q --atomic origin refs/heads/main:refs/heads/main refs/heads/dev:refs/heads/dev
git -C "${repo}" merge-base --is-ancestor "${candidate}" main
[[ $(git -C "${repo}" rev-parse dev) == "${next}" ]]
[[ $(git -C "${repo}" rev-parse main^2) == "${candidate}" ]]

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
