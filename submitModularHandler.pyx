import base64
import collections
import json
import sys
import threading
import traceback
from urllib.parse import urlencode

import requests
import tornado.gen
import tornado.web
import math

import secret.achievements.utils
from common.constants import gameModes
from common.constants import mods
from common.log import logUtils as log
from common.ripple import userUtils
from common.ripple import scoreUtils
from common.web import requestsManager
from constants import exceptions
from constants import rankedStatuses
from constants.exceptions import ppCalcException
from helpers import aeshelper
from helpers import replayHelper
from helpers import leaderboardHelper
from objects import beatmap
from objects import glob
from objects import score
from objects import scoreboard
from objects import relaxboard
from objects import rxscore
from helpers.generalHelper import zingonify
from objects.charts import BeatmapChart, OverallChart
from common import generalUtils
from secret.discord_hooks import Webhook


MODULE_NAME = "submit_modular"
class handler(requestsManager.asyncRequestHandler):
	"""
	Handler for /web/osu-submit-modular.php
	"""
	@tornado.web.asynchronous
	@tornado.gen.engine
	#@sentry.captureTornado
	def asyncPost(self):
		newCharts = self.request.uri == "/web/osu-submit-modular-selector.php"
		try:
			# Resend the score in case of unhandled exceptions
			keepSending = True

			# Get request ip
			ip = self.getRequestIP()

			# Print arguments
			if glob.debug:
				requestsManager.printArguments(self)

			# Check arguments
			if not requestsManager.checkArguments(self.request.arguments, ["score", "iv", "pass"]):
				raise exceptions.invalidArgumentsException(MODULE_NAME)

			# TODO: Maintenance check

			# Get parameters and IP
			scoreDataEnc = self.get_argument("score")
			iv = self.get_argument("iv")
			password = self.get_argument("pass")
			ip = self.getRequestIP()

			# Get bmk and bml (notepad hack check)
			if "bmk" in self.request.arguments and "bml" in self.request.arguments:
				bmk = self.get_argument("bmk")
				bml = self.get_argument("bml")
			else:
				bmk = None
				bml = None

			# Get right AES Key
			if "osuver" in self.request.arguments:
				aeskey = "osu!-scoreburgr---------{}".format(self.get_argument("osuver"))
			else:
				aeskey = "h89f2-890h2h89b34g-h80g134n90133"

			# Get score data
			log.debug("Decrypting score data...")
			scoreData = aeshelper.decryptRinjdael(aeskey, iv, scoreDataEnc, True).split(":")

			username = scoreData[1].strip()

			# Login and ban check
			userID = userUtils.getID(username)
			# User exists check
			if userID == 0:
				raise exceptions.loginFailedException(MODULE_NAME, userID)
			# Bancho session/username-pass combo check
			if not userUtils.checkLogin(userID, password, ip):
				raise exceptions.loginFailedException(MODULE_NAME, username)
			# 2FA Check
			if userUtils.check2FA(userID, ip):
				raise exceptions.need2FAException(MODULE_NAME, userID, ip)
			# Generic bancho session check
			#if not userUtils.checkBanchoSession(userID):
				# TODO: Ban (see except exceptions.noBanchoSessionException block)
			#	raise exceptions.noBanchoSessionException(MODULE_NAME, username, ip)
			# Ban check
			if userUtils.isBanned(userID):
				raise exceptions.userBannedException(MODULE_NAME, username)
			# Data length check
			if len(scoreData) < 16:
				raise exceptions.invalidArgumentsException(MODULE_NAME)

			# Get restricted
			restricted = userUtils.isRestricted(userID)

			# Get variables for relax
			used_mods = int(scoreData[13])
			isRelaxing = used_mods & 128

			# Create score object and set its data
			s = rxscore.score() if isRelaxing else score.score()
			s.setDataFromScoreData(scoreData)

			if s.completed == -1:
				# Duplicated score
				log.warning("Duplicated score detected, this is normal right after restarting the server")
				return

			# Set score stuff missing in score data
			s.playerUserID = userID

			# Get beatmap info
			beatmapInfo = beatmap.beatmap()
			beatmapInfo.setDataFromDB(s.fileMd5)

			# Make sure the beatmap is submitted and updated
			if beatmapInfo.rankedStatus == rankedStatuses.NOT_SUBMITTED or beatmapInfo.rankedStatus == rankedStatuses.NEED_UPDATE or beatmapInfo.rankedStatus == rankedStatuses.UNKNOWN:
				log.debug("Beatmap is not submitted/outdated/unknown. Score submission aborted.")
				return

			if beatmapInfo.beatmapID == 888412 or beatmapInfo.beatmapID == 888413: # fucking readme re-ranking itself smh
				return

			# increment user playtime
			length = 0
			if s.passed:
				try:
					length = userUtils.getBeatmapTime(beatmapInfo.beatmapID)
				except Exception:
					log.error("Error while contacting mirror server.")
			else:
				length = math.ceil(int(self.get_argument("ft")) / 1000)

			userUtils.incrementPlaytime(userID, s.gameMode, length)
			# Calculate PP
			midPPCalcException = None
			try:
				s.calculatePP()
			except Exception as e:
				# Intercept ALL exceptions and bypass them.
				# We want to save scores even in case PP calc fails
				# due to some rippoppai bugs.
				# I know this is bad, but who cares since I'll rewrite
				# the scores server again.
				log.error("Caught an exception in pp calculation, re-raising after saving score in db")
				s.pp = 0
				midPPCalcException = e

			if (s.pp >= 2000 and bool(s.mods & 128) == True and s.gameMode == gameModes.STD) and restricted == False:
				userUtils.restrict(userID)
				userUtils.appendNotes(userID, "Restricted due to too high pp gain ({}pp)".format(s.pp))
				log.warning("**{}** ({}) has been restricted due to too high pp gain **({}pp)**".format(username, userID, s.pp), "cm")
			elif (s.pp >= 800 and bool(s.mods & 128) == False and s.gameMode == gameModes.STD) and restricted == False:
				userUtils.restrict(userID)
				userUtils.appendNotes(userID, "Restricted due to too high pp gain ({}pp)".format(s.pp))
				log.warning("**{}** ({}) has been restricted due to too high pp gain **({}pp)**".format(username, userID, s.pp), "cm")
				

			# Restrict obvious cheaters™
			if not restricted:
				if s.gameMode == gameModes.STD:
					gamemode = 0
				elif s.gameMode == gameModes.TAIKO:
					gamemode = 1
				elif s.gameMode == gameModes.CTB:
					gamemode = 2
				elif s.gameMode == gameModes.MANIA:
					gamemode = 3

				relax = 1 if used_mods & 128 else 0
				flashlight = 1 if used_mods & 1024 else 0

				pp_limit = scoreUtils.getPPLimit(gamemode, relax, flashlight)
				unrestricted_user = userUtils.noPPLimit(userID, relax)

				if (s.pp >= pp_limit) and not unrestricted_user:
					userUtils.restrict(userID)
					userUtils.appendNotes(userID, "[GM: {gamemode}] Restricted due to too high pp gain{fl} ({pp}pp).".format(gamemode=s.gameMode, fl=' with flashlight' if flashlight else '', pp=s.pp))
					log.warning("[GM: {gamemode}] **{username}** ({userid}) has been restricted due to too high pp gain{fl} **({pp}pp)**.".format(gamemode=s.gameMode, username=username, userid=userID, fl='with flashlight' if flashlight else '', pp=s.pp), "cm")

				# Make sure the score is not memed
				if s.gameMode == gameModes.MANIA and s.score > 1000000:
					userUtils.ban(userID)
					userUtils.appendNotes(userID, "Banned due to mania score > 1000000.")

				# Ci metto la faccia, ci metto la testa e ci metto il mio cuore
				if ((s.mods & mods.DOUBLETIME) > 0 and (s.mods & mods.HALFTIME) > 0) \
						or ((s.mods & mods.HARDROCK) > 0 and (s.mods & mods.EASY) > 0) \
						or ((s.mods & mods.SUDDENDEATH) > 0 and (s.mods & mods.NOFAIL) > 0) \
						or ((s.mods & mods.RELAX) > 0 and (s.mods & mods.RELAX2) > 0):
					userUtils.ban(userID)
					userUtils.appendNotes(userID, "Impossible mod combination ({}).".format(s.mods))

				# Check notepad hack
				if bmk is None and bml is None:
					# No bmk and bml params passed, edited or super old client
					#log.warning("{} ({}) most likely submitted a score from an edited client or a super old client".format(username, userID), "cm")
					pass
				elif bmk != bml:
					# bmk and bml passed and they are different, restrict the user
					userUtils.restrict(userID)
					userUtils.appendNotes(userID, "Restricted due to notepad hack")
					log.warning("**{}** ({}) has been restricted due to notepad hack".format(username, userID), "cm")
					return

				# Right before submitting the score, get the personal best score object (we need it for charts)
			if s.passed and s.oldPersonalBest > 0:
					oldPersonalBestRank = glob.personalBestCache.get(userID, s.fileMd5)
					if oldPersonalBestRank == 0:
						oldScoreboard = scoreboard.scoreboard(username, s.gameMode, beatmapInfo, False)
						oldScoreboard.setPersonalBestRank()
						oldPersonalBestRank = max(oldScoreboard.personalBestRank, 0)
					oldPersonalBest = score.score(s.oldPersonalBest, oldPersonalBestRank)
			else:
					oldPersonalBestRank = 0
					oldPersonalBest = None

			# Save score in db
			s.saveScoreInDB()

			if not restricted:
				# Client anti-cheat flags
				haxFlags = scoreData[17].count(' ') # 4 is normal, 0 is irregular but inconsistent.
				if haxFlags != 4 and haxFlags != 0 and s.completed > 1 and s.pp > 100:

					flagsReadable = generalUtils.calculateFlags(int(haxFlags), used_mods, s.gameMode)
					if len(flagsReadable) > 1:
						userUtils.appendNotes(userID, "-- has received clientside flags: {} [{}] (cheated score id: {})".format(haxFlags, flagsReadable, s.scoreID))
						log.warning("**{}** (https://mikoto.ga/{relax}u/{}) has received clientside anti cheat flags.\n\nFlags: {}.\n[{}]\n\nScore ID: {scoreID}\nReplay: https://mikoto.ga/web/replays/{scoreID}".format(username, userID, haxFlags, flagsReadable, scoreID=s.scoreID, relax="rx/" if isRelaxing else ""), "cm")

				if s.score < 0 or s.score > (2 ** 63) - 1:
					userUtils.ban(userID)
					userUtils.appendNotes(userID, "Banned due to negative score.")

			# NOTE: Process logging was removed from the client starting from 20180322
			# Save replay for all passed scores
			# Make sure the score has an id as well (duplicated?, query error?)
			if s.passed and s.scoreID > 0:
				if "score" in self.request.files:
					# Save the replay if it was provided
					log.debug("Saving replay ({})...".format(s.scoreID))
					replay = self.request.files["score"][0]["body"]
					with open(".data/replays/replay_{}.osr".format(s.scoreID), "wb") as f:
						f.write(replay)

					# Send to cono ALL passed replays, even non high-scores
					if glob.conf.config["cono"]["enable"]:
						if isRelaxing:
							threading.Thread(target=lambda: glob.redis.publish(
								"cono:analyze", json.dumps({
									"score_id": s.scoreID,
									"beatmap_id": beatmapInfo.beatmapID,
									"user_id": s.playerUserID,
									"game_mode": s.gameMode,
									"pp": s.pp,
									"replay_data": base64.b64encode(
										replayHelper.rxbuildFullReplay(
											s.scoreID,
											rawReplay=self.request.files["score"][0]["body"]
										)
									).decode(),
								})
							)).start()
						else:
						# We run this in a separate thread to avoid slowing down scores submission,
						# as cono needs a full replay
							threading.Thread(target=lambda: glob.redis.publish(
								"cono:analyze", json.dumps({
									"score_id": s.scoreID,
									"beatmap_id": beatmapInfo.beatmapID,
									"user_id": s.playerUserID,
									"game_mode": s.gameMode,
									"pp": s.pp,
									"replay_data": base64.b64encode(
										replayHelper.buildFullReplay(
											s.scoreID,
											rawReplay=self.request.files["score"][0]["body"]
										)
									).decode(),
								})
							)).start()
				else:
					# Restrict if no replay was provided
					if not restricted:
						userUtils.restrict(userID)
						userUtils.appendNotes(userID, "Restricted due to missing replay while submitting a score.")
						log.warning("**{}** ({}) has been restricted due to not submitting a replay on map {}.".format(
							username, userID, s.fileMd5
						), "cm")

			# Update beatmap playcount (and passcount)
			beatmap.incrementPlaycount(s.fileMd5, s.passed)

			# Print out score submission
			songNameFull = beatmapInfo.songName.encode().decode("ASCII", "ignore")
			songNameShort = songNameFull[:48]+"..." if len(songNameFull) > 48 else songNameFull[:-4]
			log.info("[{}] {} has submitted a score on {}...".format("RELAX" if isRelaxing else "VANILLA", username, songNameShort))

			# Let the api know of this score
			if s.scoreID:
				glob.redis.publish("api:score_submission", s.scoreID)

			# Re-raise pp calc exception after saving score, cake, replay etc
			# so Sentry can track it without breaking score submission
			if midPPCalcException is not None:
				raise ppCalcException(midPPCalcException)

            # If there was no exception, update stats and build score submitted panel
			# Get "before" stats for ranking panel (only if passed)
			if s.passed:
				# Get stats and rank
				if isRelaxing:
					oldUserData = glob.userStatsCache.rxget(userID, s.gameMode)
					oldRank = userUtils.rxgetGameRank(userID, s.gameMode)
				else:
					oldUserData = glob.userStatsCache.get(userID, s.gameMode)
					oldRank = userUtils.getGameRank(userID, s.gameMode)

			# Always update users stats (total/ranked score, playcount, level, acc and pp)
			# even if not passed

			log.debug("[{}] Updating {}'s stats...".format("RELAX" if isRelaxing else "VANILLA", username))
			if isRelaxing:
				userUtils.rxupdateStats(userID, s)
			else:
				userUtils.updateStats(userID, s)

			# Get "after" stats for ranking panel
			# and to determine if we should update the leaderboard
			# (only if we passed that song)
			if s.passed:
				# Get new stats
				if isRelaxing:
					newUserData = userUtils.getRelaxStats(userID, s.gameMode)
					glob.userStatsCache.rxupdate(userID, s.gameMode, newUserData)
				else:
					newUserData = userUtils.getUserStats(userID, s.gameMode)
					glob.userStatsCache.update(userID, s.gameMode, newUserData)

				# Update leaderboard (global and country) if score/pp has changed
				if s.completed == 3 and newUserData["pp"] != oldUserData["pp"]:
					if isRelaxing:
						leaderboardHelper.rxupdate(userID, newUserData["pp"], s.gameMode)
						leaderboardHelper.rxupdateCountry(userID, newUserData["pp"], s.gameMode)
					else:
						leaderboardHelper.update(userID, newUserData["pp"], s.gameMode)
						leaderboardHelper.updateCountry(userID, newUserData["pp"], s.gameMode)

			# TODO: Update total hits and max combo
			# Update latest activity
			userUtils.updateLatestActivity(userID)

			# IP log
			userUtils.IPLog(userID, ip)

			# Score submission and stats update done
			log.debug("Score submission and user stats update done!")

			# Score has been submitted, do not retry sending the score if
			# there are exceptions while building the ranking panel
			keepSending = False

			# At the end, check achievements
			if s.passed:
				new_achievements = secret.achievements.utils.unlock_achievements(s, beatmapInfo, newUserData)

			# Output ranking panel only if we passed the song
			# and we got valid beatmap info from db
			if beatmapInfo is not None and beatmapInfo != False and s.passed:
				log.debug("Started building ranking panel.")

				if isRelaxing: # Relax
					# Trigger bancho stats cache update
					glob.redis.publish("peppy:update_rxcached_stats", userID)

					newScoreboard = relaxboard.scoreboard(username, s.gameMode, beatmapInfo, False)
					newScoreboard.setPersonalBestRank()
					personalBestID = newScoreboard.getPersonalBestID()
					assert personalBestID is not None
					currentPersonalBest = rxscore.score(personalBestID, newScoreboard.personalBestRank)

					# Get rank info (current rank, pp/score to next rank, user who is 1 rank above us)
					rankInfo = leaderboardHelper.rxgetRankInfo(userID, s.gameMode)

				else: # Vanilla
					# Trigger bancho stats cache update
					glob.redis.publish("peppy:update_cached_stats", userID)

					newScoreboard = scoreboard.scoreboard(username, s.gameMode, beatmapInfo, False)
					newScoreboard.setPersonalBestRank()
					personalBestID = newScoreboard.getPersonalBestID()
					assert personalBestID is not None
					currentPersonalBest = score.score(personalBestID, newScoreboard.personalBestRank)

					# Get rank info (current rank, pp/score to next rank, user who is 1 rank above us)
					rankInfo = leaderboardHelper.getRankInfo(userID, s.gameMode)

				if newCharts:
					log.debug("Using new charts")
					dicts = [
						collections.OrderedDict([
							("beatmapId", beatmapInfo.beatmapID),
							("beatmapSetId", beatmapInfo.beatmapSetID),
							("beatmapPlaycount", beatmapInfo.playcount + 1),
							("beatmapPasscount", beatmapInfo.passcount + (s.completed == 3)),
							("approvedDate", "")
						]),
						BeatmapChart(
							oldPersonalBest if s.completed == 3 else currentPersonalBest,
							currentPersonalBest if s.completed == 3 else s,
							beatmapInfo.beatmapID,
						),
						OverallChart(
							userID, oldUserData, newUserData, beatmapInfo, s, new_achievements, oldRank, rankInfo["currentRank"]
						)
					]
				else:
					log.debug("Using old charts")
					dicts = [
						collections.OrderedDict([
							("beatmapId", beatmapInfo.beatmapID),
							("beatmapSetId", beatmapInfo.beatmapSetID),
							("beatmapPlaycount", beatmapInfo.playcount),
							("beatmapPasscount", beatmapInfo.passcount),
							("approvedDate", "")
						]),
						collections.OrderedDict([
							("chartId", "overall"),
							("chartName", "Overall Ranking"),
							("chartEndDate", ""),
							("beatmapRankingBefore", oldPersonalBestRank),
							("beatmapRankingAfter", newScoreboard.personalBestRank),
							("rankedScoreBefore", oldUserData["rankedScore"]),
							("rankedScoreAfter", newUserData["rankedScore"]),
							("totalScoreBefore", oldUserData["totalScore"]),
							("totalScoreAfter", newUserData["totalScore"]),
							("playCountBefore", newUserData["playcount"]),
							("accuracyBefore", float(oldUserData["accuracy"])/100),
							("accuracyAfter", float(newUserData["accuracy"])/100),
							("rankBefore", oldRank),
							("rankAfter", rankInfo["currentRank"]),
							("toNextRank", rankInfo["difference"]),
							("toNextRankUser", rankInfo["nextUsername"]),
							("achievements", ""),
							("achievements-new", secret.achievements.utils.achievements_response(new_achievements)),
							("onlineScoreId", s.scoreID)
						])
					]
				output = "\n".join(zingonify(x) for x in dicts)

				log.debug("Generated output for online ranking screen!")
				log.debug(output)

				# Send message to #announce if we're rank #1
				if newScoreboard.personalBestRank == 1 and s.completed == 3 and not restricted:
					annmsg = "[{}] [https://mikoto.ga/u/{} {}] achieved rank #1 on [https://mikoto.ga/b/{} {}] ({})".format(
						"RELAX" if isRelaxing else "VANILLA",
						userID,
						username.encode().decode("ASCII", "ignore"),
						beatmapInfo.beatmapID,
						beatmapInfo.songName.encode().decode("ASCII", "ignore"),
						gameModes.getGamemodeFull(s.gameMode)
					)
					params = urlencode({"k": glob.conf.config["server"]["apikey"], "to": "#announce", "msg": annmsg})
					requests.get("{}/api/v1/fokabotMessage?{}".format(glob.conf.config["server"]["banchourl"], params))

					# Add the #1 to the database. Yes this is spaghetti.
					scoreUtils.newFirst(s.scoreID, userID, s.fileMd5, s.gameMode, isRelaxing)
					
					# upon new #1 = send the score to the discord bot
					# s=0 = regular && s=1 = relax
					ppGained = newUserData["pp"] - oldUserData["pp"]
					gainedRanks = oldRank - rankInfo["currentRank"]
					# webhook to discord

					#TEMPORARY mods handle
					ScoreMods = ""
					
					if s.mods == 0:
						ScoreMods += "nomod"
					if s.mods & mods.NOFAIL > 0:
						ScoreMods += "NF"
					if s.mods & mods.EASY > 0:
						ScoreMods += "EZ"
					if s.mods & mods.HIDDEN > 0:
						ScoreMods += "HD"
					if s.mods & mods.HARDROCK > 0:
						ScoreMods += "HR"
					if s.mods & mods.DOUBLETIME > 0:
						ScoreMods += "DT"
					if s.mods & mods.HALFTIME > 0:
						ScoreMods += "HT"
					if s.mods & mods.FLASHLIGHT > 0:
						ScoreMods += "FL"
					if s.mods & mods.SPUNOUT > 0:
						ScoreMods += "SO"
					if s.mods & mods.TOUCHSCREEN > 0:
						ScoreMods += "TD"
					if s.mods & mods.RELAX > 0:
						ScoreMods += "RX"
					if s.mods & mods.RELAX2 > 0:
						ScoreMods += "AP"


					url = glob.conf.config["webhooks"]["score"]
				
					embed = Webhook(url, color=0x35b75c)
					embed.set_author(name=username.encode().decode("ASCII", "ignore"), icon='https://i.imgur.com/rdm3W9t.png')
					embed.set_desc("[{}] Achieved #1 on mode **{}**, {} +{}!".format("RELAX" if isRelaxing else "VANILLA", gameModes.getGamemodeFull(s.gameMode), beatmapInfo.songName.encode().decode("ASCII", "ignore"), ScoreMods))
					embed.add_field(name='Total: {}pp'.format(float("{0:.2f}".format(s.pp))), value='Gained: +{}pp'.format(float("{0:.2f}".format(ppGained))))
					embed.add_field(name='Actual rank: {}'.format(rankInfo["currentRank"]), value='[Download Link](http://storage.ripple.moe/d/{})'.format(beatmapInfo.beatmapSetID))
					embed.set_image('https://assets.ppy.sh/beatmaps/{}/covers/cover.jpg'.format(beatmapInfo.beatmapSetID))
					embed.post()					

				# Write message to client
				self.write(output)
			else:
				# No ranking panel, send just "ok"
				self.write("ok")

			# Send username change request to bancho if needed
			# (key is deleted bancho-side)
			newUsername = glob.redis.get("ripple:change_username_pending:{}".format(userID))
			if newUsername is not None:
				log.debug("Sending username change request for user {} to Bancho".format(userID))
				glob.redis.publish("peppy:change_username", json.dumps({
					"userID": userID,
					"newUsername": newUsername.decode("utf-8")
				}))

			# Datadog stats
			glob.dog.increment(glob.DATADOG_PREFIX+".submitted_scores")
		except exceptions.invalidArgumentsException:
			pass
		except exceptions.loginFailedException:
			self.write("error: pass")
		except exceptions.need2FAException:
			# Send error pass to notify the user
			# resend the score at regular intervals
			# for users with memy connection
			self.set_status(408)
			self.write("error: 2fa")
		except exceptions.userBannedException:
			self.write("error: ban")
		except exceptions.noBanchoSessionException:
			# We don't have an active bancho session.
			# Don't ban the user but tell the client to send the score again.
			# Once we are sure that this error doesn't get triggered when it
			# shouldn't (eg: bancho restart), we'll ban users that submit
			# scores without an active bancho session.
			# We only log through schiavo atm (see exceptions.py).
			self.set_status(408)
			self.write("error: pass")
		except:
			# Try except block to avoid more errors
			try:
				log.error("Unknown error in {}!\n```{}\n{}```".format(MODULE_NAME, sys.exc_info(), traceback.format_exc()))
				if glob.sentry:
					yield tornado.gen.Task(self.captureException, exc_info=True)
			except:
				pass

			# Every other exception returns a 408 error (timeout)
			# This avoids lost scores due to score server crash
			# because the client will send the score again after some time.
			if keepSending:
				self.set_status(408)