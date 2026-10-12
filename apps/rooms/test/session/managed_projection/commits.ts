// Receipt knowledge is projected even when workspace refresh or recovery fails.
import { assert, assertEquals } from "../../assert.ts";
import { fixture, room } from "./fixture.ts";
import * as store from "../../../web/ui/store.ts";
import { ManagedOperation, ResultAcquisitionError } from "../../../web/ui/session/managed/operation.ts";
import type { RoomsManagedCommand } from "../../../../../zig-out/wasm/rooms/rooms_browser.js";

Deno.test("commit observation settles a pending bubble without names or a new workspace revision", async () => {
	const f = fixture(room());
	let status = "pending";
	let interrupted = false;
	const operation = new ManagedOperation("send", {
		status: () => interrupted ? Promise.reject(new Error("status unavailable")) : Promise.resolve(status),
		free() {},
	} as unknown as RoomsManagedCommand);
	f.operations.push(operation);
	const key = f.selected().key;
	const original = store.chatItem(f.page.projection, "ada", "delivered", true, "unconfirmed");
	store.deliver(f.page.projection, key, { ...original, operation: "send", awaitingReceipt: true, retryable: true });
	const unknown = store.chatItem(f.page.projection, "ada", "still unknown", true, "unconfirmed");
	store.deliver(f.page.projection, key, { ...unknown, operation: "different" });
	const lines = () => store.historyOf(f.page.projection, key).filter((row) => row.kind === "chat");
	try {
		await operation.status();
		f.projection.apply();
		assertEquals(lines()[0].state, "unconfirmed");
		status = "committed";
		await operation.status();
		f.projection.apply();
		assertEquals(lines().map((row) => [row.state, row.lineId, row.held, row.operation]), [
			[undefined, undefined, undefined, undefined],
			["unconfirmed", undefined, undefined, "different"],
		]);
		interrupted = true;
		const failure = (await Promise.allSettled([operation.status()]))[0];
		assert(
			failure.status === "rejected" && failure.reason instanceof ResultAcquisitionError,
			"commit survives failed observation",
		);
		const history = store.historyOf(f.page.projection, key);
		const iterate = history[Symbol.iterator].bind(history);
		let scans = 0;
		Object.defineProperty(history, Symbol.iterator, {
			configurable: true,
			value: () => {
				scans++;
				return iterate();
			},
		});
		f.projection.apply();
		assertEquals(scans, 0, "a presented commit does not rescan history on later wakes");
		Reflect.deleteProperty(history, Symbol.iterator);
		store.releaseSentLine(f.page.projection, "send");
		assertEquals(lines()[0].state, undefined, "letting go of controls cannot erase delivery");
	} finally {
		await operation.close();
		f.close();
	}
});
