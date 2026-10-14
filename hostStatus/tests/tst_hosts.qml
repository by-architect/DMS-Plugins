import QtQuick
import QtTest
import "../hosts.js" as Hosts

// What a probe answer turns into, and what a failed ssh is called.
//
//   qmltestrunner -input tests/tst_hosts.qml
TestCase {
    name: "HostStatus"

    // Trimmed from a real run of scripts/remote.sh, with a chatty .bashrc in
    // front of it.
    readonly property string linuxProbe: ["Welcome back!", "hs:begin 1", "hs:os Linux", "hs:cpu cpu  2981805 1098345 1711476 39268988 10200683 153054 69640 0 0 0", "hs:cpu cpu  2981996 1098394 1711530 39270453 10201126 153059 69644 0 0 0", "hs:ncpu 22", "hs:mem MemTotal:       15810932 kB", "hs:mem MemFree:         2586724 kB", "hs:mem MemAvailable:    6068512 kB", "hs:mem SwapTotal:      17375108 kB", "hs:mem SwapFree:        8687554 kB", "hs:uptime 39952.51 392704.60", "hs:load 8.27 10.71 14.58 3/1831 15", "hs:mnt /dev/mapper/root / ext4 rw,relatime 0 0", "hs:mnt /dev/mapper/root /nix/store ext4 ro,relatime 0 0", "hs:mnt tmpfs /run tmpfs rw 0 0", "hs:mnt /dev/nvme0n1p1 /boot vfat rw 0 0", "hs:mnt overlay /var/lib/docker/overlay2/x/merged overlay rw 0 0", "hs:mnt nas:/tank /mnt/nas nfs4 rw 0 0", "hs:mnt /dev/sdb1 /mnt/My\\040Disk ext4 rw 0 0", "hs:df /dev/mapper/root   965203388 511546656 404553332      56% /", "hs:df /dev/mapper/root   965203388 511546656 404553332      56% /nix/store", "hs:df tmpfs                3952736      7996   3944740       1% /run", "hs:df /dev/nvme0n1p1       1046512     75888    970624       8% /boot", "hs:df overlay            965203388 511546656 404553332      56% /var/lib/docker/overlay2/x/merged", "hs:df nas:/tank          100000000  50000000  50000000      50% /mnt/nas", "hs:df /dev/sdb1           2000000   1900000    100000      95% /mnt/My Disk", "hs:end", ""].join("\n")

    function test_a_linux_answer() {
        const p = Hosts.parseProbe(linuxProbe);
        verify(p.begun && p.complete);
        compare(p.os, "Linux");
        compare(p.ncpu, 22);
        // 2211 jiffies passed between the samples, 1908 of them idle or
        // waiting on I/O: 303 busy
        fuzzyCompare(p.cpuPercent, 13.70, 0.01);
        compare(p.mem.total, 15810932 * 1024);
        compare(p.mem.used, (15810932 - 6068512) * 1024);
        compare(p.swap.used, (17375108 - 8687554) * 1024);
        compare(Math.round(p.uptimeSec), 39953);
        compare(p.load[0], 8.27);
    }

    function test_only_real_filesystems_are_storage() {
        const mounts = Hosts.parseProbe(linuxProbe).filesystems.map(f => f.mount);
        // "/" first; tmpfs, overlay and nfs gone; the bind mount of / folded
        // into it; /boot hidden; a mount point with a space matched through
        // \040.
        compare(mounts.join(","), "/,/mnt/My Disk");
        const disk = Hosts.parseProbe(linuxProbe).filesystems[1];
        compare(disk.type, "ext4");
        compare(disk.label, "");
        fuzzyCompare(disk.percent, 95, 0.01);
    }

    function test_boot_only_when_nearly_full() {
        const probe = pct => Hosts.parseProbe(["hs:begin 1", "hs:mnt /dev/sda2 / ext4 rw 0 0", "hs:mnt /dev/sda1 /boot vfat rw 0 0", "hs:mnt /dev/sda3 /boot/efi vfat rw 0 0", "hs:df /dev/sda2 1000 500 500 50% /", "hs:df /dev/sda1 1000 " + pct + " " + (1000 - pct) + " " + Math.round(pct / 10) + "% /boot", "hs:df /dev/sda3 1000 10 990 1% /boot/efi", "hs:end"].join("\n")).filesystems.map(f => f.mount).join(",");
        compare(probe(95), "/");
        compare(probe(899), "/");
        compare(probe(900), "/,/boot");
        compare(probe(960), "/,/boot");
    }

    // Trimmed from Termux on a phone: the system image at "/", APEX modules,
    // vendor partitions, shared storage, an SD card seen twice and a USB stick.
    readonly property string androidProbe: ["hs:begin 1", "hs:os Linux", "hs:android 1", "hs:ncpu 8", "hs:mem MemTotal:        5662240 kB", "hs:mem MemAvailable:     652000 kB", "hs:mnt /dev/block/dm-6 / erofs ro,seclabel 0 0", "hs:mnt /dev/block/loop1 /apex/com.android.adbd@361099999 ext4 ro,dirsync 0 0", "hs:mnt /dev/block/dm-9 /vendor erofs ro 0 0", "hs:mnt /dev/block/dm-50 /data f2fs rw,lazytime 0 0", "hs:mnt /dev/fuse /storage/emulated fuse rw,lazytime 0 0", "hs:mnt /dev/block/vold/public:179,1 /mnt/media_rw/EF27-E719 exfat rw,dirsync 0 0", "hs:mnt /dev/fuse /storage/EF27-E719 fuse rw 0 0", "hs:mnt /dev/block/vold/public:8,1 /mnt/media_rw/1A2B-3C4D vfat rw 0 0", "hs:mnt /dev/fuse /storage/1A2B-3C4D fuse rw 0 0", "hs:mnt /dev/block/dm-3 /cache ext4 rw 0 0", "hs:df /dev/block/dm-6        1104000  1038000     66000      94% /", "hs:df /dev/block/loop1        11000    11000         0     100% /apex/com.android.adbd@361099999", "hs:df /dev/block/dm-9        900000   900000         0     100% /vendor", "hs:df /dev/fuse           110000000 44000000  66000000      40% /storage/emulated", "hs:df /dev/block/vold/public:179,1 62000000 48000000 14000000 78% /mnt/media_rw/EF27-E719", "hs:df /dev/fuse            62000000 48000000  14000000      78% /storage/EF27-E719", "hs:df /dev/fuse            30000000  3000000  27000000      10% /storage/1A2B-3C4D", "hs:df /dev/block/dm-3        100000        0    100000       0% /cache", "hs:end", ""].join("\n")

    function test_a_phone_shows_internal_storage_and_its_cards() {
        const p = Hosts.parseProbe(androidProbe);
        verify(p.android);
        compare(p.cpuPercent, -1);
        compare(p.ncpu, 8);
        compare(p.filesystems.map(f => f.label + "=" + f.mount).join(","), "Internal=/storage/emulated,USB drive=/storage/1A2B-3C4D,SD card=/storage/EF27-E719");
        fuzzyCompare(p.filesystems[0].percent, 40, 0.01);
        fuzzyCompare(p.filesystems[2].percent, 100 * 48 / 62, 0.01);
    }

    function test_a_phone_without_hs_android_is_still_told_apart() {
        const p = Hosts.parseProbe(androidProbe.replace("hs:android 1\n", ""));
        verify(p.android);
        compare(p.filesystems.length, 3);
    }

    function test_a_phone_with_only_data_and_two_cards() {
        const p = Hosts.parseProbe(["hs:begin 1", "hs:android 1", "hs:df /dev/block/dm-6 1000 900 100 90% /", "hs:df /dev/block/dm-50 100000 40000 60000 40% /data", "hs:df /dev/fuse 5000 1000 4000 20% /storage/AAAA-0001", "hs:df /dev/fuse 6000 1000 5000 17% /storage/BBBB-0002", "hs:df /dev/fuse 6000 1000 5000 17% /storage/self", "hs:end"].join("\n"));
        compare(p.filesystems.map(f => f.label).join(","), "Internal,SD card 1,SD card 2");
        compare(p.filesystems[0].mount, "/data");
    }

    function test_a_root_on_overlay_is_still_shown() {
        const p = Hosts.parseProbe("hs:begin 1\nhs:mnt overlay / overlay rw 0 0\nhs:df overlay 1000 500 500 50% /\nhs:end\n");
        compare(p.filesystems.length, 1);
        compare(p.filesystems[0].mount, "/");
    }

    function test_without_proc_cpu_and_memory_are_unknown() {
        const p = Hosts.parseProbe("hs:begin 1\nhs:os FreeBSD\nhs:df /dev/ada0p2 100 50 50 50% /\nhs:df devfs 1 1 0 100% /dev\nhs:end\n");
        compare(p.cpuPercent, -1);
        compare(p.mem, null);
        compare(p.swap, null);
        compare(p.filesystems.length, 1);
        compare(Hosts.classify({
            code: 0,
            stdout: "hs:begin 1\nhs:end\n",
            stderr: ""
        }).state, "online");
    }

    function test_df_rows_with_spaces() {
        const d = Hosts.parseDfLine("//nas/My Share 100 40 60 40% /mnt/My Share");
        compare(d.device, "//nas/My Share");
        compare(d.mount, "/mnt/My Share");
        compare(d.usedKb, 40);
    }

    function test_what_a_failure_is_called_data() {
        return [
            {
                tag: "key refused",
                run: {
                    code: 255,
                    stderr: "neo@box: Permission denied (publickey,password).\n"
                },
                state: "auth"
            },
            {
                tag: "never connected before",
                run: {
                    code: 255,
                    stderr: "No ED25519 host key is known for box and you have requested strict checking.\r\nHost key verification failed.\r\n"
                },
                state: "hostkey"
            },
            {
                tag: "key changed",
                run: {
                    code: 255,
                    stderr: "@    WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!     @\n"
                },
                state: "hostkey"
            },
            {
                tag: "no such name",
                run: {
                    code: 255,
                    stderr: "ssh: Could not resolve hostname box: Name or service not known\n"
                },
                state: "unreachable"
            },
            {
                tag: "down",
                run: {
                    code: 255,
                    stderr: "ssh: connect to host 10.0.0.9 port 22: Connection timed out\n"
                },
                state: "unreachable"
            },
            {
                tag: "our own deadline",
                run: {
                    code: 15,
                    stderr: "",
                    timedOut: true
                },
                state: "unreachable"
            },
            {
                tag: "no sshpass",
                run: {
                    code: 90,
                    stderr: "",
                    viaSshpass: true
                },
                state: "nopass"
            },
            {
                tag: "no ssh",
                run: {
                    code: 91,
                    stderr: ""
                },
                state: "error"
            },
            {
                tag: "wrong password",
                run: {
                    code: 5,
                    stderr: "",
                    viaSshpass: true
                },
                state: "auth"
            },
            {
                tag: "sshpass met an unknown key",
                run: {
                    code: 6,
                    stderr: "",
                    viaSshpass: true
                },
                state: "hostkey"
            },
            {
                tag: "in, but no sh",
                run: {
                    code: 1,
                    stdout: "This account is currently not available.\n",
                    stderr: ""
                },
                state: "online"
            }
        ];
    }

    function test_what_a_failure_is_called(data) {
        const v = Hosts.classify(Object.assign({
            stdout: "",
            timedOut: false,
            crashed: false,
            viaSshpass: false
        }, data.run));
        compare(v.state, data.state);
        verify(v.detail.length > 0);
        compare(v.stats, null);
    }

    function test_refusals_wait_for_a_manual_refresh() {
        verify(Hosts.holdsUntilManual("auth"));
        verify(Hosts.holdsUntilManual("hostkey"));
        verify(!Hosts.holdsUntilManual("unreachable"));
    }

    function test_the_ssh_argv() {
        const argv = Hosts.probeArgv(["ssh", "-p", "2222", "-i", "/k/id", "neo@box"], Hosts.sshOptions(false), "sh -s");
        compare(argv[0], "ssh");
        verify(argv.indexOf("BatchMode=yes") > 0);
        verify(argv.indexOf("ConnectTimeout=5") > 0);
        // ours first, then sshManager's own flags, then the destination
        verify(argv.indexOf("BatchMode=yes") < argv.indexOf("-p"));
        compare(argv.slice(-3).join(" "), "-- neo@box sh -s");

        const pass = Hosts.sshOptions(true);
        verify(pass.indexOf("BatchMode=no") > 0);
        verify(pass.indexOf("BatchMode=yes") < 0);
        verify(pass.indexOf("NumberOfPasswordPrompts=1") > 0);
    }

    function test_numbers_as_text() {
        compare(Hosts.pairText(0.4 * 1073741824, 16 * 1073741824), "0.4 / 16 GB");
        compare(Hosts.pairText(488 * 1073741824, 920 * 1073741824), "488 / 920 GB");
        compare(Hosts.agoText(1000000 - 125000, 1000000), "2 min ago");
        compare(Hosts.uptimeText(3 * 86400 + 4 * 3600), "3d 4h");
        compare(Hosts.destText({
            host: "box",
            port: "2222",
            username: "neo"
        }), "neo@box:2222");
    }
}
