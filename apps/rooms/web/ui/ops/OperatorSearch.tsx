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

import { useCallback, useEffect, useRef, useState } from "react";
import {
	operatorCountsAll,
	operatorCountsMatching,
	operatorFilteredTo,
	operatorSearching,
	opsSearchLabel,
	opsSearchPlaceholder,
} from "../../../lib/text/ops.ts";
import { Button } from "../Button.tsx";
import { Icon } from "../icons.tsx";
import { Said } from "../Said.tsx";
import { useRoomsSession } from "../controller/session.ts";
import type { OperatorReferenceKind } from "../../../lib/operator.ts";
import { useOperatorActivity } from "./operator_activity.tsx";
import { refusalText } from "../../../lib/text/failure.ts";

/** How long the pane waits after the last keystroke. Long enough that a
 * typed word is one scan rather than five, short enough to feel like the page
 * is answering as you type. */
const settleMs = 220;

export function OperatorSearch(
	{ search, referenceKind }: { search: string; referenceKind: OperatorReferenceKind | null },
) {
	const session = useRoomsSession();
	const activity = useOperatorActivity();
	const [typed, setTyped] = useState(search);
	const [busy, setBusy] = useState(false);
	const [why, setWhy] = useState("");
	const asked = useRef({ search, referenceKind });
	const generation = useRef(0);
	const submit = useCallback((wanted: string, kind: OperatorReferenceKind | null) => {
		const request = ++generation.current;
		asked.current = { search: wanted, referenceKind: kind };
		setBusy(true);
		setWhy("");
		void session.searchOperator(wanted, kind).then(
			(refused) => {
				if (generation.current !== request) return;
				setBusy(false);
				if (refused !== "") setWhy(refused);
			},
			(error) => {
				if (generation.current !== request) return;
				setBusy(false);
				setWhy(refusalText(error));
			},
		);
	}, [session]);
	// The search in force is the store's, so a refresh from elsewhere (another
	// tab retiring rows, this pane's own sweep) cannot leave the box saying
	// something the rows do not answer.
	useEffect(() => {
		if (search !== asked.current.search || referenceKind !== asked.current.referenceKind) {
			generation.current += 1;
			setBusy(false);
			setWhy("");
			asked.current = { search, referenceKind };
			setTyped(search);
		}
	}, [search, referenceKind]);
	useEffect(() => {
		if (typed === asked.current.search) return;
		const timer = setTimeout(() => {
			submit(typed, referenceKind);
		}, settleMs);
		return () => clearTimeout(timer);
	}, [typed, referenceKind, submit]);

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
					disabled={activity.sweeping}
					aria-label={opsSearchLabel}
					placeholder={opsSearchPlaceholder}
					onChange={(event) => setTyped(event.currentTarget.value)}
				/>
				{(typed !== "" || referenceKind !== null) && (
					<Button
						id="operatorSearchClear"
						className="ops-search-clear"
						type="button"
						variant="link"
						disabled={activity.sweeping}
						onClick={() => {
							setTyped("");
							if (referenceKind !== null) submit("", null);
						}}
					>
						Clear
					</Button>
				)}
			</div>
			<p className="hint" id="operatorSearchSaid" role="status">
				{busy
					? operatorSearching
					: referenceKind !== null
					? operatorFilteredTo(referenceKind)
					: search === ""
					? operatorCountsAll
					: operatorCountsMatching(search)}
			</p>
			{why !== "" && <Said kind="failure">{why}</Said>}
		</div>
	);
}
