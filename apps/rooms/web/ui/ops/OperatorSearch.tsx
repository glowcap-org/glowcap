// Finding one row in a directory that holds a hundred thousand.
//
// The search belongs to the pane rather than to a section, because an operator
// arrives with a name, not with a category: type a nickname and every
// inventory narrows to that person's rows at once, and each count says how
// many of them there are. The directory does the matching, so the answer is
// about everything it holds rather than about the page this tab happens to
// have read.
//
// Typing does not ask on every keystroke. The pane waits until the operator
// stops, because each ask is a scan of every inventory, and answers that
// arrive out of order are dropped by comparing what was asked with what is in
// force.

import { useEffect, useRef, useState } from "react";
import { Button } from "../Button.tsx";
import { Icon } from "../icons.tsx";
import { Said } from "../Said.tsx";
import { useRoomsSession } from "../controller/session.ts";

/** How long the pane waits after the last keystroke. Long enough that a
 * typed word is one scan rather than five, short enough to feel like the page
 * is answering as you type. */
const settleMs = 220;

export function OperatorSearch({ search }: { search: string }) {
	const session = useRoomsSession();
	const [typed, setTyped] = useState(search);
	const [busy, setBusy] = useState(false);
	const [why, setWhy] = useState("");
	const asked = useRef(search);
	// The search in force is the store's, so a refresh from elsewhere — another
	// tab retiring rows, this pane's own sweep — cannot leave the box saying
	// something the rows do not answer.
	useEffect(() => {
		if (search !== asked.current) {
			asked.current = search;
			setTyped(search);
		}
	}, [search]);
	useEffect(() => {
		if (typed === asked.current) return;
		const timer = setTimeout(() => {
			const wanted = typed;
			asked.current = wanted;
			setBusy(true);
			setWhy("");
			void session.searchOperator(wanted).then((refused) => {
				setBusy(false);
				if (refused !== "") setWhy(refused);
			});
		}, settleMs);
		return () => clearTimeout(timer);
	}, [typed, session]);

	return (
		<div className="ops-search">
			<div className="ops-search-field">
				<span className="ops-search-mark" aria-hidden="true">
					<Icon name="search" size={16} />
				</span>
				<input
					id="operatorSearch"
					className="field"
					type="search"
					value={typed}
					autoComplete="off"
					spellCheck={false}
					aria-label="Search everything this directory holds"
					placeholder="Search rooms, names, connections, references…"
					onChange={(event) => setTyped(event.currentTarget.value)}
				/>
				{typed !== "" && (
					<Button
						id="operatorSearchClear"
						className="ops-search-clear"
						type="button"
						variant="link"
						onClick={() => setTyped("")}
					>
						Clear
					</Button>
				)}
			</div>
			<p className="hint" id="operatorSearchSaid" role="status">
				{busy
					? "Searching this directory…"
					: search === ""
					? "Every inventory below counts what this directory holds."
					: `Every inventory below counts what matches “${search}”.`}
			</p>
			{why !== "" && <Said kind="failure">{why}</Said>}
		</div>
	);
}
