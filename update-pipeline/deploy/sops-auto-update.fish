function sops-auto-update
    # Services that must NEVER update themselves through this path.
    # Kestra: if the Kestra flow triggered sops-auto-update and restarted its
    # own Kestra container in the process, the running flow execution would
    # be killed.
    # Vault: starts sealed after every restart and needs manual unsealing
    # (unseal keys live in the password manager, cannot be automated)
    # -- an automatic Vault restart would put Vault itself AND every service
    # that fetches a secret from Vault at startup into a crash state until
    # someone unseals manually.
    # Traefik: the single ingress point -- a broken auto-update makes the
    # whole homelab unreachable from outside, including Kestra's own web UI
    # (which also runs behind Traefik). It has also really broken between
    # image versions before (binary path changed, see "Pattern: migrating a
    # new service" in the wiki) -- this pipeline does not check image
    # internals before a bump.
    # All three updates deliberately stay manual (sops-update).
    set -l auto_update_excluded kestra vault traefik

    # Remember the state before the pull
    set -l before (git rev-parse HEAD)

    # --no-edit: this server checkout occasionally gets direct local commits
    # (e.g. sops-commit for a secret change made directly on the host) that
    # have not been pushed before the next webhook pull -- git would then
    # create a merge commit and open the editor for it. In the Kestra
    # container without a TTY/$EDITOR the flow hangs before anything has
    # been fetched. --no-edit takes the default merge message without an
    # editor so this legitimate case does not block the automated run.
    git pull --no-edit
    or begin
        echo "git pull fehlgeschlagen"
        return 1
    end

    set -l after (git rev-parse HEAD)

    if test "$before" = "$after"
        echo "Keine Änderungen – nichts zu tun."
        return 0
    end

    # Get changed/new *.env.sops from the diff (secret changes)
    set -l changed (git diff --name-only --diff-filter=AM $before $after -- '*.env.sops')

    if test (count $changed) -eq 0
        echo "Keine aktualisierten *.env.sops Dateien."
    else
        echo "Folgende sops-Dateien wurden aktualisiert:"
        printf '  %s\n' $changed

        for sopsfile in $changed
            # services/adguard/adguard.env.sops -> services/adguard/adguard.env
            set -l envfile (string replace -r '\.sops$' '' $sopsfile)
            set -l dir (dirname $sopsfile)
            set -l service (basename $dir)

            if contains $service $auto_update_excluded
                echo "SKIP: $service ist von sops-auto-update ausgenommen (siehe Kommentar oben)"
                continue
            end

            # Look for a compose file in the same directory
            set -l compose ""
            for name in docker-compose.yaml docker-compose.yml compose.yaml compose.yml
                if test -f "$dir/$name"
                    set compose "$dir/$name"
                    break
                end
            end

            if test -z "$compose"
                echo "WARN: Keine Compose-Datei in $dir gefunden – überspringe $sopsfile"
                continue
            end

            echo "==> Aktualisiere $dir (Secret-Änderung)"
            sops-update $envfile $compose
        end
    end

    # Detect version bumps in config/versions.yaml (independent of *.env.sops changes)
    if test -f config/versions.yaml; and git diff --name-only --diff-filter=AM $before $after -- 'config/versions.yaml' | grep -q .
        set -l services (yq -r '.services | keys | .[]' config/versions.yaml)

        for service in $services
            set -l version_before (git show "$before:config/versions.yaml" | yq -r ".services.\"$service\".version // \"\"")
            set -l version_after (yq -r ".services.\"$service\".version" config/versions.yaml)

            if test "$version_before" != "$version_after"
                # New in versions.yaml (since #72 generated from Supabase, e.g. newly detected
                # containers): already running at this version -- no deploy, no restart.
                if test -z "$version_before"
                    echo "Neu in versions.yaml: $service ($version_after) -- kein Deploy"
                    continue
                end

                echo "Versions-Update erkannt: $service ($version_before -> $version_after)"

                # updateable: false (toggle in Supabase Studio) -> never automatic
                if test (yq -r ".services.\"$service\".updateable" config/versions.yaml) = "false"
                    echo "SKIP: $service hat updateable: false -- bitte manuell mit sops-update deployen"
                    continue
                end

                if contains $service $auto_update_excluded
                    echo "SKIP: $service ist von sops-auto-update ausgenommen (siehe Kommentar oben) -- bitte manuell mit sops-update deployen"
                    continue
                end

                set -l dir "services/$service"
                set -l envfile "$dir/$service.env"

                set -l compose ""
                for name in docker-compose.yaml docker-compose.yml compose.yaml compose.yml
                    if test -f "$dir/$name"
                        set compose "$dir/$name"
                        break
                    end
                end

                if test -z "$compose"
                    echo "WARN: Keine Compose-Datei in $dir gefunden – überspringe $service"
                    continue
                end

                if not test -f "$envfile.sops"
                    echo "WARN: Keine $envfile.sops gefunden – überspringe $service"
                    continue
                end

                echo "==> Aktualisiere $dir (Versions-Update)"
                sops-update $envfile $compose
            end
        end
    end
end
