/**
 * A/B 配置 Worker + D1 访问日志 + 管理后台
 * GET /client/api/config — 模板 ConfigService 约定
 * GET /client/api/ping — 仅鉴权探活（排障用）
 * GET /admin — 管理页（设备 / Bundle 全员强制 B、黑名单永远 A 面）
 */
import { composeAdminHtml } from "../../supabase/functions/daddy-ab-config/compose_admin_html.ts";

export interface Env {
  CONFIG_KV: KVNamespace;
  CONFIG_DB?: D1Database;
  CONFIG_AUTH_TOKEN?: string;
  /** wrangler [vars]：为 true/1/yes 时，管理页与 /admin/api/* 不校验 Token（公网暴露日志与强制 B，生产务必关闭） */
  ADMIN_OPEN?: string;
  /** 为 true 时允许用请求头 X-Mock-Apple-ASN: 1 模拟苹果出口（仅演示，生产务必关闭） */
  DEMO_MOCK_APPLE?: string;
}

function adminOpen(env: Env): boolean {
  const v = (env.ADMIN_OPEN ?? "").trim().toLowerCase();
  return v === "1" || v === "true" || v === "yes";
}

function demoMockApple(env: Env): boolean {
  const v = (env.DEMO_MOCK_APPLE ?? "").trim().toLowerCase();
  return v === "1" || v === "true" || v === "yes";
}

const CONFIG_PATH = "/client/api/config";
const KV_KEY_DEFAULT = "ab_config";
/** 设备强制 B：存在该键且值为 B/1/true 时，该设备恒为 B（低于黑名单） */
const KV_DEVICE_FORCE_PREFIX = "device_force_b_";
/** bundle_id 与 device_id 拼接分界（单字符，bundle 一般为反向域名不含该字符） */
const KV_DEVICE_FORCE_SEP = "\u001f";
/** Bundle 全员强制 B：该 Bundle 下所有设备为 B（低于黑名单；高于单设备与 KV 比例） */
const KV_BUNDLE_FORCE_PREFIX = "bundle_force_b_";
/** 黑名单：命中设备 UUID 或客户端 IP 时永远返回 A（高于一切强制 B） */
const KV_BLOCKLIST_DEVICE_PREFIX = "ab_blocklist_device_";
const KV_BLOCKLIST_IP_PREFIX = "ab_blocklist_ip_";
/** 曾命中苹果 ASN 且上报过设备 UUID：该设备永久 A（不写 IP 黑名单，避免同 IP 误伤） */
const KV_APPLE_ASN_LOCK_PREFIX = "apple_asn_lock_a_";
/** PeeringDB 同步结果 JSON：{ updatedAt, source, asns } */
const KV_APPLE_ASN_FETCHED = "apple_asn_fetched_json";
/** PeeringDB 中 Apple Inc. 组织 ID（其下网络为苹果官方登记 ASN） */
const PEERINGDB_APPLE_ORG_ID = 8418;
/** access_logs 最多保留条数，超出则按 id 最旧优先删除 */
const ACCESS_LOGS_MAX_ROWS = 1000;

// #region agent log
function agentDebugLog(entry: {
  hypothesisId: string;
  location: string;
  message: string;
  data: Record<string, unknown>;
}): void {
  const payload = {
    sessionId: "a4ecd2",
    timestamp: Date.now(),
    ...entry,
  };
  const body = JSON.stringify(payload);
  console.log("__AGENT_DEBUG__", body);
  // 勿在生产 Worker 内 fetch 127.0.0.1：边缘上会导致异常/长时间挂起，客户端表现为 CF 522 等。
}
// #endregion

function configKvKey(bundleId: string | null | undefined): string {
  const b = (bundleId ?? "").trim();
  if (!b) return KV_KEY_DEFAULT;
  return `${KV_KEY_DEFAULT}_${b}`;
}

/** 单设备强 B：按「Bundle + 设备」维度，同一 UUID 在不同 Bundle 下互不影响 */
function deviceForceKvKey(bundleId: string, deviceId: string): string {
  const b = (bundleId ?? "").trim();
  const d = deviceId.trim();
  return `${KV_DEVICE_FORCE_PREFIX}${b}${KV_DEVICE_FORCE_SEP}${d}`;
}

function bundleForceKvKey(bundleId: string): string {
  return `${KV_BUNDLE_FORCE_PREFIX}${bundleId.trim()}`;
}

function blocklistDeviceKey(deviceId: string): string {
  return `${KV_BLOCKLIST_DEVICE_PREFIX}${deviceId.trim()}`;
}

function blocklistIpKey(ip: string): string {
  return `${KV_BLOCKLIST_IP_PREFIX}${encodeURIComponent(ip.trim())}`;
}

function appleAsnDeviceLockKey(deviceId: string): string {
  return `${KV_APPLE_ASN_LOCK_PREFIX}${deviceId.trim()}`;
}

async function isAppleAsnDeviceLocked(
  env: Env,
  deviceId: string,
): Promise<boolean> {
  const d = deviceId.trim();
  if (!d) return false;
  const v = await env.CONFIG_KV.get(appleAsnDeviceLockKey(d));
  return v !== null && v !== undefined && String(v).trim() !== "";
}

function kvMeansB(raw: string | null | undefined): boolean {
  const v = raw?.trim().toLowerCase();
  return v === "b" || v === "1" || v === "true" || v === "yes";
}

async function isBlocklisted(
  env: Env,
  ip: string,
  deviceId: string,
): Promise<boolean> {
  const d = deviceId.trim();
  if (d) {
    const v = await env.CONFIG_KV.get(blocklistDeviceKey(d));
    if (v !== null && v !== undefined && String(v).trim() !== "") return true;
  }
  const x = ip.trim();
  if (x) {
    const v = await env.CONFIG_KV.get(blocklistIpKey(x));
    if (v !== null && v !== undefined && String(v).trim() !== "") return true;
  }
  return false;
}

async function isBundleForcedB(env: Env, bundleId: string): Promise<boolean> {
  const b = bundleId.trim();
  if (!b) return false;
  const raw = await env.CONFIG_KV.get(bundleForceKvKey(b));
  return kvMeansB(raw);
}

async function listBlocklist(env: Env): Promise<{
  devices: string[];
  ips: string[];
}> {
  const devices: string[] = [];
  const ips: string[] = [];
  let cursor: string | undefined;
  const prefix = "ab_blocklist_";
  do {
    const page = await env.CONFIG_KV.list({ prefix, cursor });
    for (const meta of page.keys) {
      const name = meta.name;
      if (name.startsWith(KV_BLOCKLIST_DEVICE_PREFIX)) {
        devices.push(name.slice(KV_BLOCKLIST_DEVICE_PREFIX.length));
      } else if (name.startsWith(KV_BLOCKLIST_IP_PREFIX)) {
        const enc = name.slice(KV_BLOCKLIST_IP_PREFIX.length);
        try {
          ips.push(decodeURIComponent(enc));
        } catch {
          ips.push(enc);
        }
      }
    }
    cursor = page.list_complete ? undefined : page.cursor;
  } while (cursor);
  devices.sort();
  ips.sort();
  return { devices, ips };
}

function jsonResponse(data: unknown, status = 200): Response {
  return new Response(JSON.stringify(data), {
    status,
    headers: {
      "Content-Type": "application/json; charset=utf-8",
      "Cache-Control": "no-store",
    },
  });
}

function clientIp(request: Request): string {
  const cfIp = request.headers.get("CF-Connecting-IP");
  if (cfIp) return cfIp.trim();
  const xff = request.headers.get("X-Forwarded-For");
  if (xff) return xff.split(",")[0]?.trim() ?? "";
  return "";
}

function tokenFromRequest(request: Request): string {
  const auth = request.headers.get("Authorization");
  if (auth?.startsWith("Bearer ")) return auth.slice(7).trim();
  return request.headers.get("X-Config-Token")?.trim() ?? "";
}

function assertAdmin(request: Request, env: Env): Response | null {
  if (adminOpen(env)) return null;
  const secret = env.CONFIG_AUTH_TOKEN?.trim() ?? "";
  if (!secret) {
    return jsonResponse(
      {
        code: 503,
        message:
          "Admin 已禁用：在 wrangler.toml 设置 ADMIN_OPEN=true，或执行 wrangler secret put CONFIG_AUTH_TOKEN",
      },
      503,
    );
  }
  if (tokenFromRequest(request) !== secret) {
    return jsonResponse({ code: 401, message: "Unauthorized" }, 401);
  }
  return null;
}

/** User-Agent: AppName/1.0 (iOS …; …) */
function parseAppNameFromUa(ua: string | null): string {
  if (!ua) return "";
  const m = ua.match(/^([^/]+)\//);
  const raw = m ? m[1].trim() : "";
  return raw.length > 200 ? raw.slice(0, 200) : raw;
}

/** X-App-Name 使用 URL 编码，避免中文应用名在 Header 中被过滤 */
function parseAppNameFromRequest(request: Request, ua: string | null): string {
  const rawHeader = request.headers.get("X-App-Name")?.trim() ?? "";
  if (rawHeader) {
    let appName = rawHeader;
    try {
      appName = decodeURIComponent(rawHeader);
    } catch {
      // 兼容历史或手工调试时直接传明文 ASCII 的 Header。
    }
    const trimmed = appName.trim();
    return trimmed.length > 200 ? trimmed.slice(0, 200) : trimmed;
  }
  return parseAppNameFromUa(ua);
}

/** D1 中 country / region / city + asn（含组织名与 AS 号）拼成可读归属 */
function formatIpAttribution(
  country: string | null | undefined,
  region: string | null | undefined,
  city: string | null | undefined,
  asnOrOrg: string | null | undefined,
): string {
  const c = (country ?? "").trim();
  const r = (region ?? "").trim();
  const cy = (city ?? "").trim();
  const org = (asnOrOrg ?? "").trim();
  const loc = [c, r, cy].filter((x) => x.length > 0).join(" / ");
  const parts: string[] = [];
  if (loc) parts.push(loc);
  if (org) parts.push(org);
  return parts.length > 0 ? parts.join(" · ") : "—";
}

/** 管理页设备列第二行：iOS 版本与型号 */
function formatDeviceSubtitle(
  ios: string | null | undefined,
  model: string | null | undefined,
): string {
  const v = (ios ?? "").trim();
  const m = (model ?? "").trim();
  if (!v && !m) return "";
  if (v && m) return `iOS ${v} · ${m}`;
  if (v) return `iOS ${v}`;
  return m;
}

/** 管理页 Bundle 列第二行：App 版本号（可选 build） */
function formatBundleSubtitle(
  appVersion: string | null | undefined,
  buildNumber: string | null | undefined,
): string {
  const a = (appVersion ?? "").trim();
  const b = (buildNumber ?? "").trim();
  if (!a && !b) return "";
  if (a && b) return `${a} (${b})`;
  return a || b;
}

/**
 * 与 Flutter DeviceInfoManager.userAgent 一致：`App/x (iOS ver; model)`
 * 在部分环境下自定义 Header 不可见时，仍可从 UA 解析。
 */
function parseIosDeviceFromUserAgent(ua: string | null): {
  ios: string;
  model: string;
} {
  if (!ua) return { ios: "", model: "" };
  const m = ua.match(/\(\s*iOS\s+([^;]*?)\s*;\s*([^)]*?)\s*\)/i);
  if (!m) return { ios: "", model: "" };
  return { ios: m[1].trim(), model: m[2].trim() };
}

/** 从入库时的 query_json（即 URL query 快照）补全展示 */
function pickDeviceMetaFromQueryJson(
  raw: string | null | undefined,
): {
  ios: string;
  model: string;
  app_version: string;
  build_number: string;
} {
  const empty = { ios: "", model: "", app_version: "", build_number: "" };
  if (!raw) return empty;
  try {
    const o = JSON.parse(raw) as Record<string, unknown>;
    const str = (k: string): string =>
      typeof o[k] === "string" ? (o[k] as string).trim() : "";
    return {
      ios: str("os_version"),
      model: str("device_model"),
      app_version: str("app_version"),
      build_number: str("build_number"),
    };
  } catch {
    return empty;
  }
}

/** 仅当 D1 明确报「缺列」时才降级 INSERT，避免 SQLITE_BUSY 等误走无 ios 列的语句导致全 NULL */
function d1ErrorIndicatesUnknownColumn(err: unknown): boolean {
  const s = String(
    err && typeof err === "object" && "message" in err
      ? (err as { message?: string }).message
      : err,
  ).toLowerCase();
  return (
    s.includes("no such column") ||
    s.includes("has no column named") ||
    s.includes("has no column")
  );
}

function d1RunErrorText(
  result: { success: boolean; error?: string; meta?: unknown },
): string {
  const e = (result as { error?: string }).error;
  if (e && String(e).length > 0) return String(e);
  try {
    return JSON.stringify(result.meta ?? {});
  } catch {
    return String(result.meta);
  }
}

/** 插入成功后裁剪日志表，仅保留最近 maxRows 条（id 最大者保留） */
async function pruneAccessLogsToMax(
  db: D1Database,
  maxRows: number,
): Promise<void> {
  if (maxRows < 1) return;
  const cntRow = await db
    .prepare("SELECT COUNT(*) AS c FROM access_logs")
    .first<{ c: number }>();
  const n = Number(cntRow?.c ?? 0);
  if (n <= maxRows) return;
  const toDelete = n - maxRows;
  const del = await db
    .prepare(
      `DELETE FROM access_logs WHERE id IN (
        SELECT id FROM (
          SELECT id FROM access_logs ORDER BY id ASC LIMIT ?
        ) AS old_rows
      )`,
    )
    .bind(toDelete)
    .run();
  if (!del.success) {
    console.warn(
      "[access_logs] prune to max rows failed:",
      (del as { error?: string }).error ?? del.meta,
    );
  }
}

/** 写入 access_logs 的地理与 ASN 展示字段（尽量利用 cf，避免整行全空） */
function buildAccessLogGeoRow(
  cf: IncomingRequestCfProperties | undefined,
  mockAppleRequest: boolean,
  treatCfAsApple: boolean,
): { country: string; city: string; region: string; asn: string } {
  const country = (cf?.country ?? "").trim();
  const city = (cf?.city ?? "").trim();
  let region = (cf?.region ?? "").trim();
  const rc = (cf?.regionCode ?? "").trim();
  if (!region && rc) region = rc;
  const colo = (cf?.colo ?? "").trim();
  const tz = (cf?.timezone ?? "").trim();
  if (!country && !city && !region) {
    if (colo) region = `colo:${colo}`;
    else if (tz) region = `tz:${tz}`;
  }

  let asn = "";
  if (mockAppleRequest && !treatCfAsApple) {
    asn = "MOCK Apple Inc. (X-Mock-Apple-ASN)";
  } else {
    const org = (cf?.asOrganization ?? "").trim();
    const n = cf?.asn;
    if (org && typeof n === "number") asn = `${org} (AS${n})`;
    else if (org) asn = org;
    else if (typeof n === "number") asn = `AS${n}`;
  }
  return { country, city, region, asn };
}

/** 内置兜底 ASN（PeeringDB 未收录或同步失败时仍生效；与 KV 同步结果取并集） */
const APPLE_ASNS_BUILTIN = new Set<number>([
  714,
  6185,
  6594,
]);

interface AppleAsnFetchedPayload {
  updatedAt: string;
  source: string;
  asns: number[];
}

let appleAsnMergedCache: { set: Set<number>; exp: number } | null = null;
const APPLE_ASN_MERGED_TTL_MS = 120_000;

function invalidateAppleAsnRuntimeCache(): void {
  appleAsnMergedCache = null;
}

async function readFetchedAppleAsnPayload(
  env: Env,
): Promise<AppleAsnFetchedPayload | null> {
  const raw = await env.CONFIG_KV.get(KV_APPLE_ASN_FETCHED);
  if (!raw) return null;
  try {
    const o = JSON.parse(raw) as AppleAsnFetchedPayload;
    if (!o || !Array.isArray(o.asns)) return null;
    return o;
  } catch {
    return null;
  }
}

async function getMergedAppleAsnSet(env: Env): Promise<Set<number>> {
  const now = Date.now();
  if (appleAsnMergedCache && now < appleAsnMergedCache.exp) {
    return appleAsnMergedCache.set;
  }
  const merged = new Set<number>(APPLE_ASNS_BUILTIN);
  const payload = await readFetchedAppleAsnPayload(env);
  if (payload) {
    for (const n of payload.asns) {
      if (
        typeof n === "number" &&
        Number.isInteger(n) &&
        n > 0 &&
        n <= 4294967295
      ) {
        merged.add(n);
      }
    }
  }
  appleAsnMergedCache = { set: merged, exp: now + APPLE_ASN_MERGED_TTL_MS };
  return merged;
}

/** 自 PeeringDB 拉取 Apple Inc.（org_id=8418）下全部登记 ASN */
async function fetchAppleAsnsFromInternet(): Promise<{
  asns: number[];
  source: string;
}> {
  const url = `https://www.peeringdb.com/api/net?org_id=${PEERINGDB_APPLE_ORG_ID}`;
  const res = await fetch(url, {
    headers: {
      Accept: "application/json",
      "User-Agent": "daddy-ab-config/apple-asn-sync",
    },
  });
  if (!res.ok) {
    throw new Error(`PeeringDB 请求失败 HTTP ${res.status}`);
  }
  const body = (await res.json()) as { data?: Array<{ asn?: number }> };
  const rows = body.data ?? [];
  const asns: number[] = [];
  for (const row of rows) {
    const n = row.asn;
    if (
      typeof n === "number" &&
      Number.isInteger(n) &&
      n > 0 &&
      n <= 4294967295
    ) {
      asns.push(n);
    }
  }
  const unique = [...new Set(asns)].sort((a, b) => a - b);
  return {
    asns: unique,
    source: `peeringdb.org_id=${PEERINGDB_APPLE_ORG_ID}`,
  };
}

async function handleAppleAsnRefresh(
  request: Request,
  env: Env,
): Promise<Response> {
  const deny = assertAdmin(request, env);
  if (deny) return deny;
  try {
    const { asns, source } = await fetchAppleAsnsFromInternet();
    const payload: AppleAsnFetchedPayload = {
      updatedAt: new Date().toISOString(),
      source,
      asns,
    };
    await env.CONFIG_KV.put(KV_APPLE_ASN_FETCHED, JSON.stringify(payload));
    invalidateAppleAsnRuntimeCache();
    const merged = [
      ...new Set<number>([...APPLE_ASNS_BUILTIN, ...asns]),
    ].sort((a, b) => a - b);
    return jsonResponse({
      code: 0,
      message: "ok",
      data: {
        fetched: asns,
        merged,
        builtin: [...APPLE_ASNS_BUILTIN].sort((a, b) => a - b),
        updatedAt: payload.updatedAt,
        source,
      },
    });
  } catch (e) {
    return jsonResponse({ code: 502, message: String(e) }, 502);
  }
}

async function handleAppleAsnStatus(
  request: Request,
  env: Env,
): Promise<Response> {
  const deny = assertAdmin(request, env);
  if (deny) return deny;
  const payload = await readFetchedAppleAsnPayload(env);
  const mergedSet = await getMergedAppleAsnSet(env);
  const merged = [...mergedSet].sort((a, b) => a - b);
  return jsonResponse({
    code: 0,
    data: {
      builtin: [...APPLE_ASNS_BUILTIN].sort((a, b) => a - b),
      fetched: payload?.asns ?? [],
      fetchedMeta: payload
        ? { updatedAt: payload.updatedAt, source: payload.source }
        : null,
      merged,
    },
  });
}

async function isAppleNetwork(
  env: Env,
  cf: IncomingRequestCfProperties | undefined,
): Promise<boolean> {
  if (!cf) return false;
  const asn = cf.asn;
  if (typeof asn === "number") {
    const set = await getMergedAppleAsnSet(env);
    if (set.has(asn)) return true;
  }
  const org = (cf.asOrganization ?? "").toLowerCase();
  return org.includes("apple");
}

const REMARK_APPLE_ASN = "苹果ASN";

async function isDeviceForcedB(
  env: Env,
  bundleId: string,
  deviceId: string,
): Promise<boolean> {
  const d = deviceId.trim();
  if (!d) return false;
  const b = (bundleId ?? "").trim();
  return kvMeansB(await env.CONFIG_KV.get(deviceForceKvKey(b, d)));
}

async function getEffectiveConfigAb(
  env: Env,
  bundleId: string,
): Promise<"A" | "B"> {
  const b = bundleId.trim();
  if (!b) {
    const raw = await env.CONFIG_KV.get(KV_KEY_DEFAULT);
    return raw === "B" ? "B" : "A";
  }
  const kvKey = configKvKey(b);
  let raw = await env.CONFIG_KV.get(kvKey);
  if (raw === null) {
    raw = await env.CONFIG_KV.get(KV_KEY_DEFAULT);
  }
  return raw === "B" ? "B" : "A";
}

/**
 * 判定顺序：当前请求苹果 ASN → 曾命中苹果 ASN 的设备锁（永久 A）→
 * 黑名单永远 A → 设备强制 B → Bundle 全员强制 B → KV 常规模板 A/B
 */
async function resolveFinalConfigAb(
  env: Env,
  bundleId: string,
  deviceId: string,
  ip: string,
  fromAppleAsn: boolean,
): Promise<"A" | "B"> {
  const safeMeta = {
    bundleLen: bundleId.trim().length,
    deviceLen: deviceId.trim().length,
    ipLen: ip.trim().length,
  };

  if (fromAppleAsn) {
    agentDebugLog({
      hypothesisId: "H1",
      location: "resolveFinalConfigAb",
      message: "early A: fromAppleAsn",
      data: {
        ...safeMeta,
        branch: "H1_fromAppleAsn",
        result: "A",
        fromAppleAsn: true,
      },
    });
    return "A";
  }

  const [appleLocked, blocklisted, deviceForced, bundleForced] =
    await Promise.all([
      isAppleAsnDeviceLocked(env, deviceId),
      isBlocklisted(env, ip, deviceId),
      isDeviceForcedB(env, bundleId, deviceId),
      isBundleForcedB(env, bundleId),
    ]);

  let branch: string;
  let result: "A" | "B";

  if (appleLocked) {
    branch = "H2_appleAsnDeviceLock";
    result = "A";
  } else if (blocklisted) {
    branch = "H3_blocklist";
    result = "A";
  } else if (deviceForced) {
    branch = "H4_deviceForceB";
    result = "B";
  } else if (bundleForced) {
    branch = "H5_bundleForceB";
    result = "B";
  } else {
    branch = "H6_kvTemplate";
    result = await getEffectiveConfigAb(env, bundleId);
  }

  agentDebugLog({
    hypothesisId: branch,
    location: "resolveFinalConfigAb",
    message: "resolved",
    data: {
      ...safeMeta,
      branch,
      result,
      fromAppleAsn: false,
      appleLocked,
      blocklisted,
      deviceForced,
      bundleForced,
    },
  });

  return result;
}

export interface BundleAbRow {
  kvKey: string;
  bundleId: string | null;
  ab: string;
}

async function listAllBundleAbConfigs(env: Env): Promise<BundleAbRow[]> {
  const rows: BundleAbRow[] = [];
  let cursor: string | undefined;
  const prefix = KV_KEY_DEFAULT;

  do {
    const page = await env.CONFIG_KV.list({ prefix, cursor });
    for (const meta of page.keys) {
      const name = meta.name;
      if (!name.startsWith(prefix)) continue;

      let bundleId: string | null;
      if (name === KV_KEY_DEFAULT) {
        bundleId = null;
      } else if (name.startsWith(`${KV_KEY_DEFAULT}_`)) {
        bundleId = name.slice(`${KV_KEY_DEFAULT}_`.length);
      } else {
        continue;
      }

      const raw = await env.CONFIG_KV.get(name);
      const ab = raw === "B" ? "B" : "A";
      rows.push({ kvKey: name, bundleId, ab });
    }
    cursor = page.list_complete ? undefined : page.cursor;
  } while (cursor);

  rows.sort((a, b) => {
    if (a.bundleId === null) return -1;
    if (b.bundleId === null) return 1;
    return a.bundleId.localeCompare(b.bundleId);
  });

  return rows;
}

async function distinctBundleIdsFromD1(env: Env): Promise<string[]> {
  if (!env.CONFIG_DB) return [];
  try {
    const r = await env.CONFIG_DB.prepare(
      `SELECT DISTINCT bundle_id FROM access_logs
       WHERE bundle_id IS NOT NULL AND TRIM(bundle_id) != ''
       ORDER BY bundle_id
       LIMIT 500`,
    ).all<{ bundle_id: string }>();
    return (r.results ?? []).map((x) => x.bundle_id);
  } catch {
    return [];
  }
}

export interface SeenBundleRow {
  bundleId: string;
  effectiveAb: string;
  hasOwnKvKey: boolean;
  note: string;
  /** KV bundle_force_b_* 是否开启 */
  bundleForcedB: boolean;
}

async function buildSeenBundleRows(
  env: Env,
  kvRows: BundleAbRow[],
): Promise<SeenBundleRow[]> {
  const kvBundleIds = new Set(
    kvRows.filter((r) => r.bundleId !== null).map((r) => r.bundleId as string),
  );
  const seen = await distinctBundleIdsFromD1(env);
  const rows = await Promise.all(
    seen.map(async (bid) => {
      const hasOwn = kvBundleIds.has(bid);
      const [effectiveAb, bundleForcedB] = await Promise.all([
        getEffectiveConfigAb(env, bid),
        isBundleForcedB(env, bid),
      ]);
      const note = hasOwn
        ? "KV 已有独立键 ab_config_*"
        : "KV 无独立键，当前与全局 ab_config 兜底一致";
      return {
        bundleId: bid,
        effectiveAb,
        hasOwnKvKey: hasOwn,
        note,
        bundleForcedB,
      };
    }),
  );
  rows.sort((a, b) => a.bundleId.localeCompare(b.bundleId));
  return rows;
}

export interface AccessLogRow {
  id: number;
  created_at: string;
  ip: string;
  /** 国家/地区、省州、城市与运营商组织（与 D1 写入一致） */
  ip_attribution: string;
  bundle_id: string | null;
  /** 第二行：App 版本（来自 query_json 的 app_version / build_number） */
  bundle_subtitle: string;
  device_id: string | null;
  /** 第二行展示文案，由 ios_version + device_model 生成 */
  device_subtitle: string;
  app_name: string | null;
  /** 只读展示；苹果 ASN 命中时为「苹果ASN」 */
  remark: string | null;
  device_forced_b: boolean;
  bundle_forced_b: boolean;
  blocklisted: boolean;
  /** 苹果 ASN 本条或设备锁：管理页禁用「强制 B」，且配置恒为 A */
  device_force_b_disabled: boolean;
}

/**
 * 管理页 access_logs 按 bundle_id 子串模糊匹配（INSTR，不区分大小写）。
 * 不用 LIKE：D1/SQLite 对 LOWER(?) + ESCAPE 组合易表现异常；INSTR 仅字面子串，更稳。
 */
function accessLogsBundleWhere(bundleIdFilter: string | null | undefined): {
  clause: string;
  countBinds: string[];
  pageBindsPrefix: string[];
} {
  const v = (bundleIdFilter ?? "").trim();
  if (!v) return { clause: "", countBinds: [], pageBindsPrefix: [] };
  return {
    clause:
      " WHERE bundle_id IS NOT NULL AND INSTR(LOWER(bundle_id), LOWER(?)) > 0",
    countBinds: [v],
    pageBindsPrefix: [v],
  };
}

async function fetchAccessLogPage(
  env: Env,
  page: number,
  pageSize: number,
  bundleIdFilter: string | null = null,
): Promise<{ rows: AccessLogRow[]; total: number }> {
  if (!env.CONFIG_DB) {
    return { rows: [], total: 0 };
  }
  const p = Math.max(1, page);
  const ps = Math.min(100, Math.max(1, pageSize));
  const offset = (p - 1) * ps;
  const w = accessLogsBundleWhere(bundleIdFilter);

  const cntStmt = env.CONFIG_DB.prepare(
    `SELECT COUNT(*) AS c FROM access_logs${w.clause}`,
  );
  const cnt = await (w.countBinds.length
    ? cntStmt.bind(...w.countBinds)
    : cntStmt
  ).first<{ c: number }>();
  const total = Number(cnt?.c ?? 0);

  const resRemark = await env.CONFIG_DB.prepare(
    `SELECT id, created_at, ip, country, city, region, "asn", query_json, bundle_id, device_id, app_name, ios_version, device_model, remark
     FROM access_logs${w.clause}
     ORDER BY id DESC
     LIMIT ? OFFSET ?`,
  )
    .bind(...w.pageBindsPrefix, ps, offset)
    .all<{
      id: number;
      created_at: string;
      ip: string;
      country: string | null;
      city: string | null;
      region: string | null;
      asn: string | null;
      query_json: string | null;
      bundle_id: string | null;
      device_id: string | null;
      app_name: string | null;
      ios_version: string | null;
      device_model: string | null;
      remark: string | null;
    }>();

  let rawRows: Array<{
    id: number;
    created_at: string;
    ip: string;
    country: string | null;
    city: string | null;
    region: string | null;
    asn: string | null;
    query_json: string | null;
    bundle_id: string | null;
    device_id: string | null;
    app_name: string | null;
    ios_version: string | null;
    device_model: string | null;
    remark: string | null;
  }>;

  if (resRemark.success) {
    rawRows = (resRemark.results ?? []).map((row) => ({
      ...row,
      remark: row.remark ?? null,
    }));
  } else {
    const resRemarkLegacy = await env.CONFIG_DB.prepare(
      `SELECT id, created_at, ip, country, city, region, "asn", query_json, bundle_id, device_id, app_name, remark
       FROM access_logs${w.clause}
       ORDER BY id DESC
       LIMIT ? OFFSET ?`,
    )
      .bind(...w.pageBindsPrefix, ps, offset)
      .all<{
        id: number;
        created_at: string;
        ip: string;
        country: string | null;
        city: string | null;
        region: string | null;
        asn: string | null;
        query_json: string | null;
        bundle_id: string | null;
        device_id: string | null;
        app_name: string | null;
        remark: string | null;
      }>();

    if (resRemarkLegacy.success) {
      rawRows = (resRemarkLegacy.results ?? []).map((row) => ({
        ...row,
        ios_version: null,
        device_model: null,
        remark: row.remark ?? null,
      }));
    } else {
      const fullRes = await env.CONFIG_DB.prepare(
        `SELECT id, created_at, ip, country, city, region, "asn", query_json, bundle_id, device_id, app_name, ios_version, device_model
         FROM access_logs${w.clause}
         ORDER BY id DESC
         LIMIT ? OFFSET ?`,
      )
        .bind(...w.pageBindsPrefix, ps, offset)
        .all<{
          id: number;
          created_at: string;
          ip: string;
          country: string | null;
          city: string | null;
          region: string | null;
          asn: string | null;
          query_json: string | null;
          bundle_id: string | null;
          device_id: string | null;
          app_name: string | null;
          ios_version: string | null;
          device_model: string | null;
        }>();

      if (fullRes.success) {
        rawRows = (fullRes.results ?? []).map((row) => ({
          ...row,
          remark: null,
        }));
      } else {
        const fullResLegacy = await env.CONFIG_DB.prepare(
          `SELECT id, created_at, ip, country, city, region, "asn", query_json, bundle_id, device_id, app_name
           FROM access_logs${w.clause}
           ORDER BY id DESC
           LIMIT ? OFFSET ?`,
        )
          .bind(...w.pageBindsPrefix, ps, offset)
          .all<{
            id: number;
            created_at: string;
            ip: string;
            country: string | null;
            city: string | null;
            region: string | null;
            asn: string | null;
            query_json: string | null;
            bundle_id: string | null;
            device_id: string | null;
            app_name: string | null;
          }>();

        if (fullResLegacy.success) {
          rawRows = (fullResLegacy.results ?? []).map((row) => ({
            ...row,
            ios_version: null,
            device_model: null,
            remark: null,
          }));
        } else {
          const leg = await env.CONFIG_DB.prepare(
            `SELECT id, created_at, ip FROM access_logs${w.clause} ORDER BY id DESC LIMIT ? OFFSET ?`,
          )
            .bind(...w.pageBindsPrefix, ps, offset)
            .all<{ id: number; created_at: string; ip: string }>();
          if (!leg.success) {
            throw new Error(
              (resRemark as { error?: string }).error ||
                (resRemarkLegacy as { error?: string }).error ||
                (fullRes as { error?: string }).error ||
                (fullResLegacy as { error?: string }).error ||
                (leg as { error?: string }).error ||
                "access_logs query failed",
            );
          }
          rawRows = (leg.results ?? []).map((row) => ({
            ...row,
            country: null,
            city: null,
            region: null,
            asn: null,
            query_json: null,
            bundle_id: null,
            device_id: null,
            app_name: null,
            ios_version: null,
            device_model: null,
            remark: null,
          }));
        }
      }
    }
  }
  const rows: AccessLogRow[] = await Promise.all(
    rawRows.map(async (row) => {
      const ip = row.ip ?? "";
      const did = row.device_id ?? "";
      const bid = row.bundle_id ?? "";
      const [deviceForced, bundleForced, bl, appleLocked] = await Promise.all([
        did ? isDeviceForcedB(env, bid, did) : Promise.resolve(false),
        bid ? isBundleForcedB(env, bid) : Promise.resolve(false),
        isBlocklisted(env, ip, did),
        did ? isAppleAsnDeviceLocked(env, did) : Promise.resolve(false),
      ]);
      const remark = row.remark ?? null;
      const appleRemark = remark === REMARK_APPLE_ASN;
      const qMeta = pickDeviceMetaFromQueryJson(row.query_json);
      const iosEff = (row.ios_version ?? "").trim() || qMeta.ios;
      const modelEff = (row.device_model ?? "").trim() || qMeta.model;
      const deviceSubtitle = formatDeviceSubtitle(iosEff, modelEff);
      const bundleSubtitle = formatBundleSubtitle(
        qMeta.app_version,
        qMeta.build_number,
      );
      return {
        id: row.id,
        created_at: row.created_at,
        ip,
        ip_attribution: formatIpAttribution(
          row.country,
          row.region,
          row.city,
          row.asn,
        ),
        bundle_id: row.bundle_id,
        bundle_subtitle: bundleSubtitle,
        device_id: row.device_id,
        device_subtitle: deviceSubtitle,
        app_name: row.app_name,
        remark,
        device_forced_b: deviceForced,
        bundle_forced_b: bundleForced,
        blocklisted: bl || appleRemark || appleLocked,
        device_force_b_disabled: appleRemark || appleLocked,
      };
    }),
  );

  return { rows, total };
}

async function handleClientConfig(
  request: Request,
  env: Env,
  ctx: ExecutionContext,
): Promise<Response> {
  const secret = env.CONFIG_AUTH_TOKEN?.trim() ?? "";
  if (secret.length > 0) {
    const token = request.headers.get("X-Config-Token") ?? "";
    if (token !== secret) {
      return jsonResponse({ code: 401, message: "Unauthorized" }, 401);
    }
  }

  const ip = clientIp(request);
  const cf = request.cf as IncomingRequestCfProperties | undefined;
  const ua = request.headers.get("User-Agent");

  const geo = {
    country: cf?.country ?? null,
    city: cf?.city ?? null,
    region: cf?.region ?? null,
    regionCode: cf?.regionCode ?? null,
    asOrganization: cf?.asOrganization ?? null,
    colo: cf?.colo ?? null,
    timezone: cf?.timezone ?? null,
  };

  const url = new URL(request.url);
  const query = Object.fromEntries(url.searchParams.entries());
  const bundleId =
    request.headers.get("X-Bundle-Id")?.trim() ||
    (query.bundle_id as string | undefined)?.trim() ||
    "";
  const deviceId =
    request.headers.get("X-Device-Id")?.trim() ||
    (query.device_id as string | undefined)?.trim() ||
    "";
  let iosVersion =
    request.headers.get("X-iOS-Version")?.trim() ||
    (query.os_version as string | undefined)?.trim() ||
    "";
  let deviceModel =
    request.headers.get("X-Device-Model")?.trim() ||
    (query.device_model as string | undefined)?.trim() ||
    "";
  let appVersion =
    request.headers.get("X-App-Version")?.trim() ||
    (query.app_version as string | undefined)?.trim() ||
    "";
  let buildNumber =
    request.headers.get("X-Build-Number")?.trim() ||
    (query.build_number as string | undefined)?.trim() ||
    "";
  const uaIos = parseIosDeviceFromUserAgent(ua);
  if (!iosVersion && uaIos.ios) iosVersion = uaIos.ios;
  if (!deviceModel && uaIos.model) deviceModel = uaIos.model;
  /** 与 URL 查询合并后的快照：Dio 会省略空 query 值，此处把 Header/UA 解析结果写回便于 D1 展示与排查 */
  const queryForStore: Record<string, string> = { ...query };
  if (iosVersion && !(queryForStore.os_version ?? "").trim()) {
    queryForStore.os_version = iosVersion;
  }
  if (deviceModel && !(queryForStore.device_model ?? "").trim()) {
    queryForStore.device_model = deviceModel;
  }
  if (appVersion && !(queryForStore.app_version ?? "").trim()) {
    queryForStore.app_version = appVersion;
  }
  if (buildNumber && !(queryForStore.build_number ?? "").trim()) {
    queryForStore.build_number = buildNumber;
  }
  const appName = parseAppNameFromRequest(request, ua);
  const treatCfAsApple = await isAppleNetwork(env, cf);
  let fromAppleAsn = treatCfAsApple;
  const mockHeader = request.headers.get("X-Mock-Apple-ASN")?.trim() ?? "";
  const mockAppleRequest =
    demoMockApple(env) &&
    (mockHeader === "1" ||
      mockHeader.toLowerCase() === "true" ||
      mockHeader.toLowerCase() === "yes");
  if (mockAppleRequest) {
    fromAppleAsn = true;
  }
  if (fromAppleAsn && deviceId.trim()) {
    ctx.waitUntil(
      env.CONFIG_KV.put(appleAsnDeviceLockKey(deviceId.trim()), "1"),
    );
  }
  const remarkForInsert = fromAppleAsn ? REMARK_APPLE_ASN : null;
  const geoRow = buildAccessLogGeoRow(cf, mockAppleRequest, treatCfAsApple);

  console.log(
    JSON.stringify({
      ts: new Date().toISOString(),
      ip,
      geo,
      bundleId,
      deviceId: deviceId ? "***" : "",
      appName,
      deviceMeta: {
        iosVersion: iosVersion || null,
        deviceModel: deviceModel || null,
        fromUa: Boolean(
          (!request.headers.get("X-iOS-Version")?.trim() &&
            !(query.os_version as string | undefined)?.trim() &&
            uaIos.ios) ||
            (!request.headers.get("X-Device-Model")?.trim() &&
              !(query.device_model as string | undefined)?.trim() &&
              uaIos.model),
        ),
      },
      query: queryForStore,
      fromAppleAsn,
      demoMockApple: mockAppleRequest,
    }),
  );

  if (env.CONFIG_DB) {
    const db = env.CONFIG_DB;
    const queryJson = JSON.stringify(queryForStore);
    ctx.waitUntil(
      (async () => {
        const iosForDb = iosVersion.length > 0 ? iosVersion : null;
        const modelForDb = deviceModel.length > 0 ? deviceModel : null;
        try {
          let result = await db
            .prepare(
              `INSERT INTO access_logs (ip, country, city, region, "asn", query_json, bundle_id, device_id, app_name, ios_version, device_model, remark)
               VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
            )
            .bind(
              ip,
              geoRow.country,
              geoRow.city,
              geoRow.region,
              geoRow.asn,
              queryJson,
              bundleId.length > 0 ? bundleId : null,
              deviceId.length > 0 ? deviceId : null,
              appName.length > 0 ? appName : null,
              iosForDb,
              modelForDb,
              remarkForInsert,
            )
            .run();
          if (!result.success) {
            const e0 = d1RunErrorText(result);
            if (!d1ErrorIndicatesUnknownColumn(e0)) {
              console.error("[access_logs] D1 insert failed:", e0);
            } else {
              result = await db
                .prepare(
                  `INSERT INTO access_logs (ip, country, city, region, "asn", query_json, bundle_id, device_id, app_name, ios_version, device_model)
                   VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
                )
                .bind(
                  ip,
                  geoRow.country,
                  geoRow.city,
                  geoRow.region,
                  geoRow.asn,
                  queryJson,
                  bundleId.length > 0 ? bundleId : null,
                  deviceId.length > 0 ? deviceId : null,
                  appName.length > 0 ? appName : null,
                  iosForDb,
                  modelForDb,
                )
                .run();
              if (!result.success) {
                const e1 = d1RunErrorText(result);
                if (!d1ErrorIndicatesUnknownColumn(e1)) {
                  console.error("[access_logs] D1 insert failed:", e1);
                } else {
                  console.warn(
                    "[access_logs] D1 无 remark 或 ios 相关列，降级写入；请执行 wrangler d1 migrations apply（0004/0005）",
                  );
                  result = await db
                    .prepare(
                      `INSERT INTO access_logs (ip, country, city, region, "asn", query_json, bundle_id, device_id, app_name, remark)
                       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
                    )
                    .bind(
                      ip,
                      geoRow.country,
                      geoRow.city,
                      geoRow.region,
                      geoRow.asn,
                      queryJson,
                      bundleId.length > 0 ? bundleId : null,
                      deviceId.length > 0 ? deviceId : null,
                      appName.length > 0 ? appName : null,
                      remarkForInsert,
                    )
                    .run();
                  if (!result.success) {
                    const e2 = d1RunErrorText(result);
                    if (!d1ErrorIndicatesUnknownColumn(e2)) {
                      console.error("[access_logs] D1 insert failed:", e2);
                    } else {
                      result = await db
                        .prepare(
                          `INSERT INTO access_logs (ip, country, city, region, "asn", query_json, bundle_id, device_id, app_name)
                           VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
                        )
                        .bind(
                          ip,
                          geoRow.country,
                          geoRow.city,
                          geoRow.region,
                          geoRow.asn,
                          queryJson,
                          bundleId.length > 0 ? bundleId : null,
                          deviceId.length > 0 ? deviceId : null,
                          appName.length > 0 ? appName : null,
                        )
                        .run();
                      if (!result.success) {
                        console.error(
                          "[access_logs] D1 insert failed:",
                          d1RunErrorText(result),
                        );
                      }
                    }
                  }
                }
              }
            }
          }
          if (result.success) {
            await pruneAccessLogsToMax(db, ACCESS_LOGS_MAX_ROWS);
          }
        } catch (e) {
          console.error("[access_logs] D1 insert exception:", e);
        }
      })(),
    );
  }

  agentDebugLog({
    hypothesisId: "H0",
    location: "handleClientConfig",
    message: "before resolveFinalConfigAb",
    data: {
      bundleLen: bundleId.trim().length,
      deviceLen: deviceId.trim().length,
      ipLen: ip.trim().length,
      fromAppleAsn,
    },
  });

  const configVal = await resolveFinalConfigAb(
    env,
    bundleId,
    deviceId,
    ip,
    fromAppleAsn,
  );

  return jsonResponse({
    code: 0,
    data: { config: configVal },
  });
}

async function handleDeviceForceB(
  request: Request,
  env: Env,
): Promise<Response> {
  const deny = assertAdmin(request, env);
  if (deny) return deny;
  let body: { deviceId?: string; bundleId?: string };
  try {
    body = (await request.json()) as { deviceId?: string; bundleId?: string };
  } catch {
    return jsonResponse({ code: 400, message: "Invalid JSON" }, 400);
  }
  const id = (body.deviceId ?? "").trim();
  const bundleId = (body.bundleId ?? "").trim();
  if (!id) {
    return jsonResponse({ code: 400, message: "deviceId required" }, 400);
  }
  if (await isAppleAsnDeviceLocked(env, id)) {
    return jsonResponse(
      {
        code: 400,
        message:
          "该设备已因苹果 ASN 锁定为 A（KV apple_asn_lock_a_*），不可强制 B",
      },
      400,
    );
  }
  await env.CONFIG_KV.put(deviceForceKvKey(bundleId, id), "B");
  return jsonResponse({
    code: 0,
    message: "ok",
    data: { deviceId: id, bundleId },
  });
}

async function handleBundleForceB(
  request: Request,
  env: Env,
): Promise<Response> {
  const deny = assertAdmin(request, env);
  if (deny) return deny;
  let body: { bundleId?: string };
  try {
    body = (await request.json()) as { bundleId?: string };
  } catch {
    return jsonResponse({ code: 400, message: "Invalid JSON" }, 400);
  }
  const id = (body.bundleId ?? "").trim();
  if (!id) {
    return jsonResponse({ code: 400, message: "bundleId required" }, 400);
  }
  await env.CONFIG_KV.put(bundleForceKvKey(id), "B");
  return jsonResponse({ code: 0, message: "ok", data: { bundleId: id } });
}

async function handleBundleUnforceB(
  request: Request,
  env: Env,
): Promise<Response> {
  const deny = assertAdmin(request, env);
  if (deny) return deny;
  let body: { bundleId?: string };
  try {
    body = (await request.json()) as { bundleId?: string };
  } catch {
    return jsonResponse({ code: 400, message: "Invalid JSON" }, 400);
  }
  const id = (body.bundleId ?? "").trim();
  if (!id) {
    return jsonResponse({ code: 400, message: "bundleId required" }, 400);
  }
  await env.CONFIG_KV.delete(bundleForceKvKey(id));
  return jsonResponse({ code: 0, message: "ok", data: { bundleId: id } });
}

async function handleBlocklistAdd(
  request: Request,
  env: Env,
): Promise<Response> {
  const deny = assertAdmin(request, env);
  if (deny) return deny;
  let body: { type?: string; value?: string };
  try {
    body = (await request.json()) as { type?: string; value?: string };
  } catch {
    return jsonResponse({ code: 400, message: "Invalid JSON" }, 400);
  }
  const ty = (body.type ?? "").trim().toLowerCase();
  const val = (body.value ?? "").trim();
  if (!val) {
    return jsonResponse({ code: 400, message: "value required" }, 400);
  }
  if (val.length > 500) {
    return jsonResponse({ code: 400, message: "value too long" }, 400);
  }
  if (ty === "device") {
    await env.CONFIG_KV.put(blocklistDeviceKey(val), "1");
    return jsonResponse({ code: 0, message: "ok", data: { type: "device", value: val } });
  }
  if (ty === "ip") {
    await env.CONFIG_KV.put(blocklistIpKey(val), "1");
    return jsonResponse({ code: 0, message: "ok", data: { type: "ip", value: val } });
  }
  return jsonResponse(
    { code: 400, message: "type must be device or ip" },
    400,
  );
}

async function handleBlocklistRemove(
  request: Request,
  env: Env,
): Promise<Response> {
  const deny = assertAdmin(request, env);
  if (deny) return deny;
  let body: { type?: string; value?: string };
  try {
    body = (await request.json()) as { type?: string; value?: string };
  } catch {
    return jsonResponse({ code: 400, message: "Invalid JSON" }, 400);
  }
  const ty = (body.type ?? "").trim().toLowerCase();
  const val = (body.value ?? "").trim();
  if (!val) {
    return jsonResponse({ code: 400, message: "value required" }, 400);
  }
  if (ty === "device") {
    await env.CONFIG_KV.delete(blocklistDeviceKey(val));
    return jsonResponse({ code: 0, message: "ok", data: { type: "device", value: val } });
  }
  if (ty === "ip") {
    await env.CONFIG_KV.delete(blocklistIpKey(val));
    return jsonResponse({ code: 0, message: "ok", data: { type: "ip", value: val } });
  }
  return jsonResponse(
    { code: 400, message: "type must be device or ip" },
    400,
  );
}

export default {
  async fetch(
    request: Request,
    env: Env,
    ctx: ExecutionContext,
  ): Promise<Response> {
    const url = new URL(request.url);
    const path = url.pathname;

    if ((path === "/admin" || path === "/admin/") && request.method === "GET") {
      const open = adminOpen(env);
      const html = composeAdminHtml(url.origin, open, demoMockApple(env), "");
      return new Response(html, {
        headers: {
          "Content-Type": "text/html; charset=utf-8",
          "Cache-Control": "no-store",
        },
      });
    }

    if (path === "/admin/bundle-ab" && request.method === "GET") {
      return Response.redirect(new URL("/admin", url.origin).toString(), 302);
    }

    if (path === "/admin/api/requests" && request.method === "GET") {
      const deny = assertAdmin(request, env);
      if (deny) return deny;
      try {
        const page = Math.max(1, parseInt(url.searchParams.get("page") || "1", 10) || 1);
        const pageSize = Math.min(
          100,
          Math.max(1, parseInt(url.searchParams.get("pageSize") || "20", 10) || 20),
        );
        const bundleIdRaw =
          url.searchParams.get("bundleId") ??
          url.searchParams.get("bundle_id") ??
          "";
        const bundleIdFilter = bundleIdRaw.trim() || null;
        const { rows, total } = await fetchAccessLogPage(
          env,
          page,
          pageSize,
          bundleIdFilter,
        );
        return jsonResponse({
          code: 0,
          data: {
            rows,
            page,
            pageSize,
            total,
            totalPages: Math.max(1, Math.ceil(total / pageSize)),
            d1Bound: Boolean(env.CONFIG_DB),
            bundleIdFilter: bundleIdFilter ?? "",
          },
        });
      } catch (e) {
        return jsonResponse({ code: 500, message: String(e) }, 500);
      }
    }

    if (path === "/admin/api/device-force-b" && request.method === "POST") {
      return handleDeviceForceB(request, env);
    }

    if (path === "/admin/api/bundle-force-b" && request.method === "POST") {
      return handleBundleForceB(request, env);
    }

    if (path === "/admin/api/bundle-unforce-b" && request.method === "POST") {
      return handleBundleUnforceB(request, env);
    }

    if (path === "/admin/api/blocklist" && request.method === "GET") {
      const deny = assertAdmin(request, env);
      if (deny) return deny;
      try {
        const bl = await listBlocklist(env);
        return jsonResponse({ code: 0, data: bl });
      } catch (e) {
        return jsonResponse({ code: 500, message: String(e) }, 500);
      }
    }

    if (path === "/admin/api/blocklist-add" && request.method === "POST") {
      return handleBlocklistAdd(request, env);
    }

    if (path === "/admin/api/blocklist-remove" && request.method === "POST") {
      return handleBlocklistRemove(request, env);
    }

    if (path === "/admin/api/apple-asn-refresh" && request.method === "POST") {
      return handleAppleAsnRefresh(request, env);
    }

    if (path === "/admin/api/apple-asn-status" && request.method === "GET") {
      return handleAppleAsnStatus(request, env);
    }

    if (path === "/admin/api/bundles" && request.method === "GET") {
      const deny = assertAdmin(request, env);
      if (deny) return deny;
      try {
        const kvRows = await listAllBundleAbConfigs(env);
        const seenOnly = await buildSeenBundleRows(env, kvRows);
        return jsonResponse({
          code: 0,
          data: { kvRows, seenOnly },
        });
      } catch (e) {
        return jsonResponse({ code: 500, message: String(e) }, 500);
      }
    }

    /** 仅校验 Token，不访问 KV/D1；用于与 GET /client/api/config 对比排障（522 时先测本路径） */
    if (path === "/client/api/ping" && request.method === "GET") {
      const secret = env.CONFIG_AUTH_TOKEN?.trim() ?? "";
      if (secret.length > 0) {
        const token = request.headers.get("X-Config-Token") ?? "";
        if (token !== secret) {
          return jsonResponse({ code: 401, message: "Unauthorized" }, 401);
        }
      }
      return jsonResponse({ code: 0, data: { ping: true } });
    }

    if (path === CONFIG_PATH && request.method === "GET") {
      return handleClientConfig(request, env, ctx);
    }

    return new Response("Not Found", { status: 404 });
  },
};
