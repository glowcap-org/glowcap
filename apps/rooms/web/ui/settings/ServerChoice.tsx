// The Rooms server this browser uses, under Settings > Reachability. The
// choice belongs to the device, so it is open whatever the session allows, and
// saving reloads the page, because the server is chosen once as the session
// opens. Test asks the typed server the question the session will ask, and
// only a change that answered can be saved, so a server that turns this page
// away is found before the reload, not after.

import { useState } from "react";
import { saveAndReload } from "../../../lib/text/controls.ts";
import {
	serverAddressName,
	serverTest,
	serverTestAnswers,
	serverTestElsewhere,
	serverTestRefuses,
	serverTestSilent,
	settingsServerExample,
	settingsServerHint,
	settingsServerRefused,
} from "../../../lib/text/settings.ts";
import { Button } from "../Button.tsx";
import { Field } from "../Field.tsx";
import { identifierField } from "../field.ts";
import { Input } from "../Input.tsx";
import { chooseServer, chosenServer, probeServer, serverBase, type ServerProbe } from "../server_choice.ts";
import { namesDirectory } from "../application.ts";
import { Said } from "../Said.tsx";
import { pageBase, servedByRooms } from "../page_base.ts";

/** `framed` is the dialog's own well around the form, and focus on the field
 * the reader opened it for. In a card the card is the well already. */
export function ServerChoice(
	{ reload = () => location.reload(), framed = false }: { reload?: () => void; framed?: boolean },
) {
	const [saved] = useState(chosenServer);
	const [typed, setTyped] = useState(saved ?? "");
	const [why, setWhy] = useState("");
	const [served] = useState(servedByRooms);
	const [probe, setProbe] = useState<{ base: string; said: ServerProbe } | null>(null);
	const [testing, setTesting] = useState(false);
	const read = serverBase(typed);
	const changed = "base" in read ? read.base !== saved : true;
	// What a blank address tests is the server this page came from.
	const testBase = "base" in read ? read.base ?? (served ? pageBase().href : null) : null;
	const test = async () => {
		if (testBase == null) {
			setWhy(settingsServerRefused);
			return;
		}
		setTesting(true);
		const said = await probeServer(testBase, namesDirectory);
		setProbe({ base: testBase, said });
		setTesting(false);
	};
	// A result belongs to the address it tested, so typing past it clears it.
	const result = probe != null && probe.base === testBase ? probe.said : null;
	// Saving reloads into the server, so only a server that answered is saved.
	// Choosing none, on a page with no server of its own, has nothing to ask.
	const proven = testBase == null || result?.kind === "answers";
	const savable = "base" in read && changed && proven;
	return (
		<form
			id="serverForm"
			className={framed ? "group well server-form" : "server-form"}
			onSubmit={(event) => {
				event.preventDefault();
				if (!("base" in read)) {
					setWhy(settingsServerRefused);
					return;
				}
				// Enter walks the same path the buttons show: test, then save.
				if (!proven) {
					if (!testing) void test();
					return;
				}
				if (!changed) return;
				chooseServer(read.base);
				reload();
			}}
		>
			<div className="field-row">
				<Field
					id="serverAddress"
					label={serverAddressName}
					hint={settingsServerHint(served)}
					said={why}
				>
					{(wiring) => (
						<Input
							id={wiring.id}
							type="text"
							inputMode="url"
							{...identifierField}
							value={typed}
							aria-describedby={wiring.describedBy}
							aria-invalid={wiring.invalid}
							placeholder={served ? pageBase().href : settingsServerExample}
							autoFocus={framed}
							onChange={(event) => {
								setTyped(event.currentTarget.value);
								setWhy("");
							}}
							// A browser drops Enter while the submit button is off, and
							// Save is off until a test passes, so Enter submits here and
							// the form tests first.
							onKeyDown={(event) => {
								if (event.key !== "Enter") return;
								event.preventDefault();
								event.currentTarget.form?.requestSubmit();
							}}
						/>
					)}
				</Field>
				<Button
					id="serverTest"
					size="large"
					// The next step leads: Test until the change has answered.
					variant={changed && !proven ? "primary" : "quiet"}
					busy={testing}
					disabled={testBase == null}
					onClick={() => void test()}
				>
					{serverTest}
				</Button>
			</div>
			{result != null && (
				<Said id="serverTestSaid" kind={result.kind === "answers" ? "success" : "warning"}>
					{result.kind === "answers"
						? serverTestAnswers
						: result.kind === "elsewhere"
						? serverTestElsewhere
						: result.kind === "refuses"
						? serverTestRefuses(location.origin)
						: serverTestSilent}
				</Said>
			)}
			<div className="actions" data-fill>
				{/* One act leads at a time: Save takes the lead once there is a tested change to save. */}
				<Button
					id="serverSave"
					type="submit"
					size="large"
					variant={savable ? "primary" : "quiet"}
					disabled={!savable}
				>
					{saveAndReload}
				</Button>
			</div>
		</form>
	);
}
