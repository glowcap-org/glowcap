// The generated protocol tables against the application's public vocabulary
// and readers.
//
// `tools/gen/rooms_protocol.zig` declares the wire grammar once and emits the
// application and terminal-client projections. This test holds those
// projections to the readers, so the application and clients cannot disagree
// about a method, tag, arity, field, or nullable slot.

import type { Argument, Session } from "@glowcap/runtime";
import * as z from "zod/mini";
import * as gen from "../clients/deno/protocol_gen.ts";
import * as spec from "../lib/protocol.ts";
import * as data from "../lib/protocol_data.ts";
import { isRegistrationId, readRoomEvent, ROOM_EVENT_KINDS, RoomInfoSchema } from "../lib/directory_publications.ts";
import { ROOM_MEMBERSHIP_KINDS } from "../lib/room/membership.ts";
import { PresenceSchema, SEAT_PHASES } from "../lib/room/presence.ts";
import { readPresence } from "../lib/room/message.ts";
import { roomInboxBehavior } from "../lib/room/inbox.ts";
import { assertEquals } from "./assert.ts";

const REGISTRATION_ID = "00000000-0000-4000-8000-000000000001";

/** One wire value a field admits, so a reader can be handed a row built from
 * the table alone. */
function sample(field: gen.Field): Argument {
	if (field.values.length > 0) return field.values[0];
	switch (field.type) {
		case "string":
			return "";
		case "text":
			return "ada";
		case "natural":
			return 1;
		case "boolean":
			return true;
		case "registration-id":
			return REGISTRATION_ID;
		case "list":
			return [];
		case "any":
			return "anything";
		case "reference":
			throw new Error(`no sample stands in for the ${field.name} reference`);
		default: {
			const unhandled: never = field.type;
			throw new Error(`unhandled wire type ${JSON.stringify(unhandled)}`);
		}
	}
}

/** The strings a zod enumeration admits, read off the schema object itself,
 * through a nullable wrapper when there is one. */
function enumValues(schema: unknown): string[] {
	const seen = schema as {
		options?: unknown;
		_zod?: { def?: { innerType?: unknown; entries?: Record<string, unknown> } };
	};
	if (Array.isArray(seen.options)) return seen.options.filter((v): v is string => typeof v === "string");
	if (seen._zod?.def?.innerType != null) return enumValues(seen._zod.def.innerType);
	if (seen._zod?.def?.entries != null) return Object.keys(seen._zod.def.entries);
	throw new Error("the schema is not an enumeration");
}

/** The kind each option of a discriminated union admits: a literal, or every
 * value of an enumeration. */
function unionKinds(schema: unknown): string[] {
	const options = (schema as { _zod?: { def?: { options?: unknown } } })._zod?.def?.options;
	if (!Array.isArray(options)) throw new Error("the schema is not a union");
	return options.flatMap((option) => {
		const kind = (option as { shape?: { kind?: unknown } }).shape?.kind;
		if (kind == null) throw new Error("a union option carries no kind");
		// A literal and an enumeration both keep their admitted values here,
		// as an array for the first and a set for the second.
		const values = (kind as { _zod?: { def?: { values?: unknown } } })._zod?.def?.values;
		if (values != null) {
			return [...(values as Iterable<unknown>)].filter((v): v is string => typeof v === "string");
		}
		return enumValues(kind);
	});
}

Deno.test("the client verbs and tags are the application's generated vocabulary", () => {
	const pairs: [string, string, string, string][] = [
		["DIRECTORY", gen.DIRECTORY, data.DIRECTORY, spec.DIRECTORY],
		["OPEN", gen.OPEN, data.OPEN, spec.OPEN],
		["ENTER", gen.ENTER, data.ENTER, spec.ENTER],
		["LIST_PUBLICATIONS", gen.LIST_PUBLICATIONS, data.LIST_PUBLICATIONS, spec.LIST_PUBLICATIONS],
		["WATCH_PUBLICATIONS", gen.WATCH_PUBLICATIONS, data.WATCH_PUBLICATIONS, spec.WATCH_PUBLICATIONS],
		["REGISTER", gen.REGISTER, data.REGISTER, spec.REGISTER],
		["INTRODUCE", gen.INTRODUCE, data.INTRODUCE, spec.INTRODUCE],
		["MEMBER_REGISTRATION", gen.MEMBER_REGISTRATION, data.MEMBER_REGISTRATION, spec.MEMBER_REGISTRATION],
		["SUBSCRIBE", gen.SUBSCRIBE, data.SUBSCRIBE, spec.SUBSCRIBE],
		["POST", gen.POST, data.POST, spec.POST],
		["LEAVE", gen.LEAVE, data.LEAVE, spec.LEAVE],
		["TYPING", gen.TYPING, data.TYPING, spec.TYPING],
		["AWAY", gen.AWAY, data.AWAY, spec.AWAY],
		["NOTIFY", gen.NOTIFY, data.NOTIFY, spec.NOTIFY],
		["DM", gen.DM, data.DM, spec.DM],
		["MEMBERSHIP_ENDED", gen.MEMBERSHIP_ENDED, data.MEMBERSHIP_ENDED, spec.MEMBERSHIP_ENDED],
	];
	for (const [name, client, application, specified] of pairs) {
		assertEquals(client, application, `${name} client projection`);
		assertEquals(application, specified, `${name} documented export`);
	}
	assertEquals(gen.MEMBERSHIP_VERBS.map((verb) => verb.name), [spec.POST, spec.LEAVE, spec.TYPING, spec.AWAY]);
});

Deno.test("the enumerations are the ones the server's readers admit", () => {
	assertEquals([...gen.MEMBERSHIP_KINDS], [...ROOM_MEMBERSHIP_KINDS], "membership kinds");
	assertEquals([...gen.SEAT_PHASES], [...SEAT_PHASES], "seat phases");
});

Deno.test("the watch kinds and their arities are the directory's", () => {
	assertEquals(gen.WATCH_KINDS.map((kind) => kind.tag), [...ROOM_EVENT_KINDS], "watch kinds");
	for (const kind of gen.WATCH_KINDS) {
		const args = kind.args.map(sample);
		const event = readRoomEvent([kind.tag, ...args]);
		assertEquals(event?.kind, kind.tag, `${kind.tag} at its declared arity`);
		assertEquals(event?.entry != null, kind.room, `${kind.tag} carries a publication`);
		assertEquals(readRoomEvent([kind.tag, ...args.slice(0, -1)]), null, `${kind.tag} one argument short`);
	}
});

Deno.test("the publication record is the directory's schema, field for field", () => {
	const shape = (RoomInfoSchema as { shape?: Record<string, unknown> }).shape;
	if (shape == null) throw new Error("the publication schema has no shape");
	assertEquals(gen.PUBLICATION_FIELDS.map((field) => field.name).sort(), Object.keys(shape).sort(), "fields");
	// One valid row per publication kind, because the schema ties a kind to
	// which slots may be null.
	const rows = [
		{ id: "lobby", name: "lobby", kind: "local", count: 2, origin: "", proof: "local", offers: "participant" },
		{
			id: "far",
			name: "far",
			kind: "foreign",
			count: null,
			origin: "ocapn://far",
			proof: "session",
			offers: "observer",
		},
		{ id: "irc", name: "irc", kind: "bridge", count: 3, origin: "irc.example", proof: "bridge", offers: null },
	];
	for (const row of rows) assertEquals(z.safeParse(RoomInfoSchema, row).success, true, `${row.kind} row`);
	for (const field of gen.PUBLICATION_FIELDS) {
		const nullAdmitted = rows.some((row) => z.safeParse(RoomInfoSchema, { ...row, [field.name]: null }).success);
		assertEquals(nullAdmitted, field.nullable, `${field.name} admits a wire null`);
		if (field.values.length > 0) {
			assertEquals([...field.values], enumValues(shape[field.name]), `${field.name} enumeration`);
		}
	}
});

Deno.test("the presence tails are the ones the room's reader admits", () => {
	const presence = gen.ROOM_TAILS.filter((tail) => tail.effect !== null);
	assertEquals(presence.map((tail) => tail.tag).sort(), unionKinds(PresenceSchema).sort(), "presence kinds");
	for (const tail of presence) {
		const rest = tail.rest === null ? [] : [sample({ name: "rest", type: tail.rest, nullable: false, values: [] })];
		const args = [gen.ROOM_SENDER, "", tail.tag, ...tail.trailing.map(sample), ...rest];
		assertEquals(readPresence(args)?.kind, tail.tag, `${tail.tag} at its declared arity`);
	}
});

Deno.test("the membership-ended tail is the shape the room inbox holds it to", () => {
	const ended: string[] = [];
	const behavior = roomInboxBehavior({} as Session, {
		typing() {},
		listed() {},
		line() {},
		arrived() {},
		ended: (reason) => ended.push(reason),
		authorityChanged() {},
		authorityStatus() {},
	});
	const tail = gen.ROOM_TAILS.find((candidate) => candidate.tag === gen.MEMBERSHIP_ENDED);
	assertEquals(tail?.trailing.length, 0, "no trailing arguments");
	assertEquals([tail?.sender, tail?.text], ["room", "nonempty"], "from the room, with a reason");
	behavior(gen.NOTIFY, [gen.ROOM_SENDER, "kicked by the steward", gen.MEMBERSHIP_ENDED]);
	assertEquals(ended, ["kicked by the steward"]);
	let refused = false;
	try {
		behavior(gen.NOTIFY, [gen.ROOM_SENDER, "", gen.MEMBERSHIP_ENDED]);
	} catch {
		refused = true;
	}
	assertEquals(refused, true, "an empty reason is refused");
});

Deno.test("the registration id form is the directory's", () => {
	const cases: [string, boolean][] = [
		[REGISTRATION_ID, true],
		[REGISTRATION_ID.toUpperCase(), true],
		["00000000-0000-0000-8000-000000000001", false],
		["00000000-0000-4000-c000-000000000001", false],
		["not-a-registration-id", false],
	];
	for (const [value, valid] of cases) {
		assertEquals(gen.REGISTRATION_ID_PATTERN.test(value), valid, `${value} by the generated pattern`);
		assertEquals(isRegistrationId(value), valid, `${value} by the directory`);
	}
});
