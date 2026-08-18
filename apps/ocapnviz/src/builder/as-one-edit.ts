/**
 * Run a closed set of dispatches as one undo step.
 *
 * The engine records history only at transaction depth zero, so a
 * transaction that opens and never closes does not just lose its own
 * step: it swallows every dispatch after it, and from that moment
 * nothing in the app is undoable. Nothing says so, which is what makes
 * it expensive.
 *
 * A run of dispatches with a `beginTransaction` above it and an
 * `endTransaction` below it is one `parseEntityKey` on a bad key away
 * from exactly that, and the `finally` is the only spelling that
 * cannot be reached around. Written once here so a caller opens a
 * transaction by naming what the step is called and what is in it,
 * and never by remembering to close one.
 *
 * This is for a run that begins and ends in one call. A gesture that
 * opens on one event and closes on another — a drag, a scrub, a typing
 * burst — cannot use it, and takes the Inspector's `editBracket`
 * instead, which knows whether it is open and closes itself when its
 * control goes away.
 */

import type { Engine } from "../engine/engine.ts";

export function asOneEdit(
  engine: Engine,
  label: string,
  body: () => void,
): void {
  engine.beginTransaction(label);
  try {
    body();
  } finally {
    engine.endTransaction();
  }
}
