// Live moderation operations for one room membership and its IRC bridge.

import { useState } from "react";
import {
	moderationBridgeAuthority,
	moderationBridgeAuthorityHeld,
	moderationBridgeLink,
	moderationBridgeTitle,
	moderationKick,
	moderationKickAsk,
	moderationKickHint,
	moderationKicking,
	moderationKickLabel,
	moderationKickSay,
	moderationMembers,
	moderationNobodyElse,
	moderationUnbridge,
	moderationUnbridgeFrom,
	moderationUnbridgeHint,
	moderationUnbridgeLabel,
	moderationUnbridging,
	roomBridgeDefault,
	roomKeepBridge,
	roomKeepHere,
	roomModerationTitle,
	roomUnbridgeSay,
} from "../../../lib/text/room_authority.ts";
import { Button } from "../Button.tsx";
import { Confirm } from "../Confirm.tsx";
import { useRoomsSession } from "../controller/session.ts";
import { useConversationMembers } from "../hooks.ts";
import { Said } from "../Said.tsx";
import type { AdministeredBridge, RoomConv, Standing } from "../types.ts";
import { actionRefusal } from "../error_text.ts";

function membersToModerate(members: ReadonlyMap<string, Standing>, you: string): string[] {
	return [...members]
		.filter(([name, standing]) => standing.online && name !== you)
		.map(([name]) => name)
		.sort((a, b) => a.localeCompare(b));
}

/** Operations exposed by the live capabilities this session actually holds.
 * Member removal answers to a room moderator; unbridging answers to the IRC
 * gateway for this directory. Neither authority stands in for the other. */
export function RoomModeration(
	{ conv, you, available, administeredBridge }: {
		conv: RoomConv;
		you: string;
		available: boolean;
		administeredBridge: AdministeredBridge | null;
	},
) {
	const session = useRoomsSession();
	const members = useConversationMembers(conv.key);
	const [asking, setAsking] = useState<string | null>(null);
	const [working, setWorking] = useState<string | null>(null);
	const [askWhy, setAskWhy] = useState<Readonly<Record<string, string>>>({});
	const [confirmUnbridge, setConfirmUnbridge] = useState(false);
	const [unbridging, setUnbridging] = useState(false);
	const [unbridgeWhy, setUnbridgeWhy] = useState("");
	const canRemoveMembers = available && conv.grants.has("steward");
	if (!canRemoveMembers && administeredBridge === null) return null;
	const bridgeBadge = conv.bridge?.badge ?? roomBridgeDefault;
	const targets = membersToModerate(members, you);
	const confirming = asking !== null && targets.includes(asking) ? asking : null;
	return (
		<div className="group" role="group" aria-label={roomModerationTitle}>
			{canRemoveMembers && (
				<>
					<h3 className="well-title overline" id="convcardMemberModerationTitle">{moderationMembers}</h3>
					<div className="group well" role="group" aria-labelledby="convcardMemberModerationTitle">
						<p className="hint">{moderationKickHint}</p>
						{targets.length === 0
							? <p className="empty">{moderationNobodyElse}</p>
							: (
								<ul className="entries">
									{targets.map((name) => (
										<li className="entry" key={name}>
											<div className="entry-head">
												<span className="entry-name">{name}</span>
												<div className="actions">
													<Button
														variant="quiet"
														disabled={confirming === name}
														onClick={() => setAsking(name)}
													>
														{moderationKickAsk}
													</Button>
												</div>
											</div>
											{confirming === name && (
												<Confirm
													label={moderationKickLabel(name)}
													say={moderationKickSay(name)}
													keep={roomKeepHere}
													commit={working === name ? moderationKicking : moderationKick}
													commitId="convcardKickConfirm"
													busy={working === name}
													onKeep={() => setAsking(null)}
													onCommit={() => {
														setWorking(name);
														setAskWhy((prior) => ({ ...prior, [name]: "" }));
														void actionRefusal(() =>
															session.askRoomMemberOut(conv.key, name)
														).then(
															(refused) => {
																setAskWhy((prior) => ({ ...prior, [name]: refused }));
																if (refused === "") setAsking(null);
															},
														).finally(() => setWorking(null));
													}}
												/>
											)}
											{askWhy[name] != null && askWhy[name] !== "" && (
												<Said kind="failure">{askWhy[name]}</Said>
											)}
										</li>
									))}
								</ul>
							)}
					</div>
				</>
			)}
			{administeredBridge !== null && (
				<>
					<h3 className="well-title overline" id="convcardBridgeModerationTitle">
						{moderationBridgeTitle(bridgeBadge)}
					</h3>
					<div className="group well" role="group" aria-labelledby="convcardBridgeModerationTitle">
						<dl className="dirfacts">
							<dt>{moderationBridgeLink}</dt>
							<dd>{administeredBridge.connectionId}/{administeredBridge.leaseId}</dd>
							<dt>{moderationBridgeAuthority}</dt>
							<dd>{moderationBridgeAuthorityHeld(bridgeBadge)}</dd>
						</dl>
						<p className="hint" id="convcardUnbridgeHint">{moderationUnbridgeHint(bridgeBadge)}</p>
						{confirmUnbridge
							? (
								<Confirm
									label={moderationUnbridgeLabel(bridgeBadge)}
									say={roomUnbridgeSay}
									keep={roomKeepBridge}
									commit={unbridging ? moderationUnbridging : moderationUnbridge}
									commitId="convcardUnbridgeConfirm"
									busy={unbridging}
									onKeep={() => setConfirmUnbridge(false)}
									onCommit={() => {
										setUnbridging(true);
										setUnbridgeWhy("");
										void actionRefusal(() =>
											session.removeBridgeLease(
												administeredBridge.connectionId,
												administeredBridge.leaseId,
											)
										)
											.then((refused) => setUnbridgeWhy(refused))
											.finally(() => setUnbridging(false));
									}}
								/>
							)
							: (
								<div className="actions">
									<Button
										id="convcardUnbridgeAsk"
										variant="quiet"
										onClick={() => setConfirmUnbridge(true)}
									>
										{moderationUnbridgeFrom(bridgeBadge)}
									</Button>
								</div>
							)}
						{unbridgeWhy !== "" && <Said id="convcardUnbridgeWhy" kind="failure">{unbridgeWhy}</Said>}
					</div>
				</>
			)}
		</div>
	);
}
