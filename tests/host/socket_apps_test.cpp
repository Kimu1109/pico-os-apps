// 通信を使う標準のLuaアプリ(MQTTリモコン・HAパネル・UDPツール)を、本物の main.lua のまま
// pico-os の LuaEngine と 127.0.0.1 に立てた偽物の相手(pico-os の script/host_test/socket_fake_servers.hpp)の上で動かす。
//
//   MQTTリモコン … retain の状態が届く・点け消しを送る・遺言と online/offline・戻ると DISCONNECT
//   HAパネル     … 偽物の Home Assistant(FakeHaServer)へ WebSocket で繋ぐ
//   UDPツール    … UDP の echo へ向けて送受信・Wake on LAN のマジックパケット
//
// pico-os のホストテスト(script/host_test/CMakeLists.txt の lua-apps グループ)が作って回す。
// 引数は pico-os のルートと、このリポジトリのルート。pico.socket そのもののテストは pico-os の lua_socket_test。
// (2026-11-07 に pico-os の lua_socket_test.cpp から移した)
#include "lua/LuaEngine.hpp"
#include "system/Log_Functions.hpp"
#include "gui/core/GFX_Functions.hpp"
#include "gui/core/Keyboard_Functions.hpp"
#include "gui/widgets/interfaces/ITextInputTarget.hpp"
#include "gui/widgets/Widget.hpp"
#include "gui/core/Widget_Functions.hpp"
#include "net/Mqtt_Client.hpp"
#include "OS_Data.hpp"
#include "socket_fake_servers.hpp"

#include <Arduino.h>
#include <cstdarg>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <sstream>
#include <string>

// ---- モック(lua_ext_test.cppと同じ方針) ----
void PICO_GFX::MarkDirty(const Rect&){}
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

static int failures = 0;
static void check(bool cond, const char* label){
    printf("%s %s\n", cond ? "[ OK ]" : "[FAIL]", label);
    if(!cond) failures++;
}
static int l_check(lua_State* L){
    const bool cond = lua_toboolean(L, 1);
    const char* label = luaL_optstring(L, 2, "(no label)");
    printf("%s %s\n", cond ? "[ OK ]" : "[FAIL]", label);
    if(!cond) failures++;
    return 0;
}

static void SetInt(LuaEngine& e, const char* name, int v){
    lua_pushinteger(e.raw(), v);
    lua_setglobal(e.raw(), name);
}

static bool GlobalTrue(LuaEngine& e, const char* name){
    lua_getglobal(e.raw(), name);
    const bool v = lua_toboolean(e.raw(), -1);
    lua_pop(e.raw(), 1);
    return v;
}

// ソケットを1回分回して時計を進める(PumpUntil 等の step)
static void PumpOnce(LuaEngine& e){
    e.UpdateSockets();
    PicoHostClock::now += 1;
    usleep(200);
}

// 偽物の相手(別スレッド)が s を記録するまで待つ。こちらが送っただけで返事の無いもの
// (DISCONNECT・QoS 0 等)は、こちらの都合では相手が読み終えた時を知れないので、すぐには見ない
static bool WaitSaw(FakeServers::Base& srv, const std::string& s){
    return FakeServers::WaitUntil([&]{ return srv.saw(s); }, FakeServers::Nap);
}

// 時計を進めつつ、名前の付いたLuaのグローバルが真になるまで回す(上限は壁時計。FakeServers::WaitUntil)
static bool PumpUntil(LuaEngine& e, const char* flag){
    return FakeServers::WaitUntil([&]{ return GlobalTrue(e, flag); }, [&]{ PumpOnce(e); });
}


int main(int argc, char** argv){
    const std::string apps = std::string(argc > 2 ? argv[2] : "../pico-os-apps") + "/apps";
    FakeServers::FakeUdpEcho udp;
    FakeServers::FakeMqttBroker mqtt;
    check(udp.start() && mqtt.start(), "偽物の相手を立てる");

    LuaPermissions net;
    net.network = true;

    // ---- サンプルアプリ「MQTTリモコン」 ----
    {
        // 機器の状態を retain で置いておく(本物の機器が流しておく状態の代わり)
        {
            MqttClient dev;
            MqttClient::Options o;
            o.client_id.assign("device");
            dev.begin(("mqtt://127.0.0.1:" + std::to_string(mqtt.port)).c_str(), o);
            bool sent = false, done = false;
            FakeServers::WaitUntil([&]{ return done; }, [&]{
                MqttClient::Event ev;
                while(dev.poll(ev)){
                    if(ev.type == MqttClient::EventType::Connected){
                        dev.publish("t/light/state", "ON", 2, 0, true);
                        dev.publish("t/fan/state", "{\"state\":\"OFF\"}", 15, 0, true);
                        dev.disconnect();
                        sent = true;
                    }
                    if(ev.type == MqttClient::EventType::Closed) done = true;
                }
                PicoHostClock::now += 1;
                usleep(200);
            });
            check(sent && done, "remote: 機器の状態を retain で置く");
        }

        std::ifstream f(apps + "/mqtt-remote/app/main.lua");
        std::stringstream ss;
        ss << f.rdbuf();
        std::string src = ss.str();
        check(!src.empty(), "remote: main.lua を読む");
        // 末尾へ、ローカル変数を覗く口を足す(reversi_test.lua と同じやり方)
        src += "\nTEST = { toggle = toggle, back = back, online = function() return online end,"
               " state = function(i) return state[i] end, pending = function(i) return pending[i] end,"
               " conn = function() return conn_text end, log = function() return log end }\n";

        OSData::SD_usable = true;   // 設定は store.json(stubs/ のメモリ上のSD)
        LuaEngine e(256 * 1024, net, "/remote");
        lua_register(e.raw(), "check", l_check);
        SetInt(e, "MQTT_PORT", mqtt.port);
        bool ok = e.Run(R"LUA(
            check(pico.store_save({ url = "mqtt://127.0.0.1:" .. MQTT_PORT, user = "u", pass = "p", client_id = "ptest",
                                    devices = { { "照明", "t/light" }, { "扇風機", "t/fan" }, { "テレビ", "t/tv" } } },
                                  { encrypt = true }), "remote: 設定を暗号化して置く")
        )LUA", "remote_cfg");
        check(ok, "remote: 設定の実行");
        ok = e.Run(src.c_str(), "/remote/main.lua");
        check(ok, "remote: main.lua を動かす");
        ok = e.Run(R"LUA(
            check(TEST.conn() == "接続しています…", "remote: 最初は接続しています")
            check(TEST.state(1) == nil, "remote: 状態は届くまで不明")
        )LUA", "remote1");
        check(ok, "remote: 起動直後の確認");
        e.Run("function remote_ready() ready = TEST.online() and TEST.state(1) ~= nil and TEST.state(2) ~= nil end", "fn");
        const bool ready = FakeServers::WaitUntil([&]{
            e.Run("remote_ready()", "poll");
            return GlobalTrue(e, "ready");
        }, [&]{ PumpOnce(e); });
        check(ready, "remote: 繋いで、retain の状態が届く");
        check(WaitSaw(mqtt, "connect:ptest:u:p:ka60:clean:will=pico/remote/ptest/status=offline"), "remote: CONNECT(認証・遺言)");
        check(WaitSaw(mqtt, "sub:t/light/state:1") && WaitSaw(mqtt, "sub:t/tv/state:1"), "remote: 機器ごとに <話題>/state を購読");
        check(WaitSaw(mqtt, "pub:pico/remote/ptest/status:0:retain:online"), "remote: online を retain で置く");
        ok = e.Run(R"LUA(
            check(TEST.state(1) == "ON", "remote: ON がそのまま")
            check(TEST.state(2) == "OFF", 'remote: {"state":"OFF"} の形も読む')
            check(TEST.state(3) == nil, "remote: 流していない機器は不明のまま")
            check(TEST.conn():find("接続中") == 1, "remote: 接続中の表示")
            check(#TEST.log() == 2, "remote: 届いたものの記録")
            TEST.toggle(1)
            check(TEST.pending(1) == true, "remote: 送ったら状態が返るまで待ちの印")
            TEST.toggle(2)
        )LUA", "remote2");
        check(ok, "remote: 点け消しの実行");
        const bool sent = FakeServers::WaitUntil([&]{
            return mqtt.saw("pub:t/light/set:1:OFF") && mqtt.saw("pub:t/fan/set:1:ON");
        }, [&]{ PumpOnce(e); });
        check(sent, "remote: 今の状態の逆を <話題>/set へ QoS 1 で送る");
        const int disc = mqtt.count("disconnect");
        ok = e.Run("TEST.back()", "remote3");
        check(ok, "remote: 戻るの実行");
        for(int i = 0; i < 50; i++){ e.UpdateSockets(); PicoHostClock::now += 1; usleep(200); }
        const bool closed = FakeServers::WaitUntil([&]{ return mqtt.count("disconnect") > disc; }, FakeServers::Nap);
        check(closed, "remote: 戻ると DISCONNECT");
        if(!closed && getenv("LUA_TEST_VERBOSE")){
            std::lock_guard<std::mutex> lk(mqtt.mu);
            for(const auto& l : mqtt.log) fprintf(stderr, "broker: %s\n", l.c_str());
        }
        check(WaitSaw(mqtt, "pub:pico/remote/ptest/status:0:retain:offline"), "remote: 戻る前に offline を置く");
    }

    // ---- サンプルアプリ「HAパネル」(WebSocket) ----
    {
        FakeServers::FakeHaServer ha;
        check(ha.start(), "ha: 偽物のHome Assistantを立てる");
        std::ifstream f(apps + "/ha-panel/app/main.lua");
        std::stringstream ss;
        ss << f.rdbuf();
        std::string src = ss.str();
        check(!src.empty(), "ha: main.lua を読む");
        src += "\nTEST = { toggle = toggle, back = back, authed = function() return authed end,"
               " ent = function(i) return ent[i] end, pending = function(i) return pending[i] end,"
               " conn = function() return conn_text end, log = function() return log end,"
               " retrying = function() return retry_timer ~= nil end, label = label_of }\n";

        // Luaの式が真になるまで回す
        auto until = [](LuaEngine& e, const char* expr) {
            const std::string code = std::string("until_ok = (") + expr + ") and true or false";
            return FakeServers::WaitUntil([&]{
                e.Run(code.c_str(), "until");
                return GlobalTrue(e, "until_ok");
            }, [&]{ PumpOnce(e); });
        };

        OSData::SD_usable = true;
        {
            LuaEngine e(256 * 1024, net, "/hapanel");
            lua_register(e.raw(), "check", l_check);
            SetInt(e, "HA_PORT", ha.port);
            bool ok = e.Run(R"LUA(
                check(pico.store_save({ url = "ws://127.0.0.1:" .. HA_PORT .. "/api/websocket", token = "good",
                                        entities = { { "", "light.living_room" }, { "扇風機", "switch.fan" },
                                                     { "", "sensor.temp" }, { "", "light.missing" } } },
                                      { encrypt = true }), "ha: 設定を暗号化して置く")
            )LUA", "ha_cfg");
            check(ok && e.Run(src.c_str(), "/hapanel/main.lua"), "ha: main.lua を動かす");
            check(until(e, "TEST.authed() and TEST.ent(1).state ~= nil"), "ha: 認証して、今の状態が届く");
            check(WaitSaw(ha, "auth:good"), "ha: トークンを送る");
            check(WaitSaw(ha, "sub:[\"light.living_room\",\"switch.fan\",\"sensor.temp\",\"light.missing\"]"),
                  "ha: 設定したエンティティだけを subscribe_entities");
            ok = e.Run(R"LUA(
                check(TEST.conn() == "接続中: HA 2026.10.0", "ha: 接続中の表示に版")
                check(TEST.ent(1).state == "on" and TEST.ent(1).name == "living_room", "ha: 状態と friendly_name")
                check(TEST.label(1) == "ON" and TEST.label(2) == "OFF", "ha: on/off の表示")
                check(TEST.label(3) == "21.5 °C", "ha: センサーは値と単位")
                check(TEST.label(4) == "不明", "ha: 無いエンティティは不明のまま")
                TEST.toggle(1)
                check(TEST.pending(1) ~= nil and TEST.label(1) == "…", "ha: 送ったら返るまで「…」")
                TEST.toggle(3)
                check(TEST.pending(3) == nil, "ha: センサーは点け消ししない")
                TEST.toggle(4)
            )LUA", "ha1");
            check(ok, "ha: 点け消しの実行");
            check(until(e, "TEST.ent(1).state == 'off' and TEST.pending(1) == nil"), "ha: 変わった分(\"c\")で状態が変わる");
            check(WaitSaw(ha, "call:homeassistant.toggle:light.living_room") && !ha.saw("call:homeassistant.toggle:sensor.temp"),
                  "ha: homeassistant.toggle を呼ぶ(センサーには呼ばない)");
            check(until(e, "TEST.pending(4) == nil"), "ha: 失敗の result で「…」を消す");
            ok = e.Run(R"LUA(
                local found_fail, found_change = false, false
                for _, l in ipairs(TEST.log()) do
                    if l == "失敗: Entity not found" then found_fail = true end
                    if l == "light.living_room → off" then found_change = true end
                end
                check(found_fail and found_change, "ha: 変化と失敗を記録に出す")
                TEST.back()
            )LUA", "ha2");
            check(ok, "ha: 戻るの実行");
            for(int i = 0; i < 50; i++){ e.UpdateSockets(); PicoHostClock::now += 1; usleep(200); }
            check(WaitSaw(ha, "close"), "ha: 戻ると close を送る");
        }
        {
            LuaEngine e(256 * 1024, net, "/hapanel2");
            lua_register(e.raw(), "check", l_check);
            SetInt(e, "HA_PORT", ha.port);
            e.Run(R"LUA(
                pico.store_save({ url = "ws://127.0.0.1:" .. HA_PORT .. "/api/websocket", token = "wrong",
                                  entities = { { "", "switch.fan" } } }, { encrypt = true })
            )LUA", "ha_cfg2");
            check(e.Run(src.c_str(), "/hapanel2/main.lua"), "ha: 違うトークンで動かす");
            check(until(e, "TEST.conn():find('トークンが違います') == 1 and pico.socket.state(1) == nil"),
                  "ha: auth_invalid で閉じてトークンが違うと出す");
            check(until(e, "not TEST.retrying()"), "ha: トークンが違うときは繋ぎ直さない");
        }
        ha.stop();
    }

    // ---- サンプルアプリ「UDPツール」 ----
    {
        std::ifstream f(apps + "/udp-tool/app/main.lua");
        std::stringstream ss;
        ss << f.rdbuf();
        std::string src = ss.str();
        check(!src.empty(), "udp-tool: main.lua を読む");
        src += "\nTEST = { send = send_text, wake = wake, log = function() return log end,"
               " status = function() return status end, show = show, mac = parse_mac, split = split_target,"
               " retarget = function(t) cfg.target = t end }\n";

        OSData::SD_usable = true;
        LuaEngine e(256 * 1024, net, "/udptool");
        lua_register(e.raw(), "check", l_check);
        SetInt(e, "UDP_PORT", udp.port);
        bool ok = e.Run(R"LUA(
            local to = "127.0.0.1:" .. UDP_PORT
            check(pico.store_save({ target = to, wol_addr = to, local_port = 0,
                                    wol = { { "居間のPC", "00:11:22:33:44:55" } } }), "udp-tool: 設定を置く")
        )LUA", "udp_cfg");
        check(ok && e.Run(src.c_str(), "/udptool/main.lua"), "udp-tool: main.lua を動かす");
        ok = e.Run(R"LUA(
            check(TEST.status() == "待ち受け: 返事だけ受ける", "udp-tool: 空いている番号で待つ")
            check(TEST.show("a\nb") == "a\\nb", "udp-tool: 改行は \\n で見せる")
            check(TEST.show("\0\1\255") == "[3B] 00 01 FF ", "udp-tool: 読めないものは16進")
            check(#TEST.mac("aa-bb-cc-dd-ee-ff") == 6 and TEST.mac("AABBCCDDEEFF") ~= nil, "udp-tool: MACの書き方")
            check(TEST.mac("00:11:22:33:44") == nil and TEST.mac("zz:11:22:33:44:55") == nil, "udp-tool: 違うMACは読まない")
            check(TEST.split("h:0") == nil and TEST.split("nohost") == nil and TEST.split(" h:9 ") == "h", "udp-tool: 宛先の形")
            check(TEST.send("hello"), "udp-tool: 送る")
            check(TEST.log()[1][1] == "→ hello", "udp-tool: 送ったものを記録")
        )LUA", "udp1");
        check(ok, "udp-tool: 送るの実行");
        auto until = [&e](const char* expr) {
            const std::string code = std::string("until_ok = (") + expr + ") and true or false";
            return FakeServers::WaitUntil([&]{
                e.Run(code.c_str(), "until");
                return GlobalTrue(e, "until_ok");
            }, [&]{ PumpOnce(e); });
        };
        check(until("TEST.log()[1][1] == '← echo:hello'"), "udp-tool: 宛先からの返事を並べる(送り元は省く)");
        check(WaitSaw(udp, "hello"), "udp-tool: 相手に届く");

        ok = e.Run(R"LUA( check(TEST.wake(1), "udp-tool: WoLを送る") )LUA", "udp2");
        check(ok, "udp-tool: WoLの実行");
        std::string magic(6, '\xff');
        for(int i = 0; i < 16; i++) magic += std::string("\x00\x11\x22\x33\x44\x55", 6);
        check(WaitSaw(udp, magic), "udp-tool: マジックパケット(FF×6 + MAC×16 = 102バイト)");
        check(until("TEST.log()[1][1]:find('← [107B] 65 63 68 6F 3A FF', 1, true) == 1"), "udp-tool: 読めない返事は16進で並べる");
        // 宛先と違う相手からのもの(宛先を名前で書いた・別の機器)は送り元を付ける
        ok = e.Run(R"LUA( TEST.retarget("localhost:" .. UDP_PORT) TEST.send("x") )LUA", "udp4");
        check(ok, "udp-tool: 宛先を名前にして送る");
        check(until("TEST.log()[1][1] == '← 127.0.0.1:' .. UDP_PORT .. '  echo:x'"), "udp-tool: 宛先と違う送り元は付ける");
    }

    udp.stop();
    mqtt.stop();
    WidgetFunctions::ClearSceneWidgets();
    printf("\n%s (failures=%d)\n", failures == 0 ? "ALL PASSED" : "FAILED", failures);
    return failures == 0 ? 0 : 1;
}
