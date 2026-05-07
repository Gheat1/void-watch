extends Control

## Hold Q to open, move mouse to hover an item, release Q to confirm selection.
## Emits piece_selected(name: String).

signal piece_selected(piece_name: String)

const ITEMS  : Array[String] = ["Foundation", "Wall", "Doorway", "Ceiling", "Window", "Light"]
const RADIUS := 120.0
const BTN_SZ := Vector2(116, 40)

var _buttons : Array[Button] = []
var _hovered := -1
var _open    := false
var _center  : Vector2

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_build_buttons()
	hide()

func _build_buttons() -> void:
	for i in ITEMS.size():
		var btn := Button.new()
		btn.text = ITEMS[i]
		btn.custom_minimum_size = BTN_SZ
		btn.mouse_filter = Control.MOUSE_FILTER_PASS
		btn.pressed.connect(_on_btn_pressed.bind(i))
		add_child(btn)
		_buttons.append(btn)

func _process(_delta: float) -> void:
	if not _open:
		return
	var dir := get_viewport().get_mouse_position() - _center
	if dir.length() < 28.0:
		_set_hovered(-1)
		return
	var seg := TAU / ITEMS.size()
	var idx := int(round((dir.angle() + PI * 0.5) / seg + ITEMS.size())) % ITEMS.size()
	_set_hovered(idx)

func _set_hovered(idx: int) -> void:
	if _hovered == idx:
		return
	_hovered = idx
	for i in _buttons.size():
		_buttons[i].modulate = Color(1.5, 1.5, 0.3) if i == idx else Color.WHITE

func open() -> void:
	if _open:
		return
	_open    = true
	_hovered = -1
	_center  = get_viewport_rect().size * 0.5
	for i in _buttons.size():
		var angle := (TAU / ITEMS.size()) * i - PI * 0.5
		_buttons[i].position = _center + Vector2(cos(angle), sin(angle)) * RADIUS - BTN_SZ * 0.5
	show()
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)

func close() -> void:
	if not _open:
		return
	_open = false
	var selected := _hovered
	hide()
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
	_set_hovered(-1)
	if selected >= 0:
		piece_selected.emit(ITEMS[selected])

func force_close() -> void:
	_open = false
	hide()
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
	_set_hovered(-1)

func _on_btn_pressed(idx: int) -> void:
	_hovered = idx
	close()
