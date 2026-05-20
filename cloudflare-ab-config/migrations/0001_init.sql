-- D1：配置接口访问日志（IP + Cloudflare 边缘归属）
CREATE TABLE IF NOT EXISTS access_logs (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  created_at TEXT NOT NULL DEFAULT (datetime('now')),
  ip TEXT,
  country TEXT,
  city TEXT,
  region TEXT,
  asn TEXT,
  query_json TEXT
);
