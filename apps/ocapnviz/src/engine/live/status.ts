/**
 * What the Live connection badge reports.
 *
 * Connected is one fact: CapTP is up. Observed is another: at least one
 * record has arrived. Mixing them is how a silent new endpoint looks like
 * a quiet live feed. Refused means this page cannot dial this link, and
 * another link can be tried. Stopped means setup cannot retry safely and
 * requires reload.
 */

export type LiveConnectionState = "connecting" | "connected" | "refused" | "stopped";
export type LiveFeedStatus = "idle" | "connecting" | "waiting" | "connected" | "refused" | "stopped";

export function liveFeedStatus(input: {
	sturdyref: string;
	connection: LiveConnectionState;
	observed: boolean;
}): LiveFeedStatus {
	if (input.sturdyref.trim() === "") return "idle";
	if (input.connection === "stopped") return "stopped";
	if (input.connection === "refused") return "refused";
	if (input.connection === "connecting") return "connecting";
	if (!input.observed) return "waiting";
	return "connected";
}
