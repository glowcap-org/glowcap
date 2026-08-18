/**
 * These tests pin the one question the keyboard authority answers:
 * what does this press mean right now, given what is already held.
 *
 * The defect they exist to close is a fact with two
 * representations. "Is Space acting as the hand?" used to be
 * decided twice: latched at the press by one hook, and re-derived
 * from the pointer's position by the shortcut table on every event.
 * The two answers only agreed while nothing moved. Dragging the
 * pointer off the canvas mid-pan made the table answer differently
 * from the latch, and the transport toggle fired underneath a pan
 * that was still happening, stopping a live recording.
 *
 * So the tests below lean on the case where a claim's own reason
 * stops being true while the key is still down. A design that
 * re-derives fails them; a design that latches passes them.
 *
 * What they deliberately do not cover is what a gesture *became*
 * once a press was made under a claim. That belongs to the pointer
 * FSM, which is the only layer that knows, and asking this one
 * would put a second answer where there should be one.
 *
 * Pure: no DOM, no React.
 */

import { assertEquals, assertStrictEquals, assertThrows } from "@std/assert";
import {
  HELD_GESTURES,
  type HeldGestureContext,
  type HeldGestures,
  heldModifiers,
  indexHeldGestures,
  NO_HELD_GESTURES,
  resolveBlur,
  resolveKeyDown,
  resolveKeyUp,
} from "./keyboard-input.ts";
import type { KeyEventFacts } from "./keyboard-shortcuts.ts";
import { recordingBindings } from "./keyboard-shortcuts.fixture.ts";

function key(k: string, mods?: Partial<KeyEventFacts>): KeyEventFacts {
  return { key: k, cmd: false, shift: false, alt: false, ...mods };
}

const OVER_STAGE: HeldGestureContext = { overStage: true };
const OFF_STAGE: HeldGestureContext = { overStage: false };

/** The gestures whose keys are down. */
const claimed = (held: HeldGestures) => [...held].sort();

/** Feed one keydown through the authority with recording bindings
 *  attached, so a test can assert on both halves of the answer:
 *  what is held, and what ran. */
function press(
  held: HeldGestures,
  ev: KeyEventFacts,
  ctx: HeldGestureContext,
  bindings = recordingBindings(),
) {
  const result = resolveKeyDown(held, ev, ctx, bindings.b);
  return { ...result, calls: bindings.calls };
}

Deno.test("Space over the stage claims the pan, and commands nothing", () => {
  const r = press(NO_HELD_GESTURES, key(" "), OVER_STAGE);
  assertEquals(r.press, { kind: "claim", id: "space-pan" });
  assertEquals(claimed(r.held), ["space-pan"]);
  assertEquals(r.calls, []);
  // The page would scroll otherwise.
  assertEquals(r.preventDefault, true);
});

Deno.test("Space off the stage commands the transport, and holds nothing", () => {
  const r = press(NO_HELD_GESTURES, key(" "), OFF_STAGE);
  assertEquals(r.press, { kind: "command", consumed: true });
  assertEquals(claimed(r.held), []);
  assertEquals(r.calls, ["enqueue:toggle"]);
});

Deno.test("a claim outlives the fact that granted it", () => {
  // This is the defect, stated directly. The pan claims because the
  // pointer is over the stage; the pointer then leaves the canvas
  // while the key is still down. The press must go on meaning what
  // it claimed, whether the browser re-delivers it as an
  // auto-repeat or as a bare keydown.
  const held = press(NO_HELD_GESTURES, key(" "), OVER_STAGE).held;

  const repeat = press(held, key(" ", { repeat: true }), OFF_STAGE);
  assertEquals(repeat.press, { kind: "holding", id: "space-pan" });
  assertEquals(claimed(repeat.held), ["space-pan"]);
  assertEquals(repeat.calls, []);

  const again = press(held, key(" "), OFF_STAGE);
  assertEquals(again.press, { kind: "holding", id: "space-pan" });
  assertEquals(claimed(again.held), ["space-pan"]);
  assertEquals(again.calls, []);
});

Deno.test("a repeat continues a claim but never starts one", () => {
  // A gesture begins on the rising edge. An auto-repeat arriving
  // with nothing held is not that edge, so it claims nothing — and
  // the shortcut table refuses repeats too, so nothing runs either.
  const r = press(NO_HELD_GESTURES, key(" ", { repeat: true }), OVER_STAGE);
  assertEquals(r.press, { kind: "command", consumed: false });
  assertEquals(claimed(r.held), []);
  assertEquals(r.calls, []);
});

Deno.test("the release re-opens the question for the next press", () => {
  const held = press(NO_HELD_GESTURES, key(" "), OVER_STAGE).held;
  const released = resolveKeyUp(held, " ");
  assertEquals(claimed(released), []);

  // Pointer is off the stage now, so the same key means transport.
  const next = press(released, key(" "), OFF_STAGE);
  assertEquals(next.press, { kind: "command", consumed: true });
  assertEquals(next.calls, ["enqueue:toggle"]);
});

Deno.test("Space aimed at a text field neither claims nor commands", () => {
  const r = press(
    NO_HELD_GESTURES,
    key(" ", { textInput: true }),
    OVER_STAGE,
  );
  assertEquals(r.press, { kind: "command", consumed: false });
  assertEquals(claimed(r.held), []);
  assertEquals(r.calls, []);
});

Deno.test("Shift and Alt claim everywhere, including over a text field", () => {
  // They preview what the next pointer gesture would do, and that
  // is still true while the user is typing.
  const shift = press(
    NO_HELD_GESTURES,
    key("Shift", { shift: true, textInput: true }),
    OFF_STAGE,
  );
  assertEquals(shift.press, { kind: "claim", id: "shift" });
  assertEquals(shift.calls, []);
  // Nothing to prevent: they command nothing on their own.
  assertEquals(shift.preventDefault, false);

  const both = press(shift.held, key("Alt", { alt: true }), OFF_STAGE);
  assertEquals(both.press, { kind: "claim", id: "alt" });
  assertEquals(claimed(both.held), ["alt", "shift"]);

  // One release drops one gesture and leaves the other holding.
  assertEquals(claimed(resolveKeyUp(both.held, "Shift")), ["alt"]);
});

Deno.test("a press no gesture wants and no binding answers is inert", () => {
  const r = resolveKeyDown(NO_HELD_GESTURES, key("q"), OFF_STAGE, null);
  assertEquals(r.press, { kind: "none" });
  assertEquals(r.preventDefault, false);
});

Deno.test("every held gesture releases on keyup and on blur", () => {
  // Generic over the table: a gesture registered later inherits the
  // whole lifecycle rather than having to re-implement it.
  for (const row of HELD_GESTURES) {
    for (const spelling of row.keys) {
      const held: HeldGestures = new Set([row.id]);
      assertEquals(
        claimed(resolveKeyUp(held, spelling)),
        [],
        `${row.id} should release on "${spelling}" keyup`,
      );
      assertEquals(
        claimed(resolveKeyUp(held, spelling.toUpperCase())),
        [],
        `${row.id} should release whatever case the key arrives in`,
      );
      assertEquals(
        claimed(resolveBlur(held)),
        [],
        `${row.id} should release on blur`,
      );
    }
  }
});

Deno.test("an unchanged held set keeps its identity", () => {
  // A React caller renders from this set, so "nothing changed" has
  // to be visible as the same instance.
  const held: HeldGestures = new Set(["space-pan" as const]);
  assertStrictEquals(resolveKeyUp(held, "q"), held);
  assertStrictEquals(resolveBlur(NO_HELD_GESTURES), NO_HELD_GESTURES);
  assertStrictEquals(
    press(held, key(" ", { repeat: true }), OVER_STAGE).held,
    held,
  );
});

Deno.test("one key means one gesture", () => {
  // A second row answering to a key an existing row already owns
  // would be shadowed: registered, never claiming, and silent about
  // it. The table refuses to index instead.
  assertEquals(
    indexHeldGestures(HELD_GESTURES).size,
    HELD_GESTURES.reduce((n, row) => n + row.keys.length, 0),
  );
  assertThrows(
    () =>
      indexHeldGestures([
        HELD_GESTURES[0]!,
        { ...HELD_GESTURES[0]!, id: "alt" },
      ]),
    Error,
    "is claimed by both",
  );
});

Deno.test("a claim ends at its key's release and says nothing more", () => {
  // The claim is the whole of what this layer asserts. What became
  // of a gesture the key started is the pointer FSM's, and
  // `pointer-machine-test/space-pan.test.ts` pins it: releasing Space during a pan
  // leaves a pan running, while releasing it during a marquee that
  // Space interrupted puts the marquee back. Neither outcome is
  // visible from here, and this layer must not pretend otherwise.
  const held = press(NO_HELD_GESTURES, key(" "), OVER_STAGE).held;
  assertEquals(claimed(resolveKeyUp(held, " ")), []);
});

Deno.test("the modifier set is answered by the table, not restated beside it", () => {
  // The cursor asks about three modifiers and this table watches two, and the
  // one it does not watch used to read `false` from a literal at the call
  // site. Adding the missing row would then have changed nothing: the table
  // would say Cmd is watched and the cursor would go on being told it is not.
  //
  // So each field is checked against the table itself. A row added for a
  // modifier makes that modifier live here without another edit, and this
  // goes red if some later reader answers one of them from memory again.
  for (const name of ["shift", "alt", "cmd"] as const) {
    const watched = HELD_GESTURES.some((row) => row.id === name);
    const down = new Set([name]) as unknown as HeldGestures;
    assertEquals(
      heldModifiers(down)[name],
      watched,
      watched
        ? `${name} has a held-gesture row and is still reported as up while it is down`
        : `${name} has no held-gesture row, so nothing tracks it and it cannot be reported down`,
    );
  }
  // And nothing else moves when one key is down.
  assertEquals(heldModifiers(NO_HELD_GESTURES), {
    shift: false,
    alt: false,
    cmd: false,
  });
  assertEquals(heldModifiers(new Set(["shift"])), {
    shift: true,
    alt: false,
    cmd: false,
  });
});
