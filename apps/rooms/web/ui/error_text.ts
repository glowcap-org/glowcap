// The refusal vocabulary, kept with every other sentence Rooms says, in
// `apps/rooms/lib/text/failure.ts`.
//
// This file is the UI's door onto it. The words moved rather than being copied,
// because a product whose voice lives in two places has no voice: the next
// author edits whichever copy they found.

import { refusalText } from "../../lib/text/failure.ts";

export {
	errorDetailTitle,
	locatorRefusal,
	needsErrorDetail,
	sessionCapabilityRefusal,
} from "../../lib/text/failure.ts";

/** Settle one UI action into the controller convention: an empty string is
 * success and any other string is a refusal. Expected failures already arrive
 * that way; adapter/runtime failures can still reject, and a gesture boundary
 * must turn those into something the control can draw instead of leaving an
 * unhandled promise and an ambiguous outcome. */
export async function actionRefusal(action: () => Promise<string>): Promise<string> {
	try {
		return await action();
	} catch (error) {
		return refusalText(error);
	}
}
