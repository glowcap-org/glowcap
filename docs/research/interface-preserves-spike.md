# Preserves Schema compiler spike

This experiment, run on 2026-10-26, proves selected compiler capabilities.
It does not establish that Preserves Schema meets the interface design criteria.
The [experiment record](interface-design-proof.md) compares that result with
the other candidate frontends and states the evidence limits.
The [reuse comparison](interface-idl-reuse.md) owns the broader alternatives.

## What ran

The upstream compiler compiled [Tasks message shapes](preserves-spike/tasks.prs)
and [value coverage cases](preserves-spike/coverage.prs) to its schema bundle.
Its TypeScript generator then emitted serializers, decoders, constructors,
and embedded schema descriptions. The generated modules passed strict
TypeScript checking with TypeScript 5.9.3.

A temporary caller adapter consumed the compiled description and
[method metadata](preserves-spike/contracts.json). It used generated
serializers to construct the actual method-symbol and mutation-envelope
argument sequences, validated replies, and applied explicit arity and bounds.
A captured-call transport checked these sequences without opening a session.
The [observation record](preserves-spike/observations.json) pins input hashes,
tool versions, and the cases exercised.

For example, this is accepted by the existing compiler:

```text
BoardList = [=list @index int] .
Task = [=text] .
TaskRef = #:Task .
ListMove = [=mutate @sequence int =move @task #:Task @destination #:TaskList] .
```

The schema names describe requests and value shapes. The metadata pairs a
request with its reply type and application bounds. That pairing is a glowcap
convention using ordinary JSON, not another parser or language.
Embedded annotations survive in the compiled schema, so a backend can find
the expected Task or TaskList interface without recovering it from source text.

## What worked and what needs adaptation

| Case | Observed result |
| --- | --- |
| Method symbols and receipt envelopes | Generated constructors preserve the expected positional sequences |
| Returned references | Embedded values pass, and copied integers fail reference validation |
| Pending references | An opaque pending-reference fixture survives parse and serialization without being awaited |
| Recursive data and direct invocation | Existing grammar, generation, and validation handle them |
| Atoms and containers | Boolean, integer, float, string, bytes, symbol, tuple, list, set, dictionary, and record cases run |
| Trailing arguments | Upstream tuples accept and discard them on reconstruction. The adapter enforces declared call arity |
| Application bounds | Metadata enforces integer ranges, nonempty text, and UTF-8 byte limits |
| Reference interface claims | Any embedded value passes. Host admission and identity remain necessary |
| Arbitrary integers | The interpreter accepts bigint, but the generated TypeScript validator rejects it |

The integer discrepancy was reproduced with `9007199254740993n` after a
Preserves binary round trip. It is a generator limitation in the tested
release, not an inability of the schema language or interpreter to represent
the value. The supplied TypeScript generator cannot be adopted unchanged for
the complete OCapN model. No upstream report was sent.

The pending fixture is not a glowcap Vow or a remote promise. The captured
transport proves argument construction, not live pipelining, handoff, receipt
deduplication, authorization, cancellation, or reference release.
Null versus undefined, error mappings, and cross-language projection remain
unproved by this experiment. Those need explicit profile rules and live tests.

## Reproduce the compiler and generator checks

Run from the repository root. These commands install only into a fresh
scratch directory. They add nothing to glowcap's dependencies or build graph.
The experiment used host Node 26.12.1, not the pinned development environment.
The tools remain candidates for adoption, not part of the supported toolchain.

```sh
preserves_spike=$(mktemp -d)
npm install --prefix "$preserves_spike" --ignore-scripts --no-audit --no-fund \
  @preserves/schema-cli@1.0.0-rc.2 typescript@5.9.3
"$preserves_spike/node_modules/.bin/preserves-schemac" \
  docs/research/preserves-spike > "$preserves_spike/tasks.bundle"
"$preserves_spike/node_modules/.bin/preserves-schema-ts" \
  --output "$preserves_spike/generated" docs/research/preserves-spike
"$preserves_spike/node_modules/.bin/tsc" --module commonjs \
  --moduleResolution node --target es2022 --strict \
  --outDir "$preserves_spike/js" \
  "$preserves_spike/generated/tasks.ts" \
  "$preserves_spike/generated/coverage.ts"
```

The schema bundle is Preserves binary, not a CapTP message or a Syrup wire
fixture. It is input to a generator backend. Runtime calls still use the
existing glowcap codec and Host. Modern Node module resolution exposed package
declaration lookup problems during the probe, so the command uses the older
module resolution supported by the package layout.

## Verdict

The spike did not prove the complete developer experience. Its separate method
metadata violates the one-authored-definition requirement. Moving that metadata
into [source annotations](preserves-spike/annotated-tasks.prs) removes the second
file, but the tested compiler discards the annotations from its output.
The [follow-up result](preserves-spike/one-source-result.json) records that check.

A glowcap interpretation step could retain and validate those annotations.
That is an additional language implementation to compare, not evidence that
the existing compiler already meets the criteria. Preserves Schema remains
useful prior art, but this result does not justify selecting it.

Primary references: the [schema specification](https://preserves.dev/preserves-schema.html),
[compiler interface](https://preserves.dev/doc/preserves-schemac.html), and the
npm release [schema-cli 1.0.0-rc.2](https://www.npmjs.com/package/@preserves/schema-cli/v/1.0.0-rc.2).
