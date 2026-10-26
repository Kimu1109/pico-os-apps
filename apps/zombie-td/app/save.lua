-- ゾンビTD: 途中の保存とハイスコア(アプリのフォルダの store.json。pico.store_save)。
-- マップは種から作り直すので、保存するのは種・ウェーブ数・お金・ベースの耐久・建物と兵士の一覧だけ。
-- 保存するのは準備時間の間(閉じたとき)とウェーブの始め。ウェーブ中に閉じたら、そのウェーブの頭からやり直す。
-- 形: { best = {w=, hp=, earned=}, game = {seed=, w=, money=, earned=, hp=, b = {{種類, x, z, lv, hp}, ...},
--       s = {{種類, lv, hp, x, z}, ...}} }
local M = {}

function M.load()
    local st = pico.store_load()
    if type(st) ~= "table" then st = {} end
    return st
end

-- スコアの比べ方: 耐えたウェーブ数 → 残ったベースの耐久 → 稼いだ合計
function M.better(a, b)
    if not b then return true end
    if a.w ~= b.w then return a.w > b.w end
    if a.hp ~= b.hp then return a.hp > b.hp end
    return a.earned > b.earned
end

-- 今の状態を書く(game = nil なら途中の保存を消す)
function M.write(game, score)
    local st = M.load()
    st.game = game
    if score and M.better(score, st.best) then st.best = score end
    return pico.store_save(st)
end

-- 設定などを1つ書く(tut = 説明を終えた、snd = 効果音)
function M.set(key, value)
    local st = M.load()
    st[key] = value
    return pico.store_save(st)
end

-- 建物と兵士の一覧を表にする
function M.dump(G, waves, soldiers, buildings)
    local b, s = {}, {}
    for _, x in ipairs(buildings.list) do
        -- 建設中・強化中のものは、終わった後(払った分)として残す
        b[#b + 1] = { x.kind, math.floor(x.x), math.floor(x.z), x.lv, math.ceil(x.hp) }
    end
    for _, x in ipairs(soldiers.list) do
        s[#s + 1] = { x.kind, x.lv, x.hp, math.floor(x.px * 100 + 0.5) / 100, math.floor(x.pz * 100 + 0.5) / 100 }
    end
    return { seed = G.seed, w = waves.n, money = G.money, earned = G.earned, hp = G.base.hp, b = b, s = s }
end

-- 保存した一覧を戻す(マップを作り終えて start_play した後に呼ぶ)
function M.restore(game, G, waves, soldiers, buildings, stand_rules)
    G.money, G.earned = game.money or 0, game.earned or 0
    G.base.hp = game.hp or G.base.hp
    waves.reset(game.w or 1)
    for _, e in ipairs(game.b or {}) do
        if buildings.TYPES[e[1]] and buildings.can_place(e[1], e[2], e[3], stand_rules) then
            buildings.restore(e[1], e[2], e[3], e[4], e[5], stand_rules)
        end
    end
    for _, e in ipairs(game.s or {}) do
        if soldiers.TYPES[e[1]] then soldiers.restore(e[1], e[2], e[3], e[4], e[5]) end
    end
end

return M
