# Multi-home shape comparison

Status: historical — the comparison is complete and ADR-0125 records its result.

This is the measurement required by
[ADR-0119](../decisions/adr/ADR-0119-multihome-comparison-protocol.md). It
compares the two shapes against the same question: can one durable peer remain
reachable through several changing transports without weakening identity or
the OCapN 1.0 compatibility floor?

## Result

The keyed `id/via` shape is the product contract. The `pancake/locations`
counter-proposal is retired before release.

The deciding difference is authority, not syntax. An `id` locator names one
durable public key and admits only `via` routes whose channels can prove that
key. It can therefore drive a dial, key the same-peer cache, and support a
transport-independent sturdyref. A list attached to an ordinary locator has no
fact that proves its entries name one peer. Making that list functional would
either trust unauthenticated advice or add an identity field, at which point it
has reconstructed the `id` shape less directly.

## Equal measurement

| Surface | `id/via` identity route | `pancake/locations` locator list |
| --- | --- | --- |
| Peer identity | Outer designator is the durable key; every strong route must prove it | Primary locator remains the identity; no rule proves the listed locators name it |
| Dial behavior | Materializes bounded routes and drives Node pending dials | Added no dial paths; deliberately ignored by the dial planner |
| Sturdyrefs | Reuses an authenticated same-key session or dials the strong routes | Had to be refused because the list supplied no identity proof |
| Handoff | Preserved after bilateral negotiation; lowered to one compatible route for a baseline recipient | Could be carried only as inert data and stripped for a baseline recipient |
| Session state | One negotiated `multi_location` bit admits the private identity-route vocabulary | Used the same bit but added a second hint-name branch to validation |
| Model and codecs | Generic locator records plus one transport-local `via` parser; no new record arm | Generic locator records plus special detection of one otherwise ordinary hint |
| Bindings | Generic locator and feature surfaces already carry the shape; no binding owns route semantics | The same generic surfaces carried bytes, but no binding could use them to connect |
| Compatibility | First-hello silence, bilateral feature admission, signed-give lowering, and unchanged Goblins checks | The same gates proved only that inert data did not leak |
| Product evidence | Core Host sturdyref scenarios and live Rooms directory peering | No product consumer and no successful multi-route scenario |

The shared cost is the feature negotiation and compatibility boundary. The
identity-route-specific cost is justified by usable behavior: bounded parsing,
same-key validation, pending-dial scheduling, lowering, and durable-reference
selection. The comparison-list-specific cost bought no behavior and made every
reader carry a second vocabulary whose security semantics could not be stated.

## Consequence

[ADR-0125](../decisions/adr/ADR-0125-identity-route-multihome.md) records the
choice. `multi_location` remains the negotiated feature name because it names
the capability being admitted, while `id` and its transport-local `via` hint
are the one wire shape behind that gate. Unknown locator hints remain ordinary
OCapN hints; pancake assigns no meaning to the retired comparison name.

This result does not claim upstream agreement. The shape remains a
`pancake-next` extension, is never sent to a baseline or Goblins session, and
must converge on any future OCapN specification before its names can be called
interoperable.
