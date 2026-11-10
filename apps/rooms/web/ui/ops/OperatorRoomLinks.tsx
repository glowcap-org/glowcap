// The card over the Room authority list for one room: its manager link and
// its moderator link, each in its own well the way the room card's links tab
// lays them out. A link that stands is a copy field with what holding it
// means and the one quiet act that revokes it. A link that does not stand is
// the one act that issues it. The question a revoke asks stays in the well
// that raised it, and so does a refusal. A room an IRC bridge runs takes no
// manager link and only the bridge removes it, so its manager well says why
// and it has no Forget well.

import { Fragment } from "react";
import type { StewardshipView } from "./capabilities.ts";
import {
	operatorBridgedManagerHint,
	operatorCopyManager,
	operatorCopyModerator,
	operatorForgetRoom,
	operatorForgetRoomAsk,
	operatorForgetRoomEffect,
	operatorForgetRoomHint,
	operatorForgetRoomTitle,
	operatorIssueManager,
	operatorIssueModerator,
	operatorIssuing,
	operatorManagerHeldHint,
	operatorManagerLinkTitle,
	operatorManagerNoneHint,
	operatorManagerRevoke,
	operatorManagerRevokeEffect,
	operatorModeratorHeldHint,
	operatorModeratorLinkTitle,
	operatorModeratorNoneHint,
	operatorModeratorRevoke,
	operatorModeratorRevokeEffect,
	operatorPrivateRoom,
	operatorRevokeAsk,
	operatorRoomLinksCardTitle,
	operatorRoomLinksLead,
} from "../../../lib/text/operator.ts";
import { Button } from "../Button.tsx";
import { CopyField } from "../Copy.tsx";
import { Said } from "../Said.tsx";
import { Submodal } from "../Submodal.tsx";
import type { OperatorActs } from "./operator_acts.tsx";

export function OperatorRoomLinksCard(
	{ row, open, onClose, acts }: {
		row: StewardshipView;
		open: boolean;
		onClose(): void;
		acts: OperatorActs;
	},
) {
	const session = acts.session;
	const title = row.label || operatorPrivateRoom;
	const forgetKey = `forget:${row.name}`;
	const keys = [`manager:${row.name}`, `moderator:${row.name}`, forgetKey];
	const parts = [
		{
			kind: "manager",
			title: operatorManagerLinkTitle,
			link: row.managerLink,
			held: operatorManagerHeldHint,
			none: operatorManagerNoneHint,
			issue: operatorIssueManager,
			copy: operatorCopyManager(title),
			effect: operatorManagerRevokeEffect,
			revoke: operatorManagerRevoke,
			give: () => session.giveRoomManager(row.name),
			drop: () => session.revokeRoomManager(row.name),
		},
		{
			kind: "moderator",
			title: operatorModeratorLinkTitle,
			link: row.stewardLink,
			held: operatorModeratorHeldHint,
			none: operatorModeratorNoneHint,
			issue: operatorIssueModerator,
			copy: operatorCopyModerator(title),
			effect: operatorModeratorRevokeEffect,
			revoke: operatorModeratorRevoke,
			give: () => session.giveRoomStewardship(row.name),
			drop: () => session.revokeRoomStewardship(row.name),
		},
	];
	return (
		<Submodal
			title={operatorRoomLinksCardTitle(title)}
			titleId="operatorRoomLinksTitle"
			className="operator-room-links"
			open={open}
			onClose={() => {
				// A question or a refusal belongs to the card that raised it, and
				// closing the card ends it.
				acts.dismiss(keys);
				onClose();
			}}
		>
			<p className="lead">{operatorRoomLinksLead}</p>
			{parts.map((part) => {
				const key = `${part.kind}:${row.name}`;
				const titleId = `operatorRoomLinks-${part.kind}`;
				return (
					<Fragment key={part.kind}>
						<h3 className="well-title overline" id={titleId}>{part.title}</h3>
						<div className="group well" role="group" aria-labelledby={titleId} data-part={part.kind}>
							{part.kind === "manager" && row.bridged
								? <p className="hint">{operatorBridgedManagerHint}</p>
								: part.link !== null
								? (
									<>
										<CopyField text={part.link} label={part.copy} />
										<p className="hint">{part.held}</p>
										<div className="actions">{acts.asker(key, operatorRevokeAsk)}</div>
										{acts.confirm(key, part.effect, part.revoke, part.drop)}
									</>
								)
								: (
									<>
										<p className="hint">{part.none}</p>
										<div className="actions">
											<Button
												busy={acts.busy(key)}
												disabled={acts.locked}
												onClick={() => acts.run(key, part.give)}
											>
												{acts.busy(key) ? operatorIssuing : part.issue}
											</Button>
										</div>
									</>
								)}
							{acts.why[key] != null && <Said kind="failure">{acts.why[key]}</Said>}
						</div>
					</Fragment>
				);
			})}
			{!row.bridged && (
				<>
					<h3 className="well-title overline" id="operatorRoomLinks-forget">{operatorForgetRoomTitle}</h3>
					<div
						className="group well"
						role="group"
						aria-labelledby="operatorRoomLinks-forget"
						data-part="forget"
					>
						<p className="hint">{operatorForgetRoomHint}</p>
						<div className="actions">{acts.asker(forgetKey, operatorForgetRoomAsk)}</div>
						{acts.confirm(
							forgetKey,
							operatorForgetRoomEffect,
							operatorForgetRoom,
							() => session.forgetRoom(row.name),
						)}
						{acts.why[forgetKey] != null && <Said kind="failure">{acts.why[forgetKey]}</Said>}
					</div>
				</>
			)}
		</Submodal>
	);
}
