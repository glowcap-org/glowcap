"""What CI runs: every gate, in the phase and group that runs it.

A gate is one command judged by its exit code. A phase is the list of gates
one test job runs in order. A group is the phases that share one compiled
state: its build jobs each compile one shard of what the phases run, then one
test job per phase runs on their combined state (check-group.yml). ci/plan.py
selects groups for a run, ci/gates.py runs a phase or compiles a shard.

Each row names its deadline class, which ci/gates.py sizes for a hosted
runner that compiles cold:

- `gate`: an ordinary check.
- `build`: a gate whose time is mostly a cold compile. A phase opens with the
  build its proofs share, so each proof's deadline times the proof. When it
  runs out of time the phase stops, because every later gate needs it.
- `long`: a gate that serializes many process proofs, each under its own
  deadline, so its healthy duration is itself tens of minutes.

A `zig build` row gets `--test-timeout 30s` and `--summary new` unless it sets
them. `shards` is the number of build jobs. Zero means the phases compile in
a nested build at run time and hand nothing over. Only compiles no Cargo or
Deno build reaches can leave the first shard, so a count above one pays only
where those compiles are many. What each step proves is its description in
docs/build-steps.md.
"""

from typing import NamedTuple


class Group(NamedTuple):
    name: str
    shards: int
    phases: dict


def gate(command):
    return ("gate", command)


def build(command):
    return ("build", command)


def long(command):
    return ("long", command)


# Every `zig build` proof below shares the Rooms browser application and the
# Loam browser consumer, cargo and Wasm builds.
BROWSER_BUILDS = (
    build("zig build loam-browser-build rooms-web-build"),
    build("zig build rooms-archive-build rooms-session-build iroh-abi"),
)

GROUPS = (
    # The source contracts compile only their checkers, so they report within
    # minutes of a push instead of behind the product compile.
    Group(
        "source",
        shards=0,
        phases={
            "source": [gate("zig build source-check")],
            "infrastructure": [
                gate("bash .devcontainer/hooks/post-create.sh"),
                # The deadline wrapper bounds every gate, and ci/gates.py branches
                # on its codes, so it is proven before anything relies on it.
                gate("python3 tools/run_with_timeout_test.py"),
                gate("zig build infrastructure-check"),
            ],
        },
    ),
    Group(
        "core",
        shards=2,
        phases={
            "core": [build("zig build check-build"), gate("zig build check")],
            "memcheck": [build("zig build test-memcheck-build"), long("zig build test-memcheck")],
        },
    ),
    # The process, application, and language-workspace proofs run against the
    # ReleaseSafe archives a release ships. The core phase's Debug tests still
    # meet Debug's undefined-memory fill on every change.
    Group(
        "runtime",
        shards=2,
        phases={
            "runtime": [
                build("zig build runtime-check-build -Doptimize=ReleaseSafe"),
                long("zig build runtime-check -Doptimize=ReleaseSafe"),
            ]
        },
    ),
    # The optional Mbed TLS relay is absent from the base library graph, so
    # `check` cannot prove it. Its own group reports without waiting for Rooms.
    Group("tls", shards=1, phases={"tls": [gate("zig build mbedtls-build")]}),
    Group(
        "shipped",
        shards=2,
        phases={
            # One ReleaseSafe compile per layer partition bounds optimizer memory
            # without dropping a layer. ci/gates_test.py holds the partition
            # to the Layer enum in test/all_test.zig.
            "shipped": [
                build("zig build test -Doptimize=ReleaseSafe -Dtest-layer=loam,root,foundation,codec,model"),
                build("zig build test -Doptimize=ReleaseSafe -Dtest-layer=engine,session,actors,c_abi"),
                build("zig build test -Doptimize=ReleaseSafe -Dtest-layer=driver,net"),
            ],
            # Representative browser and outside-authority proofs on every change.
            "smoke": [
                gate("zig build wasm-host-test"),
                gate("zig build wasm-abi-layout-check"),
                gate("zig build wasm-import-check"),
                gate("zig build web-peer-test"),
                gate("zig build goblins-interop"),
            ],
        },
    ),
    # Bounded mutation fuzzing over every surface that takes bytes somebody
    # else chose. It stays out of `zig build check` because it spawns a nested
    # `zig build`, and check's steps run in parallel over one cache. The run
    # budget is per target, so the sweep's time grows with every target: 25K
    # runs keeps a shard under its deadline, depth is for a local or nightly
    # run with a larger -Dfuzz-runs. Each target compiles its own ReleaseSafe
    # binary, so the sweep runs as interleaved shards. When a shard's headroom
    # warning fires, add a shard here.
    Group(
        "fuzz",
        shards=0,
        phases={
            f"fuzz-{shard}": [gate(f"zig build fuzz -Dfuzz-runs=25K -Dfuzz-shard={shard}/4")] for shard in (1, 2, 3, 4)
        },
    ),
    Group(
        "bindings",
        shards=1,
        phases={
            # The Rust sidecars' own unit tests, which reach what no Zig test can:
            # iroh's connect timeout firing and the WebRTC inbound buffer holding.
            "sidecars": [
                gate("zig build sidecar-runtime-test"),
                gate("zig build iroh-sidecar-test"),
                gate("zig build webrtc-sidecar-test"),
            ],
            "bindings": [
                gate("zig build webrtc-loop"),
                gate("zig build webrtc-redeem"),
                # Clippy compiles every first-party crate and its dependencies, so
                # on a cold runner its time is the compile. The format check
                # reuses that cache.
                build("zig build rust-lint"),
                gate("zig build bindings-fmt-check"),
                gate("zig build bindings"),
                gate("zig build bindings-package-check"),
                gate("zig build bindings-noise-relay-listen"),
                gate("zig build bindings-verb-spine"),
                gate("zig build bindings-keyed-tcp-restart"),
                gate("zig build bindings-keyed-relay-rendezvous"),
                gate("zig build zig-keyed-relay-register"),
                gate("zig build bindings-iroh-handoff"),
                gate("zig build bindings-iroh-redeem-posture"),
            ],
        },
    ),
    Group(
        "browser",
        shards=1,
        phases={
            "browser": [
                *BROWSER_BUILDS,
                gate("zig build loam-browser-test"),
                gate("zig build rooms-rust-browser-test"),
                gate("zig build ocapnviz-live-browser"),
            ],
            # Every supported browser journey is release evidence. The family runs
            # concurrently within a shard and grows with every journey, so it runs
            # as interleaved shards, each opening with the shared builds. When a
            # shard's headroom warning fires, add a shard here.
            **{
                f"browser-proofs-{shard}": [
                    *BROWSER_BUILDS,
                    gate(f"zig build rooms-web-proofs -Drooms-web-proof-shard={shard}/4"),
                ]
                for shard in (1, 2, 3, 4)
            },
        },
    ),
    # Live conversations with a real Goblins vat: the authority on protocol
    # behavior that glowcap's own checks cannot supply.
    Group(
        "interop",
        shards=1,
        phases={
            "rooms-interop": [
                build("zig build build rooms-archive-build"),
                gate("zig build goblins-rooms"),
                gate("zig build demo-rooms"),
                gate("zig build goblins-rooms-irc"),
            ],
            "interop": [
                build("zig build build rooms-archive-build"),
                gate("zig build bindings-goblins-interop"),
                gate("zig build bindings-goblins-handoff"),
                gate("zig build bindings-goblins-gift"),
                gate("zig build goblins-handoff"),
                gate("zig build goblins-handoff-iroh"),
                gate("zig build goblins-gift"),
                gate("zig build goblins-gift-hints"),
                gate("zig build goblins-relayed-give"),
                gate("zig build goblins-listen-recipient"),
                gate("zig build goblins-exporter"),
                gate("zig build goblins-gc"),
                gate("zig build bindings-goblins-listen"),
                gate("zig build goblins-relay"),
                gate("zig build fixture-gen-check"),
                gate("zig build ocapn-findings-check"),
                gate("zig build ocapn-conformance-next"),
                gate("zig build goblins-glowcap-pair-gift"),
            ],
        },
    ),
    Group(
        "transports",
        shards=1,
        phases={
            "transports": [
                build("zig build build iroh-sidecar-build iroh-abi"),
                gate("zig build iroh-session"),
                gate("zig build iroh-driver-provider"),
                gate("zig build python-iroh-driver-provider"),
                gate("zig build rust-iroh-driver-provider"),
                gate("zig build bindings-relay"),
                gate("zig build bindings-wss-relay"),
                gate("zig build bindings-relay-iroh"),
            ]
        },
    ),
)

GROUP_NAMES = tuple(group.name for group in GROUPS)
# Every phase belongs to exactly one group.
PHASES = {phase: gates for group in GROUPS for phase, gates in group.phases.items()}
assert len(PHASES) == sum(len(group.phases) for group in GROUPS), "a phase name is in two groups"
