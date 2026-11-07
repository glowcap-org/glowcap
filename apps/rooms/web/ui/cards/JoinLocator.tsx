// The address field of the join card: the directory a room lands in, typed
// or picked from the ones this tab already holds.

import { identifierField } from "../field.ts";
import { Icon } from "../icons.tsx";
import { type DirectoryDestinationContext, joinLocatorPlaceholder } from "../joining.ts";
import { joinChooseDirectory, joinHideDirectories } from "../../../lib/text/join.ts";
import { DirectoryPicks, typeAnotherAddress } from "../DirectoryPicks.tsx";
import { JoinField, JoinPrefix } from "./JoinField.tsx";
import { MenuLayer, useMenu } from "../Menu.tsx";
import type { DirId, DirView } from "../directory.ts";

export function JoinLocator(
	{ locator, dirs, defaultAddress, directoryContext, invalid, onPick, onType }: {
		locator: string;
		dirs: ReadonlyMap<DirId, DirView>;
		defaultAddress: string | null;
		directoryContext: DirectoryDestinationContext;
		invalid?: boolean;
		onPick: (locator: string) => void;
		onType: (locator: string) => void;
	},
) {
	const { open, setOpen, holder, trigger, layer } = useMenu();
	return (
		<div className="join-field-wrap" ref={holder}>
			<JoinField invalid={invalid}>
				<JoinPrefix
					id="joinLocator"
					ref={trigger}
					className="join-prefix-dir"
					label={open ? joinHideDirectories : joinChooseDirectory}
					aria-haspopup="menu"
					aria-expanded={open}
					onClick={() => setOpen((was) => !was)}
				>
					<Icon name="directory" size={18} />
				</JoinPrefix>
				<input
					id="locator"
					name="locator"
					type="text"
					inputMode="url"
					enterKeyHint="next"
					placeholder={joinLocatorPlaceholder(defaultAddress)}
					value={locator}
					aria-describedby={invalid === true ? "joinError" : undefined}
					aria-invalid={invalid === true}
					onChange={(e) => onType(e.target.value)}
					{...identifierField}
				/>
			</JoinField>
			{
				/* The addresses already in hand, from the mark that stands for this
				    field. A locator is forty characters nobody can retype, and every one
				    of these was typed or pasted once already. The only reason the field
				    is empty on the way back to it is that the field is where a *new* one
				    goes. Leaving it empty means this page's own directory, so that one
				    clears rather than fills. The last row is the way to an address that
				    is in none of them, and here it is the short way: the field it hands
				    over is the one this menu hangs from. */
			}
			{open && (
				<MenuLayer holder={holder} layer={layer} owner="joinForm">
					<DirectoryPicks
						className="locator-picks"
						locator={locator}
						dirs={dirs}
						context={directoryContext}
						onPick={(picked) => {
							setOpen(false);
							onPick(picked);
						}}
						onElsewhere={() => typeAnotherAddress(() => setOpen(false))}
					/>
				</MenuLayer>
			)}
		</div>
	);
}
