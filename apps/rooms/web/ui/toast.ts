// What a toast says and how it is classed.

export type ToastKind = "success" | "failure" | "warning";

export interface ToastNotice {
	id: number;
	kind: ToastKind;
	text: string;
}
