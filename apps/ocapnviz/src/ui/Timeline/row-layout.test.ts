/**
 * `iterateRows` is the walk that decides which timeline rows exist.
 * Height and hit-test both consume it; these cases pin the walk itself
 * (empty categories, expansion, per-entity rows, hidden-on-stage height).
 */

import { assertEquals } from "@std/assert";
import { iterateRows, type RowDescriptor } from "./row-layout.ts";
import type { LaneKind } from "./state.ts";

Deno.test(
  "iterateRows: every toggled-on category produces a collapsed row, empty included",
  () => {
    const rows = [...iterateRows(
      new Set<LaneKind>(["peers", "sessions", "messages"]),
      new Set(),
      { peers: ["alice", "bob"], sessions: ["s1"], messages: [] },
      undefined,
      30,
    )];
    // The lane toggle alone decides row existence — an empty
    // `messages` still gets its row, so content coming and going
    // never shifts the chrome and the category stays expandable.
    assertEquals(rows.length, 3);
    for (const r of rows) assertEquals(r.kind, "category-collapsed");
  },
);

Deno.test(
  "iterateRows: expanded-but-empty categories emit headers only",
  () => {
    // Expansion is user-set state, so each drilled-down empty
    // category keeps its header (the chevron is the way back);
    // no entity rows exist to draw under it.
    const rows = [...iterateRows(
      new Set<LaneKind>(["peers", "sessions", "messages"]),
      new Set(["peers", "sessions", "messages"]),
      { peers: [], sessions: [], messages: [] },
      undefined,
      30,
    )];
    assertEquals(rows.length, 3);
    for (const r of rows) assertEquals(r.kind, "category-header");
  },
);

Deno.test("iterateRows: expanded category yields header + entity rows", () => {
  const rows = [...iterateRows(
    new Set<LaneKind>(["peers"]),
    new Set(["peers"]),
    { peers: ["alice", "bob"], sessions: [], messages: [] },
    undefined,
    30,
  )];
  // 1 header + 2 entity rows.
  assertEquals(rows.length, 3);
  assertEquals(rows[0]!.kind, "category-header");
  assertEquals(rows[1]!.kind, "entity-row");
  assertEquals(
    (rows[1] as Extract<RowDescriptor, { kind: "entity-row" }>).entityId,
    "alice",
  );
  assertEquals(rows[2]!.kind, "entity-row");
  assertEquals(
    (rows[2] as Extract<RowDescriptor, { kind: "entity-row" }>).entityId,
    "bob",
  );
});

Deno.test("iterateRows: hidden-on-stage rows keep full lane height", () => {
  // The per-row eyeball controls STAGE visibility (see RowHidden
  // doctrine in engine/timeline.ts). The timeline row itself stays
  // at full lane height so selection / drag / scrub continue to
  // work on the hidden entity without first revealing it on stage.
  const rows = [...iterateRows(
    new Set<LaneKind>(["peers"]),
    new Set(["peers"]),
    { peers: ["alice", "bob"], sessions: [], messages: [] },
    { peers: ["bob"] },
    30,
  )];
  const bobRow = rows.find(
    (r) => r.kind === "entity-row" && r.entityId === "bob",
  )!;
  assertEquals(
    (bobRow as Extract<RowDescriptor, { kind: "entity-row" }>).hidden,
    true,
  );
  assertEquals(bobRow.height, 30);
});

Deno.test("iterateRows: an empty category expands and collapses like any other", () => {
  // The lane toggle alone decides whether the category row exists;
  // expansion is user-set (persisted) state on top. An empty group
  // must therefore be freely expandable AND collapsible — content
  // coming and going never traps the chrome in either state.
  const lanes = new Set<"peers" | "sessions" | "messages" | "ruler">([
    "peers",
    "messages",
  ]);
  const expandedEmpty = [...iterateRows(
    lanes,
    new Set<"peers" | "sessions" | "messages">(["messages"]),
    { peers: ["alice"], sessions: [], messages: [] },
    undefined,
    32,
  )];
  const header = expandedEmpty.find((r) => r.kind === "category-header");
  assertEquals(header?.category, "messages");
  // Collapsed, the empty group keeps its collapsed row — still
  // there to expand again.
  const collapsedEmpty = [...iterateRows(
    lanes,
    new Set<"peers" | "sessions" | "messages">(),
    { peers: ["alice"], sessions: [], messages: [] },
    undefined,
    32,
  )];
  const collapsed = collapsedEmpty.find(
    (r) => r.kind === "category-collapsed" && r.category === "messages",
  );
  assertEquals(collapsed !== undefined, true);
});
