-- HAパネル: pico.socket.websocket のサンプル。Home Assistant の WebSocket API へ繋ぎ、
-- 選んだエンティティ(最大6つ)の状態を即座に映し、タップで点け消しする。
--
-- 流れ(https://developers.home-assistant.io/docs/api/websocket/):
--   開く → {"type":"auth_required"} → こちらから {"type":"auth","access_token":長期アクセストークン}
--   → {"type":"auth_ok"} → {"id":1,"type":"subscribe_entities","entity_ids":[...]}
--   → 最初の event に今の状態("a")、以後は変わった分だけ("c" の "+")が届く
--   タップ → {"id":n,"type":"call_service","domain":"homeassistant","service":"toggle","target":{"entity_id":...}}
-- get_states(全部の状態)は大きすぎる(数百KB)ので使わない。subscribe_entities は頼んだものだけ届く。
--
-- 点け消しできるのは light / switch / fan / input_boolean / automation / cover。それ以外(sensor 等)は表示だけ。
-- トークンは Home Assistant の「プロフィール → セキュリティ → 長期アクセストークン」で作り、「設定」で入れる。
-- 設定は store.json へ暗号化して保存する。切れたら5秒後から繋ぎ直す(最大60秒)。トークンが違うときは繋ぎ直さない。
local X, Y, W, H = pico.content_rect()

local MAX_ENTITIES = 6
local TOGGLE = { light = true, switch = true, fan = true, input_boolean = true, automation = true, cover = true }

local cfg = pico.store_load() or {}
cfg.url = cfg.url or "ws://homeassistant.local:8123/api/websocket"
cfg.token = cfg.token or ""
cfg.entities = cfg.entities or {
    { "", "light.living_room" },
    { "", "switch.fan" },
    { "", "input_boolean.away_mode" },
    { "", "sensor.living_room_temperature" },
}
local function save() pico.store_save(cfg, { encrypt = true }) end

local ws = nil              -- 接続のid
local authed = false        -- auth_ok を受けた
local bad_auth = false      -- トークンが違う(直すまで繋ぎ直さない)
local conn_text = pico.tr("未接続")
local leaving = false
local retry_ms, retry_timer = 5000, nil
local next_id, sub_id = 1, nil
local ent = {}              -- 番号 → { state = "on", name = 表示名, unit = 単位 }
local pending = {}          -- 番号 → 送った call_service の id(結果か状態が届くまで「…」)
local log = {}
local canvas

local function redraw() if canvas then pico.invalidate(canvas) end end
local function add_log(line)
    table.insert(log, 1, line)
    if #log > 3 then log[4] = nil end
end

local function reset_entities()
    ent, pending = {}, {}
    for i = 1, #cfg.entities do ent[i] = {} end
end
reset_entities()

local function send(msg)
    msg.id = next_id
    next_id = next_id + 1
    if ws and pico.socket.send(ws, pico.json_encode(msg)) then return msg.id end
    return nil
end

-- 届いた状態・属性を、そのエンティティの欄へ写す
local function apply(eid, s, attrs)
    for i, e in ipairs(cfg.entities) do
        if e[2] == eid then
            if s ~= nil then
                ent[i].state = tostring(s)
                pending[i] = nil
            end
            if type(attrs) == "table" then
                if attrs.friendly_name then ent[i].name = tostring(attrs.friendly_name) end
                if attrs.unit_of_measurement then ent[i].unit = tostring(attrs.unit_of_measurement) end
            end
        end
    end
end

local connect -- 下で決める

local function schedule_retry()
    if leaving or bad_auth or retry_timer then return end
    conn_text = conn_text .. pico.tr("(%s秒後に再接続)", retry_ms // 1000)
    retry_timer = pico.after(retry_ms, function()
        retry_timer = nil
        connect()
    end)
    retry_ms = math.min(retry_ms * 2, 60000)
end

local function on_message(m)
    if m.type == "auth_required" then
        if cfg.token == "" then
            bad_auth = true
            conn_text = pico.tr("トークンが未設定です(「設定」で入れてください)")
            pico.socket.close(ws)
            return
        end
        conn_text = pico.tr("認証しています…")
        pico.socket.send(ws, pico.json_encode({ type = "auth", access_token = cfg.token }))
    elseif m.type == "auth_ok" then
        authed = true
        retry_ms = 5000
        conn_text = pico.tr("接続中: HA ") .. tostring(m.ha_version or "")
        local ids = {}
        for i, e in ipairs(cfg.entities) do ids[i] = e[2] end
        sub_id = send({ type = "subscribe_entities", entity_ids = ids })
    elseif m.type == "auth_invalid" then
        bad_auth = true
        conn_text = pico.tr("トークンが違います: ") .. tostring(m.message or "")
        pico.socket.close(ws)
    elseif m.type == "event" and m.id == sub_id and type(m.event) == "table" then
        local ev = m.event
        if type(ev.a) == "table" then        -- 今の状態(最初に全部)
            for eid, st in pairs(ev.a) do apply(eid, st.s, st.a) end
        end
        if type(ev.c) == "table" then        -- 変わった分
            for eid, ch in pairs(ev.c) do
                local plus = ch["+"]
                if type(plus) == "table" then
                    apply(eid, plus.s, plus.a)
                    if plus.s ~= nil then add_log(eid .. " → " .. tostring(plus.s)) end
                end
            end
        end
        if type(ev.r) == "table" then        -- 消えた
            for _, eid in ipairs(ev.r) do apply(eid, pico.tr("削除")) end
        end
    elseif m.type == "result" then
        for i, id in pairs(pending) do
            if id == m.id and not m.success then pending[i] = nil end
        end
        if not m.success then
            local e = type(m.error) == "table" and m.error or {}
            add_log(pico.tr("失敗: ") .. tostring(e.message or e.code or "?"))
        end
    end
end

local function on_event(ev, a, b, c)
    if ev == "open" then
        conn_text = pico.tr("開きました。認証を待っています…")
    elseif ev == "message" then
        local m = pico.json_decode(a)
        if type(m) == "table" then on_message(m) end
    elseif ev == "close" then
        ws, authed, sub_id = nil, false, nil
        pending = {}
        if leaving then return end
        if not bad_auth then
            conn_text = pico.tr("切断: ") .. (a or pico.tr("サーバが閉じました(%s)", tostring(b)))
        end
        schedule_retry()
    end
    redraw()
end

connect = function()
    if not pico.socket then
        conn_text = pico.tr("このファームは pico.socket に対応していません")
        redraw()
        return
    end
    if ws then pico.socket.close(ws) end
    bad_auth, authed, next_id, sub_id = false, false, 1, nil
    local err
    -- 状態の最初の一括(属性つき)は1エンティティ数百B。6つでも余裕を持って16KiB
    ws, err = pico.socket.websocket(cfg.url, on_event, { max_message = 16384 })
    if ws then
        conn_text = pico.tr("接続しています…")
    else
        conn_text = pico.tr("繋げません: ") .. tostring(err)
        schedule_retry()
    end
    redraw()
end

local function toggle(i)
    local e = cfg.entities[i]
    if not e then return end
    local domain = e[2]:match("^([%w_]+)%.")
    if not TOGGLE[domain] then return end      -- 表示だけのもの
    if not authed then
        pico.toast(pico.tr("Home Assistant に繋がっていません"))
        return
    end
    local id = send({ type = "call_service", domain = "homeassistant", service = "toggle",
                      target = { entity_id = e[2] } })
    if id then pending[i] = id end
    redraw()
end

-- ---- 描画 ----
local CYAN, NAVY, DGREY, LGREY, RED, WHITE, BLACK, YELLOW, GREEN = 11, 1, 8, 7, 12, 15, 0, 14, 10
local TOP = Y + 32
local STATUS_H = 22
local LOG_H = 3 * 14 + 6
local COLS, GAP = 2, 6

local function tile_rect(i)
    local rows = math.max(1, (#cfg.entities + COLS - 1) // COLS)
    local area_h = H - 32 - STATUS_H - LOG_H
    local tw = (W - GAP * (COLS + 1)) // COLS
    local th = math.min(64, (area_h - GAP * (rows + 1)) // rows)
    return X + GAP + ((i - 1) % COLS) * (tw + GAP), TOP + STATUS_H + GAP + ((i - 1) // COLS) * (th + GAP), tw, th
end

local function fit(text, w, size)
    if pico.text_width(text, size) <= w then return text end
    local n = utf8.len(text) or #text
    while n > 0 do
        local cut = text:sub(1, (utf8.offset(text, n + 1) or (#text + 1)) - 1) .. "…"
        if pico.text_width(cut, size) <= w then return cut end
        n = n - 1
    end
    return "…"
end

local function label_of(i)
    local s = ent[i].state
    if pending[i] then return "…" end
    if s == nil then return pico.tr("不明") end
    if s == "on" then return "ON" end
    if s == "off" then return "OFF" end
    if s == "open" then return pico.tr("開") end
    if s == "closed" then return pico.tr("閉") end
    if s == "unavailable" then return pico.tr("使えない") end
    return s .. (ent[i].unit and (" " .. ent[i].unit) or "")
end

local function render()
    local dot = authed and GREEN or (ws and YELLOW or RED)
    pico.fill_circle(X + 10, TOP + 10, 5, dot)
    pico.draw_text(X + 20, TOP + 4, fit(conn_text, W - 24, 0), DGREY, 0)

    for i, e in ipairs(cfg.entities) do
        local x, y, w, h = tile_rect(i)
        local s = ent[i].state
        local on = s == "on" or s == "open"
        local can = TOGGLE[e[2]:match("^([%w_]+)%.") or ""]
        local bg = on and NAVY or (can and LGREY or WHITE)
        pico.fill_rect(x, y, w, h, bg)
        pico.draw_rect(x, y, w, h, on and BLACK or DGREY)
        local name = e[1] ~= "" and e[1] or ent[i].name or e[2]
        pico.draw_text(x + 6, y + 5, fit(name, w - 12, 0), on and WHITE or BLACK, 0)
        pico.draw_text(x + 6, y + h - 30, fit(label_of(i), w - 12, 1),
                       on and CYAN or (s == nil and DGREY or BLACK), 1)
    end
    if #cfg.entities == 0 then
        pico.draw_text_wrapped(X + 8, TOP + STATUS_H + 8, W - 16,
                               pico.tr("エンティティがありません。「設定」の「エンティティ」で足してください"), DGREY, 0)
    end

    local ly = Y + H - LOG_H
    pico.draw_line(X + 4, ly, X + W - 5, ly, LGREY)
    for k, line in ipairs(log) do
        pico.draw_text(X + 6, ly + 4 + (k - 1) * 14, fit(line, W - 12, 0), DGREY, 0)
    end
end

-- ---- 設定 ----
local function entities_text()
    local lines = {}
    for _, e in ipairs(cfg.entities) do lines[#lines + 1] = (e[1] ~= "" and (e[1] .. "=") or "") .. e[2] end
    return table.concat(lines, "\n")
end

-- 1行に1つ、"entity_id" か "名前=entity_id"(最大 MAX_ENTITIES 個)
local function parse_entities(text)
    local out = {}
    for line in (text .. "\n"):gmatch("(.-)\r?\n") do
        local name, eid = line:match("^%s*(.-)%s*=%s*(.-)%s*$")
        if not name then name, eid = "", line:match("^%s*(.-)%s*$") end
        if eid and eid:match("^[%w_]+%.[%w_]+$") and #out < MAX_ENTITIES then
            out[#out + 1] = { name, eid }
        end
    end
    return out
end

local function apply_settings()
    save()
    reset_entities()
    retry_ms = 5000
    if retry_timer then pico.cancel(retry_timer); retry_timer = nil end
    connect()
end

local function settings()
    local items = { pico.tr("サーバのURL"), pico.tr("長期アクセストークン"), pico.tr("エンティティ(1行に1つ)") }
    local dlg = pico.show_choice(pico.tr("設定"), items)
    pico.on(dlg, "closed", function(_, ok, idx)
        if not ok then return end
        pico.after(50, function()   -- ダイアログからダイアログへは1フレーム空ける
            if idx == 0 then
                local d = pico.show_input(pico.tr("URL(ws://ホスト:8123/api/websocket)"), cfg.url)
                pico.on(d, "closed", function(id, ok2)
                    if not ok2 then return end
                    local v = pico.get(id, "text")
                    if not v:match("^wss?://.+") then
                        pico.show_message(pico.tr("URLは ws://… か wss://… の形で入れてください"), "", "OK")
                        return
                    end
                    cfg.url = v
                    apply_settings()
                end)
            elseif idx == 1 then
                local d = pico.show_input(pico.tr("長期アクセストークン"), cfg.token, false)
                pico.on(d, "closed", function(id, ok2)
                    if not ok2 then return end
                    cfg.token = pico.get(id, "text"):gsub("%s", "")
                    apply_settings()
                end)
            else
                local d = pico.show_input(pico.tr("entity_id か 名前=entity_id(最大%sつ)", MAX_ENTITIES),
                                          entities_text(), false)
                pico.on(d, "closed", function(id, ok2)
                    if not ok2 then return end
                    cfg.entities = parse_entities(pico.get(id, "text"))
                    apply_settings()
                end)
            end
        end)
    end)
end

local function back()
    leaving = true
    if retry_timer then pico.cancel(retry_timer) end
    if ws then pico.socket.close(ws) end
    pico.pop()
end

-- ---- 部品 ----
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

local bw = (W - 4) // 3
button(pico.tr("戻る"), X, bw, back)
button(pico.tr("設定"), X + bw + 2, bw, settings)
button(pico.tr("再接続"), X + (bw + 2) * 2, bw, function()
    retry_ms = 5000
    if retry_timer then pico.cancel(retry_timer); retry_timer = nil end
    connect()
end)

canvas = pico.create("Canvas")
pico.set(canvas, "x", X)
pico.set(canvas, "y", TOP)
pico.set(canvas, "w", W)
pico.set(canvas, "h", H - 32)
pico.on(canvas, "render", render)
pico.on(canvas, "press_end", function()
    local tx, ty = pico.get_touch()
    for i = 1, #cfg.entities do
        local x, y, w, h = tile_rect(i)
        if tx >= x and tx < x + w and ty >= y and ty < y + h then
            toggle(i)
            return
        end
    end
end)

pico.on_back(back)
connect()
