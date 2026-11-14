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
 * - The live doc retains every observation of a capture, up to
 *   `MAX_CAPTURE_CHARS`, and message payloads (up to the producer's
 *   cap, base64) ride the observations. A capture that reaches the
 *   ceiling ends as Stop ends one. A producer that doesn't need the
 *   Payload pane can turn payloads off (`enableTrace`'s
 *   `payloadCap: 0`) and record for longer.
 * - Playback runs at wall-clock speed (`speed = 1`) without a live-head control.
 */

import { Engine } from "../engine.ts";
import type { LiveConnectionState } from "./status.ts";
import type { EngineError } from "../errors.ts";
import { LiveFeed, type LivePeerFactory } from "./connection.ts";
import { primaryObservations, savedObservationChars } from "../temporal/recording-access.ts";
import type { TimelineDocument, TimelineEvent } from "../timeline.ts";

/** How far ahead of the clock an event may land: the worst-case
 * delay between an event arriving and rendering, and the window
 * within which producer spacing is preserved verbatim. Well above
 * live jitter, well below human patience. */
const FORWARD_SLACK_MS = 250;

/** How much trace one capture holds, counted as the characters its
 * observations take in the saved file (`savedObservationChars`). The file
 * also holds what the engine derives from them, which comes to more than the
 * observations again for a message with no payload. A save builds the file
 * as one string and an open reads it as one, and the shortest string limit
 * among browsers is about four times this. */
export const MAX_CAPTURE_CHARS = 128 * 1024 * 1024;

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
 * The capture holds `ceilingChars` of observations. The arrival that would
 * pass that is not kept, `onFull` runs once, and nothing after it is kept
 * either, so a full capture is a recording that ends at a known event.
 * Measuring an arrival serializes it once, as a save would.
 *
 * Exported so tests can exercise the stamping without opening a real peer.
 */
export function makeLiveAppender(opts: {
	liveDoc: TimelineDocument;
	clock: { t: number };
	ceilingChars: number;
	onFull: () => void;
}): (ev: TimelineEvent) => void {
	let offset: number | null = null;
	let held = 0;
	let full = false;
	return (ev) => {
		if (full) return;
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
		const cost = savedObservationChars(stamped);
		if (cost > opts.ceilingChars - held) {
			full = true;
			opts.onFull();
			return;
		}
		held += cost;
		primaryObservations(opts.liveDoc).push(stamped);
	};
}

/** What dialing a feed takes, and what it hands back.
 *
 * Connection reports stop at `dispose`. The error callback is the application
 * sink and remains attached while pending setup and retirement finish, so their
 * failures outlive the view that initiated them. */
type FeedDial = {
	/** The complete OCapN sturdyref announced by the trace endpoint. */
	sturdyref: string;
	/** Test seam for the browser peer. Production uses the wasm-backed peer. */
	peerFactory?: LivePeerFactory;
	/** Setup/reconnect progress, an open subscription, a link this page cannot
	 * dial, or a terminal failure requiring reload. */
	onConnectionChange?: (state: LiveConnectionState) => void;
	/** Called when the feed cannot dial or enliven the trace capability. Taken
	 *  here rather than subscribed by the caller because that
	 *  failure happens inside the dial, so a subscriber attached afterwards
	 *  would never hear it. This application sink also receives cleanup failures
	 *  after disposal; it must not write into a disposed view. */
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
	if (opts.onError) feed.onError(opts.onError);
	feed.connect();
	return {
		feed,
		dispose: () => {
			unsubConnection();
			feed.disconnect();
		},
	};
}

/** What the live document says about itself. The dialed link carries the
 *  secret that grants access to the trace, and a claimed recording is saved
 *  with this text, so it names no address. */
const LIVE_DESCRIPTION = "Live event stream. New events append as they arrive.";

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
		/** How much trace the capture holds. Defaults to `MAX_CAPTURE_CHARS`. */
		ceilingChars?: number;
		/** Called once when the capture is full. Nothing arriving after it is
		 *  kept, so the caller ends the capture. */
		onFull: () => void;
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
			"dct:description": LIVE_DESCRIPTION,
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
	dialed.feed.subscribe(makeLiveAppender({
		liveDoc,
		clock: engine.clock,
		ceilingChars: opts.ceilingChars ?? MAX_CAPTURE_CHARS,
		onFull: opts.onFull,
	}));

	return { engine, feed: dialed.feed, dispose: dialed.dispose };
}

/** How a capture ended: its user pressed Stop, or it reached
 *  `MAX_CAPTURE_CHARS`. */
export type CaptureEnd = "stopped" | "full";

/** What a claimed recording says about itself, in the document panel and in
 *  a saved file. The toast that reports a full capture is gone in seconds,
 *  and this stays with the recording for a reader who was away. Like
 *  `LIVE_DESCRIPTION`, neither names an address. */
const RECORDING_DESCRIPTION: Record<CaptureEnd, string> = {
	stopped: "Recorded from a live feed.",
	full: "Recorded from a live feed until the recording was full.",
};

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
	ended: CaptureEnd,
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
		metadata: {
			...liveDoc.metadata,
			"dct:title": "Live recording",
			"dct:description": RECORDING_DESCRIPTION[ended],
		},
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

/** The toast the App raises when a capture reaches `MAX_CAPTURE_CHARS` and ends. */
export function captureFullError(): EngineError {
	return {
		code: "validation",
		title: "Recording stopped",
		detail: `A recording holds about ${MAX_CAPTURE_CHARS / (1024 * 1024)} MiB of events, and this one is full.`,
		recovery: "Review it in Play. Record again in Live to capture more.",
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
