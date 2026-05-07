extends CharacterBody3D

enum Mode { COMBAT, CONSTRUCTION, TOOL }

const SPEED         := 5.0
const SPRINT_SPEED  := 9.0
const SNEAK_SPEED   := 2.0
const JUMP_VELOCITY := 4.5
const GRAVITY       := 9.8
const BASE_MOUSE_SENS := 0.002

const STAND_HEIGHT  := 1.8
const CROUCH_HEIGHT := 1.0
const STAND_CAM_Y   := 1.65
const CROUCH_CAM_Y  := 0.85

const MAX_HEALTH       := 100.0
const HEALTH_BAR_WIDTH := 450.0

const PICKAXE_DAMAGE   := 10.0
const INTERACT_RANGE   := 16.0

const NORMAL_FOV := 75.0
const ZOOM_FOV   := 30.0

@onready var head            : Node3D           = $Head
@onready var camera          : Camera3D         = $Head/Camera3D
@onready var ray             : RayCast3D        = $Head/Camera3D/RayCast3D
@onready var col_shape       : CollisionShape3D = $CollisionShape3D
@onready var ghost_placer    : Node3D           = $GhostPlacer
@onready var gun             : Node             = $Head/Camera3D/Gun
@onready var hammer          : Node             = $Head/Camera3D/Hammer
@onready var pickaxe         : Node             = $Head/Camera3D/Pickaxe
@onready var ammo_label      : Label            = $HUD/Control/AmmoLabel
@onready var reload_label    : Label            = $HUD/Control/ReloadLabel
@onready var hint_label      : Label            = $HUD/Control/HintLabel
@onready var pause_menu      : Node             = $PauseMenu
@onready var body_visual     : Node3D           = $BodyPivot
@onready var remote_pivot    : Node3D           = $RemotePivot
@onready var hotbar          : Node             = $HUD/Control/Hotbar
@onready var radial_menu     : Node             = $BuildMenuCanvas/RadialMenu
@onready var health_fill     : ColorRect        = $HUD/Control/HealthBar/Fill
@onready var health_label    : Label            = $HUD/Control/HealthBar/Label
@onready var crosshair       : Label            = $HUD/Control/Crosshair
@onready var interact_prompt : Label            = $HUD/Control/InteractPrompt
@onready var pickup_label    : Label            = $HUD/Control/PickupLabel
@onready var hud_layer       : CanvasLayer      = $HUD
@onready var build_canvas    : CanvasLayer      = $BuildMenuCanvas

signal health_changed(current, maximum)

var mode : int = Mode.COMBAT
var _sneaking : bool = false
var _zoomed   : bool = false
var _mouse_sens_mult : float = 1.0
var _ammo_cur : int = 30
var _ammo_res : int = 120

var health           : float = MAX_HEALTH
var _last_health     : float = MAX_HEALTH   # to detect remote-driven changes
var _pickup_clear_t  : float = 0.0

var _keypad_ui               : Control  = null
var _keypad_door             : Node     = null
var _is_setting_code         : bool     = false
var _pending_doorway         : Node3D   = null

# ── Multiplayer plumbing ────────────────────────────────────────────────────

func _enter_tree() -> void:
	# Player nodes are named after their owning peer id (see network.gd).
	# Setting authority before _ready ensures input gating works correctly.
	var id := 1
	var n := str(name)
	if n.is_valid_int():
		id = int(n)
	set_multiplayer_authority(id)

func is_local() -> bool:
	if not multiplayer.has_multiplayer_peer():
		return true
	return get_multiplayer_authority() == multiplayer.get_unique_id()

# ── Lifecycle ───────────────────────────────────────────────────────────────

func _ready() -> void:
	add_to_group("player")
	ray.add_exception(self)
	gun.ammo_changed.connect(_on_ammo_changed)
	gun.reload_started.connect(_on_reload_started)
	gun.reload_finished.connect(_on_reload_finished)
	pause_menu.mouse_sensitivity_changed.connect(_on_sens_changed)
	pause_menu.resumed.connect(_on_pause_resumed)
	hotbar.slot_selected.connect(_on_slot_selected)
	hotbar.inventory_toggled.connect(_on_inventory_toggled)
	radial_menu.piece_selected.connect(_on_piece_selected)
	health_changed.connect(_on_health_changed)

	if is_local():
		_setup_local()
	else:
		_setup_remote()

	_on_health_changed(health, MAX_HEALTH)

func _setup_local() -> void:
	remote_pivot.visible = false
	camera.current = true
	hud_layer.visible = true
	build_canvas.visible = true
	ghost_placer.visible = false
	pickup_label.visible = false
	interact_prompt.visible = false
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
	call_deferred("_recapture_mouse")
	var win := get_window()
	if win and not win.focus_entered.is_connected(_recapture_mouse):
		win.focus_entered.connect(_recapture_mouse)
	_on_slot_selected(hotbar.selected)
	hotbar.set_gun(gun)
	hotbar.item_used.connect(_on_inventory_item_used)
	# Keypad UI — lives on the HUD layer so it renders above everything.
	_keypad_ui = preload("res://scripts/keypad_ui.gd").new()
	hud_layer.add_child(_keypad_ui)
	_keypad_ui.code_confirmed.connect(_on_keypad_confirmed)
	_keypad_ui.cancelled.connect(_on_keypad_cancelled)
	var _xhair_mat := ShaderMaterial.new()
	_xhair_mat.shader = preload("res://shaders/crosshair_invert.gdshader")
	crosshair.material = _xhair_mat

func _setup_remote() -> void:
	# Hide all UI and view-model on remote players — we only want their body.
	camera.current = false
	hud_layer.visible = false
	build_canvas.visible = false
	pause_menu.visible = false
	ghost_placer.visible = false
	gun.visible = false
	hammer.visible = false
	pickaxe.visible = false
	body_visual.visible = false
	remote_pivot.visible = true
	# Disable physics-driven input; remote position is driven by the synchronizer.
	set_physics_process(true)   # still need to mirror body rotation
	set_process_input(false)
	set_process_unhandled_input(false)

func _recapture_mouse() -> void:
	if not is_local():
		return
	if _no_overlay_open():
		Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)

func _no_overlay_open() -> bool:
	if hotbar and hotbar.is_inventory_open():
		return false
	if pause_menu and pause_menu.is_open():
		return false
	if radial_menu and radial_menu.visible:
		return false
	if _keypad_ui != null and _keypad_ui.visible:
		return false
	return true

# ── Input ─────────────────────────────────────────────────────────────────

func _input(event: InputEvent) -> void:
	if not is_local():
		return
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED and not hotbar.is_inventory_open():
		var sens := BASE_MOUSE_SENS * _mouse_sens_mult
		head.rotate_y(-event.relative.x * sens)
		camera.rotate_x(-event.relative.y * sens)
		camera.rotation.x = clampf(camera.rotation.x, -PI * 0.5, PI * 0.5)
		return

	if event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_1: hotbar.select(0)
			KEY_2: hotbar.select(1)
			KEY_3: hotbar.select(2)
			KEY_4: hotbar.select(3)
			KEY_5: hotbar.select(4)
			KEY_6: hotbar.select(5)
			KEY_TAB: hotbar.toggle_inventory()

	if event is InputEventMouseButton:
		if event.pressed:
			if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED and _no_overlay_open():
				Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
				get_viewport().set_input_as_handled()
				return
			if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
				if event.button_index == MOUSE_BUTTON_WHEEL_UP:
					hotbar.cycle(-1)
				elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
					hotbar.cycle(1)
		if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED and mode == Mode.COMBAT:
			if event.button_index == MOUSE_BUTTON_RIGHT:
				_set_zoom(event.pressed)

func _unhandled_input(event: InputEvent) -> void:
	if not is_local():
		return
	if event.is_action_pressed("ui_cancel"):
		if _keypad_ui != null and _keypad_ui.visible:
			_keypad_ui.close()
			return
		if radial_menu.visible:
			radial_menu.force_close()
			return
		if hotbar.is_inventory_open():
			hotbar.toggle_inventory()
			return
		pause_menu.toggle()
		return

	if _keypad_ui != null and _keypad_ui.visible:
		return

	if hotbar.is_inventory_open():
		return

	if event.is_action_pressed("open_build_menu"):
		var sel_item = hotbar.get_selected_item()
		if str(sel_item.get("kind", "")) != "build":
			var build_slot := _find_slot_by_kind("build")
			if build_slot >= 0:
				hotbar.select(build_slot)
		radial_menu.open()
		return
	if event.is_action_released("open_build_menu"):
		if radial_menu.visible:
			radial_menu.close()
			return

	if radial_menu.visible:
		return

	if event.is_action_pressed("interact"):
		_try_interact()
		return

	if event.is_action_pressed("toggle_mode"):
		hotbar.select(0 if hotbar.selected != 0 else 1)
		return

	match mode:
		Mode.COMBAT:
			if event.is_action_pressed("primary_attack"):
				if gun.reserve_ammo <= 0:
					_pull_ammo_from_inventory()
				gun.fire(ray)
			if event.is_action_pressed("reload"):
				_pull_ammo_from_inventory()
				gun.start_reload()
		Mode.CONSTRUCTION:
			if event.is_action_pressed("place_piece"):
				if ghost_placer.get_piece() == "Light":
					if not hotbar.consume_resource("light", 1):
						_show_pickup("No light in inventory")
						return
				hammer.play_swing()
				ghost_placer.try_place()
			if event.is_action_pressed("rotate_piece"):
				ghost_placer.rotate_piece()
		Mode.TOOL:
			if event.is_action_pressed("primary_attack"):
				pickaxe.play_swing()
				_swing_pickaxe()

# ── Physics + per-frame work ───────────────────────────────────────────────

func _physics_process(delta: float) -> void:
	# Remote players: just mirror body rotation to head, sync drives position.
	if not is_local():
		remote_pivot.rotation.y = head.rotation.y
		return

	_update_stance(Input.is_action_pressed("sneak"))

	if not is_on_floor():
		velocity.y -= GRAVITY * delta

	if Input.is_action_pressed("jump") and is_on_floor() and not _sneaking:
		velocity.y = JUMP_VELOCITY

	var spd: float
	if _sneaking:
		spd = SNEAK_SPEED
	elif Input.is_action_pressed("sprint"):
		spd = SPRINT_SPEED
	else:
		spd = SPEED

	if hotbar.is_inventory_open() or (_keypad_ui != null and _keypad_ui.visible):
		spd = 0.0

	var inp := Input.get_vector("move_left", "move_right", "move_forward", "move_back")
	if inp.length_squared() > 0.0 and spd > 0.0:
		var dir := (head.global_basis * Vector3(inp.x, 0, inp.y)).normalized()
		velocity.x = dir.x * spd
		velocity.z = dir.z * spd
	else:
		velocity.x = move_toward(velocity.x, 0, max(spd, 1.0))
		velocity.z = move_toward(velocity.z, 0, max(spd, 1.0))

	move_and_slide()

	body_visual.rotation.y = head.rotation.y

	if mode == Mode.CONSTRUCTION:
		ghost_placer.update_ghost(camera, ray)

	_update_interact_prompt()

func _process(delta: float) -> void:
	if is_local():
		if _pickup_clear_t > 0.0:
			_pickup_clear_t -= delta
			if _pickup_clear_t <= 0.0:
				pickup_label.visible = false
	# Detect synchronizer-driven health changes (remote/server pushed new value).
	if not is_equal_approx(health, _last_health):
		_last_health = health
		health_changed.emit(health, MAX_HEALTH)
		if is_local() and health <= 0.0:
			_die_local()

# ── Stance ─────────────────────────────────────────────────────────────────

func _update_stance(sneaking: bool) -> void:
	if sneaking == _sneaking:
		return
	_sneaking = sneaking
	var cap := col_shape.shape as CapsuleShape3D
	cap.height = CROUCH_HEIGHT if sneaking else STAND_HEIGHT
	col_shape.position.y = cap.height * 0.5
	head.position.y = CROUCH_CAM_Y if sneaking else STAND_CAM_Y
	body_visual.scale.y = 0.6 if sneaking else 1.0

# ── Mode ───────────────────────────────────────────────────────────────────

func _set_mode(new_mode: int) -> void:
	mode = new_mode
	ghost_placer.visible = is_local() and mode == Mode.CONSTRUCTION
	gun.visible          = is_local() and mode == Mode.COMBAT
	hammer.visible       = is_local() and mode == Mode.CONSTRUCTION
	pickaxe.visible      = is_local() and mode == Mode.TOOL
	if mode != Mode.COMBAT and _zoomed:
		_set_zoom(false)
	if is_local():
		_refresh_hud()

func _set_zoom(on: bool) -> void:
	_zoomed = on
	camera.fov = ZOOM_FOV if on else NORMAL_FOV

# ── HUD ────────────────────────────────────────────────────────────────────

func _refresh_hud() -> void:
	if mode == Mode.COMBAT:
		hint_label.text = "1-6 hotbar  ·  Q build menu  ·  E interact  ·  Tab inventory  ·  LMB fire  ·  R reload"
	elif mode == Mode.CONSTRUCTION:
		hint_label.text = "1-6 hotbar  ·  Q build menu  ·  E interact  ·  Tab inventory  ·  LMB place  ·  R rotate"
	else:
		hint_label.text = "1-6 hotbar  ·  Q build menu  ·  E interact  ·  Tab inventory  ·  LMB mine"
	ammo_label.visible   = mode == Mode.COMBAT
	reload_label.visible = false
	if mode == Mode.COMBAT:
		ammo_label.text = "%d  |  %d" % [_ammo_cur, _ammo_res]

func _on_ammo_changed(current: int, _mag: int, reserve: int) -> void:
	_ammo_cur = current
	_ammo_res = reserve
	if is_local():
		ammo_label.text = "%d  |  %d" % [current, reserve]

func _on_reload_started(_dur: float) -> void:
	if is_local():
		reload_label.visible = true

func _on_reload_finished() -> void:
	if is_local():
		reload_label.visible = false
		ammo_label.text = "%d  |  %d" % [_ammo_cur, _ammo_res]

# ── Health ─────────────────────────────────────────────────────────────────

# Anyone can request damage on this player; only the authority applies it.
# Health is then replicated to all peers via the MultiplayerSynchronizer.
@rpc("any_peer", "call_local", "reliable")
func take_damage(amount: float) -> void:
	if not is_multiplayer_authority():
		return
	if health <= 0.0:
		return
	health = max(0.0, health - amount)
	_last_health = health
	health_changed.emit(health, MAX_HEALTH)
	if health == 0.0:
		_die_local()

func heal(amount: float) -> void:
	if not is_multiplayer_authority():
		return
	if health <= 0.0:
		return
	health = min(MAX_HEALTH, health + amount)
	_last_health = health
	health_changed.emit(health, MAX_HEALTH)

func _die_local() -> void:
	if not is_multiplayer_authority():
		return
	var world := get_tree().get_first_node_in_group("world")
	var spawn_y := 4.0
	if world and world.has_method("get_terrain_height"):
		spawn_y = float(world.get_terrain_height(0.0, 0.0)) + 4.0
	global_position = Vector3(randf_range(-2.5, 2.5), spawn_y, randf_range(-2.5, 2.5))
	velocity = Vector3.ZERO
	health = MAX_HEALTH
	_last_health = health
	health_changed.emit(health, MAX_HEALTH)
	if is_local():
		_show_pickup("You died — respawning")

func _on_health_changed(current, _maximum) -> void:
	if not is_local():
		return
	var ratio := clampf(float(current) / MAX_HEALTH, 0.0, 1.0)
	health_fill.size.x = HEALTH_BAR_WIDTH * ratio
	if ratio > 0.5:
		health_fill.color = Color(0.88, 0.88, 0.88)
	elif ratio > 0.25:
		health_fill.color = Color(0.60, 0.60, 0.60)
	else:
		health_fill.color = Color(0.38, 0.38, 0.38)
	health_label.text = "%d / %d" % [int(current), int(MAX_HEALTH)]

# ── Hotbar / inventory ─────────────────────────────────────────────────────

func _on_slot_selected(idx: int) -> void:
	var item = hotbar.get_item(idx)
	if radial_menu.visible:
		radial_menu.force_close()
	var kind := str(item.get("kind", "empty"))
	if kind == "weapon":
		_set_mode(Mode.COMBAT)
	elif kind == "build":
		_set_mode(Mode.CONSTRUCTION)
	elif kind == "tool":
		_set_mode(Mode.TOOL)
	else:
		_set_mode(Mode.COMBAT)
		gun.visible = false

func _on_piece_selected(piece_name: String) -> void:
	ghost_placer.set_piece(piece_name)

func _on_inventory_toggled(is_open: bool) -> void:
	if is_local():
		Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE if is_open else Input.MOUSE_MODE_CAPTURED)

func _pull_ammo_from_inventory() -> void:
	var stored : int = hotbar.get_resource_count("ammo")
	if stored <= 0 or gun.reserve_ammo >= gun.reserve_max:
		return
	var absorbed : int = gun.add_reserve(stored)
	if absorbed > 0:
		hotbar.consume_resource("ammo", absorbed)
		_show_pickup("+%d ammo loaded from inventory" % absorbed)

func _on_inventory_item_used(item: Dictionary, slot_idx: int) -> void:
	if not is_local():
		return
	var id := str(item.get("id", ""))
	if id == "ammo":
		var stored := int(item.get("stack", 0))
		if stored <= 0:
			return
		var absorbed : int = gun.add_reserve(stored)
		if absorbed > 0:
			hotbar.consume_resource("ammo", absorbed)
			_show_pickup("+%d ammo loaded into reserve" % absorbed)
		else:
			_show_pickup("Ammo reserve is full (%d / %d)" % [gun.reserve_ammo, gun.reserve_max])

func _find_slot_by_kind(kind: String) -> int:
	var n := int(hotbar.slot_count())
	for i in n:
		var item = hotbar.get_item(i)
		if str(item.get("kind", "")) == kind:
			return i
	return -1

# ── Mining + interact ──────────────────────────────────────────────────────

func _swing_pickaxe() -> void:
	if not ray.is_colliding():
		return
	var node := _find_in_group(ray.get_collider(), "mineral_nodes")
	if node == null:
		return
	if not node.has_method("mine"):
		return
	var result_v = node.mine(PICKAXE_DAMAGE)
	if not (result_v is Dictionary):
		return
	var result : Dictionary = result_v
	var rid := str(result.get("id", ""))
	var amt := int(result.get("amount", 0))
	if rid != "" and amt > 0:
		hotbar.add_resource(rid, amt)
		_show_pickup("+%d %s" % [amt, _pretty_name(rid)])

func _try_interact() -> void:
	# Open doors have no collision — detect by proximity first.
	var open_door := _find_nearby_open_door()
	if open_door != null:
		_door_call(open_door, "close_door")
		return

	if not ray.is_colliding():
		return
	var collider := ray.get_collider()

	# Interact with a closed door (collision is on, raycast finds it).
	var door := _find_in_group(collider, "doors")
	if door != null:
		if global_position.distance_to(door.base_pos) <= INTERACT_RANGE:
			if door.lock_code == "":
				_door_call(door, "open_door")
			elif _keypad_ui != null:
				_keypad_door     = door
				_is_setting_code = false
				_keypad_ui.show_for_enter()
				Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
		return

	# Place a door from inventory into an empty doorway.
	var doorway := _get_doorway(collider)
	if doorway != null:
		if global_position.distance_to(doorway.global_position) <= INTERACT_RANGE:
			if not _doorway_has_door(doorway) and hotbar.get_resource_count("door") > 0:
				_pending_doorway = doorway
				_is_setting_code  = true
				_keypad_door      = null
				if _keypad_ui != null:
					_keypad_ui.show_for_set()
					Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
		return

	# Open a loot chest.
	var chest := _find_in_group(collider, "loot_chests")
	if chest == null:
		return
	if not chest.has_method("open"):
		return
	if global_position.distance_to((chest as Node3D).global_position) > INTERACT_RANGE:
		return
	var loot_v = chest.open()
	if not (loot_v is Dictionary):
		return
	var loot : Dictionary = loot_v
	if loot.is_empty():
		return
	var msg := ""
	for k in loot.keys():
		var amt := int(loot[k])
		if amt <= 0:
			continue
		var key_str := str(k)
		hotbar.add_resource(key_str, amt)
		if msg != "":
			msg += ", "
		msg += "+%d %s" % [amt, _pretty_name(key_str)]
	if msg != "":
		_show_pickup(msg)

func _get_doorway(collider) -> Node3D:
	var piece := _find_in_group(collider, "building_pieces")
	if piece == null:
		return null
	if str(piece.get_meta("piece_type", "")) == "Doorway":
		return piece as Node3D
	return null

func _doorway_has_door(doorway: Node3D) -> bool:
	for d in get_tree().get_nodes_in_group("doors"):
		if (d as Node3D).base_pos.distance_to(doorway.global_position) < 2.0:
			return true
	return false

func _place_door_with_code(doorway: Node3D, code: String) -> void:
	var offset := doorway.global_basis * Vector3(0.0, -0.45, 0.0)
	var pos    := doorway.global_position + offset
	var rot    := doorway.global_rotation
	var main   := get_tree().current_scene
	if multiplayer.has_multiplayer_peer():
		if main and main.has_method("request_place_door"):
			main.rpc_id(1, "request_place_door", pos, rot, code)
	else:
		var packed : PackedScene = load("res://scenes/building/door.tscn")
		if not packed:
			return
		var door_node := packed.instantiate()
		door_node.position = pos
		door_node.rotation = rot
		door_node.set("lock_code", code)
		if main:
			main.add_child(door_node)

func _find_nearby_open_door() -> Node:
	for d in get_tree().get_nodes_in_group("doors"):
		var dn := d as Node3D
		if dn.is_open and dn.base_pos.distance_to(global_position) <= 3.5:
			return d
	return null

# Calls a door method locally in singleplayer or via RPC in multiplayer.
func _door_call(door: Node, method: String) -> void:
	if multiplayer.has_multiplayer_peer():
		door.rpc(method)
	else:
		door.call(method)

func _update_interact_prompt() -> void:
	interact_prompt.visible = false

	# Open doors have no collision — check proximity first.
	var open_door := _find_nearby_open_door()
	if open_door != null:
		interact_prompt.visible = true
		interact_prompt.text    = "[E] Close door"
		return

	if not ray.is_colliding():
		return
	var collider := ray.get_collider()

	var door := _find_in_group(collider, "doors")
	if door != null and global_position.distance_to(door.base_pos) <= INTERACT_RANGE:
		interact_prompt.visible = true
		if door.lock_code == "":
			interact_prompt.text = "[E] Open door"
		else:
			interact_prompt.text = "[E] Enter code to unlock"
		return

	var doorway := _get_doorway(collider)
	if doorway != null and global_position.distance_to(doorway.global_position) <= INTERACT_RANGE:
		if not _doorway_has_door(doorway):
			interact_prompt.visible = true
			interact_prompt.text = "[E] Install door" if hotbar.get_resource_count("door") > 0 else "[E] Install door  (craft a door first)"
		return

	var chest := _find_in_group(collider, "loot_chests")
	if chest != null:
		interact_prompt.visible = true
		interact_prompt.text = "[E] Open chest"

func _find_in_group(target, group: String) -> Node:
	if target == null:
		return null
	if not (target is Node):
		return null
	var n : Node = target
	if n.is_in_group(group):
		return n
	var p := n.get_parent()
	if p != null and p.is_in_group(group):
		return p
	return null

func _pretty_name(id: String) -> String:
	if id == "stone": return "stone"
	if id == "metal": return "metal ore"
	if id == "wood":  return "wood"
	if id == "ammo":  return "ammo"
	if id == "door":  return "door"
	if id == "light": return "light"
	return id

func _show_pickup(text: String) -> void:
	if not is_local():
		return
	pickup_label.text = text
	pickup_label.visible = true
	_pickup_clear_t = 1.8

# ── Keypad callbacks ────────────────────────────────────────────────────────

func _on_keypad_confirmed(code: String) -> void:
	if _is_setting_code:
		if _pending_doorway != null and is_instance_valid(_pending_doorway):
			if hotbar.consume_resource("door", 1):
				_place_door_with_code(_pending_doorway, code)
				_show_pickup("Door installed — code set")
			else:
				_show_pickup("No door in inventory")
		_pending_doorway = null
		_keypad_door     = null
		_restore_mouse_from_keypad()
		return

	# Entering code to unlock.
	if _keypad_door == null or not is_instance_valid(_keypad_door):
		_keypad_door = null
		_restore_mouse_from_keypad()
		return
	if code == _keypad_door.lock_code:
		_door_call(_keypad_door, "open_door")
		_show_pickup("Unlocked")
		_keypad_door = null
		_restore_mouse_from_keypad()
	else:
		_keypad_ui.show_wrong_code()

func _on_keypad_cancelled() -> void:
	_pending_doorway = null
	_keypad_door     = null
	_restore_mouse_from_keypad()

func _restore_mouse_from_keypad() -> void:
	if _no_overlay_open():
		Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)

# ── Pause callbacks ────────────────────────────────────────────────────────

func _on_sens_changed(v: float) -> void:
	_mouse_sens_mult = v

func _on_pause_resumed() -> void:
	pass
