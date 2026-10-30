---
id: ADR-0067
status: accepted
date: 2026-10-19
tags: ["workflow", "publication", "provenance"]
decision: "Every commit on dev and main is signed by the maintainer at integration, carries its check record, and reaches main by fast-forward."
supersedes: []
superseded_by: []
amends: []
amended_by: [ADR-0073]
---

# ADR-0067 Evidence-bearing integration

## Context

glowcap is written with AI coding assistants under one maintainer
([`PROVENANCE.md`](../../../PROVENANCE.md)). The question a reader of its
history asks is not who typed a change but who vouched for it and what was
checked. Draft commits are made in linked worktrees by agents that hold no
signing key. The CI sequence (`ci/gates.sh`) is long, so what it proved about
a commit must stay attached to that commit rather than to a run page. A squash
or merge on the way to `main` would replace the checked commit with a new
hash no check ran on and no signature covers.

## Decision

- The worktree integrator (`.agents/skills/work/bin/glowcap-integrate`) is
  the only writer of `dev`. For each publish it makes one commit from the
  branch's tree, signs it with the maintainer's SSH key, verifies the
  signature, and compare-and-swaps `dev`. Without a reachable key it refuses
  and moves nothing. Worktree commits are unsigned drafts.
- The author field records who wrote the change, kept when the branch's
  commits share one author. The committer and signature record who vouched.
- Every run of the gate sequence writes an evidence record
  (`tools/evidence/record.py`), and a clean run attaches it to the commit as
  a note under `refs/notes/evidence`. The integrator carries the note through
  its rebases onto the signed commit.
- `main` moves only by fast-forward from a commit on `dev`
  ([maintaining](../../maintaining.md#promoting-to-main)). The hosted
  rulesets require signed commits, linear history, and passing checks on the
  pushed commit, with no bypass.
- Outside contributions land through the same integrator from a review
  worktree, never through a merge button.

## Alternatives and consequences

Signing every worktree commit would need the key on every machine an agent
runs on, which contradicts keeping it in the maintainer's hands. Requiring
signatures only at promotion would leave `dev` unvouched. Merge-commit or
squash promotion through pull requests preserved ancestry but broke the
identity between the checked commit and the published one.

The cost is that integration needs the maintainer's key reachable, so an
agent session integrates only with a forwarded agent, and a contributor's
multi-author branch lands under the integrator's name with its commits listed
in the message. GitHub's rulesets, once active, are the remote half of the
rule. Until then the integrator and the local checks are the only enforcement.

## Evidence

`tools/check/worktree-integration-test.sh` proves the signed commit, the kept
author, the carried note, and the refusal without a key.
`tools/check/publication-integration-test.sh` proves a contribution landing
through the integrator and a fast-forward-only `main`.
`ci/test/workflow_test.py` holds the rulesets to signed,
linear, checked history. None of these shows the hosted rulesets are active.
