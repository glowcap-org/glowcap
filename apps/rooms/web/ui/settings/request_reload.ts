// Settings changes that reload the page can lose picked files and unpersisted drafts.
import { type CommitmentSelection, useCommitments } from "../commitment.tsx";
import { reloadLosesWork } from "../build_reload.ts";
import { useRoomsProjection } from "../hooks.ts";
import { useManagedSession } from "../session/managed/context.tsx";

export function useRequestReload() {
	const commitments = useCommitments();
	const projection = useRoomsProjection();
	const session = useManagedSession();
	return (proceed: () => void | Promise<void>, selection?: Pick<CommitmentSelection, "except">) =>
		commitments.request(proceed, {
			...selection,
			losesOnReload: () => reloadLosesWork({ projection, managedSession: session }),
		});
}
