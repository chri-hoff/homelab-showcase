function sops-update
    if test (count $argv) -lt 2
        echo "Usage: sops-update <env datei> <compose datei>"
        return 1
    end

    sops --decrypt --input-type dotenv --output-type dotenv $argv[1].sops > $argv[1]

    # The target version comes from config/versions.yaml (single source of truth) if the
    # service has been migrated there -- otherwise fall back to VERSION from the (freshly
    # decrypted) .env so services that are not migrated yet keep working as before.
    set -l service (basename (dirname $argv[2]))
    set -l target_version (yq -r ".services.\"$service\".version // \"\"" config/versions.yaml)

    # Fixed versions only (#100): "latest" would deploy whatever the registry serves
    # right now, bypassing the update check and Soll/Ist in Supabase.
    if test "$target_version" = "latest"
        echo "FEHLER: '$service' steht in config/versions.yaml auf 'latest' -- bitte feste Version in Supabase setzen"
        rm -f $argv[1]
        return 1
    end

    if test -z "$target_version" -o "$target_version" = "null"
        echo "INFO: '$service' noch nicht in config/versions.yaml -- verwende VERSION aus $argv[1]"
        if grep -qx 'VERSION=latest' $argv[1]
            echo "FEHLER: VERSION=latest in $argv[1] -- bitte feste Version setzen"
            rm -f $argv[1]
            return 1
        end
        sudo docker compose --env-file $argv[1] -f $argv[2] up -d --force-recreate --quiet-pull
    else
        sudo VERSION=$target_version docker compose --env-file $argv[1] -f $argv[2] up -d --force-recreate --quiet-pull
    end
    or begin
        echo "docker compose up fehlgeschlagen -- $argv[1] wird NICHT gelöscht"
        return 1
    end

    echo "Folgende env Datei/en werden gelöscht"
    find -name "*.env"
    find -name "*.env" -delete
end
