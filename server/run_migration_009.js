const fs = require('fs');
const path = require('path');
const db = require('./src/db');

async function runMigration() {
  try {
    const sqlPath = path.join(__dirname, 'migrations', '009_system_doctor_and_disaster_recovery.sql');
    const sql = fs.readFileSync(sqlPath, 'utf8');
    console.log('Applying migration 009...');
    await db.query(sql);
    console.log('MIGRATION_009_APPLIED_SUCCESSFULLY');
    process.exit(0);
  } catch (err) {
    console.error('Migration 009 Error:', err);
    process.exit(1);
  }
}

runMigration();

