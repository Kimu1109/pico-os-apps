-- ゾンビTD: ゾンビ(出現・流れの場をたどって歩く・兵士を狙う・ベースへの攻撃・倒れる)。仕様は docs/ZOMBIE_TD.md。
-- 道は C++ の流れの場(pico.iso.flow_*)。ゾンビは自分の柱の「次の柱」の真ん中へ向かって歩くだけ。
-- 気づく範囲に兵士かタワーがいれば、優先度と距離の点数で1つを選んで追う(粘着。離れすぎ・近づけないときだけ諦める。
-- 遠距離は同じ相手へ ENGAGE_MAX 秒投げたら諦めてベースへ進む)。
-- バリケード(ブロック)の中は遅くなり(レベルごとの slow)、通っている間はバリケードの耐久を削る。
-- 中にいる間は身動きが取りにくく、受けるダメージが WALL_EXPOSE 倍になる(タワーと組み合わせる意味を持たせる)。
-- 押し合いは game.lua が C++(pico.iso.crowd)で行い、その後に M.sync() で位置を読み戻す。
-- 1匹の表は16個以内のキーにする(Luaの表はキーが16個を超えると倍の大きさになり、40匹ぶんで約16KB変わる)。
-- 種類ごとに同じ値(t・r・お金・hurt)はメタテーブルに置く。
local iso = pico.iso
local combat = require("combat")
local sfx = require("sfx")
local M = {}

local MAX_ALIVE = 40          -- 同時に出ているゾンビの上限(超えた分は順番待ち)
local SPAWN_GAP = 0.35        -- 同じ出現位置から次を出すまでの秒
M.TAG = 1                     -- 人や物の tag(ゾンビ)
local AWARE = 4               -- 兵士に気づく範囲(マス)
local GIVE_UP_DIST = AWARE * 1.5   -- これより離れたら諦める
local GIVE_UP_TIME = 3        -- この秒数攻撃できない(近づけない)なら諦める
local SCAN_GAP = 0.5          -- 狙う相手を探し直す間隔(秒)
local COOL_DOWN = 5           -- 諦めた後、次に探すまでの秒
-- 遠距離ゾンビが同じ相手へ投げ続けてよい秒。過ぎたら諦めてベースへ向かう(COOL_DOWN の間は探さない)。
-- 兵士が持ち場から届かず、回復兵が回復し続けると、投げ合いが終わらずウェーブが終わらなかったため
local ENGAGE_MAX = 6
local MELEE_GAP = 0.25        -- 当たりの円の隙間がこれ以下なら近接で叩ける

-- 種類(数値は初期値。docs/ZOMBIE_TD.md「ゾンビ側」)
-- bmul = 建物(タワー・バリケード)へのダメージの倍率(重量級は突破・破壊が得意)
M.TYPES = {
    normal = { hp = 30, speed = 1.0, dmg = 5, rate = 1.0, reach = 0, sx = 0, w = 12, h = 22, r = 0.22, mass = 1, money = 5, bmul = 1 },
    ranged = { hp = 20, speed = 0.9, dmg = 4, rate = 1.6, reach = 5, sx = 24, w = 12, h = 22, r = 0.22, mass = 1, money = 7, bmul = 0.5 },
    heavy  = { hp = 90, speed = 0.55, dmg = 12, rate = 1.4, reach = 0, sx = 48, w = 16, h = 26, r = 0.32, mass = 3, money = 12, bmul = 3 },
}
local WALL_WEAR = 0.5         -- 中を通るときに削る量 = 1秒あたりの攻撃力 × 建物への倍率 × これ
local WALL_EXPOSE = 1.3       -- バリケードの中で受けるダメージの倍率

local SET = {}                -- entity_set に渡す表(毎回作るとゴミになり、実機でメモリが尽きるので使い回す)
local img                     -- units.pimg
local list = {}               -- 出ているゾンビ
local queue = {}              -- 順番待ち(種類の名前)
local spawns = {}             -- 出現位置 {x=, z=, y=, wait=}
local base                    -- ベースのユニット(id=, x=, y=, z=, r=, hurt=)
local stand_rules
local clock = 0               -- 歩くコマの時計(秒)
M.list = list
M.stats = { spawned = 0, killed = 0 }
M.on_kill = nil               -- function(ゾンビ) 倒されたとき(お金を足す)
M.hunt = false                -- 狙う相手を探すか(兵士もタワーも無ければ探さない。探すと毎回小さな表ができる)
M.TARGET_TAGS = nil           -- 狙う相手(兵士・タワー)の人や物の tag(game.lua が入れる)
M.wall_at = nil               -- function(x, z) その柱のバリケード(game.lua が入れる)
M.hp_mul, M.dmg_mul = 1, 1    -- ウェーブごとの体力・攻撃力の倍率(waves.lua が入れる)
local slow = 1                -- 今の1匹の速さの倍率(バリケードの中ならそのレベルの slow)

-- 立っている柱のバリケード(高さも合っているもの。無ければ nil)
local function wall_here(zb)
    local w = M.wall_at and M.wall_at(zb.x, zb.z)
    if w and w.y >= zb.gy - 0.5 and w.y <= zb.gy + 1.5 then return w end
    return nil
end

-- 叩かれた/弾が当たった(hp が 0 以下 = 倒れた。取り除くのは sweep)
local function hurt(zb, dmg)
    if zb.hp <= 0 then return end
    if wall_here(zb) then dmg = math.floor(dmg * WALL_EXPOSE + 0.5) end
    zb.hp = zb.hp - dmg
    if zb.hp <= 0 then return end
    SET.bar = math.floor(zb.hp * 100 / (zb.t.hp * M.hp_mul))
    iso.entity_set(zb.id, SET)
    SET.bar = nil
end

local META = {}
for kind, t in pairs(M.TYPES) do
    META[kind] = { __index = { t = t, kind = kind, side = "zombie", hurt = hurt, r = t.r, money = t.money } }
end

function M.init(units_image, spawn_points, base_unit, rules)
    img = units_image
    spawns = {}
    for i, s in ipairs(spawn_points) do spawns[i] = { x = s.x, z = s.z, y = s.y, wait = 0 } end
    base = base_unit
    stand_rules = rules
    M.clear()
end

function M.clear()
    for i = #list, 1, -1 do
        combat.remove(list[i])
        iso.entity_remove(list[i].id)
        list[i] = nil
    end
    for i = #queue, 1, -1 do queue[i] = nil end
end

function M.queue(kind, n)
    for _ = 1, n or 1 do queue[#queue + 1] = kind end
end

function M.alive() return #list end
function M.waiting() return #queue end

-- 立つ高さ(柱の一番上。バリケードの中も立てる)
local function stand(x, z, y)
    return iso.stand(x, z, nil, stand_rules) or y
end

local function spawn_one(kind)
    local t = M.TYPES[kind]
    -- 空いている出現位置から(全部が待ち中なら出さない)
    local best
    for _, s in ipairs(spawns) do
        if s.wait <= 0 and (not best or s.wait < best.wait) then best = s end
    end
    if not best then return false end
    best.wait = SPAWN_GAP
    local x = best.x + 0.5 + (math.random() - 0.5) * 1.6
    local z = best.z + 0.5 + (math.random() - 0.5) * 1.6
    local y = stand(x, z, best.y)
    local id = iso.entity_add(img, x, y, z, {
        sx = t.sx, sy = 40 - t.h, w = t.w, h = t.h, r = t.r, height = t.h / 16,
        crowd = "move", mass = t.mass, tag = M.TAG, shadow_color = 3, bar_color = 12,
    })
    if not id then return false end
    -- look = コマ(0/1) + 左向きなら2。tgt は無いとき false(キーを消さず、表の大きさを変えない)
    local zb = setmetatable({
        id = id, x = x, y = y, z = z, gy = y, hp = math.floor(t.hp * M.hp_mul),
        col = -1, tx = x, tz = z, look = 0, atk = 0, tgt = false, scan = math.random() * SCAN_GAP, throw = false, eng = 0,
    }, META[kind])
    list[#list + 1] = zb
    combat.add(zb)
    M.stats.spawned = M.stats.spawned + 1
    return true
end

-- 気づく範囲の兵士から、点数(距離 + 優先度の順位 × 1.5)の一番小さい1人
local function find_target(zb)
    local best, best_s = false, nil
    for _, id in ipairs(iso.nearby(zb.x, zb.z, AWARE, M.TARGET_TAGS, 8)) do
        local s = combat.units[id]
        if s and s.hp > 0 then
            local sc = combat.dist(zb, s) + s.prio * 1.5
            if not best_s or sc < best_s then best, best_s = s, sc end
        end
    end
    return best
end

-- 向き: 画面の左右(x - z が減る = 左)
local function face(zb, ux, uz)
    local sdx = (ux - zb.x) - (uz - zb.z)
    if sdx < -0.05 then return true elseif sdx > 0.05 then return false end
    return zb.look >= 2
end

local function attack(zb, tgt, dt)
    zb.atk = zb.atk - dt
    if zb.atk <= 0 then
        local t = zb.t
        zb.atk = t.rate
        -- 整数にする(倍率で小数になると、耐久を %d で出すところでエラーになった)
        local dmg = math.max(1, math.floor(t.dmg * M.dmg_mul * (tgt.side == "building" and t.bmul or 1) + 0.5))
        if t.reach > 0 then
            combat.shoot(zb, tgt, dmg, 8, 3, 6, 0.4)
        else
            tgt:hurt(dmg, zb)
        end
    end
end

-- 兵士を追う/叩く。返り値: 諦めたら nil、歩いたら true、止まって戦ったら false
local function fight(zb, tgt, dt)
    local d = combat.dist(zb, tgt)
    if d > GIVE_UP_DIST then return nil end
    local t = zb.t
    local reach
    if t.reach > 0 then
        reach = d <= t.reach and iso.sight(zb.x, zb.y + 1.2, zb.z, tgt.x, tgt.y + 1, tgt.z, combat.SIGHT_PASS)
    else
        reach = d - zb.r - tgt.r <= MELEE_GAP
    end
    if reach then
        -- 遠距離は投げ続けた時間を数え、長すぎたら諦める(届かない相手との膠着を終わらせる)
        if t.reach > 0 then
            zb.eng = zb.eng + dt
            if zb.eng > ENGAGE_MAX then return nil end
        end
        attack(zb, tgt, dt)
        zb.scan = 0
        return false
    end
    -- 近づく。GIVE_UP_TIME 秒たっても攻撃できなければ諦める(scan を追った時間に使う)
    zb.scan = zb.scan + dt
    if zb.scan > GIVE_UP_TIME then return nil end
    return combat.walk(zb, tgt.x, tgt.z, t.speed * slow * dt, stand_rules)
end

-- ベースへ向かう(流れの場)。歩いたら true
local function march(zb, dt)
    local t = zb.t
    local cx, cz = math.floor(zb.x), math.floor(zb.z)
    local col = cx * 1024 + cz
    if col ~= zb.col then
        -- 柱が変わったら、次に向かう柱と立つ高さを引き直す
        zb.col = col
        zb.gy = stand(zb.x, zb.z, zb.gy)
        local d, nx, nz = iso.flow_get(cx, cz)
        -- 遠距離ゾンビ: 届く所まで来て、地形に遮られずベースが見えたら止まって投げる
        zb.throw = t.reach > 0 and d ~= nil and d <= t.reach
            and iso.sight(zb.x, zb.gy + 1.2, zb.z, base.x + 0.5, base.y + 1.5, base.z + 0.5, combat.SIGHT_PASS)
        if nx then zb.tx, zb.tz = nx + 0.5, nz + 0.5
        elseif d then zb.tx, zb.tz = false, false      -- 目的地(ベースの隣)
        else zb.tx, zb.tz = base.x + 0.5, base.z + 0.5 end   -- 届かない所に押し出された: ベースの方へ
    end
    if not zb.tx or zb.throw then
        attack(zb, base, dt)
        return false
    end
    local dx, dz = zb.tx - zb.x, zb.tz - zb.z
    local len = math.sqrt(dx * dx + dz * dz)
    if len <= 1e-4 then return false end
    local v = t.speed * slow * dt
    if v > len then v = len end
    zb.x = zb.x + dx / len * v
    zb.z = zb.z + dz / len * v
    return true
end

-- 1匹を dt 秒進める
local function step(zb, dt)
    -- バリケードの中: 遅くなり、通っている間はバリケードを削る
    slow = 1
    local w = wall_here(zb)
    if w then
        slow = w.t.lv[w.lv].slow
        w:hurt(zb.t.dmg / zb.t.rate * zb.t.bmul * WALL_WEAR * dt, zb)
    end
    local tgt = zb.tgt
    if tgt and not combat.alive(tgt) then tgt = false; zb.tgt = false; zb.scan = 0 end
    if not tgt and M.hunt then
        zb.scan = zb.scan - dt
        if zb.scan <= 0 then
            tgt = find_target(zb)
            zb.tgt, zb.eng = tgt, 0
            zb.scan = tgt and 0 or SCAN_GAP
        end
    end
    local moved, lx, lz
    if tgt then
        moved = fight(zb, tgt, dt)
        if moved == nil then
            -- 諦めて流れの場へ戻る(しばらく探さない)
            zb.tgt, zb.scan, zb.col = false, COOL_DOWN, -1
            moved = false
        end
        lx, lz = tgt.x, tgt.z
    else
        moved = march(zb, dt)
        if zb.tx then lx, lz = zb.tx, zb.tz else lx, lz = base.x + 0.5, base.z + 0.5 end
    end
    -- 段差は少しずつ上り下り(見た目だけ。位置の判定は柱で決まる)
    if zb.y ~= zb.gy then
        local s = 6 * dt
        if math.abs(zb.gy - zb.y) <= s then zb.y = zb.gy
        elseif zb.gy > zb.y then zb.y = zb.y + s else zb.y = zb.y - s end
    end
    -- 見た目: 歩く2コマ(時計で決める)と向き。変わったときだけ entity_set
    local look = ((moved and math.floor(clock * 4) % 2) or 0) + (face(zb, lx, lz) and 2 or 0)
    if look ~= zb.look then
        zb.look = look
        SET.sx = zb.t.sx + (look % 2) * zb.t.w
        SET.flip = look >= 2
        iso.entity_set(zb.id, SET)
        SET.sx, SET.flip = nil, nil
    end
end

-- 倒れたゾンビを取り除く
local function sweep()
    for i = #list, 1, -1 do
        local zb = list[i]
        if zb.hp <= 0 then
            combat.remove(zb)
            iso.entity_remove(zb.id)
            table.remove(list, i)
            M.stats.killed = M.stats.killed + 1
            sfx.kill()
            if M.on_kill then M.on_kill(zb) end
        end
    end
end

function M.update(dt)
    clock = clock + dt
    for _, s in ipairs(spawns) do s.wait = s.wait - dt end
    sweep()
    while #queue > 0 and #list < MAX_ALIVE do
        if not spawn_one(queue[1]) then break end
        table.remove(queue, 1)
    end
    for i = 1, #list do
        local zb = list[i]
        if zb.hp > 0 then
            step(zb, dt)
            iso.entity_move(zb.id, zb.x, zb.y, zb.z)
        end
    end
    sweep()
end

-- 押し合い(iso.crowd)の後に位置を読み戻す
function M.sync()
    for i = 1, #list do
        local zb = list[i]
        local x, _, z = iso.entity_pos(zb.id)
        if x then zb.x, zb.z = x, z end
    end
end

-- 兵士が持ち場から遠くまで追うべき相手か: ベースを攻撃している(石を投げている/ベースの隣で叩いている)か、
-- 遠距離で誰かへ投げている(近接のゾンビは自分から近づいて来るので含めない)
function M.pressing(zb)
    if zb.tgt then return zb.t.reach > 0 end
    return zb.throw or not zb.tx
end

-- 倒す(テスト用)
function M.kill(i)
    local zb = list[i]
    if not zb then return end
    zb.hp = 0
    sweep()
end

M.MAX_ALIVE = MAX_ALIVE
return M
