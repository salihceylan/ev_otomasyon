const fs = require('fs');
const path = require('path');
const db = require('./src/db');

async function runMigration() {
  try {
    const sqlPath = path.join(__dirname, 'migrations', '008_transfer_and_emergency_reset.sql');
    const sql = fs.readFileSync(sqlPath, 'utf8');
    console.log('Applying migration 008...');
    await db.query(sql);
    console.log('MIGRATION_008_APPLIED_SUCCESSFULLY');
    process.exit(0);
  } catch (err) {
    console.error('Migration 008 Error:', err);
    process.exit(1);
  }
}

runMigration();

