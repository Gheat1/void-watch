extends StaticBody3D
class_name MineralNode

## A mineable resource node.  Pickaxe LMB on it calls mine(damage), which
## returns a {"id": String, "amount": int} dictionary for the player to add
## to their inventory.  When health hits zero the node disappears.

@export var resource_id : String = "stone"
@export var per_hit     : int    = 1
@export var bonus_drop  : int    = 3      # extra drop on the killing blow
@export var max_health  : float  = 30.0

var health : float

func _ready() -> void:
	health = max_health
	add_to_group("mineral_nodes")
	collision_layer = 1
	collision_mask  = 0

# Returns {"id": <resource id>, "amount": <int amount this hit>}.
# A miss / depleted node returns amount = 0.
func mine(damage: float) -> Dictionary:
	if health <= 0.0:
		return { "id": resource_id, "amount": 0 }
	health = max(0.0, health - damage)
	var amt := per_hit
	if health == 0.0:
		amt += bonus_drop
		queue_free()
	return { "id": resource_id, "amount": amt }
