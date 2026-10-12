# Rooms work admission

Living-state surface. Rooms refuses repeated work before launching its effect.
An authenticated peer keeps the same allowance after reconnecting. A shared
session charges the calling grant, every ancestor and its session pool together.
Direct inboxes protect their own receiving work. HTTP applies a deployment
allowance and can additionally limit the actual socket source address.

These are process-local token buckets. Restarting a process resets its debt.
Replicas have independent allowances. Admission does not replace capability
authority, room capacity, payload ceilings, queue limits or transport flow
control. Rotating authenticated keys can evade an individual allowance, so
HTTP starts, recipient pools and bounded retained state remain necessary.

## Configuration

All services use the typed profile in
[`admission.rs`](../../apps/rooms/rust/application/src/admission.rs).
Startup prints its effective rates, row cap, aggregate multiplier and the
source of each override. Arguments take precedence over environment values.

| Setting | Meaning |
| --- | --- |
| `admission-scale` | Multiply every default rate by 1 through 100. |
| `admission-rates` | Comma-separated absolute `class=burst/per-minute` overrides, applied after scaling. |
| `admission-rows` | Maximum retained accounting rows, 1 through 65,536. |
| `admission-aggregate-scale` | Multiply the individual profile for aggregate pools by 1 through 100. |

Rates must be positive unsigned 32-bit integers. Burst cannot exceed sustained
allowance, so a full burst can refill within one minute. Duplicate or unknown
classes, arithmetic overflow and invalid values refuse startup. Empty environment
values select defaults. Changing a profile requires restarting its owner.

The directory uses `--admission-*` arguments and
`GLOWCAP_ROOMS_ADMISSION_*` environment variables. The session uses the same
arguments and `GLOWCAP_ROOMS_SESSION_ADMISSION_*`. HTTP uses
`--http-admission-*` and `GLOWCAP_ROOMS_HTTP_ADMISSION_*`.
The web front configures browser-local sessions with `--browser-admission-*`
and `GLOWCAP_ROOMS_BROWSER_ADMISSION_*`. These settings travel with the served
page and apply when its local application opens.
For example:

```sh
glowcap apps rooms directory serve --admission-rates=message=20/80,room-join=5/10
glowcap apps rooms session serve --dir=./rooms-session --admission-scale=2 --admission-rows=4096
```

HTTP also accepts `--http-admission-per-address=true|false`, or
`GLOWCAP_ROOMS_HTTP_ADMISSION_PER_ADDRESS`. It defaults to false. Only the actual
socket address supplies this key. Forwarded headers never select allowance.
Behind a proxy, the socket address identifies the proxy and may group unrelated
people. Configure this option only when that grouping is intended.

Default row caps are 8,192 for the directory, 4,096 for the managed session and
2,048 for HTTP. Session and HTTP aggregate pools use an eightfold multiplier.
The directory's unproved-start envelope uses its aggregate setting. Its ordinary
proved data operations use individual and recipient limits.

### Deployment

Put durable operator choices in `docker-compose.override.yml` inside the
[deployment configuration directory](../../apps/rooms/web/deploy/README.md):

```yaml
services:
  directory:
    environment:
      GLOWCAP_ROOMS_ADMISSION_RATES: message=20/80,room-join=5/10
      GLOWCAP_ROOMS_HTTP_ADMISSION_ROWS: "2048"
      GLOWCAP_ROOMS_BROWSER_ADMISSION_RATES: message=20/80
  session:
    environment:
      GLOWCAP_ROOMS_SESSION_ADMISSION_SCALE: "2"
```

Run `glowcap apps rooms deployment up` to apply it. The tracked deployment
template passes every admission environment setting to its owning process.
Checkout development accepts the same environment values through `rooms-dev`.
Library users pass `Settings` at initialization. Browser embeddings pass a JSON
string as the optional third `RoomsManagedApplication` constructor argument,
for example `JSON.stringify({"admission-rates":"message=20/80"})`.
An attached session uses its server's profile. Page settings cannot change it.

The upstream directory sees an attached shared session as one authenticated
peer. Its allowance is independent of the session's collaborator and aggregate
pools. Tune both owners for the expected shared workload. Raising a local grant
allowance does not reserve upstream service capacity.

The default message allowance is a burst of 32 operations with 120 per minute.
Introductions allow 8 with 12 per minute, and upload starts allow 32 with 64 per
minute. These cover the native mixed room/DM journey and the browser's full
eight-file posts and attachment edits without special test overrides. A command
spends once at receipt admission. Its private continuation rechecks authority
without another debit. Separately held capabilities still spend the grants
guarding them, including a recipient's shared-session projections. An
introduction's readiness lookup also reaches the directory, so work counts need
not equal visible clicks. Byte and recipient limits remain independent.

## Effect and attribution inventory

Paths below are relative to `apps/rooms/rust/`. Protocol constants at each
dispatch owner define the accepted verb set, including extended post variants.
Unknown or malformed data calls still encounter ingress or existing Host input
bounds. A quota key never establishes authority.

| External surface and verbs | Subject and admission owner | Effect boundary |
| --- | --- | --- |
| Directory list, lookup, watch, location and room links | Proved calling peer, or live unproved connection. `services/src/server/behavior.rs` | Before result construction and watcher retention. |
| Register, offer inbox, open and open managed | Calling peer. Root registration/creation classes | Before actors, durable authority submission and handoff worker launch. |
| Native entrance subscribe and public publication subscribe | Calling peer plus exact room generation. `services/src/server/rooms.rs` and `services/src/server/rooms/public_membership.rs` | Before seat creation or foreign subscription launch. |
| Room posts, edits, refiles and topic changes | Current caller of the bearer facet. `services/src/server/seat.rs`, `services/src/server/lines.rs`, `services/src/server/files.rs` | Count and scalar bytes admitted together before broadcast or storage mutation. |
| History, membership queries and invitation claim/mint | Current caller. Seat, entrance and invitation owners | Before encoding, actor issuance and claim. |
| Typing and away | Current caller plus room generation. Membership owner | Identical state coalesces before atomic `transient` and `room-transient` debit. Typing has a renewable expiry. |
| Introduce and request direct | Calling registered peer and actual recipient. Directory owner | Mint requests spend opening and recipient allowance before notification. Retrieving an exact offered inbox spends read allowance. Repeated request-direct notifications coalesce. |
| Signaling offer, inbox, answer and candidate | Current caller, with recipient charge on offer. `services/src/server/signaling.rs` | Before retaining or forwarding signaling. A handed name facet still charges its current caller. |
| Attachment starts, chunk reads/writes | Current caller. `services/src/server/files.rs` | Before reservation, byte copy or async waiting read. Existing chunk and file caps bound bytes. |
| Bootstrap, manager and moderator facets | Current caller with separate capability checks. `services/src/server/authority.rs` | Before durable authority work. Revocations and kick spend cleanup allowance. |
| IRC entrances, seats and invitations | Current calling peer. `services/src/server/irc/` | Before subscription, IRC worker launch and post. IRC payload and gateway capacity remain separate. |
| Shared commands, uploads, reads and dependent forwarding | Validated grant lineage plus session pool. `runtime/src/session/managed/admission.rs` | Before command receipt/worker admission or forwarding a public held target. Private command/upload/bridge continuations recheck authority without spending the admitted gesture twice. |
| Incoming direct callbacks and line updates | Proved channel sender plus receiving session pool. `runtime/src/session/managed/incoming.rs` | Before copying input across the callback worker wait. No directory is on this payload path. |
| Relay upgrades, preview fetch and refresh | HTTP deployment, optionally actual socket address. `services/src/web/admission.rs` | Before worker launch and remote fetch. Cache hits need no new fetch allowance. |
| Rendezvous registrations and claims | Destination identity with aggregate registration capacity. `web/rendezvous.rs` | Claim debt survives unregister/re-register until full refill. |
| Leave, unwatch, discard, withdraw, close and revocation | Exact capability/source plus independent cleanup allowance | No data quota wait. Internal authority release and admitted receipt settlement retain their existing owner. |
| Operator capabilities and Loam access controls | Separately held management authority | Existing bounded operator/authority queues and Host limits provide reserved custody. Data admission confers no management rights. |

## Refusal and recovery

`rate-limited` carries validated `retry-after-ms` and `scope`. Refusal
diagnostics also identify their admission owner: `directory`, `session`,
`direct-inbox` or `http`. The delay is the earliest estimate assuming no
intervening use, not a reservation. `admission-busy` means the bounded
accounting table cannot safely retain another subject and provides no invented
retry delay. `request-too-large` means the request exceeds one configured burst.
HTTP answers 429, 503 or 413 respectively, with `Retry-After` only when a delay
exists.

Browser joins show refusal beside the form or affected sidebar target. Post
refusals stay beside the composer. Drafts and attachments remain owned by the
original gesture. Cooldowns enable a new explicit action when they expire and
schedule no future post. Repeated clicks do not extend the deadline.

Membership recovery has one worker per exact selection. It honors validated
advice with a small per-worker spread for at most one minute of automatic
waiting, with at least one second between attempts. Cancel interrupts that wait.
After exhaustion, an explicit activity retry resumes failed retained workers.
Ordinary workspace changes cannot renew the window. The page also permits
leaving and rejoining as a new explicit gesture. The existing source and receipt
checks still govern dispatch, uncertainty, replay and retirement. Confirmed current
standing ends its recovery incident. A later refusal gets a fresh finite window.
An unsent standing update follows the latest persisted preference after cooldown,
so an obsolete refused value cannot apply first. A validated refusal
retains its reason in an unsent receipt. Host refusal before target admission
also retains its diagnostic as known absence. Unknown observations keep their
distinct client type and cannot become safe-to-resend advice. Uploads confirm staged-file discard
before claiming absence. Failed compensation keeps an uncertain receipt.

The native CLI also retires a confirmed refused admission's local observation
without looking for a receipt that was never created. Lost admission or result
observations retain their exact request. If local retirement fails, its error
keeps both the original refusal and the cleanup failure.

Data queues and cleanup custody are separate. Each managed inbox reserves two
empty-argument withdrawal slots, under a session-wide count and byte ceiling.
Their worker checks authority and polls cleanup first. This does not admit
arbitrary methods or payloads through the reserved path. Native leave and
withdrawal execute synchronously without inheriting the async data-work queue.
Directory, managed-session and direct-receiving owners also keep one fixed
cleanup bucket outside their subject tables. When a table is full, that reserve
uses the configured aggregate cleanup rate. Existing subject and ancestor debt
is still checked and debited. Only missing rows use the reserve. Exhausted
cleanup allowance still refuses work, and capability checks remain mandatory.
Private recording and supervision continuations require the exact owner-root
witness. They recheck their original live grant, callback and selection through
the ordinary requirements. Public query debt cannot block their completion,
and possessing a collaborator grant cannot forge the private witness.

Roster truth changes immediately: transport loss means offline, an admitted
return means online, and explicit leave removes the member. Presentation groups
connection churn into a five-second timeline summary without delaying authority
or membership updates.

## Accounting and evidence

Each retained key owns a fixed-size row of buckets. Lookup, debit and bounded
maintenance allocate nothing. Every 64 calls, maintenance visits at most eight
rows. Only fully restored rows retire, and the subject of the current request
stays retained. At capacity, known subjects continue using their existing rows.
New subjects cannot evict depleted debt.

Directory diagnostics expose effective policy, retained rows and admitted,
refused and coalesced class counters, without raw identities or capability
links. Startup summaries describe the
session and HTTP profile. Existing operator inventories, queue ceilings and
transport diagnostics describe concurrency and retained work.
Capacity counters record table pressure even when the cleanup reserve admits
the operation. Admitted and refused counters record the final outcome.

[`bench-rooms-admission`](../build-steps.md) enforces zero steady policy
allocations. The [cost record](../../bench/rooms/session-costs.md) describes its
measurement scope. Native owning tests cover atomic debit, replacement debt,
recipient isolation and cleanup. Browser proofs exercise the shipped action,
shared-session, reconnect and direct-message paths.
