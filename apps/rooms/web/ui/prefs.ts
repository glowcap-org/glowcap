/// <reference lib="dom" />
// The URL names this tab's DM transport; durable session intent supplies the
// default. Changing it reloads the page because transport is chosen at startup.
import { TRANSPORT_NOISE_RELAY, TRANSPORT_WEBRTC } from "@glowcap/abi";

export type DmMode = "webrtc" | "relay";
export type DmTransport = typeof TRANSPORT_WEBRTC | typeof TRANSPORT_NOISE_RELAY;

/** The wire profile selected by one user-facing DM mode. Relay mode remains
 * rendezvous-reachable, but the room relay carries only Noise ciphertext. */
export function dmTransportFor(mode: DmMode): DmTransport {
	return mode === "relay" ? TRANSPORT_NOISE_RELAY : TRANSPORT_WEBRTC;
}

/** Resolve DM transport from a search string and a stored preference. */
export function dmFrom(search: URLSearchParams, stored: string | null): DmMode {
	const q = search.get("dm");
	if (q === "relay") return "relay";
	if (q === "webrtc") return "webrtc";
	return stored === "relay" ? "relay" : "webrtc";
}

export function dmMode(stored: DmMode = "webrtc"): DmMode {
	return dmFrom(new URLSearchParams(location.search), stored);
}

export function dmTransport(): DmTransport {
	return dmTransportFor(dmMode());
}

export function current(intent?: { connection: DmMode }): { dm: DmMode } {
	return { dm: dmMode(intent?.connection) };
}

/** The room directory this page is serving, from `/locator`. */
export async function directoryLocator(): Promise<string | null> {
	try {
		const res = await fetch("/locator");
		const text = (await res.text()).trim();
		if (!res.ok || text.length === 0) return null;
		return text;
	} catch {
		return null;
	}
}

/** Persist the DM route choice, preserving unrelated query parameters. */
export function writeSearch(url: URL, next: { dm: DmMode }): void {
	if (next.dm === "relay") url.searchParams.set("dm", "relay");
	else url.searchParams.delete("dm");
	url.searchParams.delete("trace");
}
