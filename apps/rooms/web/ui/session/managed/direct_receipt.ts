// The Rust results::Direct enum owns the introduction receipt's two variants.
export type DirectReceipt =
	| { status: "pending" }
	| { status: "ready"; inbox: string };

/** Validate the variant before moving custody. Return the original receipt
 * without allocating a projection or requiring fields from another variant. */
export function readDirectReceipt(raw: unknown): DirectReceipt {
	if (raw == null || typeof raw !== "object" || Array.isArray(raw)) {
		throw new Error("The direct introduction receipt is not an object");
	}
	const result = raw as { status?: unknown; inbox?: unknown };
	switch (result.status) {
		case "pending":
			return raw as DirectReceipt;
		case "ready":
			if (typeof result.inbox !== "string") {
				throw new Error("The direct introduction receipt has no ready inbox key");
			}
			return raw as DirectReceipt;
		default:
			throw new Error("The direct introduction receipt's status is unknown");
	}
}
