import { z } from "zod";

/**
 * One end of a session: who it claims to be, what backed that claim,
 * and the stage node it occupies when nothing has.
 *
 * Wire vocabulary (profile, transport, codec, CapTP version, session
 * lifecycle) lives in [`topology.ts`](./topology.ts).
 */

/**
 * Which end of a session is meant. A session joins two peers and the
 * observations name them `a` and `b`, so these are those two names
 * said once. The endpoint keyframe tracks, the resolver that reads
 * them, and the observation that states one all spell a side the
 * same way.
 */
export const SessionSide = z.enum(["a", "b"]);
export type SessionSide = z.infer<typeof SessionSide>;

/** Both ends, in the order everything lists them. */
export const SESSION_SIDES: readonly SessionSide[] = ["a", "b"];

/**
 * What backed an endpoint's claim to be who it says it is.
 *
 * A session's end always carries a designator, the name it claims, dialed or
 * read out of a hello. Whether anything *proved* that claim is a separate
 * question, and it is the one that decides whether the end is attached to a
 * peer at all. Absent, on an endpoint, means nothing proved it: the end is
 * loose, and the claim stays a claim.
 *
 * Two of these are facts the network produced and the host measured. The
 * first is glowcap's authenticated `DurableProvenance` verdict, spelled the
 * way the trace spells it. The last is the viewer's own,
 * and it is the weakest: two producers reporting one OCapN
 * Session ID is a correlation across two self-reports, not a proof, and
 * drawing it as one would be the viewer overreaching. The ledger already
 * refuses that conflation at the door: `StageLedger.openSession` takes the far
 * end's own report as `partnerOwnName`, a separate option from `verified`, so
 * a correlation cannot arrive spelled as a proof. This is the word for what
 * comes out of it.
 *
 * `verified-handoff` is its own fact and not a spelling of the durable
 * verdict. The exporter verified a signed three-party handoff: the gifter's
 * give named the session key this end holds, and the receive that arrived
 * here was signed with it and bound to this connection. That proves the end
 * is the party the gifter designated. It says nothing about the durable name
 * in the end's hello, which is a separate fact decided once before the
 * session opened, glowcap's handoff path never writes `durable_pin`, so an
 * address-designator peer can redeem a gift and stay `unauthenticated`
 * (`src/ocapn/engine/inbound.zig`). Folding it into durable provenance would
 * claim the hello's designator was proved when nothing proved it.
 *
 * Each value says what did the backing, never merely where it came from. A
 * bare `transport` here would sit one row above the session's own `transport`
 * field, which names the netlayer the bytes ride, and a reader could not tell
 * the two apart: one is a name like `keyed-tcp`, the other is the claim that
 * a lower layer authenticated a durable key.
 *
 * `self-reported` is why no session is ever loose at both ends. The producer
 * reporting a session is the thing doing the talking, so its own end is
 * attributed by that alone, and every session is anchored to at least one
 * peer.
 */
export const EndpointAttribution = z.enum([
	"authenticated-transport",
	"verified-handoff",
	"self-reported",
	"viewer-correlated",
]);
export type EndpointAttribution = z.infer<typeof EndpointAttribution>;

/**
 * What kind of evidence one attribution is, which is a different question
 * from which word it is.
 *
 * Two of the words mean a signature somebody checked, so a reader who tells
 * them apart is telling apart *which* signature rather than how much the name
 * is worth. `self-reported` is the producer speaking about its own end, which
 * is true by construction and checked by nothing. `viewer-correlated` is this
 * viewer's own inference from two producers naming one session id, and it is
 * the only word here that no party to the session stated.
 *
 * It lives beside the enum because two surfaces ask it and they must not
 * answer differently: the Inspector's chip picks its tone from the answer, and
 * the Reference groups its rows by it. Spelled once, a word added above fails
 * to compile until it is classified, and the chip and the Reference cannot
 * drift apart.
 */
export type AttributionStanding = "checked" | "stated" | "inferred";

/** The evidence behind each word. */
export const ATTRIBUTION_STANDING: Record<
	EndpointAttribution,
	AttributionStanding
> = {
	"authenticated-transport": "checked",
	"verified-handoff": "checked",
	"self-reported": "stated",
	"viewer-correlated": "inferred",
};

/**
 * What the app calls an end that nothing has attributed.
 *
 * Absence is not one of the words above, so it has no stored spelling of its
 * own, and two surfaces still have to name it: the Inspector's chip wears it
 * where a word would go, and the Reference explains it beside the four. One
 * phrasing, so a reader who meets it on a chip finds that same phrase when
 * they go looking for what it means.
 */
export const UNATTRIBUTED_WORD = "nothing proved this";

/**
 * What a glowcap host reports having authenticated a partner's durable name
 * with. The viewer's mirror of the Zig `engine.DurableProvenance`
 * (`src/ocapn/engine/mod.zig`), which reaches a trace consumer through the C
 * ABI and the TypeScript binding.
 *
 * One list rather than the words written wherever each is tested, so the mirror
 * is a single declaration to hold the Zig enum against. `zig build source-check`
 * (`checkViewerProvenanceMirror`) does hold it, tag by tag, and it reads this
 * declaration rather than the file: every word here is also read by
 * `attributionForProvenance` below, so a search of the whole module finds the
 * word whether or not this list still carries it.
 *
 * A verdict is still added here by hand, because the viewer is a separate Deno
 * scope that links no glowcap package and no generated tier reaches it. What
 * the check removes is the silence. An unrecognized verdict maps to no
 * attribution, which would draw as "nothing proved this" and look like an
 * answer rather than a gap.
 */
export const DurableProvenance = z.enum([
	"authenticated-transport",
	"unauthenticated",
]);
export type DurableProvenance = z.infer<typeof DurableProvenance>;

/**
 * The attribution a producer's provenance verdict backs, or undefined when the
 * verdict backs nothing an end can be attributed by.
 *
 * The authenticated verdict is spelled exactly as `EndpointAttribution`
 * spells it, so carrying it across is a narrowing rather than a translation.
 * `unauthenticated` proved nothing, and so does a
 * word this viewer does not recognize, a producer whose vocabulary has moved
 * past this list has told the viewer nothing it can name.
 *
 * An address transport always lands on `unauthenticated`, and that is the
 * network's answer rather than a hole in the viewer. A plain `tcp` locator
 * designates a socket address, so the name a hello claims is not a durable
 * identity and there is nothing for either proof to be about. What CapTP does
 * verify on such a session, the Ed25519 signature over the partner's
 * `<my-location …>` record, proves only that whoever answered holds the key
 * they just sent, and that key is drawn fresh per connection (ADR-0097), so it
 * names nobody across connections.
 *
 * A key designator is what lets a hello CLAIM a durable name, and claiming is
 * not being authenticated. Which sessions carry an attribution here is not a
 * question about the transport symbol at all: `engine.DurableProvenance` in
 * `src/ocapn/engine/mod.zig` derives the verdict from the evidence one session
 * holds, and says why, that the same transport name realized by different code
 * gives a different answer. What earns the authenticated verdict is a lower
 * layer having proved that the far end of the byte channel holds the key the
 * partner claimed. A cleartext transport proves nothing of the sort, so a key
 * designator there is a dial target and the durable name it carries stays a
 * claim.
 *
 * No list of which transports manage it. That list is the
 * network's to state and it has moved once already. The viewer would be a
 * second copy of it, drifting quietly, while every session's own verdict
 * arrives on the trace and needs no such table to be read.
 *
 * So a glowcap pair whose channel nothing authenticated attributes its far end
 * by correlation, if a second producer speaks for it, and a Goblins peer there
 * stays loose.
 *
 * No verdict maps to `verified-handoff`, and that is the boundary rather
 * than an omission: a verified handoff is a fact about one gift redemption,
 * glowcap's trace does not report it, and no producer can send it today. It
 * reaches a document by being authored.
 */
export function attributionForProvenance(
	verdict: string | undefined,
): EndpointAttribution | undefined {
	const parsed = DurableProvenance.safeParse(verdict);
	if (!parsed.success) return undefined;
	return parsed.data === "unauthenticated" ? undefined : parsed.data;
}

/**
 * One end of a session.
 *
 * `designator` is what this end claims to be, dialed, or read out of the
 * partner's hello. `attributedBy` is what backed that claim, and `peer` is the
 * peer the end is attached to as a result. The invariant runs one way:
 * `attributedBy` present means `peer` present, because nothing can attribute
 * an end to nobody. The converse does not hold, a hand-authored scenario
 * attaches a peer without measuring anything, and in Build mode the author is
 * the authority.
 *
 * An end with a `designator` and no `attributedBy` is **loose**: the claim
 * exists, nothing proved it, and no peer is attached. That is an ordinary
 * state of the network rather than a gap in the viewer, and it is why this is
 * a structure and not a bare peer id: a bare id has nowhere to put the claim,
 * so the ledger would have to invent a peer to hold it.
 *
 * A bare string is shorthand for `{ peer }`, which is how an authored scenario
 * reads: `a: "phone"`.
 *
 * The type is branded, so an endpoint and a peer id are two types rather than
 * two shapes that happen to differ. Every field here is optional, and without
 * the brand TypeScript reads `endpoint === peerId` as a comparison worth
 * allowing. It is not, since it is always false, and it shipped twice: a peer
 * reported as belonging to no session, and a message the authoring guard
 * refused to move. `sessionEndpoint` below is the way one is built.
 */
const SessionEndpointShape = z.object({
	peer: z.string().min(1).optional(),
	designator: z.string().optional(),
	attributedBy: EndpointAttribution.optional(),
}).refine(
	// Parsing is where an endpoint arrives already built, a loaded document, a
	// pasted fragment, so this is the invariant's guard against input nobody
	// here constructed. Code that builds one goes through `sessionEndpoint`,
	// where `EndpointParts` carries the same rule in the type.
	(e) => e.attributedBy === undefined || e.peer !== undefined,
	{ message: "an endpoint attributed by something must name the peer" },
);

export const SessionEndpoint = z.preprocess(
	// The shorthand normalizes on the way in, so every reader downstream sees
	// one shape rather than a union it has to narrow at each use.
	(raw) => (typeof raw === "string" ? { peer: raw } : raw),
	SessionEndpointShape,
).brand<"SessionEndpoint">();
export type SessionEndpoint = z.infer<typeof SessionEndpoint>;

/** What an endpoint is built from.
 *
 *  The one-way invariant is the shape of this union rather than a check the
 *  builder runs: an end that names no peer has nothing that could have
 *  attributed it, so `attributedBy` is not a field it has. A caller that tries
 *  to attribute a loose end does not fail at runtime. It does not compile.
 *
 *  Each optional field admits an explicit `undefined` so a caller holding one
 *  field at a time can hand them all over as they are. Editing an end is
 *  exactly that shape (`authoring/session.ts` resolves three patches against
 *  three current values), and a union a builder cannot spell is a union a
 *  builder goes around. */
export type EndpointParts =
	| {
		peer: string;
		designator?: string | undefined;
		attributedBy?: EndpointAttribution | undefined;
	}
	| {
		peer?: undefined;
		designator?: string | undefined;
		attributedBy?: undefined;
	};

/** Build one end of a session. The only way to make one outside a parse, so
 *  the invariant above is checked once, where the type is declared. */
export function sessionEndpoint(parts: EndpointParts): SessionEndpoint {
	return {
		...(parts.peer !== undefined && { peer: parts.peer }),
		...(parts.designator !== undefined && { designator: parts.designator }),
		...(parts.attributedBy !== undefined &&
			{ attributedBy: parts.attributedBy }),
	} as SessionEndpoint;
}

/** An endpoint attached to `peer` with nothing recorded about what attributed
 *  it, how an authored scenario names an end, and the shorthand a document
 *  may spell as the bare id. */
export function attachedEndpoint(peer: string): SessionEndpoint {
	return sessionEndpoint({ peer });
}

/** An end nothing has attributed, claiming `designator` when something named
 *  it and nothing at all when nobody has.
 *
 *  This is a session dialing out before anything answers for who answered:
 *  the wire is real, and who is on the far side of it is open. It is named
 *  beside `attachedEndpoint` because the two are the pair a session is built
 *  from, and spelling one of them as a bare `{}` at a call site would leave
 *  the reader to work out that the empty object IS the loose end. */
export function unattributedEndpoint(
	designator?: string | undefined,
): SessionEndpoint {
	return sessionEndpoint({ designator });
}

/** The word for an end that claims nothing at all.
 *
 *  It is a word rather than a blank because every surface that lists ends has
 *  to say something in the row, and it lives here, beside the shape it
 *  describes, because those surfaces are the stage, the Sidebar, the Inspector
 *  and the builder's hints. The stage also RESERVES room for it before drawing
 *  it, so the phrase is arithmetic there and not only prose: a second spelling
 *  would have the solver keeping room for a label nobody draws. */
export const UNNAMED_END_LABEL = "unnamed end";

/** One end being attached to a peer: who it is, and what backed that.
 *
 * The two arrive together and they are one fact. An end attaches BECAUSE
 * something backed it, so a value that named only the peer would have dropped
 * half of what happened, which is exactly what a bare peer id in the endpoint
 * keyframe track did, leaving a mid-session attachment able to say who is
 * there and never able to say what put them there.
 *
 * `peer` is required and `attributedBy` optional, which is the same one-way
 * invariant `SessionEndpoint` carries: nothing can attribute an end to nobody,
 * and an author may attach one without measuring anything. Loose is the
 * ABSENCE of an attachment, never an attachment with no peer in it.
 *
 * This is what the endpoint keyframe tracks hold and what a
 * `session-endpoint-attributed` observation states. The end's `designator` is
 * not part of it, because the claim was on the end from the moment the session
 * opened and attaching does not restate it. */
export const EndpointAttachment = z.object({
	peer: z.string().min(1),
	attributedBy: EndpointAttribution.optional(),
});
export type EndpointAttachment = z.infer<typeof EndpointAttachment>;

/** The same attachment to a different peer, keeping what backed it.
 *
 *  Half of an attachment restated, and the half it does not touch is the
 *  point. A surface edits the pair one control at a time, so a peer change
 *  that dropped the attribution beside it would unsay a `verified-handoff`
 *  the author had just stated. The silent loss this pair exists to stop.
 *  In Build the author is the authority: they said what backed this end,
 *  and separately they said which peer it is, so neither statement takes
 *  the other back. It is how the end a session is BORN with has always
 *  behaved (`authoring/session.updateSessionEndpoint` patches field by
 *  field), and a moment is the same end at a later time. */
export function attachedTo(
	attachment: EndpointAttachment,
	peer: string,
): EndpointAttachment {
	return { ...attachment, peer };
}

/** The same attachment backed by something else, or by nothing.
 *
 *  The other half, and the one that can be cleared: an author may attach an
 *  end having measured nothing, which is the converse the one-way invariant
 *  allows. Undefined removes the field rather than storing it empty, so a
 *  cleared attribution reads as an attachment nothing backed. */
export function backedBy(
	attachment: EndpointAttachment,
	attribution: EndpointAttribution | undefined,
): EndpointAttachment {
	return {
		peer: attachment.peer,
		...(attribution !== undefined && { attributedBy: attribution }),
	};
}

/** The attachment an endpoint carries, or undefined when it is loose.
 *
 * The one door between the two shapes, so the genesis end and a keyframe are
 * read as the same kind of thing: `SessionEndpoint` is what an end IS at a
 * moment (claim included) and `EndpointAttachment` is the part of it that can
 * change while the session runs. */
export function endpointAttachment(
	endpoint: SessionEndpoint,
): EndpointAttachment | undefined {
	if (endpoint.peer === undefined) return undefined;
	return {
		peer: endpoint.peer,
		...(endpoint.attributedBy !== undefined &&
			{ attributedBy: endpoint.attributedBy }),
	};
}

/** The stage id of a session end that no peer is attached to.
 *
 * An unattributed end still occupies a place in the picture: the force layout
 * needs a position at both ends of every edge, and a reader needs something
 * to select in order to ask what this end claims. So it is drawn, and being
 * drawn it needs a name.
 *
 * The name is the session and the side, because that is what the thing IS,
 * one end of one session. Minting it from the end's own claimed designator
 * instead is what once produced a placeholder colliding with the very peer it
 * was a claim about, and a name a partner chooses is not a name this stage
 * may adopt. It dies with its session, because that is the only thing it
 * belongs to.
 *
 * It shares one namespace with peer ids: `endpointNodeId` below returns
 * either, and the layout, the world, and every selection key one node by
 * whichever it got. The spelling is what tells them apart, so a peer id
 * spelled like this one would BE this one, one node where the picture holds
 * two. Two doors mint a peer id and each closes that:
 * `authoring/identity.checkRekeyCollision` refuses an author's rename to a
 * spelling this parses, and `StageLedger` extends a live peer's stage id when
 * a producer hands it one, because a name the network chose is disambiguated
 * and never refused. `parseEndpointStageId` is the test both of them run. */
export function endpointStageId(
	sessionId: string,
	side: SessionSide,
): string {
	return `${sessionId}::${side}`;
}

/**
 * Which kind of stage node an id names.
 *
 * The two kinds share one id namespace, so the spelling is the only thing
 * that tells them apart, and asking `parseEndpointStageId` directly invites
 * the one mistake this exists to stop: it answers `undefined`, and a caller
 * that compares against `null` gets a constant. That went wrong three times
 * in one sitting. Every reader of a node id asks this question, so it is
 * asked here.
 */
export function nodeKindOf(id: string): "peer" | "endpoint" {
	return parseEndpointStageId(id) === undefined ? "peer" : "endpoint";
}

/** The session and side an endpoint stage id names, or undefined when the id
 *  is not one.
 *
 *  The inverse of `endpointStageId`, and it lives beside it so the spelling
 *  has one home: a selection or a drag hands back only an id, and the reader
 *  that has to find the session again must not re-derive the separator. A
 *  session id may itself contain the separator, so the split is from the
 *  right, and only the two side names close the match. */
export function parseEndpointStageId(
	id: string,
): { sessionId: string; side: SessionSide } | undefined {
	const at = id.lastIndexOf("::");
	if (at <= 0) return undefined;
	const side = id.slice(at + 2);
	if (side !== "a" && side !== "b") return undefined;
	return { sessionId: id.slice(0, at), side };
}

/** The node one end of a session sits at: the peer attached to it, or the
 *  end's own stage id when nothing has attributed it.
 *
 *  This is the answer for a caller holding the endpoint itself, an
 *  observation's `a` / `b`. A caller holding a document and a moment asks
 *  `sessionEndpointPlaceAt` instead, which resolves the endpoint tracks first
 *  and then lands here. The two are one rule reached from two inputs, never
 *  two rules. Either way an unattributed end is a node to every reader or to
 *  none, a force simulation with a position for one end and nothing for the
 *  other has no edge to solve. */
export function endpointNodeId(
	sessionId: string,
	side: SessionSide,
	endpoint: SessionEndpoint,
): string {
	return endpoint.peer ?? endpointStageId(sessionId, side);
}
