extends StaticBody3D
class_name BuildingPiece

## Base script for all placeable building pieces.
## Set piece_type in the inspector (matches the key in ghost_placer PIECE_CFG).

@export var piece_type   : String = "Foundation"
@export var max_health   : float  = 200.0

var health: float

func _ready() -> void:
	health = max_health
	add_to_group("building_pieces")
	set_meta("piece_type", piece_type)
	# Layer 1 so the player (mask=1) collides with placed walls/floors/etc.
	# The ghost-placer raycast uses surface normals, not layers, to tell
	# building pieces from terrain — so sharing a layer is fine.
	collision_layer = 1
	collision_mask  = 0

@rpc("any_peer", "call_local", "reliable")
func take_damage(amount: float) -> void:
	# Building pieces are spawned/despawned by the host via the
	# MultiplayerSpawner, so only the server tracks health and frees them.
	if multiplayer.has_multiplayer_peer() and not multiplayer.is_server():
		return
	health = max(0.0, health - amount)
	if health == 0.0:
		queue_free()
