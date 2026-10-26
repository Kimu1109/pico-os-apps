-- テトリスの部品。ミノの形・SRSの壁蹴り・操作ボタンの絵。
-- LuaSceneが本体(main.lua)より先にこのファイルを実行するので、returnではなく
-- グローバル変数LIBへの代入で結果を渡す(本体側は`local LIB = LIB`で受け取る)。
-- 中身: ミノの形・SRSの壁蹴りの表・操作ボタンの絵・HOLD/NEXTのミノの絵
local M = {}

-- ミノ(向き0のマス。yは下向き)と箱の大きさ。並びは画像のタイルと同じ
local SHAPES = {
    { 4, 0,1, 1,1, 2,1, 3,1 }, -- I
    { 4, 1,0, 2,0, 1,1, 2,1 }, -- O
    { 3, 1,0, 0,1, 1,1, 2,1 }, -- T
    { 3, 1,0, 2,0, 0,1, 1,1 }, -- S
    { 3, 0,0, 1,0, 1,1, 2,1 }, -- Z
    { 3, 0,0, 0,1, 1,1, 2,1 }, -- J
    { 3, 2,0, 0,1, 1,1, 2,1 }, -- L
}
-- ROT[p][r] = {x1,y1,...,x4,y4}(右回転は (x,y) -> (n-1-y, x))
local ROT = {}
M.ROT = ROT
for p = 1, 7 do
    local s, n = SHAPES[p], SHAPES[p][1]
    local r0 = {}
    for i = 2, 9 do r0[i - 1] = s[i] end
    ROT[p] = { [0] = r0 }
    for r = 1, 3 do
        local prev, cur = ROT[p][r - 1], {}
        for i = 1, 8, 2 do
            if p == 2 then cur[i], cur[i + 1] = prev[i], prev[i + 1]
            else cur[i], cur[i + 1] = n - 1 - prev[i + 1], prev[i] end
        end
        ROT[p][r] = cur
    end
end
-- SRSの壁蹴り(向きsから右回転するときの候補。yは上向きの表なので使うときに反転する)。
-- 左回転(s→s-1)は「s-1から右回転」の候補の符号を反転したものになる
M.KJ = { [0] = { 0,0, -1,0, -1,1, 0,-2, -1,-2 }, { 0,0, 1,0, 1,-1, 0,2, 1,2 },
    { 0,0, 1,0, 1,1, 0,-2, 1,-2 }, { 0,0, -1,0, -1,-1, 0,2, -1,2 } }
M.KI = { [0] = { 0,0, -2,0, 1,0, -2,-1, 1,2 }, { 0,0, -1,0, 2,0, -1,2, 2,-1 },
    { 0,0, 2,0, -1,0, 2,1, -1,-2 }, { 0,0, 1,0, -2,0, 1,-2, -2,1 } }

local function tri(x, y, dir, s, color)
    for i = 0, s do
        if dir == "l" then pico.draw_line(x - s + i, y - i, x - s + i, y + i, color)
        elseif dir == "r" then pico.draw_line(x + s - i, y - i, x + s - i, y + i, color)
        else pico.draw_line(x - i, y + s - i, x + i, y + s - i, color) end
    end
end

-- 画面の操作ボタン1つの絵(g:button の draw に渡す)。name: left / right / down(ゆっくり) /
-- up(すぐ落とす) / a(右回転) / b(左回転)。on は押している間 true
function M.drawBtn(name, x, y, w, h, on)
    local fg = on and 15 or 0
    pico.fill_rect(x + 2, y + 4, w - 4, h - 8, on and 0 or 7)
    local mx, my = x + w // 2, y + h // 2
    if name == "left" then tri(mx + 3, my, "l", 8, fg)
    elseif name == "right" then tri(mx - 3, my, "r", 8, fg)
    elseif name == "down" then tri(mx, my - 3, "d", 8, fg)
    elseif name == "up" then
        tri(mx, my - 8, "d", 7, fg)
        pico.fill_rect(mx - 8, my + 3, 17, 3, fg)
    else
        pico.draw_circle(mx, my, 9, fg)
        pico.draw_circle(mx, my, 8, fg)
        tri(name == "a" and mx + 9 or mx - 9, my - 3, "d", 4, fg)
    end
end

-- 箱(x,y,w,h)の真ん中にミノを描く
function M.mini(ROT, T, tile, kind, x, y, w, h)
    if not kind or kind == 0 then return end
    local c = ROT[kind][0]
    local mx, my, nx, ny = 9, 9, -1, -1
    for i = 1, 8, 2 do
        mx, nx = math.min(mx, c[i]), math.max(nx, c[i])
        my, ny = math.min(my, c[i + 1]), math.max(ny, c[i + 1])
    end
    local ox = x + (w - (nx - mx + 1) * T) // 2 - mx * T
    local oy = y + (h - (ny - my + 1) * T) // 2 - my * T
    for i = 1, 8, 2 do tile(kind, ox + c[i] * T, oy + c[i + 1] * T) end
end

LIB = M
