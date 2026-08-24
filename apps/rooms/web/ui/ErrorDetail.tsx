// The rest of a long refusal, on its own card.
//
// The place the error appeared still says that something went wrong, in the
// space it already held. This is the reading surface for the rest of the
// words — selectable, copyable, and no longer competing with the control they
// answered.

import { useLayoutEffect, useRef } from "react";
import { usePeer } from "./peer.ts";
import { useHeldModal, useModalDialog } from "./modal.ts";
import { IconButton } from "./IconButton.tsx";
import { CopyButton } from "./Copy.tsx";

export function ErrorDetail(
	{ title, text, onLayer }: {
		title: string | null;
		text: string | null;
		onLayer: (held: boolean) => void;
	},
) {
	type View = { title: string; text: string };
	const last = useRef<View | null>(
		title === null || text === null ? null : { title, text },
	);
	if (title !== null && text !== null) last.current = { title, text };
	const shown = last.current;
	const { held, onExited } = useHeldModal(title !== null);
	useLayoutEffect(() => {
		onLayer(held);
		return () => onLayer(false);
	}, [held, onLayer]);
	if (!held || shown === null) return null;
	return <ErrorDialog open={title !== null} onExited={onExited} {...shown} />;
}

function ErrorDialog(
	{ open, onExited, title, text }: {
		open: boolean;
		onExited: () => void;
		title: string;
		text: string;
	},
) {
	const peer = usePeer();
	const close = useRef<HTMLButtonElement>(null);
	const dialog = useRef<HTMLDialogElement>(null);
	useModalDialog(dialog, () => peer.closeError(), close, open, onExited);
	return (
		<dialog ref={dialog} className="modal" aria-labelledby="errorTitle">
			<div className="modal-card card-plane">
				<div className="settings-head-row">
					<h2 id="errorTitle">{title}</h2>
					<span className="error-actions">
						<CopyButton text={text} label={"Copy " + title} size="small" variant="ghost" />
						<IconButton
							ref={close}
							id="errorClose"
							icon="close"
							label="Close"
							size="small"
							variant="ghost"
							onClick={() => peer.closeError()}
						/>
					</span>
				</div>
				<pre id="errorBody" className="error-body">{text}</pre>
			</div>
		</dialog>
	);
}
