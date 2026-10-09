/**
 * An in-memory Web Storage for tests that read back what they persist.
 *
 * Deno backs `localStorage` with one SQLite file shared by every test worker,
 * so under `deno test --parallel` a write can fail with "database is locked".
 * The storage boundary absorbs that as "nothing stored", which turns lock
 * contention into a wrong answer. Each test file runs in its own isolate, so
 * installing this at module scope gives that file storage nobody else touches.
 */
export function installMemoryStorage(): Storage {
	const items = new Map<string, string>();
	const storage: Storage = {
		get length() {
			return items.size;
		},
		clear: () => items.clear(),
		getItem: (key) => items.get(key) ?? null,
		key: (index) => [...items.keys()][index] ?? null,
		removeItem: (key) => void items.delete(key),
		setItem: (key, value) => void items.set(key, String(value)),
	};
	Object.defineProperty(globalThis, "localStorage", { configurable: true, value: storage });
	return storage;
}
