-- MQTTリモコン: pico.socket.mqtt のサンプル。MQTTのブローカ(Home Assistant の Mosquitto アドオン等)へ繋ぎ、
-- 照明・コンセント等の機器を点け消しする。状態は購読して即座に反映する(他の場所で切り替えても色が変わる)。
--
-- 機器ごとに「話題」を1つ決め、次の約束で話す(Home Assistant の MQTT スイッチ・Tasmota・ESPHome で作りやすい形):
--   <話題>/state … 機器が今の状態を流す("ON" / "OFF"。retain 推奨。{"state":"ON"} の形(Zigbee2MQTT)も読む)
--   <話題>/set   … このアプリが "ON" / "OFF" を送る(QoS 1)
-- 自分の生死は pico/remote/<クライアントID>/status へ "online"、切れたら遺言で "offline"(どちらも retain)。
--
-- ブローカのURL・認証・機器の一覧は「設定」で変え、store.json へ暗号化して保存する。
-- 切れたら5秒後から繋ぎ直す(続けて失敗すると間隔を倍にして最大60秒)。
local X, Y, W, H = pico.content_rect()

local MAX_DEVICES = 6
local DEFAULT_DEVICES = {
    { pico.tr("居間の照明"), "home/living/light" },
    { pico.tr("寝室の照明"), "home/bedroom/light" },
    { pico.tr("扇風機"), "home/fan" },
    { pico.tr("加湿器"), "home/humidifier" },
}

local function hex(s)
    return (s:gsub(".", function(c) return string.format("%02x", c:byte()) end))
end

local cfg = pico.store_load() or {}
cfg.url = cfg.url or "mqtt://homeassistant.local"
cfg.user = cfg.user or ""
cfg.pass = cfg.pass or ""
cfg.devices = cfg.devices or DEFAULT_DEVICES
cfg.client_id = cfg.client_id or ("pico-remote-" .. hex(pico.random_bytes(3)))

local function save() pico.store_save(cfg, { encrypt = true }) end
local function status_topic() return "pico/remote/" .. cfg.client_id .. "/status" end

local sock = nil            -- 接続のid(繋いでいなければ nil)
local online = false        -- CONNACK を受けた
local conn_text = pico.tr("未接続")
local leaving = false       -- 戻る操作で閉じている(繋ぎ直さない)
local retry_ms, retry_timer = 5000, nil
local state = {}            -- 機器の番号 → "ON" / "OFF" / その他の文字列
local pending = {}          -- 機器の番号 → 送ったが、まだ状態が返ってきていない
local log = {}              -- 最近届いたもの(新しい順に3行)
local canvas

local function redraw() if canvas then pico.invalidate(canvas) end end

-- 届いた中身を "ON" / "OFF" へ揃える(分からなければそのまま返す)
local function normalize(payload)
    local s = payload
    if s:sub(1, 1) == "{" then
        local j = pico.json_decode(s)
        if type(j) == "table" and j.state ~= nil then s = tostring(j.state) end
    end
    local u = s:upper()
    if u == "ON" or u == "1" or u == "TRUE" then return "ON" end
    if u == "OFF" or u == "0" or u == "FALSE" then return "OFF" end
    return s
end

local function add_log(line)
    table.insert(log, 1, line)
    if #log > 3 then log[4] = nil end
end

local connect -- 下で決める

local function schedule_retry()
    if leaving or retry_timer then return end
    conn_text = conn_text .. pico.tr("(%s秒後に再接続)", retry_ms // 1000)
    retry_timer = pico.after(retry_ms, function()
        retry_timer = nil
        connect()
    end)
    retry_ms = math.min(retry_ms * 2, 60000)
end

local function on_event(ev, a, b, c)
    if ev == "connect" then
        online = true
        retry_ms = 5000
        conn_text = pico.tr("接続中: ") .. cfg.url
        for _, d in ipairs(cfg.devices) do pico.socket.subscribe(sock, d[2] .. "/state", 1) end
        pico.socket.publish(sock, status_topic(), "online", { retain = true })
    elseif ev == "message" then
        for i, d in ipairs(cfg.devices) do
            if a == d[2] .. "/state" then
                state[i] = normalize(b)
                pending[i] = nil
            end
        end
        add_log(a .. " = " .. (#b > 24 and (b:sub(1, 24) .. "…") or b))
    elseif ev == "close" then
        sock, online = nil, false
        pending = {}
        if leaving then return end
        conn_text = pico.tr("切断: ") .. (a or pico.tr("ブローカが閉じました"))
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
    if sock then pico.socket.close(sock) end
    local err
    sock, err = pico.socket.mqtt(cfg.url, on_event, {
        client_id = cfg.client_id,
        username = cfg.user ~= "" and cfg.user or nil,
        password = cfg.pass ~= "" and cfg.pass or nil,
        keepalive = 60,
        will = { topic = status_topic(), payload = "offline", retain = true },
    })
    online = false
    if sock then
        conn_text = pico.tr("接続しています…")
    else
        conn_text = pico.tr("繋げません: ") .. tostring(err)
        schedule_retry()
    end
    redraw()
end

-- 機器を点け消しする(今の状態の逆を送る。状態が返ってくるまで「…」)
local function toggle(i)
    local d = cfg.devices[i]
    if not d then return end
    if not online then
        pico.toast(pico.tr("ブローカに繋がっていません"))
        return
    end
    local want = state[i] == "ON" and "OFF" or "ON"
    if pico.socket.publish(sock, d[2] .. "/set", want, { qos = 1 }) then
        pending[i] = true
    end
    redraw()
end

-- ---- 描画 ----
local GREEN, DKGREEN, DGREY, LGREY, RED, WHITE, BLACK, YELLOW = 10, 2, 8, 7, 12, 15, 0, 14
local TOP = Y + 32          -- ボタンの列の下
local STATUS_H = 22
local LOG_H = 3 * 14 + 6
local COLS = 2
local GAP = 6

local function tile_rect(i)
    local rows = math.max(1, (#cfg.devices + COLS - 1) // COLS)
    local area_h = H - 32 - STATUS_H - LOG_H
    local tw = (W - GAP * (COLS + 1)) // COLS
    local th = math.min(64, (area_h - GAP * (rows + 1)) // rows)
    local col = (i - 1) % COLS
    local row = (i - 1) // COLS
    return X + GAP + col * (tw + GAP), TOP + STATUS_H + GAP + row * (th + GAP), tw, th
end

-- 幅に収まらなければ後ろを「…」にして切る(UTF-8の文字単位)
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

local function render()
    -- 接続の状態(丸の色: 緑=繋がっている、黄=繋いでいる、赤=切れている)
    local dot = online and GREEN or (sock and YELLOW or RED)
    pico.fill_circle(X + 10, TOP + 10, 5, dot)
    pico.draw_text(X + 20, TOP + 4, fit(conn_text, W - 24, 0), DGREY, 0)

    for i, d in ipairs(cfg.devices) do
        local x, y, w, h = tile_rect(i)
        local s = state[i]
        local on = s == "ON"
        pico.fill_rect(x, y, w, h, on and DKGREEN or LGREY)
        pico.draw_rect(x, y, w, h, on and BLACK or DGREY)
        pico.draw_text(x + 6, y + 5, fit(d[1], w - 12, 0), on and WHITE or BLACK, 0)
        local label = pending[i] and "…" or (s == nil and pico.tr("不明") or (on and "ON" or (s == "OFF" and "OFF" or s)))
        pico.draw_text(x + 6, y + h - 30, fit(label, w - 12, 1), on and WHITE or (s == nil and DGREY or BLACK), 1)
    end
    if #cfg.devices == 0 then
        pico.draw_text_wrapped(X + 8, TOP + STATUS_H + 8, W - 16, pico.tr("機器がありません。「設定」の「機器の一覧」で足してください"), DGREY, 0)
    end

    local ly = Y + H - LOG_H
    pico.draw_line(X + 4, ly, X + W - 5, ly, LGREY)
    for k, line in ipairs(log) do
        pico.draw_text(X + 6, ly + 4 + (k - 1) * 14, fit(line, W - 12, 0), DGREY, 0)
    end
end

-- ---- 設定 ----
local function devices_text()
    local lines = {}
    for _, d in ipairs(cfg.devices) do lines[#lines + 1] = d[1] .. "=" .. d[2] end
    return table.concat(lines, "\n")
end

-- "名前=話題" を1行ずつ読む(話題に + # は使えない。最大 MAX_DEVICES 個)
local function parse_devices(text)
    local out = {}
    for line in (text .. "\n"):gmatch("(.-)\r?\n") do
        local name, topic = line:match("^%s*(.-)%s*=%s*(.-)%s*$")
        if name and name ~= "" and topic ~= "" and not topic:find("[+#]") and #out < MAX_DEVICES then
            out[#out + 1] = { name, topic }
        end
    end
    return out
end

local function apply(changed_conn)
    save()
    state, pending = {}, {}
    if changed_conn or online then
        retry_ms = 5000
        if retry_timer then pico.cancel(retry_timer); retry_timer = nil end
        connect()
    end
    redraw()
end

local function settings()
    local items = { pico.tr("ブローカのURL"), pico.tr("ユーザー名"), pico.tr("パスワード"), pico.tr("機器の一覧(名前=話題)") }
    local dlg = pico.show_choice(pico.tr("設定"), items)
    pico.on(dlg, "closed", function(_, ok, idx)
        if not ok then return end
        -- ダイアログからダイアログへは1フレーム空ける
        pico.after(50, function()
            if idx == 3 then
                local d = pico.show_input(pico.tr("1行に1台、名前=話題(最大%s台)", MAX_DEVICES), devices_text(), false)
                pico.on(d, "closed", function(id, ok2)
                    if not ok2 then return end
                    cfg.devices = parse_devices(pico.get(id, "text"))
                    apply(false)
                end)
                return
            end
            local keys = { "url", "user", "pass" }
            local key = keys[idx + 1]
            local d = pico.show_input(items[idx + 1], cfg[key])
            pico.on(d, "closed", function(id, ok2)
                if not ok2 then return end
                local v = pico.get(id, "text")
                if key == "url" and not (v:match("^mqtts?://.+")) then
                    pico.show_message(pico.tr("URLは mqtt://ホスト[:ポート] か mqtts://… の形で入れてください"), "", "OK")
                    return
                end
                cfg[key] = v
                apply(true)
            end)
        end)
    end)
end

local function back()
    leaving = true
    if retry_timer then pico.cancel(retry_timer) end
    if sock then
        -- 自分から閉じると遺言は流れないので、先に offline を置いていく
        if online then pico.socket.publish(sock, status_topic(), "offline", { retain = true }) end
        pico.socket.close(sock)
    end
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
    for i = 1, #cfg.devices do
        local x, y, w, h = tile_rect(i)
        if tx >= x and tx < x + w and ty >= y and ty < y + h then
            toggle(i)
            return
        end
    end
end)

pico.on_back(back)
save()      -- 初回はクライアントIDを覚える
connect()
