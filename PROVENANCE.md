# How pancake is built

pancake is written with heavy use of AI coding agents. Assume every commit in
this repository was produced that way unless something in it says otherwise.
That is the accurate default, and it does not depend on any per-commit marker
being present. Every commit is authored by the maintainer, who directed the work
and is answerable for it. There is no pre-LLM history; the first commit is from
June 2026.

Most commits also carry a `Co-Authored-By: Claude` or `Co-authored-by: Cursor`
trailer. That is corroboration rather than the disclosure itself: the trailer is
emitted by whichever agent configuration ran, several are in use here, and one
that stops emitting leaves no trace of having done so. Counting them tells you
what the mechanism captured, which is less than the whole. For today's counts:

```sh
git log --grep='Co-Authored-By: Claude' --oneline | wc -l
git log --grep='Co-authored-by: Cursor' -i --oneline | wc -l
git log --oneline | wc -l
```

Two communities pancake depends on have taken public positions on that, so this
page answers both of them directly.

## What Codeberg and Zig have decided

[Codeberg](https://codeberg.org/), which is still this repository's origin,
amended its Terms of Use in July 2026 after a member vote. § 2 (1) 7 now reads:
"You must not share projects that mostly consist of code written by
'generative AI'-tools." pancake falls within that wording. The accompanying
post,
[Protecting our FLOSS commons from LLMs](https://blog.codeberg.org/protecting-our-floss-commons-from-llms.html),
also lists projects written and maintained with heavy LLM use among those that
may no longer be welcome.

The [Zig project](https://ziglang.org/) forbids LLM-assisted contributions
entirely, including issues and comments, because reviewing a pull request is how
they grow contributors and a generated patch tells them nothing about the person
who sent it.

## What that means in practice

**Nothing from this repository is sent upstream to a project that forbids it.**
pancake consumes Zig; it does not contribute LLM-written patches, issues, or
comments back to the Zig project, and the same restraint applies to any other
project with a comparable policy. If pancake hits a Zig bug, the report is
written by hand or it is not filed.

That restraint has a standing cost, and it is better said than left implicit.
pancake is carrying a fix for a real Zig defect it has not reported. Zig's test
runner hands an error-return trace to `std.debug.writeStackTrace`, which expects
a different type, so the runner does not compile in fuzz mode. The neighbouring
`std.debug.writeErrorReturnTrace` takes exactly that type, and Zig's own
`debug.zig` uses it for the same job elsewhere. That is the whole fix, and it is
written out at the top of `tools/fuzz/test_runner.zig`. Anyone is welcome to
take it upstream; it is not ours to send.

**Someone maintains this.** pancake exists because its author intends to build
their own infrastructure on it, and stands behind what is here. If that stops
being true, this file should be the first thing updated.

**The maintainer is responsible for what lands.** Every commit author field is
the maintainer's identity. That records responsibility for accepting the work;
it does not make the generated provenance an exception to another project's
policy.

**One file here is not ours.** `tools/fuzz/test_runner.zig` is Zig's own test
runner, copied from the pinned toolchain under its MIT licence, with the single
call renamed that the section above describes. The file opens with a note saying
where it came from and under what terms, and the notice itself is in
[LICENSE-THIRD-PARTY](LICENSE-THIRD-PARTY). `zig build meta-check` compares
everything below that note against the installed toolchain on every run and
fails when the two stop matching, including on the day Zig fixes the underlying
bug and the copy should be deleted.

**The license scope is explicit.** The maintainer makes pancake-authored work
available under [MIT](LICENSE-MIT) or [Apache-2.0](LICENSE-APACHE), at the
user's option. That statement does not settle the broader copyright questions
critics raise about generated code. The copied Zig test runner is MIT-only;
[`LICENSE-THIRD-PARTY`](LICENSE-THIRD-PARTY) carries Zig's notice and
identifies the file.

**No project workflow runs on Codeberg.** Codeberg is funded by donations, and
pancake pushes often; even a small hosted job pays for a checkout and a
toolchain download on every push. The full check sequence and the documentation
site build are configured on the [GitHub mirror](https://github.com/jimisaacs/pancake/actions/workflows/check.yml) instead. See
[CONTRIBUTING.md](CONTRIBUTING.md#continuous-integration).

## What you can run yourself

Generated code looks plausible whether or not it is right, so the claims here
are attached to checks you can run:

- `zig build check` runs the in-tree checks: the test suite, architecture and
  scaffolding checks, the public examples, protocol reference fixtures, and the
  allocation and footprint budgets.
- `zig build ocapn-conformance` runs the **upstream OCapN test suite** against a
  pancake peer.
- `zig build goblins-interop` holds a live conversation with a real
  [Spritely Goblins](https://spritely.institute/goblins/) vat, both directions.
  Goblins is the implementation pancake is measured against.
- `zig build goblins-handoff` and `goblins-gift` prove three-party handoff
  against that same live peer, as gifter and as recipient.

In-tree tests only show that code agrees with code the same author wrote. The
suite comes from the people who wrote the specification, and the Goblins steps
talk to somebody else's running implementation. Where an in-tree check is the
only evidence for a claim,
[docs/community-review.md](docs/community-review.md) says so in a
proves / does-not-prove table, and [docs/boundaries.md](docs/boundaries.md)
records where each capability stops.

If you find a claim in this repository that its named check does not support,
that is a bug, and I would like the report.
