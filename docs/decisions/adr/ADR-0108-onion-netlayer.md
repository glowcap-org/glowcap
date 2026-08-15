---
id: ADR-0108
status: accepted
date: 2026-08-05
tags: [net, netlayer, onion, tor, transport, identity, goblins, interop]
decision: "pancake gains the `onion` netlayer, the one transport the OCapN draft standardizes, so a pancake peer and a real Goblins vat hold a session over Tor. It is a pure Zig resident that speaks SOCKS5 and the Tor control protocol to a Tor daemon the deployment already runs, with no sidecar and no spawned process. The service id is an address designator, not a durable key, because that is the only shape a Goblins onion peer can dial and be dialed by."
supersedes: []
superseded_by: []
amends: []
amended_by: []
---

# ADR-0108 The onion netlayer

> **Landing note.** The onion resident, provider archive, all four native
> bindings, and native `OnionLoop` ship. `zig build onion-interop` restores a
> service key in a fresh process, preserves its service id, and resolves a
> sturdyref minted before the restart. `zig build goblins-onion` holds live
> sessions with an unmodified Goblins onion netlayer in both directions. `zig
> build ocapn-conformance-onion` passes all 23 portable upstream tests plus the
> strict abort probe through the upstream onion netlayer. `zig build
> demo-rooms-onion` runs Rooms over one hosted onion service with two independent
> clients. Live Tor scale remains unmeasured; `docs/boundaries.md` owns that
> limit.
> Native Zig and every native binding also compose the onion provider into the
> generic driver and expose ordinary application-facing Sessions. The raw
> Netlayer remains the explicit embedding surface. The driver exposes opaque
> listener restoration bytes without naming Tor; only the onion package calls
> those bytes a service key.

## Context

`onion` is the only netlayer the OCapN draft actually specifies. Every other
transport in this tree, including the two production ones, is either pancake's
own or a convention. The draft's `Netlayers.md` names three things and nothing
else: the designator is "the Service ID that is provided when generating the
hidden service", the transport symbol is `onion`, and hints are unused. It then
fixes two constants, the virtual port `9045` and the key type `ED25519-V3`, and
says the implementation of the Tor network is out of scope for the document.

Upstream Spritely Goblins implements exactly that, and it ships only two
netlayers: `onion` and an in-process `fake` used by its tests. It ships no TCP
netlayer at all. The TCP and iroh netlayers this repository dials in its live
checks were both written here, in `conformance/goblins-peer/racket/`. So the one
transport where a Goblins vat and a pancake peer can meet on ground neither of
them invented is the one pancake does not implement.

pancake's URI parser already produces the right shape. It splits a locator's
host on the last dot, so `ocapn://<serviceid>.onion` yields the transport
`onion` and the designator `<serviceid>`, and `test/model/uri_test.zig` has
pinned that since before there was anything to dial. The gap is a netlayer, not
a locator.

This engages three First Principles. Conformance is load-bearing, and the OCapN
draft plus a live Goblins vat are the strongest external authority available for
a transport claim. The portable core stays sync and no-I/O, so everything here
lands in `net` and above. Performance is a public contract, and a Tor circuit is
slow enough that the timeouts and the connection budget are part of the design
rather than an afterthought.

### What the pinned Goblins source actually does

Every claim below is read off
`conformance/spritely-goblins/upstream/goblins/ocapn/netlayer/onion.rkt` and its
helper `onion-socks.rkt`, not inferred from the draft.

The netlayer reports its name as the symbol `onion`. Its own location is
`(ocapn-node 'onion service-id #f)`, where `service-id` is scraped verbatim out
of the Tor control reply `250-ServiceID=`. There is no second symbol:
`onion-socks.rkt` is a helper module holding a hand-written SOCKS5 client, never
a netlayer of its own.

Goblins does not manage a Tor process. It expects a daemon the operator already
started, and it talks to it over two Unix domain sockets whose default paths sit
under `~/.cache/goblins/tor/`. Its own documentation in
`goblins/scribblings/captp.scrbl` prints the `torrc` to use and notes that a
launcher "should probably" exist one day. On the control socket it sends a bare
`AUTHENTICATE` with no credentials, expects `250 OK`, and then sends
`ADD_ONION NEW:ED25519-V3 PORT=9045,unix:<path>`, parsing `250-ServiceID=` and
`250-PrivateKey=` out of the reply. The private key is an opaque string it hands
back to the caller to store, and `restore-onion-netlayer` feeds it to a later
`ADD_ONION` so the same service id comes back. Goblins never derives an onion
address and never touches the key material itself.

Outbound, it connects to the SOCKS socket and runs the handshake in
`onion-socks.rkt`. It offers version 5 with one method and no authentication.
It then sends a connect request with address type 3, a hard-coded length byte
of 62, the `<serviceid>.onion` text, and the port 9045 as a big-endian short. Its address
check is the regular expression for a version 3 address, fifty-five base32
characters followed by the letter `d`. Framing above the stream is raw Syrup
with no length prefix, through the same `read-write-procs` its other netlayers
use, so pancake's existing frame stream carries it unchanged.

Two details constrain the design directly. First, `connect-to` matches
`(ocapn-node 'onion designator #f)`, so a locator carrying any hints falls
through with no matching clause and the dial fails outright. Goblins's own URI
parser drops query parameters on the floor, so this is consistent rather than
accidental. Second, an inbound connection carries no client identity: the
listener accepts a local socket connection from Tor and passes a false remote
location to the connection establisher, because Tor hands a hidden service
nothing about who connected.

The CapTP layer above does not close that second gap either. Its
`op:start-session` check verifies that the claimed location was signed by the
key the same message carries, which is a fresh per-session key, so the claim is
self-signed and proves only that one message was assembled by one party. The
check that would compare the claim against a known location is commented out in
the pinned source, above a note that a dial back is still to be written.

The upstream OCapN test suite is a near line-for-line port of the same protocol,
in `conformance/ocapn-conformance/upstream/netlayers/onion.py`. It differs in one
respect: it launches its own Tor through the `stem` library rather than
expecting one to be running.

## Decision

pancake gains an `onion` netlayer resident that speaks SOCKS5 and the Tor control
protocol to a Tor daemon the deployment runs. There is no sidecar crate, no
spawned process, and no new dependency. It is an ordinary transport archive
installed by product composition, and `onion` becomes a first-class transport
beside `iroh`: documented, present in every binding, and covered by live
Goblins and upstream OCapN checks. The generic driver and binding loops do not
name it.

Five pieces carry it.

- **A Tor client in `net`.** `src/net/transport/onion/` owns two conversations.
  Outbound, a SOCKS5 connect to
  `<serviceid>.onion` on port 9045, written to match the bytes the pinned
  Goblins and the upstream suite both write. Inbound, the Tor control protocol
  over a line-oriented stream. That conversation authenticates, uses `ADD_ONION`
  to create or restore a version 3 service, and can use `SETEVENTS HS_DESC` so a
  caller waits for the descriptor to publish instead of sleeping. Closing the
  undetached control session withdraws the service. Both endpoints are
  configured, never guessed, and either may be a loopback address or a Unix
  socket path.
- **A netlayer resident over the ADR-0043 contract.**
  ([ADR-0043](ADR-0043-netlayer-contract.md)) The resident dials and accepts
  byte streams exactly as `net.tcp` does. Bytes reaching CapTP are the ordinary
  Syrup frame stream, so nothing above `net` learns a new shape. Tor forwards the
  service's virtual port to a local endpoint pancake binds, so the accept side
  reuses the existing socket path rather than inventing one.
- **Undetached service lifetime.** A listener owns the control connection that
  created its service. Releasing the listener closes that connection, which is
  Tor's withdrawal boundary for an undetached service. Destruction sends no
  `DEL_ONION` request and waits for no daemon reply.
- **A transport archive.** `libpancake_net_transport_onion` under
  `src/c_abi/net_transport/onion/`, exporting only its own `pancake_onion_*`
  symbol family and reusing `c_abi/shared` by layout, per
  [ADR-0059](ADR-0059-composable-c-abi-archives.md). Like every independently
  materialized transport provider archive, its build row is `.graph = false`
  and outside the layer DAG. It links no foreign code, so its checks ride the
  ordinary Zig build with no cargo on the path.
- **One product listener seam.** Native Zig and every native binding install
  the onion provider into the generic driver, read the driver-owned canonical
  locator, and accept ordinary Sessions. Provider-owned restoration state is a
  size-query/caller-buffer contract shared by every listener shape. It stays
  out of the locator and the generic driver never interprets it; the onion
  package alone presents those bytes as Tor's service key. The archive's raw
  frame handles remain for embedders that deliberately own the pump.

The raw Netlayer keeps an explicitly blocking listener constructor for
embedders that own that execution context. The generic provider starts Tor
control-plane setup on its operation owner and reports terminal
`LISTENER_READY` or `LISTENER_FAILED` events through the driver; no binding
event-loop thread performs that exchange. Accept and dial completion use the
same host-runtime progress model. Each high-level binding's onion module owns
one `listen` and one configured `connect`; both are asynchronous where they
perform I/O and return the same Server and Session roles as other transports.

The archive has the same source dependency posture as TCP: it imports `model`,
`net`, and `c_abi/shared`, never the `c_abi/ocapn` archive. Product composition
links the OCapN, driver, and selected provider archives.

### The locator

The symbol is `onion`. The designator is the version 3 service id, fifty-six
base32 characters, without the `.onion` suffix, which the URI already supplies
as the transport label. The virtual port is 9045 and the key type is
`ED25519-V3`, both fixed by the draft and neither exposed as a setting, because
a peer that changed either could no longer meet any other implementation.

**An onion locator pancake hands out carries no hints.** This is not a style
choice. The pinned Goblins `connect-to` matches a node whose hints are false, so
a hinted onion locator is undialable by the peer this record exists to reach.
Its `ocapn-node` contract admits only `#f` or a string where pancake writes a
dictionary, and `structs-urls.rkt` says in as many words that hints are not
supported. The URI projection, the handoff give's exporter locator, the
sturdyref form, and **the hello's own `acceptable_location`** all emit a bare
`ocapn://<serviceid>.onion`.

That last one is the case worth naming, because it is the one that costs
something. The profile hints in `model.transport` (`pancake/captp-version`,
`pancake/codec`, `pancake/features`) ride the locator a hello signs, and that is
the only place either end states a preference. Omitting them on onion means an
onion session settles the `1.0` baseline on every axis, **including between two
pancake peers**, and there is no second channel to recover it: a peer cannot know
its partner is pancake until the hellos have already been exchanged.

Sending them anyway would work against the pinned Goblins today, because its
unmarshaller builds the struct without the contract check and its one comparison,
`same-node-location?`, ignores hints outright. It would break the moment upstream
writes the dial back its own source says is still to come, since that path dials
the claimed location and `connect-to` refuses hints. A hazard that fires later,
remotely, on somebody else's release is worse than a profile pancake does not
need over this transport: onion exists here to reach Goblins, and two pancake
peers that want `pancake-next` have `iroh`.

A designator that is not a well-formed version 3 address is refused before any
socket is opened. Version 2 addresses are gone from the Tor network and pancake
does not accept their shape.

### Reaching Tor: a daemon the deployment runs

pancake talks to an existing Tor over its SOCKS and control endpoints. It does
not embed Tor, does not spawn one, and does not supervise one. A netlayer
constructed against endpoints nothing is listening on fails loudly at
construction rather than at the first dial.

This is the "no hidden runtime" principle applied literally. A background daemon
pancake started, kept alive, and restarted would be a runtime the library owns
and the application cannot see. A daemon the deployment configures is the
opposite: it is named in the config struct, its lifetime belongs to whoever
started it, and its absence is an error the caller reads.

It is also what makes the Goblins check possible at all. Goblins and the pinned
suite both speak this exact protocol to the same kind of daemon, so one Tor on
one machine serves a pancake peer and a Goblins vat at once, and the two meet on
the live network with no shim between them.

Control authentication supports the three forms a real `torrc` produces: none,
which is what Goblins assumes and what a Unix control socket with no
authentication gives; a cookie file, read and sent as hexadecimal; and a
password. Cookie authentication is the common default on a distribution package,
so leaving it out would mean the netlayer worked only against a hand-configured
daemon.

Creating a service is an effect on shared state, so it is explicit. A netlayer
given no control endpoint can dial and cannot host, which is the correct posture
for a client that only reaches out. A netlayer given a stored service key
restores that exact service, so an onion address is durable across a restart and
a sturdyref minted before the restart still resolves.

### What an onion connection proves

This is the part worth getting exactly right, because a `.onion` address is a
public key and it is tempting to conclude more from that than is true.

Five facts, then the verdict.

1. A version 3 onion address is the base32 encoding of a 32-byte Ed25519 public
   key, a two-byte checksum, and a one-byte version. The key is recoverable from
   the address by anyone.
2. Tor authenticates the service to the client. The client derives the identity
   key from the address, verifies the service's signed descriptor against it, and
   completes a handshake bound to that key. A successful connection to an address
   did reach a party holding the corresponding secret.
3. Tor authenticates nothing about the client. A hidden service learns no client
   identity, which is the whole point of the network. Version 3 client
   authorization exists and would change this; it is a separate deployment
   mechanism and is out of scope below.
4. pancake does not perform step 2 itself. It asks the local Tor to connect and
   reads a success reply, so the proof is delegated to that daemon and to the
   socket reaching it. iroh's node id proof is delegated too, to the crate inside
   the sidecar. The difference is a process boundary rather than a library
   boundary, so the trust base includes how the daemon was configured.
5. The key names the rendezvous service. The CapTP peer is whoever holds the
   local endpoint that service forwards its virtual port to. On an ordinary
   single-operator host those are the same party, and nothing in the protocol
   makes them the same party.

**The verdict, in the vocabulary of
[ADR-0105](ADR-0105-connection-scoped-durable-authentication.md).**

`designatorSchemeForTransport` answers `address` for `onion`. The service id says
where to dial, not who the peer is, which is what the draft says, what Goblins
does, and what fact 5 supports. So a dial installs no demand on the partner's
claim, and the four-clause rule at the pre-open chokepoint reaches its first
arm: a claim that does not decode as a key, with no demand standing, passes and
records nothing.

The resident asserts no verified channel key. It could: fact 1 makes the key
recoverable and fact 2 makes the assertion true about the far end of the byte
channel, which is precisely what ADR-0105's channel slot holds. It does not,
because that slot has exactly one reader, the comparison against the partner's
own claim, and an onion hello claims a service id in an encoding the key decoder
does not accept. Binding the key would add a true fact with no reader, and the
described-versus-built rule says not to ship a mechanism whose only description
is its own header.

`partnerDurableProvenance` therefore answers `unauthenticated` for every onion
session, including a pancake pair. The current provenance type accepts the
Ed25519 key form used by iroh and WebRTC, not an Onion service id. An onion
session thus has unreported Tor service authentication over a strongly
encrypted and anonymized channel.

**Where the strength does surface.** `matchSturdyrefPeer` takes its address arm
for `onion`, and on a session pancake dialed it compares the sturdyref's
designator against the address it asked for and answers `dial_target`. On `tcp`
that answer means the operating system routed the connection somewhere. On
`onion` it means Tor's rendezvous handshake proved the far end holds the key the
address encodes. Same arm, a much stronger fact, and the strength lives in the
transport rather than in the enumeration. On an accepted session the arm answers
`assertion_only` under the assertion-only policy, which is the honest report of
fact 3.

**Why not make it a key transport.** The Onion service id is not pancake's
Ed25519 key designator format. Treating it as one would conflate two identity
grammars and still would not authenticate an inbound client's self-declared
Onion location. The resident can expose Tor's service proof through a distinct
typed channel fact when policy needs it; no CapTP hint is required.

**The inbound claim is unverified, and that is a finding, not a secret.** Any
party can open a circuit to a pancake onion service and claim any onion
designator in its hello. Goblins has the identical hole, and its own source
carries the note that a dial back is still to be written. The migration order
records it under `conformance/ocapn-findings/`, beside the other pinned-source
discrepancies, so a reader meets it where the other ones live.

### The endpoint config

The transport takes one configuration struct, passed by pointer, following the
shape the iroh endpoint config established. The caller zero-initializes the whole
struct and fills the fields it sets, so a field added later reads as zero rather
than as stack contents. The meaning of every field is documented once, on the
`PancakeOnionConfig` declaration in `src/c_abi/net_transport/onion/mod.zig`, and
the resident and all four bindings mirror the struct and point at that one place.

Present from the first version:

- The SOCKS endpoint, as text: a loopback address and port, or a Unix socket
  path. Required, because a netlayer that cannot dial is not a netlayer.
- The control endpoint, in the same two forms. Empty means dial-only, and any
  attempt to host is refused rather than silently ignored.
- The control authentication kind and its secret: none, a cookie file path, or a
  password.
- The service key to restore, in the exact form the control protocol returned
  it. Empty asks for a fresh service.
- The local endpoint Tor forwards the virtual port to. Empty means pancake binds
  a loopback port and reports it.
- A connect budget in milliseconds, with zero meaning the built-in default. A Tor
  circuit takes seconds to tens of seconds, so this default is far larger than a
  TCP one and a caller that assumes TCP timings will set it wrong.
- A descriptor publication budget in milliseconds, with zero meaning do not
  wait. Creating a service returns before the network can find it, so a caller
  that publishes an address and expects an immediate dial needs this.

Deliberately absent, each for a stated reason. The virtual port and the key type
are fixed by the draft, so a setting could only produce peers unable to meet. An
idle timeout is not needed, because a Tor stream is carried over a socket that
reports end of stream, unlike the QUIC case the iroh config documents. SOCKS
credentials for per-circuit stream isolation are a real privacy control and are
scoped out below rather than half-built. Spawning or supervising Tor is refused
on principle above.

## Scope (what this does not decide)

- **pancake does not run Tor.** No embedded implementation, no spawned process,
  no supervision, and no bundled binary. A deployment without a Tor daemon has no
  onion transport.
- **Version 3 client authorization is not implemented.** It is the mechanism
  that would give a hidden service a client identity and close the unverified
  inbound claim. It needs key distribution, control-protocol verbs, and a
  decision about how a locator carries a client credential, none of which this
  record settles.
- **SOCKS stream isolation is not implemented.** Distinct SOCKS credentials per
  circuit are a privacy control with its own design, and no setting for them
  exists here.
- **Profile negotiation over onion is given up, not deferred.** Every onion
  session settles the `1.0` baseline, because the hints that would state a
  preference cannot ride an onion locator. Raising it needs a channel for the
  preference that is not the locator, which is new wire surface and a separate
  record.
- **An onion locator that also names a durable key is not decided.** A pancake
  pair over Tor could in principle carry a durable identity in a hint and attest
  it, which would raise provenance above unauthenticated. That is new wire
  surface, the pinned Goblins refuses hints on its dial path, and this record
  does not open it.
- **No sealed channel over onion.** [ADR-0107](ADR-0107-sealed-byte-channel.md)
  defines an end-to-end sealed layer under CapTP with its own symbols. Tor
  already encrypts the path, so onion does not need it for confidentiality, and
  extending those symbols to onion is a separate decision. The two records are
  orthogonal: ADR-0107 proves the partner over a pipe you do not trust, onion
  hides and encrypts the path and proves the service.
- **No onion-specific handoff shape.** A three-party handoff over onion uses the
  ordinary give and withdrawal, with the exporter locator carrying a bare onion
  address. Nothing about the descriptors changes.
- **No anonymity claim about pancake itself.** Tor hides network location. It
  does nothing about what an application puts in a message, about traffic volume
  and timing, or about a peer that reveals itself at the capability layer.

## Alternatives Considered

- **An Arti sidecar, following the iroh and WebRTC pattern.** Arti is the Tor
  Project's Rust implementation, and a sidecar crate behind a narrow C ABI is a
  shape this tree has built twice. Rejected for now on three counts. It puts
  cargo on the path of a transport that otherwise needs none, so the archive
  would leave the layer graph exactly as the iroh and WebRTC ones did. It bundles
  a second Tor into a host that usually already runs one, and running two clients
  on one machine is worse for the network and for the operator. Its onion service
  hosting is much younger than its client support, and hosting is half of what
  this netlayer needs. The flip condition, in the shape ADR-0055 established: if
  a deployment must have onion with no external daemon, and Arti's service
  hosting is stable, an Arti sidecar behind this same resident contract is the
  answer, and nothing above `net` changes.
- **Spawn and supervise a Tor process, as the upstream OCapN suite does with
  `stem`.** Rejected: it is a hidden runtime, it makes pancake responsible for a
  daemon's lifetime and log, and it hands a library the job of writing a
  `torrc`. The suite is a test harness and can afford it; a library cannot.
- **Dial only, with no control protocol.** Rejected: an onion locator names a
  service, so a peer that cannot host one can only ever be a client. That is not
  equal footing with iroh, and it cannot answer a handoff give.
- **Make `onion` a key-designator transport.** Rejected in the verdict above: it
  refuses every Goblins onion peer that dials in, which is half the interoperation
  this record is for.
- **Add a fourth `DurableProvenance` value meaning the transport proved the
  address.** Rejected: provenance is one ordered derivation in one function
  against the partner's claim, and a value for a fact the claim cannot carry
  would put a second authority beside it. ADR-0105 argued this and it still
  holds.
- **Let `matchSturdyrefPeer` take its key arm for onion by treating the service
  id as the peer key.** Rejected: that arm requires an authenticated durable
  identity, which onion does not supply, so it would refuse every onion
  sturdyref, including the one the draft uses as its own example.
- **Make the virtual port configurable.** Rejected: 9045 is normative, and a
  setting produces only peers that cannot find each other.
- **Reuse pancake's node key as the onion service key, so one key is the
  address and the signing identity.** This is what ADR-0055 did for iroh, and it
  is tempting. Rejected: it forbids reusing a service key an operator already
  has, and it changes no verdict anyway, because the claim on the wire is still
  an address the key decoder does not accept.

## Evidence

The byte, control, identity, provider, and completion checks use fake daemons
and need no network. The interoperation, upstream, and Rooms proofs use live Tor
and remain opt-in, the same split `iroh-reachability` carries.

1. **The SOCKS bytes match the peers pancake must meet.** An in-tree fake proxy
   asserts the exact request: version 5 with one method and no authentication,
   then connect with address type 3, a length of 62, the `<serviceid>.onion`
   text, and 9045 as a big-endian short. Compared against `onion-socks.rkt` and
   the suite's own client, byte for byte, not by shape.
2. **The control exchange matches.** A fake control endpoint asserts the
   authenticate step in all three forms, the create and the restore `ADD_ONION`
   requests, and the parsing of the service id and key out of the reply.
3. **An onion locator pancake emits carries no hints.** Asserted on all four
   forms — the projected URI, the give's exporter locator, the sturdyref, and the
   hello's `acceptable_location` — because the pinned Goblins dial path refuses
   anything else. The `acceptable_location` case carries its own assertion that
   no profile hint rides an onion hello, so a later change that adds one to
   recover `pancake-next` fails here and has to re-read the reasoning first.
4. **A restored service keeps its address.** `zig build onion-interop` passes
   the stored key to a fresh child process, observes the same service id, then
   fetches and calls an object through a sturdyref recorded before the restart.
5. **Two pancake peers hold a session over real Tor**, through the handshake to
   an open session and a bootstrap fetch round trip.
6. **A real Goblins vat and a pancake peer hold a session over Tor, in both
   directions**, with the Goblins side running unmodified upstream `onion.rkt`
   and both sides sharing one daemon. This is the item the record exists for, and
   the direction that matters most is the Goblins vat dialing pancake, because
   that is the one an identity decision could quietly have broken.
7. **The upstream OCapN suite runs against a pancake onion peer** through its
   own onion netlayer. `zig build ocapn-conformance-onion` passes all 23
   portable tests and the separate strict abort probe for invalid signatures,
   invalid versions, and pre-setup abort connection closure. The harness waits
   for the upstream service to be reachable before advertising it because the
   upstream `ADD_ONION` path returns before descriptor publication.
8. **The identity verdict is asserted, not assumed.** One scenario reports
   unauthenticated provenance on an onion session and a dial-target sturdyref
   match on a session pancake dialed, so a later change that quietly promotes
   either one fails.
9. **The completion and application paths use the same provider.** `zig build
   onion-loop` covers the native completion adapter, `zig build bindings-onion`
   covers provider installation from every native binding, and `zig build
   demo-rooms-onion` runs the Rooms application over one onion service with two
   independent peers.

## Adversarial review

Five objections, each answered in the design rather than in prose.

**"A `.onion` address is a public key, so calling it an address throws away a
proof."** The key is real and the proof is real, and both are about the
rendezvous service rather than the CapTP peer. The design keeps the proof where
it is read, in the sturdyref dial-target arm, and declines to bind it into a slot
whose only reader compares it against a claim that cannot match. Fact 5 in the
verdict is the honest limit: the peer is whoever holds the forwarded endpoint.
This objection is the strongest one, and the answer is a narrower claim, not a
denial.

**"Depending on an external daemon is a hidden runtime wearing a different
coat."** It is the opposite. pancake starts nothing, keeps nothing alive, and
names both endpoints in a config struct the caller fills. A missing daemon is an
error at construction. What would be hidden is the version that spawns Tor
quietly and manages it, which is exactly the alternative this record rejects.

**"The accept side accepts anybody claiming any onion address."** True, and
stated rather than buried. It is Tor's shape, the pinned Goblins carries the same
hole with its own note about the dial back it has not written, and the mechanism
that closes it is client authorization, which is scoped out. The record files it
as a finding so it is discoverable where the other pinned-source discrepancies
are.

**"Two different facts under one `dial_target` answer is the missing-dimension
problem this project keeps paying for."** Fair, and worth naming. The arm reports
what the session did, and the strength of that fact is a property of the
transport, which the transport tables state. Adding a dimension when nothing
branches on it would be a value with no reader, the same objection this record
makes against binding a channel key. The moment a consumer needs to branch, that
is when the dimension is added, and this sentence is the record that it was
considered.

**"An interoperation check that needs the live Tor network is not a check."**
Which is why the evidence splits. The protocol bytes, the control exchange, and
the no-hints projection are asserted in-tree against a fake daemon and ride the
ordinary gate with no network. The live items are opt-in and named as such, the
same posture `iroh-reachability` has held since ADR-0055.

## Consequences

- `net` gains a Unix-stream endpoint arm it does not have today, which the SOCKS
  and control clients both need, and which a Unix forward target would also use.
- The archive set gains `libpancake_net_transport_onion` with the same source
  dependency posture as TCP. Like every transport provider archive, it remains
  outside the layer DAG and is installed into a transport-empty generic driver
  by product composition. It links no foreign code.
- `zig build check` grows a header check and the fake-daemon check, and still
  needs no network, no Tor, and no cargo.
- An onion session runs the `1.0` profile in both directions, so `onion` is the
  one transport in the tree over which two pancake peers cannot reach
  `pancake-next`. `docs/boundaries.md` carries the row.
- Each binding gains a config mirror, a high-level Session listener, and a
  generated FFI row, held by the existing `gen-binding-*` checks.
- The transport tables in the architecture rule, `site/content/transports.smd`,
  and `docs/boundaries.md` gain a row. Its peer proof is Tor's rendezvous
  handshake on the dialing side and nothing on the accepting side, its channel is
  an encrypted and anonymized Tor circuit, and its verdict is production with a
  Tor daemon the deployment runs.
- `conformance/ocapn-findings/` gains a record for the unverified inbound claim
  in the pinned Goblins and in this netlayer.
- A live Goblins check exists for the one netlayer neither implementation
  invented, which is the strongest interoperation evidence this tree can hold for
  a transport.

## Notes

- [ADR-0043](ADR-0043-netlayer-contract.md) owns the resident contract this
  implements, unchanged.
- [ADR-0055](ADR-0055-iroh-netlayer-sidecar.md) is the template for a transport
  that reaches an external stack, and the source of the flip condition recorded
  in Alternatives. This record takes the opposite branch of the same question,
  because Tor's reference implementation is a daemon rather than a library.
- [ADR-0059](ADR-0059-composable-c-abi-archives.md) governs the archive, its
  header, and its symbol family.
- [ADR-0089](ADR-0089-webrtc-datachannel-netlayer.md) is the most recent
  transport record and the structural model followed here.
- [ADR-0105](ADR-0105-connection-scoped-durable-authentication.md) supplies the
  vocabulary the identity verdict is written in, and is not amended: onion
  reaches its first clause and its address arm without a carve-out, which is the
  point.
- [ADR-0098](ADR-0098-sturdyref-peer-authority.md) owns the sturdyref peer match
  whose address arm carries what Tor proved.
- [ADR-0107](ADR-0107-sealed-byte-channel.md) is orthogonal, as the Scope
  section states.
