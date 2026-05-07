extends Node3D

## Scene root. Builds the lighting environment, sun, planets, stars, and
## a player-locked "skydome" that holds them all so they appear infinitely
## distant. Also acts as the multiplayer router for building-piece placement.

const BUILDING_SCENES := {
	"Foundation": "res://scenes/building/foundation.tscn",
	"Wall":       "res://scenes/building/wall.tscn",
	"Doorway":    "res://scenes/building/doorway.tscn",
	"Ceiling":    "res://scenes/building/ceiling.tscn",
	"Door":       "res://scenes/building/door.tscn",
	"Window":     "res://scenes/building/window.tscn",
	"Light":      "res://scenes/building/light.tscn",
}

const SUN_DIR     := Vector3(0.55, 0.78, -0.30)   # FROM the sun (sun is at +SUN_DIR)
const SKY_DISTANCE := 6000.0
const STAR_DISTANCE := 5500.0
const STAR_COUNT  := 380

var _skydome: Node3D
var _camera : Camera3D

@onready var building_spawner : MultiplayerSpawner = $BuildingSpawner

func _ready() -> void:
	_setup_atmosphere()
	_setup_sun()
	_setup_skydome()
	# Custom spawn function lets us bundle the placement transform with the
	# spawn packet so each peer instantiates the piece in the correct spot.
	building_spawner.spawn_function = _spawn_building_piece
	# Tell the server we're ready so it can spawn our player. The host calls
	# this locally too; clients RPC the server. If launched offline (e.g.
	# running scenes/main.tscn directly from the editor), spawn locally.
	if Net and Net.is_online:
		Net.rpc_id(1, "notify_ready")
	else:
		_spawn_offline_player.call_deferred()
	_spawn_buggy.call_deferred()

func _spawn_buggy() -> void:
	if get_node_or_null("DuneBuggy") != null:
		return   # already spawned (avoid duplicates on reconnect)
	var packed : PackedScene = load("res://scenes/entities/dune_buggy.tscn")
	if packed == null:
		return
	var buggy : Node3D = packed.instantiate()
	buggy.name = "DuneBuggy"
	add_child(buggy, true)
	# Clients receive the correct position via MultiplayerSynchronizer.
	# Only the host / singleplayer needs to set it, and only they have
	# the terrain noise ready at this point.
	if not multiplayer.has_multiplayer_peer() or multiplayer.is_server():
		var world := get_node_or_null("World")
		var ground_y := 4.0
		if world and world.has_method("get_terrain_height"):
			ground_y = world.get_terrain_height(0.0, 0.0)
		buggy.global_position = Vector3(6.0, ground_y + 2.0, 0.0)

func _spawn_offline_player() -> void:
	var players := get_node_or_null("Players")
	if players == null or players.get_child_count() > 0:
		return
	var p : Node3D = preload("res://scenes/player/player.tscn").instantiate()
	p.name = "1"
	players.add_child(p)
	var world := get_node_or_null("World")
	var y := 4.0
	if world and world.has_method("get_terrain_height"):
		y = world.get_terrain_height(0.0, 0.0) + 4.0
	p.global_position = Vector3(0, y, 0)

# ── Building-piece placement (server-authoritative) ──────────────────────────

@rpc("any_peer", "call_local", "reliable")
func request_place_piece(piece_type: String, pos: Vector3, rot: Vector3) -> void:
	# Only the server processes placements; clients see them via the
	# BuildingSpawner.
	if multiplayer.has_multiplayer_peer() and not multiplayer.is_server():
		return
	var path : String = BUILDING_SCENES.get(piece_type, "")
	if path == "":
		return
	if multiplayer.has_multiplayer_peer():
		building_spawner.spawn({
			"path": path,
			"px": pos.x, "py": pos.y, "pz": pos.z,
			"rx": rot.x, "ry": rot.y, "rz": rot.z,
		})
	else:
		# Singleplayer / offline: just instantiate locally.
		var inst := _spawn_building_piece({
			"path": path,
			"px": pos.x, "py": pos.y, "pz": pos.z,
			"rx": rot.x, "ry": rot.y, "rz": rot.z,
		})
		var pieces := get_node_or_null("BuildingPieces")
		if pieces and inst:
			pieces.add_child(inst)

@rpc("any_peer", "call_local", "reliable")
func request_place_door(pos: Vector3, rot: Vector3, code: String) -> void:
	if multiplayer.has_multiplayer_peer() and not multiplayer.is_server():
		return
	var data := {
		"path": "res://scenes/building/door.tscn",
		"px": pos.x, "py": pos.y, "pz": pos.z,
		"rx": rot.x, "ry": rot.y, "rz": rot.z,
		"lock_code": code,
	}
	if multiplayer.has_multiplayer_peer():
		building_spawner.spawn(data)
	else:
		var inst := _spawn_building_piece(data)
		var pieces := get_node_or_null("BuildingPieces")
		if pieces and inst:
			pieces.add_child(inst)

# Used by both BuildingSpawner.spawn() and the offline fallback above.
func _spawn_building_piece(data) -> Node:
	if not (data is Dictionary):
		return null
	var d : Dictionary = data
	var path : String = str(d.get("path", ""))
	if path == "":
		return null
	var packed : PackedScene = load(path)
	if packed == null:
		return null
	var inst : Node3D = packed.instantiate()
	inst.position = Vector3(d.get("px", 0.0), d.get("py", 0.0), d.get("pz", 0.0))
	inst.rotation = Vector3(d.get("rx", 0.0), d.get("ry", 0.0), d.get("rz", 0.0))
	if d.has("lock_code"):
		inst.set("lock_code", str(d["lock_code"]))
	return inst

func _process(_delta: float) -> void:
	if not _skydome:
		return
	if _camera == null or not is_instance_valid(_camera):
		_camera = _find_camera()
	if _camera:
		_skydome.global_position = _camera.global_position

func _find_camera() -> Camera3D:
	# Pick the LOCAL player (one whose multiplayer authority is our unique id)
	# so the skydome follows the player on this peer rather than a remote one.
	var local_id := 1
	if multiplayer.has_multiplayer_peer():
		local_id = multiplayer.get_unique_id()
	for player in get_tree().get_nodes_in_group("player"):
		if player is Node and player.get_multiplayer_authority() == local_id:
			if player.has_node("Head/Camera3D"):
				return player.get_node("Head/Camera3D") as Camera3D
	# Fallback: any player (singleplayer or before authority is set)
	var any_player := get_tree().get_first_node_in_group("player")
	if any_player and any_player.has_node("Head/Camera3D"):
		return any_player.get_node("Head/Camera3D") as Camera3D
	return null

# ── Atmosphere / sky ─────────────────────────────────────────────────────────

func _setup_atmosphere() -> void:
	var sky_mat := ProceduralSkyMaterial.new()
	# Inky-black sky with a thin twilight along the horizon line
	sky_mat.sky_top_color        = Color(0.005, 0.006, 0.012)
	sky_mat.sky_horizon_color    = Color(0.025, 0.030, 0.045)
	# These two drive the AMBIENT_SOURCE_SKY fill onto terrain. Keep them
	# brighter than space-black but dimmer than daylight so the surface
	# reads playable but still feels lunar.
	sky_mat.ground_horizon_color = Color(0.42, 0.40, 0.36)
	sky_mat.ground_bottom_color  = Color(0.18, 0.16, 0.14)
	sky_mat.sun_angle_max        = 0.5
	sky_mat.sun_curve            = 0.05

	var sky          := Sky.new()
	sky.sky_material  = sky_mat

	var env                   := Environment.new()
	env.background_mode        = Environment.BG_SKY
	env.sky                    = sky
	env.ambient_light_source   = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy   = 0.85
	env.ambient_light_sky_contribution = 1.0
	env.fog_enabled            = false
	env.tonemap_mode           = Environment.TONE_MAPPER_FILMIC
	env.tonemap_exposure       = 1.0

	env.glow_enabled           = true
	env.glow_intensity         = 0.45
	env.glow_bloom             = 0.10
	env.glow_strength          = 0.95

	var we        := WorldEnvironment.new()
	we.environment = env
	add_child(we)

# ── Sun (directional light) ──────────────────────────────────────────────────

func _setup_sun() -> void:
	var sun              := DirectionalLight3D.new()
	sun.name              = "Sun"
	sun.light_color       = Color(1.0, 0.97, 0.93)
	sun.light_energy      = 2.5
	sun.shadow_enabled    = true
	sun.look_at_from_position(Vector3.ZERO, -SUN_DIR.normalized(), Vector3.UP)
	add_child(sun)

# ── Skydome with sun, planets, stars ─────────────────────────────────────────

func _setup_skydome() -> void:
	_skydome = Node3D.new()
	_skydome.name = "Skydome"
	add_child(_skydome)

	# Stars first so big bodies (sun, planets) draw on top of them visually
	_setup_stars(_skydome)

	# Sun mesh
	_add_celestial(
		_skydome,
		"SunVisual",
		SUN_DIR.normalized() * SKY_DISTANCE,
		340.0,
		Color(1.0, 0.96, 0.78),
		Color(1.0, 0.92, 0.70),
		7.0,
	)
	# Earth-like blue planet
	_add_celestial(
		_skydome,
		"PlanetBlue",
		Vector3(-0.45, 0.55, -0.85).normalized() * SKY_DISTANCE,
		520.0,
		Color(0.32, 0.55, 0.78),
		Color(0.10, 0.20, 0.30),
		0.9,
	)
	# Ringed gas giant
	_add_celestial(
		_skydome,
		"PlanetGold",
		Vector3(0.85, 0.30, 0.55).normalized() * SKY_DISTANCE,
		380.0,
		Color(0.78, 0.62, 0.34),
		Color(0.30, 0.20, 0.08),
		0.7,
	)
	# Distant red planet
	_add_celestial(
		_skydome,
		"PlanetRed",
		Vector3(-0.20, 0.40, 0.92).normalized() * SKY_DISTANCE,
		220.0,
		Color(0.62, 0.30, 0.22),
		Color(0.30, 0.10, 0.06),
		0.6,
	)

func _add_celestial(parent: Node3D, n: String, pos: Vector3, radius: float,
		albedo: Color, emission: Color, emission_strength: float) -> void:
	var mi := MeshInstance3D.new()
	mi.name = n
	var sm := SphereMesh.new()
	sm.radius          = radius
	sm.height          = radius * 2.0
	sm.radial_segments = 32
	sm.rings           = 18
	mi.mesh = sm

	var mat := StandardMaterial3D.new()
	mat.albedo_color              = albedo
	mat.emission_enabled          = true
	mat.emission                  = emission
	mat.emission_energy_multiplier = emission_strength
	mat.shading_mode              = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.disable_receive_shadows   = true
	mi.set_surface_override_material(0, mat)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.position = pos
	parent.add_child(mi)

# ── Stars ────────────────────────────────────────────────────────────────────

func _setup_stars(parent: Node3D) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 4242
	var sun_norm := SUN_DIR.normalized()

	# Pre-build a small palette of star materials so 380 instances don't blow
	# up the material count too much.
	var palette : Array = []
	for tint in [
		Color(1.00, 0.97, 0.92),  # warm white
		Color(0.86, 0.90, 1.00),  # blue-white
		Color(1.00, 0.86, 0.66),  # orange
		Color(0.94, 0.92, 0.82),  # neutral
	]:
		var mat := StandardMaterial3D.new()
		mat.albedo_color              = tint
		mat.emission_enabled          = true
		mat.emission                  = tint
		mat.emission_energy_multiplier = 5.5
		mat.shading_mode              = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.disable_receive_shadows   = true
		palette.append(mat)

	var placed := 0
	var attempts := 0
	while placed < STAR_COUNT and attempts < STAR_COUNT * 4:
		attempts += 1
		# Uniform sphere sampling
		var phi   := rng.randf_range(0.0, TAU)
		var costh := rng.randf_range(-0.25, 1.0)   # bias toward upper hemisphere
		var sinth := sqrt(1.0 - costh * costh)
		var dir   := Vector3(sinth * cos(phi), costh, sinth * sin(phi))

		# Skip stars too close to the sun (would be invisible against the glare)
		if dir.dot(sun_norm) > 0.92:
			continue

		var star := MeshInstance3D.new()
		var sm   := SphereMesh.new()
		var rad  := rng.randf_range(2.4, 5.5)
		sm.radius          = rad
		sm.height          = rad * 2.0
		sm.radial_segments = 4
		sm.rings           = 2
		star.mesh = sm
		star.set_surface_override_material(0, palette[rng.randi() % palette.size()])
		star.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		star.position = dir * STAR_DISTANCE
		parent.add_child(star)
		placed += 1
