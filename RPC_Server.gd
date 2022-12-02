extends Node
class_name rpc_server

var main = null

var LOG = []
#var LOG_ERRORS = []

var connected_players = {
	# dictionary, because it's keyed by the players' network ID number!
}
remote func remote_player_data_receive(id, client_data):
	if client_data == null:
		return
	connected_players[id] = client_data
	if cache_node != null:
		add_player_node(id)
func add_player_node(id):
	var player_node = Node.new()
	player_node.name = str(id)
	player_node.set_script(load("res://player.gd"))
	player_node.set_network_master(id)
	player_node.custom_multiplayer = API_INSTANCE
	cache_node.add_child(player_node)
func remove_player_node(id):
	if cache_node == null:
		return
	cache_node.get_node(str(id)).queue_free()

func clear_player_list():
	connected_players = {}

var USE_WEBSOCKET = true
var USE_SSL = true

var APP_NAME = ""
var CACHE_PATH = ""
var cache_node = null

var MY_PEER = null
var API_INSTANCE = null
var SERVER_PORT = 20018
var MAX_PEERS = 1000
var CONNECTION_TIMEOUT = 5
func set_params(params_dict):
	for param in params_dict:
		self.set(param, params_dict[param])
	cache_path_updated()
	params_update_ui(false)
func enumerate_params():
	var dict = {}
	var params_list = [
		"APP_NAME",
		"SERVER_PORT",
		"MAX_PEERS",
		"CONNECTION_TIMEOUT",
		"USE_WEBSOCKET",
		"USE_SSL",
		"CACHE_PATH",
	]
	for param in params_list:
		dict[param] = self.get(param)
	return dict
var update_params_in_settings = true
func params_changed():
	if !update_params_in_settings:
		return
	main.server_node_updated_params(self, enumerate_params())
func params_update_ui(update_settings = true):
	update_params_in_settings = update_settings
	$app_name.text = APP_NAME
	$TABS/TAB0/port.value = SERVER_PORT
	$TABS/TAB0/MAX_PEERS.value = MAX_PEERS
	$TABS/TAB1/CONNECTION_TIMEOUT.value = CONNECTION_TIMEOUT
	$TABS/TAB1/USE_WEBSOCKET.pressed = USE_WEBSOCKET
	$TABS/TAB1/USE_SSL.pressed = USE_SSL

	$TABS/TAB3/cache_path.text = CACHE_PATH
	update_params_in_settings = true
func cache_path_updated():
	for c in $RPC_ROOT.get_children():
		if c.name != "RPC":
			c.free()
	if CACHE_PATH == "":
		cache_node = null
		return
	var cache_tree = CACHE_PATH.split("/")
	var curr_node = $RPC_ROOT
	for node_name in cache_tree:
		var l = curr_node.get_node(node_name)
		if l == null:
			var child_node = Node.new()
			child_node.name = node_name
			curr_node.add_child(child_node)
			curr_node = child_node
	cache_node = curr_node

	# re-add all the player nodes
	for player_id in connected_players:
		add_player_node(player_id)

var SERVER_LOG = ""

var STOPPED = true
func setup_API():
	if API_INSTANCE != null:
		return
	API_INSTANCE = MultiplayerAPI.new()
#	API_INSTANCE.connect("connected_to_server", self, "_connected_ok")
#	API_INSTANCE.connect("connection_failed", self, "_connected_fail")
	API_INSTANCE.connect("network_peer_connected", self, "_player_connected")
	API_INSTANCE.connect("network_peer_disconnected", self, "_player_disconnected")
	API_INSTANCE.connect("network_peer_packet", self, "_network_packet")
#	API_INSTANCE.connect("server_disconnected", self, "_server_disconnected")
	API_INSTANCE.root_node = $RPC_ROOT
	custom_multiplayer = API_INSTANCE
	$RPC_ROOT.custom_multiplayer = API_INSTANCE
	$RPC_ROOT/RPC.custom_multiplayer = API_INSTANCE
	set_network_master(1)
func shutdown():
	if MY_PEER != null:
		if !USE_WEBSOCKET:
			MY_PEER.close_connection()
		else:
			MY_PEER.stop()
	MY_PEER = null
	clear_player_list()
	API_INSTANCE.network_peer = null
	STOPPED = true
	Log.generic(self,str("SERVER STOPPED"))
func startup():
	setup_API()

	if MY_PEER != null:
		return # clear_and_reset()
	var err = 0
	if !USE_WEBSOCKET:
		MY_PEER = NetworkedMultiplayerENet.new()
		if USE_SSL:
			if !main.refresh_cert_data():
				return shutdown()
			MY_PEER.use_dtls = true
			MY_PEER.set_dtls_certificate(main.SSL_CERT)
			MY_PEER.set_dtls_key(main.SSL_KEY)
		err = MY_PEER.create_server(SERVER_PORT, MAX_PEERS)
	else:
		MY_PEER = WebSocketServer.new()
		if USE_SSL:
			if !main.refresh_cert_data():
				return shutdown()
			MY_PEER.ssl_certificate = main.SSL_CERT
			MY_PEER.private_key = main.SSL_KEY
		err = MY_PEER.listen(SERVER_PORT, PoolStringArray(), true)
	if err != OK:
		Log.error(self,err,str("could not startup server"))
		return shutdown()
	API_INSTANCE.network_peer = MY_PEER
	start_timestamp = OS.get_unix_time()
	Log.generic(self,str("SERVER STARTED"))

# these are called on both server and clients
func _player_connected(id):
	Log.generic(self,str("JOINED: PLAYER ", id))
#	add_player_node(id)
	connected_players[id] = {}
func _player_disconnected(id):
	Log.generic(self,str("DISCONNECTED: PLAYER ", id))
#	remove_player_node(id)
	connected_players.erase(id)
func _player_connection_lost(id):
	Log.generic(self,str("TIMED OUT: PLAYER ", id))
	connected_players.erase(id)
	remove_player_node(id)
func _network_packet(id, bytes):
	Log.generic(self,str("PACKET RECEIVED FROM ", id,": ",bytes))

# Called every frame. 'delta' is the elapsed time since the previous frame.
var start_timestamp = -1
func disable_if(node, flag):
	node.disabled = !flag
#	node.focus_mode = Control.FOCUS_NONE if !flag else Control.FOCUS_ALL
	node.modulate.a = float(flag) + float(!flag) * 0.5
func _process(delta):
	if MY_PEER != null && STOPPED:
		if MY_PEER.get_connection_status() == 2:
			STOPPED = false
	if MY_PEER == null:
		STOPPED = true

	if API_INSTANCE.has_network_peer():
		API_INSTANCE.poll()

	match main.CURRENT_TAB:
		0:
			if !STOPPED:
				$TABS/TAB0/btn_start_stop.text = "stop"
				var s = OS.get_unix_time() - start_timestamp
				var m = s/60
				var h = s/3600
				var d = s/86400
				$TABS/TAB0/PANEL/uptime.text = "%d days, %02d:%02d:%02d" % [d,h%24,m%60,s%60]
			else:
				$TABS/TAB0/btn_start_stop.text = "start"
				$TABS/TAB0/PANEL/uptime.text = str("")
			$TABS/TAB0/PANEL2/players.text = str(connected_players.size(),"/",MAX_PEERS)
			$TABS/TAB0/port.editable = STOPPED
			$TABS/TAB0/MAX_PEERS.editable = STOPPED
		1:
			disable_if($TABS/TAB1/USE_WEBSOCKET, STOPPED)
			disable_if($TABS/TAB1/USE_SSL, STOPPED)

	for n in range(4):
		get_node(str("TABS/TAB",n)).visible = main.CURRENT_TAB == n


func _on_btn_start_stop_pressed():
	if STOPPED:
		startup()
	else:
		shutdown()
	params_update_ui()

func _on_btn_delete_pressed():
	main.delete_server(self)

# tab 0
func _on_app_name_text_changed(new_text):
	APP_NAME = new_text
	params_changed()
func _on_port_value_changed(value):
	SERVER_PORT = int(value)
	params_changed()

# tab 1
func _on_MAX_PEERS_value_changed(value):
	MAX_PEERS = value
	params_changed()
func _on_CONNECTION_TIMEOUT_value_changed(value):
	CONNECTION_TIMEOUT = value
	params_changed()
func _on_USE_WEBSOCKET_toggled(button_pressed):
	USE_WEBSOCKET = button_pressed
	params_changed()
func _on_USE_SSL_toggled(button_pressed):
	USE_SSL = button_pressed
	params_changed()

# tab 2
func _on_selector_pressed():
	pass # Replace with function body.

# tab 3
func _on_cache_path_text_changed(new_text):
	CACHE_PATH = new_text
	params_changed()
func _on_cache_path_text_entered(new_text):
	cache_path_updated()
func _on_cache_path_focus_exited():
	cache_path_updated()
