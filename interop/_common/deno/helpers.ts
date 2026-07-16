// Shared helpers for Deno interop client scripts.

export function fail(gate: string, msg: string): never {
	console.error(`${gate} FAILED: ${msg}`);
	Deno.exit(1);
}

export async function readSwiss(
	reader: ReadableStreamDefaultReader<Uint8Array>,
	gate: string,
	miss = "never saw the readiness line",
): Promise<string> {
	const decoder = new TextDecoder();
	let buf = "";
	const deadline = Date.now() + 30_000;
	while (Date.now() < deadline) {
		const { value, done } = await reader.read();
		if (done) break;
		buf += decoder.decode(value, { stream: true });
		const m = buf.match(/"swiss":"([^"]+)"/);
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
	for await (const conn of server) conn.serve().catch(() => {});
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

export async function drainStderr(stderr: ReadableStream<Uint8Array>): Promise<string> {
	const chunks: Uint8Array[] = [];
	for await (const chunk of stderr) chunks.push(chunk);
	return new TextDecoder().decode(
		chunks.reduce((acc, c) => {
			const merged = new Uint8Array(acc.length + c.length);
			merged.set(acc);
			merged.set(c, acc.length);
			return merged;
		}, new Uint8Array()),
	);
}
