import { retryJoin } from "../../../lib/text/admission.ts";
import { useMemo } from "react";
// A failed new selection still owns its target after the temporary row retires.
import { ActionFeedback, useActionCooldown } from "../ActionFeedback.tsx";
import { Button } from "../Button.tsx";
import { useRoomsState } from "../hooks.ts";
import { useRoomsSession } from "../controller/session.ts";
import { dirId } from "../types.ts";
import { joinRefusalKeys } from "../admission_feedback.ts";
export function JoinRefusal() {
	const refusals = useRoomsState((state) => state.actionRefusals);
	const visible = useRoomsState((state) => state.activeKey != null);
	const conversations = useRoomsState((state) => state.convs);
	const session = useRoomsSession();
	const entry = useMemo(() => {
		// Index each joined target once. Message projection must not search every
		// conversation again for every retained refusal.
		const joined = new Set<string>();
		for (const conversation of conversations.values()) {
			if (conversation.type === "room") joined.add(joinRefusalKeys(conversation.dir, conversation.id)[1]);
		}
		let latest;
		for (const candidate of refusals.entries()) {
			const target = candidate[1].target;
			if (
				target != null && target.room !== "" && !joined.has(joinRefusalKeys(target.directory, target.room)[1])
			) {
				latest = candidate;
			}
		}
		return latest;
	}, [refusals, conversations]);
	const cooldown = useActionCooldown(entry?.[0] ?? "");
	if (!visible || entry == null) return null;
	const [action, refusal] = entry;
	const target = refusal.target!;
	return (
		<li className="join-refusal-row">
			<span>{target.room}</span>
			<ActionFeedback action={action} />
			<Button disabled={cooldown > 0} onClick={() => void session.pickRoom(dirId(target.directory), target.room)}>
				{retryJoin}
			</Button>
		</li>
	);
}
