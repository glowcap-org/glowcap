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

import type { Page } from "playwright";
import { takeCapability } from "../page/capability_set.ts";

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

/** Acquire the announced trace capability through the production Holdings form. */
export async function acquireTraceCapability(page: Page, sturdyref: string): Promise<void> {
	await page.click("#settingsBtn");
	await page.click("#holdingsTab");
	await takeCapability(page, "#opsTraceToggle", sturdyref);
	await page.click("#settingsClose");
}
