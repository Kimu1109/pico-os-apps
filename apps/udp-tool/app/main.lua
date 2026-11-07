-- UDPツール: pico.socket.udp のサンプル。
--   送受信 … 宛先(ホスト:ポート)へ文字を送り、届いたデータグラムを送り元つきで並べる
--             (ESP32等の機器の確かめ・LANの中の短い命令に)。待ち受けの番号を決めれば、そこへ届くものも受ける
--   Wake on LAN … 登録したPCへマジックパケット(FF×6 + MACアドレス×16 = 102バイト)を送って起こす
--             宛先は既定でブロードキャスト(255.255.255.255:9)。届かなければ 192.168.1.255 のような
--             LANのブロードキャストアドレスや、PCのIPを直接書く
-- 設定は store.json(秘密は無いので暗号化しない)。
local X, Y, W, H = pico.content_rect()

local MAX_LOG = 40

local cfg = pico.store_load() or {}
cfg.target = cfg.target or "192.168.1.50:4210"
cfg.local_port = cfg.local_port or 0
cfg.wol_addr = cfg.wol_addr or "255.255.255.255:9"
cfg.wol = cfg.wol or {}       -- { { 名前, "AA:BB:CC:DD:EE:FF" }, ... }
local function save() pico.store_save(cfg) end

local sock = nil
local bound_port = 0          -- 実際に待っている番号(0 = 空いている番号を使った)
local status = ""
local log = {}                -- { text, color } 新しい順
local canvas

local function redraw() if canvas then pico.invalidate(canvas) end end

local DGREY, LGREY, BLUE, GREEN, RED, BLACK = 8, 7, 9, 2, 12, 0

local function add(text, color)
    table.insert(log, 1, { text, color or BLACK })
    if #log > MAX_LOG then log[#log] = nil end
    redraw()
end

-- "host:port" を分ける(ポートが無い/範囲外なら nil)
local function split_target(s)
    local host, port = s:match("^%s*(.-):(%d+)%s*$")
    port = tonumber(port)
    if not host or host == "" or not port or port < 1 or port > 65535 then return nil end
    return host, port
end

-- 文字として読めるならそのまま、そうでなければ16進で
local function show(data)
    if utf8.len(data) and not data:find("[%z\1-\8\11\12\14-\31\127]") then
        return (data:gsub("\r?\n", "\\n"))
    end
    local hex = data:sub(1, 24):gsub(".", function(c) return string.format("%02X ", c:byte()) end)
    return "[" .. #data .. "B] " .. hex .. (#data > 24 and "…" or "")
end

-- 届いたもの("close" は待ち受けを替えたときの古い方なので何もしない)。
-- 宛先からの返事は送り元を省く(上に出ている)。それ以外は送り元を付ける
local function on_event(ev, data, host, port)
    if ev == "data" then
        local th, tp = split_target(cfg.target)
        local from = (host == th and port == tp) and "" or (host .. ":" .. port .. "  ")
        add("← " .. from .. show(data), GREEN)
    end
end

local function listen()
    if not pico.socket then
        status = pico.tr("このファームは pico.socket に対応していません")
        redraw()
        return
    end
    if sock then pico.socket.close(sock) end
    local err
    sock, err = pico.socket.udp(on_event, cfg.local_port > 0 and { port = cfg.local_port } or nil)
    if sock then
        bound_port = cfg.local_port
        status = bound_port > 0 and pico.tr("待ち受け :%s", bound_port) or pico.tr("待ち受け: 返事だけ受ける")
    else
        status = pico.tr("待ち受けを始められません: ") .. tostring(err)
    end
    redraw()
end

local function send_text(text)
    local host, port = split_target(cfg.target)
    if not host then
        add(pico.tr("宛先が「ホスト:ポート」の形になっていません"), RED)
        return false
    end
    if not sock then listen() end
    if sock and pico.socket.sendto(sock, host, port, text) then
        add("→ " .. show(text), BLUE)
        return true
    end
    add(pico.tr("送れませんでした(%s:%s)", host, port), RED)
    return false
end

-- "AA:BB:CC:DD:EE:FF" / "AA-BB-..." / "AABBCCDDEEFF" → 6バイト(読めなければ nil)
local function parse_mac(s)
    local hex = s:gsub("[:%-%s%.]", "")
    if not hex:match("^%x+$") or #hex ~= 12 then return nil end
    return (hex:gsub("%x%x", function(h) return string.char(tonumber(h, 16)) end))
end

local function magic_packet(mac)
    return string.rep("\255", 6) .. string.rep(mac, 16)
end

local function wake(i)
    local d = cfg.wol[i]
    local mac = d and parse_mac(d[2])
    local host, port = split_target(cfg.wol_addr)
    if not mac or not host then
        add(pico.tr("MACアドレスかWoLの宛先が正しくありません"), RED)
        return false
    end
    if not sock then listen() end
    if sock and pico.socket.sendto(sock, host, port, magic_packet(mac)) then
        add("→ WoL " .. d[1] .. "(" .. d[2] .. ")", BLUE)
        return true
    end
    add(pico.tr("送れませんでした(%s:%s)", host, port), RED)
    return false
end

-- ---- 描画 ----
local TOP = Y + 32
local LINE = 14

local function fit(text, w)
    if pico.text_width(text, 0) <= w then return text end
    local n = utf8.len(text) or #text
    while n > 0 do
        local cut = text:sub(1, (utf8.offset(text, n + 1) or (#text + 1)) - 1) .. "…"
        if pico.text_width(cut, 0) <= w then return cut end
        n = n - 1
    end
    return "…"
end

local function render()
    pico.draw_text(X + 4, TOP + 2, fit(pico.tr("宛先 ") .. cfg.target, W - 8), BLACK, 0)
    pico.draw_text(X + 4, TOP + 2 + LINE, fit(status, W - 8), DGREY, 0)
    local y0 = TOP + 2 + LINE * 2 + 4
    pico.draw_line(X + 4, y0 - 3, X + W - 5, y0 - 3, LGREY)
    if #log == 0 then
        pico.draw_text_wrapped(X + 6, y0 + 4, W - 12,
            pico.tr("「送信」で宛先へ文字を送ります。届いたものはここに並びます。「起動」は Wake on LAN です"), DGREY, 0)
        return
    end
    local rows = (Y + H - y0) // LINE
    for k = 1, math.min(rows, #log) do
        pico.draw_text(X + 4, y0 + (k - 1) * LINE, fit(log[k][1], W - 8), log[k][2], 0)
    end
end

-- ---- 操作 ----
local function ask(title, initial, fn)
    local d = pico.show_input(title, initial)
    pico.on(d, "closed", function(id, ok)
        if ok then fn(pico.get(id, "text")) end
    end)
end

local function settings()
    local items = { pico.tr("宛先(ホスト:ポート)"), pico.tr("待ち受けの番号(0 = 返事だけ)"), pico.tr("WoLの宛先"), pico.tr("WoLの機器(名前=MAC)"), pico.tr("記録を消す") }
    local dlg = pico.show_choice(pico.tr("設定"), items)
    pico.on(dlg, "closed", function(_, ok, idx)
        if not ok then return end
        pico.after(50, function()   -- ダイアログからダイアログへは1フレーム空ける
            if idx == 0 then
                ask(items[1], cfg.target, function(v)
                    if not split_target(v) then
                        pico.show_message(pico.tr("「ホスト:ポート」の形で入れてください(例 192.168.1.50:4210)"), "", "OK")
                        return
                    end
                    cfg.target = v; save(); redraw()
                end)
            elseif idx == 1 then
                ask(items[2], tostring(cfg.local_port), function(v)
                    local p = tonumber(v)
                    if not p or p < 0 or p > 65535 or p % 1 ~= 0 then return end
                    cfg.local_port = p; save(); listen()
                end)
            elseif idx == 2 then
                ask(items[3], cfg.wol_addr, function(v)
                    if not split_target(v) then return end
                    cfg.wol_addr = v; save()
                end)
            elseif idx == 3 then
                local lines = {}
                for _, d in ipairs(cfg.wol) do lines[#lines + 1] = d[1] .. "=" .. d[2] end
                local d = pico.show_input(pico.tr("1行に1台、名前=MACアドレス"), table.concat(lines, "\n"), false)
                pico.on(d, "closed", function(id, ok2)
                    if not ok2 then return end
                    local out = {}
                    for line in (pico.get(id, "text") .. "\n"):gmatch("(.-)\r?\n") do
                        local name, mac = line:match("^%s*(.-)%s*=%s*(.-)%s*$")
                        if name and name ~= "" and parse_mac(mac) then out[#out + 1] = { name, mac } end
                    end
                    cfg.wol = out; save()
                end)
            else
                log = {}
                redraw()
            end
        end)
    end)
end

local function wol_menu()
    if #cfg.wol == 0 then
        pico.show_message(pico.tr("「設定」の「WoLの機器」で、名前=MACアドレス を登録してください"), "", "OK")
        return
    end
    local names = {}
    for i, d in ipairs(cfg.wol) do names[i] = d[1] .. "(" .. d[2] .. ")" end
    local dlg = pico.show_choice(pico.tr("起こすPC"), names)
    pico.on(dlg, "closed", function(_, ok, idx)
        if ok then wake(idx + 1) end
    end)
end

local function back()
    if sock then pico.socket.close(sock) end
    pico.pop()
end

local function button(text, x, w, fn)
    local b = pico.create("Button")
    pico.set(b, "text", text)
    pico.set(b, "x", x)
    pico.set(b, "y", Y)
    pico.set(b, "w", w)
    pico.set(b, "h", 30)
    pico.on(b, "press_end", fn)
    return b
end

local bw = (W - 6) // 4
button(pico.tr("戻る"), X, bw, back)
button(pico.tr("設定"), X + bw + 2, bw, settings)
button(pico.tr("送信"), X + (bw + 2) * 2, bw, function()
    ask(pico.tr("送る文字(%s へ)", cfg.target), cfg.last or "", function(v)
        cfg.last = v; save()
        send_text(v)
    end)
end)
button(pico.tr("起動"), X + (bw + 2) * 3, bw, wol_menu)

canvas = pico.create("Canvas")
pico.set(canvas, "x", X)
pico.set(canvas, "y", TOP)
pico.set(canvas, "w", W)
pico.set(canvas, "h", H - 32)
pico.on(canvas, "render", render)

pico.on_back(back)
listen()
