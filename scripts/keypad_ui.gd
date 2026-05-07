extends Control

signal code_confirmed(code: String)
signal cancelled

var _entered     : String = ""
var _title_lbl   : Label
var _display_lbl : Label
var _status_lbl  : Label

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	_build_ui()
	visible = false

# ── Public API ──────────────────────────────────────────────────────────────

func show_for_set() -> void:
	_entered = ""
	_title_lbl.text  = "SET DOOR CODE"
	_status_lbl.text = "Pick a 4-digit code and press OK"
	_status_lbl.add_theme_color_override("font_color", Color(0.65, 0.72, 0.82))
	_update_display()
	visible = true

func show_for_enter() -> void:
	_entered = ""
	_title_lbl.text  = "ENTER CODE TO UNLOCK"
	_status_lbl.text = ""
	_update_display()
	visible = true

func show_wrong_code() -> void:
	_entered = ""
	_status_lbl.text = "Wrong code - try again"
	_status_lbl.add_theme_color_override("font_color", Color(0.95, 0.35, 0.35))
	_update_display()
	visible = true

func close() -> void:
	_on_cancel()

# ── Internal ────────────────────────────────────────────────────────────────

func _update_display() -> void:
	var s := ""
	for i in 4:
		if i > 0:
			s += "  "
		s += ("*" if i < _entered.length() else "_")
	_display_lbl.text = s

func _on_digit(d: int) -> void:
	if _entered.length() >= 4:
		return
	_entered += str(d)
	_status_lbl.text = ""
	_update_display()

func _on_delete() -> void:
	if _entered.length() > 0:
		_entered = _entered.substr(0, _entered.length() - 1)
	_update_display()

func _on_confirm() -> void:
	if _entered.length() < 4:
		_status_lbl.text = "Enter all 4 digits"
		_status_lbl.add_theme_color_override("font_color", Color(0.95, 0.35, 0.35))
		return
	var code := _entered
	_entered = ""
	visible  = false
	code_confirmed.emit(code)

func _on_cancel() -> void:
	_entered = ""
	visible  = false
	cancelled.emit()

# ── Build UI ────────────────────────────────────────────────────────────────

func _build_ui() -> void:
	var bg := ColorRect.new()
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.color       = Color(0.0, 0.0, 0.0, 0.60)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)

	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(center)

	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(280, 430)
	var sb := StyleBoxFlat.new()
	sb.bg_color                   = Color(0.05, 0.06, 0.10, 0.97)
	sb.border_color               = Color(0.30, 0.45, 0.65, 0.95)
	sb.border_width_left          = 1
	sb.border_width_top           = 1
	sb.border_width_right         = 1
	sb.border_width_bottom        = 1
	sb.corner_radius_top_left     = 10
	sb.corner_radius_top_right    = 10
	sb.corner_radius_bottom_left  = 10
	sb.corner_radius_bottom_right = 10
	sb.content_margin_left        = 22
	sb.content_margin_right       = 22
	sb.content_margin_top         = 18
	sb.content_margin_bottom      = 18
	panel.add_theme_stylebox_override("panel", sb)
	center.add_child(panel)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 12)
	panel.add_child(vbox)

	_title_lbl = Label.new()
	_title_lbl.add_theme_font_size_override("font_size", 16)
	_title_lbl.add_theme_color_override("font_color", Color(0.86, 0.92, 1.0))
	_title_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(_title_lbl)

	_display_lbl = Label.new()
	_display_lbl.text = "_  _  _  _"
	_display_lbl.add_theme_font_size_override("font_size", 36)
	_display_lbl.add_theme_color_override("font_color", Color(0.95, 0.88, 0.35))
	_display_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_display_lbl.custom_minimum_size   = Vector2(0, 56)
	vbox.add_child(_display_lbl)

	vbox.add_child(HSeparator.new())

	var grid := GridContainer.new()
	grid.columns = 3
	grid.add_theme_constant_override("h_separation", 8)
	grid.add_theme_constant_override("v_separation", 8)
	vbox.add_child(grid)

	_add_digit_btn(grid, 1)
	_add_digit_btn(grid, 2)
	_add_digit_btn(grid, 3)
	_add_digit_btn(grid, 4)
	_add_digit_btn(grid, 5)
	_add_digit_btn(grid, 6)
	_add_digit_btn(grid, 7)
	_add_digit_btn(grid, 8)
	_add_digit_btn(grid, 9)

	var del_btn := _make_btn("Del")
	del_btn.pressed.connect(_on_delete)
	grid.add_child(del_btn)

	_add_digit_btn(grid, 0)

	var ok_btn := _make_btn("OK")
	ok_btn.add_theme_color_override("font_color", Color(0.25, 0.90, 0.45))
	ok_btn.pressed.connect(_on_confirm)
	grid.add_child(ok_btn)

	_status_lbl = Label.new()
	_status_lbl.add_theme_font_size_override("font_size", 12)
	_status_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(_status_lbl)

	var cancel_btn := Button.new()
	cancel_btn.text = "Cancel  [Esc]"
	cancel_btn.pressed.connect(_on_cancel)
	vbox.add_child(cancel_btn)

func _add_digit_btn(grid: GridContainer, d: int) -> void:
	var btn := _make_btn(str(d))
	btn.pressed.connect(_on_digit.bind(d))
	grid.add_child(btn)

func _make_btn(lbl: String) -> Button:
	var btn := Button.new()
	btn.text = lbl
	btn.custom_minimum_size = Vector2(72, 54)
	btn.add_theme_font_size_override("font_size", 20)
	return btn
