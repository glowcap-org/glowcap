// What an incoming authority becomes in the workspace once it is acquired: the
// row that holds it, staged on a candidate snapshot, and the custody slot it
// lands in.
import { invariant } from "../../../../lib/invariant.ts";
import { type ActivityEvent, type Coordinate, type DirectIntent, fieldKey, type WorkspaceSnapshot } from "./model.ts";

/** Stage `snapshot` for the arrival `id` that `event` delivers into `conversation`,
 * and name where its authority is kept and the session access that carries it. */
export function stageArrival(
	snapshot: WorkspaceSnapshot,
	conversation: DirectIntent,
	event: ActivityEvent,
	id: string,
): { destination: Coordinate; source: ReturnType<typeof fieldKey> } {
	const notice = event.notice;
	const source = fieldKey();
	const key = fieldKey();
	let destination: Coordinate;
	if (notice?.kind === "line" && event.route != null) {
		destination = { role: "directAccess", key };
		conversation.access = key;
		conversation.source = source;
	} else if (notice?.kind === "handRoom" || notice?.kind === "offerRoom") {
		destination = { role: "roomAccess", key };
		snapshot.intent.invitations.push({
			id,
			directory: conversation.directory,
			label: notice.label ?? "",
			from: conversation.peer,
			authority: { role: "roomAccess", key },
			source,
		});
	} else if (notice?.kind === "handArchive" || notice?.kind === "offerArchive") {
		const kind = notice.scope;
		destination = { role: "archiveAccess", key };
		snapshot.intent.archiveShares = [...(snapshot.intent.archiveShares ?? []), {
			id,
			channel: conversation.id,
			directory: notice.directory ?? "",
			kind,
			conversation: notice.conversation ?? null,
			from: conversation.peer,
			access: key,
			source,
			durable: notice.kind === "offerArchive",
		}];
	} else {
		invariant(false, "this incoming authority has no acquisition owner");
	}
	return { destination, source };
}
