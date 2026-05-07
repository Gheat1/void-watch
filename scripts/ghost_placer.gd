extends Node3D

## Shows a semi-transparent preview of the selected building piece.
## Call update_ghost() every physics frame from the player.
## Call try_place() to spawn the real piece into the world.

const REACH := 7.0

# Per-piece config:
#   size       — collision/visual size
#   grid       — snap-grid spacing (4 m for everything: matches a Rust foundation cell)
#   y_off      — Y offset from a top-face hit point to the new piece's centre
#   edge_align — true for walls/doorways: snap on the perpendicular axis at
#                grid+offset so the wall lands on a foundation EDGE, never the
#                centre of a foundation cell
const PIECE_CFG : Dictionary = {
	"Foundation": { "size": Vector3(4.0, 0.25, 4.0), "grid": 4.0, "y_off": 0.125, "edge_align": false },
	"Wall"      : { "size": Vector3(4.0, 3.0,  0.25), "grid": 4.0, "y_off": 1.5,   "edge_align": true  },
	"Doorway"   : { "size": Vector3(4.0, 3.0,  0.25), "grid": 4.0, "y_off": 1.5,   "edge_align": true  },
	"Ceiling"   : { "size": Vector3(4.0, 0.25, 4.0), "grid": 4.0, "y_off": 0.125, "edge_align": false },
	"Window"    : { "size": Vector3(4.0, 3.0,  0.25), "grid": 4.0, "y_off": 1.5,   "edge_align": true  },
	"Light"     : { "size": Vector3(0.5, 0.5,  0.25), "grid": 1.0, "y_off": 0.25,  "edge_align": false },
}

@onready var mesh_inst : MeshInstance3D = $MeshInstance3D

var _piece    : String = ""
var _can_place: bool   = false
var _mat_ok   : StandardMaterial3D
var _mat_bad  : StandardMaterial3D

func _ready() -> void:
	# top_level keeps the ghost in world space, so the player's translation/rotation
	# never feeds back into the ghost transform.
	top_level = true
	_mat_ok  = _ghost_mat(Color(0.2, 0.9, 0.3, 0.45))
	_mat_bad = _ghost_mat(Color(0.9, 0.2, 0.2, 0.45))
	# Default to Foundation so the ghost is meaningful before any menu pick
	set_piece("Foundation")

func _ghost_mat(c: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color       = c
	m.transparency       = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.cull_mode          = BaseMaterial3D.CULL_DISABLED
	m.shading_mode       = BaseMaterial3D.SHADING_MODE_UNSHADED
	return m

# ── Public API ─────────────────────────────────────────────────────────────

func get_piece() -> String:
	return _piece

func set_piece(piece_name: String) -> void:
	_piece = piece_name
	var cfg : Dictionary = PIECE_CFG.get(piece_name, {})
	if cfg.is_empty():
		return
	var box      := BoxMesh.new()
	box.size      = cfg["size"]
	mesh_inst.mesh = box
	mesh_inst.set_surface_override_material(0, _mat_ok)

func rotate_piece() -> void:
	rotation_degrees.y = fmod(rotation_degrees.y + 90.0, 360.0)

func update_ghost(camera: Camera3D, ray: RayCast3D) -> void:
	if _piece.is_empty():
		_set_valid(false)
		return
	var cfg : Dictionary = PIECE_CFG[_piece]

	if ray.is_colliding():
		var pt       := ray.get_collision_point()
		var normal   := ray.get_collision_normal()
		var collider := ray.get_collider()
		global_position = _snap(pt, normal, collider, cfg)
		_set_valid(true)
	else:
		# No surface hit - float in front of the camera, can't place
		global_position = camera.global_position - camera.global_basis.z * REACH
		_set_valid(false)

func try_place() -> bool:
	if not _can_place or _piece.is_empty():
		return false
	var place_pos := global_position
	var place_rot := global_rotation
	# In multiplayer the server is authoritative for building pieces — clients
	# request a place; the server validates, spawns, and the MultiplayerSpawner
	# replicates the new piece to everyone.
	if multiplayer.has_multiplayer_peer():
		var main := get_tree().current_scene
		if main and main.has_method("request_place_piece"):
			main.rpc_id(1, "request_place_piece", _piece, place_pos, place_rot)
			return true
	# Singleplayer fallback: spawn directly into the world.
	var world := get_tree().get_first_node_in_group("world")
	if not world:
		push_warning("GhostPlacer: no node in group 'world' found.")
		return false
	var scene_path := "res://scenes/building/%s.tscn" % _piece.to_lower()
	var packed : PackedScene = load(scene_path)
	if not packed:
		push_warning("GhostPlacer: missing scene at %s" % scene_path)
		return false
	var inst := packed.instantiate()
	world.add_building_piece(inst)
	inst.global_position = place_pos
	inst.global_rotation = place_rot
	return true

# ── Internal ───────────────────────────────────────────────────────────────

func _snap(pt: Vector3, normal: Vector3, collider: Object, cfg: Dictionary) -> Vector3:
	var y_off : float = cfg["y_off"]
	var bias  := normal * 0.02
	var biased_x := pt.x + bias.x
	var biased_z := pt.z + bias.z
	var xz       := _snap_xz(biased_x, biased_z, cfg)

	# Foundation–foundation alignment: when aimed at the side of an existing
	# building piece, lock Y to that piece's Y so adjacent foundations sit
	# at the same level.
	var hit_piece := _hit_building_piece(collider)
	if _piece == "Foundation" and hit_piece and absf(normal.y) < 0.5:
		return Vector3(xz.x, hit_piece.global_position.y, xz.y)

	# Top face: place piece sitting on the hit surface.  pt.y is the actual
	# hit point on the surface, so this works whether the surface is terrain,
	# a foundation, or another wall — the new piece's bottom lines up with
	# the surface regardless of the hit piece's own thickness.
	if normal.y > 0.5:
		return Vector3(xz.x, pt.y + y_off, xz.y)
	elif normal.y < -0.5:
		return Vector3(xz.x, pt.y - y_off, xz.y)
	else:
		# Vertical face — quantise Y so walls placed against a slope still
		# tile cleanly with their neighbours.
		return Vector3(xz.x, snappedf(pt.y, 0.5) + y_off - cfg["size"].y * 0.5, xz.y)

# Picks XZ snap based on whether the piece edge-aligns and the current rotation.
# Walls/doorways at 0°/180° span the X-axis: snap X on the grid, snap Z to the
# grid edge (offset by 2 m) so the wall lands flush with foundation edges.
# Rotated 90°/270°, the axes flip.
func _snap_xz(x: float, z: float, cfg: Dictionary) -> Vector2:
	var grid : float = cfg["grid"]
	if not cfg.get("edge_align", false):
		return Vector2(snappedf(x, grid), snappedf(z, grid))
	var rot_step : int = int(round(rotation_degrees.y / 90.0)) % 2
	# Half-grid offset = wall sitting on the seam between two foundation cells
	var half := grid * 0.5
	if rot_step == 0:
		return Vector2(snappedf(x, grid), snappedf(z - half, grid) + half)
	else:
		return Vector2(snappedf(x - half, grid) + half, snappedf(z, grid))

func _hit_building_piece(collider: Object) -> Node3D:
	if collider == null:
		return null
	if collider is Node and (collider as Node).is_in_group("building_pieces"):
		return collider as Node3D
	# A multi-shape piece (e.g. doorway) raycasts to a child shape — walk up
	if collider is Node:
		var p := (collider as Node).get_parent()
		if p and p is Node3D and p.is_in_group("building_pieces"):
			return p as Node3D
	return null

func _set_valid(valid: bool) -> void:
	_can_place = valid
	if mesh_inst and mesh_inst.mesh:
		mesh_inst.set_surface_override_material(0, _mat_ok if valid else _mat_bad)
