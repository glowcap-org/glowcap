# How glowcap is built

Glowcap LLC maintains glowcap with AI coding assistants. Its maintainer
directs the work, signs every commit that lands, and is answerable for the
result.

Each commit is a development checkpoint rather than every intermediate edit.
Commits carry no per-tool trailers, because tools differ in what they emit
and some emit none. This account covers every commit instead.

The illustration in `site/assets/glowcap-goblin-512.png` was generated with an
AI image tool for this project and refined by the maintainer in Pixelmator
Pro, which its embedded metadata records as the editing tool.

## Upstream policies

[Codeberg](https://codeberg.org/) amended its Terms of Use in July 2026 after a
member vote. § 2 (1) 7 says: “You must not share projects that mostly consist
of code written by ‘generative AI’-tools.” glowcap falls under that rule. The
accompanying post, [Protecting our FLOSS commons from
LLMs](https://blog.codeberg.org/protecting-our-floss-commons-from-llms.html),
also discusses projects built and maintained with heavy LLM use.

The [Zig project](https://ziglang.org/code-of-conduct/#strict-no-llm-no-ai-policy)
does not accept LLM-assisted contributions and also excludes LLM-assisted bug
finding. glowcap therefore sends no generated patches, reports, or discussion
upstream to Zig or to any project with a comparable policy. An issue found in
an agent-assisted glowcap session is not reported by glowcap. Only an
independently discovered issue may be handled under the target project's
policy.

The pinned OCapN repository has its own [generative-AI
policy](https://github.com/ocapn/ocapn#generative-ai-policy): specifications,
suite, official tooling, and surrounding communication must be human-authored,
and generated issues and pull requests are rejected. glowcap's implementation
may use agents. Its messages to OCapN may not. Any finding or review request is
independently understood and written by the maintainer rather than forwarded
from an agent-produced packet.

## Responsibility and licensing

The maintainer uses glowcap and stands behind the repository. The author
field records who wrote a change, and the maintainer's signature on every
`dev` and `main` commit records who accepted responsibility for landing it.
Neither is evidence of independent review, and neither creates an exception
to another project's policy.

glowcap-authored work is licensed under [Apache-2.0](LICENSE-APACHE). This does
not settle broader copyright questions about generated code. Third-party files
keep their original terms.

The repository is hosted on GitHub, a commercial forge, because Codeberg's
rule excludes it and because frequent container builds would draw on
Codeberg's donation-funded resources.

## Checking the claims

`zig build check` covers the tests, public examples, architecture rules,
protocol fixtures, and allocation budgets written inside this repository, so
they measure glowcap against its own expectations.

[Community review](docs/community-review.md) lists each check against the upstream OCapN suite and live
[Spritely Goblins](https://spritely.institute/goblins/) peers, and what each
one proves.

The external checks pin their direct inputs:

- OCapN conformance dependencies and the Python WebSocket proofs use committed
  `uv` locks.
- Direct Racket packages are installed at the checksums in
  `.devcontainer/pins.sh`. The crypto-lib compatibility change is a committed
  patch, and its source and output hashes are checked when the image is built.
  Racket's `--auto` still resolves transitive packages through its catalogs.
  The direct pins keep those roots fixed, but the transitive graph is not
  locked.
- GitHub workflow actions are pinned to immutable commit SHAs. A version
  comment is kept beside each one only to help review, and an upgrade
  changes both together.

[Known limitations](docs/boundaries.md) records what the checks do not
establish. If a named check does not support the claim attached
to it, please report that as a bug.
