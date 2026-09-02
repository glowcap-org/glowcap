import * as tcp from "@glowcap/tcp";

import { INVALID_ARGUMENT } from "@glowcap/abi";

import { GlowcapError } from "../../runtime/mod.ts";
import { Netlayer as TcpNetlayer } from "../../tcp/transport.ts";
import { Netlayer as InprocNetlayer } from "@glowcap/inproc";

import { _connectIroh } from "../../iroh/impl.ts";

import { assert } from "./support.ts";

export async function run(): Promise<void> {
	let listenerRefusal: GlowcapError | null = null;
	try {
		await tcp.listen("127.0.0.1", 0);
	} catch (error) {
		if (error instanceof GlowcapError) listenerRefusal = error;
	}
	assert(
		listenerRefusal?.code === INVALID_ARGUMENT &&
			listenerRefusal.message.includes("runtime that can park the loop"),
		"Bun refuses native driver listeners before allocating a loop",
	);

	for (
		const [name, open] of [
			["TCP", () => new TcpNetlayer()],
			["inproc", () => new InprocNetlayer()],
		] as const
	) {
		let transportRefusal: Error | null = null;
		try {
			open();
		} catch (error) {
			if (error instanceof Error) transportRefusal = error;
		}
		assert(
			transportRefusal?.message.includes(
				"requires native calls to run off the JavaScript event loop",
			) ?? false,
			`Bun refuses the native ${name} lifecycle before allocating a handle`,
		);
	}
}
