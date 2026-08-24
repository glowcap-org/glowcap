import * as tcp from "../../tcp/mod.ts";
import { INVALID_ARGUMENT, IO, LIFECYCLE_ACTIVE, LIFECYCLE_CLOSED, OK } from "@pancake/abi";
import { Connector } from "../transport.ts";
import { Host } from "../host.ts";
import { type CloseOptions, encodeCloseOptions, lifecycleClosed, releaseConsumed } from "../lifecycle.ts";
import { Runtime } from "../runtime.ts";
import { Context, recordCallerlessFailure, takeRuntimeFailures } from "../context.ts";
import { PancakeError } from "../errors.ts";
import { designatorHostPort, parseLocator } from "../locator.ts";
import type { Session } from "../session.ts";
import { requireArchiveFingerprint } from "../internal/ffi/runtime.ts";
import { curlTransportArgs, HardFailError, requireSecureReleaseUrl } from "../internal/ffi/release_security.ts";
import { deferFinalizerRetry, pendingFinalizerRetryCount } from "../finalizer_retry.ts";

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

Deno.test("empty locator inputs refuse as grammar errors before FFI", () => {
	for (
		const [name, parse] of [
			["locator", () => parseLocator("")],
			["designator", () => designatorHostPort("")],
		] as const
	) {
		let refusal: unknown = null;
		try {
			parse();
		} catch (error) {
			refusal = error;
		}
		assert(refusal instanceof PancakeError, `${name} did not return a typed refusal`);
		assert(refusal.code === INVALID_ARGUMENT, `${name} empty input crossed as a non-grammar failure`);
	}
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

Deno.test("release downloads enforce the shared transport policy", () => {
	requireSecureReleaseUrl("https://example.invalid/releases", false);
	let refusal: unknown = null;
	try {
		requireSecureReleaseUrl("http://example.invalid/releases", false);
	} catch (error) {
		refusal = error;
	}
	assert(refusal instanceof HardFailError, "an insecure release URL did not fail closed");
	assert(refusal.name === "HardFailError", "the archive resolver changed its failure contract");
	requireSecureReleaseUrl("http://example.invalid/releases", true);
	assert(
		curlTransportArgs("https://example.invalid/archive", true).join(" ") === "--proto =https --tlsv1.2",
		"the insecure escape weakened an HTTPS download",
	);
	assert(
		curlTransportArgs("http://example.invalid/archive", true).length === 0,
		"the explicit insecure escape retained contradictory curl TLS flags",
	);
});

Deno.test("Host session limits carry independent transient and durable byte budgets", async () => {
	const host = new Host();
	host.setSessionLimits({
		maxFrameBytes: 64 * 1024,
		outboundHighWaterBytes: 128 * 1024,
		maxRetainedSentAnswerBytes: 8 * 1024 * 1024,
	});
	let refused = false;
	try {
		host.setSessionLimits({ maxRetainedSentAnswerBytes: -1 });
	} catch (error) {
		refused = error instanceof Error && error.message.includes("non-negative");
	}
	assert(refused, "a negative durable-answer budget crossed the FFI boundary");
	await host.close();
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

Deno.test("public Host boundaries retry one claimed finalizer batch without spinning", async () => {
	let attempts = 0;
	const attemptCount = () => attempts;
	const retry = () => {
		attempts++;
		if (attempts === 1) deferFinalizerRetry(retry);
	};
	deferFinalizerRetry(retry);
	const host = new Host();
	assert(attemptCount() === 1, "one boundary retried a refusal more than once");
	assert(pendingFinalizerRetryCount() === 1, "a repeated refusal lost its owner");
	host.drainParkedReleases();
	assert(attemptCount() === 2, "the next public boundary did not retry the retained release");
	assert(pendingFinalizerRetryCount() === 0, "a successful retry stayed retained");
	await host.close();
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
