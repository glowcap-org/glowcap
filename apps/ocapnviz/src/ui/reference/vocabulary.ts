/**
 * The rest of the Reference, as text: the closed sets the app attaches to
 * peers and sessions, one table each.
 *
 * Most tables are keyed by the type the schema declares, so a word added there
 * fails to compile here until somebody writes its sentence. The open sets are
 * offers rather than closed types, because OCapN is netlayer-plural,
 * implementation-plural, and codec-extensible, and a feed may carry a word this
 * build has never heard of. Those tables are keyed by the lists their picker,
 * reference section, or legend reads, and `reference.test.ts` holds them there.
 *
 * Endpoint attribution is the one section with a shape of its own, and it
 * lives in `endpoint-attribution.ts`.
 */

import {
  type CaptpVersionReferenceOption,
  type CodecReferenceOption,
  type ProfileOption,
  type SessionState,
  type TransportOption,
} from "../../schema/topology.ts";
import type { ReferenceEntry } from "./entry.ts";

/** How far a netlayer can be trusted. Three answers, and every netlayer this
 *  build knows gives one of them. */
export type TransportStanding = "production" | "trusted-network" | "testing";

/** The standings, strongest first, which is the order the rows read in. The
 *  order is derived from this rather than from how the table below happens to
 *  be written, so a seventh netlayer added in the middle still lands beside
 *  the ones that stand where it does. */
export const TRANSPORT_LADDER: readonly TransportStanding[] = [
  "production",
  "trusted-network",
  "testing",
];

/** The word each standing is announced with. One phrasing per answer, so two
 *  netlayers that stand in the same place cannot be described as if they
 *  differed. */
export const TRANSPORT_VERDICT: Record<TransportStanding, string> = {
  production: "Production",
  "trusted-network": "Trusted network only",
  testing: "Testing only",
};

export type TransportRow = ReferenceEntry & {
  readonly standing: TransportStanding;
  /**
   * Whether this netlayer authenticates the peer: whether the code realizing
   * the connection proves which node answered, without the network being
   * trusted to help.
   *
   * Two axes, not one, which is why this is declared and not derived from
   * `standing`. A cleartext netlayer is unauthenticated, and `keyed-tcp` and
   * `keyed-relay` are cleartext, so both answer no here. They are still rated
   * above testing, because dialing a key demands that key and refuses a peer
   * claiming another, so on a network nobody can sit in the middle of, the
   * demand does bind an identity. That conditional is the whole content of
   * `standing: "trusted-network"`, and `tcp` does not reach it even on a
   * perfect network, because an address says nothing about who holds it.
   *
   * It sits beside the sentence that explains it so the two cannot disagree
   * quietly, which they did: these rows told a reader that `keyed-tcp` proved
   * its peer for as long as the credential behind that claim existed, and went
   * on saying it afterwards.
   *
   * `reference.test.ts` reads it. An authored recording may only claim
   * `authenticated-transport` on a netlayer that answers yes, so a fixture
   * cannot show a proof its transport could not have produced.
   */
  readonly authenticatesPeer: boolean;
};

/**
 * One row per netlayer the picker offers.
 *
 * The verdict, and one sentence each for who is proved and what a stranger on
 * the path can do. The reasoning behind the verdicts is the project's
 * transports page, which the section links to. Restating it here would be a
 * second copy of an assessment that already has a home.
 */
export const TRANSPORT_ROWS: Record<TransportOption, TransportRow> = {
  iroh: {
    standing: "production",
    authenticatesPeer: true,
    says: "The node id is a key, so dialing the name proves who answered. " +
      "The QUIC channel is encrypted, so nobody on the path can read the " +
      "frames.",
  },
  webrtc: {
    standing: "production",
    authenticatesPeer: true,
    says: "The DataChannel is encrypted, so nobody on the path can read the " +
      "frames. Who the peer is comes from the signaling authority that " +
      "introduced it, so it is only as good as that authority.",
  },
  "keyed-tcp": {
    standing: "trusted-network",
    authenticatesPeer: false,
    says: "The name is a key, and dialing it demands the peer claim that " +
      "key. A peer claiming another one is refused. Nothing proves the " +
      "claim, though, and the frames are cleartext, so somebody on the path " +
      "can answer in its place.",
  },
  "keyed-relay": {
    standing: "trusted-network",
    authenticatesPeer: false,
    says: "The same demand on the dialed key, refused the same way when it " +
      "does not match. The relay carrying the frames reads every one of them " +
      "in the clear, and nothing proves who is on the far side of it.",
  },
  tcp: {
    standing: "testing",
    authenticatesPeer: false,
    says: "The name is a socket address rather than a key, so nothing about " +
      "the peer is proved. Nothing is encrypted either.",
    aside: "It is here to reach peers that speak nothing else.",
  },
  inproc: {
    standing: "testing",
    authenticatesPeer: false,
    says: "Both ends are in one process, so there is no network between " +
      "them, nothing to prove and nothing to encrypt.",
    aside: "You meet it in tests and demos.",
  },
};

/** Where the reasoning behind the verdicts lives. */
export const TRANSPORTS_PAGE_URL =
  "https://jimisaacs.github.io/pancake/transports/";
export const TRANSPORTS_PAGE_NOTE =
  "The project's transports page carries the assessment behind these " +
  "verdicts. It goes through what each netlayer's name designates, what " +
  "proves the peer, whether the channel is encrypted, and what someone on " +
  "the path can do.";

export const CODEC_ROWS: Record<CodecReferenceOption, ReferenceEntry> = {
  syrup: {
    says:
      "Syrup is Spritely's self-describing binary encoding, and every OCapN " +
      "peer can read it.",
  },
  capnp: {
    says:
      "Two ends write Cap'n Proto's pointer encoding only when both of them " +
      "offered it at the hello.",
  },
  unknown: {
    says:
      "The trace said this session negotiated a codec this ABI generation " +
      "does not name. The viewer keeps that fact separate from both built-ins.",
  },
};

/**
 * The versions, keyed by the tag the document stores.
 *
 * A reader never meets that tag. `CAPTP_VERSION_WIRE` is what the app calls a
 * version everywhere one is shown, so the word at the head of each row is the
 * word the handshake uses and the word a feed arrives speaking.
 */
export const CAPTP_VERSION_ROWS: Record<
  CaptpVersionReferenceOption,
  ReferenceEntry
> = {
  v1_0: {
    says:
      "The OCapN specification writes this version, and it is what a Spritely " +
      "Goblins peer speaks.",
  },
  next: {
    says:
      "This is pancake's own forward version, and it is valid only with a " +
      "pancake host at each end. A session running it therefore tells the " +
      "viewer both of its peers are pancake.",
  },
  unknown: {
    says:
      "The trace said this session negotiated a CapTP profile this viewer " +
      "does not name. The viewer keeps that fact separate from the 1.0 floor.",
  },
};

export const PROFILE_ROWS: Record<ProfileOption, ReferenceEntry> = {
  pancake: {
    says: "The peer is a pancake host. A live feed learns this at the hello, " +
      "either because the producer said so or because the session settled on " +
      "pancake-next.",
  },
  goblins: {
    says: "The peer is a Spritely Goblins vat. A feed carries this when the " +
      "producer says so, and nothing ever concludes it from what a peer does.",
  },
  other: {
    says:
      "Nobody has named this peer's implementation. Every peer starts here, " +
      "and it changes the moment the viewer is told.",
  },
};

export const SESSION_STATE_ROWS: Record<SessionState, ReferenceEntry> = {
  negotiating: {
    says: "The two ends are settling on a version and a codec. Nothing the " +
      "application sent is moving yet.",
  },
  open: {
    says: "The session is up and carrying messages.",
  },
  draining: {
    says: "The session is on its way out and its last traffic is still " +
      "landing.",
    aside: "This is the viewer's own stage rather than a state the protocol " +
      "names.",
  },
  closed: {
    says: "The session is over. It stays on the timeline where it ended.",
  },
};
