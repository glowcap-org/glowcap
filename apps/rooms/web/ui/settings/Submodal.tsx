// A card that opens over Settings for one of its managers: the session data
// and the session access editors. It is the ordinary modal card with the
// ordinary head; what differs is only the width each asks for.

import { type ReactNode, useRef } from "react";
import { ModalHead } from "../ModalHead.tsx";
import { useHeldModal, useModalDialog } from "../modal.ts";

export function SettingsSubmodal(
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
				<ModalHead titleId={titleId} title={title} closeRef={close} onClose={onClose} />
				{children}
			</div>
		</dialog>
	);
}
