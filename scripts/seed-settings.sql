-- =====================================================================
--  Réglages listmonk appliqués automatiquement au premier démarrage.
--
--  Objectif : le client n'a que son adresse Gmail et son mot de passe
--  d'application à fournir ; la boîte d'envoi, l'expéditeur par défaut
--  et l'adresse publique sont configurés ici.
--
--  Les valeurs sont injectées par psql via -v (voir docker-compose.yml).
-- =====================================================================

\set ON_ERROR_STOP on

-- 1) Boîte d'envoi : Gmail en SMTP avec mot de passe d'application.
--    Port 465 en TLS implicite, authentification LOGIN : ce sont les
--    valeurs imposées par Gmail pour un mot de passe d'application.
UPDATE settings
   SET value = jsonb_build_array(jsonb_build_object(
         'host',            'smtp.gmail.com',
         'port',            465,
         'enabled',         true,
         'username',        :'smtp_user',
         'password',        :'smtp_password',
         'tls_type',        'TLS',
         'tls_skip_verify', false,
         'auth_protocol',   'login',
         'hello_hostname',  '',
         'max_conns',       10,
         'idle_timeout',    '15s',
         'wait_timeout',    '5s',
         'max_msg_retries', 2,
         'msg_retry_delay', '10ms',
         'email_headers',   '[]'::jsonb,
         'from_addresses',  '[]'::jsonb))
 WHERE key = 'smtp';

-- 2) Expéditeur par défaut de toutes les campagnes.
--    Gmail n'autorise que l'adresse du compte connecté (ou un alias
--    « Envoyer depuis » vérifié) : on l'impose donc dès le départ.
UPDATE settings
   SET value = to_jsonb((:'from_name' || ' <' || :'smtp_user' || '>')::text)
 WHERE key = 'app.from_email';

-- 3) Adresse publique : liens de désabonnement et pages publiques.
UPDATE settings SET value = to_jsonb(:'root_url'::text)  WHERE key = 'app.root_url';
UPDATE settings SET value = to_jsonb(:'site_name'::text) WHERE key = 'app.site_name';

-- 4) Relevé des rejets (bounces) dans la même boîte Gmail.
--    Désactivé par défaut : l'activer suppose qu'IMAP soit activé dans
--    les paramètres Gmail du client. Mettre BOUNCE_ENABLED=true dans .env.
UPDATE settings
   SET value = jsonb_build_array(jsonb_build_object(
         'host',            'imap.gmail.com',
         'port',            993,
         'type',            'imap',
         'enabled',         (:'bounce_enabled')::boolean,
         'username',        :'smtp_user',
         'password',        :'smtp_password',
         'tls_enabled',     true,
         'tls_skip_verify', false,
         'auth_protocol',   'userpass',
         'scan_interval',   '15m',
         'return_path',     :'smtp_user'))
 WHERE key = 'bounce.mailboxes';

UPDATE settings
   SET value = to_jsonb((:'bounce_enabled')::boolean)
 WHERE key = 'bounce.enabled';

-- Vérification (visible dans les journaux du service smtp-seed) :
SELECT key, left(value::text, 80) AS valeur
  FROM settings
 WHERE key IN ('smtp', 'app.from_email', 'app.root_url', 'bounce.enabled', 'bounce.mailboxes')
 ORDER BY key;
