// A browser that blocks site storage throws on the first touch, even on
// reading `localStorage` itself. The page reads through one accessor, so a
// blocked browser reads as an empty one, and a write it refuses comes back to
// the caller as the sentence that says what to do.
/// <reference lib="dom" />
import "./support/match_media.ts";
import { assert, assertEquals } from "./assert.ts";
import { failureView, LocalRefusal, refusalText } from "../lib/text/failure.ts";
import { storageBlocked } from "../lib/text/page.ts";
import { pageStorage } from "../web/ui/page_storage.ts";

const blocked = () => {
	throw new DOMException("The operation is insecure.", "SecurityError");
};

function memoryArea() {
	const kept = new Map<string, string>();
	return {
		kept,
		area: {
			get length() {
				return kept.size;
			},
			key: (index: number) => [...kept.keys()][index] ?? null,
			getItem: (key: string) => kept.get(key) ?? null,
			setItem: (key: string, value: string) => void kept.set(key, value),
			removeItem: (key: string) => void kept.delete(key),
		},
	};
}

Deno.test("a blocked browser reads as empty storage, and refuses each write with the instruction", () => {
	const storage = pageStorage(blocked);
	assertEquals(storage.read("rooms.server"), null);
	assertEquals(storage.keys(), []);
	for (const refused of [storage.write("rooms.server", "x"), storage.remove("rooms.server")]) {
		assert(refused instanceof LocalRefusal, "a refused write comes back to the caller");
		assertEquals(failureView(refused).summary, storageBlocked);
		assertEquals(failureView(refused).action, null, "no advice to try again");
		assertEquals(failureView(refused).retry, "after-state-change");
		assertEquals(refusalText(refused), `${storageBlocked} (local-storage-blocked: The operation is insecure.)`);
	}
});

Deno.test("storage that answers is read, written, listed, and removed through the accessor", () => {
	const { kept, area } = memoryArea();
	const storage = pageStorage(() => area);
	assertEquals(storage.write("a", "1"), null);
	assertEquals(storage.write("b", "2"), null);
	assertEquals(storage.read("a"), "1");
	assertEquals(storage.keys(), ["a", "b"]);
	assertEquals(storage.remove("a"), null);
	assertEquals([...kept.keys()], ["b"]);
});

Deno.test("a full browser refuses the one write it cannot keep and keeps reading", () => {
	const { area } = memoryArea();
	const storage = pageStorage(() => ({
		...area,
		setItem: () => {
			throw new DOMException("Quota exceeded.", "QuotaExceededError");
		},
	}));
	assert(storage.write("a", "1") instanceof LocalRefusal, "the write it cannot keep is refused");
	assertEquals(storage.read("a"), null);
});

Deno.test("a page in a blocked browser chooses no session, forgets nothing, and refuses to mint a tab", async () => {
	const descriptors = ["localStorage", "sessionStorage"].map((name) =>
		[name, Object.getOwnPropertyDescriptor(globalThis, name)] as const
	);
	for (const [name] of descriptors) Object.defineProperty(globalThis, name, { configurable: true, get: blocked });
	try {
		const { forgetWorkspaceChoice, workspaceChosen } = await import("../web/ui/controller/create_browser.ts");
		const { tabIdentity } = await import("../web/ui/session/managed/open.ts");
		assertEquals(workspaceChosen(), false, "startup shows session setup instead of throwing");
		assertEquals(forgetWorkspaceChoice(), null, "the failure screen has no choice to forget");
		let minted: unknown = null;
		try {
			tabIdentity();
		} catch (error) {
			minted = error;
		}
		assert(minted instanceof LocalRefusal, "an identity nobody keeps is refused");
		assertEquals(failureView(minted).summary, storageBlocked);
	} finally {
		for (const [name, descriptor] of descriptors) {
			if (descriptor === undefined) Reflect.deleteProperty(globalThis, name);
			else Object.defineProperty(globalThis, name, descriptor);
		}
	}
});

Deno.test("an invalid persisted tab identity asks for a new tab and retains the stored value", async () => {
	const { tabIdentity } = await import("../web/ui/session/managed/open.ts");
	const { area, kept } = memoryArea();
	kept.set("rooms.managed-tab", "invalid identity");
	let error: unknown;
	try {
		tabIdentity(pageStorage(() => area));
	} catch (caught) {
		error = caught;
	}
	assert(error instanceof LocalRefusal, "the refusal has a catalog key");
	assertEquals(error.code, "local-tab-identity-invalid");
	assert(failureView(error).summary.includes("new tab"), "the refusal has an available reset action");
	assertEquals(kept.get("rooms.managed-tab"), "invalid identity");
});
