# Interface authoring comparison

`comparison.syrup` is the direct input and independent expected description.
It was constructed with the pinned upstream Python Syrup encoder from explicit
records and dictionaries, without either comparison adapter. The proposed text
in `comparison.interface` must reproduce those bytes before shared validation.
The Cap'n Proto adapter uses the same expected description.

| Case | Retained mapping and evidence |
| --- | --- |
| Bounds | Name counts UTF-8 bytes from 1 to 64. Count is integer 0 through 16. Both reach the checked model. Factory.add also reaches the existing bounded creation emitter |
| Selectors | Direct prepends no symbol to its whole argument list. Named prepends the exact empty symbol, `then`, or `a-b` |
| Presence | Required undefined and optional undefined remain different parameter descriptions. The text runtime proof sends zero arguments and one void argument |
| Null | Null input and result survive description checking. Existing call targets refuse both with `UnsupportedTarget` |
| Pending references | Factory accepts Reader and promise of Reader. Prepared retains the existing receipt shape with promise of value |
| Unknown breaks | Ordinary calls leave remote breaks open. The runtime proof preserves an unlisted reason. The method description has no declared-break metadata |

The text adapter accepts module declarations, aliases, interfaces, primitive
comparison types, bounded primitives, named references, promise arguments,
trailing optional parameters, direct calls, exact quoted names, `tell`, and
`@loam.receipt`. It uses the proposed syntax from the
[language reference](../../../docs/research/interface-language-example.md).
Imports, copied records, unions, and `throws` are outside this comparison.
They are refused rather than discarded. These adapters do not select a
production authoring frontend.

## Reproduce

Run commands through `.agents/skills/work/bin/glowcap-dev` from the repository
root. The interface test step builds the comparison checker. It reads build inputs only.

```sh
zig build interface-test
zig-out/bin/interface-authoring text test/interface/authoring/comparison.interface
zig-out/bin/interface-authoring syrup test/interface/authoring/comparison.syrup
zig-out/bin/interface-authoring text test/interface/authoring/comparison.interface description comparison.Reader --named read unused zig-out/comparison.syrup
cmp test/interface/authoring/comparison.syrup zig-out/comparison.syrup
zig-out/bin/interface-authoring syrup test/interface/authoring/comparison.syrup rust comparison.Reader --named read authoring_read zig-out/authoring_read.rs
zig build gen-interface-fixtures-check interface-conversation-check
```

After input format and path, emission takes target, receiver, selector kind,
generated function name, and output path. Use `--direct` for an absent selector
or `--named NAME` for a literal wire name. `--named ''` selects the empty symbol,
and `--named --direct` selects the method named `--direct`.
Targets are `description`, `rust`, `ts`, and the existing
`zig` creation projection. Every path reads the canonical description and calls
`Model.init` before emission. The text path does so before returning its bytes.

Requested function names survive emission unchanged. Private helper and import
names cannot conflict with them. Duplicate exports and names already exported
as public support, such as `Pending`, are refused before writing output.

`interface-test` compares exact independent descriptions and checked selections.
It changes the Name bound to 32, Reader.read's reply to undefined, and the `a-b`
wire name to `renamed`, then checks the affected existing emitters. It refuses
invalid bounds, unresolved names, nontrailing optional parameters, duplicates,
and unsupported syntax. Long module prefixes consume the existing output byte
budget before expanded names allocate scratch. Adversarial references refuse
without growing allocation demand after that budget is exhausted.

Syntax diagnostics include a byte offset, line, and
column. Shared model refusals identify the validation boundary, without a
field-specific source location.

The TypeScript runtime proof starts from proposed text through the same emitter
as direct Syrup. Both session profiles check presence, immediate sending, a
passable pending input before settlement, and an unknown remote break.
The shared runtime corpus remains the evidence for the other emitter paths.
A description match alone does not establish runtime support for a type.

`interface-conversation-check` also compiles isolated Rust and TypeScript projections
from [rust_helpers.interface](rust_helpers.interface). Rust uses public library
modules checked with `cargo clippy --lib -- -D warnings`, without lint allowances.
The cases cover text, capability and value replies, reference inputs, optional
arguments, receipt preparation, and tells with zero, string, undefined, value,
or optional arguments. Bounded cases add UTF-8 text inputs and replies,
lower-only and wide byte limits, integer parameters and tells, optional bounded
text, and full signed-64-bit replies.

The scratch library reuses the conversation crate's
dependencies, lockfile, and Cargo caches. Deno checks TypeScript consumers.
Both compilers check exports matching private helpers and imports, plus multiple
selected functions in one module. Rust also checks bounded decoder names and
private module name allocation. These checks add no runtime calls.

The adapter has no new production dependency. An arena owns decoded tokens and
encoded fragments for one compilation, and the caller owns the final canonical
byte copy. The shared reader's input, node, and depth limits also bound this
adapter. Handwritten parser, checker, tests, and generated output are counted
separately when comparing authoring cost. The measured generation report is
unchanged by this comparison.

## Process and build costs, 2026-11-03

These observations use clean source revision
`c5e6078ec5449594e704ea8a6091a001cbfd0807`.
[Raw samples, compiler arguments, source hashes, and counts](process-costs.json)
retain the inputs. Other work was active on the host. These are provisional
process and resource observations, not a speed comparison.

Both formats use the same stripped ReleaseFast checker, targeting the baseline
CPU on aarch64 with Zig 0.17.0 and Python 3.13.5. The checker reads each format's
source file. Syrup enters `description.read` and `Model.init` directly. Text
translates and validates its canonical description, then the CLI repeats that
shared validation before returning. No emitter or runtime call is timed.

After one warmup per format, seven alternating pairs produced:

| Check process | Median ms | Maximum ms | Maximum RSS upper bound, bytes |
| --- | ---: | ---: | ---: |
| Direct Syrup | 0.637 | 0.757 | 17,305,600 |
| Proposed text | 0.661 | 0.804 | 17,305,600 |
| Spawn floor (`true`) | 0.485 | 0.689 | See raw samples |

Times include process launch, file I/O, and the polling observer. Their overlap
with the spawn floor prevents attributing the difference to parsing.
`wait4` includes inherited pre-exec memory, so RSS is an upper bound rather than
isolated parser memory. Both observed maxima fit the plan's warm generation
budget. This does not measure large-input throughput or an intrinsic speedup.

Three builds of the same checker used fresh private local and global Zig caches.
The filesystem was already warm. Each second invocation used the same compiler
command and caches, without assuming compilation was skipped.

| Pair | Cold-cache seconds | Warm-cache seconds | Cold RSS upper bound, bytes | Warm RSS upper bound, bytes |
| --- | ---: | ---: | ---: | ---: |
| 1 | 6.325 | 4.422 | 374,554,624 | 283,840,512 |
| 2 | 6.147 | 4.266 | 382,238,720 | 290,136,064 |
| 3 | 6.091 | 4.495 | 369,983,488 | 294,699,008 |

Every binary occupied 361,160 bytes. This shared executable contains both
frontends and the selected emitters. Its size and build cost do not isolate a
frontend's incremental contribution. Compilation uses the Zig standard library
and existing repository modules, with no fetched dependency or added library.
Python's standard library owns only the measurement process.

| Measured source | Nonblank lines |
| --- | ---: |
| Text adapter | 263 |
| Shared comparison CLI | 53 |
| Handwritten adapter tests | 141 |
| CLI refusal tests | 41 |
| Frontend runtime proof | 59 |
| Generated TypeScript | 55 |
| Proposed source / direct Syrup | 27 / 1 |

The direct Syrup file is canonical serialized data, so its single line is not an
editing-cost advantage. The text adapter adds 263 lines to the shared checked
compiler and emitters. Tests and generated output do not offset that cost.
The [generation report](../../../bench/interface/results.md) retains its own
measured revision and is unchanged.

### Repeat the measurements

Run this from the repository root through the development wrapper. It rebuilds
only the checker from the recorded module arguments, uses private temporary
caches, and writes a new report under `zig-out`. Compiler children have a
120-second deadline, warm builds 30 seconds, and check processes 5 seconds.
It does not flush host filesystem caches or replace the retained samples.

```sh
python3 - <<'PY'
import json, os, shutil, signal, subprocess, tempfile, time
from pathlib import Path

def measure(argv, timeout):
    start = time.perf_counter_ns()
    pid = os.posix_spawnp(argv[0], argv, os.environ)
    deadline = time.monotonic() + timeout
    while True:
        ended, status, usage = os.wait4(pid, os.WNOHANG)
        if ended:
            if os.waitstatus_to_exitcode(status):
                raise RuntimeError(argv[0])
            return {"ns": time.perf_counter_ns() - start,
                    "rss_upper_bytes": usage.ru_maxrss * 1024}
        if time.monotonic() >= deadline:
            os.kill(pid, signal.SIGKILL)
            os.wait4(pid, 0)
            raise TimeoutError(argv[0])
        time.sleep(0.0001)

recorded = json.loads(Path("test/interface/authoring/process-costs.json").read_text())
result = {"builds": [], "spawn_floor": [], "checks": []}
result["revision"] = subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip()
Path("zig-out").mkdir(exist_ok=True)
with tempfile.TemporaryDirectory(prefix="authoring-costs-", dir="zig-out") as temporary:
    for pair in range(3):
        directory = Path(temporary) / str(pair)
        directory.mkdir()
        binary = directory / "checker"
        substitutions = {"LOCAL": str(directory / "local"),
                         "GLOBAL": str(directory / "global"),
                         "-femit-bin=CHECKER": f"-femit-bin={binary}"}
        argv = [substitutions.get(arg, arg) for arg in recorded["compiler_args"]]
        result["builds"].append({"cold": measure(argv, 120), "warm": measure(argv, 30),
                                 "artifact_bytes": binary.stat().st_size})
    commands = {kind: [str(binary), kind, f"test/interface/authoring/comparison.{suffix}"]
                for kind, suffix in (("syrup", "syrup"), ("text", "interface"))}
    for argv in commands.values():
        measure(argv, 5)
    for pair in range(7):
        result["spawn_floor"].append(measure([shutil.which("true")], 5))
        for kind in (("syrup", "text") if pair % 2 == 0 else ("text", "syrup")):
            result["checks"].append({"format": kind, **measure(commands[kind], 5)})
Path("zig-out/authoring-repeated-costs.json").write_text(json.dumps(result, indent=2) + "\n")
PY
```
