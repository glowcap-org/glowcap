import { MAX_DM_INBOXES } from "../../lib/limits.ts";

/** One socket owns one Rooms member and its bounded authority set. */
export const IRC_FRONT_CLIENT_LIMIT = 256;

/** Worst-case published inboxes when every admitted IRC member offers the
 * directory's per-member maximum. Retired aliases leave this ledger before a
 * replacement publishes, so churn does not consume the bound. */
export const IRC_FRONT_INBOX_LIMIT = IRC_FRONT_CLIENT_LIMIT * MAX_DM_INBOXES;
