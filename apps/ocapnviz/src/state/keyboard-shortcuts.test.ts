/**
 * The shortcut table is the one authority for what each key
 * commands, so these tests pin its guard semantics: modifier
 * contracts, Build-only rows, the two table-wide refusals (a
 * repeat, and a press aimed at a text field), and the
 * nudge-else-scrub arrows.
 *
 * Whether a press reaches this table at all is a different
 * question, decided by `resolveKeyDown` in `keyboard-input.ts` and
 * tested there. Space over the stage is the case where the two
 * meet: the pan gesture claims it and this table never sees it.
 */

import { assertEquals } from "@std/assert";
import { dispatchShortcut, type KeyEventFacts } from "./keyboard-shortcuts.ts";
import { recordingBindings as harness } from "./keyboard-shortcuts.fixture.ts";

function key(k: string, mods?: Partial<KeyEventFacts>): KeyEventFacts {
  return { key: k, cmd: false, shift: false, alt: false, ...mods };
}

Deno.test("Space off the stage toggles the transport in Play and Build", () => {
  for (const mode of ["play", "build"] as const) {
    const { b, calls } = harness({ mode });
    assertEquals(dispatchShortcut(key(" "), b), true);
    assertEquals(calls, ["enqueue:toggle"]);
  }
});

Deno.test("Live refuses the transport keys the timeline already hides", () => {
  const { b, calls } = harness({ mode: "live" });
  assertEquals(dispatchShortcut(key(" "), b), false);
  assertEquals(dispatchShortcut(key("r"), b), false);
  assertEquals(dispatchShortcut(key("ArrowLeft"), b), false);
  assertEquals(dispatchShortcut(key("ArrowRight"), b), false);
  assertEquals(calls, []);
  // Observation tools and file rows still run; Live is not a lock-out.
  dispatchShortcut(key("h"), b);
  assertEquals(dispatchShortcut(key("s", { cmd: true }), b), true);
  assertEquals(calls, ["tool:hand", "save"]);
});

Deno.test("V picks Select everywhere; Cmd-V pastes only in Build", () => {
  const play = harness({ mode: "play" });
  dispatchShortcut(key("v"), play.b);
  assertEquals(play.calls, ["tool:select"]);

  const buildPaste = harness({ mode: "build" });
  assertEquals(dispatchShortcut(key("v", { cmd: true }), buildPaste.b), true);
  assertEquals(buildPaste.calls, ["paste"]);

  const playPaste = harness({ mode: "play" });
  assertEquals(dispatchShortcut(key("v", { cmd: true }), playPaste.b), false);
  assertEquals(playPaste.calls, []);
});

Deno.test("H picks Hand in every mode; Cmd-H stays the OS's", () => {
  for (const mode of ["live", "play", "build"] as const) {
    const { b, calls } = harness({ mode });
    dispatchShortcut(key("h"), b);
    assertEquals(calls, ["tool:hand"]);
    assertEquals(dispatchShortcut(key("h", { cmd: true }), b), false);
    assertEquals(calls, ["tool:hand"]);
  }
});

Deno.test("authoring tool keys are Build rows", () => {
  const play = harness({ mode: "play" });
  dispatchShortcut(key("p"), play.b);
  dispatchShortcut(key("m"), play.b);
  dispatchShortcut(key("s"), play.b);
  assertEquals(play.calls, []);

  const build = harness({ mode: "build" });
  dispatchShortcut(key("p"), build.b);
  dispatchShortcut(key("s"), build.b);
  dispatchShortcut(key("m"), build.b);
  assertEquals(build.calls, [
    "tool:add-peer",
    "tool:open-session",
    "tool:send-message",
  ]);
});

Deno.test("Cmd-S saves and Cmd-O opens in every mode", () => {
  for (const mode of ["live", "play", "build"] as const) {
    const { b, calls } = harness({ mode });
    assertEquals(dispatchShortcut(key("s", { cmd: true }), b), true);
    assertEquals(dispatchShortcut(key("o", { cmd: true }), b), true);
    assertEquals(calls, ["save", "open"]);
  }
});

Deno.test("arrows scrub outside Build and never nudge there", () => {
  const { b, calls } = harness({ mode: "play", nudgeConsumes: true });
  assertEquals(dispatchShortcut(key("ArrowRight"), b), true);
  assertEquals(calls, ["enqueue:seekTo"]);
});

Deno.test("a Build nudge that consumes the arrow suppresses the scrub", () => {
  const { b, calls } = harness({ mode: "build", nudgeConsumes: true });
  assertEquals(dispatchShortcut(key("ArrowLeft"), b), true);
  assertEquals(calls, ["nudge"]);
});

Deno.test("a Build nudge that declines falls back to the scrub", () => {
  const { b, calls } = harness({ mode: "build", nudgeConsumes: false });
  assertEquals(dispatchShortcut(key("ArrowLeft"), b), true);
  assertEquals(calls, ["nudge", "enqueue:seekTo"]);
});

Deno.test("vertical arrows claim the key only when the nudge does", () => {
  const consuming = harness({ mode: "build", nudgeConsumes: true });
  assertEquals(dispatchShortcut(key("ArrowUp"), consuming.b), true);

  const declining = harness({ mode: "build", nudgeConsumes: false });
  assertEquals(dispatchShortcut(key("ArrowDown"), declining.b), false);

  const play = harness({ mode: "play" });
  assertEquals(dispatchShortcut(key("ArrowUp"), play.b), false);
  assertEquals(play.calls, []);
});

// The recorded names matter here: `undo` is the host callback and
// `engine.undo` is the engine's own verb. A row that commanded the
// engine directly would skip the selection walk that has to ride
// along with a history step, so the assertion names which one ran.
Deno.test("undo family: Cmd-Z / Cmd-Shift-Z / Cmd-Y, Build only", () => {
  const build = harness({ mode: "build" });
  dispatchShortcut(key("z", { cmd: true }), build.b);
  dispatchShortcut(key("z", { cmd: true, shift: true }), build.b);
  dispatchShortcut(key("y", { cmd: true }), build.b);
  assertEquals(build.calls, ["undo", "redo", "redo"]);

  const play = harness({ mode: "play" });
  assertEquals(dispatchShortcut(key("z", { cmd: true }), play.b), false);
  assertEquals(play.calls, []);
});

Deno.test("clipboard rows refuse extra modifiers", () => {
  const { b, calls } = harness({ mode: "build" });
  assertEquals(
    dispatchShortcut(key("c", { cmd: true, shift: true }), b),
    false,
  );
  assertEquals(dispatchShortcut(key("d", { cmd: true, alt: true }), b), false);
  assertEquals(calls, []);
  assertEquals(dispatchShortcut(key("c", { cmd: true }), b), true);
  assertEquals(dispatchShortcut(key("d", { cmd: true }), b), true);
  assertEquals(calls, ["copy", "duplicate"]);
});

Deno.test("Delete and Backspace delete only in Build", () => {
  const build = harness({ mode: "build" });
  assertEquals(dispatchShortcut(key("Delete"), build.b), true);
  assertEquals(dispatchShortcut(key("Backspace"), build.b), true);
  assertEquals(build.calls, ["delete", "delete"]);

  const play = harness({ mode: "play" });
  assertEquals(dispatchShortcut(key("Delete"), play.b), false);
  assertEquals(play.calls, []);
});

Deno.test("a held key's auto-repeat is not a second press", () => {
  // Every row is a one-shot command, so a browser re-delivering keydown while
  // the key is still down must not run the command again.
  //
  // Trust this for what it says and no more. It was written for a bug whose
  // root was elsewhere: a guard that re-derived a held key's meaning from a
  // live fact instead of latching it at the press. Injecting that defect back
  // in and running this test passes, because refusing the repeat hides it —
  // the re-derivation only shows on a press the repeat guard does not cover.
  // `keyboard-input.test.ts` holds the latch itself, and that is the test
  // that distinguishes the two designs.
  const { b, calls } = harness({ mode: "play" });
  assertEquals(dispatchShortcut(key(" ", { repeat: true }), b), false);
  assertEquals(calls, []);

  // The press itself still works; only the repeats are refused.
  assertEquals(dispatchShortcut(key(" "), b), true);
  assertEquals(calls, ["enqueue:toggle"]);
});

Deno.test("auto-repeat is refused for every shortcut, not only Space", () => {
  const { b, calls } = harness({ mode: "build" });
  for (const k of ["v", "h", "arrowleft", "arrowright"]) {
    assertEquals(dispatchShortcut(key(k, { repeat: true }), b), false);
  }
  assertEquals(calls, []);
});

Deno.test("no shortcut shadows typing", () => {
  // The bail is table-wide, so it holds for the keys most likely to be typed
  // and for the ones a text field would otherwise lose to a command.
  const { b, calls } = harness({ mode: "build" });
  for (const k of [" ", "v", "delete", "backspace", "escape"]) {
    assertEquals(dispatchShortcut(key(k, { textInput: true }), b), false);
  }
  assertEquals(
    dispatchShortcut(key("s", { cmd: true, textInput: true }), b),
    false,
  );
  assertEquals(calls, []);
});
