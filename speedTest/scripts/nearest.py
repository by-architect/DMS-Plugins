"""One speedtest-cli test against the servers speedtest.net itself lists as
nearest, printed the way `speedtest-cli --json` prints it.

speedtest-cli 2.1.3 picks from a fixed, global server list
(speedtest-servers-static.php) that, from some countries, holds nothing
closer than another continent: from Istanbul its nearest is in England,
2,500 km and 130 ms away, and the result says more about that path than about
the line being tested. speedtest.net's own web client asks /api/js/servers
instead, which lists servers in the same city. This runs speedtest-cli's own
engine -- the same latency pick, download, upload and JSON -- against those,
and falls back to its usual list when that API does not answer.

Exit 3 when the speedtest module cannot be imported, so run.sh can fall back
to the plain speedtest-cli command. Any other failure is "ERROR: ..." on
stderr and exit 1, the way speedtest-cli reports its own.
"""
import json
import sys
import urllib.request

try:
    import speedtest
except Exception:
    sys.exit(3)

NEAREST_URL = "https://www.speedtest.net/api/js/servers?engine=js&limit=10&https_functional=true"
# The latency pick pings each one three times; five is what speedtest-cli
# itself tries.
CANDIDATES = 5


def nearest_servers():
    req = urllib.request.Request(NEAREST_URL, headers={"User-Agent": speedtest.build_user_agent()})
    with urllib.request.urlopen(req, timeout=10) as r:
        listed = json.load(r)
    out = []
    for s in listed:
        if not s.get("url") or not s.get("id"):
            continue
        out.append({
            "url": s["url"],
            "lat": str(s.get("lat", "0")),
            "lon": str(s.get("lon", "0")),
            "name": s.get("name", ""),
            "country": s.get("country", ""),
            "cc": s.get("cc", ""),
            "sponsor": s.get("sponsor", ""),
            "id": str(s["id"]),
            "host": s.get("host", ""),
            "d": float(s.get("distance", 0) or 0),
        })
    return out[:CANDIDATES]


def main():
    try:
        st = speedtest.Speedtest(secure=True)
        try:
            servers = nearest_servers()
        except Exception:
            servers = []
        if servers:
            st.get_best_server(servers)
        else:
            st.get_servers()
            st.get_best_server()
        st.download()
        st.upload(pre_allocate=True)
    except (KeyboardInterrupt, speedtest.SpeedtestException) as e:
        sys.stderr.write("ERROR: %s\n" % e)
        return 1
    except Exception as e:
        sys.stderr.write("ERROR: %s: %s\n" % (type(e).__name__, e))
        return 1
    out = st.results.dict()
    out["picked"] = "nearest" if servers else "list"
    print(json.dumps(out))
    return 0


if __name__ == "__main__":
    sys.exit(main())
