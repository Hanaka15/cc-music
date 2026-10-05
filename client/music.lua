-- CC Music Player — CC:HQ Speakers + yt-dlp API (Render / Docker)
-- Requires CC:HQ Speakers (speakerPlay). Set your deployed API URL below.

local api_base_url = "https://cc-music-z3gz.onrender.com/"
local version = "1"

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
local is_loading = false
local queue = {}
local now_playing = nil
local looping = 0 -- 0 off, 1 queue, 2 song
local volume = 1.0
local is_error = false
local progress_text = nil
local status_text = nil
local play_generation = 0
local seen_playing = false
local play_started_at = 0

local function collectSpeakers()
	local found = { peripheral.find("speaker") }
	local usable = {}
	for _, speaker in ipairs(found) do
		if type(speaker) == "table" and type(speaker.speakerPlay) == "function" then
			table.insert(usable, speaker)
		end
	end
	return usable
end

local speakers = collectSpeakers()
if #speakers == 0 then
	error("No HQ Speakers found. This player needs CC:HQ Speakers (speakerPlay).", 0)
end

local speaker = speakers[1]

local function eachSpeaker(fn)
	for _, sp in ipairs(speakers) do
		pcall(fn, sp)
	end
end

local function stopAll()
	eachSpeaker(function(sp)
		if sp.speakerStop then sp.speakerStop() end
	end)
	paused = false
	is_loading = false
	seen_playing = false
end

local function applyVolume()
	eachSpeaker(function(sp)
		if sp.speakerVolume then sp.speakerVolume(volume) end
	end)
end

local function truncate(text, max_len)
	text = tostring(text or "")
	if #text <= max_len then return text end
	return text:sub(1, math.max(1, max_len - 1)) .. "…"
end

local function streamUrlFor(track)
	if track.stream and #track.stream > 0 then
		return track.stream
	end
	return api_base_url:gsub("/+$", "") .. "/stream/" .. textutils.urlEncode(track.id)
end

local function prepareUrlFor(track)
	if track.prepare and #track.prepare > 0 then
		return track.prepare
	end
	local stream = streamUrlFor(track)
	return stream:gsub("/stream/", "/prepare/", 1)
end

--- Warm API cache (yt-dlp) before HQ Speakers fetch the mp3.
local function prepareTrack(track)
	local url = prepareUrlFor(track)
	status_text = "Preparing audio (can take 30–60s)..."
	os.queueEvent("redraw_screen")
	local ok, res = pcall(http.get, url)
	if not ok or not res then
		return false, "prepare failed (HTTP). Is the API awake?"
	end
	local body = res.readAll()
	res.close()
	local data = textutils.unserialiseJSON(body)
	if type(data) ~= "table" or data.ok ~= true then
		local err = type(data) == "table" and data.error or body
		return false, tostring(err or "prepare failed")
	end
	return true
end

local function playTrack(track)
	play_generation = play_generation + 1
	local gen = play_generation
	now_playing = track
	playing = true
	paused = false
	is_loading = true
	is_error = false
	progress_text = nil
	seen_playing = false
	play_started_at = os.clock()
	stopAll()
	-- stopAll cleared flags; restore play intent
	playing = true
	is_loading = true
	now_playing = track
	play_started_at = os.clock()
	applyVolume()
	eachSpeaker(function(sp)
		if sp.setLooping then sp.setLooping(looping == 2) end
	end)
	os.queueEvent("redraw_screen")

	-- Prepare in background so UI stays responsive
	local okPrep, prepErr = prepareTrack(track)
	if gen ~= play_generation then return end
	if not okPrep then
		is_loading = false
		is_error = true
		playing = false
		status_text = tostring(prepErr)
		os.queueEvent("redraw_screen")
		return
	end

	status_text = "Starting speakers..."
	os.queueEvent("redraw_screen")
	local url = streamUrlFor(track)
	local ok, err = pcall(function()
		local started = speaker.speakerPlay(url, volume)
		if started == false then
			error("speakerPlay returned false")
		end
	end)
	if gen ~= play_generation then return end
	is_loading = false
	if not ok then
		is_error = true
		playing = false
		status_text = tostring(err)
	else
		status_text = nil
		play_started_at = os.clock()
	end
	os.queueEvent("redraw_screen")
end

local function advanceQueue()
	if looping == 2 and now_playing then
		playTrack(now_playing)
		return
	end
	if looping == 1 and now_playing then
		table.insert(queue, now_playing)
	end
	if #queue > 0 then
		playTrack(table.remove(queue, 1))
	else
		now_playing = nil
		playing = false
		paused = false
		is_loading = false
		status_text = nil
		stopAll()
		os.queueEvent("redraw_screen")
	end
end

local function redrawScreen()
	if waiting_for_input then return end
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
		term.setBackgroundColor(colors.black)
		if now_playing then
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
		if is_error then
			term.setTextColor(colors.red)
			term.write(truncate(status_text or "Play error", width - 2))
		elseif is_loading then
			term.setTextColor(colors.yellow)
			term.write(truncate(status_text or "Loading...", width - 2))
		elseif paused then
			term.setTextColor(colors.yellow)
			term.write("Paused")
		elseif playing then
			term.setTextColor(colors.lime)
			term.write("Streaming (HQ)")
			if progress_text then
				term.setTextColor(colors.lightGray)
				term.write("  " .. progress_text)
			end
		elseif status_text then
			term.setTextColor(colors.orange)
			term.write(truncate(status_text, width - 2))
		end

		term.setBackgroundColor(colors.gray)
		term.setTextColor(colors.white)
		term.setCursorPos(2, 6)
		term.write(playing and not paused and not is_loading and " Stop " or " Play ")
		term.setCursorPos(9, 6)
		term.write(paused and " Resume " or " Pause ")
		term.setCursorPos(18, 6)
		term.write(" Skip ")
		term.setCursorPos(25, 6)
		if looping ~= 0 then
			term.setTextColor(colors.black)
			term.setBackgroundColor(colors.white)
		end
		term.write(looping == 0 and " Loop Off " or looping == 1 and " Loop Queue " or " Loop Song ")

		term.setBackgroundColor(colors.black)
		paintutils.drawBox(2, 8, 25, 8, colors.gray)
		local filled = math.floor(24 * (volume / 3) + 0.5) - 1
		if filled >= 0 then paintutils.drawBox(2, 8, 2 + filled, 8, colors.white) end
		term.setCursorPos(2, 9)
		term.setTextColor(colors.gray)
		term.write("First play may take ~1 min (API prepare)")

		local row = 11
		for i = 1, #queue do
			if row >= height then break end
			term.setTextColor(colors.white)
			term.setCursorPos(2, row)
			term.write(truncate(queue[i].name, width - 2))
			term.setTextColor(colors.lightGray)
			term.setCursorPos(2, row + 1)
			term.write(truncate(queue[i].artist, width - 2))
			row = row + 2
		end
	else
		paintutils.drawFilledBox(2, 3, width - 1, 5, colors.lightGray)
		term.setBackgroundColor(colors.lightGray)
		term.setCursorPos(3, 4)
		term.setTextColor(colors.black)
		term.write(truncate(last_search or "Search YouTube...", width - 4))

		if in_search_result and search_results then
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
			term.setCursorPos(2, 6) term.clearLine() term.write("Play now")
			term.setCursorPos(2, 8) term.clearLine() term.write("Play next")
			term.setCursorPos(2, 10) term.clearLine() term.write("Add to queue")
			term.setCursorPos(2, 13) term.clearLine() term.write("Cancel")
		elseif search_results then
			term.setBackgroundColor(colors.black)
			if type(search_results) == "table" and search_results.error then
				term.setTextColor(colors.red)
				term.setCursorPos(2, 7)
				term.write(truncate(tostring(search_results.error), width - 2))
			else
				for i = 1, #search_results do
					local y = 7 + (i - 1) * 2
					if y + 1 > height then break end
					term.setTextColor(colors.white)
					term.setCursorPos(2, y)
					term.write(truncate(search_results[i].name, width - 2))
					term.setTextColor(colors.lightGray)
					term.setCursorPos(2, y + 1)
					term.write(truncate(search_results[i].artist, width - 2))
				end
			end
		else
			term.setBackgroundColor(colors.black)
			term.setCursorPos(2, 7)
			if search_error then
				term.setTextColor(colors.red)
				term.write("Network error")
			elseif last_search_url then
				term.setTextColor(colors.lightGray)
				term.write("Searching...")
			else
				term.setTextColor(colors.lightGray)
				term.write("Search YouTube (yt-dlp API).")
			end
		end
	end
end

local function uiLoop()
	applyVolume()
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
						last_search_url = api_base_url:gsub("/+$", "") .. "/?v=" .. version .. "&search=" .. textutils.urlEncode(input)
						http.request(last_search_url)
						search_results = nil
						search_error = false
					else
						last_search = ""
						last_search_url = api_base_url:gsub("/+$", "") .. "/?v=" .. version .. "&search="
						http.request(last_search_url)
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
					if button ~= 1 then return end
					if not in_search_result and y == 1 then
						tab = x < width / 2 and 1 or 2
						redrawScreen()
						return
					end
					if tab == 2 and not in_search_result then
						if y >= 3 and y <= 5 then
							waiting_for_input = true
							return
						end
						if search_results and type(search_results) == "table" and #search_results > 0 then
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
						local t = search_results[clicked_result]
						if y == 6 then
							in_search_result = false
							queue = {}
							tab = 1
							-- run play off the click handler so prepare can block
							os.queueEvent("play_track", t)
						elseif y == 8 then
							in_search_result = false
							table.insert(queue, 1, t)
						elseif y == 10 then
							in_search_result = false
							table.insert(queue, t)
						elseif y == 13 then
							in_search_result = false
						end
						redrawScreen()
					elseif tab == 1 then
						if y == 6 then
							if x >= 2 and x < 8 then
								if playing and not paused and not is_loading then
									play_generation = play_generation + 1
									playing = false
									stopAll()
									status_text = nil
								elseif paused then
									paused = false
									if speaker.speakerResume then speaker.speakerResume() end
								elseif now_playing and not is_loading then
									os.queueEvent("play_track", now_playing)
								elseif #queue > 0 and not is_loading then
									os.queueEvent("play_track", table.remove(queue, 1))
								end
							elseif x >= 9 and x < 17 then
								if playing and not is_loading then
									if paused then
										paused = false
										if speaker.speakerResume then speaker.speakerResume() end
									else
										paused = true
										if speaker.speakerPause then speaker.speakerPause() end
									end
								end
							elseif x >= 18 and x < 24 then
								if (now_playing or #queue > 0) and not is_loading then
									stopAll()
									advanceQueue()
								end
							elseif x >= 25 then
								looping = (looping + 1) % 3
								eachSpeaker(function(sp)
									if sp.setLooping then sp.setLooping(looping == 2) end
								end)
							end
						elseif y == 8 and x >= 1 and x < 26 then
							volume = math.max(0, math.min(3, (x - 1) / 24 * 3))
							applyVolume()
						end
						redrawScreen()
					end
				end,
				function()
					local _, button, x, y = os.pullEvent("mouse_drag")
					if button == 1 and tab == 1 and y >= 7 and y <= 9 and x >= 1 and x < 26 then
						volume = math.max(0, math.min(3, (x - 1) / 24 * 3))
						applyVolume()
						redrawScreen()
					end
				end,
				function()
					os.pullEvent("redraw_screen")
					redrawScreen()
				end,
				function()
					local _, track = os.pullEvent("play_track")
					playTrack(track)
				end
			)
		end
	end
end

local function httpLoop()
	while true do
		parallel.waitForAny(
			function()
				local _, url, handle = os.pullEvent("http_success")
				if url == last_search_url then
					search_results = textutils.unserialiseJSON(handle.readAll())
					os.queueEvent("redraw_screen")
				end
			end,
			function()
				local _, url = os.pullEvent("http_failure")
				if url == last_search_url then
					search_error = true
					os.queueEvent("redraw_screen")
				end
			end
		)
	end
end

local function watchdogLoop()
	while true do
		sleep(1)
		if playing and not paused and not is_loading and now_playing then
			local is_on = false
			local streaming = false
			if speaker.speakerIsPlaying then
				local ok, v = pcall(speaker.speakerIsPlaying)
				if ok then is_on = v and true or false end
			end
			if speaker.isStreaming then
				local ok, v = pcall(speaker.isStreaming)
				if ok then streaming = v and true or false end
			end
			local q = 0
			if speaker.speakerQueueSize then
				local qok, qn = pcall(speaker.speakerQueueSize)
				if qok and type(qn) == "number" then q = qn end
			end

			if is_on or streaming or q > 0 then
				seen_playing = true
			end

			-- Only advance after we actually heard playback, and after a grace period.
			local elapsed = os.clock() - play_started_at
			if seen_playing and not is_on and not streaming and q == 0 and elapsed > 3 then
				if looping == 2 then
					playTrack(now_playing)
				else
					advanceQueue()
				end
			end

			if speaker.speakerProgress then
				local pok, prog = pcall(speaker.speakerProgress)
				if pok and type(prog) == "table" then
					local samples = prog.elapsed or prog.elapsedSamples
					local rate = prog.sampleRate or 48000
					if type(samples) == "number" and rate > 0 then
						local secs = math.floor(samples / rate)
						progress_text = string.format("%d:%02d", math.floor(secs / 60), secs % 60)
						if tab == 1 then os.queueEvent("redraw_screen") end
					end
				end
			end
		end
	end
end

parallel.waitForAny(uiLoop, httpLoop, watchdogLoop)
