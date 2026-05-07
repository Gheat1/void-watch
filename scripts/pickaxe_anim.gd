extends Node3D

const BASE_Z     := -16.5
const PEAK_Z     := 16.5
const SWING_TIME := 0.16

var _tween: Tween

func _ready() -> void:
	# this forces godot to calculate Z last, which usually fixes axis swapping
	rotation_order = EULER_ORDER_XYZ
	rotation_degrees.z = BASE_Z

func play_swing() -> void:
	if _tween:
		_tween.kill()
	
	_tween = create_tween()
	# using rads instead of degrees can sometimes bypass weird inspector bugs
	_tween.tween_property(self, "rotation:z", deg_to_rad(PEAK_Z), SWING_TIME).from(deg_to_rad(BASE_Z))
	_tween.tween_property(self, "rotation:z", deg_to_rad(BASE_Z), SWING_TIME)
