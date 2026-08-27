import { assertEquals } from "@std/assert";
import { forgetStoredValue, loadStoredValue, persistStoredValue } from "./storage.ts";

const KEY = "ocapnviz:test:storage-boundary";

Deno.test("preference storage round-trips through its one platform boundary", () => {
	forgetStoredValue(KEY);
	persistStoredValue(KEY, "kept");
	assertEquals(loadStoredValue(KEY), "kept");
	forgetStoredValue(KEY);
	assertEquals(loadStoredValue(KEY), null);
});

Deno.test("a forbidden storage getter cannot break preference state", () => {
	const descriptor = Object.getOwnPropertyDescriptor(globalThis, "localStorage");
	Object.defineProperty(globalThis, "localStorage", {
		configurable: true,
		get: () => {
			throw new DOMException("forbidden", "SecurityError");
		},
	});
	try {
		assertEquals(loadStoredValue(KEY), null);
		persistStoredValue(KEY, "ignored");
		forgetStoredValue(KEY);
	} finally {
		if (descriptor === undefined) delete (globalThis as { localStorage?: Storage }).localStorage;
		else Object.defineProperty(globalThis, "localStorage", descriptor);
	}
});

Deno.test("storage method failures remain preference loss, not app failures", () => {
	const descriptor = Object.getOwnPropertyDescriptor(globalThis, "localStorage");
	const refused = () => {
		throw new DOMException("full", "QuotaExceededError");
	};
	Object.defineProperty(globalThis, "localStorage", {
		configurable: true,
		value: {
			getItem: refused,
			setItem: refused,
			removeItem: refused,
		},
	});
	try {
		assertEquals(loadStoredValue(KEY), null);
		persistStoredValue(KEY, "ignored");
		forgetStoredValue(KEY);
	} finally {
		if (descriptor === undefined) delete (globalThis as { localStorage?: Storage }).localStorage;
		else Object.defineProperty(globalThis, "localStorage", descriptor);
	}
});
