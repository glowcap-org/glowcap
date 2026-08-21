// The reader's own seat under the rail.
//
// Its sibling files are about what this tab holds — the rooms, the direct
// lines, the directory each of them is on. This one is about the reader: who a
// directory says they are, and where they say they are. That is why it is not
// part of either list, and why it does not switch with the conversation being
// read.

import { usePeer } from "../peer.ts";
import { type DirId, dirMarkIn, type DirView, type SessionPhase } from "../types.ts";
import { directoryName, footState } from "../text.ts";
import { Avatar } from "../Avatar.tsx";
import { StandingMenu } from "../Standing.tsx";

/** The rail's foot: one lockup saying who this reader is and how they stand,
 * and pressing it opens the standing menu — the roster's two-row shape, worn by
 * the reader themselves.
 *
 * The foot is the one part of the page about the reader rather than about a
 * conversation, which is why standing lives here and not in a room's header:
 * stepping out is something you do, not something you do to a room. For the
 * same reason the top row never switches with the conversation being read: a
 * name is one directory's grant, so the row says the home directory's grant
 * and counts the others, with the whole list on its title, rather than letting
 * the rail claim one name covers every room.
 *
 * Which is exactly what a lone name at the foot of a page does look like it is
 * claiming, so when this tab holds more than one named directory the name
 * wears that directory's own mark — the same `data-dir` colour its rooms wear
 * in the rail above — and the chip beside it counts the other names in words.
 * A reader can then see that this name belongs to one of the directories on
 * screen rather than to the page. */
export function Foot(
	{ dirs, home, session, standing }: {
		dirs: ReadonlyMap<DirId, DirView>;
		home: DirId | null;
		session: SessionPhase;
		standing: string;
	},
) {
	const peer = usePeer();
	// Every directory that has granted a name, in the order this tab opened
	// them; the page's own directory answers first while it has granted one.
	const grants = [...dirs.values()].filter((held) => held.nick !== "");
	const primary = (grants.find((held) => held.id === home) ?? grants[0])?.nick ?? "";
	// Distinct names, not directories: two directories both granting "alice"
	// agree, and a count that said otherwise would raise a question the title
	// could not answer.
	const others = new Set(grants.map((held) => held.nick)).size - (primary === "" ? 0 : 1);
	const whoSaid = grants.map((held) => `${held.nick} on ${directoryName(held.id, home)}`).join(", ");
	const foot = footState(session, standing, primary !== "");
	// Whose grant this name is, drawn only when the reader can see the same
	// mark elsewhere: one directory needs no colour to be told apart from, and
	// past the ramp nothing is marked at all (`dirsWearMarks`). The title beside
	// it says every name and its directory in words whatever the colors do.
	const named = grants.find((held) => held.id === home) ?? grants[0];
	const mark = named === undefined ? undefined : dirMarkIn(named.id, home, dirs);
	// The state row is the one live region the foot carries, in both arms, so a
	// phase change or a standing change is announced without a second voice.
	const stateRow = (className?: string) => (
		<span id="status" role="status" aria-live="polite" className={className} title={foot.said}>
			{foot.said}
		</span>
	);
	return (
		<div className="sidebar-foot">
			<StandingMenu
				id="standingBtn"
				own={standing}
				effective={standing}
				about="you"
				up
				faceClass="foot-lockup"
				label={primary === "" ? undefined : `${whoSaid} — where you are: ${foot.said}`}
				onSay={(said) => peer.setStanding(said ?? "")}
				face={primary === ""
					? (
						/* Before any directory grants a name there is nobody to draw, so
						   the dot stands alone beside the state text, as it always has. */
						<>
							<span id="dot" className={"dot " + session} />
							{stateRow()}
						</>
					)
					: (
						/* While the session cannot reach anybody the chip dims the way an
						   offline member's does, so the reader's own state is said in the
						   page's one vocabulary; the dot's shape still names which of the
						   four phases this is, on the corner seat it has always held. */
						<>
							<span className={"avatar-presence" + (session === "connected" ? "" : " offline")}>
								<Avatar name={primary} />
								<span id="dot" className={"dot " + session} />
							</span>
							<span className="name-line">
								<span className="foot-names" title={others > 0 ? whoSaid : primary} data-dir={mark}>
									<span className="name">{primary}</span>
									{others > 0 && (
										<span className="foot-more">
											+{others} {others === 1 ? "name" : "names"}
										</span>
									)}
								</span>
								{stateRow(foot.away ? "away-said" : "foot-said")}
							</span>
						</>
					)}
			/>
		</div>
	);
}
