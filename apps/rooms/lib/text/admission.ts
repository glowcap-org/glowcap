// Action feedback and grouped presence narration share the product voice here.
import { ADMISSION_OWNER_LABELS, ADMISSION_SCOPE_LABELS, type RetryAdvice } from "../error_codes.ts";

export function retryLimit(advice: RetryAdvice): string {
	const scope = ADMISSION_SCOPE_LABELS[advice.scope];
	const owner = advice.owner == null ? "" : ` ${ADMISSION_OWNER_LABELS[advice.owner]}`;
	return `${scope}${owner}.`;
}
export const retryJoin = "Retry join";
export const retryCountdown = (seconds: number) => `Try again in ${seconds}s.`;
export const connectionChanges = (name: string, changes: number, online: boolean) =>
	`${name}’s connection changed ${changes} times. Now ${online ? "online" : "offline"}.`;
export const offlineMember = (name: string) => `${name} is offline.`;
