/// <reference path="../virtual-pancake-web.d.ts" />

/**
 * Live-feed bridge — consume bounded JSON trace records delivered to a hosted
 * inbox capability by the rooms server and convert each record to ocapnviz's
 * OCapN-flavored `TimelineEvent` vocabulary on the fly.
 *
 * Each line of the stream is one JSON object with `v: 1` and a `kind`.
 * The kinds this reads are the `ocapn.*` family, which a producer emits
 * about the protocol it is speaking, and the `trace.*` family, which an
 * endpoint emits about the stream itself. A kind outside those is
 * ignored rather than guessed at.
 *
 * The viewer writes only the capability protocol: it enlivens the announced
 * trace capability, hosts an inbox, and asks to subscribe. It never writes a
 * trace record or gains authority over the observed room.
 */

import type { TimelineEvent } from "./timeline.ts";
import { attributionForProvenance, captpVersionFromWire, sessionEndpoint, UNKNOWN_CODEC } from "../schema/topology.ts";
import type { Codec } from "../schema/topology.ts";
import type { EngineError } from "./errors.ts";
import type { BrowserRuntime, PancakeWebModule } from "./pancake-web-api.ts";
import { StageLedger, wireKeyFor } from "./stage-ledger.ts";

/**
 * One timeline event from the wire — generic base or any extension.
 * Fields that vary by `kind` are kept loose; the converter narrows.
 */
export type BaseTimelineEvent = {
  v: unknown;
  sim_t_ns: unknown;
  kind: unknown;
  /** Producer-stamped monotone sequence number. A producer that
   * replays a ring of recent events to a (re)connecting viewer
   * stamps every line, so the client drops what it already
   * applied instead of duplicating entities on reconnect. Absent
   * on producers without replay. */
  seq?: unknown;
  /** Producer process instance. A restarted producer starts a new
   * epoch: its `seq` resets (so the seq dedup window resets with
   * it) and its session ids may collide with the dead process's.
   * The converter closes every entity of the previous epoch when
   * the epoch changes — the old process's topology is gone.
   * Absent on producers without replay/restart concerns. */
  epoch?: unknown;
  /** `trace.producer-left` only: the departed producer's scope. Endpoint-authored;
   * `trace.` marks a fact about the stream rather than about the protocol. */
  scope?: unknown;
  /** True on lines a producer replayed to a (re)connecting viewer.
   * Replay is STATE, not events: replayed session opens/closes
   * materialize the topology this viewer needs, while replayed
   * messages are the past — they happened before this viewer
   * watched, so they stay out of its capture.
   *
   * A replayed line waits in the converter until the endpoint marks
   * the end of the batch (`trace.replay-end`), because the batch is
   * one picture rather than a sequence of moments: both ends of a
   * wire are in it before anything is drawn, so the viewer never had
   * to learn who was on either. */
  replay?: boolean;
  a?: unknown;
  b?: unknown;
  src?: unknown;
  dst?: unknown;
  /** `ocapn.message-decoded`: departure time of the message in
   * nanoseconds, present when the producer could observe both ends of
   * the link. The renderer animates the message traveling from
   * `depart_ns` to `sim_t_ns`. */
  depart_ns?: unknown;
  arrive_ns?: unknown;
  delivered_ns?: unknown;
  bytes_b64?: unknown;
  summary?: { len?: unknown; head_b64?: unknown };
  // OCapN extractor extension fields:
  /** The producer's own handle for the session, scoped by the endpoint to
   * the producer that sent it. Not the OCapN Session ID: that is
   * `session_id` below, which both ends of one session derive alike and
   * which is therefore the only one that can merge two producers' views. */
  session?: unknown;
  /** `ocapn.session-opened`: the negotiated codec word. The feed is JSON, so
   * this reaches the reader as unknown until the reader proves it is a string. */
  codec?: unknown;
  op?: unknown;
  len?: unknown;
  /** `ocapn.message-decoded` from a live host tap: which side of the session
   * sent it. The producer names only its session; this converter resolves
   * src/dst from the `ocapn.session-opened` it already saw. */
  outbound?: boolean;
  /** `ocapn.session-opened`: what proved `b`'s durable name, in the words
   * `DurableProvenance` lists. Three answers rather than a yes/no: a partner
   * that claimed no durable name and one whose claim nothing on its path could
   * prove are different facts, and only the second is a gap.
   *
   * A string rather than that type because this is the wire, where a producer
   * may send anything; `attributionForProvenance` is the one place a verdict
   * is read. Absent from a producer that predates the field. */
  provenance?: unknown;
  /** `ocapn.session-opened`: the OCapN Transport of `b`'s locator — the
   * netlayer symbol this session runs over. A designator does not name a
   * location on its own; the spec requires the transport beside it. */
  transport?: unknown;
  /** `ocapn.session-opened`: the OCapN **Session ID**, 64 lowercase hex
   * digits. Both peers of one session derive the same value from their two
   * public identifiers, with the pair sorted, so it is the same string in
   * both ends' reports and neither had to be told it. It is what tells one
   * conversation watched twice from two unrelated ones, and so it is the
   * name this converter builds its edges on. Absent when the partner sent
   * no session key, and from a producer that predates the field. */
  session_id?: unknown;
  /** `ocapn.session-opened`: what the reporting host would like itself
   * called on screen — a chat server saying "rooms" rather than showing its
   * 64-digit key designator. Display only: `a` remains the identity every
   * merge decision is made on, and this text, which the producer chose,
   * reaches none of them. */
  a_label?: unknown;
  /** `ocapn.session-opened`: what the reporting host says it RUNS, in the
   * words `PROFILE_OPTIONS` lists. A statement about the producer, standing
   * beside `a` (the name it calls itself by) and `a_label` (what it would
   * like to be called), and the only thing that names its own end.
   *
   * The `ocapn.*` kinds are a schema rather than one implementation's mark:
   * the Goblins conformance peer publishes them too. So a producer that
   * states nothing leaves its end unknown instead of being taken for
   * something. Open-ended, like the `PeerProfile` it becomes — OCapN is
   * implementation-plural, so a producer may name an implementation this
   * build has never heard of and the stage draws it under that name. */
  a_profile?: unknown;
  /** `ocapn.session-opened`: the negotiated CapTP profile, spelled the way
   * the handshake spells it (`"1.0"` / `"pancake-next"`), because a trace
   * reports on the wire. The feed is JSON, so this reaches the reader as
   * unknown until the reader proves it is a string. Absent from a producer
   * that predates the field. */
  captp_version?: unknown;
  /** `ocapn.message-decoded`: a tag over the frame's own bytes, which
   * both ends of the wire derive alike. Two producers watching one
   * session each report every message, and this is what folds their
   * two sightings into one on stage. */
  digest?: unknown;
  /** `ocapn.session-meta`: an application annotation about the
   * session — a claim by the producing application, never protocol
   * identity. `label` names the session's partner in the
   * application's own vocabulary (a chat nick); `null` WITHDRAWS the
   * claim, so the peer answers again to the name underneath. */
  meta?: { label?: unknown };
};

/**
 * Convert one wire event into zero or more OCapN-flavored
 * `TimelineEvent`s. Some inputs (`ocapn.session-opened`,
 * `ocapn.message-decoded`) yield multiple outputs because they
 * reference peers that the renderer needs as separate entities;
 * the ledger synthesizes `peer-joined` events on first sight and on
 * each return, and `peer-left` when a peer's last session closes.
 *
 * Returns `[]` for a kind this viewer does not read.
 */
/** What one feed remembers between records. Named rather than threaded as
 * loose parameters: it started as a ledger, gained an epoch, and gained the
 * producer-to-host map below, and each of those would otherwise have been one
 * more positional argument at every call. */
export type FeedState = {
  ledger: StageLedger;
  epoch: { current: number | undefined };
  /** Producer scope -> the host that producer reports as its own `a`, so a
   * departure retires exactly that node and no other. */
  hostOfScope: Map<string, string>;
  /** Producer scope -> the sessions it is watching. A producer leaving takes
   * its view of them with it, and the endpoint no longer synthesizes a close
   * per session to say so — it reports the departure, and this is what turns
   * that into the right ending for each session the viewer was shown. */
  sessionsOfScope: Map<string, Set<string>>;
  /** The replayed batch, held until the endpoint says it has ended.
   * Empty when no snapshot is in flight, which is every ordinary
   * moment of a live feed. */
  replayBatch: BaseTimelineEvent[];
};

function codecFromWire(codec: unknown): Codec {
  if (typeof codec !== "string") return UNKNOWN_CODEC;
  return codec.length > 0 ? codec : UNKNOWN_CODEC;
}

function stringFromWire(value: unknown): string | undefined {
  return typeof value === "string" ? value : undefined;
}

function nonEmptyStringFromWire(value: unknown): string | undefined {
  const text = stringFromWire(value);
  return text != null && text.length > 0 ? text : undefined;
}

function numberFromWire(value: unknown): number | undefined {
  return typeof value === "number" && Number.isFinite(value) ? value : undefined;
}

/** Which kinds a replayed batch holds.
 *
 * Only the ones that carry topology, because only those are what the
 * batch is FOR: it exists so both ends of a wire are known before
 * either is drawn. Everything else a feed might replay is already
 * dropped on arrival — `applyEvent` refuses replayed messages, which
 * are the past and not this viewer's capture — so buffering them
 * would hold bytes to reach a `continue`.
 *
 * That is also what makes the count bound below a real bound. A
 * message record carries a base64 frame and a session record does
 * not, so holding only these keeps the batch small per record, and
 * counting records is then a fair proxy for holding memory. */
const REPLAY_BATCH_KINDS = new Set([
  "ocapn.session-opened",
  "ocapn.session-closed",
  "ocapn.session-meta",
]);

/** How many replayed records the converter will hold before drawing
 * what it has.
 *
 * The batch is bounded because everything on this feed is
 * attacker-controlled until it has been read: the viewer dials the
 * endpoint, and a feed that marked records `replay` forever would
 * otherwise grow this buffer for the connection's life. Past the
 * bound the batch is drawn rather than dropped — a viewer that
 * silently discarded topology would be worse than one that draws it
 * a moment early and has to learn an end, which is the same honest
 * degradation a feed sending no end-of-batch mark already gets.
 *
 * The number is a backstop, not a fit: a replay carries one row per
 * live session per producer, and this converter takes any producer of
 * the schema, so there is no ceiling upstream to derive it from. What
 * makes it safe is `REPLAY_BATCH_KINDS` above keeping payloads out. */
const MAX_REPLAY_BATCH = 8192;

/** Apply a replayed batch as ONE picture.
 *
 * A snapshot is not a sequence of moments. Every session in it is
 * already open, and a wire watched from both ends is in it twice —
 * so the far end's name is in hand before anything is drawn, and a
 * viewer that left the end loose and then attributed it would be
 * reporting a transition that never happened.
 *
 * What resolves it is one pass over the batch's opens, grouping each
 * wire's reporting selves. A wire with exactly two distinct selves is
 * fully known: each end's own designator is the other end's answer.
 * Anything else — one end reporting, or a shape this cannot read —
 * falls through to what a live feed does, which is honest about what
 * it did not know rather than merely acceptable.
 *
 * The batch then replays in ARRIVAL order through the ordinary path.
 * Every edge is still made by `openSession` and `#joinWire`, in the
 * same order, so the snapshot only hands over a fact the live path
 * had to wait for. What that buys is the same TOPOLOGY and the same
 * names, reached without reporting a learning that did not happen —
 * not identical documents. The live path leaves an unbacked end loose
 * and mints the peer only when a producer speaks for it, so the two
 * paths can reach one picture by different routes.
 * `live-feed.test.ts` holds the equality that does apply.
 *
 * Both of a wire's records still apply — the second is what marks its
 * reporting host eternal, which the first draw does not. */
function removeObservedSession(
  state: FeedState,
  session: string,
  t: number,
  out: TimelineEvent[],
): void {
  const scope = scopeOf(session);
  const watching = state.sessionsOfScope.get(scope);
  if (watching !== undefined) {
    watching.delete(session);
    if (watching.size === 0) state.sessionsOfScope.delete(scope);
  }
  for (
    const retired of state.ledger.closeSession(session, t, out, "unobserved")
  ) {
    const retiredScope = scopeOf(retired);
    const counterpart = state.sessionsOfScope.get(retiredScope);
    if (counterpart === undefined) continue;
    counterpart.delete(retired);
    if (counterpart.size === 0) state.sessionsOfScope.delete(retiredScope);
  }
}

function flushReplayBatch(
  state: FeedState,
  out: TimelineEvent[],
  snapshotT?: number,
): void {
  const batch = state.replayBatch;
  state.replayBatch = [];
  // Both passes ask the same question of a record — is this an open, and
  // which wire is it of — so they ask it once, the same way.
  const replayOpen = (ev: BaseTimelineEvent): {
    wire: string;
    self: string;
    profile: string | undefined;
  } | null => {
    if (stringFromWire(ev.kind) !== "ocapn.session-opened") return null;
    const session = nonEmptyStringFromWire(ev.session);
    const self = nonEmptyStringFromWire(ev.a);
    const partner = nonEmptyStringFromWire(ev.b);
    if (session == null || self == null || partner == null) return null;
    return {
      wire: wireKeyFor(session, nonEmptyStringFromWire(ev.session_id)),
      self,
      profile: nonEmptyStringFromWire(ev.a_profile),
    };
  };
  // Each wire's reporting selves, and what each of them said it runs. The
  // profile rides along because the batch holds it too: an end drawn from the
  // far producer's own report can be drawn as what that producer stated,
  // instead of being drawn unknown and then updated a moment later by the
  // very record that was already in hand.
  const selvesByWire = new Map<string, Map<string, string | undefined>>();
  for (const ev of batch) {
    const open = replayOpen(ev);
    if (open === null) continue;
    const selves = selvesByWire.get(open.wire);
    if (selves === undefined) {
      selvesByWire.set(open.wire, new Map([[open.self, open.profile]]));
    } else selves.set(open.self, open.profile);
  }

  // Only an explicit replay-end makes this batch authoritative. A reconnect
  // snapshot replaces the observations the viewer previously retained: an
  // observation absent now was lost while the byte channel was down. This is
  // deliberately "unobserved", never a claim that the CapTP session closed.
  // Bounded and live-tail fallback flushes omit snapshotT because their batch
  // may be incomplete and therefore cannot prove absence.
  if (snapshotT !== undefined) {
    const present = new Set<string>();
    for (const ev of batch) {
      const open = replayOpen(ev);
      const session = open === null ? undefined : nonEmptyStringFromWire(ev.session);
      if (session !== undefined) present.add(session);
    }
    const retained = [...state.sessionsOfScope.values()].flatMap((sessions) => [
      ...sessions,
    ]);
    for (const session of retained) {
      if (!present.has(session)) {
        removeObservedSession(state, session, snapshotT, out);
      }
    }
  }

  if (batch.length === 0) return;
  for (const ev of batch) {
    const open = replayOpen(ev);
    const selves = open === null ? undefined : selvesByWire.get(open.wire);
    // Exactly two ends reporting is what "fully known" means: each one's own
    // name is the other's answer. One end, or a shape this cannot read,
    // falls through to what a live feed does — which is honest about what it
    // did not know.
    const partnerOwnName = selves?.size === 2 ? [...selves.keys()].find((self) => self !== open?.self) : undefined;
    const stated = partnerOwnName === undefined ? undefined : selves?.get(partnerOwnName);
    applyEvent(ev, state, out, {
      partnerOwnName,
      partnerOwnProfile: stated,
    });
  }
}

/** One record's effect on the stage. `convertEvent` is the envelope
 * around this — epoch changes and the replay batch — and the batch
 * flush calls straight in, so a replayed record cannot re-enter the
 * buffer it is being drained from. */
export function convertEvent(
  ev: BaseTimelineEvent,
  state: FeedState,
): TimelineEvent[] {
  const out: TimelineEvent[] = [];
  const simNs = numberFromWire(ev.sim_t_ns);
  if (simNs == null) return out;
  const kind = stringFromWire(ev.kind);
  if (kind == null) return out;
  const t_ms = simNs / 1_000_000;

  const epoch = numberFromWire(ev.epoch);
  if (epoch != null && epoch !== state.epoch.current) {
    // A new producer process. Retire the old one's topology first;
    // its sessions died with it and its wire ids may now recur.
    if (state.epoch.current !== undefined) {
      state.ledger.closeEpoch(t_ms, out);
    }
    // Both of these are keyed by producer scope, and the scopes of a
    // process that has gone will never be spoken for again — the same
    // reason `closeEpoch` drops the ledger's own per-producer state.
    state.hostOfScope.clear();
    state.sessionsOfScope.clear();
    state.epoch.current = epoch;
    // A batch held from the previous process describes sessions that
    // died with it, and its wire names may now belong to something
    // else. Drawing it into the new epoch would materialize exactly
    // the ghost topology `closeEpoch` just cleared — the same reason
    // it drops names claimed for sessions that will never open.
    state.replayBatch = [];
  }

  // The endpoint has sent everything it had; the picture is complete.
  if (kind === "trace.replay-end") {
    flushReplayBatch(state, out, t_ms);
    return out;
  }
  if (ev.replay === true) {
    // A replayed record the batch cannot use is dropped here rather than
    // held to be dropped later, which is what keeps the bound below a bound
    // on memory and not just on count.
    if (!REPLAY_BATCH_KINDS.has(kind)) return out;
    state.replayBatch.push(ev);
    // A feed that never marks the end cannot grow this without limit.
    if (state.replayBatch.length >= MAX_REPLAY_BATCH) {
      flushReplayBatch(state, out);
    }
    return out;
  }
  // A live record while a batch is open means the endpoint sent no
  // end-of-batch mark — an older one, or another producer of this
  // schema. Draw what is held rather than stranding it. This is a
  // backstop and not the boundary: a quiet feed may send no live
  // record for minutes, and the batch must not wait on one.
  flushReplayBatch(state, out);
  applyEvent(ev, state, out, {
    partnerOwnName: undefined,
    partnerOwnProfile: undefined,
  });
  return out;
}

function applyEvent(
  ev: BaseTimelineEvent,
  state: FeedState,
  out: TimelineEvent[],
  known: {
    partnerOwnName: string | undefined;
    partnerOwnProfile: string | undefined;
  },
): void {
  const { ledger, hostOfScope, sessionsOfScope } = state;
  const simNs = numberFromWire(ev.sim_t_ns);
  if (simNs == null) return;
  const kind = stringFromWire(ev.kind);
  if (kind == null) return;
  const t_ms = simNs / 1_000_000;

  switch (kind) {
    case "ocapn.session-opened": {
      const session = nonEmptyStringFromWire(ev.session);
      const a = nonEmptyStringFromWire(ev.a);
      const b = nonEmptyStringFromWire(ev.b);
      if (session == null || a == null || b == null) return;
      // Which host a producer reports as its own, so its departure can retire
      // exactly that node and no other. The scope prefixes every id this
      // endpoint assigns, so it is readable without a second field.
      const scope = scopeOf(session);
      hostOfScope.set(scope, a);
      const watching = sessionsOfScope.get(scope);
      if (watching === undefined) {
        sessionsOfScope.set(scope, new Set([session]));
      } else watching.add(session);
      // What the producer's verdict proved, if it proved anything. One read of
      // it, so the same answer decides whether the far end may be taken as an
      // identity and what the attached end says backed it.
      const provenance = stringFromWire(ev.provenance);
      const proved = attributionForProvenance(provenance);
      // The negotiated CapTP profile, read once: omitted means an old producer
      // from before the field, while a present unknown word remains unknown.
      // Only the pancake-private track names both ends as pancake hosts.
      const captpVersion = captpVersionFromWire(ev.captp_version) ?? "v1_0";
      const aLabel = stringFromWire(ev.a_label);
      const aProfile = nonEmptyStringFromWire(ev.a_profile);
      const sessionId = nonEmptyStringFromWire(ev.session_id);
      const transport = nonEmptyStringFromWire(ev.transport);
      const row = ledger.openSession(session, a, b, t_ms, out, {
        ...(provenance != null && { verified: proved !== undefined }),
        // Display only. `a` is the reporting host's own designator, which is
        // what a partner names it by and therefore the one honest merge key
        // across producers; `a_label` is what a human reads instead of 64 hex
        // digits, and it reaches no key and no merge.
        ...(aLabel != null && { aLabel }),
        // What the producer says it runs, which is the only thing that names
        // its own end. An empty string is a producer saying nothing, not an
        // implementation with no name, so it is left unstated the way an
        // empty transport is.
        ...(aProfile != null ? { selfProfile: aProfile } : {}),
        // The one name both ends of this session derive. It is what makes
        // this observation and the far end's observation the same edge.
        ...(sessionId != null && { wire: sessionId }),
        // Set only when a resolved snapshot already holds the far end's own
        // report of this wire. Live, nothing can supply it.
        ...(known.partnerOwnName !== undefined &&
          { partnerOwnName: known.partnerOwnName }),
        // And what that far end's own report says it runs, which the same
        // resolved snapshot holds. Live, nothing can supply either.
        ...(known.partnerOwnProfile !== undefined &&
          { partnerOwnProfile: known.partnerOwnProfile }),
        // `pancake-next` is pancake's own CapTP profile and travels only
        // between pancake peers (ADR-0003), so a session on it says what
        // both of its ends run. `v1_0` is the OCapN interop floor and says
        // nothing — pancake speaks it too.
        ...(captpVersion === "next" && { pancakePrivateProfile: true }),
      });
      // Null means another producer already put this wire on stage: an edge
      // watched from both ends is still one edge.
      if (row === null) return;
      out.push({
        id: ledger.nextId(),
        t: t_ms,
        kind: "session-opened",
        sessionId: row.stageId,
        // The reporting host's own end is attributed by its self-report;
        // the far end attaches only when something backed its claim, and
        // otherwise stays loose with the claim on it.
        a: sessionEndpoint({
          peer: row.aStage,
          designator: a,
          attributedBy: "self-reported",
        }),
        // What backed the far end is what the ledger says put it there, never
        // a guess read back off this record. An end the ledger attached by
        // correlating two producers' reports of one session id says exactly
        // that; an end attached because the producer named it carries the
        // producer's own verdict — and carries NOTHING when the producer
        // stated no verdict, because then nothing was measured and the viewer
        // has no attribution to offer. Attached with no attribution is the
        // shape an authored scenario already has: somebody is on this end, and
        // the recording does not say what proved it.
        b: sessionEndpoint(
          row.b === undefined ? { designator: b } : {
            peer: row.b.stage,
            designator: b,
            attributedBy: row.b.backing === "correlated" ? "viewer-correlated" : proved,
          },
        ),
        // The netlayer this session runs over, carried straight across.
        // Both ends share it, so it belongs to the session and not to
        // either end. A producer that reports none predates the field.
        ...(transport != null ? { transport } : {}),
        codec: codecFromWire(ev.codec),
        // This document's own tag for the profile, read off the handshake
        // word the producer sent (`captpVersionFromWire`). A producer that
        // reports none predates the field, and the only profile that
        // existed then was the floor; a present unknown word stays unknown.
        captpVersion,
        // The trace reports a session only once its handshake
        // completed, so it arrives on stage already open — without
        // this the stage shows "negotiating" forever.
        initialState: "open",
      });
      return;
    }
    case "ocapn.message-decoded": {
      // Replayed messages are history, not part of this viewer's
      // capture — replay materializes topology (state) only.
      if (ev.replay === true) return;
      const session = nonEmptyStringFromWire(ev.session);
      if (session == null) return;
      // A live host tap names only its session and direction; the ledger
      // owns endpoint labeling, and owns folding a second end's sighting of
      // the same message into the first. An extractor that knows src/dst
      // directly still names them itself.
      let from: string | undefined;
      let to: string | undefined;
      let sessionStage: string | undefined;
      const src = nonEmptyStringFromWire(ev.src);
      const dst = nonEmptyStringFromWire(ev.dst);
      if (src != null && dst != null) {
        from = ledger.ensurePeer(src, t_ms, out).stageId;
        to = ledger.ensurePeer(dst, t_ms, out).stageId;
      } else if (ev.outbound !== undefined) {
        const drawn = ledger.messageOn(
          session,
          ev.outbound,
          stringFromWire(ev.digest),
        );
        if (drawn === null) return;
        from = drawn.from;
        to = drawn.to;
        sessionStage = drawn.sessionId;
      }
      if (from === undefined || to === undefined) return;
      // When the producer captured the departure timestamp, anchor
      // the message-sent event at depart and let arrivalT carry the
      // observed flight time. The renderer animates `t → arrivalT`.
      // Without depart_ns (a live host tap observes only arrival),
      // stamp arrivalT EQUAL to t: the projection reads a zero
      // flight as "unobserved" and substitutes its default, so the
      // message flies visibly instead of in a sub-frame flash.
      const departNs = numberFromWire(ev.depart_ns);
      const depart_t_ms = departNs !== undefined ? departNs / 1_000_000 : t_ms;
      // Payload pass-through: whole frame (`bytes_b64`) or the
      // producer-capped head (`summary`); the true length rides
      // beside either. This layer neither decodes nor re-bounds —
      // the producer owns the cap, the Inspector owns the display.
      const bytesB64 = stringFromWire(ev.bytes_b64) ??
        stringFromWire(ev.summary?.head_b64);
      const byteLen = numberFromWire(ev.len) ?? numberFromWire(ev.summary?.len);
      const label = stringFromWire(ev.op);
      out.push({
        id: ledger.nextId(),
        t: depart_t_ms,
        kind: "message-sent",
        sessionId: sessionStage ?? session,
        messageId: ledger.nextId(),
        from,
        to,
        arrivalT: t_ms,
        ...(label != null && { label }),
        ...(bytesB64 !== undefined && { bytesB64 }),
        ...(byteLen !== undefined && { byteLen }),
      });
      return;
    }
    case "ocapn.session-meta": {
      // An application annotation about the session's PARTNER — the
      // reporting host is `a`, so the name is about `b`. A claim
      // folds into the partner's label only; it never merges or
      // splits peers (the ledger's identity rules are untouched).
      const session = nonEmptyStringFromWire(ev.session);
      if (session == null || ev.meta === undefined) return;
      if (ev.meta.label === undefined) return;
      const label = ev.meta.label === null ? null : stringFromWire(ev.meta.label);
      if (label === undefined) return;
      // The ledger owns what each stage peer is called, so it decides
      // whether this claim is a rename, a withdrawal, a restatement to
      // ignore, or a name to hold until its session opens.
      ledger.nameSessionPartner(session, label, t_ms, out);
      return;
    }
    case "trace.producer-left": {
      // A reporting host outlives its sessions, because a room server is
      // there whether or not anyone is connected. That reasoning ends at the
      // producer's own life: a browser tab that refreshes is gone, and its
      // node would otherwise be one nothing could retire. Only the endpoint
      // knows a producer departed, so it says so and this retires the one
      // host that producer spoke for.
      //
      // Its sessions go too, and they go as UNOBSERVED. The endpoint reports
      // only that the producer left; whether the conversations it was
      // watching are still running is not something anyone observed, and the
      // viewer is the layer that decides what a departure means for its own
      // picture. A wire the departing producer shared with another producer
      // still standing survives, because the ledger only ends a wire when
      // its LAST observer goes.
      const scope = nonEmptyStringFromWire(ev.scope);
      if (scope == null) return;
      const watched = sessionsOfScope.get(scope);
      if (watched !== undefined) {
        sessionsOfScope.delete(scope);
        for (const sessionId of watched) {
          ledger.closeSession(sessionId, t_ms, out, "unobserved");
        }
      }
      const host = hostOfScope.get(scope);
      if (host === undefined) return;
      hostOfScope.delete(scope);
      ledger.producerLeft(host, t_ms, out);
      return;
    }
    case "ocapn.session-closed": {
      const session = nonEmptyStringFromWire(ev.session);
      if (session == null) return;
      // A closed session is no longer one its producer is watching, so
      // it leaves the producer's set here. Without this the set only
      // ever grew, and a producer that opens and closes conversations
      // all day carried every one it had ever reported until it left.
      // The scope's whole row goes when its last session does.
      const scope = scopeOf(session);
      const watching = sessionsOfScope.get(scope);
      if (watching !== undefined) {
        watching.delete(session);
        if (watching.size === 0) sessionsOfScope.delete(scope);
      }
      for (const retired of ledger.closeSession(session, t_ms, out)) {
        const retiredScope = scopeOf(retired);
        const counterpart = sessionsOfScope.get(retiredScope);
        if (counterpart === undefined) continue;
        counterpart.delete(retired);
        if (counterpart.size === 0) sessionsOfScope.delete(retiredScope);
      }
      return;
    }
    default:
      return;
  }
}

/**
 * Stateful converter — the `StageLedger` tracks live incarnations
 * across calls so `peer-joined` fires once per lifetime, closes
 * release refcounts, and a producer restart (epoch change) retires
 * the previous process's topology.
 */
/** The producer scope the endpoint prefixed onto a session id (`p3/live-h1-s2`).
 * The endpoint assigns it, so it is the one part of an id no producer chose. */
function scopeOf(sessionId: string): string {
  const at = sessionId.indexOf("/");
  return at < 0 ? "" : sessionId.slice(0, at);
}

export function makeBaseEventConverter(): (
  ev: BaseTimelineEvent,
) => TimelineEvent[] {
  const state = newFeedState();
  return (ev) => convertEvent(ev, state);
}

/** A feed's memory, fresh. `makeBaseEventConverter` is the ordinary
 *  door; this and `convertEvent` are the same thing with the state
 *  named, so a caller that has to weigh what a feed RETAINS — every
 *  map here is per producer or per conversation, and each has to give
 *  its rows back — can hold it and look. */
export function newFeedState(): FeedState {
  return {
    ledger: new StageLedger(),
    epoch: { current: undefined },
    hostOfScope: new Map(),
    sessionsOfScope: new Map(),
    replayBatch: [],
  };
}

/**
 * The bounded record payload is deliberately the same JSON string the
 * producer/schema path already uses. There is one parser and one converter;
 * CapTP is only the capability transport around that authority.
 */
const RECONNECT_MIN_MS = 500;
const RECONNECT_MAX_MS = 5_000;
export const MAX_TRACE_RECORD_BYTES = 1 << 20;

export type LivePeer = {
  close: () => void;
  /** Settles when this exact CapTP session and its hosted inbox are gone. */
  closed: Promise<void>;
};
export type LivePeerFactory = (
  sturdyref: string,
  onRecord: (line: string) => void,
) => Promise<LivePeer>;

let browserRuntimePromise: Promise<BrowserRuntime> | null = null;

function wasmUrl(): string {
  const configured = (globalThis as { __OCV_PANCAKE_WASM_URL?: string })
    .__OCV_PANCAKE_WASM_URL;
  return configured ?? "/pancake_host.wasm";
}

async function browserRuntime(): Promise<BrowserRuntime> {
  if (browserRuntimePromise !== null) return await browserRuntimePromise;
  browserRuntimePromise = (async () => {
    const override = (globalThis as {
      __OCV_PANCAKE_WEB_LOADER?: () => Promise<PancakeWebModule>;
    }).__OCV_PANCAKE_WEB_LOADER;
    const web = override === undefined ? await import("virtual:pancake-web") : await override();
    // `init` is identity-sensitive by design. Keep this one options object
    // for the page, so remounting Live mode does not attempt a second runtime.
    return await web.init({ wasm: fetch(wasmUrl()) });
  })();
  try {
    return await browserRuntimePromise;
  } catch (error) {
    browserRuntimePromise = null;
    throw error;
  }
}

/** The production browser peer. The socket is created by `@pancake/runtime` from
 * the sturdyref's parsed locator; this function never interprets or forwards
 * CapTP bytes. */
export const browserPeerFactory: LivePeerFactory = async (
  sturdyref,
  onRecord,
) => {
  const runtime = await browserRuntime();
  const { locator } = runtime.parseSturdyRef(sturdyref, "v1_0");
  const session = await runtime.connect(locator);
  const closed = session.serve();
  // Construction may still be enlivening when the session fails. Attach a
  // handler immediately; callers still receive the original promise below.
  void closed.catch(() => {});
  let closing = false;
  try {
    const inbox = session.spawn((verb, args) => {
      if (
        verb !== "record" || args.length !== 1 || typeof args[0] !== "string"
      ) {
        throw new Error("trace inbox expects one JSON string record");
      }
      const bytes = new TextEncoder().encode(args[0]).byteLength;
      if (bytes > MAX_TRACE_RECORD_BYTES) {
        void session.close();
        throw new Error("trace record exceeds the viewer bound");
      }
      onRecord(args[0]);
      return null;
    });
    const trace = await session.enliven(sturdyref);
    await session.send(trace, "subscribe", [inbox]);
    return {
      closed,
      close: () => {
        if (closing) return;
        closing = true;
        void session.close();
      },
    };
  } catch (error) {
    await Promise.resolve(session.close()).catch(() => {});
    await closed.catch(() => {});
    throw error;
  }
};

export class LiveFeed {
  #sturdyref: string;
  #peer: LivePeer | null = null;
  #factory: LivePeerFactory;
  #convert = makeBaseEventConverter();
  #subscribers = new Set<(ev: TimelineEvent) => void>();
  #errorSubscribers = new Set<(error: EngineError) => void>();
  /** Who hears whether this feed is connected, or null when nobody
   * owns it any more. A feed that has been disconnected clears the
   * slot, because `ws.onclose` fires asynchronously AFTER `close()`
   * returns: a slot left pointing at the last owner is how a
   * replaced feed writes `false` over its successor's `true`. */
  #onConnectionChange: ((connected: boolean) => void) | null = null;
  /** Highest live-tail producer `seq` applied. A reconnect's snapshot still
   * passes through at old sequence numbers so it can reconcile current state;
   * ordinary live records at or below this are dropped. Scoped to the
   * producer `#epoch`: a restarted producer restarts its seq, so
   * the window resets with the epoch (the converter separately
   * retires the dead epoch's topology). */
  #lastSeq = Number.NEGATIVE_INFINITY;
  #epoch: number | undefined = undefined;
  /** True after `disconnect()` — a deliberate close never
   * reconnects; a dropped connection does, with capped backoff. */
  #closedByUser = false;
  #reconnectTimer: number | null = null;
  #reconnectDelayMs = RECONNECT_MIN_MS;
  #generation = 0;
  #connecting = false;

  constructor(
    sturdyref: string,
    factory: LivePeerFactory = browserPeerFactory,
  ) {
    this.#sturdyref = sturdyref;
    this.#factory = factory;
  }

  connect(): void {
    if (this.#peer !== null || this.#connecting) return;
    this.#closedByUser = false;
    if (
      !this.#sturdyref.startsWith("ocapn://") ||
      !this.#sturdyref.includes("/s/")
    ) {
      this.#emitError({
        code: "validation",
        title: "Live capability invalid",
        detail: `The live endpoint did not provide a sturdyref: "${this.#sturdyref}"`,
        recovery: "Paste the complete sturdyref announced by the rooms server.",
      });
      return;
    }
    const generation = ++this.#generation;
    this.#connecting = true;
    void this.#factory(
      this.#sturdyref,
      (line) => this.#receive(generation, line),
    ).then(
      (peer) => {
        this.#connecting = false;
        if (generation !== this.#generation || this.#closedByUser) {
          peer.close();
          return;
        }
        this.#peer = peer;
        this.#reconnectDelayMs = RECONNECT_MIN_MS;
        this.#onConnectionChange?.(true);
        void peer.closed.then(
          () => this.#peerClosed(generation),
          (cause) => this.#peerClosed(generation, cause),
        );
      },
      (cause) => {
        this.#connecting = false;
        if (generation !== this.#generation || this.#closedByUser) return;
        this.#onConnectionChange?.(false);
        this.#emitError({
          code: "internal",
          title: "Live capability unreachable",
          detail: cause instanceof Error ? cause.message : String(cause),
          recovery: "Check the sturdyref and the rooms server, then wait for reconnect.",
          cause,
        });
        this.#scheduleReconnect();
      },
    );
  }

  #receive(generation: number, line: string): void {
    if (generation !== this.#generation || this.#closedByUser) return;
    if (new TextEncoder().encode(line).byteLength > MAX_TRACE_RECORD_BYTES) {
      return;
    }
    try {
      const raw = JSON.parse(line) as BaseTimelineEvent;
      const epoch = numberFromWire(raw.epoch);
      if (epoch != null && epoch !== this.#epoch) {
        this.#epoch = epoch;
        this.#lastSeq = Number.NEGATIVE_INFINITY;
      }
      const seq = numberFromWire(raw.seq);
      if (seq != null) {
        // Replay is the endpoint's complete current snapshot, not history to
        // deduplicate. Old sequence numbers must reach the converter so replay
        // completion can remove observations that disappeared during outage.
        if (raw.replay !== true && seq <= this.#lastSeq) return;
        this.#lastSeq = Math.max(this.#lastSeq, seq);
      }
      const converted = this.#convert(raw);
      for (const ev of converted) {
        for (const sub of this.#subscribers) sub(ev);
      }
    } catch (error) {
      console.error("LiveFeed: capability record parse error", error);
    }
  }

  #peerClosed(generation: number, _cause?: unknown): void {
    if (generation !== this.#generation || this.#closedByUser) return;
    this.#peer = null;
    this.#connecting = false;
    this.#onConnectionChange?.(false);
    this.#scheduleReconnect();
  }

  #scheduleReconnect(): void {
    if (this.#closedByUser || this.#reconnectTimer !== null) return;
    this.#reconnectTimer = setTimeout(() => {
      this.#reconnectTimer = null;
      this.connect();
    }, this.#reconnectDelayMs) as unknown as number;
    this.#reconnectDelayMs = Math.min(
      this.#reconnectDelayMs * 2,
      RECONNECT_MAX_MS,
    );
  }

  /** Close for good. A disconnected feed never reconnects and never
   *  reports again: the connection slot is cleared here so the
   *  `onclose` the browser delivers after this call reaches nobody. */
  disconnect(): void {
    this.#closedByUser = true;
    this.#generation += 1;
    this.#onConnectionChange = null;
    if (this.#reconnectTimer !== null) {
      clearTimeout(this.#reconnectTimer);
      this.#reconnectTimer = null;
    }
    if (this.#peer !== null) {
      this.#peer.close();
      this.#peer = null;
    }
    this.#connecting = false;
  }

  subscribe(cb: (ev: TimelineEvent) => void): () => void {
    this.#subscribers.add(cb);
    return () => {
      this.#subscribers.delete(cb);
    };
  }

  /**
   * Hear whether this feed is connected. Returns an unsubscribe, the
   * way `subscribe` does, and for the same reason one level
   * up: the owner that registered has to be able to stop being the
   * owner. A slot with no way out is what let a torn-down feed's late
   * `onclose` write `false` into a live component's state after its
   * replacement had already reported `true`.
   *
   * One slot, not a set: the connection is one fact about one socket
   * and the app shows it in one place. Registering a second callback
   * replaces the first.
   */
  onConnectionChange(cb: (connected: boolean) => void): () => void {
    this.#onConnectionChange = cb;
    return () => {
      if (this.#onConnectionChange === cb) this.#onConnectionChange = null;
    };
  }

  /**
   * Hear about a failure this feed cannot recover from on its own, such as an
   * invalid sturdyref or a failed dial/enliven. Returns an
   * unsubscribe. Subscribers registered before `connect()` hear the
   * dial's own refusal, which is why `startLiveMode` takes the
   * callback as an option rather than letting its caller attach one
   * afterwards.
   */
  onError(cb: (error: EngineError) => void): () => void {
    this.#errorSubscribers.add(cb);
    return () => {
      this.#errorSubscribers.delete(cb);
    };
  }

  #emitError(error: EngineError): void {
    if (this.#errorSubscribers.size === 0) {
      console.error("LiveFeed:", error.detail);
      return;
    }
    for (const sub of this.#errorSubscribers) sub(error);
  }
}
