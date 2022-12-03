extends Control

onready var SERVER_SCN = load("res://RPC_Server.tscn") # prepackaged node with a script, just for convenience...

var settings = {
	"servers": [],
}

# basic IO
func write_file(path, data, password = ""):
	var file = File.new()
	var err = -1
	if password == "":
		err = file.open(path, File.WRITE)
	else:
		err = file.open_encrypted_with_pass(path, File.WRITE, password)
	if err != OK:
		Log.error(null,err,str("could not write to file '",path,"'"))
		return false
	file.store_string(data)
	file.close()
	Log.generic(null,str("file '",path,"' written successfully!"))
	return true
func read_file(path, password = ""):
	var file = File.new()
	var err = -1
	if password == "":
		err = file.open(path, File.READ)
	else:
		err = file.open_encrypted_with_pass(path, File.READ, password)
	if err != OK:
		Log.error(null,err,str("could not read file '",path,"'"))
		return null
	var data = file.get_as_text()
	file.close()
	Log.generic(null,str("file '",path,"' read successfully!"))
	return data
func read_file_metadata(path):
	var file = File.new()
	var err = file.open(path, File.READ)
	if err != OK:
		Log.error(null,err,str("could not read file '",path,"'"))
		return null
	var data = {
		"extension": path.get_extension(),
		"modified_timestamp": file.get_modified_time(path),
		"modified_datetime": OS.get_datetime_from_unix_time(file.get_modified_time(path)),
		"md5": file.get_md5(path),
		"length": file.get_len(),
	}
	file.close()
	return data
func delete_file(path):
	var dir = Directory.new()
	var err = dir.remove(path)
	if err != OK:
		Log.error(null,err,str("could not delete file '",path,"'"))
		return false
	return true

func dir_contents(path):
	var dir = Directory.new()
	var err = dir.open(path)
	if err != OK:
		Log.error(null,err,str("could not access directory '",path,"'"))
		return null
	else:
		var results = {
			"folders":{},
			"files":{}
		}
		dir.list_dir_begin()
		var file_name = dir.get_next()
		while file_name != "":
			if file_name != "." && file_name != ".." :
				var file_data = read_file_metadata(str(path,"/",file_name))
				if dir.current_is_dir():
					results.folders[file_name] = file_data
				else:
					results.files[file_name] = file_data
			file_name = dir.get_next()
		return results
func find_most_recent_file(path):
	var results = dir_contents(path)

	var most_recent_timestamp = -1
	var most_recent_file = null
	for file_name in results.files:
		var file = results.files[file_name]
		if file.modified_timestamp > most_recent_timestamp:
			most_recent_timestamp = file.modified_timestamp
			most_recent_file = file_name
	return most_recent_file

# settings IO
var DATA_PATH = "user://data.json"
func save_user_data(export_file_path = ""):
	write_file(export_file_path if export_file_path != "" else DATA_PATH, to_json(settings))
func set_setting(variable, value):
	settings[variable] = value
	save_user_data()
func load_user_data(import_file_path = ""):
	var fdata = read_file(import_file_path if import_file_path != "" else DATA_PATH)
	if fdata != null:
		settings = parse_json(fdata)
		clear_server_nodes()
		for s_params in settings.servers:
			add_server_node(s_params)
	elif import_file_path == "":
		Log.generic(null,str("No user data file found, creating a new one..."))
		save_user_data()

# cert IO
var SSL_CERT = null
var SSL_KEY = null
var LAST_CRT_FILE = null
var LAST_KEY_FILE = null
var LAST_PFX_FILE = null

var ASCII = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789" # 62 characters
func random_ascii_password(size: int) -> String:
	var password = ""
	for i in range(size):
		password += ASCII[randi() % 62]
	return password
func unpack_pkcs_12_file(path, openssl_bin, passin):
	var passout = random_ascii_password(64)
	var output = []
	var exit_code = -1

	# extract cert + key from PKCS file
	exit_code = OS.execute(openssl_bin,
		["pkcs12",
		"-in",
		path,
		"-passin", str("pass:",passin),
		"-nodes",
		"-out", OS.get_user_data_dir() + "/ssl.crt"
		], true, output)

	# return results
	return {
		"password":passout,
		"exit_code":exit_code,
		"output":output
	}
func load_crt_file(path):
	var crt = X509Certificate.new()
	var err = crt.load(path)
	if err != OK:
		Log.error(null,err,str("could not load cert file '",path,"'"))
		return null
	return crt
func load_key_file(path):
	var key = CryptoKey.new()
	var err = key.load(path)
	if err != OK:
		Log.error(null,err,str("could not load key file '",path,"'"))
		return null
	return key

func refresh_cert_data(force_refresh = false):
	if !force_refresh && (SSL_CERT != null || SSL_KEY != null):
		return true

	# get chosen method of parsing SSL data from settings
	var CERT_PARSING_METHOD = int(settings.get("cert_method", 0))

	match CERT_PARSING_METHOD:
		0:
			# 0) try to use manually passed CRT + KEY files
			var file_crt = settings.get("cert_crt_file", "")
			var file_key = settings.get("cert_key_file", "")
			if file_crt == "" || file_key == "":
				Log.error(null,null,"incorrect/missing SSL data.")
				return false # these are required!

			# -----
			if LAST_CRT_FILE == file_crt && LAST_KEY_FILE == file_key:
				return true # no update necessary!
			else:
				SSL_CERT = load_crt_file(file_crt)
				SSL_KEY = load_key_file(file_key)
				LAST_CRT_FILE = file_crt
				LAST_KEY_FILE = file_key
		1:
			# 1) try to use manually passed CRT file containing the full thing
			var file_full_crt = settings.get("cert_crt_file", "")
			if file_full_crt == "":
				Log.error(null,null,"incorrect/missing SSL data.")
				return false # this are required!

			# -----
			if LAST_CRT_FILE == file_full_crt:
				return true # no update necessary!
			else:
				SSL_CERT = load_crt_file(file_full_crt)
				SSL_KEY = load_key_file(file_full_crt)
				LAST_CRT_FILE = file_full_crt
		2:
			# 2) try to use manually passed PFX file
			var openssl_path = settings.get("openssl_bin", "")
			var file_pfx = settings.get("cert_pfx_file", "")
			if openssl_path == "" || file_pfx == "":
				Log.error(null,null,"incorrect/missing SSL data.")
				return false # these are required!

			# -----
			if LAST_PFX_FILE == file_pfx:
				return true # no update necessary: all certificates up to date!
			else:
				var r = unpack_pkcs_12_file(file_pfx, openssl_path, settings.get("cert_password", ""))
				SSL_CERT = load_crt_file(OS.get_user_data_dir() + "/ssl.crt")
				SSL_KEY = load_key_file(OS.get_user_data_dir() + "/ssl.crt")
				delete_file("user://ssl.crt")
				LAST_PFX_FILE = file_pfx
		3:
			# 3) try to fetch automatically from PFX storage
			var openssl_path = settings.get("openssl_bin", "")
			var pfx_store_path = settings.get("cert_pfx_dir", "")
			if openssl_path == "" || pfx_store_path == "":
				Log.error(null,null,"incorrect/missing SSL data.")
				return false # this are required!
			var filename_pfx = find_most_recent_file(pfx_store_path)
			if filename_pfx == null:
				Log.error(null,null,"could not find any valid SSL files in the storage location!")
				return false # no valid files found!

			# -----
			var full_file_path = str(pfx_store_path,"/",filename_pfx)
			if LAST_PFX_FILE == full_file_path:
				return true # no update necessary: all certificates up to date!
			else:
				var r = unpack_pkcs_12_file(full_file_path, openssl_path, settings.get("cert_password", ""))
				SSL_CERT = load_crt_file(OS.get_user_data_dir() + "/ssl.crt")
				SSL_KEY = load_key_file(OS.get_user_data_dir() + "/ssl.crt")
				delete_file("user://ssl.crt")

	# error!
	if SSL_CERT == null || SSL_KEY == null:
		SSL_CERT = null
		SSL_KEY = null
		LAST_CRT_FILE = null
		LAST_KEY_FILE = null
		LAST_PFX_FILE = null
		return false

	if force_refresh:
		Log.generic(null,"SSL certificates updated!")
	else:
		Log.generic(null,"SSL certificates loaded!")
	return true

# RPC servers
var SERVERS = []
onready var server_select_dropdown = $"TabContainer/Server log/OptionButton"
func add_server_node(params):
	var node = SERVER_SCN.instance()
	node.setup_API()
	node.set_params(params)
	node.main = self
	$server_nodes.add_child(node)
	server_select_dropdown.add_item(str("[ ",node.APP_NAME," ]"))
	SERVERS.push_back(node)
	return node
func clear_server_nodes():
	for s in $server_nodes.get_children():
		s.free()
	SERVERS = []
func remove_server_node(node):
	var i = node.get_index()
	server_select_dropdown.remove_item(i + 3)
	SERVERS.erase(node)
	node.queue_free()
func server_node_updated_params(node, params):
	var i = node.get_index()
	settings.servers[i] = params
	server_select_dropdown.set_item_text(i + 3, str("[ ",node.APP_NAME," ]"))
	save_user_data()

func create_new_server():
	var server = add_server_node({})
	settings.servers.push_back(server.enumerate_params())
	save_user_data()
var deleting_node = null
func delete_server(node):
	if deleting_node != null: # to fix some UI infinite loops
		return
	deleting_node = node
	dialog_operation_mode = 0
	$ConfirmationDialog.window_title = "Confirm deletion"
	$ConfirmationDialog.dialog_text = "Are you sure you want to delete the selected server?"
	$ConfirmationDialog.popup()

func status_literal(status):
	match status:
		0:
			return "DISCONNECTED"
		1:
			return "CONNECTING..."
		2:
			return "HOSTING"
func any_server_running():
	for s in $server_nodes.get_children():
		if !s.STOPPED:
			return true
	return false
func any_server_need_SSL_upkeep():
	for s in SERVERS:
		if !s.STOPPED && s.USE_SSL:
			return true
	return false

func _ready():
	clear_server_nodes() # clear the ones in the editor used for testing
	load_user_data()
	update_settings_ui()
	_on_TabContainer_tab_changed(0)

# Called every frame. 'delta' is the elapsed time since the previous frame.
var t = 0
onready var logger = $"TabContainer/Server log/Panel/Log"
var logger_lines_done = 0
func print_log(log_arr):
	for l in log_arr.size():
		if l >= logger_lines_done:
			var line = log_arr[l]
			logger.bbcode_text += line + "\n"
			logger_lines_done += 1
func refresh_log(cleanup = false):
	if cleanup:
		logger_lines_done = 0
		logger.bbcode_text = ""
	var i = server_select_dropdown.get_selected_id()
	match i:
		0:
			print_log(Log.LOG_EVERYTHING)
		1:
			print_log(Log.LOG_ENGINE)
		2:
			print_log(Log.LOG_ERRORS)
		_:
			print_log(SERVERS[i-3].LOG)
func _process(delta):
	if any_server_need_SSL_upkeep():
		t += delta
		if t >= settings.get("cert_refresh_interval", 3600):
			refresh_cert_data(true)
			t = 0
	if !$ConfirmationDialog.visible:
		deleting_node = null
	$new_server.rect_position.y = $server_nodes.rect_position.y + 34 * $server_nodes.get_child_count()
	$new_server.visible = CURRENT_TAB == 0 || CURRENT_TAB == 1

#	var status = 0
#	if MY_PEER != null:
#		status = MY_PEER.get_connection_status()
#	if logger != null:
#		logger.text = ""
#		logger.text += str("STATUS: ",status," (",status_literal(status),")\n")
#		if status == 2:
#			logger.text += str("Players: [",connected_players.size(),"/",MAX_PLAYERS,"]\n")
#			for id in connected_players:
#				logger.text += str(id,": [data]\n")
	if CURRENT_TAB == 2:
		refresh_log()

func _input(event):
	if CURRENT_TAB == 2 && server_select_dropdown.is_hovered():
		if Input.is_action_just_pressed("ui_scroll_up"):
			server_select_dropdown.select(server_select_dropdown.get_selected_id() - 1)
			refresh_log(true)
		if Input.is_action_just_pressed("ui_scroll_down"):
			server_select_dropdown.select(server_select_dropdown.get_selected_id() + 1)
			refresh_log(true)

### UI logic & signals

func set_ssl_FilePath_for_setting(variable, default, is_visible):
	var node = $"TabContainer/Settings/FilePaths".get_node(variable)
	if is_visible:
		node.show()
		node.text = settings.get(variable,default)
	else:
		node.hide()
func update_settings_ui():
	var cert_method = settings.get("cert_method",0)
	$"TabContainer/Settings/CertMethod".get_child(cert_method).pressed = true

	set_ssl_FilePath_for_setting("cert_crt_file", "", cert_method == 0 || cert_method == 1)
	set_ssl_FilePath_for_setting("cert_key_file", "", cert_method == 0)
	set_ssl_FilePath_for_setting("cert_pfx_file", "", cert_method == 2)
	set_ssl_FilePath_for_setting("cert_pfx_dir", "", cert_method == 3)
	set_ssl_FilePath_for_setting("openssl_bin", "", cert_method == 2 || cert_method == 3)

func _on_new_server_pressed():
	create_new_server()

# tabs
var CURRENT_TAB = 0
func _on_TabContainer_tab_changed(tab):
	CURRENT_TAB = tab
	if CURRENT_TAB >= 2:
		$server_nodes.hide()
	else:
		$server_nodes.show()
	refresh_log(true)

# SSL file settings
func _on_Btn_PFX_folder_pressed():
	dialog_operation_mode = 0
	$PathChooseDialog.popup()
func _on_Btn_crt_pressed():
	dialog_operation_mode = 0
	$FileChooseDialog.filters = ["*.crt ; Certificate files"]
	$FileChooseDialog.popup()
func _on_Btn_key_pressed():
	dialog_operation_mode = 1
	$FileChooseDialog.filters = ["*.key ; Private key files"]
	$FileChooseDialog.popup()
func _on_Btn_pfx_pressed():
	dialog_operation_mode = 2
	$FileChooseDialog.filters = ["*.pfx ; PKCS #12 archives"]
	$FileChooseDialog.popup()
func _on_Btn_openssl_pressed():
	dialog_operation_mode = 3
	$FileChooseDialog.filters = ["*.exe ; OpenSSL binary executable"]
	$FileChooseDialog.popup()

# SSL method selection
func _on_CertMethodRadio_pressed(button_id):
	set_setting("cert_method", button_id)
	update_settings_ui()

# data backup / clear
func _on_Btn_prefs_import_pressed():
	dialog_operation_mode = 4
	$FileChooseDialog.filters = ["*.json ; JSON User data settings"]
	$FileChooseDialog.popup()
func _on_Btn_prefs_export_pressed():
	$FileSaveDialog.filters = ["*.json ; JSON User data settings"]
	$FileSaveDialog.current_file = "data.json"
	$FileSaveDialog.popup()
func _on_Btn_prefs_clear_pressed():
	dialog_operation_mode = 1
	$ConfirmationDialog.window_title = "Confirm deletion"
	$ConfirmationDialog.dialog_text = "Are you sure you want to permanently clear all settings?"
	$ConfirmationDialog.popup()

# dialog windows
var dialog_operation_mode = -1
func _on_ConfirmationDialog_confirmed():
	match dialog_operation_mode:
		0: # delete server
			if deleting_node == null:
				return
			var i = deleting_node.get_index()
			settings.servers.remove(i)
			remove_server_node(deleting_node)
			save_user_data()
			deleting_node = null
		1: # clear all user data
			settings = {
				"servers": [],
			}
			save_user_data()
			load_user_data()
	dialog_operation_mode = -1
	update_settings_ui()
func _on_PathChooseDialog_dir_selected(dir):
	match dialog_operation_mode:
		0: # PFX storage dir
			set_setting("cert_pfx_dir", dir)
		1: # temp file extraction dir
			set_setting("cert_temp_dir", dir)
	dialog_operation_mode = -1
	update_settings_ui()
func _on_FileChooseDialog_file_selected(path):
	match dialog_operation_mode:
		0: # CRT file
			set_setting("cert_crt_file", path)
		1: # KEY file
			set_setting("cert_key_file", path)
		2: # PFX file
			set_setting("cert_pfx_file", path)
		3: # OpenSSL binaries
			set_setting("openssl_bin", path)
		4: # user data JSON import
			load_user_data(path)
			save_user_data()
	dialog_operation_mode = -1
	update_settings_ui()
func _on_FileSaveDialog_file_selected(path):
	save_user_data(path)

# server logs
func _on_BtnClearLog_pressed():
	var i = server_select_dropdown.get_selected_id()
	if i < 3:
		Log.LOG_EVERYTHING = []
		Log.LOG_ENGINE = []
		Log.LOG_ERRORS = []
	else:
		SERVERS[i-3].LOG = []
	refresh_log(true)
func _on_OptionButton_item_selected(index):
	refresh_log(true)


