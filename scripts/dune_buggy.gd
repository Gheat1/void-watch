extends VehicleBody3D

const ENGINE_FORCE := 4000.0
const BRAKE_FORCE  := 80.0
const STEER_MAX    := 0.42
const STEER_SPEED  := 3.5

# Seat occupancy — synced via MultiplayerSynchronizer.
# Setter calls _update_authority() so all peers stay in sync.
var driver_peer_id : int = -1 :
	set(v):
		driver_peer_id = v
		_update_authority()

var passenger_peer_id : int = -1

var _steer_cur   : float      = 0.0
var _seat_models : Dictionary = {}   # peer_id -> MeshInstance3D sitting model

# ── Lifecycle ──────────────────────────────────────────────────────────────

func _ready() -> void:
	add_to_group("vehicles")
	collision_layer = 1
	collision_mask  = 1
	mass = 600.0
	_build_visuals()

func _build_visuals() -> void:
	var body_mat := StandardMaterial3D.new()
	body_mat.albedo_color = Color(0.85, 0.52, 0.15)
	body_mat.metallic  = 0.25
	body_mat.roughness = 0.60

	var cage_mat := StandardMaterial3D.new()
	cage_mat.albedo_color = Color(0.22, 0.22, 0.25)
	cage_mat.metallic  = 0.75
	cage_mat.roughness = 0.35

	var seat_mat := StandardMaterial3D.new()
	seat_mat.albedo_color = Color(0.14, 0.14, 0.17)
	seat_mat.roughness = 0.80

	var wheel_mat := StandardMaterial3D.new()
	wheel_mat.albedo_color = Color(0.11, 0.11, 0.11)
	wheel_mat.roughness = 0.90

	var hub_mat := StandardMaterial3D.new()
	hub_mat.albedo_color = Color(0.38, 0.38, 0.42)
	hub_mat.metallic  = 0.70
	hub_mat.roughness = 0.30

	# Chassis pan
	_add_box(Vector3(1.8, 0.18, 3.4), Vector3(0, 0.09, 0), body_mat)
	# Nose plate (front = −Z, matching physics forward)
	_add_box(Vector3(1.6, 0.12, 0.5), Vector3(0, 0.22, -1.85), body_mat)
	# Rear plate
	_add_box(Vector3(1.6, 0.12, 0.5), Vector3(0, 0.22,  1.75), body_mat)

	# Roll-cage uprights sit behind the seats (+Z = rear)
	_add_box(Vector3(0.07, 1.1, 0.07), Vector3(-0.78, 0.75, 0.15), cage_mat)
	_add_box(Vector3(0.07, 1.1, 0.07), Vector3( 0.78, 0.75, 0.15), cage_mat)
	# Hoop cross-bar
	_add_box(Vector3(1.63, 0.07, 0.07), Vector3(0, 1.29, 0.15), cage_mat)
	# Diagonal braces lean toward the rear
	_add_box(Vector3(0.07, 0.88, 0.07), Vector3(-0.78, 0.42, 0.60), cage_mat, Vector3(-28, 0, 0))
	_add_box(Vector3(0.07, 0.88, 0.07), Vector3( 0.78, 0.42, 0.60), cage_mat, Vector3(-28, 0, 0))

	# Driver seat (left) — slightly forward of centre
	_add_box(Vector3(0.52, 0.12, 0.52), Vector3(-0.35, 0.30, -0.20), seat_mat)
	_add_box(Vector3(0.52, 0.55, 0.08), Vector3(-0.35, 0.57,  0.06), seat_mat)
	# Passenger seat (right)
	_add_box(Vector3(0.52, 0.12, 0.52), Vector3( 0.35, 0.30, -0.20), seat_mat)
	_add_box(Vector3(0.52, 0.55, 0.08), Vector3( 0.35, 0.57,  0.06), seat_mat)

	# Front bumper (−Z) and rear bumper (+Z)
	_add_box(Vector3(2.0, 0.10, 0.10), Vector3(0, 0.28, -1.95), cage_mat)
	_add_box(Vector3(2.0, 0.10, 0.10), Vector3(0, 0.28,  1.95), cage_mat)

	# Wheel meshes (attached to the VehicleWheel3D nodes)
	for wname in ["WheelFL", "WheelFR", "WheelRL", "WheelRR"]:
		var w := get_node_or_null(wname)
		if w == null:
			continue
		var wm := CylinderMesh.new()
		wm.height = 0.24
		wm.top_radius    = 0.38
		wm.bottom_radius = 0.38
		wm.radial_segments = 12
		var wmi := MeshInstance3D.new()
		wmi.mesh = wm
		wmi.rotation_degrees = Vector3(0, 0, 90)
		wmi.set_surface_override_material(0, wheel_mat)
		w.add_child(wmi)

		var hm := CylinderMesh.new()
		hm.height = 0.26
		hm.top_radius    = 0.14
		hm.bottom_radius = 0.14
		hm.radial_segments = 8
		var hmi := MeshInstance3D.new()
		hmi.mesh = hm
		hmi.rotation_degrees = Vector3(0, 0, 90)
		hmi.set_surface_override_material(0, hub_mat)
		w.add_child(hmi)

func _add_box(size: Vector3, pos: Vector3, mat: Material, rot_deg := Vector3.ZERO) -> void:
	var bm := BoxMesh.new()
	bm.size = size
	var mi := MeshInstance3D.new()
	mi.mesh = bm
	mi.position = pos
	if rot_deg != Vector3.ZERO:
		mi.rotation_degrees = rot_deg
	mi.set_surface_override_material(0, mat)
	add_child(mi)

# ── Authority ──────────────────────────────────────────────────────────────

func _update_authority() -> void:
	# Driver owns physics; nobody driving → server owns.
	var auth := driver_peer_id if driver_peer_id > 0 else 1
	set_multiplayer_authority(auth)

# ── Physics ────────────────────────────────────────────────────────────────

func _physics_process(delta: float) -> void:
	_update_occupant_positions()
	if not _is_local_driver():
		return
	# Arrow keys: up = forward, down = reverse, left/right = steer.
	var throttle := 0.0
	if Input.is_action_pressed("ui_up"):
		throttle = -1.0
	elif Input.is_action_pressed("ui_down"):
		throttle =  1.0
	var steer_in := 0.0
	if Input.is_action_pressed("ui_left"):
		steer_in =  1.0
	elif Input.is_action_pressed("ui_right"):
		steer_in = -1.0
	_steer_cur = move_toward(_steer_cur, steer_in * STEER_MAX, STEER_SPEED * delta)
	steering     = _steer_cur
	engine_force = throttle * ENGINE_FORCE
	brake        = 0.0

func _is_local_driver() -> bool:
	if driver_peer_id <= 0:
		return false
	if not multiplayer.has_multiplayer_peer():
		return driver_peer_id == 1
	return driver_peer_id == multiplayer.get_unique_id()

func _update_occupant_positions() -> void:
	_seat_player(driver_peer_id,    $SeatDriver)
	_seat_player(passenger_peer_id, $SeatPassenger)

func _seat_player(peer_id: int, seat: Node3D) -> void:
	if peer_id <= 0:
		return
	var p := _get_player(peer_id)
	if p:
		p.global_position = seat.global_position

func _get_player(peer_id: int) -> Node3D:
	for pl in get_tree().get_nodes_in_group("player"):
		if (pl as Node).get_multiplayer_authority() == peer_id:
			return pl as Node3D
	return null

# ── Camera / mouse look ────────────────────────────────────────────────────

func _input(event: InputEvent) -> void:
	var local_id := multiplayer.get_unique_id() if multiplayer.has_multiplayer_peer() else 1
	if driver_peer_id != local_id and passenger_peer_id != local_id:
		return
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		$CameraPivot.rotate_y(-event.relative.x * 0.002)
		$CameraPivot.rotation.x = clampf(
			$CameraPivot.rotation.x - event.relative.y * 0.002,
			deg_to_rad(-25.0), deg_to_rad(20.0)
		)

# ── Sitting model helpers ─────────────────────────────────────────────────

func _add_sitting_model(peer_id: int, seat: int) -> void:
	if _seat_models.has(peer_id):
		return
	var packed := load("res://VoidPlayerSitting.glb") as PackedScene
	if packed == null:
		return
	var model : Node3D = packed.instantiate()
	# Match the scale and facing used by the standing player body.
	model.scale = Vector3(0.423, 0.423, 0.423)
	model.rotation_degrees = Vector3(0, 180, 0)
	var seat_node : Node3D = $SeatDriver if seat == 0 else $SeatPassenger
	seat_node.add_child(model)
	_seat_models[peer_id] = model

func _remove_sitting_model(peer_id: int) -> void:
	if not _seat_models.has(peer_id):
		return
	var model = _seat_models[peer_id]
	if is_instance_valid(model):
		model.queue_free()
	_seat_models.erase(peer_id)

# ── Flip / unstuck ────────────────────────────────────────────────────────

func flip_upright() -> void:
	linear_velocity  = Vector3.ZERO
	angular_velocity = Vector3.ZERO
	global_transform.basis = Basis(Vector3.UP, global_rotation.y)
	global_position.y += 1.2

# ── Enter vehicle (server-authoritative) ──────────────────────────────────

@rpc("any_peer", "reliable")
func request_enter(seat: int) -> void:
	if multiplayer.has_multiplayer_peer() and not multiplayer.is_server():
		return
	var peer := multiplayer.get_remote_sender_id()
	if peer == 0:
		peer = 1   # host calling directly or singleplayer
	# Validate seat is free before confirming.
	if seat == 0 and driver_peer_id != -1:
		return
	if seat == 1 and passenger_peer_id != -1:
		return
	if seat != 0 and seat != 1:
		return
	# _on_enter sets driver/passenger_peer_id on ALL peers via RPC,
	# so every client gets the update at the same time — no sync delay.
	if multiplayer.has_multiplayer_peer():
		rpc("_on_enter", peer, seat)
	else:
		_on_enter(peer, seat)

@rpc("any_peer", "call_local", "reliable")
func _on_enter(peer_id: int, seat: int) -> void:
	if seat == 0:
		driver_peer_id = peer_id
	else:
		passenger_peer_id = peer_id
	_add_sitting_model(peer_id, seat)
	var p := _get_player(peer_id)
	if p and p.has_method("enter_vehicle"):
		p.enter_vehicle(self, seat)

# ── Exit vehicle (server-authoritative) ───────────────────────────────────

@rpc("any_peer", "reliable")
func request_exit() -> void:
	if multiplayer.has_multiplayer_peer() and not multiplayer.is_server():
		return
	var peer := multiplayer.get_remote_sender_id()
	if peer == 0:
		peer = 1
	var seat := -1
	if driver_peer_id == peer:
		seat = 0
	elif passenger_peer_id == peer:
		seat = 1
	if seat < 0:
		return
	if multiplayer.has_multiplayer_peer():
		rpc("_on_exit", peer, seat)
	else:
		_on_exit(peer, seat)

@rpc("any_peer", "call_local", "reliable")
func _on_exit(peer_id: int, seat: int) -> void:
	if seat == 0:
		driver_peer_id = -1
	else:
		passenger_peer_id = -1
	_remove_sitting_model(peer_id)
	var p := _get_player(peer_id)
	if p and p.has_method("exit_vehicle"):
		p.exit_vehicle(self)
