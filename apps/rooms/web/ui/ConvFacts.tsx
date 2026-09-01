// What this conversation is, wherever it is being asked.
//
// The directory card answers for the place this room or line lives on. This
// answers for the conversation itself: what kind of thing it is, how this tab
// reaches it, and the facts a reader would open the title to check. The
// directory's name is the door to that directory's conversation. The locator
// below the facts is that directory's address for a public room. A private room
// has no name-based entry, so its held room link is the only honest locator.
// Durable authority for either kind remains visible in the separate
// Capabilities tab.

import { type Conv, type DirView, membersHere } from "./types.ts";
import { useConversationMembers } from "./hooks.ts";
import { conversationReach, dirConnection } from "./text.ts";
import { grantedNameSaid } from "./DirectoryFacts.tsx";
import { dmMode } from "./prefs.ts";
import { CopyField } from "./Copy.tsx";
import { Button } from "./Button.tsx";
import { useRoomsBrowser } from "./controller/browser.ts";
import { useRoomsSession } from "./controller/session.ts";

function roomKind(held: boolean): string {
	return held ? "Private room" : "Public room";
}

function lineSaid(line: "introducing" | "live" | "closed"): string {
	if (line === "live") return "Open";
	if (line === "closed") return "Closed";
	return "Not open yet";
}

function dmPath(): string {
	return dmMode() === "relay" ? "Through the room relay, encrypted end to end" : "WebRTC, encrypted peer to peer";
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
	const rooms = useRoomsSession();
	const roster = useConversationMembers(conv.type === "room" ? conv.key : null);
	const phase = dir?.session;
	const connection = dir == null ? null : dirConnection(dir.session, dir.statusText);
	const here = conv.type === "room" ? membersHere(roster) : 0;
	const roomLink = conv.type === "room" && conv.held ? conv.link : undefined;
	const locator = roomLink ?? (dir === null ? null : rooms.dirAddress(dir.id));
	const locatorKind = roomLink === undefined ? "Directory locator" : "Room entry link";
	const locatorLabel = roomLink === undefined ? "Copy the locator for " + directory : "Copy the room entry link";
	return (
		<div className="group well">
			<dl className="dirfacts">
				<dt>This is</dt>
				<dd>
					{conv.type === "room" ? roomKind(conv.held) : conv.type === "dm" ? "Direct message" : "Directory"}
				</dd>
				<dt>Directory</dt>
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
						<dt>Connection</dt>
						<dd>
							<span className={"dot " + phase} aria-hidden="true" />
							{connection.said}
							{connection.why !== "" && <span className="dirfact-why">{connection.why}</span>}
						</dd>
					</>
				)}
				<dt>Your name</dt>
				<dd>{grantedNameSaid(dir)}</dd>
				{conv.type === "room" && (
					<>
						{bridgeOrigin !== null && (
							<>
								<dt>IRC channel</dt>
								<dd>Bridged via {bridgeOrigin}</dd>
							</>
						)}
						<dt>Topic</dt>
						<dd>{conv.topic === undefined || conv.topic === "" ? "None set" : conv.topic}</dd>
						<dt>Members here</dt>
						<dd>{here === 1 ? "1 person" : here + " people"}</dd>
						{conv.lineBytes !== undefined && (
							<>
								<dt>Line limit</dt>
								<dd>{"Up to " + conv.lineBytes + " bytes"}</dd>
							</>
						)}
					</>
				)}
				{conv.type === "dm" && (
					<>
						<dt>Line</dt>
						<dd>{lineSaid(conv.line)}</dd>
						<dt>Path</dt>
						<dd>{dmPath()}</dd>
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
