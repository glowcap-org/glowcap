// Persistent promotion for durable operations that require an explicit choice.

import { useCallback, useState } from "react";
import { Button } from "../Button.tsx";
import { useRoomsState } from "../hooks.ts";
import { useOpenModal } from "../modal.ts";
import { SessionRecoveryModal } from "./SessionRecovery.tsx";
import { sessionEffectMany, sessionEffectOne } from "../../../lib/text/page.ts";

export function SessionEffectNotice() {
	const effects = useRoomsState((state) => state.sessionEffects);
	const settingsOpen = useRoomsState((state) => state.settingsOpen);
	const openModalFrom = useOpenModal();
	const [reviewing, setReviewing] = useState(false);
	const closeReview = useCallback(() => setReviewing(false), []);
	const count = effects.length;
	return (
		<>
			{count > 0 && !settingsOpen && (
				<div className="session-effect-notice" role="status" aria-live="polite">
					<p>
						{count === 1 ? sessionEffectOne : sessionEffectMany(count)}
					</p>
					<Button
						id="sessionEffectReview"
						variant="quiet"
						onClick={(event) => openModalFrom(event.currentTarget, () => setReviewing(true))}
					>
						Review
					</Button>
				</div>
			)}
			<SessionRecoveryModal open={reviewing} onClose={closeReview} />
		</>
	);
}
