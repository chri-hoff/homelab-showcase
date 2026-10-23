function vault-unseal
    # Prompts for unseal keys interactively (read -s, no echo/no logging) and
    # re-checks the sealed status after every key -- so this works regardless
    # of the configured threshold (default here: 3 of 5 keys, see
    # services/vault/README.md). Runs directly on the server (not in
    # Kestra/update-runner) -- unseal keys only live in the password manager
    # and are deliberately not automatable, see the comment in sops-auto-update.fish.
    set -l sealed (docker exec vault vault status -address=http://localhost:8200 | string match -r '^Sealed\s+\S+' | string replace -r '^Sealed\s+' '')

    if test "$sealed" = false
        echo (set_color green)"Vault ist bereits entsiegelt."(set_color normal)
        return 0
    end

    while true
        echo -n "Unseal Key eingeben (leer zum Abbrechen): "
        read -s key
        echo

        if test -z "$key"
            echo "Abgebrochen."
            return 1
        end

        docker exec vault vault operator unseal -address=http://localhost:8200 "$key" >/dev/null
        or echo (set_color yellow)"Key abgelehnt -- falsch oder bereits verwendet."(set_color normal)

        set sealed (docker exec vault vault status -address=http://localhost:8200 | string match -r '^Sealed\s+\S+' | string replace -r '^Sealed\s+' '')

        if test "$sealed" = false
            echo (set_color green)"Vault ist entsiegelt."(set_color normal)
            return 0
        end
    end
end
