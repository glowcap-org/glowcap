// The capability viewer the browser proofs watch the live timeline with.
//
// The endpoint hands records to an OCapN viewer (`apps/rooms/server/viz.ts`):
// the WebSocket is only the byte channel, and records arrive through an inbox
// capability after enlivening the `ROOMS-VIZ-LISTENING` sturdyref the server
// announces on stderr. Raw JSON text frames stopped being the viewer contract
// when the endpoint moved to capability delivery, so a proof that watched the
// socket directly would drop every record unheard. This module is the one
// place the proofs connect, so the contract has one consumer shape to drift
// against.

import { designatorHostPort, Host, parseSturdyRef, Session, webSocketChannel } from "@glowcap/runtime";
import { originVizUrl, vizCapUrl } from "../../lib/viz_publish.ts";
import {
	DEFAULT_ROOMS_VIEW_STATE,
	emptyRoomsSessionState,
	WORKSPACE_STATE_KEY,
	WORKSPACE_STATE_VERSION,
} from "../../lib/rooms_state.ts";

export type VizRecord = Record<string, unknown>;

const ANNOUNCE = "ROOMS-VIZ-LISTENING ";

/** Tee the child's stderr through to this process and resolve the announced
 * viz sturdyref when it passes by. The stream keeps flowing after the match,
 * so the run stays observable and the child never blocks on a full pipe. */
export function scrapeVizSturdyref(stderr: ReadableStream<Uint8Array>): Promise<string> {
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
		reject(new Error("serve.ts ended without announcing a viz sturdyref"));
	})().catch((err) => reject(err instanceof Error ? err : new Error(String(err))));
	return found;
}

/** The port the endpoint named in its own sturdyref.
 *
 * A viewer needs two things that are really one fact: the byte channel to open,
 * and the peer to establish a session with. The endpoint states both in the
 * announcement, so a caller holding it needs to be told nothing else — which is
 * what lets a harness that asked for an ephemeral port connect at all. */
export function vizPortOf(sturdyref: string): number {
	return designatorHostPort(parseSturdyRef(sturdyref, "v1_0").locator.designator).port;
}

/** The viz capability inside the announcement: the sturdyref's swissnum is
 * the same swiss the endpoint requires of every socket, so a holder of the
 * announcement needs no second secret. */
export function vizCapOf(sturdyref: string): string {
	return new TextDecoder().decode(parseSturdyRef(sturdyref, "v1_0").swissnum);
}

/** The endpoint address a producer or viewer may use, including the capability
 * every socket must present. Producers replace the path with `/publish` while
 * preserving this query. */
export function vizUrlOf(sturdyref: string): string {
	return vizCapUrl(`ws://127.0.0.1:${vizPortOf(sturdyref)}/`, vizCapOf(sturdyref));
}

/** The localStorage row that arms a rooms tab's publishing from first load:
 * the remembered-swiss auto-redeem is production code, and a proof seeds it
 * the way a reader who checked "Remember on this device" would have.
 *
 * `pagePort` is the port the tab is served from, not the endpoint's own. A
 * browser reaches the timeline through `/viz` and `/publish` on the server
 * that served it, so the endpoint's port is not a name a tab ever holds, and
 * the row it looks up is keyed by that proxied address. Both halves of the
 * key come from the modules that read it rather than being written out here,
 * because a seed under a key nothing reads is silent: the tab arms nothing,
 * joins and chats as usual, and the proof fails much later at the endpoint
 * having heard from one producer. */
export function vizMemorySeed(pagePort: number, sturdyref: string): { key: string; value: string } {
	const endpoint = originVizUrl({ protocol: "http:", host: `127.0.0.1:${pagePort}` });
	return {
		key: WORKSPACE_STATE_KEY,
		value: JSON.stringify({
			version: WORKSPACE_STATE_VERSION,
			controller: { kind: "local" },
			session: {
				...emptyRoomsSessionState(),
				capabilities: {
					operations: [{ capability: "viz", scope: endpoint, swiss: vizCapOf(sturdyref) }],
					archivePeer: null,
				},
			},
			view: {
				...DEFAULT_ROOMS_VIEW_STATE,
				opsPane: "viz",
			},
		}),
	};
}

/** Connect one viewer and feed every record to `apply`, replay included,
 * exactly as production ocapnviz consumes the endpoint. The returned close
 * releases the session and its Host; the proofs exit explicitly, so leaving
 * a viewer open costs nothing beyond the connection. */
export async function connectVizViewer(
	sturdyref: string,
	apply: (record: VizRecord) => void,
): Promise<{ close(): Promise<void> }> {
	const locator = parseSturdyRef(sturdyref, "v1_0").locator;
	const socket = new WebSocket(vizUrlOf(sturdyref));
	await new Promise<void>((resolve, reject) => {
		socket.onopen = () => resolve();
		socket.onerror = () => reject(new Error("the live timeline endpoint would not accept a viewer"));
	});
	const host = new Host(); // rooms-profile-exempt: a viewer is production ocapnviz's v1.0 peer.
	const session = await Session.establishDialedLocator(
		host,
		locator,
		webSocketChannel(socket),
	);
	const serving = session.serve().catch(() => {});
	const raw_log = Deno.env.get("VIZ_VIEWER_LOG");
	const inbox = session.spawn((verb, args) => {
		if (verb !== "record" || args.length !== 1 || typeof args[0] !== "string") {
			throw new Error("the viewer inbox received an invalid record");
		}
		if (raw_log != null) {
			Deno.writeTextFileSync(raw_log, args[0] + "\n", { append: true });
		}
		apply(JSON.parse(args[0]) as VizRecord);
		return null;
	});
	const trace = await session.enliven(sturdyref);
	await session.send(trace, "subscribe", [inbox]);
	return {
		async close() {
			session.close();
			await serving;
			await host.close();
		},
	};
}
