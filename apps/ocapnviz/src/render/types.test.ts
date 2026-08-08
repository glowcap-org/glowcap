/**
 * What a node is doing in the traffic at the playhead, read two ways.
 *
 * The stage marks every node at once and the Inspector asks about the one node
 * it is showing. Both readings fold the same rule — a message's source is
 * sending, its destination is receiving — so the chip in the panel cannot
 * disagree with the mark on the node it names.
 */

import { assertEquals } from "@std/assert";
import {
  foldActivityByNode,
  nodeActivityIn,
  type PeerActivity,
} from "./types.ts";

function flight(from: string, to: string) {
  return { messageInFlight: { from, to } };
}

/** Every node either message names, which is what the two readings are
 *  compared over. */
function nodesIn(
  messages: Array<{ messageInFlight: { from: string; to: string } }>,
) {
  const ids = new Set<string>();
  for (const m of messages) {
    ids.add(m.messageInFlight.from);
    ids.add(m.messageInFlight.to);
  }
  return [...ids].sort();
}

Deno.test("a message makes its sender send and its receiver receive", () => {
  const byNode = foldActivityByNode([flight("alice", "bob")], new Map());
  assertEquals(byNode.get("alice"), "sending" as PeerActivity);
  assertEquals(byNode.get("bob"), "receiving" as PeerActivity);
});

Deno.test("a node doing both is doing both, and a repeat changes nothing", () => {
  const byNode = foldActivityByNode(
    [flight("alice", "bob"), flight("bob", "alice"), flight("alice", "carol")],
    new Map(),
  );
  assertEquals(byNode.get("alice"), "both" as PeerActivity);
  assertEquals(byNode.get("bob"), "both" as PeerActivity);
  assertEquals(byNode.get("carol"), "receiving" as PeerActivity);
});

Deno.test("the one-node reading agrees with the whole frame's", () => {
  // The pair that has to agree. Two spellings of the sending/receiving rule
  // drifted apart once; this is what says they are one.
  const cases = [
    [flight("alice", "bob")],
    [flight("alice", "bob"), flight("bob", "alice")],
    [
      flight("alice", "s1::b"),
      flight("alice", "carol"),
      flight("carol", "bob"),
    ],
    // A message a node sends to itself: sending and receiving in one.
    [flight("alice", "alice")],
  ];
  for (const messages of cases) {
    const byNode = foldActivityByNode(messages, new Map());
    for (const id of nodesIn(messages)) {
      assertEquals(
        nodeActivityIn(messages, id),
        byNode.get(id),
        `${id} reads differently one node at a time`,
      );
    }
    assertEquals(nodeActivityIn(messages, "nobody"), "idle" as PeerActivity);
  }
});

Deno.test("the fill-and-return buffer holds only this frame's traffic", () => {
  // The stage owns one map and hands it back every tick, so last frame's
  // senders must not linger in it.
  const buffer = new Map<string, PeerActivity>();
  foldActivityByNode([flight("alice", "bob")], buffer);
  foldActivityByNode([flight("carol", "dave")], buffer);
  assertEquals([...buffer.keys()].sort(), ["carol", "dave"]);
});
