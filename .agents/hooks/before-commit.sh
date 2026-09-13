#!/usr/bin/env bash
# Ask the three questions, at the one moment they can still change the answer.
#
# `AGENTS.md` has said "Principled moves only. No workarounds, no quick fixes."
# for as long as it has existed, and the maintainer still had to say it out loud
# in session after session. That is not a reader problem. "Principled" names a
# quality, and a quality has no failure mode you can catch yourself committing:
# nobody believes their own patch is the unprincipled one. What catches it is a
# question with a wrong answer.
#
# So this is three questions, not a reminder to be careful, and each is drawn
# from a defect this repository actually shipped. It fires on `git commit`
# because that is the last moment the answer is cheap to change, and it stays
# three lines because a paragraph here becomes wallpaper on the second reading.
# That is exactly how the sentence it replaces stopped working.
#
# Advisory. It prints and exits 0: `zig build check` is the gate, and a hook
# that could block a commit would be a second one nobody voted for.

set -uo pipefail

payload=$(cat 2>/dev/null || true)
case "$payload" in
*'git commit'*) ;;
*) exit 0 ;;
esac

cat <<'ASK'
Before this commit, three questions. Each one is a defect this repo has shipped.

  1. Does this remove the defect's class, or referee one instance of it?
     Two status lines were stopped from overlapping by a rule naming that one
     pair. The pairs nobody wrote still overlapped. Laying them in a row left
     nothing to referee, and found the pair nobody had written.

  2. Would the sibling case still be possible?
     Unsafe bodies were marked across the whole tree by a sweep run on the host
     target, and the wasm32-only one sat unmarked. Ask which targets, features,
     directions, or callers the fix did not visit.

  3. Is anything here kept true by a comment, where a type, a check, or the
     shape could keep it instead?
     A memo passed whole state and named three of its fields, correct only
     while a comment about another function's body stayed true. Handing it the
     fields made the compiler hold the pair together.

Each answer owes something. The good one owes nothing and you move on. The bad
one owes either the change, or a line in the commit message naming exactly what
stays possible and who meets it, so it is somebody's next task instead of
nobody's. "I considered it and it is fine" is neither, and is the answer this
exists to refuse.
ASK
exit 0
