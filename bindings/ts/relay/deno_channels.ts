// The two far-side dials a Deno relay opens, shared by the reference relay
// (`serve.ts`) and an embedding app relay (the rooms relay). The transport-
// agnostic pump (`webSocketRelay`) never dials — the caller hands it a channel —
// so each relay used to carry its own TCP and iroh channel factory. These are
// the one hardened copy of each: the TCP dial bounds its connect and closes
// every partial resource, and the iroh dial loads @pancake/iroh once and lazily.

import { type RelayChannel } from "./relay.ts";

const defaultTcpDialTimeoutMs = 5_000;

/** Open a raw TCP byte channel to `host:port`. A dial timeout bounds the connect
 * so a black-holed target cannot park the relay, and every partial resource is
 * released on failure — a late-winning connect is closed when it lands, and a
 * half-acquired reader is released if the writer lock fails — so no dial leaks an
 * fd. Backpressure is the awaited writer; `close` releases the locks and the
 * socket idempotently. */
export async function denoTcpChannel(
	host: string,
	port: number,
	opts: { dialTimeoutMs?: number } = {},
): Promise<RelayChannel> {
	const dialTimeoutMs = opts.dialTimeoutMs ?? defaultTcpDialTimeoutMs;
	const connecting = Deno.connect({ hostname: host, port });
	let dialTimer: number | undefined;
	let timedOut = false;
	let tcp: Deno.TcpConn;
	try {
		tcp = await Promise.race([
			connecting,
			new Promise<never>((_, reject) => {
				dialTimer = setTimeout(() => {
					timedOut = true;
					reject(new Error("TCP dial timeout"));
				}, dialTimeoutMs) as unknown as number;
			}),
		]);
	} finally {
		// Disarm the timer on the happy path (or it would later close the live
		// connection). If it already won the race, close the abandoned connect
		// when it lands late so a slow dial leaks no fd.
		clearTimeout(dialTimer);
		if (timedOut) connecting.then((late) => late.close()).catch(() => {});
	}
	let reader;
	try {
		reader = tcp.readable.getReader();
	} catch (err) {
		tcp.close();
		throw err;
	}
	let writer;
	try {
		writer = tcp.writable.getWriter();
	} catch (err) {
		reader.releaseLock();
		tcp.close();
		throw err;
	}
	return {
		read: async () => {
			const result = await reader.read();
			return result.done ? null : result.value;
		},
		write: (chunk) => writer.write(chunk),
		close: () => {
			reader.releaseLock();
			writer.releaseLock();
			tcp.close();
		},
	};
}

// Iroh is dialed through @pancake/iroh, imported lazily so a TCP-only relay run
// never loads the iroh FFI. Cache the promise, not the result, so concurrent
// dials load the module once.
type IrohRelayModule = {
	dialLocatorForRelay: (locator: string, reachability: unknown) => Promise<RelayChannel>;
	Reachability: Record<string, unknown>;
};
let irohModulePromise: Promise<IrohRelayModule> | null = null;

/** How the relay resolves an iroh target. `direct` trusts the locator's
 * advertised addresses — a conformance host on loopback — while `discovery`
 * resolves a node id through the n0 discovery services for a real deployment. */
export type IrohReach = "direct" | "discovery";

/** Open an iroh byte channel to `locator`, resolving it under `reach`. */
export async function denoIrohChannel(locator: string, reach: IrohReach): Promise<RelayChannel> {
	irohModulePromise ??= import("@pancake/iroh") as Promise<IrohRelayModule>;
	const iroh = await irohModulePromise;
	const reachability = reach === "discovery"
		? iroh.Reachability.Discovery
		: iroh.Reachability.Direct;
	return await iroh.dialLocatorForRelay(locator, reachability);
}
