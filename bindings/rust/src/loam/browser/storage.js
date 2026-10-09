// IndexedDB owns physical atomicity; the synchronous planner owns record laws.
// Each continuation runs in an active request event. A promise settles only at
// a terminal transaction event, so dropping its Rust observer cannot cancel I/O.
export async function open(name, create) {
	if (!globalThis.navigator?.locks || !globalThis.indexedDB) {
		throw new Error("durable Loam requires IndexedDB and Web Locks");
	}
	let release;
	let answer;
	let refusal;
	const ready = new Promise((resolve, reject) => {
		answer = resolve;
		refusal = reject;
	});
	const held = new Promise((resolve) => {
		release = resolve;
	});
	const ownership = navigator.locks.request(
		`glowcap-loam:${name}`,
		{ mode: "exclusive", ifAvailable: true },
		async (lock) => {
			if (!lock) throw new Error("Loam store is already owned by another tab");
			answer();
			await held;
		},
	);
	ownership.catch(refusal);
	await ready;
	try {
		const database = await new Promise((resolve, reject) => {
			const request = indexedDB.open(name, 1);
			let abandoned = false;
			request.onupgradeneeded = () => {
				if (!create || request.transaction.db.objectStoreNames.length !== 0) {
					request.transaction.abort();
					return;
				}
				request.result.createObjectStore("rows");
			};
			request.onblocked = () => {
				abandoned = true;
				reject(new Error("Loam database open is blocked"));
			};
			request.onerror = () => reject(request.error);
			request.onsuccess = () => {
				if (abandoned) {
					request.result.close();
					return;
				}
				resolve(request.result);
			};
		});
		if (database.objectStoreNames.length !== 1 || !database.objectStoreNames.contains("rows")) {
			database.close();
			throw new Error("unsupported Loam database schema");
		}
		try {
			await verifyMetadata(database);
		} catch (error) {
			database.close();
			throw error;
		}
		const owner = { database, release, ownership, closed: false, active: 0, durability: "strict" };
		database.onversionchange = () => {
			owner.closed = true;
			database.close();
		};
		database.onclose = () => {
			owner.closed = true;
		};
		return owner;
	} catch (error) {
		release();
		await ownership;
		throw error;
	}
}

// The Web Lock excludes another Store claimant through this read and the
// subsequent metadata claim. Probe one key, never the application population.
// Absent identity/allocator metadata over surviving rows requires explicit
// repair, and cannot authorize either create or bootstrap to reset authority.
function verifyMetadata(database) {
	return new Promise((resolve, reject) => {
		const transaction = database.transaction("rows", "readonly");
		const rows = transaction.objectStore("rows");
		let failure;
		transaction.oncomplete = () => failure ? reject(failure) : resolve();
		transaction.onabort = () => reject(transaction.error);
		const metadata = rows.get(new Uint8Array([109]));
		metadata.onsuccess = () => {
			if (metadata.result !== undefined) return;
			const first = rows.openKeyCursor();
			first.onsuccess = () => {
				if (first.result) failure = new Error("Loam rows exist without identity and allocator metadata");
			};
		};
	});
}

export function quiescent(owner) {
	if (owner.active !== 0) throw new Error("Loam database transactions are still active");
}

export function close(owner) {
	quiescent(owner);
	owner.closed = true;
	owner.database.onversionchange = null;
	owner.database.onclose = null;
	owner.database.close();
	owner.release();
	return owner.ownership;
}

export function put(rows, key, value) {
	if (value == null) rows.delete(key);
	else rows.put(value, key);
}

export function execute(owner, write, step) {
	if (owner.closed) return Promise.reject(new Error("Loam database is closed"));
	return new Promise((resolve) => {
		const transaction = owner.database.transaction(
			"rows",
			write ? "readwrite" : "readonly",
			write ? { durability: "strict" } : undefined,
		);
		const rows = transaction.objectStore("rows");
		owner.active++;
		let failure;
		let planned = false;
		let terminal = false;
		let pending;
		const finish = (aborted) => {
			if (terminal) return;
			terminal = true;
			transaction.oncomplete = null;
			transaction.onabort = null;
			if (pending) pending.onsuccess = null;
			pending = undefined;
			owner.active--;
			const error = failure || transaction.error || (!planned && new Error("Loam transaction had no plan"));
			resolve({ outcome: aborted ? 1 : error ? (write ? 2 : 1) : 0, error: error ? String(error) : "" });
		};
		transaction.oncomplete = () => finish(false);
		transaction.onabort = () => finish(true);
		const advance = (key, value) => {
			try {
				const plan = step(rows, key, value);
				if (plan[0] === 0) {
					const missing = plan[1];
					const request = rows.get(missing);
					pending = request;
					request.onsuccess = () => {
						const input = request.result;
						request.onsuccess = null;
						pending = undefined;
						advance(missing, input);
					};
				} else if (plan[0] === 1) {
					planned = true;
				} else throw new Error("invalid Loam transaction plan");
			} catch (error) {
				failure = error;
				try {
					transaction.abort();
				} catch { /* Keep callbacks until the actual terminal event. */ }
			}
		};
		if (write && transaction.durability !== "strict") {
			failure = new Error("strict IndexedDB durability is unavailable");
			transaction.abort();
		} else {
			advance(undefined, undefined);
		}
	});
}
