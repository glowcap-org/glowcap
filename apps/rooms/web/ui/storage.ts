// What this browser profile keeps between visits, and what to do when it
// keeps nothing.
//
// Storage can be missing or refuse a write: a private window, a profile with
// site data turned off, a quota that has run out. None of that is worth a
// failure path in a page where every stored fact is a convenience, so each
// verb here answers as though nothing had been kept and the page carries on.
// A reader in a private window loses their nickname between visits and
// nothing else.
//
// One wrapper, not one per owner. What gets kept is split by lifetime, and
// that split is real: the store's own fields name their keys in
// `store/core.ts`, the two choices that reload the peer name theirs in
// `prefs.ts`, and a remembered operations swiss number is keyed by
// `opsSwissKey` in `types.ts`. But those are splits of the keys. Reading and
// writing is the same act every time, and a second copy of it is a second
// place for the swallowing to be got wrong.

export const LS = {
	get(k: string): string | null {
		try {
			return localStorage.getItem(k);
		} catch {
			return null;
		}
	},
	set(k: string, v: string): void {
		try {
			localStorage.setItem(k, v);
		} catch { /* storage disabled (private mode); ignore */ }
	},
	remove(k: string): void {
		try {
			localStorage.removeItem(k);
		} catch { /* storage disabled (private mode); ignore */ }
	},
};
