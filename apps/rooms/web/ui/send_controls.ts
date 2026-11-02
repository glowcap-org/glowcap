// Which actions the message log offers on a line, by who owns the send.

/** Actions the message log may offer for sends this controller owns. */
export interface SendControlPolicy {
	retry: boolean;
}

export const LOCAL_SEND_CONTROLS = { retry: true } as const;
export const SHARED_SEND_CONTROLS = { retry: false } as const;

export function sendControlsFor(kind: "local" | "attached" | "hosted"): SendControlPolicy {
	return kind === "local" ? LOCAL_SEND_CONTROLS : SHARED_SEND_CONTROLS;
}
