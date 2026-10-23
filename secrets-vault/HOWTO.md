# How to: put a service behind Vault

A step-by-step guide to giving a container its secrets from Vault, using the direct-entrypoint
pattern. The running example is Vaultwarden
([`examples/direct-entrypoint-vaultwarden/`](examples/direct-entrypoint-vaultwarden/docker-compose.yaml)).
Replace `vaultwarden` with your service name everywhere.

All commands run on the Docker host. Vault has no published port, so the Vault CLI is used
inside the container (`docker exec vault vault ...`).

## 0. One-time Vault setup

Skip this if Vault already has the `homelab` KV mount and AppRole auth.

```bash
docker compose -f vault/docker-compose.yaml up -d
docker exec -it vault vault operator init      # store unseal keys + root token safely
scripts/vault-unseal.fish                      # or: vault operator unseal (3x)

docker exec -it vault vault login -address=http://localhost:8200
docker exec vault vault secrets enable -address=http://localhost:8200 -path=homelab kv-v2
docker exec vault vault auth enable    -address=http://localhost:8200 approle
```

## 1. Check what the image ships

The pattern depends on the tools inside the image. Check before you decide:

```bash
docker run --rm --entrypoint sh vaultwarden/server:latest -c 'which curl wget jq python3'
```

- `curl` (or `wget`) present: use the **direct entrypoint** (this guide).
- None of them, or the entrypoint must not be replaced (official database images): use the
  **sidecar** pattern, see [`examples/sidecar-mariadb/`](examples/sidecar-mariadb/docker-compose.yaml).

## 2. Store the secrets

Log in first. Policy, AppRole and KV writes return `403 permission denied` without a token.

```bash
docker exec -it vault vault login -address=http://localhost:8200
```

The easiest way is the Vault UI: **homelab/ → Create secret**, path `services/vaultwarden`,
keys `admin_token` and `database_url`. From the CLI, read the value from stdin so it does not
end up in your shell history:

```bash
docker exec -i vault vault kv put -address=http://localhost:8200 \
  -mount=homelab services/vaultwarden admin_token=-          # paste value, then Ctrl-D
docker exec -i vault vault kv patch -address=http://localhost:8200 \
  -mount=homelab services/vaultwarden database_url=-         # add more keys with patch
```

Several services can share one path (here: `services/smtp` for SMTP, also read by
Authentik), so a value exists only once.

## 3. Policy and AppRole

A read-only policy on exactly the paths this service needs. KV v2 policies need the `data/`
segment in the path.

```bash
echo 'path "homelab/data/services/vaultwarden" { capabilities = ["read"] }
path "homelab/data/services/smtp"      { capabilities = ["read"] }' \
| docker exec -i vault vault policy write -address=http://localhost:8200 vaultwarden-ro -

docker exec vault vault write -address=http://localhost:8200 auth/approle/role/vaultwarden \
  token_policies=vaultwarden-ro token_ttl=15m token_max_ttl=15m secret_id_ttl=0
```

The token is only needed for a few seconds at startup, so a short TTL is enough.
`secret_id_ttl=0` means the secret ID never expires. That trades rotation for a container that
can always restart on its own.

## 4. Bootstrap credentials as Docker secrets

Write `role_id` and `secret_id` straight into root-only files, without printing them:

```bash
sudo install -d -m 700 /opt/docker/secrets
docker exec vault vault read -address=http://localhost:8200 -field=role_id \
  auth/approle/role/vaultwarden/role-id \
  | sudo tee /opt/docker/secrets/vaultwarden_vault_role_id.txt > /dev/null
docker exec vault vault write -address=http://localhost:8200 -f -field=secret_id \
  auth/approle/role/vaultwarden/secret-id \
  | sudo tee /opt/docker/secrets/vaultwarden_vault_secret_id.txt > /dev/null
sudo chmod 600 /opt/docker/secrets/vaultwarden_vault_*_id.txt
```

Register both files in `/opt/docker/secrets/secrets.yaml`, which every compose file includes
(template: [`secrets.yaml.example`](secrets.yaml.example)):

```yaml
secrets:
  vaultwarden_vault_role_id:
    file: /opt/docker/secrets/vaultwarden_vault_role_id.txt
  vaultwarden_vault_secret_id:
    file: /opt/docker/secrets/vaultwarden_vault_secret_id.txt
```

Images that run as non-root cannot read mode-600 root files through Docker secrets. For those,
use mode 644 on these two files (they only allow reading this service's paths).

## 5. Compose file

Three parts, all in the example:

```yaml
include:
  - /opt/docker/secrets/secrets.yaml          # makes the secrets above known

services:
  vaultwarden:
    secrets:
      - vaultwarden_vault_role_id               # mounted at /run/secrets/<name>
      - vaultwarden_vault_secret_id
    entrypoint:
      - /bin/sh
      - -c
      - |
        set -e
        ROLE_ID=$$(cat /run/secrets/vaultwarden_vault_role_id)
        SECRET_ID=$$(cat /run/secrets/vaultwarden_vault_secret_id)
        VAULT_TOKEN=$$(curl -sf -X POST \
          -d "{\"role_id\":\"$$ROLE_ID\",\"secret_id\":\"$$SECRET_ID\"}" \
          http://vault:8200/v1/auth/approle/login \
          | grep -o '"client_token":"[^"]*"' | cut -d'"' -f4)
        RESP=$$(curl -sf -H "X-Vault-Token: $$VAULT_TOKEN" \
          http://vault:8200/v1/homelab/data/services/vaultwarden)
        export ADMIN_TOKEN=$$(echo "$$RESP" | grep -o '"admin_token":"[^"]*"' | cut -d'"' -f4)
        [ -n "$$ADMIN_TOKEN" ] || { echo "admin_token empty -- Vault sealed?"; exit 1; }
        exec /vaultwarden                        # the image's original entrypoint/command
      - --
    networks:
      - backend                                 # Vault is reachable as http://vault:8200
```

Find the original entrypoint with
`docker image inspect <image> --format '{{.Config.Entrypoint}} {{.Config.Cmd}}'`.

## 6. Deploy and verify

The example also needs a `.env` with non-secret settings (`VERSION`, `TRAEFIK_HOST`, the
`VW_*` options) and a `vaultwarden.env` next to the compose file.

```bash
docker compose --env-file .env -f examples/direct-entrypoint-vaultwarden/docker-compose.yaml up -d
docker logs vaultwarden | head
```

The container should start normally. Check that no secret leaked into the configuration:
`docker inspect vaultwarden` must not show the values, because they exist only in the process
environment.

## Pitfalls

- **`$$` in compose files:** every `$` in the entrypoint script must be doubled, or Compose
  interpolates it at deploy time. That also applies to `$` inside comments in the script.
- **`export X=$(...)` hides failures:** `set -e` does not catch a failed command substitution
  inside `export`. Without an explicit empty check, a sealed Vault starts the service with an
  empty password instead of failing.
- **`grep`/`cut` parsing** works for plain values. Values containing `"` or `\` need `jq` or
  python. Generate secrets without those characters, or use the sidecar with `jq`.
- **Vault restart = sealed Vault:** every service that fetches secrets at startup fails until
  Vault is unsealed. Exclude Vault from automatic updates.
