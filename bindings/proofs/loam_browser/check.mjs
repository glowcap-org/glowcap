// Real Chromium executes the linked consumer; each page wait has a deadline.
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { createServer } from "node:http";
import { once } from "node:events";
import { chromium } from "playwright";

const root = new URL("../../../zig-out/wasm/loam-browser/", import.meta.url);
const server = createServer(async (request, response) => {
	try {
		const path = new URL(request.url, "http://localhost").pathname;
		if (path === "/") {
			response.writeHead(200, { "Content-Type": "text/html" });
			response.end("<!doctype html><title>Loam browser contract</title>");
			return;
		}
		const target = new URL(`.${path}`, root);
		if (!target.href.startsWith(root.href)) throw new Error("asset path escaped the proof build");
		const bytes = await readFile(target);
		response.writeHead(200, { "Content-Type": path.endsWith(".wasm") ? "application/wasm" : "text/javascript" });
		response.end(bytes);
	} catch {
		response.writeHead(404);
		response.end();
	}
});
server.listen(0, "127.0.0.1");
await once(server, "listening");
const browser = await chromium.launch({ headless: true });
try {
	const page = await browser.newPage();
	page.on("pageerror", (error) => console.error(error));
	page.on("console", (event) => {
		if (event.type() === "error") console.error(event.text());
	});
	const url = `http://127.0.0.1:${server.address().port}/`;
	const initialize = async () => {
		await page.goto(url);
		await page.evaluate(async () => {
			const binding = await import("/loam_browser_proof.js");
			await binding.default();
			globalThis.binding = binding;
			globalThis.refuseLoamWrite = () => {
				const original = IDBObjectStore.prototype.put;
				let writes = 0;
				IDBObjectStore.prototype.put = function (...args) {
					if (this.transaction.db.name === "glowcap-loam-browser-proof" && ++writes === 3) {
						IDBObjectStore.prototype.put = original;
						throw new DOMException("injected mutation quota refusal", "QuotaExceededError");
					}
					return original.apply(this, args);
				};
			};
			globalThis.blockLoamStorage = (observeRestore) =>
				new Promise((resolve, reject) => {
					const opening = indexedDB.open("glowcap-loam-browser-proof", 1);
					opening.onerror = () => reject(opening.error);
					opening.onsuccess = () => {
						const database = opening.result;
						const transaction = database.transaction("rows", "readwrite");
						const rows = transaction.objectStore("rows");
						const originalGet = IDBObjectStore.prototype.get;
						let queued;
						const restoreQueued = new Promise((resolve) => { queued = resolve; });
						globalThis.waitLoamRestoreQueued = () => restoreQueued;
						let retired;
						const restoreRetired = new Promise((resolve) => { retired = resolve; });
						globalThis.waitLoamRestoreRetired = () => restoreRetired;
						const restores = new Set();
						const observedGet = function (...args) {
							const result = originalGet.apply(this, args);
							if (this.transaction.db.name === "glowcap-loam-browser-proof" && this.transaction.mode === "readonly") {
								if (!restores.has(this.transaction)) {
									restores.add(this.transaction);
									if (restores.size === 1) queued();
									else {
										IDBObjectStore.prototype.get = originalGet;
										this.transaction.addEventListener("complete", retired, { once: true });
									}
								}
							}
							return result;
						};
						if (observeRestore) IDBObjectStore.prototype.get = observedGet;
						let held = true;
						let answered = false;
						const timer = setTimeout(() => {
							held = false;
							transaction.abort();
							reject(new Error("storage blocker timed out"));
						}, 3000);
						globalThis.unblockLoamStorage = () => {
							held = false;
						};
						const next = () => {
							const request = rows.get(Uint8Array.of(109));
							request.onsuccess = () => {
								if (!answered) {
									answered = true;
									resolve();
								}
								if (held) next();
							};
						};
						transaction.oncomplete = transaction.onabort = (event) => {
							if (event.type === "abort" && IDBObjectStore.prototype.get === observedGet) IDBObjectStore.prototype.get = originalGet;
							clearTimeout(timer);
							database.close();
						};
						next();
					};
				});
		});
	};
	const bounded = async (operation) => {
		let timer;
		try {
			return await Promise.race([
				operation(),
				new Promise((_, reject) => {
					timer = setTimeout(() => reject(new Error("Loam browser contract timed out")), 10000);
				}),
			]);
		} finally {
			clearTimeout(timer);
		}
	};
	await initialize();
	const saved = await bounded(() => page.evaluate(() => binding.create()));
	console.log(JSON.stringify(JSON.parse(saved).costs));
	await initialize();
	await bounded(() => page.evaluate((saved) => binding.reopen(saved), saved));
	await bounded(() => page.evaluate((saved) => binding.cancelled_restore(saved), saved));
	await bounded(() => page.evaluate((saved) => binding.cancelled_call_progress(saved), saved));
	await bounded(() => page.evaluate((saved) => binding.buffered_restore(saved), saved));
	await bounded(() => page.evaluate((saved) => binding.retired_executor(saved), saved));
	await bounded(() => page.evaluate((saved) => binding.partial_restore(saved), saved));
	await initialize();
	const operations = JSON.parse(await bounded(() => page.evaluate((saved) => binding.operations(saved), saved)));
	const byName = Object.fromEntries(operations.map((operation) => [operation.operation, operation]));
	for (const operation of operations) {
		console.log(
			`operation ${operation.operation}: transactions=${operation.transactions} js_calls=${operation.js_calls} callbacks=${operation.callbacks} planning_passes=${operation.planning_passes} rows_read=${operation.database_rows} writes_emitted=${operation.emitted_writes} copied_bytes=${operation.copied_bytes}`,
		);
	}
	for (const operation of operations) {
		// Structurally fixed: each transaction makes one js_execute call and each
		// emitted write makes one js_put call. Nothing else crosses from Rust.
		assert.equal(
			operation.js_calls,
			operation.transactions + operation.emitted_writes,
			`${operation.operation}: JavaScript calls are transactions plus writes`,
		);
		// A lower bound only: a transaction that began before the measured window
		// may settle inside it. Each planning pass enters Rust once.
		assert.ok(
			operation.callbacks >= operation.planning_passes,
			`${operation.operation}: each planning pass enters Rust once`,
		);
	}
	assert.ok(byName["cold read"].transactions >= 1, "a cold read reaches IndexedDB");
	assert.ok(byName["cold read"].database_rows > 0, "a cold read loads rows");
	// Warm reads and receipt replays answer from resident state and retained
	// receipts, so no part of the adapter runs.
	for (const resident of [byName["warm read"], byName["receipt replay"]]) {
		for (const field of ["transactions", "js_calls", "callbacks", "database_rows", "emitted_writes", "copied_bytes"]) {
			assert.equal(resident[field], 0, `${resident.operation} leaves ${field} at zero`);
		}
	}
	for (const write of [byName.edit, byName.share]) {
		assert.ok(write.transactions >= 1, `${write.operation} commits through IndexedDB`);
		assert.ok(write.emitted_writes > 0, `${write.operation} emits writes`);
	}
	await bounded(() => page.evaluate(() => binding.cancelled_creation()));
	await bounded(() => page.evaluate(() => binding.record_bound()));
	await bounded(() => page.evaluate(() => binding.empty_store()));
	console.log(await bounded(() => page.evaluate(() => binding.collection())));
	const counts = await bounded(() =>
		page.evaluate(async () => {
			const count = () =>
				new Promise((resolve, reject) => {
					const request = indexedDB.open("glowcap-loam-abort-proof", 1);
					request.onerror = () => reject(request.error);
					request.onsuccess = () => {
						const database = request.result;
						const transaction = database.transaction("rows", "readonly");
						const result = transaction.objectStore("rows").count();
						transaction.oncomplete = () => {
							database.close();
							resolve(result.result);
						};
						transaction.onabort = () => {
							database.close();
							reject(transaction.error);
						};
					};
				});
			const before = await count();
			const original = IDBObjectStore.prototype.put;
			let writes = 0;
			IDBObjectStore.prototype.put = function (...args) {
				if (this.transaction.db.name === "glowcap-loam-abort-proof" && ++writes === 3) {
					throw new DOMException("injected quota refusal", "QuotaExceededError");
				}
				return original.apply(this, args);
			};
			try {
				await binding.aborted_creation();
			} finally {
				IDBObjectStore.prototype.put = original;
			}
			return { before, after: await count(), writes };
		})
	);
	assert.equal(counts.before, 1);
	assert.equal(counts.after, 1, "a mid-batch quota refusal persists no owner, grant or content row");
	assert.equal(counts.writes, 3);
	console.log(
		"Loam browser lifecycle, page reload, cold discovery, exclusive ownership, callback retirement, abandoned observer and quota rollback passed.",
	);
} finally {
	await browser.close();
	server.close();
	await once(server, "close");
}
