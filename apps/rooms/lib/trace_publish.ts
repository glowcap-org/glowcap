// Shared URL vocabulary for live timeline sockets. The Rooms
// services own publishing; browser consumers only need to present the held
// capability when they open the viewer or publisher path.
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

/** Put the capability on an endpoint URL, viewer or producer alike. */
export function traceCapUrl(url: string, swiss: string): string {
	const parsed = new URL(url);
	parsed.searchParams.set(TRACE_CAP_PARAM, swiss);
	return parsed.toString();
}
