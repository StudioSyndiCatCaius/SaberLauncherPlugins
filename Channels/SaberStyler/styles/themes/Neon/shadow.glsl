// Neon: an accent-coloured glow around chamfered panes instead of a dark shadow (dark UI
// themes); light UI themes keep a soft grey shadow.
#include "common.glsl"
#include "neon.glsl"

void main() {
	float d = neon_dist();
	float k = exp(-max(d, 0.0) / 9.0) * smoothstep(-1.0, 1.0, d);
	if (ui_light()) {
		finalColor = vec4(0.0, 0.0, 0.0, clamp(0.14 * params.y * k, 0.0, 1.0));
	} else {
		finalColor = vec4(accent.rgb, clamp(0.13 * params.y * k, 0.0, 1.0));
	}
}
