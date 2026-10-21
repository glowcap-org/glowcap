import type { Theme } from "./tokens.ts";
import { MoonGlyph, SunGlyph } from "./glyphs.tsx";

/** Square icon button that flips between light and dark themes. Wears
 *  the same `.ocv-btn` chrome as its neighbors in the top bar. */
export function ThemeToggle(
	{ theme, onToggle }: { theme: Theme; onToggle: () => void },
) {
	const dark = theme === "dark";
	const label = dark ? "Switch to light mode" : "Switch to dark mode";
	return (
		<button
			type="button"
			className="ocv-btn is-ghost is-icon"
			onClick={onToggle}
			aria-label={label}
			title={label}
		>
			{dark ? <SunGlyph /> : <MoonGlyph />}
		</button>
	);
}
