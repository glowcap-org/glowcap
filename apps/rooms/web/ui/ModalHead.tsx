// The first line of every card that opens over the page: its name, and the
// one mark that closes it at the line's end.
//
// Every modal is left the same way, so the dismiss is drawn once here rather
// than by each card. A form's own Cancel beside its submit is an action and
// stays in the form; this is only the way out of the layer. A card with a
// second mark that belongs to the whole card — copying the whole of an error —
// puts it beside the dismiss, in `actions`.

import type { ReactNode, Ref } from "react";
import { IconButton } from "./IconButton.tsx";
import { modalClose } from "../../lib/text/controls.ts";

export function ModalHead(
	{ titleId, title, closeId, closeLabel = modalClose, closeRef, actions, onClose }: {
		titleId?: string;
		title: ReactNode;
		closeId?: string;
		closeLabel?: string;
		closeRef?: Ref<HTMLButtonElement>;
		/** Marks that act on the whole card, drawn before the dismiss. */
		actions?: ReactNode;
		onClose?: () => void;
	},
) {
	return (
		<div className="modal-head">
			<h2 id={titleId}>{title}</h2>
			{(actions !== undefined || onClose !== undefined) && (
				<span className="modal-head-actions">
					{actions}
					{onClose !== undefined && (
						<IconButton
							id={closeId}
							ref={closeRef}
							icon="close"
							label={closeLabel}
							title={closeLabel}
							size="small"
							variant="ghost"
							onClick={onClose}
						/>
					)}
				</span>
			)}
		</div>
	);
}
