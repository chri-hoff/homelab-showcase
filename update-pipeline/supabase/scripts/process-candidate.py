#!/usr/bin/env python3
"""Processes update candidates from Supabase (Issue #72, concept from #70).

    process-candidate.py pending   full run (docker-update-check)
    process-candidate.py release   Mindwtr status/release only (update-release, every 5 min.)

Called on every update check run (docker-update-check: cron or Telegram "checkversion")
right after record-candidates.py:

1. Every open candidate without a Mindwtr task (including backlog and earlier
   failures):
   - changelog summary via n8n (workflow changelog-summary) -> changelog_summary.
     If n8n is down, processing continues without a summary.
   - If the service already has an open update task (via another candidate that is not
     done yet), that task is updated to the new version. Otherwise a new task is created
     in the inbox + a Telegram message is sent.
   - task ID -> mindwtr_task_id.
2. Open candidates with a task but without a changelog (n8n was unreachable on the first
   run or had no mapping yet): fetch the changelog, add it to the task (only for the newest
   candidate of the task) and follow up via Telegram.
3. Every task whose candidates are all "done" is completed in Mindwtr ->
   mindwtr_task_closed_at.
4. Status from Mindwtr (only tasks in project MINDWTR_PROJECT):
   - "Next" = update released: set the target version in services to the newest
     candidate version (always, even for critical containers). Auto-deploy possible
     (updateable + deployable) -> candidates + task "Waiting", the export in the same run
     commits, update-on-merge deploys. Otherwise -> "Someday" + Telegram "please update manually".
   - new version for an already released task (Waiting) -> task back to the inbox,
     title/changelog updated to the new version
   - Done/Archived in Mindwtr -> candidates done (deliberately checked off)
   - inbox/someday/waiting -> mirrored into update_candidates.status
5. Candidates whose version the running container has reached or passed -> done.

An error on one candidate does not stop the others; exit 1 at the end if anything
failed. Version and image always come from Supabase; the task only carries the
candidate ID as a reference and is never read back.

All tasks live in Mindwtr project MINDWTR_PROJECT (default "Homelab"), section
MINDWTR_SECTION (default "Updates"); tasks of open candidates without a project or outside
the section are moved there, tasks in a different project stay where they are and are
ignored.

Stack updates (bundles) that are not possible yet (bundle_state pending/fresh) sit on
"Waiting" in Mindwtr; as soon as the stack can be updated (ready) they go back to the inbox.

Environment: SUPABASE_* (supabase_api.py), N8N_URL, N8N_WEBHOOK_SECRET, MINDWTR_URL,
MINDWTR_TOKEN, BOT_TOKEN, CHAT_ID, optional TELEGRAM_API (default api.telegram.org),
optional MINDWTR_PROJECT (default "Homelab"), optional MINDWTR_SECTION (default "Updates").
"""

import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timedelta, timezone

from supabase_api import request

CANDIDATE_FIELDS = "id,service,image,new_version,status,changelog_summary,mindwtr_task_id,bundle_state,bundle_note"
OPEN_TASK_STATUSES = {"inbox", "next", "waiting", "someday", "reference"}
TELEGRAM_MAX = 3500


class CandidateError(Exception):
    pass


def http_json(method, url, body=None, headers=None, timeout=30):
    """Returns (status, json|text). Network error -> (None, error text)."""
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method,
                                 headers={"Content-Type": "application/json", **(headers or {})})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            raw = resp.read()
            return resp.status, (json.loads(raw) if raw else None)
    except urllib.error.HTTPError as e:
        raw = e.read().decode(errors="replace")
        try:
            return e.code, json.loads(raw)
        except ValueError:
            return e.code, raw[:300]
    except (urllib.error.URLError, TimeoutError, OSError) as e:
        return None, str(e)


def mindwtr(method, path, body=None):
    return http_json(method, os.environ["MINDWTR_URL"].rstrip("/") + path, body,
                     {"Authorization": "Bearer " + os.environ["MINDWTR_TOKEN"]})


_project = {}


def project_id():
    """ID of the Mindwtr project MINDWTR_PROJECT (by title, case-insensitive), cached.
    If missing: None + warning -- tasks then land in the inbox without a project."""
    if "id" not in _project:
        name = os.environ.get("MINDWTR_PROJECT", "Homelab")
        status, body = mindwtr("GET", "/v1/projects?limit=500")
        if status != 200 or not isinstance(body, dict):
            raise CandidateError(f"Mindwtr GET /v1/projects -> {status}: {str(body)[:300]}")
        match = [p for p in body.get("projects", []) if p.get("title", "").strip().lower() == name.lower()]
        _project["id"] = match[0]["id"] if match else None
        if not match:
            seen = sorted(p.get("title", "?") for p in body.get("projects", []))
            print(f"  WARNUNG: Mindwtr-Projekt '{name}' nicht gefunden -- Aufgaben ohne Projekt. "
                  f"Mit diesem Token sichtbar: {', '.join(seen) or 'keine Projekte'} "
                  "(anderer Token als die App? Mindwtr trennt Daten strikt pro Token)")
    return _project["id"]


_section = {}


def section_id(pid):
    """ID of the section MINDWTR_SECTION in the project (by title, case-insensitive),
    cached. If missing: None + warning -- tasks then land in the project without a section."""
    if "id" not in _section:
        name = os.environ.get("MINDWTR_SECTION", "Updates")
        status, body = mindwtr("GET", f"/v1/sections?projectId={urllib.parse.quote(pid)}&limit=500")
        if status != 200 or not isinstance(body, dict):
            raise CandidateError(f"Mindwtr GET /v1/sections -> {status}: {str(body)[:300]}")
        match = [s for s in body.get("sections", []) if s.get("title", "").strip().lower() == name.lower()]
        _section["id"] = match[0]["id"] if match else None
        if not match:
            print(f"  WARNUNG: Abschnitt '{name}' im Mindwtr-Projekt nicht gefunden -- Aufgaben ohne Abschnitt")
    return _section["id"]


def placement():
    """{projectId, sectionId} for update tasks (as far as available)."""
    pid = project_id()
    if not pid:
        return {}
    sid = section_id(pid)
    return {"projectId": pid, **({"sectionId": sid} if sid else {})}


def bundle_blocked(c):
    """Stack update not possible yet (upstream does not have the version, or only recently)."""
    return c.get("bundle_state") in ("pending", "fresh")


def mindwtr_task(task_id):
    """Task, or None if deleted in Mindwtr. Other errors -> CandidateError
    (don't guess: better abort than create a duplicate task)."""
    status, body = mindwtr("GET", f"/v1/tasks/{task_id}")
    if status == 404:
        return None
    if status != 200 or not isinstance(body, dict) or "task" not in body:
        raise CandidateError(f"Mindwtr GET {task_id} -> {status}: {str(body)[:300]}")
    return body["task"]


def patch_candidates(query, fields):
    request("PATCH", f"update_candidates?{query}", fields, prefer="return=minimal")


def fetch_summary(c):
    status, body = http_json(
        "POST", os.environ["N8N_URL"], {"image": f"{c['image']}:{c['new_version']}"},
        {"x-webhook-secret": os.environ["N8N_WEBHOOK_SECRET"]}, timeout=120)
    if status != 200 or not isinstance(body, dict):
        print(f"  WARNUNG: n8n changelog-summary nicht verfuegbar ({status}: {str(body)[:200]})")
        return None
    if not body.get("mapped"):
        print(f"  kein Changelog-Mapping in n8n fuer {c['image']}")
        return None
    return body.get("summary")


def label(c):
    """Service from versions.yaml, otherwise the image (e.g. supabase/gotrue)."""
    return c["service"] or c["image"]


def open_task_of_service(c):
    """(task ID, status) of another still-open candidate of the same service (or the
    same image if there is no service) -- if the task is still open in Mindwtr,
    otherwise (None, None)."""
    same = (f"service=eq.{urllib.parse.quote(c['service'])}" if c["service"]
            else f"service=is.null&image=eq.{urllib.parse.quote(c['image'], safe='')}")
    rows = request(
        "GET",
        f"update_candidates?{same}&id=neq.{c['id']}"
        "&mindwtr_task_id=not.is.null&status=neq.done&select=mindwtr_task_id&order=id.desc&limit=1",
    ) or []
    if not rows:
        return None, None
    task_id = rows[0]["mindwtr_task_id"]
    task = mindwtr_task(task_id)
    if task is None:
        print(f"  bisherige Aufgabe {task_id} in Mindwtr geloescht -> neue Aufgabe")
        return None, None
    if task.get("status") in OPEN_TASK_STATUSES:
        return task_id, task.get("status")
    print(f"  bisherige Aufgabe {task_id} ist {task.get('status')} -> neue Aufgabe")
    return None, None


def task_text(c, summary):
    title = f"Update {label(c)} → {c['new_version']}"
    description = (
        (f"{c['bundle_note']}\n\n" if c.get("bundle_note") else "")
        + (summary or "Kein Changelog verfügbar – bitte Release-Notes manuell prüfen.")
        + f"\n\n---\nSupabase update_candidates #{c['id']} · Image {c['image']}"
    )
    return title, description


# ---------------------------------------------------------------------------
# Bundles: images that are only updated as an upstream-tested combination
# ---------------------------------------------------------------------------
def upstream_compose(repo, path, until=None):
    """(date, {image: tag}) of the newest upstream commit that changes path (optionally
    before until). None on error -- the check then continues without bundle tagging."""
    q = f"path={urllib.parse.quote(path)}&per_page=1" + (f"&until={until}" if until else "")
    status, body = http_json("GET", f"https://api.github.com/repos/{repo}/commits?{q}",
                             headers={"Accept": "application/vnd.github+json"})
    if status != 200 or not isinstance(body, list) or not body:
        print(f"  WARNUNG: Upstream {repo} nicht abrufbar ({status}) -- Bundle-Kennzeichnung entfaellt")
        return None
    sha, when = body[0]["sha"], body[0]["commit"]["committer"]["date"][:10]
    try:
        with urllib.request.urlopen(f"https://raw.githubusercontent.com/{repo}/{sha}/{path}", timeout=30) as r:
            text = r.read().decode()
    except (urllib.error.URLError, OSError) as e:
        print(f"  WARNUNG: Upstream-Compose {repo}@{sha[:7]} nicht lesbar ({e})")
        return None
    images = {}
    for m in re.finditer(r"^\s*image:\s*([^\s#]+)", text, re.M):
        ref = m.group(1).split("@")[0]
        if ":" in ref.split("/")[-1]:
            img, tag = ref.rsplit(":", 1)
            images[img] = tag
    return when, images


def check_bundles():
    """Check open candidates of bundle members against the upstream state and set
    bundle_state/bundle_note. When a candidate newly becomes "ready", one Telegram message
    per bundle; task texts are updated accordingly."""
    bundles = {b["name"]: b for b in request("GET", "bundles?select=name,source_repo,compose_path,min_age_days") or []}
    members = {s["name"]: s for s in request("GET", "services?bundle=not.is.null&select=name,bundle,image") or []}
    if not bundles or not members:
        return
    rows = request("GET", "update_candidates?status=neq.done&service=not.is.null"
                          f"&select={CANDIDATE_FIELDS}&order=id") or []
    rows = [c for c in rows if c["service"] in members]
    if not rows:
        return
    newest_of_task = {}
    for c in request("GET", "update_candidates?mindwtr_task_id=not.is.null&status=neq.done"
                            "&select=id,mindwtr_task_id&order=id") or []:
        newest_of_task[c["mindwtr_task_id"]] = c["id"]
    now = datetime.now(timezone.utc)
    ready_now = {}
    for name, b in bundles.items():
        cands = [c for c in rows if members[c["service"]]["bundle"] == name]
        if not cands:
            continue
        latest = upstream_compose(b["source_repo"], b["compose_path"])
        cutoff = (now - timedelta(days=b["min_age_days"])).strftime("%Y-%m-%dT%H:%M:%SZ")
        mature = upstream_compose(b["source_repo"], b["compose_path"], until=cutoff)
        if not latest or not mature:
            continue
        for c in cands:
            image = members[c["service"]]["image"]
            m_tag, l_tag = mature[1].get(image), latest[1].get(image)
            if m_tag and ver(m_tag) >= ver(c["new_version"]):
                state = "ready"
                note = (f"✅ Teil des Stacks {name}: Upstream-Stand vom {mature[0]} (mind. "
                        f"{b['min_age_days']} Tage alt) enthält {m_tag} – Stack-Update möglich "
                        "(Tags und volumes/ zusammen übernehmen).")
            elif l_tag and ver(l_tag) >= ver(c["new_version"]):
                state = "fresh"
                ab = (datetime.fromisoformat(latest[0]) + timedelta(days=b["min_age_days"])).date()
                note = (f"🔗 Teil des Stacks {name}: seit Kurzem im Upstream (Stand {latest[0]}), "
                        f"Stack-Update ab {ab} empfohlen. Nicht einzeln updaten.")
            else:
                state = "pending"
                note = (f"🔗 Teil des Stacks {name}: Upstream getestet ist {m_tag or 'unbekannt'} "
                        f"(Stand {mature[0]}). Nicht einzeln updaten, warten bis Upstream nachzieht.")
            if (state, note) == (c["bundle_state"], c["bundle_note"]):
                continue
            patch_candidates(f"id=eq.{c['id']}", {"bundle_state": state, "bundle_note": note})
            if state == "ready" and c["bundle_state"] != "ready":
                ready_now.setdefault(name, []).append(f"{label(c)} {c['new_version']}")
            c["bundle_state"], c["bundle_note"] = state, note
            print(f"#{c['id']} {label(c)} {c['new_version']}: Bundle {name} -> {state}")
            # Update the task text (only for the newest candidate of the task)
            if c["mindwtr_task_id"] and newest_of_task.get(c["mindwtr_task_id"]) == c["id"]:
                title, description = task_text(c, c["changelog_summary"])
                st, body = mindwtr("PATCH", f"/v1/tasks/{c['mindwtr_task_id']}", {"description": description})
                if st not in (200, 404):
                    raise CandidateError(f"Mindwtr PATCH {c['mindwtr_task_id']} -> {st}: {str(body)[:300]}")
    for name, items in ready_now.items():
        telegram(f"✅ Stack-Update möglich: {name}\nDer Upstream-Stand ist alt genug und enthält:\n"
                 + "\n".join(f"• {i}" for i in items)
                 + "\n\nTags und volumes/ zusammen aus diesem Upstream-Stand übernehmen.")


def telegram(text):
    api = os.environ.get("TELEGRAM_API", "https://api.telegram.org").rstrip("/")
    status, body = http_json("POST", f"{api}/bot{os.environ['BOT_TOKEN']}/sendMessage",
                             {"chat_id": os.environ["CHAT_ID"], "text": text})
    if status != 200:
        print(f"  WARNUNG: Telegram fehlgeschlagen ({status}: {str(body)[:200]})")


def process_new(c):
    print(f"#{c['id']} {label(c)} {c['new_version']}:")
    summary = c["changelog_summary"] or fetch_summary(c)
    if summary and not c["changelog_summary"]:
        patch_candidates(f"id=eq.{c['id']}", {"changelog_summary": summary})

    title, description = task_text(c, summary)
    task_id, task_status = open_task_of_service(c)
    where = placement()
    blocked = bundle_blocked(c)
    if task_id:
        fields = {"title": title, "description": description, **where}
        # Already released (Waiting), now there is a newer version -> decide again.
        # Blocked stack updates stay on Waiting (sync_statuses keeps that in line).
        back_to_inbox = task_status == "waiting" and not blocked
        if back_to_inbox:
            fields["status"] = "inbox"
        status, body = mindwtr("PATCH", f"/v1/tasks/{task_id}", fields)
        if status != 200:
            raise CandidateError(f"Mindwtr PATCH {task_id} -> {status}: {str(body)[:300]}")
        print(f"  bestehende Aufgabe {task_id} auf {c['new_version']} aktualisiert"
              f"{' und zurueck in den Eingang (war freigegeben)' if back_to_inbox else ''} (kein Telegram)")
    else:
        status, body = mindwtr("POST", "/v1/tasks", {
            "title": title,
            "props": {"status": "waiting" if blocked else "inbox", "tags": ["#update"],
                      "description": description, **where},
        })
        if status != 201 or not isinstance(body, dict) or "task" not in body:
            raise CandidateError(f"Mindwtr POST /v1/tasks -> {status}: {str(body)[:300]}")
        task_id = body["task"]["id"]
        print(f"  neue Mindwtr-Aufgabe {task_id}")
        text = f"🔔 Update verfügbar: {label(c)} {c['new_version']}\n\n"
        if c.get("bundle_note"):
            text += c["bundle_note"] + "\n\n"
        text += (summary or "Kein Changelog verfügbar – bitte manuell prüfen.")[:TELEGRAM_MAX]
        text += "\n\nAufgabe in Mindwtr angelegt" + (
            f" (Projekt {os.environ.get('MINDWTR_PROJECT', 'Homelab')}" if where else " (Inbox") + (
            ", Status Warten bis der Stack nachzieht)." if blocked else ").")
        telegram(text)

    patch_candidates(f"id=eq.{c['id']}", {"mindwtr_task_id": task_id})


def backfill_summary(c, newest_of_task):
    """Fetch the changelog for a candidate with a task. True if it was added."""
    summary = fetch_summary(c)
    if not summary:
        return False
    patch_candidates(f"id=eq.{c['id']}", {"changelog_summary": summary})
    if newest_of_task:
        title, description = task_text(c, summary)
        status, body = mindwtr("PATCH", f"/v1/tasks/{c['mindwtr_task_id']}", {"title": title, "description": description})
        if status not in (200, 404):
            raise CandidateError(f"Mindwtr PATCH {c['mindwtr_task_id']} -> {status}: {str(body)[:300]}")
    print(f"#{c['id']} {label(c)} {c['new_version']}: Changelog nachgereicht")
    telegram(f"📝 Changelog nachgereicht: {label(c)} {c['new_version']}\n\n{summary[:TELEGRAM_MAX]}")
    return True


def ver(s):
    """Same numeric comparison as in docker-update-check.sh."""
    nums = re.findall(r"\d+", s or "")
    return [int(x) for x in nums] if nums else [0]


MINDWTR_TO_CANDIDATE = {"inbox": "inbox", "someday": "someday", "reference": "someday",
                        "waiting": "waiting", "done": "done", "archived": "done"}


def set_candidate_status(cands, status):
    ids = [str(c["id"]) for c in cands if c["status"] != status]
    if ids:
        patch_candidates(f"id=in.({','.join(ids)})", {"status": status})
    return len(ids)


def release(task_id, cands):
    """Task is on "Next": release the update to the newest candidate version.
    The target version is always set (even for critical containers -- versions.yaml shows
    the goal, version_drift the open deviation). Auto-deploy possible -> task "Waiting";
    otherwise -> "Someday" + Telegram, so it is visible what has to be done manually."""
    target = max(cands, key=lambda c: ver(c["new_version"]))
    rows = request("GET", f"services?name=eq.{urllib.parse.quote(target['service'] or '')}"
                          "&select=name,version,updateable,deployable,stack,bundle") or []
    svc = rows[0] if rows else None
    if svc and svc.get("bundle"):
        # No single-image update: the target stays, the stack is raised as a whole. Not
        # possible yet -> Waiting (comes back to the inbox by itself once "ready"),
        # otherwise Someday until the stack has been raised.
        new_status = "waiting" if bundle_blocked(target) else "someday"
        msg = (f"🔗 {label(target)} → {target['new_version']} gehört zum Stack {svc['bundle']}: "
               "kein Einzel-Update.\n" + (target.get("bundle_note") or "")
               + ("\nAufgabe steht auf 'Warten', bis ein Stack-Update möglich ist." if new_status == "waiting"
                  else "\nAufgabe steht unter 'Irgendwann', bis der Stack angehoben ist."))
        print(f"#{target['id']} {label(target)}: Bundle {svc['bundle']}, kein Einzel-Update -> {new_status}")
        set_candidate_status(cands, new_status)
        status, body = mindwtr("PATCH", f"/v1/tasks/{task_id}", {"status": new_status})
        if status != 200:
            raise CandidateError(f"Mindwtr PATCH {task_id} -> {status}: {str(body)[:300]}")
        telegram(msg)
        return False
    if svc and ver(target["new_version"]) > ver(svc["version"]):
        request("PATCH", f"services?name=eq.{urllib.parse.quote(svc['name'])}",
                {"version": target["new_version"]}, prefer="return=minimal")
    auto = bool(svc and svc["updateable"] and svc["deployable"])
    if auto:
        msg = (f"🚀 Update freigegeben: {label(target)} {svc['version']} → {target['new_version']}\n"
               "versions.yaml wird in diesem Check-Lauf committet, update-on-merge deployt.")
        print(f"#{target['id']} {label(target)}: freigegeben, Soll -> {target['new_version']}")
    else:
        if not svc:
            reason = "kein Eintrag in services"
        elif not svc["updateable"]:
            reason = "updateable: false (nie automatisch)"
        else:
            reason = "nicht ueber versions.yaml deploybar (Version steht im Compose)"
        stack = (svc or {}).get("stack") or "?"
        msg = (f"⚠️ Update freigegeben, aber kein Auto-Deploy: {label(target)} → {target['new_version']}\n"
               f"Grund: {reason}\nSoll-Version ist gesetzt -- bitte manuell deployen (services/{stack}).\n"
               "Aufgabe steht in Mindwtr unter 'Irgendwann', bis die Version laeuft.")
        print(f"#{target['id']} {label(target)}: Soll -> {target['new_version']}, manuell deployen ({reason})")
    new_status = "waiting" if auto else "someday"
    set_candidate_status(cands, new_status)
    status, body = mindwtr("PATCH", f"/v1/tasks/{task_id}", {"status": new_status})
    if status != 200:
        raise CandidateError(f"Mindwtr PATCH {task_id} -> {status}: {str(body)[:300]}")
    telegram(msg)
    return True  # target set -> export needed


def sync_statuses(pid):
    """Mirror Mindwtr task statuses (project only) to Supabase; "next" = release.
    Before that: move the task into the section and sort stack updates by bundle_state
    (blocked -> Waiting, possible -> back to the inbox).
    Returns: (released, mirrored)"""
    rows = request("GET", "update_candidates?mindwtr_task_id=not.is.null&status=neq.done"
                          f"&mindwtr_task_closed_at=is.null&select={CANDIDATE_FIELDS}&order=id") or []
    by_task = {}
    for c in rows:
        by_task.setdefault(c["mindwtr_task_id"], []).append(c)
    sid = section_id(pid)
    released = mirrored = 0
    for task_id, cands in by_task.items():
        task = mindwtr_task(task_id)
        if task is None or task.get("projectId") != pid:
            continue  # only count tasks in the project
        st = task.get("status")
        target = max(cands, key=lambda c: ver(c["new_version"]))
        fields = {"sectionId": sid} if sid and task.get("sectionId") != sid else {}
        if st in ("inbox", "someday") and bundle_blocked(target):
            fields["status"] = "waiting"
        elif st == "waiting" and target.get("bundle_state") == "ready":
            fields["status"] = "inbox"
        if fields:
            status, body = mindwtr("PATCH", f"/v1/tasks/{task_id}", fields)
            if status != 200:
                raise CandidateError(f"Mindwtr PATCH {task_id} -> {status}: {str(body)[:300]}")
            if "status" in fields:
                print(f"#{target['id']} {label(target)}: Stack {target['bundle_state']} -> Aufgabe {st} -> {fields['status']}")
                st = fields["status"]
        if st == "next":
            # Always handle stack updates: their candidates are already on waiting while Waiting
            if target.get("bundle_state") or any(c["status"] != "waiting" for c in cands):
                released += release(task_id, cands)
        elif st in MINDWTR_TO_CANDIDATE:
            mirrored += set_candidate_status(cands, MINDWTR_TO_CANDIDATE[st])
    return released, mirrored


def supersede():
    """Open candidates whose version the running container has reached/passed -> done."""
    running = {s["name"]: s["running_tag"] for s in
               request("GET", "services?running_tag=not.is.null&select=name,running_tag") or []}
    rows = request("GET", f"update_candidates?status=neq.done&service=not.is.null&select={CANDIDATE_FIELDS}") or []
    done = [c for c in rows if c["service"] in running and ver(running[c["service"]]) >= ver(c["new_version"])]
    for c in done:
        print(f"#{c['id']} {label(c)} {c['new_version']}: laeuft bereits {running[c['service']]} -> done")
    return set_candidate_status(done, "done")


def close_task(task_id, candidates):
    """All candidates of the task are done -> complete the task in Mindwtr."""
    versions = ", ".join(f"#{c['id']} {label(c)} {c['new_version']}" for c in candidates)
    task = mindwtr_task(task_id)
    if task is None:
        print(f"Aufgabe {task_id} ({versions}) existiert in Mindwtr nicht mehr")
    elif task.get("status") in OPEN_TASK_STATUSES:
        status, body = mindwtr("PATCH", f"/v1/tasks/{task_id}", {"status": "done"})
        if status != 200:
            raise CandidateError(f"Mindwtr PATCH {task_id} -> {status}: {str(body)[:300]}")
        print(f"Aufgabe {task_id} erledigt ({versions})")
    else:
        print(f"Aufgabe {task_id} war schon {task.get('status')} ({versions})")
    now = datetime.now(timezone.utc).isoformat()
    patch_candidates(f"mindwtr_task_id=eq.{task_id}&status=eq.done", {"mindwtr_task_closed_at": now})


def close_done_tasks():
    """Complete tasks whose candidates are all done. Only complete when no candidate of the
    task is still open (otherwise a newer version is already listed there).
    Returns: (closed, failed)"""
    rows = request("GET", "update_candidates?mindwtr_task_id=not.is.null&mindwtr_task_closed_at=is.null"
                          f"&select={CANDIDATE_FIELDS}&order=id") or []
    by_task = {}
    for c in rows:
        by_task.setdefault(c["mindwtr_task_id"], []).append(c)
    to_close = {t: cs for t, cs in by_task.items() if all(c["status"] == "done" for c in cs)}
    failed = 0
    for task_id, cs in to_close.items():
        try:
            close_task(task_id, cs)
        except CandidateError as e:
            failed += 1
            print(f"FEHLER: {e}")
    return len(to_close) - failed, failed


def cmd_release():
    """Mindwtr part only (flow update-release, every few minutes): read status,
    release "Next", mirror, close finished tasks. No Docker Hub check, no n8n.
    If anything was released, RELEASE_MARKER is created -> the flow then exports
    versions.yaml (otherwise no git clone)."""
    failed = 0
    released = mirrored = 0
    try:
        pid = project_id()
        if pid:
            released, mirrored = sync_statuses(pid)
    except CandidateError as e:
        failed += 1
        print(f"FEHLER: {e}")
    superseded = supersede()
    closed, close_failed = close_done_tasks()
    failed += close_failed
    if released and os.environ.get("RELEASE_MARKER"):
        open(os.environ["RELEASE_MARKER"], "w").close()
    if released or mirrored or superseded or closed or failed:
        print(f"Freigabe-Lauf: {released} freigegeben, {mirrored} Status gespiegelt, "
              f"{superseded} durch laufende Version erledigt, {closed} Aufgabe(n) geschlossen, {failed} Fehler")
    else:
        print("Freigabe-Lauf: nichts zu tun.")
    if failed:
        sys.exit(1)


def cmd_pending():
    failed = 0
    try:
        check_bundles()
    except CandidateError as e:
        failed += 1
        print(f"FEHLER: {e}")

    new = request("GET", f"update_candidates?mindwtr_task_id=is.null&status=neq.done"
                         f"&select={CANDIDATE_FIELDS}&order=id") or []
    for c in new:
        try:
            process_new(c)
        except CandidateError as e:
            failed += 1
            print(f"  FEHLER: {e}")

    # Open candidates with a task but without a changelog -> catch up. Without a mapping
    # in n8n this stays a short n8n call per run (no Claude call).
    missing = request("GET", "update_candidates?mindwtr_task_id=not.is.null&changelog_summary=is.null"
                             f"&status=neq.done&mindwtr_task_closed_at=is.null&select={CANDIDATE_FIELDS}&order=id") or []
    newest = {}
    for c in request("GET", "update_candidates?mindwtr_task_id=not.is.null&status=neq.done"
                            "&select=id,mindwtr_task_id&order=id") or []:
        newest[c["mindwtr_task_id"]] = c["id"]
    backfilled = 0
    for c in missing:
        try:
            backfilled += backfill_summary(c, newest.get(c["mindwtr_task_id"]) == c["id"])
        except CandidateError as e:
            failed += 1
            print(f"  FEHLER: {e}")

    # Move tasks of open candidates WITHOUT a project into the project/section (tasks
    # created before project assignment existed). Tasks in a different project stay there
    # -- deliberately excluded, they are then neither released nor mirrored. sync_statuses
    # takes care of the section inside the project.
    moved = 0
    pid = None
    try:
        pid = project_id()
        where = placement()
        open_tasks = {c["mindwtr_task_id"] for c in request(
            "GET", "update_candidates?mindwtr_task_id=not.is.null&status=neq.done"
                   "&mindwtr_task_closed_at=is.null&select=mindwtr_task_id") or []}
        for task_id in sorted(open_tasks) if pid else []:
            task = mindwtr_task(task_id)
            if task is not None and not task.get("projectId"):
                status, body = mindwtr("PATCH", f"/v1/tasks/{task_id}", where)
                if status != 200:
                    raise CandidateError(f"Mindwtr PATCH {task_id} -> {status}: {str(body)[:300]}")
                moved += 1
    except CandidateError as e:
        failed += 1
        print(f"FEHLER: {e}")

    # Status from Mindwtr: "Next" = release, otherwise mirror
    released = mirrored = 0
    try:
        if pid:
            released, mirrored = sync_statuses(pid)
    except CandidateError as e:
        failed += 1
        print(f"FEHLER: {e}")
    superseded = supersede()

    closed, close_failed = close_done_tasks()
    failed += close_failed

    print(f"Kandidaten: {len(new)} neu abgearbeitet, {backfilled} Changelog(s) nachgereicht, "
          f"{moved} Aufgabe(n) ins Projekt verschoben, {released} freigegeben, {mirrored} Status gespiegelt, "
          f"{superseded} durch laufende Version erledigt, {closed} Aufgabe(n) geschlossen, {failed} Fehler")
    if failed:
        sys.exit(1)


def main():
    commands = {"pending": cmd_pending, "release": cmd_release}
    if len(sys.argv) != 2 or sys.argv[1] not in commands:
        sys.exit("Aufruf: process-candidate.py pending|release")
    commands[sys.argv[1]]()


if __name__ == "__main__":
    main()
