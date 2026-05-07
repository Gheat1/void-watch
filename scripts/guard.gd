extends StaticBody3D
class_name Guard

## Stationary turret-style enemy that watches over a monument.  It tracks the
## player when within sight range and fires a hitscan shot every ATTACK_RATE
## seconds.  Takes damage from the player's gun (anything that calls
## take_damage()) and de-spawns at zero health.

const SIGHT_RANGE  := 32.0
const ATTACK_RATE  := 1.6
const FIRE_DAMAGE  := 8.0
const MAX_HEALTH   := 60.0

@onready var head         : Node3D         = $Head
@onready var muzzle_flash : MeshInstance3D = $Head/MuzzleFlash
@onready var eye          : MeshInstance3D = $Head/Eye

var health        : float
var _attack_timer : float    = 1.0
var _flash_timer  : float    = 0.0
var _player       : Node3D   = null

func _ready() -> void:
	health = MAX_HEALTH
	add_to_group("enemies")
	collision_layer = 1
	collision_mask  = 0
	if muzzle_flash:
		muzzle_flash.visible = false

func _physics_process(delta: float) -> void:
	if _flash_timer > 0.0:
		_flash_timer -= delta
		if _flash_timer <= 0.0 and muzzle_flash:
			muzzle_flash.visible = false

	_attack_timer = max(0.0, _attack_timer - delta)

	# Look up the player lazily (player may join the world after the guard)
	if _player == null or not is_instance_valid(_player):
		_player = get_tree().get_first_node_in_group("player")
		if _player == null:
			return

	var target_pos := _player.global_position + Vector3(0, 1.5, 0)
	var to_target  := target_pos - global_position
	var dist       := to_target.length()
	if dist > SIGHT_RANGE:
		return

	# Aim head at the player
	if head and dist > 0.05:
		head.look_at(target_pos, Vector3.UP)

	# Shoot on cooldown
	if _attack_timer == 0.0:
		_attack_timer = ATTACK_RATE
		_shoot(target_pos)

func _shoot(target_pos: Vector3) -> void:
	var muzzle_pos := global_position + Vector3(0, 1.45, 0)

	# Apply damage
	if _player and _player.has_method("take_damage"):
		_player.take_damage(FIRE_DAMAGE)

	# Visual flash + tracer
	if muzzle_flash:
		muzzle_flash.visible = true
	_flash_timer = 0.07
	_spawn_tracer(muzzle_pos, target_pos)

func _spawn_tracer(start_pos: Vector3, finish_pos: Vector3) -> void:
	var dist := start_pos.distance_to(finish_pos)
	if dist < 0.05:
		return
	var tracer := MeshInstance3D.new()
	var cyl    := CylinderMesh.new()
	cyl.height          = dist
	cyl.top_radius      = 0.03
	cyl.bottom_radius   = 0.03
	cyl.radial_segments = 6
	tracer.mesh = cyl

	var mat := StandardMaterial3D.new()
	mat.albedo_color              = Color(1.0, 0.30, 0.25)
	mat.emission_enabled          = true
	mat.emission                  = Color(1.0, 0.30, 0.25)
	mat.emission_energy_multiplier = 5.0
	mat.shading_mode              = BaseMaterial3D.SHADING_MODE_UNSHADED
	tracer.set_surface_override_material(0, mat)
	tracer.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

	get_tree().current_scene.add_child(tracer)
	tracer.global_position = (start_pos + finish_pos) * 0.5

	var dir := (finish_pos - start_pos).normalized()
	var up_vec := Vector3.UP if absf(dir.dot(Vector3.UP)) < 0.99 else Vector3.RIGHT
	tracer.look_at(finish_pos, up_vec)
	tracer.rotate_object_local(Vector3.RIGHT, PI * 0.5)

	get_tree().create_timer(0.05).timeout.connect(_destroy_node.bind(tracer))

func _destroy_node(n: Node) -> void:
	if is_instance_valid(n):
		n.queue_free()

func take_damage(amount: float) -> void:
	if health <= 0.0:
		return
	health = max(0.0, health - amount)
	# Brief red flash on hit — tint the eye darker so it reads as "stunned"
	if eye and eye.get_surface_override_material(0):
		var m := eye.get_surface_override_material(0) as StandardMaterial3D
		if m:
			m.emission_energy_multiplier = 8.0
			get_tree().create_timer(0.10).timeout.connect(_reset_eye_glow.bind(m))
	if health == 0.0:
		queue_free()

func _reset_eye_glow(m: StandardMaterial3D) -> void:
	if m:
		m.emission_energy_multiplier = 5.0
