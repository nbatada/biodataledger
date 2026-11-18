"""Opt-in local delivery-ticket records; independent of ProjectBundle and R."""
import argparse
import json
import os
from pathlib import Path
import platform
import socket
import subprocess
import sys
import tempfile
import stat
import time
import math
import uuid
from datetime import datetime, timezone


VERSION = "biodataledger-pilot/1"


def _now():
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def _seconds(then, now):
    seconds = (datetime.fromisoformat(now.replace("Z", "+00:00")) -
               datetime.fromisoformat(then.replace("Z", "+00:00"))).total_seconds()
    return seconds if seconds >= 0 else "unknown"


def _numbers(items, label):
    result = {}
    for item in items or []:
        if "=" not in item:
            raise ValueError("%s must be NAME=NUMBER" % label)
        name, value = item.split("=", 1)
        try:
            number = float(value)
        except ValueError:
            raise ValueError("%s must be NAME=NUMBER" % label)
        if not name.strip() or not math.isfinite(number) or number < 0 or not math.isfinite(result.get(name, 0) + number):
            raise ValueError("%s name and non-negative number required" % label)
        result[name] = result.get(name, 0) + number
    return result


def _event(kind, at_utc=None, **details):
    values = {key: value for key, value in details.items() if value not in (None, {}, [])}
    return {"at_utc": at_utc or _now(), "kind": kind, **values}


def _check(ticket):
    if not (isinstance(ticket, dict) and ticket.get("version") == VERSION
            and isinstance(ticket.get("ticket"), str) and ticket["ticket"].strip()
            and isinstance(ticket.get("events"), list)):
        raise ValueError("not a valid pilot ticket")
    if not ticket["events"] or not isinstance(ticket["events"][0], dict) or ticket["events"][0].get("kind") != "start":
        raise ValueError("pilot ticket must begin with start")
    if any(not isinstance(event, dict) or event.get("kind") not in {
        "start", "locate", "deliver", "correct", "accept", "measure_started", "measure", "sample"}
           for event in ticket["events"]):
        raise ValueError("pilot ticket has an invalid event")
    for index, event in enumerate(ticket["events"]):
        stamp = event.get("at_utc")
        if not isinstance(stamp, str) or not stamp.endswith("Z"):
            raise ValueError("pilot event is missing a UTC timestamp")
        datetime.fromisoformat(stamp[:-1] + "+00:00")
        if index and event["kind"] == "start":
            raise ValueError("duplicate dispatch event")
    return ticket


def _read(path):
    try:
        return _check(json.loads(path.read_text(encoding="utf-8")))
    except (OSError, json.JSONDecodeError, ValueError) as error:
        raise ValueError("cannot read pilot ticket %s: %s" % (path, error))


def _lock(path):
    lock = path.with_name(path.name + ".lock")
    try:
        return lock, os.open(str(lock), os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    except FileExistsError:
        raise ValueError("ticket is being updated: %s" % path)


def _write(path, ticket, *, create=False):
    """Publish complete bytes; creation never replaces an existing ticket."""
    descriptor, temporary = tempfile.mkstemp(prefix="." + path.name + ".", suffix=".tmp", dir=str(path.parent))
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            json.dump(ticket, handle, sort_keys=True, indent=2)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        if create:
            os.link(temporary, path)
        else:
            os.replace(temporary, path)
    finally:
        Path(temporary).unlink(missing_ok=True)


def _mutate(path, change):
    path = Path(path)
    lock, descriptor = _lock(path)
    try:
        os.close(descriptor)
        ticket = _read(path)
        change(ticket)
        _write(path, ticket)
    finally:
        lock.unlink(missing_ok=True)


def _logical_size(paths, ticket_path):
    """Apparent bytes only; traversal deliberately does not follow symlinks."""
    reports = []
    log = ticket_path.resolve()
    for raw in paths or []:
        root = Path(raw).absolute()
        report = {"path": str(root), "unit": "logical_bytes", "symlinks_skipped": 0}
        try:
            if log == root.resolve() or root.resolve() in log.parents:
                raise ValueError("ticket log is inside disk scope")
            total, skipped, stack = 0, 0, [root]
            while stack:
                current = stack.pop()
                info = current.lstat()
                if stat.S_ISLNK(info.st_mode):
                    skipped += 1
                elif stat.S_ISDIR(info.st_mode):
                    with os.scandir(current) as entries:
                        stack.extend(Path(entry.path) for entry in entries)
                elif stat.S_ISREG(info.st_mode):
                    total += info.st_size
            report.update(status="measured", bytes=total, symlinks_skipped=skipped)
        except (OSError, ValueError) as error:
            report.update(status="unknown", reason=str(error))
        reports.append(report)
    return reports


def _event_scope(paths, path):
    # Disk scans can be expensive; values are logical bytes, not allocated space.
    return _logical_size(paths, path) if paths else []


def _scope_deltas(before, after):
    """Pair exactly matching absolute roots; absent or failed reads remain unknown."""
    after_by_path = {item["path"]: item for item in after}
    result = []
    for first in before:
        last = after_by_path.get(first["path"])
        entry = {"path": first["path"], "unit": "logical_bytes", "start": first}
        if last is None or first.get("status") != "measured" or last.get("status") != "measured":
            entry["end"] = last if last is not None else "unknown"
            entry["delta_bytes"] = "unknown"
        else:
            entry["end"] = last
            entry["delta_bytes"] = last["bytes"] - first["bytes"]
        result.append(entry)
    return result


def _clear_measure_reservation(ticket, token):
    if not any(event["kind"] == "measure_started" and event.get("token") == token
               for event in ticket["events"]):
        raise ValueError("measurement reservation is no longer current")
    ticket["events"] = [event for event in ticket["events"]
                        if not (event["kind"] == "measure_started" and event.get("token") == token)]


def _record_measure(path, token, **details):
    def change(ticket):
        _clear_measure_reservation(ticket, token)
        ticket["events"].append(_event("measure", **details))
    _mutate(path, change)


def start(args):
    path = Path(args.path)
    if path.exists():
        raise ValueError("refusing to overwrite existing ticket: %s" % path)
    if not path.parent.is_dir():
        raise ValueError("ticket parent directory must already exist")
    if not args.ticket.strip():
        raise ValueError("ticket must not be whitespace")
    invoked_at = _now()
    ticket = {"version": VERSION, "ticket": args.ticket, "arm": args.arm, "pair": args.pair, "events": [_event(
        "start", active_review_seconds=args.active_review_seconds,
        usage=_numbers(args.usage, "usage"), cost=_numbers(args.cost, "cost"),
        disk_scope=_event_scope(args.disk, path), at_utc=invoked_at)]}
    try:
        _write(path, ticket, create=True)
    except FileExistsError:
        raise ValueError("refusing to overwrite existing ticket: %s" % path)
    return ticket


def deliver(args):
    def change(ticket):
        if _terminal(ticket):
            raise ValueError("terminal ticket cannot receive a new delivery")
        if _work_state(ticket) not in ("start", "correct"):
            raise ValueError("delivery requires start or correction")
        ticket["events"].append(_event("deliver", evidence=args.evidence))
    _mutate(args.path, change)


def correct(args):
    def change(ticket):
        if _terminal(ticket):
            raise ValueError("terminal ticket cannot be corrected")
        if _work_state(ticket) != "deliver":
            raise ValueError("correction requires the outstanding delivery")
        ticket["events"].append(_event("correct", reason=args.reason))
    _mutate(args.path, change)


def accept(args):
    invoked_at = _now()
    def change(ticket):
        if _terminal(ticket):
            raise ValueError("ticket is already terminal")
        if any(event["kind"] == "measure_started" for event in ticket["events"]):
            raise ValueError("cannot close a ticket with an active measure")
        if _work_state(ticket) != "deliver":
            raise ValueError("disposition requires the outstanding delivery")
        start_scope = next(e.get("disk_scope", []) for e in ticket["events"] if e["kind"] == "start")
        disks = args.disk or [item["path"] for item in start_scope]
        end_scope = _event_scope(disks, Path(args.path))
        ticket["events"].append(_event("accept", decision=args.decision,
            active_review_seconds=args.active_review_seconds,
            usage=_numbers(args.usage, "usage"), cost=_numbers(args.cost, "cost"),
            disk_scope=end_scope, disk_delta=_scope_deltas(start_scope, end_scope), at_utc=invoked_at))
    _mutate(args.path, change)


def locate(args):
    def change(ticket):
        if any(event["kind"] == "deliver" for event in ticket["events"]):
            raise ValueError("locate milestone must precede first delivery")
        if any(event["kind"] == "locate" for event in ticket["events"]):
            raise ValueError("locate milestone is recorded once per ticket")
        ticket["events"].append(_event("locate", evidence=args.evidence))
    _mutate(args.path, change)


def _accepted(ticket):
    return any(event["kind"] == "accept" and event.get("decision") == "accepted" for event in ticket["events"])


def _terminal(ticket):
    return any(event["kind"] == "accept" for event in ticket["events"])


def _work_state(ticket):
    return next(event["kind"] for event in reversed(ticket["events"])
                if event["kind"] in ("start", "deliver", "correct", "accept"))


def _totals(events, field):
    total = {}
    for event in events:
        for name, value in event.get(field, {}).items():
            total[name] = total.get(name, 0) + value
    return total


def summary(path):
    ticket = _read(Path(path))
    events = ticket["events"]
    start_event = events[0]
    deliveries = [e for e in events if e["kind"] == "deliver"]
    corrections = [e for e in events if e["kind"] == "correct"]
    lookup = next((e for e in events if e["kind"] == "locate"), None)
    accept_events = [e for e in events if e["kind"] == "accept"]
    decision = accept_events[-1].get("decision") if accept_events else "unknown"
    accepted = next((e for e in accept_events if e.get("decision") == "accepted"), None)
    accepted_delivery = None
    if accepted:
        accepted_delivery = next((e for e in reversed(events[:events.index(accepted)]) if e["kind"] == "deliver"), None)
    state = _work_state(ticket)
    if accept_events:
        status = decision if decision != "unknown" else "closed_unknown"
    else:
        status = {"start": "in_progress", "correct": "revision_requested", "deliver": "awaiting_review"}[state]
    observed = [e for e in events if e["kind"] == "sample" and e.get("rss_bytes") is not None]
    disk_scopes = accept_events[-1].get("disk_delta", []) if accept_events else [
        {"path": item["path"], "unit": "logical_bytes", "start": item,
         "end": "unknown", "delta_bytes": "unknown"}
        for item in start_event.get("disk_scope", [])]
    return {"version": VERSION, "ticket": ticket["ticket"], "arm": ticket.get("arm"), "pair": ticket.get("pair"),
            "status": status,
            "acceptance_decision": decision, "deliveries": len(deliveries), "correction_cycles": len(corrections),
            "first_pass": (False if corrections or decision == "rejected" else
                           bool(accepted and accepted_delivery is deliveries[0]) if accepted else "unknown"),
            "time_to_lookup_seconds": _seconds(start_event["at_utc"], lookup["at_utc"]) if lookup else "unknown",
            "lookup_evidence": lookup.get("evidence", []) if lookup else [],
            "time_to_first_delivery_seconds": _seconds(start_event["at_utc"], deliveries[0]["at_utc"]) if deliveries else "unknown",
            "time_to_accepted_delivery_seconds": _seconds(start_event["at_utc"], accepted_delivery["at_utc"]) if accepted_delivery else "unknown",
            "time_to_acceptance_seconds": _seconds(start_event["at_utc"], accepted["at_utc"]) if accepted else "unknown",
            "review_waiting_seconds": _seconds(accepted_delivery["at_utc"], accepted["at_utc"]) if accepted_delivery and accepted else "unknown",
            "active_review_seconds": (sum(e["active_review_seconds"] for e in events if e.get("active_review_seconds") is not None)
                                      if any(e.get("active_review_seconds") is not None for e in events) else "unknown"),
            "declared_usage_increment_total": _totals(events, "usage"),
            "declared_cost_increment_total": _totals(events, "cost"),
            "disk_scopes": disk_scopes,
            "first_delivery_evidence": deliveries[0].get("evidence", []) if deliveries else [],
            "max_observed_rss_bytes": max((e["rss_bytes"] for e in observed), default="unknown"),
            "rss_note": "sampled observations only; not a process lifetime or true peak", "events": events}


def measure(args):
    if len(args.command) < 2 or args.command[0] != "--":
        raise ValueError("measure requires an explicit command after --")
    args.command = args.command[1:]
    token = uuid.uuid4().hex
    def reserve(ticket):
        if _terminal(ticket):
            raise ValueError("terminal ticket cannot run a measure")
        if any(event["kind"] == "measure_started" for event in ticket["events"]):
            raise ValueError("ticket already has an active measure")
        ticket["events"].append(_event("measure_started", token=token,
            owner_pid=os.getpid(), host=socket.gethostname()))
    _mutate(args.path, reserve)
    before = _event_scope(args.disk, Path(args.path))
    started = time.monotonic()
    try:
        process = subprocess.Popen(args.command)
    except OSError as error:
        after = _event_scope(args.disk, Path(args.path))
        _record_measure(args.path, token, exit_code="unknown", elapsed_seconds=0,
                        failure="could not start command (OS error %s)" % error.errno,
                        disk_before=before, disk_after=after,
                        disk_delta=_scope_deltas(before, after))
        return 127
    if hasattr(os, "wait4"):
        _, status, usage = os.wait4(process.pid, 0)
        code = os.waitstatus_to_exitcode(status)
        process.returncode = code
        rss = usage.ru_maxrss * (1 if platform.system() == "Darwin" else 1024)
        cpu = usage.ru_utime + usage.ru_stime
        inblock, oublock = usage.ru_inblock, usage.ru_oublock
    else:
        code = process.wait()
        rss = cpu = inblock = oublock = None
    elapsed = time.monotonic() - started
    after = _event_scope(args.disk, Path(args.path))
    _record_measure(args.path, token, exit_code=code, elapsed_seconds=elapsed,
                    cpu_seconds=cpu, peak_rss_bytes=rss, os_block_input_operations=inblock,
                    os_block_output_operations=oublock, disk_before=before, disk_after=after,
                    disk_delta=_scope_deltas(before, after))
    return 128 + abs(code) if code < 0 else code


def abandon_measure(args):
    """Clear only a stale local reservation; never terminates or reruns a command."""
    def change(ticket):
        pending = [event for event in ticket["events"] if event["kind"] == "measure_started"]
        if len(pending) != 1:
            raise ValueError("ticket has no single active measure to abandon")
        reservation = pending[0]
        owner_dead = False
        if reservation.get("host") == socket.gethostname():
            try:
                os.kill(reservation["owner_pid"], 0)
            except ProcessLookupError:
                owner_dead = True
            except (KeyError, PermissionError, TypeError):
                owner_dead = False
        if not args.confirmed_stopped or (reservation.get("host") == socket.gethostname() and not owner_dead):
            raise ValueError("confirm the child stopped and verify the measurement owner has exited on this host")
        _clear_measure_reservation(ticket, reservation.get("token"))
        ticket["events"].append(_event("measure", exit_code="unknown", failure="abandoned: " + args.reason,
            reservation_token=reservation.get("token")))
    _mutate(args.path, change)


def sample(args):
    if args.pid <= 0:
        raise ValueError("pid must be positive")
    try:
        value = subprocess.check_output(["/bin/ps", "-o", "rss=", "-p", str(args.pid)], text=True).strip()
        rss, reason = int(value) * 1024, None
    except (OSError, subprocess.CalledProcessError, ValueError) as error:
        rss, reason = None, str(error)
    def change(ticket):
        if _terminal(ticket):
            raise ValueError("terminal ticket cannot receive a sample")
        ticket["events"].append(_event("sample", pid=args.pid, rss_bytes=rss, reason=reason))
    _mutate(args.path, change)


def parser():
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--path", required=True)
    numeric = argparse.ArgumentParser(add_help=False)
    numeric.add_argument("--active-review-seconds", type=float, default=None)
    numeric.add_argument("--usage", action="append", default=[])
    numeric.add_argument("--cost", action="append", default=[])
    main = argparse.ArgumentParser(description=__doc__)
    commands = main.add_subparsers(dest="action", required=True)

    p = commands.add_parser("start", parents=[common, numeric])
    p.add_argument("--ticket", required=True)
    p.add_argument("--arm", choices=("baseline", "bdl"))
    p.add_argument("--pair")
    p.add_argument("--disk", action="append", default=[])
    p.set_defaults(run=start)

    p = commands.add_parser("locate", parents=[common])
    p.add_argument("--evidence", action="append", default=[], required=True)
    p.set_defaults(run=locate)

    p = commands.add_parser("deliver", parents=[common])
    p.add_argument("--evidence", action="append", default=[])
    p.set_defaults(run=deliver)

    p = commands.add_parser("correct", parents=[common])
    p.add_argument("--reason")
    p.set_defaults(run=correct)

    p = commands.add_parser("accept", parents=[common, numeric])
    p.add_argument("--decision", choices=("accepted", "rejected", "unknown"), required=True)
    p.add_argument("--disk", action="append", default=[])
    p.set_defaults(run=accept)

    p = commands.add_parser("summary", parents=[common])
    p.set_defaults(run=lambda args: summary(args.path))

    p = commands.add_parser("measure", parents=[common])
    p.add_argument("--disk", action="append", default=[])
    p.add_argument("command", nargs=argparse.REMAINDER)
    p.set_defaults(run=measure)

    p = commands.add_parser("sample", parents=[common])
    p.add_argument("--pid", type=int, required=True)
    p.set_defaults(run=sample)

    p = commands.add_parser("abandon-measure", parents=[common])
    p.add_argument("--reason", required=True)
    p.add_argument("--confirmed-stopped", action="store_true")
    p.set_defaults(run=abandon_measure)
    return main


def main(argv=None):
    args = parser().parse_args(argv)
    try:
        if hasattr(args, "active_review_seconds") and args.active_review_seconds is not None and (
                not math.isfinite(args.active_review_seconds) or args.active_review_seconds < 0):
            raise ValueError("active review seconds must be a finite non-negative number")
        result = args.run(args)
    except (ValueError, OSError) as error:
        parser().error(str(error))
    if args.action == "summary":
        print(json.dumps(result, sort_keys=True, indent=2))
    elif args.action == "start":
        print(json.dumps({"ticket": result["ticket"], "path": args.path, "status": "started"}, sort_keys=True))
    return result if isinstance(result, int) else 0


if __name__ == "__main__":
    sys.exit(main())
