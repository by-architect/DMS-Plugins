import QtQuick
import QtTest
import "../phone.js" as Phone

// Reading remote.sh's output. The lines are real ones from an Android 16
// phone (LineageOS, one SIM in the second slot), with the notification texts
// made up.
TestCase {
    name: "Phone"

    function sec(y, mo, d, h) {
        return Math.floor(new Date(y, mo, d, h || 0, 0, 0).getTime() / 1000);
    }

    // 5 Nov 2026, 01:00 here.
    readonly property real now: new Date(2026, 10, 5, 1, 0, 0).getTime()

    function probe() {
        const T = "\t";
        return ["login banner, ignored", "ps:begin 1", "ps:now 1793832035", "ps:prop model M2007J20CG", "ps:prop manufacturer Xiaomi", "ps:prop android 16", "ps:prop rom ", "ps:uptime 7696.22", "ps:has mpv", "ps:root 1",
            // dumpsys battery
            "ps:battery Current Battery Service state:", "ps:battery AC powered: false", "ps:battery USB powered: true", "ps:battery Wireless powered: false", "ps:battery status: 2", "ps:battery health: 2", "ps:battery level: 57", "ps:battery scale: 100", "ps:battery voltage: 4183", "ps:battery temperature: 322", "ps:battery Maximum capacity: 4656000", "ps:battery Design capacity: 5216000",
            //
            "ps:prop gsm.operator.alpha ,Turkcell", "ps:prop gsm.network.type Unknown,LTE", "ps:prop gsm.sim.state ABSENT,LOADED", "ps:prop gsm.operator.isroaming false,false", "ps:setting airplane 0", "ps:setting zen 1", "ps:setting ringer 1",
            // telephony.registry
            "ps:tel Phone Id=0", "ps:tel mServiceState={mVoiceRegState=1(OUT_OF_SERVICE), mDataRegState=1(OUT_OF_SERVICE), mChannelNumber=-1, mOperatorAlphaLong=, mOperatorAlphaShort=, getRilVoiceRadioTechnology=0(Unknown), getRilDataRadioTechnology=0(Unknown)}", "ps:tel mSignalStrength=SignalStrength:{mCdma=CellSignalStrengthCdma: cdmaDbm=2147483647 level=0,mGsm=CellSignalStrengthGsm: rssi=-113 ber=0 mTa=0 mLevel=0,mWcdma=CellSignalStrengthWcdma: ss=-113 ber=0 rscp=-120 ecno=-24 level=0,mLte=CellSignalStrengthLte: rssi=-113 rsrp=2147483647 rsrq=0 rssnr=0 cqiTableIndex=2147483647 cqi=0 ta=0 level=1 parametersUseForLevel=0,mNr=CellSignalStrengthNr:{ csiRsrp = 2147483647 ssRsrp = 2147483647 ssRsrq = 0 ssSinr = 0 level = 0 parametersUseForLevel = 0 timingAdvance = 2147483647 },primary=CellSignalStrengthLte}", "ps:tel mDataConnectionState=-1", "ps:tel Phone Id=1", "ps:tel mServiceState={mVoiceRegState=0(IN_SERVICE), mDataRegState=0(IN_SERVICE), mChannelNumber=100, duplexMode()=1, mCellBandwidths=[20000], mOperatorAlphaLong=Turkcell, mOperatorAlphaShort=Turkcell, isManualNetworkSelection=false(automatic), getRilVoiceRadioTechnology=14(LTE), getRilDataRadioTechnology=14(LTE), mNetworkRegistrationInfos=[NetworkRegistrationInfo{ domain=PS transportType=WWAN registrationState=HOME roamingType=NOT_ROAMING accessNetworkTechnology=LTE}]}", "ps:tel mSignalStrength=SignalStrength:{mCdma=CellSignalStrengthCdma: cdmaDbm=2147483647 level=0,mGsm=CellSignalStrengthGsm: rssi=2147483647 ber=2147483647 mTa=2147483647 mLevel=0,mWcdma=CellSignalStrengthWcdma: ss=2147483647 ber=2147483647 rscp=2147483647 ecno=2147483647 level=0,mLte=CellSignalStrengthLte: rssi=-59 rsrp=-87 rsrq=-11 rssnr=15 cqiTableIndex=2147483647 cqi=2147483647 ta=2147483647 level=4 parametersUseForLevel=0,mNr=CellSignalStrengthNr:{ csiRsrp = 2147483647 ssRsrp = 2147483647 ssRsrq = 2147483647 ssSinr = 2147483647 level = 0 parametersUseForLevel = 0 timingAdvance = 2147483647 },primary=CellSignalStrengthLte}", "ps:tel mDataConnectionState=2", "ps:tel mActiveDataSubId=1",
            //
            "ps:wifi Wifi is enabled", "ps:wifi Wifi is connected to \"Home\"", "ps:wifi WifiInfo: SSID: \"Home\", BSSID: aa:bb:cc:dd:ee:ff, RSSI: -61, Link speed: 433Mbps", "ps:tether wlan1 2", "ps:df /dev/block/dm-40 109916044 43152312  66763732  40% /dev/seraph-view-4009/run",
            "ps:policy NetworkPolicy{template=NetworkTemplate: matchRule=CARRIER, matchSubscriberIds=[286016...], matchWifiNetworkKeys=[], metered=YES cycleRule=RecurrenceRule{start=2025-01-26T00:00+03:00[Europe/Istanbul] end=null period=P1M} warningBytes=2147483648 limitBytes=-1 lastWarningSnooze=1793032798917 lastLimitSnooze=-1 lastRapidSnooze=-1 metered=true inferred=false}",
            // the counter: before the cycle, its first hour, and today
            "ps:data " + sec(2026, 9, 25, 23) + " 5000000000 1000000000", "ps:data " + sec(2026, 9, 26, 0) + " 1000000000 500000000", "ps:data " + sec(2026, 10, 1, 12) + " 2000000000 0", "ps:data " + sec(2026, 10, 5, 0) + " 300000000 200000000",
            // notifications: pkg when flags category title text subText bigText
            ["ps:notif", "io.element.android.x", "1793825871329", "SHOW_LIGHTS|ONLY_ALERT_ONCE|GROUP_SUMMARY", "msg", "", "", "", ""].join(T), ["ps:notif", "io.element.android.x", "1793825871329", "SHOW_LIGHTS|AUTO_CANCEL", "msg", "Ada", "are you coming?", "", ""].join(T), ["ps:notif", "com.termux", "1793824666644", "ONGOING_EVENT|NO_CLEAR|FOREGROUND_SERVICE", "", "Termux", "1 session", "", ""].join(T), ["ps:notif", "dev.seraph.manager", "1793831714000", "AUTO_CANCEL", "", "Backup finished", "", "", "2 apps backed up"].join(T), ["ps:notif", "android", "1793800000000", "AUTO_CANCEL", "", "null", "null", "", ""].join(T),
            // media sessions
            ["ps:media", "com.android.server.telecom", "false", "null", ""].join(T), ["ps:media", "org.videolan.vlc", "true", "PlaybackState {state=PLAYING(3)", "Song, Singer, Album"].join(T),
            //
            "ps:photo /data/media/0/DCIM/Camera/2026-11-04-15-28-33-921.jpg", "ps:photo /data/media/0/Pictures/Screenshots/Screenshot_20261104-125623_Seraph.png", "ps:end", ""].join("\n");
    }

    function test_basics() {
        const r = Phone.parseProbe(probe(), now);
        verify(r.begun && r.complete && r.root);
        compare(r.props.model, "M2007J20CG");
        compare(r.props.android, "16");
        verify(r.hasMpv);
        compare(r.photos.length, 2);
    }

    function test_battery() {
        const b = Phone.parseProbe(probe(), now).battery;
        compare(b.level, 57);
        compare(b.state, "charging");
        compare(b.plugged, "USB");
        compare(b.tempC, 32.2);
        compare(b.health, "good");
        compare(b.wear, 89, "4656000 of 5216000");
        compare(Phone.batteryIcon(b), "battery_charging_full");
        compare(Phone.batteryIcon({
            level: 50,
            state: "on battery",
            plugged: ""
        }), "battery_4_bar");
    }

    function test_signal() {
        const c = Phone.parseProbe(probe(), now).cell;
        compare(c.operator, "Turkcell", "from the slot in service, not the empty first one");
        compare(c.rat, "LTE");
        compare(c.level, 4);
        compare(c.dbm, -87);
        verify(c.inService && c.dataConnected && !c.roaming && !c.noSim);
        compare(Phone.signalIcon(c, false), "signal_cellular_4_bar");
        compare(Phone.signalIcon(c, true), "airplanemode_active");
    }

    function test_noSim() {
        const c = Phone.parseTelephony([], {
            "gsm.sim.state": "ABSENT,ABSENT"
        });
        verify(c.noSim && !c.inService);
        compare(Phone.signalIcon(c, false), "signal_cellular_nodata");
    }

    function test_wifiHotspotStorage() {
        const r = Phone.parseProbe(probe(), now);
        compare(r.wifi.ssid, "Home");
        compare(r.wifi.rssi, -61);
        verify(r.wifi.connected);
        verify(r.hotspot.on);
        compare(r.hotspot.clients, 2);
        compare(Math.round(r.storage.fraction * 100), 39);
        compare(r.settings.zen, "1");
        compare(Phone.parseWifi(["Wifi is disabled"]).enabled, false);
    }

    function test_mobileData() {
        const d = Phone.parseProbe(probe(), now).data;
        compare(d.start, new Date(2026, 9, 26).getTime(), "the cycle starts on the 26th");
        compare(d.end, new Date(2026, 10, 26).getTime());
        compare(d.used, 1500000000 + 2000000000 + 500000000, "the hour before the cycle is left out");
        compare(d.today, 500000000);
        compare(d.warningBytes, 2147483648);
        compare(d.limitBytes, 0);
        verify(d.fromPolicy);
        compare(d.days.length, 11, "26 Oct to 5 Nov");
        compare(d.days[0].bytes, 1500000000);
        compare(Phone.bytesText(d.used), "4.00 GB");
    }

    function test_cycleEdges() {
        const p = {
            day: 31,
            hour: 0,
            minute: 0,
            monthly: true
        };
        const b = Phone.cycleBounds(p, new Date(2026, 2, 5).getTime());
        compare(new Date(b.start).getDate(), 28, "no 31 February: its last day");
        compare(new Date(b.start).getMonth(), 1);
        compare(new Date(b.end).getDate(), 31);
        const none = Phone.cycleBounds(null, new Date(2026, 10, 5, 12).getTime());
        compare(none.start, new Date(2026, 10, 1).getTime(), "no policy: the calendar month");
    }

    function test_notifications() {
        const list = Phone.parseProbe(probe(), now).notifications;
        compare(list.length, 3, "no group summary, nothing empty");
        compare(list[0].app, "Seraph manager", "newest first");
        compare(list[0].text, "2 apps backed up", "the big text when there is no text");
        compare(list[1].app, "Element");
        compare(list[1].title, "Ada");
        verify(!list[1].ongoing);
        verify(list[2].ongoing);
        compare(Phone.appName("io.heckel.ntfy"), "ntfy");
        compare(Phone.appName("com.example.weather_app"), "Weather");
    }

    function test_media() {
        const m = Phone.parseProbe(probe(), now).media;
        compare(m.app, "VLC");
        verify(m.playing);
        compare(m.title, "Song");
        compare(m.artist, "Singer");
        compare(Phone.pickMedia([["com.android.server.telecom", "false", "null", ""]]), null);
    }

    function test_withoutRoot() {
        const r = Phone.parseProbe("ps:begin 1\nps:root 0\nps:sys capacity 80\nps:sys status Discharging\nps:end\n", now);
        verify(!r.root);
        compare(r.battery.level, 80);
        compare(r.battery.state, "on battery");
        compare(r.data, null);
        compare(r.hotspot, null);
    }

    function test_sshFailures() {
        compare(Phone.classify(255, "ssh: connect to host 100.70.50.3 port 2422: Connection refused", false).state, "unreachable");
        compare(Phone.classify(255, "Permission denied (publickey).", false).state, "auth");
        compare(Phone.classify(255, "Host key verification failed.", false).state, "hostkey");
        compare(Phone.classify(-1, "", true).state, "unreachable");
        compare(Phone.parseProbe("", now).begun, false);
    }
}
