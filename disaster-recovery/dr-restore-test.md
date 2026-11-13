# Halbjährlicher Restore-Test (Vorlage für Mindwtr)

Vorlage zum Kopieren in eine Mindwtr-Aufgabe. Alle 6 Monate und nach größeren Änderungen
an `ansible/` (neue Rolle, neuer Dienst mit eigenen Daten, Debian-Upgrade). Hintergrund:
`ansible/README.md`, ADR 006. Dauer: etwa 1,5 Stunden, davon rund 1 Stunde Wartezeit.

---

**Restore-Test Homelab (DR, #157)**

Vorher bereitlegen (Vaultwarden):
- [ ] „Ansible-Vault-Passwort“
- [ ] 3 der 5 Vault-Unseal-Keys
- [ ] keine Screenshots von Passwort-Eingaben, nichts in Chats einfügen

**1. ThinkCentre: Testdaten exportieren** (nach einem nächtlichen Backup, ca. 10 min)
```fish
cd /data/gitea/homelab
git checkout main; git pull
sudo bash scripts/maintenance/dr-test-export.sh
```
- [ ] endet mit „exported=…“, Archiv von heute Nacht

**2. Laptop: Testdaten holen und Repo aktualisieren**
```fish
cd ~/Dokumente/projekte/gitea/homelab
git checkout main; git pull
rsync -a --delete tc:/data/backup/drtest/ ~/.local/state/homelab-drtest/data/
```

**3. Laptop: Restore-Test starten** (ca. 55–60 min)
```fish
cd ~/Dokumente/projekte/gitea/homelab/ansible
./dr-test.sh restore
```
- [ ] Passwort-Abfragen: zweimal das **Ansible-Vault-Passwort**
- [ ] Bei der Pause: in einem **zweiten Terminal** mit der IP **aus diesem Lauf** entsiegeln:
  ```fish
  ssh -i ~/.local/state/homelab-drtest/id_ed25519 admin@<IP aus dem Prompt>
  docker exec -it vault vault operator unseal -address=http://127.0.0.1:8200
  ```
  dreimal mit drei verschiedenen Unseal-Keys, bis `Sealed false`, dann im ersten Terminal Enter

**4. Ergebnis prüfen**
- [ ] Ausgabe am Ende: alle `PLAY RECAP` mit `failed=0`
- [ ] „nicht gesund“: nur `nextcloud` (erwartet, im Test ohne Daten)
- [ ] Zeiten notieren: Host-Schicht, Borg-Restore, Vault, Dienste, RTO gesamt
- [ ] Optional in der VM:
  ```fish
  ssh -i ~/.local/state/homelab-drtest/id_ed25519 admin@<IP> 'docker ps --format "{{.Names}} {{.Status}}" | grep -v healthy'
  ```
  (nur `nextcloud`, die drei `*-vault-agent` mit `Exited (0)` und `loki` ohne Healthcheck)

**Bei einem Fehler**
- Log: Pfad steht am Ende der Ausgabe (`~/.local/state/homelab-drtest/logs/restore-*.log`)
- Nach einem Fix ab den Diensten weitermachen: `./dr-test.sh restore-continue`
- Gefundene Probleme in `ansible/README.md`, Abschnitt 6 „Lessons“ eintragen

**5. Aufräumen**
```fish
cd ~/Dokumente/projekte/gitea/homelab/ansible
./dr-test.sh destroy
rm -rf ~/.local/state/homelab-drtest/data
```
Auf dem ThinkCentre:
```fish
sudo rm -rf /data/backup/drtest
```
Die Testkopien enthalten den kompletten Inhalt von `/opt/docker`, deshalb nicht liegen lassen.

**6. Dokumentieren**
- [ ] RTO in `ansible/README.md`, Abschnitt 5 „Measured RTO“ ergänzen
- [ ] Kommentar in Issue #157 (oder neues Issue) mit Datum, Archiv und Zeiten
- [ ] Nächsten Test in Mindwtr in 6 Monaten anlegen

**Nebenbei prüfen**
- [ ] GitHub-Token des Spiegels: wann läuft er ab? (GitHub → Settings → Developer settings → Fine-grained tokens)
- [ ] Vault-Restore-Test (ADR 004) fällig? Nächster laut Plan: 2027-04
