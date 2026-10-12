#!/usr/bin/env -S deno run -A
// Tail a Rooms server's live trace as lines.
//
// `--trace` makes a server publish every OCapN session it and its members open,
// and ocapnviz in a browser is the other way to read that. A picture
// is the right tool for topology and the wrong one for "what did this peer do
// just now, in order", which is the question a terminal answers.
//
// It takes the sturdyref the server announces on stderr as
// `ROOMS-TRACE-LISTENING`, because that one string carries both halves a viewer
// needs, where the endpoint is, and the capability that admits a socket. There
// is no second secret to find and nothing to assemble.
//
// The viewer contract itself lives in `lib/trace_view.ts`, shared with the
// browser proofs, so this adds a rendering and not a fifth implementation of
// how to read the feed.

import { connectTraceViewer, traceLine, type TraceRecord } from "../lib/trace_view.ts";

const usage = `Tail a Rooms server's live trace.

  rooms-trace-tail <sturdyref> [--json]

<sturdyref> is what the server prints after ROOMS-TRACE-LISTENING when it is
started with --trace. --json passes each record through unchanged, one per
line, for piping into something else.
`;

const args = Deno.args.filter((arg) => arg !== "--json");
const raw = Deno.args.includes("--json");
if (args.length !== 1 || args[0] === "--help" || args[0] === "-h") {
	console.error(usage);
	Deno.exit(args.length === 1 ? 0 : 2);
}
const sturdyref = args[0];

const write = (line: string) => {
	// Written straight out rather than through console.log so a closed pipe
	// (`… | head`) ends this quietly instead of as an unhandled failure.
	try {
		Deno.stdout.writeSync(new TextEncoder().encode(line + "\n"));
	} catch {
		// best-effort: a reader that has gone away takes the tail with it.
		Deno.exit(0);
	}
};

let viewer: { closed: Promise<void>; close(): Promise<void> };
try {
	viewer = await connectTraceViewer(sturdyref, (record: TraceRecord) => {
		write(raw ? JSON.stringify(record) : traceLine(record));
	});
} catch (error) {
	console.error(`rooms-trace-tail: ${error instanceof Error ? error.message : String(error)}`);
	Deno.exit(1);
}

// Ctrl-C closes the session rather than dropping the socket, so the endpoint
// retires this viewer on its own turn instead of noticing a dead peer later.
const stop = async () => {
	try {
		await viewer.close();
		Deno.exit(0);
	} catch (error) {
		console.error(`rooms-trace-tail: ${error instanceof Error ? error.message : String(error)}`);
		Deno.exit(1);
	}
};
Deno.addSignalListener("SIGINT", () => void stop());
Deno.addSignalListener("SIGTERM", () => void stop());

// Records arrive through the inbox capability until the session ends. Ending
// when it does is the point: a tail still running past its feed shows a quiet
// room where what happened is that the server went away, and from the outside
// those read the same.
await viewer.closed;
console.error("rooms-trace-tail: the trace endpoint closed the session");
