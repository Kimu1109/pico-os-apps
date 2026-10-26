-- ブロック崩しのステージ定義と自動プレイの狙い。ステージの生成ロジックが大きいので
-- 本体(main.lua)と分けてある。LuaSceneが本体(main.lua)より
-- 先にこのファイルを読み込み・実行し(同じディレクトリの"lib.lua"を自動で探す)、
-- 結果はグローバル変数STAGESとして本体から見える(LuaScene.hppのクラスコメント参照)。
-- 以前はmain.lua自身がpico.sd_read()+Luaのload()+pcall()で実行時にこのファイルを
-- コンパイルしていたが、実機でコア0のスタックオーバーフローを起こしコア1(音声専用)の
-- スタックを巻き込む事故につながったため、この形へ改めた。
--
-- 「形(shape: どのマスにブロックを置くか)」「速度tier(tier: 何色/何速で置くか)」
-- 「壁(wall: そのうちどれを壊せなくするか)」の3つを独立した関数として組み合わせる
-- 設計にしてある。以前はshape/tier/wallが1つの関数に混ざっており、壁を「壊せる
-- ブロックへ一定確率で上書きする」形で足していたため、運が悪いと壊せるブロックの
-- 四方をすべて壁で囲んでしまい、そのブロックに二度と当たれず詰む(クリア不能になる)
-- 事故が起きた。3つに分けたことで壁の形を意図的にデザインできるようになり、
-- 加えて末尾のensureSolvable()が「壊せるブロックがパドル側の開放空間へ本当に
-- 届くか」を毎ステージ機械的に検証するので、デザインを間違えても詰みステージは
-- 出荷されない(万一届かないブロックがあれば、そのマスだけ自動的に空へ戻す)。

local COLS = 8
local WALL = -1 -- main.lua側のWALL_TIERと値を一致させること

-- 速度tierのパターン。1が最速(赤)、6が最遅(青)。
-- tierTop:  上段ほど速い(元祖ブロック崩しの定番配置。序盤はこれで様子を掴んでもらう)
-- tierBottom: 下段(パドルに近い)ほど速い。当てた瞬間ボールが速くなるので、
--   反応時間が一番短いタイミングで一番速くなる=同じ壁配置でも体感難易度が上がる。
--   後半ステージほどこちらを多く使う。
-- tierEdges: 上下の端が速く、中段が遅い。中央に固まりがちな詰まった形状に
--   メリハリを付けるための3つ目のバリエーション。
local function tierTop(r, rows) return ((r - 1) % 6) + 1 end
local function tierBottom(r, rows) return ((rows - r) % 6) + 1 end
local function tierEdges(r, rows)
    local mid = (rows + 1) / 2
    local maxd = math.floor((rows - 1) / 2 + 0.5)
    local d = math.floor(math.abs(r - mid) + 0.5)
    return ((maxd - d) % 6) + 1
end

-- 形(shape)。(r, c, rows) -> そのマスにブロックを置くかどうか
local function shapeFull(r, c, rows) return true end

local function shapeChecker(odd)
    local m = odd and 1 or 0
    return function(r, c, rows) return (r + c) % 2 == m end
end

local function shapeBorder(r, c, rows)
    return r == 1 or r == rows or c == 1 or c == COLS
end

local function shapeStripes(gap)
    return function(r, c, rows) return c % gap ~= 0 end
end

local function shapePyramid(r, c, rows)
    local half = (COLS - r) / 2
    return c > half and c <= COLS - half
end

local function shapeInvPyramid(r, c, rows)
    local half = (r - 1) / 2
    return c > half and c <= COLS - half
end

local function shapeColumns2(r, c, rows)
    return c <= 3 or c >= COLS - 2
end

local function shapeCross(r, c, rows)
    local midr, midc = math.ceil(rows / 2), math.ceil(COLS / 2)
    return c == midc or (r >= midr - 1 and r <= midr + 1)
end

local function shapeDiamond(r, c, rows)
    local cy, cx = (rows + 1) / 2, (COLS + 1) / 2
    local rad = math.min(cx, cy)
    local d = math.abs(r - cy) + math.abs(c - cx) * (cy / cx)
    return d <= rad
end

local function shapeRings(r, c, rows)
    local cy, cx = (rows + 1) / 2, (COLS + 1) / 2
    local d = math.floor(math.max(math.abs(r - cy), math.abs(c - cx)))
    return d % 2 == 0
end

-- 一定間隔で1マスだけ穴を開ける「窓」。以前のrandomHoles(乱数で穴あけ)の
-- 置き換え。乱数を使わないので見た目が整い、壁の安全性の議論からも独立する
-- (これは「壁」ではなく単なる空きマスなので、そもそも詰みの原因にならない)
local function shapeWindows(holeEvery)
    return function(r, c, rows) return not (r % holeEvery == 0 and c % holeEvery == 0) end
end

-- 壁(wall)。(r, c, rows) -> そのマス(shapeが立っている前提)を壊せなくするか
--
-- wallPillars: 指定した列をまるごと壁にする「柱」。列は常に一番下の行まで
-- 壁で埋まるが、挟まれた列(柱にしていない列)は自分の列の中で下へ辿れば
-- 必ずパドル側の開放空間へ抜けられるので、他の列を壁にしても詰まない。
local function wallPillars(cols)
    local set = {}
    for _, c in ipairs(cols) do set[c] = true end
    return function(r, c, rows) return set[c] == true end
end

-- wallFrameGate: 外枠(上端・左端・右端)を壁にし、下端だけは開けておく「門」。
-- 内側(枠の内部)は壁にしないので、下端の開口部から入って上へ辿れば
-- 必ず内側の壊せるブロックへ届く。
local function wallFrameGate()
    return function(r, c, rows) return (r == 1 or c == 1 or c == COLS) and r ~= rows end
end

-- wallDiagonal: 斜めの帯を壁にする。period(周期)を3以上にしてあるのは、
-- 隣接マスを壁で埋め尽くさないため(壊せるブロックの上下左右のどこかは
-- 必ず空くように間隔を空けてある)。
local function wallDiagonal(period, phase)
    return function(r, c, rows) return (r + c + phase) % period == 0 end
end

-- 詰み防止の安全網。パドル側に開放されている最下段(rows行目)を起点に、
-- 壁(WALL)だけを障害物として4方向へ塗りつぶす(壊せるブロックはいずれ
-- 壊されて空になるので、ここでは障害物として扱わない)。塗りつぶしが
-- 届かなかった壊せるブロックが残っていたら、そのマスを空(0)へ戻して
-- ステージから除外する——「絶対にクリア不能なブロックを残さない」ことを
-- 幾何学デザインの正しさに頼らず機械的に保証するための最終防衛ライン。
local function ensureSolvable(rows, grid)
    local visited = {}
    for r = 1, rows do visited[r] = {} end
    local queue, qh, qt = {}, 1, 0
    local function push(r, c)
        if r < 1 or r > rows or c < 1 or c > COLS then return end
        if visited[r][c] or grid[r][c] == WALL then return end
        visited[r][c] = true
        qt = qt + 1
        queue[qt] = { r, c }
    end
    for c = 1, COLS do push(rows, c) end
    while qh <= qt do
        local r, c = queue[qh][1], queue[qh][2]
        qh = qh + 1
        push(r - 1, c); push(r + 1, c); push(r, c - 1); push(r, c + 1)
    end
    for r = 1, rows do
        for c = 1, COLS do
            if grid[r][c] > 0 and not visited[r][c] then
                grid[r][c] = 0
            end
        end
    end
end

-- shape/tier/wallの3つを合成して実際のマス目(grid)を確定させ、
-- ensureSolvable()を必ず通してから返す
local function stage(rows, shapeFn, tierFn, wallFn)
    tierFn = tierFn or tierTop
    local grid = {}
    for r = 1, rows do
        grid[r] = {}
        for c = 1, COLS do
            if shapeFn(r, c, rows) then
                grid[r][c] = (wallFn and wallFn(r, c, rows)) and WALL or tierFn(r, rows)
            else
                grid[r][c] = 0
            end
        end
    end
    ensureSolvable(rows, grid)
    return { rows = rows, cell = function(r, c) return grid[r][c] end }
end

-- 自動プレイ(バッテリー消費計測等で放置プレイさせるためのもの)の狙い。狙うのは
-- 「パドルへ向かって落ちてくるボールのうち一番下にいるもの」で、無ければ(全ボールが
-- 上向きの間)先頭のボールを追う。完璧な反射は狙わずパドル中央で追尾するだけの単純な
-- 実装(ミスもする=ライフが減りゲームオーバーへ至ることも許容)。
-- ボールは { cx, cy(中心), dx, dy(速度) } を持つスプライト。戻り値は狙うx(無ければfallback)
local function autoTargetX(balls, fallback)
    local best, bestY = nil, -1
    for i = 1, #balls do
        local b = balls[i]
        if b.dy > 0 and b.cy > bestY then best, bestY = b, b.cy end
    end
    if not best and #balls > 0 then best = balls[1] end
    return best and best.cx or fallback
end

-- 序盤(1〜5)は壁なし・上段が速いだけのチュートリアル。6以降は
-- 柱/門/斜め帯の壁を幾何学的に配置しつつ、tierBottom(下段が速い)の
-- 採用比率を上げていくことで、壁の物量に頼らず難易度を積み増す。
-- LuaSceneが本体より先にこのファイルを実行するだけなので、returnではなく
-- グローバル変数への代入で結果を渡す(本体側は`local STAGES = STAGES`で受け取る)
STAGES = {
    autoTargetX = autoTargetX,
    cols = COLS,
    list = {
        stage(3, shapeFull, tierTop),
        stage(4, shapeChecker(false), tierTop),
        stage(4, shapeBorder, tierTop),
        stage(4, shapeStripes(3), tierTop),
        stage(4, shapeFull, tierTop),
        stage(5, shapePyramid, tierTop, wallPillars({ 4 })),
        stage(5, shapeInvPyramid, tierBottom, wallPillars({ 5 })),
        stage(5, shapeColumns2, tierTop, wallPillars({ 1, 8 })),
        stage(5, shapeChecker(true), tierEdges, wallDiagonal(5, 0)),
        stage(5, shapeCross, tierTop, wallPillars({ 4 })),
        stage(6, shapeBorder, tierBottom, wallPillars({ 1, 8 })),
        stage(6, shapeStripes(2), tierTop, wallDiagonal(6, 3)),
        stage(6, shapeDiamond, tierBottom, wallPillars({ 4, 5 })),
        stage(6, shapeWindows(3), tierEdges, wallDiagonal(4, 1)),
        stage(7, shapePyramid, tierBottom, wallPillars({ 3, 6 })),
        stage(7, shapeRings, tierTop, wallDiagonal(3, 0)),
        stage(7, shapeChecker(false), tierBottom, wallPillars({ 2, 4, 6 })),
        stage(7, shapeWindows(2), tierBottom, wallDiagonal(3, 2)),
        stage(8, shapeDiamond, tierBottom, wallPillars({ 2, 4, 5, 7 })),
        stage(8, shapeFull, tierBottom, wallFrameGate()),
    },
}
