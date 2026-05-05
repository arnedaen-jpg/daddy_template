-- daddy-ab-config on Supabase：KV 模拟 + 访问日志（数据可空库重建）

CREATE TABLE IF NOT EXISTS kv_store (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_kv_store_key_prefix ON kv_store (key text_pattern_ops);

COMMENT ON TABLE kv_store IS 'A/B、黑名单、苹果 ASN 同步等键值，键名与 Cloudflare KV 一致';

CREATE TABLE IF NOT EXISTS access_logs (
  id BIGSERIAL PRIMARY KEY,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  ip TEXT,
  country TEXT,
  city TEXT,
  region TEXT,
  asn TEXT,
  query_json JSONB,
  bundle_id TEXT,
  device_id TEXT,
  app_name TEXT,
  ios_version TEXT,
  device_model TEXT,
  remark TEXT
);

CREATE INDEX IF NOT EXISTS idx_access_logs_bundle_id ON access_logs (bundle_id);
CREATE INDEX IF NOT EXISTS idx_access_logs_created_at ON access_logs (created_at DESC);

ALTER TABLE kv_store ENABLE ROW LEVEL SECURITY;
ALTER TABLE access_logs ENABLE ROW LEVEL SECURITY;

-- Edge Function 使用 service_role，不暴露 anon 访问；策略禁止客户端直连表
CREATE POLICY "deny_all_access_logs"
  ON access_logs FOR ALL
  USING (false)
  WITH CHECK (false);

CREATE POLICY "deny_all_kv_store"
  ON kv_store FOR ALL
  USING (false)
  WITH CHECK (false);
