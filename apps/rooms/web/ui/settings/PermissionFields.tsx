import {
	managedAccessText as text,
	permissionDependency,
	permissionMatch,
	unavailablePermissions,
} from "../../../lib/text/managed_access.ts";
// Preset mode is local editing state. Saved authority is explicit values.
import { type CSSProperties, useId, useState } from "react";
import { ROOMS_PERMISSIONS, type RoomsPermission, SESSION_CONTENT } from "../../../lib/session_content_data.ts";
import { Checkbox } from "../Checkbox.tsx";
import { Said } from "../Said.tsx";
import { Choice, Choices } from "../Choices.tsx";

type SessionPermission = typeof SESSION_CONTENT.declaration.permissions[number];
// Every permission a session declares has a reader name. The type says so.
const names: Record<SessionPermission, string> = {
	observeWorkspace: text.observeWorkspace,
	interactWorkspace: text.interactWorkspace,
	replaceWorkspace: text.replaceWorkspace,
	manageCustody: text.manageCustody,
	shareCustody: text.shareCustody,
	resolvePending: text.resolvePending,
	useOperations: text.useOperations,
	history: text.history,
	readArchive: text.readArchive,
	readFile: text.readFile,
};
const readerNames: Partial<Record<RoomsPermission, string>> = names;
const nameOf = (permission: RoomsPermission): string => readerNames[permission] ?? permission;
type Group = keyof typeof SESSION_CONTENT.groups;
const isGroup = (key: string): key is Group => Object.hasOwn(SESSION_CONTENT.groups, key);
const groups: readonly Group[] = Object.keys(SESSION_CONTENT.groups).filter(isGroup);
/** A group's permissions, widened so any permission can be looked up in it. */
const fieldsOf = (group: Group): readonly RoomsPermission[] => SESSION_CONTENT.groups[group];
interface PresetChoice {
	readonly name: string;
	readonly group: Group;
	readonly label: string;
	readonly description: string;
	readonly values: readonly RoomsPermission[];
}
const presets: readonly PresetChoice[] = Object.entries(SESSION_CONTENT.presets).map(([name, preset]) => ({
	name,
	group: preset.group,
	label: preset.label,
	description: preset.description,
	values: preset.values,
}));
/** The group's question lays out one row per answer, plus the custom one. */
type QuestionStyle = CSSProperties & Record<"--answers" | "--rows", number>;

/** A set of permissions in the words the picker uses: each group by the
 * preset it matches, or by its members when it matches none, then the reading
 * permissions one by one. A group holding nothing says nothing. */
export function permissionSummary(values: readonly RoomsPermission[]): string[] {
	const said: string[] = [];
	for (const group of groups) {
		const held = fieldsOf(group).filter((field) => values.includes(field));
		if (held.length === 0) continue;
		const preset = presets.find((candidate) =>
			candidate.group === group && candidate.values.length === held.length &&
			held.every((field) => candidate.values.includes(field))
		);
		if (preset != null) said.push(preset.label);
		else said.push(...held.map(nameOf));
	}
	const grouped = groups.flatMap(fieldsOf);
	for (const permission of SESSION_CONTENT.declaration.permissions) {
		if (!grouped.includes(permission) && values.includes(permission)) said.push(nameOf(permission));
	}
	return said;
}

export function permissionRefusal(values: readonly RoomsPermission[]): string {
	for (const value of values) {
		const prerequisite = ROOMS_PERMISSIONS[value].prerequisite;
		if (prerequisite != null && !values.includes(prerequisite)) {
			return permissionDependency(nameOf(value), nameOf(prerequisite));
		}
	}
	return "";
}

export function PermissionFields({ value, ceiling, disabled = false, onChange }: {
	value: readonly RoomsPermission[];
	ceiling: readonly RoomsPermission[];
	disabled?: boolean;
	onChange(value: RoomsPermission[]): void;
}) {
	const id = useId();
	const [custom, setCustom] = useState<Partial<Record<Group, boolean>>>({});
	const toggle = (permission: RoomsPermission) =>
		onChange(value.includes(permission) ? value.filter((item) => item !== permission) : [...value, permission]);
	const independent = SESSION_CONTENT.declaration.permissions.filter((permission) =>
		!groups.some((group) => fieldsOf(group).includes(permission))
	);
	const refusal = permissionRefusal(value);
	const checkRow = (permission: RoomsPermission) => (
		<label className="check-row" key={permission}>
			<Checkbox
				checked={value.includes(permission)}
				disabled={disabled || (!ceiling.includes(permission) && !value.includes(permission))}
				onChange={() => toggle(permission)}
			/>
			<span>{nameOf(permission)}</span>
		</label>
	);
	return (
		<>
			<div className="permission-groups">
				{groups.map((group) => {
					const fields = fieldsOf(group);
					const candidates = presets.filter((preset) => preset.group === group);
					const match = candidates.find((preset) =>
						fields.every((field) => value.includes(field) === preset.values.includes(field))
					);
					const style: QuestionStyle = {
						"--answers": candidates.length + 1,
						"--rows": candidates.length + 2,
					};
					const customizing = custom[group] === true || match == null;
					const labelId = `${id}-${group}`;
					return (
						<div
							className="question permission-group"
							key={group}
							style={style}
						>
							<p className="group-label" id={labelId}>
								{SESSION_CONTENT.groupLabels[group]}
							</p>
							<Choices labelledBy={labelId}>
								{candidates.map((preset) => {
									const { name, values } = preset;
									const unavailable = values.filter((permission) => !ceiling.includes(permission));
									return (
										<div className="choice-row" key={name}>
											<Choice
												name={labelId}
												checked={!customizing && match?.name === name}
												disabled={disabled || unavailable.length > 0}
												onChange={() => {
													setCustom((prior) => ({ ...prior, [group]: false }));
													onChange([
														...value.filter((permission) => !fields.includes(permission)),
														...values,
													]);
												}}
											>
												<strong>{preset.label}</strong>
												{preset.description}
												{unavailable.length > 0 && (
													<em className="choice-aside" data-tone="warn">
														{unavailablePermissions(
															unavailable.map((permission) =>
																nameOf(permission)
															),
														)}
													</em>
												)}
											</Choice>
										</div>
									);
								})}
								<div className="choice-row">
									<Choice
										name={labelId}
										checked={customizing}
										disabled={disabled}
										onChange={() => setCustom((prior) => ({ ...prior, [group]: true }))}
									>
										<strong>{text.custom}</strong>
										{text.customSaid}
										{custom[group] && match && (
											<em className="choice-aside">{permissionMatch(match.label)}</em>
										)}
									</Choice>
									{customizing && <div className="permission-picks">{fields.map(checkRow)}</div>}
								</div>
							</Choices>
						</div>
					);
				})}
			</div>
			<div className="question">
				<p className="group-label">{text.reading}</p>
				<div className="permission-picks">{independent.map(checkRow)}</div>
			</div>
			{refusal && <Said kind="warning">{refusal}</Said>}
		</>
	);
}
