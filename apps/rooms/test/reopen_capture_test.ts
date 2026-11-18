// The reopen failure capture: bounded storage, the fields it keeps, the order
// of its markers, what it counts when it fails, and that observing a page
// changes nothing the page sees.
//
// Unit layer. The authority is the capture's own contract, written in
// `support/reopen_capture.ts`. A failure here points at the helper, never at
// Rooms. These tests do not establish what a real Chromium delivers to the
// page observer.

import { type CapturePage, clipError, ReopenCapture, Ring } from "./support/reopen_capture.ts";
import {
	installPageCapture,
	PAGE_CAPTURE_BINDING,
	PAGE_CAPTURE_KEY,
	type PageScope,
	type PageSnapshot,
} from "./support/reopen_capture_page.ts";
import { assert, assertEquals } from "./assert.ts";

/** A page global with classes of its own, so no test patches another's. */
function fixture() {
	const sendError = new DOMException("closed", "InvalidStateError");
	class Channel extends EventTarget {
		readyState = "open";
		id: number | null = 4;
		sent: unknown[] = [];
		thisSeen: unknown = null;
		send(data: unknown): string {
			this.thisSeen = this;
			if (data === "boom") throw sendError;
			this.sent.push(data);
			return "native-return";
		}
	}
	class Peer extends EventTarget {
		args: unknown[] = [];
		createDataChannel(...args: unknown[]): Channel {
			this.args = args;
			return new Channel();
		}
	}
	const scope: PageScope = {
		RTCPeerConnection: Peer,
		RTCDataChannel: Channel,
		performance: { now: () => 5, timeOrigin: 1000 },
		location: { origin: "http://x" },
		ArrayBuffer,
		Uint8Array,
		DataView,
		Blob,
		Math,
		Reflect,
		Proxy,
		Object,
	};
	return { scope, Peer, Channel, sendError };
}

type Fixture = ReturnType<typeof fixture>;

function install(fx: Fixture, capacity = 100): void {
	installPageCapture(fx.scope, PAGE_CAPTURE_KEY, PAGE_CAPTURE_BINDING, capacity);
}

function peerOf(fx: Fixture): InstanceType<Fixture["Peer"]> {
	const peer = new fx.scope.RTCPeerConnection();
	assert(peer instanceof fx.Peer, "a wrapped constructor still builds a Peer");
	return peer;
}

function channelOf(fx: Fixture, peer: InstanceType<Fixture["Peer"]>): InstanceType<Fixture["Channel"]> {
	const channel = peer.createDataChannel("ocapn", { ordered: true });
	assert(channel instanceof fx.Channel, "the native channel is returned");
	return channel;
}

function snapshotOf(fx: Fixture): PageSnapshot {
	const state = Reflect.get(fx.scope, PAGE_CAPTURE_KEY);
	return state.snapshot();
}

function messageEvent(channel: EventTarget, data: unknown): void {
	channel.dispatchEvent(Object.assign(new Event("message"), { data }));
}

const tick = () => new Promise((resolve) => setTimeout(resolve, 0));

Deno.test("a ring keeps the most recent items and counts what it evicted", () => {
	const ring = new Ring<number>(3);
	for (let i = 1; i <= 5; i++) ring.push(i);
	assertEquals(ring.items(), [3, 4, 5]);
	assertEquals([ring.seen, ring.retained, ring.evicted], [5, 3, 2]);
});

Deno.test("an error is a name and its first line", () => {
	assertEquals(clipError(new TypeError("first\nsecond")), "TypeError: first");
	assertEquals(clipError("plain").startsWith("error: plain"), true);
});

Deno.test("a viewer arrival keeps the allowlisted fields and nothing else", async () => {
	const capture = new ReopenCapture();
	capture.viewer({
		kind: "ocapn.message-decoded",
		session: "p0/s1",
		session_id: "abc",
		transport: "webrtc",
		outbound: true,
		sim_t_ns: 7,
		seq: 9,
		epoch: 11,
		replay: false,
		scope: "p0",
		body: "secret",
		a: "sturdyref",
		meta: { label: "x" },
		a_label: "alice".repeat(100),
	});
	capture.viewer({ kind: "trace.producer-left", scope: "p3", sim_t_ns: 0 });
	const report = await capture.snapshot("e", "t");
	const [first, second] = report.viewer.arrivals;
	assertEquals(Object.keys(first).sort(), [
		"a_label",
		"epoch",
		"i",
		"kind",
		"outbound",
		"replay",
		"seq",
		"session",
		"session_id",
		"sim_t_ns",
		"t",
		"transport",
	]);
	assertEquals(String(first.a_label).length, 120);
	assertEquals(second.scope, "p3");
	assertEquals([report.viewer.arrived, report.viewer.evicted, report.viewer.projectionFailures], [2, 0, 0]);
});

Deno.test("an arrival the capture cannot project still counts as an arrival", async () => {
	let failing = false;
	const capture = new ReopenCapture({
		clock: {
			timeOrigin: 0,
			now: () => {
				if (failing) throw new Error("clock");
				return 1;
			},
		},
	});
	capture.viewer({
		get kind(): string {
			throw new Error("getter");
		},
	});
	capture.viewer(null);
	capture.viewer({ kind: "ok" });
	failing = true;
	capture.viewer({ kind: "no-clock" });
	await capture.phase("p", "w", () => Promise.resolve());
	const report = await capture.snapshot("e", "t");
	assertEquals(
		[report.viewer.arrived, report.viewer.projectionFailures, report.viewer.retained],
		[4, 2, 2],
	);
	assertEquals(report.viewer.arrivals.map((a) => [a.i, a.kind, a.t]), [[3, "ok", 1], [4, "no-clock", null]]);
	assertEquals(report.phases.markers[0].arrivals, 4);
	assert(report.faults > 0, "the clock failures are counted");
});

Deno.test("the viewer ring keeps the newest 4000 arrivals and the report counts the rest", async () => {
	const capture = new ReopenCapture();
	for (let i = 1; i <= 4001; i++) capture.viewer({ kind: "k", seq: i });
	capture.viewer(null);
	const { viewer } = await capture.snapshot("e", "t");
	assertEquals(
		[viewer.capacity, viewer.arrived, viewer.projectionFailures, viewer.retained, viewer.evicted],
		[4000, 4002, 1, 4000, 1],
	);
	assertEquals([viewer.oldest?.i, viewer.newest?.i], [2, 4001]);
	assertEquals(viewer.arrivals.map((a) => a.i), Array.from({ length: 4000 }, (_, at) => at + 2));
	assertEquals([viewer.arrivals[0].seq, viewer.arrivals[3999].seq], [2, 4001]);
});

Deno.test("the phase ring keeps the newest 500 markers, including the snapshot's own failure marker", async () => {
	const capture = new ReopenCapture();
	for (let i = 1; i <= 600; i++) {
		capture.viewer({ kind: "k" });
		await capture.phase("p", "w", () => Promise.resolve());
	}
	const { phases } = await capture.snapshot("e", "t");
	assertEquals([phases.seen, phases.evicted, phases.markers.length], [1201, 701, 500]);
	assertEquals(phases.markers.map((m) => m.n), Array.from({ length: 500 }, (_, at) => at + 702));
	assertEquals(
		phases.markers.map((m) => m.arrivals),
		phases.markers.map((m) => (m.n <= 1200 ? Math.ceil(m.n / 2) : 600)),
	);
	assertEquals([phases.markers[0].event, phases.markers[498].event, phases.markers[499].event], [
		"end",
		"end",
		"failure",
	]);
});

Deno.test("phases are ordered, carry the arrival index, and rethrow the original error", async () => {
	const capture = new ReopenCapture();
	capture.viewer({ kind: "a" });
	assertEquals(await capture.phase("open", "alice", () => Promise.resolve(42)), 42);
	capture.viewer({ kind: "b" });
	const original = new Error("never arrived\nsecond line");
	let thrown: unknown = null;
	try {
		await capture.phase("sees", "bob", () => Promise.reject(original), "detail");
	} catch (error) {
		thrown = error;
	}
	assert(thrown === original, "the phase must rethrow the identical error");
	const { phases } = await capture.snapshot(original, "t");
	assertEquals(
		phases.markers.map((m) => [m.n, m.phase, m.event, m.arrivals]),
		[[1, "open", "begin", 1], [2, "open", "end", 1], [3, "sees", "begin", 2], [4, "sees", "fail", 2], [
			5,
			"failure",
			"failure",
			2,
		]],
	);
	assertEquals(phases.markers[3].error, "Error: never arrived");
});

Deno.test("the viewer's end is recorded truthfully, even when the clock fails, and is never unhandled", async () => {
	const broken = {
		timeOrigin: 0,
		now: (): number => {
			throw new Error("clock");
		},
	};
	const failed = new ReopenCapture({ clock: broken });
	failed.observeClosed(Promise.reject(new Error("socket gone")));
	const clean = new ReopenCapture({ clock: broken });
	clean.observeClosed(Promise.resolve());
	await tick();
	assertEquals((await failed.snapshot("e", "t")).viewer.closed, { t: null, error: "Error: socket gone" });
	assertEquals((await clean.snapshot("e", "t")).viewer.closed, { t: null });
	const open = new ReopenCapture();
	assertEquals((await open.snapshot("e", "t")).viewer.closed, "open");
});

Deno.test("the page observer forwards native returns, throws, this and prototypes", () => {
	const fx = fixture();
	install(fx);
	const peer = peerOf(fx);
	assertEquals(Object.getPrototypeOf(peer) === fx.Peer.prototype, true);
	const channel = channelOf(fx, peer);
	assertEquals(peer.args, ["ocapn", { ordered: true }]);
	assertEquals(channel.send("hi"), "native-return");
	assert(channel.thisSeen === channel, "send keeps its receiver");
	let thrown: unknown = null;
	try {
		channel.send("boom");
	} catch (error) {
		thrown = error;
	}
	assert(thrown === fx.sendError, "the identical native error passes through");
	const snap = snapshotOf(fx);
	assertEquals(snap.events.map((e) => e.kind), ["peer", "channel", "send", "sent", "send", "send-threw"]);
	assertEquals([snap.peers, snap.channels, snap.faults, snap.evicted], [1, 1, 0, 0]);
	assertEquals(snap.events[2].bytes, 2);
	assertEquals(snap.origin, "http://x");
});

Deno.test("each install patches its own classes, so tests do not stack", () => {
	const one = fixture();
	const two = fixture();
	install(one);
	install(two);
	channelOf(two, peerOf(two));
	assertEquals([snapshotOf(one).channels, snapshotOf(two).channels], [0, 1]);
});

Deno.test("an event is already recorded when the product's own listener runs", () => {
	const fx = fixture();
	install(fx);
	const peer = peerOf(fx);
	const incoming = new fx.Channel();
	peer.dispatchEvent(Object.assign(new Event("datachannel"), { channel: incoming }));
	const seenByProduct: string[][] = [];
	incoming.addEventListener("message", () => seenByProduct.push(snapshotOf(fx).events.map((e) => e.kind)));
	messageEvent(incoming, new ArrayBuffer(6));
	incoming.dispatchEvent(new Event("open"));
	assertEquals(seenByProduct, [["peer", "channel", "message"]]);
	const snap = snapshotOf(fx);
	assertEquals(snap.events.map((e) => [e.kind, e.origin ?? e.bytes ?? e.sctpId ?? null]), [
		["peer", null],
		["channel", "incoming"],
		["message", 6],
		["open", 4],
	]);
});

Deno.test("a send's size is read only from a string or a branded buffer, never from arbitrary properties", () => {
	const fx = fixture();
	install(fx);
	const channel = channelOf(fx, peerOf(fx));
	let touched = 0;
	const hostile = {
		get byteLength(): number {
			touched++;
			return 99;
		},
		get size(): number {
			touched++;
			return 99;
		},
		get length(): number {
			touched++;
			return 99;
		},
	};
	const buffer = new ArrayBuffer(8);
	const sends: unknown[] = [
		"héllo",
		"\u{1F600}",
		"\ud800",
		buffer,
		new Uint8Array(buffer, 2, 3),
		new DataView(buffer, 1, 4),
		new Blob(["abcd"]),
		hostile,
		7,
		null,
	];
	for (const data of sends) channel.send(data);
	assertEquals(touched, 0);
	assertEquals(
		snapshotOf(fx).events.filter((e) => e.kind === "send").map((e) => e.bytes),
		[6, 4, 3, 8, 3, 4, 4, null, null, null],
	);
	assertEquals(channel.sent.length, sends.length);
});

Deno.test("a page keeps its most recent events and reports the eviction", () => {
	const fx = fixture();
	install(fx, 4);
	const channel = channelOf(fx, peerOf(fx));
	for (let i = 0; i < 5; i++) channel.send(`m${i}`);
	const snap = snapshotOf(fx);
	assertEquals([snap.capacity, snap.retained, snap.seen, snap.evicted], [4, 4, 12, 8]);
	assertEquals([snap.oldest?.n, snap.newest?.n], [9, 12]);
});

Deno.test("a bookkeeping failure is counted and the page sees native behavior", () => {
	const fx = fixture();
	let broken = true;
	fx.scope.performance = {
		now: () => {
			if (broken) throw new Error("clock");
			return 1;
		},
		timeOrigin: 0,
	};
	install(fx, 10);
	const channel = channelOf(fx, peerOf(fx));
	assertEquals(channel.send("a"), "native-return");
	assert(channel.sent.length === 1, "the native send still ran");
	broken = false;
	assert(snapshotOf(fx).faults > 0, "faults are counted");
});

Deno.test("a document announces itself once, and a refused announcement is counted, not unhandled", async () => {
	const fx = fixture();
	const calls: unknown[] = [];
	Object.assign(fx.scope, {
		[PAGE_CAPTURE_BINDING]: (payload: unknown) => {
			calls.push(payload);
			return Promise.reject(new Error("refused"));
		},
	});
	install(fx);
	await tick();
	const snap = snapshotOf(fx);
	assertEquals(calls, [{ installId: snap.installId, timeOrigin: 1000, origin: "http://x" }]);
	assertEquals(snap.faults, 1);
});

function pageOf(evaluate: (expression: string) => Promise<unknown>): CapturePage {
	return { evaluate, onNavigate: () => {} };
}

Deno.test("each tab reports ok, uninstalled, unavailable, or not instrumented, and a hung page is bounded", async () => {
	const capture = new ReopenCapture({ snapshotMs: 30 });
	const fx = fixture();
	install(fx);
	const keys = [{}, {}, {}, {}, {}];
	capture.register(keys[0], "alice", "webrtc", true, {
		evaluate: (expression) => Promise.resolve(Function("globalThis", `return ${expression}`)(fx.scope)),
		onNavigate: () => {},
	});
	capture.register(keys[1], "bob", "webrtc", true, pageOf(() => Promise.resolve(null)));
	capture.register(keys[2], "carol", "webrtc", true, pageOf(() => Promise.reject(new Error("Target closed\nstack"))));
	capture.register(keys[3], "dave", "webrtc", true, pageOf(() => new Promise(() => {})));
	capture.register(
		keys[4],
		"erin",
		"noise-relay",
		false,
		pageOf(() => Promise.reject(new Error("must not be asked"))),
	);
	const report = await capture.snapshot(new Error("first"), "timeline");
	assertEquals(report.tabs.map((t) => t.status), [
		"ok",
		"uninstalled",
		"unavailable",
		"unavailable",
		"not-instrumented",
	]);
	assertEquals(report.tabs[2].reason, "Error: Target closed");
	assertEquals(report.tabs[3].reason, "no answer within 30ms");
	assertEquals(report.tabs[4].history, "not-instrumented");
	assertEquals(capture.who(keys[0]), "alice");
});

Deno.test("a tab whose read throws is unavailable and does not stop the report", async () => {
	const capture = new ReopenCapture();
	capture.register(
		{},
		"alice",
		"webrtc",
		true,
		pageOf(() => {
			throw new Error("sync throw");
		}),
	);
	capture.register({}, "bob", "webrtc", true, pageOf(() => Promise.resolve(null)));
	const report = await capture.snapshot("e", "t");
	assertEquals(report.tabs.map((t) => [t.status, t.reason]), [["unavailable", "Error: sync throw"], [
		"uninstalled",
		undefined,
	]]);
});

Deno.test("documents tell a same-document navigation from a new install, and unknown history from a reset", async () => {
	const capture = new ReopenCapture({ historyCapacity: 2 });
	const tab = {};
	let navigate = () => {};
	capture.register(tab, "alice", "webrtc", true, {
		evaluate: () => Promise.resolve(null),
		onNavigate: (listener) => {
			navigate = listener;
		},
	});
	const history = async () => (await capture.snapshot("e", "t")).tabs[0];
	assertEquals((await history()).history, "unknown");

	capture.documentInstalled(tab, false, { installId: "child", timeOrigin: 1, origin: "http://x" });
	assertEquals([(await history()).history, (await history()).documents.childFrames], ["unknown", 1]);

	capture.documentInstalled(tab, true, { installId: "A", timeOrigin: 10, origin: "http://x" });
	navigate();
	navigate();
	navigate();
	let report = await history();
	assertEquals([report.history, report.documents.seen, report.navigations.seen], ["single", 1, 3]);

	capture.documentInstalled(tab, true, { not: "a document" });
	assertEquals((await history()).history, "unknown");
	assertEquals((await history()).documents.malformed, 1);

	capture.documentInstalled(tab, true, { installId: "B", timeOrigin: 20, origin: "http://x" });
	capture.documentInstalled(tab, true, { installId: "C", timeOrigin: 30, origin: "http://x" });
	report = await history();
	assertEquals([report.history, report.documents.seen, report.documents.evicted], ["reset", 3, 1]);
	assertEquals(report.documents.retained.map((d) => d.installId), ["B", "C"]);
	assertEquals([report.navigations.seen, report.navigations.evicted], [3, 1]);
});

Deno.test("a lone malformed announcement is unknown history, and the snapshot is matched to the newest install", async () => {
	const capture = new ReopenCapture();
	const fx = fixture();
	install(fx);
	const key = {};
	capture.register(key, "alice", "webrtc", true, {
		evaluate: (expression) => Promise.resolve(Function("globalThis", `return ${expression}`)(fx.scope)),
		onNavigate: () => {},
	});
	capture.documentInstalled(key, true, "garbage");
	assertEquals((await capture.snapshot("e", "t")).tabs[0].history, "unknown");
	capture.documentInstalled(key, true, { installId: snapshotOf(fx).installId, timeOrigin: 1, origin: "http://x" });
	capture.documentInstalled(key, true, { installId: "later", timeOrigin: 2, origin: "http://x" });
	const [tab] = (await capture.snapshot("e", "t")).tabs;
	assertEquals([tab.status, tab.history, tab.snapshotIsNewestInstall], ["ok", "reset", false]);
});

Deno.test("reporting a failure never throws, even when the snapshot or the write fails", async () => {
	const original = console.error;
	try {
		const lines: string[] = [];
		console.error = (line: string) => lines.push(line);
		const broken = new ReopenCapture({
			clock: {
				timeOrigin: 0,
				now: () => {
					throw new Error("clock");
				},
			},
			snapshotMs: 10,
		});
		broken.register(
			{},
			"alice",
			"webrtc",
			true,
			pageOf(() => {
				throw new Error("sync throw");
			}),
		);
		await broken.report(new Error("first"), "timeline");
		assertEquals(lines.length, 1);
		assert(
			lines[0].includes("[reopen capture]") && lines[0].includes("unavailable"),
			"the report names the unavailable page",
		);

		console.error = () => {
			throw new Error("stderr closed");
		};
		await new ReopenCapture().report(new Error("first"), "timeline");
	} finally {
		console.error = original;
	}
});
