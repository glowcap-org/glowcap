// The Rust results::Direct owns the acquired inbox receipt.
import { LocalRefusal } from "../../../../lib/text/failure.ts";
interface DirectReceipt {
	inbox: string;
}

function isDirectReceipt(raw: unknown): raw is DirectReceipt {
	return raw != null && typeof raw === "object" && !Array.isArray(raw) &&
		"inbox" in raw && typeof raw.inbox === "string";
}

/** Validate the inbox before moving custody. */
export function readDirectReceipt(raw: unknown): DirectReceipt {
	if (!isDirectReceipt(raw)) {
		throw new LocalRefusal("retained-result-unreadable", {
			cause: "the direct introduction receipt has no inbox key",
		});
	}
	return raw;
}
