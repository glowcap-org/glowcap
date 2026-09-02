// Shared iroh/TCP shell for durable standalone Rooms peers.

import {
	formatPeerUri,
	type Host,
	retainCleanupFailures,
	secondaryFailures,
	type Session,
	TRANSPORT_IROH,
} from "@glowcap/runtime";
import * as irohTransport from "@glowcap/iroh";
import { isWildcardHost } from "./bind_host.ts";
import { roomsListen } from "./locator.ts";
import { optionalEnv } from "./env.ts";
import { routinePeerDisconnect } from "./session_failure.ts";

export type StandaloneTransport = "iroh" | "tcp";

export interface ClosingServer extends AsyncIterable<Session> {
	close(): void;
}

export interface StandalonePeerOptions {
	readonly args: readonly string[];
	readonly envPrefix: string;
	readonly label: string;
}

function option(args: readonly string[], name: string): string | undefined {
	return args.find((arg) => arg.startsWith(`--${name}=`))?.slice(name.length + 3);
}

function envName(options: StandalonePeerOptions, suffix: string): string {
	return `${options.envPrefix}_${suffix}`;
}

function transportChoice(options: StandalonePeerOptions): StandaloneTransport {
	const raw = option(options.args, "transport") ?? optionalEnv(envName(options, "TRANSPORT")) ?? "iroh";
	if (raw !== "iroh" && raw !== "tcp") throw new Error(`unknown transport "${raw}" (expected iroh or tcp)`);
	return raw;
}

function portChoice(options: StandalonePeerOptions): number {
	const raw = option(options.args, "port") ?? optionalEnv(envName(options, "PORT")) ?? "0";
	const port = Number(raw);
	if (!Number.isInteger(port) || port < 0 || port > 65535) {
		throw new Error(`${options.label} port is not a port: "${raw}"`);
	}
	return port;
}

function reachabilityChoice(options: StandalonePeerOptions):
	| typeof irohTransport.Reachability.Direct
	| typeof irohTransport.Reachability.Discovery {
	const raw = option(options.args, "reachability") ?? optionalEnv(envName(options, "REACHABILITY")) ?? "discovery";
	if (raw === "direct") return irohTransport.Reachability.Direct;
	if (raw === "discovery") return irohTransport.Reachability.Discovery;
	throw new Error(`unknown reachability "${raw}" (expected direct or discovery)`);
}

/** The one iroh configuration a standalone peer installs for both its listener
 * and any outbound dials on the same Host runtime. */
export function standaloneIrohConfig(options: StandalonePeerOptions): irohTransport.IrohConfig | null {
	if (transportChoice(options) !== "iroh") return null;
	return { reachability: reachabilityChoice(options), idleTimeoutMs: 8_000 };
}

export async function listenStandalone(
	host: Host,
	options: StandalonePeerOptions,
): Promise<{ server: ClosingServer; locator: string; transport: StandaloneTransport }> {
	const transport = transportChoice(options);
	if (transport === "iroh") {
		const config = standaloneIrohConfig(options);
		if (config == null) throw new Error("the standalone iroh listener has no iroh configuration");
		const server = await irohTransport.listen(config, { host });
		const reachability = config.reachability;
		const locator = reachability === irohTransport.Reachability.Discovery
			? formatPeerUri(TRANSPORT_IROH, server.nodeId)
			: server.uri;
		return { server, locator, transport };
	}

	const bind = option(options.args, "bind") ?? optionalEnv(envName(options, "BIND")) ?? "127.0.0.1";
	const announce = option(options.args, "announce-host") ?? optionalEnv(envName(options, "ANNOUNCE_HOST"));
	if (isWildcardHost(bind) && announce == null) {
		throw new Error(`${options.label} bind ${bind} needs --announce-host=<dialable-host>`);
	}
	const server = await roomsListen(bind, portChoice(options), host, announce);
	return { server, locator: server.designator, transport };
}

function failureText(error: unknown): string {
	return error instanceof Error ? error.message : String(error);
}

async function serveConnection(session: Session): Promise<void> {
	try {
		await session.serve();
	} catch (error) {
		throw await retainCleanupFailures(error, [() => session.close()]);
	}
	await session.close();
}

function reportConnectionFailure(label: string, error: unknown): void {
	if (!routinePeerDisconnect(error)) {
		console.error(`${label}: a peer connection ended unexpectedly: ${failureText(error)}`);
	}
	for (const cleanup of secondaryFailures(error)) {
		console.error(`${label}: closing that connection also failed: ${failureText(cleanup)}`);
	}
}

export async function serveStandalone(server: ClosingServer, label: string): Promise<void> {
	const stop = () => server.close();
	Deno.addSignalListener("SIGINT", stop);
	Deno.addSignalListener("SIGTERM", stop);
	try {
		for await (const session of server) {
			// One failed client must not tear down the listener. Its detached task
			// still owns both the primary failure and every close consequence.
			void serveConnection(session).catch((error) => reportConnectionFailure(label, error));
		}
	} finally {
		Deno.removeSignalListener("SIGINT", stop);
		Deno.removeSignalListener("SIGTERM", stop);
	}
}
