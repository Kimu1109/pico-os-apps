-- Spotifyのリモコン。スマホ/PCのSpotifyで鳴っている再生を、再生/停止・次へ・前へ・シーク・音量・
-- シャッフル・リピート・端末の切り替えで操作する(この本体から音は出ない)。
--
--   api.lua    … トークンの管理とWeb APIの呼び出し
--   player.lua … 再生の状態を数秒ごとに取る・操作を送る
--   view.lua   … 画面を描く・タップの場所を決める
--
-- 操作には Spotify Premium が要る。最初のログインはPCで picoos spotify-auth(api.lua の説明)。
local A = require("api")
local P = require("player")
local V = require("view")

local X, Y, W, H = pico.content_rect()
local TOP = 32
local canvas
local logged_in = false
local press = nil      -- 押し始めた所の操作(シーク/音量はドラッグ)
local shown_sec = -1

local function redraw() P.dirty = true end

local function check_login()
    local ok, msg = A.load()
    logged_in = ok
    P.reset()
    if msg then P.say(msg, not ok, 5000)
    elseif not ok then P.say("") end
    redraw()
end

local function back()
    P.close()
    pico.pop()
end

-- ---- 端末・メニュー ----
-- ダイアログを閉じた直後に次のダイアログを出すときは1フレーム空ける
local function later(fn) pico.after(30, fn) end

local function choose_device()
    if not logged_in then return end
    P.say("端末を探しています…", false, 3000)
    P.devices(function(list, why)
        if not list then P.say(why, true, 5000) return end
        if #list == 0 then
            P.say("端末が見つかりません。スマホ/PCでSpotifyを開いてください", true, 6000)
            return
        end
        P.say("")
        local names = {}
        for i, d in ipairs(list) do names[i] = (d.active and "● " or "") .. d.name end
        local dlg = pico.show_choice("再生する端末", names)
        pico.on(dlg, "closed", function(_, ok, idx)
            if ok and list[idx + 1] then P.transfer(list[idx + 1].id) end
        end)
    end)
end

local function confirm_logout()
    local m = pico.show_message("ログアウトしますか?(保存したトークンを消します)", "いいえ", "はい")
    pico.on(m, "closed", function(_, yes)
        if yes then
            A.logout()
            logged_in = false
            P.reset()
            P.say("ログアウトしました", false, 4000)
        end
    end)
end

local function open_menu()
    local items = logged_in and { "端末を選ぶ", "今すぐ更新", "ログアウト" } or { "ログイン情報を読み込む" }
    local dlg = pico.show_choice("Spotify", items)
    pico.on(dlg, "closed", function(_, ok, idx)
        if not ok then return end
        if not logged_in then return check_login() end
        if idx == 0 then later(choose_device)
        elseif idx == 1 then P.poll_soon(0)
        elseif idx == 2 then later(confirm_logout) end
    end)
end

-- ---- 操作 ----
local function act(name, v)
    if name == "reload" then return check_login() end
    if not logged_in then return end
    if name == "play" then P.toggle()
    elseif name == "next" then P.next()
    elseif name == "prev" then P.prev()
    elseif name == "shuffle" then P.shuffle()
    elseif name == "repeat" then P.repeat_cycle()
    elseif name == "seek" and P.st then P.seek(v * P.st.duration)
    elseif name == "vol" then P.set_volume(v * 100)
    elseif name == "vol-" then P.volume_step(-5)
    elseif name == "vol+" then P.volume_step(5)
    end
end

local function on_press_start(_, x, y)
    local name, v = V.hit(x, y, logged_in)
    press = name
    if (name == "seek" and P.st and P.st.duration > 0) or (name == "vol" and P.st and P.st.can_volume) then
        V.drag = { kind = name, v = v }
        redraw()
    end
end

local function on_press_move(_, x, y)
    if not V.drag then return end
    local name, v = V.hit(x, y, logged_in)
    if name == V.drag.kind or v then
        V.drag.v = v or V.drag.v
        -- 動かしている欄だけ描き直す(ジャケットをSDから解き直さない)
        pico.mark_dirty((V.drag.kind == "seek" and V.progress_rect or V.volume_rect)())
    end
end

local function on_press_end(_, x, y)
    if V.drag then
        local d = V.drag
        V.drag = nil
        act(d.kind, d.v)
    else
        local name, v = V.hit(x, y, logged_in)
        if name and name == press then act(name, v) end
    end
    press = nil
    redraw()
end

-- 物理キーボード(メディアキー・矢印・文字)
local KEYS = {
    playpause = "play", [" "] = "play", k = "play",
    nexttrack = "next", n = "next", right = "next",
    prevtrack = "prev", p = "prev", left = "prev",
    s = "shuffle", r = "repeat",
}
local function on_key(key, mods)
    if mods.ctrl or mods.alt then return false end
    if key == "volumeup" or key == "up" then P.volume_step(5) return true end
    if key == "volumedown" or key == "down" then P.volume_step(-5) return true end
    if key == "mute" or key == "m" then P.mute() return true end
    if key == "d" then choose_device() return true end
    if key == "stop" then if P.st and P.st.playing then P.toggle() end return true end
    local name = KEYS[key]
    if name then act(name) return true end
    return false
end

-- 外部コントローラー
local PAD = { a = "play", r = "next", l = "prev", x = "shuffle", y = "repeat" }
local function read_pad()
    if not pico.pad_connected() then return end
    for button, name in pairs(PAD) do
        if pico.pad_pressed(button) then act(name) end
    end
    if pico.pad_pressed("up") then P.volume_step(5) end
    if pico.pad_pressed("down") then P.volume_step(-5) end
    if pico.pad_pressed("right") then act("next") end
    if pico.pad_pressed("left") then act("prev") end
    if pico.pad_pressed("select") then choose_device() end
    if pico.pad_pressed("start") then open_menu() end
    if pico.pad_pressed("b") or pico.pad_pressed("home") then back() end
end

function setup()
    -- 上の段: [戻る] Spotify [端末][他]
    local b = pico.create("Button")
    pico.set(b, "icon_id", 30)  -- ArrowLeft
    pico.set(b, "font_size", 0)
    pico.set(b, "x", X + 4) pico.set(b, "y", Y + 3) pico.set(b, "w", 52) pico.set(b, "h", 26)
    pico.on(b, "press_end", back)
    local title = pico.create("Label")
    pico.set(title, "text", "Spotify")
    pico.set(title, "font_size", 0)
    pico.set(title, "x", X + 62) pico.set(title, "y", Y + 8)
    local dev = pico.create("Button")
    pico.set(dev, "text", "端末")
    pico.set(dev, "font_size", 0)
    pico.set(dev, "x", X + W - 108) pico.set(dev, "y", Y + 3) pico.set(dev, "w", 52) pico.set(dev, "h", 26)
    pico.on(dev, "press_end", choose_device)
    local menu = pico.create("Button")
    pico.set(menu, "text", "他")
    pico.set(menu, "font_size", 0)
    pico.set(menu, "x", X + W - 52) pico.set(menu, "y", Y + 3) pico.set(menu, "w", 48) pico.set(menu, "h", 26)
    pico.on(menu, "press_end", open_menu)

    canvas = pico.create("Canvas")
    pico.set(canvas, "x", X) pico.set(canvas, "y", Y + TOP)
    pico.set(canvas, "w", W) pico.set(canvas, "h", H - TOP)
    V.setup(X, Y + TOP, W, H - TOP)
    pico.on(canvas, "render", function() V.render(logged_in) end)
    pico.on(canvas, "press_start", on_press_start)
    pico.on(canvas, "press_move", on_press_move)
    pico.on(canvas, "press_end", on_press_end)

    pico.on_key(on_key)
    pico.on_back(back)
    check_login()
end

function loop()
    read_pad()
    if logged_in and A.revoked then   -- refresh token が使えなくなった: 案内の画面へ(理由は下の欄に残る)
        logged_in = false
        P.reset()
    end
    P.update()
    if P.dirty then
        P.dirty = false
        pico.invalidate(canvas)
        shown_sec = P.st and (P.position() // 1000) or -1
    end
    -- 再生中は1秒ごとに再生位置の欄だけ描き直す
    if P.st and P.st.playing and not V.drag then
        local sec = P.position() // 1000
        if sec ~= shown_sec then
            shown_sec = sec
            pico.mark_dirty(V.progress_rect())
        end
    end
end
