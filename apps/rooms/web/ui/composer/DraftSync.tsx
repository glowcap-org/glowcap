import { useSyncExternalStore } from "react";
import { useManagedSession } from "../session/managed/context.tsx";
import type { DraftFailure } from "../session/managed/drafts.ts";
import { useRoomsSession } from "../controller/session.ts";
import { useSessionPermission } from "../hooks.ts";
import { Button } from "../Button.tsx";
import { Said } from "../Said.tsx";
import { useAsyncAction } from "../async_action.ts";
import {
	composerDraftConflict,
	composerDraftConflictFiles,
	composerRetrySync,
	composerUnsynced,
	composerUseSessionDraft,
} from "../../../lib/text/controls.ts";

export function useDraftFailure(id: string | null): DraftFailure | undefined {
	const session = useManagedSession();
	return useSyncExternalStore(session.subscribe, () => id == null ? undefined : session.drafts.failure(id));
}

export function DraftSync({ id, convKey, failure, files }: {
	id: string | null;
	convKey: string | null;
	failure: DraftFailure | undefined;
	files: boolean;
}) {
	const session = useManagedSession();
	const canRetry = useSessionPermission("interactWorkspace");
	const composer = useRoomsSession();
	const retry = useAsyncAction(async () => {
		if (id != null) await session.drafts.flush(id);
	});
	if (failure == null) return null;
	if (failure.conflict && convKey != null) {
		return (
			<div className="draft-sync">
				<Said kind="warning">{composerDraftConflict}{files ? ` ${composerDraftConflictFiles}` : ""}</Said>
				<Button variant="link" onClick={() => composer.useSessionDraft(convKey)}>
					{composerUseSessionDraft}
				</Button>
			</div>
		);
	}
	return (
		<div className="draft-sync">
			<Said kind="warning">{`${composerUnsynced} ${failure.text}`}</Said>
			<Button variant="link" busy={retry.busy} disabled={!canRetry} onClick={() => void retry.run()}>
				{composerRetrySync}
			</Button>
		</div>
	);
}
