// A branch's status as a chip: active is the plain fact, paused and revoked
// warn, and a control not yet inspected says so quietly. status-allow: pending state or quoted runtime label
import { statusTag } from "../../../lib/text/managed_access.ts";
import type { GrantView } from "../session/managed/access.ts";

export function AccessStatusTag({ status }: { status: GrantView["status"] | undefined }) {
	const tone = status == null ? "quiet" : status === "active" ? undefined : "warn";
	return <span className="tag" data-tone={tone}>{statusTag[status ?? "uninspected"]}</span>;
}
