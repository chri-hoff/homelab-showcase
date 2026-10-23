# Development: Gitea

The self-hosted Git server that holds the private version of this repository. It is also the
trigger of the [update pipeline](../update-pipeline/): every push to `main` fires a webhook that
makes Kestra deploy the change.

## Gitea (`gitea/`)

- **Secrets from Vault at startup:** the entrypoint logs in with an AppRole and exports
  `SECRET_KEY`, `INTERNAL_TOKEN` and the database password as `GITEA__...` environment
  variables, then starts Gitea's original entrypoint. The image has `curl` but no `jq`, so the
  JSON is parsed with `grep`/`cut`.
- **Shared Postgres:** Gitea uses the central Postgres container on the `backend` network.
  `gitea-init.sql` creates the database and user. Its password is the `gitea_password` key
  under `homelab/databases/postgres` in Vault.
- **Web UI from internal networks only** (`std-app-internal-chain`: LAN, IoT, VPN). Git over
  SSH uses Gitea's built-in SSH server on port 2222, so the host's own SSH daemon stays separate.
- `no-new-privileges` and a health check on the web port.

## Webhooks to internal services

Gitea blocks webhooks to private addresses by default (SSRF protection). For the deploy webhook
to reach Kestra on the internal Docker network, the target has to be allowed explicitly in
`app.ini`, for example:

```ini
[webhook]
; a host name, or "private" for all private networks
ALLOWED_HOST_LIST = kestra
```

The webhook URL then points at Kestra directly (`http://kestra:8080/api/v1/executions/webhook/...`)
and never leaves the Docker network.

## Setup

1. Run `gitea-init.sql` against Postgres and store the same password in Vault.
2. Create the AppRole and policy for `homelab/services/gitea` and
   `homelab/databases/postgres` (see `secrets-vault/`).
3. Copy `gitea.env.example` to `gitea.env`, then `docker compose up -d`.

Hostnames and IP ranges are placeholders (`example.com`, RFC 5737 ranges).
