import { assert, assertEquals, assertStringIncludes } from "@std/assert";
import { TimelineDocument } from "./timeline.ts";
import { Engine } from "./engine.ts";
import { engineTest } from "./engine-test/harness.ts";
import { validateIntent } from "./authoring/validate.ts";
import { cascadePaste } from "./schema/paste.ts";
import { wiredFeed } from "./live/feed-test/wired-feed.ts";
import type { EngineError } from "./errors.ts";
import { opened } from "./live/feed-test/fixtures.ts";
import type { BaseTimelineEvent } from "./live/record.ts";

/** `__proto__` is the one id a record keyed by id cannot hold, so it is
 *  refused wherever an id enters: a file, an authoring edit, the live wire. */

const joined = (peerId: string) => ({ id: "e1", t: 0, kind: "peer-joined", peerId, profile: "glowcap" });

Deno.test("parse: a file whose observation names __proto__ fails, naming the id", () => {
	const result = TimelineDocument.safeParse({ id: "x", duration: 10, events: [joined("__proto__")] });
	assert(!result.success);
	assertStringIncludes(result.error.issues[0]?.message ?? "", '"__proto__"');
});

Deno.test("parse: a file whose entities map keys __proto__ fails, naming the id", () => {
	const text =
		`{"id":"x","duration":10,"entities":{"sessions":{"__proto__":{"a":{"peer":"p"},"b":{"peer":"q"},"codec":"syrup","captpVersion":"v1_0"}}}}`;
	const result = TimelineDocument.safeParse(JSON.parse(text));
	assert(!result.success);
	assertStringIncludes(result.error.issues[0]?.message ?? "", '"__proto__"');
});

Deno.test("parse: the other inherited names still parse", () => {
	assert(TimelineDocument.safeParse({ id: "x", duration: 10, events: [joined("hasOwnProperty")] }).success);
});

engineTest("authoring: add-peer and the renames refuse __proto__ and change nothing", () => {
	const engine = new Engine(TimelineDocument.parse({ id: "x", duration: 10, events: [joined("a")] }));
	const errors: EngineError[] = [];
	engine.onError((e) => errors.push(e));
	const before = JSON.stringify(engine.doc);
	engine.dispatch({ kind: "add-peer", id: "__proto__", profile: "glowcap", position: { x: 0, y: 0 } });
	engine.dispatch({ kind: "rename-peer", oldId: "a", newId: "__proto__" });
	assertEquals(errors.length, 2);
	for (const e of errors) assertStringIncludes(e.detail, '"__proto__"');
	assertEquals(JSON.stringify(engine.doc), before);
	const checked = validateIntent(engine.doc, { kind: "rename-session", oldId: "s", newId: "__proto__" });
	assert(!checked.ok);
});

Deno.test("paste: a payload carrying __proto__ is refused whole", () => {
	const doc = TimelineDocument.parse({ id: "x", duration: 10 });
	const payload = JSON.parse(
		`{"entities":{"peers":{"__proto__":{"profile":"glowcap"}}},"events":[],"minT":0,"externalRefs":{}}`,
	);
	const result = cascadePaste(doc, payload, 0);
	assert(!result.ok);
	assertStringIncludes(result.error.detail, '"__proto__"');
});

Deno.test("live: a record naming __proto__ is reported and draws nothing", async () => {
	const { feed, errors, seen, send } = await wiredFeed();
	send({
		v: 1,
		sim_t_ns: 0,
		seq: 1,
		epoch: 1,
		kind: "ocapn.session-opened",
		session: "p0/s1",
		a: "__proto__",
		b: "alice",
		transport: "tcp",
		codec: "syrup",
		captp_version: "1.0",
	});
	feed.disconnect();
	assertEquals(seen, []);
	assertEquals(errors.length, 1);
	assertStringIncludes(errors[0] ?? "", '"__proto__"');
});

const replayed = (record: BaseTimelineEvent): BaseTimelineEvent => ({ ...record, replay: true });
const END = { v: 1, sim_t_ns: 9_000_000, kind: "trace.replay-end" } as const;
const message = (session: string): BaseTimelineEvent => ({
	v: 1,
	sim_t_ns: 20_000_000,
	kind: "ocapn.message-decoded",
	session,
	outbound: true,
	op: "op:deliver",
});

Deno.test("live: a replayed session that names __proto__ is refused alone, and its neighbors draw", async () => {
	const { feed, errors, seen, send } = await wiredFeed();
	send(replayed(opened(0, "p0/s1", "rooms-key", "tab1-key", "wire-1", true)));
	send(replayed(opened(1, "p0/s2", "rooms-key", "__proto__", "wire-2", true)));
	send(replayed(opened(2, "p0/s3", "rooms-key", "tab3-key", "wire-3", true)));
	send(END);
	send(message("p0/s1"));
	feed.disconnect();
	assertEquals(errors.length, 1);
	const opens = seen.filter((ev) => ev.kind === "session-opened");
	assertEquals(opens.length, 2);
	const joined = seen.flatMap((ev) => ev.kind === "peer-joined" ? [ev.peerId] : []);
	assert(joined.includes("tab1-key") && joined.includes("tab3-key") && !joined.includes("__proto__"));
	const sent = seen.flatMap((ev) => ev.kind === "message-sent" ? [ev] : []);
	assertEquals(sent.length, 1);
	assert(opens.some((o) => o.kind === "session-opened" && o.sessionId === sent[0]?.sessionId));
});

Deno.test("live: a live record naming __proto__ while a batch is open leaves the batch to its own end", async () => {
	const { feed, errors, seen, send } = await wiredFeed();
	send(replayed(opened(0, "p0/s1", "rooms-key", "tab1-key", "wire-1", true)));
	send(opened(1, "p0/s2", "rooms-key", "__proto__", "wire-2", true));
	assertEquals(seen, []);
	send(END);
	feed.disconnect();
	assertEquals(errors.length, 1);
	assertEquals(seen.filter((ev) => ev.kind === "session-opened").length, 1);
});
