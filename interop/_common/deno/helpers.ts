// Shared helpers for Deno interop client scripts.

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
	const decoder = new TextDecoder();
	let buf = "";
	const deadline = Date.now() + 30_000;
	while (Date.now() < deadline) {
		const { value, done } = await reader.read();
		if (done) break;
		buf += decoder.decode(value, { stream: true });
		const m = buf.match(new RegExp(`"${field}":"([^"]+)"`));
		if (m) return m[1];
	}
	fail(gate, miss);
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
	const decoder = new TextDecoder();
	let buf = "";
	const deadline = Date.now() + 30_000;
	while (Date.now() < deadline) {
		const { value, done } = await reader.read();
		if (done) break;
		buf += decoder.decode(value, { stream: true });
		if (buf.includes('"name":"greeter"')) return;
	}
	fail(gate, miss);
}
