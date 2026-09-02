/// <reference lib="dom" />

import { DURABLE_SWISS_ENTROPY_BYTES, parseLocator, type Ref, type Session } from "@glowcap/runtime";
import type { Live } from "../web/ui/net/live.ts";
import { formatRoomsSturdyref } from "../lib/locator.ts";
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
const {
	dropArchiveShare,
	receiveArchiveShare,
	receiveDurableArchiveOffer,
	releaseArchiveSharesForConversation,
} = await import("../web/ui/net/archive_shares.ts");
const { RoomsPage } = await import("../web/ui/page.ts");
const { dirId } = await import("../web/ui/types.ts");

function shareSturdyref(): string {
	return formatRoomsSturdyref(
		parseLocator("ocapn://127.0.0.1%3A9000.tcp"),
		new Uint8Array(DURABLE_SWISS_ENTROPY_BYTES).fill(0x5a),
	);
}

function localShareHome(): { page: InstanceType<typeof RoomsPage>; home: Live; directory: ReturnType<typeof dirId> } {
	const page = new RoomsPage();
	const directory = dirId("directory");
	page.projection.set({
		...store.initialState(),
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
	const home = { id: directory, page } as Live;
	page.live.dirs.set(directory, home);
	return { page, home, directory };
}

function ownerTracking(released: Ref[]): Session {
	return {
		sessionOpen: true,
		onClose: () => () => {},
		release: (ref: Ref) => released.push(ref),
	} as unknown as Session;
}

Deno.test("a local archive share uses the sender's persisted conversation identity", () => {
	const { page, home, directory } = localShareHome();
	const released: Ref[] = [];
	const archive = {} as Ref;
	try {
		receiveArchiveShare(
			home,
			ownerTracking(released),
			directory,
			"direct",
			"sender-persisted-direct",
			archive,
			"bo",
			registrationId(1),
		);
		const share = page.projection.get().archiveShares[0];
		assertEquals(share?.from, "bo");
		const conversation = share == null ? null : store.getConv(page.projection, share.conversationKey);
		assertEquals(conversation?.type === "dm" ? conversation.peerRegistrationId : null, registrationId(1));
		if (share == null) throw new Error("the local archive share was not retained");
		dropArchiveShare(page, share.id);
		assertEquals(released, [archive]);
	} finally {
		page.live.dirs.delete(directory);
		page.projection.reset();
	}
});

Deno.test("a local room archive share lands on the carrying DM without requiring that DM's persist id", () => {
	const { page, home, directory } = localShareHome();
	const released: Ref[] = [];
	const archive = {} as Ref;
	try {
		receiveArchiveShare(
			home,
			ownerTracking(released),
			directory,
			"room",
			"lobby",
			archive,
			"bo",
			registrationId(1),
		);
		const share = page.projection.get().archiveShares[0];
		assertEquals(share?.kind, "room");
		assertEquals(share?.scopeConversation, "lobby");
		assertEquals(share?.custody, "live");
		const conversation = share == null ? null : store.getConv(page.projection, share.conversationKey);
		assertEquals(conversation?.type === "dm" ? conversation.peerRegistrationId : null, registrationId(1));
		if (share == null) throw new Error("the local room archive share was not retained");
		dropArchiveShare(page, share.id);
		assertEquals(released, [archive]);
	} finally {
		page.live.dirs.delete(directory);
		page.projection.reset();
	}
});

Deno.test("a local durable archive offer survives closing the carrying DM", () => {
	const { page, home, directory } = localShareHome();
	try {
		receiveDurableArchiveOffer(
			home,
			directory,
			"room",
			"lobby",
			shareSturdyref(),
			"bo",
			registrationId(1),
		);
		const share = page.projection.get().archiveShares[0];
		assertEquals(share?.custody, "durable");
		assertEquals(share?.kind, "room");
		assertEquals(share?.scopeConversation, "lobby");
		if (share == null) throw new Error("the durable archive offer was not retained");
		releaseArchiveSharesForConversation(page, share.conversationKey);
		assertEquals(page.projection.get().archiveShares.map((row) => row.id), [share.id]);
		dropArchiveShare(page, share.id);
		assertEquals(page.projection.get().archiveShares, []);
	} finally {
		page.live.dirs.delete(directory);
		page.projection.reset();
	}
});

Deno.test("a local durable archive offer refuses a malformed sturdyref", () => {
	const { page, home, directory } = localShareHome();
	let refused = false;
	try {
		receiveDurableArchiveOffer(
			home,
			directory,
			"direct",
			"sender-persisted-direct",
			"ocapn://archive.test/s/share",
			"bo",
			registrationId(1),
		);
	} catch {
		refused = true;
	} finally {
		page.live.dirs.delete(directory);
		page.projection.reset();
	}
	assertEquals(refused, true);
	assertEquals(page.projection.get().archiveShares, []);
});
