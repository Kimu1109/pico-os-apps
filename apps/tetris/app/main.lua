-- テトリス風ゲーム。pico.game(2Dゲームの簡易エンジン)で作っている。
--   盤面=タイルマップ(blocks.pimg。変わったマスを map:set() するだけ) / 落ちるミノ・ゴースト=スプライト4枚ずつ
--   HOLD/NEXT/点数=g:on_draw(変わったとき g:dirty) / 操作ボタン=g:button(絵はlib.luaのdrawBtn)
--   画面=g:state(title / play / pause / clear / over)
-- ミノの形・SRSの壁蹴りの表・ボタンの絵は lib.lua(グローバルLIBで渡る)。画像は script/assets/generate_tetris_blocks.py
-- ※LuaSceneが読むのは16KiBまで(日本語コメントは1文字3バイト)。足すときは余裕を見ること
local game = require("pico.game")

local W, H, HID = 10, 20, 2          -- 盤面の幅/高さ + 見えない上の段
local T = 12                         -- タイルの大きさ(px)
local BX, BY = 5, 3                  -- 盤面の左上(キャンバスの中の座標。キャンバスはステータスバーの下の全面)
local SX, SY, SW, SH = 130, 2, 106, 208    -- 右の欄(HOLD/NEXT/点数)
local PY, PH = 246, 54               -- 下の操作ボタン
-- タイルの値(blocks.pimgの左から1番目〜): 1〜7=ミノ 8=ゴースト 9=消える行の白 10=空きマス
local T_GHOST, T_FLASH, T_EMPTY = 8, 9, 10

local LIB = LIB
local ROT, KJ, KI = LIB.ROT, LIB.KJ, LIB.KI

local DIR = pico.app_dir()
local HISCORE_PATH = pico.path_join(DIR, "hiscore.txt")
local g = game.new{ bg = 15, w = 240, h = 300 } -- 240x300で作った配置。大きい画面では真ん中に置く
local img = g:image(pico.path_join(DIR, "blocks.pimg"))
local map = g:tilemap{ image = img, tile = T, x = BX, y = BY, cols = W,
                       data = string.rep(string.char(T_EMPTY), W * H) }

-- 落ちているミノとゴースト(どちらも4マス=スプライト4枚)
local piece_s, ghost_s = {}, {}
for i = 1, 4 do
    ghost_s[i] = g:sprite{ image = img, w = T, h = T, frame = T_GHOST - 1, layer = 1, visible = false }
    piece_s[i] = g:sprite{ image = img, w = T, h = T, frame = 0, layer = 2, visible = false }
end

-- ---- ゲームの状態 ----
local grid = {}       -- 盤面 grid[y*W+x+1] (y=0..H+HID-1)。0=空、1〜7=ミノ
local p, rot, px, py  -- 落下中のミノ
local queue, bag = {}, {}
local hold, held_used = 0, false
local score, lines, level = 0, 0, 1
local hiscore = tonumber(pico.sd_read(HISCORE_PATH) or "") or 0
local fall_t, lock_t, resets, low_y = 0, 0, 0, 0
local das_dir, das_t = 0, 0
local clear_rows, clear_t = {}, 0
local bgm = true
local side_dirty, board_dirty = true, true

local function se(freq, ms, wave, vol, env)
    pico.sound_play(2, freq, ms, { wave = wave or "pulse25", volume = vol or 8, envelope = env or 0 })
end

local function music(on)
    if on and bgm then
        local ok, err = pico.music_play(pico.path_join(DIR, "bgm.mml"))
        if not ok then pico.log("テトリス: BGM " .. tostring(err)) end
    else
        pico.music_stop()
    end
end

local function fits(pp, r, x, y)
    local c = ROT[pp][r]
    for i = 1, 8, 2 do
        local bx, by = x + c[i], y + c[i + 1]
        if bx < 0 or bx >= W or by >= H + HID then return false end
        if by >= 0 and grid[by * W + bx + 1] ~= 0 then return false end
    end
    return true
end

local function ghostY()
    local y = py
    while fits(p, rot, px, y + 1) do y = y + 1 end
    return y
end

local function nextPiece()
    if #bag == 0 then
        bag = { 1, 2, 3, 4, 5, 6, 7 }
        for i = 7, 2, -1 do
            local j = math.random(i)
            bag[i], bag[j] = bag[j], bag[i]
        end
    end
    return table.remove(bag)
end

local function saveHiscore()
    if score > hiscore then
        hiscore = score
        pico.sd_write(HISCORE_PATH, tostring(hiscore))
    end
end

local function gameOver()
    g:go("over")
    side_dirty = true
    music(false)
    se(160, 700, "pulse50", 10, -2)
    saveHiscore()
end

local function spawn(kind)
    if not kind then
        kind = table.remove(queue, 1)
        queue[#queue + 1] = nextPiece()
    end
    p, rot, px, py = kind, 0, 3, 1
    fall_t, lock_t, resets, low_y = 0, 0, 0, py
    side_dirty = true
    if not fits(p, rot, px, py) then gameOver() end
end

local function newGame()
    for i = 1, W * (H + HID) do grid[i] = 0 end
    bag, queue = {}, {}
    for i = 1, 5 do queue[i] = nextPiece() end
    hold, held_used = 0, false
    score, lines, level = 0, 0, 1
    g:go("play")
    board_dirty, side_dirty = true, true
    spawn()
    music(true)
end

local function interval()
    local lv = math.min(level, 20)
    return math.max((0.8 - (lv - 1) * 0.007) ^ (lv - 1) * 1000, 16)
end

-- 接地中に動かせたら固定までの猶予を戻す(15回まで)
local function moved()
    if not fits(p, rot, px, py + 1) and resets < 15 then
        lock_t = 0
        resets = resets + 1
    end
end

local function shift(dx)
    if fits(p, rot, px + dx, py) then
        px = px + dx
        moved()
        return true
    end
    return false
end

local function rotate(dir)
    if p == 2 then return end
    local to = (rot + dir) % 4
    local k = (p == 1) and KI or KJ
    local tbl, sg = k[rot], 1
    if dir < 0 then tbl, sg = k[to], -1 end
    for i = 1, 10, 2 do
        local dx, dy = tbl[i] * sg, -tbl[i + 1] * sg
        if fits(p, to, px + dx, py + dy) then
            rot, px, py = to, px + dx, py + dy
            moved()
            se(1400, 25, "pulse12", 5)
            return
        end
    end
end

local function lock()
    local c = ROT[p][rot]
    local visible = false
    for i = 1, 8, 2 do
        local y = py + c[i + 1]
        grid[y * W + px + c[i] + 1] = p
        if y >= HID then visible = true end
    end
    held_used = false
    board_dirty = true
    clear_rows = {}
    for y = 0, H + HID - 1 do
        local full = true
        for x = 0, W - 1 do
            if grid[y * W + x + 1] == 0 then full = false break end
        end
        if full then clear_rows[#clear_rows + 1] = y end
    end
    local n = #clear_rows
    if n > 0 then
        score = score + ({ 100, 300, 500, 800 })[n] * level
        lines = lines + n
        level = 1 + lines // 10
        clear_t = 0
        g:go("clear")
        if n == 4 then se(1760, 300, "pulse25", 12, -2) else se(880 + n * 220, 180, "pulse50", 10, -3) end
        side_dirty = true
        p = nil
        return
    end
    se(3000, 60, "noise", 6, -1)
    if not visible then p = nil gameOver() return end -- 見える段より上だけで固まった: 終わり
    spawn()
end

local function finishClear()
    for _, row in ipairs(clear_rows) do
        for y = row, 1, -1 do
            for x = 1, W do grid[y * W + x] = grid[(y - 1) * W + x] end
        end
        for x = 1, W do grid[x] = 0 end
    end
    clear_rows = {}
    board_dirty = true
    g:go("play")
    spawn()
end

local function doHold()
    if held_used then return end
    held_used = true
    local k = hold
    hold = p
    se(600, 40, "pulse25", 6)
    if k == 0 then spawn() else spawn(k) end
    held_used = true
end

-- ---- 見た目へ写す ----

-- 盤面をタイルへ。変わったタイルだけエンジンが描き直す
local function syncBoard()
    local flash = g.state_name == "clear"
    for y = 0, H - 1 do
        local lit = false
        if flash then
            for _, r in ipairs(clear_rows) do if r == y + HID then lit = true end end
        end
        for x = 0, W - 1 do
            local v = grid[(y + HID) * W + x + 1]
            map:set(x, y, lit and T_FLASH or (v == 0 and T_EMPTY or v))
        end
    end
end

-- 落ちているミノとゴーストのスプライトの位置(見えない上の段は隠す)
local function syncPiece()
    local show = p and (g.state_name == "play" or g.state_name == "pause")
    local gy = show and ghostY()
    local cells = show and ROT[p][rot]
    for i = 1, 4 do
        local ps, gs = piece_s[i], ghost_s[i]
        if show then
            local cx, cy = cells[i * 2 - 1], cells[i * 2]
            local row, grow = py + cy - HID, gy + cy - HID
            ps.visible, gs.visible = row >= 0, grow >= 0
            ps.x, ps.y, ps.frame = BX + (px + cx) * T, BY + row * T, p - 1
            gs.x, gs.y = ps.x, BY + grow * T
        else
            ps.visible, gs.visible = false, false
        end
    end
end

-- ---- 描画(キャンバスの中のHUD) ----

local function tile(v, x, y)
    pico.draw_image_part(img, x, y, (v - 1) * T, 0, T, T)
end

local function mini(kind, x, y, w, h) LIB.mini(ROT, T, tile, kind, x, y, w, h) end

local function overlaps(x, y, w, h)
    local ax, ay, aw, ah = pico.get_draw_area()
    if aw <= 0 then return true end
    return ax < x + w and x < ax + aw and ay < y + h and y < ay + ah
end

function g:on_draw(ox, oy)
    pico.draw_rect(ox + BX - 1, oy + BY - 1, W * T + 2, H * T + 2, 7)
    local sx, sy = ox + SX, oy + SY
    if not overlaps(sx, sy, SW, SH) then return end
    pico.draw_text(sx + 2, sy, "HOLD", 0, 0)
    pico.draw_rect(sx, sy + 18, 52, 32, held_used and 8 or 0)
    mini(hold, sx, sy + 18, 52, 32)
    pico.draw_text(sx + 2, sy + 54, "BGM", 0, 0)
    pico.draw_text(sx + 2, sy + 72, bgm and "ON" or "OFF", bgm and 2 or 8, 0)
    pico.draw_rect(sx, sy + 52, 52, 40, 7)

    pico.draw_text(sx + 56, sy, "NEXT", 0, 0)
    pico.draw_rect(sx + 54, sy + 18, 52, 92, 0)
    for i = 1, 3 do mini(queue[i], sx + 54, sy + 20 + (i - 1) * 30, 52, 28) end

    local rows = { { "SCORE", score }, { "LEVEL", level }, { "LINES", lines }, { "HI", hiscore } }
    for i, r in ipairs(rows) do
        local y = sy + 116 + (i - 1) * 23
        pico.draw_text(sx + 2, y, r[1], 8, 0)
        local v = tostring(r[2])
        pico.draw_text(sx + SW - 2 - pico.text_width(v, 0), y, v, 0, 0)
    end
end

-- 盤面の真ん中に出す2行の枠(タイトル・一時停止・ゲームオーバー)
local function box(ox, oy, l1, l2)
    local x, y, w = ox + BX + 4, oy + BY + 90, W * T - 8
    pico.fill_rect(x, y, w, 56, 0)
    pico.draw_rect(x, y, w, 56, 15)
    pico.draw_text(x + (w - pico.text_width(l1, 0)) // 2, y + 8, l1, 14, 0)
    pico.draw_text(x + (w - pico.text_width(l2, 0)) // 2, y + 32, l2, 15, 0)
end

-- ---- 操作 ----

local function tapIn(x, y, w, h)
    local t = g.touch
    return t.pressed and t.x >= x and t.x < x + w and t.y >= y and t.y < y + h
end
local function boardTap() return tapIn(BX, BY, W * T, H * T) end
local function holdTap() return tapIn(SX, SY, 54, 52) end
local function bgmTap() return tapIn(SX, SY + 52, 54, 40) end

-- 開始・再開・もう一度のきっかけ(盤面のタップ、START、A/X、上=すぐ落とす)
local function startKey()
    return boardTap() or g:pressed("start") or g:pressed("a") or g:pressed("x") or g:pressed("up")
end

local pause_btn
local function setPause(on)
    if on and g.state_name == "play" then
        g:go("pause")
        music(false)
    elseif not on and g.state_name == "pause" then
        g:go("play")
        music(true)
    else
        return
    end
    pause_btn.label = on and pico.tr("再開") or pico.tr("停止")
    g:dirty(pause_btn.x, pause_btn.y, pause_btn.w, pause_btn.h)
end

local function leave()
    saveHiscore()
    pico.music_stop()
    pico.pop()
end

local function play(ms)
    if g:pressed("l") or g:pressed("r") or g:pressed("zl") or g:pressed("zr") or holdTap() then doHold() end
    if not p or g.state_name ~= "play" then return end
    if g:pressed("a") or g:pressed("x") or boardTap() then rotate(1) end
    if g:pressed("b") or g:pressed("y") then rotate(-1) end

    -- 左右: 押した瞬間に1マス、170ms押し続けたら50msごと
    if g:pressed("left") then das_dir, das_t = -1, 0 shift(-1)
    elseif g:pressed("right") then das_dir, das_t = 1, 0 shift(1) end
    local want = das_dir < 0 and "left" or "right"
    if das_dir ~= 0 and not g:down(want) then
        das_dir, das_t = 0, 0
        if g:down("left") then das_dir = -1 elseif g:down("right") then das_dir = 1 end
    elseif das_dir ~= 0 then
        das_t = das_t + ms
        while das_t >= 170 do
            das_t = das_t - 50
            if not shift(das_dir) then das_t = 169 break end
        end
    end

    if g:pressed("up") then
        local gy = ghostY()
        score = score + (gy - py) * 2
        py = gy
        side_dirty = true
        lock()
        return
    end

    local iv = interval()
    local soft = g:down("down")
    if soft then iv = math.min(iv, 30) end
    fall_t = fall_t + ms
    while fall_t >= iv do
        fall_t = fall_t - iv
        if fits(p, rot, px, py + 1) then
            py = py + 1
            if py > low_y then low_y, resets = py, 0 end
            if soft then score = score + 1 side_dirty = true end
        else
            fall_t = 0
            break
        end
    end
    if not fits(p, rot, px, py + 1) then
        lock_t = lock_t + ms
        if lock_t >= 500 then lock() end
    else
        lock_t = 0
    end
end

g:state("title", {
    update = function() if startKey() then newGame() end end,
    draw = function(_, ox, oy) box(ox, oy, pico.tr("テトリス"), pico.tr("タップで開始")) end,
})
g:state("play", {
    update = function(_, dt)
        if g:pressed("start") then setPause(true) else play(dt * 1000) end
    end,
})
g:state("pause", {
    update = function() if startKey() then setPause(false) end end,
    draw = function(_, ox, oy) box(ox, oy, pico.tr("一時停止中"), pico.tr("タップで再開")) end,
})
g:state("clear", {
    update = function(_, dt)
        clear_t = clear_t + dt * 1000
        if clear_t >= 200 then finishClear() end
    end,
})
g:state("over", {
    update = function() if startKey() then newGame() end end,
    draw = function(_, ox, oy) box(ox, oy, "GAME OVER", pico.tr("タップでもう一度")) end,
})

-- 毎フレーム(状態ごとの update の後): 見た目へ写す
function g:on_update()
    if self:pressed("back") then leave() return end
    if self:pressed("pause") then setPause(self.state_name == "play") end
    if bgmTap() then
        bgm = not bgm
        side_dirty = true
        music(self.state_name == "play")
    end
    if board_dirty then
        syncBoard()
        board_dirty = false
    end
    syncPiece()
    if side_dirty then
        self:dirty(SX, SY, SW, SH)
        side_dirty = false
    end
end

-- 下の操作ボタン(左から)。名前はコントローラーのボタン名と同じにしてあるので、
-- 画面のボタンでも十字キー・A/Bでも同じ g:down / g:pressed で読める。
-- up は「すぐ落とす」、a は右回転、b は左回転
for i, n in ipairs({ "left", "down", "right", "up", "b", "a" }) do
    g:button{ name = n, x = (i - 1) * 40, y = PY, w = 40, h = PH, draw = function(b, x, y, w, h, on)
        LIB.drawBtn(n, x, y, w, h, on)
    end }
end
pause_btn = g:button{ name = "pause", x = SX, y = SH + 6, w = 50, h = 30, label = pico.tr("停止") }
g:button{ name = "back", x = SX + 54, y = SH + 6, w = 50, h = 30, label = "left" }

for i = 1, W * (H + HID) do grid[i] = 0 end
pico.on_back(leave)
-- PCビルドの --scene play(画面写真用): タイトルを飛ばしてすぐ始める
local tag, scene = pico.launch_reason()
if tag == "scene" and scene == "play" then newGame() else g:go("title") end
