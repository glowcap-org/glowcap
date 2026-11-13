/**
 * Every string field of every record kind the feed converts, set to
 * `__proto__` in turn. A field the refusal forgot would draw an id the
 * document cannot hold, so the check reads what comes out and not a list of
 * fields: no emitted id is `__proto__`, the recording parses, and no lookup map
 * in the projection has lost its prototype.
 */

import { assert, assertEquals } from "@std/assert";
import { TimelineDocument } from "../../timeline.ts";
import { projectFromObservations } from "../../temporal/project-from-observations.ts";
import { type BaseTimelineEvent, parseWireRecord } from "../record.ts";
import { opened, wireName } from "./fixtures.ts";
import { wiredFeed } from "./wired-feed.ts";

type Json = string | number | boolean | { [key: string]: Json };

/** A record of one kind, and what must follow it for its effect to show. */
type Sample = { name: string; record: BaseTimelineEvent; replayed?: boolean };

const OPEN = opened(1, "p0/s1", "host-key", "partner-key", wireName("a"), true, { profile: "glowcap" });
const END: BaseTimelineEvent = { v: 1, sim_t_ns: 9_000_000, kind: "trace.replay-end" };

const SAMPLES: Sample[] = [
	{
		name: "session-opened",
		record: { ...opened(2, "p0/s2", "host-key", "other-key", wireName("b"), true), a_label: "Host" },
	},
	{
		name: "session-opened replayed",
		record: { ...opened(2, "p0/s2", "host-key", "other-key", wireName("b"), true), replay: true },
		replayed: true,
	},
	{
		name: "message-decoded by session",
		record: {
			v: 1,
			sim_t_ns: 3_000_000,
			kind: "ocapn.message-decoded",
			session: "p0/s1",
			outbound: true,
			op: "op:deliver",
			digest: "d1",
		},
	},
	{
		name: "message-decoded by ends",
		record: {
			v: 1,
			sim_t_ns: 3_000_000,
			kind: "ocapn.message-decoded",
			session: "p0/s1",
			src: "host-key",
			dst: "partner-key",
			op: "op:deliver",
		},
	},
	{
		name: "session-meta",
		record: { v: 1, sim_t_ns: 4_000_000, kind: "ocapn.session-meta", session: "p0/s1", meta: { label: "nick" } },
	},
	{ name: "session-closed", record: { v: 1, sim_t_ns: 5_000_000, kind: "ocapn.session-closed", session: "p0/s1" } },
	{ name: "producer-left", record: { v: 1, sim_t_ns: 6_000_000, kind: "trace.producer-left", scope: "p0" } },
];

/** The path to every string in a record, nested ones included. */
function stringPaths(value: unknown, path: string[] = []): string[][] {
	if (typeof value === "string") return [path];
	if (typeof value !== "object" || value === null) return [];
	return Object.entries(value).flatMap(([key, child]) => stringPaths(child, [...path, key]));
}

function withReserved(record: BaseTimelineEvent, path: string[]): BaseTimelineEvent {
	const copy: { [key: string]: Json } = JSON.parse(JSON.stringify(record));
	let at = copy;
	for (const key of path.slice(0, -1)) {
		const next = at[key];
		if (typeof next !== "object") throw new Error(`no object at ${key}`);
		at = next;
	}
	const last = path[path.length - 1];
	if (last === undefined) throw new Error("empty path");
	at[last] = "__proto__";
	return parseWireRecord(JSON.stringify(copy));
}

const ID_KEYS = new Set(["id", "peerId", "sessionId", "messageId", "from", "to", "peer"]);

/** Every value an emitted event holds under a key that names an id. */
function idsIn(value: unknown): string[] {
	if (typeof value !== "object" || value === null) return [];
	return Object.entries(value).flatMap(([key, child]) =>
		typeof child === "string" ? (ID_KEYS.has(key) ? [child] : []) : idsIn(child)
	);
}

for (const sample of SAMPLES) {
	const paths = stringPaths(sample.record);
	Deno.test(`live ids: ${sample.name} with any string field set to __proto__ draws no such id`, async () => {
		assert(paths.length > 0);
		for (const path of paths) {
			const where = `${sample.name} ${path.join(".")}`;
			const { feed, seen, send } = await wiredFeed();
			send(OPEN);
			send(withReserved(sample.record, path));
			if (sample.replayed) send(END);
			feed.disconnect();
			for (const id of seen.flatMap(idsIn)) assert(id !== "__proto__", `${where} drew an id`);
			const parsed = TimelineDocument.safeParse({
				id: "live",
				duration: 100,
				recording: { sources: [{ id: "live", meta: { kind: "glowcap-host" }, observations: seen }] },
			});
			assert(parsed.success, `${where} left a recording that does not parse`);
			const entities = projectFromObservations(parsed.data).entities;
			for (const map of [entities?.peers, entities?.sessions, entities?.messages]) {
				if (map !== undefined) assertEquals(Object.getPrototypeOf(map), Object.prototype, where);
			}
		}
	});
}
