# glowcap — Agent Hooks

Canonical home for hook scripts that fire around agent work.

| Surface                     | Canonical                                        |
| --------------------------- | ------------------------------------------------ |
| Per-edit formatter dispatch | [`format-edited-file.sh`](format-edited-file.sh) |
| Pre-commit design questions | [`before-commit.sh`](before-commit.sh)           |

[`format-edited-file.sh`](format-edited-file.sh) formats:

- `*.zig` with `zig fmt`
- `*.rs` with `rustfmt` (discovers root `rustfmt.toml`)
- `*.ts` / `*.tsx` / `*.js` with `deno fmt` (from the file's directory, so the nearest
  `deno.json` applies)

Python and Racket have no single-file formatter on PATH here; `zig build
bindings-fmt-check` holds them. The script exits 0 even when formatting fails;
`zig build check` stays the load-bearing gate. Cursor and Claude point at this
canonical command; `zig build source-check` verifies the tool wiring.

[`before-commit.sh`](before-commit.sh) prints three questions when a `Bash` call
is a `git commit`, and nothing otherwise.

`AGENTS.md` has carried "Principled moves only. No workarounds, no quick fixes."
from the beginning, and the maintainer still had to say it out loud, session
after session. The sentence is not the problem. "Principled" names a quality,
and a quality gives you nothing to catch yourself failing: nobody believes their
own patch is the unprincipled one. A question with a wrong answer does.

So the script asks three, each drawn from a defect this repository actually
shipped. Whether the change removes a class or referees one instance, whether
the sibling case is still reachable, and whether a comment is holding something
a type or a check could hold. It fires at commit because that is the last moment
the answer is still cheap, and it stays short because a paragraph here would
become wallpaper on its second reading, which is precisely how the sentence it
supplements stopped working.

It is advisory: it prints and exits 0. `zig build check` is the gate, and a hook
able to block a commit would be a second one nobody agreed to.
