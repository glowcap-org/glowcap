/// <reference lib="dom" />

// A pending live room offer cannot outlive the direct session that owns it.

import { Ref, type Session } from "@pancake/runtime";

Object.defineProperty(globalThis, "matchMedia", {
	configurable: true,
	value: () => ({ matches: false, addEventListener() {}, removeEventListener() {} }),
});

const { assertEquals } = await import("./assert.ts");
const { handedRoom, takeHandedRoom } = await import("../web/ui/net/direct_offers.ts");
const { RoomsPage } = await import("../web/ui/page.ts");
const { dirId } = await import("../web/ui/types.ts");
const store = await import("../web/ui/store.ts");
type Live = import("../web/ui/net/live.ts").Live;

Deno.test("closing a direct route retires its pending handed room", () => {
	const page = new RoomsPage();
	const id = dirId("directory");
	const home = { id, page } as Live;
	page.live.dirs.set(id, home);
	let close = () => {};
	let releases = 0;
	const owner = {
		onClose: (callback: () => void) => {
			close = callback;
			return () => {};
		},
		release: () => releases += 1,
	} as unknown as Session;
	const room = Object.create(Ref.prototype) as Ref;
	try {
		assertEquals(handedRoom(home, owner, "plans", room, "bo"), true);
		const invitation = page.projection.get().invites[0];
		assertEquals(invitation?.way, "handed");
		close();
		assertEquals(page.projection.get().invites, []);
		assertEquals(takeHandedRoom(page, invitation.id), null);
		assertEquals(releases, 0);
	} finally {
		page.live.dirs.delete(id);
		for (const invitation of page.projection.get().invites) store.dropInvite(page.projection, invitation.id);
	}
});
