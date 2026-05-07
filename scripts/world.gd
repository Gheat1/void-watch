extends Node3D

const SAVE_PATH      := "user://world_save.json"
# 1 m heightmap cell spacing — visual mesh and HeightMapShape3D align exactly.
const MAP_SIZE       := 512
const TERRAIN_SUBDIV := 256
const SPAWN_CLEAR_R  := 14.0

const MONUMENT_COUNT          := 12
const MONUMENT_MIN_FROM_SPAWN := 60.0
const MONUMENT_MIN_APART      := 65.0

# Preloaded scripts/scenes used by procedural spawn helpers.
const MineralNodeScript := preload("res://scripts/mineral_node.gd")
const LootChestScene    := preload("res://scenes/entities/loot_chest.tscn")
const GuardScene        := preload("res://scenes/entities/guard.tscn")

var terrain_seed  : int  = 0
var _world_built  : bool = false

var _building_pieces : Array[Node3D] = []
var _noise_big       : FastNoiseLite        # mountain-scale features
var _noise_detail    : FastNoiseLite        # surface micro-bumps
var _craters         : Array[Dictionary] = []

func _ready() -> void:
	add_to_group("world")
	if not multiplayer.has_multiplayer_peer() or multiplayer.is_server():
		# Singleplayer or host: pick the seed, build, then push it to any clients that join later.
		terrain_seed = randi()
		_build_world()
		if multiplayer.has_multiplayer_peer():
			multiplayer.peer_connected.connect(_on_peer_connected)
	# Clients do nothing here — they wait for sync_seed() RPC from the server.

func _on_peer_connected(peer_id: int) -> void:
	rpc_id(peer_id, "sync_seed", terrain_seed)

@rpc("authority", "call_remote", "reliable")
func sync_seed(seed: int) -> void:
	terrain_seed = seed
	_build_world()

func _build_world() -> void:
	if _world_built:
		return
	_world_built = true
	print("[World] Seed: %d" % terrain_seed)
	_init_noise()
	_init_craters()
	_build_terrain()
	_scatter_rocks()
	_scatter_mineral_nodes()
	_spawn_monuments()
	_position_player_on_surface.call_deferred()

# ── Procedural data ──────────────────────────────────────────────────────────

func _init_noise() -> void:
	_noise_big              = FastNoiseLite.new()
	_noise_big.seed          = terrain_seed
	_noise_big.noise_type    = FastNoiseLite.TYPE_SIMPLEX
	_noise_big.frequency     = 0.0055
	_noise_big.fractal_type  = FastNoiseLite.FRACTAL_FBM
	_noise_big.fractal_octaves = 4
	_noise_big.fractal_lacunarity = 2.10
	_noise_big.fractal_gain   = 0.55

	_noise_detail              = FastNoiseLite.new()
	_noise_detail.seed          = terrain_seed + 101
	_noise_detail.noise_type    = FastNoiseLite.TYPE_SIMPLEX
	_noise_detail.frequency     = 0.045
	_noise_detail.fractal_type  = FastNoiseLite.FRACTAL_FBM
	_noise_detail.fractal_octaves = 2
	_noise_detail.fractal_gain  = 0.5

func _init_craters() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = terrain_seed + 7
	_craters.clear()
	# A handful of dramatic, deep craters
	for _i in 6:
		var pos := _rand_crater_pos(rng, 26.0)
		_craters.append({
			"pos":    pos,
			"radius": rng.randf_range(22.0, 36.0),
			"depth":  rng.randf_range(7.0, 12.0),
		})
	# Medium craters
	for _i in 20:
		var pos := _rand_crater_pos(rng, 10.0)
		_craters.append({
			"pos":    pos,
			"radius": rng.randf_range(9.0, 18.0),
			"depth":  rng.randf_range(2.5, 5.5),
		})
	# Lots of pock-marks
	for _i in 100:
		var pos := _rand_crater_pos(rng, 3.0)
		_craters.append({
			"pos":    pos,
			"radius": rng.randf_range(2.0, 5.5),
			"depth":  rng.randf_range(0.4, 1.4),
		})

func _rand_crater_pos(rng: RandomNumberGenerator, min_radius: float) -> Vector2:
	for _try in 32:
		var x := rng.randf_range(-MAP_SIZE * 0.5, MAP_SIZE * 0.5)
		var z := rng.randf_range(-MAP_SIZE * 0.5, MAP_SIZE * 0.5)
		if Vector2(x, z).length() > SPAWN_CLEAR_R + min_radius:
			return Vector2(x, z)
	return Vector2(MAP_SIZE * 0.4, MAP_SIZE * 0.4)

# Public terrain-height query — used by rocks, monuments, and player spawn.
func get_terrain_height(x: float, z: float) -> float:
	# Big rolling mountains/valleys (~±7 m)
	var h := _noise_big.get_noise_2d(x, z) * 7.0
	# Surface micro-detail (~±0.6 m)
	h += _noise_detail.get_noise_2d(x, z) * 0.6
	# Apply craters
	for c in _craters:
		var d := Vector2(x - c["pos"].x, z - c["pos"].y).length()
		var r : float = c["radius"]
		if d > r * 1.18:
			continue
		var depth : float = c["depth"]
		if d < r * 0.85:
			var t := d / (r * 0.85)
			h -= depth * (1.0 - t * t)
		else:
			var t := (d - r * 0.85) / (r * 0.33)
			h += depth * 0.30 * sin(t * PI)
	# Damp height near spawn so monuments / player land flat
	var spawn_d := Vector2(x, z).length()
	if spawn_d < SPAWN_CLEAR_R:
		var k := spawn_d / SPAWN_CLEAR_R
		h *= k * k
	return h

# ── Terrain mesh + heightmap collision ───────────────────────────────────────

func _build_terrain() -> void:
	var step := float(MAP_SIZE) / float(TERRAIN_SUBDIV)
	var w := TERRAIN_SUBDIV + 1

	var heights := PackedFloat32Array()
	heights.resize(w * w)
	for z in range(w):
		for x in range(w):
			var px := -float(MAP_SIZE) * 0.5 + x * step
			var pz := -float(MAP_SIZE) * 0.5 + z * step
			heights[z * w + x] = get_terrain_height(px, pz)

	var verts := PackedVector3Array()
	var uvs   := PackedVector2Array()
	verts.resize(w * w)
	uvs.resize(w * w)
	for z in range(w):
		for x in range(w):
			var px := -float(MAP_SIZE) * 0.5 + x * step
			var pz := -float(MAP_SIZE) * 0.5 + z * step
			var i := z * w + x
			verts[i] = Vector3(px, heights[i], pz)
			uvs[i]   = Vector2(float(x) / TERRAIN_SUBDIV, float(z) / TERRAIN_SUBDIV)

	var indices := PackedInt32Array()
	indices.resize(TERRAIN_SUBDIV * TERRAIN_SUBDIV * 6)
	var idx := 0
	for z in range(TERRAIN_SUBDIV):
		for x in range(TERRAIN_SUBDIV):
			var i := z * w + x
			var i_right := i + 1
			var i_down  := i + w
			var i_diag  := i_down + 1
			indices[idx + 0] = i
			indices[idx + 1] = i_down
			indices[idx + 2] = i_right
			indices[idx + 3] = i_right
			indices[idx + 4] = i_down
			indices[idx + 5] = i_diag
			idx += 6

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX]  = indices

	var raw := ArrayMesh.new()
	raw.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)

	var st := SurfaceTool.new()
	st.create_from(raw, 0)
	st.generate_normals()
	var final_mesh := st.commit()

	var mi := MeshInstance3D.new()
	mi.name = "TerrainMesh"
	mi.mesh = final_mesh
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.62, 0.59, 0.54)
	mat.roughness    = 1.0
	mat.metallic     = 0.0
	mat.cull_mode    = BaseMaterial3D.CULL_DISABLED
	mi.set_surface_override_material(0, mat)
	mi.custom_aabb   = AABB(Vector3(-MAP_SIZE * 0.5, -100.0, -MAP_SIZE * 0.5),
							Vector3(MAP_SIZE, 200.0, MAP_SIZE))
	add_child(mi)

	var hmap := HeightMapShape3D.new()
	hmap.map_width = w
	hmap.map_depth = w
	hmap.map_data  = heights

	var body := StaticBody3D.new()
	body.name = "TerrainBody"
	body.scale = Vector3(step, 1.0, step)
	body.collision_layer = 1
	body.collision_mask  = 0
	var col := CollisionShape3D.new()
	col.shape = hmap
	body.add_child(col)
	add_child(body)

# ── Rock scatter ─────────────────────────────────────────────────────────────

func _scatter_rocks() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = terrain_seed + 19
	var count := 220
	for _i in count:
		var px := rng.randf_range(-MAP_SIZE * 0.5, MAP_SIZE * 0.5)
		var pz := rng.randf_range(-MAP_SIZE * 0.5, MAP_SIZE * 0.5)
		if Vector2(px, pz).length() < 9.0:
			continue
		var ground_y := get_terrain_height(px, pz)

		var use_box := rng.randf() > 0.55
		var body := StaticBody3D.new()
		body.collision_layer = 1
		body.collision_mask  = 0

		var mi  := MeshInstance3D.new()
		var col := CollisionShape3D.new()

		if use_box:
			var rx := rng.randf_range(0.5, 2.4)
			var ry := rng.randf_range(0.4, 1.6)
			var rz := rng.randf_range(0.5, 2.4)
			var bm := BoxMesh.new()
			bm.size  = Vector3(rx, ry, rz)
			mi.mesh  = bm
			var bs := BoxShape3D.new()
			bs.size  = bm.size
			col.shape = bs
			body.position = Vector3(px, ground_y + ry * 0.35, pz)
		else:
			var rad := rng.randf_range(0.4, 1.4)
			var sm := SphereMesh.new()
			sm.radius = rad
			sm.height = rad * 2.0
			mi.mesh = sm
			var ss := SphereShape3D.new()
			ss.radius = rad
			col.shape = ss
			body.position = Vector3(px, ground_y + rad * 0.65, pz)

		body.rotation_degrees.y = rng.randf_range(0.0, 360.0)

		var rock_mat := StandardMaterial3D.new()
		var g := rng.randf_range(0.30, 0.58)
		rock_mat.albedo_color = Color(g, g * 0.97, g * 0.93)
		rock_mat.roughness    = 1.0
		mi.set_surface_override_material(0, rock_mat)

		body.add_child(col)
		body.add_child(mi)
		add_child(body)

# ── Mineral nodes (mined with the pickaxe) ──────────────────────────────────

func _scatter_mineral_nodes() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = terrain_seed + 47
	# Stone nodes — common, scattered across the map
	for _i in 72:
		var px := rng.randf_range(-MAP_SIZE * 0.48, MAP_SIZE * 0.48)
		var pz := rng.randf_range(-MAP_SIZE * 0.48, MAP_SIZE * 0.48)
		if Vector2(px, pz).length() < 12.0:
			continue
		_spawn_stone_node(px, pz, rng)
	# Metal ore nodes — rarer, often near monuments
	for _i in 28:
		var px := rng.randf_range(-MAP_SIZE * 0.48, MAP_SIZE * 0.48)
		var pz := rng.randf_range(-MAP_SIZE * 0.48, MAP_SIZE * 0.48)
		if Vector2(px, pz).length() < 18.0:
			continue
		_spawn_metal_node(px, pz, rng)

func _spawn_stone_node(px: float, pz: float, rng: RandomNumberGenerator) -> void:
	var ground_y := get_terrain_height(px, pz)
	var node := StaticBody3D.new()
	node.set_script(MineralNodeScript)
	node.set("resource_id", "stone")
	node.set("per_hit", 1)
	node.set("bonus_drop", 4)
	node.set("max_health", 28.0)

	# Cluster of 3 boxes for that "pile of rock" look
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.50, 0.49, 0.46)
	mat.roughness    = 1.0
	for i in 3:
		var bm := BoxMesh.new()
		var sx := rng.randf_range(0.6, 1.4)
		var sy := rng.randf_range(0.5, 1.0)
		var sz := rng.randf_range(0.6, 1.4)
		bm.size = Vector3(sx, sy, sz)
		var mi := MeshInstance3D.new()
		mi.mesh = bm
		mi.position = Vector3(rng.randf_range(-0.6, 0.6),
							  sy * 0.5 + rng.randf_range(-0.05, 0.05),
							  rng.randf_range(-0.6, 0.6))
		mi.rotation.y = rng.randf_range(0.0, TAU)
		mi.set_surface_override_material(0, mat)
		node.add_child(mi)

	var col := CollisionShape3D.new()
	var bs := BoxShape3D.new()
	bs.size = Vector3(2.4, 1.6, 2.4)
	col.shape = bs
	col.position = Vector3(0, 0.8, 0)
	node.add_child(col)

	add_child(node)
	node.global_position = Vector3(px, ground_y, pz)

func _spawn_metal_node(px: float, pz: float, rng: RandomNumberGenerator) -> void:
	var ground_y := get_terrain_height(px, pz)
	var node := StaticBody3D.new()
	node.set_script(MineralNodeScript)
	node.set("resource_id", "metal")
	node.set("per_hit", 1)
	node.set("bonus_drop", 5)
	node.set("max_health", 50.0)

	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.42, 0.45, 0.50)
	mat.metallic     = 0.55
	mat.roughness    = 0.40

	var emit := StandardMaterial3D.new()
	emit.albedo_color              = Color(0.65, 0.55, 0.30)
	emit.emission_enabled          = true
	emit.emission                  = Color(0.95, 0.55, 0.18)
	emit.emission_energy_multiplier = 1.5
	emit.shading_mode              = BaseMaterial3D.SHADING_MODE_PER_PIXEL

	# A jagged metal cluster — 4 angled boxes
	for i in 4:
		var bm := BoxMesh.new()
		bm.size = Vector3(rng.randf_range(0.45, 0.85),
						  rng.randf_range(0.6, 1.4),
						  rng.randf_range(0.45, 0.85))
		var mi := MeshInstance3D.new()
		mi.mesh = bm
		mi.position = Vector3(rng.randf_range(-0.55, 0.55),
							  bm.size.y * 0.5,
							  rng.randf_range(-0.55, 0.55))
		mi.rotation = Vector3(
			deg_to_rad(rng.randf_range(-15.0, 15.0)),
			rng.randf_range(0.0, TAU),
			deg_to_rad(rng.randf_range(-15.0, 15.0)),
		)
		mi.set_surface_override_material(0, mat if i % 2 == 0 else emit)
		node.add_child(mi)

	var col := CollisionShape3D.new()
	var bs := BoxShape3D.new()
	bs.size = Vector3(2.0, 1.8, 2.0)
	col.shape = bs
	col.position = Vector3(0, 0.9, 0)
	node.add_child(col)

	add_child(node)
	node.global_position = Vector3(px, ground_y, pz)

# ── Monuments ────────────────────────────────────────────────────────────────

func _spawn_monuments() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = terrain_seed + 31
	var placed : Array[Vector2] = []
	var attempts := 0
	while placed.size() < MONUMENT_COUNT and attempts < 200:
		attempts += 1
		var px := rng.randf_range(-MAP_SIZE * 0.42, MAP_SIZE * 0.42)
		var pz := rng.randf_range(-MAP_SIZE * 0.42, MAP_SIZE * 0.42)
		if Vector2(px, pz).length() < MONUMENT_MIN_FROM_SPAWN:
			continue
		var ok := true
		for q in placed:
			if Vector2(px - q.x, pz - q.y).length() < MONUMENT_MIN_APART:
				ok = false
				break
		if not ok:
			continue
		var ground_y := get_terrain_height(px, pz)
		var kind := rng.randi() % 3
		var monument: Node3D
		match kind:
			0: monument = _build_colony_dome(rng)
			1: monument = _build_comm_tower(rng)
			_: monument = _build_crashed_lander(rng)
		add_child(monument)
		monument.global_position = Vector3(px, ground_y, pz)
		monument.rotation.y = rng.randf_range(0.0, TAU)

		# Drop a loot chest and 1–2 guards near each monument
		_spawn_loot_chest_near(Vector3(px, ground_y, pz), rng)
		var guard_count := 1 + (rng.randi() % 2)   # 1 or 2 guards
		for g in guard_count:
			_spawn_guard_near(Vector3(px, ground_y, pz), rng)

		placed.append(Vector2(px, pz))

func _spawn_loot_chest_near(centre: Vector3, rng: RandomNumberGenerator) -> void:
	var ang := rng.randf_range(0.0, TAU)
	var r   := rng.randf_range(8.0, 14.0)
	var px  := centre.x + cos(ang) * r
	var pz  := centre.z + sin(ang) * r
	var chest : Node3D = LootChestScene.instantiate()
	chest.set("loot", _roll_loot(rng))
	add_child(chest)
	chest.global_position = Vector3(px, get_terrain_height(px, pz), pz)
	chest.rotation.y = rng.randf_range(0.0, TAU)

func _roll_loot(rng: RandomNumberGenerator) -> Dictionary:
	# Random mix: always some stone, often metal, sometimes ammo bonus
	var loot : Dictionary = {
		"stone": rng.randi_range(20, 60),
		"metal": rng.randi_range(10, 30),
	}
	if rng.randf() < 0.7:
		loot["ammo"] = rng.randi_range(15, 45)
	if rng.randf() < 0.4:
		loot["wood"] = rng.randi_range(10, 25)
	return loot

func _spawn_guard_near(centre: Vector3, rng: RandomNumberGenerator) -> void:
	var ang := rng.randf_range(0.0, TAU)
	var r   := rng.randf_range(5.0, 11.0)
	var px  := centre.x + cos(ang) * r
	var pz  := centre.z + sin(ang) * r
	var guard : Node3D = GuardScene.instantiate()
	add_child(guard)
	guard.global_position = Vector3(px, get_terrain_height(px, pz), pz)
	guard.rotation.y = rng.randf_range(0.0, TAU)

func _make_metal_mat(base: Color, metallic: float, rough: float, emission := Color(0,0,0,0)) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = base
	m.metallic     = metallic
	m.roughness    = rough
	if emission.a > 0.0:
		m.emission_enabled = true
		m.emission = Color(emission.r, emission.g, emission.b, 1.0)
		m.emission_energy_multiplier = emission.a   # repurpose alpha as intensity
	return m

func _add_mesh(parent: Node3D, mesh: Mesh, pos: Vector3, mat: Material,
		rot_deg := Vector3.ZERO) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.position = pos
	mi.rotation_degrees = rot_deg
	mi.set_surface_override_material(0, mat)
	parent.add_child(mi)
	return mi

# Colony dome — short cylinder base + sphere on top + antenna + habitat module
func _build_colony_dome(_rng: RandomNumberGenerator) -> Node3D:
	var root := StaticBody3D.new()
	root.name = "ColonyDome"
	root.collision_layer = 1
	root.collision_mask  = 0

	var hull := _make_metal_mat(Color(0.62, 0.65, 0.70), 0.55, 0.45)
	var trim := _make_metal_mat(Color(0.30, 0.32, 0.36), 0.65, 0.40)
	var glow := _make_metal_mat(Color(0.38, 0.55, 0.78), 0.20, 0.25,
								Color(0.30, 0.55, 0.95, 1.6))

	# Cylindrical base
	var base := CylinderMesh.new()
	base.height          = 3.0
	base.top_radius      = 6.0
	base.bottom_radius   = 6.4
	base.radial_segments = 16
	_add_mesh(root, base, Vector3(0, 1.5, 0), hull)

	# Trim ring at base top
	var ring := CylinderMesh.new()
	ring.height          = 0.4
	ring.top_radius      = 6.2
	ring.bottom_radius   = 6.2
	ring.radial_segments = 16
	_add_mesh(root, ring, Vector3(0, 3.2, 0), trim)

	# Dome (sphere with bottom partially buried in base)
	var dome := SphereMesh.new()
	dome.radius          = 5.6
	dome.height          = 11.2
	dome.radial_segments = 20
	dome.rings           = 12
	_add_mesh(root, dome, Vector3(0, 3.4, 0), hull)

	# Antenna mast
	var mast := CylinderMesh.new()
	mast.height          = 4.0
	mast.top_radius      = 0.05
	mast.bottom_radius   = 0.10
	mast.radial_segments = 6
	_add_mesh(root, mast, Vector3(0, 11.0, 0), trim)

	# Antenna tip — small glowing ball
	var tip := SphereMesh.new()
	tip.radius          = 0.30
	tip.height          = 0.60
	tip.radial_segments = 8
	tip.rings           = 4
	_add_mesh(root, tip, Vector3(0, 13.0, 0), glow)

	# Side habitat module — boxy extension
	var hab := BoxMesh.new()
	hab.size = Vector3(4.5, 2.6, 3.0)
	_add_mesh(root, hab, Vector3(7.5, 1.3, 0), hull)

	# Window strip on the habitat
	var win := BoxMesh.new()
	win.size = Vector3(0.05, 0.7, 2.4)
	_add_mesh(root, win, Vector3(9.78, 1.6, 0), glow)

	# Connecting tube
	var tube := CylinderMesh.new()
	tube.height          = 1.4
	tube.top_radius      = 0.9
	tube.bottom_radius   = 0.9
	tube.radial_segments = 10
	_add_mesh(root, tube, Vector3(5.6, 1.6, 0), hull, Vector3(0, 0, 90))

	# Single broad collision: a slightly oversize cylinder around the dome+base
	var col := CollisionShape3D.new()
	var cs := CylinderShape3D.new()
	cs.height = 8.0
	cs.radius = 6.5
	col.shape = cs
	col.position = Vector3(0, 4.0, 0)
	root.add_child(col)

	# Plus a box for the habitat
	var col2 := CollisionShape3D.new()
	var bs := BoxShape3D.new()
	bs.size = Vector3(4.5, 2.6, 3.0)
	col2.shape = bs
	col2.position = Vector3(7.5, 1.3, 0)
	root.add_child(col2)

	return root

# Communication tower — lattice pillar + dish
func _build_comm_tower(_rng: RandomNumberGenerator) -> Node3D:
	var root := StaticBody3D.new()
	root.name = "CommTower"
	root.collision_layer = 1
	root.collision_mask  = 0

	var hull := _make_metal_mat(Color(0.40, 0.42, 0.46), 0.60, 0.35)
	var warn := _make_metal_mat(Color(0.95, 0.55, 0.18), 0.20, 0.50)
	var glow := _make_metal_mat(Color(0.95, 0.18, 0.18), 0.10, 0.30,
								Color(1.0, 0.30, 0.20, 4.0))

	# Concrete-looking footing
	var foot := BoxMesh.new()
	foot.size = Vector3(4.0, 0.6, 4.0)
	_add_mesh(root, foot, Vector3(0, 0.3, 0),
			  _make_metal_mat(Color(0.60, 0.58, 0.54), 0.10, 0.85))

	# Four lattice legs
	for sx in [-1, 1]:
		for sz in [-1, 1]:
			var leg := BoxMesh.new()
			leg.size = Vector3(0.18, 14.0, 0.18)
			_add_mesh(root, leg, Vector3(sx * 1.4, 7.6, sz * 1.4), hull)

	# Cross-bracing — alternating diagonals at four heights
	for h in [3.0, 6.5, 10.0, 13.0]:
		# X-axis diagonals (connect leg pairs along Z)
		for sx in [-1, 1]:
			var brace := BoxMesh.new()
			brace.size = Vector3(0.10, 0.10, 3.6)
			_add_mesh(root, brace, Vector3(sx * 1.4, h, 0), hull, Vector3(45, 0, 0))
		for sz in [-1, 1]:
			var brace2 := BoxMesh.new()
			brace2.size = Vector3(3.6, 0.10, 0.10)
			_add_mesh(root, brace2, Vector3(0, h, sz * 1.4), hull, Vector3(0, 0, 45))

	# Warning bands near the top
	for h in [11.5, 13.5]:
		for sx in [-1, 1]:
			var band := BoxMesh.new()
			band.size = Vector3(0.30, 0.30, 0.30)
			_add_mesh(root, band, Vector3(sx * 1.4, h, 0), warn)

	# Dish at top
	var dish := SphereMesh.new()
	dish.radius          = 1.8
	dish.height          = 1.8
	dish.radial_segments = 16
	dish.rings           = 8
	_add_mesh(root, dish, Vector3(0, 15.5, 0),
			  _make_metal_mat(Color(0.78, 0.80, 0.82), 0.30, 0.30),
			  Vector3(-30, 0, 0))

	# Aviation light on the apex
	var apex := SphereMesh.new()
	apex.radius          = 0.20
	apex.height          = 0.40
	apex.radial_segments = 6
	apex.rings           = 4
	_add_mesh(root, apex, Vector3(0, 16.5, 0), glow)

	# Collision: a single tall cylinder
	var col := CollisionShape3D.new()
	var cs := CylinderShape3D.new()
	cs.height = 16.0
	cs.radius = 2.2
	col.shape = cs
	col.position = Vector3(0, 8.0, 0)
	root.add_child(col)

	return root

# Crashed lander — tilted capsule + legs + scattered debris
func _build_crashed_lander(rng: RandomNumberGenerator) -> Node3D:
	var root := StaticBody3D.new()
	root.name = "CrashedLander"
	root.collision_layer = 1
	root.collision_mask  = 0

	var hull   := _make_metal_mat(Color(0.55, 0.50, 0.42), 0.55, 0.50)
	var burnt  := _make_metal_mat(Color(0.18, 0.16, 0.14), 0.40, 0.85)
	var glow   := _make_metal_mat(Color(0.95, 0.55, 0.20), 0.05, 0.20,
								Color(1.0, 0.50, 0.15, 3.0))

	# Tilted body — parent a "tilt" Node3D so the whole thing leans without
	# also rotating the collision footprint
	var tilt := Node3D.new()
	tilt.rotation_degrees = Vector3(rng.randf_range(15.0, 32.0),
									rng.randf_range(0.0, 360.0),
									rng.randf_range(-10.0, 10.0))
	tilt.position = Vector3(0, 1.6, 0)
	root.add_child(tilt)

	# Main capsule (cylinder + cone-ish top using a smaller cylinder)
	var cap := CylinderMesh.new()
	cap.height          = 4.6
	cap.top_radius      = 1.5
	cap.bottom_radius   = 1.9
	cap.radial_segments = 14
	_add_mesh(tilt, cap, Vector3(0, 0, 0), hull)

	# Burn scoring around bottom
	var ring := CylinderMesh.new()
	ring.height          = 0.6
	ring.top_radius      = 2.05
	ring.bottom_radius   = 2.10
	ring.radial_segments = 14
	_add_mesh(tilt, ring, Vector3(0, -2.0, 0), burnt)

	# Cap nose
	var nose := SphereMesh.new()
	nose.radius          = 1.5
	nose.height          = 1.8
	nose.radial_segments = 14
	nose.rings           = 8
	_add_mesh(tilt, nose, Vector3(0, 2.4, 0), hull)

	# Hatch with a glow
	var hatch := BoxMesh.new()
	hatch.size = Vector3(1.2, 1.4, 0.10)
	_add_mesh(tilt, hatch, Vector3(0, 0.3, 1.92), burnt)
	var hatch_glow := BoxMesh.new()
	hatch_glow.size = Vector3(0.6, 0.10, 0.06)
	_add_mesh(tilt, hatch_glow, Vector3(0, 0.95, 1.97), glow)

	# Four landing legs splayed out
	for ang in [0.0, 90.0, 180.0, 270.0]:
		var rad := deg_to_rad(ang)
		var dir := Vector3(cos(rad), 0, sin(rad))
		var leg := BoxMesh.new()
		leg.size = Vector3(0.14, 2.4, 0.14)
		_add_mesh(tilt, leg, Vector3(dir.x * 2.0, -1.4, dir.z * 2.0), hull,
				  Vector3(15.0 * dir.z, 0, -15.0 * dir.x))

	# Scattered debris on the ground around it (not parented to tilt)
	for i in 5:
		var ang := rng.randf_range(0.0, TAU)
		var r   := rng.randf_range(2.5, 4.5)
		var d   := BoxMesh.new()
		d.size = Vector3(rng.randf_range(0.4, 1.0),
						 rng.randf_range(0.3, 0.6),
						 rng.randf_range(0.4, 1.0))
		_add_mesh(root, d, Vector3(cos(ang) * r, 0.25, sin(ang) * r), burnt,
				  Vector3(0, rng.randf_range(0.0, 360.0), 0))

	# Collision: simple capsule approximation
	var col := CollisionShape3D.new()
	var cs := CylinderShape3D.new()
	cs.height = 5.5
	cs.radius = 2.4
	col.shape = cs
	col.position = Vector3(0, 2.5, 0)
	root.add_child(col)

	return root

func _position_player_on_surface() -> void:
	var player := get_tree().get_first_node_in_group("player")
	if player:
		player.global_position = Vector3(0.0, get_terrain_height(0.0, 0.0) + 4.0, 0.0)

# ── Building piece management ─────────────────────────────────────────────────

func add_building_piece(piece: Node3D) -> void:
	# Multiplayer: pieces live under Main/BuildingPieces so the
	# MultiplayerSpawner can replicate them. Fall back to the world for
	# anything that calls in directly (singleplayer / loaded saves before
	# the spawner exists).
	var main := get_tree().current_scene
	var pieces := main.get_node_or_null("BuildingPieces") if main else null
	if pieces:
		pieces.add_child(piece, true)
	else:
		add_child(piece)
		_building_pieces.append(piece)

# ── Persistence (F5 = save, F9 = load) ───────────────────────────────────────

func _input(event: InputEvent) -> void:
	if event.is_action_pressed("save_world"):
		save_world()
	elif event.is_action_pressed("load_world"):
		load_world()

func _all_pieces() -> Array:
	# Pieces live under Main/BuildingPieces in multiplayer; legacy/singleplayer
	# pieces may also be parented to the world.
	var out : Array = []
	var main := get_tree().current_scene
	var bp := main.get_node_or_null("BuildingPieces") if main else null
	if bp:
		for c in bp.get_children():
			if is_instance_valid(c):
				out.append(c)
	for p in _building_pieces:
		if is_instance_valid(p) and not out.has(p):
			out.append(p)
	return out

func save_world() -> void:
	# Only the host owns the save file in multiplayer.
	if multiplayer.has_multiplayer_peer() and not multiplayer.is_server():
		print("[World] Save is host-only.")
		return
	var data: Array = []
	for p in _all_pieces():
		data.append({
			"type": p.get_meta("piece_type", "Foundation"),
			"px": p.position.x, "py": p.position.y, "pz": p.position.z,
			"rx": p.rotation.x, "ry": p.rotation.y, "rz": p.rotation.z,
		})
	var fa := FileAccess.open(SAVE_PATH, FileAccess.WRITE)
	fa.store_string(JSON.stringify(data, "\t"))
	fa.close()
	print("[World] Saved %d pieces." % data.size())

func load_world() -> void:
	if multiplayer.has_multiplayer_peer() and not multiplayer.is_server():
		print("[World] Load is host-only.")
		return
	if not FileAccess.file_exists(SAVE_PATH):
		print("[World] No save file at %s" % SAVE_PATH)
		return
	var fa     := FileAccess.open(SAVE_PATH, FileAccess.READ)
	var parsed = JSON.parse_string(fa.get_as_text())
	fa.close()
	if not parsed is Array:
		push_error("[World] Corrupt save file.")
		return
	var loaded := 0
	var main := get_tree().current_scene
	for d in parsed:
		var piece_type := str(d["type"])
		var pos := Vector3(d["px"], d["py"], d["pz"])
		var rot := Vector3(d["rx"], d["ry"], d["rz"])
		# Routing through main.request_place_piece keeps the spawn path
		# consistent (MultiplayerSpawner in MP, direct add in SP).
		if main and main.has_method("request_place_piece"):
			main.request_place_piece(piece_type, pos, rot)
			loaded += 1
	print("[World] Loaded %d pieces." % loaded)
