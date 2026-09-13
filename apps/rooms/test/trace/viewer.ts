// The capability viewer the browser proofs watch the live timeline with.
//
// The native Rooms server hands records to an OCapN viewer:
// the WebSocket is only the byte channel, and records arrive through an inbox
// capability after enlivening the `ROOMS-TRACE-LISTENING` sturdyref the server
// announces on stderr. Raw JSON text frames stopped being the viewer contract
// when the endpoint moved to capability delivery, so a proof that watched the
// socket directly would drop every record unheard. This module is the one
// place the proofs connect, so the contract has one consumer shape to drift
// against.

import { originTraceUrl } from "../../lib/trace_publish.ts";
import { traceCapOf } from "../../lib/trace_view.ts";
import {
	DEFAULT_ROOMS_VIEW_STATE,
	emptyRoomsSessionState,
	WORKSPACE_STATE_KEY,
	WORKSPACE_STATE_VERSION,
} from "../../lib/rooms_state.ts";

// The viewer contract itself is shared with the `rooms-trace-tail` tool, so it
// lives beside the publishing half rather than under the proofs. What stays
// here is what only a proof needs: scraping the announcement out of a child's
// stderr, and seeding a tab's remembered capability.
export { connectTraceViewer, traceCapOf, tracePortOf, type TraceRecord, traceUrlOf } from "../../lib/trace_view.ts";

const ANNOUNCE = "ROOMS-TRACE-LISTENING ";

/** Tee the child's stderr through to this process and resolve the announced
 * trace sturdyref when it passes by. The stream keeps flowing after the match,
 * so the run stays observable and the child never blocks on a full pipe. */
export function scrapeTraceSturdyref(stderr: ReadableStream<Uint8Array>): Promise<string> {
	let resolve!: (ref: string) => void;
	let reject!: (err: Error) => void;
	const found = new Promise<string>((res, rej) => {
		resolve = res;
		reject = rej;
	});
	(async () => {
		const decoder = new TextDecoder();
		let tail = "";
		for await (const chunk of stderr) {
			await Deno.stderr.write(chunk).catch(() => {});
			tail += decoder.decode(chunk, { stream: true });
			let nl: number;
			while ((nl = tail.indexOf("\n")) !== -1) {
				const line = tail.slice(0, nl);
				tail = tail.slice(nl + 1);
				const mark = line.indexOf(ANNOUNCE);
				if (mark !== -1) resolve(line.slice(mark + ANNOUNCE.length).trim());
			}
		}
		reject(new Error("rooms-server ended without announcing a trace sturdyref"));
	})().catch((err) => reject(err instanceof Error ? err : new Error(String(err))));
	return found;
}

/** The localStorage row that arms a rooms tab's publishing from first load:
 * the remembered-swiss auto-redeem is production code, and a proof seeds it
 * the way a reader who checked "Remember on this device" would have.
 *
 * `pagePort` is the port the tab is served from, not the endpoint's own. A
 * browser reaches the timeline through `/trace` and `/publish` on the server
 * that served it, so the endpoint's port is not a name a tab ever holds, and
 * the row it looks up is keyed by that proxied address. Both halves of the
 * key come from the modules that read it rather than being written out here,
 * because a seed under a key nothing reads is silent: the tab arms nothing,
 * joins and chats as usual, and the proof fails much later at the endpoint
 * having heard from one producer. */
export function traceMemorySeed(pagePort: number, sturdyref: string): { key: string; value: string } {
	const endpoint = originTraceUrl({ protocol: "http:", host: `127.0.0.1:${pagePort}` });
	return {
		key: WORKSPACE_STATE_KEY,
		value: JSON.stringify({
			version: WORKSPACE_STATE_VERSION,
			controller: { kind: "local" },
			session: {
				...emptyRoomsSessionState(),
				capabilities: {
					operations: [{ capability: "trace", scope: endpoint, swiss: traceCapOf(sturdyref) }],
					archivePeer: null,
				},
			},
			view: {
				...DEFAULT_ROOMS_VIEW_STATE,
				opsPane: "trace",
			},
		}),
	};
}
