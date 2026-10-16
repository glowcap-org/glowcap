// The codec consumer writes through Loam, then a new Wasm instance restores
// the same IndexedDB graph and exact held fields after a full page reload.
export async function checkSessionGraph(page) {
	const resource = await page.evaluate(async () => {
		const binding = await import("/rooms_contract_proofs.js");
		await binding.default();
		const original = IDBObjectStore.prototype.put;
		let refusals = 0;
		let masked = 0;
		let recoveries = 0;
		globalThis.refuseRoomsGraphWrite = (after) => {
			let writes = 0;
			IDBObjectStore.prototype.put = function (...args) {
				if (this.transaction.db.name === "rooms-session-graph" && ++writes === after) {
					refusals++;
					IDBObjectStore.prototype.put = original;
					throw new DOMException("injected session graph quota refusal", "QuotaExceededError");
				}
				return original.apply(this, args);
			};
		};
		globalThis.armRoomsGraphOutcome = (applied) => {
			let recovering;
			let release;
			const ready = new Promise((resolve) => { recovering = resolve; });
			globalThis.roomsGraphOutcome = {
				phase: "armed",
				release: new Promise((resolve) => { release = resolve; }),
				retired(terminal) {
					if (terminal.outcome !== (applied ? 0 : 1)) throw new Error("unexpected physical graph outcome");
					masked++;
					this.phase = "unknown";
				},
				recovering() {
					recoveries++;
					recovering();
				},
			};
			globalThis.waitRoomsGraphRecovery = () => ready;
			globalThis.releaseRoomsGraphRecovery = release;
		};
		try {
			const resource = Array.from(await binding.rooms_session_graph_create());
			if (refusals !== 2 || masked !== 2 || recoveries !== 2) {
				throw new Error(`session graph outcome probes incomplete: ${refusals}/${masked}/${recoveries}`);
			}
			return resource;
		} finally {
			globalThis.releaseRoomsGraphRecovery?.();
			IDBObjectStore.prototype.put = original;
			delete globalThis.refuseRoomsGraphWrite;
			delete globalThis.armRoomsGraphOutcome;
			delete globalThis.waitRoomsGraphRecovery;
			delete globalThis.releaseRoomsGraphRecovery;
			delete globalThis.roomsGraphOutcome;
		}
	});
	await page.reload();
	await page.evaluate(async (resource) => {
		const binding = await import("/rooms_contract_proofs.js");
		await binding.default();
		await binding.rooms_session_graph_reopen(Uint8Array.from(resource));
	}, resource);
}

// Cold source owners restore the complete distinct foreign field population.
// The exporter stays alive in this realm; this does not claim exporter restart.
// Four cold-owner phases restore the maximum field population through IndexedDB.
// This scenario has its own process and budget, separate from the Host journey.
export async function checkSessionForeign(page) {
	await page.evaluate(async () => {
		const binding = await import("/rooms_contract_proofs.js");
		await binding.default();
		let deadline;
		try {
			await Promise.race([
				binding.rooms_session_foreign_contract(),
				new Promise((_, reject) => {
					deadline = setTimeout(() => reject(new Error("maximum foreign session timed out")), 90_000);
				}),
			]);
		} finally {
			clearTimeout(deadline);
		}
	});
}
