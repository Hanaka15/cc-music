-- Computercraft Streaming Music Program (Version 2.2-hq)
-- Based on https://pastebin.com/Rc1PCzLH
-- Audio still uses the iPod DFPWM API + playAudio (API does not serve MP3).
-- Controls use CC:HQ Speakers: speakerStop, speakerVolume, speakerPause/Resume,
-- speakerIsPlaying, speakerProgress.

local api_base_url = "https://ipod-2to6magyna-uc.a.run.app/"
local version = "2.1"

local width, height = term.getSize()
local tab = 1

local waiting_for_input = false
local last_search = nil
local last_search_url = nil
local search_results = nil
local search_error = false
local in_search_result = false
local clicked_result = nil

local playing = false
local paused = false
local queue = {}
local now_playing = nil
local looping = 0 -- 0 off, 1 queue, 2 song
local volume = 1.5

local playing_id = nil
local last_download_url = nil
local playing_status = 0
local is_loading = false
local is_error = false

local player_handle = nil
local size = nil
local decoder = require "cc.audio.dfpwm".make_decoder()
local needs_next_chunk = 0
local buffer

local progress_text = nil

local function collectSpeakers()
	local found = { peripheral.find("speaker") }
	local usable = {}
	for _, speaker in ipairs(found) do
		if type(speaker) == "table" and type(speaker.playAudio) == "function" then
			table.insert(usable, speaker)
		end
	end
	return usable
end

local speakers = collectSpeakers()
if #speakers == 0 then
	error("No speakers attached. Connect a CC speaker (HQ Speakers upgrades the same block).", 0)
end

local has_hq = type(speakers[1].speakerStop) == "function"

-- HQ Speakers sends one queued PCM chunk to the client every game tick and drops
-- overflow. A vanilla 16KiB DFPWM chunk is ~2.7s of audio, so feeding those makes
-- playback race and the decoder hit "too long without yielding".
-- 48000 samples/sec / 20 ticks / 8 samples-per-DFPWM-byte = 300 bytes/tick.
local CHUNK_SIZE = has_hq and 300 or (16 * 1024)

local function eachSpeaker(fn)
	for _, speaker in ipairs(speakers) do
		pcall(fn, speaker)
	end
end

local function stopAllSpeakers()
	eachSpeaker(function(speaker)
		if type(speaker.speakerStop) == "function" then
			speaker.speakerStop()
		elseif type(speaker.stop) == "function" then
			speaker.stop()
		end
	end)
	paused = false
	os.queueEvent("playback_stopped")
end

local function applyVolume()
	eachSpeaker(function(speaker)
		if type(speaker.speakerVolume) == "function" then
			speaker.speakerVolume(volume)
		end
	end)
end

local function pausePlayback()
	if not playing or paused then
		return
	end
	paused = true
	eachSpeaker(function(speaker)
		if type(speaker.speakerPause) == "function" then
			speaker.speakerPause()
		end
	end)
	os.queueEvent("playback_stopped")
	os.queueEvent("audio_update")
	os.queueEvent("redraw_screen")
end

local function resumePlayback()
	if not playing or not paused then
		return
	end
	paused = false
	eachSpeaker(function(speaker)
		if type(speaker.speakerResume) == "function" then
			speaker.speakerResume()
		end
	end)
	os.queueEvent("audio_update")
	os.queueEvent("redraw_screen")
end

local function syncLoopMode()
	-- HQ setLooping only applies to speakerPlay file/stream tracks.
	-- Song-loop for DFPWM is still handled in audioLoop; this keeps HQ state consistent.
	local song_loop = looping == 2
	eachSpeaker(function(speaker)
		if type(speaker.setLooping) == "function" then
			speaker.setLooping(song_loop)
		end
	end)
end

local function formatProgress()
	local speaker = speakers[1]
	if type(speaker.speakerProgress) ~= "function" then
		return nil
	end
	local ok, prog = pcall(speaker.speakerProgress)
	if not ok or type(prog) ~= "table" then
		return nil
	end

	local elapsed = prog.elapsed or prog.elapsedSamples or prog.position
	local total = prog.total or prog.totalSamples or prog.duration
	local rate = prog.sampleRate or prog.rate or 48000

	if type(elapsed) == "number" and type(rate) == "number" and rate > 0 then
		local secs = math.floor(elapsed / rate)
		local m = math.floor(secs / 60)
		local s = secs % 60
		local text = string.format("%d:%02d", m, s)
		if type(total) == "number" and total > 0 then
			local tsecs = math.floor(total / rate)
			text = text .. string.format(" / %d:%02d", math.floor(tsecs / 60), tsecs % 60)
		end
		return text
	end
	return nil
end

local function truncate(text, max_len)
	text = tostring(text or "")
	if #text <= max_len then
		return text
	end
	return text:sub(1, math.max(1, max_len - 1)) .. "…"
end

local function advanceQueue(from_end_of_track)
	if looping == 2 or (looping == 1 and #queue == 0 and now_playing) then
		playing_id = nil
		return
	end

	if looping == 1 and now_playing then
		table.insert(queue, now_playing)
	end

	if #queue > 0 then
		now_playing = table.remove(queue, 1)
		playing_id = nil
		playing = true
		paused = false
		is_error = false
	else
		now_playing = nil
		playing = false
		paused = false
		playing_id = nil
		is_loading = false
		is_error = false
		-- Do not speakerStop here: HQ still has a short buffer of the song end.
	end
end

function redrawScreen()
	if waiting_for_input then
		return
	end

	term.setCursorBlink(false)
	term.setBackgroundColor(colors.black)
	term.clear()

	term.setCursorPos(1, 1)
	term.setBackgroundColor(colors.gray)
	term.clearLine()

	local tabs = { " Now Playing ", " Search " }
	for i = 1, #tabs do
		if tab == i then
			term.setTextColor(colors.black)
			term.setBackgroundColor(colors.white)
		else
			term.setTextColor(colors.white)
			term.setBackgroundColor(colors.gray)
		end
		term.setCursorPos((math.floor((width / #tabs) * (i - 0.5))) - math.ceil(#tabs[i] / 2) + 1, 1)
		term.write(tabs[i])
	end

	if tab == 1 then
		drawNowPlaying()
	else
		drawSearch()
	end
end

function drawNowPlaying()
	term.setBackgroundColor(colors.black)

	if now_playing ~= nil then
		term.setTextColor(colors.white)
		term.setCursorPos(2, 3)
		term.write(truncate(now_playing.name, width - 2))
		term.setTextColor(colors.lightGray)
		term.setCursorPos(2, 4)
		term.write(truncate(now_playing.artist, width - 2))
	else
		term.setTextColor(colors.lightGray)
		term.setCursorPos(2, 3)
		term.write("Not playing")
	end

	term.setCursorPos(2, 5)
	term.setBackgroundColor(colors.black)
	if is_loading then
		term.setTextColor(colors.gray)
		term.write("Loading...")
	elseif is_error then
		term.setTextColor(colors.red)
		term.write("Network error")
	elseif paused then
		term.setTextColor(colors.yellow)
		term.write("Paused")
		if progress_text then
			term.write("  " .. progress_text)
		end
	elseif playing then
		term.setTextColor(colors.lime)
		local status = "Playing"
		if has_hq and type(speakers[1].speakerIsPlaying) == "function" then
			local ok, is_on = pcall(speakers[1].speakerIsPlaying)
			if ok and is_on == false and not is_loading then
				status = "Buffering"
			end
		end
		term.write(status)
		if progress_text then
			term.setTextColor(colors.lightGray)
			term.write("  " .. progress_text)
		end
	end

	-- Row 6: Play/Stop | Pause | Skip | Loop
	local can_control = now_playing ~= nil or #queue > 0
	term.setBackgroundColor(colors.gray)

	term.setCursorPos(2, 6)
	if playing and not paused then
		term.setTextColor(colors.white)
		term.write(" Stop ")
	elseif can_control then
		term.setTextColor(colors.white)
		term.write(" Play ")
	else
		term.setTextColor(colors.lightGray)
		term.write(" Play ")
	end

	term.setCursorPos(9, 6)
	if has_hq and playing then
		term.setTextColor(colors.white)
		if paused then
			term.write(" Resume ")
		else
			term.write(" Pause ")
		end
	else
		term.setTextColor(colors.lightGray)
		term.write(" Pause ")
	end

	term.setCursorPos(18, 6)
	if can_control then
		term.setTextColor(colors.white)
	else
		term.setTextColor(colors.lightGray)
	end
	term.write(" Skip ")

	term.setCursorPos(25, 6)
	if looping ~= 0 then
		term.setTextColor(colors.black)
		term.setBackgroundColor(colors.white)
	else
		term.setTextColor(colors.white)
		term.setBackgroundColor(colors.gray)
	end
	if looping == 0 then
		term.write(" Loop Off ")
	elseif looping == 1 then
		term.write(" Loop Queue ")
	else
		term.write(" Loop Song ")
	end

	-- Volume
	term.setBackgroundColor(colors.black)
	paintutils.drawBox(2, 8, 25, 8, colors.gray)
	local filled = math.floor(24 * (volume / 3) + 0.5) - 1
	if filled >= 0 then
		paintutils.drawBox(2, 8, 2 + filled, 8, colors.white)
	end
	local pct = math.floor(100 * (volume / 3) + 0.5) .. "%"
	if volume < 0.6 then
		term.setCursorPos(2 + math.max(filled, 0) + 2, 8)
		term.setBackgroundColor(colors.gray)
		term.setTextColor(colors.white)
	else
		term.setCursorPos(math.max(2, 2 + filled - #pct), 8)
		term.setBackgroundColor(colors.white)
		term.setTextColor(colors.black)
	end
	term.write(pct)

	if has_hq then
		term.setBackgroundColor(colors.black)
		term.setTextColor(colors.gray)
		term.setCursorPos(2, 9)
		term.write("HQ Speakers")
	end

	if #queue > 0 then
		term.setBackgroundColor(colors.black)
		local row = 11
		for i = 1, #queue do
			if row >= height then
				break
			end
			term.setTextColor(colors.white)
			term.setCursorPos(2, row)
			term.write(truncate(queue[i].name, width - 2))
			term.setTextColor(colors.lightGray)
			term.setCursorPos(2, row + 1)
			term.write(truncate(queue[i].artist, width - 2))
			row = row + 2
		end
	end
end

function drawSearch()
	paintutils.drawFilledBox(2, 3, width - 1, 5, colors.lightGray)
	term.setBackgroundColor(colors.lightGray)
	term.setCursorPos(3, 4)
	term.setTextColor(colors.black)
	term.write(truncate(last_search or "Search...", width - 4))

	if search_results ~= nil then
		term.setBackgroundColor(colors.black)
		for i = 1, #search_results do
			local y = 7 + (i - 1) * 2
			if y + 1 > height then
				break
			end
			term.setTextColor(colors.white)
			term.setCursorPos(2, y)
			term.write(truncate(search_results[i].name, width - 2))
			term.setTextColor(colors.lightGray)
			term.setCursorPos(2, y + 1)
			term.write(truncate(search_results[i].artist, width - 2))
		end
	else
		term.setCursorPos(2, 7)
		term.setBackgroundColor(colors.black)
		if search_error then
			term.setTextColor(colors.red)
			term.write("Network error")
		elseif last_search_url ~= nil then
			term.setTextColor(colors.lightGray)
			term.write("Searching...")
		else
			term.setTextColor(colors.lightGray)
			term.write("Tip: paste YouTube video or playlist links.")
		end
	end

	if in_search_result then
		term.setBackgroundColor(colors.black)
		term.clear()
		term.setCursorPos(2, 2)
		term.setTextColor(colors.white)
		term.write(truncate(search_results[clicked_result].name, width - 2))
		term.setCursorPos(2, 3)
		term.setTextColor(colors.lightGray)
		term.write(truncate(search_results[clicked_result].artist, width - 2))

		term.setBackgroundColor(colors.gray)
		term.setTextColor(colors.white)
		term.setCursorPos(2, 6)
		term.clearLine()
		term.write("Play now")
		term.setCursorPos(2, 8)
		term.clearLine()
		term.write("Play next")
		term.setCursorPos(2, 10)
		term.clearLine()
		term.write("Add to queue")
		term.setCursorPos(2, 13)
		term.clearLine()
		term.write("Cancel")
	end
end

local function playSelectedResult()
	stopAllSpeakers()
	playing = true
	paused = false
	is_error = false
	playing_id = nil
	local result = search_results[clicked_result]
	if result.type == "playlist" then
		now_playing = result.playlist_items[1]
		queue = {}
		for i = 2, #result.playlist_items do
			table.insert(queue, result.playlist_items[i])
		end
	else
		now_playing = result
	end
	os.queueEvent("audio_update")
end

local function enqueueSelected(front)
	local result = search_results[clicked_result]
	if result.type == "playlist" then
		if front then
			for i = #result.playlist_items, 1, -1 do
				table.insert(queue, 1, result.playlist_items[i])
			end
		else
			for i = 1, #result.playlist_items do
				table.insert(queue, result.playlist_items[i])
			end
		end
	else
		if front then
			table.insert(queue, 1, result)
		else
			table.insert(queue, result)
		end
	end
	os.queueEvent("audio_update")
end

local function setVolumeFromX(x)
	volume = math.max(0, math.min(3, (x - 1) / 24 * 3))
	applyVolume()
end

function uiLoop()
	applyVolume()
	syncLoopMode()
	redrawScreen()

	while true do
		if waiting_for_input then
			parallel.waitForAny(
				function()
					term.setCursorPos(3, 4)
					term.setBackgroundColor(colors.white)
					term.setTextColor(colors.black)
					local input = read()
					if #input > 0 then
						last_search = input
						last_search_url = api_base_url .. "?v=" .. version .. "&search=" .. textutils.urlEncode(input)
						http.request(last_search_url)
						search_results = nil
						search_error = false
					else
						last_search = nil
						last_search_url = nil
						search_results = nil
						search_error = false
					end
					waiting_for_input = false
					os.queueEvent("redraw_screen")
				end,
				function()
					while waiting_for_input do
						local _, _, x, y = os.pullEvent("mouse_click")
						if y < 3 or y > 5 or x < 2 or x > width - 1 then
							waiting_for_input = false
							os.queueEvent("redraw_screen")
							break
						end
					end
				end
			)
		else
			parallel.waitForAny(
				function()
					local _, button, x, y = os.pullEvent("mouse_click")
					if button ~= 1 then
						return
					end

					if not in_search_result and y == 1 then
						tab = (x < width / 2) and 1 or 2
						redrawScreen()
						return
					end

					if tab == 2 and not in_search_result then
						if y >= 3 and y <= 5 and x >= 1 and x <= width - 1 then
							paintutils.drawFilledBox(2, 3, width - 1, 5, colors.white)
							term.setBackgroundColor(colors.white)
							waiting_for_input = true
							return
						end
						if search_results then
							for i = 1, #search_results do
								if y == 7 + (i - 1) * 2 or y == 8 + (i - 1) * 2 then
									in_search_result = true
									clicked_result = i
									redrawScreen()
									return
								end
							end
						end
					elseif tab == 2 and in_search_result then
						if y == 6 then
							in_search_result = false
							playSelectedResult()
						elseif y == 8 then
							in_search_result = false
							enqueueSelected(true)
						elseif y == 10 then
							in_search_result = false
							enqueueSelected(false)
						elseif y == 13 then
							in_search_result = false
						end
						redrawScreen()
					elseif tab == 1 then
						if y == 6 then
							-- Stop / Play
							if x >= 2 and x < 8 then
								if playing and not paused then
									playing = false
									paused = false
									playing_id = nil
									is_loading = false
									is_error = false
									stopAllSpeakers()
									os.queueEvent("audio_update")
								elseif paused then
									resumePlayback()
								elseif now_playing ~= nil then
									playing_id = nil
									playing = true
									paused = false
									is_error = false
									os.queueEvent("audio_update")
								elseif #queue > 0 then
									now_playing = table.remove(queue, 1)
									playing_id = nil
									playing = true
									paused = false
									is_error = false
									os.queueEvent("audio_update")
								end
							-- Pause / Resume
							elseif x >= 9 and x < 17 then
								if has_hq and playing then
									if paused then
										resumePlayback()
									else
										pausePlayback()
									end
								end
							-- Skip
							elseif x >= 18 and x < 24 then
								if now_playing ~= nil or #queue > 0 then
									is_error = false
									if playing then
										stopAllSpeakers()
									end
									if #queue > 0 then
										if looping == 1 and now_playing then
											table.insert(queue, now_playing)
										end
										now_playing = table.remove(queue, 1)
										playing_id = nil
										playing = true
										paused = false
									else
										now_playing = nil
										playing = false
										paused = false
										is_loading = false
										is_error = false
										playing_id = nil
									end
									os.queueEvent("audio_update")
								end
							-- Loop
							elseif x >= 25 and x < 38 then
								looping = (looping + 1) % 3
								syncLoopMode()
							end
						elseif y == 8 and x >= 1 and x < 26 then
							setVolumeFromX(x)
						end
						redrawScreen()
					end
				end,
				function()
					local _, button, x, y = os.pullEvent("mouse_drag")
					if button == 1 and tab == 1 and not in_search_result and y >= 7 and y <= 9 then
						if x >= 1 and x < 26 then
							setVolumeFromX(x)
							redrawScreen()
						end
					end
				end,
				function()
					os.pullEvent("redraw_screen")
					redrawScreen()
				end
			)
		end
	end
end

-- Wait until a speaker can take more audio. HQ Speakers' empty events use the
-- computer attachment name, which does not always match peripheral.getName(),
-- so never filter on the name — and always keep a timer so we cannot hang.
local function waitForSpeakerRoom(this_id)
	local timer = os.startTimer(0.1)
	while true do
		local ev, p1 = os.pullEvent()
		if ev == "speaker_audio_empty" or (ev == "timer" and p1 == timer) then
			return playing and not paused and playing_id == this_id
		elseif ev == "playback_stopped" then
			return playing and not paused and playing_id == this_id
		elseif not playing or paused or playing_id ~= this_id then
			return false
		end
	end
end

local function playBufferOnSpeakers(this_id)
	for _, speaker in ipairs(speakers) do
		while playing and not paused and playing_id == this_id do
			local ok, accepted = pcall(speaker.playAudio, buffer, volume)
			if not ok then
				return false, accepted
			end
			if accepted then
				break
			end
			if not waitForSpeakerRoom(this_id) then
				return true
			end
		end
		if not playing or paused or playing_id ~= this_id then
			return true
		end
	end

	-- HQ drains ~one chunk per tick. Sleep for this buffer's real duration so we
	-- feed realtime instead of stuffing the queue and then stalling.
	if has_hq and playing and not paused and playing_id == this_id and type(buffer) == "table" then
		local dur = #buffer / 48000
		if dur > 0 then
			sleep(dur)
		end
	end
	return true
end

function audioLoop()
	while true do
		if playing and now_playing and not paused then
			local this_id = now_playing.id
			if playing_id ~= this_id then
				-- Cut any leftover buffered audio from the previous track.
				eachSpeaker(function(speaker)
					if type(speaker.speakerStop) == "function" then
						speaker.speakerStop()
					elseif type(speaker.stop) == "function" then
						speaker.stop()
					end
				end)
				decoder = require "cc.audio.dfpwm".make_decoder()
				playing_id = this_id
				last_download_url = api_base_url .. "?v=" .. version .. "&id=" .. textutils.urlEncode(playing_id)
				playing_status = 0
				needs_next_chunk = 1
				progress_text = nil
				if player_handle then
					pcall(player_handle.close)
					player_handle = nil
				end
				http.request({ url = last_download_url, binary = true })
				is_loading = true
				os.queueEvent("redraw_screen")
				os.queueEvent("audio_update")
			elseif playing_status == 1 and needs_next_chunk == 1 then
				while playing and playing_id == this_id and not paused do
					local chunk = player_handle.read(size)
					if not chunk then
						if player_handle then
							player_handle.close()
							player_handle = nil
						end
						needs_next_chunk = 0
						playing_status = 0
						advanceQueue(true)
						os.queueEvent("redraw_screen")
						break
					end

					local decoded_ok, decoded = pcall(decoder, chunk)
					if not decoded_ok then
						needs_next_chunk = 2
						is_error = true
						playing = false
						break
					end
					buffer = decoded

					local ok, err = playBufferOnSpeakers(this_id)
					if not ok then
						needs_next_chunk = 2
						is_error = true
						playing = false
						break
					end
					if not playing or paused or playing_id ~= this_id then
						break
					end
				end
				os.queueEvent("audio_update")
				os.queueEvent("redraw_screen")
			end
		end
		os.pullEvent("audio_update")
	end
end

function httpLoop()
	while true do
		parallel.waitForAny(
			function()
				local _, url, handle = os.pullEvent("http_success")
				if url == last_search_url then
					search_results = textutils.unserialiseJSON(handle.readAll())
					os.queueEvent("redraw_screen")
				elseif url == last_download_url then
					is_loading = false
					player_handle = handle
					size = CHUNK_SIZE
					playing_status = 1
					os.queueEvent("redraw_screen")
					os.queueEvent("audio_update")
				end
			end,
			function()
				local _, url = os.pullEvent("http_failure")
				if url == last_search_url then
					search_error = true
					os.queueEvent("redraw_screen")
				elseif url == last_download_url then
					is_loading = false
					is_error = true
					playing = false
					playing_id = nil
					os.queueEvent("redraw_screen")
					os.queueEvent("audio_update")
				end
			end
		)
	end
end

function progressLoop()
	while true do
		sleep(0.5)
		if playing and now_playing and has_hq then
			local text = formatProgress()
			if text ~= progress_text then
				progress_text = text
				if tab == 1 and not in_search_result and not waiting_for_input then
					os.queueEvent("redraw_screen")
				end
			end
		elseif progress_text then
			progress_text = nil
		end
	end
end

parallel.waitForAny(uiLoop, audioLoop, httpLoop, progressLoop)
