const fs = require('fs');
const path = require('path');
const db = require('./src/db');

async function runMigration() {
  try {
    const sqlPath = path.join(__dirname, 'migrations', '010_night_peace_and_child_lock.sql');
    const sql = fs.readFileSync(sqlPath, 'utf8');
    console.log('Applying migration 010...');
    await db.query(sql);
    console.log('MIGRATION_010_APPLIED_SUCCESSFULLY');
    process.exit(0);
  } catch (err) {
    console.error('Migration 010 Error:', err);
    process.exit(1);
  }
}

runMigration();

