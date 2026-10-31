-- SpotifyのWeb APIとの通信: トークンの管理と要求。画面のことは知らない。
--
-- 最初のトークンは本体では取れない(OAuthの戻り先がHTTPSか127.0.0.1に限られる)ので、
-- PCで script/spotify_auth.py(picoos spotify-auth)を動かして、このアプリのフォルダへ
-- spotify_auth.json を置いてもらう。読んだら暗号化して store.json へ移し、平文のファイルは消す。
local A = {}

-- 向き先はアプリのフォルダの settings.cfg の api / token-url で差し替えられる(偽物のサーバで試すとき)
A.API = pico.settings_get("api", "https://api.spotify.com/v1")
A.TOKEN_URL = pico.settings_get("token-url", "https://accounts.spotify.com/api/token")
A.AUTH_FILE = "spotify_auth.json"
A.auth = nil        -- { client_id, refresh_token, access_token, expires_at }
A.revoked = false   -- refresh token が使えなくなった(ログインし直しが要る)

local refreshing = false
local waiting = {}

-- 時計が合っているか(合っていないとTLSが通らず、トークンの期限も分からない)
function A.clock_ok() return pico.time() > 1700000000 end

local function save()
    return pico.store_save({ auth = A.auth }, { encrypt = true })
end

-- PCの spotify_auth.json があれば取り込む。無ければ保存済みのものを読む。
-- 戻り値: ログイン済みか, 知らせる文(無ければnil)
function A.load()
    local path = pico.path_join(pico.app_dir(), A.AUTH_FILE)
    local text = pico.sd_read(path)
    if text then
        -- トークンは255バイトを超える(json_pick は文字列を255バイトで切る)ので json_decode で読む
        local r = pico.json_decode(text)
        if not (type(r) == "table" and type(r.client_id) == "string" and type(r.refresh_token) == "string") then
            return false, pico.tr("%s を読めません。作り直してください", A.AUTH_FILE)
        end
        A.auth = { client_id = r.client_id, refresh_token = r.refresh_token,
                   access_token = type(r.access_token) == "string" and r.access_token or "",
                   expires_at = math.tointeger(r.expires_at) or 0 }
        A.revoked = false
        if not save() then return true, pico.tr("ログイン情報を保存できません(SDを確かめてください)") end
        pico.sd_remove(path)   -- 平文の鍵をSDに残さない
        return true, pico.tr("ログイン情報を取り込みました")
    end
    local st = pico.store_load()
    if type(st) == "table" and type(st.auth) == "table" and st.auth.refresh_token then
        A.auth = st.auth
        return true
    end
    A.auth = nil
    return false
end

function A.logout()
    A.auth = nil
    A.revoked = false
    pico.store_save({}, { encrypt = true })
end

local function token_ok()
    return A.auth ~= nil and (A.auth.access_token or "") ~= ""
        and pico.time() < (A.auth.expires_at or 0) - 60
end

local function finish(ok, why)
    refreshing = false
    local list = waiting
    waiting = {}
    for _, f in ipairs(list) do f(ok, why) end
end

-- アクセストークンを取り直す。fn(ok, why)。同時に頼まれたら1回の取り直しを待ち合わせる
function A.refresh(fn)
    if not A.auth then return fn(false, pico.tr("ログインしていません")) end
    waiting[#waiting + 1] = fn
    if refreshing then return end
    refreshing = true
    local body = pico.form_encode({ grant_type = "refresh_token", refresh_token = A.auth.refresh_token,
                                   client_id = A.auth.client_id })
    local id = pico.http_request("POST", A.TOKEN_URL, body, "application/x-www-form-urlencoded",
        function(ok, status, text, err)
            if not ok then return finish(false, pico.tr("トークンを取れません: ") .. tostring(err)) end
            -- アクセストークンは300文字ほどあり json_pick(255バイトまで)では切れるので json_decode で読む
            local r = text and pico.json_decode(text)
            if type(r) ~= "table" then r = {} end
            if status == 200 and type(r.access_token) == "string" and A.auth then
                A.auth.access_token = r.access_token
                A.auth.expires_at = pico.time() + (math.tointeger(r.expires_in) or 3600)
                -- PKCEのrefresh tokenは使うたびに新しいものが返ることがある。返ったら保存し直す
                if type(r.refresh_token) == "string" then A.auth.refresh_token = r.refresh_token end
                save()
                return finish(true)
            end
            if r.error == "invalid_grant" or r.error == "invalid_client" then
                A.revoked = true
                return finish(false, pico.tr("ログインし直してください(%s)", tostring(r.error_description or r.error)))
            end
            finish(false, pico.tr("トークンを取れません(HTTP %s)", tostring(status)))
        end, { keep_alive = true })
    if not id then finish(false, pico.tr("通信が混んでいます")) end
end

-- APIを呼ぶ。fn(ok, status, body, err, info)。
-- 401(期限切れ)なら1回だけトークンを取り直して送り直す。json は送る本文(JSONの文字列)か nil
function A.call(method, path, json, fn, opts)
    if not A.auth then return fn(false, 0, nil, pico.tr("ログインしていません"), {}) end
    local function send(retried)
        local id = pico.http_request(method, A.API .. path, json, json and "application/json" or nil,
            function(ok, status, body, err, _, info)
                if ok and status == 401 and not retried and A.auth then
                    A.auth.access_token = ""
                    return A.refresh(function(rok, why)
                        if rok then send(true) else fn(false, 401, nil, why, {}) end
                    end)
                end
                fn(ok, status, body, err, info or {})
            end, { keep_alive = true, save_to = opts and opts.save_to,
                   headers = { Authorization = "Bearer " .. (A.auth.access_token or "") } })
        if not id then fn(false, 0, nil, pico.tr("通信が混んでいます"), {}) end
    end
    if token_ok() then return send(false) end
    A.refresh(function(ok, why)
        if ok then send(false) else fn(false, 0, nil, why, {}) end
    end)
end

-- 画像等をSDへ取ってくる(トークンは付けない)。fn(ok, why)
function A.download(url, path, fn)
    local id = pico.http_request("GET", url, nil, nil, function(ok, status, _, err, _, info)
        fn(ok and status == 200 and info ~= nil and info.saved ~= nil, err or ("HTTP " .. tostring(status)))
    end, { keep_alive = true, save_to = path })
    if not id then fn(false, pico.tr("通信が混んでいます")) end
end

-- 失敗の応答から利用者向けの理由を作る(Spotifyは {"error":{"status":..,"message":..,"reason":..}})
function A.error_text(status, body)
    local r = body and pico.json_pick(body, { "error.message", "error.reason" }) or {}
    local msg = r["error.message"]
    if status == 404 then return pico.tr("再生中の端末がありません。Spotifyで再生するか「端末」で選んでください") end
    if status == 403 then
        if r["error.reason"] == "PREMIUM_REQUIRED" then return pico.tr("操作にはSpotify Premiumが必要です") end
        return pico.tr("この操作はできません") .. (msg and ("(" .. msg .. ")") or "")
    end
    if status == 429 then return pico.tr("Spotifyが混んでいます。少し待ちます") end
    return pico.tr("エラー(HTTP %s)", tostring(status)) .. (msg and (": " .. msg) or "")
end

return A
