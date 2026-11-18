"""Create a small offline review table from explicitly selected pilot tickets."""
import argparse
from html import escape
import os
from pathlib import Path
import tempfile

from .pilot import summary


def _duration(seconds):
    if not isinstance(seconds, (float, int)) or seconds < 0:
        return "Unknown"
    if seconds < 60:
        return f"{seconds:.1f} s"
    minutes, remainder = divmod(round(seconds), 60)
    return f"{minutes}m {remainder:02d}s"


def _row(ticket):
    decision = ticket["acceptance_decision"]
    first_pass = ticket["first_pass"]
    values = (
        ticket["ticket"],
        ticket.get("arm") or "—",
        ticket.get("pair") or "—",
        decision if decision != "unknown" else ticket["status"],
        "Yes" if first_pass is True else "No" if first_pass is False else "Unknown",
        str(ticket["correction_cycles"]),
        _duration(ticket["time_to_lookup_seconds"]),
        _duration(ticket["time_to_first_delivery_seconds"]),
        _duration(ticket["time_to_accepted_delivery_seconds"]),
        _duration(ticket["time_to_acceptance_seconds"]),
        _duration(ticket["active_review_seconds"]),
    )
    return _cells(values)


def _cells(values):
    return "<tr>" + "".join(f"<td>{escape(str(value))}</td>" for value in values) + "</tr>"


def _table(columns, rows):
    headers = "".join(f'<th scope="col">{escape(label)}</th>' for label in columns)
    return f'<div class="scroll"><table><thead><tr>{headers}</tr></thead><tbody>{rows}</tbody></table></div>'


def _resource_rows(tickets):
    rows = []
    for ticket in tickets:
        measurements = (e for e in ticket["events"] if e["kind"] == "measure")
        for attempt, measurement in enumerate(measurements, start=1):
            peak = measurement.get("peak_rss_bytes")
            values = (ticket["ticket"], attempt, measurement.get("exit_code", "Unknown"),
                      _duration(measurement.get("elapsed_seconds")),
                      _duration(measurement.get("cpu_seconds")),
                      f"{peak / (1024 ** 2):.1f}" if isinstance(peak, (int, float)) else "Unknown")
            rows.append(_cells(values))
    return "".join(rows)


def render(paths):
    """Render milestone times for every supplied ticket, including unfinished work."""
    tickets = [summary(path) for path in paths]
    rows = "\n".join(_row(ticket) for ticket in tickets)
    labels = ("Ticket", "Workflow", "Pair", "Decision / state", "First pass", "Corrections", "Source located",
              "First delivery", "Accepted delivery", "Decision elapsed¹", "Active review²")
    milestones = _table(labels, rows)
    processes = _resource_rows(tickets)
    resources = (_table(("Ticket", "Command #", "Exit code", "Elapsed", "CPU", "Peak RSS (MiB)"), processes)
                 if processes else "<p>No batch command measurements recorded.</p>")
    storage = []
    observations = []
    for ticket in tickets:
        for index, scope in enumerate(ticket.get("disk_scopes", []), 1):
            first, last = scope.get("start"), scope.get("end")
            storage.append(_cells((ticket["ticket"], index,
                                   first.get("bytes", "Unknown") if isinstance(first, dict) else "Unknown",
                                   last.get("bytes", "Unknown") if isinstance(last, dict) else "Unknown",
                                   scope.get("delta_bytes", "Unknown"))))
        for event in ticket["events"]:
            if event["kind"] == "sample":
                rss = event.get("rss_bytes")
                observations.append(_cells((ticket["ticket"], event["pid"], event["at_utc"],
                                            f"{rss / (1024 ** 2):.1f}" if isinstance(rss, int) else "Unknown")))
    disks = (_table(("Ticket", "Scope #", "Start bytes", "End bytes", "Change in bytes"), "".join(storage))
             if storage else "<p>No ticket storage scope selected.</p>")
    live = (_table(("Ticket", "PID", "Time (UTC)", "Observed RSS (MiB)"), "".join(observations))
            if observations else "<p>No live-process samples recorded.</p>")
    return f"""<!doctype html>
<html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width">
<title>Ticket review</title>
<style>
body {{font: 16px system-ui, sans-serif; margin: 2rem; color: #192b36; background: white}}
table {{border-collapse: collapse; font-variant-numeric: tabular-nums}}
th, td {{padding: .65rem; text-align: left; border-bottom: 1px solid #ccd7da}}
th {{background: #e8f1f1}} tr:nth-child(even) {{background: #f7f9fa}}
p {{max-width: 70ch}} .scroll {{overflow-x: auto}}
</style>
<h1>Ticket review</h1><p>Time from dispatch to each milestone. Corrections stay with the original ticket.</p>
{milestones}
<p>¹ Time to scientist acceptance, including waiting for review. Open and rejected tickets remain visible.</p>
<p>² Active review time is reported by the reviewer. Unknown means no usable observation.</p>
<h2>Measured commands</h2>{resources}
<h2>Live process samples</h2>{live}
<h2>Selected storage</h2>{disks}
</html>"""


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("tickets", nargs="+", type=Path)
    parser.add_argument("--out", required=True, type=Path, help="new local HTML file")
    args = parser.parse_args(argv)
    try:
        content = render(args.tickets)
        with tempfile.NamedTemporaryFile(dir=args.out.parent, delete=False) as temp:
            temp_path = Path(temp.name)
        try:
            temp_path.write_text(content, encoding="utf-8")
            os.link(temp_path, args.out)
        finally:
            temp_path.unlink()
    except (OSError, ValueError, KeyError, IndexError, TypeError) as error:
        parser.exit(1, f"Could not generate ticket review: {error}\n")
    print(args.out)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
