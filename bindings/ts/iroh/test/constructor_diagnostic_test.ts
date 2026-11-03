import { Context, Reachability } from "@glowcap/runtime";
import { INVALID_ARGUMENT, IROH_CONFIG_REACHABILITY_OFF, IROH_CONFIG_SIZE } from "@glowcap/runtime/ffi";
import { irohS } from "../ffi.ts";
import { IrohNetlayer } from "../mod.ts";
import { DriverLoop } from "@glowcap/runtime/transport";
import { secondaryFailures } from "@glowcap/runtime";
import { _ensureIrohProvider } from "../impl.ts";
import { assert } from "../../test/assert.ts";

Deno.test("iroh provider refusal retains a failed release without replacing its reason", async () => {
	const primary = Object.freeze({
		then: () => {
			throw new Error("reason was awaited");
		},
	});
	const cleanup = new Error("release failed");
	let releases = 0;
	const netlayer = Object.create(IrohNetlayer.prototype) as IrohNetlayer;
	netlayer.nodeId = () => "endpoint";
	netlayer.installProvider = () => Promise.reject(primary);
	netlayer.release = () => {
		releases++;
		return Promise.reject(cleanup);
	};
	const loop = Object.create(DriverLoop.prototype) as DriverLoop;
	Object.defineProperty(loop, "wrapperHost", { value: () => ({ seed: new Uint8Array(32) }) });
	const originalOpen = IrohNetlayer.open;
	IrohNetlayer.open = () => Promise.resolve(netlayer);
	try {
		// Catch directly: returning the reason from an async assertion would
		// itself assimilate this thenable and obscure the production result.
		let caught = false;
		try {
			await _ensureIrohProvider(loop, { reachability: Reachability.Direct });
		} catch (error) {
			caught = true;
			assert(error === primary, "provider refusal was replaced");
		}
		assert(caught && releases === 1, "provider rollback skipped or repeated release");
		assert(secondaryFailures(primary)[0] === cleanup, "provider rollback lost the release failure");
	} finally {
		IrohNetlayer.open = originalOpen;
	}
});

Deno.test("off-thread iroh construction returns its worker diagnostic", async () => {
	let failure: unknown;
	try {
		await IrohNetlayer.open(
			{ reachability: Reachability.Direct },
			new Uint8Array(1),
		);
	} catch (error) {
		failure = error;
	}
	if (!(failure instanceof Error)) throw new Error("expected iroh construction to fail");
	if (!failure.message.includes("secret_seed must be empty or exactly 32 bytes")) {
		throw new Error(`missing worker diagnostic: ${failure.message}`);
	}
});

Deno.test("allocator-aware iroh construction returns its worker diagnostic", async () => {
	const context = Context.withAllocator({
		alloc: (size) => new Uint8Array(size),
		free: () => {},
	});
	try {
		const seed = new Uint8Array(1);
		const config = new Uint8Array(IROH_CONFIG_SIZE);
		new DataView(config.buffer).setUint32(
			IROH_CONFIG_REACHABILITY_OFF,
			Reachability.Direct,
			true,
		);
		const out = new Uint8Array(8);
		const error = new Uint8Array(257);
		const errorLen = new Uint8Array(8);
		const code = await irohS().glowcap_iroh_netlayer_new_in(
			context.pointer,
			seed,
			BigInt(seed.length),
			config,
			out,
			error,
			BigInt(error.length),
			errorLen,
		);
		if (code !== INVALID_ARGUMENT) {
			throw new Error(`expected invalid argument, got ${code}`);
		}
		const reported = Number(new DataView(errorLen.buffer).getBigUint64(0, true));
		const detail = new TextDecoder().decode(error.subarray(0, reported));
		if (!detail.includes("secret_seed must be empty or exactly 32 bytes")) {
			throw new Error(`missing allocator-aware worker diagnostic: ${detail}`);
		}
	} finally {
		context.release();
	}
});

Deno.test("off-thread iroh construction snapshots its identity seed", async () => {
	const seed = Uint8Array.from({ length: 32 }, (_, index) => index + 1);
	const original = seed.slice();
	const opening = IrohNetlayer.open({ reachability: Reachability.Direct }, seed);
	seed.fill(0xa5);

	const mutatedDuringOpen = await opening;
	let nodeId: string;
	try {
		nodeId = mutatedDuringOpen.nodeId();
	} finally {
		await mutatedDuringOpen.release();
	}

	const baseline = await IrohNetlayer.open(
		{ reachability: Reachability.Direct },
		original,
	);
	try {
		if (baseline.nodeId() !== nodeId) {
			throw new Error("caller mutation changed the off-thread endpoint identity");
		}
	} finally {
		await baseline.release();
	}
});
