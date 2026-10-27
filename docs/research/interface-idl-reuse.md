# Reusing an existing interface language

This review checked primary sources on 2026-10-26. It compares existing
frontends for glowcap's application interfaces. It does not establish that no
existing IDL can work, and it does not select a language before a working
mapping exists.

## Recommendation

Evaluate total authoring and implementation cost. Reuse is a candidate, not
the default verdict. The [experiment record](interface-design-proof.md)
and [proposed architecture](../decisions/adr/ADR-0069-proposed-interface-language.md)
record the recommendation after the Preserves and live Tasks experiments.
The language sketch is a requirements example, not proof of a finished design.

Separate three decisions: the authoring grammar, the compiler's shared model,
and the runtime or wire protocol. Reusing a schema compiler does not require
using its RPC transport. Conversely, generating familiar syntax does not
supply OCapN promise, reference, or authority semantics automatically.

## Preserves Schema

[Preserves Schema](https://preserves.dev/preserves-schema.html) already covers
literal patterns, recursive definitions, records, sequences, sets, dictionaries,
and embedded values. Its experimental `#:` patterns associate an interface
schema with an embedded value. The specification explicitly illustrates
actor references whose schema describes messages they accept.
That is stronger prior art than treating it as a copied-data-only schema.

Its [compiler](https://preserves.dev/doc/preserves-schemac.html) emits a
structured Schema or Bundle representation. A glowcap backend could consume
that representation instead of inventing a parser. Existing grammar can
express message shapes and embedded-reference expectations. Calls, replies,
passable promises, bounds, receipts, and compatibility still need an explicit
mapping or additional description conventions.

Assessment: best fit for preserving Syrup-shaped values and arbitrary actor
messages. The authoring style is pattern-oriented rather than method-oriented.
A convention that uses existing data forms is still a specification to
maintain, but it need not be a new text language.

## Cap'n Proto

The [schema language](https://capnproto.org/language.html) has interfaces,
capability-valued fields, inheritance, generic declarations, unions, and
user-defined annotations. Its built-in numeric types have fixed widths.
Generic parameters accept pointer types, not arbitrary scalar types.
`AnyPointer` admits pointer categories rather than every OCapN value.

The [compiler plugin interface](https://capnproto.org/otherlang.html) supplies a
CodeGeneratorRequest to an external executable. This gives glowcap a documented
way to reuse parsing and resolution while emitting its own clients and Syrup
encoders. Such a backend would not make those files compatible with ordinary
Cap'n Proto generated clients or its RPC protocol.

Assessment: strongest ready interface/compiler architecture to test. The schema
language does not directly describe every OCapN distinction. Arbitrary integers,
symbols, null versus undefined, dynamic passable values, promise arguments,
and direct invocation need named helper types or annotations.
Those are adaptation costs, not proof that the grammar is unusable.
Whether the resulting declarations remain pleasant must be tested.

## Web IDL

The [Web IDL standard](https://webidl.spec.whatwg.org/) includes interfaces,
callback interfaces and functions, dictionaries, optional and nullable values,
sequences, records, unions, bigint, symbols, promises, and extended attributes.
It therefore covers substantially more of the desired surface than a simple
request/response service IDL.

Its standard specifies browser interfaces and JavaScript conversion behavior.
Those conversion rules are not an OCapN wire mapping. In particular,
JavaScript symbol identity differs from the OCapN model's content-equal
Unicode symbols, and DOMString can carry surrogate code units that OCapN
strings exclude. A glowcap backend must state distinct binding rules and
preserve the [OCapN model](https://github.com/ocapn/ocapn/blob/main/draft-specifications/Model.md).
Extended attributes could record bounds and wire names without adding tokens
to the grammar. Tagged values and explicit passable-promise handling need
conventions, not assumed equivalence with a JavaScript Promise.

Assessment: credible for an existing readable syntax, but reusing the grammar
is different from claiming compliance with every Web IDL binding rule.
The standard also forbids recursive dictionary members, including through
sequences. Reusing its grammar for the recursive copied-data example would
therefore require different semantics or loss of the typed structure.

## WIT

The [WIT grammar](https://github.com/WebAssembly/component-model/blob/main/design/mvp/WIT.md)
provides records, variants, lists, tuples, resources, ownership and borrowing,
and async future and stream forms. It explicitly prohibits recursive types.
Its resource contracts belong to the WebAssembly Component Model, not to
shared distributed object references.

Assessment: a plausible integration target, especially for component users,
but a less direct common authoring model for the recursive copied values and
arbitrary messages in the requirements sketch. Wrappers can encode missing
concepts, but would make them application conventions rather than WIT
semantics. An OCapN adapter cannot silently substitute different ownership
rules while claiming the usual component contract.

## Slice

[Slice operations](https://docs.zeroc.com/ice/3.8/slice/operations) and
[proxies](https://docs.zeroc.com/ice/3.8/slice/proxies) describe interfaces,
remote object references, parameters, optional values, and inherited methods.
[Metadata directives](https://docs.zeroc.com/ice/3.8/javascript/slice-metadata-directives)
supply backend-specific information without changing the grammar.
Its [field rules](https://docs.zeroc.com/ice/3.8/python/fields) show why a
mapping must be checked carefully: standard language projections can collapse
an absent optional proxy and an explicitly null proxy.

Assessment: usable syntax for a custom distributed-object backend, but existing
Ice proxies and bindings do not implement OCapN. Preserve value distinctions,
promise behavior, and authority explicitly rather than inheriting Ice runtime
assumptions. This review found no advantage over the leading two candidates
that justifies starting with Slice.

## Comparison criteria

Map the same Tasks methods and adversarial value cases through Preserves Schema
and Cap'n Proto. Include a returned capability, a pending argument, exact wire
symbols, distinct absent/null/undefined values, unknown errors, and a bounded
integer. Compare generated API quality, retained ownership, diagnostics,
annotation burden, dependencies, and compiler integration work.

Handling these cases qualifies a candidate for the complete application proof.
It does not establish adoption. Compare complete single-file authoring and
generated application behavior.
An existing parser is not a sufficient reason to retain a more complicated
interface. A new parser is not justified by familiar syntax alone.
No claim of community support follows from this comparison.
