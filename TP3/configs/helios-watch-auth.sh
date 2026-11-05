#!/usr/bin/bash
# helios-watch-auth.sh - bloque les sources qui accumulent les echecs SSH.
# Fenetre glissante de 10 min, seuil : plus de 5 echecs par adresse.
# Sortie : 0 OK · 1 erreur interne · 2 une autre instance tourne deja
set -euo pipefail
IFS=$'\n\t'
readonly TAG=helios-watch-auth
readonly LOCK=/run/lock/helios-watch-auth.lock
readonly IPSET=helios-blacklist
readonly STATE=/var/lib/helios/blocked.txt
readonly WINDOW='-10min'
readonly SEUIL=5
# 192.168.56.1 : poste du formateur ; 192.168.56.0 : mon PC (adresse vue par sshd)
readonly WHITELIST=(127.0.0.1 192.168.56.1 192.168.56.0)

log() { logger -t "$TAG" -p "authpriv.${1}" -- "$2" ; }

exec 9>"$LOCK"
flock -n 9 || { log warning "une autre instance tourne deja" ; exit 2 ; }

touch "$STATE"
declare -A nb=()
while read -r ip ; do
    [[ -n "$ip" ]] && nb[$ip]=$(( ${nb[$ip]:-0} + 1 ))
done < <(journalctl -u sshd --since "$WINDOW" -o cat --no-pager \
         | grep -E 'Invalid user|Failed (password|publickey|none)|Connection closed by invalid user|Disconnected from invalid user' \
         | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}')

for ip in "${!nb[@]}" ; do
    (( nb[$ip] > SEUIL )) || continue
    for w in "${WHITELIST[@]}" ; do
        [[ "$ip" == "$w" ]] && { log info "${ip} en liste blanche (${nb[$ip]} echecs), ignoree" ; continue 2 ; }
    done
    if grep -qx "$ip" "$STATE" || firewall-cmd -q --ipset="$IPSET" --query-entry="$ip" ; then
        continue                      # deja bloquee : pas de seconde alerte
    fi
    firewall-cmd -q --ipset="$IPSET" --add-entry="$ip"
    echo "$ip" >> "$STATE"
    log alert "blocage de ${ip} : ${nb[$ip]} echecs SSH en 10 min"
done
log info "analyse terminee : ${#nb[@]} source(s) en echec"
exit 0
