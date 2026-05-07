extends Node3D

const BASE_Z    := -15.5
const PEAK_Z    := 15.5
const SWING_TIME := 0.13

var _tween: Tween

func _ready() -> void:
	rotation_degrees.z = BASE_Z

func play_swing() -> void:
	if _tween and _tween.is_running():
		return
	_tween = create_tween()
	_tween.tween_method(_set_z, BASE_Z, PEAK_Z, SWING_TIME)
	_tween.tween_method(_set_z, PEAK_Z, BASE_Z, SWING_TIME)

func _set_z(deg: float) -> void:
	rotation_degrees.z = deg
