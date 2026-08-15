/**
 * Keyboard shortcut table — the one authority for what each key
 * commands. A shortcut is a data row: the key, the guard facts that
 * must hold (modifier contract, Build-only), and the action.
 * `dispatchShortcut` is the whole interpreter, so adding or
 * changing a shortcut is editing one row, and the table is
 * unit-testable without a browser or React.
 *
 * This table owns one-shot commands only. A key whose meaning is
 * "while held" — Space as the hand tool, Shift and Alt as previews
 * — is a row in `HELD_GESTURES` in `keyboard-input.ts` instead, and
 * `resolveKeyDown` there consults that table first. So a press only
 * reaches this one when no gesture claimed it, and no row here
 * needs a guard describing when a held gesture owns its key. Space
 * appears here as the plain transport toggle for exactly that
 * reason: over the stage the pan claims it and this row is never
 * reached.
 *
 * Tool rows are convenience routing: the app-state reducer's
 * `toolsForMode` check is the authority that refuses an authoring
 * tool outside Build.
 */

import type { Engine } from "../engine/engine.ts";
import type { AppMode, BuilderTool } from "./app-state.ts";

/** Host callbacks a shortcut can invoke, plus the one context fact
 * guards read (`mode`). One object so the React view can publish
 * its freshest render through a ref. */
export interface KeyboardShortcutBindings {
  engine: Engine;
  mode: AppMode;
  onDeselect: () => void;
  onDelete: () => void;
  onSave: () => void;
  onOpen: () => void;
  onPickTool: (tool: BuilderTool) => void;
  /** Cmd-Z: take history back. Not `engine.undo()` straight from the
   *  row, because undoing also walks the selection back onto what the
   *  document then holds, and a key table has no business knowing
   *  that. The host runs both steps, and the top bar's undo button
   *  asks for the same one. */
  onUndo: () => void;
  /** Cmd-Shift-Z / Cmd-Y: take history forward, selection and all. */
  onRedo: () => void;
  /** Cmd-C: extract a payload from the current selection into the
   *  clipboard slot. Host (App) holds the clipboard between copy
   *  and paste; the engine doesn't carry clipboard state. */
  onCopySelection: () => void;
  /** Cmd-V: paste the stashed clipboard payload at the playhead.
   *  No-op when clipboard is empty (no prior copy). */
  onPasteClipboard: () => void;
  /** Cmd-D: extract + immediately paste the current selection
   *  without touching the clipboard. */
  onDuplicateSelection: () => void;
  /** Arrow-key nudge of the current selection (Stage entities).
   *  Returns `true` if it consumed the gesture; falsy → caller
   *  falls back to time scrubbing. The host decides what's
   *  selected and what units the nudge uses. */
  onNudgeSelection: (
    dx: number,
    dy: number,
    opts: { shift: boolean },
  ) => boolean;
}

/** The modifier/key facts of one keydown, DOM-free so the table
 * is testable. `cmd` folds metaKey and ctrlKey (Mac / non-Mac). */
export type KeyEventFacts = {
  key: string;
  cmd: boolean;
  shift: boolean;
  alt: boolean;
  /** True when the browser is auto-repeating a key that is still held.
   *  Every row here is a one-shot command, so a repeat is not a second
   *  press and must not run one. See `dispatchShortcut`. */
  repeat?: boolean;
  /** True when the press landed on a text-editing surface. No row
   *  here may shadow typing, so none runs. See `dispatchShortcut`. */
  textInput?: boolean;
};

type ModifierContract = "required" | "forbidden";

type ShortcutRow = {
  /** `KeyboardEvent.key`, lowercased ("arrowleft", " ", "v"). */
  key: string;
  /** Omitted = the modifier doesn't matter for this row. */
  cmd?: ModifierContract;
  shift?: ModifierContract;
  alt?: ModifierContract;
  /** Row exists only while Build holds mutation authority. */
  buildOnly?: boolean;
  /** Perform the action. Returns whether the browser default
   *  should be prevented. */
  run: (b: KeyboardShortcutBindings, ev: KeyEventFacts) => boolean;
};

/** Scrub stride per arrow press; Shift is the coarse jump. */
const strideOf = (ev: KeyEventFacts): number => (ev.shift ? 1000 : 100);

const SHORTCUTS: readonly ShortcutRow[] = [
  // ── Transport ────────────────────────────────────────────────
  {
    // Space toggles the transport the timeline offers in every
    // mode. Over the stage it never gets here: the `space-pan`
    // gesture claims the press and `resolveKeyDown` returns before
    // reaching this table.
    key: " ",
    run: (b) => {
      b.engine.enqueue({ kind: "toggle" });
      return true;
    },
  },
  {
    key: "r",
    cmd: "forbidden",
    run: (b) => {
      b.engine.enqueue({ kind: "restart" });
      return false;
    },
  },
  // ── Arrows: nudge in Build (a mutation), else scrub ──────────
  {
    key: "arrowleft",
    run: (b, ev) => {
      if (
        b.mode === "build" && b.onNudgeSelection(-1, 0, { shift: ev.shift })
      ) return true;
      b.engine.enqueue({
        kind: "seekTo",
        t: Math.max(0, b.engine.clock.t - strideOf(ev)),
      });
      return true;
    },
  },
  {
    key: "arrowright",
    run: (b, ev) => {
      if (
        b.mode === "build" && b.onNudgeSelection(1, 0, { shift: ev.shift })
      ) return true;
      b.engine.enqueue({
        kind: "seekTo",
        t: Math.min(b.engine.clock.duration, b.engine.clock.t + strideOf(ev)),
      });
      return true;
    },
  },
  {
    // Vertical arrows have no scrub meaning; they only claim the
    // key when a Build nudge actually consumes it.
    key: "arrowup",
    run: (b, ev) => b.mode === "build" && b.onNudgeSelection(0, -1, { shift: ev.shift }),
  },
  {
    key: "arrowdown",
    run: (b, ev) => b.mode === "build" && b.onNudgeSelection(0, 1, { shift: ev.shift }),
  },
  // ── Selection ────────────────────────────────────────────────
  {
    key: "escape",
    run: (b) => {
      b.onDeselect();
      return false;
    },
  },
  {
    key: "delete",
    buildOnly: true,
    run: (b) => {
      b.onDelete();
      return true;
    },
  },
  {
    key: "backspace",
    buildOnly: true,
    run: (b) => {
      b.onDelete();
      return true;
    },
  },
  // ── File (the topbar offers Save/Open in every mode) ─────────
  {
    key: "s",
    cmd: "required",
    run: (b) => {
      b.onSave();
      return true;
    },
  },
  {
    key: "o",
    cmd: "required",
    run: (b) => {
      b.onOpen();
      return true;
    },
  },
  // ── History / clipboard (Build owns mutation) ────────────────
  {
    key: "z",
    cmd: "required",
    buildOnly: true,
    run: (b, ev) => {
      if (ev.shift) b.onRedo();
      else b.onUndo();
      return true;
    },
  },
  {
    // Windows / Linux redo convention; Mac uses Cmd+Shift+Z.
    key: "y",
    cmd: "required",
    buildOnly: true,
    run: (b) => {
      b.onRedo();
      return true;
    },
  },
  {
    key: "c",
    cmd: "required",
    shift: "forbidden",
    alt: "forbidden",
    buildOnly: true,
    run: (b) => {
      b.onCopySelection();
      return true;
    },
  },
  {
    key: "v",
    cmd: "required",
    shift: "forbidden",
    alt: "forbidden",
    buildOnly: true,
    run: (b) => {
      b.onPasteClipboard();
      return true;
    },
  },
  {
    // Cmd-D would otherwise open the browser's bookmark dialog;
    // the preventDefault is load-bearing.
    key: "d",
    cmd: "required",
    shift: "forbidden",
    alt: "forbidden",
    buildOnly: true,
    run: (b) => {
      b.onDuplicateSelection();
      return true;
    },
  },
  // ── Tools (observation tools everywhere, authoring in Build) ─
  {
    key: "v",
    cmd: "forbidden",
    run: (b) => {
      b.onPickTool("select");
      return false;
    },
  },
  {
    key: "h",
    cmd: "forbidden",
    run: (b) => {
      b.onPickTool("hand");
      return false;
    },
  },
  {
    // Cmd-P belongs to the browser (print).
    key: "p",
    cmd: "forbidden",
    buildOnly: true,
    run: (b) => {
      b.onPickTool("add-peer");
      return false;
    },
  },
  {
    key: "s",
    cmd: "forbidden",
    buildOnly: true,
    run: (b) => {
      b.onPickTool("open-session");
      return false;
    },
  },
  {
    key: "m",
    cmd: "forbidden",
    buildOnly: true,
    run: (b) => {
      b.onPickTool("send-message");
      return false;
    },
  },
];

/** Match `ev` against the table and run the first row whose guards
 * hold. Rows are disjoint by construction (a key that appears
 * twice differs in its `cmd` contract), so order between them
 * never decides. Returns whether the caller should
 * `preventDefault()`. */
export function dispatchShortcut(
  ev: KeyEventFacts,
  b: KeyboardShortcutBindings,
): boolean {
  // Two rules the table declares for every row, so they are checked
  // once here rather than repeated per row.
  //
  // A shortcut must never shadow typing.
  if (ev.textInput) return false;
  // A held key auto-repeats, and every row here is a one-shot
  // command, so a repeat is not a second press and must not run one.
  if (ev.repeat) return false;
  const key = ev.key.toLowerCase();
  for (const row of SHORTCUTS) {
    if (row.key !== key) continue;
    if (row.cmd === "required" && !ev.cmd) continue;
    if (row.cmd === "forbidden" && ev.cmd) continue;
    if (row.shift === "required" && !ev.shift) continue;
    if (row.shift === "forbidden" && ev.shift) continue;
    if (row.alt === "required" && !ev.alt) continue;
    if (row.alt === "forbidden" && ev.alt) continue;
    if (row.buildOnly && b.mode !== "build") continue;
    return row.run(b, ev);
  }
  return false;
}
