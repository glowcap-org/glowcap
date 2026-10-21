---
type: static
description: Why the app has Live, Play and Build modes over one document buffer instead of a playback mode with a live flag.
sources:
  - resource: /apps/ocapnviz/src/state/
---

# Live, Play, and Build

The app has three top-level modes over one document buffer, not a playback mode
with a live flag. `AppMode` and `recording` live in `src/state/app-state.ts`,
and `useBufferEngine` and `useLiveConnection` live in `src/state/hooks.ts`.

## Why not a live flag

`mode = {play, build}` crossed with `liveMode = {on, off}` is four cells and
only three ideas. Build with the live flag on is meaningless, because Build is a
working copy with its own engine and nothing the live socket writes is ever read
there. That combination admits inconsistent controls: a source picker offering "go
live" in Build, a timeline offering "follow live" in Build, and a websocket
running in the background while Build ignores it.

Live is not a mode of operating on the buffer. It is a way of filling it.
Forcing it into a playback variant ties it to playback's UI, which means a
playhead, a scrubber, and follow-live over a feed that only goes forward.

## The buffer

The app holds one document buffer at a time. Four things fill it: opening a
file, picking a fixture, recording from a live feed, and Build editing it in
place. Save writes it out and stays available in every mode, including during a
capture.

The three modes are three verbs against that buffer.

- **Live** taps a feed. Entering the mode connects. Events draw on the stage
  only while recording, and the buffer is not involved unless you are recording.
  Scrubbing and playback mean nothing here.
- **Play** replays the buffer, with the playhead, scrubbing, and speed.
- **Build** edits the buffer.

| Transition         | What happens                                                                                            |
| ------------------ | ------------------------------------------------------------------------------------------------------- |
| Play to Build      | Fork the buffer into a working copy. The copy keeps its own layout mode, and an authored position pins. |
| Build to Play      | Edits are captured back into the buffer, and the source panel flags it as edited.                       |
| anything to Live   | Connect. The stage stays blank and the buffer is untouched until Record.                                |
| Live to Play/Build | When idle, disconnect and preserve the buffer. While recording, these transitions are unavailable.     |
| Record starts      | If the buffer is non-empty and unsaved, warn before clearing it.                                        |
| Record stops       | Claim the recording as the buffer and enter Play.                                                       |
| Record discards    | Throw away the capture and remain connected in Live.                                                    |

The loaded document means the same thing in every mode, so Play replaying a
fixture, a live recording, or an opened file is one code path, and Build editing
any of them is another.

## Alternatives

**Keep the flag and hide the UI in Build.** The degenerate cell and the "live is
a flavor of playback" framing survive, and the next feature that reaches for a
live scrubber reopens the same class of bug.

**Make Live a flavor of Play, with the feed extending the buffer.** A forward-only
feed cannot be scrubbed or played, so each of Play's verbs would need special
handling. Separate modes are cheaper than teaching one transport UI to handle a
feed that cannot seek.

**Record implicitly, with Live itself as the bracket.** This commits the buffer
the moment you click Live. Live without Record keeps the connection warm and
shows whether the feed is there, without committing memory to a capture.

## What each mode shows

In **Live** the stage stays blank until Record, then draws arriving events and
accumulates them into the capture. Play, pause, restart, and speed are replaced
by Record and a duration readout. The scrubber is hidden, because there is no
seekable time. The Inspector works and is read-only, since Build is the only
mode that injects editor bindings. The source picker shows the feed URL and its
connection dot, and nothing else.

In **Play** the stage replays the buffer with the full transport, the scrubber,
and the overview. The source picker offers fixtures and files.

In **Build** the stage carries the authoring tools, the timeline carries the
scrubber and the event handles, and there are no transport controls.

## State

`AppState` in `src/state/app-state.ts` carries `mode: AppMode` and a
`liveSturdyref` that persists across modes and is read only in Live. Whether a
capture is running is not app state: `App` holds a `recording` flag beside the
buffer engine and passes it to `useLiveConnection`, because it lasts as long as
the session and nothing reloads into the middle of one.

The `?live=<sturdyref>` query parameter sets both the mode and capability on
load. Play and Build have no deep link.

`useBufferEngine` backs Play and Build from the fixture, file, or recording.
`useLiveConnection` holds the feed and, while recording, mounts a capture engine
that appends arrivals to the buffer and draws them.
