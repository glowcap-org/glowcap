/// <reference lib="dom" />
/**
 * Films ocapnviz in use for the site's explainer video: its production
 * bundle, opened in Live mode on a real trace endpoint and recording. The
 * scene is staged to read at video size: three peers in a triangle, so no two
 * lines cross, fitted to the stage. Two glowcap peers talk glowcap's own
 * Cap'n Proto profile, and a Goblins peer talks Syrup to each. The reel opens
 * with the peers standing as a publisher streams their messages into the
 * endpoint. Every message carries a real frame from the Syrup oracle corpus.
 * The pointer stops the recording, which becomes a Play document with a
 * timeline, plays it at half speed from where every peer has settled, pauses
 * with the Goblins peer's call a quarter of the way along its line, clear of
 * the line's label, and picks it, so the details pane reads its frame out.
 *
 * The trace endpoint is the Rooms trace host, started as a child process.
 * Writes the `ocapnviz` reel (see `reel.ts`). `zig build site-video` builds
 * the site's ocapnviz into `site/assets/ocapnviz`, then runs this after the
 * Rooms films and before the render.
 */
import { chromium } from "playwright";
import { filmArgs, glide, glideClick, placePointer, press, reelsDirArg, startReel } from "./reel.ts";
import { type OcvPage, openLiveRecording, peersBox, serveOcapnviz, stageBox } from "./ocapnviz-live.ts";
import { spawnOwned, stopOwned } from "../../apps/rooms/test/support/children.ts";

/** The endpoint the trace host announces on its first line of output. */
type Announcement = { sturdyref: string; publish: string; swiss: string };

/** The sessions between the peers. Each is reported by its first peer, which
 * names what it runs. Two glowcap peers speak glowcap's own profile over
 * Cap'n Proto, so the session says what both ends run. The Goblins peer's
 * sessions are OCapN 1.0 over Syrup, the interop floor. */
const SESSIONS = [
	{
		session: "s-alice-carol",
		a: "alice",
		b: "carol",
		a_profile: "glowcap",
		codec: "capnp",
		captp_version: "glowcap-next",
	},
	{ session: "s-bob-alice", a: "bob", b: "alice", a_profile: "goblins", codec: "syrup", captp_version: "1.0" },
	{ session: "s-bob-carol", a: "bob", b: "carol", a_profile: "goblins", codec: "syrup", captp_version: "1.0" },
];

/** The messages that fly while recording: the session each travels over,
 * which way (outbound is from the session's first peer to its second), and
 * the Syrup frame it carries, from the oracle corpus. All of them travel
 * Syrup sessions, so every frame is in the codec its session speaks. */
const MESSAGES = [
	{ session: "s-bob-alice", outbound: true, frame: "op_deliver_v1_0_with_resolve_me_desc" },
	{ session: "s-bob-carol", outbound: true, frame: "op_deliver" },
	{ session: "s-bob-carol", outbound: false, frame: "op_listen_promise_target" },
	{ session: "s-bob-alice", outbound: true, frame: "op_deliver_v1_0_with_resolve_me_desc" },
	{ session: "s-bob-carol", outbound: true, frame: "op_deliver_v1_0_with_resolve_me_desc" },
	{ session: "s-bob-alice", outbound: true, frame: "op_deliver_v1_0_with_resolve_me_desc" },
	{ session: "s-bob-carol", outbound: false, frame: "op_deliver" },
	{ session: "s-bob-alice", outbound: true, frame: "op_deliver_v1_0_with_resolve_me_desc" },
	{ session: "s-bob-carol", outbound: true, frame: "op_deliver" },
	{ session: "s-bob-alice", outbound: true, frame: "op_deliver_v1_0_with_resolve_me_desc" },
	{ session: "s-bob-carol", outbound: false, frame: "op_listen_promise_target" },
	{ session: "s-bob-alice", outbound: true, frame: "op_deliver_v1_0_with_resolve_me_desc" },
];

/** The session whose message the pointer picks: the Goblins peer calling a
 * glowcap peer. Every message on it goes that way and carries one frame, so
 * whichever is caught, the details pane reads the same call. */
const PICKED = "s-bob-alice";
/** The peers at the picked session's two ends. */
const PICKED_ENDS = ["bob", "alice"];

/** ocapnviz's side panes at their narrowest that still read the picked
 * frame, so the stage between them is as large as the window allows. The
 * timeline fits its rows. */
const PANES = { leftPaneWidth: 200, rightPaneWidth: 320 };

/** A corpus frame's bytes, and the operation it carries, read from its own
 * Syrup record label, so the label on the stage is the frame's. */
async function corpusFrame(name: string): Promise<{ bytes: Uint8Array; op: string }> {
	const bytes = await Deno.readFile(`test/oracle/corpus/${name}.bin`);
	const label = /^<\d+'(op:[a-z-]+)/.exec(new TextDecoder().decode(bytes));
	if (label == null) throw new Error(`the corpus frame ${name} is not an op record`);
	return { bytes, op: label[1] };
}

/** Read the trace host's one-line JSON announcement, with a bound on its size. */
async function readAnnouncement(stdout: ReadableStream<Uint8Array>): Promise<Announcement> {
	const reader = stdout.getReader();
	const decoder = new TextDecoder();
	let text = "";
	try {
		while (!text.includes("\n")) {
			const { value, done } = await reader.read();
			if (done) throw new Error("the trace host exited before announcing its endpoint");
			text += decoder.decode(value, { stream: true });
			if (text.length > 8192) throw new Error("the trace host announcement is too long");
		}
	} finally {
		reader.releaseLock();
	}
	const parsed: unknown = JSON.parse(text.slice(0, text.indexOf("\n")));
	if (
		typeof parsed !== "object" || parsed == null ||
		!("sturdyref" in parsed) || typeof parsed.sturdyref !== "string" ||
		!("publish" in parsed) || typeof parsed.publish !== "string" ||
		!("swiss" in parsed) || typeof parsed.swiss !== "string"
	) {
		throw new Error(`the trace host announced something unexpected: ${text}`);
	}
	return { sturdyref: parsed.sturdyref, publish: parsed.publish, swiss: parsed.swiss };
}

/** Open the producer route. The endpoint reads the capability's secret only
 * as the first message, and drops records from a publisher that skipped it. */
async function openPublisher(url: string, swiss: string): Promise<WebSocket> {
	const socket = new WebSocket(url);
	await new Promise<void>((resolve, reject) => {
		const timer = setTimeout(() => reject(new Error("the trace publisher did not open")), 15_000);
		socket.onopen = () => {
			clearTimeout(timer);
			socket.send(swiss);
			resolve();
		};
		socket.onerror = () => {
			clearTimeout(timer);
			reject(new Error("the trace publisher WebSocket failed"));
		};
	});
	return socket;
}

const sleep = (ms: number) => new Promise<void>((resolve) => setTimeout(resolve, ms));

/** A publisher that stamps each record with the time since it began. */
function stamper(socket: WebSocket): (record: Record<string, unknown>) => void {
	const began = performance.now();
	return (record) => {
		const now = Math.round((performance.now() - began) * 1e6);
		socket.send(JSON.stringify({ v: 1, sim_t_ns: now, ...record }));
	};
}
type Send = ReturnType<typeof stamper>;

/** Open every session in one burst. The stage lays out one arrangement for
 * them all, so the playback's first frame already stands settled, where
 * sessions apart would ease from one arrangement to the next. */
function openSessions(send: Send): void {
	for (const s of SESSIONS) send({ kind: "ocapn.session-opened", transport: "tcp", ...s });
}

/** Stream the messages, one every `MESSAGE_GAP_MS`. */
const MESSAGE_GAP_MS = 300;
async function streamMessages(send: Send): Promise<void> {
	for (const m of MESSAGES) {
		const frame = frames.get(m.frame);
		if (frame == null) throw new Error(`no corpus frame read for ${m.frame}`);
		send({
			kind: "ocapn.message-decoded",
			session: m.session,
			outbound: m.outbound,
			op: frame.op,
			len: frame.bytes.length,
			bytes_b64: btoa(Array.from(frame.bytes, (byte) => String.fromCharCode(byte)).join("")),
			// The endpoint wants a 32 digit hex tag for the frame.
			digest: crypto.randomUUID().replaceAll("-", ""),
		});
		await sleep(MESSAGE_GAP_MS);
	}
}

/** Where a message on the picked session is, in page pixels, while it is
 * between `least` and `most` of the way along its line. Runs in the page. */
const caught = ({ picked, least, most }: { picked: string; least: number; most: number }) => {
	const scope = globalThis as unknown as OcvPage;
	const { t } = scope.__ocv.engine.clock.snapshot();
	const flying = scope.__ocv.engine.orderedMessages().find(({ messageInFlight: m }) => {
		const along = (t - m.sentT) / Math.max(1, m.arrivalT - m.sentT);
		return m.sessionId.endsWith(picked) && along >= least && along <= most;
	});
	const canvas = document.querySelector("canvas#ocv-pixi");
	if (flying == null || canvas == null) return null;
	const at = scope.__ocvViewport.toScreen(flying.position.x, flying.position.y);
	const box = canvas.getBoundingClientRect();
	return { x: box.left + at.x, y: box.top + at.y };
};

const frames = new Map(
	await Promise.all(
		[...new Set(MESSAGES.map((m) => m.frame))].map(async (name) => [name, await corpusFrame(name)] as const),
	),
);
// Everything the film starts, stopped in reverse order when it ends. Each
// stop runs even when an earlier one throws.
await using started = new AsyncDisposableStack();
const dist = serveOcapnviz();
started.defer(() => dist.shutdown());
/** The window ocapnviz is filmed in: the video's 16:9 at the Rooms films'
 * size, so ocapnviz's type plays at the size Rooms' does, at a scale that
 * gives the reel the same pixels. */
const VIEWPORT = { width: 1280, height: 720 };
const SCALE = 1.875;
const browser = await chromium.launch({ args: filmArgs(SCALE) });
started.defer(() => browser.close());
const traceHost = spawnOwned(Deno.execPath(), {
	args: ["run", "-A", "apps/rooms/test/trace/browser_host.ts"],
	stdout: "piped",
	stderr: "inherit",
});
started.defer(() => stopOwned(traceHost));
let announceTimer: ReturnType<typeof setTimeout> | undefined;
const trace = await Promise.race([
	readAnnouncement(traceHost.stdout),
	new Promise<never>((_, reject) => {
		announceTimer = setTimeout(
			() => reject(new Error("the trace host did not announce within 30 seconds")),
			30_000,
		);
	}),
]).finally(() => clearTimeout(announceTimer));
const publisher = await openPublisher(trace.publish, trace.swiss);
started.defer(() => publisher.close());
const send = stamper(publisher);

const errors: string[] = [];
const page = await openLiveRecording(
	browser,
	dist,
	trace.sturdyref,
	VIEWPORT,
	SCALE,
	errors,
	PANES,
);
const fit = page.getByRole("button", { name: "Fit everything in view" });
const zoomOut = page.getByRole("button", { name: "Zoom out" });
// A fitted stage reaches its bottom corner, under the zoom controls, so a
// step out keeps every peer's name clear of them.
const fitClearOfControls = async () => {
	await fit.click();
	await page.waitForTimeout(400);
	await zoomOut.click();
	await page.waitForTimeout(400);
};
// The peers stand and the stage fits them before the reel opens, and the
// traffic flows on camera.
openSessions(send);
await page.waitForFunction(
	(count) => (globalThis as unknown as OcvPage).__ocv.engine.orderedPeers().length === count,
	SESSIONS.length,
	{ timeout: 15_000 },
);
await page.waitForTimeout(700);
await fitClearOfControls();
await placePointer(page, 420, 560);
const reel = await startReel(page, `${reelsDirArg()}/ocapnviz`);
await reel.mark("recording");
await streamMessages(send);

// The whole window is in view, the timeline with it, as Stop turns the
// recording into one.
const stop = page.getByRole("button", { name: "Stop recording" });
// The recording runs on long enough to read the line about it.
await reel.hold(1800);
await glideClick(page, stop);
// Play takes Stop's place, so the pointer only settles onto it.
const play = page.getByRole("button", { name: "Play", exact: true }).last();
// Stop turns the recording into a document that opens at its start, before
// the peers stand, and at the stage's own scale. Off camera, it goes to
// just before the first message, once every peer has settled into place,
// as a scrub on the timeline would, is fitted again, and plays at half
// speed, so the call is plain to see as it travels and the pause catches
// it every time. The video cuts from Stop to the fitted recording.
await reel.offCamera(async () => {
	await play.waitFor();
	const settled = await page.evaluate((count) => {
		const engine = (globalThis as unknown as OcvPage).__ocv.engine;
		const { duration } = engine.clock.snapshot();
		const at = (t: number) => {
			engine.seekTo(t);
			return engine.orderedPeers().map(({ position }) => ({ ...position }));
		};
		for (let t = 0; t + 50 <= duration; t += 10) {
			const now = at(t);
			if (now.length !== count) continue;
			const later = at(t + 50);
			if (!now.every((p, i) => Math.hypot(p.x - later[i].x, p.y - later[i].y) < 0.5)) continue;
			for (let first = t; first <= duration; first += 10) {
				engine.seekTo(first);
				if (engine.orderedMessages().length === 0) continue;
				const from = Math.max(t, first - 150);
				engine.seekTo(from);
				return from;
			}
			return null;
		}
		return null;
	}, SESSIONS.length);
	if (settled == null) throw new Error("the recording never holds a message with every peer settled in place");
	await page.waitForTimeout(300);
	await fitClearOfControls();
	// The field takes typing once clicked.
	await page.getByLabel("Playback speed").click();
	await page.keyboard.press("ControlOrMeta+A");
	await page.keyboard.type("0.5");
	await page.keyboard.press("Enter");
	await page.waitForFunction(() =>
		document.querySelector('[aria-label="Playback speed"]')?.getAttribute("aria-valuenow") === "0.5"
	);
});
const playBox = await play.boundingBox();
if (playBox == null) throw new Error("ocapnviz shows no Play button after Stop");
await glide(page, playBox.x + playBox.width / 2, playBox.y + playBox.height / 2, 200);
// The stopped recording holds a moment before Play, so Stop and Play read
// as two presses.
await reel.hold(500);

// Play until the Goblins peer's call is a quarter of the way along its
// line, then pause, so it is caught clear of both peers and of the label
// at the line's middle. It can land between seeing it and the pause, so
// play on and try again, a few times.
let message: { x: number; y: number } | null = null;
for (let attempt = 0; attempt < 5 && message == null; attempt++) {
	await press(page);
	await page.waitForFunction(caught, { picked: PICKED, least: 0.25, most: 1 }, { timeout: 15_000 });
	await press(page);
	await play.waitFor({ timeout: 5_000 });
	message = await page.evaluate(caught, { picked: PICKED, least: 0.22, most: 0.42 });
}
if (message == null) throw new Error(`no ${PICKED} message was in flight after pausing five times`);
// The camera turns to the call's two ends, on the stage between the panes,
// and settles before the pointer picks the message between them.
await reel.mark("pick", await peersBox(page, 80, PICKED_ENDS), await stageBox(page));
await reel.hold(1800);
await glideClick(page, message);
// The pointer steps off the message's label, and the picked message holds
// a moment before the camera turns to what it carries.
await reel.hold(200);
await glide(page, message.x - 40, message.y - 40, 300);
await reel.hold(600);
// The details pane is the right-hand rail, filled once a message is
// picked. The camera looks at its top, from the message's ends down to
// the frame it carries.
const lens = page.getByRole("radiogroup", { name: "Payload view mode" });
await lens.waitFor();
await page.waitForTimeout(300);
const pane = await page.locator("aside.ocv-pane").last().boundingBox();
const frameBox = await lens.boundingBox();
if (pane == null || frameBox == null) throw new Error("ocapnviz shows no payload for the picked message");
await reel.mark("details", {
	x: pane.x,
	y: pane.y,
	width: pane.width,
	height: frameBox.y + frameBox.height + 110 - pane.y,
});
// The pane holds while the camera settles on it and the frame is read.
await reel.hold(3400);
await reel.stop();
if (errors.length > 0) throw new Error(`ocapnviz failed while filming:\n${errors.join("\n")}`);
