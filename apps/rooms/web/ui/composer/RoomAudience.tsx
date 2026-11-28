import { useId, useMemo, useState } from "react";
import { MAX_ROOM_AUDIENCE } from "../../../lib/application_data.ts";
import { memberProfileLabels, roomAudienceText as words } from "../../../lib/text/conversation.ts";
import { refusalText } from "../../../lib/text/failure.ts";
import { applicationModule } from "../application.ts";
import { Button } from "../Button.tsx";
import type { RoomConv } from "../conversation.ts";
import { useRoomsSession } from "../controller/session.ts";
import { useConversationMembers } from "../hooks.ts";
import { Submodal } from "../Submodal.tsx";

export function RoomAudience({ room, nick }: { room: RoomConv; nick: string }) {
	const session = useRoomsSession();
	const roster = useConversationMembers(room.key);
	const listId = useId();
	const [open, setOpen] = useState(false);
	const [openedWith, setOpenedWith] = useState<readonly string[]>([]);
	const [chosen, choose] = useState<readonly string[]>([]);
	const [saving, setSaving] = useState(false);
	const [failure, setFailure] = useState("");
	const saved = room.audience ?? [];
	const [search, setSearch] = useState("");
	const available = useMemo(
		() =>
			open
				? [...roster].filter(([name, member]) =>
					member.online && name.toLowerCase() !== nick.toLowerCase() &&
					applicationModule().roomAudienceName(name)
				).map(([name]) => name)
				: [],
		[roster, nick, open],
	);
	const current = new Map(available.map((name) => [name.toLowerCase(), name]));
	const names = [...new Set([...available, ...chosen.map((name) => current.get(name.toLowerCase()) ?? name)])]
		.sort((left, right) => left.localeCompare(right));
	const selected = new Set(chosen.map((name) => name.toLowerCase()));
	const additional = available.filter((name) => !selected.has(name.toLowerCase())).sort((a, b) => a.localeCompare(b));
	const allFit = chosen.length + additional.length <= MAX_ROOM_AUDIENCE;
	const changedElsewhere = open &&
		(saved.length !== openedWith.length || saved.some((name, i) => name !== openedWith[i]));
	const query = search.trim().toLowerCase();
	const matching = names.filter((name) => {
		if (name.toLowerCase().includes(query)) return true;
		const profile = roster.get(name)?.profile;
		return profile != null && (profile.about.toLowerCase().includes(query) ||
			memberProfileLabels[profile.kind].toLowerCase().includes(query));
	});
	const searchable = search !== "" || names.length > 8 ||
		(names.length > 1 && names.some((name) => roster.get(name)?.profile));
	if (!saved.length && room.membership !== "joined") return null;
	async function save() {
		setSaving(true);
		setFailure("");
		try {
			await session.setRoomAudience(room.key, chosen);
			setOpen(false);
		} catch (cause) {
			setFailure(refusalText(cause));
		} finally {
			setSaving(false);
		}
	}
	const destination = saved.length ? saved.map((name) => "@" + name).join(", ") : words.room;
	const summary = saved.length > 2 ? words.members(saved.length) : destination;
	return (
		<div className="room-audience">
			<button
				type="button"
				aria-haspopup="dialog"
				onClick={() => {
					setOpenedWith(saved);
					choose(saved);
					setSearch("");
					setFailure("");
					setOpen(true);
				}}
				title={words.tooltip(destination)}
			>
				<span>{words.address}</span> <bdi>{summary}</bdi>
			</button>
			<Submodal
				title={words.title(room.id)}
				titleId="roomAudienceTitle"
				open={open}
				onClose={() => {
					if (!saving) setOpen(false);
				}}
			>
				<p>{words.explain(MAX_ROOM_AUDIENCE)}</p>
				<fieldset className="audience-choices" disabled={saving}>
					<legend>{words.legend}</legend>
					{searchable && (
						<label>
							{words.find}
							<input
								type="search"
								value={search}
								onChange={(event) => setSearch(event.currentTarget.value)}
							/>
						</label>
					)}
					{available.length > 0 && (
						<Button
							variant="link"
							disabled={!allFit || !additional.length}
							onClick={() => choose([...chosen, ...additional])}
						>
							{words.all}
						</Button>
					)}
					{!allFit && <p>{words.tooMany(MAX_ROOM_AUDIENCE)}</p>}
					{chosen.length >= MAX_ROOM_AUDIENCE && <p role="status">{words.full(MAX_ROOM_AUDIENCE)}</p>}
					<div className="audience-members">
						{matching.map((name, index) => {
							const checked = selected.has(name.toLowerCase());
							const member = roster.get(name);
							const offline = !member?.online;
							const profile = member?.profile;
							const descriptionId = profile ? listId + "-" + index : undefined;
							return (
								<label key={name}>
									<input
										type="checkbox"
										aria-label={profile ? name : undefined}
										aria-describedby={descriptionId}
										checked={checked}
										disabled={!checked && (offline || chosen.length >= MAX_ROOM_AUDIENCE)}
										onChange={() =>
											choose((was) =>
												checked
													? was.filter((item) => item.toLowerCase() !== name.toLowerCase())
													: [...was, name]
											)}
									/>
									<span className="audience-person">
										<bdi>{name}</bdi>
										{profile && (
											<small id={descriptionId}>
												{profile.kind && <span>{memberProfileLabels[profile.kind]}</span>}
												{profile.about && <bdi>{profile.about}</bdi>}
											</small>
										)}
									</span>
									{offline && <small>{words.offline}</small>}
								</label>
							);
						})}
					</div>
					{!matching.length && <p>{search ? words.noMatches : words.noOthers}</p>}
				</fieldset>
				{changedElsewhere && (
					<p role="status">
						{words.changed}
					</p>
				)}
				{failure && <p role="alert">{failure}</p>}
				<div className="actions">
					<Button variant="quiet" disabled={saving || chosen.length === 0} onClick={() => choose([])}>
						{words.clear}
					</Button>
					<Button
						variant="primary"
						busy={saving}
						disabled={saving || changedElsewhere}
						busyLabel={words.saving}
						onClick={() => void save()}
					>
						{words.save}
					</Button>
				</div>
			</Submodal>
		</div>
	);
}
