// The directory name a tab-hosted WebRTC Attach registers under to signal.
//
// It is derived from this tab's Host designator so two attachers do not collide,
// and it is not a session nick: the hosted workspace already owns those.

export function attachSignalingNick(designator: string): string {
	const token = designator.replace(/[^a-zA-Z0-9]/g, "").slice(0, 12);
	return token.length > 0 ? `s${token}` : "sattach";
}
