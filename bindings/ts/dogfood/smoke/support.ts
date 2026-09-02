import process from "node:process";

import { connectTcp, listenTcp, type NetConn } from "../../runtime/internal/seam.ts";
import { type Argument } from "../../runtime/mod.ts";

import { _connectIroh } from "../../iroh/impl.ts";

export const runtime = typeof (globalThis as { Bun?: unknown }).Bun !== "undefined"
	? "bun"
	: typeof (globalThis as { Deno?: unknown }).Deno !== "undefined"
	? "deno"
	: "node";

export function assert(cond: boolean, msg: string): asserts cond {
	if (!cond) {
		console.error(`${runtime} zig-smoke FAILED: ${msg}`);
		process.exit(1);
	}
}

export function ok(msg: string): void {
	console.log(`${runtime} zig-smoke OK: ${msg}`);
}

export function eqBytes(a: Uint8Array, b: Uint8Array): boolean {
	return a.length === b.length && a.every((v, i) => v === b[i]);
}

export async function within<T>(promise: Promise<T>, milliseconds: number, label: string): Promise<T> {
	let timer: ReturnType<typeof setTimeout> | undefined;
	try {
		return await Promise.race([
			promise,
			new Promise<T>((_resolve, reject) => {
				timer = setTimeout(() => reject(new Error(`${label} timed out`)), milliseconds);
			}),
		]);
	} finally {
		if (timer != null) clearTimeout(timer);
	}
}

// A byte-level TCP relay between a client and a server that are both real
// glowcap connections: it shuttles raw bytes both ways, optionally rewriting
// the client->server stream and observing the traffic. This is how the smoke
// watches the wire (a gc release frame) or doctors it (a retargeted fetch)
// without either endpoint dropping out of the application surface.

export async function startRelay(
	targetPort: number,
	rewriteToServer: (chunk: Uint8Array) => Uint8Array = (c) => c,
	observe: (chunk: Uint8Array, toServer: boolean) => void = () => {},
): Promise<{ port: number; close: () => void }> {
	const listener = await listenTcp("127.0.0.1", 0);
	const open: NetConn[] = [];
	void (async () => {
		while (true) {
			let client: NetConn;
			try {
				client = await listener.accept();
			} catch {
				return; // the relay was closed
			}
			const server = await connectTcp("127.0.0.1", targetPort);
			open.push(client, server);
			void (async () => {
				while (true) {
					const chunk = await client.read().catch(() => null);
					if (chunk === null) break;
					observe(chunk, true);
					await server.write(rewriteToServer(chunk)).catch(() => {});
				}
				server.close();
			})();
			void (async () => {
				while (true) {
					const chunk = await server.read().catch(() => null);
					if (chunk === null) break;
					observe(chunk, false);
					await client.write(chunk).catch(() => {});
				}
				client.close();
			})();
		}
	})();
	return {
		port: listener.port,
		close: () => {
			listener.close();
			for (const c of open) c.close();
		},
	};
}

// A counter behavior reused by the round-trip tests: "add" adds args[0] to the
// count and returns it, "get" reads it, anything else throws (a break).
export function counterBehavior(start: bigint): (verb: string, args: Argument[]) => Argument {
	let count = start;
	return (verb: string, args: Argument[]): Argument => {
		if (verb === "add") {
			const n = args[0];
			count += typeof n === "bigint" ? n : BigInt(n as number);
			return count;
		}
		if (verb === "get") return count;
		throw new Error(`unknown verb ${verb}`);
	};
}
