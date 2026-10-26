-- ゾンビTD: 建物(弓塔・剣塔・バリケード)。仕様は docs/ZOMBIE_TD.md「建物」。
-- 建設・レベルアップには時間がかかり、その間は耐久が低い(完成時の40%)。修理は3秒かけて戻る。売ると払った合計の70%。
-- タワーは人や物(crowd = "fixed")で、ゾンビの狙う相手になる。バリケードはブロック(穴の開いた絵、pass)で、
-- ゾンビは中を通り抜けられるが遅くなり(レベルが上がるほど遅い)、通っている間はバリケードの耐久が下がる。
-- 1つの表のキーは16個以内(zombies.lua と同じ理由)。種類ごとに同じ値はメタテーブルに置く。
local iso = pico.iso
local combat = require("combat")
local sfx = require("sfx")
local M = {}

M.TAG = 4                     -- 人や物の tag(タワー)
M.WALLS = { 12, 14, 15, 16 }  -- バリケード Lv1〜4 のブロック番号(faces.pimg のこの段を柵の絵にしてある)
M.MAX_TOWERS = 20
local LOW = 0.4               -- 建設中・レベルアップ中の耐久(完成時の割合)
local REPAIR_TIME = 3
local REPAIR_RATE = 0.3       -- 修理の費用 = 減った割合 × 払った合計 × これ
local SELL_RATE = 0.7
local SCAN_GAP = 0.3
local MELEE_GAP = 0.9         -- 剣塔はこれだけ離れていても届く(台の上から槍で突く)

-- 種類とレベルごとの値(数値は初期値)。up[i] は Lv i → i+1 の費用。build は建設の秒(レベルアップはその半分)
-- 動けない代わりに、同じお金なら兵士より強くしてある(近接兵 $60 で 7.5/秒・耐久60 に対し、
-- 弓塔 $100 で 13/秒・射程6、剣塔 $90 で 17/秒・耐久450。docs/ZOMBIE_TD.md「釣り合い」)
M.TYPES = {
    arrow = {
        name = "弓塔", tower = true, prio = 4, cost = 100, build = 5, sx = 216, range = 6,
        up = { 80, 120, 170 },
        lv = {
            { hp = 200, dmg = 12, rate = 0.9 },
            { hp = 230, dmg = 17, rate = 0.9 },    -- ダメージ強化
            { hp = 260, dmg = 20, rate = 0.7 },    -- 間隔短縮・ダメージ強化
            { hp = 300, dmg = 26, rate = 0.55 },   -- 間隔短縮・ダメージ強化Ⅱ
        },
    },
    guard = {
        -- ゾンビが一番先に狙う(囮。優先度の順位 0)
        name = "剣塔", tower = true, prio = 0, cost = 90, build = 5, sx = 236,
        up = { 70, 110, 160 },
        lv = {
            { hp = 450, dmg = 12, rate = 0.7 },
            { hp = 650, dmg = 12, rate = 0.7 },    -- 鎧 → 塔の耐久
            { hp = 750, dmg = 18, rate = 0.7 },    -- 槍
            { hp = 1000, dmg = 22, rate = 0.7 },   -- 強化鎧 → 塔の耐久
        },
    },
    -- slow = 中を通るゾンビの速さの倍率(zombies.lua)
    wall = {
        name = "柵", cost = 20, build = 3,
        up = { 25, 40, 60 },
        lv = { { hp = 150, slow = 0.5 }, { hp = 260, slow = 0.45 }, { hp = 400, slow = 0.4 }, { hp = 600, slow = 0.35 } },
    },
}
M.KINDS = { "arrow", "guard", "wall" }

local SET = {}
local img
local base
local spawns
local list = {}
M.list = list
M.at = {}                     -- 柱(x * 1024 + z) → 建物
M.on_walls_changed = nil      -- function() バリケードが増えた/消えた(流れの場を作り直す)
M.on_lost = nil               -- function(建物) 壊されたとき
local towers = 0

local function col(x, z) return math.floor(x) * 1024 + math.floor(z) end

-- 最大の耐久(建設中・レベルアップ中は低い)
local function max_hp(b)
    local full = b.t.lv[b.lv].hp
    if b.state ~= "ready" then return math.floor(full * LOW) end
    return full
end
M.max_hp = max_hp

local function set_bar(b)
    if not b.id then return end
    SET.bar = math.max(0, b.hp) * 100 // max_hp(b)
    SET.bar_color = b.state == "ready" and 10 or 14
    iso.entity_set(b.id, SET)
    SET.bar, SET.bar_color = nil, nil
end

local function hurt(b, dmg)
    if b.hp <= 0 then return end
    b.hp = b.hp - dmg
    if b.hp > 0 then set_bar(b) end
end

local META = {}
for kind, t in pairs(M.TYPES) do
    META[kind] = { __index = { t = t, kind = kind, side = "building", hurt = hurt, r = t.tower and 0.45 or 0.5, prio = t.prio or 9 } }
end

function M.init(units_image, base_unit, spawn_points)
    img = units_image
    base = base_unit
    spawns = spawn_points
    M.clear()
end

-- set_wall_block は下で定義する
local set_wall_block

-- 全部取り除く(バリケードのブロックも空気へ戻す。流れの場の作り直しは呼び出し側で)
function M.clear()
    local open = iso.size() ~= nil
    for i = #list, 1, -1 do
        local b = list[i]
        if b.id then combat.remove(b); iso.entity_remove(b.id)
        elseif open then set_wall_block(b, 0) end
        list[i] = nil
    end
    for k in pairs(M.at) do M.at[k] = nil end
    towers = 0
end

function M.count() return #list end

-- 置けるか。置けないときは理由を返す
function M.can_place(kind, x, z, stand_rules)
    x, z = math.floor(x), math.floor(z)
    if M.at[col(x, z)] then return false, "もう建物があります" end
    if not iso.stand(x, z, nil, stand_rules) then return false, "そこには置けません" end
    if math.max(math.abs(x - base.x), math.abs(z - base.z)) <= 3 then return false, "ベースの近くには置けません" end
    for _, s in ipairs(spawns) do
        if math.max(math.abs(x - s.x), math.abs(z - s.z)) <= 3 then return false, "出現位置の近くには置けません" end
    end
    if M.TYPES[kind].tower and towers >= M.MAX_TOWERS then return false, "タワーは" .. M.MAX_TOWERS .. "個までです" end
    return true
end

function set_wall_block(b, block)
    local x, z = math.floor(b.x), math.floor(b.z)
    iso.set(x, b.y, z, block)
    iso.dirty_edit(x, b.y, z)
end

-- 建てる(建設中から始まる)。can_place を通してから呼ぶこと
function M.place(kind, x, z, stand_rules)
    x, z = math.floor(x), math.floor(z)
    local t = M.TYPES[kind]
    local y = iso.stand(x, z, nil, stand_rules)
    -- x, z は柱の真ん中(ユニットの位置)。rr = 修理で1秒に戻す量、look = 左を向いているか
    local b = setmetatable({ x = x + 0.5, y = y, z = z + 0.5, hp = 1, lv = 1, state = "build", timer = t.build,
        atk = 0, tgt = false, scan = 0, rr = 0, id = false, look = false }, META[kind])
    if t.tower then
        local id = iso.entity_add(img, x + 0.5, y, z + 0.5, {
            sx = 196, sy = 16, w = 20, h = 24, r = 0.45, height = 2, crowd = "fixed", tag = M.TAG,
            shadow_color = 3, bar = 100, bar_color = 14,
        })
        if not id then return nil end
        b.id = id
        -- 撃つ高さ・高低差の倍率は台の上(地面より1段上)で数える
        b.y = y + 1
        combat.add(b)
        towers = towers + 1
    else
        set_wall_block(b, M.WALLS[1])
        if M.on_walls_changed then M.on_walls_changed() end
    end
    b.hp = max_hp(b)
    set_bar(b)
    list[#list + 1] = b
    M.at[col(x, z)] = b
    return b
end

-- 建設/レベルアップが終わった
local function finish(b)
    local low = max_hp(b)
    b.state = "ready"
    b.hp = b.hp + (max_hp(b) - low)
    if b.id then
        SET.sx, SET.sy, SET.w, SET.h, SET.height = b.t.sx, b.lv * 40 - 36, 20, 36, 2.2   -- レベルごとに40pxの段
        iso.entity_set(b.id, SET)
        SET.sx, SET.sy, SET.w, SET.h, SET.height = nil, nil, nil, nil, nil
    end
    set_bar(b)
end

-- 保存から戻す: 完成した状態で lv・hp にする
function M.restore(kind, x, z, lv, hp, stand_rules)
    local b = M.place(kind, x, z, stand_rules)
    if not b then return nil end
    b.lv = math.max(1, math.min(lv or 1, #b.t.lv))
    finish(b)
    b.hp = math.max(1, math.min(hp or max_hp(b), max_hp(b)))
    if not b.id then set_wall_block(b, M.WALLS[b.lv]) end
    set_bar(b)
    return b
end

-- 払った合計
function M.paid(b)
    local p = b.t.cost
    for i = 1, b.lv - 1 do p = p + b.t.up[i] end
    return p
end

function M.busy(b) return b.state ~= "ready" end

-- 次のレベルへの費用(最大・建設中なら nil)
function M.upgrade_cost(b)
    if b.state ~= "ready" then return nil end
    return b.t.up[b.lv]
end

function M.upgrade(b)
    if not M.upgrade_cost(b) then return false end
    b.lv = b.lv + 1
    b.state = "up"
    b.timer = b.t.build / 2
    b.rr = 0
    b.hp = math.min(b.hp, max_hp(b))
    if not b.id then set_wall_block(b, M.WALLS[b.lv]) end
    set_bar(b)
    return true
end

-- 修理の費用(要らない・できないなら nil)
function M.repair_cost(b)
    if b.state ~= "ready" or b.rr > 0 then return nil end
    local m = max_hp(b)
    if b.hp >= m then return nil end
    return math.max(1, math.floor((1 - b.hp / m) * M.paid(b) * REPAIR_RATE + 0.5))
end

function M.repair(b)
    if not M.repair_cost(b) then return false end
    b.rr = (max_hp(b) - b.hp) / REPAIR_TIME
    b.timer = REPAIR_TIME
    return true
end

-- 売った額(売れないなら nil)
function M.sell_value(b)
    if b.state ~= "ready" then return nil end
    return math.floor(M.paid(b) * SELL_RATE + 0.5)
end

local function remove(b)
    for i = #list, 1, -1 do if list[i] == b then table.remove(list, i) end end
    M.at[col(b.x, b.z)] = nil
    if b.id then
        combat.remove(b)
        iso.entity_remove(b.id)
        towers = towers - 1
    else
        set_wall_block(b, 0)
        if M.on_walls_changed then M.on_walls_changed() end
    end
end

function M.sell(b)
    local v = M.sell_value(b)
    if not v then return 0 end
    remove(b)
    return v
end

-- (x, z) の柱のバリケード(無ければ nil)
function M.wall_at(x, z)
    local b = M.at[col(x, z)]
    return b and not b.id and b or nil
end

-- ---------------------------------------------------------------- 戦い(タワー)

local function in_reach(b, z)
    local d = combat.dist(b, z)
    if b.t.range then
        return d <= b.t.range * combat.height_factor(b, z)
            and iso.sight(b.x, b.y + 1.2, b.z, z.x, z.y + 1, z.z, combat.SIGHT_PASS)
    end
    return d - b.r - z.r <= MELEE_GAP
end

local function fight(b, dt)
    local tgt = b.tgt
    if tgt and not (combat.alive(tgt) and in_reach(b, tgt)) then tgt = false; b.tgt = false end
    if not tgt then
        b.scan = b.scan - dt
        if b.scan > 0 then return end
        b.scan = SCAN_GAP
        local range = (b.t.range or 1) * 1.5 + 0.5
        for _, id in ipairs(iso.nearby(b.x, b.z, range, M.ZOMBIE_TAG, 8)) do
            local z = combat.units[id]
            if z and z.hp > 0 and in_reach(b, z) then tgt = z; break end
        end
        b.tgt = tgt
        if not tgt then return end
    end
    b.atk = b.atk - dt
    if b.atk > 0 then return end
    local lv = b.t.lv[b.lv]
    b.atk = lv.rate
    if b.t.range then
        combat.shoot(b, tgt, math.floor(lv.dmg * combat.height_factor(b, tgt) + 0.5), 5, 2, 12, 0.15)
        sfx.arrow()
    else
        tgt:hurt(lv.dmg, b)
        sfx.hit()
    end
    local left = (tgt.x - b.x) - (tgt.z - b.z) < 0
    if b.look ~= left then
        b.look = left
        SET.flip = left
        iso.entity_set(b.id, SET)
        SET.flip = nil
    end
end

function M.update(dt)
    for i = 1, #list do
        local b = list[i]
        if b.hp > 0 then
            if b.state ~= "ready" then
                b.timer = b.timer - dt
                if b.timer <= 0 then finish(b); sfx.built() end
            else
                if b.rr > 0 then
                    b.timer = b.timer - dt
                    b.hp = math.min(max_hp(b), b.hp + b.rr * dt)
                    if b.timer <= 0 then b.rr = 0 end
                    set_bar(b)
                end
                if b.id then fight(b, dt) end
            end
        end
    end
    for i = #list, 1, -1 do
        local b = list[i]
        if b.hp <= 0 then
            remove(b)
            sfx.lost()
            if M.on_lost then M.on_lost(b) end
        end
    end
end

-- 建物の残り秒(建設中・レベルアップ中・修理中。無ければ nil)
function M.remaining(b)
    if b.state ~= "ready" or b.rr > 0 then return math.max(0, b.timer) end
    return nil
end

M.col = col
return M
