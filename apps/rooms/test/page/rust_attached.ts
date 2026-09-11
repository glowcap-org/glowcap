// Exercise the generated Rust attachment owner through native rooms-web and
// rooms-session. This isolated page stays at setup and never opens a TS Host.
import type { Browser } from "playwright";
import { fail } from "./harness.ts";

import type {
	RoomsBrowserApplication,
	RoomsBrowserFile,
	RoomsBrowserSession,
} from "../../../../zig-out/wasm/rooms/rooms_browser.js";
import type { RoomsSessionSnapshot } from "../../lib/session/client.ts";
interface Probe {
	app: RoomsBrowserApplication;
	session: RoomsBrowserSession;
	current: RoomsSessionSnapshot | null;
	file: RoomsBrowserFile | null;
	callbacks: number;
}
declare global {
	var __rustAttached: Probe | undefined;
}

export async function openRustAttachedView(browser: Browser, httpPort: number, sturdyref: string) {
	const context = await browser.newContext();
	const page = await context.newPage();
	try {
		await page.goto(`http://127.0.0.1:${httpPort}/`);
		await page.waitForSelector("#sessionSetup");
		await page.evaluate(async (link) => {
			const source = performance.getEntriesByType("resource")
				.find((entry) => new URL(entry.name).pathname.startsWith("/rooms_browser-"))?.name;
			if (source == null) throw new Error("production Rust module was not loaded");
			const binding: typeof import("../../../../zig-out/wasm/rooms/rooms_browser.js") = await import(source);
			const app = new binding.RoomsBrowserApplication();
			const session = await app.attach(link);
			const state: Probe = { app, session, current: null, file: null, callbacks: 0 };
			globalThis.__rustAttached = state;
			state.current = await session.watch(
				(snapshot: RoomsSessionSnapshot) => {
					state.current = snapshot;
					state.callbacks++;
				},
				(event: { attachments: RoomsBrowserFile[] }) => {
					for (const file of event.attachments) {
						if (file.name === "shared-session.png") {
							state.file?.release();
							state.file = file;
						} else file.release();
					}
				},
				() => {},
				() => {},
			);
			if (typeof state.current!.revision !== "number" || state.current!.checkpoint.conversations.length !== 2) {
				throw new Error("Rust snapshot did not preserve the multiple-room workspace");
			}
			await session.verifySibling(link);
			await session.command(crypto.randomUUID(), state.current!.revision, "setStanding", ["Rust boundary"]);
		}, sturdyref);
		await page.waitForFunction(() => globalThis.__rustAttached!.current!.checkpoint.standing === "Rust boundary");
		await page.evaluate(async () => {
			const state = globalThis.__rustAttached!;
			await state.session.command(crypto.randomUUID(), state.current!.revision, "setStanding", [""]);
			if (Reflect.get(globalThis, Symbol.for("glowcap.runtime.adapter")) !== undefined) {
				throw new Error("Rust attachment booted a TS Host");
			}
		});
	} catch (error) {
		await context.close();
		throw error;
	}
	return {
		async expectFile(expected: Uint8Array) {
			await page.waitForFunction(() => globalThis.__rustAttached!.file != null);
			const bytes = await page.evaluate(async () => {
				const state = globalThis.__rustAttached!;
				const file = state.file!;
				const bytes: number[] = [];
				while (bytes.length < file.size) {
					const chunk = await file.read(bytes.length, Math.min(64 * 1024, file.size - bytes.length));
					bytes.push(...chunk);
				}
				file.release();
				let refused = false;
				try {
					await file.read(0, 1);
				} catch {
					refused = true;
				}
				if (!refused) throw new Error("released Rust file remained readable");
				const before = state.callbacks;
				await state.session.close();
				await state.app.close();
				if (state.callbacks !== before) throw new Error("closed Rust observation delivered a callback");
				state.session.free();
				state.app.free();
				file.free();
				delete globalThis.__rustAttached;
				return bytes;
			});
			if (bytes.length !== expected.length || bytes.some((value, index) => value !== expected[index])) {
				fail("Rust attached file bytes differed from the sent image");
			}
			await context.close();
		},
	};
}
