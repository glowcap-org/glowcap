// Execute the actual managed callback and worker against IndexedDB. Each case
// closes its physical owners and cold opens its committed/unresolved receipts.
// A selected group runs its scenario inventory. Null runs startup/storage checks.
export async function checkSessionExecutor(page, group = null) {
	await page.evaluate(async (selectedGroup) => {
		async function removeDatabases() {
			for (const { name } of await indexedDB.databases()) {
				if (!name?.startsWith("rooms-session-executor-")) continue;
				await new Promise((resolve, reject) => {
					const request = indexedDB.deleteDatabase(name);
					request.onsuccess = () => resolve();
					request.onerror = () => reject(request.error);
					request.onblocked = () => reject(new Error(`executor still owns ${name}`));
				});
			}
		}
		await removeDatabases();
		const binding = await import("/rooms_contract_proofs.js");
		await binding.default();
		let phase = "missing metadata";
		let lastDatabase = "none";
		const open = IDBFactory.prototype.open;
		IDBFactory.prototype.open = function (name, ...args) {
			lastDatabase = name;
			return open.call(this, name, ...args);
		};
		async function bounded(work) {
			let deadline;
			try {
				await Promise.race([
					work(),
					new Promise((_, reject) => {
						deadline = setTimeout(
							() =>
								reject(
									new Error(
										`session receipt executor timed out in ${phase}; last database: ${lastDatabase}`,
									),
								),
							30_000,
						);
					}),
				]);
			} finally {
				clearTimeout(deadline);
			}
		}
		async function runGroup(group) {
			const scenarios = binding.rooms_session_executor_scenarios(group);
			if (scenarios.length === 0) throw new Error(`unknown executor group ${group}`);
			for (const name of scenarios) {
				phase = `executor group ${group}: ${name}`;
				await bounded(() => binding.rooms_session_executor_scenario_contract(name));
			}
		}
		try {
			if (selectedGroup !== null) {
				await runGroup(selectedGroup);
				await removeDatabases();
				return;
			}
			await bounded(async () => {
				const damaged = await new Promise((resolve, reject) => {
					const request = indexedDB.open("rooms-session-executor-missing-metadata", 1);
					request.onupgradeneeded = () => request.result.createObjectStore("rows");
					request.onsuccess = () => resolve(request.result);
					request.onerror = () => reject(request.error);
				});
				const rowKey = new Uint8Array([114]);
				const rowValue = new Uint8Array([1, 2, 3]);
				async function changeRows(change) {
					await new Promise((resolve, reject) => {
						const tx = damaged.transaction("rows", "readwrite", { durability: "strict" });
						tx.oncomplete = resolve;
						tx.onabort = () => reject(tx.error);
						change(tx.objectStore("rows"));
					});
				}
				try {
					await changeRows((rows) => rows.put(rowValue, rowKey));
					await binding.rooms_session_missing_metadata_contract(true);
					await new Promise((resolve, reject) => {
						const tx = damaged.transaction("rows", "readonly");
						const rows = tx.objectStore("rows");
						const count = rows.count();
						const surviving = rows.get(rowKey);
						tx.oncomplete = () => {
							if (count.result !== 1 || String(surviving.result) !== String(rowValue)) {
								reject(new Error("refused startup changed physical rows"));
							} else resolve();
						};
						tx.onabort = () => reject(tx.error);
					});
					await changeRows((rows) => rows.clear());
					await binding.rooms_session_missing_metadata_contract(false);
				} finally {
					damaged.close();
				}
				await removeDatabases();
			});
			await bounded(async () => {
				for (const metadata of [true, false]) {
					phase = metadata ? "bootstrap metadata durability" : "bootstrap Store durability";
					const name = metadata ? "rooms-history" : "rooms-session-executor-bootstrap-store-durability";
					const transaction = IDBDatabase.prototype.transaction;
					let ignored = 0;
					IDBDatabase.prototype.transaction = function (stores, mode, options) {
						if (this.name === name && mode === "readwrite" && ignored === 0) {
							if (options?.durability !== "strict") {
								throw new Error("startup did not request strict durability");
							}
							ignored++;
							return transaction.call(this, stores, mode, { ...options, durability: "relaxed" });
						}
						return transaction.call(this, stores, mode, options);
					};
					try {
						await binding.rooms_session_bootstrap_durability_contract(metadata);
						if (ignored !== 1) throw new Error("strict durability refusal was not exercised");
					} finally {
						IDBDatabase.prototype.transaction = transaction;
					}
					await removeDatabases();
				}
			});
		} finally {
			IDBFactory.prototype.open = open;
		}
		await removeDatabases();
	}, group);
}
