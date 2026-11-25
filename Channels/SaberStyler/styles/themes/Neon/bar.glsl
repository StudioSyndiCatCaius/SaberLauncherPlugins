// Neon header / footer: the HUD pane plus ruler ticks along the inner edge and a bright
// segment of the rim at the centre of the screen.
#include "glass.glsl"

void main() {
	vec4 c = glass_pane();
	vec2 px = ui_px();
	float d = neon_dist();
	float tick = step(fract(px.x / 32.0), 0.05) * step(-10.0, d) * step(d, -4.0);
	float mid = (px.x - (rect.x + rect.z * 0.5)) / max(rect.z * 0.16, 1.0);
	float rim = clamp(1.0 - abs(d + 1.0), 0.0, 1.0);
	c.rgb = mix(c.rgb, accent.rgb, tick * 0.45 + rim * exp(-mid * mid) * 0.9);
	finalColor = c;
}
