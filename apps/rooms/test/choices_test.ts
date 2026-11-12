// The shared one-of-several question, as its callers render it. `Choices` is
// a named radio group and `Choice` one HTML radio input in it, so these read the
// static markup for what a keyboard and a screen reader meet: which answers
// share a group, which one is chosen, and which are closed.

import "./support/match_media.ts";
import { createElement, type ReactElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { managedAccessText as text } from "../lib/text/managed_access.ts";
import { ROOMS_PERMISSIONS, type RoomsPermission, SESSION_CONTENT } from "../lib/session_content_data.ts";
import { Choice, Choices } from "../web/ui/Choices.tsx";
import { CeilingQuestion, NO_CEILING } from "../web/ui/settings/CeilingQuestion.tsx";
import { PermissionFields, permissionSummary } from "../web/ui/settings/PermissionFields.tsx";
import { assertEquals } from "./assert.ts";

interface Radio {
	readonly label: string;
	readonly checked: boolean;
	readonly disabled: boolean;
}

/** Each radio group in `markup`, by the id that labels it, with its answers
 * in order. An answer is named by the bold first part of its words. */
function radioGroups(markup: string): Map<string, Radio[]> {
	const groups = new Map<string, Radio[]>();
	const starts = [...markup.matchAll(/role="radiogroup" aria-labelledby="([^"]*)"/g)];
	starts.forEach((start, index) => {
		const end = starts[index + 1]?.index ?? markup.length;
		const body = markup.slice(start.index, end);
		const radios = [...body.matchAll(/<input([^>]*)\/?><span><strong>([^<]*)<\/strong>/g)].map((radio) => ({
			label: radio[2],
			checked: / checked=""/.test(radio[1]),
			disabled: / disabled=""/.test(radio[1]),
		}));
		groups.set(start[1], radios);
	});
	return groups;
}

const render = (element: ReactElement) => renderToStaticMarkup(element);
const ignore = () => {};
const everyPermission: readonly RoomsPermission[] = SESSION_CONTENT.declaration.permissions;
/** `values` with every prerequisite they name, so the picker raises no
 * dependency warning (which needs the browser provider to render). */
function withPrerequisites(values: readonly RoomsPermission[]): RoomsPermission[] {
	const held = [...values];
	for (let index = 0; index < held.length; index += 1) {
		const prerequisite = ROOMS_PERMISSIONS[held[index]].prerequisite;
		if (prerequisite != null && !held.includes(prerequisite)) held.push(prerequisite);
	}
	return held;
}
const chosen = (radios: readonly Radio[] | undefined) =>
	radios?.filter((radio) => radio.checked).map((radio) => radio.label);

Deno.test("a choice is an HTML radio input in a group the question's label names", () => {
	const markup = render(
		createElement(Choices, {
			labelledBy: "question",
			children: [
				createElement(Choice, {
					key: "one",
					name: "q",
					checked: true,
					onChange: ignore,
					children: createElement("strong", null, "One"),
				}),
				createElement(Choice, {
					key: "two",
					name: "q",
					checked: false,
					disabled: true,
					onChange: ignore,
					children: createElement("strong", null, "Two"),
				}),
			],
		}),
	);
	assertEquals(markup.match(/role="radiogroup"/g)?.length, 1);
	assertEquals(markup.match(/type="radio"/g)?.length, 2);
	assertEquals(radioGroups(markup).get("question"), [
		{ label: "One", checked: true, disabled: false },
		{ label: "Two", checked: false, disabled: true },
	]);
});

Deno.test("the ceiling question chooses the answer it holds, and closes every limit when none can be passed on", () => {
	const ask = (available: readonly RoomsPermission[] | undefined) =>
		[
			...radioGroups(render(createElement(CeilingQuestion, {
				label: "Manage",
				noneSaid: "nothing",
				answer: { ...NO_CEILING, mode: "within" },
				permissions: everyPermission,
				available,
				disabled: false,
				onChange: ignore,
			}))).values(),
		][0];
	const open = ask(everyPermission);
	assertEquals(open?.map((radio) => radio.label), [
		text.ceilingNone,
		text.ceilingWithin,
		text.ceilingAll,
		text.custom,
	]);
	assertEquals(chosen(open), [text.ceilingWithin]);
	assertEquals(open?.every((radio) => !radio.disabled), true);
	const closed = ask(undefined);
	assertEquals(closed?.map((radio) => radio.disabled), [false, true, true, true]);
});

Deno.test("each permission group chooses the preset its permissions match, and custom when they match none", () => {
	for (const [name, preset] of Object.entries(SESSION_CONTENT.presets)) {
		const values: readonly RoomsPermission[] = preset.values;
		const groups = [
			...radioGroups(render(createElement(PermissionFields, {
				value: withPrerequisites(values),
				ceiling: everyPermission,
				onChange: ignore,
			}))).values(),
		];
		const answered = groups.find((radios) => radios.some((radio) => radio.label === preset.label));
		assertEquals(chosen(answered), [preset.label], `preset ${name}`);
		// A group holding nothing says nothing, so an empty preset has no words in the summary.
		assertEquals(permissionSummary(values).includes(preset.label), values.length > 0, `summary of preset ${name}`);
	}
	// One permission of a group with its prerequisites, where no preset of
	// that group holds exactly what the group then holds.
	const presets = Object.values(SESSION_CONTENT.presets);
	const loose = Object.entries(SESSION_CONTENT.groups).flatMap(([group, fields]) => {
		const members: readonly RoomsPermission[] = fields;
		return members.map((field) => ({ group, field, held: withPrerequisites([field]) })).filter(({ held }) => {
			const inGroup = held.filter((permission) => members.includes(permission));
			return !presets.some((preset) => {
				const values: readonly RoomsPermission[] = preset.values;
				return preset.group === group && values.length === inGroup.length &&
					inGroup.every((permission) => values.includes(permission));
			});
		});
	})[0];
	assertEquals(loose != null, true, "every lone permission completes a preset, so custom has no case here");
	if (loose == null) return;
	const groupPresets: readonly string[] = presets.filter((preset) => preset.group === loose.group).map((preset) =>
		preset.label
	);
	const custom = [
		...radioGroups(render(createElement(PermissionFields, {
			value: loose.held,
			ceiling: everyPermission,
			onChange: ignore,
		}))).values(),
	].find((radios) => radios.some((radio) => groupPresets.includes(radio.label)));
	assertEquals(chosen(custom), [text.custom]);
});

Deno.test("a preset beyond the ceiling is offered but closed, and custom stays open", () => {
	// With no ceiling, a preset that grants anything is beyond it, and a group's
	// empty preset is the one an empty value matches.
	const groups = [
		...radioGroups(render(createElement(PermissionFields, { value: [], ceiling: [], onChange: ignore })))
			.values(),
	];
	const presets = Object.values(SESSION_CONTENT.presets);
	for (const [group] of Object.entries(SESSION_CONTENT.groups)) {
		const own = presets.filter((preset) => preset.group === group);
		const labels: readonly string[] = own.map((preset) => preset.label);
		const radios = groups.find((candidate) => candidate.some((radio) => labels.includes(radio.label)));
		assertEquals(radios?.map((radio) => radio.disabled), [...own.map((preset) => preset.values.length > 0), false]);
		const empty = own.find((preset) => preset.values.length === 0);
		assertEquals(chosen(radios), [empty?.label ?? text.custom], `group ${group}`);
	}
});
