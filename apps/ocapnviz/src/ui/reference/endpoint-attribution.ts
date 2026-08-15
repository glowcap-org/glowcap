/**
 * The endpoint attribution section of the Reference, as text.
 *
 * Attribution answers one question: what makes the viewer say this end is
 * that peer. The answer decides whether the end attaches to a peer node or
 * stands as a node of its own, so the axis is evidence and nothing else. It
 * is not how far the far side can be trusted, which is a question about a
 * deployment and belongs to the transports section.
 *
 * The rows read strongest evidence first, and each wears the kind of evidence
 * it is. That classification is `ATTRIBUTION_STANDING` in the schema, beside
 * the words themselves, because the Inspector's chip picks its tone from the
 * same answer and the two must not disagree.
 *
 * `ATTRIBUTION_ROWS` is a `Record<EndpointAttribution, …>`, so a word added to
 * the schema fails to compile here until somebody writes its sentence.
 *
 * The words themselves are the stored values rather than phrases of this
 * section's own, so what a reader learns here is what the chip on the stage
 * says and what the Build-mode picker offers.
 */

import type { AttributionStanding, EndpointAttribution } from "../../schema/topology.ts";
import type { ReferenceEntry } from "./entry.ts";

/** The kinds of evidence, strongest first, which is the order the rows read
 *  in. A standing missing from this list has no place to sit, and
 *  `reference.test.ts` says so. */
export const ATTRIBUTION_LADDER: readonly AttributionStanding[] = [
  "checked",
  "stated",
  "inferred",
];

/** The word each kind of evidence is announced with, so two words backed the
 *  same way cannot be described as if they differed. */
export const ATTRIBUTION_STANDING_WORD: Record<AttributionStanding, string> = {
  checked: "Checked",
  stated: "Stated",
  inferred: "Inferred",
};

/** One row per word the schema declares. */
export const ATTRIBUTION_ROWS: Record<EndpointAttribution, ReferenceEntry> = {
  "authenticated-transport": {
    says: "The name this end claims is itself a key, and the code that opened the " +
      "connection verified the far end holds it. Dialing the name and proving " +
      "who answered were one act.",
  },
  "verified-handoff": {
    says: "This end is the party a third peer introduced, and the signatures on " +
      "that introduction checked out. The introducer's gift named the key " +
      "this end holds, and the message that redeemed it was signed with that " +
      "key.",
    aside: "It says nothing about the name in this end's hello, which is a " +
      "separate fact nothing here proved. No producer reports it today, so it " +
      "reaches a document by being authored.",
  },
  "self-reported": {
    says: "The peer published its own trace and named itself, and nothing checked " +
      "the name.",
    aside: "A producer always speaks for its own end, so no session is loose at " +
      "both ends.",
  },
  "viewer-correlated": {
    says: "Two producers described the same session and this viewer matched them " +
      "by its id. That is a correlation between two self-reports, and nothing " +
      "checked either one.",
  },
};

/** The fifth answer, which is the absence of the other four and the one a
 *  reader meets most often. It is titled with the phrase the chip wears, so
 *  the word a reader came here from is the word they land on. */
export const LOOSE_END_TEXT = "An end nothing has attributed stays loose. The viewer draws it as a node " +
  "of its own, carrying only the name it claims. Nothing has said which peer " +
  "is on it, and attaching it to one anyway would merge two nodes on no " +
  "evidence.";

/** What holds for every attribution alike. The first is what CapTP's own
 *  handshake proves on every netlayer, and the second is why this section
 *  names no netlayers: the transports section is where a reader compares
 *  those. */
export const ATTRIBUTION_NOTES: readonly string[] = [
  "Every CapTP session signs the location each end claims with a key drawn " +
  "fresh for that connection. That proves the same party stayed on the line " +
  "for the whole session, and it never proves who that party is.",
  "Which of these words an end gets follows what its connection proved, not " +
  "the netlayer it ran over. Two sessions on the same netlayer can land on " +
  "different words.",
];
