// Registration commits identity and name together, without a callback acknowledgment.
import { type Behavior, Ref, type Session } from "@glowcap/runtime";
import { DirectoryRegistration } from "../lib/directory_registration.ts";
import { assert, assertEquals } from "./assert.ts";

const ID = "11111111-1111-4111-8111-111111111111";
function ref(): Ref {
	return Object.create(Ref.prototype) as Ref;
}
function fixture() {
	const released: Ref[] = [];
	const inboxes: Ref[] = [];
	let answer: () => Promise<unknown> = () => Promise.reject(new Error("no answer selected"));
	let sends = 0;
	const session = {
		spawn: (_behavior: Behavior) => {
			const inbox = ref();
			inboxes.push(inbox);
			return inbox;
		},
		release: (value: Ref) => released.push(value),
		send: () => {
			sends += 1;
			return answer();
		},
	} as unknown as Session;
	return {
		registration: new DirectoryRegistration(session, ref(), (value) => session.release(value), () => {}),
		released,
		inboxes,
		answer: (next: () => Promise<unknown>) => answer = next,
		sends: () => sends,
	};
}

Deno.test("registration acquires one committed identity without waiting for discovery", async () => {
	const f = fixture();
	const name = ref();
	f.answer(() => Promise.resolve(["alice", ID, name]));
	assertEquals(await f.registration.register("alice", "ocapn://alice.id"), ID);
	assert(f.released.includes(f.inboxes[0]), "the handed callback retires its local occurrence");
	assert(await f.registration.takeNameCapability() === name, "the acquired name remains owned until taken");
});

Deno.test("invalid registration returns its capabilities and preserves the predecessor", async () => {
	const f = fixture();
	const predecessor = ref();
	f.answer(() => Promise.resolve(["alice", ID, predecessor]));
	await f.registration.register("alice", "ocapn://alice.id");
	const refused = ref();
	f.answer(() => Promise.resolve(["alice-2", ID, refused]));
	const error = await f.registration.register("alice", "ocapn://alice.id").catch((error) => error);
	assert(error instanceof Error, "an exact nickname mismatch refuses acquisition");
	assert(f.released.includes(refused), "an invalid reply returns its acquired name");
	assert(!f.released.includes(predecessor), "the previously accepted name remains held");
	assert(await f.registration.takeNameCapability() === predecessor, "refusal preserves previous custody");
});

Deno.test("one replacement owns pending registration and synchronous refusal returns its inbox", async () => {
	const f = fixture();
	const predecessor = ref();
	f.answer(() => Promise.resolve(["alice", ID, predecessor]));
	await f.registration.register("alice", "ocapn://alice.id");
	let refuse!: (error: Error) => void;
	f.answer(() => new Promise((_, reject) => refuse = reject));
	const pending = f.registration.register("alice", "ocapn://alice.id");
	const busy = await f.registration.register("alice", "ocapn://alice.id").catch((error) => error);
	assert(busy instanceof Error, "a second replacement refuses before sending");
	assertEquals(f.sends(), 2);
	refuse(new Error("registration refused"));
	await pending.catch(() => {});
	f.answer(() => {
		throw new Error("marshal refusal");
	});
	const failed = await f.registration.register("alice", "ocapn://alice.id").catch((error) => error);
	assert(failed instanceof Error, "synchronous send failure is observed");
	assert(f.released.includes(f.inboxes.at(-1)!), "unsent callback custody is returned");
	assert(await f.registration.takeNameCapability() === predecessor, "both refusals preserve the prior name");
});
