import { Context, Reachability } from "@pancake/runtime";
import { INVALID_ARGUMENT, IROH_CONFIG_REACHABILITY_OFF, IROH_CONFIG_SIZE } from "@pancake/runtime/ffi";
import { irohS } from "../ffi.ts";
import { IrohNetlayer } from "../mod.ts";

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
		const code = await irohS().pancake_iroh_netlayer_new_in(
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
