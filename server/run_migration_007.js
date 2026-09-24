const fs = require('fs');
const path = require('path');
const db = require('./src/db');

async function runMigration() {
  try {
    const sqlPath = path.join(__dirname, 'migrations', '007_guest_and_invitations.sql');
    const sql = fs.readFileSync(sqlPath, 'utf8');
    console.log('Applying migration 007...');
    await db.query(sql);
    console.log('MIGRATION_007_APPLIED_SUCCESSFULLY');
    process.exit(0);
  } catch (err) {
    console.error('Migration 007 Error:', err);
    process.exit(1);
  }
}

runMigration();

