// The card a modal dialog draws: the surface every conversation, directory,
// member, settings, and error card stands on. It owns the pair of classes that
// make that surface, so a caller names only what is its own (`dircard`, a
// `data-dir` mark) and never restates the surface it sits on.

import type { ComponentPropsWithRef } from "react";

export function ModalCard({ className, ...card }: ComponentPropsWithRef<"div">) {
	return <div {...card} className={["modal-card card-plane", className].filter(Boolean).join(" ")} />;
}
