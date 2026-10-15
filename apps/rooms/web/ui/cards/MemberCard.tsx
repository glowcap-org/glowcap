// Who one person is, on their own surface.
//
// A roster row has to stay short, because it is one of a column of people, so
// it says a name and a state and stops. The rest of the answer lives here: which
// directory granted that name, whether this person can be reached, and what the
// reader can do about them. The room's card answers for the room and the
// directory's card for the directory, so the three divide the page's nouns
// between them and none has to guess at another's subject.
//
// The card is the same shape whoever it describes, including the
// reader. Opening your own from the rail's foot and someone else's from a
// roster should not feel like two features, and the one fact that does differ,
// that a name is granted per directory and you may hold several, is a fact
// about names rather than about whose card this is.

import { memo, useLayoutEffect, useMemo, useRef } from "react";
import type { DirId, DirView, MemberRef, Standing } from "../types.ts";
import { useConversationMembers, useRoomsState } from "../hooks.ts";
import { useRoomsBrowser } from "../controller/browser.ts";
import { useRoomsSession } from "../controller/session.ts";
import { directoryName } from "../text.ts";
import { useHeldModal, useModalDialog } from "../modal.ts";
import { type MemberIdentity, memberIdentity } from "../member_identity.ts";
import { ModalHead } from "../ModalHead.tsx";
import { Button } from "../Button.tsx";
import { PresenceAvatar, type PresenceState } from "../Avatar.tsx";
import { dmSaid } from "./DirectoryFacts.tsx";
import {
	factThisIs,
	memberAMember,
	memberAway,
	memberCanMessage,
	memberDirectMessages,
	memberGrantedBy,
	memberHereNow,
	memberManageBridgeIdentity,
	memberMessageDirectly,
	memberNoDirectoryNamed,
	memberNoDirectoryNamedYou,
	memberNoNameYet,
	memberNotReachable,
	memberOf,
	memberYou,
	memberYourNames,
} from "../../../lib/text/conversation.ts";
import { memberNetwork, memberPresence } from "../../../lib/text/conversation.ts";
import { memberOffline } from "../../../lib/text/conversation.ts";

/** Everything the card paints, gathered while the member is still on screen.
 *
 * Held whole through the close transition for the reason the directory card
 * holds its own: a member who leaves as the card closes would otherwise rewrite
 * it on the way out, and the reverse transition would play over facts that were
 * never true together. */
interface MemberView {
	/** The roster key every act here names. */
	key: string;
	name: string;
	mark: MemberIdentity["mark"];
	said: string;
	network: MemberIdentity["network"];
	/** The bridge's own word for itself when this room is bridged, so the
	 * reader's own identity control names the service rather than a hardcoded
	 * "IRC". Null in a room with no bridge. */
	bridgeBadge: string | null;
	standing: Standing;
	you: boolean;
	/** The room this reading came from. Null when the foot opened the card, which
	 * is about the reader on the page rather than in any one room, and null for a
	 * conversation that is not a room, because neither names a room to say. */
	room: string | null;
	dir: DirView | null;
	dirName: string;
	/** Every name this reader holds, when the card is their own: a name belongs
	 * to one directory, so the reader's card is the one place that has to say so
	 * rather than let a single name look like it covers the page. */
	grants: readonly { id: DirId; nick: string; where: string }[];
	reachable: boolean;
	pageStanding: string;
}

export const MemberCard = memo(function MemberCard(
	{ about, canInteract, onLayer }: {
		about: MemberRef | null;
		canInteract: boolean;
		onLayer: (held: boolean) => void;
	},
) {
	// Each of these is one stable reference out of the store. Building the view
	// inside the selector instead returns a fresh object on every call, so no
	// equality check can ever match it and React re-renders until it gives up;
	// the arrays this view holds are exactly what makes that fatal here. Derive
	// outside, where a `useMemo` can hold the result still.
	const convs = useRoomsState((state) => state.convs);
	const dirs = useRoomsState((state) => state.dirs);
	const homeDir = useRoomsState((state) => state.homeDir);
	const pageStanding = useRoomsState((state) => state.standing);
	const members = useConversationMembers(about?.conv ?? null);
	const view = useMemo<MemberView | null>(() => {
		if (about === null) return null;
		const conv = about.conv === null ? null : convs.get(about.conv) ?? null;
		const dir = conv === null ? null : dirs.get(conv.dir) ?? null;
		// The reader's own card comes from the foot, which is not on a room, so
		// its directory is the one that named them: the page's own where it has,
		// and the first that granted a name otherwise. The same answer the foot
		// itself draws, so the card and the lockup that opened it agree.
		const grants = [...dirs.values()]
			.filter((held) => held.nick !== "")
			.map((held) => ({ id: held.id, nick: held.nick, where: directoryName(held.id, homeDir) }));
		const home = [...dirs.values()].find((held) => held.id === homeDir && held.nick !== "") ??
			[...dirs.values()].find((held) => held.nick !== "") ?? null;
		const on = dir ?? home;
		const standing = members.get(about.name) ?? { online: false, away: "" };
		const identity = memberIdentity(about.name, standing, conv?.type === "room" ? conv.bridge : undefined);
		const you = about.conv === null || (dir !== null && dir.nick !== "" && about.name === dir.nick);
		return {
			key: about.name,
			name: identity.name,
			mark: identity.mark,
			said: identity.said,
			network: identity.network,
			bridgeBadge: conv?.type === "room" ? conv.bridge?.badge ?? null : null,
			standing,
			you,
			room: conv === null || conv.type !== "room" ? null : conv.id,
			dir: on,
			dirName: on === null ? "" : directoryName(on.id, homeDir),
			grants,
			reachable: on !== null && on.dmablePeers.has(about.name.toLowerCase()),
			pageStanding,
		};
	}, [about, convs, dirs, homeDir, members, pageStanding]);
	const last = useRef<MemberView | null>(view);
	if (view !== null) last.current = view;
	const shown = last.current;
	const { held, onExited } = useHeldModal(about !== null);
	useLayoutEffect(() => {
		onLayer(held);
		return () => onLayer(false);
	}, [held, onLayer]);
	if (!held || shown === null) return null;
	return <MemberDialog open={about !== null} onExited={onExited} view={shown} canInteract={canInteract} />;
});

/** One reading of how this person is: the shape the pip on their chip wears, and
 * the sentence the row under it says. Both come out of one branch, because a pip
 * drawing "here" over a line reading "away" is the card disagreeing with itself
 * about the only fact a reader glanced at it for.
 *
 * The reader's own standing is the page's rather than any roster's. The foot can
 * open this card with no room in sight, and stepping away is something a reader
 * does everywhere at once rather than in one room. */
function presenceOf(view: MemberView): { state: PresenceState; said: string } {
	if (view.you) {
		return view.pageStanding === ""
			? { state: "online", said: memberHereNow }
			: { state: "away", said: memberAway(view.pageStanding) };
	}
	if (!view.standing.online) return { state: "offline", said: memberOffline };
	return view.standing.away === ""
		? { state: "online", said: memberHereNow }
		: { state: "away", said: memberAway(view.standing.away) };
}

function MemberDialog(
	{ open, onExited, view, canInteract }: {
		open: boolean;
		onExited: () => void;
		view: MemberView;
		canInteract: boolean;
	},
) {
	const browser = useRoomsBrowser();
	const session = useRoomsSession();
	const close = useRef<HTMLButtonElement>(null);
	const dialog = useRef<HTMLDialogElement>(null);
	useModalDialog(dialog, () => browser.aboutMember(null), close, open, onExited);
	const presence = presenceOf(view);
	return (
		<dialog ref={dialog} className="modal" aria-labelledby="membercardTitle">
			<div className="modal-card card-plane membercard">
				<div className="modal-body">
					<ModalHead
						titleId="membercardTitle"
						title={
							<>
								<PresenceAvatar name={view.name} state={presence.state} />
								<span className="membercard-name">{view.name}</span>
								{view.you && <span className="membercard-you">(you)</span>}
								{view.mark !== null && (
									<span className="bridge-chip" data-network={view.network}>{view.mark}</span>
								)}
							</>
						}
						closeId="membercardClose"
						closeRef={close}
						onClose={() => browser.aboutMember(null)}
					/>

					{
						/* One well for what is known, the way the directory card holds its
									    locator and facts together: this is all one answer to "who is
									    this", and splitting it would make the reader decide which half
									    they came for. */
					}
					<div className="group well">
						<dl className="dirfacts">
							<dt>{factThisIs}</dt>
							<dd id="membercardIs">
								{view.you ? memberYou : view.room === null ? memberAMember : memberOf(view.room)}
							</dd>
							{
								/* Who granted this name, which is one fact and gets one row.
											    A name and the directory behind it are not two answers: the
											    name exists because that directory granted it, for the
											    length of a connection, and takes it back when the
											    connection ends. Saying it as a name row and a "where" row
											    had the card answer "this directory" twice on the ordinary
											    page that holds one.

											    The directory is a door rather than a label: pressing it
											    opens that directory's conversation. The reader holds one
											    name per directory and somebody else is only ever read
											    through one, so the reader's arm is a list and theirs is a
											    single door. */
							}
							{view.you
								? (
									<>
										<dt>{memberYourNames}</dt>
										<dd id="membercardName">
											{view.grants.length === 0
												? memberNoNameYet
												: (
													<ul className="membercard-grants">
														{view.grants.map((grant, at) => (
															<li key={grant.id}>
																{grant.nick} on{" "}
																<Button
																	id={at === 0 ? "membercardDirectory" : undefined}
																	className="membercard-door"
																	variant="link"
																	onClick={() => browser.showDirectory(grant.id)}
																>
																	{grant.where}
																</Button>
															</li>
														))}
													</ul>
												)}
										</dd>
									</>
								)
								: (
									<>
										<dt>{memberGrantedBy}</dt>
										<dd id="membercardName">
											{view.dir === null ? memberNoDirectoryNamed : (
												<Button
													id="membercardDirectory"
													className="membercard-door"
													variant="link"
													onClick={() => browser.showDirectory(view.dir!.id)}
												>
													{view.dirName}
												</Button>
											)}
										</dd>
									</>
								)}
							<dt>{memberPresence}</dt>
							<dd id="membercardHere">{presence.said}</dd>
							{view.said !== "" && (
								<>
									<dt>{memberNetwork}</dt>
									<dd id="membercardNetwork">{view.said}</dd>
								</>
							)}
							<dt>{memberDirectMessages}</dt>
							{
								/* Two different questions wear this one label, and which one is
								    asked depends on whose card it is. Whether others can reach
								    the reader is the directory card's question, so it is asked
								    there and only read here: that answer knows about a name
								    never granted and a directory that is not connected, and a
								    second copy of it here would eventually tell somebody they
								    are reachable while nothing could arrive. Whether the reader
								    can reach this person is its own question and is answered
								    here. */
							}
							<dd id="membercardReach">
								{view.you
									? view.dir === null ? memberNoDirectoryNamedYou : dmSaid(view.dir)
									: view.reachable
									? memberCanMessage(view.name)
									: memberNotReachable}
							</dd>
						</dl>
					</div>

					{
						/* What the reader can do about this person, in a well of its own so
									    an act never sits among the facts it acts on. The reader's own
									    card offers the identity they hold. Anybody else's offers the
									    line the roster's own button offers, said in words here because
									    a card has room for the sentence a glyph cannot carry. */
					}
					{canInteract && (view.you
						? view.standing.seat !== undefined && (
							<div className="actions">
								<Button
									id="membercardBridge"
									variant="quiet"
									onClick={() => {
										browser.aboutMember(null);
										browser.manageBridgeIdentity();
									}}
								>
									{memberManageBridgeIdentity(view.bridgeBadge ?? "bridge")}
								</Button>
							</div>
						)
						: view.reachable && (
							<div className="actions">
								<Button
									id="membercardMessage"
									onClick={() => {
										browser.aboutMember(null);
										session.startDm(view.key);
									}}
								>
									{memberMessageDirectly(view.name)}
								</Button>
							</div>
						))}
				</div>
			</div>
		</dialog>
	);
}
