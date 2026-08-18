/**
 * A draft that was typed has to be handed up, including when nobody
 * tells it to.
 *
 * The id field holds what the reader types and hands it up on blur.
 * The case that has no blur is the one that matters: clicking a
 * different entity unmounts the field with the caret still in it, and
 * the rename the reader watched themselves type never happened.
 *
 * The other side of the same pair is a commit that lands twice. A
 * rename moves the anchor, which unmounts the field that made it, so
 * an unmount that handed the same draft up again would ask to rename
 * an id the document no longer has.
 */

import { assert, assertEquals } from "@std/assert";
import { pendingEdit } from "./edit-bracket.ts";

/** Records what the field would have been asked to hand up. */
function recorder() {
  const calls: string[] = [];
  let draft = "";
  return {
    calls,
    type(next: string) {
      draft = next;
    },
    edit: pendingEdit(() => void calls.push(draft)),
  };
}

Deno.test("typing then blurring hands the draft up once", () => {
  const r = recorder();
  r.type("peer-renamed");
  r.edit.touch();
  r.edit.settle();
  assertEquals(r.calls, ["peer-renamed"]);
  assertEquals(r.edit.isPending, false);
});

Deno.test("a field unmounting mid-edit hands up what it holds", () => {
  const r = recorder();
  r.type("peer-renamed");
  r.edit.touch();
  // Selecting another entity: React unmounts the input, and no blur
  // ever fires. Without this the reader's rename is dropped in
  // silence.
  r.edit.dispose();
  assertEquals(r.calls, ["peer-renamed"]);
});

Deno.test("committing then unmounting is not a second commit", () => {
  const r = recorder();
  r.type("peer-renamed");
  r.edit.touch();
  r.edit.settle();
  // The rename moved the anchor, so the field that made it unmounts.
  // Handing the same draft up again would rename an id that is gone.
  r.edit.dispose();
  assertEquals(r.calls, ["peer-renamed"]);
});

Deno.test("unmounting with nothing typed hands up nothing", () => {
  const r = recorder();
  r.edit.dispose();
  assertEquals(r.calls, []);
});

Deno.test("typing again after a commit arms a second one", () => {
  const r = recorder();
  r.type("first");
  r.edit.touch();
  r.edit.settle();
  r.type("second");
  r.edit.touch();
  assert(r.edit.isPending);
  r.edit.dispose();
  assertEquals(r.calls, ["first", "second"]);
});

Deno.test("saying no leaves nothing to hand up, then or later", () => {
  const r = recorder();
  r.type("abandoned");
  r.edit.touch();
  // Escape. Putting the draft back cannot do this on its own: the
  // put-back is a state update that has not landed when the blur it
  // triggers runs, so the commit would still read "abandoned".
  r.edit.discard();
  r.edit.settle();
  r.edit.dispose();
  assertEquals(r.calls, []);
});
