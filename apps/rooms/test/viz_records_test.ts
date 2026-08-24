// Pure trace-record admission and replay-state contracts for the Rooms viz endpoint.

import type { TraceEvent } from "@pancake/runtime";
import { announceLines, publishUrl } from "../lib/viz_publish.ts";
import { parseRecord, replayLines } from "../server/viz.ts";
import { utf8Bytes } from "../server/viz/records.ts";
import { assertEquals } from "./assert.ts";

function assert(ok: boolean, what: string): void {
	if (!ok) throw new Error(what);
}

type Stamped = { seq: number; line: string };

const stamp = (seq: number): Stamped => ({ seq, line: `{"seq":${seq}}` });
const replayed = (seq: number): string => `{"replay":true,"seq":${seq}}`;
const producerOpen = (extra: Record<string, unknown> = {}): string =>
	JSON.stringify({
		v: 1,
		sim_t_ns: 1,
		kind: "ocapn.session-opened",
		session: "s",
		a: "alice",
		b: "room",
		transport: "tcp",
		...extra,
	});

Deno.test("replay is exactly the live opens, in seq order", () => {
	const liveOpens = new Map([
		["s2", stamp(7)],
		["s1", stamp(3)],
		["s3", stamp(400)],
	]);
	assertEquals(replayLines(liveOpens, new Map()), [
		replayed(3),
		replayed(7),
		replayed(400),
	]);
});

Deno.test("a live session's annotation replays beside its open", () => {
	const liveOpens = new Map([["s1", stamp(3)]]);
	const liveMetas = new Map([["s1", stamp(9)], ["dead", stamp(4)]]);
	assertEquals(replayLines(liveOpens, liveMetas), [replayed(3), replayed(9)]);
});

Deno.test("no live sessions replays nothing", () => {
	assertEquals(replayLines(new Map(), new Map()), []);
});

Deno.test("a producer line that is not a timeline record is refused", () => {
	assert(parseRecord("not json") === null, "non-JSON accepted");
	assert(parseRecord("[1,2,3]") === null, "array accepted");
	assert(
		parseRecord('{"v":2,"kind":"ocapn.session-opened","session":"s"}') === null,
		"wrong version accepted",
	);
	assert(
		parseRecord('{"v":1,"kind":"whatever","session":"s"}') === null,
		"unknown kind accepted",
	);
	assert(
		parseRecord('{"v":1,"kind":"toString","session":"s"}') === null,
		"inherited object key reached the kind table",
	);
	assert(parseRecord('{"v":1,"kind":"ocapn.session-opened"}') === null, "missing session id accepted");
	assert(
		parseRecord('{"v":1,"kind":"ocapn.session-opened","session":5}') === null,
		"non-string id accepted",
	);
	assert(
		parseRecord(`{"v":1,"kind":"ocapn.session-opened","session":"${"x".repeat(5000)}"}`) === null,
		"unbounded id accepted",
	);
	assert(
		parseRecord('{"v":1,"kind":"ocapn.session-opened","session":"s","a":7}') === null,
		"non-string endpoint accepted",
	);
});

Deno.test("what a producer says about itself is bounded like everything else", () => {
	for (const field of ["a_label", "a_profile"]) {
		assert(
			parseRecord(producerOpen({ [field]: "x".repeat(5000) })) === null,
			`unbounded ${field} accepted`,
		);
		assert(parseRecord(producerOpen({ [field]: 7 })) === null, `non-string ${field} accepted`);
		const ok = parseRecord(producerOpen({ [field]: "pancake" }));
		assert(ok !== null, `an ordinary ${field} was refused`);
		assertEquals((ok as unknown as Record<string, unknown>)[field], "pancake");
	}
});

Deno.test("a producer cannot stamp its own seq, epoch, or replay mark", () => {
	const rec = parseRecord(producerOpen({ seq: 99999, epoch: 123, replay: true }));
	assert(rec !== null, "a well-formed record was refused");
	const fields = rec as unknown as Record<string, unknown>;
	assert(fields.seq === undefined, "producer seq survived");
	assert(fields.epoch === undefined, "producer epoch survived");
	assert(fields.replay === undefined, "producer replay mark survived");
});

Deno.test("producer limits count UTF-8 bytes and each kind satisfies its schema", () => {
	const unusual = "aé😀\ud800";
	assertEquals(utf8Bytes(unusual), new TextEncoder().encode(unusual).byteLength);
	assert(parseRecord(producerOpen({ a: "", b: "room" })) === null, "empty endpoint accepted");
	assert(parseRecord(producerOpen({ b: undefined })) === null, "missing partner endpoint accepted");
	assert(parseRecord(producerOpen({ transport: undefined })) === null, "missing transport accepted");
	assert(
		parseRecord(producerOpen({ a_label: "é".repeat(3000) })) === null,
		"UTF-8 field limit was enforced as UTF-16 code units",
	);
	assert(
		parseRecord(JSON.stringify({
			v: 1,
			sim_t_ns: 1,
			kind: "ocapn.message-decoded",
			session: "s",
			outbound: true,
			digest: "a".repeat(32),
		})) !== null,
		"valid message record was refused",
	);
	assert(
		parseRecord(JSON.stringify({
			v: 1,
			sim_t_ns: 1,
			kind: "ocapn.message-decoded",
			session: "s",
			outbound: true,
			digest: "a".repeat(32),
			len: 4096,
			bytes_b64: `${"A".repeat(5462)}==`,
		})) !== null,
		"the binding's default full-frame payload was refused as an ordinary field",
	);
	assert(
		parseRecord(JSON.stringify({
			v: 1,
			sim_t_ns: 1,
			kind: "ocapn.message-decoded",
			session: "s",
			outbound: true,
			digest: "a".repeat(32),
			len: 2,
			bytes_b64: "YQ==",
		})) === null,
		"payload length mismatch accepted",
	);
	assert(
		parseRecord(JSON.stringify({
			v: 1,
			sim_t_ns: 1,
			kind: "ocapn.message-decoded",
			session: "s",
			outbound: true,
			digest: "a".repeat(32),
			len: 1,
			bytes_b64: "YR==",
		})) === null,
		"non-canonical base64 accepted",
	);
	assert(
		parseRecord(JSON.stringify({ v: 1, sim_t_ns: 1, kind: "ocapn.session-meta", session: "s" })) === null,
		"metadata record without metadata accepted",
	);
	assert(parseRecord(producerOpen({ invented: { retained: true } })) === null, "unknown retained field accepted");
});

Deno.test("publishUrl points at the producer half of an endpoint URL", () => {
	assertEquals(publishUrl("ws://127.0.0.1:9000/"), "ws://127.0.0.1:9000/publish");
	assertEquals(publishUrl("ws://127.0.0.1:9000/publish"), "ws://127.0.0.1:9000/publish");
});

Deno.test("a reconnecting producer re-announces its live topology and nothing else", () => {
	const open = (id: string): TraceEvent => ({
		v: 1,
		sim_t_ns: 0,
		kind: "ocapn.session-opened",
		session: id,
	});
	const meta = (id: string): TraceEvent => ({
		v: 1,
		sim_t_ns: 0,
		kind: "ocapn.session-meta",
		session: id,
		meta: { label: "bob" },
	});
	const opens = new Map([["s1", open("s1")]]);
	const metas = new Map([["s1", meta("s1")], ["gone", meta("gone")]]);
	assertEquals(announceLines(opens, metas), [JSON.stringify(open("s1")), JSON.stringify(meta("s1"))]);
});
