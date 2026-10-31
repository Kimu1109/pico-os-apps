-- スクラッチパッド: 手書きメモアプリ。
--
-- 描画は"CanvasRaster"(pico.create("CanvasRaster"))1枚。自前のLGFX_Spriteを
-- 持ち続けるウィジェットで、causeOnPressMove()がタッチのドラッグをそのまま
-- 線として焼き込むため、"Canvas"(LuaCanvas)と違って毎フレーム全部を
-- 描き直す必要が無い(過去に描いた線を覚えておくLua側の配列も不要)。
--
-- w/hのリサイズ(pico.set(id,"w"/"h",...))とpico.canvas_clear/save/loadは
-- このアプリのために新設したLua API。CanvasRasterは元々100×100固定でリサイズも
-- クリア/保存/読み込みの手段も無かった。詳細はlua-api-doc/content/api/graphics/canvas.mdと
-- guide/freehand-drawing.md、C++側の設計意図はsrc/lua/LuaEngine.hppの
-- 「ラスタキャンバスの保存/読み込み」コメントを参照。
--
-- ツールバーはテキストボタンではなくアイコンボタン1段(描画領域を広く取るため)。
-- Buttonのicon_id/icon_sizeも元々C++側にsetIcon()はあったがLuaへ橋渡しされて
-- いなかった穴で、このアプリを作る過程で埋めた(WidgetProperty.cppのButtonケース参照)。

-- Buttonのw/hは枠・立体表示を含めた全体の大きさ。文字/アイコンの領域はこれより9px小さい
local BUTTON_FRAME = 9

local SAVE_PATH = "/lua/apps/スクラッチパッド/memo.pimg"

local PEN_BLACK = 0    -- PICO_BLACK
local PEN_BLUE = 9     -- PICO_BLUE
local ERASER_WHITE = 15 -- PICO_WHITE(背景色と同じ=消しゴム)

local PEN_RADIUS = 2
local ERASER_RADIUS = 8

local BORDER_NORMAL = 0    -- PICO_BLACK
local BORDER_SELECTED = 12 -- PICO_RED(選択中のペン/消しゴムの枠)

-- IconID(src/gui/icons/icons_data.hのenum順、0始まり)。名前→番号の変換表は
-- Lua側に無いため、他のenum系プロパティ(canvas_mode等)と同じく数値+コメントで持つ
local ICON_ARROW_LEFT = 30
local ICON_TRASH = 28
local ICON_STACK_PUSH = 52 -- 保存(スタックへ積む=保存、の見立て)
local ICON_STACK_POP = 51  -- 読込(スタックから取り出す=読込、の見立て)
local ICON_BRUSH = 53
local ICON_ERASER = 54
local ICON_SIZE_24 = 1 -- IconSize::Px24

local x, y, w, h = pico.content_rect()
local margin = 3
local gap = 3
local btn_size = 30

local function makeIconButton(icon_id, bx, by)
    local id = pico.create("Button")
    pico.set(id, "x", bx)
    pico.set(id, "y", by)
    pico.set(id, "w", btn_size + BUTTON_FRAME)
    pico.set(id, "h", btn_size + BUTTON_FRAME)
    pico.set(id, "icon_id", icon_id)
    pico.set(id, "icon_size", ICON_SIZE_24)
    return id
end

-- ツールバー1段: 戻る・黒ペン・青ペン・消しゴム・全消去・保存・読込(7個)。
-- 戻るは先頭(=画面左上)に置き、他とは独立した「ナビゲーション」であることを示す。
-- 幅で割った余りは最後のボタンへ足す(TabBar/MonthGridと同じ流儀。docs/design/gui.md参照)
local row_y = y + margin
local col_w = math.floor((w - margin * 2 - gap * 6) / 7)
local col_last_w = w - margin * 2 - (col_w + gap) * 6 -- 最後の列だけ余り分だけ広い

local function colX(i) -- i: 0始まりの列番号
    return x + margin + (col_w + gap) * i
end

local btn_back   = makeIconButton(ICON_ARROW_LEFT, colX(0), row_y)
local btn_black  = makeIconButton(ICON_BRUSH,       colX(1), row_y)
local btn_blue   = makeIconButton(ICON_BRUSH,       colX(2), row_y)
local btn_eraser = makeIconButton(ICON_ERASER,      colX(3), row_y)
local btn_clear  = makeIconButton(ICON_TRASH,       colX(4), row_y)
local btn_save   = makeIconButton(ICON_STACK_PUSH,  colX(5), row_y)
local btn_load   = makeIconButton(ICON_STACK_POP,   colX(6), row_y)
-- 最後(読込)だけ列の余りぶん幅を広げる。既に置いた位置はcolX()どおりなのでwだけ上書き
pico.set(btn_load, "w", col_last_w + BUTTON_FRAME)

-- ペン/消しゴムのボタンは色そのものを背景にして、今どの色で描けるかを見せる
pico.set(btn_black, "background_color", PEN_BLACK)
pico.set(btn_black, "text_color", 15) -- アイコンの色はtext_colorに従う
pico.set(btn_blue, "background_color", PEN_BLUE)
pico.set(btn_blue, "text_color", 15)
pico.set(btn_eraser, "background_color", ERASER_WHITE)
pico.set(btn_eraser, "text_color", 0)

-- 保存/読込の結果を一言だけ出す小さなラベル。
-- Buttonのw/hは枠を含む全体の大きさなので、中身(btn_size)に枠のぶん(+9)を
-- 足した高さがそのまま見た目の高さ。btn_sizeだけで詰めると枠と文字が重なる
local btn_visual_h = btn_size + BUTTON_FRAME
local status_y = row_y + btn_visual_h + 2
local status = pico.create("Label")
pico.set(status, "x", x + margin)
pico.set(status, "y", status_y)
pico.set(status, "font_size", 0) -- Small16px
pico.set(status, "text", "")

-- キャンバス本体: 残りの高さいっぱいに広げる。生成直後は100×100固定なので
-- w/hをここで明示的に設定し直す(この時点ではまだ何も描いていないので、
-- リサイズで白紙に戻っても実害は無い)
local canvas_y = status_y + 18
local canvas_h = h - (canvas_y - y) - margin

-- CanvasRaster自体はborder_colorを持たない(枠を描く機能が無い)ので、
-- キャンバスの背景が白紙だと範囲が見えなくなる。1px外側を囲む輪郭だけの
-- "Rect"を境界線として使う。
--
-- 【重要】このRectは必ずCanvasRasterより先に作ること。WidgetFunctions::HitTest()は
-- widgetsを「後から作った順(末尾から)」に判定して最初に当たったものを返す
-- (pico.add_childの重なり順の説明と同じ理屈。docs/design/lua.md「実装中に見つけて直した
-- 既存のバグ2件」参照)。このRectはCanvasRasterを1px外側から囲む(=CanvasRasterの
-- 当たり判定を完全に包含する)ため、後から作るとRectが常にCanvasRasterより先に
-- ヒットしてしまい、キャンバス上のタップが一切CanvasRasterへ届かなくなる
-- (実際にこれでフリーハンド描画が完全に効かなくなるバグを踏んだ)。
-- 枠線のピクセル自体はCanvasRasterの外側1pxにしかないので、描画順(先に作る=下に
-- 描かれる)を変えても見た目には重ならず影響しない。
local canvas_border = pico.create("Rect")
pico.set(canvas_border, "x", x + margin - 1)
pico.set(canvas_border, "y", canvas_y - 1)
pico.set(canvas_border, "w", (w - margin * 2) + 2)
pico.set(canvas_border, "h", canvas_h + 2)
pico.set(canvas_border, "filled", false)
pico.set(canvas_border, "thickness", 1)
pico.set(canvas_border, "color", 8) -- PICO_DARKGREY

local canvas = pico.create("CanvasRaster")
pico.set(canvas, "x", x + margin)
pico.set(canvas, "y", canvas_y)
pico.set(canvas, "w", w - margin * 2)
pico.set(canvas, "h", canvas_h)
pico.set(canvas, "canvas_mode", 0) -- Line(フリーハンド)

local pen_buttons = { [btn_black] = true, [btn_blue] = true, [btn_eraser] = true }

local function selectPen(selected_id, color, radius)
    pico.set(canvas, "color", color)
    pico.set(canvas, "brush_radius", radius)
    for pid in pairs(pen_buttons) do
        pico.set(pid, "border_color", BORDER_NORMAL)
    end
    pico.set(selected_id, "border_color", BORDER_SELECTED)
end

pico.on(btn_black, "press_start", function() selectPen(btn_black, PEN_BLACK, PEN_RADIUS) end)
pico.on(btn_blue, "press_start", function() selectPen(btn_blue, PEN_BLUE, PEN_RADIUS) end)
pico.on(btn_eraser, "press_start", function() selectPen(btn_eraser, ERASER_WHITE, ERASER_RADIUS) end)

pico.on(btn_clear, "press_start", function()
    pico.canvas_clear(canvas)
    pico.set(status, "text", "")
end)

pico.on(btn_save, "press_start", function()
    if pico.canvas_save(canvas, SAVE_PATH) then
        pico.set(status, "text", pico.tr("保存しました"))
    else
        pico.set(status, "text", pico.tr("保存に失敗しました(SD未挿入?)"))
    end
end)

pico.on(btn_load, "press_start", function()
    if pico.canvas_load(canvas, SAVE_PATH) then
        pico.set(status, "text", pico.tr("読み込みました"))
    else
        pico.set(status, "text", pico.tr("読み込みに失敗しました(未保存?)"))
    end
end)

pico.on(btn_back, "press_start", function()
    pico.pop()
end)

-- 起動直後は黒ペンを選択状態にしておく
selectPen(btn_black, PEN_BLACK, PEN_RADIUS)
