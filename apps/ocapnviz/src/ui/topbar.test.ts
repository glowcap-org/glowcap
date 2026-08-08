/**
 * What the top bar refuses while a capture is in flight.
 *
 * A recording cannot outlive the connection it is recording, so every
 * act that leaves Live ends it. There are two: the mode toggle's other
 * two cells, and Open, which replaces the buffer and lands in Play.
 * Both used to do it as a side effect of a click that promised
 * something else — the toggle stopped and claimed the capture on its
 * way out — and both now refuse and name the controls that actually
 * end a recording.
 *
 * The claim worth testing is that the refusal is visible. A disabled
 * control with no tooltip is a dead end, which is the failure mode
 * this pattern trades for: the reader is not allowed to leave and is
 * not told how.
 *
 * Neither control has hooks, so both are called as the plain functions
 * they are.
 *
 * Validated against an injected defect: a toggle that holds only the
 * Play cell leaves Build live, and the first case below fails on it.
 */

import { assert, assertEquals } from "@std/assert";
import { ModeToggle, SaveOpenControls } from "./topbar.tsx";

type Cell = { props: { disabled?: boolean; title?: string; children: string } };

function modeCells(recording: boolean): Record<string, Cell> {
  const el = ModeToggle({ mode: "live", recording, onChange: () => {} });
  const out: Record<string, Cell> = {};
  for (const cell of el.props.children as Cell[]) {
    out[cell.props.children] = cell;
  }
  return out;
}

function saveOpen(recording: boolean): Record<string, Cell> {
  const el = SaveOpenControls({
    recording,
    onNew: () => {},
    onSave: () => {},
    onOpen: () => {},
  });
  const out: Record<string, Cell> = {};
  for (
    const button of el.props.children as {
      props: Cell["props"] & {
        "aria-label": string;
      };
    }[]
  ) {
    out[button.props["aria-label"]] = button as Cell;
  }
  return out;
}

/** The refusal has to point at the way out, or it is a dead end. */
function namesTheWayOut(title: string | undefined): boolean {
  return title !== undefined && title.includes("Stop") &&
    title.includes("Discard");
}

Deno.test("recording holds every cell that would leave Live", () => {
  const held = modeCells(true);
  for (const label of ["Play", "Build"]) {
    assertEquals(
      held[label]!.props.disabled,
      true,
      `${label} still ended the recording on the way out`,
    );
    assert(
      namesTheWayOut(held[label]!.props.title),
      `${label} refused without naming the way out`,
    );
  }
  // Live is where the reader already is, and re-picking it changes
  // nothing, so holding it would be refusing a no-op.
  assertEquals(held["Live"]!.props.disabled, false);
});

Deno.test("with no capture running the toggle is untouched", () => {
  const free = modeCells(false);
  for (const label of ["Live", "Play", "Build"]) {
    assertEquals(free[label]!.props.disabled, false);
    assertEquals(
      free[label]!.props.title,
      undefined,
      `${label} carried a refusal with nothing to refuse`,
    );
  }
});

Deno.test("recording holds both ways out of the buffer, and not Save", () => {
  // New and Open are the same act from the buffer's point of view: each replaces
  // it, so each would end a capture without saying so. Refusing one and not the
  // other is the shape this file exists to catch.
  const held = saveOpen(true);
  for (const label of ["New", "Open"]) {
    assertEquals(
      held[label]!.props.disabled,
      true,
      `${label} still replaced the buffer and left Live mid-capture`,
    );
    assert(
      namesTheWayOut(held[label]!.props.title),
      `${label}'s refusal did not name the way out`,
    );
  }
  // Save reads the document and disturbs nothing, so a capture is no
  // reason to refuse it — and it is how a reader keeps work anyway.
  assertEquals(held["Save"]!.props.disabled, undefined);

  const free = saveOpen(false);
  for (const label of ["New", "Open"]) {
    assertEquals(free[label]!.props.disabled, false);
  }
  assert(free["Open"]!.props.title!.includes("Cmd/Ctrl+O"));
  // New has no chord: Cmd+N is the browser's own and cannot be taken.
  assert(!free["New"]!.props.title!.includes("Cmd/Ctrl"));
});
