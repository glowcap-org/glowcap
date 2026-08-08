import type { TimelineDocument } from "../engine/timeline.ts";
import { callARemoteMethod } from "./01-call-a-remote-method.ts";
import { lookUpByName } from "./02-look-up-by-name.ts";
import { passAReferenceAlong } from "./03-pass-a-reference-along.ts";
import { skipTheRoundtrip } from "./04-skip-the-roundtrip.ts";
import { doThreeThingsAtOnce } from "./05-do-three-things-at-once.ts";
import { pokeMeWhenReady } from "./06-poke-me-when-ready.ts";
import { speakGoblins } from "./07-speak-goblins.ts";
import { enlivenASturdyref } from "./08-enliven-a-sturdyref.ts";
import { threeVatHandoffMixed } from "./three-vat-handoff-mixed.ts";

/**
 * Registry of every timeline the visualizer ships. Adding a new
 * scenario is one file in this directory plus one entry here.
 *
 * Scenario 00 sorts first because it is the headline: three vats, two
 * implementations, and one codec and CapTP version settled per session, so
 * both profiles pancake actually speaks appear in one picture. The eight that
 * follow each teach one idea, and every one of them is a pancake pair on
 * Cap'n Proto over pancake-next, except 07, which meets a Goblins vat and so
 * settles back to Syrup over OCapN 1.0.
 *
 * Two titling rules hold across the set: a title is an imperative verb phrase
 * so the picker reads as a list of things to watch, and a description is a
 * few plain sentences saying what happens and why it is worth watching. The
 * Sidebar renders a description as plain text, so it carries no markup —
 * backticks and asterisks appear on screen exactly as typed.
 */
export const scenarios: readonly TimelineDocument[] = [
  threeVatHandoffMixed,
  callARemoteMethod,
  lookUpByName,
  passAReferenceAlong,
  skipTheRoundtrip,
  doThreeThingsAtOnce,
  pokeMeWhenReady,
  speakGoblins,
  enlivenASturdyref,
] as const;
