import { PSet, PStruct, Ref, type Session, Tagged } from "@pancake/runtime";
import { hasCapabilityArguments, releaseCapabilityArguments } from "../lib/argument_custody.ts";
import { ROOMS_SESSION_FILES } from "../lib/session/client.ts";
import { admitSessionFacetArguments, takeSessionObserver } from "../session/facet_arguments.ts";
import { assertEquals } from "./assert.ts";

function ref(): Ref {
	return Object.create(Ref.prototype) as Ref;
}

Deno.test("argument custody finds and releases nested capability occurrences", () => {
	const direct = ref();
	const inSet = ref();
	const inTag = ref();
	const inStruct = ref();
	const args = [
		direct,
		new PSet([inSet]),
		new Tagged("held", [inTag]),
		new PStruct([["capability", inStruct]]),
	];
	assertEquals(hasCapabilityArguments(args), true);
	const released: Ref[] = [];
	const session = { release: (capability: Ref) => released.push(capability) } as unknown as Session;
	assertEquals(releaseCapabilityArguments(session, args, new Set([inTag])), null);
	assertEquals(released.includes(direct), true);
	assertEquals(released.includes(inSet), true);
	assertEquals(released.includes(inTag), false);
	assertEquals(released.includes(inStruct), true);
});

Deno.test("session facet admission rejects nested refs except on capability-bearing verbs", () => {
	const nested = ref();
	const args = [new PStruct([["nested", new Tagged("capability", [nested])]])];
	const released: Ref[] = [];
	const session = { release: (capability: Ref) => released.push(capability) } as unknown as Session;
	let refused = false;
	try {
		admitSessionFacetArguments(session, "snapshot", args);
	} catch {
		refused = true;
	}
	assertEquals(refused, true);
	assertEquals(released, [nested]);
	admitSessionFacetArguments(session, ROOMS_SESSION_FILES, args);
	assertEquals(released, [nested]);
});

Deno.test("session watch adopts exactly one observer or releases every occurrence", () => {
	const first = ref();
	const second = ref();
	const released: Ref[] = [];
	const session = { release: (capability: Ref) => released.push(capability) } as unknown as Session;
	let refused = false;
	try {
		takeSessionObserver(session, [first, second]);
	} catch {
		refused = true;
	}
	assertEquals(refused, true);
	assertEquals(released, [first, second]);
	assertEquals(takeSessionObserver(session, [first]), first);
	assertEquals(released, [first, second]);
});
