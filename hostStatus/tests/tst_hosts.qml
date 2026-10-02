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
        // into it; a mount point with a space matched through \040.
        compare(mounts.join(","), "/,/boot,/mnt/My Disk");
        const disk = Hosts.parseProbe(linuxProbe).filesystems[2];
        compare(disk.type, "ext4");
        fuzzyCompare(disk.percent, 95, 0.01);
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
