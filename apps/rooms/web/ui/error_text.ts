// The refusal vocabulary, kept with every other sentence Rooms says, in
// `apps/rooms/lib/text/failure.ts`.
//
// This file is the UI's door onto it. The words live in one place and are not copied,
// because a product whose voice lives in two places has no voice: the next
// author edits whichever copy they found.

import { refusalText, transportBreak } from "../../lib/text/failure.ts";

export { errorDetailTitle, needsErrorDetail, sessionCapabilityRefusal } from "../../lib/text/failure.ts";

/** An attach that failed, in the reader's words. A break on the way names
 * the server this browser goes through, said by `unreachable` for the screen
 * that says it; anything else is about the link. */
export function attachRefusal(
	error: unknown,
	server: { readonly base: string } | null,
	unreachable: (host: string, detail: string) => string,
): string {
	const broke = transportBreak(error);
	return broke !== null && server != null ? unreachable(new URL(server.base).host, broke) : refusalText(error);
}

/** Settle one UI action into the controller convention: an empty string is
 * success and any other string is a refusal. Expected failures already arrive
 * that way. Adapter/runtime failures can still reject, and a gesture boundary
 * must turn those into something the control can draw instead of leaving an
 * unhandled promise and an ambiguous outcome. */
export async function actionRefusal(action: () => Promise<string>): Promise<string> {
	try {
		return await action();
	} catch (error) {
		return refusalText(error);
	}
}
