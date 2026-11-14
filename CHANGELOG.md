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

### Added

- The website serves ocapnviz at `/ocapnviz/`. Play works as it does from a
  checkout, and Live watches a server on the same computer as the browser. A
  trace link for any other address is refused with the reason: a browser
  blocks a WebSocket without TLS from an https page unless it goes to the
  computer's own address.
  `zig build site-ocapnviz-page` builds the page into the site's assets.

### Changed

- The terminal Rooms client prints a name, a room name, and an error on one
  line with control and text-direction characters written out, and marks
  each further line of a message that has several.
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

### Fixed

- A covered spoiler in a Rooms message hides everything under it. A link
  under one showed its color through the cover and opened on the press
  meant to uncover it.
- A Rooms relay keeps only a short hello from a registered peer that no
  dialer has reached yet, and closes one that sends more. It kept up to
  8 MiB of received messages for each waiting registration. A message still
  arriving is bounded by the WebSocket message limit, as before.
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

## [0.1.7] - 2026-11-11

This release's changes are in
[its own changelog](docs/history/0.1.7/CHANGELOG.md).

[Unreleased]: https://github.com/glowcap-org/glowcap/compare/v0.1.7...HEAD
[0.1.7]: https://github.com/glowcap-org/glowcap/compare/v0.1.6...v0.1.7
