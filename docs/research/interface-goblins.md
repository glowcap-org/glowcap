# Interfaces beside Goblins

Spritely has explored interface descriptions directly. The question for
glowcap is which parts justify a shared implementation and which should remain
optional application conventions. This review checked primary sources on
2026-10-26. It establishes neither an upstream endorsement nor an explanation
of Spritely's development priorities.

## What Spritely describes

The paper [Content Addressed Descriptors and Interfaces with Spritely
Goblins](https://files.spritely.institute/papers/interfaces.html) describes
Syrup-compatible interface data, content addressing, runtime contracts, and
remote discovery. Its example language is explicitly incomplete and
illustrative. It suggests Preserves Schema as a fuller design.

Sections 5.4 and 5.5 explain why a universal description method does not fit
every actor. An actor may accept arguments directly, without method dispatch.
The paper instead demonstrates description through a separate capability
that unlocks hidden behavior, using a ward and its incanter.

Section 7 treats a remote interface as an allegation. A matching description
does not justify removing checks where mutually suspicious programs exchange
values. Content addressing identifies description content, not trustworthy
execution. These are documented design concerns, not inferred objections.

The [Guile Goblins 0.18 manual](https://files.spritely.institute/docs/guile-goblins/0.18.0/index.html)
documents the underlying machinery. Its
[methods library](https://files.spritely.institute/docs/guile-goblins/0.18.0/Methods.html)
dispatches on a symbol, and its
[ward library](https://files.spritely.institute/docs/guile-goblins/0.18.0/Ward.html)
restricts behavior to holders of the corresponding incanter.
The manual has no documented general interface-definition language or
cross-language generator facility that this review could identify. That
limited observation does not show that Spritely rejected either facility.

## What the dynamic model preserves

Goblins actors can change their behavior. The
[object definition documentation](https://files.spritely.institute/docs/guile-goblins/0.18.0/Object-definition.html)
shows this explicitly, and
[swappable actors](https://files.spritely.institute/docs/guile-goblins/0.18.0/Swappable.html)
can change targets. A description attached to a reference therefore needs a
defined lifetime. A fixed generated proxy cannot establish that the remote
object still implements its original contract.

A [facet](https://files.spritely.institute/docs/guile-goblins/0.18.0/Facet.html)
forwards only selected methods. For glowcap, the consequence is that discovery
must describe that restricted view. Forwarding the underlying object's
description would expose information the facet did not intend to share.

## A related implementation

Endo already provides
[interface guards](https://github.com/endojs/endo/blob/master/packages/patterns/README.md)
and [exos](https://github.com/endojs/endo/blob/master/packages/exo/README.md)
that check arguments and results. Its exo documentation also exposes an
interface-query operation and warns that upgrades can invalidate cached
interfaces. Optional descriptions above capability transport therefore have
precedent. This does not make Endo's representation an OCapN convention.

## Credible alternatives

[Preserves Schema](https://preserves.gitlab.io/preserves/preserves-schema.html)
already specifies a data-description language, its structured representation,
and compilation into host-language types, parsers, and serializers. Its
embedded-value patterns can carry an interface schema, with actor references
as an explicitly experimental interpretation. This is more than copied-data
typing and deserves testing before adding grammar. Its compound patterns allow
extra fields by default. A replacement that borrows
its vocabulary must decide whether it preserves those semantics.

The [IDL reuse review](interface-idl-reuse.md) compares specific candidates
and compiler entry points. The choices below are design assessments, not
upstream recommendations.

| Approach | Benefit | Cost or limit |
| --- | --- | --- |
| Keep application-specific tables | Small investment and no new language | Shared applications still need adapters and handwritten checks |
| Declare interfaces in a host language | Familiar tooling and direct links to implementations | One language becomes the authoring environment, and portable data still needs a representation |
| Reuse Preserves Schema | Existing grammar, value semantics, and language projections | Capability ownership, calls, and Loam receipts still need a separate design |
| Build a custom interface language | Direct expression of glowcap application calls | glowcap owns another grammar, compiler, formatter, and compatibility policy |

A shared C validator keeps runtime interpretation in one implementation.
It also adds calls across the foreign interface and requires generated
programs to load the matching library. Generated checks avoid that runtime
dependency but distribute behavior across emitters. Neither choice removes
the need to test agreement across languages.

These alternatives can share an intermediate data form. The useful early
experiment is whether one such form produces a client and server that replace
real handwritten code without making reference ownership or failures harder
to understand. That result should precede a commitment to surface syntax.

## Consequences for glowcap

These are design judgments for glowcap, rather than attributed Spritely positions:

- Generated clients should remove repetitive encoding and check replies.
  A type or fingerprint must never certify authority, honesty, retry safety,
  or permission to perform an operation.
- Raw CapTP calls and objects without descriptions must remain usable.
  Generated code must not silently require a discovery exchange before a call.
- A namespaced method is convenient for method-based applications, but it
  remains an application convention. Compare it with a separate description
  capability before choosing a universal discovery mechanism.
- Code generation adds parser, compiler, distribution, and release costs.
  Prove one useful client/server pair before implementing a broad language
  and every binding.
- Check compatibility as a local programming aid. Structural agreement cannot
  prove unchanged meanings, effects, or behavior after a remote upgrade.

The evidence supports starting with reusable descriptions and a small
generated-client proof. It gives no reason to make discovery a prerequisite
for those benefits or for public use of glowcap.

## A candidate to test

The [complete language sketch](interface-language-example.md) exercises the
value model, methods and direct invocation, promises, callbacks, durable
references, and capability patterns. Its coverage table separates application
declarations, runtime operations, and optional Syrup or Loam profiles.
The syntax is a design input, not an implemented language or community decision.
