import type { Theme } from "./tokens.ts";
import { MoonGlyph, SunGlyph } from "./glyphs.tsx";

/** Square icon button that flips between light and dark themes. Wears
 *  the same `.ocv-btn` chrome as its neighbors in the top bar; it used
 *  to be a round 32px control of its own and was the only thing in the
 *  app that looked like it. */
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
