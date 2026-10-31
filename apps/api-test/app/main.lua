-- 動作確認: Lua APIの動作確認用の画面をまとめたアプリ。
-- このメニューから各ページ(同じフォルダの *.lua)を pico.push_scene で開き、
-- 各ページの「戻る」(pico.pop)でここへ戻る。権限(app.cfg)は開いたページへ引き継がれる。
--
--   basics.lua … 基本の部品(TabBar / DropdownMenu / Textbox / NumberInput / Checkbox / 図形 / コンテナの出し入れ / テスト音)
--   extra.lua  … 追加の部品(ProgressBar / AnalogClock / DurationPicker / MonthGrid / MarkdownView / TextView / ImageView、
--                 pico.ui / pico.tween / ジェスチャー / 暗号化)
--   draw.lua   … Canvasへの直接描画(図形・太線・画像の拡大/回転/反転・文字幅・on_key・電池)
--   scene.lua  … require / タッチ座標 / 画面の受け渡し(picker.lua) / JSON / タイマー / store
--   pad.lua    … 外部コントローラー
--   sound.lua  … チップチューン音源の鍵盤とデモ曲(demo.mml)
--   notify.lua … 通知(pico.notify)。通知から開かれたときは、このメニューが通知のページへ送る
--   mic.lua    … マイク(pico.mic_*)。メーター・録音・再生・増幅/周波数

local x, y, w, h = pico.content_rect()
local dir = pico.app_dir()

local function open(file, args)
    pico.push_scene(pico.path_join(dir, file), args)
end

local PAGES = {
    { pico.tr("基本の部品"),     "basics.lua" },
    { pico.tr("追加の部品"),     "extra.lua" },
    { pico.tr("直接描画"),       "draw.lua" },
    { pico.tr("画面とデータ"),   "scene.lua" },
    { pico.tr("コントローラー"), "pad.lua" },
    { pico.tr("音"),             "sound.lua" },
    { pico.tr("通知"),           "notify.lua" },
    { pico.tr("マイク"),         "mic.lua" },
}

local BTN_H = 28
local GAP = 3
local top = y + 4

for i, p in ipairs(PAGES) do
    local b = pico.create("Button")
    pico.set(b, "text", p[1])
    pico.set(b, "x", x + 8)
    pico.set(b, "y", top + (i - 1) * (BTN_H + GAP))
    pico.set(b, "w", w - 16)
    pico.set(b, "h", BTN_H)
    pico.on(b, "press_end", function() open(p[2]) end)
end

local back = pico.create("Button")
pico.set(back, "icon_id", 30)  -- ArrowLeft
pico.set(back, "x", x + 8)
pico.set(back, "y", top + #PAGES * (BTN_H + GAP) + 4)
pico.set(back, "w", 80)
pico.set(back, "h", BTN_H)
pico.on(back, "press_end", function() pico.go_back() end)
pico.on_back(function() pico.pop() end)

-- 通知から開かれた(launch_reasonは1回きり)ときは通知のページへ
local tag, data = pico.launch_reason()
if tag then open("notify.lua", { tag = tag, data = data }) end
