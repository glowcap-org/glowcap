// Late server admission remains owned, but cannot turn cancellation into a join.
/// <reference lib="dom" />
import { assertEquals } from "../assert.ts";
import { deferred, snapshot, viewer } from "../support/managed_viewer.ts";
import { initializeApplication } from "../support/application.ts";
import { OPEN_ROOM_POLICY } from "../../lib/room/policy.ts";
import type { RoomsManagedCommand } from "../../../../zig-out/wasm/rooms/rooms_browser.js";

Object.defineProperty(globalThis, "matchMedia", {
	configurable: true,
	value: () => ({ matches: false, addEventListener() {}, removeEventListener() {} }),
});
await initializeApplication();
const { RoomsPage } = await import("../../web/ui/page.ts");
const { ManagedProjection } = await import("../../web/ui/session/managed/projection.ts");
const { presentationFiles } = await import("../../web/ui/session/managed/files.ts");
const { room, fixture } = await import("./managed_projection/fixture.ts");
const store = await import("../../web/ui/store.ts");

for (const owner of ["acquisition", "creation"] as const) {
	for (const cleanup of ["delayed", "refused"] as const) {
		Deno.test(`cancelled ${owner} never presents late membership with ${cleanup} cleanup`, async () => {
			const current = snapshot();
			current.intent.directories.push({
				id: "directory",
				access: "access",
				home: true,
				nick: "ada",
				nickAllocation: "exact",
				standing: null,
			});
			current.intent.conversations.push(room());
			current.intent.active = "conversation";
			const admitted = deferred<void>(), reply = deferred<void>();
			const departing = deferred<void>(), releaseDeparture = deferred<void>();
			let late = "", admissions = 0, departures = 0;
			const session = viewer({
				snapshot: () => Promise.resolve(structuredClone(current)),
				preparePublicRoom: (_revision: string, raw: string) => {
					const row = JSON.parse(raw);
					late = row.id;
					return Promise.resolve({
						submit: async () => {
							admissions++;
							admitted.resolve();
							await reply.promise;
							current.intent.conversations.push({ ...room(), ...row, seat: "late-seat" });
							current.revision = "2";
							return "committed";
						},
						free() {},
					});
				},
				prepareCommand: (id: string, revision: string, name: string, args: string[]) => {
					if (name === "openManagedRoom") late = id;
					else departures++;
					return Promise.resolve({
						originalIntent: () => [id, Number(revision), name, args],
						submit: async () => {
							if (name === "openManagedRoom") {
								admissions++;
								admitted.resolve();
								await reply.promise;
							}
							return "committed";
						},
						status: () => Promise.resolve("committed"),
						free() {},
					} as unknown as RoomsManagedCommand);
				},
			});
			session.completeResult = async (operation) => {
				const [, , name, args] = operation.request.originalIntent();
				if (name === "openManagedRoom") {
					current.intent.conversations.push({ ...room(), id: late, name: "late-room", seat: "late-seat" });
					current.revision = "2";
					session.finish(operation);
					await session.refresh();
				} else {
					departing.resolve();
					if (cleanup === "refused") throw new Error("departure unavailable");
					await releaseDeparture.promise;
					current.intent.conversations = current.intent.conversations.filter((row) => row.id !== args[0]);
					current.revision = "3";
					session.finish(operation);
					await session.refresh();
				}
			};
			const page = new RoomsPage();
			const files = presentationFiles(page.projection, () => null);
			const projection = new ManagedProjection(page, session, files, () => {}, () => {});
			const seen: string[][] = [];
			const stop = session.subscribe(() => {
				projection.apply();
				seen.push([...page.projection.get().convs.values()].map((row) => row.key));
			});
			const cancel = new AbortController();
			try {
				await session.refresh();
				const previous = store.activeConv(page.projection)!.key;
				const outcome = Promise.allSettled([session.openings.run(
					async (opening) => {
						const id = owner === "acquisition"
							? await session.actions.publicRoom("directory", "late-room", "publication", opening)
							: await session.actions.createRoom("directory", "late-room", OPEN_ROOM_POLICY, opening);
						await opening.select(id);
					},
					null,
					cancel.signal,
				)]);
				await admitted.promise;
				cancel.abort();
				reply.resolve();
				await departing.promise;
				await session.refresh();
				assertEquals(current.intent.conversations.some((row) => row.id === late), true);
				assertEquals(store.convByPersistId(page.projection, late), null);
				assertEquals(store.activeConv(page.projection)?.key, previous);
				assertEquals(seen.some((rows) => rows.includes(`room:${late}`)), false);
				releaseDeparture.resolve();
				await outcome;
				await session.openings.close();
				assertEquals([admissions, departures], [1, 1]);
				if (cleanup === "refused") {
					assertEquals(page.projection.get().sessionEffects.length > 0, true);
					assertEquals(current.intent.conversations.some((row) => row.id === late), true);
				} else {
					assertEquals(current.intent.conversations.some((row) => row.id === late), false);
					assertEquals(page.projection.get().sessionEffects, []);
				}
				assertEquals(store.convByPersistId(page.projection, late), null);
			} finally {
				reply.resolve();
				releaseDeparture.resolve();
				stop();
				await session.close();
				files.close();
			}
		});
	}
}

for (const owner of ["cancelledAcquisitions", "cancelledEffects"] as const) {
	Deno.test(`${owner} changes projection even without a workspace revision`, () => {
		const f = fixture();
		try {
			const before = f.selected();
			f.current.intent.conversations.push({ ...room(), id: "late-room", name: "late-room", seat: "late-seat" });
			f.apply();
			assertEquals(store.convByPersistId(f.page.projection, "late-room") != null, true);
			f[owner].push("late-room");
			f.projection.apply();
			assertEquals(store.convByPersistId(f.page.projection, "late-room"), null);
			assertEquals(f.selected().key, before.key);
		} finally {
			f.close();
		}
	});
}
