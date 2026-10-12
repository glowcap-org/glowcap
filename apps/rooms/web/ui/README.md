# The browser page

This is the design contract for the Rooms page. It covers the layout, the shared parts every form is built from, how a
form decides what its fields say, where failures appear, and how files are shown. The [Rooms overview](../../README.md)
walks through the page as a person uses it, and [Developing Rooms](../../developing.md) covers the build and the objects
on the wire.

## Layout

The page has two columns. On the left is a sidebar listing rooms and direct lines. On the right is the workarea for the
conversation you have open: a topbar, the message log, and the composer at the bottom.

- **The conversation card.** Pressing the room or direct-message name in the topbar opens a card with what this tab
  knows about that conversation: the directory that carries it, the session, and the path a direct line takes.
  `/details` (or `/info`) opens the same card. A room's card is where you set your place in the room and where you leave
  it. A direct line's card closes the conversation.
- **The room link.** The room card's Capabilities tab creates the room's durable link when you press the button, then
  shows it for copying. `/link` does the same from the composer.
- **Joining.** `/join` takes a destination, either a room name or a locator. It never refers to the conversation it was
  typed in.

Visual rules:

- The topbar stripe and the welcome card take their color from the sidebar row that opened the conversation. The
  sidebar header's teal-to-orange fade never changes, and orange controls stay orange.
- Wrapped prose on a card, a notice, or the welcome panel never ends with a single word on its last line. A heading on a
  card breaks into even halves.
- A long refusal shows two lines where it appeared, and Show opens the rest on its own card.
- Monospace is for things a person could type: addresses, commands, code, keys, and the clock. It renders larger than
  the sans-serif text, so wherever the two appear together, monospace steps down one size.

## The page and its chunks

`page.js` is the browser entry point, and it loads the React application in `main.tsx`.

- **Production build.** The build runs the app's own Vite configuration through Deno's pinned toolchain and publishes
  the entry as `page.js`.
- **Development.** During `zig build rooms-dev`, the same configuration serves source modules with React Fast Refresh
  and proxies Rooms process endpoints to a temporary loopback backend.
- **Browser support.** Production JavaScript targets Mobile Safari on iOS 26 as the oldest engine, plus current Chrome
  and Firefox. The build adds no legacy bundle and no module-preload polyfill.

Vite splits the code at the points where a reader is already waiting for something:

- The opening screen in `page.html` covers the boot module, the Wasm runtime, and whichever comes next: the session
  choice or the session shell. That next chunk starts loading as soon as the page knows which one it needs, so the
  splash screen does not fade into a second wait.
- Once a session exists, Operations is its own chunk, and each page is another. The directory page's shell stays in the
  Operations chunk, so opening it does not show two loading shimmers in a row.
- Help's parts catalog is the last chunk.
- Hovering or focusing the control that opens a chunk starts its download. A failed prefetch stays silent. If the chunk
  is still missing, opening the surface is what explains it.
- If `import()` refuses a required chunk, the opening screen is marked lost. That rejection does not reach the window's
  error handler, so the page handles it directly.
- While a chunk loads, the page shows the same quiet shimmer an Operations page uses while waiting for its first answer
  from the server.

The component folders follow visual ownership:

- `shell/` composes the page frame.
- `cards/` holds focused subject cards.
- `panes/` holds the conversation and modal work surfaces.
- `settings/` holds the settings surface and its sections.
- `ops/`, `sidebar/`, `composer/`, and `message/` each own a narrower domain.
- Reusable controls and composition helpers stay at this directory's root.

State lives in three places:

- **The store.** One Zustand store holds the facts the page draws, and components subscribe through `useRoomsState`
  selectors. It has no persistence middleware and holds no live capability. Rust holds every reference. The store holds
  only what to draw.
- **The component.** State that belongs to one control stays in that component, such as an open emoji tray or the
  composer caret.
- **Never the DOM.** An element's own value outlives the control being closed or the conversation being switched, and
  would come back carrying an old intention. So UI state is never read from the DOM.

## Shared form parts

Every card and page builds its forms from one set of parts. The styles are in `forms.css`, beside the components
`Field`, `Confirm`, `ModalHead`, and `Button`. Help's parts catalog shows each part next to the others.

### Fields

A question is a `Field`. It wires together a label, the refusal its answer received, the control, and a sentence under
the control. Screen readers announce all three in the order they appear.

The two slots around a control hold different things, and every form on the page keeps this rule:

- **Above the control** goes what the reader must fix before the answer is accepted: the refusal.
- **Below the control** goes what only informs the answer: the guidance sentence.

Keeping them apart means a refusal never pushes out the guidance that would fix it. On a phone, it also keeps the
refusal above the on-screen keyboard instead of hidden behind it. Every field-level refusal goes through `Field`, so
this order is enforced in one place.

A single-line field is the standard touch height (`--field-h`). A button next to it in a `field-row` lines up with the
control.

### Actions and confirmation

The actions a surface offers sit in an `actions` row at the end of the line they belong to, with the committing action
last. Only a card's own footer spans the full width. A row holds at most two acts, which fit a card on any screen. A
well that offers more gives each its own line with `EntryActs`: the subject, then its one act at the column's right
edge. An act that answers a status, such as Reconnect, sits on the line that states it.

When one slot shows different actions by state, each gets its own `key`. React otherwise reuses the element, and a click
that changes the state runs its default action on the new one, so a Done that becomes a submit button submits the form.

An action that takes something away ends its label with an ellipsis and opens an inline `Confirm`. The confirm says in
one sentence what will be lost, then offers a way out and a red button that commits. So leaving, deleting, or revoking
never looks like the same button as joining. When a confirm opens, focus moves to the way out. Escape also takes the way
out and stays inside the card. Choosing to keep returns focus to the action that asked.

### Lists, doors, and sections

- **`entries`** is a list of things the surface knows about. Each entry has a head (the name, a short fact, and its
  actions at the end of the line), with longer facts underneath.
- **`launch`** is a row that opens another card: a mark, a name, one sentence, and the action at the end.
- **`choices`** is a question with one answer from several: one box with a row per answer, and the chosen row tinted. A
  row may hold what its answer opens, such as the checkboxes under Custom, lined up with the row's words.
- **Sections** are an overline title over a `well`.

Session setup, the Session, Holdings, and Reachability tabs, the room and directory cards, and every Operations page use
only these parts. A form in one of them looks like a form in all the others.

The Settings tabs are divided by subject:

- **Reachability** holds the locators.
- **Session** holds where the session lives and what it keeps.
- **Holdings** holds what the session is holding: room links, archive peers and their shares, operations capabilities,
  the attached-session link, and access grants.

### Sub-cards and files

A form that takes a pasted capability opens its own card instead of sitting on the tab that owns the subject. Attaching
a session, choosing an archive peer, issuing access, and replacing stored state each open a `Submodal`. A label ending
in an ellipsis means the press opens a card rather than committing, and the commit button is at the foot of the card it
opens.

Closing Settings with an unsaved form asks first. Settings switches to the tab with the change and shows a `Confirm`
above that form, so the reader sees what is at stake where they left it.

A file picker is a `FilePick`: the platform's own file input, made transparent and laid over a face the page draws. The
page does this because the platform's control cannot be styled.

## The operator page

The operator page is built for a directory with more rows than fit on one page.

- Each inventory offers its rows as sources with two parts: the lowercased text a search matches, which every row
  provides, and the work of building the row, which only rows on the requested page pay for.
- A count is the directory's own number of matches, not the number of rows sent. So searching a hundred thousand rooms
  costs a hundred thousand string tests, not a hundred thousand member lists.
- Every category looks the same: the wire row, plus the action that retires it where one exists. Search, paging, and
  bulk retire are written once.
- Bulk retire handles a bounded number of rows per call and reports how many still match. A sweep over a large inventory
  can stop partway without losing its progress.

## How a form decides its answers

An empty field is an answer to a question. Opening a room from a link, pressing "add a room" in the
sidebar, and loading the page fresh ask different questions, and one saved form cannot answer all three.

`intent.ts` decides. Every surface that can put a question in front of the reader files an **act**: a record of where
the reader came from and what that names. Each field then takes its value from the strongest evidence available:

| Evidence  | Means                                                                            |
| --------- | -------------------------------------------------------------------------------- |
| `edited`  | The reader typed it here, under this act.                                        |
| `named`   | The act said it outright. A link to `/room/general` names that room.             |
| `implied` | The act did not say it, but where it happened allows only one reading.           |
| `recent`  | Not in this act at all: what this browser used last, saved when a join succeeds. |
| `default` | Nobody has an answer, so the application offers its own.                         |

An act has one of three sources, and each is something the reader did:

- `press`: a control on this page.
- `link`: an address the reader followed or typed.
- `restore`: this browser reopening what it had open.

When the application shows something on its own, it files no act. Filing one would put words in the reader's mouth.
Filing none leaves the last real answer in place, and leaves anything half-typed where the reader left it.

Two consequences are easy to get wrong:

- **An act that names an empty value still beats a remembered one.** A link to a room in this page's own directory says
  nothing about where. That silence means "here", and it is an answer.
- **An override belongs to the act it was typed under.** When the reader goes somewhere else, it is dropped, without
  anything needing to clear it.

`test/intent_test.ts` covers the precedence, and `test/routes_test.ts` covers which act each route files. Other forms
hold values that belong to one control and are cleared when it closes, so they need no act. A form that starts keeping a
value across screens needs one.

### The join card

The join card, in `joining.ts`, is where this is used.

- It states what it is answering once, in its opening line. A card reached by following an address is answering that
  address. A card opened from the sidebar is not answering anything in particular.
- Pasting a room link into the locator field retitles that field and redeems the link, instead of asking for a room name
  on a peer.
- While the named directory has not yet answered this tab, the card's one button is Connect. Pressing it waits for an
  answer, and shows any refusal on the locator field. An address that has never answered is dropped rather than dialed
  again and again.

The connection words separate a directory that never answered from one that answered and then dropped:

- **connecting**: the first answer is still on its way.
- **reconnecting**: the directory answered before, dropped, and the page is trying again.
- **not connected**: the directory answered before and is still unreachable. After sixty seconds of failed automatic
  reconnects, the directory shows not connected, and its card offers Retry connection, which starts a fresh reconnect
  window.

When a directory drops, the rooms you already joined stay in the sidebar and show not connected. These words describe a
directory. The roster lists current room members. Leaving removes that membership,
while their messages remain. Directory registration and a direct line have their
own lifetimes, so leaving a room does not disconnect either.

A direct line displays CLOSED when its saved route has ended and needs a fresh
introduction. Its history remains readable. Exporter loss closes the exact saved
DM even if readiness failed. A refused workspace update retains that retirement
for retry.

### The sidebar's room panel

While the join card fills the workarea, the sidebar's room panel is a second view of the same card: one room name, one
lock, one destination. Both read from the card's answers, and a change on either side shows on both.

- Picking a directory in the panel writes the card's locator, just as typing in the panel's field writes the card's room
  name. These picks are edits, so they file no act and leave every other answer in place.
- The last row of the directory menu is for an address this tab does not know yet, and both surfaces offer it. On the
  card, it puts the caret in the field the menu hangs from. The panel has nowhere to type an address, so it hands over
  that same field.
- The two stay on screen together until a conversation opens, which puts the panel away.
- With a room open, the panel names the directory of the room you are reading. Switching to another directory is an
  ordinary press: it files an act and ends in the card's locator field.

## Failures and pending work

A failure appears on the thing that failed, with the retry attached to it, and it interrupts nothing else. In order of
preference:

1. **The action's own widget** keeps its control and shows the reason. A message bubble shows "Not sent" with a retry,
   and a refused form answer appears above the field that asked.
2. **A system line in the conversation**, when the action has no widget of its own. The line includes the way forward.
3. **The surface that owns the claim**, for a condition that stays true. For example, the directory card says so while
   nobody can reach you for direct messages.
4. **A toast**, for a failure whose home is already gone.
5. **A modal**, only when nothing can continue until the reader answers. That means the join card and taking a capability.

Logging a failure to the console that the reader should see hides it. `zig build source-check`
refuses a bare `console.error` in the page, except in the three files that own a reader-facing surface of their own.

A success is also shown where the action happened:

- As its own checked line under the actions row ("Listed here as lobby."), never inside the row, so the buttons stay
  put.
- Or as the well changing into what the action made, such as a link's copy field replacing the button that created it.

A form that shows nothing on success has not answered the reader.

Pending work belongs to the initiating gesture. `session/managed/lifecycle.ts` records its owner, phase and outcome
separately. Preparation, admission, settlement, acquisition and completion remain owned through notifications. The
session-effect bar lists retained operations explicitly left without an owner after a failure or restoration. An
interrupted reply never proves that a mutation failed.
Session settings also opens the retained receipt inventory explicitly, including terminal unknown outcomes whose
observation has ended. An empty inventory says that there are no unfinished changes.

`session/managed/gestures.ts` covers the generated command inventory. Repeated controls share their submitted request.
New posts keep distinct operation identities even when their text is equal. Mutations of one line conflict, as do
retirement and use of its conversation or directory. Independent rooms continue. Only admission takes turns on the
workspace revision. Settlement and draft synchronization proceed independently. The existing effect limit bounds
retained gestures. Saturation asks the reader to finish or recover work already held. `local_gestures.ts` checks
acquisition and controller read coverage. Acquisitions retain at most 32 requests, shared workspace reads at most eight
workers, and each composer permits one queued submission beside its active send. History keeps one serialized read owner
and previews use the existing bounded cache. Startup makes one pass over the eight-receipt inventory. The capability
caller bounds each observation at 15 seconds. The runtime owns its 20-second executor observation windows. The UI adds
no transient retry loop. Only proved revision conflicts permit up to four admissions, each checked against the original
selection. Simple workspace settings fence their original value. Retention also fences unfinished erasure.
Unrelated room supervision leaves these settings available. Diagnostics on a retained operation show its elapsed time, owners and last eight phase transitions without
storing message bodies or capabilities. Session resource counts include active workers, reads, receipts, listeners and
subscriptions and return to zero on close.

Presentation follows `presentation.ts`:

| Feedback                                                                                 | Delay                        |
| ---------------------------------------------------------------------------------------- | ---------------------------- |
| Pressed control's busy decoration                                                        | 400ms                        |
| Sending message                                                                          | 1s                           |
| Joining or reconnecting decoration                                                       | 2s                           |
| Failure, permission change, disabling a conflicting control, releasing a settled control | Immediate                    |
| Supported Stop action                                                                    | Immediate, in reserved space |

Each run has a monotonic start time and a retirement token. Background-tab wake reads elapsed time and current state. A
feedback slot may hand off to a confirmed result for the remainder of its 500ms minimum. A surface without a truthful
result treatment clears progress immediately. Neither the minimum nor a delayed spinner extends the effect, keeps a
settled control disabled, or postpones a failure.

`useAsyncAction` owns a control's refusal and cancellation signal. Stop requests cancellation at the worker. Its
existing run remains shared until it drains. Closing a card drops its presentation, while the session keeps admitted
work and its original receipt. A committed effect with a failed acquisition recovers that acquisition. A partial file
send retains its posted line. No recovery path creates a replacement send from the bubble's text.

Text edits project a pending version over the accepted line. A newer accepted update wins when the edit settles.
Withdrawal hides only the initiating line's pending change. Its place and refusal remain visible. Standing projects
the pending change over accepted state. Draft synchronization retains editable local text and one persistent retry notice
inside the composer above its text field. Long diagnostics open through the notice's detail card. Retry requires
current participation access. A retained committed request completes without opening privileged receipt recovery.
Access edits keep conflict and uncertain-result recovery beside the original control, with the current name or
permission summary when the control can inspect a conflicting edit. Recovery remains reachable when refresh
removes editing powers. Entry action groups wrap within their row on phones.
Typing expires with its authority and records a bounded diagnostic instead of a toast per keystroke. Sidebar-close and
archive-drop refusals stay on their rows. Closing a surface or choosing a different conversation prevents a late
completion from reopening the original controls.

A room post carries a bounded operation identity to its own membership's notification. The page reconciles that identity
with its optimistic bubble before rendering an echo. Nickname, text and arrival order establish no match. The optimistic
DOM node survives confirmation. Other viewers' posts remain distinct. Room presentation follows the persistent
conversation id. Membership generation still retires line authority. Archive refresh preserves unaffected rows, and a
retired request cannot resurrect a revoked row.

Progress and results use scoped status regions. Refusals use the initiating surface's alert. Keyboard and pointer
activation share the same guard. Reduced motion changes animation without removing state information or Stop.

`async_action_test.ts` covers cancellation and timing boundaries. The managed admission, acquisition, draft, projection
and send-receipt suites cover ownership, exact replay, overlap and identity. `rooms-web-responsiveness` runs the
production page as two people over a delayed transport, observes intermediate DOM mutations, and reports the browser,
event volume, queue peak and input latency, enforcing 100ms local feedback and 50ms main-thread task budgets on its
declared profile.

Every sentence a reader sees lives in `lib/text/`.
`zig build source-check` refuses a reader-facing string literal in a component.

## Files in the log

`media.ts` decides how a file is shown, and there are four cases:

- **A picture** shows in the message line and opens full-screen, fitted to the window. If it is larger than the window,
  a click or the zoom control shows it at actual size, and the view scrolls.
- **A video** plays where it was posted and also opens full-screen.
- **Audio** gets a player and no viewer, because a player is all a listener needs.
- **Anything else** is a row with one control, which fetches the bytes and hands them to the browser to save in a single
  press.

Two things keep the log from jumping as files arrive. The sender measures a picture before posting it, and the message
records that size, so a reader reserves the right space before the bytes arrive. That space shimmers while the bytes are
on their way, so the reader can see a picture is coming.

The viewer is an overlay over the interface. It sits beside Settings in `App.tsx`, not inside a message. Clicking
its backdrop dismisses it, as does Escape, which dismisses every overlay the same way. It has none of Settings' frame.
Settings is a panel because it is a form with fields and a title. A picture is the content itself, and a frame would
only take space from it.
