// A card that opens over another card, for a subject that is a form rather
// than a row: the session data and access editors over Settings, handing an
// archive account over a conversation card. It is the ordinary modal card with
// the ordinary head, and what differs between them is only the width each asks
// for.
//
// A form earns one; a question does not. A question belongs to the row that
// raised it and stays inline there, which is `Confirm` and its own reasons.

import { type ReactNode, useRef } from "react";
import { ModalHead } from "./ModalHead.tsx";
import { useHeldModal, useModalDialog } from "./modal.ts";

export function Submodal(
	{ title, titleId, className = "", open, onClose, children }: {
		title: string;
		titleId: string;
		className?: string;
		open: boolean;
		onClose(): void;
		children: ReactNode;
	},
) {
	const dialog = useRef<HTMLDialogElement>(null);
	const close = useRef<HTMLButtonElement>(null);
	const { held, onExited } = useHeldModal(open);
	useModalDialog(dialog, onClose, close, open, onExited);
	if (!held) return null;
	return (
		<dialog ref={dialog} className="modal" aria-labelledby={titleId}>
			<div className={`modal-card card-plane ${className}`.trim()}>
				<div className="modal-body">
					<ModalHead titleId={titleId} title={title} closeRef={close} onClose={onClose} />
					{children}
				</div>
			</div>
		</dialog>
	);
}
