"""Shared helpers for the plot scripts: paths, CSV loading, and the CPU/RAM twin axis.
Raw CSVs live in scripts/data, PNGs are written to scripts/graphs."""
import csv, os

HERE = os.path.dirname(os.path.abspath(__file__))
DATA = os.path.normpath(os.path.join(HERE, "..", "data"))
GRAPHS = os.path.normpath(os.path.join(HERE, "..", "graphs"))

# palette shared across every figure
OK, BAD, LINE = "#2a9d8f", "#e76f51", "#c1121f"
CPUC, RAMC = "#8338ec", "#3a86ff"   # CPU and RAM lines (right axis)


def rows(name):
    p = os.path.join(DATA, name)
    return list(csv.DictReader(open(p))) if os.path.exists(p) else []


def num(v):
    try:
        return float(v)
    except (TypeError, ValueError):
        return None


def kfmt(x, _=None):
    return f"{x/1e6:g}M" if x >= 1e6 else f"{x/1e3:g}k"


def resources(ax, xs, rs):
    """Prometheus CPU% and RAM% (of the whole node) on a fixed 0-100 right axis.
    Skips silently if the CSV predates resource recording. Returns the twin axis."""
    cpu = [num(r.get("cpu_pct")) for r in rs]
    ram = [num(r.get("ram_pct")) for r in rs]
    if not any(v is not None for v in cpu + ram):
        return None
    nan = float("nan")
    cpu = [c if c is not None else nan for c in cpu]
    ram = [m if m is not None else nan for m in ram]
    ax2 = ax.twinx()
    ax2.plot(xs, cpu, color=CPUC, lw=1.4, marker="o", ms=3, label="CPU %", zorder=4)
    ax2.plot(xs, ram, color=RAMC, lw=1.4, marker="s", ms=3, label="RAM %", zorder=4)
    ax2.set_ylim(0, 100)
    ax2.set_ylabel("CPU / RAM (% of node)", fontsize=8.5, color="#555")
    ax2.tick_params(axis="y", labelsize=7.5, colors="#555")
    ax2.legend(loc="upper left", fontsize=7, framealpha=0.85)
    return ax2


def save(fig, name):
    os.makedirs(GRAPHS, exist_ok=True)
    p = os.path.join(GRAPHS, name)
    fig.savefig(p, bbox_inches="tight")
    print(f"-> {os.path.relpath(p)}")
