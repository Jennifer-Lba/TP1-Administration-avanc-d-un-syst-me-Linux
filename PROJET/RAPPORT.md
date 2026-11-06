# PROJET — Mise en production du portail de suivi des tournées

## 0. Prérequis

Les 5 contrôles passent au départ (`preuves/captures/0-prerequis.png`) :

```
[root@srv-core ~]# systemctl is-active helios-collect.service
active
[root@srv-core ~]# ls -l /var/lib/helios/telemetry.csv ; sleep 10 ; ls -l /var/lib/helios/telemetry.csv
-rw-r--r--. 1 helios helios 75855  5 nov.  11:56 /var/lib/helios/telemetry.csv
-rw-r--r--. 1 helios helios 75933  5 nov.  11:56 /var/lib/helios/telemetry.csv
[root@srv-core ~]# systemctl cat helios.target
# /etc/systemd/system/helios.target
[Unit]
Description=Pile applicative Helios
Requires=multi-user.target
After=multi-user.target
AllowIsolate=no

[Install]
WantedBy=multi-user.target
[root@srv-core ~]# firewall-cmd --get-default-zone
drop
[root@srv-core ~]# firewall-cmd --get-active-zones
drop
  interfaces: enp0s3 enp0s8 enp0s9
internal
  interfaces: bond0.42 bond0
work
  interfaces: enp0s10
  sources: 192.168.56.0/24
[root@srv-core ~]# sshd -T | grep -E '^(port|allowgroups|passwordauthentication) '
port 2242
passwordauthentication no
allowgroups ssh-admins
[root@srv-core ~]# systemctl is-active helios-watch-auth.timer
active
```

Instantanés pris dans VirtualBox : `03-fin-TP3` et `04-debut-projet`.

## 1. Tableau de conformité

|Exigence|Commande de preuve|Partie utile de la sortie|
|-|-|-|
|E1 — Comptes et groupe|`id lea` · `getent passwd lea helios-suivi` · `chage -l lea`|`uid=5104(lea) gid=5003(suivi) groupes=5003(suivi)` · `helios-suivi:x:982:979::/srv/helios/suivi:/sbin/nologin` · min 1 / max 90 / alerte 14, inactif le 10/02/2027|
|E2 — Répertoire publié|`ls -ld www` · `getfacl www` · `runuser -u ...`|`drwxrws--- root suivi` · `user:helios-suivi:rwx`, `user:zabbix:--x`, défauts `group::rwx other::---` · index.html de lea en `-rw-rw----+ lea suivi` malgré `umask 077` · nadia refusée, zabbix ne liste pas www mais fait `stat` sur etat.json|
|E3 — Script de publication|codes provoqués · `python3 -m json.tool` · `journalctl -t helios-suivi-publish`|`code=0` (helios-suivi) · `code=2` (verrou pris) · `code=3` (nadia, www non inscriptible) · JSON valide avec les 6 champs|
|E4 — Units systemd|`systemctl status/show` · `kill -9` · `systemd-analyze security` · `curl` · `list-dependencies`|portail relancé en 2 s après `kill -9` · score **9.2 UNSAFE → 1.2 OK** (publication : 1.6 OK) · `200` sur `/` et `/etat.json` · timer toutes les 2 min · `helios-suivi.service` sous `helios.target`|
|E5 — Délégation sudo|`visudo -c` · `sudo -l -U lea` · essais réels|4 fichiers « analyse réussie » · 5 commandes exactes · `restart sshd` et `journalctl --vacuum-time=1s` refusés (`code=1`)|
|E6 — Pare-feu|`--query-port` · `--list-all` · `nft` · tests srv-edge|`yes` / `yes` · 8080 seulement dans internal · défaut `drop` · srv-edge : `200` sur 10.42.0.10, échec sur 192.168.56.10|
|E7 — Non-régression|`sshd -T` · ssh de lea · `journalctl -u sshd`|`port 2242`, `permitrootlogin no`, `passwordauthentication no`, `allowgroups ssh-admins` · lea `Permission denied (publickey)` · `User lea ... not allowed because none of user's groups are listed in AllowGroups` · timer actif, `Storage=persistent`|
|E8 — Supervision|`systemctl is-active` · `zabbix_get`|agent et `sysstat-collect.timer` actifs et activés · `agent.ping` = `1` · `helios.suivi.http` = `200` · `helios.suivi.age` = `48`|
|E9 — Sauvegarde et restauration|`ls -l` archives · `tar -tzf` · `sha256sum -c` · rotation · restauration|`/srv/helios/archives` en `helios:helios 0750` · archive `suivi-20261106-073440.tar.gz` + `.sha256` (`Réussi`) · 7 archives gardées · timer 03:15 `Persistent=true` · ACL identiques après extraction · index.html restauré seul avec ses ACL en 1 s|

### E1 — Comptes et groupe

```
[root@srv-core ~]# groupadd -g 5003 suivi
[root@srv-core ~]# useradd -u 5104 -g suivi -c "Lea Fabre - responsable suivi des tournees" -m lea
[root@srv-core ~]# passwd lea
Changement de mot de passe pour l'utilisateur lea.
Nouveau mot de passe :
Retapez le nouveau mot de passe :
passwd : mise à jour réussie de tous les jetons d'authentification.
[root@srv-core ~]# chage -M 90 -m 1 -W 14 -I 7 lea
[root@srv-core ~]# id lea
uid=5104(lea) gid=5003(suivi) groupes=5003(suivi)
[root@srv-core ~]# chage -l lea
Last password change                                    : nov. 05, 2026
Password expires                                        : févr. 03, 2027
Password inactive                                       : févr. 10, 2027
Account expires                                         : never
Minimum number of days between password change          : 1
Maximum number of days between password change          : 90
Number of days of warning before password expires       : 14
[root@srv-core ~]# ls /home
audit-ext  julien  lea  nadia  sysops  tarek
```

Lors de la création du compte de service, j'ai fait une erreur en saisissant `helios-suiv` au lieu de `helios-suivi`. Je m'en suis rendu compte en vérifiant le compte avec `getent` et `id`. J'ai donc supprimé le mauvais compte, puis créé le compte avec le nom attendu :

```
[root@srv-core ~]# userdel helios-suiv
[root@srv-core ~]# useradd -r -s /sbin/nologin -d /srv/helios/suivi -M helios-suivi
[root@srv-core ~]# getent passwd helios-suiv ; echo "(rien attendu au-dessus)"
(rien attendu au-dessus)
[root@srv-core ~]# id helios-suivi
uid=982(helios-suivi) gid=979(helios-suivi) groupes=979(helios-suivi)
[root@srv-core ~]# getent passwd lea helios-suivi
lea:x:5104:5003:Lea Fabre - responsable suivi des tournees:/home/lea:/bin/bash
helios-suivi:x:982:979::/srv/helios/suivi:/sbin/nologin
```

### E2 — Répertoire publié : setgid et ACL

```
[root@srv-core ~]# mkdir -p /srv/helios/suivi/www
[root@srv-core ~]# ls -ld /srv/helios /srv/helios/suivi
drwxr-xr-x. 5 root root 47  5 nov.  14:06 /srv/helios
drwxr-x---. 3 root root 17  5 nov.  14:06 /srv/helios/suivi
[root@srv-core ~]# chown root:suivi /srv/helios/suivi/www
[root@srv-core ~]# chmod 2770 /srv/helios/suivi/www
[root@srv-core ~]# ls -ld /srv/helios/suivi/www
drwxrws---. 2 root suivi 6  5 nov.  14:06 /srv/helios/suivi/www
[root@srv-core ~]# chmod 755 /srv/helios/suivi
[root@srv-core ~]# ls -ld /srv/helios/suivi
drwxr-xr-x. 3 root root 17  5 nov.  14:06 /srv/helios/suivi
```

J'ai rencontré ici un problème lié à l'umask `027` configuré pendant le TP2. Le répertoire `/srv/helios/suivi` avait été créé avec les droits `750`. Les comptes `helios-suivi`, `zabbix` et `lea` ne pouvaient donc pas traverser ce répertoire pour accéder à `www`. J'ai corrigé cela avec les droits `755`. Ils peuvent maintenant traverser le répertoire parent, mais seul root peut le modifier. Les restrictions d'accès au contenu restent définies sur `www` avec les ACL.

```
[root@srv-core ~]# setfacl -m u:helios-suivi:rwx /srv/helios/suivi/www
[root@srv-core ~]# setfacl -m u:zabbix:--x /srv/helios/suivi/www
[root@srv-core ~]# setfacl -d -m u::rwx,g::rwx,o::---,u:helios-suivi:r-x /srv/helios/suivi/www
[root@srv-core ~]# getfacl /srv/helios/suivi/www
getfacl : suppression du premier « / » des noms de chemins absolus
# file: srv/helios/suivi/www
# owner: root
# group: suivi
# flags: -s-
user::rwx
user:helios-suivi:rwx
user:zabbix:--x
group::rwx
mask::rwx
other::---
default:user::rwx
default:user:helios-suivi:r-x
default:group::rwx
default:mask::rwx
default:other::---
```

Dépôt de la page d'accueil par lea elle-même, avec un umask volontairement strict :

```
[root@srv-core ~]# su - lea
[lea@srv-core ~]$ umask 077
cd /srv/helios/suivi/www
echo "<h1>Portail de suivi des tournees Helios</h1>" > index.html
ls -l index.html
exit
-rw-rw----+ 1 lea suivi 46  5 nov.  14:27 index.html
déconnexion
[root@srv-core ~]# getfacl /srv/helios/suivi/www/index.html
# file: srv/helios/suivi/www/index.html
# owner: lea
# group: suivi
user::rw-
user:helios-suivi:r-x           #effective:r--
group::rwx                      #effective:rw-
mask::rw-
other::---
[root@srv-core ~]# runuser -u helios-suivi -- cat /srv/helios/suivi/www/index.html
<h1>Portail de suivi des tournees Helios</h1>
[root@srv-core ~]# runuser -u nadia -- cat /srv/helios/suivi/www/index.html
cat: /srv/helios/suivi/www/index.html: Permission non accordée
[root@srv-core ~]# runuser -u zabbix -- ls /srv/helios/suivi/www
ls: impossible d'ouvrir le répertoire '/srv/helios/suivi/www': Permission non accordée
```

Une fois que le script de publication a été mis en place (E3), j'ai vérifié que le compte `zabbix` pouvait consulter les métadonnées de `etat.json` sans pouvoir lister le contenu du répertoire :

```
[root@srv-core ~]# runuser -u zabbix -- stat /srv/helios/suivi/www/etat.json
  Fichier : /srv/helios/suivi/www/etat.json
   Taille : 185          Blocs : 8          Blocs d'E/S : 4096   fichier
Accès : (0640/-rw-r-----)  UID : (  982/helios-suivi)   GID : ( 5003/   suivi)
[... dates, voir preuves/captures/e3-2-codes.png ...]
```

### E3 — Script de publication

Format de la télémétrie (3 champs, sans ligne de titre) :

```
[root@srv-core ~]# tail -3 /var/lib/helios/telemetry.csv
2026-11-05T14:39:11+01:00,0.00,2893852
2026-11-05T14:39:16+01:00,0.00,2893852
2026-11-05T14:39:22+01:00,0.00,2893852
```

Le script utilisé est `configs/helios-suivi-publish.sh`. Il est installé avec les droits `0755` et appartient à `root:root`. Son empreinte MD5 (`3fdf6366d0dce3f0e0f1544549ade342`) permet d'identifier la version testée. J'ai repris les cinq règles vues au TP1 : `set -Eeuo pipefail`, un verrou avec `flock`, un `trap` de nettoyage à la sortie, un `trap` sur erreur pour renvoyer le code 1, ainsi que des messages dans le journal avec `logger -t helios-suivi-publish`. Les codes de retour utilisés sont 0, 1, 2 et 3.

J'ai fait trois choix importants dans ce script :

* **Écriture du JSON :** le contenu est d'abord écrit dans un fichier temporaire nommé `www/.etat.json.XXXXXX`. Le script le renomme ensuite avec `mv`. Cela évite qu'un lecteur consulte un fichier incomplet pendant sa mise à jour.
* **Verrouillage :** le script verrouille son propre fichier, ouvert en lecture avec `exec 9<"$0"`. Il n'a donc pas besoin de créer un fichier de verrou dans un répertoire où l'écriture serait interdite par `ProtectSystem=strict`.
* **Droits d'exécution :** le script possède les droits `0755`, car il doit pouvoir être exécuté par le compte `helios-suivi`, et pas uniquement par root.

```
[root@srv-core ~]# runuser -u helios-suivi -- /usr/local/sbin/helios-suivi-publish.sh ; echo "code=$?"
code=0
[root@srv-core ~]# python3 -m json.tool /srv/helios/suivi/www/etat.json
{
    "genere": "2026-11-05T15:04:12+01:00",
    "hote": "srv-core",
    "derniere_mesure": "2026-11-05T15:04:09+01:00",
    "charge_1min": 0.14,
    "mem_dispo_ko": 2890508,
    "mesures": 4018
}
[root@srv-core ~]# ls -l /srv/helios/suivi/www
total 8
-rw-r-----+ 1 helios-suivi suivi 185  5 nov.  15:04 etat.json
-rw-rw----+ 1 lea          suivi  46  5 nov.  14:27 index.html
[root@srv-core ~]# flock /usr/local/sbin/helios-suivi-publish.sh sleep 20 &
[root@srv-core ~]# runuser -u helios-suivi -- /usr/local/sbin/helios-suivi-publish.sh ; echo "code=$?"
[1] 12991
code=2
[root@srv-core ~]# runuser -u nadia -- /usr/local/sbin/helios-suivi-publish.sh ; echo "code=$?"
code=3
[root@srv-core ~]# journalctl -t helios-suivi-publish -n 5 --no-pager
nov. 05 15:04:12 srv-core helios-suivi-publish[12972]: etat.json publie (4018 mesures, derniere 2026-11-05T15:04:09+01:00)
nov. 05 15:04:31 srv-core helios-suivi-publish[12997]: une autre publication est en cours
nov. 05 15:04:45 srv-core helios-suivi-publish[13009]: une autre publication est en cours
nov. 05 15:06:47 srv-core helios-suivi-publish[13125]: /srv/helios/suivi/www non inscriptible pour nadia
```

Le premier test avec `nadia`, à 15:04:45, a renvoyé le code 2. Ce résultat s'explique par le verrou de 20 secondes qui était encore utilisé par l'autre processus. J'ai refait le test une fois le verrou libéré : le script a alors renvoyé le code 3, qui correspond au refus d'écriture dans `www`.

### E4 — Units systemd

Pour cette partie, j'ai ajouté trois fichiers : `configs/helios-suivi.service`, `configs/helios-suivi-publish.service` et `configs/helios-suivi-publish.timer`. Je n'ai pas modifié les unités créées pendant les TP précédents.

Score du portail avant durcissement (seulement `User=`, `Restart=`, `MemoryMax=128M`, `CPUQuota=50%`) :

```
→ Overall exposure level for helios-suivi.service: 9.2 UNSAFE 😨
```

Après l'ajout des protections systemd, j'ai vérifié que le service démarrait toujours et que les deux pages répondaient correctement :

```
[root@srv-core ~]# systemctl is-active helios-suivi.service
active
[root@srv-core ~]# curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8080/
200
[root@srv-core ~]# curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8080/etat.json
200
[root@srv-core ~]# systemd-analyze security helios-suivi.service | tail -1
→ Overall exposure level for helios-suivi.service: 1.2 OK 🙂
```

Redémarrage automatique :

```
[root@srv-core ~]# systemctl show -p MainPID helios-suivi.service
MainPID=13973
[root@srv-core ~]# kill -9 $(systemctl show -p MainPID --value helios-suivi.service)
[root@srv-core ~]# sleep 3
[root@srv-core ~]# systemctl show -p MainPID helios-suivi.service
MainPID=14189
[root@srv-core ~]# systemctl is-active helios-suivi.service
active
[root@srv-core ~]# journalctl -u helios-suivi -n 5 --no-pager
nov. 05 15:23:50 srv-core systemd[1]: helios-suivi.service: Main process exited, code=killed, status=9/KILL
nov. 05 15:23:50 srv-core systemd[1]: helios-suivi.service: Failed with result 'signal'.
nov. 05 15:23:52 srv-core systemd[1]: helios-suivi.service: Scheduled restart job, restart counter is at 1.
nov. 05 15:23:52 srv-core systemd[1]: Stopped Portail de suivi des tournees Helios.
nov. 05 15:23:52 srv-core systemd[1]: Started Portail de suivi des tournees Helios.
```

Publication planifiée :

```
→ Overall exposure level for helios-suivi-publish.service: 1.6 OK 🙂
[root@srv-core ~]# systemctl list-timers helios-suivi-publish.timer --no-pager
NEXT                        LEFT     LAST                        PASSED       UNIT                       ACTIVATES
Thu 2026-11-05 15:42:00 CET 16s left Thu 2026-11-05 15:40:01 CET 1min 41s ago helios-suivi-publish.timer helios-suivi-publish.service
[root@srv-core ~]# journalctl -t helios-suivi-publish -n 4 --no-pager
nov. 05 15:31:24 srv-core helios-suivi-publish[14641]: etat.json publie (4330 mesures, derniere 2026-11-05T15:31:19+01:00)
nov. 05 15:36:02 srv-core helios-suivi-publish[14980]: etat.json publie (4382 mesures, derniere 2026-11-05T15:36:00+01:00)
nov. 05 15:38:02 srv-core helios-suivi-publish[15091]: etat.json publie (4404 mesures, derniere 2026-11-05T15:37:59+01:00)
nov. 05 15:40:02 srv-core helios-suivi-publish[15206]: etat.json publie (4426 mesures, derniere 2026-11-05T15:39:58+01:00)
```

Rattachement à la pile Hélios :

```
[root@srv-core ~]# systemctl list-dependencies helios.target --no-pager
helios.target
● ├─helios-collect.service
● ├─helios-suivi.service
● └─multi-user.target
[... la suite de multi-user.target, voir preuves/captures/e4-6-target.png ...]
[root@srv-core ~]# systemctl is-active helios-collect.service helios-suivi.service helios-suivi-publish.timer
active
active
active
```

### E5 — Délégation sudo

Fichier : `configs/92-helios-suivi` (0440 root:root).

```
[root@srv-core ~]# visudo -cf /root/92-helios-suivi
/root/92-helios-suivi : analyse réussie
[root@srv-core ~]# visudo -c
/etc/sudoers : analyse réussie
/etc/sudoers.d/90-helios-ops : analyse réussie
/etc/sudoers.d/91-nadia-edition : analyse réussie
/etc/sudoers.d/92-helios-suivi : analyse réussie
-r--r-----. 1 root root 521  5 nov.  16:02 /etc/sudoers.d/92-helios-suivi
[root@srv-core ~]# sudo -l -U lea
[... entrées Defaults de Rocky, voir preuves/captures/e5-2-sudo-l.png ...]

L'utilisateur lea peut utiliser les commandes suivantes sur srv-core :
    (root) /usr/bin/systemctl restart helios-suivi.service, /usr/bin/systemctl status --no-pager helios-suivi.service,
        /usr/bin/systemctl start helios-suivi-publish.service, /usr/bin/journalctl --no-pager -n 100 -u helios-suivi.service,
        /usr/bin/journalctl --no-pager -n 100 -u helios-suivi-publish.service
[root@srv-core ~]# sudo -l -U lea /usr/bin/systemctl restart sshd ; echo "code=$?"
code=1
[root@srv-core ~]# sudo -l -U lea /usr/bin/journalctl --vacuum-time=1s ; echo "code=$?"
code=1
[root@srv-core ~]# sudo -l -U lea /usr/bin/journalctl --no-pager -n 100 -u helios-suivi.service ; echo "code=$?"
/usr/bin/journalctl --no-pager -n 100 -u helios-suivi.service
code=0
```

Essai réel en lea :

```
[lea@srv-core ~]$ sudo systemctl status --no-pager helios-suivi.service | head -3
● helios-suivi.service - Portail de suivi des tournees Helios
     Loaded: loaded (/etc/systemd/system/helios-suivi.service; enabled; preset: disabled)
     Active: active (running) since Thu 2026-11-05 16:13:51 CET; 13s ago
[lea@srv-core ~]$ sudo journalctl --no-pager -n 100 -u helios-suivi-publish.service | tail -3
nov. 05 16:14:02 srv-core helios-suivi-publish[17218]: etat.json publie (4800 mesures, derniere 2026-11-05T16:14:00+01:00)
nov. 05 16:14:02 srv-core systemd[1]: helios-suivi-publish.service: Deactivated successfully.
nov. 05 16:14:02 srv-core systemd[1]: Finished Publication de etat.json du portail de suivi.
[lea@srv-core ~]$ sudo systemctl restart sshd
Désolé, l'utilisateur lea n'est pas autorisé à exécuter « /bin/systemctl restart sshd » en tant que root sur srv-core.
```

### E6 — Pare-feu

```
[root@srv-core ~]# firewall-cmd --zone=internal --add-port=8080/tcp
success
[root@srv-core ~]# firewall-cmd --permanent --zone=internal --add-port=8080/tcp
success
[root@srv-core ~]# firewall-cmd --zone=internal --query-port=8080/tcp
yes
[root@srv-core ~]# firewall-cmd --permanent --zone=internal --query-port=8080/tcp
yes
[root@srv-core ~]# firewall-cmd --zone=internal --list-all
internal (active)
  target: default
  icmp-block-inversion: no
  interfaces: bond0 bond0.42
  sources:
  services:
  ports: 10051/tcp 2242/tcp 8080/tcp
  protocols:
  forward: yes
  masquerade: no
  forward-ports:
  source-ports:
  icmp-blocks:
  rich rules:
	rule source ipset="helios-blacklist" drop
[root@srv-core ~]# firewall-cmd --get-default-zone
drop
[root@srv-core ~]# for z in $(firewall-cmd --get-zones) ; do firewall-cmd --zone=$z --list-all | grep -q 8080 && echo "8080 dans $z" ; done
8080 dans internal
[root@srv-core ~]# nft list ruleset | grep 8080
		tcp dport 8080 accept
```

Depuis srv-edge :

```
sysops@srv-edge:~$ curl -s -o /dev/null -w '%{http_code}\n' http://10.42.0.10:8080/etat.json
200
sysops@srv-edge:~$ nc -zv -w2 192.168.56.10 8080
nc: connect to 192.168.56.10 port 8080 (tcp) failed: No route to host
```

Sur le réseau d'admin, la zone `work` rejette ce qui n'est pas autorisé (réponse ICMP, d'où « No route to host »), alors que la zone `drop` jette sans répondre. Dans les deux cas le port est filtré.

### E7 — Non-régression de la sécurité

```
[root@srv-core ~]# sshd -T | grep -E '^(port|permitrootlogin|passwordauthentication|allowgroups) '
port 2242
permitrootlogin no
passwordauthentication no
allowgroups ssh-admins
```

```
sysops@srv-edge:~$ ssh -p 2242 lea@192.168.56.10
*** Serveur Helios Logistique - acces strictement reserve ***
Toute connexion est journalisee.
lea@192.168.56.10: Permission denied (publickey).
```

```
[root@srv-core ~]# journalctl -u sshd --since '-5min' --no-pager | grep lea
nov. 05 16:36:29 srv-core sshd-session[18556]: User lea from 192.168.56.11 not allowed because none of user's groups are listed in AllowGroups
nov. 05 16:36:29 srv-core sshd-session[18556]: Connection closed by invalid user lea 192.168.56.11 port 42896 [preauth]
[root@srv-core ~]# systemctl is-active helios-watch-auth.timer
active
[root@srv-core ~]# grep -i storage /etc/systemd/journald.conf.d/50-helios.conf
Storage=persistent
[root@srv-core ~]# journalctl --list-boots --no-pager | tail -3
 -2 7e56eb6b9d8148b18de003fa4e95fef5 Thu 2026-11-05 08:53:49 CET Thu 2026-11-05 10:51:15 CET
 -1 e560e3a79f754b2690c6a2ddaf62543c Thu 2026-11-05 10:51:51 CET Thu 2026-11-05 12:10:04 CET
  0 eb0a002dbd734242b3d9e000dba6c650 Thu 2026-11-05 12:13:51 CET Thu 2026-11-05 16:36:29 CET
```

### E8 — Supervision

**E8.1 — Dépôt et paquets.** J'ai vérifié les dépôts configurés sur `srv-core`. EPEL n'est pas présent. L'exclusion de `zabbix*` dans `epel.repo` n'était donc pas utile dans cette configuration. J'ai installé le dépôt officiel Zabbix 7.0, puis les paquets nécessaires.

```
[root@srv-core ~]# ls /etc/yum.repos.d/
rocky-addons.repo  rocky-devel.repo  rocky-extras.repo  rocky.repo  rocky-security.repo
[root@srv-core ~]# rpm -Uvh https://repo.zabbix.com/zabbix/7.0/rocky/9/x86_64/zabbix-release-latest-7.0.el9.noarch.rpm
[...]
   1:zabbix-release-7.0-5.el9         ################################# [100%]
[root@srv-core ~]# dnf repolist
id du dépôt                         nom du dépôt
appstream                           Rocky Linux 9 - AppStream
baseos                              Rocky Linux 9 - BaseOS
extras                              Rocky Linux 9 - Extras
zabbix                              Zabbix Official Repository - x86_64
zabbix-non-supported                Zabbix Official Repository (non-supported) - x86_64
zabbix-tools                        Zabbix Official Repository (tools) - x86_64
```

Paquets installés : `zabbix-agent2-7.0.32-release2.el9`, `zabbix-get-7.0.32-release2.el9`, `sysstat-12.5.4-11.el9`.

**E8.1 et E8.2 — Services.**

```
[root@srv-core ~]# systemctl enable --now zabbix-agent2 sysstat.service sysstat-collect.timer sysstat-summary.timer
Created symlink /etc/systemd/system/multi-user.target.wants/zabbix-agent2.service → /usr/lib/systemd/system/zabbix-agent2.service.
[root@srv-core ~]# getent passwd zabbix
zabbix:x:983:980:Zabbix Monitoring System:/var/lib/zabbix:/sbin/nologin
[root@srv-core ~]# grep -E '^(Server|ServerActive)=' /etc/zabbix/zabbix_agent2.conf
Server=127.0.0.1
ServerActive=127.0.0.1
[root@srv-core ~]# systemctl is-active zabbix-agent2 ; systemctl is-enabled zabbix-agent2
active
enabled
[root@srv-core ~]# systemctl is-active sysstat-collect.timer ; systemctl is-enabled sysstat-collect.timer
active
enabled
[root@srv-core ~]# zabbix_get -s 127.0.0.1 -k agent.ping
1
```

**E8.3 et E8.4 — Sondes.** Fichier : `configs/helios-suivi.conf`.

Après avoir créé ce fichier, j'ai constaté que l'agent Zabbix ne démarrait plus. Le problème venait de ses permissions : avec l'umask `027` utilisé au TP2, le fichier avait été créé en `640 root:root`. Comme l'agent fonctionne avec le compte `zabbix`, il ne pouvait pas lire ce fichier de configuration. Le journal indiquait bien un refus d'accès :

```
nov. 05 16:49:20 srv-core zabbix_agent2[19357]: zabbix_agent2 [19357]: ERROR: Cannot read configuration: cannot include "/etc/zabbix/zabbix_agent2.d/helios-suivi.conf": open /etc/zabbix/zabbix_agent2.d/helios-suivi.conf: permission denied.
```

J'ai corrigé les droits en attribuant le fichier à `root:zabbix` avec les permissions `0640`. Root peut le modifier, le groupe `zabbix` peut le lire et les autres utilisateurs n'y ont aucun accès.

```
[root@srv-core ~]# chown root:zabbix /etc/zabbix/zabbix_agent2.d/helios-suivi.conf
[root@srv-core ~]# chmod 0640 /etc/zabbix/zabbix_agent2.d/helios-suivi.conf
[root@srv-core ~]# ls -l /etc/zabbix/zabbix_agent2.d/helios-suivi.conf
-rw-r-----. 1 root zabbix 288  5 nov.  16:47 /etc/zabbix/zabbix_agent2.d/helios-suivi.conf
[root@srv-core ~]# systemctl restart zabbix-agent2
[root@srv-core ~]# ss -tlnp | grep 10050
LISTEN 0      4096               *:10050            *:*    users:(("zabbix_agent2",pid=19497,fd=8))
[root@srv-core ~]# zabbix_get -s 127.0.0.1 -k helios.suivi.http
200
[root@srv-core ~]# zabbix_get -s 127.0.0.1 -k helios.suivi.age
48
```

### E9 — Sauvegarde et restauration

Fichiers : `configs/helios-suivi-backup.sh` (0750 root:root, `md5sum` = `cc0264a098b62d39610a0382214dbc0f`), `configs/helios-suivi-backup.service`, `configs/helios-suivi-backup.timer`.

Le script de sauvegarde reprend les mécanismes utilisés dans les scripts précédents : `set -Eeuo pipefail`, un verrou, un `trap` de nettoyage, une journalisation avec `logger -t helios-suivi-backup` et les codes de retour 0, 1, 2 et 3. La commande `tar --acls -czpf` permet de conserver les permissions et les ACL dans l'archive.

L'archive est d'abord créée sous un nom temporaire, puis renommée une fois l'opération terminée. Le script crée également un fichier `.sha256` pour vérifier son intégrité. Il conserve les sept sauvegardes les plus récentes et supprime les plus anciennes. J'ai choisi `umask 077`, car l'archive contient notamment le fichier sudoers et doit donc rester accessible uniquement à root.

Le service est exécuté avec le compte root, mais ses possibilités sont limitées par `CapabilityBoundingSet=CAP_DAC_OVERRIDE CAP_DAC_READ_SEARCH`. Son seul chemin autorisé en écriture est `/srv/helios/archives`.

```
[root@srv-core ~]# mkdir /srv/helios/archives
[root@srv-core ~]# chown helios:helios /srv/helios/archives
[root@srv-core ~]# chmod 0750 /srv/helios/archives
[root@srv-core ~]# ls -ld /srv/helios/archives
drwxr-x---. 2 helios helios 6  6 nov.  07:28 /srv/helios/archives
```

```
[root@srv-core ~]# systemctl daemon-reload
[root@srv-core ~]# systemctl enable --now helios-suivi-backup.timer
Created symlink /etc/systemd/system/timers.target.wants/helios-suivi-backup.timer → /etc/systemd/system/helios-suivi-backup.timer.
[root@srv-core ~]# systemctl start helios-suivi-backup.service ; echo "code=$?"
code=0
[root@srv-core ~]# journalctl -t helios-suivi-backup -n 3 --no-pager
nov. 06 07:34:40 srv-core helios-suivi-backup[36023]: sauvegarde suivi-20261106-073440.tar.gz creee (8,0K)
[root@srv-core ~]# ls -l /srv/helios/archives/suivi/
total 12
-rw-------. 1 root root 4253  6 nov.  07:34 suivi-20261106-073440.tar.gz
-rw-------. 1 root root   95  6 nov.  07:34 suivi-20261106-073440.tar.gz.sha256
[root@srv-core ~]# systemctl list-timers helios-suivi-backup.timer --no-pager
NEXT                        LEFT     LAST PASSED UNIT                      ACTIVATES
Sat 2026-11-07 03:15:00 CET 19h left -    -      helios-suivi-backup.timer helios-suivi-backup.service
```

Contenu de l'archive et empreinte :

```
[root@srv-core suivi]# tar -tzf suivi-*.tar.gz
srv/helios/suivi/
srv/helios/suivi/www/
srv/helios/suivi/www/index.html
srv/helios/suivi/www/etat.json
etc/systemd/system/helios-suivi.service
etc/systemd/system/helios-suivi-publish.service
etc/systemd/system/helios-suivi-publish.timer
etc/systemd/system/helios-suivi-backup.service
etc/systemd/system/helios-suivi-backup.timer
etc/sudoers.d/92-helios-suivi
etc/zabbix/zabbix_agent2.d/helios-suivi.conf
usr/local/sbin/helios-suivi-publish.sh
usr/local/sbin/helios-suivi-backup.sh
[root@srv-core suivi]# sha256sum -c suivi-*.sha256
suivi-20261106-073440.tar.gz: Réussi
```

Rotation (8 lancements de plus) :

```
[root@srv-core suivi]# for i in $(seq 8) ; do systemctl start helios-suivi-backup.service ; sleep 1 ; done
Job for helios-suivi-backup.service failed.
See "systemctl status helios-suivi-backup.service" and "journalctl -xeu helios-suivi-backup.service" for details.
[root@srv-core suivi]# ls -1 *.tar.gz | wc -l
7
[root@srv-core suivi]# ls -1 *.sha256 | wc -l
7
[root@srv-core suivi]# journalctl -t helios-suivi-backup -n 15 --no-pager
nov. 06 07:34:40 srv-core helios-suivi-backup[36023]: sauvegarde suivi-20261106-073440.tar.gz creee (8,0K)
nov. 06 07:37:29 srv-core helios-suivi-backup[36198]: sauvegarde suivi-20261106-073729.tar.gz creee (8,0K)
nov. 06 07:37:31 srv-core helios-suivi-backup[36220]: sauvegarde suivi-20261106-073731.tar.gz creee (8,0K)
nov. 06 07:37:33 srv-core helios-suivi-backup[36246]: sauvegarde suivi-20261106-073733.tar.gz creee (8,0K)
nov. 06 07:37:35 srv-core helios-suivi-backup[36268]: sauvegarde suivi-20261106-073734.tar.gz creee (8,0K)
nov. 06 07:37:37 srv-core helios-suivi-backup[36290]: sauvegarde suivi-20261106-073736.tar.gz creee (8,0K)
nov. 06 07:37:40 srv-core helios-suivi-backup[36319]: sauvegarde suivi-20261106-073739.tar.gz creee (8,0K)
nov. 06 07:37:42 srv-core helios-suivi-backup[36341]: rotation : suivi-20261106-073440.tar.gz supprimee
nov. 06 07:37:42 srv-core helios-suivi-backup[36345]: sauvegarde suivi-20261106-073741.tar.gz creee (8,0K)
[root@srv-core suivi]# journalctl -u helios-suivi-backup.service --since '-10min' --no-pager | grep -iE 'fail|err|status='
nov. 06 07:37:38 srv-core systemd[1]: helios-suivi-backup.service: Failed with result 'start-limit-hit'.
nov. 06 07:37:38 srv-core systemd[1]: Failed to start Sauvegarde du portail de suivi.
[root@srv-core suivi]# systemctl reset-failed helios-suivi-backup.service
[root@srv-core suivi]# systemctl is-failed helios-suivi-backup.service
inactive
```

J'ai observé un échec pendant cette série de tests. Il ne venait pas du script de sauvegarde : systemd a bloqué un nouveau démarrage à cause de sa limite de fréquence (`start-limit-hit`, plus de cinq démarrages en dix secondes). Le script n'a donc pas été exécuté lors de cette tentative. Les sauvegardes qui ont effectivement été lancées se sont terminées correctement. Ce blocage ne devrait pas se produire avec le déclenchement quotidien prévu, mais il est à prendre en compte lors de tests répétés.

### Vérification après redémarrage

J'ai ensuite redémarré le serveur pour vérifier que la configuration était bien conservée. Après `systemctl reboot`, les services et les timers attendus étaient actifs sans que j'aie besoin de les relancer manuellement. Les contrôles ci-dessous montrent aussi que le portail répondait toujours et que les règles de sécurité étaient présentes (`preuves/captures/reboot.png`).

```
[root@srv-core ~]# systemctl is-active helios-collect helios-suivi zabbix-agent2 helios-suivi-publish.timer helios-suivi-backup.timer helios-watch-auth.timer sysstat-collect.timer
active
active
active
active
active
active
active
[root@srv-core ~]# curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8080/etat.json
200
[root@srv-core ~]# firewall-cmd --zone=internal --query-port=8080/tcp
yes
[root@srv-core ~]# sshd -T | grep -E '^(port|permitrootlogin|passwordauthentication|allowgroups) '
port 2242
permitrootlogin no
passwordauthentication no
allowgroups ssh-admins
[root@srv-core ~]# sleep 120 ; zabbix_get -s 127.0.0.1 -k helios.suivi.http ; zabbix_get -s 127.0.0.1 -k helios.suivi.age
200
89
```

## 2. Justifications

**(a) Durcissement de `helios-suivi.service`.** Le score fourni par `systemd-analyze security` passe de 9,2 (« UNSAFE ») à 1,2 (« OK »). J'ai cherché à limiter ce que le processus peut consulter ou modifier, sans empêcher le portail de fonctionner.

`ProtectSystem=strict` rend le système de fichiers accessible en lecture seule au service. Je n'ai ajouté aucun `ReadWritePaths`, car le portail n'a pas besoin d'écrire sur le serveur. Les options `ProtectHome`, `PrivateDevices`, `PrivateUsers` et `ProtectProc=invisible` réduisent également son accès aux ressources du système. De leur côté, `NoNewPrivileges`, un `CapabilityBoundingSet` vide et `RestrictSUIDSGID` empêchent le processus d'obtenir des privilèges supplémentaires.

J'ai aussi limité les familles d'adresses réseau avec `RestrictAddressFamilies=AF_INET AF_INET6` et les appels système avec `SystemCallFilter=@system-service ~@privileged @resources`. Après ces changements, j'ai contrôlé le fonctionnement avec `curl` : les pages `/` et `/etat.json` renvoient toujours le code HTTP 200.

Pour le service de publication, j'ai utilisé `DevicePolicy=closed` plutôt que `PrivateDevices=yes`. Je voulais conserver l'accès à `/dev/log`, utilisé par `logger` pour écrire les messages dans le journal.

**(b) Pourquoi donner `--x` plutôt que `r-x` à `zabbix` sur `www` ?** Sur un répertoire, le droit `x` permet de le traverser et d'accéder à un fichier si son nom est connu. Le droit `r`, lui, permet d'afficher la liste des éléments du répertoire.

La sonde `helios.suivi.age` utilise `stat` sur le fichier `etat.json`, dont le nom est connu à l'avance. Le droit `--x` est donc suffisant pour son fonctionnement. Il évite aussi que le compte `zabbix` puisse lister les autres fichiers du répertoire. C'est une application du principe du moindre privilège.

J'ai vérifié ce comportement avec deux commandes : `runuser -u zabbix -- ls www` est refusée, alors que `runuser -u zabbix -- stat www/etat.json` fonctionne. Sans l'ACL dédiée à `zabbix`, le compte serait soumis aux droits de la catégorie « autres » (`---`) et ne pourrait pas consulter les métadonnées du fichier.

**(c) Le risque d'utiliser un joker `*` dans une règle sudo pour `journalctl`.** Une règle trop large, par exemple avec un joker, pourrait permettre à `lea` d'ajouter des options qui ne sont pas prévues. L'exemple testé est `sudo journalctl --vacuum-time=1s`, une commande qui supprime les anciens journaux et peut donc faire disparaître des traces utiles à l'audit.

Pour éviter cela, j'ai écrit les commandes autorisées avec leur chemin et leurs arguments précis. Le test `sudo -l -U lea /usr/bin/journalctl --vacuum-time=1s` renvoie le code 1 : cette commande n'est pas autorisée. J'ai également ajouté `--no-pager` aux commandes de consultation. Sans cette option, `systemctl status` ou `journalctl` peut ouvrir `less` avec les privilèges de root. Or, certaines commandes internes de `less`, comme `!sh`, peuvent alors permettre d'ouvrir un shell avec ces mêmes privilèges. C'est un risque similaire à celui rencontré avec `vim` pendant le TP2.

## 3. Test de restauration (E9.5)

**(a) Extraction de la dernière archive dans un répertoire de test, et comparaison des ACL de www avec la production.**

```
[root@srv-core suivi]# D=$(ls -1t /srv/helios/archives/suivi/suivi-*.tar.gz | head -1) ; echo "$D"
/srv/helios/archives/suivi/suivi-20261106-073741.tar.gz
[root@srv-core suivi]# mkdir -p /root/test-restau
[root@srv-core suivi]# tar --acls -xzpf "$D" -C /root/test-restau
[root@srv-core suivi]# diff <(cd /srv/helios/suivi && getfacl -R www 2>/dev/null) <(cd /root/test-restau/srv/helios/suivi && getfacl -R www 2>/dev/null) && echo "ACL identiques"
ACL identiques
```

**(b) Incident simulé : suppression de index.html, puis restauration de ce seul fichier avec ses ACL.**

```
[root@srv-core suivi]# date +%T
07:45:28
[root@srv-core suivi]# rm -f /srv/helios/suivi/www/index.html
[root@srv-core suivi]# curl -s http://127.0.0.1:8080/ | head -3
<!DOCTYPE HTML PUBLIC "-//W3C//DTD HTML 4.01//EN" "http://www.w3.org/TR/html4/strict.dtd">
<html>
<head>
[root@srv-core suivi]# tar --acls -xvzpf "$D" -C / srv/helios/suivi/www/index.html
srv/helios/suivi/www/index.html
[root@srv-core suivi]# ls -l /srv/helios/suivi/www/
total 8
-rw-r-----+ 1 helios-suivi suivi 184  6 nov.  07:44 etat.json
-rw-rw----+ 1 lea          suivi  46  5 nov.  14:27 index.html
[root@srv-core suivi]# getfacl /srv/helios/suivi/www/index.html
# file: srv/helios/suivi/www/index.html
# owner: lea
# group: suivi
user::rw-
user:helios-suivi:r-x           #effective:r--
group::rwx                      #effective:rw-
mask::rw-
other::---
[root@srv-core suivi]# curl -s http://127.0.0.1:8080/
<h1>Portail de suivi des tournees Helios</h1>
[root@srv-core suivi]# date +%T
07:45:29
```

Après la suppression de `index.html`, le portail n'avait plus de page d'accueil et affichait la liste des fichiers du répertoire. J'ai extrait uniquement `srv/helios/suivi/www/index.html` depuis l'archive. La sortie de `tar` confirme qu'un seul fichier a été restauré. Le fichier `etat.json` n'a pas été modifié.

J'ai ensuite contrôlé les droits : `index.html` a retrouvé son propriétaire `lea`, son groupe `suivi` et ses ACL. La page d'accueil était de nouveau accessible avec `curl`. Entre les deux commandes `date`, la restauration a pris environ une seconde (de 07:45:28 à 07:45:29), une fois les commandes préparées.

## 4. Mesure sous charge

```
[root@srv-core suivi]# systemctl show -p CPUUsageNSec -p MemoryCurrent helios-suivi.service
MemoryCurrent=10596352
CPUUsageNSec=9536817000
[root@srv-core suivi]# sar -u 2 > /root/sar-charge.txt &
[1] 36957
[root@srv-core suivi]# date +%T
07:47:46
[root@srv-core suivi]# time (for i in $(seq 2000); do curl -s -o /dev/null http://127.0.0.1:8080/etat.json; done)
[... la sortie de time (real/user/sys) a défilé hors des captures ...]
[root@srv-core suivi]# date +%T
07:50:50
[root@srv-core suivi]# kill %1
[root@srv-core suivi]# cat /root/sar-charge.txt
Linux 5.14.0-687.61.1.el9_8.x86_64 (srv-core)   06/11/2026      _x86_64_        (3 CPU)

07:47:46        CPU     %user     %nice   %system   %iowait    %steal     %idle
07:47:48        all      7,33      0,40     43,76      0,00      0,00     48,51
07:47:50        all      8,22      0,39     37,57      0,00      0,00     53,82
07:47:52        all      7,87      0,00     40,69      0,00      0,00     51,44
07:48:00        all      7,90      0,58     40,27      0,00      0,00     51,25
07:48:02        all     13,18      0,00     48,68      0,00      0,00     38,13
07:48:04        all      8,20      0,00     41,21      0,00      0,00     50,59
[... une ligne toutes les 2 s, même ordre de grandeur, voir preuves/captures/charge-2-sar.png et charge-3-apres.png ...]
07:50:00        all      8,37      0,97     40,66      0,00      0,00     50,00
07:50:02        all     13,12      0,00     50,21      0,00      0,00     36,67
07:50:04        all      7,98      0,00     40,27      0,00      0,00     51,75
07:50:46        all      7,84      0,00     37,06      0,00      0,00     55,10
07:50:48        all      8,48      0,00     38,73      0,00      0,00     52,79
07:50:50        all      7,93      0,39     45,84      0,00      0,00     45,84
[1]+  Complété              sar -u 2 > /root/sar-charge.txt
[root@srv-core suivi]# systemctl show -p CPUUsageNSec -p MemoryCurrent helios-suivi.service
MemoryCurrent=10608640
CPUUsageNSec=26536742000
```

Pour estimer le temps CPU consommé pendant le test, j'ai soustrait la valeur relevée avant les requêtes de celle relevée après :

`26 536 742 000 − 9 536 817 000 = 17 000 000 000 ns`, soit environ 17 secondes de CPU.

Le test a duré 184 secondes, entre 07:47:46 et 07:50:50. Le portail a donc consommé environ 9 % d'un CPU sur cette période. La mémoire affichée est passée d'environ 10,10 Mo à 10,12 Mo.

Le quota `CPUQuota=50%` n'a pas été atteint pendant ce test. Les requêtes étaient envoyées les unes après les autres, et non simultanément. Les mesures `sar` montrent une part importante de temps système (`%system` autour de 40 % sur les trois CPU), ce qui correspond notamment au lancement des 2 000 processus `curl`. Le test mesure donc aussi le coût de ces processus clients ; il ne permet pas, à lui seul, de conclure sur le comportement du portail avec plusieurs utilisateurs simultanés. Les pics observés à 07:48:02 et 07:50:02 correspondent aux publications déclenchées par le timer.

## 5. Limites connues

* **Permissions et umask :** l'umask `027` configuré au TP2 a entraîné deux difficultés pendant le projet. Le répertoire `/srv/helios/suivi` a été créé en `750`, ce qui empêchait certains comptes de le traverser. Le fichier `helios-suivi.conf` a aussi été créé sans droit de lecture pour `zabbix`. Ces deux problèmes m'ont montré qu'il faut vérifier les droits nécessaires à chaque étape, en particulier lorsqu'un service fonctionne avec un compte différent de root.
* **Emplacement des sauvegardes :** les archives sont stockées sur le même disque que le serveur. En cas de panne de ce disque, le service et ses sauvegardes pourraient être perdus en même temps. Une amélioration serait de copier les archives vers une autre machine, par exemple `srv-edge`, ou vers un NAS, avec `rsync` ou `scp`.
* **Chiffrement et authentification :** le portail utilise HTTP, sans chiffrement ni authentification. Son accès est limité au réseau métier par le pare-feu, mais cela ne remplace pas HTTPS. Une prochaine amélioration serait de placer un reverse proxy comme Nginx devant le portail et de configurer HTTPS ainsi qu'un mécanisme d'authentification adapté.
* **Limite de démarrage systemd :** lors de mes tests répétés, systemd a bloqué un lancement de la sauvegarde avec `start-limit-hit`. Ce comportement est lié à la limite de fréquence des démarrages, et non à une erreur du script. Il faut en tenir compte lorsqu'on lance plusieurs tests rapidement.
* **Test de charge :** les 2 000 requêtes ont été envoyées séquentiellement. Ce test ne représente donc pas plusieurs utilisateurs qui consultent le portail en même temps. Pour aller plus loin, je pourrais utiliser `ab` ou lancer plusieurs clients en parallèle afin d'observer le comportement du service sous charge simultanée.



