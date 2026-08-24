import type { Behavior } from "@pancake/runtime";
import type { InboxPublisher } from "../lib/dm_inbox.ts";
import { DM } from "../lib/protocol.ts";
import type { Directory } from "../lib/room_client.ts";
import { IRC_FRONT_INBOX_ROUTE_LIMIT, IrcInboxRouter } from "../irc/front/inbox.ts";
import { assertEquals } from "./assert.ts";

function router(): IrcInboxRouter {
	const publisher = {
		offerer() {
			return { offer() {}, forget() {}, async close() {} };
		},
	} as InboxPublisher;
	return new IrcInboxRouter(publisher);
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
	const publisher: InboxPublisher = {
		offerer(opts) {
			return {
				offer(peer) {
					behaviors.push(opts.behaviorFor(peer));
				},
				forget() {},
				async close() {},
			};
		},
	};
	const routes = new IrcInboxRouter(publisher);
	const directory = {} as Directory;
	let firstCalls = 0;
	const first = routes.attach("alice", directory, () => firstCalls += 1, () => {});
	first.offer("bob");
	await first.detach();

	let secondCalls = 0;
	const second = routes.attach("alice", directory, () => secondCalls += 1, () => {});
	second.offer("bob");
	let oldRefusal = "";
	try {
		behaviors[0](DM, ["stale"]);
	} catch (error) {
		oldRefusal = String(error);
	}
	behaviors[1](DM, ["fresh"]);

	assertEquals(firstCalls, 0, "detached actor should not deliver");
	assertEquals(secondCalls, 1, "fresh actor should reach the reconnect");
	assertEquals(oldRefusal.includes("recipient disconnected"), true, oldRefusal);
	await second.detach();
});
