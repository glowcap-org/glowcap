import { applyPresenceEvent, parsePresenceEvent } from "./presence.ts";

function assert(condition: unknown, message: string): asserts condition {
	if (!condition) throw new Error(message);
}

function assertEquals<T>(actual: T, expected: T): void {
	const actualText = JSON.stringify(actual);
	const expectedText = JSON.stringify(expected);
	if (actualText !== expectedText) {
		throw new Error(`expected ${expectedText}, got ${actualText}`);
	}
}

Deno.test("presence parser recognizes room roster messages", () => {
	assertEquals(
		parsePresenceEvent("welcome ada — 3 in the room: ada, grace, alan"),
		{
			kind: "roster",
			names: ["ada", "grace", "alan"],
		},
	);
	assertEquals(parsePresenceEvent("grace joined (4 here)"), {
		kind: "join",
		name: "grace",
	});
	assertEquals(parsePresenceEvent("alan left (2 here)"), {
		kind: "leave",
		name: "alan",
	});
	assertEquals(parsePresenceEvent("not a roster event"), null);
});

Deno.test("presence state tracks online and recently offline members", () => {
	const members = new Map<string, boolean>();
	applyPresenceEvent(members, { kind: "roster", names: ["ada", "grace"] });
	applyPresenceEvent(members, { kind: "leave", name: "grace" });
	applyPresenceEvent(members, { kind: "join", name: "alan" });

	assert(members.get("ada") === true, "ada should still be online");
	assert(members.get("grace") === false, "grace should be retained as offline");
	assert(members.get("alan") === true, "alan should be online");
});
