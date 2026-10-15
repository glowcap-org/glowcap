/**
 * Live mode, wires a `LiveFeed` (capability-native trace consumer)
 * into a fresh `Engine` whose `TimelineDocument` is mutable. Each
 * incoming `TimelineEvent` is appended to the doc's primary recording
 * source (via `primaryObservations`) so the engine picks it up on the
 * next tick.
 *
 * The engine mounts when Record is pressed and connects then, so
 * t=0 IS the press. The producer's replay contributes the topology
 * alive at that moment as state (`replay`-marked messages stay
 * out), the stage builds from there while recording, and the whole
 * accumulated doc is the recording, `claimRecording` turns it into
 * the Play/Build source at Stop. Before the press, Live renders
 * nothing, no engine, no feed.
 *
 * **Limitations**:
 *
 * - `seekTo` past the current live cursor isn't possible. Events
 *   only arrive in real wall-clock time. Scrubbing back into
 *   already-received history works because past observations are
 *   retained in the recording.
 * - The engine's `duration` is set to a generous upper bound (1
 *   simulated hour by default). Long-running live sessions may hit
 *   it and require a re-mount.
 * - The live doc retains every observation for the session's life,
 *   and message payloads (up to the producer's cap, base64) ride
 *   the observations, payload capture accelerates that known
 *   growth. Clear (remount) is the relief valve. A producer that
 *   doesn't need the Payload pane can turn payloads off
 *   (`enableTrace`'s `payloadCap: 0`).
 * - No "live cursor at head" UI affordance yet, playback runs at
 *   wall-clock speed (`speed = 1`).
 *
 * These are documented limitations of the lightweight integration.
 * A future engine refactor (append-only TimelineDocument with a
 * true live cursor) would address them as a separate piece of
 * work.
 */

import { Engine } from "../engine.ts";
import type { EngineError } from "../errors.ts";
import { LiveFeed, type LivePeerFactory } from "./connection.ts";
import { primaryObservations } from "../temporal/recording-access.ts";
import type { TimelineDocument, TimelineEvent } from "../timeline.ts";

/** How far ahead of the clock an event may land: the worst-case
 * delay between an event arriving and rendering, and the window
 * within which producer spacing is preserved verbatim. Well above
 * live jitter, well below human patience. */
const FORWARD_SLACK_MS = 250;

/**
 * Build the feed-event handler that the live engine subscribes
 * to. Maps producer time onto the live clock through ONE latched
 * offset, so the producer's inter-event spacing, nanosecond
 * resolution at the source, survives onto the stage. Re-stamping
 * every event to "now" instead would quantize all arrivals to the
 * engine's tick boundary (~16.7 ms buckets at 60 fps) and erase
 * the spacing entirely: every event between two frames would land
 * on the same timestamp.
 *
 * The offset re-latches at two boundaries, so an event lands in
 * `[clock.t + 1, clock.t + FORWARD_SLACK_MS]`:
 *
 * - behind the clock (`t < clock.t` is the past): the first event,
 *   and a stalled feed resuming, re-latch to "now";
 * - more than the slack ahead: a backlog burst, a late connect's
 *   replay, a reconnect, carries producer times far older than
 *   their arrival, which one anchor would spread over the same stage-future
 *   they took on the wire. The forward clamp saturates
 *   the burst at now-plus-slack instead (order preserved), so a
 *   late viewer's topology materializes immediately.
 *
 * Between the boundaries the offset holds still, which is the
 * point: the live tail's inter-event spacing survives exactly.
 *
 * Exported so tests can exercise the stamping without opening a real peer.
 */
export function makeLiveAppender(opts: {
	liveDoc: TimelineDocument;
	clock: { t: number };
}): (ev: TimelineEvent) => void {
	let offset: number | null = null;
	return (ev) => {
		const minT = opts.clock.t + 1;
		const maxT = opts.clock.t + FORWARD_SLACK_MS;
		if (offset === null || ev.t + offset < minT) offset = minT - ev.t;
		else if (ev.t + offset > maxT) offset = maxT - ev.t;
		// Every time field shifts by the same offset, a message's
		// `arrivalT` left on the producer's base would give the flight
		// a nonsense (often negative) duration.
		const stamped: TimelineEvent = ev.kind === "message-sent"
			? { ...ev, t: ev.t + offset, arrivalT: ev.arrivalT + offset }
			: { ...ev, t: ev.t + offset };
		primaryObservations(opts.liveDoc).push(stamped);
	};
}

/** What dialing a feed takes, and what it hands back.
 *
 *  Both reports are optional and both are released by `dispose`, so a feed
 *  the caller no longer owns can never write into it. */
export type FeedDial = {
	/** The complete OCapN sturdyref announced by the trace endpoint. */
	sturdyref: string;
	/** Test seam for the browser peer. Production uses the wasm-backed peer. */
	peerFactory?: LivePeerFactory;
	/** Called after CapTP subscription completes, with `true`. On close, with `false`. */
	onConnectionChange?: (connected: boolean) => void;
	/** Called when the feed cannot dial or enliven the trace capability. Taken
	 *  here rather than subscribed by the caller because that
	 *  failure happens inside the dial, so a subscriber attached afterwards
	 *  would never hear it. */
	onError?: (error: EngineError) => void;
};

/**
 * Open the announced trace capability and report what it does, with nothing
 * capturing what arrives.
 *
 * This is what Live mode holds while nobody has pressed Record: the session
 * and its two reports, and no document. `startLiveMode` below is this plus
 * the capture, and it is built on this call rather than beside it, the two
 * differ in what they RETURN, never in how they dial, and a second spelling
 * of the dial is where they would start to.
 */
export function dialLiveFeed(opts: FeedDial): {
	feed: LiveFeed;
	dispose: () => void;
} {
	const feed = new LiveFeed(opts.sturdyref, opts.peerFactory);
	const unsubConnection = opts.onConnectionChange ? feed.onConnectionChange(opts.onConnectionChange) : () => {};
	const unsubError = opts.onError ? feed.onError(opts.onError) : () => {};
	feed.connect();
	return {
		feed,
		dispose: () => {
			unsubConnection();
			unsubError();
			feed.disconnect();
		},
	};
}

/**
 * Construct an empty live `TimelineDocument`, the capture, and an
 * engine that folds incoming `LiveFeed` events into it.
 *
 * The dial itself is `dialLiveFeed`. What this adds is the document and the
 * appender that folds arrivals into it. Returns a `dispose()` the caller
 * invokes to close the CapTP session and release subscribers.
 */
export function startLiveMode(
	opts: FeedDial & {
		/** Upper bound on simulated time, in milliseconds. Defaults to 1 hour. */
		durationMs?: number;
	},
): {
	engine: Engine;
	feed: LiveFeed;
	dispose: () => void;
} {
	const liveDoc: TimelineDocument = {
		id: "live",
		metadata: {
			"dct:title": "Live timeline-event feed",
			"dct:description": `Live event stream from ${opts.sturdyref}. New events append as they arrive.`,
		},
		duration: opts.durationMs ?? 60 * 60 * 1000, // 1h default
		recording: {
			sources: [{
				id: "live",
				meta: { kind: "glowcap-host" },
				observations: [],
			}],
		},
	};

	const engine = new Engine(liveDoc);
	// Auto-play so events render as they arrive without the user
	// having to hit play.
	engine.enqueue({ kind: "play" });

	// Subscribed before the dial, for the reason `FeedDial.onError` gives:
	// `connect()` can fail inside itself, so everything that must hear this
	// feed is attached first. The appender is registered after `dialLiveFeed`
	// returns because a failed dial delivers no events at all, the socket
	// either opens and the subscription runs, or it does not and nothing does.
	const dialed = dialLiveFeed(opts);
	dialed.feed.subscribe(makeLiveAppender({ liveDoc, clock: engine.clock }));

	return { engine, feed: dialed.feed, dispose: dialed.dispose };
}

/** Breathing room past the last observation, so a claimed
 *  recording's final flights land inside its duration. */
const CAPTURE_TAIL_MS = 1_000;

/**
 * Turn the recording engine's accumulated doc into a Play/Build
 * source: a fresh id (so the timeline fits the new document) and a
 * duration derived from the content instead of the live view's
 * one-hour ceiling. The whole doc IS the recording, the engine
 * connects at the Record press, so its t=0 is the press and the
 * producer's replay already materialized the topology alive then as
 * state. Null when nothing was captured.
 *
 * The claim owns its own observation list. A shallow spread of `liveDoc`
 * would hand the claimed document the very array the live appender is still
 * pushing into, so a feed that kept arriving after Stop would go on writing
 * into what the reader is now scrubbing. That the one caller happens to
 * unmount the capture in the same commit is a coupling nothing states, and
 * a second caller would inherit it silently. Severing here removes the
 * question instead of documenting it. The cost is one array copy per Stop,
 * which is a human act rather than a frame.
 *
 * The observations inside it are shared, not cloned, and that is enough
 * because of what the live side does: it only ever APPENDS, and each
 * appended observation is a fresh object (`makeLiveAppender` stamps a copy).
 * Nothing on the live path reaches back into an observation already
 * recorded. Authoring does mutate them in place, and that is why `App`
 * clones a source document before opening it for editing rather than
 * relying on this.
 */
export function claimRecording(
	liveDoc: TimelineDocument,
	id: string,
): TimelineDocument | null {
	const observations = primaryObservations(liveDoc);
	if (observations.length === 0) return null;
	let end = 0;
	for (const ev of observations) {
		const t = ev.kind === "message-sent" ? Math.max(ev.t, ev.arrivalT) : ev.t;
		if (t > end) end = t;
	}
	return {
		...liveDoc,
		id,
		metadata: { ...liveDoc.metadata, "dct:title": "Live recording" },
		duration: end + CAPTURE_TAIL_MS,
		recording: {
			...liveDoc.recording,
			sources: (liveDoc.recording?.sources ?? []).map((source) => ({
				...source,
				observations: [...source.observations],
			})),
		},
	};
}

/** The toast Stop uses when `claimRecording` returns null. */
export function emptyCaptureError(): EngineError {
	return {
		code: "validation",
		title: "Nothing to review",
		detail: "Nothing arrived during this capture, so there is no recording to review.",
		recovery: "Stay in Live and wait for activity, then Stop again.",
	};
}
