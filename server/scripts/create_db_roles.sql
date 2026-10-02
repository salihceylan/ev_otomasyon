-- ==============================================================================
-- AHBU Akilli Ev - EMQX icin EN AZ YETKILI veritabani rolu (WP-C, plan C5)
-- ==============================================================================
-- EMQX kimlik/ACL sorgulari icin kullanilan rol YALNIZCA su tablolari OKUYABILIR:
--   mqtt_credentials, mqtt_acl (WP-B, migration 020) ve gecis doneminde mqtt_users (migration 024).
-- Uygulamanin sahip rolunu (POSTGRES_USER) EMQX'e VERMEYIN: EMQX ele gecirilirse tum veri okunamasin.
--
-- KULLANIM (parola komut satirinda GORUNMEZ: psql >= 15 \getenv ile ortamdan okur):
--   export EMQX_AUTHDB_PASSWORD='<rastgele, en az 24 karakter>'     # docker-compose.yml'deki ayni deger
--   docker exec -i -e EMQX_AUTHDB_PASSWORD ev_otomasyon_postgres \
--     sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -v ON_ERROR_STOP=1' < scripts/create_db_roles.sql
-- (Postgres kapsayicisinin psql'i 16'dir; yerel psql < 15 ise -v emqx_password=... kullanmak
--  parolayi surec listesinde gosterir, tercih etmeyin.)
--
-- Migration'lar (020, 024) uygulandiktan SONRA calistirin; tablolar yoksa ilgili GRANT atlanir ve
-- NOTICE verilir. Parolayi dondurmak icin ayni komutu yeni degerle yeniden calistirin (IDEMPOTENT).
-- Rol adi EMQX_AUTHDB_USER ile ayni olmalidir (varsayilan: emqx_auth).

\set ON_ERROR_STOP on
\getenv emqx_password EMQX_AUTHDB_PASSWORD
\getenv emqx_role EMQX_AUTHDB_USER

\if :{?emqx_password}
\else
  \echo 'HATA: EMQX_AUTHDB_PASSWORD ortam degiskeni tanimli degil (docker exec -e EMQX_AUTHDB_PASSWORD ...).'
  \quit
\endif
\if :{?emqx_role}
\else
  \set emqx_role emqx_auth
\endif

-- 1) Rol (yoksa olustur; varsa yalniz parolayi guncelle). NOSUPERUSER ve baska yetki YOK.
SELECT format('CREATE ROLE %I LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOINHERIT CONNECTION LIMIT 20 PASSWORD %L',
              :'emqx_role', :'emqx_password')
 WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'emqx_role') \gexec

SELECT format('ALTER ROLE %I LOGIN PASSWORD %L', :'emqx_role', :'emqx_password') \gexec

-- Rol basina guvenlik: salt-okunur oturum, kisa sorgu suresi
SELECT format('ALTER ROLE %I SET default_transaction_read_only = on', :'emqx_role') \gexec
SELECT format('ALTER ROLE %I SET statement_timeout = ''5s''', :'emqx_role') \gexec

-- 2) Baglanti ve sema: yalnizca baglanti + sema gorunurlugu
SELECT format('GRANT CONNECT ON DATABASE %I TO %I', current_database(), :'emqx_role') \gexec
SELECT format('GRANT USAGE ON SCHEMA public TO %I', :'emqx_role') \gexec
SELECT format('REVOKE CREATE ON SCHEMA public FROM %I', :'emqx_role') \gexec

-- 3) Onceki yetkileri temizle (yanlislikla verilmis olabilecek her sey), sonra YALNIZCA gerekeni ver
SELECT format('REVOKE ALL ON ALL TABLES IN SCHEMA public FROM %I', :'emqx_role') \gexec
SELECT format('REVOKE ALL ON ALL SEQUENCES IN SCHEMA public FROM %I', :'emqx_role') \gexec

SELECT format('GRANT SELECT ON TABLE %I TO %I', t.name, :'emqx_role')
  FROM (VALUES ('mqtt_credentials'), ('mqtt_acl'), ('mqtt_users')) AS t(name)
 WHERE to_regclass('public.' || t.name) IS NOT NULL \gexec

-- Eksik tablolar icin uyari (GRANT atlandi)
SELECT format('UYARI: public.%s tablosu bulunamadi (ilgili migration uygulanmamis olabilir); GRANT atlandi', t.name) AS uyari
  FROM (VALUES ('mqtt_credentials'), ('mqtt_acl'), ('mqtt_users')) AS t(name)
 WHERE to_regclass('public.' || t.name) IS NULL;

-- 4) Dogrulama ozeti: rolun SELECT yetkisi olan tablolari
SELECT table_name AS select_yetkisi_olan_tablo
  FROM information_schema.role_table_grants
 WHERE grantee = :'emqx_role' AND privilege_type = 'SELECT'
 ORDER BY table_name;
