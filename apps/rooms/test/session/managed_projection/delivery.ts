// The delivery owner validates once before transferring its carrier and handles.
import { assert, assertEquals } from "../../assert.ts";
import { ActivityDelivery, releaseActivity } from "../../../web/ui/session/managed/activity.ts";
import { assertThrows } from "@std/assert";
import type { RoomsManagedFile } from "../../../../../zig-out/wasm/rooms/rooms_browser.js";
import * as store from "../../../web/ui/store.ts";
import { fixture } from "./fixture.ts";

Deno.test("managed activity validates its notice once and preserves its carrier and handles", () => {
	let reads = 0;
	let released = 0;
	const file = { free: () => released++ } as unknown as RoomsManagedFile;
	const raw = {
		cursor: "original",
		event: {
			at: 0,
			target: { kind: "directory" as const, id: "directory" },
			notice: {
				kind: "mintInboxFor",
				get registration() {
					reads++;
					return "registration";
				},
				opening: "opening",
			},
			files: [file],
		},
	};
	const event = raw.event;
	const delivery = new ActivityDelivery(raw, false);
	const page = delivery.take();
	assert(page === raw, "the carrier is transferred without cloning");
	assert(page.event === event, "the event is transferred without cloning");
	assert(page.event?.files?.[0] === file, "transient handle identity is preserved");
	assertEquals(reads, 1, "transferring the carrier must not revalidate its notice");
	assertThrows(() => delivery.take(), Error, "already transferred custody");
	delivery.close();
	assertEquals(released, 0);
	releaseActivity(page);
	assertEquals(released, 1);
});

for (const notice of [null, { kind: "futureNotice" }, { kind: "line", text: 42 }]) {
	Deno.test(`managed activity ignores an unsupported notice and still releases its files: ${JSON.stringify(notice)}`, () => {
		const f = fixture();
		let released = 0;
		const delivery = new ActivityDelivery({
			cursor: "1",
			event: {
				at: 0,
				target: { kind: "room", id: "conversation" },
				notice,
				files: [{ free: () => released++ } as unknown as RoomsManagedFile],
			},
		}, false);
		try {
			const page = delivery.take();
			assertEquals(page.event?.notice, null);
			try {
				f.projection.activity(page, false);
				assertEquals(store.historyOf(f.page.projection, f.selected().key), []);
			} finally {
				releaseActivity(page);
			}
		} finally {
			delivery.close();
			f.close();
		}
		assertEquals(released, 1);
	});
}
