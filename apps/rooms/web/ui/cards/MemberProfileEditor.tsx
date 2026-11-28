import { useEffect, useRef, useState } from "react";
import { MAX_PROFILE_ABOUT } from "../../../lib/limits.ts";
import {
	type MemberProfile,
	MemberProfileSchema,
	type ProfileKind,
	ProfileKindSchema,
} from "../../../lib/room/presence.ts";
import { memberProfileLabels, memberProfileText } from "../../../lib/text/conversation.ts";
import { refusalText } from "../../../lib/text/failure.ts";
import { Field } from "../Field.tsx";
import { Input } from "../Input.tsx";
import { Select } from "../Select.tsx";
import { Said } from "../Said.tsx";
import { Button } from "../Button.tsx";

export function MemberProfileEditor({ room, profile, onSave }: {
	room: string;
	profile: MemberProfile | undefined;
	onSave: (kind: ProfileKind, about: string) => Promise<void>;
}) {
	const editButton = useRef<HTMLButtonElement>(null);
	const kindSelect = useRef<HTMLSelectElement>(null);
	const restoreFocus = useRef(false);
	const [editing, setEditing] = useState(false);
	const [kind, setKind] = useState<ProfileKind>("");
	const [about, setAbout] = useState("");
	const [saving, setSaving] = useState(false);
	const [error, setError] = useState("");
	useEffect(() => {
		if (editing) kindSelect.current?.focus();
		else if (restoreFocus.current) editButton.current?.focus();
	}, [editing]);
	if (!editing) {
		return (
			<Button
				variant="quiet"
				ref={editButton}
				onClick={() => {
					setKind(profile?.kind ?? "");
					setAbout(profile?.about ?? "");
					setError("");
					restoreFocus.current = true;
					setEditing(true);
				}}
			>
				{profile ? memberProfileText.edit : memberProfileText.add}
			</Button>
		);
	}
	async function save() {
		if (!MemberProfileSchema.safeParse({ kind, about }).success) {
			setError(memberProfileText.singleLine);
			return;
		}
		setSaving(true);
		setError("");
		try {
			await onSave(kind, about);
			setEditing(false);
		} catch (cause) {
			setError(refusalText(cause));
		} finally {
			setSaving(false);
		}
	}
	return (
		<form
			className="member-profile-form"
			onSubmit={(event) => {
				event.preventDefault();
				void save();
			}}
		>
			<fieldset disabled={saving}>
				<legend>{memberProfileText.title(room)}</legend>
				<p className="hint">{memberProfileText.scope}</p>
				<Field id="roomProfileKind" label={memberProfileText.type}>
					{({ id }) => (
						<Select
							id={id}
							ref={kindSelect}
							value={kind}
							onChange={(event) => setKind(ProfileKindSchema.parse(event.currentTarget.value))}
						>
							<option value="">{memberProfileText.undeclared}</option>
							{(["person", "bot", "assisted"] as const).map((value) => (
								<option key={value} value={value}>{memberProfileLabels[value]}</option>
							))}
						</Select>
					)}
				</Field>
				<Field id="roomProfileAbout" label={memberProfileText.introduction}>
					{({ id }) => (
						<Input
							id={id}
							value={about}
							maxLength={MAX_PROFILE_ABOUT}
							onChange={(event) => setAbout(event.currentTarget.value)}
						/>
					)}
				</Field>
				{error && <Said kind="failure">{error}</Said>}
				<div className="actions">
					<Button variant="quiet" onClick={() => setEditing(false)} type="button">
						{memberProfileText.cancel}
					</Button>
					<Button variant="primary" type="submit" busy={saving} busyLabel={memberProfileText.saving}>
						{memberProfileText.save}
					</Button>
				</div>
			</fieldset>
		</form>
	);
}
