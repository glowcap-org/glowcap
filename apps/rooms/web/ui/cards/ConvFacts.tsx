// What this conversation is, wherever it is being asked.
//
// The directory card answers for the place this room or line lives on. This
// answers for the conversation itself: what kind of thing it is, how this tab
// reaches it, and the facts a reader would open the title to check. The
// directory's name is the door to that directory's conversation. The locator
// below the facts is that directory's address for a public room. A private room
// has no name-based entry, so its held room link is the only accurate locator.
// Durable authority for either kind remains visible in the separate
// Capabilities tab.

import { type Conv, conversationCarries, conversationTakesFiles, type DirView, membersHere } from "../types.ts";
import { useConversationMembers, useRoomBearer } from "../hooks.ts";
import { conversationReach, dirConnection } from "../text.ts";
import { roomLinkTitle } from "../../../lib/text/room_authority.ts";
import {
	directoryConnection,
	factBridgedVia,
	factCarries,
	factCarriesSaid,
	factCopyLocatorFor,
	factCopyRoomLink,
	factDirectMessage,
	factDirectory,
	factDirectoryLocator,
	factDmDirect,
	factDmRelay,
	factIrcChannel,
	factLine,
	factLineClosed,
	factLineLimit,
	factLineNotOpen,
	factLineOpen,
	factMembersHere,
	factPath,
	factPeopleHere,
	factPrivateRoom,
	factPublicRoom,
	factSubject,
	factSubjectLink,
	factSubjectNone,
	factThisIs,
	factUpToBytes,
	factYourName,
} from "../../../lib/text/conversation.ts";
import { grantedNameSaid } from "./DirectoryFacts.tsx";
import { dmMode } from "../prefs.ts";
import { useManagedSession } from "../session/managed/context.tsx";
import { CopyField } from "../Copy.tsx";
import { subjectCopyLink } from "../../../lib/text/controls.ts";
import { Button } from "../Button.tsx";
import { useRoomsBrowser } from "../controller/browser.ts";
import { useRoomsSession } from "../controller/session.ts";

function roomKind(held: boolean): string {
	return held ? factPrivateRoom : factPublicRoom;
}

function lineSaid(line: "introducing" | "live" | "closed"): string {
	if (line === "live") return factLineOpen;
	if (line === "closed") return factLineClosed;
	return factLineNotOpen;
}

export function ConvFacts(
	{ conv, dir, directory, bridgeOrigin = null }: {
		conv: Conv;
		dir: DirView | null;
		directory: string;
		bridgeOrigin?: string | null;
	},
) {
	const browser = useRoomsBrowser();
	const managed = useManagedSession();
	const rooms = useRoomsSession();
	const roster = useConversationMembers(conv.type === "room" ? conv.key : null);
	const phase = dir?.session;
	const connection = dir == null ? null : dirConnection(dir.session, dir.statusText);
	const here = conv.type === "room" ? membersHere(roster) : 0;
	const bearer = useRoomBearer(conv.type === "room" && conv.held ? conv : null, "link");
	const roomLink = bearer ?? undefined;
	const locator = roomLink ?? (dir === null ? null : rooms.dirAddress(dir.id));
	const locatorKind = roomLink === undefined ? factDirectoryLocator : roomLinkTitle;
	const locatorLabel = roomLink === undefined ? factCopyLocatorFor(directory) : factCopyRoomLink;
	return (
		<div className="group well">
			<dl className="dirfacts">
				<dt>{factThisIs}</dt>
				<dd>
					{conv.type === "room"
						? roomKind(conv.held)
						: conv.type === "dm"
						? factDirectMessage
						: factDirectory}
				</dd>
				<dt>{factDirectory}</dt>
				<dd>
					{dir === null ? directory : (
						<Button
							id="convcardDir"
							variant="link"
							onClick={() => browser.showDirectory(dir.id)}
						>
							{directory}
						</Button>
					)}
				</dd>
				{connection !== null && (
					<>
						<dt>{directoryConnection}</dt>
						<dd>
							<span className={"dot " + phase} aria-hidden="true" />
							{connection.said}
							{connection.why !== "" && <span className="dirfact-why">{connection.why}</span>}
						</dd>
					</>
				)}
				<dt>{factYourName}</dt>
				<dd>{grantedNameSaid(dir)}</dd>
				{conv.type === "room" && (
					<>
						{bridgeOrigin !== null && (
							<>
								<dt>{factIrcChannel}</dt>
								<dd>{factBridgedVia(bridgeOrigin)}</dd>
							</>
						)}
						<dt>{factSubject}</dt>
						<dd>{conv.subject?.description ?? factSubjectNone}</dd>
						{conv.subject?.link !== undefined && (
							<>
								<dt>{factSubjectLink}</dt>
								<dd>
									<CopyField
										id="convcardSubjectLink"
										text={conv.subject.link}
										label={subjectCopyLink}
									/>
								</dd>
							</>
						)}
						<dt>{factMembersHere}</dt>
						<dd>{factPeopleHere(here)}</dd>
						{conv.lineBytes !== undefined && (
							<>
								<dt>{factLineLimit}</dt>
								<dd>{factUpToBytes(conv.lineBytes)}</dd>
							</>
						)}
						{
							/* Said only when something a message ordinarily carries is
						    missing here, for a seated participant: an ordinary room says
						    nothing, and an observer's seat already says what it cannot do. */
						}
						{conv.membership === "joined" && conv.membershipKind === "participant" &&
							(!conversationTakesFiles(conv) || !conversationCarries(conv, "previews") ||
								!conversationCarries(conv, "typing")) &&
							(
								<>
									<dt>{factCarries}</dt>
									<dd>
										{factCarriesSaid(
											conversationTakesFiles(conv),
											conversationCarries(conv, "previews"),
											conversationCarries(conv, "typing"),
										)}
									</dd>
								</>
							)}
					</>
				)}
				{conv.type === "dm" && (
					<>
						<dt>{factLine}</dt>
						<dd>{lineSaid(conv.line)}</dd>
						<dt>{factPath}</dt>
						<dd>{dmMode(managed.current?.intent.connection) === "relay" ? factDmRelay : factDmDirect}</dd>
					</>
				)}
			</dl>
			<p className="field-label" id="convcardUriKind">{locatorKind}</p>
			<CopyField
				id="convcardLocator"
				text={locator}
				label={locatorLabel}
			/>
			{conv.type !== "directory" && <p className="hint" id="convcardReach">{conversationReach(conv)}</p>}
		</div>
	);
}
