// Retiring everything an inventory matches, in batches the operator watches.
//
// The per-row act is the surgical one and stays where the row is. This is the
// other end of the same authority: when a search has narrowed an inventory to
// exactly the rows that should go, pressing once should not mean pressing
// three thousand times.
//
// It is not one call. The directory retires a bounded batch and
// answers how many still match, so the turn stays short, the number the reader
// watches is the directory's own, and Stop is real rather than a cancel button
// over an act that already left. A sweep that meets a refusal on one row keeps
// going and reports the first reason at the end, because one row that changed
// under the sweep is not a reason to leave the rest.

import { useEffect, useRef, useState } from "react";
import { opsSweepKeep, sweepDone, sweepRefused, sweepStopped } from "../../../lib/text/ops.ts";
import type { OperatorCategory } from "../types.ts";
import { Button } from "../Button.tsx";
import { Confirm } from "../Confirm.tsx";
import { Said } from "../Said.tsx";
import { useRoomsSession } from "../controller/session.ts";
import type { OperatorReferenceKind } from "../../../lib/operator.ts";
import { useOperatorActivity } from "./operator_activity.tsx";
import { refusalText } from "../../../lib/text/failure.ts";

/** How many rows one call retires. The directory bounds this too. Asking for
 * its whole allowance keeps the number of round trips down while leaving each
 * turn short. */
const batch = 256;

export function OperatorSweep(
	{ category, act, past, subject, effect, search, total, referenceKind = null }: {
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
		referenceKind?: OperatorReferenceKind | null;
	},
) {
	const session = useRoomsSession();
	const activity = useOperatorActivity();
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
	}, [search, referenceKind]);

	// What a sweep said outlives the rows it took: finishing one empties the
	// inventory it swept, and a control that disappears at the moment it
	// succeeds is an act with no answer.
	if ((search === "" && referenceKind === null) || (total === 0 && said === "" && why === "" && !running)) {
		return null;
	}

	const sweep = async () => {
		if (!activity.beginSweep()) return;
		stopped.current = false;
		setRunning(true);
		setAsking(false);
		setWhy("");
		setSaid("");
		setDone(0);
		setLeft(total);
		let retired = 0;
		let firstRefusal = "";
		try {
			while (!stopped.current) {
				const answer = await session.retireMatchingOperator(category, search, batch, referenceKind);
				if (typeof answer === "string") {
					firstRefusal ||= answer;
					break;
				}
				retired += answer.retired;
				setDone(retired);
				setLeft(answer.remaining);
				if (answer.refused !== "" && firstRefusal === "") firstRefusal = answer.refused;
				// Nothing went and nothing is left to try: stop rather than spin.
				if (answer.remaining === 0 || answer.retired === 0) break;
			}
			const refreshFailure = await session.searchOperator(search, referenceKind);
			if (refreshFailure !== "" && firstRefusal === "") firstRefusal = refreshFailure;
			setRunning(false);
			if (firstRefusal === "") {
				setSaid(stopped.current ? sweepStopped(retired, total, subject) : sweepDone(past, retired, subject));
			} else {
				setWhy(sweepRefused(firstRefusal, past, retired, subject));
			}
		} catch (error) {
			setWhy(refusalText(error));
		} finally {
			setRunning(false);
			activity.endSweep();
		}
	};

	return (
		<>
			{asking
				? (
					<Confirm
						id={`operatorSweep-${category}`}
						label={`${act} every matching row`}
						say={`${total} ${subject} match ${
							referenceKind === null ? `“${search}”` : `the ${referenceKind} kind`
						}. ${effect} Rows that come to match while this runs go too.`}
						keep={opsSweepKeep}
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
										{past} {done}, {left} left
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
