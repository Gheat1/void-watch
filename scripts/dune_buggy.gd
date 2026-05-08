extends VehicleBody3D

const ENGINE_FORCE := 4000.0
const BRAKE_FORCE  := 80.0
const STEER_MAX    := 0.42
const STEER_SPEED  := 3.5

# Seats: 0=driver (front-left), 1=front-right, 2=rear-left, 3=rear-right
var driver_peer_id : int = -1 :
	set(v):
		driver_peer_id = v
		_update_authority()

var passenger_peer_id  : int = -1
var passenger2_peer_id : int = -1
var passenger3_peer_id : int = -1

var _steer_cur   : float      = 0.0
var _seat_models : Dictionary = {}   # peer_id -> Node3D sitting model

# ── Lifecycle ──────────────────────────────────────────────────────────────

func _ready() -> void:
	add_to_group("vehicles")
	collision_layer = 1
	collision_mask  = 1
	mass = 700.0
	_build_visuals()

func _build_visuals() -> void:
	var body_mat := StandardMaterial3D.new()
	body_mat.albedo_color = Color(0.88, 0.52, 0.10)   # sandy orange
	body_mat.metallic  = 0.10
	body_mat.roughness = 0.72

	var cage_mat := StandardMaterial3D.new()
	cage_mat.albedo_color = Color(0.14, 0.15, 0.17)   # dark steel tube
	cage_mat.metallic  = 0.82
	cage_mat.roughness = 0.26

	var seat_mat := StandardMaterial3D.new()
	seat_mat.albedo_color = Color(0.11, 0.11, 0.14)
	seat_mat.roughness = 0.88

	var wheel_mat := StandardMaterial3D.new()
	wheel_mat.albedo_color = Color(0.07, 0.07, 0.07)
	wheel_mat.roughness = 0.96

	var hub_mat := StandardMaterial3D.new()
	hub_mat.albedo_color = Color(0.36, 0.38, 0.42)
	hub_mat.metallic  = 0.80
	hub_mat.roughness = 0.22

	var headlight_mat := StandardMaterial3D.new()
	headlight_mat.albedo_color             = Color(1.0, 0.98, 0.90)
	headlight_mat.emission_enabled         = true
	headlight_mat.emission                 = Color(1.0, 0.98, 0.90)
	headlight_mat.emission_energy_multiplier = 3.5
	headlight_mat.shading_mode             = BaseMaterial3D.SHADING_MODE_UNSHADED

	var taillight_mat := StandardMaterial3D.new()
	taillight_mat.albedo_color             = Color(0.88, 0.05, 0.04)
	taillight_mat.emission_enabled         = true
	taillight_mat.emission                 = Color(0.88, 0.05, 0.04)
	taillight_mat.emission_energy_multiplier = 2.5
	taillight_mat.shading_mode             = BaseMaterial3D.SHADING_MODE_UNSHADED

	var exhaust_mat := StandardMaterial3D.new()
	exhaust_mat.albedo_color = Color(0.26, 0.24, 0.22)
	exhaust_mat.metallic  = 0.68
	exhaust_mat.roughness = 0.52

	# ── Skid plate (flat bottom, all that a dune buggy has under it) ──────────
	_add_box(Vector3(1.88, 0.08, 5.10), Vector3(0, 0.04, 0.10), cage_mat)

	# ── Front cowl — small fibreglass-style nose, open on top ────────────────
	# Nose face
	_add_box(Vector3(1.82, 0.44, 0.58), Vector3(0, 0.28, -2.20), body_mat)
	# Narrow top lip (no full hood — just an edge)
	_add_box(Vector3(1.82, 0.07, 0.46), Vector3(0, 0.52, -2.09), body_mat)
	# Pair of headlights sits flush in the nose
	#_add_sphere(0.14, Vector3(-0.52, 0.40, -2.56), headlight_mat)
	#_add_sphere(0.10, Vector3(-0.80, 0.40, -2.54), headlight_mat)
	#_add_sphere(0.14, Vector3( 0.52, 0.40, -2.56), headlight_mat)
	#_add_sphere(0.10, Vector3( 0.80, 0.40, -2.54), headlight_mat)

	# ── Rear engine bump (rear-engined dune buggy) ────────────────────────────
	_add_box(Vector3(1.82, 0.55, 0.85), Vector3(0, 0.32, 2.22), body_mat)
	_add_box(Vector3(1.82, 0.07, 0.85), Vector3(0, 0.61, 2.22), body_mat)
	# Cooling vent strip on the rear face
	_add_box(Vector3(1.40, 0.20, 0.05), Vector3(0, 0.38, 2.67), cage_mat)
	# Taillights on rear face
	#_add_sphere(0.11, Vector3(-0.62, 0.48, 2.68), taillight_mat)
	#_add_sphere(0.11, Vector3( 0.62, 0.48, 2.68), taillight_mat)

	# ── Sill tubes (the only structural side members at floor level) ──────────
	_add_box(Vector3(0.09, 0.09, 5.10), Vector3(-0.96, 0.13, 0.10), cage_mat)
	_add_box(Vector3(0.09, 0.09, 5.10), Vector3( 0.96, 0.13, 0.10), cage_mat)

	# ── Front bumper hoop ─────────────────────────────────────────────────────
	#_add_box(Vector3(2.18, 0.09, 0.09), Vector3(0, 0.26, -2.61), cage_mat)
	#_add_box(Vector3(0.09, 0.35, 0.09), Vector3(-0.92, 0.26, -2.61), cage_mat)
	#_add_box(Vector3(0.09, 0.35, 0.09), Vector3( 0.92, 0.26, -2.61), cage_mat)

	# ── Rear skid / bash bar ──────────────────────────────────────────────────
	_add_box(Vector3(2.18, 0.09, 0.09), Vector3(0, 0.26,  2.72), cage_mat)
	#_add_box(Vector3(0.09, 0.35, 0.09), Vector3(-0.92, 0.26, 2.72), cage_mat)
	#_add_box(Vector3(0.09, 0.35, 0.09), Vector3( 0.92, 0.26, 2.72), cage_mat)

	# ── Roll cage ─────────────────────────────────────────────────────────────

	# ── Seats (all four, no body panels around them — fully exposed) ──────────
	_add_seat_mesh(Vector3(-0.42, 0.12, -0.65), seat_mat)
	_add_seat_mesh(Vector3( 0.42, 0.12, -0.65), seat_mat)
	_add_seat_mesh(Vector3(-0.42, 0.12,  0.85), seat_mat)
	_add_seat_mesh(Vector3( 0.42, 0.12,  0.85), seat_mat)

	# ── Steering wheel ────────────────────────────────────────────────────────
	_add_box(Vector3(0.48, 0.05, 0.05), Vector3(-0.42, 0.70, -1.08), cage_mat)
	_add_box(Vector3(0.05, 0.48, 0.05), Vector3(-0.42, 0.70, -1.08), cage_mat)
	_add_box(Vector3(0.05, 0.33, 0.05), Vector3(-0.42, 0.50, -1.00), cage_mat, Vector3(-22, 0, 0))

	# ── Wheel meshes (big knobbly off-road tyres) ─────────────────────────────
	for wname in ["WheelFL", "WheelFR", "WheelRL", "WheelRR"]:
		var w := get_node_or_null(wname)
		if w == null:
			continue
		# Tyre — wide and fat
		var wm := CylinderMesh.new()
		wm.height          = 0.36
		wm.top_radius      = 0.44
		wm.bottom_radius   = 0.44
		wm.radial_segments = 16
		var wmi := MeshInstance3D.new()
		wmi.mesh = wm
		wmi.rotation_degrees = Vector3(0, 0, 90)
		wmi.set_surface_override_material(0, wheel_mat)
		w.add_child(wmi)
		# Rim
		var hm := CylinderMesh.new()
		hm.height          = 0.38
		hm.top_radius      = 0.19
		hm.bottom_radius   = 0.19
		hm.radial_segments = 8
		var hmi := MeshInstance3D.new()
		hmi.mesh = hm
		hmi.rotation_degrees = Vector3(0, 0, 90)
		hmi.set_surface_override_material(0, hub_mat)
		w.add_child(hmi)

func _add_seat_mesh(base: Vector3, mat: Material) -> void:
	_add_box(Vector3(0.50, 0.10, 0.50), base + Vector3(0, 0.30, 0.00), mat)  # cushion
	_add_box(Vector3(0.50, 0.60, 0.07), base + Vector3(0, 0.60, 0.26), mat)  # backrest
	_add_box(Vector3(0.38, 0.20, 0.06), base + Vector3(0, 0.98, 0.26), mat)  # headrest

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

func _add_sphere(radius: float, pos: Vector3, mat: Material) -> void:
	var sm := SphereMesh.new()
	sm.radius          = radius
	sm.height          = radius * 2.0
	sm.radial_segments = 8
	sm.rings           = 5
	var mi := MeshInstance3D.new()
	mi.mesh = sm
	mi.position = pos
	mi.set_surface_override_material(0, mat)
	add_child(mi)

func _add_cylinder(radius: float, height: float, pos: Vector3, rot_deg: Vector3, mat: Material) -> void:
	var cm := CylinderMesh.new()
	cm.top_radius      = radius
	cm.bottom_radius   = radius
	cm.height          = height
	cm.radial_segments = 7
	var mi := MeshInstance3D.new()
	mi.mesh = cm
	mi.position = pos
	if rot_deg != Vector3.ZERO:
		mi.rotation_degrees = rot_deg
	mi.set_surface_override_material(0, mat)
	add_child(mi)

# ── Authority ──────────────────────────────────────────────────────────────

func _update_authority() -> void:
	var auth := driver_peer_id if driver_peer_id > 0 else 1
	set_multiplayer_authority(auth)

# ── Physics ────────────────────────────────────────────────────────────────

func _physics_process(delta: float) -> void:
	_update_occupant_positions()
	if not _is_local_driver():
		return
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
	_steer_cur   = move_toward(_steer_cur, steer_in * STEER_MAX, STEER_SPEED * delta)
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
	_seat_player(driver_peer_id,     $SeatDriver)
	_seat_player(passenger_peer_id,  $SeatPassenger)
	_seat_player(passenger2_peer_id, $SeatRearLeft)
	_seat_player(passenger3_peer_id, $SeatRearRight)

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
	if driver_peer_id != local_id and passenger_peer_id != local_id \
			and passenger2_peer_id != local_id and passenger3_peer_id != local_id:
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
	var packed := load("res://assets/models/VoidPlayerSitting.glb") as PackedScene
	if packed == null:
		return
	var model : Node3D = packed.instantiate()
	model.scale = Vector3(0.423, 0.423, 0.423)
	model.rotation_degrees = Vector3(0, 180, 0)
	var seat_node := _get_seat_node(seat)
	if seat_node:
		seat_node.add_child(model)
	_seat_models[peer_id] = model

func _remove_sitting_model(peer_id: int) -> void:
	if not _seat_models.has(peer_id):
		return
	var model = _seat_models[peer_id]
	if is_instance_valid(model):
		model.queue_free()
	_seat_models.erase(peer_id)

func _get_seat_node(seat: int) -> Node3D:
	match seat:
		0: return $SeatDriver
		1: return $SeatPassenger
		2: return $SeatRearLeft
		3: return $SeatRearRight
	return null

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
		peer = 1
	match seat:
		0:
			if driver_peer_id    != -1: return
		1:
			if passenger_peer_id != -1: return
		2:
			if passenger2_peer_id != -1: return
		3:
			if passenger3_peer_id != -1: return
		_:
			return
	if multiplayer.has_multiplayer_peer():
		rpc("_on_enter", peer, seat)
	else:
		_on_enter(peer, seat)

@rpc("any_peer", "call_local", "reliable")
func _on_enter(peer_id: int, seat: int) -> void:
	match seat:
		0: driver_peer_id     = peer_id
		1: passenger_peer_id  = peer_id
		2: passenger2_peer_id = peer_id
		3: passenger3_peer_id = peer_id
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
	if   driver_peer_id     == peer: seat = 0
	elif passenger_peer_id  == peer: seat = 1
	elif passenger2_peer_id == peer: seat = 2
	elif passenger3_peer_id == peer: seat = 3
	if seat < 0:
		return
	if multiplayer.has_multiplayer_peer():
		rpc("_on_exit", peer, seat)
	else:
		_on_exit(peer, seat)

@rpc("any_peer", "call_local", "reliable")
func _on_exit(peer_id: int, seat: int) -> void:
	match seat:
		0: driver_peer_id     = -1
		1: passenger_peer_id  = -1
		2: passenger2_peer_id = -1
		3: passenger3_peer_id = -1
	_remove_sitting_model(peer_id)
	var p := _get_player(peer_id)
	if p and p.has_method("exit_vehicle"):
		p.exit_vehicle(self)
