#!/bin/bash
set -e

echo "=== Adding EMQX Built-in DB Users ==="

docker exec ev_otomasyon_emqx /opt/emqx/bin/emqx eval 'emqx_authn_mnesia:add_user(<<"password_based:built_in_database">>, #{user_id => <<"backend_service">>, password => <<"GudeBackend2026!MqttSec">>}).'
docker exec ev_otomasyon_emqx /opt/emqx/bin/emqx eval 'emqx_authn_mnesia:add_user(<<"password_based:built_in_database">>, #{user_id => <<"home_101">>, password => <<"PassHome101!Sec">>}).'
docker exec ev_otomasyon_emqx /opt/emqx/bin/emqx eval 'emqx_authn_mnesia:add_user(<<"password_based:built_in_database">>, #{user_id => <<"home_102">>, password => <<"PassHome102!Sec">>}).'

echo "=== Users Added Successfully ==="

