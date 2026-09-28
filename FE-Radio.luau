-- GlassRadio MM2 | маленькое glass-окно: коды -> музыка, история "название - код"
-- Игра: Murder Mystery 2 (u66654135). Использует официальное радио (Inventory.PlaySong),
-- поэтому при Radio-пассе музыку слышат ВСЕ. Без пасса — локальный режим (только ты).
-- Управление: RightShift — показать/скрыть.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local MarketplaceService = game:GetService("MarketplaceService")
local HttpService = game:GetService("HttpService")
local UserInputService = game:GetService("UserInputService")

local LocalPlayer = Players.LocalPlayer
if not LocalPlayer then return end

local HISTORY_FILE = "GlassRadio_History.json"
local HISTORY_BAK = "GlassRadio_History.bak.json"
local MAX_HISTORY = 50

local notify -- прямое объявление: тосты создаются вместе с GUI ниже

-- чистим старую копию
pcall(function()
	if getgenv().GlassRadioGui and getgenv().GlassRadioGui.Parent then
		getgenv().GlassRadioGui:Destroy()
	end
	if getgenv().GlassRadioLoop then
		getgenv().GlassRadioLoop = false
	end
end)

-- ---------- helpers ----------
local function hasRadioPass()
	local ok, v = pcall(function()
		return LocalPlayer:GetAttribute("Radio")
	end)
	return ok and v == true
end

-- conoce juego: MM2 = официальное радио всем, остальное (включая Driving Empire) = локально,
-- пока ремоут их радио не изучен живьём. Проверка идёт по наличию ремоута, а не по названию игры.
local KNOWN_GAMES = {
	[66654135] = "Murder Mystery 2",
	[1202096104] = "Driving Empire",
}
local function currentGameName(): string?
	local id = 0
	pcall(function()
		id = game.GameId
	end)
	return KNOWN_GAMES[id]
end

local function radioMode(): string
	if hasRadioPass() then
		local ok, remote = pcall(function()
			return game.ReplicatedStorage.Remotes.Inventory.PlaySong
		end)
		if ok and remote ~= nil then
			return "mm2"
		end
	end
	return "local"
end

local function getRadioSound()
	local char = workspace:FindFirstChild(LocalPlayer.Name)
	if not char then return nil end
	local radio = char:FindFirstChild("Radio")
	if not radio then return nil end
	return radio:FindFirstChildOfClass("Sound")
end

local function normalizeCode(input: string): string?
	if not input or input == "" then return nil end
	-- берём самую длинную группу цифр (работает и для голого кода, и для ссылок вида asset/?id=... и rbxassetid://...)
	local best: string? = nil
	for run in string.gmatch(input, "%d+") do
		if not best or #run > #best then
			best = run
		end
	end
	if best and #best >= 3 and #best <= 15 then
		return best
	end
	return nil
end

local function toRadioUrl(code: string): string
	return "https://www.roblox.com/asset/?id=" .. code
end

local function fetchTrackName(code: string): string
	local ok, info = pcall(function()
		return MarketplaceService:GetProductInfo(tonumber(code))
	end)
	if ok and type(info) == "table" and info.Name and info.Name ~= "" then
		local n: string = tostring(info.Name)
		if #n > 32 then n = string.sub(n, 1, 32) .. "..." end
		return n
	end
	return "Трек " .. code
end

-- ---------- history ----------
local history: {{id: string, name: string}} = {}

local function readHistoryFile(path: string): {{id: string, name: string}}?
	local ok, content = pcall(function()
		if isfile(path) then
			return readfile(path)
		end
		return nil
	end)
	if not ok or not content then return nil end
	local ok2, data = pcall(function()
		return HttpService:JSONDecode(content)
	end)
	if ok2 and type(data) == "table" then
		return data
	end
	return nil
end

-- ---------- audio state (объявлено рано: нужно функциям сейва/истории ниже) ----------
local currentCode: string? = nil
local currentUrl: string? = nil
local volume: number = 1.0 -- абсолютная громкость 0..10, ползунок 0..100%
local prevFrac: number = 0.1 -- куда вернуть ползунок после выключения MAX
local localSound: Sound? = nil
-- очередь для кнопок следующий/предыдущий: снимок списка, из которого включили
local playCtx: { list: {{ code: string, title: string }}, index: number }? = nil
-- избранное: множество id + пауза мини-плеера (только у тебя)
local favorites: { [string]: boolean } = {}
local favNames: { [string]: string } = {}
local FAV_FILE = "GlassRadio_Fav.json"
local miniPaused = false
local miniPauseBtn -- кнопка создаётся ниже вместе с GUI
local toggleFav -- прямое объявление: назначается после refreshHistory
local lyItems -- очередь каталога (объявлена ниже)
local favWin -- окно избранного (создаётся ниже)
local refreshFavWin -- прямое объявление: назначается вместе с окном
local favOrder: {{ code: string, title: string }} = {} -- текущий список избранного для очереди

local function saveFav()
	local nameOf: { [string]: string } = {}
	for _, h in ipairs(history) do
		nameOf[h.id] = h.name
	end
	for id, nm in pairs(favNames) do
		if not nameOf[id] then nameOf[id] = nm end
	end
	if lyItems then
		for _, it in ipairs(lyItems) do
			if it.title and it.title ~= "" and not nameOf[it.code] then
				nameOf[it.code] = it.title
			end
		end
	end
	local arr = {}
	for id in pairs(favorites) do
		table.insert(arr, { id = id, name = nameOf[id] or id })
	end
	pcall(function()
		writefile(FAV_FILE, HttpService:JSONEncode(arr))
	end)
end

local function loadFav()
	local data = readHistoryFile(FAV_FILE)
	if type(data) == "table" then
		for _, e in ipairs(data) do
			if type(e) == "string" and normalizeCode(e) then
				favorites[e] = true
			elseif type(e) == "table" and e.id and normalizeCode(tostring(e.id)) then
				local id = tostring(e.id)
				favorites[id] = true
				if type(e.name) == "string" and e.name ~= "" then
					favNames[id] = e.name
				end
			end
		end
	end
end

local function saveHistory(allowEmpty: boolean?)
	-- защита от потери: никогда не затираем хороший файл пустой историей
	-- (бывает, если песни MM2 не подгрузились при старте). Очистка кнопкой идёт мимо.
	if not allowEmpty and #history == 0 then
		local existing = readHistoryFile(HISTORY_FILE)
		if existing and #existing > 0 then
			return
		end
	end
	pcall(function()
		local json = HttpService:JSONEncode(history)
		writefile(HISTORY_FILE, json)
		if #history > 0 then
			writefile(HISTORY_BAK, json)
		end
	end)
end

local mergeMm2Songs -- прямое объявление: вызывается из loadHistory выше
local function loadHistory()
	local data = readHistoryFile(HISTORY_FILE)
	if not data or #data == 0 then
		data = readHistoryFile(HISTORY_BAK) -- запасная копия
	end
	if data then
		for _, e in ipairs(data) do
			if type(e) == "table" and e.id and normalizeCode(tostring(e.id)) then
				table.insert(history, { id = tostring(e.id), name = tostring(e.name or ("Трек " .. tostring(e.id))) })
				if #history >= MAX_HISTORY then break end
			end
		end
	end
	mergeMm2Songs()
end

-- подмешиваем сохранённые песни MM2 (GetData RadioSongs), чтобы история не была пустой.
-- Сервер на заходе иногда тупит, поэтому можно вызывать повторно фоном.
function mergeMm2Songs(): number
	local added = 0
	pcall(function()
		local ext = ReplicatedStorage:FindFirstChild("Remotes")
		local extras = ext and ext:FindFirstChild("Extras")
		local gd = extras and extras:FindFirstChild("GetData")
		if gd then
			local res = gd:InvokeServer("RadioSongs")
			if type(res) == "table" then
				for _, v in ipairs(res) do
					if type(v) == "table" and v.ID then
						local code = normalizeCode(tostring(v.ID))
						if code then
							local exists = false
							for _, h in ipairs(history) do
								if h.id == code then exists = true break end
							end
							if not exists then
								table.insert(history, { id = code, name = tostring(v.Name or ("Трек " .. code)) })
								added += 1
							end
						end
					end
					if #history >= MAX_HISTORY then break end
				end
			end
		end
	end)
	return added
end

local function pushHistory(code: string, name: string)
	for i, h in ipairs(history) do
		if h.id == code then
			table.remove(history, i)
			break
		end
	end
	table.insert(history, 1, { id = code, name = name })
	while #history > MAX_HISTORY do
		table.remove(history)
	end
	saveHistory()
end

-- ---------- audio state (таблицы объявлены выше, перед saveFav) ----------

local function getLocalSound(parent: Instance): Sound
	if localSound and localSound.Parent then
		return localSound
	end
	-- локальный звук: работает в ЛЮБОЙ игре без бумбокса/пассов, слышишь только ты
	local s = Instance.new("Sound")
	s.Name = "GlassRadioLocal"
	s.Volume = volume
	s.Looped = true
	s.Parent = parent
	localSound = s
	return s
end

-- MAX-громкость (только у тебя): Volume/дистанция меняются лишь локально.
-- Проверил скрипты игры: серверного регулятора громкости радио нет,
-- а свойства звука от клиента на сервер не реплицируются —
-- другим игрокам громкость ставит сервер, со своей стороны её не поднять.
-- Что реально уходит всем: сам факт play/stop через PlaySong.
local maxVol: boolean = true

local function applyMaxVolume(rs: Sound)
	pcall(function()
		rs.Volume = 10
		rs.RollOffMinDistance = 100000
		rs.RollOffMaxDistance = 1000000
		rs.EmitterSize = 1000
	end)
end

local function applyVolume()
	local rs = getRadioSound()
	if rs then
		if maxVol and radioMode() == "mm2" then
			applyMaxVolume(rs)
		else
			pcall(function() rs.Volume = volume end)
		end
	end
	if localSound and localSound.Parent then
		pcall(function() (localSound :: Sound).Volume = volume end)
	end
end

-- читаем РЕАЛЬНОЕ состояние радио (а не то, что нам кажется): так стоп всегда
-- бьёт по тому ID, который звучит прямо сейчас, и не может включить чужой трек
local function radioState()
	local rs = getRadioSound()
	if not rs then return nil end
	local sid, playing, length, pos = "", false, 0, 0
	pcall(function()
		sid = rs.SoundId
		playing = rs.IsPlaying
		length = rs.TimeLength
		pos = rs.TimePosition
	end)
	return { rs = rs, sid = sid, playing = playing, length = length, pos = pos }
end

local function waitRadioState(timeoutSec: number, fn): boolean
	local t0 = os.clock()
	while os.clock() - t0 < timeoutSec do
		local st = radioState()
		if st then
			local ok, res = pcall(fn, st)
			if ok and res then return true end
		end
		task.wait(0.15)
	end
	return false
end

local function stopTrack(): string
	if radioMode() == "mm2" then
		-- сервер тогглит трек ТОЛЬКО если прислать тот ID, что сейчас загружен,
		-- поэтому берём фактический SoundId, а не запомненный (он мог рассинхрониться).
		-- miniPaused тоже ведёт на сервер: локальная пауза не останавливает трек у других.
		local st = radioState()
		if st and (st.playing or miniPaused) and normalizeCode(st.sid) then
			pcall(function()
				ReplicatedStorage.Remotes.Inventory.PlaySong:FireServer(st.sid)
			end)
			-- ждём, что звук реально встал; если нет — глушим локально то, что звучит
			local stopped = waitRadioState(2.5, function(s)
				return (not s.playing) or (normalizeCode(s.sid) ~= normalizeCode(st.sid))
			end)
			if not stopped then
				local st2 = radioState()
				if st2 and st2.playing then
					pcall(function() st2.rs:Stop() end)
				end
			end
		elseif st and st.playing then
			-- играет, но ID не распознан — просто глушим локально
			pcall(function() st.rs:Stop() end)
		end
	end
	if localSound and localSound.Parent then
		pcall(function() (localSound :: Sound):Stop() end)
	end
	currentCode = nil
	currentUrl = nil
	miniPaused = false
	if miniPauseBtn then miniPauseBtn.Text = "II" end
	return "Остановлено"
end

local function playTrack(code: string, knownName: string?): string
	local name = knownName or fetchTrackName(code)
	local url = toRadioUrl(code)
	miniPaused = false
	if miniPauseBtn then miniPauseBtn.Text = "II" end
	if radioMode() == "mm2" then
		-- ОДИН фаер без «стоп прошлого»: сервер рассылает (звук, ID),
		-- а клиент сам переключается на новый ID. Двойные фаеры подряд
		-- иногда приходили вперемешку и включали не тот трек — так было раньше.
		local ok, err = pcall(function()
			ReplicatedStorage.Remotes.Inventory.PlaySong:FireServer(url)
		end)
		if not ok then
			if notify then notify("Ошибка отправки: " .. tostring(err)) end
			return "Ошибка: " .. tostring(err)
		end
		-- проверяем, что заиграл именно наш ID и звук реально загрузился:
		-- если звук встал, а ID наш — значит это был реплей того же трека (сервер тогглит),
		-- фаерим ещё раз чтобы заиграть заново
		local playingNow = waitRadioState(3.5, function(s)
			return s.playing and s.sid == url and (s.length or 0) > 1
		end)
		if not playingNow then
			local st = radioState()
			if st and (not st.playing) and st.sid == url then
				pcall(function()
					ReplicatedStorage.Remotes.Inventory.PlaySong:FireServer(url)
				end)
				playingNow = waitRadioState(3.5, function(s)
					return s.playing and s.sid == url and (s.length or 0) > 1
				end)
			end
		end
		if not playingNow then
			-- наш ID загружен, но звук не идёт и длины нет: аудио удалено/приватно
			local st2 = radioState()
			if st2 and st2.sid == url then
				if notify then notify("Трек недоступен: аудио удалено или приватное") end
				return "Трек недоступен"
			end
		end
		currentCode = code
		currentUrl = url
		task.delay(0.5, applyVolume)
	else
		-- локальный режим без пасса: слышишь только ты.
		-- включается сам в любой игре, где нет MM2-радио (другая игра, нет геймпасса).
		local holder = LocalPlayer:FindFirstChildOfClass("PlayerGui") or LocalPlayer:WaitForChild("PlayerGui")
		local s = getLocalSound(holder)
		pcall(function()
			s:Stop()
			s.SoundId = "rbxassetid://" .. code
			s.Volume = volume
			s.Looped = true
			s:Play()
		end)
		local lokOk = false
		local t0 = os.clock()
		while os.clock() - t0 < 4 do
			local okL, pl, ln = pcall(function()
				return s.IsPlaying, s.TimeLength
			end)
			if okL and pl and (ln or 0) > 1 then
				lokOk = true
				break
			end
			task.wait(0.2)
		end
		if not lokOk then
			if notify then notify("Трек недоступен: аудио удалено или приватное") end
			return "Трек недоступен"
		end
		currentCode = code
		currentUrl = url
	end
	pushHistory(code, name)
	return "Играет: " .. name
end

-- ---------- GUI (glass) ----------
loadFav()
loadHistory()

local parentGui: Instance = LocalPlayer:WaitForChild("PlayerGui")
pcall(function()
	local h = gethui()
	if h then parentGui = h end
end)

local gui = Instance.new("ScreenGui")
gui.Name = "GlassRadio"
gui.ResetOnSpawn = false
gui.DisplayOrder = 999
gui.Parent = parentGui
getgenv().GlassRadioGui = gui

local main = Instance.new("Frame")
main.Name = "Main"
main.Size = UDim2.new(0, 272, 0, 368)
main.Position = UDim2.new(1, -292, 0.5, -184)
main.BackgroundColor3 = Color3.fromRGB(28, 16, 52)
main.BackgroundTransparency = 0
main.BorderSizePixel = 0
main.Active = true
main.Parent = gui

local corner = Instance.new("UICorner")
corner.CornerRadius = UDim.new(0, 14)
corner.Parent = main

local stroke = Instance.new("UIStroke")
stroke.Color = Color3.fromRGB(170, 120, 255)
stroke.Transparency = 0.72
stroke.Thickness = 1
stroke.Parent = main

local grad = Instance.new("UIGradient")
grad.Color = ColorSequence.new({
	ColorSequenceKeypoint.new(0, Color3.fromRGB(70, 35, 140)),
	ColorSequenceKeypoint.new(0.5, Color3.fromRGB(130, 80, 220)),
	ColorSequenceKeypoint.new(1, Color3.fromRGB(48, 24, 100)),
})
grad.Transparency = NumberSequence.new({
	NumberSequenceKeypoint.new(0, 0.15),
	NumberSequenceKeypoint.new(1, 0.3),
})
grad.Rotation = 35
grad.Parent = main

-- фон: своя картинка radio_bg.png из папки Workspace исполнителя, иначе аватарка.
-- GitHub-ссылка сюда не подойдёт: Roblox не грузит картинки по внешним URL,
-- только свои ассеты или файл через getcustomasset.
local avatarBg = Instance.new("ImageLabel")
avatarBg.Name = "AvatarBg"
avatarBg.Size = UDim2.new(1, 0, 1, 0)
avatarBg.BackgroundTransparency = 1
avatarBg.ImageTransparency = 0.55
avatarBg.ScaleType = Enum.ScaleType.Crop
avatarBg.Parent = main
task.spawn(function()
	-- 1) ссылка на картинку (github raw и т.п.) в файле radio_bg_url.txt:
	-- скрипт сам скачает её в radio_bg.png
	local urlOk, url = pcall(function()
		if isfile("radio_bg_url.txt") then
			return readfile("radio_bg_url.txt")
		end
		return nil
	end)
	if urlOk and type(url) == "string" then
		url = string.gsub(url, "%s+", "")
		if url ~= "" then
			local markOk, mark = pcall(function()
				if isfile("radio_bg_url.done.txt") then
					return readfile("radio_bg_url.done.txt")
				end
				return nil
			end)
			local needDl = (not isfile("radio_bg.png")) or (not markOk) or (mark ~= url)
			if needDl then
				local okR, res = pcall(request, { Url = url, Method = "GET" })
				local bytes: string? = nil
				if okR and res ~= nil then
					if type(res) == "string" then
						bytes = res
					elseif type(res) == "table" then
						local b = res.Body or res.body or res.Content or res.content
						if type(b) == "string" then bytes = b end
					end
				end
				if bytes and #bytes > 1000 then
					pcall(function()
						writefile("radio_bg.png", bytes)
						writefile("radio_bg_url.done.txt", url)
					end)
				end
			end
		end
	end
	-- 2) локальный файл из Workspace
	local customOk, customId = pcall(function()
		if isfile("radio_bg.png") then
			return getcustomasset("radio_bg.png")
		end
		return nil
	end)
	if customOk and type(customId) == "string" and customId ~= "" then
		avatarBg.Image = customId
		return
	end
	-- 3) запасной вариант: аватарка
	local ok, content = pcall(function()
		return Players:GetUserThumbnailAsync(LocalPlayer.UserId, Enum.ThumbnailType.AvatarBust, Enum.ThumbnailSize.Size420x420)
	end)
	if ok and type(content) == "string" and content ~= "" then
		avatarBg.Image = content
	end
end)

-- шапка (drag)
local top = Instance.new("Frame")
top.Size = UDim2.new(1, 0, 0, 34)
top.BackgroundTransparency = 1
top.Parent = main

local title = Instance.new("TextLabel")
title.Size = UDim2.new(1, -102, 1, 0)
title.Position = UDim2.new(0, 12, 0, 0)
title.BackgroundTransparency = 1
title.Font = Enum.Font.GothamBold
title.TextSize = 13
title.TextXAlignment = Enum.TextXAlignment.Left
title.TextColor3 = Color3.fromRGB(228, 216, 255)
title.Text = "Glass Radio"
title.Parent = top

local modeLabel = Instance.new("TextLabel")
modeLabel.Size = UDim2.new(1, -24, 0, 14)
modeLabel.Position = UDim2.new(0, 12, 0, 32)
modeLabel.BackgroundTransparency = 1
modeLabel.Font = Enum.Font.Gotham
modeLabel.TextSize = 11
modeLabel.TextXAlignment = Enum.TextXAlignment.Left
modeLabel.TextColor3 = Color3.fromRGB(196, 164, 255)
local __gameName = currentGameName()
if radioMode() == "mm2" then
	modeLabel.Text = "Радио — слышат все"
elseif __gameName then
	modeLabel.Text = __gameName .. " — локально (радио игры изучается)"
else
	modeLabel.Text = "Локально — слышишь только ты"
end
modeLabel.Parent = main

-- строка мини-режима: видна вместо modeLabel, когда окно свернуто
local miniTrack = Instance.new("TextLabel")
miniTrack.Size = UDim2.new(1, -110, 0, 14)
miniTrack.Position = UDim2.new(0, 12, 0, 32)
miniTrack.BackgroundTransparency = 1
miniTrack.Font = Enum.Font.GothamBold
miniTrack.TextSize = 11
miniTrack.TextXAlignment = Enum.TextXAlignment.Left
miniTrack.TextTruncate = Enum.TextTruncate.AtEnd
miniTrack.TextColor3 = Color3.fromRGB(200, 170, 255)
miniTrack.Text = "Остановлено"
miniTrack.Visible = false
miniTrack.Parent = main

-- скип-кнопки мини-режима
local function miniNavBtn(text: string, x: number): TextButton
	local b = Instance.new("TextButton")
	b.Name = "MiniNav" .. text
	b.Size = UDim2.new(0, 26, 0, 16)
	b.Position = UDim2.new(1, x, 0, 31)
	b.BackgroundColor3 = Color3.fromRGB(70, 50, 120)
	b.BackgroundTransparency = 0
	b.BorderSizePixel = 0
	b.Font = Enum.Font.GothamBold
	b.TextSize = 11
	b.TextColor3 = Color3.fromRGB(230, 235, 255)
	b.Text = text
	b.Visible = false
	b.Parent = main
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, 5)
	c.Parent = b
	return b
end
local miniPrev = miniNavBtn("<", -66)
local miniNext = miniNavBtn(">", -38)
miniPauseBtn = miniNavBtn("II", -94)

local function smallBtn(text: string, x: number): TextButton
	local b = Instance.new("TextButton")
	b.Size = UDim2.new(0, 26, 0, 22)
	b.Position = UDim2.new(1, x, 0, 6)
	b.BackgroundColor3 = Color3.fromRGB(70, 50, 120)
	b.BackgroundTransparency = 0
	b.Font = Enum.Font.GothamBold
	b.TextSize = 12
	b.TextColor3 = Color3.fromRGB(230, 235, 255)
	b.Text = text
	b.AutoButtonColor = true
	b.Parent = top
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, 7)
	c.Parent = b
	return b
end
local hideBtn = smallBtn("-", -58)
local closeBtn = smallBtn("X", -30)
-- звёздочка картинкой с гитхаба (шрифт символы не тянет): нет файла — обычная "*"
local lastStarToggle = 0
local function onStarToggle()
	local now = os.clock()
	if now - lastStarToggle < 0.3 then return end
	lastStarToggle = now
	favWin.Visible = not favWin.Visible
	if favWin.Visible then
		refreshFavWin()
	end
end
local starBtn: TextButton | ImageButton = smallBtn("*", -88)
starBtn.MouseButton1Click:Connect(onStarToggle)
task.spawn(function()
	-- нет локального файла — скачать с гитхаба
	local have = false
	pcall(function()
		have = isfile("star.png")
	end)
	if not have then
		local ok2, raw = pcall(function()
			return (request({ Url = "https://raw.githubusercontent.com/Boja1586/radio-bg/main/star.png", Method = "GET" }))
		end)
		if ok2 and raw ~= nil then
			local bytes: string? = nil
			if type(raw) == "string" then
				bytes = raw
			elseif type(raw) == "table" then
				local b = raw.Body or raw.body or raw.Content or raw.content
				if type(b) == "string" then bytes = b end
			end
			if bytes and #bytes > 500 then
				pcall(function()
					writefile("star.png", bytes)
				end)
			end
		end
	end
	local ok, id = pcall(function()
		if isfile("star.png") then
			return getcustomasset("star.png")
		end
		return nil
	end)
	if not ok or type(id) ~= "string" or id == "" then
		return
	end
	local img = Instance.new("ImageButton")
	img.Size = UDim2.new(0, 26, 0, 22)
	img.Position = UDim2.new(1, -88, 0, 6)
	img.BackgroundColor3 = Color3.fromRGB(70, 50, 120)
	img.BackgroundTransparency = 0
	img.BorderSizePixel = 0
	img.Image = id
	img.ScaleType = Enum.ScaleType.Fit
	img.Parent = top
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, 7)
	c.Parent = img
	img.MouseButton1Click:Connect(onStarToggle)
	starBtn:Destroy()
	starBtn = img
end)

local body = Instance.new("Frame")
body.Position = UDim2.new(0, 0, 0, 50)
body.Size = UDim2.new(1, 0, 1, -50)
body.BackgroundTransparency = 1
body.Parent = main

-- поле ввода кода
local input = Instance.new("TextBox")
input.Size = UDim2.new(1, -24, 0, 30)
input.Position = UDim2.new(0, 12, 0, 0)
input.BackgroundColor3 = Color3.fromRGB(20, 12, 40)
input.BackgroundTransparency = 0
input.Font = Enum.Font.Gotham
input.TextSize = 13
input.PlaceholderText = "Код трека... напр. 1837879082"
input.Text = ""
input.TextColor3 = Color3.fromRGB(240, 244, 255)
input.PlaceholderColor3 = Color3.fromRGB(160, 170, 190)
input.ClearTextOnFocus = false
input.Parent = body
local inputC = Instance.new("UICorner")
inputC.CornerRadius = UDim.new(0, 9)
inputC.Parent = input
local inputS = Instance.new("UIStroke")
inputS.Transparency = 0.7
inputS.Color = Color3.fromRGB(255, 255, 255)
inputS.Parent = input

-- кнопки play/stop
local function glassBtn(text: string, pos: UDim2, size: UDim2): TextButton
	local b = Instance.new("TextButton")
	b.Position = pos
	b.Size = size
	b.BackgroundColor3 = Color3.fromRGB(90, 60, 160)
	b.BackgroundTransparency = 0
	b.Font = Enum.Font.GothamBold
	b.TextSize = 13
	b.TextColor3 = Color3.fromRGB(240, 245, 255)
	b.Text = text
	b.AutoButtonColor = true
	b.Parent = body
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, 9)
	c.Parent = b
	local s = Instance.new("UIStroke")
	s.Transparency = 0.5
	s.Color = Color3.fromRGB(255, 255, 255)
	s.Parent = b
	return b
end

local playBtn = glassBtn("Играть", UDim2.new(0, 12, 0, 36), UDim2.new(0, 79, 0, 30))
playBtn.BackgroundColor3 = Color3.fromRGB(130, 90, 230)
local pauseBtn = glassBtn("Пауза", UDim2.new(0, 97, 0, 36), UDim2.new(0, 78, 0, 30))
pauseBtn.TextSize = 12
local stopBtn = glassBtn("Стоп", UDim2.new(0, 181, 0, 36), UDim2.new(0, 79, 0, 30))
stopBtn.BackgroundColor3 = Color3.fromRGB(200, 70, 90)

-- статус
local status = Instance.new("TextLabel")
status.Size = UDim2.new(1, -24, 0, 18)
status.Position = UDim2.new(0, 12, 0, 70)
status.BackgroundTransparency = 1
status.Font = Enum.Font.Gotham
status.TextSize = 11
status.TextXAlignment = Enum.TextXAlignment.Left
status.TextTruncate = Enum.TextTruncate.AtEnd
status.TextColor3 = Color3.fromRGB(190, 200, 220)
status.Text = "Вставь код и нажми Играть"
status.Parent = body

-- громкость
local volTitle = Instance.new("TextLabel")
volTitle.Size = UDim2.new(1, -24, 0, 14)
volTitle.Position = UDim2.new(0, 12, 0, 90)
volTitle.BackgroundTransparency = 1
volTitle.Font = Enum.Font.Gotham
volTitle.TextSize = 11
volTitle.TextXAlignment = Enum.TextXAlignment.Left
volTitle.TextColor3 = Color3.fromRGB(170, 180, 200)
volTitle.Text = "Громкость: 60%"
volTitle.Parent = body

local volBar = Instance.new("TextButton")
volBar.Size = UDim2.new(1, -24, 0, 10)
volBar.Position = UDim2.new(0, 12, 0, 106)
volBar.BackgroundColor3 = Color3.fromRGB(60, 40, 110)
volBar.BackgroundTransparency = 0
volBar.Text = ""
volBar.AutoButtonColor = false
volBar.Parent = body
local volBarC = Instance.new("UICorner")
volBarC.CornerRadius = UDim.new(1, 0)
volBarC.Parent = volBar

local volFill = Instance.new("Frame")
volFill.Size = UDim2.new(0.6, 0, 1, 0)
volFill.BackgroundColor3 = Color3.fromRGB(178, 132, 255)
volFill.BackgroundTransparency = 0
volFill.BorderSizePixel = 0
volFill.Parent = volBar
local volFillC = Instance.new("UICorner")
volFillC.CornerRadius = UDim.new(1, 0)
volFillC.Parent = volFill

local function setVolumeFrac(f: number)
	local frac = math.clamp(f, 0, 1)
	volume = frac * 10
	volFill.Size = UDim2.new(frac, 0, 1, 0)
	if maxVol and hasRadioPass() then
		volTitle.Text = "Громкость: MAX (только у тебя)"
	else
		volTitle.Text = "Громкость: " .. tostring(math.floor(frac * 100)) .. "%"
	end
	applyVolume()
end

-- перемотка: время трека + полоса. Сервер отдаёт всем только Play/Stop,
-- позицию каждый мотает себе локально — у других трек продолжает с их места.
local seekTime = Instance.new("TextLabel")
seekTime.Size = UDim2.new(1, -24, 0, 12)
seekTime.Position = UDim2.new(0, 12, 0, 118)
seekTime.BackgroundTransparency = 1
seekTime.Font = Enum.Font.Gotham
seekTime.TextSize = 10
seekTime.TextXAlignment = Enum.TextXAlignment.Left
seekTime.TextColor3 = Color3.fromRGB(150, 165, 190)
seekTime.Text = "0:00 / 0:00"
seekTime.Parent = body

local seekBar = Instance.new("TextButton")
seekBar.Size = UDim2.new(1, -24, 0, 8)
seekBar.Position = UDim2.new(0, 12, 0, 132)
seekBar.BackgroundColor3 = Color3.fromRGB(60, 40, 110)
seekBar.BackgroundTransparency = 0
seekBar.Text = ""
seekBar.AutoButtonColor = false
seekBar.Parent = body
local seekBarC = Instance.new("UICorner")
seekBarC.CornerRadius = UDim.new(1, 0)
seekBarC.Parent = seekBar

local seekFill = Instance.new("Frame")
seekFill.Size = UDim2.new(0, 0, 1, 0)
seekFill.BackgroundColor3 = Color3.fromRGB(205, 150, 255)
seekFill.BackgroundTransparency = 0
seekFill.BorderSizePixel = 0
seekFill.Parent = seekBar
local seekFillC = Instance.new("UICorner")
seekFillC.CornerRadius = UDim.new(1, 0)
seekFillC.Parent = seekFill

local function fmtTime(sec: number): string
	sec = math.max(0, math.floor(sec + 0.5))
	return string.format("%d:%02d", math.floor(sec / 60), sec % 60)
end

-- звук, у которого можно читать/мотать позицию (играющий прямо сейчас)
local function activeSeekSound(): Sound?
	if hasRadioPass() then
		local st = radioState()
		if st and st.playing and st.length > 1 then
			return st.rs
		end
		return nil
	end
	if localSound and localSound.Parent then
		local s: Sound = localSound
		local ok, len, pl = pcall(function()
			return s.TimeLength, s.IsPlaying
		end)
		if ok and pl and len > 1 then
			return s
		end
	end
	return nil
end

local function seekAt(x: number)
	local s = activeSeekSound()
	if not s then
		status.Text = "Нечего мотать: трек не играет"
		return
	end
	local abs = seekBar.AbsolutePosition.X
	local sz = math.max(1, seekBar.AbsoluteSize.X)
	local frac = math.clamp((x - abs) / sz, 0, 1)
	local ok, len = pcall(function()
		return (s :: Sound).TimeLength
	end)
	if ok and len and len > 1 then
		pcall(function()
			(s :: Sound).TimePosition = frac * len
		end)
	end
end

-- кнопка «на всё лобби»
local boostBtn = glassBtn("MAX громкость: ВКЛ", UDim2.new(0, 12, 0, 142), UDim2.new(0.5, -16, 0, 20))
boostBtn.TextSize = 11
boostBtn.BackgroundColor3 = Color3.fromRGB(140, 220, 160)
local muteBtn = glassBtn("Чужие: звук", UDim2.new(0.5, 4, 0, 142), UDim2.new(0.5, -16, 0, 20))
muteBtn.TextSize = 11

-- история
local histTitle = Instance.new("TextLabel")
histTitle.Size = UDim2.new(0.5, 0, 0, 16)
histTitle.Position = UDim2.new(0, 12, 0, 166)
histTitle.BackgroundTransparency = 1
histTitle.Font = Enum.Font.GothamBold
histTitle.TextSize = 11
histTitle.TextXAlignment = Enum.TextXAlignment.Left
histTitle.TextColor3 = Color3.fromRGB(200, 210, 230)
histTitle.Text = "История"
histTitle.Parent = body

local clearBtn = Instance.new("TextButton")
clearBtn.Size = UDim2.new(0, 70, 0, 18)
clearBtn.Position = UDim2.new(1, -82, 0, 164)
clearBtn.BackgroundTransparency = 1
clearBtn.Font = Enum.Font.Gotham
clearBtn.TextSize = 11
clearBtn.TextColor3 = Color3.fromRGB(255, 150, 150)
clearBtn.Text = "Очистить"
clearBtn.Parent = body

-- следующий / предыдущий трек, как в музыкальных приложениях
local function navBtn(text: string, x: number): TextButton
	local b = Instance.new("TextButton")
	b.Size = UDim2.new(0, 26, 0, 18)
	b.Position = UDim2.new(1, x, 0, 164)
	b.BackgroundColor3 = Color3.fromRGB(70, 50, 120)
	b.BackgroundTransparency = 0
	b.BorderSizePixel = 0
	b.Font = Enum.Font.GothamBold
	b.TextSize = 12
	b.TextColor3 = Color3.fromRGB(230, 235, 255)
	b.Text = text
	b.Parent = body
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, 6)
	c.Parent = b
	return b
end
local prevBtn = navBtn("<", -142)
local nextBtn = navBtn(">", -114)

local list = Instance.new("ScrollingFrame")
list.Size = UDim2.new(1, -24, 0, 100)
list.Position = UDim2.new(0, 12, 0, 184)
list.BackgroundColor3 = Color3.fromRGB(20, 12, 40)
list.BackgroundTransparency = 0
list.BorderSizePixel = 0
list.ScrollBarThickness = 3
list.CanvasSize = UDim2.new(0, 0, 0, 0)
list.AutomaticCanvasSize = Enum.AutomaticSize.Y
list.Parent = body
local listC = Instance.new("UICorner")
listC.CornerRadius = UDim.new(0, 9)
listC.Parent = list
local listLayout = Instance.new("UIListLayout")
listLayout.Padding = UDim.new(0, 4)
listLayout.SortOrder = Enum.SortOrder.LayoutOrder
listLayout.Parent = list
local listPad = Instance.new("UIPadding")
listPad.PaddingTop = UDim.new(0, 4)
listPad.PaddingLeft = UDim.new(0, 4)
listPad.PaddingRight = UDim.new(0, 4)
listPad.PaddingBottom = UDim.new(0, 4)
listPad.Parent = list

local catalogBtn = glassBtn("Каталог lylib.fun", UDim2.new(0, 12, 0, 288), UDim2.new(0.5, -16, 0, 24))
catalogBtn.TextSize = 12
catalogBtn.BackgroundColor3 = Color3.fromRGB(150, 120, 255)
local mineBtn = glassBtn("Мой сборник", UDim2.new(0.5, 4, 0, 288), UDim2.new(0.5, -16, 0, 24))
mineBtn.TextSize = 12
mineBtn.BackgroundColor3 = Color3.fromRGB(150, 120, 255)

local function refreshHistory()
	for _, ch in ipairs(list:GetChildren()) do
		if ch:IsA("Frame") then ch:Destroy() end
	end
	-- мини-режим всегда показывает, что играет прямо сейчас
	local miniText = "Остановлено"
	if currentCode then
		miniText = "Сейчас: " .. currentCode
		for _, h in ipairs(history) do
			if h.id == currentCode then
				miniText = "Сейчас: " .. h.name
				break
			end
		end
	end
	miniTrack.Text = miniText
	-- избранное всегда наверху
	local ordered = {}
	for _, e in ipairs(history) do
		if favorites[e.id] then table.insert(ordered, e) end
	end
	for _, e in ipairs(history) do
		if not favorites[e.id] then table.insert(ordered, e) end
	end
	for i, e in ipairs(ordered) do
		local row = Instance.new("Frame")
		row.Size = UDim2.new(1, -6, 0, 26)
		row.BackgroundColor3 = Color3.fromRGB(55, 35, 105)
		row.BackgroundTransparency = 0
		row.BorderSizePixel = 0
		row.LayoutOrder = i
		row.Parent = list
		local rc = Instance.new("UICorner")
		rc.CornerRadius = UDim.new(0, 7)
		rc.Parent = row

		local btn = Instance.new("TextButton")
		btn.Size = UDim2.new(1, -58, 1, 0)
		btn.BackgroundTransparency = 1
		btn.Font = Enum.Font.Gotham
		btn.TextSize = 11
		btn.TextXAlignment = Enum.TextXAlignment.Left
		btn.TextTruncate = Enum.TextTruncate.AtEnd
		btn.TextColor3 = if e.id == currentCode then Color3.fromRGB(140, 220, 160) else Color3.fromRGB(225, 232, 248)
		btn.Text = "  " .. e.name .. " — " .. e.id
		btn.Parent = row

		local favBtn = Instance.new("TextButton")
		favBtn.Size = UDim2.new(0, 26, 1, 0)
		favBtn.Position = UDim2.new(1, -56, 0, 0)
		favBtn.BackgroundTransparency = 1
		favBtn.Font = Enum.Font.GothamBold
		favBtn.TextSize = 13
		favBtn.TextColor3 = if favorites[e.id] then Color3.fromRGB(255, 210, 100) else Color3.fromRGB(120, 125, 145)
		favBtn.Text = "+"
		favBtn.Parent = row
		local favId = e.id
		local favNm = e.name
		favBtn.MouseButton1Click:Connect(function()
			if toggleFav then toggleFav(favId, favNm) end
		end)

		local code = e.id
		local nm = e.name
		btn.MouseButton1Click:Connect(function()
			status.Text = "Включаю..."
			task.spawn(function()
				-- снимок истории как очередь для кнопок следующий/предыдущий
				local snap: {{ code: string, title: string }} = {}
				local at = 1
				for j, h in ipairs(history) do
					table.insert(snap, { code = h.id, title = h.name })
					if h.id == code then at = j end
				end
				playCtx = { list = snap, index = at }
				local msg = playTrack(code, nm)
				status.Text = msg
				refreshHistory()
			end)
		end)

		local del = Instance.new("TextButton")
		del.Size = UDim2.new(0, 26, 1, 0)
		del.Position = UDim2.new(1, -26, 0, 0)
		del.BackgroundTransparency = 1
		del.Font = Enum.Font.GothamBold
		del.TextSize = 12
		del.TextColor3 = Color3.fromRGB(255, 140, 140)
		del.Text = "X"
		del.Parent = row
		del.MouseButton1Click:Connect(function()
			for j, h in ipairs(history) do
				if h.id == code then table.remove(history, j) break end
			end
			saveHistory()
			refreshHistory()
		end)
	end
end

function toggleFav(id: string, name: string?)
	if favorites[id] then
		favorites[id] = nil
		status.Text = "Убрано из избранного"
	else
		favorites[id] = true
		if name and name ~= "" then favNames[id] = name end
		status.Text = "В избранном"
	end
	saveFav()
	refreshHistory()
	if favWin and favWin.Visible and refreshFavWin then refreshFavWin() end
end

-- ---------- каталог lylib.fun ----------
local lyWin = Instance.new("Frame")
lyWin.Name = "Lylib"
lyWin.Size = UDim2.new(0, 272, 0, 330)
lyWin.Position = UDim2.new(1, -574, 0.5, -165)
lyWin.BackgroundColor3 = Color3.fromRGB(28, 16, 52)
lyWin.BackgroundTransparency = 0
lyWin.BorderSizePixel = 0
lyWin.Visible = false
lyWin.Parent = gui
local lyCorner = Instance.new("UICorner")
lyCorner.CornerRadius = UDim.new(0, 14)
lyCorner.Parent = lyWin
local lyStroke = Instance.new("UIStroke")
lyStroke.Color = Color3.fromRGB(170, 120, 255)
lyStroke.Transparency = 0.6
lyStroke.Thickness = 1
lyStroke.Parent = lyWin

local lyTop = Instance.new("Frame")
lyTop.Size = UDim2.new(1, 0, 0, 32)
lyTop.BackgroundTransparency = 1
lyTop.Parent = lyWin

local lyTitle = Instance.new("TextLabel")
lyTitle.Size = UDim2.new(1, -110, 1, 0)
lyTitle.Position = UDim2.new(0, 12, 0, 0)
lyTitle.BackgroundTransparency = 1
lyTitle.Font = Enum.Font.GothamBold
lyTitle.TextSize = 13
lyTitle.TextXAlignment = Enum.TextXAlignment.Left
lyTitle.TextColor3 = Color3.fromRGB(228, 216, 255)
lyTitle.Text = "Каталог lylib.fun"
lyTitle.Parent = lyTop

local lyClose = Instance.new("TextButton")
lyClose.Size = UDim2.new(0, 26, 0, 22)
lyClose.Position = UDim2.new(1, -32, 0, 5)
lyClose.BackgroundColor3 = Color3.fromRGB(70, 50, 120)
lyClose.BackgroundTransparency = 0
lyClose.Font = Enum.Font.GothamBold
lyClose.TextSize = 12
lyClose.TextColor3 = Color3.fromRGB(230, 235, 255)
lyClose.Text = "X"
lyClose.Parent = lyTop
local lyCloseC = Instance.new("UICorner")
lyCloseC.CornerRadius = UDim.new(0, 7)
lyCloseC.Parent = lyClose

local lyRandom = Instance.new("TextButton")
lyRandom.Size = UDim2.new(0, 62, 0, 22)
lyRandom.Position = UDim2.new(1, -100, 0, 5)
lyRandom.BackgroundColor3 = Color3.fromRGB(70, 50, 120)
lyRandom.BackgroundTransparency = 0
lyRandom.BorderSizePixel = 0
lyRandom.Font = Enum.Font.GothamBold
lyRandom.TextSize = 11
lyRandom.TextColor3 = Color3.fromRGB(230, 235, 255)
lyRandom.Text = "Рандом"
lyRandom.Parent = lyTop
local lyRandomC = Instance.new("UICorner")
lyRandomC.CornerRadius = UDim.new(0, 7)
lyRandomC.Parent = lyRandom

local lySearch = Instance.new("TextBox")
lySearch.Size = UDim2.new(1, -96, 0, 28)
lySearch.Position = UDim2.new(0, 12, 0, 34)
lySearch.BackgroundColor3 = Color3.fromRGB(20, 12, 40)
lySearch.BackgroundTransparency = 0
lySearch.Font = Enum.Font.Gotham
lySearch.TextSize = 12
lySearch.PlaceholderText = "Поиск..."
lySearch.Text = ""
lySearch.TextColor3 = Color3.fromRGB(240, 244, 255)
lySearch.PlaceholderColor3 = Color3.fromRGB(160, 170, 190)
lySearch.ClearTextOnFocus = false
lySearch.Parent = lyWin
local lySearchC = Instance.new("UICorner")
lySearchC.CornerRadius = UDim.new(0, 9)
lySearchC.Parent = lySearch

local lyFind = Instance.new("TextButton")
lyFind.Size = UDim2.new(0, 72, 0, 28)
lyFind.Position = UDim2.new(1, -84, 0, 34)
lyFind.BackgroundColor3 = Color3.fromRGB(130, 90, 230)
lyFind.BackgroundTransparency = 0
lyFind.Font = Enum.Font.GothamBold
lyFind.TextSize = 12
lyFind.TextColor3 = Color3.fromRGB(240, 245, 255)
lyFind.Text = "Найти"
lyFind.Parent = lyWin
local lyFindC = Instance.new("UICorner")
lyFindC.CornerRadius = UDim.new(0, 9)
lyFindC.Parent = lyFind

local lyStatus = Instance.new("TextLabel")
lyStatus.Size = UDim2.new(1, -24, 0, 14)
lyStatus.Position = UDim2.new(0, 12, 0, 64)
lyStatus.BackgroundTransparency = 1
lyStatus.Font = Enum.Font.Gotham
lyStatus.TextSize = 10
lyStatus.TextXAlignment = Enum.TextXAlignment.Left
lyStatus.TextTruncate = Enum.TextTruncate.AtEnd
lyStatus.TextColor3 = Color3.fromRGB(170, 180, 200)
lyStatus.Text = ""
lyStatus.Parent = lyWin

local lyList = Instance.new("ScrollingFrame")
lyList.Size = UDim2.new(1, -24, 0, 196)
lyList.Position = UDim2.new(0, 12, 0, 80)
lyList.BackgroundColor3 = Color3.fromRGB(20, 12, 40)
lyList.BackgroundTransparency = 0
lyList.BorderSizePixel = 0
lyList.ScrollBarThickness = 3
lyList.CanvasSize = UDim2.new(0, 0, 0, 0)
lyList.AutomaticCanvasSize = Enum.AutomaticSize.Y
lyList.Parent = lyWin
local lyListC = Instance.new("UICorner")
lyListC.CornerRadius = UDim.new(0, 9)
lyListC.Parent = lyList
local lyLayout = Instance.new("UIListLayout")
lyLayout.Padding = UDim.new(0, 4)
lyLayout.SortOrder = Enum.SortOrder.LayoutOrder
lyLayout.Parent = lyList
local lyPad = Instance.new("UIPadding")
lyPad.PaddingTop = UDim.new(0, 4)
lyPad.PaddingLeft = UDim.new(0, 4)
lyPad.PaddingRight = UDim.new(0, 4)
lyPad.PaddingBottom = UDim.new(0, 4)
lyPad.Parent = lyList

local lyPrev = Instance.new("TextButton")
lyPrev.Size = UDim2.new(0, 76, 0, 26)
lyPrev.Position = UDim2.new(0, 12, 0, 282)
lyPrev.BackgroundColor3 = Color3.fromRGB(130, 90, 230)
lyPrev.BackgroundTransparency = 0
lyPrev.Font = Enum.Font.GothamBold
lyPrev.TextSize = 12
lyPrev.TextColor3 = Color3.fromRGB(240, 245, 255)
lyPrev.Text = "Назад"
lyPrev.Parent = lyWin
local lyPrevC = Instance.new("UICorner")
lyPrevC.CornerRadius = UDim.new(0, 9)
lyPrevC.Parent = lyPrev

local lyPageLabel = Instance.new("TextBox")
lyPageLabel.Size = UDim2.new(1, -176, 0, 26)
lyPageLabel.Position = UDim2.new(0, 88, 0, 282)
lyPageLabel.BackgroundTransparency = 1
lyPageLabel.Font = Enum.Font.GothamBold
lyPageLabel.TextSize = 12
lyPageLabel.TextColor3 = Color3.fromRGB(190, 200, 220)
lyPageLabel.TextXAlignment = Enum.TextXAlignment.Center
lyPageLabel.ClearTextOnFocus = false
lyPageLabel.Text = ""
lyPageLabel.Parent = lyWin

local lyNext = Instance.new("TextButton")
lyNext.Size = UDim2.new(0, 76, 0, 26)
lyNext.Position = UDim2.new(1, -88, 0, 282)
lyNext.BackgroundColor3 = Color3.fromRGB(130, 90, 230)
lyNext.BackgroundTransparency = 0
lyNext.Font = Enum.Font.GothamBold
lyNext.TextSize = 12
lyNext.TextColor3 = Color3.fromRGB(240, 245, 255)
lyNext.Text = "Далее"
lyNext.Parent = lyWin
local lyNextC = Instance.new("UICorner")
lyNextC.CornerRadius = UDim.new(0, 9)
lyNextC.Parent = lyNext

local lyPage, lyPages, lyQuery, lyOpened = 1, 1, "", false
lyItems = {} -- {{code, title}}, объявлено выше прямым объявлением
local lyMinePage = 1
local lyMineMapped = {}
local lyMineView = {}
local lyMineQuery = ""
local MINE_PER = 15
local lyMode -- прямое объявление: обработчики страниц ниже, значение задаётся дальше
local renderMinePage -- прямое объявление: функция ниже
local applyMineFilter -- прямое объявление: функция ниже

local function urlencode(s: string): string
	local e = string.gsub(s, "([^%w%-_%.~ ])", function(c)
		return string.format("%%%02X", string.byte(c))
	end)
	e = string.gsub(e, " ", "+")
	return e
end

local function lyBuildRows(items)
	for _, ch in ipairs(lyList:GetChildren()) do
		if ch:IsA("Frame") then ch:Destroy() end
	end
	local n = 0
	for i, it in ipairs(items) do
		if type(it) == "table" then
			local code = normalizeCode(tostring(it.roblox_id or ""))
			if code then
				n += 1
				local title = tostring(it.title or "Без названия")
				local artist = tostring(it.artist or "")
				local row = Instance.new("Frame")
				row.Size = UDim2.new(1, -6, 0, 26)
				row.BackgroundColor3 = Color3.fromRGB(55, 35, 105)
				row.BackgroundTransparency = 0
				row.BorderSizePixel = 0
				row.LayoutOrder = n
				row.Parent = lyList
				local rc = Instance.new("UICorner")
				rc.CornerRadius = UDim.new(0, 7)
				rc.Parent = row
				local btn = Instance.new("TextButton")
				btn.Size = UDim2.new(1, -30, 1, 0)
				btn.BackgroundTransparency = 1
				btn.Font = Enum.Font.Gotham
				btn.TextSize = 11
				btn.TextXAlignment = Enum.TextXAlignment.Left
				btn.TextTruncate = Enum.TextTruncate.AtEnd
				btn.TextColor3 = if code == currentCode then Color3.fromRGB(140, 220, 160) else Color3.fromRGB(225, 232, 248)
				btn.Text = "  " .. title .. " - " .. artist
				btn.Parent = row
				local lyFav = Instance.new("TextButton")
				lyFav.Size = UDim2.new(0, 26, 1, 0)
				lyFav.Position = UDim2.new(1, -28, 0, 0)
				lyFav.BackgroundTransparency = 1
				lyFav.Font = Enum.Font.GothamBold
				lyFav.TextSize = 13
				lyFav.TextColor3 = if favorites[code] then Color3.fromRGB(255, 210, 100) else Color3.fromRGB(120, 125, 145)
				lyFav.Text = "+"
				lyFav.Parent = row
				lyFav.MouseButton1Click:Connect(function()
					if toggleFav then toggleFav(code, title) end
					lyFav.TextColor3 = if favorites[code] then Color3.fromRGB(255, 210, 100) else Color3.fromRGB(120, 125, 145)
				end)
				btn.MouseButton1Click:Connect(function()
					status.Text = "Включаю..."
					task.spawn(function()
						-- очередь = текущий список каталога
						local snap: {{ code: string, title: string }} = {}
						local at = 1
						for j, it in ipairs(lyItems) do
							table.insert(snap, { code = it.code, title = it.title })
							if it.code == code then at = j end
						end
						playCtx = { list = snap, index = at }
						status.Text = playTrack(code, title)
						refreshHistory()
					end)
				end)
				if n >= 15 then break end
			end
		end
		if n >= 15 then break end
	end
	if n == 0 then
		lyStatus.Text = "Ничего не найдено"
	end
end

local function lyFetch(page: number, query: string)
	lyQuery = query
	lyStatus.Text = "Загрузка..."
	for _, ch in ipairs(lyList:GetChildren()) do
		if ch:IsA("Frame") then ch:Destroy() end
	end
	task.spawn(function()
		local url = "https://lylib.fun/api/songs?sort=new&page=" .. tostring(page) .. "&per_page=15"
		if query ~= "" then
			url ..= "&q=" .. urlencode(query)
		end
		local ok, res = pcall(request, { Url = url, Method = "GET" })
		local body: string? = nil
		if ok and res ~= nil then
			if type(res) == "string" then
				body = res
			elseif type(res) == "table" then
				local b = res.Body or res.body or res.Content or res.content
				if type(b) == "string" then body = b end
			end
		end
		if not lyWin.Parent then return end
		if type(body) ~= "string" or body == "" then
			lyStatus.Text = "Ошибка сети"
			notify("Каталог: ошибка сети")
			return
		end
		local ok2, data = pcall(function()
			return HttpService:JSONDecode(body)
		end)
		if not ok2 or type(data) ~= "table" or type(data.items) ~= "table" then
			lyStatus.Text = "Ошибка ответа"
			notify("Каталог: плохой ответ сервера")
			return
		end
		lyPage = tonumber(data.page) or page
		lyPages = math.max(1, tonumber(data.pages) or 1)
		lyItems = {}
		for _, it in ipairs(data.items) do
			if type(it) == "table" then
				local code = normalizeCode(tostring(it.roblox_id or ""))
				if code then
					table.insert(lyItems, { code = code, title = tostring(it.title or "Без названия") })
				end
			end
		end
		lyBuildRows(data.items)
		lyStatus.Text = "Всего треков: " .. tostring(tonumber(data.total) or "?")
		lyPageLabel.Text = tostring(lyPage) .. " / " .. tostring(lyPages)
	end)
end

do
	local dragging = false
	local dragStart: Vector2 = Vector2.new()
	local startPos: UDim2 = lyWin.Position
	lyTop.InputBegan:Connect(function(inp)
		if inp.UserInputType == Enum.UserInputType.MouseButton1 or inp.UserInputType == Enum.UserInputType.Touch then
			dragging = true
			dragStart = inp.Position
			startPos = lyWin.Position
		end
	end)
	UserInputService.InputChanged:Connect(function(inp)
		if dragging and (inp.UserInputType == Enum.UserInputType.MouseMovement or inp.UserInputType == Enum.UserInputType.Touch) then
			local d = inp.Position - dragStart
			lyWin.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X, startPos.Y.Scale, startPos.Y.Offset + d.Y)
		end
	end)
	UserInputService.InputEnded:Connect(function(inp)
		if inp.UserInputType == Enum.UserInputType.MouseButton1 or inp.UserInputType == Enum.UserInputType.Touch then
			dragging = false
		end
	end)
end

lyClose.MouseButton1Click:Connect(function()
	lyWin.Visible = false
end)
-- рандомный трек из текущего списка (сборник с учётом поиска, каталог — страница)
lyRandom.MouseButton1Click:Connect(function()
	local pool: {{ code: string, title: string }} = {}
	if lyMode == "mine" then
		for _, m in ipairs(lyMineView) do
			local c = normalizeCode(tostring(m.roblox_id or ""))
			if c then
				table.insert(pool, { code = c, title = tostring(m.title or c) })
			end
		end
	else
		for _, it in ipairs(lyItems) do
			table.insert(pool, { code = it.code, title = it.title })
		end
	end
	if #pool == 0 then
		status.Text = "Список пуст"
		return
	end
	local idx = math.random(1, #pool)
	local item = pool[idx]
	playCtx = { list = pool, index = idx }
	status.Text = "Включаю..."
	task.spawn(function()
		status.Text = playTrack(item.code, item.title)
		refreshHistory()
	end)
end)
lyFind.MouseButton1Click:Connect(function()
	if lyMode == "mine" then
		lyMineQuery = lySearch.Text or ""
		applyMineFilter()
	else
		lyFetch(1, lySearch.Text)
	end
end)
lySearch.FocusLost:Connect(function(enter)
	if enter then
		if lyMode == "mine" then
			lyMineQuery = lySearch.Text or ""
			applyMineFilter()
		else
			lyFetch(1, lySearch.Text)
		end
	end
end)
lyPrev.MouseButton1Click:Connect(function()
	if lyMode == "mine" then
		if lyMinePage > 1 then
			lyMinePage -= 1
			renderMinePage()
		end
	elseif lyPage > 1 then
		lyFetch(lyPage - 1, lyQuery)
	end
end)
-- ---------- окно избранного (открывается звёздочкой в шапке) ----------
favWin = Instance.new("Frame")
favWin.Name = "Fav"
favWin.Size = UDim2.new(0, 272, 0, 310)
favWin.Position = UDim2.new(1, -574, 0.5, -155)
favWin.BackgroundColor3 = Color3.fromRGB(28, 16, 52)
favWin.BackgroundTransparency = 0
favWin.BorderSizePixel = 0
favWin.Visible = false
favWin.Parent = gui
local favCorner = Instance.new("UICorner")
favCorner.CornerRadius = UDim.new(0, 14)
favCorner.Parent = favWin
local favStroke = Instance.new("UIStroke")
favStroke.Color = Color3.fromRGB(170, 120, 255)
favStroke.Transparency = 0.5
favStroke.Thickness = 1
favStroke.Parent = favWin

local favTop = Instance.new("Frame")
favTop.Size = UDim2.new(1, 0, 0, 32)
favTop.BackgroundTransparency = 1
favTop.Parent = favWin

local favTitle = Instance.new("TextLabel")
favTitle.Size = UDim2.new(1, -44, 1, 0)
favTitle.Position = UDim2.new(0, 12, 0, 0)
favTitle.BackgroundTransparency = 1
favTitle.Font = Enum.Font.GothamBold
favTitle.TextSize = 13
favTitle.TextXAlignment = Enum.TextXAlignment.Left
favTitle.TextColor3 = Color3.fromRGB(228, 216, 255)
favTitle.Text = "Избранное"
favTitle.Parent = favTop

local favClose = Instance.new("TextButton")
favClose.Size = UDim2.new(0, 26, 0, 22)
favClose.Position = UDim2.new(1, -32, 0, 5)
favClose.BackgroundColor3 = Color3.fromRGB(70, 50, 120)
favClose.BackgroundTransparency = 0
favClose.BorderSizePixel = 0
favClose.Font = Enum.Font.GothamBold
favClose.TextSize = 12
favClose.TextColor3 = Color3.fromRGB(230, 235, 255)
favClose.Text = "X"
favClose.Parent = favTop
local favCloseC = Instance.new("UICorner")
favCloseC.CornerRadius = UDim.new(0, 7)
favCloseC.Parent = favClose

local favCount = Instance.new("TextLabel")
favCount.Size = UDim2.new(1, -24, 0, 14)
favCount.Position = UDim2.new(0, 12, 0, 32)
favCount.BackgroundTransparency = 1
favCount.Font = Enum.Font.Gotham
favCount.TextSize = 11
favCount.TextXAlignment = Enum.TextXAlignment.Left
favCount.TextColor3 = Color3.fromRGB(255, 210, 100)
favCount.Text = "Треков: 0"
favCount.Parent = favWin

local favList = Instance.new("ScrollingFrame")
favList.Size = UDim2.new(1, -24, 0, 232)
favList.Position = UDim2.new(0, 12, 0, 48)
favList.BackgroundColor3 = Color3.fromRGB(20, 12, 40)
favList.BackgroundTransparency = 0
favList.BorderSizePixel = 0
favList.ScrollBarThickness = 3
favList.CanvasSize = UDim2.new(0, 0, 0, 0)
favList.AutomaticCanvasSize = Enum.AutomaticSize.Y
favList.Parent = favWin
local favListC = Instance.new("UICorner")
favListC.CornerRadius = UDim.new(0, 9)
favListC.Parent = favList
local favLayout = Instance.new("UIListLayout")
favLayout.Padding = UDim.new(0, 4)
favLayout.SortOrder = Enum.SortOrder.LayoutOrder
favLayout.Parent = favList
local favPad = Instance.new("UIPadding")
favPad.PaddingTop = UDim.new(0, 4)
favPad.PaddingLeft = UDim.new(0, 4)
favPad.PaddingRight = UDim.new(0, 4)
favPad.PaddingBottom = UDim.new(0, 4)
favPad.Parent = favList

function refreshFavWin()
	for _, ch in ipairs(favList:GetChildren()) do
		if ch:IsA("Frame") then ch:Destroy() end
	end
	local nameOf: { [string]: string } = {}
	for _, h in ipairs(history) do
		nameOf[h.id] = h.name
	end
	for id, nm in pairs(favNames) do
		if not nameOf[id] then nameOf[id] = nm end
	end
	if lyItems then
		for _, it in ipairs(lyItems) do
			if it.title and it.title ~= "" and not nameOf[it.code] then
				nameOf[it.code] = it.title
			end
		end
	end
	local order = {}
	for id in pairs(favorites) do
		table.insert(order, { code = id, title = nameOf[id] or id })
	end
	table.sort(order, function(a, b) return a.title < b.title end)
	favOrder = order
	for i, e in ipairs(order) do
		local row = Instance.new("Frame")
		row.Size = UDim2.new(1, -6, 0, 26)
		row.BackgroundColor3 = Color3.fromRGB(55, 35, 105)
		row.BackgroundTransparency = 0
		row.BorderSizePixel = 0
		row.LayoutOrder = i
		row.Parent = favList
		local rc = Instance.new("UICorner")
		rc.CornerRadius = UDim.new(0, 7)
		rc.Parent = row
		local btn = Instance.new("TextButton")
		btn.Size = UDim2.new(1, -30, 1, 0)
		btn.BackgroundTransparency = 1
		btn.Font = Enum.Font.Gotham
		btn.TextSize = 11
		btn.TextXAlignment = Enum.TextXAlignment.Left
		btn.TextTruncate = Enum.TextTruncate.AtEnd
		btn.TextColor3 = if e.code == currentCode then Color3.fromRGB(140, 220, 160) else Color3.fromRGB(225, 232, 248)
		btn.Text = "  " .. e.title .. " — " .. e.code
		btn.Parent = row
		local code = e.code
		local nm = e.title
		btn.MouseButton1Click:Connect(function()
			status.Text = "Включаю..."
			task.spawn(function()
				-- очередь = избранное (листание остаётся внутри вкладки)
				local snap: {{ code: string, title: string }} = {}
				local at = 1
				for j, it in ipairs(favOrder) do
					table.insert(snap, { code = it.code, title = it.title })
					if it.code == code then at = j end
				end
				playCtx = { list = snap, index = at }
				status.Text = playTrack(code, nm)
				refreshHistory()
				refreshFavWin()
			end)
		end)
		local unFav = Instance.new("TextButton")
		unFav.Size = UDim2.new(0, 26, 1, 0)
		unFav.Position = UDim2.new(1, -28, 0, 0)
		unFav.BackgroundTransparency = 1
		unFav.Font = Enum.Font.GothamBold
		unFav.TextSize = 12
		unFav.TextColor3 = Color3.fromRGB(255, 140, 140)
		unFav.Text = "X"
		unFav.Parent = row
		unFav.MouseButton1Click:Connect(function()
			if toggleFav then toggleFav(code, nm) end
		end)
	end
	favCount.Text = "Треков: " .. tostring(#order)
end

do
	local dragging = false
	local dragStart: Vector2 = Vector2.new()
	local startPos: UDim2 = favWin.Position
	favTop.InputBegan:Connect(function(inp)
		if inp.UserInputType == Enum.UserInputType.MouseButton1 or inp.UserInputType == Enum.UserInputType.Touch then
			dragging = true
			dragStart = inp.Position
			startPos = favWin.Position
		end
	end)
	UserInputService.InputChanged:Connect(function(inp)
		if dragging and (inp.UserInputType == Enum.UserInputType.MouseMovement or inp.UserInputType == Enum.UserInputType.Touch) then
			local d = inp.Position - dragStart
			favWin.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X, startPos.Y.Scale, startPos.Y.Offset + d.Y)
		end
	end)
	UserInputService.InputEnded:Connect(function(inp)
		if inp.UserInputType == Enum.UserInputType.MouseButton1 or inp.UserInputType == Enum.UserInputType.Touch then
			dragging = false
		end
	end)
end

favClose.MouseButton1Click:Connect(function()
	favWin.Visible = false
end)
lyNext.MouseButton1Click:Connect(function()
	if lyMode == "mine" then
		local pages = math.max(1, math.ceil(#lyMineView / MINE_PER))
		if lyMinePage < pages then
			lyMinePage += 1
			renderMinePage()
		end
	elseif lyPage < lyPages then
		lyFetch(lyPage + 1, lyQuery)
	end
end)
-- ввод номера страницы клавиатурой: клик по цифрам, напечатать, Enter
lyPageLabel.FocusLost:Connect(function(enter)
	if not enter then return end
	local digits = string.match(lyPageLabel.Text or "", "%d+")
	local n = tonumber(digits or "")
	if not n then
		if lyMode == "mine" then renderMinePage() else lyFetch(lyPage, lyQuery) end
		return
	end
	if lyMode == "mine" then
		lyMinePage = math.floor(n)
		renderMinePage()
		return
	end
	n = math.clamp(math.floor(n), 1, math.max(1, lyPages))
	if n ~= lyPage then
		lyFetch(n, lyQuery)
		return
	end
	lyPageLabel.Text = tostring(lyPage) .. " / " .. tostring(lyPages)
end)

-- тосты-уведомления поверх всего
local toast = Instance.new("TextLabel")
toast.Name = "Toast"
toast.Size = UDim2.new(0, 300, 0, 36)
toast.Position = UDim2.new(0.5, -150, 0, 70)
toast.BackgroundColor3 = Color3.fromRGB(60, 30, 120)
toast.BackgroundTransparency = 0
toast.BorderSizePixel = 0
toast.Font = Enum.Font.GothamBold
toast.TextSize = 12
toast.TextColor3 = Color3.fromRGB(245, 240, 255)
toast.Text = ""
toast.Visible = false
toast.Parent = gui
local toastCorner = Instance.new("UICorner")
toastCorner.CornerRadius = UDim.new(0, 10)
toastCorner.Parent = toast
local toastStroke = Instance.new("UIStroke")
toastStroke.Color = Color3.fromRGB(170, 120, 255)
toastStroke.Transparency = 0.4
toastStroke.Parent = toast
local toastGen = 0
function notify(text: string, ms: number?)
	toastGen += 1
	local g = toastGen
	toast.Text = text
	toast.Visible = true
	task.spawn(function()
		task.wait((ms or 3000) / 1000)
		if g == toastGen and toast.Parent then
			toast.Visible = false
		end
	end)
end

-- ---------- wiring ----------
-- режимы окна каталога: общий lylib.fun или мой сборник с гитхаба
lyMode = "lylib"
local MINE_URL = "https://raw.githubusercontent.com/Boja1586/glassradio-tracks/main/AllTracks.json"
local function setLyMode(mode: string)
	lyMode = mode
	local mine = mode == "mine"
	lyTitle.Text = if mine then "Мой сборник" else "Каталог lylib.fun"
	lySearch.Visible = true
	lyFind.Visible = true
	lySearch.PlaceholderText = if mine then "Поиск по сборнику..." else "Поиск..."
	lyPrev.Visible = true
	lyNext.Visible = true
	lyPageLabel.Visible = true
	lyList.Position = UDim2.new(0, 12, 0, 80)
	lyList.Size = UDim2.new(1, -24, 0, 196)
end
-- счётчик + страницы сборника (580 треков одним списком тормозили бы)
function renderMinePage()
	local total = #lyMineView
	local all = #lyMineMapped
	local pages = math.max(1, math.ceil(total / MINE_PER))
	lyMinePage = math.clamp(lyMinePage, 1, pages)
	local s = (lyMinePage - 1) * MINE_PER + 1
	local e = math.min(s + MINE_PER - 1, total)
	local slice = {}
	for i = s, e do
		table.insert(slice, lyMineView[i])
	end
	lyBuildRows(slice)
	if lyMineQuery ~= "" then
		lyStatus.Text = "Найдено: " .. tostring(total) .. " из " .. tostring(all) .. " • Стр. " .. tostring(lyMinePage) .. " из " .. tostring(pages)
	else
		lyStatus.Text = "Треков: " .. tostring(total) .. " • Стр. " .. tostring(lyMinePage) .. " из " .. tostring(pages)
	end
	lyPageLabel.Text = tostring(lyMinePage) .. " / " .. tostring(pages)
end
-- локальный фильтр сборника по названию/коду (без запросов в сеть)
function applyMineFilter()
	local q = string.lower(lyMineQuery)
	lyMineView = {}
	if q == "" then
		for _, m in ipairs(lyMineMapped) do
			table.insert(lyMineView, m)
		end
	else
		for _, m in ipairs(lyMineMapped) do
			local hay = string.lower(tostring(m.title or "") .. " " .. tostring(m.roblox_id or ""))
			if string.find(hay, q, 1, true) then
				table.insert(lyMineView, m)
			end
		end
	end
	lyMinePage = 1
	renderMinePage()
end
local function fetchMine()
	lyStatus.Text = "Загрузка..."
	for _, ch in ipairs(lyList:GetChildren()) do
		if ch:IsA("Frame") then ch:Destroy() end
	end
	task.spawn(function()
		local ok, res = pcall(request, { Url = MINE_URL, Method = "GET" })
		local body: string? = nil
		if ok and res ~= nil then
			if type(res) == "string" then
				body = res
			elseif type(res) == "table" then
				local b = res.Body or res.body or res.Content or res.content
				if type(b) == "string" then body = b end
			end
		end
		if not lyWin.Parent then return end
		if type(body) ~= "string" or body == "" then
			lyStatus.Text = "Ошибка сети"
			notify("Сборник: ошибка сети")
			return
		end
		local ok2, data = pcall(function()
			return HttpService:JSONDecode(body)
		end)
		if not ok2 or type(data) ~= "table" then
			lyStatus.Text = "Ошибка ответа"
			return
		end
		lyItems = {}
		local mapped = {}
		for _, t in ipairs(data) do
			if type(t) == "table" then
				local code = normalizeCode(tostring(t.id or ""))
				if code then
					local nm = tostring(t.name or code)
					table.insert(lyItems, { code = code, title = nm })
					table.insert(mapped, { title = nm, artist = code, roblox_id = code })
				end
			end
		end
		lyPage = 1
		lyPages = 1
		lyMinePage = 1
		lyMineMapped = mapped
		lyMineQuery = ""
		lySearch.Text = ""
		lyMineView = {}
		for _, m in ipairs(lyMineMapped) do
			table.insert(lyMineView, m)
		end
		renderMinePage()
	end)
end
local function stepTrack(dir: number)
	if not playCtx or #playCtx.list == 0 then
		status.Text = "Нет очереди: включи трек из истории или каталога"
		return
	end
	local n = #playCtx.list
	local idx = ((playCtx.index - 1 + dir) % n) + 1
	local item = playCtx.list[idx]
	status.Text = "Включаю..."
	task.spawn(function()
		status.Text = playTrack(item.code, item.title)
		playCtx.index = idx
		refreshHistory()
	end)
end

prevBtn.MouseButton1Click:Connect(function()
	stepTrack(-1)
end)
nextBtn.MouseButton1Click:Connect(function()
	stepTrack(1)
end)
miniPrev.MouseButton1Click:Connect(function()
	stepTrack(-1)
end)
miniNext.MouseButton1Click:Connect(function()
	stepTrack(1)
end)
-- пауза мини-плеера (только у тебя: сервер трек не ставит на паузу)
local function toggleMiniPause()
	local s: Sound? = activeSeekSound()
	if not s then
		local st = radioState()
		if st and miniPaused then
			s = st.rs
		elseif localSound and localSound.Parent then
			s = localSound
		end
	end
	if not s then
		status.Text = "Нечего ставить на паузу"
		return
	end
	if miniPaused then
		pcall(function() (s :: Sound):Play() end)
		miniPaused = false
		miniPauseBtn.Text = "II"
		status.Text = "Продолжаем"
	else
		pcall(function() (s :: Sound):Pause() end)
		miniPaused = true
		miniPauseBtn.Text = ">"
		status.Text = "Пауза (только у тебя)"
	end
end
miniPauseBtn.MouseButton1Click:Connect(function()
	toggleMiniPause()
end)
-- пауза в главном окне: та же локальная пауза, рядом полная остановка
pauseBtn.MouseButton1Click:Connect(function()
	toggleMiniPause()
end)

playBtn.MouseButton1Click:Connect(function()
	local code = normalizeCode(input.Text)
	if not code then
		status.Text = "Вставь числовой код трека"
		notify("Вставь числовой код трека")
		return
	end
	playCtx = nil -- ручной ввод вне очереди
	status.Text = "Загружаю название..."
	playBtn.Text = "..."
	task.spawn(function()
		local msg = playTrack(code, nil)
		status.Text = msg
		playBtn.Text = "Играть"
		-- после ручного ввода очередь = недавние
		local snap: {{ code: string, title: string }} = {}
		local at = 1
		for j, h in ipairs(history) do
			table.insert(snap, { code = h.id, title = h.name })
			if h.id == code then at = j end
		end
		playCtx = { list = snap, index = at }
		refreshHistory()
	end)
end)

stopBtn.MouseButton1Click:Connect(function()
	status.Text = stopTrack()
	refreshHistory()
end)

clearBtn.MouseButton1Click:Connect(function()
	table.clear(history)
	pcall(function()
		writefile(HISTORY_FILE, "[]")
	end)
	refreshHistory()
	status.Text = "История очищена"
end)

catalogBtn.MouseButton1Click:Connect(function()
	setLyMode("lylib")
	lyWin.Visible = true
	lyFetch(1, lyQuery)
end)
mineBtn.MouseButton1Click:Connect(function()
	setLyMode("mine")
	lyWin.Visible = true
	fetchMine()
end)

boostBtn.MouseButton1Click:Connect(function()
	maxVol = not maxVol
	boostBtn.Text = if maxVol then "MAX громкость: ВКЛ" else "MAX громкость: ВЫКЛ"
	boostBtn.BackgroundColor3 = if maxVol then Color3.fromRGB(140, 220, 160) else Color3.fromRGB(120, 170, 255)
	if maxVol then
		prevFrac = math.clamp(volume / 10, 0, 1)
		if prevFrac > 0.99 then prevFrac = 0.1 end
		setVolumeFrac(1)
		status.Text = "MAX у тебя. Другим громче нельзя: им громкость ставит сервер"
	else
		setVolumeFrac(prevFrac)
		status.Text = "Громкость — по ползунку (до 100% = x10)"
	end
end)
muteBtn.MouseButton1Click:Connect(function()
	muteOthers = not muteOthers
	muteBtn.Text = if muteOthers then "Чужие: мут" else "Чужие: звук"
	muteBtn.BackgroundColor3 = if muteOthers then Color3.fromRGB(200, 70, 90) else Color3.fromRGB(90, 60, 160)
	applyMuteOthers()
	status.Text = if muteOthers then "Чужие радио заглушены (только у тебя)" else "Чужие радио снова слышно"
end)

-- подхватываем трек, который уже играет (например, включён до перезапуска скрипта)
pcall(function()
	local rs = getRadioSound()
	if rs and rs.IsPlaying and rs.SoundId and rs.SoundId ~= "" then
		local code = normalizeCode(rs.SoundId)
		if code then
			currentCode = code
			currentUrl = toRadioUrl(code)
			if maxVol and hasRadioPass() then applyMaxVolume(rs) end
		end
	end
end)

-- заглушка чужих радио (только у тебя): гасит громкость чужих Radio.Sound,
-- респауны и новые песни подхватывает сторож ниже
local muteOthers = false
local savedOtherVol: { [Sound]: number } = {}
local function applyMuteOthers()
	for _, ch in ipairs(workspace:GetChildren()) do
		if ch:IsA("Model") and ch.Name ~= LocalPlayer.Name then
			local r = ch:FindFirstChild("Radio")
			local s = r and r:FindFirstChildOfClass("Sound")
			if s then
				if muteOthers then
					if savedOtherVol[s] == nil then
						local ok, v = pcall(function()
							return s.Volume
						end)
						if ok and type(v) == "number" then
							savedOtherVol[s] = v
						end
					end
					pcall(function()
						s.Volume = 0
					end)
				elseif savedOtherVol[s] ~= nil then
					local v = savedOtherVol[s]
					pcall(function()
						s.Volume = v
					end)
				end
			end
		end
	end
	if not muteOthers then
		table.clear(savedOtherVol)
	end
end

-- сторож: раз в 2 сек возвращает громкость/дальность, если их сбросили (респаун, смена раунда)
getgenv().__GlassRadioBoostGen = ((getgenv().__GlassRadioBoostGen or 0) :: number) + 1
local myGen = getgenv().__GlassRadioBoostGen
	task.spawn(function()
		local tick = 0
		while getgenv().__GlassRadioBoostGen == myGen do
			task.wait(2)
			tick += 1
			if tick % 10 == 0 then
				saveHistory() -- автосейв истории раз в ~20 сек
			end
			if muteOthers then
				applyMuteOthers()
			end
			if maxVol and currentCode and hasRadioPass() then
			local rs = getRadioSound()
			if rs then
				local need = false
				pcall(function()
					need = rs.Volume < 9 or rs.RollOffMaxDistance < 100000
				end)
				if need then applyMaxVolume(rs) end
			end
		end
	end
end)
-- обновление полосы времени 4 раза в секунду
task.spawn(function()
	while getgenv().__GlassRadioBoostGen == myGen do
		task.wait(0.25)
		if not gui.Parent then break end
		local s = activeSeekSound()
		if s then
			local ok, len, pos = pcall(function()
				return (s :: Sound).TimeLength, (s :: Sound).TimePosition
			end)
			if ok and len and len > 1 then
				seekFill.Size = UDim2.new(math.clamp(pos / len, 0, 1), 0, 1, 0)
				seekTime.Text = fmtTime(pos) .. " / " .. fmtTime(len)
			end
		else
			if seekFill.Size.X.Scale ~= 0 then
				seekFill.Size = UDim2.new(0, 0, 1, 0)
				seekTime.Text = "0:00 / 0:00"
			end
		end
	end
end)
-- фиолетовый перелив: градиент медленно крутится, обводка пульсирует оттенками
task.spawn(function()
	local t = 0
	while getgenv().__GlassRadioBoostGen == myGen do
		task.wait(0.07)
		if not gui.Parent then break end
		t += 1
		grad.Rotation = (t % 100) * 3.6
		local pulse = 0.5 + 0.5 * math.sin(t * 0.12)
		stroke.Color = Color3.fromRGB(150 + math.floor(70 * pulse), 110, 255)
		stroke.Transparency = 0.66 + 0.16 * pulse
	end
end)
local boostConn: RBXScriptConnection? = nil
boostConn = LocalPlayer.CharacterAdded:Connect(function()
	if getgenv().__GlassRadioBoostGen ~= myGen then
		if boostConn then boostConn:Disconnect() end
		return
	end
	task.wait(3)
	if maxVol and currentCode and hasRadioPass() then		local rs = getRadioSound()
		if rs then
			-- переиграть трек на новом теле + вернуть буст
			pcall(function()
				ReplicatedStorage.Remotes.Inventory.PlaySong:FireServer(currentUrl)
			end)
			task.wait(0.5)
			local rs2 = getRadioSound()
			if rs2 then applyMaxVolume(rs2) end
		end
	end
	saveHistory() -- смерть/респаун историю не трогает, но сейв не помешает
end)

-- если песни MM2 не подгрузились на старте (сервер тупил), добираем их фоном
task.spawn(function()
	task.wait(8)
	if getgenv().__GlassRadioBoostGen ~= myGen then return end
	if not gui.Parent then return end
	local added = mergeMm2Songs()
	if added > 0 then
		saveHistory()
		refreshHistory()
	end
end)

do
	local dragging = false
	local dragStart: Vector2 = Vector2.new()
	local startPos: UDim2 = main.Position
	local function updateDrag(inputPos: Vector2)
		local d = inputPos - dragStart
		main.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X, startPos.Y.Scale, startPos.Y.Offset + d.Y)
	end
	top.InputBegan:Connect(function(inp)
		if inp.UserInputType == Enum.UserInputType.MouseButton1 or inp.UserInputType == Enum.UserInputType.Touch then
			dragging = true
			dragStart = inp.Position
			startPos = main.Position
		end
	end)
	UserInputService.InputChanged:Connect(function(inp)
		if dragging and (inp.UserInputType == Enum.UserInputType.MouseMovement or inp.UserInputType == Enum.UserInputType.Touch) then
			updateDrag(inp.Position)
		end
	end)
	UserInputService.InputEnded:Connect(function(inp)
		if inp.UserInputType == Enum.UserInputType.MouseButton1 or inp.UserInputType == Enum.UserInputType.Touch then
			dragging = false
		end
	end)
end

do
	local volDrag = false
	local function applyAt(x: number)
		local abs = volBar.AbsolutePosition.X
		local sz = math.max(1, volBar.AbsoluteSize.X)
		setVolumeFrac((x - abs) / sz)
	end
	volBar.InputBegan:Connect(function(inp)
		if inp.UserInputType == Enum.UserInputType.MouseButton1 or inp.UserInputType == Enum.UserInputType.Touch then
			volDrag = true
			applyAt(inp.Position.X)
		end
	end)
	UserInputService.InputChanged:Connect(function(inp)
		if volDrag and inp.UserInputType == Enum.UserInputType.MouseMovement then
			applyAt(inp.Position.X)
		end
	end)
	UserInputService.InputEnded:Connect(function(inp)
		if inp.UserInputType == Enum.UserInputType.MouseButton1 then volDrag = false end
	end)
end

do
	local seekDrag = false
	seekBar.InputBegan:Connect(function(inp)
		if inp.UserInputType == Enum.UserInputType.MouseButton1 or inp.UserInputType == Enum.UserInputType.Touch then
			seekDrag = true
			seekAt(inp.Position.X)
		end
	end)
	UserInputService.InputChanged:Connect(function(inp)
		if seekDrag and inp.UserInputType == Enum.UserInputType.MouseMovement then
			seekAt(inp.Position.X)
		end
	end)
	UserInputService.InputEnded:Connect(function(inp)
		if inp.UserInputType == Enum.UserInputType.MouseButton1 then seekDrag = false end
	end)
end

local collapsed = false
hideBtn.MouseButton1Click:Connect(function()
	collapsed = not collapsed
	body.Visible = not collapsed
	modeLabel.Visible = not collapsed
	miniTrack.Visible = collapsed
	miniPrev.Visible = collapsed
	miniNext.Visible = collapsed
	miniPauseBtn.Visible = collapsed
	if collapsed then
		-- сворачиваем и все остальные окна
		lyWin.Visible = false
		favWin.Visible = false
	end
	main.Size = if collapsed then UDim2.new(0, 272, 0, 50) else UDim2.new(0, 272, 0, 368)
	hideBtn.Text = if collapsed then "+" else "-"
end)
closeBtn.MouseButton1Click:Connect(function()
	pcall(stopTrack)
	gui:Destroy()
	getgenv().GlassRadioGui = nil
end)

UserInputService.InputBegan:Connect(function(inp, gpe)
	if gpe then return end
	if inp.KeyCode == Enum.KeyCode.RightShift then
		gui.Enabled = not gui.Enabled
	end
end)

setVolumeFrac(volume / 10)
refreshHistory()
if currentCode then
	status.Text = "Продолжает играть (MAX)"
	for _, h in ipairs(history) do
		if h.id == currentCode then status.Text = "Играет: " .. h.name break end
	end
	refreshHistory()
else
	status.Text = if radioMode() == "mm2" then "Готово: включай код — услышат все" else "Готово (локальный режим)"
end
