/**
 * The stage-identity ledger — how observations of live wires become
 * timeline entities.
 *
 * A trace record is one peer's observation: "on this session, my end
 * is A and the other end presents as B". Several peers watch the same
 * conversation and report it independently, so the ledger is built
 * EDGE-FIRST. The strongly identified thing is the session, not the
 * peer: both of its ends derive the same OCapN session identifier
 * (the `wire`), with no coordination and nothing to trust. Two
 * producers reporting one wire are the two ends of one edge, and who
 * the peers are falls out of what those two ends say about each
 * other.
 *
 * That is what lets one browser tab be ONE node. The tab publishes
 * its own trace and names itself by its key designator; the room
 * server reports the same tab as an unverified claim (a tab dials as
 * an ephemeral client and has no listening address to prove). Neither
 * view can identify the other on its own. Together they can: the side
 * of wire W the room could not name is whichever producer says it is
 * on W. That inference is a CLAIM, not proof — a producer asserts it
 * is an end of W and this endpoint takes its word — so it stands on
 * the same footing as the rest of a development-time loopback feed,
 * and it never overrides a name a durable identity proved.
 *
 * The timeline's entity model gives each id exactly ONE lifetime
 * (`{start, duration}`), while wire names recur: a member reconnects
 * with the same designator, a restarted producer reuses session ids.
 * The ledger maps each name to its current live incarnation and mints
 * a fresh stage id (`name#2`, `name#3`, …) for each return, so every
 * stage entity lives once — the architecture rule that a bare key
 * needs its namespace and its WHEN, applied to the stage.
 *
 * Two kinds of fact come out of this, and the ledger keeps them
 * apart because a visualizer that mixes them lies about the
 * protocol. A WIRE fact is an observation of the network: a session
 * opened, a message crossed, a session closed. A KNOWLEDGE fact is
 * about this observer: it learned who was on the far end of a wire
 * it had already drawn. Learning is not an event on the network, so
 * it is never reported as one. A session's identity is its wire
 * name, known from the very first observation and never revised;
 * WHO is on each end is revisable, and that is why an endpoint is a
 * property that changes over the session's life
 * (`session-endpoint-attributed`) rather than a reason to close the
 * session and draw another.
 *
 * Losing sight is its own ending, and it is neither of the other
 * two: `session-unobserved` and `peer-unobserved` say a row stops
 * here because the telemetry showing it went away, and say nothing
 * about the conversation. A producer's socket dropping and a whole
 * endpoint restarting both land there, because in both the viewer
 * knows only that it can no longer see. A peer that turned tracing
 * off looks exactly like one that departed, and picking the second
 * would be inventing a wire fact out of a feed fact.
 *
 * Identity rules the converter leans on:
 * - a VERIFIED partner name is a cross-session identity; an
 *   unverified claim draws no peer at all — the end stays loose,
 *   carrying its claim, until a producer speaks for that side;
 * - a peer's row ends when the last wire touching it ends, never
 *   while another still references it, and it ends the way that wire
 *   did — a peer whose last conversation the viewer merely stopped
 *   watching did not depart;
 * - an explicit close from either endpoint retires the shared wire;
 *   losing telemetry remains observer-counted, so one feed going dark
 *   does not erase a session another producer still reports;
 * - one message is one message however many ends report it: each
 *   carries a tag over its own wire bytes that both ends derive
 *   alike, and the second sighting folds into the first;
 * - what a peer RUNS is stated, never deduced from the fact that it
 *   reported: every peer starts unknown, and a producer that says what
 *   it runs names its own end at the moment it says so rather than at
 *   its join. `#learnProfile` holds the one thing the viewer reads
 *   without being told, and says why there is only one.
 */

import type { TimelineEvent } from "./timeline.ts";
import {
  endpointStageId,
  PANCAKE_PROFILE,
  parseEndpointStageId,
  type PeerProfile,
  type SessionSide,
  UNNAMED_PROFILE,
} from "../schema/topology.ts";

/** A live incarnation of a peer. `stageId` is the timeline entity id
 * this incarnation renders as, and `liveWires` counts the open wires
 * touching it — a peer leaves when the last one closes, unless it is
 * `eternal` (a producer's own reporting host, whose lifetime is its
 * producer's rather than any one session's).
 *
 * What the peer is CALLED is three facts, most specific first: a
 * partner's application annotation (`claimLabel`, a chat nick), the
 * producer's own display name for itself (`selfLabel`), and the name
 * it joined under. Held apart so withdrawing a claim reveals the name
 * underneath instead of freezing the last thing anyone said. */
type LivePeer = {
  stageId: string;
  liveWires: number;
  eternal: boolean;
  joinName: string;
  selfLabel: string | undefined;
  claimLabel: string | undefined;
  /** What is currently on screen, so a restatement is not a rename. */
  shown: string;
  /** The implementation this peer is currently known by, so a
   * restatement is not a change. Starts unknown and only ever moves to a
   * named implementation — see `#learnProfile`. */
  profile: PeerProfile;
};

/** One producer's view of a wire: which side it occupies, so a
 * message's `outbound` flag reads against the right end. */
type Observer = {
  selfStage: string;
  /** The node the far end sits at, or undefined while it is loose. */
  otherStage: string | undefined;
  /** Ledger keys of the same two sides, for the close refcount. */
  selfKey: string;
  otherKey: string;
};

/** A live incarnation of one wire — one stage session, however many
 * producers report it. */
type LiveWire = {
  stageId: string;
  /** The two ends. Which POSITION a side holds is fixed when the wire
   * opens — `a` is the end the first observer reported as its own —
   * and only the key AT a position ever moves (`#retargetSide`). Every
   * `session-endpoint-attributed` the timeline holds names a position,
   * so swapping these would silently retarget keyframes already
   * recorded. */
  aKey: string;
  bKey: string;
  /** Every producer session watching this wire, by scoped session id. */
  observers: Map<string, Observer>;
  /** Message tags already drawn on this wire. A tag is entered by the
   * first end to report the message and CONSUMED by the second, so a
   * peer that genuinely sends the same bytes twice draws two
   * messages. Bounded, oldest out first. */
  seen: Set<string>;
  /** Names an application claimed for an end nobody could name yet,
   * by side, held until the end attaches to a peer that can wear
   * them.
   *
   * It lives on the wire because that is what it is about: a claim
   * names one end of one conversation, and when the conversation goes
   * the claim has nothing left to be about. Kept in a ledger-wide map
   * instead it outlived every wire it described and grew for the
   * feed's life. At most two entries, and they die with the row. */
  looseClaims: Map<SessionSide, string>;
};

/** How many names claimed for sessions that have not opened the
 * ledger holds at once. A producer states a session's partner name
 * around the time the session opens, so a handful are ever in
 * flight; the bound is what keeps a producer that names sessions it
 * never opens from growing this map for the feed's life. Oldest
 * claim out first. */
const MAX_PENDING_NAMES = 64;

/** Message tags held per wire for the fold. One conversation's
 * in-flight window is a handful; this is far past it and still a
 * fixed ceiling per wire. */
const MAX_SEEN_DIGESTS = 512;

/** Why a row on stage ended.
 *
 * `closed` is a protocol fact somebody observed: CapTP tore the
 * session down, or the peer departed. `unobserved` is a fact about
 * this viewer and nothing else: the telemetry that was showing it
 * went away, and what the conversation did next is unknown here.
 *
 * They are different claims and the timeline says which, because a
 * viewer that reported the second as the first would be inventing a
 * teardown out of a dropped socket. */
type EndingReason = "closed" | "unobserved";

/** How a wire's far end came to be attached to a peer.
 *
 * The ledger attaches an end for one of exactly two reasons, and they are
 * different claims, so a caller that has to say what backed the end is told
 * which one it got rather than inferring one from what it passed in.
 *
 * `partner-named` means the reporting producer named that end and the caller
 * passed the name as an identity (`openSession`'s `verified`). What backed the
 * name is the caller's own fact — this ledger never sees the evidence.
 * `correlated` means a second producer's own report of this same wire supplied
 * the name: a correlation across two self-reports, which is the viewer's
 * inference and nobody's measurement. */
export type FarEndBacking = "partner-named" | "correlated";

/** The ledger key for a wire side no producer has spoken for. Wire
 * names are 64 hex digits and designators are hex too, so the prefix
 * is what keeps an unattributed side from ever colliding with a real
 * name. */
function anonKey(wireKey: string): string {
  return `claim@${wireKey}`;
}

/** What one observation says about its own reporting end: the producer's
 * own statement, and failing that pancake when the session negotiated the
 * profile only pancake speaks.
 *
 * The two arms are the two things `#learnProfile` reads, applied to the end
 * the reporting producer occupies. A statement wins over the inference
 * because it is the stronger claim: a producer naming itself something that
 * cannot speak `pancake-next` is a producer contradicting itself, and the
 * viewer repeats what it was told rather than correcting it. */
function selfProfileOf(opts?: {
  selfProfile?: PeerProfile;
  pancakePrivateProfile?: boolean;
}): PeerProfile | undefined {
  if (opts?.selfProfile !== undefined) return opts.selfProfile;
  return opts?.pancakePrivateProfile === true ? PANCAKE_PROFILE : undefined;
}

/** The name an observation's edge is keyed on: the wire, which both
 * ends of a session derive and neither had to be told, falling back
 * to the reporting producer's own scoped session id when the partner
 * sent no session key.
 *
 * Exported because the ledger is not the only caller that has to
 * group observations by edge — resolving a replayed batch groups by
 * the same thing before handing anything to `openSession`, and two
 * implementations of "which edge is this" would be two answers the moment
 * one of them changed. */
export function wireKeyFor(
  sessionId: string,
  wire: string | undefined,
): string {
  return wire !== undefined && wire.length > 0 ? wire : sessionId;
}

export class StageLedger {
  #counter = 0;
  peers = new Map<string, LivePeer>();
  /** Live wires by wire key: the OCapN session identifier when the
   * producer reported one, else that producer's own scoped session id
   * (unique to it, so an unnamed wire still cannot collide). */
  wires = new Map<string, LiveWire>();

  /** Scoped session id -> the wire it observes. A producer names only
   * its own session on a message or a close, and this is what routes
   * that to the shared edge. */
  #wireOfSession = new Map<string, string>();
  #peerIncarnations = new Map<string, number>();
  #wireIncarnations = new Map<string, number>();
  /** Names claimed for sessions the ledger has not seen open yet,
   * by scoped session id. A producer that replays its state to a
   * connecting viewer can state the name before the open, and the
   * peer that name belongs to does not exist until the open — so
   * the claim waits here and lands as the peer joins. */
  #pendingNames = new Map<string, string | null>();

  nextId(): string {
    return `live-${++this.#counter}`;
  }

  #mintStageId(key: string, incarnations: Map<string, number>): string {
    const n = (incarnations.get(key) ?? 0) + 1;
    incarnations.set(key, n);
    return n === 1 ? key : `${key}#${n}`;
  }

  /** A peer's stage id, which must not use the representation of a loose
   *  session end.
   *
   *  The two share one node namespace (see `endpointStageId`), and a
   *  producer picks the name a peer arrives under — so this cannot
   *  refuse one, the way the author's rename is refused. Refusing a
   *  name the network chose refuses a correct producer. Extending it
   *  is what the ledger already does when two peers present the same
   *  name, and an incarnation suffix breaks the endpoint form for
   *  the same reason it disambiguates: `alice::a#1` no longer ends in
   *  a side. */
  #mintPeerStageId(name: string): string {
    const id = this.#mintStageId(name, this.#peerIncarnations);
    if (parseEndpointStageId(id) === undefined) return id;
    return `${id}#${this.#peerIncarnations.get(name) ?? 1}`;
  }

  /** The peer's live incarnation, minting one (and emitting its
   * peer-joined into `out`) on first sight or on return.
   *
   * `key` is both the ledger's identity for the peer and the durable name
   * it answers to on the wire, and those are one string because a peer only
   * ever reaches this ledger by being NAMED — a producer's own end, a
   * verified partner, or a far end another producer spoke for. A side nobody
   * can name gets no peer at all; it stays a loose end of its session
   * (`openSession`). The stage id is minted from the same string and differs
   * from it only when a name recurs: `bob#2` is a second lifetime of one
   * peer, and showing it under that id would report a rename that never
   * happened, so the label stays `bob`. */
  ensurePeer(
    key: string,
    t: number,
    out: TimelineEvent[],
    opts?: { eternal?: boolean; label?: string; profile?: PeerProfile },
  ): LivePeer {
    const live = this.peers.get(key);
    if (live !== undefined) {
      if (opts?.eternal) live.eternal = true;
      if (opts?.label !== undefined) {
        this.#setSelfLabel(live, opts.label, t, out);
      }
      // A peer already on stage that this observation can speak for is the
      // whole reason an implementation is temporal: it was drawn before
      // anyone could say what it runs, and now somebody can.
      if (opts?.profile !== undefined) {
        this.#learnProfile(live, opts.profile, t, out);
      }
      return live;
    }
    const row: LivePeer = {
      stageId: this.#mintPeerStageId(key),
      liveWires: 0,
      eternal: opts?.eternal ?? false,
      joinName: key,
      selfLabel: opts?.label,
      claimLabel: undefined,
      shown: opts?.label ?? key,
      profile: opts?.profile ?? UNNAMED_PROFILE,
    };
    this.peers.set(key, row);
    out.push({
      id: this.nextId(),
      t,
      kind: "peer-joined",
      peerId: row.stageId,
      // What this peer runs, when the observation that drew it could say.
      // An implementation is something a caller measured, never something
      // the stage supplies: the two ways a live feed reaches a verdict are
      // named on `#learnProfile`, and a peer neither of them reaches joins
      // unknown and waits. Unknown is not a final answer — the property is
      // a keyframe track, so a peer nobody could speak for at the join
      // changes at the moment somebody can.
      profile: row.profile,
      label: row.shown,
      // The name is this peer's public identifier, so it is recorded as one
      // instead of surviving only as the text it happens to be shown by: a
      // room renaming the peer to a nickname would otherwise erase the very
      // fact that made it identified.
      designator: key,
    });
    return row;
  }

  /** Record one producer's observation of a session, opening the wire's
   * stage entity the first time any producer reports it. Returns the
   * stage ids the caller emits `session-opened` with, or null when this
   * observation joined a wire that is already on stage — the edge is
   * drawn once however many ends watch it.
   *
   * `selfKey` is the designator the reporting host names ITSELF by, which is
   * the name a partner knows it by and so the only honest merge key across
   * producers. A display label rides beside it in `opts.aLabel` and touches
   * nothing but the text on screen.
   *
   * `b` is absent when nobody could name the far end, which is the loose
   * case; present it carries the peer AND why that end is attached to it
   * (`FarEndBacking`), because the caller has to state what backed the end
   * and only the ledger knows which of the two ways it got there. */
  openSession(
    sessionId: string,
    selfKey: string,
    bName: string,
    t: number,
    out: TimelineEvent[],
    opts?: {
      verified?: boolean;
      aLabel?: string;
      wire?: string;
      /** The name the far end calls ITSELF, when the caller already
       * holds that end's own report of this same wire. It is the fact
       * `#attributeSide` would otherwise have to wait for: a producer's
       * self-assertion that it is an end of this wire.
       *
       * Deliberately NOT the same fact as `verified`. A verified name
       * is one a durable identity proved; this one is correlation
       * across two producers' self-reports, which is weaker and is
       * exactly what `#attributeSide` acts on when the reports arrive one
       * at a time. Passing it as the partner NAME with
       * `verified: true` would put a lie in the vocabulary — so it is
       * its own option, and it says its own thing. */
      partnerOwnName?: string;
      /** What that same far-end report STATES its producer runs, when the
       * caller holds it. It is read only when `partnerOwnName` turns out to
       * be the peer drawn at the far end, because it is that producer's
       * statement about itself and belongs to nobody else.
       *
       * It rides beside the name rather than being deduced from it: holding
       * a producer's report says who is on the far end, and who is on it is
       * not what is on it. A caller holding a report that states nothing
       * passes nothing, and the end joins unknown. */
      partnerOwnProfile?: PeerProfile;
      /** True when this session negotiated the `next` CapTP profile, which
       * is pancake-private (ADR-0003) and so names BOTH ends as pancake
       * hosts. The caller passes the fact rather than the version string
       * because the version is wire vocabulary and the conclusion is what
       * the ledger acts on; `#learnProfile` is where it lands and why.
       *
       * False, or absent, says nothing at all about the far end — a `v1_0`
       * session is the OCapN interop floor, which two pancake peers speak
       * to each other as readily as either speaks it to a Goblins vat. */
      pancakePrivateProfile?: boolean;
      /** What the reporting producer STATES it runs, when it stated
       * anything. This is the only thing that names the producer's own
       * end, and it stands beside `selfKey` as one more fact the producer
       * asserts about itself.
       *
       * Absent means unknown, for a pancake producer exactly as for any
       * other: `#learnProfile` says why a record's own existence proves
       * nothing about the host that sent it. */
      selfProfile?: PeerProfile;
    },
  ): {
    stageId: string;
    aStage: string;
    b: { stage: string; backing: FarEndBacking } | undefined;
  } | null {
    // The wire name is the one name both ends of a session derive, so it is
    // the edge's identity. A session whose partner sent no session key has
    // none; that producer's own scoped id stands in, and since the endpoint
    // scopes ids per connection it cannot collide with another producer's.
    const wireKey = wireKeyFor(sessionId, opts?.wire);
    const existing = this.wires.get(wireKey);
    if (existing !== undefined) {
      // An edge watched from both ends is one edge, always. Whatever
      // this observation teaches lands on the edge already there.
      this.#joinWire(existing, wireKey, sessionId, selfKey, t, out, opts);
      return null;
    }
    // A partner NAME is an identity only when a durable identity verified
    // it. An unverified claim (a browser tab behind a relay claims
    // `127.0.0.1:0` — it has no listening address) must not merge distinct
    // sessions onto one stage peer, so its side is wire-scoped until a
    // producer speaks for it.
    const verified = opts?.verified !== false;
    // Three ways this side can be named, strongest first. A verified
    // name is an identity. Failing that, a caller holding the far
    // end's own report knows whose end this is — no weaker than what
    // `#attributeSide` acts on, and available here only when both reports
    // arrived together. Failing both, nobody can say, and the side is
    // wire-scoped until someone speaks for it.
    const farOwnName = verified ? undefined : opts?.partnerOwnName;
    const otherKey = verified ? bName : farOwnName ?? anonKey(wireKey);
    // The producer's own end runs what the producer SAID it runs, and
    // nothing when it said nothing. That a record arrived is not evidence
    // about the host that sent it; `#learnProfile` carries the reasoning.
    const selfProfile = selfProfileOf(opts);
    const a = this.ensurePeer(selfKey, t, out, {
      eternal: true,
      ...(selfProfile !== undefined && { profile: selfProfile }),
      ...(opts?.aLabel !== undefined && { label: opts.aLabel }),
    });
    // A side nobody can name gets no peer, because there is no peer to
    // draw: what exists is an end of a session carrying a claim nothing
    // backed. It is left loose, and a producer speaking for it later
    // attributes it — which moves the end onto a peer rather than
    // retiring one the viewer made up.
    const attributed = verified || farOwnName !== undefined;
    // Two things can say what the far end runs at the moment it is drawn, and
    // both are somebody's words. The far end's OWN statement, when the caller
    // is holding that end's report of this wire and it is the peer being
    // drawn here — that producer speaking about itself, exactly as
    // `selfProfile` is for this record. Failing that, the pancake-private
    // profile, which names both ends of the session it ran on. Correlating
    // two reports is neither: it says WHO is there, and who is there is not
    // what is there. So a far end on the v1.0 floor that nobody has spoken
    // for joins unknown and learns when its own producer states something.
    const farProfile = (otherKey === opts?.partnerOwnName ? opts?.partnerOwnProfile : undefined) ??
      (opts?.pancakePrivateProfile === true ? PANCAKE_PROFILE : undefined);
    // Attributed means `otherKey` is a name somebody stated, so it is the
    // peer's key and its designator alike; unattributed it is the wire-scoped
    // stand-in for a side nobody spoke for, and no peer is drawn there.
    const b = attributed
      ? this.ensurePeer(
        otherKey,
        t,
        out,
        farProfile === undefined ? undefined : { profile: farProfile },
      )
      : undefined;
    a.liveWires += 1;
    if (b !== undefined) b.liveWires += 1;
    const row: LiveWire = {
      stageId: this.#mintStageId(wireKey, this.#wireIncarnations),
      aKey: selfKey,
      bKey: otherKey,
      observers: new Map([[sessionId, {
        selfStage: a.stageId,
        otherStage: b?.stageId,
        selfKey,
        otherKey,
      }]]),
      seen: new Set(),
      looseClaims: new Map(),
    };
    this.wires.set(wireKey, row);
    this.#wireOfSession.set(sessionId, wireKey);
    this.#applyPendingName(sessionId, t, out);
    return {
      stageId: row.stageId,
      aStage: a.stageId,
      // Attached because the partner name was taken as an identity, or
      // because the far end's own report of this wire named it — the same
      // two arms `otherKey` was chosen from, said out loud.
      b: b === undefined ? undefined : {
        stage: b.stageId,
        backing: verified ? "partner-named" : "correlated",
      },
    };
  }

  /** A second producer reports a wire another already put on stage. What it
   * contributes is the one thing only it knows: which side it is. That
   * identifies a side the first observer could not name.
   *
   * From one observation of a wire whose partner is unverified, the other
   * side's name is simply not derivable, so a picture that draws immediately
   * has to be able to learn. Learning is all that happens here: the edge that
   * exists stays, and the end nobody could name attaches to the peer that
   * spoke for it. */
  #joinWire(
    row: LiveWire,
    wireKey: string,
    sessionId: string,
    selfKey: string,
    t: number,
    out: TimelineEvent[],
    opts?: {
      verified?: boolean;
      aLabel?: string;
      pancakePrivateProfile?: boolean;
      selfProfile?: PeerProfile;
    },
  ): void {
    // Which side is this? The one no other observer speaks for. With both
    // sides already spoken for, an extra observer of the same wire is not a
    // fact this ledger can place, so it is oriented and left at that.
    const spoken = new Set([...row.observers.values()].map((o) => o.selfKey));
    const mine = selfKey === row.aKey || selfKey === row.bKey
      ? selfKey
      : !spoken.has(row.bKey)
      ? row.bKey
      : !spoken.has(row.aKey)
      ? row.aKey
      : row.bKey;
    // This producer says it is this end of this wire, so the name it calls
    // itself and the side nobody could name are the same peer. That is one
    // fact and it lands one way: the loose end attaches to the peer that
    // spoke for it, whether or not that peer was already drawn.
    let side = mine;
    const selfProfile = selfProfileOf(opts);
    if (side === anonKey(wireKey) && selfKey !== side) {
      this.#attributeSide(row, side, selfKey, t, out, selfProfile);
      side = selfKey;
    }
    const theirsAfter = side === row.aKey ? row.bKey : row.aKey;
    const mineRow = this.peers.get(side);
    const theirsRow = this.peers.get(theirsAfter);
    if (mineRow !== undefined) {
      // This end is a reporting host, whatever the other end could prove
      // about it, so it outlives its own sessions like every other producer.
      mineRow.eternal = true;
      // And what it runs is whatever it states it runs. An end another
      // producer drew before anyone could speak for it learns its
      // implementation here, from that producer's own words — the moment of
      // learning this property exists for. A producer that states nothing
      // leaves the end where it was.
      if (selfProfile !== undefined) {
        this.#learnProfile(mineRow, selfProfile, t, out);
      }
      if (opts?.aLabel !== undefined) {
        this.#setSelfLabel(mineRow, opts.aLabel, t, out);
      }
    }
    // A `next` session names both its ends, so this observation can speak
    // for the peer at the other end too, whichever producer drew it.
    if (opts?.pancakePrivateProfile === true && theirsRow !== undefined) {
      this.#learnProfile(theirsRow, PANCAKE_PROFILE, t, out);
    }
    row.observers.set(sessionId, {
      selfStage: mineRow?.stageId ?? side,
      otherStage: theirsRow?.stageId ?? theirsAfter,
      selfKey: side,
      otherKey: theirsAfter,
    });
    this.#wireOfSession.set(sessionId, wireKey);
    this.#applyPendingName(sessionId, t, out);
  }

  /** Point every reference to one side of a wire at a different ledger key.
   * Kept apart from `#attributeSide`, its one caller, because the references
   * are a list a reader has to be able to check against the row's fields.
   *
   * A side's POSITION is fixed when the wire opens: `a` is whichever end the
   * first observer reported as its own, and `b` the other, for the wire's
   * whole life. Only the key at that position moves. Every
   * `session-endpoint-attributed` already recorded names a position, so
   * swapping them here would silently retarget the keyframes the timeline
   * already holds. */
  #retargetSide(row: LiveWire, from: string, to: string): void {
    if (row.aKey === from) row.aKey = to;
    if (row.bKey === from) row.bKey = to;
    for (const [id, obs] of row.observers) {
      const self = obs.selfKey === from ? to : obs.selfKey;
      const other = obs.otherKey === from ? to : obs.otherKey;
      row.observers.set(id, {
        selfKey: self,
        otherKey: other,
        selfStage: this.peers.get(self)?.stageId ?? self,
        otherStage: this.peers.get(other)?.stageId ?? other,
      });
    }
  }

  /** Which end of a wire a ledger key sits on. */
  #sideOf(row: LiveWire, key: string): SessionSide {
    return row.aKey === key ? "a" : "b";
  }

  /** Attribute a loose end: a producer has spoken for the side nobody could
   * name, so the end attaches to that producer's peer.
   *
   * One fact, and it is the viewer's: nothing happened on the wire, the
   * session opened and is still open. What changed is that the end can now be
   * said to be somebody. The end moves onto that peer; nothing is superseded,
   * because nothing was ever drawn in its place. Whether that peer was
   * already on stage does not change the path — ensure it is drawn, then move
   * the end onto it. */
  #attributeSide(
    row: LiveWire,
    from: string,
    to: string,
    t: number,
    out: TimelineEvent[],
    profile: PeerProfile | undefined,
  ): void {
    const side = this.#sideOf(row, from);
    // The speaker reports itself, so it is drawn under its own designator and
    // outlives this session the way every reporting host does. What it RUNS
    // rides along only because the speaker stated it: speaking for an end
    // says who is on it, and who is on it is not what is on it.
    const arrived = this.ensurePeer(to, t, out, {
      eternal: true,
      ...(profile !== undefined && { profile }),
    });
    out.push({
      id: this.nextId(),
      t,
      kind: "session-endpoint-attributed",
      sessionId: row.stageId,
      side,
      peerId: arrived.stageId,
      // A producer asserting it is an end of this wire is a correlation
      // across two producers' self-reports, which is the viewer's own
      // inference and nobody's measurement — the same standing
      // `openSession` gives the arm it calls `correlated` when both
      // reports arrive together.
      attributedBy: "viewer-correlated",
    });
    arrived.liveWires += 1;
    // A name claimed for this end before anyone could say who it was was
    // about this peer all along.
    const claimed = row.looseClaims.get(side);
    if (claimed !== undefined && arrived.claimLabel === undefined) {
      this.#setClaimLabel(to, claimed, t, out);
      row.looseClaims.delete(side);
    }
    this.#retargetSide(row, from, to);
  }

  /** Where one message drew from and to, or null when it is a second
   * end's sighting of a message already on stage, or names a session
   * this ledger never saw open. */
  messageOn(
    sessionId: string,
    outbound: boolean,
    digest: string | undefined,
  ): { sessionId: string; from: string; to: string } | null {
    const wireKey = this.#wireOfSession.get(sessionId);
    if (wireKey === undefined) return null;
    const row = this.wires.get(wireKey);
    const obs = row?.observers.get(sessionId);
    if (row === undefined || obs === undefined) return null;
    // One frame crosses one wire, so both ends hold the same bytes and
    // derive the same tag. The first sighting draws the message and enters
    // the tag; the second CONSUMES it. Consuming rather than remembering is
    // what keeps a peer that really does send identical bytes twice drawing
    // twice.
    if (digest !== undefined && digest.length > 0) {
      if (row.seen.delete(digest)) return null;
      row.seen.add(digest);
      while (row.seen.size > MAX_SEEN_DIGESTS) {
        const oldest = row.seen.values().next();
        if (oldest.done === true) break;
        row.seen.delete(oldest.value);
      }
    }
    // A message whose far end is loose still arrives somewhere: at the
    // end itself, which is drawn and holds a position exactly so that it
    // can be the other end of a line.
    const other = obs.otherStage ??
      endpointStageId(row.stageId, this.#sideOf(row, obs.otherKey));
    return {
      sessionId: row.stageId,
      from: outbound ? obs.selfStage : other,
      to: outbound ? other : obs.selfStage,
    };
  }

  /** Apply a name an application claims for a session's partner, or
   * withdraw the claim with `null`.
   *
   * Emits a rename only when the shown name actually changes. A
   * producer states the name at every moment it knows it — the rooms
   * server annotates a session when a member subscribes to a room AND
   * again when it registers for direct messages, both with the same
   * nick — and restating a name is not a rename. Withdrawing reveals
   * the name underneath rather than freezing the last claim, which is
   * how a member leaving a room stops being called by the nick that
   * membership gave it.
   *
   * A claim for a session the ledger has not seen open waits (a
   * producer replaying its state can send them in either order) and
   * lands as that session opens. */
  nameSessionPartner(
    sessionId: string,
    label: string | null,
    t: number,
    out: TimelineEvent[],
  ): void {
    const wireKey = this.#wireOfSession.get(sessionId);
    const row = wireKey === undefined ? undefined : this.wires.get(wireKey);
    const obs = row?.observers.get(sessionId);
    if (row === undefined || obs === undefined) {
      this.#holdName(sessionId, label);
      return;
    }
    // An end nobody can name yet has no peer to wear the nick, and the claim
    // is about whoever turns out to be there rather than about nobody. It
    // waits on the end itself and transfers when the end attaches; a
    // withdrawal while it is still waiting simply takes it back.
    if (obs.otherStage === undefined) {
      const side = this.#sideOf(row, obs.otherKey);
      if (label === null) row.looseClaims.delete(side);
      else row.looseClaims.set(side, label);
      return;
    }
    this.#setClaimLabel(obs.otherKey, label, t, out);
  }

  /** Land a name claimed before its session opened, at the open's `t`:
   * the peer arrives already answering to it, which is what an early
   * claim means. */
  #applyPendingName(sessionId: string, t: number, out: TimelineEvent[]): void {
    if (!this.#pendingNames.has(sessionId)) return;
    const pending = this.#pendingNames.get(sessionId) ?? null;
    this.#pendingNames.delete(sessionId);
    this.nameSessionPartner(sessionId, pending, t, out);
  }

  /** A partner's application claim about this peer. */
  #setClaimLabel(
    key: string,
    label: string | null,
    t: number,
    out: TimelineEvent[],
  ): void {
    const live = this.peers.get(key);
    if (live === undefined) return;
    live.claimLabel = label ?? undefined;
    this.#showLabel(live, t, out);
  }

  /** What a producer would like its own endpoint called. */
  #setSelfLabel(
    live: LivePeer,
    label: string,
    t: number,
    out: TimelineEvent[],
  ): void {
    live.selfLabel = label;
    this.#showLabel(live, t, out);
  }

  /** State the implementation a peer turns out to run, from this moment on.
   *
   * Two things reach this verdict, both read at a session's hello, and only
   * the second is something the viewer works out for itself:
   *
   * - **What the producer states.** A producer says what it runs beside the
   *   designator it calls itself by (`a_profile` on the record), and that
   *   statement is the whole of what names its own end. The `ocapn.*` kinds
   *   are a schema, not a pancake credential: the Goblins conformance peer
   *   publishes the very same records, so a record ARRIVING says that
   *   something is reporting and nothing whatever about what that something
   *   is. A producer that states nothing leaves its own end unknown, and
   *   that holds for pancake's own producers too — to be named here, you
   *   have to speak.
   * - **The far end of a `next` session.** `pancake-next` is a
   *   pancake-private CapTP profile (ADR-0003), so a session that
   *   negotiated it has a pancake host at each end. This is the one fact
   *   the viewer reads without being told it. The converse proves nothing
   *   and is deliberately not read: two pancake peers meeting on the OCapN
   *   v1.0 interop floor speak `v1_0`, exactly as a Goblins vat does, so a
   *   `v1_0` session leaves its far end where it was.
   *
   * Nothing else is inferred, from a record's existence or from anything
   * else. `goblins` in particular is only ever STATED: no observation here
   * concludes it, and concluding it from the ABSENCE of a pancake marker is
   * the overreach this whole property exists to refuse.
   *
   * The move is one-way, from unknown to named, and the guard below holds
   * it rather than the callers: a second observation restating what is
   * already shown is not a change, and a peer nobody could speak for stays
   * unknown rather than being told so. Learning that a peer runs something
   * ELSE is not a case this can reach, because what a peer runs does not
   * change while it lives — a different implementation is a different
   * peer — so a caller offering one is a caller with a bug, and taking it
   * would report a wire fact nothing observed. */
  #learnProfile(
    live: LivePeer,
    profile: PeerProfile,
    t: number,
    out: TimelineEvent[],
  ): void {
    if (profile === UNNAMED_PROFILE || live.profile !== UNNAMED_PROFILE) return;
    live.profile = profile;
    out.push({
      id: this.nextId(),
      t,
      kind: "peer-updated",
      peerId: live.stageId,
      profile,
    });
  }

  /** Put the most specific name this peer has on screen, emitting a
   * rename only when it differs from what is already there. Display
   * only, in both directions: it reads a ledger key and writes none,
   * so a label can neither merge two peers nor split one. Every naming
   * path lands here, so there is one rule for when a name change is an
   * event. */
  #showLabel(live: LivePeer, t: number, out: TimelineEvent[]): void {
    const next = live.claimLabel ?? live.selfLabel ?? live.joinName;
    if (next === live.shown) return;
    live.shown = next;
    out.push({
      id: this.nextId(),
      t,
      kind: "peer-updated",
      peerId: live.stageId,
      label: next,
    });
  }

  /** Hold a name claimed for a session that has not opened. Only the
   * newest claim per session survives, and the oldest claim overall
   * is dropped once the map is full. */
  #holdName(sessionId: string, label: string | null): void {
    this.#pendingNames.delete(sessionId);
    this.#pendingNames.set(sessionId, label);
    while (this.#pendingNames.size > MAX_PENDING_NAMES) {
      const oldest = this.#pendingNames.keys().next();
      if (oldest.done === true) break;
      this.#pendingNames.delete(oldest.value);
    }
  }

  /** Drop one wire reference; the peer's row ends when its last one
   * goes (unless it is a live producer's own reporting host). `why`
   * carries the reason the wire went, because it is the peer's reason
   * too: a peer whose last conversation the viewer merely stopped
   * WATCHING did not depart. */
  #releasePeer(
    key: string,
    t: number,
    out: TimelineEvent[],
    why: EndingReason,
  ): void {
    const live = this.peers.get(key);
    if (live === undefined) return;
    live.liveWires = Math.max(0, live.liveWires - 1);
    this.#retireIfIdle(key, live, t, out, why);
  }

  #retireIfIdle(
    key: string,
    live: LivePeer,
    t: number,
    out: TimelineEvent[],
    why: EndingReason,
  ): void {
    if (live.liveWires > 0 || live.eternal) return;
    this.peers.delete(key);
    out.push({
      id: this.nextId(),
      t,
      kind: why === "closed" ? "peer-left" : "peer-unobserved",
      peerId: live.stageId,
    });
  }

  /** One producer's observation of a session ended. An explicit CapTP
   * close is a fact about the shared wire, so either endpoint retires
   * the whole row. Losing telemetry is only a fact about that observer;
   * the row then ends when its last observer disappears.
   *
   * `why` says which of those the caller is reporting, and it is the
   * difference between a claim about the network and a claim about
   * this viewer. `closed` means a producer observed CapTP tear the
   * session down. `unobserved` means the viewer lost sight of it and
   * knows nothing about the conversation itself. */
  closeSession(
    sessionId: string,
    t: number,
    out: TimelineEvent[],
    why: EndingReason = "closed",
  ): string[] {
    // An ending ends this session's current life, so a name claimed for it
    // and never applied is moot. Dropping it here is what stops it from
    // naming the NEXT session to take the same id.
    this.#pendingNames.delete(sessionId);
    const wireKey = this.#wireOfSession.get(sessionId);
    if (wireKey === undefined) return [];
    this.#wireOfSession.delete(sessionId);
    const row = this.wires.get(wireKey);
    if (row === undefined) return [];
    row.observers.delete(sessionId);
    if (why === "unobserved" && row.observers.size > 0) return [];
    const retiredObservers = [...row.observers.keys()];
    for (const observerSessionId of row.observers.keys()) {
      this.#wireOfSession.delete(observerSessionId);
      this.#pendingNames.delete(observerSessionId);
    }
    row.observers.clear();
    this.wires.delete(wireKey);
    out.push({
      id: this.nextId(),
      t,
      kind: why === "closed" ? "session-closed" : "session-unobserved",
      sessionId: row.stageId,
    });
    this.#releasePeer(row.aKey, t, out, why);
    this.#releasePeer(row.bKey, t, out, why);
    return retiredObservers;
  }

  /** A producer left the feed, so the node it reported as its own
   * stops being a reporting host. It does not vanish while another
   * producer still shows a session to it — that peer is on stage
   * because someone is talking to it, and only the last of those
   * conversations ending takes it off.
   *
   * Its row ends as a loss of sight, not a departure. What actually
   * happened is that a PUBLISHING SOCKET closed; a peer that turned
   * tracing off looks exactly like one that went away, and picking
   * the second is the inference this vocabulary exists to refuse. */
  producerLeft(key: string, t: number, out: TimelineEvent[]): void {
    const live = this.peers.get(key);
    if (live === undefined) return;
    live.eternal = false;
    this.#retireIfIdle(key, live, t, out, "unobserved");
  }

  /** An explicitly lifecycle-managed leave (generic sims own their
   * hosts' lifetimes; refcounting does not apply). */
  forceLeavePeer(key: string, t: number, out: TimelineEvent[]): void {
    const live = this.peers.get(key);
    if (live === undefined) return;
    this.peers.delete(key);
    out.push({
      id: this.nextId(),
      t,
      kind: "peer-left",
      peerId: live.stageId,
    });
  }

  /** The telemetry endpoint restarted, so everything it was showing
   * goes out of view at once. Incarnation counters survive, so stage
   * ids stay unique across epochs.
   *
   * Every row ends `unobserved`, and none ends closed. Some of these
   * conversations really did die with the process — its own sessions
   * did — but a conversation it was merely REPORTING, two browser
   * tabs talking directly, did not, and the reconnecting producers
   * will draw it again. From here the two are indistinguishable, so
   * the timeline says the one thing that is true of both: the viewer
   * stopped being able to see them. */
  closeEpoch(t: number, out: TimelineEvent[]): void {
    for (const row of this.wires.values()) {
      out.push({
        id: this.nextId(),
        t,
        kind: "session-unobserved",
        sessionId: row.stageId,
      });
    }
    this.wires.clear();
    this.#wireOfSession.clear();
    // A dead process's claims name sessions that will never open.
    this.#pendingNames.clear();
    for (const live of this.peers.values()) {
      out.push({
        id: this.nextId(),
        t,
        kind: "peer-unobserved",
        peerId: live.stageId,
      });
    }
    this.peers.clear();
  }
}
