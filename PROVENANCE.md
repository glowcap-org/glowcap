# How pancake is built

pancake began as the capability-secure substrate for an agent orchestrator.
The maintainer builds it with AI coding assistants, authors every commit,
directs the work, and is answerable for what lands. There is no earlier,
human-only codebase; the first commit is from June 2026.

`Co-Authored-By: Claude` and `Co-authored-by: Cursor` trailers corroborate
the disclosure, but they are not the disclosure: different tools emit different
trailers, and some emit none.

## Upstream policies

[Codeberg](https://codeberg.org/) amended its Terms of Use in July 2026 after a
member vote. § 2 (1) 7 says: “You must not share projects that mostly consist
of code written by ‘generative AI’-tools.” pancake falls under that rule. The
accompanying post, [Protecting our FLOSS commons from
LLMs](https://blog.codeberg.org/protecting-our-floss-commons-from-llms.html),
also discusses projects built and maintained with heavy LLM use.

The [Zig project](https://ziglang.org/code-of-conduct/#strict-no-llm-no-ai-policy)
does not accept LLM-assisted contributions and also excludes LLM-assisted bug
finding. pancake therefore sends no generated patches, reports, or discussion
upstream to Zig or to any project with a comparable policy. An issue found in
an agent-assisted pancake session is not reported by pancake; only an
independently discovered issue may be handled under the target project's
policy.

The pinned OCapN repository has its own [generative-AI
policy](https://github.com/ocapn/ocapn#generative-ai-policy): specifications,
suite, official tooling, and surrounding communication must be human-authored,
and generated issues and pull requests are rejected. pancake's implementation
may use agents; its messages to OCapN may not. Any finding or review request is
independently understood and written by the maintainer rather than forwarded
from an agent-produced packet.

## Responsibility and licensing

The maintainer uses pancake and stands behind the repository. The author field
records who accepted responsibility for what landed; it is not evidence of
independent review, does not erase how the work was made, and creates no
exception to another project's policy.

pancake-authored work is available under [Apache-2.0](LICENSE-APACHE). This does
not settle broader copyright questions about generated code. Third-party files
keep their original terms.

The repository is hosted on GitHub because Codeberg's rule excludes it and
because frequent container builds would consume donation-funded resources.
A paid commercial forge avoids both conflicts.

## Checking the claims

`zig build check` covers the tests, public examples, architecture rules,
protocol fixtures, and allocation budgets written inside this repository.
Those checks show that pancake agrees with its own expectations.

External evidence is separate:

- `zig build ocapn-conformance` runs every portable upstream OCapN test module
  except its TCP-reset-sensitive `op:abort` case, then runs pancake's stricter
  pre-setup abort and handshake-refusal probe against the same peer.
- `zig build goblins-interop` runs a two-way conversation with a live
  [Spritely Goblins](https://spritely.institute/goblins/) vat.
- `zig build goblins-handoff`, `goblins-gift`, and `goblins-exporter` exercise
  pancake in each three-party handoff role against Goblins.

External evidence does not resolve its direct inputs from moving package
catalogs. OCapN conformance dependencies and Python WebSocket proofs use
committed `uv` locks. Direct Racket packages are installed at the checksums in
`.devcontainer/pins.sh`; the pinned crypto-lib compatibility change is a
committed patch whose source and output hashes are checked during image build.
Racket's `--auto` still resolves transitive packages through its catalogs; the
direct source pins prevent those roots from moving but do not make that graph a
lockfile.
GitHub workflow actions use immutable commit SHAs, with the corresponding
major tag left only as a review aid; upgrades change both together.

[Community review](docs/community-review.md) distinguishes in-tree evidence
from outside evidence. [Known boundaries](docs/boundaries.md) records what the
checks do not establish. If a named check does not support the claim attached
to it, please report that as a bug.
