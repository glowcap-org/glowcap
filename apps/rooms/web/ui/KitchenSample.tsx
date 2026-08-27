// The frame each kitchen-sink chapter sits in: a heading, an optional note,
// and rows of samples on the plain plate or a colored one.

import type { ReactNode } from "react";

export function Sample({ label, note, children }: { label: string; note?: string; children: ReactNode }) {
	return (
		<section className="kitchen-sample">
			<h3>{label}</h3>
			{note !== undefined ? <p className="kitchen-note">{note}</p> : null}
			{children}
		</section>
	);
}

export function Row({ plate, children }: { plate?: "accent" | "dark"; children: ReactNode }) {
	return <div className={plate === undefined ? "kitchen-row" : "kitchen-row kitchen-plate-" + plate}>{children}</div>;
}
