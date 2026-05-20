-- 每条配置请求：设备 UUID（与模板 query device_id / Header X-Device-Id 一致）、应用名（从 User-Agent 解析）
ALTER TABLE access_logs ADD COLUMN device_id TEXT;
ALTER TABLE access_logs ADD COLUMN app_name TEXT;
