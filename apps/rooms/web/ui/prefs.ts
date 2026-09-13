/// <reference lib="dom" />
// Direct-message transport and the ocapnviz WebSocket.
//
// The address bar wins when it names a value, so a test or a shared link keeps
// doing what it says. When the URL is silent, the last choice this browser
// remembered is used. A save writes and then reloads — Settings the DM
// transport, the Visualizer pane the trace endpoint — because both are decided
// when the peer opens, not mid-session.

import { TRANSPORT_NOISE_RELAY, TRANSPORT_WEBRTC } from "@glowcap/abi";
import { originTraceUrl } from "./trace_endpoint.ts";
import { workspaceConnectionSettings } from "./workspace_state.ts";

export { originTraceUrl } from "./trace_endpoint.ts";

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

/** Resolve the trace override. `null` means "ask this page's server". An empty
 * `?trace=` is an explicit blank, not "use storage". */
export function traceFrom(search: URLSearchParams, stored: string | null): string | null {
	if (search.has("trace")) return search.get("trace");
	return stored;
}

export function dmMode(): DmMode {
	return dmFrom(new URLSearchParams(location.search), workspaceConnectionSettings().dmMode);
}

export function dmTransport(): DmTransport {
	return dmTransportFor(dmMode());
}

export function traceOverride(): string | null {
	return traceFrom(new URLSearchParams(location.search), workspaceConnectionSettings().traceOverride || null);
}

export function current(): { dm: DmMode; trace: string } {
	return { dm: dmMode(), trace: traceOverride() ?? "" };
}

/** What a blank trace field means: this page's own endpoint through its
 * origin, or null when the server has none. */
export async function advertisedTrace(): Promise<string | null> {
	try {
		const res = await fetch("/trace");
		await res.body?.cancel();
		// Only a 200 names an endpoint: a server with the visualizer off
		// answers 204, which is "nothing here" rather than a failure.
		if (res.status !== 200) return null;
		return originTraceUrl(location);
	} catch {
		return null;
	}
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

/** Write `dm` / `trace` onto `url`, leaving any other query alone. WebRTC is the
 * default, so it comes off the address rather than sitting there as `?dm=webrtc`. */
export function writeSearch(url: URL, next: { dm: DmMode; trace: string }): void {
	if (next.dm === "relay") url.searchParams.set("dm", "relay");
	else url.searchParams.delete("dm");
	if (next.trace !== "") url.searchParams.set("trace", next.trace);
	else url.searchParams.delete("trace");
}
