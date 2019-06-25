from common.constants import mods
from objects import glob

def newFirst(scoreID, userID, md5, mode, rx=0):
	"""
	set score into db

	:param userID: user id
	:param scoreID: score id
	"""
	# check if a score on that beatmap already exists with same mode
	result = glob.db.fetch("SELECT scoreid FROM scores_first WHERE beatmap_md5 = '{}' AND mode = '{}' AND rx = '{relax}' LIMIT 1".format(md5, mode, relax=1 if rx else 0))
	if result is None:
		glob.db.execute("INSERT INTO scores_first VALUES('{}', '{}', '{}', '{}', '{relax}')".format(scoreID, userID, md5, mode, relax=1 if rx else 0))
	else:
		glob.db.execute("UPDATE scores_first SET userid = '{}', scoreid = '{}' WHERE beatmap_md5 = '{}' AND mode = '{}' AND rx = '{relax}'".format(userID, scoreID, md5, mode, relax=1 if rx else 0))

def getPPLimit(gameMode, rx, fl):
	"""
	Get PP Limit from DB based on gameMode
	"""
	result = glob.db.fetch("SELECT {rx}{fl}pp FROM pp_limits WHERE gamemode = {gamemode}".format(rx='relax_' if rx else '', fl='flashlight_' if fl else '', gamemode=gameMode))

	return result['{rx}{fl}pp'.format(rx='relax_' if rx else '', fl='flashlight_' if fl else '')]

def isRankable(m):
	"""
	Checks if `m` contains unranked mods

	:param m: mods enum
	:return: True if there are no unranked mods in `m`, else False
	"""
	# TODO: Check other modes unranked mods ...?
	return not ((m & mods.RELAX2 > 0) or (m & mods.AUTOPLAY > 0) or (m & mods.SCOREV2 > 0))

def readableGameMode(gameMode):
	"""
	Convert numeric gameMode to a readable format. Can be used for db too.

	:param gameMode:
	:return:
	"""
	# TODO: Same as common.constants.gameModes.getGameModeForDB, remove one
	if gameMode == 0:
		return "std"
	elif gameMode == 1:
		return "taiko"
	elif gameMode == 2:
		return "ctb"
	else:
		return "mania"

def readableMods(m):
	"""
	Return a string with readable std mods.
	Used to convert a mods number for oppai

	:param m: mods bitwise number
	:return: readable mods string, eg HDDT
	"""
	r = ""
	if m == 0:
		return "nomod"
	if m & mods.NOFAIL > 0:
		r += "NF"
	if m & mods.EASY > 0:
		r += "EZ"
	if m & mods.HIDDEN > 0:
		r += "HD"
	if m & mods.HARDROCK > 0:
		r += "HR"
	if m & mods.DOUBLETIME > 0:
		r += "DT"
	if m & mods.HALFTIME > 0:
		r += "HT"
	if m & mods.FLASHLIGHT > 0:
		r += "FL"
	if m & mods.SPUNOUT > 0:
		r += "SO"
	if m & mods.TOUCHSCREEN > 0:
		r += "TD"
	if m & mods.RELAX > 0:
		r += "RX"
	return r
