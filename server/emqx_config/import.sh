#!/bin/bash
set -e

docker exec ev_otomasyon_emqx /opt/emqx/bin/emqx eval 'emqx_authn_mnesia:import_users(<<"password_based:built_in_database">>, <<"/opt/emqx/etc/auth-built-in-db-bootstrap.csv">>).'

