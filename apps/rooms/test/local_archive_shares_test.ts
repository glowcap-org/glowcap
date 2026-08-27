/// <reference lib="dom" />

import { type Ref, type Session } from "@pancake/runtime";
import type { Live } from "../web/ui/net/live.ts";
import { assertEquals } from "./assert.ts";
import { registrationId } from "./support/registration.ts";

Object.defineProperty(globalThis, "matchMedia", {
	configurable: true,
	value: () => ({ matches: false, addEventListener() {}, removeEventListener() {} }),
});
Object.defineProperty(globalThis, "localStorage", {
	configurable: true,
	value: { getItem: () => null, setItem() {}, removeItem() {} },
});

const store = await import("../web/ui/store.ts");
const { dropArchiveShare, receiveArchiveShare } = await import("../web/ui/net/archive_shares.ts");
const { dirs } = await import("../web/ui/net/live.ts");
const { dirId } = await import("../web/ui/types.ts");

Deno.test("a local archive share uses the sender's persisted conversation identity", () => {
	const directory = dirId("directory");
	store.set({
		...store.initial,
		dirs: new Map([[
			directory,
			{
				id: directory,
				locator: "127.0.0.1:1",
				liveRooms: new Map(),
				dmablePeers: new Map(),
				requestedNick: "ada",
				nick: "ada",
				slot: 1,
				reached: true,
				session: "connected",
				statusText: "",
				dmUnreachable: "",
				standing: null,
			},
		]]),
		homeDir: directory,
		convs: new Map(),
		drafts: new Map(),
	});
	const home = { id: directory } as Live;
	dirs.set(directory, home);
	const released: Ref[] = [];
	const owner = {
		sessionOpen: true,
		onClose: () => () => {},
		release: (ref: Ref) => released.push(ref),
	} as unknown as Session;
	const archive = {} as Ref;
	try {
		receiveArchiveShare(
			home,
			owner,
			directory,
			"sender-persisted-direct",
			archive,
			"bo",
			registrationId(1),
		);
		const share = store.get().archiveShares[0];
		assertEquals(share?.from, "bo");
		const conversation = share == null ? null : store.getConv(share.conversationKey);
		assertEquals(conversation?.type === "dm" ? conversation.peerRegistrationId : null, registrationId(1));
		if (share == null) throw new Error("the local archive share was not retained");
		dropArchiveShare(share.id);
		assertEquals(released, [archive]);
	} finally {
		dirs.delete(directory);
		store.set(store.initial);
	}
});
