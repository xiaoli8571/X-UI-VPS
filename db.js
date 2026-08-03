// db.js — D1-compatible database layer over Node's built-in SQLite (node:sqlite)
// Requires Node >= 22.5 (node:sqlite). Zero native deps, works on any arch.
// All methods are async (return Promises), matching Cloudflare D1 semantics:
//   prepare(sql).bind(...).all() | .first() | .run()   -> Promise
//   db.batch([statements])                             -> Promise
import { DatabaseSync } from 'node:sqlite';
import fs from 'node:fs';
import path from 'node:path';

function normalizeParams(params) {
  // D1 accepts undefined params; node:sqlite does not — coerce to null.
  return params.map(p => (p === undefined ? null : p));
}

class Statement {
  constructor(db, sql) {
    this._db = db;
    this._sql = sql;
    this._params = [];
  }

  bind(...args) {
    this._params = args.length === 1 && Array.isArray(args[0]) ? args[0] : args;
    return this;
  }

  _stmt() {
    return this._db.prepare(this._sql);
  }

  // Async so `.catch()`/`.then()` work like D1.
  async all() {
    const rows = this._stmt().all(...normalizeParams(this._params));
    return { results: rows, meta: {} };
  }

  async first() {
    const row = this._stmt().get(...normalizeParams(this._params));
    return row === undefined ? null : row;
  }

  async run() {
    const info = this._stmt().run(...normalizeParams(this._params));
    return { meta: { changes: Number(info.changes), last_row_id: Number(info.lastInsertRowid) } };
  }
}

class D1Compat {
  constructor(sqlite, dbPath) {
    this._db = sqlite;
    this._dbPath = dbPath;
  }

  prepare(sql) {
    return new Statement(this._db, sql);
  }

  async batch(statements) {
    const useTx = statements.length > 1;
    if (useTx) this._db.exec('BEGIN');
    try {
      const results = [];
      for (const st of statements) results.push(await st.all());
      if (useTx) this._db.exec('COMMIT');
      return results;
    } catch (e) {
      if (useTx) { try { this._db.exec('ROLLBACK'); } catch (_) {} }
      throw e;
    }
  }

  async dump() {
    return { total_bytes: 0 };
  }
}

export function openDatabase(dbPath) {
  fs.mkdirSync(path.dirname(dbPath), { recursive: true });
  const sqlite = new DatabaseSync(dbPath);
  sqlite.exec('PRAGMA journal_mode = WAL');
  sqlite.exec('PRAGMA foreign_keys = ON');
  sqlite.exec('PRAGMA busy_timeout = 5000');
  return new D1Compat(sqlite, dbPath);
}
