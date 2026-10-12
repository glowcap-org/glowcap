import { useSyncExternalStore } from "react";
import { useManagedSession } from "../session/managed/context.tsx";
import { useRoomsState, useSessionPermission } from "../hooks.ts";
import { Button } from "../Button.tsx";
import { Said } from "../Said.tsx";
import { useAsyncAction } from "../async_action.ts";
import { composerRetrySync, composerUnsynced } from "../../../lib/text/controls.ts";

export function DraftSync({ convKey }: { convKey: string | null }) {
	const session = useManagedSession();
	const canRetry = useSessionPermission("interactWorkspace");
	const row = useRoomsState((state) => convKey == null ? undefined : state.convs.get(convKey));
	const id = row?.type === "room" || row?.type === "dm" ? row.persistId : null;
	const failure = useSyncExternalStore(session.subscribe, () => id == null ? "" : session.drafts.failure(id));
	const retry = useAsyncAction(async () => {
		if (id != null) await session.drafts.flush(id);
	});
	if (failure === "") return null;
	return (
		<div className="draft-sync">
			<Said kind="warning">{`${composerUnsynced} ${failure}`}</Said>
			<Button variant="link" busy={retry.busy} disabled={!canRetry} onClick={() => void retry.run()}>
				{composerRetrySync}
			</Button>
		</div>
	);
}
