-- マイク(pico.mic_*)の動作確認。I2Sマイク SPH0645(GP26=BCLK / GP27=LRCLK / GP28=DOUT)。
-- 開いている間はメーターで聞き続け、[録音]でこのアプリのフォルダの rec_NNNN.wav へ録る。
-- [再生]で最後に録ったものを pico.wav_play で鳴らす。増幅・周波数はこのアプリを閉じると元へ戻る(mic.cfgへは書かない)。
-- 権限 permission_microphone(app.cfg)が要る。PCビルドは PICOOS_MIC=tone(既定)で440Hzの試験音が入る。

local x, y, w, h = pico.content_rect()
local M = 8
local BLACK, WHITE, GREY, RED, GREEN, YELLOW = 0, 15, 7, 12, 10, 14

local last = nil        -- 最後に録ったファイル
local level = 0         -- 0〜1(落ちるときはゆっくり)
local db = -96

local function button(text, bx, by, bw, fn)
    local b = pico.create("Button")
    pico.set(b, "text", text)
    pico.set(b, "x", bx)
    pico.set(b, "y", by)
    pico.set(b, "w", bw)
    pico.set(b, "h", 32)
    pico.set(b, "font_size", 0)
    pico.on(b, "press_end", fn)
    return b
end

local function label(ly, lh)
    local l = pico.create("Label")
    pico.set(l, "x", x + M)
    pico.set(l, "y", ly)
    pico.set(l, "font_size", 0)
    pico.set(l, "max_width", w - M * 2)
    if lh then pico.set(l, "max_height", lh) end
    pico.set(l, "text", "")
    return l
end

button("戻る", x + M, y + 4, 60, function() pico.go_back() end)
pico.on_back(function() pico.mic_stop(); pico.wav_stop(); pico.pop() end)

local status = label(y + 42, 34)
local info = label(y + 78, 34)

-- メーター(-60〜0dBFS)
local MY = y + 116
local meter = pico.create("Canvas")
pico.set(meter, "x", x + M)
pico.set(meter, "y", MY)
pico.set(meter, "w", w - M * 2)
pico.set(meter, "h", 16)
pico.on(meter, "render", function()
    local mw = w - M * 2
    pico.draw_rect(x + M, MY, mw, 16, BLACK)
    local fill = math.floor((mw - 2) * level)
    if fill > 0 then
        local c = (db >= -1 and RED) or (db >= -12 and YELLOW) or GREEN
        pico.fill_rect(x + M + 1, MY + 1, fill, 14, c)
    end
end)

local BY = MY + 26
local half = (w - M * 3) // 2
local rec_btn
rec_btn = button("録音", x + M, BY, half, function()
    if pico.mic_recording() then
        pico.mic_stop()
    else
        local p, err = pico.mic_start()
        if p then last = p else pico.toast("録音できません: " .. tostring(err)) end
    end
end)
button("再生", x + M * 2 + half, BY, half, function()
    if pico.mic_recording() then return end
    if not last then pico.toast("まだ録っていません"); return end
    local ok, err = pico.wav_play(last)
    if not ok then pico.toast("鳴らせません: " .. tostring(err)) end
end)

local third = (w - M * 4) // 3
button("増幅-", x + M, BY + 38, third, function() pico.mic_set_gain(pico.mic_gain() - 6) end)
button("増幅+", x + M * 2 + third, BY + 38, third, function() pico.mic_set_gain(pico.mic_gain() + 6) end)
button("周波数", x + M * 3 + third * 2, BY + 38, third, function()
    local nxt = { [16000] = 24000, [24000] = 48000, [48000] = 16000 }
    local ok, err = pico.mic_set_rate(nxt[pico.mic_rate()] or 16000)
    if not ok then pico.toast(tostring(err)) end
end)

local ok, err = pico.mic_monitor(true)
if not ok then pico.set(status, "text", "メーターを入れられません: " .. tostring(err)) end

local shown_rec = nil
pico.every(50, function()
    local v, d = pico.mic_level()
    local nv = math.max(0, math.min(1, (d + 60) / 60))
    if v <= 0 then nv = 0 end
    local before = level
    level = math.max(nv, level - 0.03)
    db = d
    if math.floor(before * 100) ~= math.floor(level * 100) then pico.invalidate(meter) end
end)

pico.every(250, function()
    local i = pico.mic_info()
    local rec = i.recording
    if rec ~= shown_rec then
        pico.set(rec_btn, "text", i.finishing and "保存中" or (rec and "停止" or "録音"))
        shown_rec = rec
    end
    local s
    if i.input == "failed" then
        s = "マイクのI2Sを開始できません"
    elseif i.input == "running" and not i.signal then
        s = "マイクの信号がありません(配線を確認)"
    elseif rec then
        s = string.format("録音中 %d.%d秒", i.ms // 1000, (i.ms % 1000) // 100)
        if i.dropped > 0 then s = s .. string.format(" 取りこぼし%d", i.dropped) end
    else
        s = "待機中 (" .. i.input .. ")"
    end
    pico.set(status, "text", s)
    -- Label は "_" を下線の印として消すので、ファイル名は空白に置き換えて見せる
    local name = last and last:match("[^/]+$"):gsub("_", " ") or ""
    pico.set(info, "text", string.format("%dHz +%ddB %s", i.rate, i.gain, name))
end)
