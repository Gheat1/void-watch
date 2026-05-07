extends Node

## Multiplayer manager (autoloaded as "Net").
## Hosts an authoritative ENet server, joins one as a client, and spawns
## /despawns Player nodes per peer. The host is always peer id 1.

const PORT_DEFAULT := 7777
const MAX_PEERS    := 16
const PLAYER_SCENE := preload("res://scenes/player/player.tscn")
const MAIN_SCENE   := "res://scenes/main.tscn"

signal connection_failed
signal connected_to_server
signal server_disconnected

var is_server : bool = false
var is_online : bool = false

func host(port: int = PORT_DEFAULT) -> Error:
	close()
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_server(port, MAX_PEERS)
	if err != OK:
		return err
	multiplayer.multiplayer_peer = peer
	is_server = true
	is_online = true
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	return OK

func join_server(ip: String, port: int = PORT_DEFAULT) -> Error:
	close()
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_client(ip, port)
	if err != OK:
		return err
	multiplayer.multiplayer_peer = peer
	is_server = false
	is_online = true
	multiplayer.connected_to_server.connect(_on_connected)
	multiplayer.connection_failed.connect(_on_connect_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)
	return OK

func close() -> void:
	for s in [
		["peer_connected",       _on_peer_connected],
		["peer_disconnected",    _on_peer_disconnected],
		["connected_to_server",  _on_connected],
		["connection_failed",    _on_connect_failed],
		["server_disconnected",  _on_server_disconnected],
	]:
		var sig: String = s[0]
		var cb: Callable = s[1]
		if multiplayer.is_connected(sig, cb):
			multiplayer.disconnect(sig, cb)
	if multiplayer.multiplayer_peer:
		multiplayer.multiplayer_peer.close()
	multiplayer.multiplayer_peer = null
	is_server = false
	is_online = false

func enter_world() -> void:
	get_tree().change_scene_to_file(MAIN_SCENE)

# Called by main.gd once the world is ready (host only — host's player isn't
# announced via peer_connected because the host is always already there).
func host_spawn_self() -> void:
	if is_server:
		_ensure_player_for(1)

# ── Server: peer hooks ──────────────────────────────────────────────────────

func _on_peer_connected(_id: int) -> void:
	# Defer spawning until the client tells us it has loaded the world via
	# notify_ready(). Otherwise the spawn replication arrives before the
	# client has a Players node to receive it.
	pass

# Clients call this on the server once main.tscn is loaded.
@rpc("any_peer", "call_local", "reliable")
func notify_ready() -> void:
	if not is_server:
		return
	var sender := multiplayer.get_remote_sender_id()
	if sender == 0:
		sender = 1
	_ensure_player_for(sender)

func _on_peer_disconnected(id: int) -> void:
	if not is_server:
		return
	var players := _players_root()
	if players == null:
		return
	var n := players.get_node_or_null(str(id))
	if n:
		n.queue_free()

# ── Client: state hooks ─────────────────────────────────────────────────────

func _on_connected() -> void:
	connected_to_server.emit()

func _on_connect_failed() -> void:
	connection_failed.emit()
	close()

func _on_server_disconnected() -> void:
	server_disconnected.emit()
	close()

# ── Internals ───────────────────────────────────────────────────────────────

func _ensure_player_for(id: int) -> void:
	var players := _players_root()
	if players == null:
		return
	if players.has_node(str(id)):
		return
	var p : Node3D = PLAYER_SCENE.instantiate()
	p.name = str(id)
	players.add_child(p, true)
	p.global_position = _spawn_position()

func _spawn_position() -> Vector3:
	var world := get_tree().get_first_node_in_group("world")
	var y := 4.0
	if world and world.has_method("get_terrain_height"):
		y = world.get_terrain_height(0.0, 0.0) + 4.0
	return Vector3(randf_range(-2.5, 2.5), y, randf_range(-2.5, 2.5))

func _players_root() -> Node:
	var main := get_tree().current_scene
	if main == null:
		return null
	return main.get_node_or_null("Players")
