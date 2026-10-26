// The two far-side dials a Deno relay opens, shared by the reference relay
// (`serve.ts`) and an embedding app relay (the rooms relay). The transport-
// agnostic pump (`webSocketRelay`) never dials: the caller hands it a channel,
// agnostic pump (`webSocketRelay`) never dials: the caller hands it a channel.
// These are the one hardened copy of each: the TCP dial bounds its connect and closes
// every partial resource, and the iroh dial loads @glowcap/iroh once and lazily.

import type { RelayChannel } from "./relay.ts";
import type { Timer } from "@glowcap/runtime/transport";
import { recordProcessBindingFailure, retainCleanupFailures, retainSecondaryFailure } from "@glowcap/runtime/transport";
import { BINDING_RELAY_TCP_DIAL_TIMEOUT_MS } from "@glowcap/abi";

const defaultTcpDialTimeoutMs = BINDING_RELAY_TCP_DIAL_TIMEOUT_MS;

function closeTcp(tcp: Deno.TcpConn): void {
	try {
		tcp.close();
	} catch (error) {
		if (error instanceof Deno.errors.BadResource) return;
		throw error;
	}
}

/** Open a raw TCP byte channel to `host:port`. A dial timeout bounds the connect
 * so a black-holed target cannot park the relay, and every partial resource is
 * released on failure (a late-winning connect is closed when it lands, and a
 * half-acquired reader is released if the writer lock fails), so no dial leaks an
 * fd. Backpressure is the awaited writer; `close` releases the locks and the
 * socket idempotently. */
export async function denoTcpChannel(
	host: string,
	port: number,
	opts: { dialTimeoutMs?: number } = {},
): Promise<RelayChannel> {
	const dialTimeoutMs = opts.dialTimeoutMs ?? defaultTcpDialTimeoutMs;
	const connecting = Deno.connect({ hostname: host, port });
	let dialTimer: Timer | undefined;
	let timedOut = false;
	let tcp: Deno.TcpConn;
	try {
		tcp = await Promise.race([
			connecting,
			new Promise<never>((_, reject) => {
				dialTimer = setTimeout(() => {
					timedOut = true;
					reject(new Error("TCP dial timeout"));
				}, dialTimeoutMs);
			}),
		]);
	} finally {
		// Disarm the timer on the happy path (or it would later close the live
		// connection). If it already won the race, close the abandoned connect
		// when it lands late so a slow dial leaks no fd.
		clearTimeout(dialTimer);
		if (timedOut) {
			void connecting.then(
				(late) => {
					try {
						closeTcp(late);
					} catch (error) {
						recordProcessBindingFailure("relay.tcp.dial.late-close", error);
					}
				},
				(error) => recordProcessBindingFailure("relay.tcp.dial.late-settlement", error),
			);
		}
	}
	let reader;
	try {
		reader = tcp.readable.getReader();
	} catch (err) {
		throw await retainCleanupFailures(err, [() => tcp.close()]);
	}
	let writer;
	try {
		writer = tcp.writable.getWriter();
	} catch (err) {
		throw await retainCleanupFailures(err, [
			() => reader.releaseLock(),
			() => tcp.close(),
		]);
	}
	let closeBarrier: Promise<void> | null = null;
	return {
		read: async () => {
			const result = await reader.read();
			return result.done ? null : result.value;
		},
		write: (chunk) => writer.write(chunk),
		close: () => {
			if (closeBarrier != null) return closeBarrier;
			closeBarrier = Promise.resolve().then(() => {
				let primary: { readonly error: unknown } | null = null;
				for (
					const release of [
						() => closeTcp(tcp),
						() => reader.releaseLock(),
						() => writer.releaseLock(),
					]
				) {
					try {
						release();
					} catch (error) {
						primary = primary == null ? { error } : { error: retainSecondaryFailure(primary.error, error) };
					}
				}
				if (primary != null) throw primary.error;
			});
			void closeBarrier.catch(() => {});
			return closeBarrier;
		},
	};
}

// Iroh is dialed through @glowcap/iroh, imported lazily so a TCP-only relay run
// never loads the iroh FFI. Cache the promise, not the result, so concurrent
// dials load the module once.
type IrohRelayModule = {
	dialLocatorForRelay: (locator: string, reachability: unknown) => Promise<RelayChannel>;
	Reachability: Record<string, unknown>;
};
let irohModulePromise: Promise<IrohRelayModule> | null = null;

/** How the relay resolves an iroh target. `direct` trusts the locator's
 * advertised addresses (a conformance host on loopback), while `discovery`
 * resolves a node id through the n0 discovery services for a real deployment. */
export type IrohReach = "direct" | "discovery";

/** Open an iroh byte channel to `locator`, resolving it under `reach`. */
export async function denoIrohChannel(locator: string, reach: IrohReach): Promise<RelayChannel> {
	irohModulePromise ??= import("@glowcap/iroh") as Promise<IrohRelayModule>;
	const iroh = await irohModulePromise;
	const reachability = reach === "discovery" ? iroh.Reachability.Discovery : iroh.Reachability.Direct;
	return await iroh.dialLocatorForRelay(locator, reachability);
}
