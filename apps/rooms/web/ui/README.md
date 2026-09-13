# The browser page

This is the design contract the Rooms page keeps: the layout, the one
vocabulary its forms are drawn from, how a form decides what its fields say,
where a failure lands, and how a file is shown. The
[Rooms overview](../../README.md) is the walk a person takes through it;
[Developing Rooms](../../developing.md) covers the build and the objects on
the wire.

## Layout

The page is a rail of rooms and direct lines beside a workarea for the one
you have open: a topbar, a message log, and a composer at the bottom of that
column. Pressing the room or direct-message name in the topbar opens what
this tab knows about that conversation: the directory that carries it, the
session, and the path a direct line takes. `/details` (also `/info`) opens
the same card. A room's card is where you say where you are in it and where
you leave it; a direct line's card closes the conversation. The room card's
Capabilities tab creates the room's durable link with an explicit press and
then shows it for copying; `/link` reaches the same act from the composer.
`/join` names a destination, a room name or a locator, never the
conversation it was typed in.

The topbar stripe and the welcome card take their color from the rail row
that opened the conversation. The rail's teal-to-orange header fade stays
static, and orange controls stay orange. Wrapping prose on a card, a notice,
or the welcome panel never leaves a last line of one word, and a heading on
a card breaks into even halves. A long refusal stays two lines where it
appeared; Show opens the rest on its own card.

Monospace is for things a person could type: addresses, commands, code,
keys, the clock. It sets larger than the sans beside it, so it steps down
one size on the ramp wherever the two meet.

## The page and its chunks

It is a React application entered through `main.tsx`. `rooms-web` bundles
`page.js` with Deno's browser compiler and splits the graph at the waits a
reader can name. The opening screen in `page.html` covers the boot module,
the Wasm runtime, and whichever of session choice or the session shell comes
next; that next chunk starts as soon as the branch is known, so the splash
does not fade onto a second wait. After a session exists, Operations is its
own chunk and each pane another, except that the directory pane's shell
stays with Operations so opening it is not two sheens. Help's parts catalog
is the last chunk. A hover or focus on the control that opens one starts its
download; a prefetch that refuses is silent, and opening the surface is
what explains a missing chunk. A required chunk that `import()` refuses
stamps the opening screen lost, because that rejection is not a window
error. The wait on screen is the same quiet sheen a pane uses for its first
answer from the server.

The component tree names visual ownership. `shell/` composes the page frame,
`cards/` owns focused subject cards, `panes/` owns the conversation and modal
work surfaces, and `settings/` owns the settings surface and its sections.
Reusable controls and composition infrastructure stay at this directory's
root; the existing `ops/`, `sidebar/`, `composer/`, and `message/` subtrees keep
their narrower domain ownership.

One Zustand store projects the facts the page draws, and components
subscribe through `useRoomsState` selectors. The store has no persistence
middleware and holds no live capability; Rust holds every reference, and the
store holds what to draw. State that belongs to one control stays in that
component: an open emoji tray, the composer caret. UI state does not live in
the DOM. An element's own value outlives closing the control or switching
conversations, and comes back carrying an earlier intention.

## One vocabulary for forms

Every card and pane draws its forms from one vocabulary, held in `forms.css`
and the components beside it (`Field`, `Confirm`, `ModalHead`, `Button`),
and Help's parts catalog shows each piece next to its siblings.

A question is a `Field`: its label, the control, the sentence under it, and
the refusal it met, wired together so the control announces all three. A
single-line field stands at the touch height (`--field-h`), and a button
beside it in a `field-row` stands level with the control. The acts a surface
offers sit in an `actions` row at the end of the line they belong to, with
the commitment last; only a card's own foot fills the width. An act that
takes something away ends its label with an ellipsis and opens a `Confirm`
inline: one sentence saying what will be lost, then the way out and a red
commitment, so a leave, a delete, or a revoke never wears the same button
as a join. Opening one moves focus onto the way out, Escape is the way out
and stays inside the card, and keeping hands focus back to the act that
asked.

A list of things the surface knows about is `entries`: each has a head (the
name, a short fact, the acts at the line's end) and its longer facts under
it. A door to another card is a `launch` row: a mark, a name, one sentence,
and the act at the end. Sections are an overline title over a `well`.
Session setup, the Session, Holdings, and Reachability tabs, the room and
directory cards, and every Operations pane are built from these and nothing
else, so a form in one of them looks like a form in the rest. The tabs
divide by subject: Reachability holds the locators, Session holds where the
session lives and what it keeps, and Holdings holds what the session is
holding, which is room links, archive peers and their shares, operations
capabilities, the attached-session link, and access grants.

A form that takes a pasted capability opens a card of its own rather than
standing on the tab that owns the subject: attaching a session, choosing an
archive peer, issuing access, and replacing stored state each open a
`SettingsSubmodal`. A door's label ending in an ellipsis says the press opens
rather than commits, and the commitment lives at the foot of the card that
opened. Closing Settings over an unsaved form asks first: the window selects
the tab holding the change and puts a `Confirm` above that form, so the
reader sees what is at stake where they left it. A file to choose is a
`FilePick`, the platform's own input made transparent over a face the page
draws, because the platform's control cannot be dressed.

## The operator pane

The operator pane is written for a directory holding more rows than one
page. Each inventory offers its rows as sources: the lowercased text a
search matches, which every row pays, and the work of building the row,
which only a row on the asked-for page pays. A count is the directory's own
number of matches rather than the length of what was sent, so a search over
a hundred thousand rooms costs a hundred thousand string tests instead of a
hundred thousand member lists. Every category has the same face, the wire
row and the act that retires it where one exists, so search, paging, and
bulk retire are written once. The bulk retire is bounded per call and
answers how many rows still match, so a sweep over a large inventory can be
stopped without losing its progress.

## Form answers

Empty fields are answers to a question, not leftover state. Opening a room
from a link, pressing "add a room" in the rail, and loading the page cold
ask different questions; one saved form cannot answer all three.

`intent.ts` decides. Every surface that can put the reader in front of a
question files an **act** saying where it came from and what it names, and
presentation resolves each field from the strongest evidence available:

| Evidence  | Means                                                                              |
| --------- | ---------------------------------------------------------------------------------- |
| `edited`  | The reader typed it here, under this act.                                          |
| `named`   | The act said it outright. A link to `/room/general` names that room.               |
| `implied` | The act did not say it, but standing where it stood has only one reading.          |
| `recent`  | Not in this act at all: what this browser used last, written when a join succeeds. |
| `default` | Nobody has an answer, so the application offers its own.                           |

An act has one of three sources, each a reader doing something: `press` for
a control on this page, `link` for an address followed or typed, `restore`
for this browser reopening what it had. A presentation the application
causes by itself files no act. Filing one would put words in the reader's
mouth; filing none leaves the last real answer standing and leaves anything
half-typed where the reader left it.

Two consequences are easy to get wrong. An act naming an empty value still
beats a remembered one: a link to a room in this page's directory says
"here" by saying nothing about where, and that silence is an answer. And an
override the reader types belongs to the act they typed it under, so going
somewhere else drops it without anybody clearing anything.

The join card is the surface this runs on, in `joining.ts`. It says what it
is answering once, in its opening line: a card reached by following an
address is answering that address, and a card opened from the rail is
answering nothing in particular. A room link pasted into the locator field
retitles that field and redeems the link instead of asking to enter a name
on a peer. The card's one button is Connect while the named directory has
not answered this tab; that press waits for an answer and names a refusal on
the locator, and an address that has never answered is let go rather than
kept dialing. A directory that answered and then dropped is a standing
condition on the memberships already held: the rooms stay and say not
connected. The four connection words follow that split: connecting while the
first answer is still coming, reconnecting or not connected after a
directory that already answered drops. Those words are a directory's; a
person who is not in the room is offline. After sixty seconds of
unsuccessful automatic reconnects the directory reads not connected and its
card offers Retry connection, which starts a fresh reconnect window.

While that card is the workarea, the rail's room panel is a second view of
it: one room name, one lock, one destination, all read from the card's own
answers and changed from either side. Picking a directory on the panel's
line writes the card's locator exactly as typing in the panel's field writes
the card's room name. Those picks are edits and file no act, so they leave
every other answer standing. The last row of that menu is the way to an
address this tab does not hold, and both surfaces offer it: on the card it
puts the caret in the field the menu hangs from, and from the panel, which
has nowhere to type an address, it hands that same field over. The two
halves stay on screen together; what puts the panel away is a conversation
opening. With a room open, the panel names the directory of the room being
read, and stepping out to another directory is an ordinary press that files
an act and ends in the card's locator field.

`test/intent_test.ts` drives the precedence and `test/routes_test.ts`
drives which act each route files. Other forms hold values that belong to
one control and are cleared when it closes, so they have no act to answer;
a form that starts keeping a value across screens needs one.

## Failures and pending work

A failure lands on the thing that failed, with the retry attached to that
thing, and it interrupts nothing else. In order of preference: the act's own
widget keeps its control and gains the reason, the way a bubble tints "Not
sent" with retry on it and a refused form answer lands beside the field that
asked; the conversation the act belongs to carries a system line when the
act has no widget of its own, with the way forward in the same sentence; a
condition that stays true lives on the surface that owns the claim, the way
the directory card says while nobody can reach you for direct messages; a
toast is for a failure whose home is already gone; and a modal asks only
when nothing can proceed until the reader answers, which today means the
join card and a capability take. Logging a reader-facing failure to the
console instead of one of these is swallowing it, and `zig build
source-check` refuses a bare `console.error` in the page outside the three
files that own a reader-facing surface of their own.

A success says so where the act is too: a checked line of its own under the
actions row ("Listed here as lobby."), never inside the row, so the buttons
keep their place. It can instead be the well changing shape into what the
act made, such as a link's copy field replacing the button that created it.
A form whose only answer to success is that nothing happened has not
answered.

Work in flight follows the same rule without blocking anything. A shape that
will be filled shimmers, the way an attachment does on its way in. A control
that was pressed goes busy where it stands (`Button`'s `busy`, a listener
switch mid-flip). An act worth narrating keeps saying what it is doing and
offers the way to stop it (`WorkingAction`, the join's stop mark). Tab-wide
work is a sentence in the rail's foot ("entering #x…", the reconnect
narration). The word beside a spinner names the act actually running: a
peering row still publishing says "publishing…" rather than lending its
busy state to the Revoke control beside it.

Every sentence a reader sees lives in `lib/text/`, so the product's voice
can be read in one place, and `zig build source-check` refuses a
reader-facing literal in a component.

## Files in the log

How a file is met is decided in one place, `media.ts`, and there are four
answers. A picture draws in the line and opens full-screen, fitted to the
stage; when it is larger than the window, a click or the bar's zoom control
shows it at actual size and the stage scrolls. A video plays where it was
posted and opens full-screen too. Sound gets a player and no viewer, because
a player is the whole of what a listener wants. Everything else is a row
whose one control fetches the bytes and hands them to the browser to save,
in a single press.

Two things make the log settle rather than jump. A sender measures a picture
before posting it and the record carries that shape, so a reader reserves
the right box before the bytes arrive. And that box shimmers while they are
on the way, so a rectangle about to become a picture says so with the space
it is already holding.

The viewer is an overlay over the whole interface, beside Settings in
`App.tsx` rather than inside a message, dismissed by its backdrop and by the
one Escape chain that dismisses every overlay. It carries none of Settings'
chrome: that is a panel because it is a form with fields and a title, while
a picture is the content and a frame around it would only take space from
it.
