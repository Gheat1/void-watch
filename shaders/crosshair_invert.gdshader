shader_type canvas_item;

uniform sampler2D screen_texture : hint_screen_texture, repeat_disable, filter_nearest;

void fragment() {
	vec4 screen_col = texture(screen_texture, SCREEN_UV);
	COLOR.rgb = 1.0 - screen_col.rgb;
}
