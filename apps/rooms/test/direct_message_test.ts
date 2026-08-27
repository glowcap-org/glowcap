import { type Behavior, Ref, type Session } from "@pancake/runtime";
import type { Directory } from "../lib/directory.ts";
import { DirectMessage } from "../lib/direct_message.ts";
import { DIRECT_READY, DM, HAND_ARCHIVE, HAND_ROOM, OFFER_ROOM, TYPING } from "../lib/protocol.ts";
import { type DirectRealizationCallbacks, establishRequestedDirectRoute } from "../session/directory_directs.ts";
import { DirectConversationRouteAttempt } from "../session/direct_route_attempt.ts";
import type { LiveDirectory } from "../session/live.ts";
import { registrationId } from "./support/registration.ts";

const PEER_REGISTRATION = registrationId(1);

function assert(condition: unknown, message: string): asserts condition {
	if (!condition) throw new Error(message);
}

Deno.test("a direct line construction failure retires its redeemed authority", async () => {
	const dm = {} as Ref;
	const released: Ref[] = [];
	let closed = 0;
	const via = {
		spawn(): Ref {
			throw new Error("reply export refused");
		},
		release(ref: Ref): void {
			released.push(ref);
		},
		close(): Promise<void> {
			closed++;
			return Promise.resolve();
		},
	} as unknown as Session;
	const directory = {
		session: via,
		introduceVia(): Promise<{ dm: Ref; via: Session }> {
			return Promise.resolve({ dm, via });
		},
	} as unknown as Directory;

	let refused = "";
	await DirectMessage.open(directory, "peer", { message: () => null }, PEER_REGISTRATION).catch((error) => {
		refused = error instanceof Error ? error.message : String(error);
	});
	assert(refused.includes("reply export refused"), "the construction error was not preserved");
	assert(released.length === 1 && released[0] === dm, "the imported DM occurrence was not released");
	assert(closed === 1, "the otherwise-unowned redeemed session was not closed");
});

Deno.test("a direct reply capability implements the complete inbox protocol", async () => {
	const ref = (): Ref => Object.create(Ref.prototype) as Ref;
	const dm = ref();
	const room = ref();
	const archive = ref();
	const reciprocal = ref();
	let reply!: Behavior;
	const via = {
		spawn(behavior: Behavior): Ref {
			reply = behavior;
			return ref();
		},
		close: () => Promise.resolve(),
	} as unknown as Session;
	const directory = {
		session: via,
		introduceVia: () => Promise.resolve({ dm, via }),
	} as unknown as Directory;
	const received: string[] = [];
	const line = await DirectMessage.open(directory, "peer", {
		message: (text) => {
			received.push(`message:${text}`);
			return null;
		},
		ready: (_session, replyRoute) => {
			received.push(`ready:${replyRoute === reciprocal}`);
		},
		typing: (on) => received.push(`typing:${on}`),
		handRoom: (label, handed) => {
			received.push(`hand-room:${label}:${handed === room}`);
		},
		offerRoom: (label, link) => {
			received.push(`offer-room:${label}:${link}`);
		},
		handArchive: (directoryId, conversation, handed) => {
			received.push(`archive:${directoryId}:${conversation}:${handed === archive}`);
		},
	}, PEER_REGISTRATION);
	await reply(DM, ["hello"]);
	await reply(DIRECT_READY, [reciprocal]);
	await reply(TYPING, [true]);
	await reply(HAND_ROOM, ["plans", room]);
	await reply(OFFER_ROOM, ["lobby", "ocapn://room.test/s/link"]);
	await reply(HAND_ARCHIVE, ["directory", "conversation", archive]);
	assert(
		JSON.stringify(received) === JSON.stringify([
			"message:hello",
			"ready:true",
			"typing:true",
			"hand-room:plans:true",
			"offer-room:lobby:ocapn://room.test/s/link",
			"archive:directory:conversation:true",
		]),
		"the direct reply capability did not dispatch one inbox protocol",
	);
	await line.close();
});

Deno.test("an unsupported direct capability is returned before refusal", async () => {
	const ref = (): Ref => Object.create(Ref.prototype) as Ref;
	const handed = ref();
	const extra = ref();
	const released: Ref[] = [];
	let reply!: Behavior;
	const via = {
		spawn(behavior: Behavior): Ref {
			reply = behavior;
			return ref();
		},
		release(capability: Ref): void {
			released.push(capability);
		},
		close: () => Promise.resolve(),
	} as unknown as Session;
	const directory = {
		session: via,
		introduceVia: () => Promise.resolve({ dm: ref(), via }),
	} as unknown as Directory;
	const line = await DirectMessage.open(directory, "peer", { message: () => null }, PEER_REGISTRATION);
	let refused = "";
	try {
		await reply(HAND_ROOM, ["plans", handed, extra]);
	} catch (error) {
		refused = error instanceof Error ? error.message : String(error);
	}
	assert(refused.includes("handed room needs"), "the malformed direct verb was not refused");
	assert(
		released.length === 2 && released[0] === handed && released[1] === extra,
		"the malformed direct call did not return every capability occurrence",
	);
	const malformedText = ref();
	refused = "";
	try {
		await reply(DM, [malformedText]);
	} catch (error) {
		refused = error instanceof Error ? error.message : String(error);
	}
	assert(refused.includes("text value"), "a capability in the message text position was not refused");
	assert(released.at(-1) === malformedText, "the malformed message text capability was not returned");
	await line.close();
});

Deno.test("a direct refusal releases each capability occurrence at most once", async () => {
	const ref = (): Ref => Object.create(Ref.prototype) as Ref;
	const attachment = ref();
	const unexpected = ref();
	const released: Ref[] = [];
	let reply!: Behavior;
	const via = {
		spawn(behavior: Behavior): Ref {
			reply = behavior;
			return ref();
		},
		release(capability: Ref): void {
			released.push(capability);
			if (capability === unexpected) throw new Error("unexpected release failed");
		},
		close: () => Promise.resolve(),
	} as unknown as Session;
	const directory = {
		session: via,
		introduceVia: () => Promise.resolve({ dm: ref(), via }),
	} as unknown as Directory;
	const line = await DirectMessage.open(directory, "peer", { message: () => null }, PEER_REGISTRATION);
	let refused = "";
	try {
		await reply(DM, ["file", "file", "a.txt", "text/plain", 1n, attachment, 0n, 0n, unexpected]);
	} catch (error) {
		refused = error instanceof Error ? error.message : String(error);
	}
	assert(refused.includes("unexpected capability"), "the cleanup failure did not refuse the direct call");
	assert(
		released.filter((capability) => capability === unexpected).length === 1,
		"the failed unexpected occurrence was released more than once",
	);
	assert(
		released.filter((capability) => capability === attachment).length === 1,
		"the otherwise-adoptable attachment was not returned exactly once",
	);
	await line.close();
});

Deno.test("an adopted direct route releases its capability without closing the shared session", async () => {
	const route = Object.create(Ref.prototype) as Ref;
	const released: Ref[] = [];
	let closed = 0;
	const session = {
		release(capability: Ref): void {
			released.push(capability);
		},
		close(): Promise<void> {
			closed += 1;
			return Promise.resolve();
		},
	} as unknown as Session;
	await DirectMessage.adopt(session, route, "peer", PEER_REGISTRATION).close();
	assert(released.length === 1 && released[0] === route, "the adopted route was not released exactly once");
	assert(closed === 0, "closing an adopted route closed a peer-owned shared session");
});

Deno.test("a reciprocal request uses an already-live durable direct route", async () => {
	let established = 0;
	const held = {
		directConversationByRegistration: new Map([[PEER_REGISTRATION, "conversation"]]),
		directs: new Map([["conversation", {
			line: {
				live: true,
				establishReplyRoute: () => {
					established += 1;
					return Promise.resolve();
				},
			},
		}]]),
	} as unknown as LiveDirectory;
	await establishRequestedDirectRoute(held, PEER_REGISTRATION, {} as DirectRealizationCallbacks);
	assert(established === 1, "the live route was mistaken for an answered reciprocal request");
});

Deno.test("canceling one direct-route opening joins its in-flight cleanup", async () => {
	const opening = new DirectConversationRouteAttempt("peer topology");
	const work = Promise.withResolvers<void>();
	let cleaned = false;
	opening.trackOpening(work.promise.then(() => {
		cleaned = true;
	}));
	const observed = opening.promise.then(
		() => "resolved",
		(error) => error instanceof Error ? error.message : String(error),
	);
	let canceled = false;
	const canceling = opening.directoryClosed().then(() => {
		canceled = true;
	});
	await Promise.resolve();
	assert(!canceled, "direct-route cancellation returned before its work settled");
	work.resolve();
	await canceling;
	assert(cleaned, "direct-route cancellation did not join its cleanup");
	assert(
		(await observed).includes("directory connection ended"),
		"direct-route waiters did not receive the directory closure",
	);
});
