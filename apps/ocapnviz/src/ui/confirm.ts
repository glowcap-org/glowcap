/**
 * The question a destructive act asks before it runs, and the answer coming
 * back.
 *
 * Three acts in this app take away work a reader cannot get back: switching
 * source, discarding every edit, and recording over a loaded buffer. Each used
 * to ask with `globalThis.confirm`, which was wrong in three ways that had
 * nothing to do with how it looked.
 *
 * It kept none of the app's keyboard contract. `ui/dialog.ts` exists so that
 * focus moves in and cannot leave, Tab wraps, Enter takes the default and Escape
 * dismisses, in every dialog — and the three places where that contract matters
 * most were the three that did not have it.
 *
 * It blocked the event loop, which stops the render loop and the live feed's
 * pump along with it. The Record guard is the sharp case: it stalled the very
 * stream it was asking about.
 *
 * And a browser may suppress it, in which case it returns false and the act
 * silently never happens, with nothing on screen to say so.
 *
 * # The shape
 *
 * A request goes in and a promise comes back, so a caller reads about as it did
 * before. The dialog itself is `ConfirmDialog`, mounted once under the app, which
 * is what keeps the contract one promise rather than one per question.
 *
 * The answer is a plain boolean rather than a thrown cancellation, because
 * "the reader said no" is an ordinary outcome and not an error.
 */

/** What to ask, in the words the reader sees. */
export type ConfirmRequest = {
  /** The question, as a question. It is also the name the dialog is announced
   *  by, so it has to make sense read on its own. */
  title: string;
  /** What going ahead would do, in a sentence. Where the reason lives: a reader
   *  who is about to lose work is owed what and why, not just a warning. */
  detail: string;
  /** The word on the button that goes ahead — an imperative naming the act, so
   *  that a reader who reads nothing but the button still knows what happens.
   *  Never "OK", which is what the browser's own dialog could offer and is the
   *  one word that says nothing. */
  confirmLabel: string;
};

/** A request on screen, waiting to be answered. */
export type PendingConfirm = ConfirmRequest & {
  /** Answer it. Calling this twice does nothing the second time, so Escape and
   *  a click on the same button cannot both resolve. */
  answer: (confirmed: boolean) => void;
};

let pending: PendingConfirm | null = null;
const listeners = new Set<() => void>();

function notify(): void {
  for (const listener of listeners) listener();
}

/**
 * Ask, and resolve with what the reader said.
 *
 * A second question while one is already on screen resolves false rather than
 * queueing. It should not be reachable — the dialog marks the rest of the app
 * `inert` and swallows keystrokes, so nothing behind it can start another act —
 * and if it ever is, refusing is the safe answer for a guard: the act does not
 * happen, and nobody is asked two questions at once.
 */
export function requestConfirm(request: ConfirmRequest): Promise<boolean> {
  if (pending !== null) return Promise.resolve(false);
  return new Promise<boolean>((resolve) => {
    const row: PendingConfirm = {
      ...request,
      answer(confirmed) {
        // Identity, not a null check: this row is only the live one until it is
        // answered, so a late second call cannot clear whatever replaced it.
        if (pending !== row) return;
        pending = null;
        notify();
        resolve(confirmed);
      },
    };
    pending = row;
    notify();
  });
}

/** The question on screen, or null. Referentially stable while it waits, which
 *  is what lets `useSyncExternalStore` hold it. */
export function currentConfirm(): PendingConfirm | null {
  return pending;
}

/** Subscribe to the question changing. `useSyncExternalStore`-shaped. */
export function subscribeConfirm(onChange: () => void): () => void {
  listeners.add(onChange);
  return () => {
    listeners.delete(onChange);
  };
}

/** Test-only. Abandons any question on screen, answering it no so a caller
 *  awaiting one cannot hang, and drops every listener. */
export function _resetConfirmForTesting(): void {
  pending?.answer(false);
  pending = null;
  listeners.clear();
}
