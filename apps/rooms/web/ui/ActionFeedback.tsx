import { retryCountdown } from "../../lib/text/admission.ts";
import { useEffect, useState } from "react";
import { activeRefusal, remaining } from "./admission_feedback.ts";
import { useRoomsState } from "./hooks.ts";
import { Said } from "./Said.tsx";

export function useActionCooldown(action: string | readonly string[]): number {
	const refusal = activeRefusal(useRoomsState((state) => state.actionRefusals), action);
	const [now, setNow] = useState(() => performance.now());
	useEffect(() => {
		setNow(performance.now());
		if (refusal?.until == null) return;
		const timer = setInterval(() => {
			const now = performance.now();
			setNow(now);
			if (now >= refusal.until!) clearInterval(timer);
		}, 250);
		return () => clearInterval(timer);
	}, [refusal]);
	return remaining(refusal, now);
}

export function ActionFeedback({ action, target }: {
	action: string | readonly string[];
	target?: { directory: string; room: string };
}) {
	const refusal = activeRefusal(useRoomsState((state) => state.actionRefusals), action);
	const seconds = useActionCooldown(action);
	if (refusal == null) return null;
	if (
		target != null && (refusal.target?.directory !== target.directory ||
			refusal.target?.room.toLowerCase() !== target.room.toLowerCase())
	) return null;
	return (
		<div className="action-feedback">
			<Said kind="warning">{refusal.text}</Said>
			{seconds > 0 && <span role="status">{retryCountdown(seconds)}</span>}
		</div>
	);
}
