-- ペイント: ペン/消しゴム/直線/四角形/楕円/塗りつぶしで描き、.pimgで保存/読込する。
-- 描画(プレビュー・塗りつぶし・元に戻す)はCanvasRaster(C++)の仕事で、ここは道具の
-- 切り替えとファイル操作の配線だけ。詳細はlua-api-doc/content/examples/paint.md。
-- ※LuaSceneが読むのは16KiBまで。コメントを増やしすぎないこと

-- Buttonのw/hは枠・立体表示を含めた全体の大きさ。文字/アイコンの領域はこれより9px小さい
local BUTTON_FRAME = 9

local APP_DIR = "/lua/apps/ペイント"

-- 色(PICO 4bitパレット番号。src/consts.hpp)
local BLACK = 0
local DARKGREY = 8
local RED = 12
local WHITE = 15

-- canvas_mode(src/gui/widgets/CanvasRaster.hppのCanvas::Mode)
local MODE_LINE = 0     -- フリーハンド
local MODE_RECT = 1
local MODE_ELLIPSE = 2
local MODE_STRAIGHT = 4
local MODE_FILL = 5

-- IconID(src/gui/icons/icons_data.hのenum順、0始まり)
local ICON_ARROW_LEFT = 30
local ICON_SQUARE = 35       -- square.svg(チェックボックスの「空」と同じ絵)
local ICON_SAVE = 50         -- device-floppy
local ICON_ERASER = 54
local ICON_PENCIL = 70
local ICON_LINE = 71
local ICON_CIRCLE = 72
local ICON_SQUARE_FILLED = 73
local ICON_CIRCLE_FILLED = 74
local ICON_BUCKET = 75
local ICON_PALETTE = 76
local ICON_UNDO = 77
local ICON_FOLDER_OPEN = 78
local ICON_FILE_PLUS = 79
local ICON_SIZE_24 = 1 -- IconSize::Px24

-- brush_radius。0は1px。消しゴムは同じ段階でひと回り太く
local PEN_SIZES = { 0, 1, 2, 4, 7 }
local ERASER_SIZES = { 3, 4, 6, 9, 13 }

-- 淡い色(色ボタンのアイコンを黒にする)
local LIGHT_COLORS = { [7] = true, [10] = true, [11] = true, [14] = true, [15] = true }

---------------------------------------------------------------------------
-- 状態
---------------------------------------------------------------------------
local tool = "pen"       -- pen / eraser / straight / rect / ellipse / fill
local color = BLACK
local size_index = 2
local fill_shape = false -- 四角形/楕円を塗りつぶすか
local current_path = nil -- 開いている/保存したファイル(nilなら無題)
local modified = false   -- 保存してから描いたか
local message = nil      -- ステータス行に一時的に出す一言
local undone = false     -- 直前の「元に戻す」で戻した状態か(次に押すとやり直し)

---------------------------------------------------------------------------
-- レイアウト
---------------------------------------------------------------------------
local x, y, w, h = pico.content_rect()
local margin = 3
local gap = 3
local btn_size = 30
-- Buttonのw/hは枠を含む全体の大きさ。中身(btn_size)に枠のぶんを足した高さが見た目の高さ
local btn_visual_h = btn_size + BUTTON_FRAME

local row1_y = y + margin
local row2_y = row1_y + btn_visual_h + 2

-- n個並べたときのi番目(0始まり)のxと幅。余りは最後へ足す
local function column(i, n)
    local cw = math.floor((w - margin * 2 - gap * (n - 1)) / n)
    local cx = x + margin + (cw + gap) * i
    if i == n - 1 then cw = (x + w - margin) - cx end
    return cx, cw
end

local function makeIconButton(icon_id, bx, by, bw)
    local id = pico.create("Button")
    pico.set(id, "x", bx)
    pico.set(id, "y", by)
    pico.set(id, "w", bw + BUTTON_FRAME)
    pico.set(id, "h", btn_size + BUTTON_FRAME)
    if icon_id then
        pico.set(id, "icon_id", icon_id)
        pico.set(id, "icon_size", ICON_SIZE_24)
    end
    return id
end

local function row1(icon_id, i) local bx, bw = column(i, 7); return makeIconButton(icon_id, bx, row1_y, bw) end
local function row2(icon_id, i) local bx, bw = column(i, 6); return makeIconButton(icon_id, bx, row2_y, bw) end

local btn_back     = row1(ICON_ARROW_LEFT, 0)
local btn_pen      = row1(ICON_PENCIL, 1)
local btn_eraser   = row1(ICON_ERASER, 2)
local btn_straight = row1(ICON_LINE, 3)
local btn_rect     = row1(ICON_SQUARE, 4)
local btn_ellipse  = row1(ICON_CIRCLE, 5)
local btn_fill     = row1(ICON_BUCKET, 6)

local btn_color = row2(ICON_PALETTE, 0)
local btn_size_ = row2(nil, 1) -- 絵は下のプレビュー(Canvas)が描く
local btn_undo  = row2(ICON_UNDO, 2)
local btn_new   = row2(ICON_FILE_PLUS, 3)
local btn_open  = row2(ICON_FOLDER_OPEN, 4)
local btn_save  = row2(ICON_SAVE, 5)

-- 太さボタンの上に今の太さと色の丸を描くCanvasを重ねる(後に作るのでタップも受ける)
local size_bx, size_bw = column(1, 6)
local preview_d = 22
local size_preview = pico.create("Canvas")
pico.set(size_preview, "x", size_bx + math.floor((size_bw - preview_d) / 2))
pico.set(size_preview, "y", row2_y + math.floor((btn_size - preview_d) / 2) + 2)
pico.set(size_preview, "w", preview_d)
pico.set(size_preview, "h", preview_d)
pico.set(size_preview, "background_color", WHITE)

-- ステータス行(ファイル名・未保存の印・一時的なメッセージ)
local status_y = row2_y + btn_visual_h + 1
local status = pico.create("Label")
pico.set(status, "x", x + margin)
pico.set(status, "y", status_y)
pico.set(status, "font_size", 0) -- Small16px
pico.set(status, "text", "")

-- 枠線のRectはCanvasRasterより先に作る(後だとタップを奪う。スクラッチパッド参照)
local canvas_y = status_y + 18
local canvas_w = w - margin * 2
local canvas_h = h - (canvas_y - y) - margin

local border = pico.create("Rect")
pico.set(border, "x", x + margin - 1)
pico.set(border, "y", canvas_y - 1)
pico.set(border, "w", canvas_w + 2)
pico.set(border, "h", canvas_h + 2)
pico.set(border, "filled", false)
pico.set(border, "thickness", 1)
pico.set(border, "color", DARKGREY)

local canvas = pico.create("CanvasRaster")
pico.set(canvas, "x", x + margin)
pico.set(canvas, "y", canvas_y)
pico.set(canvas, "w", canvas_w)
pico.set(canvas, "h", canvas_h)
-- 元に戻す用の控え(キャンバスと同じ大きさ)。確保できなければ使えない
pico.set(canvas, "undo_enabled", true)
local undo_available = pico.get(canvas, "undo_enabled")

---------------------------------------------------------------------------
-- 表示の更新
---------------------------------------------------------------------------
local TOOL_NAMES = {
    pen = "ペン", eraser = "消しゴム", straight = "直線",
    rect = "四角形", ellipse = "楕円", fill = "塗りつぶし",
}

local function fileName(path)
    return path and path:match("([^/]+)$") or "無題"
end

local function refreshStatus()
    local text
    if message then
        text = message
    else
        local tool_name = TOOL_NAMES[tool]
        if (tool == "rect" or tool == "ellipse") and fill_shape then
            tool_name = tool_name .. "(塗)"
        end
        text = fileName(current_path) .. (modified and "(未保存)" or "") .. "  " .. tool_name
    end
    pico.set(status, "text", text)
end

local function say(text)
    message = text
    refreshStatus()
end

local TOOL_BUTTONS = {
    pen = btn_pen, eraser = btn_eraser, straight = btn_straight,
    rect = btn_rect, ellipse = btn_ellipse, fill = btn_fill,
}

-- 道具・色・太さ・塗りつぶしをキャンバスとボタンへ反映する
local function applyTool()
    local mode = MODE_LINE
    if tool == "straight" then mode = MODE_STRAIGHT
    elseif tool == "rect" then mode = MODE_RECT
    elseif tool == "ellipse" then mode = MODE_ELLIPSE
    elseif tool == "fill" then mode = MODE_FILL end
    pico.set(canvas, "canvas_mode", mode)

    if tool == "eraser" then
        pico.set(canvas, "color", WHITE)
        pico.set(canvas, "brush_radius", ERASER_SIZES[size_index])
    else
        pico.set(canvas, "color", color)
        pico.set(canvas, "brush_radius", PEN_SIZES[size_index])
    end
    pico.set(canvas, "filled", fill_shape)

    -- 選択中の道具は赤い枠
    for name, id in pairs(TOOL_BUTTONS) do
        pico.set(id, "border_color", name == tool and RED or BLACK)
    end
    pico.set(btn_rect, "icon_id", fill_shape and ICON_SQUARE_FILLED or ICON_SQUARE)
    pico.set(btn_ellipse, "icon_id", fill_shape and ICON_CIRCLE_FILLED or ICON_CIRCLE)

    -- 色ボタンは今の色そのものを背景にする
    pico.set(btn_color, "background_color", color)
    pico.set(btn_color, "text_color", LIGHT_COLORS[color] and BLACK or WHITE)

    pico.invalidate(size_preview)
    refreshStatus()
end

pico.on(size_preview, "render", function()
    local px, py = pico.get(size_preview, "x"), pico.get(size_preview, "y")
    local cx, cy = px + preview_d // 2, py + preview_d // 2
    pico.set_draw_area(px, py, preview_d, preview_d)
    if tool == "eraser" then
        local r = math.min(ERASER_SIZES[size_index], preview_d // 2 - 1)
        pico.draw_circle(cx, cy, r, BLACK)
    else
        local r = PEN_SIZES[size_index]
        pico.fill_circle(cx, cy, r, color)
        -- 白は地と区別できないので輪郭を付ける
        if color == WHITE then pico.draw_circle(cx, cy, r + 1, DARKGREY) end
    end
    pico.clear_draw_area()
end)

---------------------------------------------------------------------------
-- ダイアログを閉じた直後に次を開くと跡が残る(FlushDirty()は半透明の下を
-- 描き直さない。docs/design/browser-net.md「ブラウザのヘッダー」)ので、続きは数フレーム遅らせる
---------------------------------------------------------------------------
local pending = nil
local pending_frames = 0

local function later(fn)
    pending = fn
    pending_frames = 2
end

function loop(dt)
    if pending then
        pending_frames = pending_frames - 1
        if pending_frames <= 0 then
            local fn = pending
            pending = nil
            fn()
        end
    end
end

-- 確認ダイアログ。OKならon_okを(次のダイアログを開けるよう遅らせて)呼ぶ
local function confirm(text, ok_text, on_ok)
    local d = pico.show_message(text, "キャンセル", ok_text)
    pico.on(d, "closed", function(_, is_ok)
        if is_ok then later(on_ok) end
    end)
end

local function notice(text)
    pico.show_message(text, "閉じる", "OK")
end

---------------------------------------------------------------------------
-- ファイル操作
---------------------------------------------------------------------------
local function dirOf(path)
    return path and path:match("^(.*)/[^/]*$") or APP_DIR
end

local function doSave(path)
    if pico.canvas_save(canvas, path) then
        current_path = path
        modified = false
        say("保存しました: " .. fileName(path))
    else
        notice("保存できませんでした")
    end
end

local function askSave()
    local default_name = current_path and fileName(current_path) or "無題.pimg"
    local d = pico.show_file_save(dirOf(current_path), default_name)
    pico.on(d, "closed", function(id, is_ok)
        if not is_ok then return end
        local path = pico.get(id, "path")
        if not path or path:sub(-1) == "/" then
            later(function() notice("ファイル名を入れてください") end)
            return
        end
        if not path:lower():match("%.pimg$") then path = path .. ".pimg" end

        -- 開いているファイル以外へ上書きするときだけ確かめる
        if path ~= current_path and pico.sd_exists(path) then
            later(function()
                confirm(fileName(path) .. " を上書きしますか?", "上書き", function() doSave(path) end)
            end)
        else
            doSave(path)
        end
    end)
end

local function askOpen()
    local d = pico.show_file_select(dirOf(current_path))
    pico.on(d, "closed", function(id, is_ok)
        if not is_ok then return end
        local path = pico.get(id, "path")
        if not path or not path:lower():match("%.pimg$") then
            later(function() notice(".pimg の画像を選んでください") end)
            return
        end
        -- 大きさは変えずに左上へ合わせて読む
        if pico.canvas_load(canvas, path, true) then
            current_path = path
            modified = false
            say("開きました: " .. fileName(path))
        else
            later(function() notice("開けませんでした") end)
        end
    end)
end

-- 未保存の変更があれば確かめてからfnを実行する
local function unlessDiscarding(text, ok_text, fn)
    if modified then confirm(text, ok_text, fn) else fn() end
end

---------------------------------------------------------------------------
-- ボタン
---------------------------------------------------------------------------
local function selectTool(name)
    -- 四角形/楕円は選択中にもう一度押すと輪郭⇔塗りつぶし
    if name == tool and (name == "rect" or name == "ellipse") then
        fill_shape = not fill_shape
    end
    tool = name
    message = nil
    applyTool()
end

for name, id in pairs(TOOL_BUTTONS) do
    pico.on(id, "press_start", function() selectTool(name) end)
end

pico.on(btn_color, "press_start", function()
    local d = pico.show_color()
    pico.on(d, "closed", function(id, is_ok)
        local c = pico.get(id, "value")
        if is_ok and c and c >= 0 then
            color = c
            -- 消しゴムのまま色を変えても意味が無いのでペンへ
            if tool == "eraser" then tool = "pen" end
            message = nil
            applyTool()
        end
    end)
end)

local function cycleSize()
    size_index = size_index % #PEN_SIZES + 1
    message = nil
    applyTool()
end
pico.on(btn_size_, "press_start", cycleSize)
pico.on(size_preview, "press_start", cycleSize)

pico.on(btn_undo, "press_start", function()
    if not undo_available then
        say("元に戻すは使えません(メモリ不足)")
    elseif pico.canvas_undo(canvas) then
        -- 控えと入れ替えるので、続けて押すと戻す/やり直すが交互
        undone = not undone
        modified = true
        say(undone and "元に戻しました" or "やり直しました")
    else
        say("戻せる操作がありません")
    end
end)

pico.on(btn_new, "press_start", function()
    confirm("白紙に戻しますか?", "白紙に", function()
        pico.canvas_clear(canvas)
        current_path = nil
        modified = false
        say("新しい絵")
    end)
end)

pico.on(btn_open, "press_start", function()
    unlessDiscarding("保存していない変更を捨てて開きますか?", "開く", askOpen)
end)

pico.on(btn_save, "press_start", askSave)

pico.on(btn_back, "press_start", function()
    unlessDiscarding("保存せずに終了しますか?", "終了", function() pico.pop() end)
end)

-- キャンバスに触れたら「未保存の変更あり」
pico.on(canvas, "press_start", function()
    undone = false
    if not modified or message then
        modified = true
        message = nil
        refreshStatus()
    end
end)

applyTool()
