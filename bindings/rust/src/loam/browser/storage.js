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

export function close(owner) {
	if (owner.active !== 0) throw new Error("Loam database transactions are still active");
	owner.closed = true;
	owner.database.onversionchange = null;
	owner.database.onclose = null;
	owner.database.close();
	owner.release();
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
		let requests = [];
		const finish = (aborted) => {
			if (terminal) return;
			terminal = true;
			transaction.oncomplete = null;
			transaction.onabort = null;
			for (const request of requests) request.onsuccess = null;
			requests = [];
			owner.active--;
			const error = failure || transaction.error || (!planned && new Error("Loam transaction had no plan"));
			resolve({ outcome: aborted ? 1 : error ? (write ? 2 : 1) : 0, error: error ? String(error) : "" });
		};
		transaction.oncomplete = () => finish(false);
		transaction.onabort = () => finish(true);
		const advance = (key, value) => {
			try {
				const plan = step(key, value);
				if (plan[0] === 0) {
					const missing = plan[1];
					const request = rows.get(missing);
					requests.push(request);
					request.onsuccess = () => advance(missing, request.result);
				} else if (plan[0] === 1) {
					if (!write && plan[1].length !== 0) throw new Error("read-only Loam plan attempted a write");
					for (const [key, value] of plan[1]) {
						if (value === undefined) rows.delete(key);
						else rows.put(value, key);
					}
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
