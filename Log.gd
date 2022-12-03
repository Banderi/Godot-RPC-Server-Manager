extends Node

var LOG_EVERYTHING = []
var LOG_ENGINE = []
var LOG_ERRORS = []

func get_enum_string(enums, value):
	return enums.keys()[value]
func get_timestamp(from):
	var d = OS.get_datetime()
	var date = "%04d/%02d/%02d %02d:%02d:%02d" % [d.year, d.month, d.day, d.hour, d.minute, d.second]
	if from == null:
		return date + " -- "
	else:
		return date + str(" -- [", from.APP_NAME, "]: ")
func generic(from, text):
	var msg = str(get_timestamp(from), text)

	var bb_msg = msg
	LOG_EVERYTHING.push_back(bb_msg)
	if from != null:
		from.LOG.push_back(bb_msg)
	else:
		LOG_ENGINE.push_back(bb_msg)
	print(msg)
func error(from, err, text):
	var msg = str(get_timestamp(from), "ERROR: ", text)
	if err != null:
		msg += str(" (", err, ":", get_enum_string(GlobalScope.Error, err), ")")

	var bb_msg = str("[color=#ee1100]", msg, "[/color]")
	LOG_EVERYTHING.push_back(bb_msg)
	LOG_ERRORS.push_back(bb_msg)
	if from != null:
		from.LOG.push_back(bb_msg)
	else:
		LOG_ENGINE.push_back(bb_msg)
	print(msg)
	push_error(msg)
