// Retiring everything an inventory matches, in batches the operator watches.
//
// The per-row act is the surgical one and stays where the row is. This is the
// other end of the same authority: when a search has narrowed an inventory to
// exactly the rows that should go, pressing once should not mean pressing
// three thousand times.
//
// It is deliberately not one call. The directory retires a bounded batch and
// answers how many still match, so the turn stays short, the number the reader
// watches is the directory's own, and Stop is real rather than a cancel button
// over an act that already left. A sweep that meets a refusal on one row keeps
// going and reports the first reason at the end, because one row that changed
// under the sweep is not a reason to leave the rest.

import { useEffect, useRef, useState } from "react";
import type { OperatorCategory } from "../types.ts";
import { Button } from "../Button.tsx";
import { Confirm } from "../Confirm.tsx";
import { Said } from "../Said.tsx";
import { useRoomsSession } from "../controller/session.ts";

/** How many rows one call retires. The directory bounds this too; asking for
 * its whole allowance keeps the number of round trips down while leaving each
 * turn short. */
const batch = 256;

export function OperatorSweep(
	{ category, act, past, subject, effect, search, total }: {
		category: OperatorCategory;
		/** The act, in the words of this inventory: "Release", "Disconnect". */
		act: string;
		/** The same act, done: "Released", "Disconnected". Written out rather
		 * than suffixed, because "Disconnectd" is what suffixing gives. */
		past: string;
		/** What the rows are, plural: "references", "peer sessions". */
		subject: string;
		/** What retiring one of these costs, said once in the question. */
		effect: string;
		search: string;
		/** How many rows match the search now. */
		total: number;
	},
) {
	const session = useRoomsSession();
	const [asking, setAsking] = useState(false);
	const [running, setRunning] = useState(false);
	const [done, setDone] = useState(0);
	const [left, setLeft] = useState(0);
	const [why, setWhy] = useState("");
	const [said, setSaid] = useState("");
	const stopped = useRef(false);
	// A new search is a new question, so the last one's answer goes with it.
	useEffect(() => {
		setSaid("");
		setWhy("");
	}, [search]);

	// What a sweep said outlives the rows it took: finishing one empties the
	// inventory it swept, and a control that disappears at the moment it
	// succeeds is an act with no answer.
	if (search === "" || (total === 0 && said === "" && why === "" && !running)) return null;

	const sweep = async () => {
		stopped.current = false;
		setRunning(true);
		setAsking(false);
		setWhy("");
		setSaid("");
		setDone(0);
		setLeft(total);
		let retired = 0;
		let firstRefusal = "";
		while (!stopped.current) {
			const answer = await session.retireMatchingOperator(category, search, batch);
			if (typeof answer === "string") {
				setWhy(answer);
				break;
			}
			retired += answer.retired;
			setDone(retired);
			setLeft(answer.remaining);
			if (answer.refused !== "" && firstRefusal === "") {
				firstRefusal = answer.refused;
				setWhy(answer.refused);
			}
			// Nothing went and nothing is left to try: stop rather than spin.
			if (answer.remaining === 0 || answer.retired === 0) break;
		}
		// The pane read nothing while this ran; this is the one read that puts
		// the inventories and their counts back in step with the directory.
		await session.searchOperator(search);
		setRunning(false);
		setSaid(
			stopped.current ? `Stopped after ${retired} of ${total} ${subject}.` : `${past} ${retired} ${subject}.`,
		);
	};

	return (
		<>
			{asking
				? (
					<Confirm
						id={`operatorSweep-${category}`}
						label={`${act} every matching row`}
						say={`${total} ${subject} match “${search}”. ${effect} Rows that come to match while this runs go too.`}
						keep="Keep them"
						commit={`${act} ${total}`}
						commitId={`operatorSweepGo-${category}`}
						onKeep={() => setAsking(false)}
						onCommit={() => void sweep()}
					/>
				)
				: total === 0 && !running
				? null
				: (
					<div className="actions">
						{running
							? (
								<>
									<span className="ops-sweep-progress" role="status">
										{past} {done}; {left} left
									</span>
									<Button
										type="button"
										variant="danger"
										onClick={() => {
											stopped.current = true;
										}}
									>
										Stop
									</Button>
								</>
							)
							: (
								<Button
									id={`operatorSweepAsk-${category}`}
									type="button"
									variant="quiet"
									onClick={() => setAsking(true)}
								>
									{act} all {total} matching…
								</Button>
							)}
					</div>
				)}
			{said !== "" && !running && <Said kind="success">{said}</Said>}
			{why !== "" && <Said kind="failure">{why}</Said>}
		</>
	);
}
