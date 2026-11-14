# Changelog, 0.1.7

The [changelog](../../../CHANGELOG.md) holds the current release line. This
page holds release 0.1.7, in the same form. The releases before it are in the
[earlier changelog](../CHANGELOG.md).

## [0.1.7] - 2026-11-11

### Breaking

- Fallible C release functions now report ownership explicitly: negative
  results retain the handle, zero consumes it successfully, and positive
  results consume it with the negated error code. Use
  `glowcap_release_result_consumed` and `glowcap_release_result_code` instead
  of inferring ownership from an error category. Rebuild the archives and
  bindings together.
- A redeem or enliven that cannot reach its exporter breaks with text that
  starts `ExporterUnreachable`, where it started `handoff redeem failed` or
  was the raw route error. Branch on the cause, never on the text: Rust and
  Python `is_exporter_unreachable`, TypeScript `isExporterUnreachable`, and
  Racket `glowcap-exporter-unreachable?`.
- `GlowcapTcpConfig.profiles` (zero refused) picks the TCP profiles. Bindings
  default to `noise-tcp` alone, so opt in to plain or keyed TCP with `profiles`
  (`#:profiles` in Racket). A dial on a profile the package does not serve
  fails `INVALID_ARGUMENT`, cause `transport_unavailable`. In C, a zeroed
  `GlowcapTcpConfig` is now refused: set `profiles` to
  `GLOWCAP_TCP_PROFILES_ALL` to serve all three as before.
- `glowcap_driver_add_provider` composes packages by profile. It installs the
  profiles nothing serves yet and accepts a served one only from the same
  provider with an equal profile and configuration. A different one is refused
  with nothing installed. A package that adds nothing gets its lease back
  before the call returns.
- A Rooms peer that dials TCP dials `noise-tcp`. It dials the cleartext
  `tcp` or `keyed-tcp` only when its operator named that transport, so an
  address a room hands over never opens a cleartext dial by itself.
  - A server or client names one by listening on it or by the locator it was
    started with.
  - A session names one by listening on it or in `--dial-transports`, which
    now takes `tcp`, `keyed-tcp` and `noise-tcp` each by name. `tcp` used to
    install all three: use `noise-tcp` for sealed TCP alone, and add
    `keyed-tcp` to reach a peer on it.
  - The IRC server names one by its directory, its direct-message listener,
    or the new `--dial-transports`, which also takes `iroh`. Its
    `--directory` is now required: pass the address your Rooms server
    printed.
    Its `--dm-transport` names sealed TCP `noise-tcp`, as every other option
    does: replace `--dm-transport=noise`, or leave it out for the default.
  - A running session keeps the list it was started with. Stop it and pass
    the new list to `session start`.
  - A Rust peer's dial on a transport it did not register carries the new
    code `transport-not-dialed`, or `saved-transport-unavailable` when it
    restores a saved address.
- The Rooms IRC bridge takes `--transport` as the Rooms server does, listens
  on iroh by default, and prints its address where it printed a port. It
  listened on cleartext TCP: pass `--transport=tcp` to keep that.
- A Rooms peer refuses a listener argument its transport does not read, such
  as `--port` with iroh or `--reachability` with TCP, where it ignored
  one. Remove the argument or name the transport that reads it.
  `rooms-web` passes its room port default only to a TCP listener, and a
  session started under another transport leaves the stored options of the
  one it left.
- Zig embedders: a break is an `engine.Broken`, its text and its cause,
  wherever the text alone used to travel.
  - `actors.Resolution.broken` and `Outcome.broken` hold one, so a listener
    reads `.detail` for the text.
  - `Vat.breakVow`, `Host.resolverBreak`, `Host.resolverReject`,
    `TurnParticipant.abort` and `abort_notify` take one.
  - `HostedActor.handleOpaque` and `Hosting(B).handleOpaque` return an
    optional `HostedActor.Failure` where they returned an error union. Its
    `own` field says whether the behavior refused or the adapter around it
    failed. Build one with `.behavior(err)` or `.adapter(err)`, which
    replace `fromError`.
  - `Hosting(B).handle` returns a `HostedActor.Result` with no error union,
    so a direct caller drops its `try`. A `B` that fronts another behavior
    declares `pub fn refuses(err: anyerror) bool` to name the errors that are
    that behavior's refusal.
  - `HostRuntime.addProviderPackage` takes the package alone and returns
    `!void`. `HostRuntime.unservedProfiles` says which of its profiles
    nothing serves yet.
- A Rooms server refuses to advertise a cleartext trace route off loopback.
  `--trace-connect` and `--trace-publish` take a `wss://` route, or a
  `ws://` route on loopback, and a specific `--trace-bind` address off
  loopback needs both named, while a wildcard bind advertises loopback. A
  producer's first message is the trace capability, which a `ws://` route
  carries in the clear. Put a TLS proxy in front of the
  listener and name its routes.
- The `rooms-web` program started by itself serves HTTP on `127.0.0.1`. It
  listened on every interface. Name `0.0.0.0` with `--http-bind`, or with
  `GLOWCAP_ROOMS_HTTP_BIND`, which `glowcap apps rooms serve` reads too, where
  another machine or a container's port forward reaches the listener. The
  devcontainer sets the variable, so recreate an existing container before
  `zig build rooms-web` there.
- Rooms no longer reports the failure codes `session-handshake-incomplete`,
  `session-signaling-host-offline`, `session-signaling-unavailable` and
  `session-webrtc-no-route`. A session that cannot be reached reports
  `peer-unreachable`, which the browser page shows as `session-unreachable`
  text. Remove branches on the four codes.
- Rooms direct introductions now wait for the requested inbox in one call.
  Remove retries for `introduction-pending` and handlers for `introducible`.
  An unanswered request fails with `introduction-timed-out` ten seconds after
  the server accepted it. `startDirect` returns an inbox receipt without a
  `status` field and spends one introduction token.
  Before upgrading, finish or release retained direct-opening operations with
  the previous version, or reset the session store. Retained 0.1.6 direct
  receipts cannot be read by this version.
- A Loam control request that names a stale revision or an operation already
  used answers with an `access:control-conflict` verdict where it broke the
  call. Read the reply before treating it as applied. Rust decodes it with
  `ControlConflict::read`.
- Failures carry a typed cause separately from diagnostic text through Zig,
  the C ABI, and all four bindings. Use the cause or binding predicates to
  distinguish identity, routing, restoration, and withdrawal failures.
  Partner-written text cannot claim a local diagnosis. A call a behavior
  breaks inside its own vat (`breakWith`, a returned error, or a hosted
  refusal) carries the local application cause, so Rooms admission advice
  survives local calls, forwarding, and retained receipts.

  C consumers use `glowcap_host_last_error_cause`,
  `glowcap_driver_last_error_cause`, FAIL's `cause` field, and
  `GlowcapLoamEffectResult.cause`. Dial failure reports now require a route
  cause. Unavailable transports remain distinct from failed connections.
  Rebuild against the updated archive fingerprint.

  FAIL's message contains detail without its display prefix. Bindings render
  the prefix from the cause. TypeScript exposes it as `breakCause`, preserving
  JavaScript's `Error.cause` for chained errors. Long local diagnostics retain
  a UTF-8 prefix within their existing byte limit.
- Zig: match `EndpointReleaseFailed` in iroh and WebRTC
  `Resident.deinit` error handling instead of `SidecarTeardownFailed`.
  C error text quoting this failure changes too.
- A Racket broken vow raises `exn:fail:glowcap:broken`, a subtype of
  `exn:fail:glowcap`. Read its reason from `exn:fail:glowcap:broken-reason`
  and its cause from `exn:fail:glowcap-cause`. Code that constructs
  `exn:fail:glowcap` directly adds the trailing cause field.
- ocapnviz: the Live deep link is `#live=<sturdyref>`, and the
  page clears it from the address once read. A `?live=` query is ignored, so
  change those links to `#live=`. The capability stays only in memory. Paste
  the link again after reloading the viewer.
- `zig build bench-iroh` and `profile-iroh` are `bench-transports` and
  `profile-transports`, because they measure TCP, Noise TCP, in-process, and
  iroh. Rename any invocation.
- Zig `net.waitAny` and `net.waitAnyReadable` refuse a connection with no
  descriptor with `error.NotPollable`, and their error set is
  `net.WaitAnyError`. `net.waitAnyDescriptor` waits on descriptors alone.
  Update explicit error sets and handle `NotPollable`, or use the
  descriptor-only operation.
- Zig `net.clock.nowMonotonicNs` is private. Use `net.clock.nowNs(io)`.
- The bindings' generated FFI tables leave out the per-module
  `clear_last_error` functions and the `_in` allocator forms of transport,
  locator, and URI constructors. Code that called those raw symbols through a
  binding's FFI table calls the C library directly.
- `glowcap_driver_*` functions return the Host's code for every error the
  Host names, where most of them returned `GLOWCAP_ERR_IO`. Code that branched
  on `GLOWCAP_ERR_IO` for one of these branches on the new code:
  - `GLOWCAP_ERR_NOT_FOUND` for a peer, vow, capability, or connection lookup
    that names nothing.
  - `GLOWCAP_ERR_CLOSED` for a closed sealed channel, a broken promise, a gone
    peer, or a released vat.
  - `GLOWCAP_ERR_WOULD_BLOCK` for backpressure and pending state.
  - `GLOWCAP_ERR_SESSION` for an unverified partner or signature.
  - `GLOWCAP_ERR_INVALID_ARGUMENT` for refused arguments, locators, and URIs.
  - `GLOWCAP_ERR_INTERNAL` for exhausted capacity.
- `glowcap_host_set_ingress_limits` returns `GLOWCAP_ERR_INVALID_ARGUMENT` for
  a Host that is not quiescent, where it returned `GLOWCAP_ERR_WOULD_BLOCK`.
  Configure limits before starting session work rather than retrying.
- A transport provider may return `GLOWCAP_ERR_NOT_FOUND`, which the driver
  reads as `ProviderNotFound`. Zig's `foundation.FailureClassification` and
  `driver.OperationFailure.Kind` gain `not_found`, so an exhaustive switch
  over either adds that arm.
- These Zig declarations are removed:
  - `driver.Served.feedBorrowed`. Use `recvBorrowed` with `driveFed`, or
    `HostSession.feedBorrowedCommitted`.
  - `HostSession.captpVersion`. Read `settledProfile().?.captp_version`.
  - `model.equality.argumentSlicesEqual`. Use `model.argumentsEqual`.
  - `model.uri.freePeer`. Use `model.freePeerLocator`.
  - `PartnerIdentity.designatorIsSessionKey`, `SealedChannel.takeWireInto`,
    `engine.events.Head.slabOf`, `GiftRegistry.applyWithdraw`, and the CLI's
    `log.hasDivert`.
- The iroh Rust library does not export `glowcap_iroh_sidecar_conn_close`.
  `glowcap_iroh_sidecar_conn_free` closes gracefully before it frees. Replace
  close-then-free calls with one free call.
- The Rooms live timeline's capability no longer travels in a URL. A
  producer connects to `/publish` and sends the capability as its first
  WebSocket message. A viewer connects to `/captp` and presents it when
  fetching the trace object. The endpoint refuses any route with a query,
  including `?cap=`, and the `/` viewer route. Through the web server, an
  upgrade on `/trace` gets 404 and viewers use `/trace/captp`. Update any
  external producer or viewer.
- A Goblins vat that publishes a Rooms timeline sets
  `GLOWCAP_ROOMS_TRACE_URL` to the link's `trace-publish` route with no
  query, and `GLOWCAP_ROOMS_TRACE_CAP` to its swiss number.
- Dependencies move to their current releases. Zig 0.17.1 is the minimum
  toolchain and the development container's pins move with it (Rust 1.99.1,
  Deno 2.9.8, Node 26.13, Playwright 1.65, ZLS 0.17.0). Rebuild the
  development container. The Rooms and ocapnviz Deno projects take zod 4.6.7,
  which fixes a published advisory, and the transports lockfile takes
  `webpki-root-certs` 1.0.12 (RUSTSEC-2026-0383). The CLI's REPL library
  libvaxis no longer pulls zigimg, and ocapnviz moves to `pixi-viewport` 7.
- Every direct Zig Host constructor now requires `Host.Options.thread_policy`.
  Choose `driver.checked_threads` to refuse off-thread verbs with `WrongThread`,
  or `.unchecked` when the embedder enforces confinement. Replace
  `Options.withFrameCap(cap)` with `Options.init(policy, cap)` and set the
  policy in direct `Host.init` options. C Hosts and HostRuntime check OS threads.
  Freestanding Wasm explicitly uses unchecked confinement.
- C archive fingerprints cover C contracts without binding omission policy.
  Rebuild or reinstall matching C libraries and bindings together. Libraries
  built before this change fail the updated bindings' fingerprint checks.
- TypeScript byte-fed handoff connectors receive the Session that introduced
  the handoff, so WebRTC signaling can use its context. Code that builds a
  `ConnectorRequest` itself must set `introducer`, to `null` for an
  application dial.
- Python `Connector` realizers and Racket `make-byte-connector` realizers
  take a fourth argument, the Session that introduced a handoff redeem, or
  `None`/`#f` for an application dial. Add that parameter to every custom
  realizer. Python `Connector.connect` takes the introducer as its fourth
  argument too.
- Rooms join, room, and directory URLs carry the room and destination after
  `#`, keeping locators out of the page host's HTTP request logs. Recreate
  saved URLs that name them after `?`, or paste the room locator into the
  join card.
- Zig `Netlayer.supportsDial`, `supportsBlockingDial`, `supportsStagedDial`,
  `supportsListen`, and `Listener.sealedChannel` are removed. Read `dial` and
  `listen` on the netlayer's vtable, and `sealed_channel` on its transport
  profile.
- Zig `driver.HostInitError`, `model.uri.tcpConnectHostPort`, `Entity.generation`
  in the CLI lab, the engine's `DecodeError`, `completion.loop.SubmissionDebt`,
  and `state_lock.mapError` are removed. Read
  `Host.InitError` and `connectHostPort` in place of the first two. The rest
  have no replacement.

### Changed

- TypeScript, Python, and Racket report library-resolution notes as
  `library-resolution` failure events instead of printing warnings. A failed
  archive load includes the notes from its own attempt and the loader cause.
  TypeScript still prints download notices.
- The Tasks, Tools, and Accountability demos listen and dial over encrypted
  Noise TCP. Clients take the `ocapn://` locator the server prints, and each
  `*-LISTENING` line ends with it. The Tasks server takes `--transport=tcp`
  for the cleartext adapter. Tools attach reads the coordinator's locator
  from `zig-out/state/tools/`.
- The Rooms page keeps working when the browser blocks site storage. Blocked
  storage reads as empty, and a setting the browser refuses to save says so.
  A tab that cannot store its reload guard does not reload itself after an
  upgrade, so reload it by hand.
- Zig's `HostRuntime.tcpBackendStatus()` reports the Linux completion backend
  selected for its stream stack and the reason for falling back to epoll.
- A direct message that finds no route on a page with no Rooms server opens
  **Choose a Rooms server**, which saves the conversation to return to.
- Per-language benchmark charts label a value a run did not measure as
  unmeasured instead of drawing it as zero.
- Rooms offers **Fastest** in **Direct message connection** to race
  WebRTC against the server route. **Browser to browser** prefers WebRTC,
  and **Through the server** uses only the server. Pages with no Rooms server
  use browser-to-browser connections. Existing browser data keeps
  **Browser to browser**. Choose **Fastest** in Settings to race both routes.
- Pointing anywhere along a Rooms message's row shows that line's time and
  menu. Only the message and a strip beside it did.
- The new-room panel in the Rooms sidebar chooses the kind of room from the
  mark that leads the name, as the join card does. The separate button at
  the end of the field is gone. The panel and every row under it keep one
  inset around their marks and one column for their names, so a room's name
  starts where a direct message's does.
- The Rooms join card calls an open room's field "Open room", as it names a
  moderated and a private one.
- On a wide screen the Rooms members button stands beside the join card too,
  where it shows and hides the member column and counts nothing.
- The sidebar row of a directory with no room open opens that directory. The
  line under it that says "no rooms yet" opens the join card aimed there.
  The row opened the join card and the line opened the directory.
- The "Share with" field on the Rooms archive card finishes a member's name
  from the page's own list, as the sidebar's fields do. The browser drew its
  own list there. A list of names goes down when the caret leaves its field,
  on the join card too.
- A Rooms field that takes an `ocapn://` address or link tells password
  managers to leave it alone and asks a phone for its address keyboard. The
  history link field shows what is pasted, as every other link field does.

### Added

- Rooms failure codes say more about a reach that failed, for code that
  branches on them.
  - `peer-unreachable` is a peer the dial could not reach, or one that was
    lost before it answered.
  - `member-unreachable` is a member the Rooms server could not deliver a
    direct-message request to.
  - `introduction-refused` is a member whose side turned a direct message
    down.
  - `introduction-timed-out` is a member that did not answer a
    direct-message request in time.
  - `transport-not-dialed` is an address on a transport this peer was not
    started with.
- `GLOWCAP_UNKNOWN_SWISSNUM_MESSAGE` in C and `UNKNOWN_SWISSNUM_MESSAGE` in
  the bindings (`UNKNOWN-SWISSNUM-MESSAGE` in Racket) name the text a peer
  answers a fetch of a name it does not publish. Each binding's
  publication-not-found check reads the cause before that text: Rust and
  Python `is_publication_not_found`, Racket `glowcap-publication-not-found?`,
  and the TypeScript `PublicationNotFound` error.
- TypeScript, Python, and Racket can independently retain held references and
  resolve opaque capabilities to owned references or settled values. Explicit
  retains and resolution results receive finalizer cleanup even with Session
  GC off.
- TypeScript, Python, and Racket Hosts spawn, send to, and tell actors with no
  Session: `host.spawn`, `host.send`, and `host.tell`, and in Racket
  `host-spawn`, `host-send`, `host-send-promise`, `host-await`, and
  `host-tell`. Inside a behavior these calls join its turn.
- `Session.breakFarPromises` in TypeScript, `break_far_promises` in Python and
  Rust, break every promise still waiting on the partner and keep the session
  open, as Racket's `break-far-vows!` does. A driver-owned session refuses it.
- Sessions in every binding report the `op:abort` the partner sent, which
  stays readable after the session closes: `partnerAbort()` in TypeScript,
  `partner_abort()` in Python and Rust, and `session-partner-abort` in Racket.
- Rust TCP, in-process, and onion connections and listeners expose
  `shutdown_handle()`. Its handle can wake blocked reads, writes, or accepts
  from another thread.
- `glowcap --json` prints a broken call's `cause` beside its text: who
  established the break (`origin`), its `reason`, and whether it happened
  during a `fetch`, a `restoration`, or a `withdrawal`. A script branches on
  `cause`, because a partner can write any text.

### Fixed

- The devcontainer keys Zig's global cache by compiler version, preventing
  false package hash mismatches after an upgrade. Rebuild and recreate it.
- The CLI's REPL shows `! cancelled` and `! WaitTimedOut` only for a wait it
  ended itself. A partner's break whose reason read the same was shown as
  the REPL's own cancel.
- A Rooms server whose work queue is full refuses with `admission-busy`, so
  the page says the server is busy and to try again in a moment. The refusal
  carried no code.
- A Rooms server takes a call's place in its queue before it charges that
  call's own allowance, so a call refused as `admission-busy` spends only the
  `ingress` allowance that counts every arriving call. A caller retrying
  against a full queue was charged for the call each time and ended up rate
  limited.
- Linking a saved Rooms publication costs one `read` whether or not it
  names a room, and subscribing to an ID that names none costs one `read`.
  Linking a room the server holds cost two, and subscribing to an ID that
  names none cost nothing.
- A Rooms action that failed after it was sent names what went wrong on the
  page, such as a member who could not be reached. The page showed the raw
  error text under a general heading.
- `glowcap apps rooms serve` takes every shared-session option under
  `--session-`, such as `--session-dial-transports`. The installed command
  refused them, though the server it starts reads them.
- A rate-limited Rooms action says when to try again. It asked the person
  to decide on a change the session never started.
- Opening a Rooms direct conversation is admitted or refused whole, so
  waiting the advised time and pressing again opens it.
- The Goblins Rooms peer lists members who registered before it joined, so
  it can message them directly.
- Releasing an iroh endpoint succeeds when a partner vanished without
  acknowledging the close. It reported a teardown failure, which made a
  Rooms server exit 1 after an ordinary shutdown.
- `nextAction` and `takeAction` skip a retried dial whose pending row was
  cancelled. They reported an empty queue while rows remained.
- Rooms refusals name what is gone and the next step. Letting go of a change
  that is already gone succeeds, and clearing browser data removes every key
  even when one is refused.
- The Rooms trace capability comparison holds its length difference at full
  width.
- A browser can direct-message a Goblins Rooms member reached over iroh. The
  Goblins test peer's iroh netlayer admits a hello that claims another
  transport, such as a browser's locator carried through the Rooms relay, and
  traces it as unauthenticated. An iroh claim must still name the endpoint
  QUIC authenticated.
- The Rooms page enters a room that another member created at the same
  moment. It showed the second member a room-exists error.
- The Rooms trace endpoint and the web proxy wait for the peer's reply after
  they refuse a socket, so the peer reads the close code. A client that sent
  as the socket opened could see a reset in its place.
- Zig `loam.hosting.Attachment.destroy` refuses with nothing changed. A
  refusal at its Vat barrier left publication discovery uninstalled.
- `glowcap_loam_attachment_release` returns `GLOWCAP_ERR_WOULD_BLOCK` and
  leaves the attachment intact while a failed live startup's proposal waits
  on a busy Store, where it aborted the process.
- Zig `Host.Call`, `Host.Enliven`, and the Loam reference save do not panic
  when `deinit` is called inside a Host callback. The release runs when that
  callback's verb finishes.
- Racket listener, provider, and session verbs on a released driver loop or
  session refuse with `ERR-CLOSED` instead of reaching freed memory. Closing
  a listener inside a behavior turn refuses with `ERR-INVALID-ARGUMENT`. A
  verb on a closed listener refuses with `ERR-CLOSED`, and one on a failed
  listener raises the failure it latched.
- Python driver-loop verbs on a released loop raise `ERR_CLOSED` instead of
  crashing the process. A behavior exception whose text raises breaks the
  answer with its type name.
- TypeScript WebRTC bring-up closes the opened session when it is aborted or
  its candidate disposer throws.
- Rust `loam::Store::close` leaves the store closed when the engine close
  fails, and never releases the handle a second time. `collect` and
  `recover_creation` refuse on a closed store.
- Rust `Resolver::fulfill`, `fulfill_value`, `break_with`, and session close
  return success once the effect is committed. A refused progress kick is
  reported at the next progress.
- Dropping a Rust driver-loop connect after its session opened releases that
  session.
- A failure inside a Racket hosted callback does not unwind through C. The
  feed or driver step that ran it raises the exact cause, and a second
  failure in the same step is kept for `take-runtime-failures!`.
- Every Racket `on` listener on a local vow fires, where a second `on`
  replaced the first. A failure escaping `drive` keeps the rest of its batch
  queued.
- Closing a TypeScript WebRTC session's channel closes its
  `RTCPeerConnection`.
- A listener fire whose resolution names an export far past the table's
  frontier does not panic on allocation failure. The table grows through
  that position before the commit.
- A failed in-memory Loam engine close frees its rows.
- A told async behavior in TypeScript or Python runs to completion, and the
  Host reports its failure as `tell.behavior` from `takeFailures` (Python
  `take_failures`). It used to be refused before it ran, and Python left its
  coroutine unawaited.
- Serving a Python or Racket session whose partner had already disconnected
  reports how it closed. It used to hand the freed session back to the
  driver, which refused it with `SessionNotOwned`.
- Deferred Python and Racket behavior replies can carry capabilities. Rust
  `Host::send` and `Host::tell` use the active turn inside behavior callbacks.
- The Rooms commands that start the browser app or print the skill directory
  report an installed component they cannot read, with its cause, instead of
  calling it missing.
- Rooms Docker deployment reports a failed image inspection instead of
  showing the selected image's revision as `unrecorded`.
- A refused onion SOCKS connect fails with the proxy's refusal as its cause,
  and a proxy that answers the greeting with another method or with extra
  bytes fails the dial as a protocol violation.
- A TypeScript `Runtime` asked to connect over a transport none of its
  connectors serve refuses with the `transport_unavailable` cause, as Rust
  does. It refused with `INVALID_ARGUMENT` and no cause.
- Racket's `glowcap` module exports `route-failure-from-cause`, which its
  guide tells a caller to branch on.
- A Rooms refusal passed on from a peered server keeps its failure code, so
  the page names the cause. A taken nickname on a peered room read as an
  unexplained refusal.
- A Rooms session tries a saved room again on its recovery timer when the
  refusal says the peer or member cannot be reached, or carries no failure
  code. It left that room refused until something else changed.
- A completion-loop connection that runs out of memory while taking a frame
  or packet closes its session with that cause recorded.
- The Rooms page no longer reloads once per tab when its host answers a
  missing `/ui-version` with the page itself.
- Rooms manager recovery reports why a held room's seat could not be read,
  and the page reports malformed link preview data instead of showing none.
- A handoff give refuses an exporter locator that cannot be parsed completely
  for privacy filtering. Allocation failures also return an error instead of
  sending the unstripped locator.
- A frame the engine cannot copy leaves the session unmarked so a byte-fed
  Host can retry, and a failed relayed settlement breaks its promise without
  marking the recipient session aborted.
- Racket dial cancellation unwinds the worker through cleanup, without
  waiting on a worker inside a hosted behavior.
- A direct message in **Browser to browser** mode falls back to the Rooms
  server when WebRTC finds no route. Signaling attempts have a ten-second
  deadline even when the network produces no candidates. The conversation
  card reports the route the conversation actually took.
- `zig build rooms-dev` tells its server the address browsers reach the page
  at, so the links it prints open and its shared session can start a direct
  message with a browser member. The server named its own internal port. In
  the devcontainer the address comes from `GLOWCAP_ROOMS_DEV_HTTP_PUBLIC`, so
  recreate an existing container.
- A Rooms page that attaches to a shared session reads what happened before
  it attached without redrawing it as news. Each room's member list appears
  once, and nobody is shown typing or announced by a desktop notification
  for something already past. The page
  replayed every earlier join and departure as if it were happening, so the
  member list flickered and members were reported as changing connection
  many times. A page of this release reads activity only from a session of
  this release, so stop a running shared session and start it again after
  updating.
- A Rooms page whose shared session stops answering says so in a standing
  notice, with the action to reload once the session is running again. It
  showed only the failure of whichever control was used next.
- A Rooms progress ring turns about its own center. A ring sized to a
  fraction of a pixel wobbled as it turned.
- A Rooms page on a static host reloads itself at an address that host
  answers. Entering a server address reloaded the page at a path below it,
  which a host without a deep-link 404 page answers with its own not-found
  page.

[0.1.7]: https://github.com/glowcap-org/glowcap/compare/v0.1.6...v0.1.7
