// The card a modal dialog draws: the surface every conversation, directory,
// member, settings, and error card stands on. It owns the pair of classes that
// make that surface, so a caller names only what is its own (`dircard`, a
// `data-dir` mark) and never restates the surface it sits on. `ModalForm` is
// the same surface as a form, for a dialog that submits.

import type { ComponentPropsWithRef } from "react";
import { classNames } from "./classes.ts";

const CARD = "modal-card card-plane";

export function ModalCard({ className, ...card }: ComponentPropsWithRef<"div">) {
	return <div {...card} className={classNames(CARD, className)} />;
}

export function ModalForm({ className, ...form }: ComponentPropsWithRef<"form">) {
	return <form {...form} className={classNames(CARD, className)} />;
}
