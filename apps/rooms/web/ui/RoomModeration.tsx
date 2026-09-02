// Live moderation operations for one room membership and its IRC bridge.

import { useState } from "react";
import { Button } from "./Button.tsx";
import { Confirm } from "./Confirm.tsx";
import { useRoomsSession } from "./controller/session.ts";
import { useConversationMembers } from "./hooks.ts";
import { Said } from "./Said.tsx";
import type { AdministeredBridge, RoomConv, Standing } from "./types.ts";

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
	const bridgeBadge = conv.bridge?.badge ?? "Bridge";
	const targets = membersToModerate(members, you);
	const confirming = asking !== null && targets.includes(asking) ? asking : null;
	return (
		<div className="group" role="group" aria-label="Room moderation">
			{canRemoveMembers && (
				<>
					<h3 className="well-title overline" id="convcardMemberModerationTitle">Members</h3>
					<div className="group well" role="group" aria-labelledby="convcardMemberModerationTitle">
						<p className="hint">
							Asking somebody to leave does not ban them. A room entry link or public room name still lets
							them return.
						</p>
						{targets.length === 0
							? <p className="empty">Nobody else is here right now.</p>
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
														Ask to leave…
													</Button>
												</div>
											</div>
											{confirming === name && (
												<Confirm
													label={"Ask " + name + " to leave"}
													say={"Ask " + name +
														" to leave the room? They can come back by its name or link."}
													keep="Keep here"
													commit={working === name ? "Asking to leave…" : "Ask to leave"}
													commitId="convcardKickConfirm"
													busy={working === name}
													onKeep={() => setAsking(null)}
													onCommit={() => {
														setWorking(name);
														setAskWhy((prior) => ({ ...prior, [name]: "" }));
														void session.askRoomMemberOut(conv.key, name).then(
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
					<h3 className="well-title overline" id="convcardBridgeModerationTitle">{bridgeBadge} bridge</h3>
					<div className="group well" role="group" aria-labelledby="convcardBridgeModerationTitle">
						<dl className="dirfacts">
							<dt>Link</dt>
							<dd>{administeredBridge.connectionId}/{administeredBridge.leaseId}</dd>
							<dt>Authority</dt>
							<dd>{bridgeBadge} gateway capability held by this session</dd>
						</dl>
						<p className="hint" id="convcardUnbridgeHint">
							Unbridging closes every {bridgeBadge}{" "}
							seat and removes this room from the directory. The linked conversation itself stays as it
							is.
						</p>
						{confirmUnbridge
							? (
								<Confirm
									label={`Unbridge this room from ${bridgeBadge}`}
									say="Unbridge this room? Every seat closes and the room leaves the directory."
									keep="Keep bridge"
									commit={unbridging ? "Unbridging…" : "Unbridge room"}
									commitId="convcardUnbridgeConfirm"
									busy={unbridging}
									onKeep={() => setConfirmUnbridge(false)}
									onCommit={() => {
										setUnbridging(true);
										setUnbridgeWhy("");
										void session.removeBridgeLease(
											administeredBridge.connectionId,
											administeredBridge.leaseId,
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
										Unbridge from {bridgeBadge}…
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
