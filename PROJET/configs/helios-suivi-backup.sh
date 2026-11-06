#!/usr/bin/bash
# helios-suivi-backup.sh - sauvegarde du portail de suivi (avec les ACL)
# Codes retour : 0 OK · 1 erreur interne · 2 deja en cours · 3 prerequis manquant
set -Eeuo pipefail
IFS=$'\n\t'
umask 077
readonly TAG=helios-suivi-backup
readonly DEST=/srv/helios/archives/suivi
readonly GARDER=7
readonly SOURCES=(
    /srv/helios/suivi
    /etc/systemd/system/helios-suivi.service
    /etc/systemd/system/helios-suivi-publish.service
    /etc/systemd/system/helios-suivi-publish.timer
    /etc/systemd/system/helios-suivi-backup.service
    /etc/systemd/system/helios-suivi-backup.timer
    /etc/sudoers.d/92-helios-suivi
    /etc/zabbix/zabbix_agent2.d/helios-suivi.conf
    /usr/local/sbin/helios-suivi-publish.sh
    /usr/local/sbin/helios-suivi-backup.sh
)
TMP=""

log() { logger -t "$TAG" -p "user.$1" -- "$2" ; }
nettoyage() { [[ -n "$TMP" && -e "$TMP" ]] && rm -f -- "$TMP" ; return 0 ; }
trap nettoyage EXIT
trap 'log err "erreur interne ligne $LINENO" ; exit 1' ERR

# Verrou : le script lui-meme, ouvert en lecture
exec 9<"$0"
flock -n 9 || { log warning "une autre sauvegarde est en cours" ; exit 2 ; }

# Prerequis : toutes les sources existent, la destination est inscriptible
for s in "${SOURCES[@]}" ; do
    [[ -e "$s" ]] || { log err "source absente : $s" ; exit 3 ; }
done
mkdir -p -- "$DEST" 2>/dev/null || true
[[ -d "$DEST" && -w "$DEST" ]] || { log err "$DEST non inscriptible" ; exit 3 ; }

# Archive avec les ACL, ecrite sous un nom temporaire puis renommee
nom="suivi-$(date +%Y%m%d-%H%M%S).tar.gz"
TMP="$DEST/.${nom}.tmp"
tar --acls -czpf "$TMP" "${SOURCES[@]}" 2>/dev/null
mv -f -- "$TMP" "$DEST/$nom"
TMP=""
( cd "$DEST" && sha256sum "$nom" > "$nom.sha256" )

# Rotation : on garde les 7 archives les plus recentes
mapfile -t vieilles < <(ls -1t "$DEST"/suivi-*.tar.gz | tail -n +$((GARDER + 1)))
for f in "${vieilles[@]}" ; do
    rm -f -- "$f" "$f.sha256"
    log info "rotation : $(basename "$f") supprimee"
done

log info "sauvegarde ${nom} creee ($(du -h "$DEST/$nom" | cut -f1))"
exit 0
