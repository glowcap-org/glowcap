// Policies for the local custody and read fronts, beside the generated command
// inventory. Public acquisition methods cannot be added without choosing one.
import type { ManagedActions } from "./actions.ts";
import type { RoomsSessionController } from "../../controller/session.ts";
import { SESSION_CONTENT } from "../../../../lib/session_content_data.ts";

export const LOCAL_LIMITS = { acquisitions: 32, reads: SESSION_CONTENT.limits.effects } as const;
interface LocalPolicy {
	presentation: "optimistic" | "indicate";
	conflict: "receipt" | "directory" | "publication" | "registration" | "workspace" | "distinct" | "target";
	retry: "originalReceipt" | "originalAcquisition" | "freshRead";
	stop: "observe" | "retireRead";
	stale: "originalAuthority";
	failure: "initiator" | "row";
	limit: number;
}
const acquire = (
	conflict: LocalPolicy["conflict"],
	retry: LocalPolicy["retry"] = "originalAcquisition",
): LocalPolicy => ({
	presentation: "indicate",
	conflict,
	retry,
	stop: "observe",
	stale: "originalAuthority",
	failure: "initiator",
	limit: retry === "originalReceipt" ? SESSION_CONTENT.limits.effects : LOCAL_LIMITS.acquisitions,
});
const read: LocalPolicy = {
	presentation: "indicate",
	conflict: "target",
	retry: "freshRead",
	stop: "retireRead",
	stale: "originalAuthority",
	failure: "initiator",
	limit: LOCAL_LIMITS.reads,
};
type Method<T> = { [K in keyof T]: T[K] extends (...args: never[]) => unknown ? K : never }[keyof T];
export const LOCAL_GESTURES = {
	directory: acquire("directory"),
	publicRoom: acquire("publication"),
	createRoom: acquire("directory", "originalReceipt"),
	direct: acquire("registration", "originalReceipt"),
	run: acquire("target", "originalReceipt"),
	clear: acquire("workspace", "originalReceipt"),
	post: { ...acquire("distinct", "originalReceipt"), presentation: "optimistic" },
	acquireLine: acquire("receipt", "originalReceipt"),
	replace: acquire("workspace"),
	operations: acquire("workspace"),
	importState: acquire("workspace"),
	acceptInvitation: acquire("target"),
	receive: acquire("receipt"),
	roomLink: acquire("directory"),
	recoverAcquisition: acquire("receipt"),
} satisfies Record<Exclude<Method<ManagedActions>, "close" | "stop">, LocalPolicy>;

type ReadPattern =
	| `read${string}`
	| `list${Capitalize<string>}`
	| `refresh${string}`
	| `load${string}`
	| `search${string}`
	| `export${string}`;
type ReadName = Extract<keyof RoomsSessionController, ReadPattern>;
export const READ_GESTURES = {
	readArchiveShare: { ...read, failure: "row" },
	listIssuedArchiveShares: read,
	readOpsBundle: read,
	refreshOpsCap: read,
	loadMoreOperator: read,
	searchOperator: read,
	exportRoomsState: read,
} satisfies Record<ReadName, LocalPolicy>;
