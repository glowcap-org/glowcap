// The application owns session-opening advice; preserve unknown thrown text.
import { attachmentFailureAdvice } from "../application.ts";
import { failureView, renderFailure } from "../../../lib/text/failure.ts";

export function attachedSessionFailureText(error: unknown): string {
	const fallback = failureView(error);
	const advice = attachmentFailureAdvice(fallback.detail);
	return advice === null ? renderFailure(fallback) : renderFailure({ ...advice, detail: fallback.detail });
}
