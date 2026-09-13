import { z } from "zod";
import { CaptpVersion, Codec, PeerProfile, SessionState, Transport } from "../schema/topology.ts";
import { EndpointAttachment, SessionEndpoint } from "../schema/session-end.ts";
import { DescriptiveMetadata, Provenance } from "../schema/provenance.ts";
import { TimeSpanSchema } from "./temporal/zod.ts";
import { Observation, Position, Recording } from "./temporal/recording.ts";
import { Keyframe } from "./temporal/keyframes.ts";

/** Re-exported so an authoring caller reads one module. The schema
 *  itself lives with the observation that carries it. */
export { Position };

/**
 * Timeline layer — events at simulated-clock timestamps are the
 * primitive; the ECS world is the derived form (replay). Time is in
 * **simulated milliseconds** since the document's t=0; the
 * wall-clock relationship is owned by `Clock`.
 */

/**
 * A document's events and a recording's observations are one shape,
 * defined once in `temporal/recording.ts` and named here for the
 * authoring side of the same wire. The projection moves values
 * between the two names without converting, because there is nothing
 * to convert: a field added to the observation is an authorable field
 * the same afternoon, and no second declaration can fall behind.
 */
export const TimelineEvent = Observation;
export type TimelineEvent = Observation;

/**
 * Layout policy for the renderer.
 *
 *   per-topology  (default) force-directed layout per topology
 *                 change; peers lerp between keyframes.
 *   static-union  one layout over every peer + session that ever
 *                 exists; peers stay put for the whole scenario.
 *   authored      honor `peer-joined.position` verbatim; no force
 *                 simulation.
 *
 * In the two force modes an authored `position` pins its peer at
 * exactly that point in every keyframe.
 *
 * Mirrors `LayoutMode` in `layout-eras.ts`.
 */
export const LayoutMode = z.enum(["per-topology", "static-union", "authored"]);
export type LayoutMode = z.infer<typeof LayoutMode>;

/**
 * Per-category entity definitions — the IDENTITY half of the
 * entity-vs-event split. Lives independently of `events`:
 *
 *   - Observations carry TEMPORAL facts (peer arrived at t=12,
 *     session closed at t=45, message in flight from t=20 to
 *     t=22). A creation observation is self-describing capture
 *     evidence, so it carries the genesis facts observed at that
 *     moment. Build-mode authors write definitions directly.
 *
 *   - The `entities` map carries the STATIC identity (peer's
 *     profile / label, session's endpoints, message's payload).
 *     An entity present here WITHOUT a matching creation event
 *     in `events` is "eternal-start" — it exists before any
 *     captured activity, mirroring the existing "no end event"
 *     = eternal-end semantic for peers and sessions.
 *
 * The parser projects captured genesis facts into missing definitions;
 * runtime reads then have one path through `entities[cat][id]`.
 */
const PeerDefinition = z.object({
	profile: PeerProfile,
	/** The name the peer joined under. A `peer-updated` observation
	 *  renames it from that moment on without touching this field —
	 *  read the name at a given t through `peerLabelAt`. */
	label: z.string().optional(),
	/** The durable name this peer answers to, as against the name it
	 *  is shown by. A live feed records the designator it filed the
	 *  peer under; an author types one in build mode. It is what a
	 *  session end's claim matches, so a peer with none can never be
	 *  what a claim names. It does not change while the peer lives — a
	 *  peer that turns out to be someone else is that other peer, not a
	 *  rename — so unlike `label` it is not a keyframe track. */
	designator: z.string().optional(),
	/** Authored render-space position. Under `layoutMode: "authored"` it
	 *  IS the peer's position; under the force modes it pins the peer
	 *  there while its neighbors settle around it. */
	position: Position.optional(),
	/** Per-property keyframe tracks: `label`, the name the peer
	 *  answers to, which a live feed restates after the join (a chat
	 *  nick), and `profile`, the implementation it is known by. Read
	 *  through `peerLabelAt(doc, id, t)` and `peerProfileAt`; before
	 *  the first keyframe the peer carries what it joined with, the
	 *  same way a session falls back to `initialState`. */
	keyframes: z.object({
		label: z.array(Keyframe(z.string())).optional(),
		profile: z.array(Keyframe(PeerProfile)).optional(),
	}).optional(),
	/** Stored timing — start + duration, each side explicit/implicit.
	 *  Optional because a captured entity obtains its span from observations;
	 *  the engine projects from observations on load
	 *  so every entity has `timing` populated by the time any reader
	 *  consults it. See `docs/temporal-model.md` and
	 *  `docs/data-model.md`. */
	timing: TimeSpanSchema.optional(),
});
export type PeerDefinition = z.infer<typeof PeerDefinition>;

const SessionDefinition = z.object({
	a: SessionEndpoint,
	b: SessionEndpoint,
	/** The netlayer this session's bytes ride. Optional, and absent means
	 *  nothing stated it rather than a netlayer everyone agreed on: a live
	 *  producer that reported no transport is a real recording, and so is a
	 *  session an author has not said this about yet. One session runs over
	 *  one netlayer, so it sits on the session and not on either end. */
	transport: Transport.optional(),
	codec: Codec,
	captpVersion: CaptpVersion,
	initialState: SessionState.optional(),
	/** Where an unattributed end sits, when an author has placed it, by side.
	 *
	 *  An end nothing has attributed is drawn at a node of its own, so it pins
	 *  the force layout exactly as a peer's `position` does. It lives here
	 *  rather than beside the endpoint because the pin is a fact about the
	 *  picture and the endpoint is a fact about the wire, and because the
	 *  session is the only thing that outlives the end. An attached end takes
	 *  its position from the peer it attached to, so its entry means nothing
	 *  until the end comes loose again. */
	endpointPosition: z.object({
		a: Position.optional(),
		b: Position.optional(),
	}).optional(),
	/** See PeerDefinition.timing. */
	timing: TimeSpanSchema.optional(),
	/** Per-property keyframe tracks. `state` is the session's
	 *  lifecycle within its span; `a` and `b` are which peer is on each
	 *  end AND what backed the end attaching to it, which changes at the
	 *  moment something attributes an end that was loose. Each reads
	 *  through `keyframeAt(track, t)` and falls back to the genesis value
	 *  beside it — `initialState` (or "negotiating") for the state, and
	 *  the `a` / `b` above for the endpoints, read as attachments through
	 *  `endpointAttachment`. Read where an end sits and what put it there
	 *  through `sessionEndpointAt` / `sessionEndpointPlaceAt`. See
	 *  `docs/data-model.md`. */
	keyframes: z.object({
		state: z.array(Keyframe(SessionState)).optional(),
		a: z.array(Keyframe(EndpointAttachment)).optional(),
		b: z.array(Keyframe(EndpointAttachment)).optional(),
	}).optional(),
});
export type SessionDefinition = z.infer<typeof SessionDefinition>;

const MessageDefinition = z.object({
	sessionId: z.string().min(1),
	from: z.string().min(1),
	to: z.string().min(1),
	label: z.string().optional(),
	// The wire payload deliberately does NOT live here: the entities
	// map carries static identity, and a frame is the observation
	// itself. The `message-sent` observation's `bytesB64` is its one
	// home; the Inspector reads it there.
	/** See PeerDefinition.timing. Messages REQUIRE duration to be
	 *  explicit per the temporal model; flight time IS
	 *  `timing.duration`. */
	timing: TimeSpanSchema.optional(),
});
export type MessageDefinition = z.infer<typeof MessageDefinition>;

const Entities = z.object({
	peers: z.record(z.string(), PeerDefinition).optional(),
	sessions: z.record(z.string(), SessionDefinition).optional(),
	messages: z.record(z.string(), MessageDefinition).optional(),
}).optional();
export type Entities = z.infer<typeof Entities>;

/** Per-category row-management overrides for the Flash-grade
 * timeline. Identical structurally; kept as two distinct named
 * shapes (vs. one shared `PerCategoryEntityIds`) because the
 * meanings differ and call-sites read more clearly. */
const RowOrder = z.object({
	peers: z.array(z.string()).optional(),
	sessions: z.array(z.string()).optional(),
	messages: z.array(z.string()).optional(),
}).optional();

const RowHidden = z.object({
	peers: z.array(z.string()).optional(),
	sessions: z.array(z.string()).optional(),
	messages: z.array(z.string()).optional(),
}).optional();

const RowLabelHidden = z.object({
	peers: z.array(z.string()).optional(),
	sessions: z.array(z.string()).optional(),
	messages: z.array(z.string()).optional(),
}).optional();

const RowBodyHidden = z.object({
	peers: z.array(z.string()).optional(),
	sessions: z.array(z.string()).optional(),
	messages: z.array(z.string()).optional(),
}).optional();

/** Four-way visibility mode used at every level of the
 *  visibility cascade (all → category → entity). `visible` is
 *  the default / pass-through; the three "hidden" modes each
 *  drop a specific aspect of the entity. */
const VisMode = z.enum(["visible", "label", "body", "both"]);
export type VisMode = z.infer<typeof VisMode>;

/** Master "all rows" visibility flag. Stored independently of
 *  per-category / per-entity flags; the render layer composes
 *  them: the FIRST non-`visible` flag in the chain
 *  `all → category → entity` wins. This means setting `all` to
 *  `label` hides labels everywhere regardless of what
 *  individual categories or entities are set to; cycling it
 *  back to `visible` reveals whatever the categories / entities
 *  were independently configured for. Absent ⇒ `visible`. */
const AllVisModeField = VisMode.optional();

/** Per-category visibility flag. Same independence as
 *  `allVisMode` — setting `peers` to `body` hides every peer's
 *  body regardless of per-entity flags, and cycling back to
 *  `visible` doesn't lose those per-entity settings. */
const CategoryVisMode = z.object({
	peers: VisMode.optional(),
	sessions: VisMode.optional(),
	messages: VisMode.optional(),
}).optional();

/** The camera position a document opens at. Finite numbers only; the range a
 *  scale may take is `render/stage-view.ts`'s to say, and it clamps on read
 *  rather than refusing the parse, so a document written under different bounds
 *  still opens. */
const StageViewField = z.object({
	zoom: z.number().positive().finite(),
	center: z.object({
		x: z.number().finite(),
		y: z.number().finite(),
	}),
});

/** Top-level document. `events` must be sorted by `t` and have
 * unique `id`s; both are enforced at parse time. */
export const TimelineDocument = z
	.object({
		"@context": z.unknown().optional(),
		id: z.string().min(1),
		/** What the document says about itself: its title, description, creator, and
		 *  when it was created and last saved. One block, because a title spelled
		 *  both here and at the top level meant two places to read and one of them
		 *  was always stale. `schema/provenance.ts` owns the terms. */
		metadata: DescriptiveMetadata.optional(),
		provenance: Provenance.optional(),
		duration: z.number().nonnegative().finite(),
		layoutMode: LayoutMode.optional(),
		/** Where the stage camera opens on this document: a scale, and the world
		 *  point held at the center of the viewport. Absent means the default,
		 *  which is the middle of the world at 1:1.
		 *
		 *  Panning and zooming do NOT write here. A camera position is not a
		 *  statement the document makes, so looking around is not an edit and does
		 *  not enter undo. This field is written by the one act that does make the
		 *  statement, saving the current view as the document's opening view, and
		 *  that act is an edit like any other. `render/stage-view.ts` owns the
		 *  bounds and clamps whatever is stored, because a document is an input. */
		initialView: StageViewField.optional(),
		/** PARSER INPUT ONLY — fixture-friendly top-level observation
		 *  array. The `.transform` below projects it into
		 *  `recording.sources[0]` and strips the field from the runtime
		 *  shape. Readers must use `observationsOf(doc)` /
		 *  `primaryObservations(doc)`. */
		events: z.array(TimelineEvent).optional().default([]),
		/** Recording layer — append-only observation streams grouped
		 *  by named emitter source. The runtime source-of-truth for
		 *  observations after parse. See `docs/data-model.md` and
		 *  `temporal/recording.ts`. */
		recording: Recording.optional(),
		/** Per-category row order overrides for the Flash-grade
		 * timeline. Listed entity ids render first in the listed
		 * order; unlisted entities fall after by first-event-t.
		 * Absent ⇒ pure first-event-t ordering. Additive. */
		rowOrder: RowOrder,
		/** Per-entity stage-visibility, three-way: ids in `rowHidden`
		 * are hidden on stage in BOTH body and label; ids in
		 * `rowLabelHidden` keep the body but drop the label; ids in
		 * `rowBodyHidden` keep the label but drop the body. An id is
		 * in at most ONE of these three arrays at any time (the
		 * engine enforces; on parse, the more aggressive state
		 * wins when an id appears in multiple). Absent from all
		 * three ⇒ fully visible. Parallels `StageVisibility` at
		 * category granularity — same Adobe / Macromedia layer-
		 * visibility idiom, scoped per entity with a "label vs body"
		 * dimension since stage entities have both. */
		rowHidden: RowHidden,
		rowLabelHidden: RowLabelHidden,
		rowBodyHidden: RowBodyHidden,
		/** Master "all rows" visibility flag — independent of
		 *  category / entity flags; render-time cascade lets it
		 *  override on the way down. See `AllVisModeField`. */
		allVisMode: AllVisModeField,
		/** Per-category visibility flags — independent of per-
		 *  entity flags. See `CategoryVisMode`. */
		categoryVisMode: CategoryVisMode,
		/** Identity-side of the entity model — see `Entities`.
		 *  Lets an id exist without a creation event (eternal-
		 *  start), mirroring the existing eternal-end semantic. */
		entities: Entities,
	})
	.superRefine((doc, ctx) => {
		let last = -Infinity;
		for (const [i, ev] of doc.events.entries()) {
			if (ev.t < last) {
				ctx.addIssue({
					code: "custom",
					message: `Events must be sorted by t (event ${i} at t=${ev.t} after t=${last})`,
					path: ["events", i, "t"],
				});
			}
			if (ev.t > doc.duration) {
				ctx.addIssue({
					code: "custom",
					message: `Event ${i} at t=${ev.t} exceeds document duration ${doc.duration}`,
					path: ["events", i, "t"],
				});
			}
			last = ev.t;
		}
		const ids = new Set<string>();
		for (const [i, ev] of doc.events.entries()) {
			if (ids.has(ev.id)) {
				ctx.addIssue({
					code: "custom",
					message: `Duplicate event id "${ev.id}"`,
					path: ["events", i, "id"],
				});
			}
			ids.add(ev.id);
		}
	})
	// Normalize the identity model on parse. Walk events and
	// populate `entities.{peers, sessions, messages}` from the
	// creation-event payloads when not already present. This makes
	// `doc.entities` the single source of truth for identity reads
	// post-parse, while leaving the wire format (event payloads
	// still carry identity) unchanged for external consumers and
	// the live-feed protocol. Pre-existing `entities` entries win
	// over event-payload values — explicit definition trumps
	// implicit identity derived from observations.
	.transform(({ events, ...rest }) => {
		// 1) Derive entities from event payloads (existing identity
		//    normalization — `doc.entities` is the post-parse source
		//    of truth for identity reads). Pre-existing entries win.
		const peers: Record<string, PeerDefinition> = {
			...(rest.entities?.peers ?? {}),
		};
		const sessions: Record<string, SessionDefinition> = {
			...(rest.entities?.sessions ?? {}),
		};
		const messages: Record<string, MessageDefinition> = {
			...(rest.entities?.messages ?? {}),
		};
		for (const ev of events) {
			if (ev.kind === "peer-joined" && !peers[ev.peerId]) {
				peers[ev.peerId] = {
					profile: ev.profile,
					...(ev.label !== undefined ? { label: ev.label } : {}),
					...(ev.designator !== undefined ? { designator: ev.designator } : {}),
					...(ev.position !== undefined ? { position: ev.position } : {}),
				};
			} else if (
				ev.kind === "session-opened" && !sessions[ev.sessionId]
			) {
				sessions[ev.sessionId] = {
					a: ev.a,
					b: ev.b,
					codec: ev.codec,
					captpVersion: ev.captpVersion,
					...(ev.transport !== undefined ? { transport: ev.transport } : {}),
					...(ev.initialState !== undefined ? { initialState: ev.initialState } : {}),
				};
			} else if (ev.kind === "message-sent" && !messages[ev.messageId]) {
				messages[ev.messageId] = {
					sessionId: ev.sessionId,
					from: ev.from,
					to: ev.to,
					...(ev.label !== undefined ? { label: ev.label } : {}),
				};
			}
		}
		const hasAny = Object.keys(peers).length > 0 ||
			Object.keys(sessions).length > 0 ||
			Object.keys(messages).length > 0;
		const entities = hasAny
			? {
				...(Object.keys(peers).length > 0 ? { peers } : {}),
				...(Object.keys(sessions).length > 0 ? { sessions } : {}),
				...(Object.keys(messages).length > 0 ? { messages } : {}),
			}
			: rest.entities;

		// 2) Project the flat input `events` into `recording.sources[0]`
		//    when recording isn't already present. After this transform
		//    the runtime doc has no `events` field — observations live
		//    only in the recording layer.
		const recording = rest.recording ? rest.recording : events.length > 0
			? {
				sources: [{
					id: "input",
					meta: { kind: "input" as const },
					observations: events,
				}],
			}
			: undefined;

		return {
			...rest,
			...(entities !== undefined ? { entities } : {}),
			...(recording !== undefined ? { recording } : {}),
		};
	});
export type TimelineDocument = z.infer<typeof TimelineDocument>;

/**
 * What to call a document on screen: what it says its title is, or its id when it
 * says nothing.
 *
 * A reader that spells `doc.metadata?.["dct:title"]` itself is a reader that has
 * to remember the fallback, and the ones that forgot it showed an empty heading
 * for a document with no title. Two of these exist rather than one accessor per
 * field because the fallback only makes sense for the title: a document with no
 * description has nothing to say, and saying its id instead would be wrong.
 */
export function docTitle(doc: TimelineDocument): string {
	return doc.metadata?.["dct:title"] ?? doc.id;
}
