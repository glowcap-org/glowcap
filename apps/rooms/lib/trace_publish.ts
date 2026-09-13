// Shared URL vocabulary for the page-origin live timeline door. The Rooms
// services own publishing; browser consumers only need to present the held
// capability when they open the viewer or publisher path.
import {
	traceEndpointFragment,
	traceEndpointNotUrl,
	traceEndpointScheme,
	traceEndpointWhitespace,
} from "./text/ops.ts";

/** The query parameter a connecting socket presents the endpoint's capability
 * in — producers and viewers alike. Reachability alone reads and writes
 * nothing: the endpoint refuses a socket that does not present its swiss.
 * (ocapnviz presents the same parameter from the sturdyref it already holds;
 * its viewer names the parameter itself because it shares no module with this
 * app.) */
export const TRACE_CAP_PARAM = "cap";

/** The close code a refused socket receives, with the reason in the close
 * frame, so a WebSocket client can read why it was turned away. In the
 * application range because the WebSocket protocol reserves the low codes. */
export const TRACE_REFUSED_CLOSE_CODE = 4403;

/** The page-origin timeline socket. Browser pages reach the supervised
 * endpoint through their own origin, so HTTPS selects WSS and no internal
 * endpoint port enters browser state. */
export function originTraceUrl(location: { protocol: string; host: string }): string {
	return `${location.protocol === "https:" ? "wss://" : "ws://"}${location.host}/trace`;
}

/** Why a durable trace endpoint override cannot be used, or null for blank and a
 * complete WebSocket URL. Validation never rewrites the operator's value. */
export function traceOverrideRefusal(value: string): string | null {
	if (value === "") return null;
	if (value !== value.trim()) return traceEndpointWhitespace;
	let parsed: URL;
	try {
		parsed = new URL(value);
	} catch {
		return traceEndpointNotUrl;
	}
	if (parsed.protocol !== "ws:" && parsed.protocol !== "wss:") {
		return traceEndpointScheme;
	}
	if (parsed.hash !== "") return traceEndpointFragment;
	return null;
}

/** Put the capability on an endpoint URL, viewer or producer alike. */
export function traceCapUrl(url: string, swiss: string): string {
	const parsed = new URL(url);
	parsed.searchParams.set(TRACE_CAP_PARAM, swiss);
	return parsed.toString();
}
