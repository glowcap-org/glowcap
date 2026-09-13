// The Rust attachment owns transport recovery and callback generations.
// This module connects its presentation facade to the existing controller.
import { retainCleanupFailures, retainSecondaryFailure } from "@glowcap/runtime/cleanup";
import { applicationModule, directoryId, workspaceStorageKey } from "../application.ts";
import { homeLocator } from "../page_bootstrap.ts";
import type { RoomsPageContext } from "../page.ts";
import { AttachedRoomsController } from "./attached.ts";
import { rustRemote } from "./rust_remote.ts";
import type { RoomsBrowserApplication, RoomsBrowserSession } from "../../../../../zig-out/wasm/rooms/rooms_browser.js";
import { LS } from "../storage.ts";
import * as store from "../store.ts";

export async function connectAttachedRoomsSession(
	page: RoomsPageContext,
	sturdyref: string,
): Promise<AttachedRoomsController> {
	const home = await homeLocator(page);
	const application = new (applicationModule().RoomsBrowserApplication)(troubleReporter(page));
	return await connect(application, () => application.attach(sturdyref, home));
}

export async function connectLocalRoomsSession(page: RoomsPageContext): Promise<{
	controller: AttachedRoomsController;
	publish(): Promise<string>;
}> {
	const home = await homeLocator(page);
	const id = directoryId(home);
	if (id === null) throw new Error("The page supplied an invalid directory address");
	page.bootstrap.pageDirectoryId = id;
	const application = applicationModule().RoomsBrowserApplication.localWorkspace(
		LS.get(workspaceStorageKey()) ?? undefined,
		home,
		troubleReporter(page),
	);
	const controller = await connect(application, () => application.localSession());
	return { controller, publish: () => application.publishLocal() };
}

function troubleReporter(page: RoomsPageContext): (source: string, reason: string) => void {
	return (source, reason) => store.noteTrouble(page.projection, source, reason);
}

async function connect(
	application: RoomsBrowserApplication,
	open: () => Promise<RoomsBrowserSession>,
): Promise<AttachedRoomsController> {
	let session: RoomsBrowserSession | null = null;
	let closing: Promise<void> | null = null;
	const close = (): Promise<void> =>
		closing ??= (async () => {
			// Observe both Rust barriers before releasing generated wrappers. A
			// synchronous wrapper refusal must not skip its sibling's retirement.
			const results = await Promise.allSettled([
				Promise.resolve().then(() => application.close()),
				Promise.resolve().then(() => session?.close()),
			]);
			results.push(
				...await Promise.allSettled([
					Promise.resolve().then(() => session?.free()),
					Promise.resolve().then(() => application.free()),
				]),
			);
			let failure: { reason: unknown } | null = null;
			for (const result of results) {
				if (result.status === "rejected") {
					if (failure === null) failure = result;
					else retainSecondaryFailure(failure.reason, result.reason);
				}
			}
			if (failure !== null) throw failure.reason;
		})();
	try {
		const active = await open();
		session = active;
		const controller = new AttachedRoomsController(rustRemote(active), close);
		await controller.start();
		return controller;
	} catch (error) {
		throw await retainCleanupFailures(connectionError(error), [close]);
	}
}

function connectionError(error: unknown): Error {
	return error instanceof Error ? error : new Error(String(error));
}
