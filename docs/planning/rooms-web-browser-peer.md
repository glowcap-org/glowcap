# Rooms Web on the Browser Peer

Status: active plan

Retire the rooms web demo's per-tab JSON bridge onto the real browser peer
(`@pancake/web`, ADR-0070 Milestone 1), so the browser is an OCapN peer
rather than a client of a private JSON protocol. This is the execution plan
the [roadmap](../roadmap.md) defers to; it names the milestones, the files
each one moves, and the checks that hold them.

## Where the demo stands

Today `apps/rooms/deno/web.ts` is a per-tab bridge: it serves the
page, and for every browser tab it opens its own pancake connection to the
room directory and translates between a JSON WebSocket protocol
(`lib/wire.ts`, consumed by `ui/net.ts`) and the OCapN wire. The browser
never holds a capability; web.ts holds them all on the tab's behalf,
including the tab's `dm` listener and the three-party handoff redeem. The
bridge also supervises the room server (spawn, attach, takeover), and that
part is worth keeping.

Every load-bearing piece of the replacement already ships:

- `@pancake/web` runs the whole `@pancake/stack` surface in a browser over
  the wasm Host (`init({ wasm, wsUrl })`), with dials mapped to WebSocket
  URLs.
- `bindings/ts/web/test/serve_ws_host.ts` is the accepting shape the room
  server adopts: one `Channel` per accepted WebSocket,
  `Session.establishAccepted` over it, the socket a bearer rather than a
  protocol translator. `zig build web-peer-test` proves a keyed session over
  it in both directions.
- The OCapN room vocabulary the browser will speak (`lib/protocol.ts`,
  `lib/room_client.ts`) is the same one every terminal client already
  speaks.

## Constraints (from the roadmap, made concrete)

1. **No socket opens that is not already open.** The public surface stays
   exactly web.ts's one HTTP port: the page, the bundled graph and wasm,
   and every browser ws upgrade all ride it. The room server keeps only
   its existing TCP room port and needs no WebSocket listener of its own —
   a browser session reaches it through the relay below, and the keyed
   handshake rides the relayed bytes end to end, so the public side and
   the internal side mesh over today's two sockets (one public HTTP, one
   loopback TCP). `serve_ws_host.ts` stays the bindings-level proof that a
   ws bearer works; the demo does not need to duplicate it server-side.
2. **web.ts shrinks to a static file server, the supervisor, and one dumb
   byte relay.** No per-tab pancake connection, no JSON translation. The
   relay is one endpoint on the existing HTTP port
   (`ws://web-host/relay?target=host:port`): the browser's `wsUrl` maps every
   dial — the room server's locator and a DM-introduced member's `tcp`
   locator alike — onto it, and web.ts moves bytes between the ws socket
   and the target TCP socket without parsing them. The handshake rides
   through end to end, so the relay never holds a capability; it is honest
   plumbing, and the page keeps labeling the hop plaintext-over-loopback
   exactly as today's banner does.
3. **The browser UI's data layer moves onto stack sessions.** `ui/net.ts`
   (the JSON client) is replaced by `lib/room_client.ts` running in the
   page over `@pancake/web`; `lib/wire.ts` (the zod JSON vocabulary) and
   web.ts's per-tab bridge code delete. The page ships the bundled
   `@pancake/web` graph plus `pancake_driver.wasm`, served statically by
   web.ts.

Browser-to-browser DM stays out of scope until Milestone 2 (WebRTC
DataChannel with room-relayed signaling); a browser's own `dm` listener
lives on its wasm Host and is reachable through the relay's accept path
only if a member can dial the browser, which no transport here provides.

## Milestones

Each lands whole — code, tests, and doc claims in the same change.

- **W1 — the relay (landed).** web.ts gains the one `/relay` ws endpoint on its
  existing HTTP port, piping bytes to a target TCP address without parsing
  them, plus the allow-list that keeps it honest plumbing rather than an
  open proxy: the room server's own port always, and member addresses only
  while a DM introduction for them is live. A `web_test.ts` case drives a
  keyed session from a ws client through the relay to the room server.
  `demo-rooms*` stay green untouched; no new listener anywhere.
- **W2 — the browser speaks OCapN (proven end to end in a real browser).**
  Two gated proofs: `zig build rooms-web-relay-peer`
  (`apps/rooms/deno/web_relay_peer_test.ts`, a wasm peer under Deno) and
  `zig build rooms-web-browser-peer` (`apps/rooms/deno/browser_peer_test.ts`,
  a real headless Chromium via Playwright). Both have a `@pancake/web` peer —
  `init`, no dlopen — fetch the room directory and list rooms through
  `/relay`, dialing by mapping the locator's host:port to
  `ws://<web-host>/relay?target=host:port`. The stack now bundles for a browser:
  the blocker was that `internal/ffi/runtime.ts` and `internal/ffi/load.ts`
  carried module-level top-level awaits, and `deno bundle` (esbuild)
  flattens every module's TLA into one file where the stack's import graph
  deadlocks around one. The fix removed both: `runtime.ts` resolves its
  adapter without a top-level await (Deno and the injected browser adapter
  synchronously; Bun via `ensureRuntimeReady`, awaited by the async entry
  points), the four archive symbol tables `dlopen` lazily on first use
  (`lazySymbols`) instead of at module load, and `load.ts`'s archive-cascade
  `node:*` built-ins are static imports the browser bundle stubs
  (`bindings/ts/web/browser-bundle.json` +
  `bindings/ts/web/browser_ffi_stubs.ts`). All native paths still pass
  (deno/bun dogfoods, web-peer-test, wasm-driver-test, keyed-tcp).

  The page itself is now a browser peer for public chat.
  `apps/rooms/deno/ui/net.ts` no longer speaks the JSON bridge protocol: it
  runs `@pancake/web` (`init` with the wasm fetched from web.ts, dials mapped
  to `/relay`) and drives `lib/room_client.ts` directly — connect, directory
  watch, join, send, receive, presence, typing, all capability calls. web.ts
  serves `/pancake_driver.wasm` and bundles the page through the
  browser-bundle config; `page.html` loads `page.js` as a module.
  `zig build rooms-web-page` runs a real headless Chromium that loads the
  actual page, joins a room, and round-trips a chat line over the room
  capability. Direct messages surface an honest "coming in a later
  milestone" note (a browser has no dialable locator; the relay reaches only
  the room server). What remains:

  - **The JSON bridge is retired (done).** The page dropped `/ws`, so
    web.ts's per-tab `bridge`, the `/ws` route, `startDmMember`, the
    `safeSend`/`Outbound` plumbing, and `lib/wire.ts` were dead and are
    deleted. `web_test.ts` dropped the ten JSON-bridge/DM tests (including
    the two load-marginal flakes) and checks reachability the way the page
    does — a keyed session over `/relay`; the attach/take-over supervision
    tests keep their meaning through that same relay dial. web.ts's header,
    the rooms README, and the lib/ui comments now describe the browser-peer
    architecture.
  - **DMs (W3 + M2).** The relay's allow-list gains introduced-member
    addresses so a browser can dial a member it was introduced to; the
    reverse (a member dialing a browser) waits on M2's browser-to-browser
    path. Until then the DM surface says so.
  - **Adapter dedup (done).** The two near-identical WebSocket→`Channel`
    adapters (`web_test.ts`'s and
    `bindings/ts/web/test/serve_ws_host.ts`'s `channelOf`) and the production
    `connectWebSocket` in `adapter.ts` now share one `webSocketChannel(ws)`
    in `bindings/ts/web/ws_channel.ts`, exported as `@pancake/web/channel` so
    the rooms test imports the primitive without pulling the browser adapter
    graph. The named streaming costs (unbounded inbound queue and outbound
    buffer) live in that one place.
- **W3 — DMs through the relay.** The `wsUrl` mapping routes a redeemed
  give's member locator through `/relay`, so the introduction flow works
  browser-to-terminal the one direction it can (a terminal member DMs a
  browser only once M2 exists, and the UI says so instead of pretending).
- **W4 — the iroh variant.** `rooms-web-iroh` keeps a relay in any design
  (no browser speaks QUIC): web.ts relays each browser session's bytes
  into an iroh connection it holds to the server or member, still without
  parsing them. Same wsUrl mapping, different far end. Watch item: if
  upstream iroh ever ships a browser transport (its relay protocol is
  HTTP-shaped, and n0 has explored browser support), the browser joins the
  iroh mesh natively and this relay hop retires; until then the relay is
  the browser's only road to QUIC.

## Checks that hold it

`zig build web-peer-test` (the minimal ws-accepting shape), the reshaped
`server_test.ts` / `web_test.ts` under the demo steps' runner, and the
existing `demo-rooms` / `demo-rooms-dm` / `rooms-web` steps, which must end
this plan green with the browser peer underneath. Doc claims move in the
same changes: `apps/rooms/README.md`, the roadmap's browser
binding item, and `docs/shipped.md` when the retirement completes.
