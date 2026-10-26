-- ゾンビTD: モジュールどうしで共有する状態(お金・選択・画面の Canvas など)。
-- require("state") はどこから呼んでも同じ表を返す。
local G = {
    mode = "load",          -- load(マップを作っている/始め方を選んでいる)/ play / over(ベースが壊れた)
    money = 0,
    earned = 0,             -- 稼いだ合計(スコアの同点を比べる)
    base = false,           -- ベースのユニット
    sel = {},               -- 選んでいる兵士
    bsel = false,           -- 選んでいる建物(兵士とは同時に選ばない)
    build_mode = false,     -- 「建設」で選んだ種類(次に地図をタップした所へ建てる)
    select_mode = false,    -- 「選択」: ドラッグが範囲選択になる
    flow_dirty = false,     -- バリケードが変わったので流れの場を作り直す
    speed = 1,              -- 1 / 3 / 0(一時停止)
    info_msg = false,       -- 下の欄に少しの間だけ出す言葉
    info_t = 0,
    hud = 0, view = 0, panel = 0,   -- Canvas
}

function G.say(msg)
    G.info_msg, G.info_t = msg, 2.5
    pico.invalidate(G.panel)
end

-- お金が増えた/減った(上の行と下の欄の値段を描き直す)
function G.add_money(n, earned)
    G.money = G.money + n
    if earned then G.earned = G.earned + n end
    pico.invalidate(G.hud)
    pico.invalidate(G.panel)
end

return G
