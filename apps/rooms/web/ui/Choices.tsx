// A set of answers to one question, where choosing one sets the others aside.
//
// `Choices` is the well the answers stand in, named by the question's label.
// `Choice` is one answer: an HTML radio input (forms, labels, and keyboards already
// know one) beside its words, whose bold first part names the answer. The
// stylesheet draws both in `forms.css`, so a caller passes what it asks and
// never the look.

import type { ComponentPropsWithRef, ReactNode } from "react";

export function Choices({ labelledBy, children }: { labelledBy: string; children: ReactNode }) {
	return <div className="choices" role="radiogroup" aria-labelledby={labelledBy}>{children}</div>;
}

export type ChoiceProps = Omit<ComponentPropsWithRef<"input">, "type" | "children"> & { children: ReactNode };

export function Choice({ children, ...input }: ChoiceProps) {
	return (
		<label className="choice">
			<input {...input} type="radio" />
			<span>{children}</span>
		</label>
	);
}
