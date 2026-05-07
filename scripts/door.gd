extends StaticBody3D

var is_open    : bool    = false
var lock_code  : String  = ""
var base_pos   : Vector3 = Vector3.ZERO
var _base_rot_y: float   = 0.0

@onready var col: CollisionShape3D = $CollisionShape3D

func _ready() -> void:
	add_to_group("doors")
	collision_layer = 1
	collision_mask  = 0
	# The spawner (and the singleplayer path) both set position before add_child,
	# so global_position is already correct when _ready fires.
	init_placement()

# Records the current world transform as the "closed" reference.
# Called automatically in _ready(); player.gd need not call it again.
func init_placement() -> void:
	base_pos    = global_position
	_base_rot_y = rotation.y

# ── Networked door actions ────────────────────────────────────────────────────

@rpc("any_peer", "call_local", "reliable")
func open_door() -> void:
	if is_open:
		return
	var hinge       := global_position + global_basis.x * (-1.0)
	rotation.y       = _base_rot_y + deg_to_rad(90.0)
	global_position  = hinge + global_basis.x * 1.0
	is_open          = true
	col.disabled     = true

@rpc("any_peer", "call_local", "reliable")
func close_door() -> void:
	if not is_open:
		return
	global_position = base_pos
	rotation.y      = _base_rot_y
	is_open         = false
	col.disabled    = false

