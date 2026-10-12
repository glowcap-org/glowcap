/**
 * Best-effort browser preference storage.
 *
 * Preferences may disappear when storage is unavailable, full, or forbidden.
 * None of those platform policies may prevent the visualizer from starting or
 * changing view state. This is the one boundary that absorbs those failures.
 */

function withLocalStorage<T>(fallback: T, operation: (storage: Storage) => T): T {
	try {
		const storage = (globalThis as { localStorage?: Storage }).localStorage;
		return storage === undefined ? fallback : operation(storage);
	} catch {
		return fallback;
	}
}

export function loadStoredValue(key: string): string | null {
	return withLocalStorage(null, (storage) => storage.getItem(key));
}

export function persistStoredValue(key: string, value: string): void {
	withLocalStorage(undefined, (storage) => storage.setItem(key, value));
}

export function forgetStoredValue(key: string): void {
	withLocalStorage(undefined, (storage) => storage.removeItem(key));
}
