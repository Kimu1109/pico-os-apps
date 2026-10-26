-- ゾンビTD: 兵士(雇う・移動の指示・戦い・回復・レベルアップ・売却)。仕様は docs/ZOMBIE_TD.md「兵士」。
-- 兵士はベースから出てきて、指示された位置(持ち場)へ経路探索(pico.iso.path)の道で歩く。
-- 持ち場では射程に入ったゾンビを自動で攻撃し、近接兵は持ち場から LEASH マスまで追いかけて、それより離れたら戻る。
-- ベースを攻撃しているゾンビ・遠くから投げているゾンビ・自分を狙うゾンビだけは LEASH + SIEGE_EXTRA マスまで追う
-- (持ち場の少し外から石を投げられ続け、回復兵が回復し続けてウェーブが終わらなくならないように)。
-- 移動中は攻撃されたときだけ反撃する(相手が倒れるか離れたら移動を続ける)。
-- 押し合いは game.lua が C++(pico.iso.crowd)で行い、その後に M.sync() で位置を読み戻す。
-- 1人の表は16個以内のキーにする(zombies.lua と同じ理由)。種類ごとに同じ値はメタテーブルに置く。
local iso = pico.iso
local combat = require("combat")
local sfx = require("sfx")
local M = {}

M.MAX = 32                    -- 同時に雇える数
M.TAG = 3                     -- 人や物の tag(兵士)
local LEASH = 3               -- 持ち場からこれ以上離れたら追うのをやめて戻る(マス)
local SIEGE_EXTRA = 4         -- 遠くまで追う相手(上)は、持ち場から LEASH + これまで追う(マス)
local MELEE_GAP = 0.25        -- 当たりの円の隙間がこれ以下なら近接で叩ける
local COUNTER_EXTRA = 1.0     -- 移動中の反撃: 間合い + これ以内の相手にだけ向かう
local GIVE_UP_TIME = 3        -- この秒数攻撃できなければ(近づけなければ)諦める
local HEAL_RANGE = 2.5        -- 回復兵が回復できる範囲(マス)
local SCAN_GAP = 0.3          -- 攻撃する相手を探し直す間隔(秒)
local SELL_RATE = 0.7         -- 売ると払った合計のこの割合が戻る

-- 種類とレベルごとの値(数値は初期値)。up[i] は Lv i → i+1 の費用
M.TYPES = {
    melee = {
        name = "近接", prio = 1, cost = 60, sx = 124, speed = 1.6,
        up = { 50, 80, 120 },
        lv = {
            { hp = 60, dmg = 6, rate = 0.8 },     -- 短剣
            { hp = 90, dmg = 6, rate = 0.8 },     -- 鎧付き短剣
            { hp = 110, dmg = 10, rate = 0.8 },   -- 鎧付き槍
            { hp = 150, dmg = 12, rate = 0.8 },   -- 強化鎧付き槍
        },
    },
    healer = {
        name = "回復", prio = 2, cost = 70, sx = 148, speed = 1.4,
        up = { 50, 80, 120 },
        lv = {
            { hp = 45, heal = 6, rate = 2.0 },
            { hp = 50, heal = 10, rate = 2.0 },   -- 回復量強化
            { hp = 55, heal = 12, rate = 1.5 },   -- 回復量強化・間隔短縮
            { hp = 65, heal = 16, rate = 1.2 },   -- 回復量強化Ⅱ・間隔短縮
        },
    },
    ranged = {
        name = "弓", prio = 3, cost = 80, sx = 172, speed = 1.4, range = 4.5,
        up = { 60, 90, 130 },
        lv = {
            { hp = 40, dmg = 5, rate = 1.2 },     -- 弓
            { hp = 45, dmg = 7, rate = 1.2 },     -- ダメージ強化
            { hp = 50, dmg = 9, rate = 0.95 },    -- 間隔短縮・ダメージ強化
            { hp = 55, dmg = 11, rate = 0.8 },    -- 間隔短縮・ダメージ強化Ⅱ
        },
    },
}
M.KINDS = { "melee", "healer", "ranged" }

local W, H, R = 12, 22, 0.22  -- 絵の大きさと当たりの半径(3種類とも同じ)
local SET = {}                -- entity_set に渡す表(使い回す)
local HEAL = { color = 10, size = 2, speed = 10, arc = 0 }   -- 回復の光(何も起こさない弾)
local img
local list = {}
local base                    -- ベースのユニット
local stand_rules, path_rules
local clock = 0
M.list = list
M.stats = { hired = 0, lost = 0 }
M.on_lost = nil               -- function(兵士) 倒されたとき
M.blocked = nil               -- function(x, z) その柱に建物があるか(game.lua が入れる。持ち場にも道にもしない)
M.pressing = nil              -- function(ゾンビ) 遠くまで追うべき相手か(zombies.pressing。game.lua が入れる)

-- 最大の耐久
local function max_hp(s) return s.t.lv[s.lv].hp end
M.max_hp = max_hp

local function set_bar(s)
    SET.bar = math.max(0, s.hp) * 100 // max_hp(s)
    iso.entity_set(s.id, SET)
    SET.bar = nil
end

local function post_dist(u, s)
    local dx, dz = u.x - s.px, u.z - s.pz
    return math.sqrt(dx * dx + dz * dz)
end

-- 兵士 s が持ち場からどこまで z を追うか(M.pressing の相手と、s 自身を狙う相手は遠くまで。
-- 近づくと相手が s を狙い直すので、それでも追うのをやめないように)
local function leash_for(z, s)
    if z.tgt == s or (M.pressing and M.pressing(z)) then return LEASH + SIEGE_EXTRA end
    return LEASH
end

-- 攻撃の間合い(弓兵は高低差で伸び縮みする。近接は nil)
local function range_of(s, tgt)
    local r = s.t.range
    return r and r * combat.height_factor(s, tgt)
end

-- 叩かれた/弾が当たった。まだ誰とも戦っていなければ、近くの相手に反撃する
local function hurt(s, dmg, src)
    if s.hp <= 0 then return end
    s.hp = s.hp - dmg
    if s.hp <= 0 then return end
    set_bar(s)
    if s.tgt or not src or src.side ~= "zombie" or src.hp <= 0 or s.kind == "healer" then return end
    local d = combat.dist(s, src)
    local reach = range_of(s, src) or (s.r + src.r + MELEE_GAP)
    local ok
    if s.state == "hold" then ok = post_dist(src, s) <= leash_for(src, s) + (s.t.range or 0)
    else ok = d <= reach + COUNTER_EXTRA end
    if ok then s.tgt, s.wait = src, 0 end
end

local META = {}
for kind, t in pairs(M.TYPES) do
    META[kind] = { __index = { t = t, kind = kind, side = "soldier", hurt = hurt, r = R, prio = t.prio } }
end

function M.init(units_image, base_unit, rules)
    img = units_image
    base = base_unit
    stand_rules = rules
    -- 道の規則: 水には入らない。段差は1段まで登り、2段まで降りる。遠い所も探せるよう点の上限は大きめ
    path_rules = {
        max_up = 1, max_down = 2, height = rules.height or 2, avoid = rules.avoid,
        diagonal = true, partial = true, max_nodes = 3200,
        -- タワーの柱は通らない(バリケードは avoid のブロックで避ける)
        edge = function(_, _, _, nx, _, nz) if M.blocked and M.blocked(nx, nz) then return false end end,
    }
    M.clear()
end

function M.clear()
    for i = #list, 1, -1 do
        combat.remove(list[i])
        iso.entity_remove(list[i].id)
        list[i] = nil
    end
end

function M.count() return #list end

-- 立てる柱か(水・世界の外・ベースの上は不可)。立つ高さを返す
function M.standable(x, z)
    local y = iso.stand(x, z, nil, stand_rules)
    if not y then return nil end
    if base and math.abs(math.floor(x) - base.x) < 2 and math.abs(math.floor(z) - base.z) < 2 then return nil end
    if M.blocked and M.blocked(x, z) then return nil end
    return y
end

-- 持ち場を (px, pz) にして、そこへの道を探す(道の何番目へ向かっているかは path.i)
local function order(s, px, pz)
    s.px, s.pz = px, pz
    s.tgt, s.wait = false, 0
    s.state = "move"
    local path, why = iso.path(s.x, nil, s.z, px, nil, pz, path_rules)
    if path and #path >= 2 then path.i = 2; s.path = path else s.path = false end
    -- メモリが足りず探せなかった: 1秒は探し直さず、持ち場へまっすぐ歩く(wait が負の間)
    if why == "memory" then s.wait = -1 end
end
M.order = order

-- 雇う(ベースの前に出てきて、少し前へ出る)。数の上限なら nil
function M.hire(kind)
    if #list >= M.MAX then return nil end
    local t = M.TYPES[kind]
    local x = base.x + 0.5 + (math.random() - 0.5) * 2
    local z = base.z + 2.6
    local y = iso.stand(x, z, nil, stand_rules) or base.y
    local id = iso.entity_add(img, x, y, z, {
        sx = t.sx, sy = 40 - H, w = W, h = H, r = R, height = H / 16,
        crowd = "move", mass = 1, tag = M.TAG, shadow_color = 3, bar = 100, bar_color = 10,
    })
    if not id then return nil end
    -- look = コマ(0/1) + 左向きなら2。wait = 追っても攻撃できない時間/道で詰まっている時間
    local s = setmetatable({
        id = id, lv = 1, x = x, y = y, z = z, gy = y, hp = t.lv[1].hp, px = x, pz = z,
        path = false, state = "move", tgt = false, atk = 0, scan = 0, look = 0, wait = 0,
    }, META[kind])
    list[#list + 1] = s
    combat.add(s)
    M.stats.hired = M.stats.hired + 1
    -- 持ち場: ベースの前(出現位置の側)の、立てる所
    local px, pz = x + (math.random() - 0.5) * 2, base.z + 4 + math.random() * 1.5
    if not M.standable(px, pz) then px, pz = x, z end
    order(s, px, pz)
    return s
end

-- 保存から戻す: 持ち場 (px, pz) に立った状態で出す
function M.restore(kind, lv, hp, px, pz)
    local s = M.hire(kind)
    if not s then return nil end
    s.lv = math.max(1, math.min(lv or 1, #s.t.lv))
    s.hp = math.max(1, math.min(hp or max_hp(s), max_hp(s)))
    local y = M.standable(px, pz)
    if y then
        s.x, s.z, s.px, s.pz, s.y, s.gy = px, pz, px, pz, y, y
        iso.entity_move(s.id, px, y, pz)
    end
    s.path, s.state = false, "hold"
    s.look = -1
    set_bar(s)
    return s
end

-- 何人かを (x, z) のまわりへ散らばらせて動かす。動かせたら true
function M.order_group(group, x, z)
    local cx, cz = math.floor(x), math.floor(z)
    local cy = M.standable(cx, cz)
    if not cy then return false end
    -- 近い柱から順に、立てて高さの近い所を候補にする
    local cand = {}
    for r = 0, 3 do
        for dx = -r, r do
            for dz = -r, r do
                if math.max(math.abs(dx), math.abs(dz)) == r then
                    local y = M.standable(cx + dx, cz + dz)
                    if y and math.abs(y - cy) <= 1 then cand[#cand + 1] = cx + dx; cand[#cand + 1] = cz + dz end
                end
            end
        end
        if #cand >= 2 * #group then break end
    end
    local nc = #cand // 2
    for i, s in ipairs(group) do
        local k = (i - 1) % nc
        -- 1つの柱に何人も入るときは柱の中で少しずらす
        local spread = (i - 1) >= nc and 0.6 or 0
        order(s, cand[2 * k + 1] + 0.5 + (math.random() - 0.5) * spread,
                 cand[2 * k + 2] + 0.5 + (math.random() - 0.5) * spread)
    end
    return true
end

-- 選んだ印
function M.select(s, on)
    SET.mark = on and 14 or false
    iso.entity_set(s.id, SET)
    SET.mark = nil
end

-- 次のレベルへの費用(最大なら nil)
function M.upgrade_cost(s) return s.t.up[s.lv] end

function M.upgrade(s)
    local c = s.t.up[s.lv]
    if not c then return false end
    local old = max_hp(s)
    s.lv = s.lv + 1
    s.hp = s.hp + (max_hp(s) - old)
    s.look = -1                     -- 次の step で新しいレベルの絵にする
    set_bar(s)
    return true
end

-- 払った合計(雇った費用 + レベルアップの費用)
function M.paid(s)
    local p = s.t.cost
    for i = 1, s.lv - 1 do p = p + s.t.up[i] end
    return p
end

function M.sell_value(s) return math.floor(M.paid(s) * SELL_RATE + 0.5) end

local function remove_at(i)
    local s = list[i]
    combat.remove(s)
    iso.entity_remove(s.id)
    table.remove(list, i)
end

-- 売る(取り除く)。戻るお金を返す
function M.sell(s)
    for i = 1, #list do
        if list[i] == s then
            remove_at(i)
            return M.sell_value(s)
        end
    end
    return 0
end

-- ---------------------------------------------------------------- 戦い

-- 攻撃できる間合いか
local function in_reach(s, tgt, d)
    local rg = range_of(s, tgt)
    if rg then return d <= rg and iso.sight(s.x, s.y + 1.2, s.z, tgt.x, tgt.y + 1, tgt.z, combat.SIGHT_PASS) end
    return d - s.r - tgt.r <= MELEE_GAP
end

-- 持ち場で攻撃する相手を選ぶ(近い順に、弓兵は間合いに入っている・近接は持ち場から LEASH 以内のゾンビ)
local function choose(s)
    local range = s.t.range
    for _, id in ipairs(iso.nearby(s.x, s.z, range and range * 1.5 or LEASH + SIEGE_EXTRA + 1, M.ZOMBIE_TAG, 8)) do
        local z = combat.units[id]
        if z and z.hp > 0 then
            if range then
                if in_reach(s, z, combat.dist(s, z)) then return z end
            elseif post_dist(z, s) <= leash_for(z, s) then
                return z
            end
        end
    end
    return false
end

-- 狙った相手と戦う。返り値: やめたら nil、歩いたら true、止まって戦ったら false
local function engage(s, tgt, dt)
    local d = combat.dist(s, tgt)
    if in_reach(s, tgt, d) then
        s.atk = s.atk - dt
        if s.atk <= 0 then
            local lv = s.t.lv[s.lv]
            s.atk = lv.rate
            if s.t.range then
                combat.shoot(s, tgt, math.floor(lv.dmg * combat.height_factor(s, tgt) + 0.5), 5, 2, 12, 0.15)
                sfx.arrow()
            else
                tgt:hurt(lv.dmg, s)
                sfx.hit()
            end
        end
        s.wait = 0
        return false
    end
    -- 弓兵は追いかけない(間合いの外へ出たら別の相手を探す)
    if s.t.range then return nil end
    -- 近接: 持ち場では LEASH まで、移動中は反撃の間合いまで追う
    if s.state == "hold" then
        if post_dist(tgt, s) > leash_for(tgt, s) then return nil end
    elseif d > s.r + tgt.r + MELEE_GAP + COUNTER_EXTRA then
        return nil
    end
    s.wait = s.wait + dt
    if s.wait > GIVE_UP_TIME then return nil end
    return combat.walk(s, tgt.x, tgt.z, s.t.speed * dt, stand_rules)
end

-- 回復兵: 自分(減っていれば) → 範囲の中で一番減っている(割合で)兵士
local function heal(s, dt)
    s.atk = s.atk - dt
    if s.atk > 0 then return end
    local best = false
    if s.hp < max_hp(s) then
        best = s
    else
        local br = 1
        for _, id in ipairs(iso.nearby(s.x, s.z, HEAL_RANGE, M.TAG, 8)) do
            local o = combat.units[id]
            if o and o.hp > 0 and o.hp / max_hp(o) < br then best, br = o, o.hp / max_hp(o) end
        end
    end
    if not best then s.atk = 0.3; return end
    local lv = s.t.lv[s.lv]
    s.atk = lv.rate
    best.hp = math.min(max_hp(best), best.hp + lv.heal)
    set_bar(best)
    if best ~= s then
        HEAL.target = best.id
        iso.shot_add(s.x, s.y + 1.2, s.z, HEAL)
    end
end

-- 持ち場へ向かう(道をたどる/押し出されたら戻る)。返り値: 歩いたら true と向かう先
local function go(s, dt)
    local v = s.t.speed * dt
    local path = s.path
    if path then
        local p = path[path.i]
        local tx, tz = p.x + 0.5, p.z + 0.5
        if path.i == #path then tx, tz = s.px, s.pz end
        local dx, dz = tx - s.x, tz - s.z
        if dx * dx + dz * dz < 0.02 then
            path.i = path.i + 1
            if path.i > #path then s.path = false end
            return false
        end
        if combat.walk(s, tx, tz, v, stand_rules) then
            s.wait = 0
            return true, tx, tz
        end
        -- 押されて道から外れた: しばらく進めなければ探し直す
        s.wait = s.wait + dt
        if s.wait > 1 then order(s, s.px, s.pz) end
        return false
    end
    local d = post_dist(s, s)
    if s.wait < 0 then s.wait = math.min(0, s.wait + dt) end
    if d > LEASH + 0.5 and s.wait >= 0 then
        order(s, s.px, s.pz)      -- 遠くまで追いかけた/押された: 道を探して戻る
    elseif d > 0.3 then
        if s.state == "move" and d < 0.6 then s.state = "hold" end
        if combat.walk(s, s.px, s.pz, v, stand_rules) then return true, s.px, s.pz end
    else
        s.state = "hold"
    end
    return false
end

local function step(s, dt)
    local tgt = s.tgt
    if tgt and not combat.alive(tgt) then tgt = false; s.tgt = false end
    -- 柱が変わったら立つ高さを合わせる(押されたとき)
    s.gy = iso.stand(s.x, s.z, nil, stand_rules) or s.gy
    if s.kind == "healer" then
        heal(s, dt)
    elseif not tgt and s.state == "hold" then
        s.scan = s.scan - dt
        if s.scan <= 0 then
            s.scan = SCAN_GAP
            tgt = choose(s)
            s.tgt, s.wait = tgt, 0
        end
    end
    local moved, lx, lz = false, nil, nil
    if tgt then
        moved = engage(s, tgt, dt)
        if moved == nil then
            s.tgt, s.wait, s.scan = false, 0, SCAN_GAP
            tgt = false
        else
            lx, lz = tgt.x, tgt.z
        end
    end
    if not tgt then moved, lx, lz = go(s, dt) end
    if s.y ~= s.gy then
        local st = 6 * dt
        if math.abs(s.gy - s.y) <= st then s.y = s.gy
        elseif s.gy > s.y then s.y = s.y + st else s.y = s.y - st end
    end
    -- 見た目: 歩く2コマと向き(画面の左 = x - z が減る方を向くと左右反転)
    local left = s.look >= 2
    if lx then
        local sdx = (lx - s.x) - (lz - s.z)
        if sdx < -0.05 then left = true elseif sdx > 0.05 then left = false end
    end
    local look = ((moved and math.floor(clock * 4.5) % 2) or 0) + (left and 2 or 0)
    if look ~= s.look then
        s.look = look
        SET.sx = s.t.sx + (look % 2) * W
        SET.sy = s.lv * 40 - H          -- units.pimg はレベルごとに40pxの段
        SET.flip = left
        iso.entity_set(s.id, SET)
        SET.sx, SET.sy, SET.flip = nil, nil, nil
    end
end

function M.update(dt)
    clock = clock + dt
    for i = 1, #list do
        local s = list[i]
        if s.hp > 0 then
            step(s, dt)
            iso.entity_move(s.id, s.x, s.y, s.z)
        end
    end
    for i = #list, 1, -1 do
        local s = list[i]
        if s.hp <= 0 then
            remove_at(i)
            M.stats.lost = M.stats.lost + 1
            sfx.lost()
            if M.on_lost then M.on_lost(s) end
        end
    end
end

function M.sync()
    for i = 1, #list do
        local s = list[i]
        local x, _, z = iso.entity_pos(s.id)
        if x then s.x, s.z = x, z end
    end
end

return M
