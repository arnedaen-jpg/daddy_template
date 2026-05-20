-- 配置请求：iOS 系统版本、设备型号（来自 Header X-iOS-Version / X-Device-Model）
ALTER TABLE access_logs ADD COLUMN ios_version TEXT;
ALTER TABLE access_logs ADD COLUMN device_model TEXT;
