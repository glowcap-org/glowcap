// Copy metadata out of a borrowed C view before the Host reuses that view.
import type { RawBreakCause } from "@glowcap/abi";
import { L } from "./layout.ts";

export function readBreakCause(view: DataView, offset = 0): RawBreakCause {
	return {
		origin: view.getUint32(offset + L.BREAK_CAUSE_ORIGIN_OFF, true),
		reason: view.getUint32(offset + L.BREAK_CAUSE_REASON_OFF, true),
		context: view.getUint32(offset + L.BREAK_CAUSE_CONTEXT_OFF, true),
	};
}
