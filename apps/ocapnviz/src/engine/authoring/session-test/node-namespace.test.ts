/**
 * The node namespace peers and loose ends share. A peer cannot take
 * an end's stage id; a live producer that presents one is renamed,
 * not refused.
 */

import { assert, assertEquals } from "@std/assert";
import { Engine } from "../../engine.ts";
import type { TimelineEvent } from "../../timeline.ts";
import { parseEndpointStageId } from "../../../schema/session-end.ts";
import { StageLedger } from "../../stage-ledger.ts";
import { engineTest, looseDoc } from "./harness.ts";

// ── the node namespace peers and loose ends share ─────────────────

engineTest("a peer cannot be renamed onto a session end's node", () => {
  const e = new Engine(looseDoc());
  // `s1`'s loose end `b` is drawn as the node `s1::b`. A peer wearing
  // that name would be the same node — one place in the layout for
  // two things the picture holds apart.
  const refused = e.validate({
    kind: "rename-peer",
    oldId: "a",
    newId: "s1::b",
  });
  assert(!refused.ok, "the rename onto an end's node was allowed");
  assertEquals(refused.error.code, "collision");
  // Only that spelling. A name that merely contains the separator is
  // not an end's name, and refusing it would refuse a correct id.
  const allowed = e.validate({
    kind: "rename-peer",
    oldId: "a",
    newId: "s1::c",
  });
  assert(allowed.ok, "a name that is not an end's name was refused");
});

engineTest(
  "a live peer named like an end is disambiguated, not refused",
  () => {
    const ledger = new StageLedger();
    const out: TimelineEvent[] = [];
    // A producer picks the name a peer arrives under, so this one is
    // reachable from the wire and must not be refused. It is extended
    // instead, the way two peers presenting one name are.
    const live = ledger.ensurePeer("wire-1::a", 0, out);
    assert(
      parseEndpointStageId(live.stageId) === undefined,
      `a live peer took an end's node id: ${live.stageId}`,
    );
  },
);
