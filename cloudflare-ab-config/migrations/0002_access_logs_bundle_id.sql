-- 记录配置请求头中的 Bundle ID，供管理页展示「近期出现过的 Bundle」
ALTER TABLE access_logs ADD COLUMN bundle_id TEXT;
