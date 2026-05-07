extends CanvasLayer

## Escape menu. Built procedurally so it can sit on the player without
## bloating player.tscn. Pause-mode is set so the menu still processes
## while get_tree().paused = true.

signal resumed
signal mouse_sensitivity_changed(value: float)

const PANEL_BG := Color(0.08, 0.08, 0.08, 0.92)
const TITLE_FG := Color(1.0, 1.0, 1.0, 1.0)

var _root         : Control
var _resume_btn   : Button
var _quit_btn     : Button
var _save_btn     : Button
var _load_btn     : Button
var _sens_slider  : HSlider
var _sens_value   : Label

var _open := false

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build_ui()
	visible = false

func _unhandled_input(event: InputEvent) -> void:
	# When paused, the player can't see input — pause menu owns ESC.
	if _open and event.is_action_pressed("ui_cancel"):
		close()
		get_viewport().set_input_as_handled()

# ── Public API ─────────────────────────────────────────────────────────────

func is_open() -> bool:
	return _open

func open() -> void:
	if _open:
		return
	_open = true
	visible = true
	# Pausing the tree freezes the network too — only do it in singleplayer.
	if not multiplayer.has_multiplayer_peer():
		get_tree().paused = true
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	_resume_btn.grab_focus()

func close() -> void:
	if not _open:
		return
	_open = false
	visible = false
	if not multiplayer.has_multiplayer_peer():
		get_tree().paused = false
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
	resumed.emit()

func toggle() -> void:
	if _open:
		close()
	else:
		open()

# ── Build ──────────────────────────────────────────────────────────────────

func _build_ui() -> void:
	# Full-screen dimmer
	_root = Control.new()
	_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_root)

	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.55)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(dim)

	# Centre panel
	var panel := PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_CENTER)
	panel.custom_minimum_size = Vector2(420, 460)
	panel.position = Vector2(-210, -230)
	var sb := StyleBoxFlat.new()
	sb.bg_color           = PANEL_BG
	sb.border_color       = Color(0.55, 0.55, 0.55, 0.9)
	sb.border_width_left  = 1
	sb.border_width_top   = 1
	sb.border_width_right = 1
	sb.border_width_bottom = 1
	sb.corner_radius_top_left     = 8
	sb.corner_radius_top_right    = 8
	sb.corner_radius_bottom_left  = 8
	sb.corner_radius_bottom_right = 8
	sb.content_margin_left   = 24
	sb.content_margin_right  = 24
	sb.content_margin_top    = 22
	sb.content_margin_bottom = 22
	panel.add_theme_stylebox_override("panel", sb)
	_root.add_child(panel)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 14)
	panel.add_child(vbox)

	var title := Label.new()
	title.text = "VOIDWATCH"
	title.add_theme_font_size_override("font_size", 28)
	title.add_theme_color_override("font_color", TITLE_FG)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(title)

	var subtitle := Label.new()
	subtitle.text = "— paused —"
	subtitle.add_theme_color_override("font_color", Color(0.70, 0.70, 0.70))
	subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(subtitle)

	vbox.add_child(_spacer(8))

	_resume_btn = _make_button("Resume",          _on_resume)
	_save_btn   = _make_button("Save World (F5)", _on_save)
	_load_btn   = _make_button("Load World (F9)", _on_load)
	_quit_btn   = _make_button("Quit to Desktop", _on_quit)
	vbox.add_child(_resume_btn)
	vbox.add_child(_save_btn)
	vbox.add_child(_load_btn)

	vbox.add_child(_spacer(8))

	# Sensitivity slider
	var sens_label := Label.new()
	sens_label.text = "Mouse Sensitivity"
	sens_label.add_theme_color_override("font_color", Color(0.85, 0.85, 0.85))
	vbox.add_child(sens_label)

	var sens_row := HBoxContainer.new()
	vbox.add_child(sens_row)

	_sens_slider = HSlider.new()
	_sens_slider.min_value = 0.4
	_sens_slider.max_value = 3.0
	_sens_slider.step = 0.05
	_sens_slider.value = 1.0
	_sens_slider.custom_minimum_size = Vector2(280, 24)
	_sens_slider.value_changed.connect(_on_sens_changed)
	sens_row.add_child(_sens_slider)

	_sens_value = Label.new()
	_sens_value.text = "1.00x"
	_sens_value.custom_minimum_size = Vector2(60, 24)
	sens_row.add_child(_sens_value)

	vbox.add_child(_spacer(8))
	vbox.add_child(_quit_btn)

func _make_button(label: String, cb: Callable) -> Button:
	var b := Button.new()
	b.text = label
	b.custom_minimum_size = Vector2(0, 38)
	b.add_theme_font_size_override("font_size", 16)
	b.pressed.connect(cb)
	return b

func _spacer(h: int) -> Control:
	var c := Control.new()
	c.custom_minimum_size = Vector2(0, h)
	return c

# ── Callbacks ──────────────────────────────────────────────────────────────

func _on_resume() -> void:
	close()

func _on_quit() -> void:
	get_tree().quit()

func _on_save() -> void:
	var world := get_tree().get_first_node_in_group("world")
	if world and world.has_method("save_world"):
		world.save_world()

func _on_load() -> void:
	var world := get_tree().get_first_node_in_group("world")
	if world and world.has_method("load_world"):
		world.load_world()

func _on_sens_changed(v: float) -> void:
	_sens_value.text = "%.2fx" % v
	mouse_sensitivity_changed.emit(v)
