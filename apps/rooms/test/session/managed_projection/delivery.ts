// The delivery owner validates once before readiness and presentation share it.
import { assert, assertEquals } from "../../assert.ts";
import { ActivityDelivery, releaseActivity } from "../../../web/ui/session/managed/activity.ts";
import { ReadinessNotices } from "../../../web/ui/session/managed/readiness.ts";
import type { RoomsManagedFile } from "../../../../../zig-out/wasm/rooms/rooms_browser.js";
import * as store from "../../../web/ui/store.ts";
import { fixture } from "./fixture.ts";

Deno.test("managed activity shares one validated notice and preserves its carrier and handles", async () => {
	let reads = 0;
	let released = 0;
	const file = { free: () => released++ } as unknown as RoomsManagedFile;
	const raw = {
		cursor: "original",
		event: {
			target: { kind: "directory" as const, id: "directory" },
			notice: {
				kind: "introducible",
				get registration() {
					reads++;
					return "registration";
				},
				opening: "opening",
			},
			files: [file],
		},
	};
	const delivery = new ActivityDelivery(raw);
	const event = delivery.event!;
	const notices = new ReadinessNotices();
	const waits = Array.from({ length: 32 }, () =>
		notices.wait((offered) => {
			assert(offered.notice === event.notice, "all readiness consumers share the parsed notice");
			return offered.notice?.kind === "introducible" && offered.notice.registration === "registration";
		}));
	notices.notify(event);
	await Promise.all(waits.map((wait) => wait.ready));
	const page = delivery.take();
	assert(page === raw, "the carrier is transferred without cloning");
	assert(page.event === event, "the event is transferred without cloning");
	assert(page.event?.files?.[0] === file, "transient handle identity is preserved");
	assertEquals(reads, 1, "32 waiters must not revalidate the notice");
	assertEquals(delivery.event, undefined, "the reader no longer exposes transferred custody");
	delivery.close();
	assertEquals(released, 0);
	releaseActivity(page);
	assertEquals(released, 1);
	notices.close();
});

for (const notice of [null, { kind: "futureNotice" }, { kind: "line", text: 42 }]) {
	Deno.test(`managed activity ignores an unsupported notice and still releases its files: ${JSON.stringify(notice)}`, () => {
		const f = fixture();
		let released = 0;
		const delivery = new ActivityDelivery({
			cursor: "1",
			event: {
				target: { kind: "room", id: "conversation" },
				notice,
				files: [{ free: () => released++ } as unknown as RoomsManagedFile],
			},
		});
		try {
			assertEquals(delivery.event?.notice, null);
			const page = delivery.take();
			try {
				f.projection.activity(page);
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
