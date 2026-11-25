// Matte helpers (only this theme has this file): flat paper look, small corners, ink lines.

// Small, fixed-feeling corners whatever radius the element asks for (pills included).
float m_rad() {
	return min(params.x, 8.0);
}

float m_dist() {
	return ui_dist(m_rad());
}

// Line colour: near-black on light UI themes, off-white on dark ones.
vec3 m_ink() {
	return ui_light() ? vec3(0.07, 0.07, 0.09) : vec3(0.93, 0.92, 0.88);
}

float m_hash(vec2 p) {
	return fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453);
}

// Paper grain: a static per-pixel speckle, +-amount.
vec3 m_grain(vec3 col, float amount) {
	return col * (1.0 + (m_hash(floor(ui_px())) - 0.5) * 2.0 * amount);
}

// 1 on diagonal stripes `period` px apart, scrolling with `speed` px/s.
float m_hatch(float period, float speed) {
	vec2 px = ui_px();
	return step(0.5, fract((px.x + px.y - time * speed) / period));
}
