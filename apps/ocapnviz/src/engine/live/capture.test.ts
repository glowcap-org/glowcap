import { assert, assertEquals } from "@std/assert";
import { Engine } from "../engine.ts";
import { engineTest } from "../engine-test/harness.ts";
import { makeBaseEventConverter } from "./feed.ts";
import {
	captureFullError,
	claimRecording,
	emptyCaptureError,
	makeLiveAppender,
	MAX_CAPTURE_CHARS,
	startLiveMode,
} from "./mode.ts";
import { savedText } from "../../builder/document-io.ts";
import type { LivePeerFactory } from "./connection.ts";
import { newLiveDoc, UNBOUNDED } from "./feed-test/harness.ts";
import { primaryObservations, savedObservationChars } from "../temporal/recording-access.ts";

/**
 * What a capture keeps and what a recording claims from it: the ceiling a
 * capture ends at, the count that ceiling is measured in, and the document
 * Stop or a full capture hands to Play.
 */

Deno.test("makeLiveAppender keeps arrivals up to its ceiling and ends the capture at the one past it", () => {
	const liveDoc = newLiveDoc();
	const arrival = (id: string) => ({ id, kind: "peer-left" as const, t: 10, peerId: "p" });
	const sized = newLiveDoc();
	makeLiveAppender({ liveDoc: sized, clock: { t: 0 }, ...UNBOUNDED })(arrival("e0"));
	const cost = primaryObservations(sized).reduce((sum, kept) => sum + savedObservationChars(kept), 0);
	let full = 0;
	const append = makeLiveAppender({
		liveDoc,
		clock: { t: 0 },
		ceilingChars: 2 * cost,
		onFull: () => full++,
	});
	append(arrival("e1"));
	append(arrival("e2"));
	assertEquals([primaryObservations(liveDoc).length, full], [2, 0], "a capture holds exactly its ceiling");
	append(arrival("e3"));
	assertEquals([primaryObservations(liveDoc).length, full], [2, 1], "the arrival past the ceiling is not kept");
	append(arrival("e4"));
	assertEquals([primaryObservations(liveDoc).length, full], [2, 1], "a full capture says so once");

	// A full capture keeps nothing, an arrival its ceiling still has room for
	// included.
	const room = newLiveDoc();
	const tight = makeLiveAppender({
		liveDoc: room,
		clock: { t: 0 },
		// One character short of holding `e1` and the longer arrival together.
		ceilingChars: 2 * cost + "longer-than-e1".length - "e1".length - 1,
		onFull: () => {},
	});
	tight(arrival("e1"));
	tight(arrival("longer-than-e1"));
	tight(arrival("e2"));
	assertEquals(primaryObservations(room).map((observation) => observation.id), ["e1"]);

	const none = newLiveDoc();
	makeLiveAppender({ liveDoc: none, clock: { t: 0 }, ceilingChars: 0, onFull: () => full++ })(arrival("e5"));
	assertEquals([primaryObservations(none).length, full], [0, 2]);
});

Deno.test("a capture that fills through the feed tells its owner once and holds what it kept", async () => {
	const records: Array<(line: string) => void> = [];
	const factory: LivePeerFactory = (_ref, onRecord) => {
		records.push(onRecord);
		return Promise.resolve({ closed: new Promise<void>(() => {}), close: () => Promise.resolve() });
	};
	const opened = (partner: string) =>
		JSON.stringify({
			v: 1,
			sim_t_ns: 5_000_000,
			kind: "ocapn.session-opened",
			transport: "tcp",
			captp_version: "1.0",
			session: `alice--${partner}`,
			a: "alice",
			b: partner,
			codec: "syrup",
		});
	let full = 0;
	const capture = async (ceilingChars: number) => {
		const handle = startLiveMode({
			sturdyref: "ocapn://node.keyed-tcp?h=127.0.0.1:9/s/swiss",
			peerFactory: factory,
			ceilingChars,
			onFull: () => full++,
		});
		await new Promise((resolve) => setTimeout(resolve, 0));
		const record = records.pop();
		if (record === undefined) throw new Error("the dial must reach the peer factory");
		return { handle, record };
	};
	// What the first record alone costs is the ceiling the second one passes.
	const sized = await capture(Infinity);
	sized.record(opened("bob"));
	const first = primaryObservations(sized.handle.engine.doc);
	const cost = first.reduce((sum, observation) => sum + savedObservationChars(observation), 0);
	sized.handle.dispose();
	assert(first.length > 0 && full === 0);

	const { handle, record } = await capture(cost);
	record(opened("bob"));
	assertEquals(full, 0, "a capture holds exactly its ceiling");
	record(opened("carol"));
	record(opened("dave"));
	assertEquals(full, 1);
	const claimed = claimRecording(handle.engine.doc, "claimed", "full");
	handle.dispose();
	assertEquals(claimed === null ? 0 : primaryObservations(claimed).length, first.length);
});

Deno.test("a capture counts an arrival as the characters it adds to the saved file", () => {
	const liveDoc = newLiveDoc();
	const append = makeLiveAppender({ liveDoc, clock: { t: 0 }, ...UNBOUNDED });
	const saved = () => savedText(liveDoc, "2026-01-01T00:00:00.000Z").length;
	append({ id: "e1", kind: "peer-left", t: 10, peerId: "p" });
	const one = saved();
	// A message carries a nested value, so its lines sit at more than one depth.
	append({
		id: "m1",
		kind: "message-sent",
		t: 20,
		arrivalT: 30,
		sessionId: "s",
		messageId: "m1",
		from: "a",
		to: "b",
		label: "line one\nline two",
		provenance: { "prov:wasDerivedFrom": ["a capture", "a file"] },
	});
	const message = primaryObservations(liveDoc)[1];
	if (message === undefined) throw new Error("the capture must keep the message");
	assertEquals(saved() - one, savedObservationChars(message));
});

engineTest("a recording saves in under three times what its capture counted", () => {
	const doc = newLiveDoc();
	const engine = new Engine(doc);
	engine.enqueue({ kind: "play" });
	engine.tick(0);
	const append = makeLiveAppender({ liveDoc: doc, clock: engine.clock, ...UNBOUNDED });
	const convert = makeBaseEventConverter();
	const feed = (record: Parameters<typeof convert>[0]) => convert(record).forEach(append);
	feed({
		v: 1,
		sim_t_ns: 0,
		kind: "ocapn.session-opened",
		transport: "tcp",
		captp_version: "1.0",
		session: "alice--bob",
		a: "alice",
		b: "bob",
		codec: "syrup",
	});
	// A message with no payload is the arrival the page derives the most from
	// for its size.
	for (let n = 1; n <= 200; n++) {
		feed({
			v: 1,
			sim_t_ns: n * 1_000_000,
			kind: "ocapn.message-decoded",
			session: "alice--bob",
			src: n % 2 === 0 ? "alice" : "bob",
			dst: n % 2 === 0 ? "bob" : "alice",
			op: "op:deliver",
			len: 50,
		});
		engine.tick(20);
	}
	const counted = primaryObservations(engine.doc).reduce((sum, kept) => sum + savedObservationChars(kept), 0);
	const claimed = claimRecording(engine.doc, "claimed", "full");
	if (claimed === null) throw new Error("the capture must hold observations");
	const saved = savedText(claimed, "2026-01-01T00:00:00.000Z").length;
	assert(
		Object.keys(claimed.entities?.messages ?? {}).length >= 200,
		"the engine derived a message for each arrival",
	);
	// `MAX_CAPTURE_CHARS` leaves room for four times.
	assert(saved < 3 * counted, `saved ${saved} characters for ${counted} counted`);
});

Deno.test("the notice a full capture raises names how much a recording holds", () => {
	const error = captureFullError();
	assertEquals(error.title, "Recording stopped");
	assert(error.detail.includes(`${MAX_CAPTURE_CHARS / (1024 * 1024)} MiB`));
});

// claimRecording: the whole accumulated doc IS the recording, the
// engine connects at the Record press, so its t=0 is the press.

Deno.test("claimRecording: fresh id, content-derived duration", () => {
	const doc = newLiveDoc();
	primaryObservations(doc).push(
		{
			id: "e1",
			t: 0,
			kind: "peer-joined",
			peerId: "alice",
			profile: "glowcap",
		},
		{
			id: "e2",
			t: 500,
			kind: "message-sent",
			messageId: "m1",
			sessionId: "s1",
			from: "alice",
			to: "bob",
			arrivalT: 900,
		},
	);
	const claimed = claimRecording(doc, "rec-1", "stopped")!;
	assert(claimed !== null, "a non-empty recording claims");
	assertEquals(claimed.id, "rec-1");
	assertEquals(primaryObservations(claimed).length, 2);
	// Duration covers the last flight's arrival plus breathing room,
	// instead of the live view's one-hour ceiling.
	assert(
		claimed.duration >= 900 && claimed.duration < 60_000,
		`duration derives from content, got ${claimed.duration}`,
	);
});

Deno.test("claimRecording: an empty recording claims nothing", () => {
	assertEquals(claimRecording(newLiveDoc(), "rec-2", "stopped"), null);
	const error = emptyCaptureError();
	assertEquals(error.code, "validation");
	assertEquals(error.title, "Nothing to review");
});

Deno.test("claimRecording: a recording says how its capture ended", () => {
	const doc = newLiveDoc();
	primaryObservations(doc).push({ id: "e1", t: 0, kind: "peer-joined", peerId: "alice", profile: "glowcap" });
	assertEquals(
		claimRecording(doc, "rec-5", "stopped")?.metadata?.["dct:description"],
		"Recorded from a live feed.",
	);
	assertEquals(
		claimRecording(doc, "rec-6", "full")?.metadata?.["dct:description"],
		"Recorded from a live feed until the recording was full.",
		"a recording that filled says so after its notice is gone",
	);
});

Deno.test("claimRecording: the claim owns its observations", () => {
	// A shallow spread hands the claimed document the very array the live
	// appender is still pushing into, so a feed that keeps arriving after Stop
	// goes on writing into what the reader is scrubbing. The one caller
	// unmounts the capture in the same commit, which makes it safe and
	// is a coupling nothing states. This holds the sever instead.
	const doc = newLiveDoc();
	primaryObservations(doc).push({
		id: "e1",
		t: 0,
		kind: "peer-joined",
		peerId: "alice",
		profile: "glowcap",
	});
	const claimed = claimRecording(doc, "rec-3", "stopped")!;
	assertEquals(primaryObservations(claimed).length, 1);
	// The live side goes on doing what a live side does.
	primaryObservations(doc).push({
		id: "e2",
		t: 10,
		kind: "peer-joined",
		peerId: "bob",
		profile: "glowcap",
	});
	assertEquals(
		primaryObservations(claimed).length,
		1,
		"an arrival after the claim reached the claimed recording",
	);
	assertEquals(primaryObservations(doc).length, 2);
});

Deno.test("a saved recording holds no part of the link it was captured with", async () => {
	const marker = "SECRET-SWISSNUM-MARKER";
	const link = `ocapn://node.keyed-tcp?h=127.0.0.1:9/s/${marker}`;
	const records: Array<(line: string) => void> = [];
	const factory: LivePeerFactory = (_ref, onRecord) => {
		records.push(onRecord);
		return Promise.resolve({ closed: new Promise<void>(() => {}), close: () => Promise.resolve() });
	};
	const handle = startLiveMode({ sturdyref: link, peerFactory: factory, onFull: () => {} });
	await new Promise((resolve) => setTimeout(resolve, 0));
	const record = records[0];
	if (record === undefined) throw new Error("the dial must reach the peer factory");
	record(JSON.stringify({
		v: 1,
		sim_t_ns: 5_000_000,
		kind: "ocapn.session-opened",
		transport: "tcp",
		captp_version: "1.0",
		session: "alice--bob",
		a: "alice",
		b: "bob",
		codec: "syrup",
	}));
	const claimed = claimRecording(handle.engine.doc, "claimed", "stopped");
	handle.dispose();
	assert(claimed !== null, "the capture must hold an observation");
	const saved = savedText(claimed, "2026-01-01T00:00:00.000Z");
	assertEquals(saved.includes(marker), false);
	assertEquals(saved.includes("ocapn://"), false);
});
