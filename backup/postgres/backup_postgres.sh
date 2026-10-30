#!/usr/bin/env bash
# Postgres-Backup: logische Dumps (pg_dumpall) beider Postgres-Instanzen, geprüft und
# unter /data/backup/<host>/postgres abgelegt (von dort nimmt Duplicati sie nach OneDrive mit).
#
#   supabase  supabase-db  -- Update-Pipeline, CrowdSec-Alarme, ASN-Entscheidungen
#   shared    postgres     -- Authentik, Gitea, Kestra
#
# - pg_dumpall statt Dateikopie: eine Kopie des Datenverzeichnisses eines laufenden
#   Postgres ist nicht konsistent; der Dump schon (eine Transaktion pro Datenbank).
#   Enthält auch Rollen und alle Datenbanken der Instanz.
# - Passwörter verlassen die Container nicht: die Shell im Container liest sie selbst.
# - Prüfung: Exit-Status der ganzen Pipe, gzip -t und die Schlusszeile, die pg_dumpall
#   nur bei vollständigem Durchlauf schreibt. Erst dann wird die Datei umbenannt.
# - Fehler einer Instanz halten die andere nicht auf; der Status meldet beide.
# - Aufbewahrung: alle Dumps der letzten 14 Tage, dazu die Sonntags-Dumps der letzten
#   8 Wochen (wie beim Vault-Snapshot).
#
# Aufruf: sudo homelab-deploy backup-postgres   (Kestra-Flow backup-postgres, täglich)
#         oder direkt: sudo bash scripts/backup/backup_postgres.sh
#
# Restore (Beispiel shared, in einen Wegwerf-Container, nie direkt in die laufende Instanz):
#   docker run -d --name pg-restore-test --network none -e POSTGRES_PASSWORD=test postgres:<version>
#   gunzip -c shared-<stamp>.sql.gz | docker exec -i pg-restore-test psql -U postgres -v ON_ERROR_STOP=0
#   docker exec pg-restore-test psql -U postgres -l ; docker rm -f pg-restore-test
# Supabase: in ein supabase/postgres-Image derselben Version (es legt eigene Rollen/Schemas
# an; "already exists"-Meldungen beim Einspielen sind dort normal).
set -Eeuo pipefail

HOST_SHORT="$(hostname -s)"
TARGET="/data/backup/${HOST_SHORT}/postgres"
KEEP_DAYS=14
KEEP_WEEKLY_DAYS=56
STAMP="$(date +%Y%m%d-%H%M%S)"
START="$(date +%s)"
ERRORS=0

[ "$(id -u)" -eq 0 ] || { echo "FEHLER: muss als root laufen"; echo "Status: Fehlgeschlagen"; exit 1; }

umask 077
mkdir -p "$TARGET"
chmod 700 "$TARGET"

# dump <name> <container> <Kommando im Container, schreibt den Dump nach stdout>
dump() {
  local name=$1 container=$2 cmd=$3
  local out="${TARGET}/${name}-${STAMP}.sql.gz" t0 size
  t0=$(date +%s)
  if ! docker inspect -f '{{.State.Running}}' "$container" 2>/dev/null | grep -qx true; then
    echo "    ${name}: FEHLER - Container ${container} läuft nicht"; ERRORS=$((ERRORS + 1)); return
  fi
  if ! docker exec "$container" sh -c "$cmd" 2>"${out}.err" | gzip > "${out}.tmp"; then
    echo "    ${name}: FEHLER - Dump abgebrochen: $(tail -n 3 "${out}.err" | tr '\n' ' ')"
    rm -f "${out}.tmp" "${out}.err"; ERRORS=$((ERRORS + 1)); return
  fi
  rm -f "${out}.err"
  if ! gzip -t "${out}.tmp" || ! gunzip -c "${out}.tmp" | tail -n 5 | grep -q 'PostgreSQL database cluster dump complete'; then
    echo "    ${name}: FEHLER - Dump unvollständig (Schlusszeile fehlt)"
    rm -f "${out}.tmp"; ERRORS=$((ERRORS + 1)); return
  fi
  mv "${out}.tmp" "$out"
  size=$(numfmt --to=iec "$(stat -c %s "$out")")
  echo "    ${name}: OK -- $(basename "$out"), ${size}, $(( $(date +%s) - t0 ))s, Datenbanken: $(gunzip -c "$out" | grep -c '^\\connect ')"
}

echo "==> Postgres-Backup ${STAMP} auf ${HOST_SHORT}"
dump supabase supabase-db \
  '. /vault-secrets/db.env; PGPASSWORD="$POSTGRES_PASSWORD" exec pg_dumpall -h localhost -U postgres'
dump shared postgres \
  'PGPASSWORD="$(cat /vault-secrets/admin_password.txt)" exec pg_dumpall -h localhost -U "$POSTGRES_USER"'

# Aufbewahrung: < KEEP_DAYS Tage alles, < KEEP_WEEKLY_DAYS Tage nur Sonntage
DELETED=0
NOW=$(date +%s)
for f in "$TARGET"/*-*.sql.gz; do
  [ -e "$f" ] || continue
  d=$(basename "$f" | sed -E 's/^[a-z]+-([0-9]{8})-.*/\1/')
  ts=$(date -d "$d" +%s 2>/dev/null) || continue
  age_days=$(( (NOW - ts) / 86400 ))
  dow=$(date -d "$d" +%u)
  if [ "$age_days" -ge "$KEEP_DAYS" ] && { [ "$dow" != 7 ] || [ "$age_days" -ge "$KEEP_WEEKLY_DAYS" ]; }; then
    rm -f "$f"
    DELETED=$((DELETED + 1))
  fi
done
echo "    Aufbewahrung: $(find "$TARGET" -maxdepth 1 -name '*.sql.gz' | wc -l) Dumps vorhanden, ${DELETED} gelöscht"
echo "Dauer: $(( $(date +%s) - START ))s"
if [ "$ERRORS" -eq 0 ]; then echo "Status: Erfolgreich"; else echo "Status: Fehlgeschlagen (${ERRORS} Fehler)"; exit 1; fi
