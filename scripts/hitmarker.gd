extends Control

const DURATION := 0.3

var _alpha := 0.0

func _ready() -> void:
	mouse_filter = MOUSE_FILTER_IGNORE
	anchor_left   = 0.5
	anchor_right  = 0.5
	anchor_top    = 0.5
	anchor_bottom = 0.5
	offset_left   = -16.0
	offset_right  =  16.0
	offset_top    = -16.0
	offset_bottom =  16.0
	visible = false

func show_hit() -> void:
	_alpha  = 1.0
	visible = true
	queue_redraw()

func _process(delta: float) -> void:
	if _alpha > 0.0:
		_alpha = maxf(0.0, _alpha - delta / DURATION)
		if _alpha == 0.0:
			visible = false
		queue_redraw()

func _draw() -> void:
	if _alpha <= 0.0:
		return
	var color   := Color(1.0, 1.0, 1.0, _alpha)
	var center  := size / 2.0
	var gap     := 5.0
	var length  := 7.0
	var thickness := 2.0
	for d: Vector2 in [Vector2(-1, -1), Vector2(1, -1), Vector2(-1, 1), Vector2(1, 1)]:
		var nd := d.normalized()
		draw_line(center + nd * gap, center + nd * (gap + length), color, thickness, true)
