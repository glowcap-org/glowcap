// What this browser profile keeps between visits, and what to do when it
// keeps nothing.
//
// Storage can be missing or refuse a write: a private window, a profile with
// site data turned off, or a quota that has run out. This adapter contains the
// browser exception and reports success explicitly. The workspace owner then
// keeps the prior durable projection authoritative and presents the failure.
//
// One wrapper for the versioned Rooms bundle. IndexedDB separately owns
// message records and their retention epoch because they have a different
// size, transaction, and custody boundary.

export const LS = {
	get(k: string): string | null {
		try {
			return localStorage.getItem(k);
		} catch {
			return null;
		}
	},
	set(k: string, v: string): boolean {
		try {
			localStorage.setItem(k, v);
			return true;
		} catch {
			return false;
		}
	},
	remove(k: string): boolean {
		try {
			localStorage.removeItem(k);
			return true;
		} catch {
			return false;
		}
	},
};
