-- ゾンビTD: ウェーブ(準備時間 → ウェーブ → 準備時間 …)。仕様は docs/ZOMBIE_TD.md「流れ」「ゾンビ側」。
-- 準備時間は30秒(最初だけ60秒)。「次へ」で早く呼ぶと残り秒数×2のお金。
-- ウェーブはそのウェーブのゾンビが全部出て(順番待ちを含む)、全部倒れたら終わりで、30 + 10×ウェーブ数 のお金。
-- ウェーブが進むほど数が増え、遠距離・重量級の割合と体力・攻撃力が上がる。倒したときのお金は ×(1 + 0.05×(n-1))。
-- 序盤(W1〜4)は弱いノーマルを多めに出す「稼ぎどき」: 守りを固めておけば倒した分のお金が貯まる
-- (EARLY_EXTRA × (5 - n) 体を足し、体力は ×0.6〜0.9。W1 は 9 → 17 体で、合計の体力は約1.1倍・お金は約1.9倍)。
local M = {}

M.FIRST_PREP = 60
M.EARLY = 4                   -- 稼ぎどきのウェーブ(ここまで)
local EARLY_EXTRA = 2
M.PREP = 30
M.phase = "prep"              -- prep(準備時間)/ wave
M.n = 1                       -- 今の(準備時間なら次の)ウェーブ
M.timer = M.FIRST_PREP        -- 準備時間の残り秒

function M.reset(n)
    M.n = n or 1
    M.phase = "prep"
    M.timer = M.n == 1 and M.FIRST_PREP or M.PREP
end

-- n 番目のウェーブの中身: ノーマル・遠距離・重量級の数
function M.mix(n)
    local total = 6 + 3 * n + EARLY_EXTRA * math.max(0, M.EARLY + 1 - n)
    local ranged = n >= 2 and math.floor(total * math.min(0.3, 0.08 + 0.02 * n)) or 0
    local heavy = n >= 3 and math.max(1, math.floor(total * math.min(0.25, 0.03 * (n - 2)))) or 0
    return total - ranged - heavy, ranged, heavy
end

function M.hp_mul(n)
    local m = 1 + 0.08 * (n - 1)
    if n <= M.EARLY then m = m * (0.5 + 0.1 * n) end
    return m
end
function M.dmg_mul(n) return 1 + 0.04 * (n - 1) end
function M.money_mul(n) return 1 + 0.05 * (n - 1) end
function M.bonus(n) return 30 + 10 * n end

-- 準備時間に出す予告
function M.preview(n)
    local a, b, c = M.mix(n)
    local s = string.format(pico.tr("次 W%d: %d体"), n, a + b + c)
    if c > 0 and select(3, M.mix(n - 1)) == 0 then return s .. pico.tr(" 重量級が来る!") end
    if b > 0 and select(2, M.mix(n - 1)) == 0 then return s .. pico.tr(" 遠距離が来る!") end
    if c > 0 then return string.format(pico.tr("%s(遠%d・重%d)"), s, b, c) end
    if b > 0 then s = string.format(pico.tr("%s(遠%d)"), s, b) end
    if n <= M.EARLY then s = s .. pico.tr(" 稼ぎどき") end
    return s
end

-- ウェーブを始める: ゾンビの強さを決め、順番待ちへ混ぜて積む(重量級は散らばる)
function M.start(zombies)
    local n = M.n
    zombies.hp_mul, zombies.dmg_mul = M.hp_mul(n), M.dmg_mul(n)
    local a, b, c = M.mix(n)
    local list = {}
    for _ = 1, a do list[#list + 1] = "normal" end
    for _ = 1, b do list[#list + 1] = "ranged" end
    for _ = 1, c do list[#list + 1] = "heavy" end
    for i = #list, 2, -1 do
        local j = math.random(1, i)
        list[i], list[j] = list[j], list[i]
    end
    for _, k in ipairs(list) do zombies.queue(k) end
    M.phase = "wave"
end

-- 「次へ」: 残り秒数×2 のお金を返して、すぐ始められるようにする
function M.skip()
    if M.phase ~= "prep" then return 0 end
    local bonus = math.floor(M.timer) * 2
    M.timer = 0
    return bonus
end

-- dt 秒進める。返り値: "start"(準備時間が終わった)/ "clear"(ウェーブを越えた)/ nil
function M.update(dt, zombies)
    if M.phase == "prep" then
        M.timer = M.timer - dt
        if M.timer <= 0 then return "start" end
    elseif zombies.alive() == 0 and zombies.waiting() == 0 then
        M.n = M.n + 1
        M.phase = "prep"
        M.timer = M.PREP
        return "clear"
    end
    return nil
end

return M
