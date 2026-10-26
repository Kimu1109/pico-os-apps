-- require のデモ用モジュール(scene.lua から require("util") で読まれる)
local M = {}

function M.pad2(n)
    return string.format("%02d", n)
end

-- 秒数を "m:ss" にする
function M.clock(sec)
    return string.format("%d:%02d", sec // 60, sec % 60)
end

return M
