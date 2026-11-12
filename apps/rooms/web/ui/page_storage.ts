/// <reference lib="dom" />
// This browser's storage for the page: local storage, kept across visits, and
// session storage, kept for one tab. A browser that blocks site storage
// throws on the first touch, even on reading the `localStorage` property
// itself, so every read and write the page makes goes through here.

import { LocalRefusal } from "../../lib/text/failure.ts";

/** The part of `Storage` the page uses. */
export type StorageArea = Pick<Storage, "getItem" | "setItem" | "removeItem" | "key" | "length">;

/** One storage area, read and written so its refusal never throws past the
 * caller. A read answers null when there is nothing or the browser refuses.
 * A write or removal answers null when it happened, and otherwise the
 * refusal to show, so the caller decides what an unkept value means. */
export interface PageStorage {
	read(key: string): string | null;
	write(key: string, value: string): LocalRefusal | null;
	remove(key: string): LocalRefusal | null;
	/** Every key the area holds, or none when the browser refuses. */
	keys(): string[];
}

/** The storage behind `area`, which is asked on every call, because reaching
 * a blocked area is what throws. */
export function pageStorage(area: () => StorageArea): PageStorage {
	const kept = (act: (storage: StorageArea) => void): LocalRefusal | null => {
		try {
			act(area());
			return null;
		} catch (error) {
			return new LocalRefusal("storage-blocked", { cause: error });
		}
	};
	return {
		read(key) {
			try {
				return area().getItem(key);
			} catch {
				// tolerant: a refused read is no value, which every reader already handles.
				return null;
			}
		},
		write: (key, value) => kept((storage) => storage.setItem(key, value)),
		remove: (key) => kept((storage) => storage.removeItem(key)),
		keys() {
			try {
				const storage = area();
				const keys: string[] = [];
				for (let index = 0; index < storage.length; index += 1) {
					const key = storage.key(index);
					if (key != null) keys.push(key);
				}
				return keys;
			} catch {
				// tolerant: a refused listing holds no keys, so there is nothing to remove.
				return [];
			}
		},
	};
}

/** Kept across visits on this origin. */
export const localArea: PageStorage = pageStorage(() => localStorage);
/** Kept for this tab, across its reloads. */
export const sessionArea: PageStorage = pageStorage(() => sessionStorage);
