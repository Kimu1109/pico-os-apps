-- ゾンビTD: 戦いの共通部分(人や物のハンドル → ユニットの表、弾、距離と高低差)。
-- ユニット(ベース・ゾンビ・兵士)は表で、どれも次を持つ:
--   id(人や物のハンドル)・x, y, z(足元)・hp(0 以下 = 倒れた)・r(当たりの半径)・
--   side("base" "zombie" "soldier")・hurt(自分, ダメージ, 撃った/叩いたユニット)
-- 弾は C++ の pico.iso.shot_*。撃ったユニットとダメージは弾のハンドルで覚えておき、当たったら hurt を呼ぶ。
local iso = pico.iso
local M = {}

M.units = {}                  -- 人や物のハンドル → ユニット
local shot_src = {}           -- 弾のハンドル → 撃ったユニット
local shot_dmg = {}           -- 弾のハンドル → ダメージ
local SHOT = {}               -- shot_add に渡す表(使い回す)

function M.add(u) M.units[u.id] = u end
function M.remove(u) if M.units[u.id] == u then M.units[u.id] = nil end end
-- まだ生きているか(倒れて取り除かれた後の古い参照を見分ける)
function M.alive(u) return u and u.hp > 0 and M.units[u.id] == u or false end

-- 水平の距離
function M.dist(a, b)
    local dx, dz = a.x - b.x, a.z - b.z
    return math.sqrt(dx * dx + dz * dz)
end

-- 当たりの円どうしの隙間(負なら重なっている)
function M.gap(a, b) return M.dist(a, b) - a.r - b.r end

-- 高低差の倍率: 相手より1段高いごとに +10%(+50% まで)、低いと同じだけ下がる(-30% まで)
function M.height_factor(a, b)
    local f = 1 + 0.1 * (a.y - b.y)
    if f > 1.5 then return 1.5 elseif f < 0.7 then return 0.7 end
    return f
end

-- 狙った相手へ弾を撃つ(必ず当たる)。opts は shot_add の color / size / speed / arc
function M.shoot(src, tgt, dmg, color, size, speed, arc)
    SHOT.target = tgt.id
    SHOT.color = color or 0
    SHOT.size = size or 2
    SHOT.speed = speed or 8
    SHOT.arc = arc or 0
    local id = iso.shot_add(src.x, src.y + 1.2, src.z, SHOT)
    if id then shot_src[id] = src; shot_dmg[id] = dmg end
    return id
end

-- 弾を進めて、当たったものに hurt を呼ぶ
function M.step(dt)
    if iso.shot_count() == 0 then return end   -- 弾が無いのに毎フレーム空の表を作らない
    for _, h in ipairs(iso.shots_step(dt)) do
        local src, dmg = shot_src[h.id], shot_dmg[h.id]
        shot_src[h.id] = nil
        shot_dmg[h.id] = nil
        if not h.lost and dmg then
            local u = M.units[h.target]
            if u then u:hurt(dmg, src) end
        end
    end
end

-- 弾を全部消す(ユニットの表はそのまま)
function M.clear_shots()
    iso.shot_clear()
    for k in pairs(shot_src) do shot_src[k] = nil end
    for k in pairs(shot_dmg) do shot_dmg[k] = nil end
end

-- 地形に沿って (tx, tz) の方へ v だけ歩く。登れない段差・水・世界の外へは入らない(入れない軸だけ止める)。
-- rules は iso.stand の規則。歩けたら true。u.gy(立つ高さ)も合わせる
local function can_enter(u, nx, nz, rules)
    local ny = iso.stand(nx, nz, nil, rules)
    if not ny then return nil end
    if ny - u.gy > 1.01 or u.gy - ny > 2.01 then return nil end
    return ny
end

-- (nx, nz) へ動けるなら動かす
local function try(u, nx, nz, rules)
    if math.floor(nx) == math.floor(u.x) and math.floor(nz) == math.floor(u.z) then
        u.x, u.z = nx, nz
        return true
    end
    local ny = can_enter(u, nx, nz, rules)
    if not ny then return false end
    u.x, u.z, u.gy = nx, nz, ny
    return true
end

function M.walk(u, tx, tz, v, rules)
    local dx, dz = tx - u.x, tz - u.z
    local len = math.sqrt(dx * dx + dz * dz)
    if len < 1e-4 then return false end
    if v > len then v = len end
    local nx, nz = u.x + dx / len * v, u.z + dz / len * v
    -- 斜めに入れなければ、片方の軸だけで滑る
    return try(u, nx, nz, rules) or try(u, nx, u.z, rules) or try(u, u.x, nz, rules)
end

return M
