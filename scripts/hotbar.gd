extends Control

## Rust-style hotbar + inventory panel.
## - Always-visible hotbar at bottom-centre of the screen.
## - Tab toggles a larger inventory window that includes the hotbar plus
##   extra storage slots.
## The hotbar drives what the player does on LMB:
##   * weapon slot  → fire gun
##   * building slot → place ghost piece

signal slot_selected(index: int)
signal inventory_toggled(open: bool)
signal item_used(item: Dictionary, slot_idx: int)

# Each entry is a Dictionary so a future loot/save system can simply mutate it.
const ITEMS := [
	{ "id": "rifle",   "kind": "weapon", "name": "Rifle",        "color": Color(0.85, 0.85, 0.85), "stack": 1 },
	{ "id": "hammer",  "kind": "build",  "name": "Build Hammer", "color": Color(0.65, 0.65, 0.65), "stack": 1 },
	{ "id": "pickaxe", "kind": "tool",   "name": "Pickaxe",      "color": Color(0.50, 0.50, 0.50), "stack": 1 },
	{ "id": "",        "kind": "empty",  "name": "",             "color": Color(0.20, 0.20, 0.20), "stack": 0 },
	{ "id": "",        "kind": "empty",  "name": "",             "color": Color(0.20, 0.20, 0.20), "stack": 0 },
	{ "id": "",        "kind": "empty",  "name": "",             "color": Color(0.20, 0.20, 0.20), "stack": 0 },
]

# Lookup table for resources picked up via mining or chests.  add_resource()
# uses this to set the slot's display name and icon colour.
const RESOURCE_INFO := {
	"stone": { "name": "Stone",     "color": Color(0.55, 0.55, 0.55) },
	"metal": { "name": "Metal Ore", "color": Color(0.75, 0.75, 0.75) },
	"wood":  { "name": "Wood",      "color": Color(0.45, 0.45, 0.45) },
	"ammo":  { "name": "Ammo",      "color": Color(0.70, 0.70, 0.70) },
	"door":  { "name": "Door",      "color": Color(0.35, 0.35, 0.35) },
	"light": { "name": "Light",     "color": Color(0.90, 0.90, 0.90) },
}

const ITEM_TEXTURES := {
	"rifle":   "res://assets/icons/Rifle.png",
	"hammer":  "res://assets/icons/Hammer.png",
	"pickaxe": "res://assets/icons/Pickaxe.png",
	"stone":   "res://assets/icons/Stone.png",
	"metal":   "res://assets/icons/Raw_Metal.png",
	"wood":    "res://assets/icons/Wood.png",
	"ammo":    "res://assets/icons/Ammo.png",
	"door":    "res://assets/icons/Door.png",
}

const SLOT_SIZE  := Vector2(70, 80)
const SLOT_GAP   := 6
const HOTBAR_BOTTOM_OFFSET := 28.0

# Inventory grid: full hotbar plus 18 extra storage slots
const STORAGE_ROWS := 3
const STORAGE_COLS := 6

var selected         : int  = 0
var _inventory_open  : bool = false

var _hotbar_slots    : Array = []   # of Panel
var _storage_slots   : Array = []   # of Panel
var _inventory_panel : PanelContainer
var _storage_state   : Array = []   # of Dictionary (item-or-empty), keeps mutation in one place
var _craft_door_btn        : Button
var _craft_door_count_lbl  : Label
var _craft_light_btn       : Button
var _craft_light_count_lbl : Label

# Gun reference for ammo routing
var _gun_ref : WeakRef = null

# Inventory swap state (click-to-select, click-to-swap)
var _selected_storage_idx : int = -1

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_init_storage_state()
	_build_hotbar()
	_build_inventory_panel()
	refresh()

func _init_storage_state() -> void:
	_storage_state.clear()
	for _i in (STORAGE_ROWS * STORAGE_COLS):
		_storage_state.append({ "id": "", "kind": "empty", "name": "", "color": Color(0.20, 0.20, 0.20), "stack": 0 })

# ── Public API ─────────────────────────────────────────────────────────────

func set_gun(gun_node) -> void:
	_gun_ref = weakref(gun_node)

func get_selected_item() -> Dictionary:
	return ITEMS[selected]

func get_item(idx: int) -> Dictionary:
	return ITEMS[idx]

func slot_count() -> int:
	return ITEMS.size()

func select(idx: int) -> void:
	idx = clampi(idx, 0, ITEMS.size() - 1)
	if idx == selected:
		return
	selected = idx
	refresh()
	slot_selected.emit(selected)

func cycle(delta: int) -> void:
	var n := ITEMS.size()
	select((selected + delta + n) % n)

func toggle_inventory() -> void:
	_inventory_open = not _inventory_open
	_inventory_panel.visible = _inventory_open
	if _inventory_open:
		_update_craft_labels()
	else:
		_clear_selection()
	inventory_toggled.emit(_inventory_open)

# Adds a resource amount to inventory storage.  Stacks with an existing slot
# if one matches the id; otherwise occupies the first empty slot.  Drops on
# the floor (returns false) if storage is full.
func add_resource(id: String, amount: int) -> bool:
	if id == "" or amount <= 0:
		return false
	# Ammo goes directly into the gun's reserve first; only overflow hits storage.
	if id == "ammo" and _gun_ref and _gun_ref.get_ref():
		var g = _gun_ref.get_ref()
		if g.has_method("add_reserve"):
			var absorbed : int = g.add_reserve(amount)
			amount -= absorbed
			if amount <= 0:
				return true
	for i in _storage_state.size():
		if _storage_state[i].get("id", "") == id:
			_storage_state[i]["stack"] = int(_storage_state[i].get("stack", 0)) + amount
			_refresh_storage_slot(i)
			_update_craft_labels()
			return true
	for i in _storage_state.size():
		if _storage_state[i].get("id", "") == "":
			_storage_state[i] = _make_resource_dict(id, amount)
			_refresh_storage_slot(i)
			_update_craft_labels()
			return true
	return false

func get_resource_count(id: String) -> int:
	for item in _storage_state:
		if item.get("id", "") == id:
			return int(item.get("stack", 0))
	return 0

func consume_resource(id: String, amount: int) -> bool:
	for i in _storage_state.size():
		if _storage_state[i].get("id", "") == id:
			var cur := int(_storage_state[i].get("stack", 0))
			if cur < amount:
				return false
			if cur <= amount:
				_storage_state[i] = { "id": "", "kind": "empty", "name": "", "color": Color(0.20, 0.20, 0.20), "stack": 0 }
			else:
				_storage_state[i]["stack"] = cur - amount
			_refresh_storage_slot(i)
			_update_craft_labels()
			return true
	return false

func _make_resource_dict(id: String, amount: int) -> Dictionary:
	var info: Dictionary = RESOURCE_INFO.get(id, {
		"name":  id.capitalize(),
		"color": Color(0.45, 0.50, 0.55),
	})
	return {
		"id":    id,
		"kind":  "resource",
		"name":  info["name"],
		"color": info["color"],
		"stack": amount,
	}

func _refresh_storage_slot(idx: int) -> void:
	if idx < 0 or idx >= _storage_slots.size():
		return
	var slot : Panel = _storage_slots[idx]
	var item : Dictionary = _storage_state[idx]
	var name_lbl  := slot.get_node_or_null("NameLabel") as Label
	var stack_lbl := slot.get_node_or_null("StackLabel") as Label
	var icon_tex := slot.get_node_or_null("IconTex") as TextureRect
	if icon_tex:
		var tp : String = ITEM_TEXTURES.get(item.get("id", ""), "")
		icon_tex.texture = load(tp) if tp != "" else null
	if name_lbl:
		name_lbl.text = item.get("name", "")
	if stack_lbl:
		stack_lbl.text = _format_stack(int(item.get("stack", 0)))

func is_inventory_open() -> bool:
	return _inventory_open

# ── Build ──────────────────────────────────────────────────────────────────

func _build_hotbar() -> void:
	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", SLOT_GAP)
	hbox.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	var total_w := ITEMS.size() * SLOT_SIZE.x + (ITEMS.size() - 1) * SLOT_GAP
	hbox.position = Vector2(-total_w * 0.5, -SLOT_SIZE.y - HOTBAR_BOTTOM_OFFSET)
	hbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(hbox)

	for i in ITEMS.size():
		var slot := _make_slot(ITEMS[i], str(i + 1))
		hbox.add_child(slot)
		_hotbar_slots.append(slot)

func _build_inventory_panel() -> void:
	_inventory_panel = PanelContainer.new()
	_inventory_panel.set_anchors_preset(Control.PRESET_CENTER)
	_inventory_panel.position = Vector2(-300, -330)
	_inventory_panel.custom_minimum_size = Vector2(600, 660)
	_inventory_panel.visible = false
	_inventory_panel.mouse_filter = Control.MOUSE_FILTER_STOP

	var sb := StyleBoxFlat.new()
	sb.bg_color           = Color(0.08, 0.08, 0.08, 0.94)
	sb.border_color       = Color(0.55, 0.55, 0.55, 0.95)
	sb.border_width_left  = 1
	sb.border_width_top   = 1
	sb.border_width_right = 1
	sb.border_width_bottom = 1
	sb.corner_radius_top_left     = 8
	sb.corner_radius_top_right    = 8
	sb.corner_radius_bottom_left  = 8
	sb.corner_radius_bottom_right = 8
	sb.content_margin_left   = 22
	sb.content_margin_right  = 22
	sb.content_margin_top    = 18
	sb.content_margin_bottom = 18
	_inventory_panel.add_theme_stylebox_override("panel", sb)
	add_child(_inventory_panel)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 14)
	_inventory_panel.add_child(vbox)

	var title := Label.new()
	title.text = "INVENTORY"
	title.add_theme_font_size_override("font_size", 22)
	title.add_theme_color_override("font_color", Color(1.0, 1.0, 1.0))
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(title)

	var hint := Label.new()
	hint.text = "Tab to close  ·  1-6 hotbar  ·  Click to pick up, click again to place  ·  Right-click to use"
	hint.add_theme_color_override("font_color", Color(0.70, 0.70, 0.70))
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(hint)

	# Storage grid (cosmetic for now — state held in _storage_state)
	var stash_label := Label.new()
	stash_label.text = "Storage"
	stash_label.add_theme_color_override("font_color", Color(0.80, 0.80, 0.80))
	vbox.add_child(stash_label)

	var grid := GridContainer.new()
	grid.columns = STORAGE_COLS
	grid.add_theme_constant_override("h_separation", SLOT_GAP)
	grid.add_theme_constant_override("v_separation", SLOT_GAP)
	vbox.add_child(grid)

	for i in (STORAGE_ROWS * STORAGE_COLS):
		var slot := _make_slot(_storage_state[i], "")
		grid.add_child(slot)
		_storage_slots.append(slot)

	# ── Crafting section ──────────────────────────────────────────────────────
	var craft_sep := HSeparator.new()
	craft_sep.add_theme_constant_override("separation", 10)
	vbox.add_child(craft_sep)

	var craft_title := Label.new()
	craft_title.text = "CRAFTING"
	craft_title.add_theme_font_size_override("font_size", 18)
	craft_title.add_theme_color_override("font_color", Color(1.0, 1.0, 1.0))
	craft_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(craft_title)

	var door_row := HBoxContainer.new()
	door_row.add_theme_constant_override("separation", 12)
	vbox.add_child(door_row)

	var door_icon := ColorRect.new()
	door_icon.color = Color(0.35, 0.35, 0.35)
	door_icon.custom_minimum_size = Vector2(32, 32)
	door_row.add_child(door_icon)

	var door_recipe_lbl := Label.new()
	door_recipe_lbl.text = "Door   ←   10× Metal Ore"
	door_recipe_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	door_recipe_lbl.add_theme_color_override("font_color", Color(0.85, 0.85, 0.85))
	door_row.add_child(door_recipe_lbl)

	_craft_door_btn = Button.new()
	_craft_door_btn.text = "Craft"
	_craft_door_btn.custom_minimum_size = Vector2(76, 0)
	_craft_door_btn.pressed.connect(_craft_door)
	door_row.add_child(_craft_door_btn)

	_craft_door_count_lbl = Label.new()
	_craft_door_count_lbl.add_theme_color_override("font_color", Color(0.65, 0.65, 0.65))
	_craft_door_count_lbl.add_theme_font_size_override("font_size", 11)
	vbox.add_child(_craft_door_count_lbl)

	var light_row := HBoxContainer.new()
	light_row.add_theme_constant_override("separation", 12)
	vbox.add_child(light_row)

	var light_icon := ColorRect.new()
	light_icon.color = Color(0.90, 0.90, 0.90)
	light_icon.custom_minimum_size = Vector2(32, 32)
	light_row.add_child(light_icon)

	var light_recipe_lbl := Label.new()
	light_recipe_lbl.text = "Light   ←   5× Metal Ore"
	light_recipe_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	light_recipe_lbl.add_theme_color_override("font_color", Color(0.85, 0.85, 0.85))
	light_row.add_child(light_recipe_lbl)

	_craft_light_btn = Button.new()
	_craft_light_btn.text = "Craft"
	_craft_light_btn.custom_minimum_size = Vector2(76, 0)
	_craft_light_btn.pressed.connect(_craft_light)
	light_row.add_child(_craft_light_btn)

	_craft_light_count_lbl = Label.new()
	_craft_light_count_lbl.add_theme_color_override("font_color", Color(0.65, 0.65, 0.65))
	_craft_light_count_lbl.add_theme_font_size_override("font_size", 11)
	vbox.add_child(_craft_light_count_lbl)

	# Spacer between crafting and hotbar mirror
	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(0, 8)
	vbox.add_child(spacer)

	var bar_label := Label.new()
	bar_label.text = "Hotbar"
	bar_label.add_theme_color_override("font_color", Color(0.80, 0.80, 0.80))
	vbox.add_child(bar_label)

	# We don't duplicate the hotbar inside the panel — the live one at the bottom
	# of the screen is visible through the panel's outline anyway. A label is
	# enough to remind the player where it lives.
	var bar_hint := Label.new()
	bar_hint.text = "(visible at the bottom of the screen)"
	bar_hint.add_theme_color_override("font_color", Color(0.65, 0.65, 0.65))
	vbox.add_child(bar_hint)

func _make_slot(item: Dictionary, keybind: String) -> Panel:
	var p := Panel.new()
	p.custom_minimum_size = SLOT_SIZE
	p.add_theme_stylebox_override("panel", _slot_stylebox(false))

	# Keybind number (top-left)
	if keybind != "":
		var kb := Label.new()
		kb.text = keybind
		kb.position = Vector2(6, 2)
		kb.add_theme_font_size_override("font_size", 11)
		kb.add_theme_color_override("font_color", Color(0.90, 0.90, 0.90, 0.85))
		p.add_child(kb)

	# Stack count (top-right)
	var stack_lbl := Label.new()
	stack_lbl.name = "StackLabel"
	stack_lbl.text = _format_stack(item.get("stack", 0))
	stack_lbl.position = Vector2(SLOT_SIZE.x - 30, 2)
	stack_lbl.add_theme_font_size_override("font_size", 11)
	stack_lbl.add_theme_color_override("font_color", Color(1.0, 1.0, 1.0))
	p.add_child(stack_lbl)

	# Icon block — fills the slot between the keybind label and the name label
	const ICON_PAD := 4.0
	const ICON_Y   := 16.0
	var icon_w := SLOT_SIZE.x - ICON_PAD * 2          # 62 px
	var icon_h := SLOT_SIZE.y - ICON_Y - 16.0         # 48 px

	var icon_tex := TextureRect.new()
	icon_tex.name = "IconTex"
	var _tp : String = ITEM_TEXTURES.get(item.get("id", ""), "")
	if _tp != "":
		icon_tex.texture = load(_tp)
	icon_tex.size         = Vector2(icon_w, icon_h)
	icon_tex.position     = Vector2(ICON_PAD, ICON_Y)
	icon_tex.expand_mode  = TextureRect.EXPAND_KEEP_SIZE
	icon_tex.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon_tex.mouse_filter = Control.MOUSE_FILTER_IGNORE
	p.add_child(icon_tex)

	# Item name (bottom)
	var name_lbl := Label.new()
	name_lbl.name = "NameLabel"
	name_lbl.text = item.get("name", "")
	name_lbl.size = Vector2(SLOT_SIZE.x, 14)
	name_lbl.position = Vector2(0, SLOT_SIZE.y - 16)
	name_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	name_lbl.add_theme_font_size_override("font_size", 10)
	name_lbl.add_theme_color_override("font_color", Color(0.90, 0.90, 0.90))
	p.add_child(name_lbl)

	return p

func _slot_stylebox(highlighted: bool) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color           = Color(0.08, 0.08, 0.08, 0.85)
	sb.corner_radius_top_left     = 4
	sb.corner_radius_top_right    = 4
	sb.corner_radius_bottom_left  = 4
	sb.corner_radius_bottom_right = 4
	if highlighted:
		sb.border_color       = Color(1.0, 1.0, 1.0, 1.0)
		sb.border_width_left  = 3
		sb.border_width_top   = 3
		sb.border_width_right = 3
		sb.border_width_bottom = 3
	else:
		sb.border_color       = Color(0.55, 0.55, 0.55, 0.95)
		sb.border_width_left  = 1
		sb.border_width_top   = 1
		sb.border_width_right = 1
		sb.border_width_bottom = 1
	return sb

func _format_stack(s: int) -> String:
	if s <= 0:
		return ""
	if s >= 999:
		return "∞"
	if s == 1:
		return ""
	return str(s)

# ── Refresh ────────────────────────────────────────────────────────────────

func refresh() -> void:
	for i in _hotbar_slots.size():
		var p : Panel = _hotbar_slots[i]
		p.add_theme_stylebox_override("panel", _slot_stylebox(i == selected))

# ── Crafting ────────────────────────────────────────────────────────────────

func _craft_door() -> void:
	if get_resource_count("metal") < 10:
		return
	consume_resource("metal", 10)
	add_resource("door", 1)

func _craft_light() -> void:
	if get_resource_count("metal") < 5:
		return
	consume_resource("metal", 5)
	add_resource("light", 1)

# ── Inventory item movement (click-to-select, click-to-swap) ───────────────

func _input(event: InputEvent) -> void:
	if not _inventory_open:
		return
	if not (event is InputEventMouseButton) or not (event as InputEventMouseButton).pressed:
		return
	var mb := event as InputEventMouseButton
	var hovered := _get_hovered_storage_slot()

	if mb.button_index == MOUSE_BUTTON_RIGHT:
		if hovered >= 0:
			var item : Dictionary = _storage_state[hovered]
			if item.get("kind", "empty") != "empty":
				item_used.emit(item.duplicate(), hovered)
		_clear_selection()
		return

	if mb.button_index == MOUSE_BUTTON_LEFT:
		if hovered < 0:
			_clear_selection()
			return
		if _selected_storage_idx < 0:
			# Nothing held — pick up this slot (only if it has an item)
			if _storage_state[hovered].get("kind", "empty") != "empty":
				_set_selection(hovered)
		else:
			# Already holding something — swap with hovered slot
			if hovered != _selected_storage_idx:
				_swap_storage_slots(_selected_storage_idx, hovered)
			_clear_selection()

func _get_hovered_storage_slot() -> int:
	var mouse_pos := get_viewport().get_mouse_position()
	for i in _storage_slots.size():
		var slot := _storage_slots[i] as Control
		if slot.get_global_rect().has_point(mouse_pos):
			return i
	return -1

func _set_selection(idx: int) -> void:
	_selected_storage_idx = idx
	_apply_slot_style(idx, true)

func _clear_selection() -> void:
	if _selected_storage_idx >= 0:
		_apply_slot_style(_selected_storage_idx, false)
	_selected_storage_idx = -1

func _apply_slot_style(idx: int, selected: bool) -> void:
	if idx < 0 or idx >= _storage_slots.size():
		return
	var slot := _storage_slots[idx] as Panel
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.08, 0.08, 0.08, 0.85)
	sb.corner_radius_top_left     = 4
	sb.corner_radius_top_right    = 4
	sb.corner_radius_bottom_left  = 4
	sb.corner_radius_bottom_right = 4
	if selected:
		sb.border_color        = Color(1.0, 1.0, 1.0, 1.0)
		sb.border_width_left   = 3
		sb.border_width_top    = 3
		sb.border_width_right  = 3
		sb.border_width_bottom = 3
	else:
		sb.border_color        = Color(0.55, 0.55, 0.55, 0.95)
		sb.border_width_left   = 1
		sb.border_width_top    = 1
		sb.border_width_right  = 1
		sb.border_width_bottom = 1
	slot.add_theme_stylebox_override("panel", sb)

func _swap_storage_slots(a: int, b: int) -> void:
	var tmp : Dictionary = _storage_state[a].duplicate()
	_storage_state[a] = _storage_state[b].duplicate()
	_storage_state[b] = tmp
	_refresh_storage_slot(a)
	_refresh_storage_slot(b)
	_update_craft_labels()

func _update_craft_labels() -> void:
	if not is_instance_valid(_craft_door_count_lbl):
		return
	var metal := get_resource_count("metal")
	_craft_door_count_lbl.text = "Metal Ore in storage: %d  (need 10 to craft)" % metal
	if is_instance_valid(_craft_door_btn):
		_craft_door_btn.disabled = metal < 10
	if is_instance_valid(_craft_light_count_lbl):
		_craft_light_count_lbl.text = "Metal Ore in storage: %d  (need 5 to craft)" % metal
	if is_instance_valid(_craft_light_btn):
		_craft_light_btn.disabled = metal < 5
