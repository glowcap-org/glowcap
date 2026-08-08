/**
 * The rule every entity picker reads its options through.
 *
 * A pure function over a whole list, which is the only way the rule can
 * be stated at all: whether one option shows its id is decided by the
 * other options beside it, not by anything the option itself carries.
 * So each case here is a list, and what it asserts is the list.
 */

import { assertEquals } from "@std/assert";
import { pickerLabelFor, pickerLabels } from "./picker-labels.ts";

Deno.test("a name of its own is the whole label", () => {
  assertEquals(
    pickerLabels([
      { id: "peer-alice", name: "alice" },
      { id: "peer-bob", name: "bob" },
    ]),
    ["alice", "bob"],
  );
});

Deno.test("an entity nobody named falls back to its id", () => {
  assertEquals(
    pickerLabels([{ id: "peer-alice", name: "alice" }, { id: "peer-7" }]),
    ["alice", "peer-7"],
  );
});

Deno.test("a name that is only the id again is not a name", () => {
  // `peerLabelAt` answers with the peer's id when the document never
  // named it, so a caller passing that through must not produce
  // "peer-7 (peer-7)".
  assertEquals(
    pickerLabels([{ id: "peer-7", name: "peer-7" }]),
    ["peer-7"],
  );
  assertEquals(
    pickerLabels([{ id: "peer-7", name: "peer-7" }, { id: "peer-8" }]),
    ["peer-7", "peer-8"],
  );
});

Deno.test("a blank name is no name", () => {
  assertEquals(
    pickerLabels([{ id: "peer-7", name: "   " }, { id: "peer-8", name: "" }]),
    ["peer-7", "peer-8"],
  );
});

Deno.test("two options that would read alike qualify the whole list", () => {
  // Carol collides with nobody and is qualified anyway: the list has one
  // grammar, and "carol" beside "alice (peer-a1)" reads as a different
  // kind of row.
  assertEquals(
    pickerLabels([
      { id: "peer-a1", name: "alice" },
      { id: "peer-a2", name: "alice" },
      { id: "peer-c", name: "carol" },
    ]),
    ["alice (peer-a1)", "alice (peer-a2)", "carol (peer-c)"],
  );
});

Deno.test("a nameless option in a qualified list still shows its id", () => {
  assertEquals(
    pickerLabels([
      { id: "peer-a1", name: "alice" },
      { id: "peer-a2", name: "alice" },
      { id: "peer-x" },
    ]),
    ["alice (peer-a1)", "alice (peer-a2)", "peer-x"],
  );
});

Deno.test("a long id is shortened where it appears", () => {
  const long = "b".repeat(64);
  const [label] = pickerLabels([
    { id: long, name: "alice" },
    { id: "peer-a2", name: "alice" },
  ]);
  assertEquals(label, `alice (bbbbbbbb…bbbbbbbb)`);
});

Deno.test("ids that shorten alike fall back to whole ids", () => {
  // Both ends of each id match, so the shortened form cannot tell them
  // apart and a qualified list would still be unreadable.
  const head = "0".repeat(8);
  const tail = "9".repeat(8);
  const one = `${head}${"a".repeat(40)}${tail}`;
  const two = `${head}${"b".repeat(40)}${tail}`;
  assertEquals(
    pickerLabels([{ id: one, name: "alice" }, { id: two, name: "alice" }]),
    [`alice (${one})`, `alice (${two})`],
  );
});

Deno.test("one option is never qualified", () => {
  assertEquals(pickerLabels([{ id: "s-1", name: "alice ↔ carol" }]), [
    "alice ↔ carol",
  ]);
});

Deno.test("an empty list has no labels", () => {
  assertEquals(pickerLabels([]), []);
});

Deno.test("the lookup answers by id, and by the id itself when unknown", () => {
  const label = pickerLabelFor([
    { id: "peer-a1", name: "alice" },
    { id: "peer-a2", name: "alice" },
  ]);
  assertEquals(label("peer-a1"), "alice (peer-a1)");
  assertEquals(label("peer-a2"), "alice (peer-a2)");
  assertEquals(label("peer-gone"), "peer-gone");
});
