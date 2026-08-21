/**
 * What the Live connection badge reports.
 *
 * Connected is one fact: CapTP is up. Observed is another: at least one
 * record has arrived. Mixing them is how a silent new endpoint looks like
 * a quiet live feed.
 */

export type LiveFeedStatus = "idle" | "connecting" | "waiting" | "connected";

export function liveFeedStatus(input: {
  sturdyref: string;
  connected: boolean;
  observed: boolean;
}): LiveFeedStatus {
  if (input.sturdyref.trim() === "") return "idle";
  if (!input.connected) return "connecting";
  if (!input.observed) return "waiting";
  return "connected";
}
