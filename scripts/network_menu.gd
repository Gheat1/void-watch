extends Control

## Title / connect screen. Hosts a server or joins one and then loads the
## main world scene. Net (autoload) owns the actual connection.

const DEFAULT_IP      := "game.gheat.net"
const DEFAULT_PORT    := 7777
const VOIDWATCH_HOST  := "game.gheat.net"

@onready var ip_field         : LineEdit = $Panel/VBox/IPRow/IPField
@onready var port_field       : LineEdit = $Panel/VBox/PortRow/PortField
@onready var host_btn         : Button   = $Panel/VBox/HostBtn
@onready var join_btn         : Button   = $Panel/VBox/JoinBtn
@onready var quick_join_btn   : Button   = $Panel/VBox/QuickJoinBtn
@onready var status_lbl       : Label    = $Panel/VBox/StatusLabel

func _ready() -> void:
	# When exported as a dedicated server, skip the menu and host immediately.
	if OS.has_feature("dedicated_server"):
		var err := Net.host(DEFAULT_PORT)
		if err != OK:
			push_error("Dedicated server failed to bind port %d (err %d)" % [DEFAULT_PORT, err])
			get_tree().quit(1)
			return
		print("VoidWatch dedicated server running on port %d" % DEFAULT_PORT)
		Net.enter_world.call_deferred()
		return

	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	ip_field.text   = DEFAULT_IP
	port_field.text = str(DEFAULT_PORT)
	host_btn.pressed.connect(_on_host_pressed)
	join_btn.pressed.connect(_on_join_pressed)
	quick_join_btn.pressed.connect(_on_quick_join_pressed)
	Net.connected_to_server.connect(_on_connected)
	Net.connection_failed.connect(_on_connect_failed)

func _on_host_pressed() -> void:
	var port := _read_port()
	var err := Net.host(port)
	if err != OK:
		status_lbl.text = "Host failed: %d" % err
		return
	status_lbl.text = "Hosting on port %d…" % port
	Net.enter_world()

func _on_quick_join_pressed() -> void:
	ip_field.text = VOIDWATCH_HOST
	port_field.text = str(DEFAULT_PORT)
	_do_join(VOIDWATCH_HOST, DEFAULT_PORT)

func _on_join_pressed() -> void:
	var ip := ip_field.text.strip_edges()
	if ip == "":
		ip = DEFAULT_IP
	_do_join(ip, _read_port())

func _do_join(ip: String, port: int) -> void:
	status_lbl.text = "Connecting to %s:%d…" % [ip, port]
	host_btn.disabled = true
	join_btn.disabled = true
	quick_join_btn.disabled = true
	var err := Net.join_server(ip, port)
	if err != OK:
		status_lbl.text = "Connect failed: %d" % err
		host_btn.disabled = false
		join_btn.disabled = false
		quick_join_btn.disabled = false

func _on_connected() -> void:
	status_lbl.text = "Connected — entering world…"
	Net.enter_world()

func _on_connect_failed() -> void:
	status_lbl.text = "Connection failed."
	host_btn.disabled = false
	join_btn.disabled = false
	quick_join_btn.disabled = false

func _read_port() -> int:
	var p := int(port_field.text)
	if p <= 0 or p > 65535:
		p = DEFAULT_PORT
	return p
