// The rest of a long refusal, on its own card.
//
// The place the error appeared still says that something went wrong, in the
// space it already held. This is the reading surface for the rest of the
// words — selectable, copyable, and no longer competing with the control they
// answered.
//
// It stands over whatever layer the refusal is in rather than replacing it, so
// closing it puts the reader back exactly where they were, on the control that
// answered.

import { memo, useRef } from "react";
import { useRoomsBrowser } from "../controller/browser.ts";
import { useHeldModal, useModalDialog } from "../modal.ts";
import { ModalHead } from "../ModalHead.tsx";
import { CopyButton } from "../Copy.tsx";

export const ErrorDetail = memo(function ErrorDetail(
	{ title, text }: { title: string | null; text: string | null },
) {
	type View = { title: string; text: string };
	const last = useRef<View | null>(
		title === null || text === null ? null : { title, text },
	);
	if (title !== null && text !== null) last.current = { title, text };
	const shown = last.current;
	const { held, onExited } = useHeldModal(title !== null);
	if (!held || shown === null) return null;
	return <ErrorDialog open={title !== null} onExited={onExited} {...shown} />;
});

function ErrorDialog(
	{ open, onExited, title, text }: {
		open: boolean;
		onExited: () => void;
		title: string;
		text: string;
	},
) {
	const browser = useRoomsBrowser();
	const close = useRef<HTMLButtonElement>(null);
	const dialog = useRef<HTMLDialogElement>(null);
	useModalDialog(dialog, () => browser.closeError(), close, open, onExited);
	return (
		<dialog ref={dialog} className="modal" aria-labelledby="errorTitle">
			<div className="modal-card card-plane">
				<div className="modal-body">
					<ModalHead
						titleId="errorTitle"
						title={title}
						closeId="errorClose"
						closeRef={close}
						actions={<CopyButton text={text} label={"Copy " + title} size="small" variant="ghost" />}
						onClose={() => browser.closeError()}
					/>
					<pre id="errorBody" className="error-body">{text}</pre>
				</div>
			</div>
		</dialog>
	);
}
