// The signaling reply capability admits only its bounded vocabulary and returns unexpected capabilities.
import { type Behavior, Ref, type Session } from "@glowcap/runtime";
import { DirectorySignaling } from "../lib/directory_signal.ts";
import { SIG_ACCEPTED } from "../lib/protocol.ts";
import { assertEquals } from "./assert.ts";

function ref(): Ref {
	return Object.create(Ref.prototype) as Ref;
}

Deno.test("a signaling reply capability admits exact data and returns unexpected capabilities", () => {
	let replyBehavior: Behavior | null = null;
	const released: Ref[] = [];
	const reply = ref();
	const session = {
		spawn: (behavior: Behavior) => {
			replyBehavior = behavior;
			return reply;
		},
		release: (capability: Ref) => released.push(capability),
	} as unknown as Session;
	const signaling = new DirectorySignaling(session, ref(), () => {}, () => session);
	const stop = signaling.onSignalCandidate("peer", () => {});
	if (replyBehavior == null) throw new Error("the signaling exchange did not mint a reply capability");
	const refused = (verb: string, args: Parameters<Behavior>[1]): boolean => {
		try {
			replyBehavior?.(verb, args);
			return false;
		} catch {
			return true;
		}
	};
	assertEquals(refused(SIG_ACCEPTED, ["exchange", "surplus"]), true);
	assertEquals(refused("unknown", []), true);
	const unexpected = ref();
	assertEquals(refused("unknown", [unexpected]), true);
	assertEquals(released, [unexpected]);
	stop();
});
