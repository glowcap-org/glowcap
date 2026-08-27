// What this conversation is, wherever it is being asked.
//
// The directory card answers for the place this room or line lives on. This
// answers for the conversation itself: what kind of thing it is, how this tab
// reaches it, and the facts a reader would open the title to check. The
// directory's name is the door to that card. The locator below the facts is
// that directory's address unless this tab already holds a room link — from
// `/link`, or from `/join` of one. Opening the card never mints that link.

import { type Conv, type DirView, membersHere } from "./types.ts";
import { conversationReach, dirConnection } from "./text.ts";
import { dmMode } from "./prefs.ts";
import { CopyField } from "./Copy.tsx";
import { Button } from "./Button.tsx";
import { openModalFrom } from "./modal.ts";
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
	const phase = dir?.session;
	const connection = dir == null ? null : dirConnection(dir.session, dir.statusText);
	const here = conv.type === "room" ? membersHere(conv.members) : 0;
	const roomLink = conv.type === "room" ? conv.link : undefined;
	const locator = roomLink ?? (dir === null ? null : rooms.dirAddress(dir.id));
	const locatorKind = roomLink === undefined ? "Directory locator" : "Room link";
	const locatorLabel = roomLink === undefined ? "Copy the locator for " + directory : "Copy the room link";
	return (
		<div className="group well">
			<dl className="dirfacts">
				<dt>This is</dt>
				<dd>
					{conv.type === "room" ? roomKind(conv.held) : "Direct message"}
				</dd>
				<dt>Directory</dt>
				<dd>
					{dir === null ? directory : (
						<Button
							id="convcardDir"
							variant="link"
							aria-haspopup="dialog"
							onClick={(event) =>
								openModalFrom(event.currentTarget, () => browser.aboutDirectory(dir.id))}
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
				<dt>Your name here</dt>
				<dd>{dir === null || dir.nick === "" ? "Not granted yet" : dir.nick}</dd>
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
			<p className="hint" id="convcardReach">{conversationReach(conv)}</p>
		</div>
	);
}
