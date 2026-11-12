// How much local work a page keeps in flight: prepared acquisitions waiting on
// their receipts, and shared workspace reads.
import { SESSION_CONTENT } from "../../../../lib/session_content_data.ts";

export const LOCAL_LIMITS = { acquisitions: 32, reads: SESSION_CONTENT.limits.effects } as const;
