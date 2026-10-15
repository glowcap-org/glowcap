---
type: static
description: How Rooms refuses repeated work with per-peer, per-grant, and per-deployment allowances before launching an effect.
sources:
  - resource: /apps/rooms/rust/application/src/admission.rs
  - resource: /apps/rooms/rust/application/src/
---

# Rooms work admission

Rooms limits how much work each caller can ask of it, and refuses the extra
before doing any of it. An authenticated peer keeps its allowance across
reconnects. A shared session charges the calling grant, every grant it came
from and the session's shared pool together. A direct inbox limits the work
of receiving. HTTP has one allowance for the deployment and can also limit
each socket address.

The limits are token buckets kept in each process, so a restart clears the
debt and each replica counts on its own. They add to capability checks, room
capacity, payload ceilings, queue limits and transport flow control, and
replace none of them. A peer can dodge its own allowance by switching keys,
which is why HTTP starts, recipient pools and bounded state are limited too.

## Configuration

All services use the typed profile in
[`admission.rs`](../../apps/rooms/rust/application/src/admission.rs).
Startup prints its effective rates, row cap, aggregate multiplier and the
source of each override. Arguments take precedence over environment values.

| Setting | Meaning |
| --- | --- |
| `admission-scale` | Multiply every default rate by 1 through <!-- value ../../apps/rooms/rust/application/src/admission/settings.rs MAX_SCALE -->100<!-- /value -->. |
| `admission-rates` | Comma-separated absolute `class=burst/per-minute` overrides, applied after scaling. |
| `admission-rows` | Maximum retained accounting rows, 1 through <!-- value ../../apps/rooms/rust/application/src/admission/settings.rs MAX_ROWS -->65,536<!-- /value -->. |
| `admission-aggregate-scale` | Multiply the individual profile for aggregate pools by 1 through <!-- value ../../apps/rooms/rust/application/src/admission/settings.rs MAX_SCALE -->100<!-- /value -->. |

Rates must be positive unsigned 32-bit integers. Burst cannot exceed the sustained
allowance, so a full burst refills within one minute. Duplicate or unknown
classes, arithmetic overflow and invalid values refuse startup. Empty environment
values select defaults. Changing a profile requires restarting its owner.

The directory uses `--admission-*` arguments and
`GLOWCAP_ROOMS_ADMISSION_*` environment variables. The session uses the same
arguments and `GLOWCAP_ROOMS_SESSION_ADMISSION_*`. HTTP uses
`--http-admission-*` and `GLOWCAP_ROOMS_HTTP_ADMISSION_*`.
The web server configures browser-local sessions with `--browser-admission-*`
and `GLOWCAP_ROOMS_BROWSER_ADMISSION_*`. These settings travel with the served
page and apply when its local application opens. For example:

```sh
glowcap apps rooms directory serve --admission-rates=message=20/80,room-join=5/10
glowcap apps rooms session serve --dir=./rooms-session --admission-scale=2 --admission-rows=4096
```

HTTP also accepts `--http-admission-per-address=true|false`, or
`GLOWCAP_ROOMS_HTTP_ADMISSION_PER_ADDRESS`. It defaults to false. Only the actual
socket address supplies this key. Forwarded headers never select allowance.
Behind a proxy, the socket address identifies the proxy and may group unrelated
people. Configure this option only when that grouping is intended.

Default row caps are <!-- value ../../apps/rooms/rust/application/src/admission/settings.rs DIRECTORY_ROWS -->8,192<!-- /value --> for the directory, <!-- value ../../apps/rooms/rust/application/src/admission/settings.rs SESSION_ROWS -->4,096<!-- /value --> for the managed session and
<!-- value ../../apps/rooms/rust/application/src/admission/settings.rs HTTP_ROWS -->2,048<!-- /value --> for HTTP. Session and HTTP aggregate pools multiply the profile by <!-- value ../../apps/rooms/rust/application/src/admission/settings.rs POOLED_AGGREGATE_SCALE -->8<!-- /value -->.
Connections that have proved no key share the directory's aggregate
allowance. After a peer proves its key, its calls use its own allowance and the
recipient's.

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

Run `glowcap apps rooms deployment up` to apply it. The deployment template
passes every admission environment setting to its owning process. Other callers
set the profile where they start the application:

- Checkout development accepts the same environment values through `rooms-dev`.
- Library users pass `Settings` at initialization.
- Browser embeddings pass a JSON string as the optional third
  `RoomsManagedApplication` constructor argument, for example
  `JSON.stringify({"admission-rates":"message=20/80"})`.
- An attached session uses its server's profile. Page settings cannot change it.

The upstream directory sees an attached shared session as one authenticated
peer, with an allowance independent of the session's collaborator and aggregate
pools. Tune both owners for the expected shared workload, because raising a
local grant allowance does not reserve upstream capacity.

Each class's default burst and per-minute rate is its `default_rate` in
`apps/rooms/rust/application/src/admission.rs`. The defaults cover the mixed
room and direct-message use and the browser's largest posts and attachment
edits. A click does not always cost exactly one unit:

- A command is charged once, when its receipt is admitted. Its later steps
  recheck authority without charging again.
- Separately held capabilities still spend the grants guarding them, including
  a recipient's shared-session projections.
- An introduction's readiness lookup also reaches the directory.
- Byte and recipient limits remain independent.

## Effect and attribution inventory

Paths below are relative to `apps/rooms/rust/`. Protocol constants at each
dispatch owner define the accepted verb set, including extended post variants.
Unknown or malformed data calls still encounter ingress or existing Host input
bounds. A quota key never establishes authority.

| External surface and verbs | Subject and admission owner | Effect boundary |
| --- | --- | --- |
| Directory list, lookup, watch, location and room links | Proved calling peer, or live unproved connection. `services/src/server/behavior.rs` | Before result construction and watcher retention. |
| Register, offer inbox, open and open managed | Calling peer. Root registration/creation classes | Before actors, durable authority submission and handoff worker launch. |
| Local room entrance subscribe and public publication subscribe | Calling peer plus exact room generation. `services/src/server/rooms.rs` and `services/src/server/rooms/public_membership.rs` | Before seat creation or foreign subscription launch. |
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
| Rendezvous registrations and claims | Destination identity with aggregate registration capacity. `services/src/web/rendezvous.rs` | Claim debt survives unregister/re-register until full refill. |
| Leave, unwatch, discard, withdraw, close and revocation | Exact capability/source plus independent cleanup allowance | No data quota wait. Internal authority release and admitted receipt settlement retain their existing owner. |
| Operator capabilities and Loam access controls | Separately held management authority | Existing bounded operator and authority queues and Host limits provide reserved capacity. Data admission confers no management rights. |

## Refusal and recovery

Each refusal names which limit refused it: `directory`, `session`,
`direct-inbox` or `http`.

| Refusal | Meaning | HTTP |
| --- | --- | --- |
| `rate-limited` | Over the allowance. It carries `retry-after-ms`, the earliest time a retry could pass if nothing else is spent meanwhile, and the `scope`. The delay is an estimate, not a reservation. | 429 with `Retry-After` |
| `admission-busy` | The table that tracks callers is full. No retry delay is given, because none is known. | 503 |
| `request-too-large` | The request is bigger than one whole burst. | 413 |

Browser joins show a refusal beside the form or affected sidebar target, and
post refusals stay beside the composer. Drafts and attachments stay with the
action that was refused. When the cooldown ends, the button works again, and
nothing is posted on its own. Clicking during the cooldown does not extend it.

Membership recovery has one worker per exact selection:

- It waits as the refusal advises, with a little jitter per worker, for at
  most one minute in total and at least one second between attempts. Cancel
  stops the wait.
- After that minute, a retry from the activity list resumes the failed
  workers. Ordinary workspace changes do not restart the minute. Leaving and
  rejoining also works.
- The existing source and receipt checks still govern dispatch, uncertainty,
  replay and retirement.
- Confirmed current standing ends its recovery incident. A later refusal gets a
  fresh finite window.
- An unsent standing update follows the latest persisted preference after
  cooldown, so an obsolete refused value cannot apply first.

A receipt records what is known about a refusal:

- A validated refusal retains its reason in an unsent receipt. Host refusal
  before target admission also retains its diagnostic as known absence.
- Unknown observations keep their distinct client type and cannot become
  safe-to-resend advice.
- Uploads confirm staged-file discard before claiming absence. Failed
  compensation keeps an uncertain receipt.

The CLI retires a confirmed refused admission's local observation without
looking for a receipt that was never created. Lost admission or result
observations retain their exact request. If local retirement fails, its error
keeps both the original refusal and the cleanup failure.

Data queues and cleanup are separate:

- Each managed inbox reserves two empty-argument withdrawal slots, under a
  session-wide count and byte ceiling. Their worker checks authority and polls
  cleanup first, and the reserved path admits no other methods or payloads.
- Leave and withdrawal execute synchronously, outside the async data-work
  queue.
- Directory, managed-session and direct-receiving owners also keep one fixed
  cleanup bucket outside their subject tables. When a table is full, that
  reserve uses the configured aggregate cleanup rate. Existing subject and
  ancestor debt is still checked and debited, and only missing rows use the
  reserve. Exhausted cleanup allowance still refuses work, and capability
  checks remain mandatory.
- Private recording and supervision continuations require the exact owner-root
  witness. They recheck their original live grant, callback and selection
  through the ordinary requirements. Public query debt cannot block their
  completion, and possessing a collaborator grant cannot forge the private
  witness.

The roster changes at once: a lost connection means offline, an admitted
return means online, and leaving removes the member. The timeline groups
connection churn within
<!-- value ../../apps/rooms/web/ui/session/presence_narration.ts PRESENCE_WINDOW_MS milliseconds -->5 seconds<!-- /value --> into one line, without delaying any membership
change.

## Accounting and diagnostics

Each retained key owns a fixed-size row of buckets. Lookup, debit and bounded
maintenance allocate nothing. Every <!-- value ../../apps/rooms/rust/application/src/admission/registry.rs MAINTENANCE_PERIOD -->64<!-- /value --> calls, maintenance visits at most <!-- value ../../apps/rooms/rust/application/src/admission/registry.rs MAINTENANCE_ROWS -->8<!-- /value -->
rows. Only fully restored rows retire, and the subject of the current request
stays retained. At capacity, known subjects continue using their existing rows.
New subjects cannot evict depleted debt.

Directory diagnostics expose effective policy, retained rows and admitted,
refused and coalesced class counters, without raw identities or capability
links. Startup summaries describe the session and HTTP profile. Capacity
counters record table pressure even when the cleanup reserve admits the
operation, and admitted and refused counters record the final outcome.

[`bench-rooms-admission`](../build-steps.md) enforces zero steady policy
allocations, and the [cost record](../../bench/rooms/session-costs.md) describes
its measurement scope.
