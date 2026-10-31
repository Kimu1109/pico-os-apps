-- ゾンビTD: 説明(初めて遊ぶときだけ、地図の上に操作を1つずつ出す)。
-- 言われたことをすると次へ進む(時間で進むものもある)。案内をタップすると説明を終える。
-- 終えたことは store.json の tut に覚える(save.lua)。
local G = require("state")
local soldiers = require("soldiers")
local buildings = require("buildings")
local waves = require("waves")
local M = {}

M.active = false
local step, t = 1, 0

local STEPS = {
    { pico.tr("「建設」で塔を道の近くに建てよう(同じお金なら兵士より強い)"), function() return buildings.count() > 0 end },
    { pico.tr("柵の中のゾンビは遅く、傷つきやすい。塔の前の道に並べよう"), 8 },
    { pico.tr("「雇う」の兵士は動かせる。穴をふさぐのに使おう"), function() return soldiers.count() > 0 end },
    { pico.tr("兵士を選んで地面をタップ(A)すると移動"), function() return G.moved end },
    { pico.tr("準備ができたら上の「次へ」かSTART(早いとお金)"), function() return waves.phase == "wave" end },
    { pico.tr("選ぶと下で強化・修理・売却ができる"), 8 },
    { pico.tr("ゾンビからベースを守り抜こう!"), 5 },
}

function M.start()
    M.active, step, t = true, 1, 0
    G.moved = false
end

function M.stop() M.active = false end

function M.text() return M.active and STEPS[step][1] or nil end

-- dt 秒進める。案内が変わったら true
function M.update(dt)
    if not M.active then return false end
    local s = STEPS[step]
    t = t + dt
    local done
    if type(s[2]) == "number" then done = t >= s[2] else done = s[2]() end
    if not done then return false end
    step, t = step + 1, 0
    if step > #STEPS then M.active = false end
    return true
end

return M
