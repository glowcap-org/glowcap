// The control that puts the rail's questions to a reader.
//
// It hangs off the rooms heading, because a rail with a bar of its own over
// both lists had two headings and a third line above them saying nothing most
// of the time. What it asks is still about the whole rail: the questions land
// on rooms and on direct lines alike, and the panel says so.
//
// Closed it says how much of the rail is on screen. Open it is a panel with
// room for every question, one under the next, each with the same amount of
// space as the one above it.
//
// It draws whatever `railCriteria` holds and knows nothing about any single
// question. A question with a set of answers is a well of rows, a question with
// a typed answer is a field, and adding either kind changes nothing here.

import { useEffect, useRef } from "react";
import { Checkbox } from "../Checkbox.tsx";
import { Icon } from "../icons.tsx";
import { useMenu } from "../Menu.tsx";
import { identifierField } from "../field.ts";
import {
	anyAsked,
	askedNothing,
	type Criterion,
	type FilterAnswers,
	offKey,
	setTyped,
	toggleChoice,
} from "./filter.ts";

/** How much of the rail is on screen, as the two numbers alone. The heading has
 * room for these and not for a sentence. */
function countSaid(shown: number, total: number): string {
	return shown + " of " + total;
}

/** The same fact written out, for what the heading announces to a reader who
 * is given the name rather than the badge. One producer for the numbers, so
 * what is seen and what is said cannot come to differ. */
function countSentence(shown: number, total: number): string {
	return countSaid(shown, total) + " shown";
}

/** A question whose answers are whatever the reader types. */
function TypedAsk(
	{ criterion, answers, onAnswers }: {
		criterion: Extract<Criterion, { kind: "text" }>;
		answers: FilterAnswers;
		onAnswers: (answers: FilterAnswers) => void;
	},
) {
	const id = "railFilter-" + criterion.id;
	return (
		<div className="filter-ask">
			<label className="filter-label" htmlFor={id}>{criterion.label}</label>
			<input
				id={id}
				className="filter-field"
				type="text"
				enterKeyHint="done"
				placeholder={criterion.placeholder}
				value={answers.typed.get(criterion.id) ?? ""}
				onChange={(e) => onAnswers(setTyped(answers, criterion.id, e.target.value))}
				{...identifierField}
			/>
		</div>
	);
}

/** A question with a known set of answers, each of which can be turned off.
 *
 * A list of rows in a well, one answer to a row, which is what this question
 * is: every answer is included or excluded on its own and none of them is a
 * choice between the others. The page's own `Checkbox` answers each row, and
 * the whole row is its label, so pressing anywhere on the line is pressing the
 * answer.
 *
 * What is left here is the question: its name, what its answers are called, and
 * what turning one off means. */
function ChoiceAsk(
	{ criterion, answers, onAnswers }: {
		criterion: Extract<Criterion, { kind: "choices" }>;
		answers: FilterAnswers;
		onAnswers: (answers: FilterAnswers) => void;
	},
) {
	const labelId = "railFilterLabel-" + criterion.id;
	return (
		<div className="filter-ask">
			<span className="filter-label" id={labelId}>{criterion.label}</span>
			{criterion.choices.length === 0
				? <span className="filter-none">Nothing to choose from yet</span>
				: (
					<div className="filter-choices" role="group" aria-labelledby={labelId}>
						{criterion.choices.map((choice) => {
							const key = offKey(criterion.id, choice.value);
							return (
								<label key={key} className="check-row filter-choice">
									<Checkbox
										checked={!answers.off.has(key)}
										onChange={() => onAnswers(toggleChoice(answers, key))}
									/>
									<span className="filter-choice-said">{choice.said}</span>
								</label>
							);
						})}
					</div>
				)}
		</div>
	);
}

/** The rooms heading, which is also what opens the rail's questions. */
export function RailFilter(
	{ title, criteria, answers, shown, total, onAnswers }: {
		/** What the list under this heading is called. The heading is the press
		 * target, so the words are the control's own label as well. */
		title: string;
		criteria: readonly Criterion[];
		answers: FilterAnswers;
		/** How many rows the rail is drawing, and how many it holds. Counted by
		 * the rail rather than here, because the rail is what walks the rows. */
		shown: number;
		total: number;
		onAnswers: (answers: FilterAnswers) => void;
	},
) {
	const { open, setOpen, holder, trigger } = useMenu();
	const panel = useRef<HTMLDivElement>(null);
	const asked = anyAsked(criteria, answers);
	// The panel exists to be answered, so the first thing in it takes the caret
	// as it opens. Asked of the panel rather than named question by question,
	// since which question is first is `railCriteria`'s to say.
	useEffect(() => {
		if (!open) return;
		panel.current?.querySelector<HTMLElement>("input, button")?.focus();
	}, [open]);
	return (
		<div className="rail-filter" ref={holder}>
			<button
				id="railFilter"
				type="button"
				className="rail-filter-head"
				ref={trigger}
				// Expanded plus controls is the whole of the disclosure pattern
				// this is. Saying `haspopup="dialog"` as well promised a dialog and
				// handed over a group.
				aria-expanded={open}
				aria-controls="railFilterPanel"
				// Both halves are said out loud, because a reader using the
				// accessible name is given no punctuation to tell them apart.
				aria-label={asked
					? title + ". Change what the rail shows. " + countSentence(shown, total)
					: title + ". Choose what the rail shows. Nothing is hidden"}
				onClick={() => setOpen((was) => !was)}
			>
				<Icon name="filter" size={12} />
				<span className="rail-filter-title">{title}</span>
				{asked && <span className="rail-filter-count">{countSaid(shown, total)}</span>}
			</button>
			{open && (
				<div
					id="railFilterPanel"
					className="filter-panel"
					ref={panel}
					role="group"
					aria-label="What the rail shows"
				>
					{criteria.map((criterion) => (
						criterion.kind === "text"
							? (
								<TypedAsk
									key={criterion.id}
									criterion={criterion}
									answers={answers}
									onAnswers={onAnswers}
								/>
							)
							: (
								<ChoiceAsk
									key={criterion.id}
									criterion={criterion}
									answers={answers}
									onAnswers={onAnswers}
								/>
							)
					))}
					{
						/* The way back out, drawn as one more answer in a well of
						   its own, because that is what it is: every question
						   above narrows the rail, and this is the row that says
						   none of them do. It carries no count. The heading that
						   opened this panel already says how much of the rail is
						   on screen, and a second copy under the questions is the
						   same fact twice.

						   It is ticked when nothing is hidden and inert while it
						   is ticked. Turning it off would have to mean showing
						   less than everything, and there is no such thing to
						   mean. A reader hides rows by answering the questions
						   above, and this is only how they come back. */
					}
					<div className="filter-choices">
						<label className="check-row filter-choice">
							<Checkbox
								id="railFilterClear"
								checked={!asked}
								disabled={!asked}
								onChange={() => onAnswers(askedNothing)}
							/>
							<span className="filter-choice-said">Show everything</span>
						</label>
					</div>
				</div>
			)}
		</div>
	);
}
