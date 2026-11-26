import pg from 'pg';
import { readFile } from 'node:fs/promises';
let pool;
export async function database() {
  if (!pool) {
    const url = process.env.DATABASE_URL || process.env.NETLIFY_DB_URL;
    requireThat(url,'Workspace database has not been configured',503);
    pool = new pg.Pool({connectionString:url, max:4, idleTimeoutMillis:10000});
  }
  return pool;
}
export async function transaction(run) {
  const client = await (await database()).connect();
  try {
    await client.query('BEGIN');
    const result = await run(client);
    await client.query('COMMIT');
    return result;
  } catch (error) {
    await client.query('ROLLBACK');
    throw error;
  } finally { client.release(); }
}
export async function migrate() {
  const sql = await readFile(new URL('../database/schema.sql',import.meta.url),'utf8');
  await (await database()).query(sql);
}
export async function one(c,sql,args=[]) { return (await c.query(sql,args)).rows[0]; }
export async function many(c,sql,args=[]) { return (await c.query(sql,args)).rows; }
export function requireThat(valid, message, status=400) {
  if (!valid) throw Object.assign(new Error(message),{status});
}
export function uuid(value) {
  requireThat(typeof value==='string' && /^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i.test(value),'Invalid identifier');
  return value.toLowerCase();
}
export function string(value,max=64000) {
  requireThat(typeof value==='string' && value.trim().length>0 && value.length<=max,'Invalid text');
  return value;
}
