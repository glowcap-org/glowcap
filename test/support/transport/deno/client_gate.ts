// The gate protocol a Deno live client speaks: fail a named gate, read a
// readiness field from the partner's stdout within the deadline, parse the port
// argument, and serve accepted sessions.

import { readUntil } from "../../../../apps/_demo/orchestrator.ts";

/** How long a partner has to print its readiness line. */
const READY_MS = 30_000;

export function fail(gate: string, msg: string): never {
	throw new Error(`${gate} FAILED: ${msg}`);
}

export async function readSwiss(
	reader: ReadableStreamDefaultReader<Uint8Array>,
	gate: string,
	miss = "never saw the readiness line",
): Promise<string> {
	return await readReadinessField(reader, "swiss", gate, miss);
}

export async function readSturdyrefPath(
	reader: ReadableStreamDefaultReader<Uint8Array>,
	gate: string,
	miss = "never saw the sturdyref path readiness field",
): Promise<string> {
	return await readReadinessField(reader, "sturdyref-path", gate, miss);
}

async function readReadinessField(
	reader: ReadableStreamDefaultReader<Uint8Array>,
	field: string,
	gate: string,
	miss: string,
): Promise<string> {
	const [, value] = await ready(reader, new RegExp(`"${field}":"([^"]+)"`), gate, miss);
	return value;
}

export function parseOptionalPortArg(gate: string): void {
	for (const a of Deno.args) {
		if (!a.startsWith("--port=")) fail(gate, `unknown argument '${a}'`);
	}
}

export function parsePort(gate: string, defaultPort: number, maxPort = 65535): number {
	let port = defaultPort;
	for (const a of Deno.args) {
		if (a.startsWith("--port=")) {
			port = Number(a.slice("--port=".length));
		} else {
			fail(gate, `unknown argument '${a}'`);
		}
	}
	if (!Number.isInteger(port) || port < 1 || port > maxPort) {
		fail(gate, `--port must be an integer in 1..${maxPort}`);
	}
	return port;
}

export async function acceptLoop(
	server: AsyncIterable<{ serve(): Promise<void> }>,
): Promise<void> {
	// tolerant: a session's serve rejects when its partner hangs up, which is that session's normal end.
	for await (const session of server) session.serve().catch(() => {});
}

export async function awaitGreeterReady(
	reader: ReadableStreamDefaultReader<Uint8Array>,
	gate: string,
	miss = "never saw the exporter's greeter readiness line",
): Promise<void> {
	await ready(reader, /"name":"greeter"/, gate, miss);
}

async function ready(
	reader: ReadableStreamDefaultReader<Uint8Array>,
	pattern: RegExp,
	gate: string,
	miss: string,
): Promise<RegExpMatchArray> {
	try {
		return await readUntil(reader, pattern, miss, READY_MS);
	} catch (error) {
		fail(gate, error instanceof Error ? error.message : String(error));
	}
}
