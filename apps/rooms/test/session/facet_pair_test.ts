import { Ref, type Session } from "@pancake/runtime";
import { spawnFacetPair } from "../../session/facet_pair.ts";
import { assertEquals } from "../assert.ts";

function ref(): Ref {
	return Object.create(Ref.prototype) as Ref;
}

Deno.test("ephemeral session facet creation releases its first half when revoker spawn fails", () => {
	const delegated = ref();
	const released: Ref[] = [];
	let spawns = 0;
	const session = {
		spawn: () => {
			spawns += 1;
			if (spawns === 1) return delegated;
			throw new Error("revoker spawn failed");
		},
		release: (capability: Ref) => released.push(capability),
	} as unknown as Session;
	let refusal = "";
	try {
		spawnFacetPair(session, () => null, () => null);
	} catch (error) {
		refusal = error instanceof Error ? error.message : String(error);
	}
	assertEquals(refusal, "revoker spawn failed");
	assertEquals(released, [delegated]);
});

Deno.test("ephemeral session facet creation transfers both successful occurrences", () => {
	const capabilities = [ref(), ref()];
	const session = {
		spawn: () => {
			const capability = capabilities.shift();
			if (capability == null) throw new Error("test session exhausted its capabilities");
			return capability;
		},
	} as unknown as Session;
	const pair = spawnFacetPair(session, () => null, () => null);
	assertEquals(pair.length, 2);
});
