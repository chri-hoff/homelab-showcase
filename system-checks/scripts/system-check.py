#!/usr/bin/env python3
"""Weekly system checks on the host (ADR 007). Read-only.

    sudo homelab-deploy system-check            # via Kestra (forced command)
    sudo python3 scripts/maintenance/system-check.py out.json   # by hand

Writes one JSON document:
    {"generated": "...", "host": "...", "checks": [names that ran], "errors": [...],
     "findings": [{"check", "fingerprint", "severity", "title", "details"}]}

The script decides what is a finding (fixed thresholds); nothing here talks to Claude.
The fingerprint is stable for the same problem and is the key for deduplication in the
issue tracker. A check that fails internally is reported under "errors", the others run on.
Exit code 0 also with findings; 1 only if the output could not be written.
"""
import base64
import json
import os
import pwd
import shutil
import socket
import subprocess
import sys
from datetime import datetime, timedelta, timezone

REPO = os.environ.get("HOMELAB_REPO", "/data/gitea/homelab")
BACKUP_LOG_DIR = "/data/backup/ThinkCentre/log"
BACKUP_JOBS = {"docker": "docker.log", "nextcloud": "nextcloud.log",
               "offsite-nextcloud": "offsite-nextcloud.log"}   # Storage Box copy (#202)
BACKUP_MAX_AGE_H = 26          # last successful run (the night before the check)
BACKUP_ERROR_LOOKBACK_D = 8    # weekly run: report errors of the whole week
# Duplicati result reports, written by the Kestra flow duplicati-report (/state in Kestra)
DUPLICATI_STATE_DIR = "/data/kestra-state/duplicati"
DUPLICATI_MAX_AGE_H = 26       # all Duplicati jobs run daily
ACME_JSON = "/opt/docker/traefik/letsencrypt/acme.json"
CERT_WARN_DAYS = 21
DISK_MOUNTS = ["/", "/data", "/mnt/wd-750", "/mnt/nextcloud", "/mnt/bk_nxc_data"]
DISK_WARN, DISK_CRIT = 85, 95
# One-shot containers that end with exit code 0 by design
ONE_SHOT_SUFFIX = "-vault-agent"
STATE_DIR = "/var/lib/homelab-checks"
CHECK_CONFIG = os.path.join(REPO, "config/system-checks")
TRIVY_MAX_AGE_D = 8
APT_MAX_AGE_H = 26
REBOOT_MAX_AGE_D = 3
EXPIRY_WARN_DAYS = 21

NOW = datetime.now(timezone.utc)
findings, errors, ran = [], [], []


def finding(check, key, severity, title, details):
    findings.append({"check": check, "fingerprint": f"{check}:{key}", "severity": severity,
                     "title": title, "details": details})


def run(cmd, timeout=120, **kw):
    return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, **kw)


def config_lines(name):
    """Non-empty, non-comment lines of config/system-checks/<name>; None if the file is missing."""
    path = os.path.join(CHECK_CONFIG, name)
    if not os.path.exists(path):
        return None
    return [l.split("#", 1)[0].strip() for l in open(path, encoding="utf-8") if l.split("#", 1)[0].strip()]


def check(name):
    def wrap(fn):
        def inner():
            try:
                fn()
                ran.append(name)
            except Exception as e:  # one broken check must not stop the others
                errors.append(f"{name}: {type(e).__name__}: {e}")
        return inner
    return wrap


@check("container")
def containers():
    r = run(["docker", "ps", "-a", "--format", "{{json .}}"])
    if r.returncode != 0:
        raise RuntimeError(r.stderr.strip()[:200])
    for line in r.stdout.splitlines():
        c = json.loads(line)
        name, state, status = c.get("Names", "?"), c.get("State", ""), c.get("Status", "")
        if "(unhealthy)" in status:
            finding("container", f"unhealthy:{name}", "high", f"Container {name} ist unhealthy",
                    f"Status: {status}")
        elif state == "restarting":
            finding("container", f"restarting:{name}", "high", f"Container {name} startet ständig neu",
                    f"Status: {status}")
        elif state in ("exited", "dead"):
            if name.endswith(ONE_SHOT_SUFFIX) and status.startswith("Exited (0)"):
                continue
            finding("container", f"stopped:{name}", "medium", f"Container {name} läuft nicht",
                    f"Status: {status}")


@check("backup")
def backups():
    for job, fname in BACKUP_JOBS.items():
        path = os.path.join(BACKUP_LOG_DIR, fname)
        if not os.path.exists(path):
            finding("backup", f"log-missing:{job}", "high", f"Backup-Log {fname} fehlt", path)
            continue
        last_ok, recent_errors = None, []
        for line in open(path, encoding="utf-8", errors="replace"):
            try:
                e = json.loads(line)
                ts = datetime.fromisoformat(e["timestamp"].replace("Z", "+00:00"))
            except (ValueError, KeyError):
                continue
            if e.get("message") == "Skript beendet":
                last_ok = ts
            if e.get("level") == "ERROR" and NOW - ts < timedelta(days=BACKUP_ERROR_LOOKBACK_D):
                recent_errors.append(f"{ts:%d.%m. %H:%M} UTC: {e.get('message', '')[:200]}")
        if last_ok is None or NOW - last_ok > timedelta(hours=BACKUP_MAX_AGE_H):
            since = f"{last_ok:%d.%m.%Y %H:%M} UTC" if last_ok else "nie (im Log)"
            finding("backup", f"no-success:{job}", "high",
                    f"Kein erfolgreiches {job}-Backup in den letzten {BACKUP_MAX_AGE_H} h",
                    f"Letzter erfolgreicher Lauf: {since}. Log: {path}")
        if recent_errors:
            finding("backup", f"errors:{job}", "high", f"Fehler im {job}-Backup",
                    "\n".join(recent_errors[-10:]))


@check("duplicati")
def duplicati():
    """Off-site copies: Duplicati reports every run to Kestra (flow duplicati-report)."""
    files = sorted(f for f in os.listdir(DUPLICATI_STATE_DIR) if f.endswith(".json")) \
        if os.path.isdir(DUPLICATI_STATE_DIR) else []
    if not files:
        finding("backup", "duplicati:no-reports", "high", "Keine Duplicati-Berichte vorhanden",
                f"{DUPLICATI_STATE_DIR} ist leer oder fehlt. Sendet Duplicati seine Ergebnisse an "
                "den Kestra-Flow duplicati-report? (services/duplicati/README.md)")
        return
    for fname in files:
        s = json.load(open(os.path.join(DUPLICATI_STATE_DIR, fname), encoding="utf-8"))
        name = s.get("name", fname[:-5])
        last_ok = datetime.fromisoformat(s["last_success"]) if s.get("last_success") else None
        if last_ok is None or NOW - last_ok > timedelta(hours=DUPLICATI_MAX_AGE_H):
            since = f"{last_ok:%d.%m.%Y %H:%M} UTC" if last_ok else "nie (seit Beginn der Berichte)"
            finding("backup", f"duplicati:no-success:{name}", "high",
                    f"Kein erfolgreiches Duplicati-Backup „{name}“ in den letzten {DUPLICATI_MAX_AGE_H} h",
                    f"Letzter Erfolg: {since}. Letzter Bericht: {s.get('last_report', '?')} "
                    f"({s.get('last_operation', '?')} {s.get('last_result', '?')}).")
        recent = [f for f in s.get("failures", [])
                  if NOW - datetime.fromisoformat(f["time"]) < timedelta(days=BACKUP_ERROR_LOOKBACK_D)]
        if recent:
            lines = [f"{datetime.fromisoformat(f['time']):%d.%m. %H:%M} UTC: {f.get('operation', '?')} "
                     f"{f.get('result', '?')}" + (f" -- {f['details'][0]}" if f.get("details") else "")
                     for f in recent[-10:]]
            finding("backup", f"duplicati:errors:{name}", "medium",
                    f"Duplicati „{name}“: {len(recent)} Fehlschlag/Fehlschläge in {BACKUP_ERROR_LOOKBACK_D} Tagen",
                    "\n".join(lines))


@check("cert")
def certs():
    data = json.load(open(ACME_JSON))
    for resolver, content in data.items():
        for cert in (content or {}).get("Certificates") or []:
            main = cert.get("domain", {}).get("main", "?")
            pem = base64.b64decode(cert["certificate"])
            r = run(["openssl", "x509", "-noout", "-enddate"], input=pem.decode())
            end = datetime.strptime(r.stdout.strip().split("=", 1)[1], "%b %d %H:%M:%S %Y %Z") \
                .replace(tzinfo=timezone.utc)
            days = (end - NOW).days
            if days < CERT_WARN_DAYS:
                finding("cert", f"expiry:{main}", "high" if days < 7 else "medium",
                        f"Zertifikat {main} läuft in {days} Tagen ab",
                        f"Ablauf: {end:%d.%m.%Y} (Resolver {resolver}). Traefik erneuert normalerweise "
                        "30 Tage vorher -- Log prüfen: docker logs traefik 2>&1 | grep -i acme")


@check("disk")
def disks():
    for m in DISK_MOUNTS:
        if not os.path.ismount(m):
            if m != "/":
                finding("disk", f"not-mounted:{m}", "high", f"{m} ist nicht eingehängt", "")
            continue
        u = shutil.disk_usage(m)
        pct = round(u.used * 100 / u.total)
        if pct >= DISK_WARN:
            finding("disk", f"usage:{m}", "high" if pct >= DISK_CRIT else "medium",
                    f"{m} ist zu {pct} % belegt",
                    f"frei: {u.free / 2**30:.1f} GiB von {u.total / 2**30:.1f} GiB")


@check("drift")
def host_checkout():
    owner = pwd.getpwuid(os.stat(REPO).st_uid).pw_name

    def git(*a):
        return run(["runuser", "-u", owner, "--", "git", "-C", REPO, *a])

    branch = git("rev-parse", "--abbrev-ref", "HEAD").stdout.strip()
    if branch != "main":
        finding("drift", "checkout-branch", "medium", f"Host-Klon steht auf Branch {branch} statt main",
                f"{REPO}: git checkout main; git pull")
    git("fetch", "-q", "origin")
    behind = git("rev-list", "--count", "HEAD..origin/main").stdout.strip()
    if behind.isdigit() and int(behind) > 0:
        finding("drift", "checkout-behind", "low", f"Host-Klon ist {behind} Commit(s) hinter main",
                f"{REPO}: git pull (update-on-merge hätte das normalerweise erledigt)")
    # porcelain: "XY path" -- do not strip(), the leading space is part of the status
    dirty = [l for l in git("status", "--porcelain", "--untracked-files=no").stdout.splitlines() if l.strip()]
    if dirty:
        files = [l[3:] for l in dirty][:20]
        finding("drift", "checkout-dirty", "medium", "Host-Klon hat lokale Änderungen an versionierten Dateien",
                "\n".join(files))


@check("trivy")
def trivy():
    path = os.path.join(STATE_DIR, "trivy.tsv")
    if not os.path.exists(path):
        finding("trivy", "no-result", "low", "Kein Trivy-Ergebnis vorhanden",
                f"{path} fehlt -- läuft der wöchentliche Flow trivy-scan?")
        return
    age = NOW - datetime.fromtimestamp(os.path.getmtime(path), timezone.utc)
    if age > timedelta(days=TRIVY_MAX_AGE_D):
        finding("trivy", "stale", "low", f"Letzter Trivy-Scan ist {age.days} Tage alt", path)
    # One finding for all images: "fixable" mostly means the image maintainer has to rebuild;
    # new image versions come through the update pipeline anyway. One issue per image was
    # 15 issues on the first run -- noise, not something to act on image by image.
    rows = []
    for line in open(path, encoding="utf-8"):
        if line.startswith("#") or not line.strip():
            continue
        crit, high, img, ids = (line.rstrip("\n").split("\t") + [""] * 4)[:4]
        if crit.isdigit() and int(crit) > 0:
            rows.append((int(crit), img, high, ids))
    if rows:
        rows.sort(reverse=True)
        finding("trivy", "critical", "medium",
                f"{len(rows)} Image(s) mit fixbaren CRITICAL-Lücken",
                "\n".join(f"{img}: CRITICAL {c}, HIGH {h}{'  (' + ids + ')' if ids else ''}"
                          for c, img, h, ids in rows)
                + "\n\nMeist muss der Image-Hersteller neu bauen. Prüfen, ob es eine neuere Version gibt "
                  "(Update-Pipeline / Supabase), sonst beobachten.")


@check("lynis")
def lynis():
    if not shutil.which("lynis"):
        raise RuntimeError("lynis ist nicht installiert (Ansible-Rolle base)")
    os.makedirs(STATE_DIR, exist_ok=True)
    report = os.path.join(STATE_DIR, "lynis-report.dat")
    r = run(["lynis", "audit", "system", "--quick", "--quiet", "--no-colors",
             "--report-file", report, "--log-file", os.path.join(STATE_DIR, "lynis.log")], timeout=900)
    if not os.path.exists(report):
        raise RuntimeError(f"kein Bericht, rc={r.returncode}: {r.stderr.strip()[:200]}")
    baseline = set(config_lines("lynis-baseline.txt") or [])
    for line in open(report, encoding="utf-8", errors="replace"):
        if not line.startswith("warning[]="):
            continue
        test_id, _, text = line.split("=", 1)[1].partition("|")
        text = text.split("|")[0]
        if test_id in baseline:
            continue
        finding("lynis", test_id, "medium", f"Lynis-Warnung {test_id}: {text}",
                "Bewusst akzeptiert? Dann die Test-ID in config/system-checks/lynis-baseline.txt eintragen.")


@check("ports")
def ports():
    r = run(["ss", "-H", "-tuln"])
    # UDP sockets in the ephemeral range are client sockets (DNS, NTP, mDNS) with a new
    # random port each time, not services -- they would be a new finding every day
    lo, hi = map(int, open("/proc/sys/net/ipv4/ip_local_port_range").read().split())
    listening = set()
    for line in r.stdout.splitlines():
        parts = line.split()
        if len(parts) < 5:
            continue
        proto, local = parts[0], parts[4]
        addr, _, port = local.rpartition(":")
        if addr.strip("[]").split("%")[0] in ("127.0.0.1", "::1", "127.0.0.53", "127.0.0.54"):
            continue
        if proto == "udp" and port.isdigit() and lo <= int(port) <= hi:
            continue
        listening.add(f"{proto} {port}")
    expected = config_lines("expected-ports.txt")
    if expected is None:
        raise RuntimeError("config/system-checks/expected-ports.txt fehlt; aktuell offen: "
                           + ", ".join(sorted(listening)))
    for p in sorted(listening - set(expected)):
        finding("ports", p.replace(" ", "/"), "medium", f"Unerwarteter offener Port {p}",
                "Nicht in config/system-checks/expected-ports.txt. Gewollt? Dann dort eintragen.\n"
                + run(["ss", "-H", "-tulnp", "sport", "=", ":" + p.split()[1]]).stdout.strip()[:500])


@check("expiry")
def expiries():
    for line in config_lines("expiries.tsv") or []:
        date_s, name, *hint = [x.strip() for x in line.split("\t")]
        days = (datetime.fromisoformat(date_s).replace(tzinfo=timezone.utc) - NOW).days
        if days < EXPIRY_WARN_DAYS:
            finding("expiry", name.lower().replace(" ", "-"), "high" if days < 7 else "medium",
                    f"{name} läuft in {days} Tagen ab ({date_s})", hint[0] if hint else "")


@check("apt")
def apt():
    sim = run(["apt-get", "-s", "-o", "Debug::NoLocking=1", "dist-upgrade"], timeout=300).stdout
    security = [l.split()[1] for l in sim.splitlines() if l.startswith("Inst ") and "-security" in l]
    log = "/var/log/unattended-upgrades/unattended-upgrades.log"
    last = datetime.fromtimestamp(os.path.getmtime(log), timezone.utc) if os.path.exists(log) else None
    if security and (last is None or NOW - last > timedelta(hours=APT_MAX_AGE_H)):
        finding("apt", "security-pending", "medium", f"{len(security)} Sicherheitsupdate(s) offen",
                (f"unattended-upgrades zuletzt: {last:%d.%m. %H:%M} UTC" if last else "kein unattended-upgrades-Log")
                + "\n" + ", ".join(security[:20]))
    flag = "/var/run/reboot-required"
    if os.path.exists(flag):
        age = NOW - datetime.fromtimestamp(os.path.getmtime(flag), timezone.utc)
        if age > timedelta(days=REBOOT_MAX_AGE_D):
            pkgs = open(flag + ".pkgs").read().split() if os.path.exists(flag + ".pkgs") else []
            finding("apt", "reboot-required", "low", f"Neustart seit {age.days} Tagen nötig",
                    "Pakete: " + (", ".join(sorted(set(pkgs))[:20]) or "-")
                    + "\nVault danach entsiegeln (vault-unseal).")


@check("ansible")
def ansible_drift():
    if not shutil.which("ansible-playbook"):
        raise RuntimeError("ansible ist nicht installiert (Ansible-Rolle base)")
    env = dict(os.environ, ANSIBLE_STDOUT_CALLBACK="ansible.posix.json", ANSIBLE_NOCOLOR="1")
    r = run(["ansible-playbook", "drift-check.yml", "-l", "thinkcentre", "-c", "local", "--check"],
            timeout=900, cwd=os.path.join(REPO, "ansible"), env=env)
    try:
        out = json.loads(r.stdout)
    except ValueError:
        raise RuntimeError(f"rc={r.returncode}: {(r.stderr or r.stdout).strip()[-300:]}")
    changed, failed = [], []
    for play in out.get("plays", []):
        for t in play.get("tasks", []):
            for host, res in t.get("hosts", {}).items():
                name = t["task"]["name"]
                if res.get("failed") or res.get("unreachable"):
                    failed.append(f"{name}: {str(res.get('msg', ''))[:150]}")
                elif res.get("changed"):
                    changed.append(name)
    if failed:
        finding("ansible", "failed", "medium", f"Ansible-Drift-Check: {len(failed)} Aufgabe(n) fehlgeschlagen",
                "\n".join(failed[:20]))
    if changed:
        finding("ansible", "drift", "medium", f"Ansible-Drift: {len(changed)} Aufgabe(n) würden etwas ändern",
                "\n".join(changed[:30]) + "\nPrüfen vom Laptop: ansible-playbook site.yml -l thinkcentre --check --diff -K --ask-vault-pass")


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else None
    for fn in (containers, backups, duplicati, certs, disks, host_checkout, trivy, lynis, ports, expiries, apt, ansible_drift):
        fn()
    doc = {"generated": NOW.isoformat(timespec="seconds"), "host": socket.gethostname(),
           "checks": ran, "errors": errors, "findings": findings}
    text = json.dumps(doc, ensure_ascii=False, indent=1)
    try:
        if out:
            open(out, "w").write(text)
        print(f"{len(findings)} Befund(e), {len(errors)} Check-Fehler, Checks: {', '.join(ran)}")
        for f in findings:
            print(f"  [{f['severity']}] {f['title']}")
        for e in errors:
            print(f"  [check-fehler] {e}")
    except OSError as e:
        print(f"FEHLER: {e}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
