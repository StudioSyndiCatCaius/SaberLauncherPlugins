// Neon shape helpers (only this theme has this file): a HUD-style chamfered box.

// Signed distance to a box with half size b whose corners are cut off at 45 degrees by c px.
float sd_chamfer(vec2 p, vec2 b, float c) {
	vec2 q = abs(p) - b;
	float box = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0);
	float cut = (abs(p.x) + abs(p.y) - (b.x + b.y - c)) * 0.70710678;
	return max(box, cut);
}

// The cut for this element: from the corner radius, so pill buttons turn hexagonal.
float neon_cut() {
	return min(params.x * 0.75, min(rect.z, rect.w) * 0.45);
}

float neon_dist() {
	return sd_chamfer(ui_local(), rect.zw * 0.5, neon_cut());
}

// 1 within the bracket arms near the corners (len px along each edge from the cut).
float neon_corners(vec2 l, vec2 b, float c, float len) {
	vec2 a = abs(l);
	return step(b.x + b.y - c - 2.0 * len, a.x + a.y);
}

float neon_hash(float x) {
	return fract(sin(x) * 43758.5453);
}
