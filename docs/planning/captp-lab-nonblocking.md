Status: active plan

# CapTP lab: nonblocking turns

## Goal

The TUI CapTP lab must not freeze the prompt while `call` / `fetch` (and
queued session verbs) wait for settlement. A pending turn shows a spinner on
its transcript line; the prompt stays usable; CapTP verbs FIFO-queue; local
lab commands (`tour`, `help`, `focus`, `?`, `quit`) run immediately; Esc
cancels the active wait.

## Why not a worker thread

`driver.Host` pins an owning thread under runtime safety (`assertOwner`). The
lab already pumps the session on the UI thread (`stepReadable(0)`). CapTP
waits therefore stay on that thread: `send` / `beginFetch` + `on` + cooperative
`stepReadable` until the vow settles, with spinner frames between pumps.

## Shape

- `cli/repl/await_queue.zig`. FIFO of owned lines + one heap-pinned active wait
  (`SettleCapture` + `SettleFlag`).
- Session verbs enqueue; `registry.dispatch` is not used for those in the TUI
  path while awaiting.
- Cancel / settle timeout: `Session.breakFarVows` with a stable reason string
  (`"cancelled"` / `"wait timed out"`), same as the blocking settle path.
- Line-mode REPL stays synchronous (no spinner).

## Out of scope (for this plan)

- True overlapping in-flight CapTP turns
- Canceling queued (not yet active) items except by draining after active cancel
  (v1: Esc cancels active only; queue remains)
