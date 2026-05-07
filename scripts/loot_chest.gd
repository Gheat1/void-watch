extends StaticBody3D
class_name LootChest

## Static container.  Player presses E (interact) to grab everything inside —
## the chest then disappears.  The `loot` dictionary is keyed by resource id
## (e.g. "stone", "metal", "ammo") and the value is the integer amount.

@export var loot : Dictionary = {}

var _opened : bool = false

func _ready() -> void:
	add_to_group("loot_chests")
	collision_layer = 1
	collision_mask  = 0

# Returns the loot dictionary; the chest is consumed afterward.
func open() -> Dictionary:
	if _opened:
		return {}
	_opened = true
	var contents := loot.duplicate()
	queue_free()
	return contents
