-- ゾンビTD: 効果音とジングル。
-- 効果音はチャンネル2で、1フレームに1つ・優先度の高いものだけ鳴らす(ブロック崩しと同じ。大勢が同時に
-- 叩いたり撃ったりするので、全部鳴らすと命令の列(32件)が溢れる)。ジングルは短いMMLを曲として鳴らす(チャンネル1)。
local M = {}

M.on = true
local pri, freq, ms, wave = 0, 0, 0, nil
local OPTS = { wave = "pulse25", volume = 9, envelope = -3 }   -- sound_play に渡す表(使い回す)

-- 鳴らしたい音を出す(このフレームで一番優先度の高いものだけが、flush で鳴る)
function M.play(p, f, t, w)
    if M.on and p > pri then pri, freq, ms, wave = p, f, t, w end
end

-- 毎フレームの最後に1回呼ぶ
function M.flush()
    if pri > 0 then
        OPTS.wave = wave or "pulse25"
        pico.sound_play(2, freq, ms, OPTS)
        pri = 0
    end
end

function M.jingle(mml)
    if M.on then pico.music_play_text("#tempo 180\nA @pulse25 v10 q7 o5 l16 " .. mml) end
end

-- 決まった音(優先度・高さ・長さ・波形)
function M.arrow() M.play(1, 1600, 25, "noise") end          -- 矢を射る
function M.hit() M.play(2, 260, 40, "noise") end             -- 叩く
function M.kill() M.play(3, 196, 70, "pulse25") end          -- ゾンビが倒れる
function M.base() M.play(4, 98, 80, "pulse50") end            -- ベースが叩かれる
function M.built() M.play(5, 880, 90, "pulse50") end         -- 建設・強化が終わった
function M.coin() M.play(6, 1320, 50, "pulse12") end         -- 雇う・建てる・強化・売る
function M.lost() M.play(7, 147, 220, "triangle") end        -- 兵士が倒れる・建物が壊れる

function M.wave_start() M.jingle("c e g > c4") end
function M.wave_clear() M.jingle("g > c e g4 e g2") end
function M.game_over() M.jingle("o4 g f e d c4 < g2") end

return M
