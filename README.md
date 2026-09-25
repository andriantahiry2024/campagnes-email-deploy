# Campagnes email — déploiement listmonk + Gmail

Déploiement clé en main d'une application d'envoi de campagnes email :

- **listmonk** (logiciel libre, licence AGPL) : listes de contacts, import CSV, rédaction des
  campagnes, envoi, statistiques, désabonnements ;
- **PostgreSQL** pour les données ;
- **Gmail du client** comme serveur d'envoi, via un **mot de passe d'application** — aucune
  application Google Cloud à créer, aucun OAuth, aucune vérification Google.

Le client ne fournit que **deux valeurs** : son adresse Gmail et son mot de passe d'application.
La boîte d'envoi, l'expéditeur par défaut et l'adresse publique sont configurés automatiquement.

---

## 1. Démarrage rapide (serveur avec Docker)

```bash
cp .env.example .env
# Éditer .env : SMTP_USER, SMTP_PASSWORD, ROOT_URL, ADMIN_PASSWORD, DB_PASSWORD
docker compose up -d
```

Puis décommenter le bloc `ports:` du service `app` (ou placer un reverse-proxy devant) et ouvrir
`http://<serveur>:9000`.

## 2. Ce que le client remplit

| Valeur | Où elle se trouve |
|---|---|
| `SMTP_USER` | son adresse Gmail |
| `SMTP_PASSWORD` | le **mot de passe d'application de 16 caractères** généré sur [myaccount.google.com/apppasswords](https://myaccount.google.com/apppasswords) — sans espaces |

Le mot de passe d'application exige la **validation en deux étapes** activée sur le compte Google.
Il est révocable à tout moment, et Google le révoque automatiquement si le client change le mot de
passe de son compte (il faudra alors en générer un nouveau et relancer `docker compose up -d`).

## 3. Comment l'automatisation fonctionne

Le fichier `docker-compose.yml` enchaîne trois services, dans cet ordre :

1. **`db`** — PostgreSQL, avec un *healthcheck*.
2. **`init`** — exécute `listmonk --install --idempotent --yes` puis `--upgrade`, et crée le compte
   administrateur à partir de `ADMIN_USER` / `ADMIN_PASSWORD`. **Ce service est indispensable** :
   l'image officielle de listmonk n'exécute pas l'installation toute seule, et un conteneur lancé
   sans elle redémarre en boucle avec :
   `the database does not appear to be setup. Run --install.`
3. **`smtp-seed`** — écrit les réglages dans la base (`scripts/seed-settings.sql`) : boîte Gmail,
   expéditeur par défaut, adresse publique, et éventuellement le relevé IMAP des rejets.
4. **`app`** — démarre listmonk une fois les réglages en place, donc avec la bonne boîte d'envoi
   dès le premier lancement.

Cette séparation évite le piège classique : si les réglages étaient écrits après le démarrage de
l'application, celle-ci garderait en mémoire le serveur SMTP par défaut.

## 4. Déploiement sur Coolify (recommandé)

1. **Nouveau Service** → *Docker Compose* → coller le contenu de `docker-compose.yml`
   (ou pointer sur ce dépôt Git).
2. **Variables d'environnement** (Configuration → Environment Variables) :
   - le client : `SMTP_USER`, `SMTP_PASSWORD`
   - à générer : `DB_PASSWORD`, `ADMIN_PASSWORD`
   - `ROOT_URL` : l'adresse publique finale, ex. `https://campagnes.exemple.fr`
   - `SERVICE_FQDN_APP_9000` : le domaine de l'interface. Coolify route alors le proxy Traefik
     vers le port interne `9000` et émet le certificat HTTPS automatiquement.
3. **Ne publiez pas de `ports:`** : sur Coolify, le proxy s'en charge (voir la note dans le compose).
4. **Excluez les services éphémères du healthcheck.** `init` et `smtp-seed` s'arrêtent normalement
   après leur travail ; sans cette exclusion, Coolify peut considérer le Service comme en échec.
   Ajoutez sur ces deux services :

   ```yaml
       exclude_from_hc: true
   ```

   (Clé propre à Coolify : à ne pas laisser dans le fichier si vous déployez avec un simple
   `docker compose up` sur un serveur nu, Docker la refuserait.)

Le domaine doit exister dans le DNS (enregistrement `A` vers l'IP du serveur) **avant** la première
émission du certificat, et le fournisseur ne doit pas bloquer le **port sortant 465** (certains
hébergeurs le filtrent) : c'est ce port qui sert à joindre Gmail.

## 5. Mise à jour de listmonk

Changez `LISTMONK_VERSION` dans `.env`, puis :

```bash
docker compose up -d          # recrée init (qui rejoue --upgrade) puis app
```

Le service `init` rejoue les migrations à chaque démarrage du stack : c'est sans danger
(`--install --idempotent`).

## 6. Sauvegarde

Toutes les données vivent dans le volume `db-data`. Sauvegarde logique :

```bash
docker compose exec db pg_dump -U listmonk listmonk > sauvegarde-$(date +%F).sql
```

Restauration :

```bash
cat sauvegarde-2026-10-01.sql | docker compose exec -T db psql -U listmonk -d listmonk
```

Pensez aussi au volume `uploads` (médias des campagnes, logos).

## 7. Dépannage

| Symptôme | Cause et solution |
|---|---|
| `the database does not appear to be setup. Run --install.` en boucle | Le service `init` n'a pas tourné. Vérifiez son journal, et que `app` dépend bien de `smtp-seed`. |
| `dial tcp …:25: i/o timeout` | Les réglages SMTP n'ont pas été écrits : l'application utilise encore `smtp.yoursite.com:25`. Vérifiez le journal de `smtp-seed` puis redémarrez `app`. |
| `Username and Password not accepted` (535) | Le mot de passe saisi est celui du compte Google, pas un **mot de passe d'application**. Voir la section 2. |
| Timeout à l'envoi sur le port 465 | Le port sortant est filtré par l'hébergeur. Demandez son ouverture, ou utilisez le port 587 (STARTTLS). |
| Le message part mais l'expéditeur affiché change | Gmail remplace toute adresse « De » qui n'est pas celle du compte connecté (ou un alias vérifié). Utilisez l'adresse Gmail. |
| Les envois s'arrêtent après quelques centaines de messages | Plafond Gmail : ~500 destinataires/jour pour un compte `@gmail.com` (≈2 000 en Workspace). Réglez le débit dans *Paramètres → Performance*. |

## 8. Limites à connaître

- **Plafond Gmail** : ~500 destinataires par jour pour une adresse `@gmail.com`. Prévoir une montée
  en charge progressive ; envoyer des centaines de messages d'affilée depuis une boîte personnelle
  peut faire limiter, voire suspendre le compte.
- **Envoi depuis un domaine tiers** (`contact@exemple.fr`) : possible uniquement si l'adresse est un
  alias vérifié dans Gmail, et avec SPF/DKIM configurés sur le domaine. Sinon, rester sur l'adresse
  Gmail.
- **Relevé des rejets** (`BOUNCE_ENABLED=true`) : nécessite qu'IMAP soit activé dans les paramètres
  Gmail du client.
