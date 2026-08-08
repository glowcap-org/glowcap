/**
 * The one keyboard authority: which held gesture is acting right
 * now, and — only when none is — which one-shot command a press
 * runs.
 *
 * A key whose meaning is "while held" is a row in `HELD_GESTURES`:
 * an id, the key spellings that press it, and the guard that
 * decides at the press whether it claims. A claim then latches
 * until the key is released or the window loses focus, so the fact
 * that granted it may change underneath without changing what the
 * key is doing. That is the point of the latch. Space claims the
 * hand tool because the pointer was over the stage; the pointer
 * then leaving the canvas mid-pan must not turn the pan into a
 * transport toggle.
 *
 * A claim says what a key offers, and it ends at the key's release.
 * It does not say what became of a gesture the key started: a press
 * made under a claim resolves to a verb, and from then on the
 * pointer FSM owns it. Releasing Space during a pan leaves a pan
 * running; releasing it during a marquee that Space interrupted
 * puts the marquee back. This layer cannot tell those apart and
 * does not try. A reader that must know what is *happening* asks
 * `inFlightGesture` in `interactions/pointer-machine.ts`; a claim
 * answers only what is *offered*.
 *
 * Precedence is a function call rather than a listener
 * registration. `resolveKeyDown` consults the held table first and
 * reaches `dispatchShortcut` only when nothing claimed the press,
 * so the order is in the code. Two listeners on the same event
 * could not express it: whichever the browser called first would
 * decide. So there is one listener, `useKeyboardInput` in
 * `hooks.ts`, and it calls this.
 *
 * Registering a held gesture is one row here, plus its id in the
 * union above. That row buys the whole lifecycle: the claim, the
 * keyup and blur releases, and the refusal to also run a one-shot
 * command on the same press, even when the key already has a
 * `SHORTCUTS` row. Whatever wants to act on the gesture reads it
 * out of the held set, the way App reads `space-pan` for the
 * cursor.
 *
 * Pure and DOM-free, like the shortcut table it fronts.
 */

import type { ModifierSet } from "../interactions/types.ts";
import {
  dispatchShortcut,
  type KeyboardShortcutBindings,
  type KeyEventFacts,
} from "./keyboard-shortcuts.ts";

/** Every gesture whose meaning is "while this key is held". */
export type HeldGestureId = "space-pan" | "shift" | "alt";

/** App facts a claim guard may read. Sampled at the press and not
 *  consulted again for the life of that hold. */
export type HeldGestureContext = {
  /** The pointer's topmost hit target is the stage canvas
   *  (`useOverStage`). */
  overStage: boolean;
};

export type HeldGestureRow = {
  readonly id: HeldGestureId;
  /** Lowercased `KeyboardEvent.key` spellings that press this
   *  gesture. Older browsers still send "Spacebar" for space. */
  readonly keys: readonly string[];
  /** Whether this press claims the gesture. Asked once, on the
   *  rising edge.
   *
   *  A claim consumes the press, so a guard that never declines
   *  makes this key unreachable as a one-shot command. That is
   *  right for `shift` and `alt`, which command nothing on their
   *  own. It would silently retire a `SHORTCUTS` row for a key that
   *  has one. */
  readonly claimWhen: (ctx: HeldGestureContext, ev: KeyEventFacts) => boolean;
  /** Whether a press this gesture holds should `preventDefault()`.
   *  Space would scroll the page otherwise. */
  readonly preventDefault: boolean;
};

export const HELD_GESTURES: readonly HeldGestureRow[] = [
  {
    // Adobe / Macromedia convention: Space held is a temporary hand
    // tool. It claims over the stage in every mode, because panning
    // mutates nothing. Anywhere else Space is the transport toggle
    // and the shortcut table owns it, which is why this guard is
    // the only place the stage-versus-elsewhere split is decided.
    id: "space-pan",
    keys: [" ", "spacebar"],
    claimWhen: (ctx, ev) => ctx.overStage && !ev.textInput,
    preventDefault: true,
  },
  {
    // Shift and Alt preview what a click or drag would do — the
    // "copy" cursor for add, "no-drop" for remove. They claim
    // everywhere, including over a focused text field, because a
    // modifier held while typing still modifies the next pointer
    // gesture.
    id: "shift",
    keys: ["shift"],
    claimWhen: () => true,
    preventDefault: false,
  },
  {
    id: "alt",
    keys: ["alt"],
    claimWhen: () => true,
    preventDefault: false,
  },
];

/** The gestures whose keys are down at this instant. */
export type HeldGestures = ReadonlySet<HeldGestureId>;

export const NO_HELD_GESTURES: HeldGestures = new Set<HeldGestureId>();

/** True while the key itself is down, which is the whole of what a
 *  claim asserts. */
export function isClaimed(held: HeldGestures, id: HeldGestureId): boolean {
  return held.has(id);
}

/** Whether a modifier named like a gesture is down: only a modifier the
 *  table above tracks can be, and only while its row is claimed. A name with
 *  no row is not watched by anything, so it is never held. */
function modifierClaimed(held: HeldGestures, name: string): boolean {
  for (const row of HELD_GESTURES) {
    if (row.id === name) return held.has(row.id);
  }
  return false;
}

/**
 * The pointer layer's modifier set, answered from the held gestures.
 *
 * Which modifiers this app watches is `HELD_GESTURES` and nothing else, so
 * every field is asked of that table rather than stated here. Cmd currently
 * has no row — nothing about the canvas changes while it is down on its own,
 * and its click verb draws the same cursor as the plain one — and it reads
 * false because the table says nothing about it. Giving it a row is therefore
 * the whole of making the cursor watch it; there is no second place that
 * remembers Cmd is not watched.
 */
export function heldModifiers(held: HeldGestures): ModifierSet {
  return {
    shift: modifierClaimed(held, "shift"),
    alt: modifierClaimed(held, "alt"),
    cmd: modifierClaimed(held, "cmd"),
  };
}

function withClaim(held: HeldGestures, id: HeldGestureId): HeldGestures {
  const next = new Set(held);
  next.add(id);
  return next;
}

/** Index a held-gesture table by key spelling, refusing a table
 *  where two gestures answer to the same key. One key means one
 *  gesture: if two rows shared a spelling, whichever came first
 *  would silently shadow the other, and the shadowed one would look
 *  registered while never claiming. */
export function indexHeldGestures(
  rows: readonly HeldGestureRow[],
): ReadonlyMap<string, HeldGestureRow> {
  const byKey = new Map<string, HeldGestureRow>();
  for (const row of rows) {
    for (const key of row.keys) {
      const clash = byKey.get(key);
      if (clash) {
        throw new Error(
          `held gesture key "${key}" is claimed by both ` +
            `"${clash.id}" and "${row.id}"`,
        );
      }
      byKey.set(key, row);
    }
  }
  return byKey;
}

const BY_KEY = indexHeldGestures(HELD_GESTURES);

/** The gesture a key spelling presses, or `null` for a key that is
 *  not a held gesture at all. `key` must already be lowercased. */
function heldGestureFor(key: string): HeldGestureRow | null {
  return BY_KEY.get(key) ?? null;
}

/** What a press turned out to mean. */
export type KeyPress =
  /** A held gesture took this press and holds until its release. */
  | { kind: "claim"; id: HeldGestureId }
  /** The key is already held. A repeat is not a second press, and
   *  the claim decides the meaning until the release. */
  | { kind: "holding"; id: HeldGestureId }
  /** No gesture wanted it, so the one-shot table saw it. */
  | { kind: "command"; consumed: boolean }
  /** No gesture wanted it and no shortcut bindings are attached. */
  | { kind: "none" };

export type KeyDownResult = {
  /** The held set after this press. The same instance when the
   *  press changed nothing, so a React caller can skip a render. */
  held: HeldGestures;
  press: KeyPress;
  /** Whether the caller should `preventDefault()` the event. */
  preventDefault: boolean;
};

/**
 * Resolve one keydown: held gestures first, one-shot commands
 * second.
 *
 * `bindings` is the shortcut table's host callbacks, or `null` when
 * no view has attached them yet; a press then resolves gestures and
 * runs no command.
 */
export function resolveKeyDown(
  held: HeldGestures,
  ev: KeyEventFacts,
  ctx: HeldGestureContext,
  bindings: KeyboardShortcutBindings | null,
): KeyDownResult {
  const row = heldGestureFor(ev.key.toLowerCase());
  if (row !== null) {
    if (held.has(row.id)) {
      // The user has not let go. Whatever the guard's facts have
      // done since the press, this key still means what it claimed.
      return {
        held,
        press: { kind: "holding", id: row.id },
        preventDefault: row.preventDefault,
      };
    }
    // A repeat continues a claim; it never starts one. A gesture
    // begins on the rising edge or not at all.
    if (!ev.repeat && row.claimWhen(ctx, ev)) {
      return {
        held: withClaim(held, row.id),
        press: { kind: "claim", id: row.id },
        preventDefault: row.preventDefault,
      };
    }
  }
  if (bindings === null) {
    return { held, press: { kind: "none" }, preventDefault: false };
  }
  const consumed = dispatchShortcut(ev, bindings);
  return {
    held,
    press: { kind: "command", consumed },
    preventDefault: consumed,
  };
}

/** End the claim `key` was holding. A gesture the key started is
 *  not affected: it belongs to the pointer, and the FSM ends it.
 *  Returns the same instance when the key held nothing. */
export function resolveKeyUp(held: HeldGestures, key: string): HeldGestures {
  const row = heldGestureFor(key.toLowerCase());
  if (row === null || !held.has(row.id)) return held;
  const next = new Set(held);
  next.delete(row.id);
  return next;
}

/** Drop every claim. The window lost focus, so no keyup is coming
 *  for anything still down, and an alt-tab must not strand the
 *  cursor in a grab. */
export function resolveBlur(held: HeldGestures): HeldGestures {
  return held.size === 0 ? held : NO_HELD_GESTURES;
}
