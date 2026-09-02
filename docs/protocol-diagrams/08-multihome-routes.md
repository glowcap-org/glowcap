# Multi-home routes `[glowcap-next]`

Anchors: [ADR-0125](../decisions/adr/ADR-0125-identity-route-multihome.md);
OCapN Locators and Netlayers specifications (which define the single-location
baseline these diagrams extend); [upstream watch](../upstream-watch.md) for the
extension's standing. Nothing on this page is pinned-draft behavior: every
flow is gated behind `glowcap-next` negotiation, and a baseline or Goblins
session never sees this vocabulary.

## MH-1: The `id` locator

An `id` locator names a peer by a durable public key instead of by one
transport address. Routes live in hints, which the Netlayers draft already
excludes from peer identity. `via` carries the ordered routes that must prove
the outer key; `alt-locators` carries weak fallbacks that redeem a signed gift
without ever establishing the identity. Route URIs are percent-encoded inside
the hint value and separated by `|`, with the count and byte size bounded
before any allocation.

```mermaid
flowchart TD
    ID["ocapn://durable-key.id"] --> DK["designator: the peer's durable public key"]
    ID --> VIA["via hint: ordered routes"]
    ID --> ALT["alt-locators hint: weak fallbacks"]
    VIA --> R1["ocapn://key.iroh"]
    VIA --> R2["ocapn://key.noise-relay"]
    ALT --> R3["ocapn://host:port.tcp"]
    R1 --> P1["channel must prove the outer key"]
    R2 --> P1
    R3 --> P2["redeems the authorizing gift only, never proves or caches the identity"]
```

A route under `via` is admitted only when its transport can prove a durable
key on its own channel (an encrypted peer-id handshake, a sealed Noise
channel, or an authorized signaling exchange) and its designator names the
same key as the outer `id`. A cleartext keyed route is refused there, because
its key is only a dial target.

## MH-2: Negotiating the vocabulary

Route vocabulary is a named `glowcap-next` feature. A first hello carries
none of it, because the sender does not yet know what the partner accepts.
Only after both signed hellos advertise the feature does the settled session
admit it; a hello that carries an `id` route outside such an offer is malformed.

```mermaid
sequenceDiagram
    participant A as Peer A
    participant B as Peer B
    A->>B: op:start-session (signed hello offering glowcap-next + multi_location, no route vocabulary)
    B->>A: op:start-session (signed hello offering glowcap-next + multi_location)
    Note over A,B: both advertised the feature, so the settled session admits route vocabulary
    A->>B: op:deliver carrying route vocabulary (an id exporter location inside a signed give)
    Note over A,B: had either hello omitted the feature, the session settles<br/>on the baseline profile and this payload is refused before send
```

## MH-3: Lowering a signed give

A signed give crosses two sessions: the exporter's and the recipient's. Route
vocabulary survives only in their intersection. A recipient that did not
negotiate it receives one concrete route on a transport it demonstrably
participates in, or the give is refused; it is never handed experimental
vocabulary to ignore.

```mermaid
flowchart TD
    G["outbound give whose exporter location is an id bundle"] --> RN{"recipient session negotiated route vocabulary?"}
    RN -->|yes| EN{"exporter session negotiated it too?"}
    RN -->|no| LW["lower to the first route the recipient can dial"]
    EN -->|yes| FULL["send the id bundle intact"]
    EN -->|no| CONC["fall back to the concrete location the exporter claimed on its session"]
    LW --> OK{"a compatible concrete route exists?"}
    OK -->|yes| ONE["send that one baseline locator, private vocabulary stripped"]
    OK -->|no| RF["refuse the give before send"]
```

## MH-4: Dialing an `id` bundle

No physical `id` session exists. The generic dial planner refuses the symbol;
only the pending-dial expansion resolves it into concrete routes. Source order
is the explicit rank: Node races at most the first two strong routes, refills
that bounded window in order, and accepts the first proved completion. It
cancels every still-running loser. Weak fallbacks begin one at a time only
after every strong route fails. A weak fallback may complete the withdrawal
its signed gift authorized, and nothing more.

```mermaid
sequenceDiagram
    participant N as Dialing peer
    participant R1 as via rank 0 (key-proving)
    participant R2 as via rank 1 (key-proving)
    participant W as alt-locator (weak fallback)
    Note over N: stages the dial for a signed gift's withdrawal,<br/>via routes ordered before the weak fallbacks
    N->>R1: dial in bounded strong window
    N->>R2: dial in bounded strong window
    R2--xN: dial fails (unreachable)
    R1--xN: dial fails (unreachable)
    N->>W: dial the first weak fallback
    W->>N: session established, key unproven
    Note over N: the gift withdraws over this session,<br/>but the id identity is neither established nor cached
    Note over N: a later dial that completes a key-proving channel<br/>is what records the identity as canonical
```

## MH-5: Enlivening an `id` sturdyref

An `id` sturdyref is honored only by a Host that opted into the feature. It
reuses any session whose channel already authenticated the same key,
including a baseline session, because no route syntax crosses that
established channel. Otherwise the concrete `via` routes are staged as in
MH-4.

```mermaid
flowchart TD
    EN["enliven ocapn://key.id/s/swiss"] --> OPT{"Host opted into glowcap-next multi_location?"}
    OPT -->|no| RF1["refuse"]
    OPT -->|yes| AS{"an authenticated session already proves this key?"}
    AS -->|yes| RE["fetch over that session"]
    AS -->|no| ST["stage the concrete via routes for dialing"]
    ST --> PR["first route whose channel proves the key carries the fetch"]
```
