import type { ReactNode } from "react";
import { IconButton } from "../IconButton.tsx";

/** A condition that changes what Send will do, with its way back to ordinary writing. */
export function ComposerContext({ id, children, dismissLabel, dismiss, busy }: {
	id: string;
	children: ReactNode;
	dismissLabel: string;
	dismiss: () => void;
	busy?: boolean;
}) {
	return (
		<div id={id} className="composer-context">
			<span className="composer-context-said">{children}</span>
			<IconButton icon="close" size="small" variant="ghost" label={dismissLabel} busy={busy} onClick={dismiss} />
		</div>
	);
}
