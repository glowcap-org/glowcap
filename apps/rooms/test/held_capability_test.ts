import type { Ref, Session } from "@pancake/runtime";
import { releaseHeldCapability } from "../web/ui/net/held_capability.ts";
import { dirId } from "../web/ui/types.ts";
import { assertEquals } from "./assert.ts";

Deno.test("a local operations hold releases its exact occurrence and reports refusal", () => {
	const capability = {} as Ref;
	const released: Ref[] = [];
	const session = {
		release: (ref: Ref) => {
			released.push(ref);
			throw new Error("release refused");
		},
	} as unknown as Session;
	const originalError = console.error;
	const errors: string[] = [];
	console.error = (message) => errors.push(String(message));
	try {
		releaseHeldCapability({ session, cap: capability, dir: dirId("directory") }, "test capability release failed");
	} finally {
		console.error = originalError;
	}
	assertEquals(released, [capability]);
	assertEquals(errors.some((message) => message.includes("release refused")), true);
});
