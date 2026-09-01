// File the directory signaling inbox a webrtc member locator needs.

import { type Host, TRANSPORT_WEBRTC } from "@pancake/runtime";
import { decodeIceServers, type IceServer } from "../lib/ice.ts";
import { roomsLocator } from "../lib/locator.ts";
import type { Directory } from "../lib/room/client.ts";

export interface WebrtcDirectoryAnswer {
	close(): Promise<void>;
}

/** After `register` with a webrtc member locator, file the inbox `signalOffer`
 * routes by. TCP, iroh, and relay locators need no directory signaling. The
 * WebRTC module loads only on that path so the Deno session peer stays free of
 * it. */
export async function answerWebrtcSignaling(opts: {
	host: Host;
	directory: Directory;
	memberLocator: string;
	iceServers?: () => Promise<IceServer[]>;
	onError: (error: unknown) => void;
}): Promise<WebrtcDirectoryAnswer | null> {
	if (roomsLocator(opts.memberLocator).transport !== TRANSPORT_WEBRTC) return null;
	const { serveWebrtcSignaling } = await import("../lib/signaling.ts");
	return await serveWebrtcSignaling({
		host: opts.host,
		dir: () => opts.directory,
		iceServers: opts.iceServers ?? loadPageIceServers,
		onError: opts.onError,
	});
}

async function loadPageIceServers(): Promise<IceServer[]> {
	const answer = await fetch("/ice");
	if (!answer.ok) throw new Error(`rooms: ICE configuration request failed (${answer.status})`);
	return decodeIceServers(await answer.json());
}
