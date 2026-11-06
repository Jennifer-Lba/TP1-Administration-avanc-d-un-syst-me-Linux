#!/usr/bin/bash
# helios-suivi-publish.sh - publie etat.json a partir de la telemetrie
# Codes retour : 0 OK · 1 erreur interne · 2 deja en cours · 3 prerequis manquant
set -Eeuo pipefail
IFS=$'\n\t'
readonly TAG=helios-suivi-publish
readonly CSV=/var/lib/helios/telemetry.csv
readonly WWW=/srv/helios/suivi/www
readonly CIBLE="$WWW/etat.json"
TMP=""

log() { logger -t "$TAG" -p "user.$1" -- "$2" ; }
nettoyage() { [[ -n "$TMP" && -e "$TMP" ]] && rm -f -- "$TMP" ; return 0 ; }
trap nettoyage EXIT
trap 'log err "erreur interne ligne $LINENO" ; exit 1' ERR

# Verrou : on verrouille le script lui-meme, ouvert en lecture (rien a ecrire)
exec 9<"$0"
flock -n 9 || { log warning "une autre publication est en cours" ; exit 2 ; }

# Prerequis
[[ -r "$CSV" ]] || { log err "telemetrie illisible : $CSV" ; exit 3 ; }
[[ -d "$WWW" && -w "$WWW" ]] || { log err "$WWW non inscriptible pour $(id -un)" ; exit 3 ; }

# Lecture et controle de la derniere ligne : date,charge,memoire
ligne=$(tail -n 1 -- "$CSV")
if [[ ! "$ligne" =~ ^([0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}[+-][0-9]{2}:[0-9]{2}),([0-9]+(\.[0-9]+)?),([0-9]+)$ ]] ; then
    log err "derniere ligne de telemetrie invalide : ${ligne}"
    exit 1
fi
mesure=${BASH_REMATCH[1]}
charge=${BASH_REMATCH[2]}
mem=${BASH_REMATCH[4]}
nb=$(wc -l < "$CSV")

# Ecriture atomique : fichier temporaire dans www, puis renommage
TMP=$(mktemp "$WWW/.etat.json.XXXXXX")
chmod 0640 "$TMP"
printf '{\n  "genere": "%s",\n  "hote": "%s",\n  "derniere_mesure": "%s",\n  "charge_1min": %s,\n  "mem_dispo_ko": %s,\n  "mesures": %s\n}\n' \
    "$(date --iso-8601=seconds)" "$(uname -n)" "$mesure" "$charge" "$mem" "$nb" > "$TMP"
mv -f -- "$TMP" "$CIBLE"
TMP=""

log info "etat.json publie (${nb} mesures, derniere ${mesure})"
exit 0
