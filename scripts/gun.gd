extends Node3D
class_name Gun

signal ammo_changed(current, mag, reserve)
signal reload_started(duration)
signal reload_finished()

@export var damage      := 18.0
@export var fire_rate   := 0.11   # seconds per shot (~9 rps)
@export var mag_size    := 30
@export var reserve_max := 120
@export var reload_time := 2.2
@export var max_range   := 10000.0

# Gun-local muzzle position (matches MuzzleLight in gun.tscn)
const MUZZLE_LOCAL := Vector3(0.0, 0.025, -0.36)

@onready var muzzle_light: OmniLight3D = $MuzzleLight
@onready var muzzle_flash: MeshInstance3D = $MuzzleFlash

var ammo_in_mag  : int
var reserve_ammo : int

var _cooldown     := 0.0
var _reloading    := false
var _reload_timer := 0.0
var _flash_timer  := 0.0

func _ready() -> void:
	ammo_in_mag  = mag_size
	reserve_ammo = reserve_max
	if muzzle_flash:
		muzzle_flash.visible = false
	if muzzle_light:
		muzzle_light.visible = false

func _process(delta: float) -> void:
	_cooldown = max(0.0, _cooldown - delta)

	if _flash_timer > 0.0:
		_flash_timer -= delta
		if _flash_timer <= 0.0:
			if muzzle_light:
				muzzle_light.visible = false
			if muzzle_flash:
				muzzle_flash.visible = false

	if _reloading:
		_reload_timer -= delta
		if _reload_timer <= 0.0:
			_finish_reload()

# ---- Public API -----------------------------------------------------------

func fire(ray: RayCast3D) -> bool:
	if _reloading or _cooldown > 0.0:
		return false
	if ammo_in_mag <= 0:
		start_reload()
		return false

	_cooldown    = fire_rate
	ammo_in_mag -= 1
	ammo_changed.emit(ammo_in_mag, mag_size, reserve_ammo)

	_flash_timer = 0.06
	if muzzle_light:
		muzzle_light.visible = true
	if muzzle_flash:
		muzzle_flash.visible = true

	ray.force_raycast_update()

	var muzzle_world := global_transform * MUZZLE_LOCAL
	var hit_pos: Vector3
	var hit_normal := Vector3.UP
	if ray.is_colliding():
		hit_pos    = ray.get_collision_point()
		hit_normal = ray.get_collision_normal()
		var target = ray.get_collider()
		_apply_damage_chain(target)
		_spawn_impact(hit_pos, hit_normal)
	else:
		var ray_dir := -ray.global_transform.basis.z
		hit_pos = ray.global_position + ray_dir * max_range

	_spawn_tracer(muzzle_world, hit_pos)
	return true

func start_reload() -> void:
	if _reloading or reserve_ammo <= 0 or ammo_in_mag == mag_size:
		return
	_reloading    = true
	_reload_timer = reload_time
	reload_started.emit(reload_time)

func is_reloading() -> bool:
	return _reloading

func add_reserve(amount: int) -> int:
	var room := reserve_max - reserve_ammo
	var taken := mini(amount, room)
	if taken <= 0:
		return 0
	reserve_ammo += taken
	ammo_changed.emit(ammo_in_mag, mag_size, reserve_ammo)
	return taken

# ---- Internal -------------------------------------------------------------

func _apply_damage_chain(target) -> void:
	if target == null:
		return
	# Walk up the collider chain to find a node that handles damage.
	var node : Node = null
	if target is Node:
		if (target as Node).has_method("take_damage"):
			node = target
		else:
			var p := (target as Node).get_parent()
			if p != null and p.has_method("take_damage"):
				node = p
	if node == null:
		return
	# Players replicate via RPC (target authority applies + syncs health).
	# Other entities (guards / mineral nodes / building pieces) are local-state
	# in this MVP, so call directly on this peer.
	if node.is_in_group("player"):
		if node.has_method("rpc_id"):
			var auth: int = node.get_multiplayer_authority()
			node.rpc_id(auth, "take_damage", damage)
		else:
			node.take_damage(damage)
		return
	if node.is_in_group("building_pieces"):
		if multiplayer.has_multiplayer_peer():
			node.rpc_id(1, "take_damage", damage)
		else:
			node.take_damage(damage)
		return
	node.take_damage(damage)

func _finish_reload() -> void:
	var needed := mag_size - ammo_in_mag
	var taken := needed
	if taken > reserve_ammo:
		taken = reserve_ammo
	ammo_in_mag  += taken
	reserve_ammo -= taken
	_reloading    = false
	ammo_changed.emit(ammo_in_mag, mag_size, reserve_ammo)
	reload_finished.emit()

func _spawn_tracer(start_pos: Vector3, finish_pos: Vector3) -> void:
	var dist := start_pos.distance_to(finish_pos)
	if dist < 0.05:
		return
	var tracer := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.height = dist
	cyl.top_radius = 0.025
	cyl.bottom_radius = 0.025
	cyl.radial_segments = 6
	tracer.mesh = cyl

	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(1.0, 0.85, 0.3)
	mat.emission_enabled = true
	mat.emission = Color(1.0, 0.85, 0.3)
	mat.emission_energy_multiplier = 6.0
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	tracer.set_surface_override_material(0, mat)
	tracer.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

	get_tree().current_scene.add_child(tracer)
	tracer.global_position = (start_pos + finish_pos) * 0.5

	var dir := (finish_pos - start_pos).normalized()
	var up_vec := Vector3.UP
	if absf(dir.dot(Vector3.UP)) >= 0.99:
		up_vec = Vector3.RIGHT
	tracer.look_at(finish_pos, up_vec)
	tracer.rotate_object_local(Vector3.RIGHT, PI * 0.5)

	get_tree().create_timer(0.05).timeout.connect(_destroy_node.bind(tracer))

func _spawn_impact(pos: Vector3, normal: Vector3) -> void:
	var burst := MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = 0.10
	sm.height = 0.20
	sm.radial_segments = 8
	sm.rings = 4
	burst.mesh = sm

	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(1.0, 0.7, 0.2)
	mat.emission_enabled = true
	mat.emission = Color(1.0, 0.55, 0.15)
	mat.emission_energy_multiplier = 8.0
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	burst.set_surface_override_material(0, mat)
	burst.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

	get_tree().current_scene.add_child(burst)
	burst.global_position = pos + normal * 0.05

	get_tree().create_timer(0.09).timeout.connect(_destroy_node.bind(burst))

func _destroy_node(n: Node) -> void:
	if is_instance_valid(n):
		n.queue_free()
