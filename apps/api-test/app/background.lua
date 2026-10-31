-- バックグラウンドスクリプトの動作確認(app.cfg の background)。
-- アプリを閉じている間も background_interval(60秒)ごとに、小さな使い捨てのエンジンで上から1回動く。
-- 画面の pico.*(create 等)は無い。回をまたぐ値は settings_* で持ち越す(グローバル変数は残らない)。
-- 通知のページの「BG通知」を入れておくと、動くたびに通知を出す。

local runs = tonumber(pico.settings_get("bg_runs") or "0") + 1
local t = pico.get_time()
pico.settings_set("bg_runs", tostring(runs))
pico.settings_set("bg_last", string.format("%02d:%02d:%02d", t.hour, t.min, t.sec))
pico.log("動作確認(バックグラウンド): " .. runs .. "回目 is_background=" .. tostring(pico.is_background())
         .. " create=" .. tostring(pico.create))

if pico.settings_get("bg_notify") == "true" then
    -- タイマーが残っている間はエンジンが生きている(1秒後に出して終わる)
    pico.after(1000, function()
        pico.notify{ title = pico.tr("バックグラウンド"), body = pico.tr("%s回目に動きました", runs), tag = "bg", data = "bg", sound = false }
    end)
end
