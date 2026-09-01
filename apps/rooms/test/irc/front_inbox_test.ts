import { type Behavior, Ref, type Session } from "@pancake/runtime";
import type { InboxPublisher } from "../../lib/dm_inbox.ts";
import { DM } from "../../lib/protocol.ts";
import type { Directory } from "../../lib/room/client.ts";
import { IRC_FRONT_INBOX_ROUTE_LIMIT, IrcInboxRouter } from "../../irc/front/inbox.ts";
import { assertEquals } from "../assert.ts";
import { registrationId } from "../support/registration.ts";

function router(): IrcInboxRouter {
	const publisher = {
		offerer() {
			return { offer() {}, forget() {}, async close() {} };
		},
	} as InboxPublisher;
	return new IrcInboxRouter(publisher, () => ({} as Session));
}

Deno.test("IRC inbox routes retire disconnected names instead of growing with churn", async () => {
	const routes = router();
	const directory = {} as Directory;
	for (let at = 0; at < IRC_FRONT_INBOX_ROUTE_LIMIT * 3; at += 1) {
		const attached = routes.attach(`nick-${at}`, directory, () => {}, () => {});
		await attached.detach();
	}
});

Deno.test("IRC inbox routes keep every active client and refuse the next", () => {
	const routes = router();
	const directory = {} as Directory;
	for (let at = 0; at < IRC_FRONT_INBOX_ROUTE_LIMIT; at += 1) {
		routes.attach(`nick-${at}`, directory, () => {}, () => {});
	}
	let refused = "";
	try {
		routes.attach("one-too-many", directory, () => {}, () => {});
	} catch (error) {
		refused = String(error);
	}
	assertEquals(refused.includes(`${IRC_FRONT_INBOX_ROUTE_LIMIT} active inbox routes`), true, refused);
});

Deno.test("an IRC nick reconnect never retargets its old inbox capability", async () => {
	const behaviors: Behavior[] = [];
	const released: Ref[] = [];
	const session = { release: (capability: Ref) => released.push(capability) } as unknown as Session;
	const publisher: InboxPublisher = {
		offerer(opts) {
			return {
				offer(peer, peerRegistrationId) {
					behaviors.push(opts.behaviorFor(peer, peerRegistrationId));
				},
				forget() {},
				async close() {},
			};
		},
	};
	const routes = new IrcInboxRouter(publisher, () => session);
	const directory = {} as Directory;
	let firstCalls = 0;
	const first = routes.attach("alice", directory, () => {
		firstCalls += 1;
	}, () => {});
	first.offer("bob", registrationId(1));
	const unexpected = Object.create(Ref.prototype) as Ref;
	let unsupported = false;
	try {
		behaviors[0]("unknown", [unexpected]);
	} catch {
		unsupported = true;
	}
	assertEquals(unsupported, true);
	assertEquals(released, [unexpected]);
	await first.detach();

	let secondCalls = 0;
	const second = routes.attach("alice", directory, () => {
		secondCalls += 1;
	}, () => {});
	second.offer("bob", registrationId(2));
	let oldRefusal = "";
	try {
		await behaviors[0](DM, ["stale"]);
	} catch (error) {
		oldRefusal = String(error);
	}
	await behaviors[1](DM, ["fresh"]);

	assertEquals(firstCalls, 0, "detached actor should not deliver");
	assertEquals(secondCalls, 1, "fresh actor should reach the reconnect");
	assertEquals(oldRefusal.includes("recipient disconnected"), true, oldRefusal);
	await second.detach();
});

Deno.test("an IRC inbox reports asynchronous delivery failure to the direct sender", async () => {
	let behavior!: Behavior;
	const publisher: InboxPublisher = {
		offerer(options) {
			return {
				offer(peer, peerRegistrationId) {
					behavior = options.behaviorFor(peer, peerRegistrationId);
				},
				forget() {},
				async close() {},
			};
		},
	};
	const routes = new IrcInboxRouter(publisher, () => ({} as Session));
	const attached = routes.attach(
		"alice",
		{} as Directory,
		() => Promise.reject(new Error("IRC socket write failed")),
		() => {},
	);
	attached.offer("bob", registrationId(1));
	let refused = "";
	try {
		await behavior(DM, ["hello"]);
	} catch (error) {
		refused = error instanceof Error ? error.message : String(error);
	}
	assertEquals(refused, "IRC socket write failed");
	await attached.detach();
});
