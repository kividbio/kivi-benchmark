"""Render a ramp run from Prometheus as an MP4 (and a summary PNG).

  python video/render.py --start <unix> --end <unix> [--prom http://127.0.0.1:19090]
                         [--speed 15] [--fps 30] [--out video/out]

The four graphs of the dashboard, drawn as the run went, sped up: throughput,
p99 latency per pipelined batch, database CPU, database memory. Then a card
with each database's peak throughput.
"""
import argparse
import json
import os
import urllib.parse
import urllib.request

import imageio_ffmpeg
import matplotlib

matplotlib.use("Agg")
import matplotlib.animation as animation  # noqa: E402
import matplotlib.pyplot as plt  # noqa: E402

matplotlib.rcParams["animation.ffmpeg_path"] = imageio_ffmpeg.get_ffmpeg_exe()

DBS = ["kividb", "dragonfly", "redis-cluster", "redis"]
NAMES = {"kividb": "KiviDB 1.1.2", "dragonfly": "Dragonfly 2.0.2", "redis-cluster": "Redis 8.10.2 Cluster (4 x 2 vCPU)", "redis": "Redis 8.10.2"}
COLORS = {"kividb": "#2ECC71", "dragonfly": "#A569BD", "redis-cluster": "#F39C12", "redis": "#E74C3C"}
W = "[20s]"
QUERIES = {
    "tput": ('sum(rate(client_requests_total{db="$DB",status="ok"}' + W + '))', 1e-6),
    "p50": ('1000 * histogram_quantile(0.50, sum by (le) (rate(client_request_duration_seconds_bucket{db="$DB",op="set"}' + W + ')))', 1),
    "p99": ('1000 * histogram_quantile(0.99, sum by (le) (rate(client_request_duration_seconds_bucket{db="$DB",op="set"}' + W + ')))', 1),
    "err": ('sum(rate(client_requests_total{db="$DB",status="error"}' + W + ')) or vector(0)', 1e-3),
    "cpu": ('100 * (1 - avg(rate(node_cpu_seconds_total{job="db-nodes",db="$DB",mode="idle"}' + W + ')))', 1),
    "mem": ('sum(node_memory_MemTotal_bytes{job="db-nodes",db="$DB"} - node_memory_MemAvailable_bytes{job="db-nodes",db="$DB"})', 1 / 2**30),
    "clients": ('sum(client_workers{db="$DB"})', 1),
}
PANELS = [
    ("tput", "Throughput", "million requests/s"),
    ("p50", "p50 latency", "ms"),
    ("p99", "p99 latency", "ms"),
    ("err", "Errors (timed out after 1 s)", "thousand requests/s"),
    ("cpu", "Database CPU (8 vCPU each)", "%"),
    ("mem", "Database memory used", "GiB"),
]


def series(prom, q, start, end, step):
    url = prom + "/api/v1/query_range?" + urllib.parse.urlencode(
        {"query": q, "start": start, "end": end, "step": step})
    res = json.load(urllib.request.urlopen(url))["data"]["result"]
    if not res:
        return [], []
    pts = res[0]["values"]
    return [float(t) - start for t, _ in pts], [float(v) for _, v in pts]


# What each of an export's series is called here, and the factor that makes
# it what QUERIES gives (latency is exported in seconds; QUERIES gives ms).
EXPORT_KEYS = {
    "tput": ("throughput", 1), "err": ("errors", 1), "p50": ("p50_seconds", 1000),
    "p99": ("p99_seconds", 1000), "cpu": ("db_cpu_percent", 1), "mem": ("db_memory_bytes", 1),
    "clients": ("clients", 1),
}


def from_export(path):
    """The series of a prometheus-export.json, as main() gets them from Prometheus."""
    with open(path) as f:
        exp = json.load(f)
    start = exp["start"]
    data = {}
    for key, (name, factor) in EXPORT_KEYS.items():
        data[key] = {db: ([], []) for db in DBS}
        for s_ in exp["series"].get(name, []):
            db = s_["labels"].get("db")
            if db in data[key]:
                vals = [(float(t) - start, float(v) * factor) for t, v in s_["values"] if v not in ("NaN", "+Inf")]
                data[key][db] = ([t for t, _ in vals], [v for _, v in vals])
    return data, start, exp["end"]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--start", type=int, help="unix time; from Prometheus (with --end)")
    ap.add_argument("--end", type=int)
    ap.add_argument("--export", help="a results/*/prometheus-export.json instead of Prometheus")
    ap.add_argument("--prom", default="http://127.0.0.1:19090")
    ap.add_argument("--speed", type=float, default=15)
    ap.add_argument("--fps", type=int, default=30)
    ap.add_argument("--step", type=int, default=5)
    ap.add_argument("--kividb-label", default="KiviDB 1.1.2")
    ap.add_argument("--per-client", type=float, default=2000, help="nominal req/s each client offers")
    ap.add_argument("--out", default=os.path.join(os.path.dirname(os.path.abspath(__file__)), "out"))
    ap.add_argument("--subtitle", default=(
        "Pipeline 10 · SET+GET, ~110 B JSON values, 10M keys, no TTL · each client sleeps 10 ms "
        "between batches, +40 clients every 30 s · 8 vCPU arm64 each (Redis Cluster: 4 × 2 vCPU, "
        "no replicas) · two 8-vCPU load nodes per database · Dragonfly busy-polls: its CPU reads "
        "100% at any load"))
    a = ap.parse_args()
    NAMES["kividb"] = a.kividb_label
    os.makedirs(a.out, exist_ok=True)

    if a.export:
        data, a.start, a.end = from_export(a.export)
    else:
        data = {k: {db: series(a.prom, q.replace("$DB", db), a.start, a.end, a.step) for db in DBS}
                for k, (q, _) in QUERIES.items()}
    scale = {k: s for k, (_, s) in QUERIES.items()}
    with open(os.path.join(a.out, "data.json"), "w") as f:
        json.dump(data, f)
    duration = a.end - a.start

    plt.style.use("dark_background")
    fig = plt.figure(figsize=(19.2, 10.8), dpi=100)
    fig.patch.set_facecolor("#0E1117")
    gs = fig.add_gridspec(2, 3, left=0.05, right=0.985, top=0.83, bottom=0.10, hspace=0.36, wspace=0.17)
    title = fig.text(0.05, 0.94, "KiviDB vs Dragonfly vs Redis", fontsize=34, weight="bold")
    import textwrap
    fig.text(0.05, 0.915, "\n".join(textwrap.wrap(a.subtitle, 190)), fontsize=12.5, color="#AAB2BF", va="top")
    clock = fig.text(0.98, 0.94, "", fontsize=20, ha="right", color="#AAB2BF")
    fig.text(0.05, 0.035, "Load: Go clients (go-redis), concurrent clients added step by step, after Anton Putra's "
             "latency/throughput/saturation method. Metrics: Prometheus, 5 s scrapes.", fontsize=11, color="#7F8896")
    axes, lines, labels = {}, {}, {}
    for i, (key, name, unit) in enumerate(PANELS):
        ax = fig.add_subplot(gs[i // 3, i % 3])
        ax.set_facecolor("#161B22")
        ax.set_title(name, loc="left", fontsize=16, pad=8)
        ax.set_ylabel(unit, fontsize=12)
        ax.set_xlim(0, duration / 60)
        ax.set_xlabel("minutes", fontsize=11)
        ax.grid(color="#2A313C", linewidth=0.8)
        top = max((max(v) * scale[key] for db in DBS for v in [data[key][db][1]] if v), default=1)
        if key == "tput":
            top = max(top, max(data["clients"]["kividb"][1] or [0]) * a.per_client * 1e-6 * 0.75)
        ax.set_ylim(0, (100 if key == "cpu" else max(top * 1.15, 1 if key == "err" else 0.001)))
        if key == "tput":
            (lines[("tput", "offered")],) = ax.plot([], [], color="#7F8896", linewidth=2, linestyle="--",
                                                    label="load offered (2,000 req/s per client)")
        for db in DBS:
            (lines[(key, db)],) = ax.plot([], [], color=COLORS[db], linewidth=3, label=NAMES[db])
        leg = ax.legend(loc=("lower right" if key == "mem" else "upper left"), fontsize=10.5, frameon=True, framealpha=0.6,
                        facecolor="#0E1117", edgecolor="#2A313C")
        for txt in leg.get_texts():
            for db in DBS:
                if txt.get_text() == NAMES[db]:
                    labels[(key, db)] = txt
        axes[key] = ax

    frames_run = int(duration / a.speed * a.fps)
    frames_card = a.fps * 6

    def fmt(key, v):
        return {"tput": f"{v:.2f}M", "p50": f"{v:.1f} ms", "p99": f"{v:.1f} ms", "err": f"{v:.1f}k",
                "cpu": f"{v:.0f}%", "mem": f"{v:.1f} GiB"}[key]

    def draw(frame):
        if frame >= frames_run:
            return []
        t = (frame + 1) / frames_run * duration
        for key, _, _ in PANELS:
            for db in DBS:
                xs, ys = data[key][db]
                n = sum(1 for x in xs if x <= t)
                lines[(key, db)].set_data([x / 60 for x in xs[:n]], [y * scale[key] for y in ys[:n]])
                if n:
                    labels[(key, db)].set_text(f"{NAMES[db]}   {fmt(key, ys[n - 1] * scale[key])}")
        cx, cy = data["clients"]["kividb"]
        n = sum(1 for x in cx if x <= t)
        lines[("tput", "offered")].set_data([x / 60 for x in cx[:n]], [y * a.per_client * 1e-6 for y in cy[:n]])
        clients = int(cy[n - 1]) if n else 0
        clock.set_text(f"{int(t // 60):02d}:{int(t % 60):02d}   ·   {clients} clients per database")
        return []

    writer = animation.FFMpegWriter(fps=a.fps, bitrate=8000, codec="libx264",
                                    extra_args=["-pix_fmt", "yuv420p"])
    mp4 = os.path.join(a.out, "kividb-vs-dragonfly-vs-redis.mp4")
    anim = animation.FuncAnimation(fig, draw, frames=frames_run, blit=False)
    anim.save(mp4, writer=writer)
    fig.savefig(os.path.join(a.out, "final-dashboard.png"), facecolor=fig.get_facecolor())

    # Summary card: peak throughput, held for a few seconds (separate clip + PNG).
    peaks = {db: max(data["tput"][db][1] or [0]) * 1e-6 for db in DBS}
    card = plt.figure(figsize=(19.2, 10.8), dpi=100)
    card.patch.set_facecolor("#0E1117")
    ax = card.add_axes([0.30, 0.12, 0.62, 0.62])
    ax.set_facecolor("#0E1117")
    order = sorted(DBS, key=lambda d: peaks[d])
    bars = ax.barh([NAMES[d] for d in order], [peaks[d] for d in order], color=[COLORS[d] for d in order], height=0.6)
    for b, d in zip(bars, order):
        ax.text(b.get_width() * 1.01, b.get_y() + b.get_height() / 2, f"{peaks[d]:.2f}M req/s",
                va="center", fontsize=24, weight="bold", color=COLORS[d])
    ax.tick_params(axis="y", labelsize=22)
    ax.set_xlim(0, max(peaks.values()) * 1.25)
    ax.set_xticks([])
    for s in ax.spines.values():
        s.set_visible(False)
    card.text(0.06, 0.88, "Peak throughput", fontsize=38, weight="bold")
    card.text(0.06, 0.835, "\n".join(textwrap.wrap(a.subtitle, 170)), fontsize=13, color="#AAB2BF", va="top")
    card.savefig(os.path.join(a.out, "peak-throughput.png"), facecolor=card.get_facecolor())
    canim = animation.FuncAnimation(card, lambda f: [], frames=frames_card, blit=False)
    canim.save(os.path.join(a.out, "peak-throughput.mp4"), writer=writer)
    print(json.dumps({"mp4": mp4, "peaks_millions": peaks}, indent=1))


if __name__ == "__main__":
    main()
