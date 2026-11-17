# Changelog

Every release lists what changed for people using glowcap, in the form
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) describes. The
release notes on each [GitHub release](https://github.com/glowcap-org/glowcap/releases)
open with that version's section, so a release needs its section here first.
glowcap is alpha software, and a minor or patch version can change APIs, ABIs,
and storage formats before 1.0.
Releases before 0.1.7 are in the
[earlier changelog](docs/history/CHANGELOG.md).

## [Unreleased]

### Breaking

- A `SessionAcceptObserver.opened` that returns an error now keeps its
  reservation. The runtime then calls `abandoned` and `arrival_failed`, where
  it called `failed` before. An observer outside this repository releases
  that reservation exactly once, in `abandoned`, and handles `arrival_failed`
  as the retirement of one arrival with the listener still open.
- `net.completion.BufferPool.acquire` returns `Allocator.Error!?u16`. Null
  still means every buffer is leased, and a refused lazy allocation is now
  `error.OutOfMemory` instead of looking like exhaustion. A caller that
  unwrapped the old optional adds `try`. A data receive whose buffer
  allocation is refused completes once with that error and retires only its
  wire, where it used to wait for a recycle that never came and time out the
  handshake. Signal and wake receives drain or re-arm instead.
- Values nest at most 64 deep on every path (`model.max_value_depth`), and
  one count decides it: a top-level argument sits at depth 0, a container's
  items one deeper, and any container at depth 64, an empty one included, is
  refused. `SessionLimits.max_nesting_depth` and the C marshal's separate
  ceiling are gone, so a Zig embedder deletes the field from its limits.
- A send to a promise past the ceiling, settled data included, is refused at
  the call instead of failing after it queues, and the Zig surface reports
  `ValueTooDeep`. Data that settles only after the send is admitted can
  still fail when it lowers, and that send's result breaks.
- A local send, a promise send, a queued admission, a settle, a Vat send, a
  Loam write, and the C marshal refuse a value past the ceiling with
  `ValueTooDeep` before admission, and the session keeps serving. A partner's
  frame past it stays `NestingTooDeep` and ends that session. Over C, such a
  value returns `GLOWCAP_ERR_INVALID_ARGUMENT` where it returned
  `GLOWCAP_ERR_UNSUPPORTED_VALUE` (or `GLOWCAP_ERR_SESSION` for a far send),
  so handle that code for depth. Zig callers of those boundaries that matched
  `NestingTooDeep`, `UnsupportedValue`, `UnsupportedArgument` or
  `MalformedView` for their own deep value match `ValueTooDeep`.
- A handler result past the ceiling that fails conversion before its turn
  commits (the C marshal and Host capability lowering) retracts the turn's
  provisional sends. A served turn that already committed keeps its effects
  and breaks only its answer with `ValueTooDeep`. Neither ends the session.
- Low-level Zig callers also change. `model.argumentIsPlainData` now
  returns `error{ValueTooDeep}!bool`, so call it with `try` or handle
  `ValueTooDeep`. Resolver `fulfill` and the settle mailbox's `post` report an
  over-deep value as `ValueTooDeep` instead of `ForeignArgument` and
  `NotPlainData`. Those errors remain for authority. The view materializers
  `toTreeDepth` and `toSliceDepth`
  take a trailing comptime `author` argument, `.local` for a value your code
  wrote (`ValueTooDeep`) or `.partner` for wire data (`MalformedView`).
  Clones and measures of owned values now report `ValueTooDeep` for depth.
- `Host.liftValue`, `liftView`, `liftValues`, `projectValue`, and
  `projectValues` take a required trailing `input`, a `Host.LiftInput` that
  says who owns the values: `.partner` for wire data, `.queued` for a message
  a Vat queue owns, and `.borrowed` for a live caller's near-call arguments or
  reply. A caller that lifts a turn's arguments passes
  `Host.LiftInput.ofTurn(turn)`, and one that lifts wire data passes
  `.partner`.
- A refused `.borrowed` lift undoes only its own claims, including the settled
  data an answer reference in it reads. It sends nothing, keeps the session,
  and leaves a redeemed route for the caller's retry, while `.partner` and
  `.queued` still retire every reference through wire GC. Depth
  refusals for `.borrowed` and `.queued` input report `ValueTooDeep`, and a
  `.partner` one stays `NestingTooDeep`.
- A `.borrowed` value refuses an inline handoff give with `UnsupportedValue`
  before the Node sees it, because accepting one cannot be undone. A hosted
  actor that a raw Vat actor calls near with a give now sees that refusal,
  where a partner's or a queued call's give is still accepted.
- `Session.noteHostCapability` returns `!bool` instead of `!void`: whether the
  retain moved out of a held-back resolution hold. A caller that ignored the
  result writes `_ = try`, and `Session.restoreHostCapabilityHeldBack` is the
  inverse.
- A mutation intent counts each argument from depth 0. A stored Loam value
  with a container at depth 64, an empty one included, no longer decodes, and
  a write refuses it. An author whose records hold such a value rewrites each
  one so every container sits at depth 63 or less.
- A Host refuses an `outbound_high_water_bytes` of zero with
  `InvalidOutboundHighWater`, at construction and in `setSessionLimits`. A
  session with a zero waterline could never take input. Pass null for the
  default. The C ABI already reads zero as the default.
- `HostSession.resumeFeed` and `glowcap_host_session_resume_feed` refuse
  with `OutboundBackpressure` (`GLOWCAP_ERR_WOULD_BLOCK`) while a session
  holds input it can dispatch and its queued outbound is at the waterline.
  The input stays held: drain outbound and call again, as each binding's
  pump does.
- A Rooms room name holds no control or text-direction character, as a
  nickname does not. The directory refuses one when a room is opened,
  renamed, or published from another directory, and an IRC bridge refuses a
  channel named with one. A Rooms server whose `rooms.json` holds such a
  name does not start: remove that room's rows from the file, or start from
  a new state directory. The name of a room published from another
  directory is measured as every other room name is, in UTF-16 code units.
- A Rooms nickname or room name may not hold U+061C (the Arabic letter mark),
  which joins the other text-direction characters Rooms refuses. A saved
  archive or session checkpoint that holds such a nickname no longer opens.
  Remove that state directory to start it again.
- A Rooms file name holds no control or text-direction character, as a
  nickname and a room name do not. A direction override draws `photo`
  followed by `gpj.exe` as `photoexe.jpg`. The page refuses such a file
  before it is sent, a room refuses to take one, and a direct message that
  carries one arrives without that file or anything attached after it. A
  saved archive that holds such a file name no longer opens. Remove that
  state directory to start it again.
- A Rooms link preview shows the host its card opens above the title, with
  the port when that is not the scheme's own. The card showed the site name
  the linked page declared, and under a page with no title the host of the
  address that page declared, so a page could name another site on its own
  card. A Rooms server no longer sends the site name, the address, or the
  kind a page declares, and a page that declares only those makes no preview.
  The Rooms page refuses a preview that carries one of them. Update a Rooms
  server and the page that uses it together, or previews fail.
- A Rooms relay reads no WebSocket message larger than 1 MiB, the largest a
  binding's adapter admits. It read one of up to 8 MiB before any byte budget
  counted it. Every glowcap adapter already sends less. A client of another
  implementation sends messages of at most 1 MiB through a Rooms relay.
- A Rooms upload `write` carries at least one byte, and an upload's window
  starts again only when the bytes received reach a multiple of the chunk
  size. Any write started a new window before, an empty one included, so a
  member could hold a reserved upload without sending it. A client of
  another implementation writes whole chunks, or at least one chunk's worth
  of bytes in each window.
- The reply a C behavior callback writes to `out_reply` stays valid and
  unchanged until the library call that ran the callback returns or a
  behavior callback is entered again, whichever comes first. It needed to
  last only across the callback's return. The bundled bindings already keep
  it that long. A C consumer that frees or reuses reply storage as soon as
  its callback returns keeps it for that span. A turn that forwarded its
  answer has its `out_reply` ignored: a value there that would not convert
  does not fail the turn.
- The C ABI drops `GLOWCAP_RESOLUTION_FULFILL`,
  `GLOWCAP_RESOLUTION_BREAK`, and `GLOWCAP_RESOLUTION_HANDOFF`. No function,
  field, or callback took or returned them. C code that names them deletes
  the use.

### Added

- The website serves ocapnviz at `/ocapnviz/`. Play works as it does from a
  checkout, and Live watches a server on the same computer as the browser. A
  trace link for any other address is refused with the reason: a browser
  blocks a WebSocket without TLS from an https page unless it goes to the
  computer's own address.
  `zig build site-ocapnviz-page` builds the page into the site's assets.
- The Rust binding exports `BINDING_WEBSOCKET_MESSAGE_CAP_BYTES`, the largest
  WebSocket message a binding's adapter admits.
- Every binding exports `VERSION_MAJOR`, `VERSION_MINOR`, and `VERSION_PATCH`,
  the library version it was built against, to compare with the linked
  library's ABI version. Racket writes these and every other name here with
  hyphens, as in `VERSION-MAJOR`.
- Every binding exports `LOCAL_TURN_BUDGET_DEFAULT` and
  `LOCAL_TURN_BUDGET_UNBOUNDED`, the two special values of the Host's
  local-turn budget option.
- Every binding exports the five `FAILURE_TRUNCATED_*` bits, which name the
  text fields a failure event reports as cut to fit.
- TypeScript's `@glowcap/abi` also gains `FAILURE_EVENT_ABI_VERSION` and the
  return codes `NULL_POINTER` and `MALFORMED`.

### Changed

- The website and introductory guides shorten repeated explanations and clarify
  installation, shared-session lifetimes, history recovery limits, and Loam's
  supported interfaces.
  Examples and diagrams stay in place, and the rendered Zig dial example
  retains its closing brace when copied.

- The Rooms page draws text field edges at three to one against their
  ground. An offline member, an idle entry, or a session choice that is not
  open yet steps back by its avatar, mark, or a quieter ink, and its text
  keeps reading contrast.
- A Rooms timeline socket reads no message larger than one record line, at
  the endpoint, through the web address, and in the viewer. A timeline
  producer that sends a longer message is closed with code 1009 and the
  bound, where a line of up to 16 MiB was skipped. The Rooms Rust WebSocket
  byte channel sends a large write as several messages.
- A Rooms relay with `GLOWCAP_RELAY_MAX_SESSIONS` unset runs 256 sessions at
  once, where it ran 224.
- The terminal Rooms client prints a name, a room name, and an error on one
  line with control and text-direction characters written out, and marks
  each further line of a message that has several.
- A Rooms server sends the page's files gzip-compressed to a browser that
  accepts it, and builds the browser module for size. A first visit
  downloads about 3 MB where it downloaded about 13 MB.
- ocapnviz serves the Inter typeface itself, so the page asks no other site
  for a font. Its build names every file relative to the entry document, so
  it works from any directory, and carries no service worker.
- In Rooms, a posted line ends its author's typing. The room ends that
  member's typing state when it publishes the line and sends no notice for
  it, and the page sends no `typing(false)` beside a line that has no files
  to upload. A client that shows who is typing clears a member's indicator
  when that member's line arrives, and a client whose member is still typing
  when their own line lands says so again.
- A Rooms room holds a typing level for as long as a reader shows it, and
  the application crate's `room::membership` owns the three typing durations
  (`TYPING_IDLE_MS`, `TYPING_RENEW_MS`, `TYPING_CLEAR_MS`). A client that says
  its member is typing says so again every `TYPING_RENEW_MS` while that holds,
  and not at every keystroke: the room relays a repeated start sooner than it
  did. A start with no renewal stands longer than it did.
- The Rooms page clears a member's typing indicator when that member leaves
  or goes offline. It waited for the indicator to expire.
- The Rooms page says a member is typing when they edit a draft. Focus on a
  draft kept from earlier says nothing, and neither does changing a line
  already said.
- The Rooms join card announces each field's guidance with its control and
  places a refused room name above that field. Address, room, and nickname
  fields use the same label, refusal, and hint layout as other forms.
- The Rooms page moves what a change displaces. When a line lands, the rows
  above it slide to their new places and the line rises with them. The
  welcome card at the top of a conversation grows from the size it had, a
  member who arrives fades into the member list, the member counts roll to a
  new figure, and the message field eases between its states. Nothing waits
  for a move, and a reader who asked for less motion gets none.
- The Rooms page shows the placeholder for earlier history once the read has
  run long enough to be a wait, as its other waits do. It drew the
  placeholder at once, so a quick read laid the log out around it and again
  without it.
- The site renders themed diagrams with the page, without fetching them again
  or waiting for JavaScript. Links stay visible in prose, navigation marks the
  current page, and footer columns fit the space beside the article. Heading
  links clear the sticky header when it wraps.
- A link in a Rooms message shows where it goes when its label does not
  say: the host of a web address, with its port when that is not the
  scheme's own, or the mailbox of a mail link, beside the label. A label
  such as `bank.example` over a link to another host is followed by the true
  host. A pasted address is its own
  label and shows nothing more, unless a user name or password stands before
  its host, or its host has letters outside ASCII, which are shown encoded.
  An address the browser would read as another place is shown as its words
  and opens nothing. A web address written without `//` is one. So is a mail
  link written with a host, with no mailbox in its path, with a fragment, or
  with a query field other than a subject and a body.
- Past its ceiling, the Rooms directory evicts the oldest signaling exchange
  among the members that hold the most, where it evicted the oldest of all.
  One member's flood of offers takes its own exchanges first.
- A frame split across reads takes only the bytes it lacks from the next
  read, in the connection loop and in a byte-fed Host session, and the frames
  behind it are read where they arrived. Each read behind a split frame was
  copied whole.
- A fulfilled reply off the wire reaches its listener with its text and bytes
  read from the received frame. Each was copied into the Vat's settle arena
  first.
- A delivery lent as views and sent on to a local actor, from a handler turn
  or through a Port, has its text and bytes copied once, by the queue. They
  were copied twice.
- A call that carries no capability reaches a behavior served through the C
  library, and so through every binding, with its arguments projected once,
  from the received frame onto the C argument arrays. They were first lifted
  into a Host value tree in the turn arena.
- The website keeps its sidebar and reading column in one place on every
  page at wide widths, draws one focus ring on every control, and sizes its
  fallback fonts like IBM Plex, so less of a page moves when the web font
  arrives. The Rooms page shares the fallback fonts.
- A reply from a behavior served through the C library, and so through
  every binding, has its text and bytes copied once, into the stored answer.
  They were copied into the turn arena first.

### Fixed

- A Zig `HostRuntime` that runs out of memory while draining queued work no
  longer fails the loop. A step, a settle, a session release, a deferred
  release, a close, and a mailbox turn keep the queued work and retry it after
  a short interval. A blocking settle that needs that work answers
  `OutOfMemory` until it runs. The Host holds the deadline, and
  `hasRunnableWork` reports no work from the moment it is set until a runtime
  attempt runs or clears it, so `glowcap_loam_advance` reports no progress
  instead of spinning on that work.
- A session open that completes or fails queues its consequences and no
  longer drains beneath its caller. `startDial` leaves them for the next step,
  and the step that decided the open attempts to answer them before it parks.
  Work a memory shortage gated stays queued for the retry. Stepping or
  draining from a completion sink's `reserve`, `take`, or `release` returns
  `ReenteredHost`. A failed pending-open report, an allocation that fails
  before a dial owns its row, provider admission, entropy, kernel pressure,
  wait capacity, and the final contract for unreturned failures still fail the
  open or the step ([#216](https://github.com/glowcap-org/glowcap/issues/216)).
- Closing an accepted Racket session no longer hangs when the driver closed
  it before the application accepted it. The binding releases the session
  handle when it consumes the remembered close event.
- A Host driver loop step no longer fails when one connection's input cannot
  be fed or parked for lack of memory. That connection closes with
  `OutOfMemory`, and the other sessions keep running. Closing a connection
  while memory is short no longer ends the loop.
- A Host driver loop step no longer fails when the runtime cannot admit one
  connection a provider has handed over, for lack of memory or any other
  local cause. That arrival closes, and the listener, the other sessions, and
  the loop keep running. A session the listener's observer refuses retires its
  arrival the same way, where it used to report the listener as failed. A
  provider that breaks its contract on an accept, a connect record, or a drain
  count still ends the loop. A provider that fails before it hands a
  connection over is outside this change.
- A Rooms session saves a moderator it issued while it holds no seat in the
  room, as a session does between a link rotation and the rejoin. The save
  read the room's live seat and failed without one. A joined room keeps
  asking to reconnect when it creates a new link.
- A stream provider's failed listen reaches the driver's listener-failed
  event under the provider's own cause name. A TCP listen on a busy port
  reports `AddressInUse`. It reported `ProviderIo`, so a Rooms server never
  said that its address was already in use.
- A Rust Host with a Loam attachment answers a fetch of a durable name
  that arrived before `Session::serve`. The lookup was never started, so
  the fetch stayed unanswered until the caller gave up.
- A connection that reaches a listener before its Host has a selected
  location is closed, and the driver loop keeps running.
  `glowcap_driver_step` returned `GLOWCAP_ERR_INVALID_ARGUMENT` for it,
  which every binding treats as the end of its loop, so a peer that
  connected while a server was starting stopped that server.
- A Host stepped by its embedder's loop waits while input it holds cannot
  move: part of a message from a partner, or messages held until the
  application serves an accepted session. It woke its embedder after every
  step in both cases, so a partner that stalled partway through a message
  kept a core busy.
- An iroh connection whose partner stopped reading, or closed cleanly,
  accepts and discards what is written to it and reports one writable
  record. `glowcap_iroh_conn_try_write` answered
  `GLOWCAP_ERR_WOULD_BLOCK` from then on, so a loop that had stopped
  reading until its queued output could move was never woken again. What
  the partner sent before it left still arrives in order, ahead of the
  closed record.
- A stepped Host wakes its embedder for input a read left behind the
  message that opened a session. That input could wait until the partner
  sent more.
- A stepped Host holds a session's unread input while that session's queued
  replies are at the outbound waterline, and dispatches it as they drain.
  It closed the session, so a partner that sent requests faster than it
  read replies lost its connection, and so did a session the application
  served while its replies were queued that deep. A partner that never
  reads its replies keeps its session until the application closes it.
- For a session the application is serving, a stepped Host dispatches what
  a partner sent before it closed its side when a read was waiting behind
  the message that opened the session. Over a transport that reports the
  partner's close as an event, it dropped that input and reported a lost
  connection.
- `glowcap_driver_step` returns `GLOWCAP_OK` for a step that dispatched
  held input. It returned `GLOWCAP_ERR_WOULD_BLOCK` when nothing else was
  ready.
- A covered spoiler in a Rooms message hides everything under it. A link
  under one showed its color through the cover and opened on the press
  meant to uncover it.
- A Rooms relay keeps only a short hello from a registered peer that no
  dialer has reached yet, and closes one that sends more. It kept up to
  8 MiB of received messages for each waiting registration.
- A Rooms member asked to leave a room can no longer change its subject. The
  subject reference a participant is handed comes with that seat and answers
  for as long as the seat lasts. One handed on to somebody outside the room
  stops answering when the seat ends, which a reconnect does too, and the
  member's next seat comes with a new one.
- Asking a Rooms directory for a private room's link spends the allowance
  that opening a room spends. It spent a read, so one connection could record
  private rooms until the server had no room link left to make.
- A Rooms room tells its link only through a way in that would seat the
  caller to post now. The link of a room that lets the public in to watch is
  not told by name or to a member who watches. A member who entered through
  a revoked link is not told the link that replaced it, and an invitation's
  entrance is not told the link.
- After a Rooms room's link is revoked, its manager or the holder of its
  room key makes the next one. Asking the directory by name made it. The
  name still makes it for a room that has no manager and no room key.
- An entrance to a Rooms room taken by name admits what the room offers the
  public now.
  One taken while a room was open let its holder in to post after the room
  turned moderated, or after it was forgotten and opened again as moderated.
- Opening a managed Rooms room with its key under a name or policy other
  than the recorded one is refused while the room is empty too. It opened a
  live room that contradicted the record.
- A factory reset of a Rooms directory retires what arrived while the reset
  was being saved: a session that connected, a room that opened, a name that
  was claimed. Such a session stayed connected and could hold a capability
  the reset retired.
- A manager, a moderator, or a link entrance issued before a factory reset of
  a Rooms directory never reads as current after it. The reset started
  generation numbers over, so one held by a session the reset left connected
  worked again once the same name was linked, moderated, or managed again.
  Numbering continues above everything the reset cleared, and the server's
  stored document records where in `generationFloor`.
- A session on a message-framed transport replays the packets that arrived
  before the application attended it in one pass. The replay took time that
  grew with the square of the packet count, so a peer sending many small
  packets could stall the driver when the session was attended.
- `GLOWCAP_REPL_REDUCED_MOTION=1` turns off the REPL's flash on a table that
  changed and holds the wait spinner on one glyph. The REPL read the variable
  and changed nothing.
- The Rooms join card no longer says a name is already in use while that name
  is this tab's own registration on a directory it just reached. A directory
  lists a new member before it tells that member its name, so the card waits
  for the grant before calling its own pending name taken.
- The members button in the Rooms page counts nothing until the room has
  said who is in it. It showed 0 while a join was on its way.
- A Rooms session asks the server to recheck its registered name
  (`signalCheck`) when a signaling route starts, after a retry or a failure,
  and at a change to its saved state once the last answer has grown old. It
  asked after every such change, which included each keystroke of a draft.
- Someone who types in Rooms for longer than a few seconds stays shown as
  typing. The page said so once, and other members' pages cleared the
  indicator while the member was still typing.
- A typing stop from the Rooms page goes to the conversation that heard the
  start, whichever conversation is on screen when it is sent.
- A Rooms page answering WebRTC offers rechecks its registered name for an
  offer and for the transport that offer opens. It rechecked for every
  candidate too.
- The Send button in the Rooms page leaves the caret in the field, as the
  attach and emoji buttons do, so a phone's keyboard stays up after a send.
  Pressing it took the caret away, which also sent a typing stop ahead of
  every line sent that way.
- The live trace reports the answer to a call where it arrives. A host
  reported the answers it sent and not the ones its own calls received.
- ocapnviz Live draws a message whose bytes repeat an earlier one. A second
  send of the same bytes from the same end was taken for the first one
  arriving and not drawn, which hid answers that carry nothing. The same
  bytes sent from both ends were drawn once.
- ocapnviz Build mode shows text as it is typed. Fields such as a peer's
  label and a message's label dropped each key until the field lost focus,
  and then kept only the last one.
- ocapnviz Build mode shows a moment changed in a recording that holds
  several sources. The viewer kept the list of moments it had read before
  the edit, and drew the moment as it was.
- A recording kept from ocapnviz Live names no address. Its description held
  the trace link the viewer had dialed, and that link lets its holder watch
  the server, so a saved or shared recording carried it.
- ocapnviz reads an id such as `constructor` or `toString` as any other id.
  Looking up such an id found what every JavaScript object inherits under
  that name, and the viewer took it for a peer, session, or message of the
  recording. The id `__proto__` is refused with the reason wherever an id
  enters a recording.
- ocapnviz opens a recording of several sources where one source holds a
  very large number of observations. It failed with a call-stack error.
- A connection reads what its peer sent before glowcap finished opening it.
  Over WebRTC, a first message that arrived that early stayed unread, and the
  session timed out in its handshake.
- `glowcap_webrtc_peer_try_send_packet` names how a channel ended:
  `GLOWCAP_ERR_CLOSED` after a clean close and `GLOWCAP_ERR_IO` after a
  fault. It returned `GLOWCAP_ERR_IO` for both once the channel had opened,
  and `GLOWCAP_ERR_WOULD_BLOCK` on every call for a channel that ended before
  it opened.
- ocapnviz ends a Live recording when it holds 128 MiB of events, as
  **Stop** does, and says the recording is full in a notice and in its
  description. A recording grew for as long as it ran, until the page ran
  out of memory.
- A byte-fed Host session (`glowcap_host_session_feed_bytes`) that refuses a
  chunk for memory keeps its pending bytes as they were, so the same chunk
  fed again applies each frame once. When one frame of a chunk has applied
  and the unread rest cannot be kept, the session closes with a
  resource-exhausted abort. It returned a retryable error, and the retry
  applied that frame twice.
- The progress ring on a busy Rooms icon button stands in the exact middle of
  the button. It sat half a pixel to one side.
- A Rooms result that carries a link to manage or moderate a room is prepared
  again from the current workspace when the session took a new seat in that
  room after the page read it, as any other workspace conflict is. The result
  ended in recovery with a bare refusal, which the room's connection
  restarting at that moment was enough to cause.
- A Rooms process that cannot bind its trace, HTTP, or IRC listener names the
  listener and the address in its refusal.
- The TCP connections a Rooms process owns send each small write as soon as
  it is written, as glowcap's own sockets do. A write could wait tens of
  milliseconds for the one before it to be acknowledged, which was enough to
  show a progress ring on opening a direct message through a Rooms server on
  the same machine.
- A service started through `glowcap-dev` with a terminal (`rooms-dev`,
  `site-serve`, and the others) stops when that terminal closes. It kept
  running in the container and held its ports, so the next start failed with
  "Address already in use".

## [0.1.7] - 2026-11-11

This release's changes are in
[its own changelog](docs/history/0.1.7/CHANGELOG.md).

[Unreleased]: https://github.com/glowcap-org/glowcap/compare/v0.1.7...HEAD
[0.1.7]: https://github.com/glowcap-org/glowcap/compare/v0.1.6...v0.1.7
