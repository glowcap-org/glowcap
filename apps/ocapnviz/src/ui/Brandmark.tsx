import { c } from "./tokens.ts";

// Mirror the legend's profile palette so the brandmark reads as a
// legend cue: amber = glowcap, purple = goblins, slate = other.
const PROFILE_GLOWCAP = "#f59e0b";
const PROFILE_GOBLINS = "#8b5cf6";
const PROFILE_OTHER = "#94a3b8";

/**
 * Brandmark, three connected vats arranged as a triangle (the
 * three-vat handoff that motivates ocapnviz). Two solid edges from
 * the gifter at top to the two parties below. A dashed edge between
 * those two represents the handoff that hasn't happened yet.
 *
 * Drawn at the 22px grid. Scales cleanly down to 16px and up to 32.
 */
export function Brandmark({ size = 22 }: { size?: number }) {
	return (
		<svg
			width={size}
			height={size}
			viewBox="0 0 22 22"
			aria-hidden="true"
			role="img"
		>
			<line
				x1={11}
				y1={4}
				x2={4}
				y2={17}
				style={{ stroke: c.borderStrong }}
				strokeWidth={1.4}
				strokeLinecap="round"
			/>
			<line
				x1={11}
				y1={4}
				x2={18}
				y2={17}
				style={{ stroke: c.borderStrong }}
				strokeWidth={1.4}
				strokeLinecap="round"
			/>
			<line
				x1={4}
				y1={17}
				x2={18}
				y2={17}
				style={{ stroke: c.borderStrong }}
				strokeWidth={1.4}
				strokeDasharray="2 2.4"
				strokeLinecap="round"
			/>
			<circle cx={11} cy={4} r={2.6} fill={PROFILE_GLOWCAP} />
			<circle cx={4} cy={17} r={2.6} fill={PROFILE_GOBLINS} />
			<circle cx={18} cy={17} r={2.6} fill={PROFILE_OTHER} />
		</svg>
	);
}
