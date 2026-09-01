// Whether a shared-session Connect has actually reached the directory.
//
// `joinDirectory` only writes a workspace record. The dial is the runtime's,
// and its refusal arrives later as a snapshot issue. The join card's Connect
// is the act of reaching, so it waits here until that issue or a live
// connection exists rather than treating the record as success. How those
// answers read in the four connection words is `directoryLivePhase`.

import type { RoomsSessionSnapshot } from "../../../lib/session/client.ts";

export interface DirectoryReachSource {
	readonly current: RoomsSessionSnapshot | null;
	onSnapshot(listener: (snapshot: RoomsSessionSnapshot) => void): () => void;
}

/** Whether this directory is already a standing membership.
 *
 * A directory that has answered, or this session's home, keeps its rooms when
 * Connect fails: they say not connected. A Connect that only just named the
 * address is still establishment, so the refusal belongs on the card and the
 * row goes — including a leftover that never answered, which is the same typo
 * sitting under a workspace record. */
export function directoryReachIsStanding(
	existing: { readonly reached?: boolean; readonly home: boolean } | undefined,
): boolean {
	return existing != null && (existing.reached === true || existing.home === true);
}

/** Empty string: reached. A sentence: refused. Undefined: still opening. */
export function directoryReachOutcome(
	snapshot: RoomsSessionSnapshot | null,
	directoryId: string,
): string | undefined {
	if (snapshot == null) return undefined;
	if (snapshot.connectedDirectories.includes(directoryId)) return "";
	for (const issue of snapshot.issues) {
		if (
			issue.subject === "session" ||
			issue.subject === "session-access" ||
			issue.subject === `directory:${directoryId}`
		) {
			return issue.reason;
		}
	}
	return undefined;
}

export function waitForDirectoryReach(
	source: DirectoryReachSource,
	directoryId: string,
	signal?: AbortSignal,
): Promise<string> {
	if (signal?.aborted) return Promise.resolve("");
	const already = directoryReachOutcome(source.current, directoryId);
	if (already !== undefined) return Promise.resolve(already);
	return new Promise((resolve) => {
		let settled = false;
		const finish = (why: string) => {
			if (settled) return;
			settled = true;
			signal?.removeEventListener("abort", onAbort);
			stop();
			resolve(why);
		};
		const onAbort = () => finish("");
		const stop = source.onSnapshot((snapshot) => {
			const next = directoryReachOutcome(snapshot, directoryId);
			if (next !== undefined) finish(next);
		});
		signal?.addEventListener("abort", onAbort);
		const raced = directoryReachOutcome(source.current, directoryId);
		if (raced !== undefined) finish(raced);
	});
}
