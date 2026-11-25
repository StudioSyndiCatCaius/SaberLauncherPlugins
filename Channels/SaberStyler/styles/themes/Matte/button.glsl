// Matte buttons: the paper pane, but a focused button fills strongly with the accent.
#include "glass.glsl"

void main() {
	vec4 c = glass_pane();
	c.rgb = mix(c.rgb, glow.rgb, glow.a * 0.30);
	finalColor = c;
}
