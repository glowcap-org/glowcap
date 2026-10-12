#!/usr/bin/env -S deno run --allow-net
/**
 * cdp-debug.ts: connect to a chromium CDP session and dump
 * console messages + uncaught errors. Used by visual-verify.sh
 * when the screenshot looks blank, points at the JS exception
 * that crashed the page.
 *
 * Usage:
 *   deno run --allow-net cdp-debug.ts <wsUrl>
 */

const wsUrl = Deno.args[0];
if (!wsUrl) {
	console.error("usage: cdp-debug.ts <wsUrl>");
	Deno.exit(1);
}

const ws = new WebSocket(wsUrl);
await new Promise<void>((resolve, reject) => {
	ws.onopen = () => resolve();
	ws.onerror = (e) => reject(new Error(`ws error: ${JSON.stringify(e)}`));
	setTimeout(() => reject(new Error("ws connect timeout")), 5000);
});

let nextId = 1;
ws.onmessage = (e) => {
	if (typeof e.data !== "string") return;
	const msg = JSON.parse(e.data);
	if (msg.method === "Console.messageAdded") {
		const m = msg.params.message;
		console.log(
			`[${m.level}] ${m.text}${m.url ? ` (${m.url}:${m.line})` : ""}`,
		);
	} else if (msg.method === "Runtime.exceptionThrown") {
		const ex = msg.params.exceptionDetails;
		console.log(
			`[exception] ${ex.text}: ${ex.exception?.description ?? ""}${
				ex.stackTrace
					? "\n" + ex.stackTrace.callFrames
						.map((
							f: { functionName: string; url: string; lineNumber: number },
						) => `  at ${f.functionName} (${f.url}:${f.lineNumber})`)
						.join("\n")
					: ""
			}`,
		);
	} else if (msg.method === "Runtime.consoleAPICalled") {
		const args = msg.params.args
			.map((a: { value?: unknown; description?: string }) =>
				a.value !== undefined ? JSON.stringify(a.value) : (a.description ?? "?")
			)
			.join(" ");
		console.log(`[console.${msg.params.type}] ${args}`);
	}
};

function send(method: string, params: Record<string, unknown> = {}) {
	ws.send(JSON.stringify({ id: nextId++, method, params }));
}

send("Console.enable");
send("Runtime.enable");
send("Runtime.evaluate", { expression: "document.title" });

// Listen for 5 seconds then exit.
await new Promise((r) => setTimeout(r, 5000));
ws.close();
