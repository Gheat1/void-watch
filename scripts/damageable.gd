extends Node
class_name Damageable

## Health component. Add as a child named "Damageable" to any physics body.
## The parent node gains take_damage / heal via forwarding, or connect signals
## directly to your game logic.

signal health_changed(current: float, maximum: float)
signal died(owner_node: Node)

@export var max_health      := 100.0
@export var destroy_on_death := true

var health: float

func _ready() -> void:
	health = max_health

func take_damage(amount: float) -> void:
	health = max(0.0, health - amount)
	health_changed.emit(health, max_health)
	if health == 0.0:
		_die()

func heal(amount: float) -> void:
	health = min(max_health, health + amount)
	health_changed.emit(health, max_health)

func _die() -> void:
	died.emit(get_parent())
	if destroy_on_death:
		get_parent().queue_free()
