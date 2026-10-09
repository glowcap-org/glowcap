// Held management keeps its exact custody: issuance and close settle returned
// handles once, and what a viewer knows about an access survives the control
// losing sight of it. Rust browser proofs separately exercise actual authority.
import { assert, assertEquals } from "../assert.ts";
import { keptPowers, knownLabel, ManagedAccess, NO_MANAGEMENT } from "../../web/ui/session/managed/access.ts";
import type { HeldControl } from "../../web/ui/session/managed/access.ts";
import type {
	RoomsManagedApplication,
	RoomsManagedControl,
	RoomsManagedWorkspace,
} from "../../../../zig-out/wasm/rooms/rooms_browser.js";
import { deferred } from "../support/managed_viewer.ts";

Deno.test("managed issuance coalesces submission and close drains returned custody exactly once", async () => {
	const result = deferred<unknown>();
	let submissions = 0;
	let freed = 0;
	const request = {
		submitOutcome: () => {
			submissions++;
			return result.promise;
		},
		free: () => freed++,
	};
	const access = new ManagedAccess({} as RoomsManagedApplication, {} as RoomsManagedWorkspace, () => {});
	const source = {
		powers: { revision: "1" },
		handle: { prepareIssue: () => Promise.resolve(request) },
	} as unknown as HeldControl;
	await access.prepareIssue(source, [], "original", false, 0, { editCeiling: null, issueCeiling: null });
	const first = access.submitIssue();
	const second = access.submitIssue();
	assert(first === second, "concurrent callers must join the original submission");
	assertEquals(submissions, 1);
	access.stop();
	let closed = false;
	const closing = access.close().then(() => {
		closed = true;
	});
	await Promise.resolve();
	assert(!closed, "close must not free a request while its submission owns returned wrappers");
	const wrapper = { free: () => freed++ };
	result.resolve({ status: "committed", access: wrapper, control: wrapper });
	await Promise.all([first, second, closing]);
	assertEquals(freed, 3);
	await access.close();
	assertEquals(freed, 3);
});

Deno.test("managed close drains a control description without adopting late custody", async () => {
	const description = deferred<unknown>();
	let freed = 0;
	const access = new ManagedAccess({} as RoomsManagedApplication, {} as RoomsManagedWorkspace, () => {});
	const handle = { describe: () => description.promise, free: () => freed++ } as unknown as RoomsManagedControl;
	const holding = access.hold("late", handle).catch(() => {
		handle.free();
	});
	const closing = access.close();
	description.resolve({ available: false });
	await Promise.all([holding, closing]);
	assertEquals(access.held.length, 0);
	assertEquals(freed, 1);
});

Deno.test("the issuer keeps every power its source can pass on", async () => {
	let sent: unknown = null;
	const request = { submitOutcome: () => new Promise(() => {}), free() {} };
	const access = new ManagedAccess({} as RoomsManagedApplication, {} as RoomsManagedWorkspace, () => {});
	const source = {
		powers: { revision: "1", delegateControl: true, inspect: true, pause: true, resume: true, revoke: false },
		handle: {
			prepareIssue: (...args: unknown[]) => {
				sent = JSON.parse(args[5] as string);
				return Promise.resolve(request);
			},
		},
	} as unknown as HeldControl;
	await access.prepareIssue(source, ["observeWorkspace"], "kept", false, 0, {
		editCeiling: ["observeWorkspace"],
		issueCeiling: null,
	});
	assertEquals(sent, {
		inspect: true,
		pause: true,
		resume: true,
		revoke: false,
		delegateControl: true,
		editCeiling: ["observeWorkspace"],
		issueCeiling: null,
	});
	assertEquals(keptPowers({ available: true, inspect: true }, { editCeiling: [], issueCeiling: [] }), NO_MANAGEMENT);
	await access.close();
});

Deno.test("a committed issuance rereads its source, so the next one starts from its new revision", async () => {
	let revision = "1";
	const bases: unknown[] = [];
	const issued = { describe: () => Promise.resolve({ available: false }), free() {} };
	const request = {
		submitOutcome: () => {
			revision = String(Number(revision) + 1);
			return Promise.resolve({ status: "committed", access: { free() {} }, control: issued });
		},
		free() {},
	};
	const access = new ManagedAccess({} as RoomsManagedApplication, {} as RoomsManagedWorkspace, () => {});
	const source = {
		id: "current",
		grant: null,
		powers: { available: true, revision },
		handle: {
			describe: () => Promise.resolve({ available: true, revision }),
			prepareIssue: (base: unknown) => {
				bases.push(base);
				return Promise.resolve(request);
			},
		},
	} as unknown as HeldControl;
	const none = { editCeiling: null, issueCeiling: null };
	await access.prepareIssue(source, ["observeWorkspace"], "first", false, 0, none);
	assertEquals((await access.submitIssue()).phase, "committed");
	access.issue!.control!.saved = true;
	access.finishIssue();
	await access.prepareIssue(source, ["observeWorkspace"], "second", false, 0, none);
	assertEquals(bases, ["1", "2"]);
	await access.close();
});

Deno.test("a committed label is known even to a control that cannot inspect", async () => {
	const access = new ManagedAccess({} as RoomsManagedApplication, {} as RoomsManagedWorkspace, () => {});
	const control = {
		id: "blind",
		grant: null,
		powers: { available: true, revision: "1", editCeiling: { permissions: [], bounds: [] } },
		handle: {
			prepareLabel: () =>
				Promise.resolve({ submitOutcome: () => Promise.resolve({ status: "committed" }), free() {} }),
		},
	} as unknown as HeldControl;
	await access.prepare(control, { kind: "label", label: "Home" }, "1");
	assertEquals((await access.submit(control)).phase, "committed");
	assertEquals(knownLabel(control), "Home");
	access.finish(control);
	await access.close();
});
