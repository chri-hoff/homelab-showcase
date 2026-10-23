# Shared helper image for Kestra Docker tasks that need to work on the host
# repo/Docker:
#   - services/kestra/flows/update-on-merge.yml (sops-auto-update on merge)
#   - services/kestra/flows/docker-update-check.yml (daily update check + Telegram)
# Started as a Docker task via the host Docker socket already mounted into
# Kestra -- no new Kestra secret needed, it only uses the existing
# docker.sock access. Contains: fish, git, sops, yq, jq, python3, docker-cli
# (+compose plugin).
#
# Build (once, on the host):
#   docker build -t homelab-update-runner:latest services/kestra/update-runner
#
# When this Dockerfile changes, the image must be rebuilt on the host --
# Kestra only references the local image name, there is no registry pull.

FROM docker:27-cli

RUN apk add --no-cache fish git curl bash jq sudo docker-cli-compose python3

RUN SOPS_VERSION=$(curl -s https://api.github.com/repos/getsops/sops/releases/latest | grep tag_name | cut -d '"' -f4) \
    && curl -Lo /usr/local/bin/sops "https://github.com/getsops/sops/releases/download/${SOPS_VERSION}/sops-${SOPS_VERSION}.linux.amd64" \
    && chmod +x /usr/local/bin/sops

RUN YQ_VERSION=$(curl -s https://api.github.com/repos/mikefarah/yq/releases/latest | grep tag_name | cut -d '"' -f4) \
    && curl -Lo /usr/local/bin/yq "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_amd64" \
    && chmod +x /usr/local/bin/yq

WORKDIR /repo
