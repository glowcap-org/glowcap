// One line of a well that offers acts: what the line is about, then the one
// act that takes it, on the name's line at the column's right edge. A phone
// gives the name its own line and puts the act under it (entries.css). Every
// act a well offers is a line of its own inside `EntryActs`, so a well never
// wraps a row of buttons into a ragged second row, and every such list is
// spaced the same way.

import type { MouseEvent, ReactNode } from "react";
import { Button, type ButtonVariant } from "./Button.tsx";

export function EntryAct(
	{ name, id, act, variant = "quiet", onClick }: {
		name: string;
		id: string;
		act: string;
		variant?: ButtonVariant;
		onClick(event: MouseEvent<HTMLButtonElement>): void;
	},
) {
	return (
		<li className="entry">
			<div className="entry-head" data-one-line>
				<span className="entry-name">{name}</span>
				<div className="actions">
					<Button id={id} type="button" variant={variant} onClick={onClick}>
						{act}
					</Button>
				</div>
			</div>
		</li>
	);
}

export function EntryActs({ children }: { children: ReactNode }) {
	return <ul className="entries" data-acts>{children}</ul>;
}
