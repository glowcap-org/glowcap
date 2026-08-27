// Saying where you are, at whichever level you are saying it about.
//
// One word — here, or why you stepped out — and three places it can be said:
// everywhere, on one directory, or in one room. They fall through outward, so
// the ordinary reader touches only the first, and the other two are there for
// somebody who wants to be away in one place and not another. Which level
// answers for a room is `store.standingFor`; this is the control, and it is the
// same control at all three because it is the same question.
//
// A level with nothing of its own to say shows what it follows rather than an
// answer of its own, because "here" and "here because you are" are different
// facts and only one of them survives you stepping out.

import { type ReactNode, useState } from "react";
import { MAX_AWAY, PLAIN_AWAY } from "../../lib/limits.ts";
import { MenuList, MenuRow, useMenu } from "./Menu.tsx";

/** What to call a standing on the control itself: the word somebody wrote, or a
 * plain name for each of the two ordinary answers. */
function standingSaid(standing: string): string {
	if (standing === "") return "Here";
	return standing === PLAIN_AWAY ? "Away" : standing;
}

export function StandingMenu(
	{ own, effective, follows, about, onSay, actions = [], disabled = false, up, id, face, faceClass, label }: {
		/** This level's own word, or null while it follows the next one out. */
		own: string | null;
		/** What is in force here, once the levels have been read. */
		effective: string;
		/** What this level follows when it has nothing of its own, named for a
		 * reader ("you", "this directory"). Undefined at the outermost level,
		 * which follows nothing and so cannot be handed back. */
		follows?: string;
		/** Where this standing applies, for the label: "you", "this directory",
		 * "#lobby". */
		about: string;
		onSay: (own: string | null) => void;
		/** Contextual acts that belong to the trigger rather than to standing. The
		 * rail footer uses these for its directory-scoped identity grants. */
		actions?: readonly { label: string; onPick(): void }[];
		/** Draw the standing as a fact without offering mutation. */
		disabled?: boolean;
		/** Whether the menu opens upward, for a control near the foot of the
		 * page. */
		up?: boolean;
		id?: string;
		/** The trigger's own face, in place of the word-chip the control draws by
		 * default. The rail's foot hands in the reader's whole identity lockup, so
		 * pressing who you are is how you change how you stand. */
		face?: ReactNode;
		/** The trigger's class while it wears a handed-in face. */
		faceClass?: string;
		/** What a listener hears the trigger called, when the handed-in face says
		 * more than the standing word alone. */
		label?: string;
	},
) {
	const { open, setOpen, holder, trigger } = useMenu();
	const [reason, setReason] = useState("");
	const away = effective !== "";
	const said = standingSaid(effective);
	const pick = (next: string | null) => {
		setOpen(false);
		onSay(next);
	};
	return (
		<div className="standing" ref={holder}>
			<button
				type="button"
				id={id}
				ref={trigger}
				className={face !== undefined ? faceClass : away ? "standing-said away" : "standing-said"}
				aria-haspopup="menu"
				aria-expanded={open}
				disabled={disabled}
				aria-label={label ?? `Where you are${about === "you" ? "" : " in " + about}: ${said.toLowerCase()}`}
				onClick={() => {
					if (!disabled) setOpen((was) => !was);
				}}
			>
				{face ?? (
					<>
						<span className="standing-pip" aria-hidden="true" />
						<span className="standing-word">{said}</span>
					</>
				)}
			</button>
			{open && !disabled && (
				<MenuList className={up ? "line-menu standing-menu above" : "line-menu standing-menu"}>
					{follows !== undefined && (
						<MenuRow
							className="line-menu-row"
							marked={own === null}
							first
							onPick={() => pick(null)}
						>
							Follow {follows}
						</MenuRow>
					)}
					<MenuRow
						className="line-menu-row"
						marked={own !== null && effective === ""}
						first={follows === undefined}
						onPick={() =>
							pick("")}
					>
						Here
					</MenuRow>
					<MenuRow
						className="line-menu-row"
						marked={own !== null && away}
						onPick={() => pick(PLAIN_AWAY)}
					>
						Away
					</MenuRow>
					{
						/* A reason is still away, so it is written where away is chosen
					    rather than behind a second step. Empty and submitted means
					    here, which is the same answer the row above gives. */
					}
					<form
						className="standing-why"
						action={() => {
							const why = reason;
							setReason("");
							pick(why);
						}}
					>
						<input
							type="text"
							value={reason}
							maxLength={MAX_AWAY}
							placeholder="back in ten"
							enterKeyHint="done"
							autoCapitalize="sentences"
							aria-label={`Why you stepped away${about === "you" ? "" : ", in " + about}`}
							onChange={(event) => setReason(event.target.value)}
						/>
						<button type="submit" className="standing-say">Say it</button>
					</form>
					{actions.length > 0 && (
						<div className="standing-actions" role="none">
							{actions.map((action) => (
								<MenuRow
									key={action.label}
									className="line-menu-row"
									onPick={() => {
										setOpen(false);
										action.onPick();
									}}
								>
									{action.label}
								</MenuRow>
							))}
						</div>
					)}
				</MenuList>
			)}
		</div>
	);
}
