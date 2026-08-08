# The live control surface

Status: active plan — reduced to what is left.
[ADR-0106](../decisions/adr/ADR-0106-viz-control-capability.md) holds the
control-capability design (proposed, not implemented). Connecting and capturing
are already split: entering Live dials the feed, and Record starts a capture.
What remains below is two defects in ocapnviz's Live mode, neither of them
started.

## What is left

These defects are independent of ADR-0106 and of each other.

**Transport keyboard shortcuts still work in Live.** Space toggles the clock, R
restarts, and the arrow keys seek, in every mode (`keyboard-shortcuts.ts`).
`startLiveMode` auto-plays the clock, so Space in Live pauses a clock while
events keep appending. That desync is reachable from the keyboard even though
the timeline hides those controls on screen in Live. Disable those three
shortcuts while Live is active.

**Waiting for the first observation looks like an idle feed.** A newly connected
endpoint that has emitted nothing shows the same green "connected" badge and
empty stage as a previously active feed that is currently quiet. The viewer can
distinguish those states by whether it has received any observation. Pressing
Stop on an empty capture calls `claimRecording`, gets null, and returns with no
feedback. Socket and parse failures reach `console.error` instead of the error
toast the application already mounts.
