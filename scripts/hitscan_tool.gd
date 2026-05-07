extends Node3D

## Standalone weapon/tool script.
## Parent a Node3D with this script under your weapon mount.
## The player (or any controller) calls fire() on primary_attack input.
##
## Scene tree expected:
##   WeaponMount (Node3D) — this script
##     RayCast3D           — forward-facing, length = reach

@export var damage    := 25.0
@export var reach     := 30.0   # must match RayCast3D.target_position.z magnitude
@export var fire_rate := 0.15   # seconds between shots

@onready var ray: RayCast3D = $RayCast3D

var _cooldown := 0.0

func _ready() -> void:
	# Ensure the ray is sized to match reach
	ray.target_position = Vector3(0.0, 0.0, -reach)

func _process(delta: float) -> void:
	_cooldown = max(0.0, _cooldown - delta)

func fire() -> bool:
	if _cooldown > 0.0:
		return false
	_cooldown = fire_rate

	if not ray.is_colliding():
		return false

	_apply_damage(ray.get_collider())
	return true

func _apply_damage(target: Node) -> void:
	# Try the hit collider first, then its parent (component-style Damageable)
	for node: Node in [target, target.get_parent()]:
		if node.has_method("take_damage"):
			node.take_damage(damage)
			return
