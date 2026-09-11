// The application owns session-opening advice; preserve unknown thrown text.
import { applicationModule } from "../application.ts";

export function attachedSessionFailureText(error: unknown): string {
	const reason = error instanceof Error ? error.message : String(error);
	return applicationModule().attachmentFailureAdvice(reason) ?? reason;
}
