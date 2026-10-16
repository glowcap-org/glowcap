// A room's moderation authorities and the operations they make possible.
//
// The application-wide Operations page supplied the useful shape, not this
// layout: possession is a visible fact, taking a capability is an explicit
// act, and only operations backed by a capability held are offered.
// A local room moderator can remove members. An IRC gateway holder can retire
// one exact bridge it administers. The tab shows only the powers this session
// actually holds, without treating the broader gateway as room stewardship.

import { Link } from "react-router";
import { useRoomBearer } from "../hooks.ts";
import { opsAddress, paneForCap } from "../ops/panes.ts";
import {
	bridgeHasNoManagerAfter,
	bridgeHasNoManagerLead,
	bridgeHasNoManagerLink,
	roomAuthorityModerate,
	roomAuthorityModerateHeld,
	roomAuthorityModerateNotHeld,
	roomAuthorityModerateRetained,
	roomAuthorityModerateViaManager,
	roomAuthoritySubject,
	roomAuthoritySubjectHeld,
	roomAuthoritySubjectNotOffered,
	roomAuthorityTitle,
	roomCapabilitiesTitle,
	roomDiscardCapability,
	roomKeepCapability,
	roomKeepLink,
	roomKeepManagement,
	roomKeepRegistration,
	roomLinkCopy,
	roomLinkCreate,
	roomLinkCreateHint,
	roomLinkCreating,
	roomLinkHeldHint,
	roomLinkNoneHint,
	roomLinkRevoke,
	roomLinkRevokeAsk,
	roomLinkRevoked,
	roomLinkRevokeSay,
	roomLinkSave,
	roomLinkSaveHint,
	roomLinkSaving,
	roomLinkTitle,
	roomManagementTitle,
	roomManagerCopy,
	roomManagerDiscard,
	roomManagerDiscardAsk,
	roomManagerDiscarded,
	roomManagerDiscardSay,
	roomManagerHeldHint,
	roomManagerRecover,
	roomManagerRecoverHint,
	roomManagerSourceOwned,
	roomManagerTake,
	roomManagerTakeCommit,
	roomManagerTakeHint,
	roomModerationRevokeAll,
	roomModerationRevokeAllSay,
	roomModeratorCopy,
	roomModeratorDiscard,
	roomModeratorDiscardAsk,
	roomModeratorDiscarded,
	roomModeratorDiscardSay,
	roomModeratorHeldHint,
	roomModeratorIssue,
	roomModeratorIssuing,
	roomModeratorKind,
	roomModeratorRevokeAllAsk,
	roomModeratorRevokedAll,
	roomModeratorTake,
	roomModeratorTakeCommit,
	roomModeratorTakeHint,
	roomModeratorTakeRetained,
	roomModeratorTaking,
	roomModeratorTakingRetained,
	roomNameReleaseAsk,
	roomNameReleased,
	roomNameReleaseLabel,
	roomNameReleaseSay,
	roomReleaseName,
	roomRevokeAuthority,
	roomRevokeModerator,
} from "../../../lib/text/room_authority.ts";
import { sturdyrefPlaceholder } from "../../../lib/text/controls.ts";
import { Button } from "../Button.tsx";
import { Confirm } from "../Confirm.tsx";
import { CopyField } from "../Copy.tsx";
import { Field } from "../Field.tsx";
import { identifierField } from "../field.ts";
import { useRoomsSession } from "../controller/session.ts";
import { useRoomsBrowser } from "../controller/browser.ts";
import { Said } from "../Said.tsx";
import type { RoomConv } from "../types.ts";
import { RoomRecovery } from "./RoomRecovery.tsx";
import { roomIsListed } from "../room_policy.ts";
import { RoomAccessControl } from "./RoomAccess.tsx";
import { useRoomCapabilityActs } from "../room_capability_acts.ts";

export function RoomCapabilities(
	{ conv, available, authoritySource }: {
		conv: RoomConv;
		available: boolean;
		authoritySource: "local" | "foreign" | "bridge" | "unknown";
	},
) {
	const session = useRoomsSession();
	const browser = useRoomsBrowser();
	const {
		directoryOperatorPossessed,
		directoryOperatorCanManage,
		managerPasted,
		setManagerPasted,
		takingManager,
		managerSaid,
		setManagerSaid,
		pasted,
		setPasted,
		taking,
		claimSaid,
		takeSaid,
		setTakeSaid,
		linking,
		linkSaid,
		confirming,
		setConfirming,
		authorityBusy,
		authoritySaid,
		policyBusy,
		policySaid,
		authorityWorking,
		held,
		managerHeld,
		canRevoke,
		changePolicy,
		managerTakeShown,
		stewardTakeShown,
		take,
		takeManager,
		recoverManager,
		createLink,
		changeAuthority,
		roomToken,
		managerToken,
		stewardToken,
		revokeAuthority,
	} = useRoomCapabilityActs(conv, authoritySource);
	// The strings themselves stay out of the store; the card reads each from
	// the session as it draws, so a copy field shows the current one.
	const linkBearer = useRoomBearer(conv, "link");
	const managerBearer = useRoomBearer(conv, "manager");
	const stewardBearer = useRoomBearer(conv, "steward");

	return (
		<div className="group" role="group" aria-label={roomCapabilitiesTitle}>
			<h3 className="well-title overline" id="convcardManagerTitle">{roomManagementTitle}</h3>
			<div className="group well" role="group" aria-labelledby="convcardManagerTitle">
				{conv.managerToken == null
					? !managerTakeShown
						? (
							<p className="hint">
								{bridgeHasNoManagerLead} {
									/* The card is a layer over the page, and a route change under it
								    leaves it standing: the address would move to IRC operations
								    while the reader was still looking at the room. Put it away as
								    the link is taken, the way Operations closes Settings before
								    it navigates. */
								}
								<Link
									to={opsAddress(paneForCap("irc"))}
									onClick={() => browser.closeAboutConversation()}
								>
									{bridgeHasNoManagerLink}
								</Link>
								{bridgeHasNoManagerAfter}
							</p>
						)
						: (
							<form
								className="group"
								onSubmit={(event) => {
									event.preventDefault();
									if (managerPasted !== "") takeManager();
								}}
							>
								<Field
									id="convcardManagerTake"
									label={roomManagerTake}
									hint={roomManagerTakeHint}
									said={managerSaid}
								>
									{(wiring) => (
										<input
											id={wiring.id}
											className="field"
											value={managerPasted}
											onChange={(event) => {
												setManagerPasted(event.currentTarget.value);
												setManagerSaid("");
											}}
											{...identifierField}
											placeholder={sturdyrefPlaceholder}
											aria-describedby={wiring.describedBy}
											aria-invalid={wiring.invalid}
											disabled={!available || authorityWorking}
										/>
									)}
								</Field>
								<div className="actions">
									<Button
										type="submit"
										busy={takingManager === "take"}
										disabled={!available || authorityWorking || managerPasted.trim() === ""}
									>
										{roomManagerTakeCommit}
									</Button>
								</div>
								{directoryOperatorCanManage && (
									<>
										<p className="hint">{roomManagerRecoverHint}</p>
										<div className="actions">
											<Button
												id="convcardManagerRecover"
												type="button"
												variant="quiet"
												busy={takingManager === "recover"}
												disabled={!available || authorityWorking}
												onClick={recoverManager}
											>
												{roomManagerRecover}
											</Button>
										</div>
									</>
								)}
								{directoryOperatorPossessed && !directoryOperatorCanManage && (
									<p className="hint">{roomManagerSourceOwned}</p>
								)}
							</form>
						)
					: (
						<>
							<CopyField
								id="convcardManager"
								text={managerBearer ?? ""}
								label={roomManagerCopy}
							/>
							<p className="hint">{roomManagerHeldHint}</p>
							{managerToken !== null && (
								<>
									{confirming?.act === "drop-manager" && confirming.token === managerToken
										? (
											<Confirm
												label={roomManagerDiscard}
												say={roomManagerDiscardSay}
												keep={roomKeepManagement}
												commit={roomDiscardCapability}
												busy={authorityBusy === "drop-manager"}
												onKeep={() => setConfirming(null)}
												onCommit={() =>
													changeAuthority(
														confirming,
														() => session.dropRoomManager(conv.key, confirming.token),
														roomManagerDiscarded,
													)}
											/>
										)
										: confirming?.act === "unregister-room" && confirming.token === managerToken
										? (
											<Confirm
												label={roomNameReleaseLabel(conv.id)}
												say={roomNameReleaseSay}
												keep={roomKeepRegistration}
												commit={roomReleaseName}
												busy={authorityBusy === "unregister-room"}
												onKeep={() => setConfirming(null)}
												onCommit={() =>
													changeAuthority(
														confirming,
														() => session.unregisterManagedRoom(conv.key),
														roomNameReleased(conv.id),
													)}
											/>
										)
										: (
											<div className="actions">
												<Button
													id="convcardManagerDropAsk"
													variant="quiet"
													disabled={authorityWorking}
													onClick={() =>
														setConfirming({ act: "drop-manager", token: managerToken })}
												>
													{roomManagerDiscardAsk}
												</Button>
												{roomIsListed(conv.policy) && (
													<Button
														id="convcardUnregisterAsk"
														variant="quiet"
														disabled={authorityWorking}
														onClick={() =>
															setConfirming({
																act: "unregister-room",
																token: managerToken,
															})}
													>
														{roomNameReleaseAsk}
													</Button>
												)}
											</div>
										)}
									{authoritySaid["drop-manager"] && (
										<Said kind="failure">{authoritySaid["drop-manager"]}</Said>
									)}
									{authoritySaid["unregister-room"] && (
										<Said kind="failure">{authoritySaid["unregister-room"]}</Said>
									)}
								</>
							)}
						</>
					)}
			</div>
			{conv.managerToken != null && (
				<RoomAccessControl
					policy={conv.policy}
					busy={policyBusy}
					disabled={!available || authorityWorking}
					said={policySaid}
					onChange={changePolicy}
				/>
			)}
			{!available && <RoomRecovery conv={conv} blocked={authorityWorking} />}
			<h3 className="well-title overline" id="convcardRoomLinkTitle">{roomLinkTitle}</h3>
			<div className="group well" role="group" aria-labelledby="convcardRoomLinkTitle">
				{conv.linkToken === undefined
					? (
						<>
							<p className="hint" id="convcardRoomLinkHint">
								{managerHeld
									? roomLinkCreateHint
									: authoritySource === "bridge"
									? roomLinkSaveHint
									: roomLinkNoneHint}
							</p>
							{(managerHeld || authoritySource === "bridge") && (
								<div className="actions">
									<Button
										id="convcardCreateRoomLink"
										busy={linking}
										disabled={!available || authorityWorking}
										aria-describedby="convcardRoomLinkHint"
										onClick={createLink}
									>
										{linking
											? authoritySource === "bridge" ? roomLinkSaving : roomLinkCreating
											: authoritySource === "bridge"
											? roomLinkSave
											: roomLinkCreate}
									</Button>
								</div>
							)}
							{linkSaid !== "" && <Said id="convcardRoomLinkSaid" kind="failure">{linkSaid}</Said>}
						</>
					)
					: (
						<>
							<CopyField
								id="convcardRoomLink"
								text={linkBearer ?? ""}
								label={roomLinkCopy}
							/>
							<p className="hint" id="convcardRoomLinkHint">{roomLinkHeldHint}</p>
							{canRevoke && roomToken !== null && (
								<>
									{confirming?.act === "revoke-room" && confirming.token === roomToken
										? (
											<Confirm
												label={roomLinkRevoke}
												say={roomLinkRevokeSay}
												keep={roomKeepLink}
												commit={roomRevokeAuthority}
												busy={authorityBusy === "revoke-room"}
												onKeep={() => setConfirming(null)}
												onCommit={() =>
													changeAuthority(
														confirming,
														() => revokeAuthority("room", confirming.token),
														roomLinkRevoked,
													)}
											/>
										)
										: (
											<div className="actions">
												<Button
													id="convcardRoomLinkRevokeAsk"
													variant="quiet"
													disabled={authorityWorking}
													onClick={() =>
														setConfirming({ act: "revoke-room", token: roomToken })}
												>
													{roomLinkRevokeAsk}
												</Button>
											</div>
										)}
									{authoritySaid["revoke-room"] && (
										<Said kind="failure">{authoritySaid["revoke-room"]}</Said>
									)}
								</>
							)}
						</>
					)}
			</div>
			<h3 className="well-title overline" id="convcardRoomAuthorityTitle">{roomAuthorityTitle}</h3>
			<div className="group well" role="group" aria-labelledby="convcardRoomAuthorityTitle">
				<dl className="dirfacts">
					<dt>{roomAuthoritySubject}</dt>
					<dd>{conv.grants.has("subject") ? roomAuthoritySubjectHeld : roomAuthoritySubjectNotOffered}</dd>
					<dt>{roomAuthorityModerate}</dt>
					<dd>
						{held
							? roomAuthorityModerateHeld
							: conv.stewardToken !== undefined
							? roomAuthorityModerateRetained
							: managerHeld
							? roomAuthorityModerateViaManager
							: roomAuthorityModerateNotHeld}
					</dd>
				</dl>
				{stewardTakeShown && (conv.stewardToken !== undefined || managerHeld) && (
					<div className="actions">
						<Button
							id="convcardStewardClaim"
							/* The alternative route, beside the paste form's own submit below:
							   the room manager's well pairs them the same way, its form
							   carrying the solid act and `convcardManagerRecover` the quiet
							   one. Two solid buttons in one well ask the reader to choose
							   between two shouts. */
							variant="quiet"
							busy={taking === "claim"}
							disabled={!available || authorityWorking}
							onClick={() => take("claim", stewardBearer ?? undefined)}
						>
							{taking === "claim"
								? conv.stewardToken === undefined ? roomModeratorIssuing : roomModeratorTakingRetained
								: conv.stewardToken === undefined
								? roomModeratorIssue
								: roomModeratorTakeRetained}
						</Button>
					</div>
				)}
				{claimSaid !== "" && <Said id="convcardStewardSaid" kind="failure">{claimSaid}</Said>}
				{stewardTakeShown && (
					<form
						className="group"
						onSubmit={(event) => {
							event.preventDefault();
							if (pasted !== "") take("form", pasted);
						}}
					>
						<Field
							id="convcardStewardTake"
							label={roomModeratorTake}
							hint={roomModeratorTakeHint}
							said={takeSaid}
						>
							{(wiring) => (
								<input
									id={wiring.id}
									className="field"
									name="steward"
									type="text"
									enterKeyHint="go"
									value={pasted}
									onChange={(event) => {
										setPasted(event.target.value);
										setTakeSaid("");
									}}
									{...identifierField}
									placeholder={sturdyrefPlaceholder}
									aria-describedby={wiring.describedBy}
									aria-invalid={wiring.invalid}
									disabled={!available || authorityWorking}
								/>
							)}
						</Field>
						<div className="actions">
							<Button
								type="submit"
								busy={taking === "form"}
								disabled={!available || authorityWorking || pasted.trim() === ""}
							>
								{taking === "form" ? roomModeratorTaking : roomModeratorTakeCommit}
							</Button>
						</div>
					</form>
				)}
				{conv.stewardToken !== undefined && (
					<>
						<p className="field-label" id="convcardStewardKind">{roomModeratorKind}</p>
						<CopyField
							id="convcardSteward"
							text={stewardBearer ?? ""}
							label={roomModeratorCopy}
						/>
						<p className="hint" id="convcardStewardHint">{roomModeratorHeldHint}</p>
						{stewardToken !== null && (
							<>
								{confirming?.act === "drop-steward" && confirming.token === stewardToken
									? (
										<Confirm
											label={roomModeratorDiscard}
											say={roomModeratorDiscardSay}
											keep={roomKeepCapability}
											commit={roomDiscardCapability}
											busy={authorityBusy === "drop-steward"}
											onKeep={() => setConfirming(null)}
											onCommit={() =>
												changeAuthority(
													confirming,
													() => session.dropRoomModerator(conv.key, confirming.token),
													roomModeratorDiscarded,
												)}
										/>
									)
									: confirming?.act === "revoke-steward" && confirming.token === stewardToken
									? (
										<Confirm
											label={roomModerationRevokeAll}
											say={roomModerationRevokeAllSay}
											keep={roomKeepCapability}
											commit={roomRevokeModerator}
											busy={authorityBusy === "revoke-steward"}
											onKeep={() => setConfirming(null)}
											onCommit={() =>
												changeAuthority(
													confirming,
													() => revokeAuthority("steward", confirming.token),
													roomModeratorRevokedAll,
												)}
										/>
									)
									: (
										<div className="actions">
											<Button
												id="convcardStewardDropAsk"
												variant="quiet"
												disabled={authorityWorking}
												onClick={() =>
													setConfirming({ act: "drop-steward", token: stewardToken })}
											>
												{roomModeratorDiscardAsk}
											</Button>
											{canRevoke && (
												<Button
													id="convcardStewardRevokeAsk"
													variant="quiet"
													disabled={authorityWorking}
													onClick={() =>
														setConfirming({ act: "revoke-steward", token: stewardToken })}
												>
													{roomModeratorRevokeAllAsk}
												</Button>
											)}
										</div>
									)}
								{authoritySaid["drop-steward"] && (
									<Said kind="failure">{authoritySaid["drop-steward"]}</Said>
								)}
								{authoritySaid["revoke-steward"] && (
									<Said kind="failure">{authoritySaid["revoke-steward"]}</Said>
								)}
							</>
						)}
					</>
				)}
			</div>
		</div>
	);
}
