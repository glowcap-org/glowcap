/**
 * Playback, the engine's only runtime mutator besides authoring.
 *
 * Owns the playhead loop: drain intents, advance the clock, fold the
 * document into the world, and rebuild the frame's shared geometry so
 * layout and message flight read the same tables. The Engine remains
 * the public door (`tick`, `enqueue`, `seekTo`, `restart`). This module holds
 * the private loop state those methods share.
 *
 * Document edits, undo, and builder dispatch stay off this class,
 * they change what there is to play, not how a frame is produced.
 */

import { Clock } from "./clock.ts";
import { type EngineError, internalError } from "./errors.ts";
import { type EngineIntent } from "./intents.ts";
import {
	claimTargets,
	computeMessageTimeBundles,
	computeSessionBundles,
	drawnSessionCurve,
	EMPTY_FRAME_GEOMETRY,
	type FrameGeometry,
	type SessionCurve,
} from "./session-geometry.ts";
import { CLAIM_LEAN } from "./systems/claim-placement.ts";
import { KeyframeLayoutSystem } from "./systems/keyframe-layout-system.ts";
import { MessageFlightSystem } from "./systems/message-flight-system.ts";
import { materializeWorldAt } from "./systems/world-materializer.ts";
import { projectFromObservations } from "./temporal/project-from-observations.ts";
import { observationsOf } from "./temporal/recording-access.ts";
import type { TimelineDocument, TimelineEvent } from "./timeline.ts";
import type { GameWorld } from "./world.ts";

/**
 * What playback needs from the Engine: the live document and the
 * systems that draw a frame from it. Projection may replace the doc
 * object, `rebindDoc` keeps authoring in step when that happens.
 */
export type PlaybackHost = {
	getDoc(): TimelineDocument;
	setDoc(value: TimelineDocument): void;
	readonly clock: Clock;
	readonly world: GameWorld;
	readonly layout: KeyframeLayoutSystem;
	readonly messages: MessageFlightSystem;
	claims(): ReadonlyMap<string, string>;
	notify(docChanged?: boolean): void;
	emitError(err: EngineError): void;
	/** Keep authoring in step when projection returns a new doc.
	 *  Returns false when the context already held this object. */
	rebindDoc(doc: TimelineDocument): boolean;
};

export class Playback {
	#prevT = 0;
	// Last `t` for which layout / messages systems ran. Lets
	// `tick()` skip per-frame interpolation when nothing moved
	// (paused, no seek). NaN sentinel so the first tick always runs.
	#lastUpdateT = Number.NaN;
	/** Claim/bundle tables for the last stage update, Stage projects
	 *  from these so flight and edges do not rebuild the same maps. */
	#frameGeometry: FrameGeometry = EMPTY_FRAME_GEOMETRY;
	/** Time bundles are observation-shaped. Playback and mid-drag leave
	 *  observations alone, so the table stays. Seek and a document
	 *  change mark it dirty and the next stage pass rebuilds. */
	#timeBundlesDirty = true;
	/** Claim targets + session bundles are membership-shaped. A playing
	 *  frame that only lerps positions leaves them alone. Materialize
	 *  reports when the standing set changed. */
	#pairTablesDirty = true;
	#intents: EngineIntent[] = [];
	#scrubbing = false;
	#resumeAfterScrub = false;

	constructor(private readonly host: PlaybackHost) {}

	get frameGeometry(): FrameGeometry {
		return this.#frameGeometry;
	}

	/** Observation edits land through Engine `#notify`. The next stage
	 *  pass must not keep simultaneity slots from the previous document. */
	markDocumentChanged(): void {
		this.#timeBundlesDirty = true;
		this.#pairTablesDirty = true;
	}

	/** Enqueue a user intent. Drained in FIFO order at the next `tick()`. */
	enqueue(intent: EngineIntent): void {
		this.#intents.push(intent);
	}

	/** Advance by `wallDt` ms. The only runtime mutator. Returns simDt. */
	tick(wallDt: number): number {
		// Notify only when something observable changed, paused frames
		// would otherwise wake every `useEngineVersion` subscriber 60Hz
		// for nothing.
		let dirty = this.#intents.length > 0;
		// Every authoring intent edits the document, so a non-empty queue counts as
		// a document change without anyone reading the intents to find out. The
		// default runs this way round: over-reporting costs a re-render
		// nobody needed, while under-reporting leaves a panel showing a document
		// that is no longer there.
		let docChanged = this.#intents.length > 0;
		for (const intent of this.#intents) {
			try {
				this.#applyIntent(intent);
			} catch (caught) {
				// Keep draining. One bad intent shouldn't strand the rest of
				// the queue. The error surfaces via `onError`; the UI decides
				// whether to toast or modal based on the code.
				this.host.emitError(internalError(caught));
			}
		}
		this.#intents.length = 0;

		const simDt = this.host.clock.tick(wallDt);
		const tNow = this.host.clock.t;

		if (simDt > 0) {
			if (this.#drainEvents(this.#prevT, tNow)) {
				docChanged = true;
				this.#timeBundlesDirty = true;
				// Claims may have changed with the document even when the
				// standing set did not.
				this.#pairTablesDirty = true;
			}
			dirty = true;
		}
		// Skip layout / message updates when `t` hasn't advanced,
		// paused frames or repeated ticks at the same t would otherwise
		// reinterpolate every peer back to the same coords.
		if (tNow !== this.#lastUpdateT) {
			this.runStageSystems(tNow);
			this.#lastUpdateT = tNow;
			dirty = true;
		}
		this.#prevT = tNow;

		// The world moving is not the document changing. A playing clock advances
		// positions and flights on every frame, and a panel showing what the
		// document says has nothing to redraw for any of it.
		if (dirty) this.host.notify(docChanged);
		return simDt;
	}

	/** Materialize the world at t=0 and run the layout pass. Used
	 *  by construction and restart paths. */
	applyInstantaneousEvents(): void {
		materializeWorldAt(this.host.world, this.host.getDoc(), 0);
		this.runStageSystems(0);
		this.#lastUpdateT = 0;
	}

	/**
	 * Layout peers, rebuild the frame's shared geometry tables, then place
	 * in-flight messages from those same tables.
	 *
	 * Claim targets and session bundles are membership-shaped: memoized until
	 * materialize reports a topology change or the document dirties claims.
	 * Time bundles are observation-shaped: memoized across playback and
	 * mid-drag. Session curves depend on positions, so they are rebuilt every
	 * pass, once per session, and shared by flight and the Stage.
	 */
	runStageSystems(t: number): void {
		this.host.layout.update(this.host.world, t);
		let claimsToward = this.#frameGeometry.claimsToward;
		let sessionBundles = this.#frameGeometry.sessionBundles;
		if (this.#pairTablesDirty) {
			claimsToward = claimTargets(this.host.world, this.host.claims());
			sessionBundles = computeSessionBundles(
				this.host.world,
				claimsToward,
			);
			this.#pairTablesDirty = false;
		}
		let timeBundles = this.#frameGeometry.timeBundles;
		if (this.#timeBundlesDirty) {
			timeBundles = computeMessageTimeBundles(
				observationsOf(this.host.getDoc()) as readonly TimelineEvent[],
			);
			this.#timeBundlesDirty = false;
		}
		const sessionCurves = new Map<string, SessionCurve>();
		for (const e of this.host.world.with("session", "endpoints")) {
			const bundle = sessionBundles.get(e.session.id);
			if (!bundle) continue;
			const curve = drawnSessionCurve(
				this.host.world,
				e.endpoints.a,
				e.endpoints.b,
				bundle,
				claimsToward,
				CLAIM_LEAN,
			);
			if (curve) sessionCurves.set(e.session.id, curve);
		}
		this.#frameGeometry = {
			claimsToward,
			sessionBundles,
			timeBundles,
			sessionCurves,
		};
		this.host.messages.update(this.host.world, t, this.#frameGeometry);
	}

	/**
	 * Run the same layout + message systems `tick` would for this `t`, then
	 * mark the playhead current so the next paused tick does not redo them.
	 *
	 * Both systems must run: message dots sit on curves derived from peer
	 * positions, so a placement that only updated layout left in-flight
	 * messages on the pre-drag wire until time advanced.
	 */
	refreshStageAtPlayhead(): void {
		const t = this.host.clock.t;
		this.runStageSystems(t);
		this.#lastUpdateT = t;
	}

	/** Reset to t=0 without notifying. Engine.restart wraps this. */
	restart(): void {
		this.#resetWorld();
		this.host.clock.restart();
		this.applyInstantaneousEvents();
	}

	/**
	 * Rebuild the world at `targetT` without notifying. Engine.seekTo wraps
	 * this after flushing any deferred layout from an open transaction.
	 */
	seekTo(targetT: number): void {
		const clamped = Math.max(
			0,
			Math.min(this.host.getDoc().duration, targetT),
		);
		// Same document-changed gate as `#drainEvents`: live feeds append
		// observations in place, projection returns a fresh doc when it notices,
		// and only then are keyframes stale. Seek must not skip that recompute or
		// scrubbing after a paused live arrival leaves peers at seed positions.
		const docChanged = this.#reproject();
		this.#resetWorld();
		materializeWorldAt(this.host.world, this.host.getDoc(), clamped);
		if (docChanged) this.host.layout.recompute();
		// Scrub and authoring seek both land here. Observations may have been
		// rewritten in place since the last build (retiming a message does that
		// without a fresh doc object), so the time-bundle table is not trusted
		// across a seek. The standing set is rebuilt from empty, so pair tables
		// are not trusted either.
		this.#timeBundlesDirty = true;
		this.#pairTablesDirty = true;
		this.host.layout.invalidateSettled();
		this.runStageSystems(clamped);
		this.host.clock.seekTo(clamped);
		this.#prevT = clamped;
		this.#lastUpdateT = clamped;
	}

	#applyIntent(intent: EngineIntent): void {
		switch (intent.kind) {
			case "play":
				this.#playOrRestart();
				return;
			case "pause":
				this.host.clock.pause();
				return;
			case "toggle":
				if (this.host.clock.state === "playing") {
					this.host.clock.pause();
				} else this.#playOrRestart();
				return;
			case "restart":
				this.restart();
				return;
			case "setSpeed":
				this.host.clock.setSpeed(intent.speed);
				return;
			case "seekTo":
				this.seekTo(intent.t);
				return;
			case "beginScrub":
				if (this.#scrubbing) return;
				this.#scrubbing = true;
				this.#resumeAfterScrub = this.host.clock.state === "playing";
				this.host.clock.pause();
				return;
			case "endScrub":
				if (!this.#scrubbing) return;
				this.#scrubbing = false;
				if (this.#resumeAfterScrub) this.host.clock.play();
				this.#resumeAfterScrub = false;
				return;
		}
	}

	/** Fold the document forward to `toT`, and report whether the document
	 *  itself changed on the way, which in playback is never, and in live mode
	 *  is whenever an observation arrived. */
	#drainEvents(fromT: number, toT: number): boolean {
		// Reconciler-based replay: rather than walking events from
		// fromT..toT, project any new observations into the behavior
		// layer (so live-mode pushes to the recording get reflected in
		// entity.timing/keyframes), then materialize the world to
		// `toT`. One code path for build / live / playback.
		void fromT;
		// A recompute is warranted by the DOCUMENT changing, because that is the
		// whole of what the keyframes are derived from: `recompute` reads the doc
		// and the config and nothing else, and `KeyframeLayoutSystem.claims` says
		// so where it is declared. Projection is what knows. It returns a fresh
		// doc when it touched something and the original when it did not.
		//
		// Which topology the world holds AT `toT` is a different fact, and it was
		// the wrong one to ask. It shifts on any ordinary playback frame where a
		// peer or a session comes into view, with the document behind it
		// untouched, so a document whose sessions arrive steadily re-derived every
		// era's layout on frame after frame and threw the identical keyframes
		// away. That is one d3-force convergence per era per arrival, and it is
		// why playing a hand-built document cost far more than drawing it.
		const docChanged = this.#reproject();
		if (materializeWorldAt(this.host.world, this.host.getDoc(), toT)) {
			this.#pairTablesDirty = true;
			this.host.layout.invalidateSettled();
		}
		if (docChanged) this.host.layout.recompute();
		return docChanged;
	}

	/** Re-derive the behavior layer from the observations. Idempotent
	 *  on already-projected entities, and authored values outrank it,
	 *  so it is safe to run before anything reads the doc. Both paths
	 *  that rebuild the world call it: the playing tick, where live
	 *  observations arrive, and every seek, because an authoring
	 *  gesture that moved observations must not wait for the clock to
	 *  advance before the doc agrees with them.
	 *
	 *  Returns whether the document changed, which is the signal a caller needs
	 *  to decide whether anything derived from the document is now stale. A
	 *  quiet run over an unchanged observation set returns the same doc object
	 *  and so reports false. */
	#reproject(): boolean {
		const next = projectFromObservations(this.host.getDoc());
		this.host.setDoc(next);
		if (!this.host.rebindDoc(next)) return false;
		this.host.layout.rebind(next);
		return true;
	}

	/** Play, restarting first if at the end. Without the restart,
	 * the world is frozen in its end-state and transient events
	 * never re-fire. */
	#playOrRestart(): void {
		if (this.host.clock.isAtEnd) this.restart();
		this.host.clock.play();
	}

	#resetWorld(): void {
		for (const e of [...this.host.world]) this.host.world.remove(e);
		this.#prevT = 0;
		// Force the next tick's layout / messages update to run, the
		// entity world is empty so the cached "already updated for
		// this t" promise no longer holds.
		this.#lastUpdateT = Number.NaN;
		// Fresh entities do not carry the targets a settled early-out assumes.
		this.host.layout.invalidateSettled();
	}
}
