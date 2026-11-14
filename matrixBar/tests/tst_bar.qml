import QtQuick
import QtTest
import "../bar.js" as Bar

// What a probe snapshot turns into, and what a failed stream is called.
// Shaped on real runs of scripts/probe.sh on a laptop, a desktop and a
// phone, with the addresses, IDs and names changed.
//
//   qmltestrunner -input tests/tst_bar.qml
TestCase {
    name: "MatrixBar"

    function lines(list) {
        return list.join("\n");
    }

    // A laptop: two CPU and GPU readings a second apart (the first snapshot
    // takes its own), / on LUKS -- df names it /dev/dm-1, the mount table
    // /dev/mapper/luks-… -- /boot, tmpfs, an sshfs mount, and a USB stick.
    readonly property string laptop: lines(["Welcome back!", "mx:begin 0 1", "mx:t 6210.37", "mx:host nebuchadnezzar", "mx:android 0 0", "mx:ncpu 22", "mx:cpu cpu  435944 16806 203009 9323676 3627801 18280 12542 0 0 0", "mx:gpu idle card1 4767771 6210.37", "mx:cpu cpu  435970 16810 203025 9325300 3628418 18281 12544 0 0 0", "mx:gpu idle card1 4768779 6211.42", "mx:mem 15810908 9105620 91422588 87064616", "mx:bat BAT0 64 Charging", "mx:ssh 1 2 1", "mx:sshpeer 100.64.0.2:47048", "mx:sshpeer 100.64.0.9:51000", "mx:sshpeer 100.64.0.2:47100", "mx:jobs", "mx:units", "mx:unit matrix-sync-backup-manager-sync-laptop-music-to-desktop.service activating start", "mx:unit matrix-sync-backup-manager-sync-laptop-pictures-to-desktop.service inactive dead", "mx:unit matrix-sync-backup-manager-sync-phone-sd-to-laptop.service failed failed", "mx:job rsync - matrix-sync-backup-manager-sync-laptop-music-to-desktop", "mx:job rsync 42 to /mnt/stick/films", "mx:mnt /dev/mapper/luks-abc / ext4", "mx:mnt /dev/mapper/luks-abc /nix/store ext4", "mx:mnt /dev/nvme0n1p1 /boot vfat", "mx:mnt tmpfs /run tmpfs", "mx:mnt user@100.64.0.5:/ /run/user/1000/phone fuse.sshfs", "mx:mnt /dev/sdb1 /mnt/stick exfat", "mx:df /dev/dm-1        965203388 700904224 215195764      77% /", "mx:df tmpfs              3952728      8016   3944712       1% /run", "mx:df /dev/nvme0n1p1     1046512     75912    970600       8% /boot", "mx:df /dev/sdb1         60000000  30000000  30000000      50% /mnt/stick", "mx:blk /dev/mapper/luks-abc nvme0n1 0 other", "mx:blk /dev/nvme0n1p1 nvme0n1 0 other", "mx:blk /dev/sdb1 sdb 1 usb", "mx:stfolders", "mx:stfolder docs 0 My Documents", "mx:stfolder code 0 Code", "mx:stdevs", "mx:stdev 1 0", "mx:stdev 0 0", "mx:ststatus docs idle 0 0 0", "mx:ststatus code idle 0 0 1", "mx:end", ""])

    // The same laptop five seconds on: one reading each, and no slow parts.
    readonly property string laptopNext: lines(["mx:begin 1 0", "mx:t 6216.42", "mx:cpu cpu  436070 16810 203125 9325700 3628418 18281 12544 0 0 0", "mx:gpu idle card1 4772779 6216.42", "mx:mem 15810908 7905454 91422588 87064616", "mx:bat BAT0 65 Charging", "mx:ssh 0 1 1", "mx:jobs", "mx:units same", "mx:end"])

    // A phone: root, an LTE SIM in slot 1, on mobile data, a call ringing,
    // two missed calls, an SD card, and a data warning of 50 GB.
    readonly property string phone: lines(["mx:begin 0 1", "mx:t 7939.14", "mx:host localhost", "mx:android 1 1", "mx:ncpu 8", "mx:cpu cpu  139146 73131 246427 2759126 9109 14580 9290 0 0 0", "mx:cpu cpu  139392 73132 246550 2759577 9109 14587 9292 0 0 0", "mx:gpu busy adreno 38", "mx:mem 5691048 1389728 3983728 3181840", "mx:bat battery 78 Discharging", "mx:ssh 0 2 0", "mx:sshpeer 127.0.0.1:44798", "mx:jobs", "mx:job rsync - from another machine", "mx:mnt /dev/block/dm-40 /data f2fs", "mx:mnt /dev/block/vold/public:179,1 /mnt/media_rw/AB12-CD34 exfat", "mx:df /data 109916044 66817264 42967708 - /data", "mx:df /mnt/media_rw/AB12-CD34 250337152 167034752 83302400 - /storage/AB12-CD34", "mx:stpause 1", "mx:stfolders", "mx:stfolder music 0 music", "mx:stdevs", "mx:stdev 0 1", "mx:ststatus music idle 6 2126 0", "mx:prop gsm.operator.alpha ,Carrier", "mx:prop gsm.sim.state ABSENT,LOADED", "mx:prop gsm.operator.isroaming false,false", "mx:tel Phone Id=0", "mx:tel mCallState=0", "mx:tel mServiceState={mVoiceRegState=1(OUT_OF_SERVICE), mDataRegState=1(OUT_OF_SERVICE), mOperatorAlphaLong=null}", "mx:tel mSignalStrength=SignalStrength:{mLte=CellSignalStrengthLte: rssi=2147483647 rsrp=2147483647 level=0, primary=CellSignalStrengthLte}", "mx:tel mDataConnectionState=-1", "mx:tel Phone Id=1", "mx:tel mCallState=1", "mx:tel mServiceState={mVoiceRegState=0(IN_SERVICE), mDataRegState=0(IN_SERVICE), mOperatorAlphaLong=Carrier, getRilVoiceRadioTechnology=14(LTE), getRilDataRadioTechnology=14(LTE), roamingType=NOT_ROAMING}", "mx:tel mSignalStrength=SignalStrength:{mLte=CellSignalStrengthLte: rssi=-71 rsrp=-103 rsrq=-12 level=3, primary=CellSignalStrengthLte}", "mx:tel mDataConnectionState=2", "mx:wifi Wifi is enabled", "mx:uplink rmnet_data2", "mx:setting airplane 0", "mx:missed 2", "mx:policy NetworkPolicy{template=NetworkTemplate: matchRule=CARRIER, metered=YES cycleRule=RecurrenceRule{start=2025-01-10T00:00+03:00[Europe/Istanbul] end=null period=P1M} cycleDay=10 warningBytes=50000000000 limitBytes=-1}", "mx:data " + (nov11s - 7200) + " 1000000000 500000000", "mx:data " + (nov11s - 3600) + " 2000000000 500000000", "mx:end"])

    // 11 Nov 2025 at noon here, the day after the phone's cycle started on
    // the 10th; the data rows are an hour and two before it.
    readonly property real nov11: new Date(2025, 10, 11, 12, 0, 0).getTime()
    readonly property real nov11s: Math.round(nov11 / 1000)

    function test_a_laptop_snapshot() {
        const s = Bar.parseSnapshot(laptop);
        verify(s.begun && s.complete);
        compare(s.seq, 0);
        verify(s.full);
        compare(s.host, "nebuchadnezzar");
        const st = Bar.advance(null, s, Date.now(), {
            "peerNames": {
                "100.64.0.2": "desktop"
            }
        });
        compare(st.ncpu, 22);
        // 2071 jiffies between the readings, 2241 - 618 idle or waiting:
        // (26+4+16+1624+617+1+2) total, 1624+617 idle
        fuzzyCompare(st.cpu, 100 * (2290 - 2241) / 2290, 0.01);
        // 1008 ms asleep in RC6 over 1050 ms
        fuzzyCompare(st.gpu, 100 * (1 - 1008 / 1050), 0.01);
        fuzzyCompare(st.mem.percent, 100 * (15810908 - 9105620) / 15810908, 0.01);
        fuzzyCompare(st.swap.percent, 100 * (91422588 - 87064616) / 91422588, 0.01);
        compare(st.battery.level, 64);
        verify(st.battery.charging);
    }

    // Intel: the programs' own engine counters win over the time awake.
    function test_intel_gpu_from_its_programs() {
        const first = Bar.parseSnapshot(lines(["mx:begin 0 1", "mx:gpu idle card1 1000 100.00", "mx:drm 100.00 7 5000000000 0 0 0 0", "mx:drm 100.00 9 100 0 0 0 0", "mx:gpu idle card1 1500 101.00", "mx:drm 101.00 7 5100000000 0 0 0 0", "mx:drm 101.00 9 100 0 20000000 0 0", "mx:end"]));
        const st = Bar.advance(null, first, Date.now(), {});
        // render: 0.1 s of the second for client 7; video: 0.02 s for 9
        fuzzyCompare(st.gpu, 10, 0.01);
        // a client that was not there the time before adds nothing yet
        const next = Bar.parseSnapshot(lines(["mx:begin 1 0", "mx:gpu idle card1 1600 102.00", "mx:drm 102.00 7 5400000000 0 0 0 0", "mx:drm 102.00 11 900000000 0 0 0 0", "mx:end"]));
        fuzzyCompare(Bar.advance(st, next, Date.now(), {}).gpu, 30, 0.01);
        // no program could be read: 500 ms of 1000 asleep
        const awake = Bar.parseSnapshot(lines(["mx:begin 0 1", "mx:gpu idle card1 1000 100.00", "mx:gpu idle card1 1500 101.00", "mx:end"]));
        fuzzyCompare(Bar.advance(null, awake, Date.now(), {}).gpu, 50, 0.01);
    }

    function test_ssh_leaves_out_the_probes_own_connection() {
        const st = Bar.advance(null, Bar.parseSnapshot(laptop), Date.now(), {
            "peerNames": {
                "100.64.0.2": "desktop"
            }
        });
        // one with a terminal, two without of which one is the probe's own
        compare(st.ssh.total, 2);
        compare(st.ssh.tty, 1);
        // a machine of the matrix by its name, once; the rest by address
        compare(st.ssh.from.join(","), "desktop,100.64.0.9");
    }

    function test_disks_and_what_can_be_pulled_out() {
        const st = Bar.advance(null, Bar.parseSnapshot(laptop), Date.now(), {});
        // "/" found through its mount point although df calls it /dev/dm-1;
        // /boot hidden while it has room; tmpfs and sshfs are not disks
        compare(st.disks.map(d => d.mount).join(","), "/");
        compare(st.disks[0].type, "ext4");
        fuzzyCompare(st.disks[0].percent, 100 * 700904224 / (700904224 + 215195764), 0.01);
        compare(st.removable.length, 1);
        compare(st.removable[0].label, "stick");
        compare(st.removable[0].bus, "usb");
        fuzzyCompare(st.removable[0].percent, 50, 0.01);
    }

    function test_the_next_snapshot_keeps_what_it_did_not_carry() {
        const first = Bar.advance(null, Bar.parseSnapshot(laptop), Date.now(), {});
        const st = Bar.advance(first, Bar.parseSnapshot(laptopNext), Date.now(), {});
        compare(st.snapshots, 2);
        // CPU from the previous snapshot's last reading to this one's
        fuzzyCompare(st.cpu, 100 * (100 + 100) / (100 + 100 + 400), 0.01);
        // 4000 ms asleep over 5000 ms
        fuzzyCompare(st.gpu, 20, 0.01);
        compare(st.battery.level, 65);
        compare(st.ssh.total, 0);
        // storage and Syncthing come every few snapshots: kept meanwhile
        compare(st.disks.length, 1);
        compare(st.removable.length, 1);
        compare(st.sync.state, "idle");
        // the units are as before ("same"); no rsync process runs any more,
        // but the unit still starts
        compare(st.rsync.configured, 3);
        compare(st.rsync.count, 1);
        compare(st.rsync.failed.join(), "phone-sd-to-laptop");
    }

    function test_syncthing() {
        const st = Bar.advance(null, Bar.parseSnapshot(laptop), Date.now(), {});
        // a file that failed to sync leaves the folder idle, counted
        compare(st.sync.state, "idle");
        compare(st.sync.folders, 2);
        compare(Bar.syncTip(st).split("\n")[1], "2 folders · 1 of 2 devices connected");
        compare(st.sync.failedItems, 1);
        compare(st.sync.connected, 1);
        compare(st.sync.devices, 2);
        compare(Bar.syncIcon(st.sync), "check");

        const raw = Bar.emptySyncRaw();
        raw.folders = [{
                "id": "a",
                "label": "A"
            }, {
                "id": "b",
                "label": "B",
                "paused": true
            }];
        raw.status = {
            "a": {
                "state": "syncing",
                "needFiles": 3
            }
        };
        compare(Bar.syncState(raw).state, "working");
        compare(Bar.syncState(raw).busy.join(), "A");

        raw.status.a.state = "error";
        compare(Bar.syncState(raw).state, "error");

        // every folder paused
        raw.folders[0].paused = true;
        compare(Bar.syncState(raw).state, "paused");

        // `matrix sync pause`: the unit does not even start
        const off = Bar.emptySyncRaw();
        off.running = false;
        compare(Bar.syncState(off).state, "off");
        off.pauseFile = true;
        compare(Bar.syncState(off).state, "paused");

        // running but its API did not answer
        compare(Bar.syncState(Bar.emptySyncRaw()).state, "unknown");
    }

    // syncthing-guard on mobile data: the relays off, each device let in
    // only from the machine's own networks. The phone's real answer, on
    // mobile data with Wi-Fi off: nothing connected, so paused.
    function test_syncthing_on_mobile_data() {
        const mobile = Bar.parseSnapshot(lines(["mx:begin 0 1", "mx:stfolders", "mx:stfolder music 0 music", "mx:stfolder obsidian 0 obsidian", "mx:stdevs", "mx:stdev 0 0", "mx:stdev 0 0", "mx:stdev 0 0", "mx:stlimit 0 169.254.52.55/30", "mx:ststatus music idle 0 0 0", "mx:ststatus obsidian idle 6 2126 6", "mx:end"]));
        compare(mobile.sync.state, "paused");
        compare(mobile.sync.why, "mobile");
        verify(mobile.sync.mobile);
        compare(Bar.syncIcon(mobile.sync), "pause");
        const tip = Bar.syncTip({
            "sync": mobile.sync
        }).split("\n");
        compare(tip[0], "Syncthing paused on mobile data");
        compare(tip[1], "syncs only with machines within 169.254.52.55/30");

        // a laptop on its hotspot is connected: that syncs, so not paused
        const local = Bar.parseSnapshot(lines(["mx:begin 0 1", "mx:stfolders", "mx:stfolder music 0 music", "mx:stdevs", "mx:stdev 1 0", "mx:stdev 0 0", "mx:stlimit 0 192.168.43.1/24", "mx:ststatus music syncing 3 100 0", "mx:end"]));
        compare(local.sync.state, "working");
        verify(local.sync.mobile);
        compare(Bar.syncTip({
            "sync": local.sync
        }).split("\n")[1], "On mobile data: syncs only with machines within 192.168.43.1/24");

        // no local network at all: every device paused
        const none = Bar.parseSnapshot(lines(["mx:begin 0 1", "mx:stfolders", "mx:stfolder music 0 music", "mx:stdevs", "mx:stdev 0 1", "mx:stdev 0 1", "mx:stlimit 0 -", "mx:ststatus music idle 0 0 0", "mx:end"]));
        compare(none.sync.why, "mobile");
        compare(Bar.syncTip({
            "sync": none.sync
        }).split("\n")[1], "no local network to sync on");

        // off mobile data: the relays on, every network allowed
        const home = Bar.parseSnapshot(lines(["mx:begin 0 1", "mx:stfolders", "mx:stfolder music 0 music", "mx:stdevs", "mx:stdev 0 0", "mx:stlimit 1 -", "mx:ststatus music idle 0 0 0", "mx:end"]));
        compare(home.sync.state, "idle");
        verify(!home.sync.mobile);
    }

    // A pair whose last run was skipped for a pause or mobile data is paused
    // -- on its own machine, and on the machine it waits for -- while that
    // machine is still paused or on mobile data.
    function test_paused_pairs() {
        const laptopSnap = Bar.parseSnapshot(lines(["mx:begin 0 1", "mx:jobs", "mx:units", "mx:unit matrix-sync-backup-manager-sync-laptop-music-to-desktop.service inactive dead", "mx:unit matrix-sync-backup-manager-sync-phone-sd-to-laptop.service inactive dead", "mx:unit matrix-sync-backup-manager-backup-docs.service inactive dead", "mx:skips", "mx:skip rsync pause laptop laptop-music-to-desktop", "mx:skip rsync mobile phone phone-sd-to-laptop", "mx:skip rsync mobile phone phone-gone-to-laptop", "mx:skip backup pause laptop docs", "mx:metered no", "mx:end"]));
        const lap = Bar.advance(null, laptopSnap, nov11, {});
        verify(lap.metered === false);
        // a skip of a pair no longer configured is left out
        compare(lap.rsync.paused.map(p => p.name).join(), "laptop-music-to-desktop,phone-sd-to-laptop");
        compare(lap.backup.paused.length, 1);

        // the next snapshot carries no skips: kept
        const lap2 = Bar.advance(lap, Bar.parseSnapshot(lines(["mx:begin 1 0", "mx:jobs", "mx:units same", "mx:end"])), nov11, {});
        compare(lap2.rsync.paused.length, 2);
        // one of them runs now: not paused
        const lap3 = Bar.advance(lap2, Bar.parseSnapshot(lines(["mx:begin 2 0", "mx:jobs", "mx:units same", "mx:job rsync - matrix-sync-backup-manager-sync-phone-sd-to-laptop", "mx:end"])), nov11, {});
        compare(lap3.rsync.paused.map(p => p.name).join(), "laptop-music-to-desktop");

        const phoneSt = Bar.advance(null, Bar.parseSnapshot(phone), nov11, {});
        const results = {
            "laptop": {
                "state": "online",
                "stats": lap
            },
            "phone": {
                "state": "online",
                "stats": phoneSt
            }
        };
        // the laptop is not on mobile data, but its pause file is not known
        // (no Syncthing answer in this snapshot); the phone is on mobile data
        const conds = Bar.hostConditions(results);
        verify(conds.laptop.mobile === false);
        verify(conds.phone.mobile === true);
        compare(Bar.pausedJobs("laptop", "rsync", results, conds).length, 2);
        const onPhone = Bar.pausedJobs("phone", "rsync", results, conds);
        compare(onPhone.length, 1);
        compare(onPhone[0].on, "laptop");
        compare(Bar.jobTip(phoneSt.rsync, "rsync", "pair", onPhone, "phone").split("\n")[2], "paused while phone is on mobile data: phone-sd-to-laptop (on laptop)");
        compare(Bar.jobTip(lap.rsync, "rsync", "pair", Bar.pausedJobs("laptop", "rsync", results, conds), "laptop").split("\n")[1], "paused by matrix sync pause on laptop: laptop-music-to-desktop");

        // the phone back on Wi-Fi: its pair is not shown paused any more
        conds.phone.mobile = false;
        compare(Bar.pausedJobs("phone", "rsync", results, conds).length, 0);
        // the laptop resumed
        conds.laptop.pause = false;
        compare(Bar.pausedJobs("laptop", "rsync", results, conds).length, 0);
    }

    function test_rsync_and_backups() {
        const st = Bar.advance(null, Bar.parseSnapshot(laptop), Date.now(), {});
        // the running unit and its own rsync are one job; the rsync run by
        // hand (fct knows its progress) is another
        compare(st.rsync.configured, 3);
        compare(st.rsync.count, 2);
        compare(st.rsync.names.join(","), "laptop-music-to-desktop,to /mnt/stick/films");
        compare(st.rsync.failed.join(), "phone-sd-to-laptop");
        // progress only when every running job has one
        compare(st.rsync.percent, -1);
        compare(st.backup.count, 0);
        compare(st.backup.configured, 0);

        const jobs = {
            "units": [{
                    "unit": "matrix-sync-backup-manager-backup-docs.service",
                    "active": "activating",
                    "sub": "auto-restart"
                }],
            "running": [{
                    "kind": "rsync",
                    "percent": 40,
                    "name": "rsync"
                }]
        };
        const b = Bar.jobSummary(jobs, "backup");
        compare(b.count, 0);
        compare(b.retrying.join(), "docs");
        const r = Bar.jobSummary(jobs, "rsync");
        compare(r.count, 1);
        compare(r.percent, 40);
    }

    function test_a_phone() {
        const s = Bar.parseSnapshot(phone);
        const st = Bar.advance(null, s, nov11, {
            "dataAllowanceBytes": 0
        });
        verify(st.android && st.root);
        compare(st.gpu, 38);
        compare(st.battery.level, 78);
        compare(st.battery.status, "on battery");
        // internal storage is /data; the SD card is known from vold's name
        compare(st.disks.length, 1);
        compare(st.disks[0].label, "Internal");
        compare(st.removable.length, 1);
        compare(st.removable[0].label, "SD card");
        compare(st.removable[0].mount, "/storage/AB12-CD34");
        compare(st.removable[0].type, "exfat");
        fuzzyCompare(st.removable[0].percent, 100 * 167034752 / (167034752 + 83302400), 0.01);
        // the slot in service, the call ringing in it
        compare(st.cell.operator, "Carrier");
        compare(st.cell.rat, "LTE");
        compare(st.cell.level, 3);
        compare(st.cell.dbm, -103);
        compare(st.call, "ringing");
        compare(st.missed, 2);
        // the route says mobile data, whatever Wi-Fi is up to
        compare(st.net, "mobile");
        compare(Bar.networkIcon(st), "lte_mobiledata");
        compare(Bar.signalIcon(st.cell, st.airplane), "signal_cellular_3_bar");
        compare(Bar.callIcon(st.call), "ring_volume");
        // paused by `matrix sync pause` on the phone
        compare(st.sync.state, "paused");
        // the far end of a computer's rsync
        compare(st.rsync.count, 1);
        compare(st.rsync.names.join(), "from another machine");
    }

    function test_the_switches() {
        // on mobile data, Wi-Fi on but not joined, no hotspot yet
        const st = Bar.advance(null, Bar.parseSnapshot(phone.replace("mx:setting airplane 0", "mx:setting airplane 0\nmx:setting data 1\nmx:tether \nmx:prop ro.serialno 56853bd8")), nov11, {});
        compare(st.serial, "56853bd8");
        compare(Bar.switchState(st, "wifi"), true);
        compare(Bar.switchState(st, "data"), true);
        compare(Bar.switchState(st, "hotspot"), false);
        compare(Bar.switchIcon("hotspot", false), "portable_wifi_off");
        // mobile data carries the bar's connection and Wi-Fi has no network
        verify(Bar.switchRisk(st, "data", false) !== "");
        compare(Bar.switchRisk(st, "wifi", false), "");
        compare(Bar.switchRisk(st, "data", true), "");
        verify(Bar.switchTip(st, "data", null, "").indexOf("Mobile data: on") === 0);
        compare(Bar.switchTip(st, "hotspot", {
            "want": true,
            "error": ""
        }, ""), "Switching Hotspot on…");

        // the hotspot comes on; a snapshot without the switches keeps them
        const next = Bar.advance(st, Bar.parseSnapshot(lines(["mx:begin 1 0", "mx:tether wlan1 ", "mx:end"])), nov11 + 15000, {});
        compare(Bar.switchState(next, "hotspot"), true);
        compare(next.hotspot.ifaces.join(), "wlan1");
        compare(Bar.switchState(next, "data"), true);
        compare(next.serial, "56853bd8");
        // a USB tether is not the hotspot
        const usb = Bar.advance(st, Bar.parseSnapshot(lines(["mx:begin 1 0", "mx:tether rndis0", "mx:end"])), nov11 + 15000, {});
        compare(Bar.switchState(usb, "hotspot"), false);
    }

    function test_mobile_data_this_cycle() {
        const st = Bar.advance(null, Bar.parseSnapshot(phone), nov11, {
            "dataAllowanceBytes": 0
        });
        // both rows are in the cycle that began on the 10th
        compare(st.data.used, 4000000000);
        compare(st.data.ofWhat, "warning");
        fuzzyCompare(st.data.percent, 8, 0.01);
        compare(new Date(st.data.start).getDate(), 10);

        // no limit and no warning: the allowance from the settings, else none
        const rows = [{
                "st": nov11 / 1000 - 3600,
                "rx": 1e9,
                "tx": 1e9
            }];
        const none = Bar.dataUsage(rows, null, nov11, 0);
        compare(none.percent, -1);
        const allowed = Bar.dataUsage(rows, null, nov11, 10e9);
        compare(allowed.ofWhat, "allowance");
        fuzzyCompare(allowed.percent, 20, 0.01);
    }

    function test_network_kind() {
        compare(Bar.networkKind(null, null, false, "wlan0"), "wifi");
        compare(Bar.networkKind(null, null, false, "rmnet_data1"), "mobile");
        compare(Bar.networkKind(null, null, true, ""), "airplane");
        compare(Bar.networkKind(null, null, false, ""), "none");
        // no `ip` there: what Wi-Fi and the modem say
        compare(Bar.networkKind({
            "connected": true
        }, null, false, null), "wifi");
        compare(Bar.networkKind(null, {
            "dataConnected": true
        }, false, null), "mobile");
    }

    function test_why_a_stream_ended() {
        compare(Bar.classifyExit(255, "ssh: connect to host 100.64.0.5 port 2422: Connection timed out", false).state, "unreachable");
        compare(Bar.classifyExit(255, "user@100.64.0.5: Permission denied (publickey).", false).state, "auth");
        verify(Bar.holdsUntilManual("auth"));
        compare(Bar.classifyExit(255, "Host key verification failed.", false).state, "hostkey");
        compare(Bar.classifyExit(91, "", false).detail, "ssh is not installed on this machine");
        // it had been sending snapshots: the connection went
        compare(Bar.classifyExit(255, "", true).state, "unreachable");
    }

    function test_labels() {
        compare(Bar.pctLabel(29.6), "30");
        compare(Bar.pctLabel(-1), "–");
        compare(Bar.shortName("nebuchadnezzar"), "NEB");
        compare(Bar.shortName("mjölnir"), "MJL");
        compare(Bar.peerHost("[fd7a::1]:22"), "fd7a::1");
        compare(Bar.peerHost("100.64.0.2:47048"), "100.64.0.2");
    }
}
