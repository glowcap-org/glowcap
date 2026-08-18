import * as tcp from "../../tcp/mod.ts";
import { INVALID_ARGUMENT, IO, LIFECYCLE_ACTIVE, LIFECYCLE_CLOSED, OK } from "@pancake/abi";
import { Connector } from "../transport.ts";
import { Host } from "../host.ts";
import { type CloseOptions, encodeCloseOptions, lifecycleClosed, releaseConsumed } from "../lifecycle.ts";
import { Runtime } from "../runtime.ts";
import { Context, recordCallerlessFailure, takeRuntimeFailures } from "../context.ts";
import type { Session } from "../session.ts";
import { requireArchiveFingerprint } from "../internal/ffi/runtime.ts";

function assert(value: unknown, message: string): asserts value {
	if (!value) throw new Error(message);
}

function fakeSession(id: number): Session {
	return { id } as unknown as Session;
}

Deno.test("final release status names the ownership boundary", () => {
	assert(!releaseConsumed(INVALID_ARGUMENT), "INVALID_ARGUMENT must remain retryable");
	assert(releaseConsumed(OK), "successful release must consume ownership");
	assert(releaseConsumed(IO), "teardown failure must consume ownership");
});

Deno.test("native lifecycle decoding rejects unknown states", () => {
	assert(!lifecycleClosed(LIFECYCLE_ACTIVE), "active was decoded as closed");
	assert(lifecycleClosed(LIFECYCLE_CLOSED), "closed was decoded as active");
	let refused = false;
	try {
		lifecycleClosed(0xffff_ffff);
	} catch (error) {
		refused = error instanceof Error && error.message.includes("unknown lifecycle state");
	}
	assert(refused, "unknown lifecycle state was normalized into progress");
});

Deno.test("archive fingerprints refuse stale callable surfaces before use", () => {
	requireArchiveFingerprint(
		{ pancake_test_archive_fingerprint: () => 0x1234n },
		{ symbol: "pancake_test_archive_fingerprint", expected: 0x1234n, archive: "test" },
	);
	let refused = false;
	try {
		requireArchiveFingerprint(
			{ pancake_test_archive_fingerprint: () => 0x5678n },
			{ symbol: "pancake_test_archive_fingerprint", expected: 0x1234n, archive: "test" },
		);
	} catch (error) {
		refused = error instanceof Error && error.message.includes("callable surface does not match");
	}
	assert(refused, "stale callable surface was admitted");
});

Deno.test("callerless failure without a surviving Context reaches the process seam", () => {
	takeRuntimeFailures();
	recordCallerlessFailure(null, {
		layer: "binding",
		scope: "process",
		operation: "driver-loop.finalizer.release",
		primaryName: "DriverLoopReleaseRefused",
		primaryResult: -5,
		primaryMessage: "release refused",
	});
	const failures = takeRuntimeFailures();
	assert(failures.length === 1, "callerless failure disappeared");
	assert(failures[0].operation === "driver-loop.finalizer.release", "operation identity changed");
	assert(failures[0].primaryMessage === "release refused", "failure detail changed");
});

Deno.test("allocator callback exceptions stay inside the Context boundary", () => {
	takeRuntimeFailures();
	let allocationRefused = false;
	try {
		Context.withAllocator({
			alloc() {
				throw new Error("allocator refused");
			},
			free() {},
		});
	} catch {
		allocationRefused = true;
	}
	assert(allocationRefused, "null allocator result did not refuse Context construction");
	let failures = takeRuntimeFailures();
	assert(failures.length === 1, "allocator exception disappeared");
	assert(failures[0].operation === "context.allocator.alloc", "allocator operation identity changed");
	assert(failures[0].primaryMessage === "allocator refused", "allocator detail changed");

	const context = Context.withAllocator({
		alloc(size) {
			return new Uint8Array(size);
		},
		free() {
			throw new Error("free refused");
		},
	});
	context.release();
	failures = takeRuntimeFailures();
	assert(failures.length >= 1, "free exception disappeared");
	assert(failures[0].operation === "context.allocator.free", "free operation identity changed");
	assert(failures[0].primaryMessage === "free refused", "free detail changed");
});

Deno.test("Runtime reuses one connector Host and clears its authority on close", async () => {
	const seen: Array<{ host: Host; options?: Uint8Array }> = [];
	const connector = new Connector(["test"], (host, _locator, request) => {
		seen.push({ host, options: request.transportOptions });
		return Promise.resolve(fakeSession(seen.length));
	});
	const runtime = await Runtime.open({ connectors: [connector], codec: "capnp" });
	const host = runtime.host;
	const operation = { transports: ["test"], data: Uint8Array.of(1, 2, 3) };
	await runtime.connect(
		{ transport: "test", designator: "one", hints: new Map(), hintWireForm: "boolean-false" },
		{ transport: operation },
	);
	await runtime.connect(
		{ transport: "test", designator: "two", hints: new Map(), hintWireForm: "boolean-false" },
	);

	assert(seen.length === 2, "Runtime did not reuse the connector for both dials");
	assert(seen.every((entry) => entry.host === host), "Runtime replaced its Host between dials");
	assert(host.codec === "capnp", "connector-backed Runtime lost its configured codec");
	assert(seen[0].options === operation.data, "Runtime did not borrow the operation override");
	assert(seen[1].options == null, "Runtime retained an override into the next operation");

	await runtime.close();
	assert(host.connectorFor("test") == null, "Runtime teardown retained connector authority");
});

Deno.test("Host connector installation is transactional", async () => {
	const host = new Host();
	const first = new Connector(["first"], () => Promise.resolve(fakeSession(1)));
	const conflicting = new Connector(["second", "first"], () => Promise.resolve(fakeSession(2)));
	let failed = false;
	try {
		host.installConnectors([first, conflicting]);
	} catch {
		failed = true;
	}
	assert(failed, "conflicting connector composition was accepted");
	assert(
		host.connectorFor("first") == null,
		"failed composition partially installed a connector",
	);
	assert(
		host.connectorFor("second") == null,
		"failed composition partially installed a connector",
	);
	await host.close();
});

Deno.test("an invalid Runtime close leaves admission open", async () => {
	let connects = 0;
	const connector = new Connector(["test"], () => {
		connects += 1;
		return Promise.resolve(fakeSession(connects));
	});
	const runtime = await Runtime.open({ connectors: [connector] });
	let failed = false;
	try {
		await runtime.close({ pending: "finish" } as unknown as CloseOptions);
	} catch {
		failed = true;
	}
	assert(failed, "Runtime accepted finish without an explicit grace budget");
	await runtime.connect({
		transport: "test",
		designator: "still-open",
		hints: new Map(),
		hintWireForm: "boolean-false",
	});
	assert(connects === 1, "invalid close sealed Runtime admission");
	await runtime.close();
});

Deno.test("finite close grace preserves the C field representation", () => {
	encodeCloseOptions({ pending: "finish", graceMs: 0xffff_ffff });
	let failed = false;
	try {
		encodeCloseOptions({ pending: "finish", graceMs: 0x1_0000_0000 });
	} catch {
		failed = true;
	}
	assert(failed, "close accepted a finite grace outside its C field");
});

Deno.test("a failed provider setup leaves an adopted Host retryable", async () => {
	const host = new Host();
	let failed = false;
	try {
		await Runtime.open({
			adoptHost: host,
			providers: [{
				install() {
					throw new Error("provider setup failed");
				},
			}],
		});
	} catch {
		failed = true;
	}
	assert(failed, "provider setup failure was swallowed");
	assert(host.driverLoop != null, "failed setup detached the adopted loop");

	const retry = await Runtime.open({ adoptHost: host, providers: [tcp.provider()] });
	assert(host.driverLoop != null, "provider retry replaced the adopted Host");
	await retry.close();
});
