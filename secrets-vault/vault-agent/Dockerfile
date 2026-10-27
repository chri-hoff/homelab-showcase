# Minimal image for the one-shot vault-agent sidecars (mariadb, postgres, supabase):
# AppRole login + read secrets from Vault, write them into a named volume. Needs only
# curl and jq -- replaces the former homelab-update-runner, which Kestra no longer uses
# (#100: Kestra reaches the host only through homelab-deploy).
#
# Build on the host (tag = image version; bump it when this file changes):
#   docker build --pull -t homelab-vault-agent:1.0 services/vault-agent
FROM alpine:3.24.3

RUN apk add --no-cache curl jq
