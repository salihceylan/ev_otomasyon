#!/usr/bin/env node
'use strict';
require('dotenv').config({ path: '/home/salihceylan/ev_otomasyon/server/.env' });
const { Pool } = require('pg');
const pool = new Pool({ connectionString: 'postgresql://ev_admin:GudeEvPg2026!SecurePass@127.0.0.1:5434/ev_otomasyon' });
pool.query("SELECT tablename FROM pg_tables WHERE schemaname='public' ORDER BY tablename")
  .then(r => { console.log(r.rows.map(x => x.tablename).join(', ')); pool.end(); })
  .catch(e => { console.error(e.message); pool.end(); });

