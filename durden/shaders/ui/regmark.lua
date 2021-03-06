return {
	version = 1,
	label = "Region-Border",
	uniforms = {
		border = {
			label = 'Border Size',
			utype = 'f',
			default = 1.0,
			low = 0.0,
			high = 10.0
		},
		col = {
			label = 'Color',
			utype = 'fff',
			default = {1.0, 1.0, 1.0},
			low = 0.0,
			high = 1.0
		},
	},
	frag = [[
uniform sampler2D map_tu0;
uniform vec2 obj_output_sz;
uniform float border;
uniform float obj_opacity;
uniform vec3 col;
varying vec2 texco;

void main()
{
	float bstep_x = border / obj_output_sz.x;
	float bstep_y = border / obj_output_sz.y;

	bvec2 marg1 = greaterThan(texco, vec2(1.0 - bstep_x, 0.99 - bstep_y));
	bvec2 marg2 = lessThan(texco, vec2(bstep_x, bstep_y));
	float f = float( !(any(marg1) || any(marg2)) );

	gl_FragColor = vec4(mix(col, texture2D(map_tu0, texco).rgb, f), 1.0);
}
]],
	states = {
		active = {
			uniforms = {
			}
		}
	}
};
