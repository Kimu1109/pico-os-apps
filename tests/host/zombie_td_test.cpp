// ゾンビTD(apps/zombie-td/app/)の Lua を、pico-os の本物のエンジン(pico.iso の ARENA・流れの場・押し合い・弾)の上で動かす。
//   zombies.lua / soldiers.lua / buildings.lua / waves.lua・save.lua / game.lua 全体の流れ / コントローラーのカーソル
//
// pico-os のホストテスト(script/host_test/CMakeLists.txt の lua-apps グループ)が作って回す。
// 引数は pico-os のルートと、このリポジトリのルート。pico.iso そのもののテストは pico-os の lua_ext_test・iso_world_test・iso_td_test。
// (2026-11-07 に pico-os の lua_ext_test.cpp から移した。モックは lua_ext_test と同じ)
//   pico.iso(2.5Dの箱庭のエンジン。中身は iso_world_test、ここはLuaからの呼び方と権限。経路探索 path/stand も)
#include "lua/LuaEngine.hpp"
#include "system/I18n_Functions.hpp"
#include "services/Power_Functions.hpp"
#include "hal/Battery_Functions.hpp"
#include "system/Notification_Functions.hpp"
#include "hal/Sound_Functions.hpp"
#include "system/Pad_Functions.hpp"
#include "hal/Mic_Functions.hpp"
#include <I2S.h>
#include <cmath>
#include "gui/widgets/Widget.hpp"
#include "gui/widgets/WidgetRegistry.hpp"
#include "gui/widgets/Button.hpp"
#include "gui/widgets/TabBar.hpp"
#include "gui/widgets/ScrollContainer.hpp"
#include "gui/widgets/ScrollList.hpp"
#include "gui/widgets/DropdownMenu.hpp"
#include "gui/widgets/Textbox.hpp"
#include "gui/widgets/TextView.hpp"
#include "gui/widgets/apps/MonthGrid.hpp"
#include "gui/widgets/apps/DurationPicker.hpp"
#include "gui/widgets/WidgetFactory.hpp"
#include "gui/widgets/interfaces/ITextInputTarget.hpp"
#include "gui/widgets/dialogs/PickerDialog.hpp"
#include "gui/widgets/dialogs/MsgDialog.hpp"
#include "gui/widgets/dialogs/InputDialog.hpp"
#include "gui/core/Widget_Functions.hpp"
#include "gui/core/GFX_Functions.hpp"
#include "system/Log_Functions.hpp"
#include "gui/core/Keyboard_Functions.hpp"
#include "system/Time_Functions.hpp"
#include "hal/Network_Functions.hpp"
#include "OS_Data.hpp"
#include <algorithm>
#include <cstdarg>
#include <cstdlib>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <iterator>
#include <string>
#include "jpeg_test_data.hpp"
#include "png_test_data.hpp"
#include "gui/icons/Bmp_Codec.hpp"

// ---- モック(lua_engine_test.cppと同じ方針) ----
static Rect g_last_dirty{0, 0, 0, 0};
static int g_dirty_calls = 0;
void PICO_GFX::MarkDirty(const Rect& r){ g_last_dirty = r; g_dirty_calls++; }
void PICO_GFX::Setup(){}
void PICO_GFX::FlushDirty(){}
void PICO_GFX::DrawDialogBackground(){}
void LogFunctions::Log(LogType, const char* fmt, ...){
    if(!getenv("LUA_TEST_VERBOSE")) return;
    va_list ap;
    va_start(ap, fmt);
    vfprintf(stderr, fmt, ap);
    fputc('\n', stderr);
    va_end(ap);
}
void LogFunctions::Setup(){}
void LogFunctions::Update(){}
void LogFunctions::Flush(){}
void KeyboardFunctions::RegisterInputTarget(ITextInputTarget*){}
void KeyboardFunctions::UnregisterInputTarget(ITextInputTarget*){}
void KeyboardFunctions::Show(ITextInputTarget*, KeyboardFunctions::Layout, bool){}
void KeyboardFunctions::OnPanelShown(KeyboardPanel*){}
void KeyboardFunctions::OnPanelHidden(KeyboardPanel*){}
void KeyboardFunctions::OnPanelResized(KeyboardPanel*){}
void KeyboardFunctions::OnPanelChanged(KeyboardPanel*, bool){}
void KeyboardFunctions::HideAll(){}

class FakeKeyboard : public ITextInputWidget {
    public:
        FixedString<PICO_STR_LL> text;
        FixedString<PICO_STR_LL> getText() override { return text; }
        void setText(const FixedString<PICO_STR_LL>& t) override { text = t; }
        size_t getCursorByteOffset() override { return text.length(); }
        void setCursorByteOffset(size_t) override {}
        void setInputTarget(ITextInputTarget*) override {}
        void removeInputTarget(ITextInputTarget*) override {}
        ITextInputTarget* getInputTarget() override { return nullptr; }
};

static int failures = 0;
static void check(bool cond, const char* label) {
    printf("%s %s\n", cond ? "[ OK ]" : "[FAIL]", label);
    if (!cond) failures++;
}
static int l_check(lua_State* L) {
    const bool cond = lua_toboolean(L, 1);
    const char* label = luaL_optstring(L, 2, "(no label)");
    printf("%s %s\n", cond ? "[ OK ]" : "[FAIL]", label);
    if (!cond) failures++;
    return 0;
}

static std::string MakePimgBytes(uint16_t width, uint16_t height, bool transparent, uint8_t color_index) {
    std::string bytes;
    bytes += (char)(width & 0xFF);
    bytes += (char)((width >> 8) & 0xFF);
    bytes += (char)(height & 0xFF);
    bytes += (char)((height >> 8) & 0xFF);
    bytes += (char)(transparent ? 0x01 : 0x00);
    uint32_t remaining = (uint32_t)width * height;
    while (remaining > 0) {
        const uint8_t run = (remaining > 255) ? 255 : (uint8_t)remaining;
        bytes += (char)run;
        bytes += (char)color_index;
        remaining -= run;
    }
    return bytes;
}

static WidgetId GlobalId(lua_State* L, const char* name) {
    lua_getglobal(L, name);
    const WidgetId id = (WidgetId)lua_tointeger(L, -1);
    lua_pop(L, 1);
    return id;
}
static lua_Integer GlobalInt(lua_State* L, const char* name) {
    lua_getglobal(L, name);
    const lua_Integer v = lua_tointeger(L, -1);
    lua_pop(L, 1);
    return v;
}

// タッチを1フレーム分進める
static void Touch(int x, int y, bool start, bool end, bool touched) {
    OSData::touchX = x;
    OSData::touchY = y;
    OSData::isTouchStart = start;
    OSData::isTouchEnd = end;
    OSData::isTouched = touched;
}
static void TouchIdle() { Touch(OSData::touchX, OSData::touchY, false, false, false); }


int main(int argc, char** argv) {
    setvbuf(stdout, nullptr, _IONBF, 0);
    const std::string app = std::string(argc > 2 ? argv[2] : "../pico-os-apps") + "/apps/zombie-td/app/";

    // =====================================================================
    // ゾンビTD の zombies.lua を本物のエンジン(ARENA・流れの場・押し合い・弾)の上で動かす
    // =====================================================================
    {
        auto slurp = [&](const char* rel) {
            std::ifstream f(app + rel, std::ios::binary);
            return std::string((std::istreambuf_iterator<char>(f)), {});
        };
        HostSd::files["/td/zombies.lua"] = slurp("zombies.lua");
        HostSd::files["/td/combat.lua"] = slurp("combat.lua");
        HostSd::files["/td/soldiers.lua"] = slurp("soldiers.lua");
        HostSd::files["/td/buildings.lua"] = slurp("buildings.lua");
        HostSd::files["/td/sfx.lua"] = slurp("sfx.lua");
        HostSd::files["/td/units.pimg"] = slurp("units.pimg");
        HostSd::files["/td/faces.pimg"] = slurp("faces.pimg");
        OSData::SD_usable = true;
        LuaEngine te(180 * 1024, LuaPermissions{}, "/td");
        lua_register(te.raw(), "check", l_check);
        bool ok = te.Run(R"LUA(
            local iso = pico.iso
            Z = require("zombies")
            C = require("combat")
            iso.set_image(pico.image_load("/td/faces.pimg"), { 1, 2, 3, 4, 5, 11, 12, 14, 15, 16, 18, 22, 26 })
            local units = pico.image_load("/td/units.pimg")
            iso.create("/td/map", 4, 3, 7)
            iso.keep_all(true)
            iso.view(0, 20, 240, 246)
            while iso.pump(64) > 0 do end
            A = iso.arena()
            local b = A.base
            local goals = {}
            for dx = -2, 2 do for dz = -2, 2 do
                if math.max(math.abs(dx), math.abs(dz)) == 2 then goals[#goals + 1] = {b.x + dx, b.z + dz} end
            end end
            iso.flow_build(goals, {max_up = 1, max_down = 2, height = 2, up_cost = 0.5, diagonal = true}, true)
            for _, s in ipairs(A.spawns) do check(iso.flow_get(s.x, s.z) ~= nil, "zombies: 出現位置から道がある") end
            BASE = {x = b.x, y = b.y, z = b.z, hp = 100000, melee = 0, thrown = 0, r = 1.4, side = "base"}
            BASE.id = iso.entity_add(units, b.x + 0.5, b.y, b.z + 0.5,
                {sx = 80, sy = 0, w = 44, h = 40, r = 1.4, height = 2.5, crowd = "fixed", tag = 2})
            function BASE.hurt(self, d, src)
                BASE.hp = BASE.hp - d
                if src and src.t.reach > 0 then BASE.thrown = BASE.thrown + 1 else BASE.melee = BASE.melee + 1 end
            end
            C.add(BASE)
            math.randomseed(7)
            Z.init(units, A.spawns, BASE, {height = 2})
            Z.queue("normal", 30); Z.queue("ranged", 12); Z.queue("heavy", 8)
            check(Z.waiting() == 50 and Z.alive() == 0, "zombies.queue: 順番待ちに積む")
            Z.update(0.05)
            check(Z.alive() >= 1 and Z.alive() <= 3, "zombies.update: 出現位置ごとに間を空けて出す")
            function tick(n)
                for _ = 1, n do
                    Z.update(0.05)
                    if iso.crowd(2, {height = 2}) > 0 then Z.sync() end
                    C.step(0.05)
                end
            end
        )LUA", "td");
        check(ok, "zombies: 準備");
        int max_alive = 0;
        // 120秒ぶん(1回の Run は 2秒ぶん。命令数の上限に掛からないよう分ける)
        for (int i = 0; i < 60 && ok; i++) {
            ok = te.Run("tick(40)", "tick");
            lua_State* L = te.raw();
            lua_getglobal(L, "Z"); lua_getfield(L, -1, "alive"); lua_call(L, 0, 1);
            max_alive = std::max(max_alive, (int)lua_tointeger(L, -1));
            lua_pop(L, 2);
        }
        check(ok, "zombies: 120秒ぶん動かしてもエラーにならない");
        check(max_alive == 40, "zombies: 同時に出るのは40匹まで");
        ok = te.Run(R"LUA(
            local iso = pico.iso
            check(Z.alive() == 40 and Z.waiting() == 10, "zombies: 倒さなければ上限の40匹で止まり、残りは待つ")
            check(BASE.melee > 0, "zombies: 近接のゾンビがベースへ着いて叩く")
            check(BASE.thrown > 0, "zombies: 遠距離のゾンビの石がベースに当たる")
            -- 全員がマップの中、ベースのまわりへ寄っている
            local near, inside = 0, true
            for _, zb in ipairs(Z.list) do
                local x, y, z = iso.entity_pos(zb.id)
                if x < 0 or x > 56 or z < 0 or z > 56 then inside = false end
                if math.abs(x - (A.base.x + 0.5)) < 8 and math.abs(z - (A.base.z + 0.5)) < 8 then near = near + 1 end
                -- 立っている高さ: 柱の地面の上(浮いても埋まってもいない)
                local g = iso.stand(x, z, nil, {height = 2})
                if g and math.abs(y - g) > 1.01 then inside = false end
            end
            check(inside, "zombies: マップの中で地面に立っている")
            check(near >= 30, "zombies: ほとんどがベースのまわりへ着く (" .. near .. ")")
            -- 押し合い: 同じ所に重なっていない
            local overlap = 0
            for i = 1, #Z.list do for k = i + 1, #Z.list do
                local ax, _, az = iso.entity_pos(Z.list[i].id)
                local bx, _, bz = iso.entity_pos(Z.list[k].id)
                if (ax - bx) ^ 2 + (az - bz) ^ 2 < 0.01 then overlap = overlap + 1 end
            end end
            check(overlap == 0, "zombies: 押し合って重ならない")
            Z.kill(1)
            check(Z.alive() == 39 and Z.stats.killed == 1, "zombies.kill")
            Z.update(0.5)
            check(Z.alive() == 40 and Z.waiting() == 9, "zombies: 倒れた分だけ順番待ちから出す")
            Z.clear()
            check(Z.alive() == 0 and Z.waiting() == 0 and iso.entity_get(BASE.id) ~= nil, "zombies.clear: ゾンビだけ消える")
            iso.close()
        )LUA", "td3");
        check(ok, "zombies: 上限・ベースへの攻撃・押し合い・倒す");
    }

    // =====================================================================
    // ゾンビTD の soldiers.lua(雇う・移動・戦い・回復・強化・売却)を本物のエンジンの上で動かす
    // =====================================================================
    {
        OSData::SD_usable = true;
        LuaEngine te(180 * 1024, LuaPermissions{}, "/td");
        lua_register(te.raw(), "check", l_check);
        bool ok = te.Run(R"LUA(
            local iso = pico.iso
            Z = require("zombies"); C = require("combat"); S = require("soldiers")
            iso.set_image(pico.image_load("/td/faces.pimg"), { 1, 2, 3, 4, 5, 11, 12, 14, 15, 16, 18, 22, 26 })
            local units = pico.image_load("/td/units.pimg")
            iso.create("/td/map2", 4, 3, 7)
            iso.keep_all(true)
            iso.view(0, 20, 240, 246)
            while iso.pump(64) > 0 do end
            A = iso.arena()
            local b = A.base
            local goals = {}
            for dx = -2, 2 do for dz = -2, 2 do
                if math.max(math.abs(dx), math.abs(dz)) == 2 then goals[#goals + 1] = {b.x + dx, b.z + dz} end
            end end
            RULES = {height = 2, avoid = {1}}
            iso.flow_build(goals, {max_up = 1, max_down = 2, height = 2, up_cost = 0.5, diagonal = true, avoid = {1}}, true)
            BASE = {x = b.x, y = b.y, z = b.z, hp = 100000, r = 1.4, side = "base"}
            BASE.id = iso.entity_add(units, b.x + 0.5, b.y, b.z + 0.5,
                {sx = 80, sy = 0, w = 44, h = 40, r = 1.4, height = 2.5, crowd = "fixed", tag = 2})
            function BASE.hurt(self, d) BASE.hp = BASE.hp - d end
            C.add(BASE)
            math.randomseed(11)
            Z.init(units, A.spawns, BASE, RULES)
            S.init(units, BASE, RULES)
            Z.TARGET_TAGS = {S.TAG}; S.ZOMBIE_TAG = Z.TAG; Z.hunt = true
            KILLED, LOST, HEALED, LASTHP = 0, 0, 0, setmetatable({}, {__mode = "k"})
            Z.on_kill = function() KILLED = KILLED + 1 end
            S.on_lost = function() LOST = LOST + 1 end
            function tick(n)
                for _ = 1, n do
                    Z.update(0.05)
                    S.update(0.05)
                    if iso.crowd(2, {height = 2}) > 0 then Z.sync(); S.sync() end
                    C.step(0.05)
                    for _, s in ipairs(S.list) do
                        if s.state == "hold" and s.kind == "melee" then
                            local d = math.sqrt((s.x - s.px) ^ 2 + (s.z - s.pz) ^ 2)
                            if s.tgt and s.tgt.tgt == s then
                                if d > (MAXLEASH2 or 0) then MAXLEASH2 = d end   -- 自分を狙う相手は遠くまで追う
                            elseif d > (MAXLEASH or 0) then MAXLEASH = d end
                        end
                        if s.hp > (LASTHP[s] or s.hp) then HEALED = HEALED + 1 end
                        LASTHP[s] = s.hp
                    end
                end
            end
            -- 雇う: ベースの前へ出てきて、持ち場へ歩いて止まる
            M1 = S.hire("melee"); H1 = S.hire("healer"); R1 = S.hire("ranged")
            check(M1 and H1 and R1 and S.count() == 3, "soldiers.hire: 3種類を雇える")
            check(M1.t.name == "近接" and M1.lv == 1 and M1.hp == 60, "soldiers.hire: Lv1 の値")
        )LUA", "sol");
        check(ok, "soldiers: 準備");
        ok = ok && te.Run("tick(120)", "tick");
        ok = ok && te.Run(R"LUA(
            local iso = pico.iso
            for _, s in ipairs(S.list) do
                check(s.state == "hold" and not s.path, "soldiers: 持ち場に着いて止まる (" .. s.kind .. ")")
                local g = iso.stand(s.x, s.z, nil, RULES)
                check(g and math.abs(s.y - g) < 0.01, "soldiers: 地面に立っている")
                check(s.z > BASE.z + 1.5, "soldiers: ベースの前(出現位置の側)にいる")
            end
            -- 移動の指示: 10マスほど先へ3人を散らばらせる
            local tx, tz = BASE.x, BASE.z + 14
            while not S.standable(tx, tz) do tx = tx + 1 end
            check(S.order_group(S.list, tx + 0.5, tz + 0.5), "soldiers.order_group: 立てる所へは指示できる")
            DEST = {tx, tz}
            -- 水の上へは指示できない
            local wx, wz
            for x = 0, 55 do for z = 0, 55 do
                if not wx and iso.ground(x, z) and iso.get(x, iso.ground(x, z) - 1, z) == 1 then wx, wz = x, z end
            end end
            if wx then check(not S.order_group(S.list, wx + 0.5, wz + 0.5), "soldiers.order_group: 水の上は不可") end
            check(not S.order_group(S.list, BASE.x + 0.5, BASE.z + 0.5), "soldiers.order_group: ベースの上は不可")
        )LUA", "sol2");
        ok = ok && te.Run("tick(200)", "tick") && te.Run("tick(200)", "tick");
        ok = ok && te.Run(R"LUA(
            local iso = pico.iso
            local cols = {}
            for _, s in ipairs(S.list) do
                check(s.state == "hold", "soldiers: 指示した所へ着く (" .. s.kind .. ")")
                check(math.abs(s.x - (DEST[1] + 0.5)) <= 3.6 and math.abs(s.z - (DEST[2] + 0.5)) <= 3.6, "soldiers: 指示した地点のまわりにいる")
                cols[math.floor(s.px) * 100 + math.floor(s.pz)] = true
                check(iso.get(math.floor(s.x), math.floor(s.gy) - 1, math.floor(s.z)) ~= 1, "soldiers: 水の上に立っていない")
            end
            local n = 0 for _ in pairs(cols) do n = n + 1 end
            check(n == 3, "soldiers: 複数人はまわりに散らばって並ぶ")
            -- 道を探す作業場所を確保できない(実機でヒープが足りない)とき: 止まらず、1秒は探し直さず持ち場へ歩く
            do
                local real = iso.path
                local calls = 0
                iso.path = function() calls = calls + 1; return nil, "memory" end
                local m = S.hire("melee")
                S.order(m, DEST[1] + 0.5, DEST[2] + 0.5)   -- 遠い所(毎回探し直す距離)
                local okk, err = pcall(tick, 40)           -- 2秒
                iso.path = real
                check(okk, "soldiers: 道を探すメモリが無くてもエラーにならない " .. tostring(err))
                check(calls >= 2 and calls <= 5, "soldiers: メモリが無いときは1秒ごとにしか探し直さない (" .. calls .. "回)")
                S.order(m, m.x, m.z)
                S.sell(m)
            end
            -- 1人/1匹の表のキーは16個以内(超えるとLuaの表が倍の大きさになる)
            local function keys(t) local k = 0 for _ in pairs(t) do k = k + 1 end return k end
            for _, u in ipairs(S.list) do check(keys(u) <= 16, "soldiers: 表のキーは16個以内 (" .. keys(u) .. ")") end
            -- 強化と売却
            check(S.upgrade_cost(M1) == 50, "soldiers.upgrade_cost")
            M1.hp = 50
            check(S.upgrade(M1) and M1.lv == 2 and S.max_hp(M1) == 90 and M1.hp == 80, "soldiers.upgrade: 最大耐久の増えた分だけ回復")
            S.upgrade(M1); S.upgrade(M1)
            check(M1.lv == 4 and S.upgrade_cost(M1) == nil and not S.upgrade(M1), "soldiers.upgrade: Lv4 が最大")
            check(S.paid(M1) == 60 + 50 + 80 + 120 and S.sell_value(M1) == 217, "soldiers.sell_value: 払った合計の70%")
            M1.hp = S.max_hp(M1)
            -- 持ち場をベースの近くへ戻し、ゾンビを呼ぶ
            S.order_group(S.list, BASE.x + 0.5, BASE.z + 5.5)
            Z.queue("normal", 12); Z.queue("ranged", 4)
        )LUA", "sol3");
        // 60秒ぶん戦わせる
        for (int i = 0; i < 30 && ok; i++) ok = te.Run("tick(40)", "tick");
        ok = ok && te.Run(R"LUA(
            check(KILLED > 0 and Z.stats.killed == KILLED, "soldiers: ゾンビを倒す (" .. KILLED .. ")")
            local function keys(t) local k = 0 for _ in pairs(t) do k = k + 1 end return k end
            local mk = 0
            for _, u in ipairs(Z.list) do mk = math.max(mk, keys(u)) end
            check(mk <= 16, "zombies: 表のキーは16個以内 (" .. mk .. ")")
            check(MAXLEASH and MAXLEASH <= 3.6, "soldiers: 近接兵は持ち場から3マスほどまでしか離れない (" .. tostring(MAXLEASH) .. ")")
            check((MAXLEASH2 or 0) <= 7.6, "soldiers: 自分を狙うゾンビでも持ち場から7マスほどまで (" .. tostring(MAXLEASH2) .. ")")
            check(HEALED > 0, "soldiers: 回復兵が回復する (" .. HEALED .. ")")
            -- 移動中の反撃: 攻撃してきたゾンビが近くにいれば止まって戦う
            Z.clear(); C.clear_shots()
            S.clear()
            local s = S.hire("melee")
            tick(80)
            S.order(s, s.x, s.z + 12)
            Z.queue("normal", 1)
            Z.update(0.4)
            local zb = Z.list[1]
            zb.x, zb.z = s.x + 0.4, s.z
            zb.gy = s.gy; zb.y = s.y
            pico.iso.entity_move(zb.id, zb.x, zb.y, zb.z)
            zb.tgt = s
            s.hurt(s, 1, zb)
            check(s.state == "move" and s.tgt == zb, "soldiers: 移動中でも攻撃してきた相手に反撃する")
            local px, pz = s.x, s.z
            S.update(0.35)
            check(s.tgt == zb and math.abs(s.x - px) + math.abs(s.z - pz) < 0.3, "soldiers: 反撃しながら目的地へは進まない")
            -- 相手が倒れたら移動を続ける
            zb.hp = 1
            tick(30)
            check(Z.alive() == 0, "soldiers: 反撃で倒す")
            tick(20)
            check(s.state == "move" and s.path and not s.tgt, "soldiers: 倒したら移動を続ける")
            -- 兵士が倒れる
            s.hp = 1
            local lost0 = LOST
            s.hurt(s, 5, nil)
            S.update(0.05)
            check(LOST == lost0 + 1 and S.count() == 0 and C.units[s.id] == nil, "soldiers: 倒れたら消える")
            -- ゾンビは気づく範囲の兵士を、優先度と距離で狙う
            local m = S.hire("melee"); local r = S.hire("ranged")
            Z.queue("normal", 1); Z.update(0.4)
            local z2 = Z.list[1]
            m.x, m.z = z2.x + 2.5, z2.z; r.x, r.z = z2.x + 1.5, z2.z
            pico.iso.entity_move(m.id, m.x, m.y, m.z); pico.iso.entity_move(r.id, r.x, r.y, r.z)
            z2.scan = 0
            Z.update(0.01)
            check(z2.tgt == m, "zombies: 近接兵(優先度0)を弓兵(優先度3)より先に狙う")
            -- 遠距離ゾンビが反撃して来ない相手へ投げ続けても、ENGAGE_MAX 秒で諦めてベースへ向かう(膠着しない)
            S.clear(); Z.clear()
            local h = S.hire("melee")
            h.hp = 100000
            Z.queue("ranged", 1); Z.update(0.4)
            local zr = Z.list[1]
            local placed = false
            for d = 0, 40 do
                for _, o in ipairs({{3.6, 0}, {0, 3.6}, {-3.6, 0}, {0, -3.6}}) do
                    local hx, hz = zr.x + o[1], zr.z + o[2] - d * 0.5
                    local hy = pico.iso.stand(hx, hz, nil, {height = 2, avoid = {1}})
                    if not placed and hy and math.abs(hy - zr.gy) < 0.5
                        and pico.iso.sight(zr.x, zr.gy + 1.2, zr.z, hx, hy + 1, hz) then
                        h.x, h.y, h.z, h.gy = hx, hy, hz, hy
                        pico.iso.entity_move(h.id, hx, hy, hz)
                        placed = true
                    end
                end
                if placed then break end
                zr.z = zr.z - 0.5; zr.col = -1
            end
            zr.scan = 0
            local ZX0, ZZ0, ZY0 = zr.x, zr.z, zr.gy
            for _ = 1, 40 do Z.update(0.05); C.step(0.05) end
            check(placed and zr.tgt == h, "zombies: 遠距離ゾンビが兵士を狙って投げる")
            local zx, zz = zr.x, zr.z
            for _ = 1, 140 do Z.update(0.05); C.step(0.05) end
            check(h.hp < 100000, "zombies: 兵士に石が当たる")
            check(zr.tgt == false and zr.hp > 0, "zombies: 遠距離ゾンビは投げ続けても諦める(膠着しない)")
            for _ = 1, 40 do Z.update(0.05); C.step(0.05) end
            check(math.abs(zr.x - zx) + math.abs(zr.z - zz) > 0.5, "zombies: 諦めた後はベースへ進む")
            -- 兵士はベースか自分を攻撃しているゾンビを、持ち場から LEASH(3) より遠くまで追う
            S.pressing = Z.pressing
            local g = S.restore("melee", 1, 60, h.x, h.z)
            zr.x, zr.z, zr.gy, zr.y = ZX0, ZZ0, ZY0, ZY0
            zr.col = math.floor(zr.x) * 1024 + math.floor(zr.z)     -- 次の update で投げる/投げないを引き直させない
            pico.iso.entity_move(zr.id, zr.x, zr.y, zr.z)
            zr.tgt, zr.throw, zr.tx = false, false, zr.x
            g.scan = 0
            S.update(0.05)
            check(not g.tgt, "soldiers: 持ち場から3マスより遠い、ベースを攻撃していないゾンビは追わない")
            zr.throw = true
            g.scan = 0
            S.update(0.05)
            check(g.tgt == zr, "soldiers: ベースへ石を投げているゾンビは持ち場から3マスより遠くても追う")
            g.tgt = false; zr.throw = false; zr.tgt = g
            g.scan = 0
            S.update(0.05)
            check(g.tgt == zr, "soldiers: 自分を狙っているゾンビも遠くまで追う")
            g.tgt = false; zr.tgt = BASE     -- 他の誰か(ここではベースの表)へ投げている遠距離ゾンビ
            g.scan = 0
            S.update(0.05)
            check(g.tgt == zr, "soldiers: 他の兵士へ投げている遠距離ゾンビも遠くまで追う")
            S.pressing = nil
            S.clear(); Z.clear()
            pico.iso.close()
        )LUA", "sol4");
        check(ok, "soldiers: 一通り");
    }

    // =====================================================================
    // ゾンビTD の buildings.lua(タワー・バリケード・建設・強化・修理・売却)を本物のエンジンの上で動かす
    // =====================================================================
    {
        OSData::SD_usable = true;
        LuaEngine te(180 * 1024, LuaPermissions{}, "/td");
        lua_register(te.raw(), "check", l_check);
        bool ok = te.Run(R"LUA(
            local iso = pico.iso
            Z = require("zombies"); C = require("combat"); S = require("soldiers"); B = require("buildings")
            iso.set_image(pico.image_load("/td/faces.pimg"), { 1, 2, 3, 4, 5, 11, 12, 14, 15, 16, 18, 22, 26 })
            local units = pico.image_load("/td/units.pimg")
            iso.create("/td/map3", 4, 3, 7)
            iso.keep_all(true)
            iso.view(0, 20, 240, 246)
            while iso.pump(64) > 0 do end
            A = iso.arena()
            local b = A.base
            GOALS = {}
            for dx = -2, 2 do for dz = -2, 2 do
                if math.max(math.abs(dx), math.abs(dz)) == 2 then GOALS[#GOALS + 1] = {b.x + dx, b.z + dz} end
            end end
            local W = B.WALLS
            local cost = {}
            for _, w in ipairs(W) do cost[w] = 6 end
            FLOW = {max_up = 1, max_down = 2, height = 2, up_cost = 0.5, diagonal = true, avoid = {1}, pass = W, body_cost = cost}
            ZR = {height = 2, avoid = {1}, pass = W}
            SR = {height = 2, avoid = {1, W[1], W[2], W[3], W[4]}}
            C.SIGHT_PASS = W
            iso.flow_build(GOALS, FLOW, true)
            BASE = {x = b.x, y = b.y, z = b.z, hp = 100000, r = 1.4, side = "base"}
            BASE.id = iso.entity_add(units, b.x + 0.5, b.y, b.z + 0.5,
                {sx = 80, sy = 0, w = 44, h = 40, r = 1.4, height = 2.5, crowd = "fixed", tag = 2})
            function BASE.hurt(self, d) BASE.hp = BASE.hp - d end
            C.add(BASE)
            math.randomseed(5)
            Z.init(units, A.spawns, BASE, ZR)
            S.init(units, BASE, SR)
            B.init(units, BASE, A.spawns)
            Z.TARGET_TAGS = {S.TAG, B.TAG}; Z.hunt = true; Z.wall_at = B.wall_at
            S.ZOMBIE_TAG = Z.TAG; B.ZOMBIE_TAG = Z.TAG
            S.blocked = function(x, z) return B.at[B.col(x, z)] ~= nil end
            WALLS_CHANGED, KILLED, LOSTB = 0, 0, 0
            B.on_walls_changed = function() WALLS_CHANGED = WALLS_CHANGED + 1; iso.flow_build(GOALS, FLOW, true) end
            B.on_lost = function() LOSTB = LOSTB + 1 end
            Z.on_kill = function() KILLED = KILLED + 1 end
            function tick(n)
                for _ = 1, n do
                    Z.update(0.05); S.update(0.05); B.update(0.05)
                    if iso.crowd(2, {height = 2, pass = W}) > 0 then Z.sync(); S.sync() end
                    C.step(0.05)
                end
            end
            -- 置ける所: ベースの近く・出現位置の近く・水の上・建物のある柱は不可
            check(not B.can_place("arrow", b.x + 2, b.z + 2, SR), "buildings.can_place: ベースの近くは不可")
            local sp = A.spawns[1]
            check(not B.can_place("wall", sp.x + 1, sp.z, SR), "buildings.can_place: 出現位置の近くは不可")
            local wx, wz
            for x = 0, 55 do for z = 0, 55 do
                if not wx and iso.ground(x, z) and iso.get(x, iso.ground(x, z) - 1, z) == 1 then wx, wz = x, z end
            end end
            if wx then check(not B.can_place("wall", wx, wz, SR), "buildings.can_place: 水の上は不可") end
            -- 弓塔: ベースの前に建てる
            TX, TZ = b.x, b.z + 5
            while not B.can_place("arrow", TX, TZ, SR) do TX = TX + 1 end
            T1 = B.place("arrow", TX, TZ, SR)
            check(T1 and T1.state == "build" and T1.hp == 80 and B.max_hp(T1) == 80, "buildings.place: 建設中は完成時の40%の耐久")
            check(not B.can_place("wall", TX, TZ, SR), "buildings.can_place: 同じ柱には置けない")
            check(not S.standable(TX, TZ), "soldiers.standable: 建物の柱には立てない")
            check(B.sell_value(T1) == nil and B.upgrade_cost(T1) == nil and B.repair_cost(T1) == nil, "buildings: 建設中は売れない・強化/修理できない")
            check(B.remaining(T1) == 5, "buildings.remaining: 建設の残り秒")
        )LUA", "bld");
        check(ok, "buildings: 準備");
        ok = ok && te.Run("tick(165)", "tick");
        ok = ok && te.Run(R"LUA(
            local iso = pico.iso
            check(T1.state == "ready" and T1.hp == 200 and B.max_hp(T1) == 200, "buildings: 建設が終わると耐久が完成時の値になる")
            local _, _, _, o = iso.entity_get(T1.id)
            check(o.sx == 216 and o.h == 36, "buildings: 完成すると塔の絵になる")
            -- 強化: 建設の半分の時間、その間は耐久が低い
            check(B.upgrade_cost(T1) == 80 and B.upgrade(T1), "buildings.upgrade")
            check(T1.state == "up" and T1.lv == 2 and B.max_hp(T1) == 92 and T1.hp == 92 and B.remaining(T1) == 2.5,
                  "buildings.upgrade: 強化中は耐久が低い (" .. T1.hp .. ")")
            tick(85)
            check(T1.state == "ready" and T1.hp == 230, "buildings.upgrade: 終わると耐久が戻る (" .. T1.hp .. ")")
            -- 修理: 費用 = 減った割合 × 払った合計 × 0.3、3秒かけて戻る
            T1.hp = 115
            check(B.repair_cost(T1) == 27, "buildings.repair_cost (" .. tostring(B.repair_cost(T1)) .. ")")
            check(B.repair(T1) and B.repair_cost(T1) == nil, "buildings.repair: 修理中は重ねて修理しない")
            tick(30)
            check(T1.hp > 130 and T1.hp < 230, "buildings.repair: 少しずつ戻る")
            tick(40)
            check(math.abs(T1.hp - 230) < 0.01 and T1.rr == 0, "buildings.repair: 3秒で戻る")
            check(B.sell_value(T1) == 126, "buildings.sell_value: 払った合計の70% (" .. B.sell_value(T1) .. ")")
            -- バリケード: ブロックを置き、流れの場を作り直す
            local fz = A.spawns[2].z - 6
            WX, WZ = A.spawns[2].x, fz
            while not B.can_place("wall", WX, WZ, SR) do WX = WX + 1 end
            local w0 = WALLS_CHANGED
            W1 = B.place("wall", WX, WZ, SR)
            check(W1 and iso.get(WX, W1.y, WZ) == B.WALLS[1] and WALLS_CHANGED == w0 + 1, "buildings.place(wall): ブロックを置いて道を作り直す")
            check(B.wall_at(WX + 0.3, WZ + 0.7) == W1 and B.wall_at(TX, TZ) == nil, "buildings.wall_at")
            check(iso.stand(WX, WZ, nil, ZR) == W1.y and iso.stand(WX, WZ, nil, SR) == nil, "バリケードの中はゾンビは立てる・兵士は立てない")
            tick(85)
            check(W1.state == "ready" and W1.hp == 150, "buildings: バリケードの建設が終わる")
            -- 兵士の道はタワーの柱を通らない
            local s = S.hire("melee")
            tick(80)
            S.order(s, TX + 0.5, TZ + 2.5)
            local through = false
            for _, p in ipairs(s.path or {}) do if p.x == TX and p.z == TZ then through = true end end
            check(s.path and not through, "soldiers: 道はタワーの柱を通らない")
            S.clear()
            -- ゾンビがバリケードの中を通ると遅くなり、バリケードが削れる
            Z.queue("heavy", 1); Z.update(0.4)
            ZB = Z.list[1]
            ZB.x, ZB.z, ZB.gy, ZB.y = WX + 0.5, WZ + 0.1, W1.y, W1.y
            ZB.col = -1
            local hp0 = W1.hp
            Z.update(0.05)
            check(W1.hp < hp0, "zombies: バリケードの中を通ると削る")
            -- 遅くなる: 同じ時間で動く距離を比べる
            local x0, z0 = ZB.x, ZB.z
            Z.update(0.1)
            local inside = math.sqrt((ZB.x - x0) ^ 2 + (ZB.z - z0) ^ 2)
            check(inside > 0 and inside < 0.55 * 0.1 * 0.6, "zombies: バリケードの中は遅い (" .. inside .. ")")
            -- 中にいる間は受けるダメージが1.3倍
            local zh = ZB.hp
            ZB:hurt(10)
            check(zh - ZB.hp == 13, "zombies: バリケードの中は傷つきやすい (" .. zh - ZB.hp .. ")")
            -- 強化するとブロックが変わる
            W1.hp = 150
            Z.clear()
            check(B.upgrade(W1) and iso.get(WX, W1.y, WZ) == B.WALLS[2], "buildings.upgrade(wall): ブロックが Lv2 の絵になる")
            tick(45)
            check(W1.state == "ready" and W1.lv == 2, "buildings.upgrade(wall): 終わる")
            -- 壊されると消える(ブロックも空気に)
            local lost0, changed = LOSTB, WALLS_CHANGED
            W1:hurt(1000)
            tick(1)
            check(LOSTB == lost0 + 1 and iso.get(WX, W1.y, WZ) == 0 and B.wall_at(WX, WZ) == nil and WALLS_CHANGED == changed + 1,
                  "buildings: バリケードは壊されると消えて道を作り直す")
            -- 表のキーは16個以内
            local function keys(t) local k = 0 for _ in pairs(t) do k = k + 1 end return k end
            check(keys(T1) <= 16, "buildings: 表のキーは16個以内 (" .. keys(T1) .. ")")
            -- ゾンビはタワーを狙い、弓塔はゾンビを倒す
            Z.queue("normal", 10); Z.queue("ranged", 4)
        )LUA", "bld2");
        for (int i = 0; i < 40 && ok; i++) ok = te.Run("tick(40)", "tick");
        ok = ok && te.Run(R"LUA(
            local iso = pico.iso
            check(KILLED > 0, "buildings: 弓塔がゾンビを倒す (" .. KILLED .. ")")
            check(T1.hp < 230 or LOSTB > 1, "zombies: タワーを狙って攻撃する (" .. T1.hp .. ")")
            -- 売る
            if T1.hp > 0 and B.sell_value(T1) then
                local id = T1.id
                local v = B.sell(T1)
                check(v > 0 and iso.entity_get(id) == nil and B.at[B.col(TX, TZ)] == nil, "buildings.sell: 取り除いてお金を返す")
            end
            -- 全部消す: バリケードのブロックも空気に戻る
            local w2 = B.place("wall", WX, WZ, SR)
            B.clear()
            check(iso.get(WX, w2.y, WZ) == 0 and B.count() == 0, "buildings.clear: バリケードのブロックも消える")
            Z.clear()
            iso.close()
        )LUA", "bld3");
        check(ok, "buildings: 一通り");
    }

    // =====================================================================
    // ゾンビTD のウェーブ・保存(waves.lua / save.lua)と、game.lua 全体の流れ
    // =====================================================================
    {
        auto slurp = [&](const std::string& rel) {
            std::ifstream f(app + rel, std::ios::binary);
            return std::string((std::istreambuf_iterator<char>(f)), {});
        };
        static const char* const kFiles[] = {"game.lua", "state.lua", "orders.lua", "ui.lua", "waves.lua", "save.lua", "sfx.lua", "tutorial.lua", "cursor.lua",
            "combat.lua", "zombies.lua", "soldiers.lua", "buildings.lua", "palette.lua", "faces.pimg", "units.pimg"};
        for (const char* f : kFiles) {
            HostSd::files[std::string("/tdg/") + f] = slurp(f);
        }
        OSData::SD_usable = true;
        // pico.keep_awake
        {
            LuaEngine ke(64 * 1024);
            PowerFunctions::detail::keep_awake = false;
            check(ke.Run("pico.keep_awake()", "ka") && PowerFunctions::detail::keep_awake, "pico.keep_awake: 印を立てる");
            PowerFunctions::detail::keep_awake = false;
        }
        LuaPermissions tperm;
        tperm.strip_debug = true;   // app.cfg と同じ
        LuaEngine te(270 * 1024, tperm, "/tdg");
        lua_register(te.raw(), "check", l_check);
        // waves.lua 単体
        bool ok = te.Run(R"LUA(
            local Wv = require("waves")
            local a, b, c = Wv.mix(1)
            check(a == 17 and b == 0 and c == 0, "waves.mix: 1回目はノーマルだけ(稼ぎどきで多め)")
            check(Wv.preview(1):find("稼ぎどき") ~= nil and Wv.preview(6):find("稼ぎどき") == nil, "waves.preview: 序盤は稼ぎどき")
            a, b, c = Wv.mix(5)
            check(a + b + c == 21, "waves.mix: 稼ぎどきの後は 6 + 3×ウェーブ数")
            a, b, c = Wv.mix(10)
            check(a + b + c == 36 and b > 0 and c > 0, "waves.mix: 進むと遠距離・重量級が混ざる")
            check(Wv.preview(3):find("重量級が来る") ~= nil and Wv.preview(2):find("遠距離が来る") ~= nil,
                  "waves.preview: 初めて来る種類を予告する")
            check(Wv.bonus(3) == 60 and Wv.money_mul(5) == 1.2, "waves: 越えたお金と倒したお金の倍率")
            Wv.reset(1)
            check(Wv.phase == "prep" and Wv.timer == 60, "waves.reset: 最初の準備時間は60秒")
            Wv.timer = 12.6
            check(Wv.skip() == 24 and Wv.timer == 0, "waves.skip: 残り秒数×2 のお金")
            local Z = { q = {}, a = 0 }
            function Z.queue(k) Z.q[#Z.q + 1] = k end
            function Z.alive() return Z.a end
            function Z.waiting() return #Z.q end
            check(Wv.update(0.1, Z) == "start", "waves.update: 準備時間が終わると start")
            Wv.n = 4
            Wv.start(Z)
            local n = { normal = 0, ranged = 0, heavy = 0 }
            for _, k in ipairs(Z.q) do n[k] = n[k] + 1 end
            a, b, c = Wv.mix(4)
            check(Wv.phase == "wave" and n.normal == a and n.ranged == b and n.heavy == c, "waves.start: 中身どおりに積む")
            check(Z.hp_mul == Wv.hp_mul(4) and Z.dmg_mul == Wv.dmg_mul(4), "waves.start: 強さの倍率を入れる")
            check(Wv.update(1, Z) == nil, "waves.update: 残っている間は続く")
            Z.q = {}
            check(Wv.update(1, Z) == "clear" and Wv.n == 5 and Wv.phase == "prep" and Wv.timer == 30,
                  "waves.update: 全部倒すと clear・次の準備時間は30秒")
            -- save.better
            local Sv = require("save")
            check(Sv.better({w = 3, hp = 0, earned = 1}, {w = 2, hp = 9, earned = 9}) and
                  not Sv.better({w = 3, hp = 0, earned = 1}, {w = 3, hp = 0, earned = 2}) and
                  Sv.better({w = 1, hp = 0, earned = 0}, nil), "save.better: ウェーブ数 → ベースの耐久 → 稼いだ合計")
        )LUA", "waves");
        check(ok, "waves/save: 単体");
        // game.lua 全体: 新しく始める → ウェーブ → 越える → 保存 → ゲームオーバー
        HostSd::files.erase("/tdg/store.json");
        ok = ok && te.Run("TEST = {}; require('game')", "game");
        lua_State* L = te.raw();
        for (int i = 0; i < 300 && ok; i++) {
            te.CallLoop(50);
            ok = te.Run("DONE = TEST.env.G.mode == 'play'", "m");
            lua_getglobal(L, "DONE");
            const bool done = lua_toboolean(L, -1);
            lua_pop(L, 1);
            if (done) break;
        }
        ok = te.Run(R"LUA(
            local E = TEST.env
            local G, Wv = E.G, E.waves
            check(G.mode == "play" and G.money == 300 and Wv.n == 1 and Wv.phase == "prep", "game: マップを作って準備時間から始まる")
            check(E.tutorial.active and E.tutorial.text():find("建設") ~= nil, "tutorial: 初めてなら説明が始まる(建設から)")
            E.orders.hire("melee")
            E.tutorial.update(0.1)
            check(E.tutorial.text():find("建設") ~= nil, "tutorial: 言われたことをするまで進まない")
            check(G.money == 240 and E.soldiers.count() == 1, "game: 雇うとお金が減る")
            local left = math.floor(Wv.timer)
            E.next_wave()
            check(left > 50 and G.money == 240 + left * 2 and Wv.timer == 0, "game: 次へで残り秒数×2 (" .. G.money .. ")")
            MONEY_START = G.money
        )LUA", "g1");
        te.CallLoop(50);
        ok = ok && te.Run(R"LUA(
            local E = TEST.env
            local G, Wv = E.G, E.waves
            check(Wv.phase == "wave" and E.zombies.waiting() + E.zombies.alive() == 17, "game: ウェーブ1が始まる")
            local st = pico.store_load()
            check(st and st.game and st.game.w == 1 and st.game.money == MONEY_START and #st.game.s == 1 and st.game.seed == G.seed,
                  "game: ウェーブの始めに保存する")
            -- 全部倒したことにする
            MONEY0 = G.money
            E.zombies.clear()
        )LUA", "g2");
        te.CallLoop(50);
        ok = ok && te.Run(R"LUA(
            local E = TEST.env
            local G, Wv = E.G, E.waves
            check(Wv.n == 2 and Wv.phase == "prep" and G.money == MONEY0 + 40, "game: ウェーブを越えると 30+10×1 のお金")
            local st = pico.store_load()
            check(st.game.w == 2, "game: 準備時間の始めに保存する")
            -- 保存から戻す: 建物と兵士
            local B, S = E.buildings, E.soldiers
            local b = G.base
            local x, z = b.x, b.z + 6
            while not B.can_place("arrow", x, z, G.S_STAND) do x = x + 1 end
            local t = B.place("arrow", x, z, G.S_STAND)
            B.upgrade(t)   -- 建設中なので強化できない
            local game = E.save.dump(G, Wv, S, B)
            check(#game.b == 1 and game.b[1][1] == "arrow" and game.b[1][4] == 1, "save.dump: 建物の一覧")
            E.orders.deselect_all(); B.clear(); S.clear()
            game.b[1][4], game.b[1][5] = 3, 100
            game.money = 999
            E.save.restore(game, G, Wv, S, B, G.S_STAND)
            local r = B.list[1]
            check(r and r.lv == 3 and r.state == "ready" and r.hp == 100 and G.money == 999 and S.count() == 1 and
                  S.list[1].state == "hold", "save.restore: 建物と兵士を戻す")
            -- レベルごとの絵(units.pimg の 40px の段)
            local sx = S.list[1]
            S.upgrade(sx)
            E.soldiers.update(0.05)
            local _, _, _, o = pico.iso.entity_get(sx.id)
            check(o.sy == 2 * 40 - 22, "soldiers.upgrade: Lv2 の段の絵になる (" .. o.sy .. ")")
            _, _, _, o = pico.iso.entity_get(r.id)
            check(o.sy == 3 * 40 - 36, "buildings: Lv3 の塔の段の絵 (" .. o.sy .. ")")
            -- ウェーブ2以降の攻撃力の倍率(1.04)でも、ゾンビのダメージは整数(耐久を %d で出すため)
            E.zombies.dmg_mul = 1.04
            E.zombies.queue("normal", 4)
            E.zombies.queue("ranged", 2)
            G.speed = 3
        )LUA", "g3");
        for (int i = 0; i < 3000 && ok; i++) {
            te.CallLoop(50);
            ok = te.Run("local b = TEST.env.G.base; DONE = b.hp < 1990", "m");
            lua_getglobal(L, "DONE");
            const bool done = lua_toboolean(L, -1);
            lua_pop(L, 1);
            if (done) break;
        }
        ok = ok && te.Run(R"LUA(
            local E = TEST.env
            local G = E.G
            check(G.base.hp < 1990 and G.base.hp == math.floor(G.base.hp), "zombies: 倍率がかかってもダメージは整数 (" .. G.base.hp .. ")")
            for _, s in ipairs(E.soldiers.list) do check(s.hp == math.floor(s.hp), "zombies: 兵士の耐久も整数") end
            -- ゲームオーバー
            G.base:hurt(5000)
            check(G.mode == "over", "game: ベースが壊れると終わる")
            st = pico.store_load()
            check(st.game == nil and st.best and st.best.w == E.waves.n - 1 and st.best.w >= 1, "game: 途中の保存を消して最高記録(耐えたウェーブ数)を残す (" .. tostring(st.best and st.best.w) .. ")")
        )LUA", "g4");
        check(ok, "game: ウェーブと保存の流れ");
        // コントローラー・キーボードのカーソル(cursor.lua)と、地図の上のメニュー(ui.lua)
        ok = te.Run(R"LUA(
            PAD, PADP = {}, {}
            pico.pad_down = function(n) return PAD[n] == true end
            pico.pad_pressed = function(n) return PADP[n] == true end
            function press(...)
                for _, n in ipairs({...}) do PAD[n] = true; PADP[n] = true end
                loop(16)
                PAD, PADP = {}, {}
                loop(16)
            end
            press("a")
            check(TEST.env.G.mode == "load", "cursor: 終わった画面で A を押すと新しく始める")
        )LUA", "c0");
        for (int i = 0; i < 300 && ok; i++) {
            te.CallLoop(50);
            ok = te.Run("DONE = TEST.env.G.mode == 'play'", "m");
            lua_getglobal(L, "DONE");
            const bool done = lua_toboolean(L, -1);
            lua_pop(L, 1);
            if (done) break;
        }
        ok = ok && te.Run(R"LUA(
            local E = TEST.env
            local G, C, ui, S, B = E.G, E.cursor, E.ui, E.soldiers, E.buildings
            E.tutorial.stop()
            check(G.mode == "play" and not C.on, "cursor: 始めは隠れている")
            press("up")
            check(C.on, "cursor: 十字を押すと出る")
            local x, z = C.x, C.z
            press("up"); press("right")
            check(C.x == x + 1 and C.z == z - 1, "cursor: 上=+x、右=-z (" .. C.x - x .. "," .. C.z - z .. ")")
            -- 押したままで続けて動く
            x = C.x
            PAD.down = true; PADP.down = true; loop(16); PADP = {}
            for _ = 1, 30 do loop(16) end
            PAD = {}; loop(16)
            check(C.x <= x - 3, "cursor: 押したままで続けて動く (" .. x - C.x .. ")")
            -- SELECT で下の欄へ → A で雇う → メニューで2番目を選ぶ
            press("select")
            check(ui.focus and ui.focus.id == "hire", "cursor: SELECT で下の欄の「雇う」へ")
            press("a")
            check(ui.menu_active(), "cursor: 雇うでメニューが開く")
            press("down"); press("a")
            check(not ui.menu_active() and S.count() == 1 and S.list[1].kind == S.KINDS[2] and G.sel[1] == S.list[1] and not ui.focus,
                  "cursor: メニューで選んで雇い、地図へ戻る")
            -- B で外す、X で兵士を選ぶ(カーソルもそこへ)
            press("b")
            check(#G.sel == 0, "cursor: B で選択を外す")
            press("x")
            local s = S.list[1]
            check(G.sel[1] == s and C.x == math.floor(s.x) and C.z == math.floor(s.z), "cursor: X で兵士を選びカーソルもそこへ")
            -- カーソルの所へ動かす
            local b = G.base
            G.moved = false
            C.place(b.x - 3, b.z + 3)
            press("a")
            check(G.moved and s.px == b.x - 2.5 and s.pz == b.z + 3.5, "cursor: A で選んだ兵士をカーソルの所へ")
            -- 兵士の所で A を押すと選ぶ(もう一度で外す)
            press("b")
            C.place(s.x, s.z)
            press("a")
            check(G.sel[1] == s, "cursor: 兵士の所で A を押すと選ぶ")
            press("a")
            check(#G.sel == 0, "cursor: もう一度で外す")
            -- 建設: 下の欄の「建設」→ 弓塔 → カーソルの所へ
            press("select"); press("right"); press("a")
            check(ui.menu_active(), "cursor: 建設のメニュー")
            press("a")
            check(G.build_mode == "arrow" and not ui.focus, "cursor: 弓塔を選ぶと建てる所を選ぶ")
            local bx, bz = b.x, b.z + 6
            while not B.can_place("arrow", bx, bz, G.S_STAND) do bx = bx + 1 end
            C.place(bx, bz)
            local money = G.money
            press("a")
            check(B.count() == 1 and G.bsel == B.list[1] and G.money < money and not G.build_mode, "cursor: A で建てる")
            press("b")
            press("y")
            check(G.bsel == B.list[1] and C.x == bx and C.z == bz, "cursor: Y で建物を選ぶ")
            press("b")
            -- メニューは B でやめる
            ui.press(ui.buttons[6])
            check(ui.menu_active(), "ui: 他のメニュー")
            press("down"); press("b")
            check(not ui.menu_active() and #G.sel == 0, "cursor: B でメニューをやめる")
            -- タップ: 枠の外はやめる、項目は選ぶ
            local got = nil
            ui.menu("t", { "a", "b" }, function(i) got = i end, function() got = "cancel" end)
            ui.menu_tap(0, 0)
            check(got == "cancel", "ui.menu_tap: 枠の外はやめる")
            ui.menu("t", { "a", "b" }, function(i) got = i end)
            local VX, VY, VW, VH = pico.get_rect(G.view)
            local h = 26 + 2 * 26 + 4
            ui.menu_tap(VX + VW // 2, VY + (VH - h) // 2 + 26 + 26 + 5)
            check(got == 2, "ui.menu_tap: 項目を選ぶ (" .. tostring(got) .. ")")
            -- カメラが付いてくる
            local ox, oy = E.origin()
            for _ = 1, 12 do press("up") end
            local ox2, oy2 = E.origin()
            check(ox2 ~= ox or oy2 ~= oy, "cursor: 端に近づくとカメラが動く")
            local sx, sy = pico.iso.to_screen(C.x + 0.5, pico.iso.ground(C.x, C.z), C.z + 0.5)
            check(sx >= VX and sx < VX + VW and sy >= VY and sy < VY + VH, "cursor: カーソルは画面の中")
            -- キーボード
            x = C.x
            check(C.key("up", {}) and C.x == x + 1, "cursor.key: 矢印でカーソル")
            G.build_mode = "wall"
            check(C.key("escape", {}) and not G.build_mode, "cursor.key: Esc で建設をやめる")
            check(C.key("tab", {}) and ui.focus, "cursor.key: Tab で下の欄へ")
            check(C.key("escape", {}) and not ui.focus, "cursor.key: Esc で地図へ")
            check(not C.key("q", {}), "cursor.key: 知らないキーは取らない")
            -- START で次へ
            press("start")
            loop(16)   -- ゲームの計算は33msごと(SIM_MS)なので、次の計算まで進める
            check(E.waves.phase == "wave", "cursor: START で次へ")
        )LUA", "cur");
        check(ok, "game: コントローラーのカーソル");
    }


    WidgetFunctions::ClearSceneWidgets();
    printf("\n%s (failures=%d)\n", failures == 0 ? "ALL PASSED" : "FAILED", failures);
    return failures == 0 ? 0 : 1;
}
