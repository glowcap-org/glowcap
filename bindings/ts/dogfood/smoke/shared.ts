import * as tcp from "@glowcap/tcp";

import { DEFAULT_FAILURE_CAPACITY, DEFAULT_FAILURE_PAYLOAD_CAP, INTERNAL, INVALID_ARGUMENT, IO } from "@glowcap/abi";

import {
	abiVersion,
	Context,
	formatSturdyRef,
	GlowcapError,
	Host,
	parseSturdyRef,
	takeRuntimeFailures,
} from "../../runtime/mod.ts";

import { entryFor } from "../../runtime/trampoline.ts";
import { type PumpHandle, raiseFeedRefusal } from "../../runtime/pump.ts";
import { _connectIroh } from "../../iroh/impl.ts";

import { recordCallerlessFailure, reportFailure } from "../../runtime/context.ts";

import { assert, eqBytes, ok } from "./support.ts";

export async function run(): Promise<void> {
	{
		using context = Context.create();
		reportFailure(context, {
			layer: "transport",
			scope: "listener",
			operation: "listener.close",
			primaryName: "CloseFailed",
			primaryResult: IO,
			primaryMessage: "socket refused shutdown",
			scopeId: 31n,
			operationId: 47n,
			secondaryResult: INTERNAL,
			secondaryName: "ReleaseFailed",
			secondaryMessage: "descriptor remained live",
			secondaryCount: 2,
		});
		const failures = context.takeFailures();
		assert(failures.length === 1, "Context claims one structured failure");
		const failure = failures[0];
		assert(failure.sequence === 1n && failure.droppedBefore === 0n, "Context preserves sequence and loss");
		assert(failure.layer === "transport" && failure.scope === "listener", "Context preserves layer and scope");
		assert(failure.scopeId === 31n && failure.operationId === 47n, "Context preserves lifecycle identity");
		assert(failure.primaryResult === IO && failure.secondaryResult === INTERNAL, "Context preserves typed results");
		assert(failure.secondaryCount === 2, "Context preserves secondary count");
		assert(
			failure.operation === "listener.close" && failure.primaryName === "CloseFailed" &&
				failure.primaryMessage === "socket refused shutdown" && failure.secondaryName === "ReleaseFailed" &&
				failure.secondaryMessage === "descriptor remained live",
			"Context preserves diagnostic text",
		);
		assert(context.nextFailure() === null, "Context claims a diagnostic only once");
	}
	ok("Context preserves the cross-language native failure vector exactly once");

	{
		takeRuntimeFailures();
		using malformedContext = Context.create();
		let malformedRefused = false;
		try {
			recordCallerlessFailure(malformedContext, {
				layer: "binding",
				scope: "context",
				operation: "diagnostic.invalid",
				primaryName: "InvalidReport",
				primaryResult: INTERNAL,
				secondaryName: "Contradiction",
			});
		} catch (error) {
			malformedRefused = error instanceof TypeError;
		}
		assert(malformedRefused, "a contradictory internal diagnostic report is refused");
		assert(takeRuntimeFailures().length === 0, "an invalid internal report cannot enter either diagnostic queue");

		const context = Context.create();
		context.release();
		recordCallerlessFailure(context, {
			layer: "application-observer",
			scope: "host",
			operation: "trace.sink",
			primaryName: "Error",
			primaryResult: INTERNAL,
			primaryMessage: "observer failed",
		});
		const fallback = takeRuntimeFailures();
		assert(fallback.length === 2, "a refused Context recorder preserves both failures");
		assert(
			fallback[0].layer === "application-observer" && fallback[0].operation === "trace.sink" &&
				fallback[0].primaryMessage === "observer failed",
			"the process fallback preserves the original callerless failure",
		);
		assert(
			fallback[1].layer === "binding" && fallback[1].operation === "trace.sink.diagnostic",
			"the process fallback preserves the recorder failure separately",
		);

		const overflowAttempts = Math.floor(DEFAULT_FAILURE_CAPACITY / 2) + 8;
		for (let index = 0; index < overflowAttempts; index++) {
			recordCallerlessFailure(context, {
				layer: "binding",
				scope: "process",
				operation: "☃".repeat(600),
				primaryName: "Error",
				primaryResult: INTERNAL,
			});
		}
		const bounded = takeRuntimeFailures();
		const producedRecords = overflowAttempts * 2;
		assert(
			bounded.length === DEFAULT_FAILURE_CAPACITY &&
				bounded[0].droppedBefore === BigInt(producedRecords - DEFAULT_FAILURE_CAPACITY),
			"the process fallback exposes saturation",
		);
		assert(
			new TextEncoder().encode(bounded.at(-2)!.operation).byteLength <= DEFAULT_FAILURE_PAYLOAD_CAP &&
				!bounded.at(-2)!.operation.includes("�"),
			"the process fallback truncates UTF-8 at the shared byte bound",
		);
	}

	{
		const projectionFailure = new Error("abort write failed");
		const handle = {
			released: true,
			kickActions: () => Promise.reject(projectionFailure),
		} as unknown as PumpHandle;
		try {
			await raiseFeedRefusal(handle, INVALID_ARGUMENT);
			assert(false, "feed refusal must throw");
		} catch (error) {
			assert(error instanceof GlowcapError, "feed refusal stays typed");
			assert(
				error.cause === projectionFailure,
				"feed refusal retains the exact effect-drain failure as its cause",
			);
		}
		ok("feed refusal retains a secondary effect-drain failure");
	}

	const parsedSturdyRef = parseSturdyRef(
		"ocapn://wy46gxdweyqn5m7ntzwlxinhdia2jjanlsh37gxklwhfec7yxqr4k3qd.onion/s/eQjP4nR28ffX5eoNCK5DWH6DT_d7BIqD3-My459CUbU",
		"v1_0",
	);
	assert(
		parsedSturdyRef.locator.transport === "onion",
		"sturdyref locator transport survives parsing",
	);
	assert(
		eqBytes(
			parsedSturdyRef.swissnum,
			Uint8Array.of(
				0x79,
				0x08,
				0xcf,
				0xe2,
				0x74,
				0x76,
				0xf1,
				0xf7,
				0xd7,
				0xe5,
				0xea,
				0x0d,
				0x08,
				0xae,
				0x43,
				0x58,
				0x7e,
				0x83,
				0x4f,
				0xf7,
				0x7b,
				0x04,
				0x8a,
				0x83,
				0xdf,
				0xe3,
				0x32,
				0xe3,
				0x9f,
				0x42,
				0x51,
				0xb5,
			),
		),
		"sturdyref swiss authority survives parsing",
	);
	const formattedSturdyRef = formatSturdyRef(
		tcp.locator("127.0.0.1", 9045),
		new TextEncoder().encode("durable:0123456789abcdef"),
		"v1_0",
	);
	assert(
		eqBytes(
			parseSturdyRef(formattedSturdyRef, "v1_0").swissnum,
			new TextEncoder().encode("durable:0123456789abcdef"),
		),
		"sturdyref formatting round-trips opaque authority",
	);

	// The linked library reports a real ABI version.
	const [major, minor, patch] = abiVersion();
	assert(
		major + minor + patch > 0,
		`abiVersion is nonzero, got ${major}.${minor}.${patch}`,
	);

	for (const invalidSeed of [new Uint8Array(31), new Uint8Array(33)]) {
		let refused = false;
		try {
			new Host(invalidSeed);
		} catch (error) {
			refused = error instanceof GlowcapError && error.code === INVALID_ARGUMENT;
		}
		assert(refused, "Host must reject a seed that is not 32 bytes");
	}

	{
		const callerSeed = Uint8Array.from({ length: 32 }, (_, i) => i);
		const ownedSeedHost = new Host(callerSeed);
		try {
			const expectedDesignator = ownedSeedHost.designator();
			callerSeed[0] ^= 0xff;
			const exposedSeed = ownedSeedHost.seed;
			exposedSeed[0] ^= 0xff;
			assert(
				ownedSeedHost.designator() === expectedDesignator,
				"Host identity must not follow caller or returned seed mutation",
			);
		} finally {
			await ownedSeedHost.close();
		}
	}

	// A hosted behavior may close over its own Host. The live Host retains that
	// callback, while the process-global trampoline lookup stays weak so the cycle
	// remains collectable; deterministic release removes the lookup immediately.
	{
		const host = new Host();
		host.publish("cycle", () => host.designator());
		const ctx = host.publicationCtx("cycle");
		assert(ctx != null && entryFor(ctx) != null, "a live Host retains its callback entry");
		const closing = host.close();
		assert(entryFor(ctx) != null, "Host close retains callbacks until its barrier completes");
		await closing;
		assert(entryFor(ctx) == null, "Host close retires its callback entry at the barrier");
	}
}
