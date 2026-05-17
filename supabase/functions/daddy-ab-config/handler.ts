import type { SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2.49.1";

// deno-lint-ignore no-explicit-any
declare const EdgeRuntime: { waitUntil: (p: Promise<unknown>) => void } | undefined;

export interface ServiceEnv {
  sb: SupabaseClient;
  CONFIG_AUTH_TOKEN?: string;
  ADMIN_OPEN?: string;
  DEMO_MOCK_APPLE?: string;
  /** 若设置，GET/POST /admin 与 /admin/bundle-ab 302 到该静态托管页（完整 URL，可带路径） */
  ADMIN_STATIC_REDIRECT_URL?: string;
}

const CONFIG_PATH = "/client/api/config";
const KV_KEY = {
  DEFAULT: "ab_config",
  DEVICE_FORCE_PREFIX: "device_force_b_",
  DEVICE_FORCE_SEP: "\u001f",
  BUNDLE_FORCE_PREFIX: "bundle_force_b_",
  BLOCK_DEV: "ab_blocklist_device_",
  BLOCK_IP: "ab_blocklist_ip_",
  APPLE_LOCK: "apple_asn_lock_a_",
  APPLE_FETCHED: "apple_asn_fetched_json",
} as const;
const SEP = KV_KEY.DEVICE_FORCE_SEP;
const PEERINGDB_APPLE_ORG_ID = 8418;
const APPLE_ASNS_BUILTIN = new Set<number>([714, 6185, 6594]);
const REMARK_APPLE_ASN = "苹果ASN";
const ACCESS_LOGS_MAX_ROWS = 1000;

function bg(p: Promise<unknown>): void {
  try {
    EdgeRuntime?.waitUntil(p);
  } catch {
    void p.catch(console.error);
  }
}

function adminOpen(env: ServiceEnv): boolean {
  const v = (env.ADMIN_OPEN ?? "").trim().toLowerCase();
  return v === "1" || v === "true" || v === "yes";
}

function demoMockApple(env: ServiceEnv): boolean {
  const v = (env.DEMO_MOCK_APPLE ?? "").trim().toLowerCase();
  return v === "1" || v === "true" || v === "yes";
}

export function jsonResponse(data: unknown, status = 200): Response {
  return new Response(JSON.stringify(data), {
    status,
    headers: {
      "Content-Type": "application/json; charset=utf-8",
      "Cache-Control": "no-store",
    },
  });
}

function clientIp(request: Request): string {
  const cfIp = request.headers.get("CF-Connecting-IP") ??
    request.headers.get("cf-connecting-ip");
  if (cfIp) return cfIp.trim();
  const xff = request.headers.get("X-Forwarded-For") ??
    request.headers.get("x-forwarded-for");
  if (xff) return xff.split(",")[0]?.trim() ?? "";
  return "";
}

function tokenFromRequest(request: Request): string {
  const auth = request.headers.get("Authorization");
  if (auth?.startsWith("Bearer ")) return auth.slice(7).trim();
  return request.headers.get("X-Config-Token")?.trim() ?? "";
}

function assertAdmin(request: Request, env: ServiceEnv): Response | null {
  if (adminOpen(env)) return null;
  const secret = env.CONFIG_AUTH_TOKEN?.trim() ?? "";
  if (!secret) {
    return jsonResponse({
      code: 503,
      message:
        "Admin 已禁用：设置 Edge Function Secrets：`ADMIN_OPEN=true` 或 `CONFIG_AUTH_TOKEN`。",
    }, 503);
  }
  if (tokenFromRequest(request) !== secret) {
    return jsonResponse({ code: 401, message: "Unauthorized" }, 401);
  }
  return null;
}

function parseAppNameFromUa(ua: string | null): string {
  if (!ua) return "";
  const m = ua.match(/^([^/]+)\//);
  const raw = m ? m[1].trim() : "";
  return raw.length > 200 ? raw.slice(0, 200) : raw;
}

function parseAppNameFromRequest(request: Request, ua: string | null): string {
  const rawHeader = request.headers.get("X-App-Name")?.trim() ?? "";
  if (rawHeader) {
    let appName = rawHeader;
    try {
      appName = decodeURIComponent(rawHeader);
    } catch { /* ASCII 明文 */ }
    const trimmed = appName.trim();
    return trimmed.length > 200 ? trimmed.slice(0, 200) : trimmed;
  }
  return parseAppNameFromUa(ua);
}

function configKvKey(bundleId: string | null | undefined): string {
  const b = (bundleId ?? "").trim();
  if (!b) return KV_KEY.DEFAULT;
  return `${KV_KEY.DEFAULT}_${b}`;
}

function deviceForceKvKey(bundleId: string, deviceId: string): string {
  const b = (bundleId ?? "").trim();
  const d = deviceId.trim();
  return `${KV_KEY.DEVICE_FORCE_PREFIX}${b}${SEP}${d}`;
}

function bundleForceKvKey(bundleId: string): string {
  return `${KV_KEY.BUNDLE_FORCE_PREFIX}${bundleId.trim()}`;
}

function blocklistDeviceKey(deviceId: string): string {
  return `${KV_KEY.BLOCK_DEV}${deviceId.trim()}`;
}

function blocklistIpKey(ip: string): string {
  return `${KV_KEY.BLOCK_IP}${encodeURIComponent(ip.trim())}`;
}

function appleAsnDeviceLockKey(deviceId: string): string {
  return `${KV_KEY.APPLE_LOCK}${deviceId.trim()}`;
}

function kvMeansB(raw: string | null | undefined): boolean {
  const v = raw?.trim().toLowerCase();
  return v === "b" || v === "1" || v === "true" || v === "yes";
}

function dbErrMsg(err: unknown): string {
  if (err instanceof Error) return err.message;
  if (err && typeof err === "object") {
    const o = err as Record<string, unknown>;
    const parts = [o.message, o.details, o.hint, o.code].filter((x) =>
      x != null && String(x) !== ""
    );
    if (parts.length) return parts.map(String).join(" | ");
  }
  try {
    return JSON.stringify(err);
  } catch {
    return String(err);
  }
}

async function kvGet(env: ServiceEnv, key: string): Promise<string | null> {
  const { data, error } = await env.sb.from("kv_store").select("value").eq(
    "key",
    key,
  ).maybeSingle();
  if (error) throw new Error(dbErrMsg(error));
  return data?.value ?? null;
}

async function kvPut(env: ServiceEnv, key: string, value: string): Promise<void> {
  const { error } = await env.sb.from("kv_store").upsert(
    { key, value, updated_at: new Date().toISOString() },
    { onConflict: "key" },
  );
  if (error) throw new Error(dbErrMsg(error));
}

async function kvDel(env: ServiceEnv, key: string): Promise<void> {
  const { error } = await env.sb.from("kv_store").delete().eq("key", key);
  if (error) throw new Error(dbErrMsg(error));
}

async function kvListPrefix(
  env: ServiceEnv,
  prefix: string,
): Promise<{ key: string; value: string }[]> {
  const { data, error } = await env.sb.from("kv_store").select("key,value").like(
    "key",
    `${prefix}%`,
  );
  if (error) throw new Error(dbErrMsg(error));
  return (data ?? []) as { key: string; value: string }[];
}

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
  env: ServiceEnv,
): Promise<AppleAsnFetchedPayload | null> {
  const raw = await kvGet(env, KV_KEY.APPLE_FETCHED);
  if (!raw) return null;
  try {
    const o = JSON.parse(raw) as AppleAsnFetchedPayload;
    if (!o || !Array.isArray(o.asns)) return null;
    return o;
  } catch {
    return null;
  }
}

async function getMergedAppleAsnSet(env: ServiceEnv): Promise<Set<number>> {
  const now = Date.now();
  if (appleAsnMergedCache && now < appleAsnMergedCache.exp) {
    return appleAsnMergedCache.set;
  }
  const merged = new Set<number>(APPLE_ASNS_BUILTIN);
  const payload = await readFetchedAppleAsnPayload(env);
  if (payload) {
    for (const n of payload.asns) {
      if (
        typeof n === "number" && Number.isInteger(n) && n > 0 && n <= 4294967295
      ) merged.add(n);
    }
  }
  appleAsnMergedCache = { set: merged, exp: now + APPLE_ASN_MERGED_TTL_MS };
  return merged;
}

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
  if (!res.ok) throw new Error(`PeeringDB 请求失败 HTTP ${res.status}`);
  const body = (await res.json()) as { data?: Array<{ asn?: number }> };
  const rows = body.data ?? [];
  const asns: number[] = [];
  for (const row of rows) {
    const n = row.asn;
    if (
      typeof n === "number" && Number.isInteger(n) && n > 0 && n <= 4294967295
    ) {
      asns.push(n);
    }
  }
  const unique = [...new Set(asns)].sort((a, b) => a - b);
  return { asns: unique, source: `peeringdb.org_id=${PEERINGDB_APPLE_ORG_ID}` };
}

interface IpLookup {
  country: string;
  city: string;
  region: string;
  asnDisplay: string;
  asnNum: number | null;
  org: string;
}

function parseAsnFields(
  org: string,
  asnRaw: unknown,
): { asnNum: number | null; asnDisplay: string } {
  let asnNum: number | null = null;
  if (asnRaw != null) {
    const a = String(asnRaw);
    const m = a.match(/AS?(\d+)/i);
    if (m) asnNum = parseInt(m[1], 10);
    else if (/^\d+$/.test(a)) asnNum = parseInt(a, 10);
  }
  const o = org.trim();
  let asnDisplay = "";
  if (o && asnNum != null) asnDisplay = `${o} (AS${asnNum})`;
  else if (o) asnDisplay = o;
  else if (asnNum != null) asnDisplay = `AS${asnNum}`;
  return { asnNum, asnDisplay };
}

function emptyIpLookup(): IpLookup {
  return {
    country: "",
    city: "",
    region: "",
    asnDisplay: "",
    asnNum: null,
    org: "",
  };
}

function lookupHasGeo(l: IpLookup): boolean {
  return Boolean(
    l.country.trim() || l.city.trim() || l.region.trim() || l.asnDisplay.trim(),
  );
}

async function fetchJsonWithTimeout(
  url: string,
  ms = 4500,
): Promise<Record<string, unknown> | null> {
  try {
    const ac = new AbortController();
    const t = setTimeout(() => ac.abort(), ms);
    const r = await fetch(url, { signal: ac.signal });
    clearTimeout(t);
    if (!r.ok) return null;
    return await r.json() as Record<string, unknown>;
  } catch {
    return null;
  }
}

async function lookupIpFromIpApiCo(ip: string): Promise<IpLookup | null> {
  const j = await fetchJsonWithTimeout(
    `https://ipapi.co/${encodeURIComponent(ip)}/json/`,
  );
  if (!j || j.error) return null;
  const org = String(j.org ?? "");
  const { asnNum, asnDisplay } = parseAsnFields(org, j.asn);
  const out: IpLookup = {
    country: String(j.country_name ?? j.country ?? ""),
    city: String(j.city ?? ""),
    region: String(j.region ?? j.region_code ?? ""),
    asnDisplay,
    asnNum,
    org,
  };
  return lookupHasGeo(out) ? out : null;
}

/** ip-api.com：Supabase Edge 上比 ipapi.co 更稳定（ipapi 易 429） */
async function lookupIpFromIpApiCom(ip: string): Promise<IpLookup | null> {
  const j = await fetchJsonWithTimeout(
    `http://ip-api.com/json/${encodeURIComponent(ip)}?fields=status,message,country,regionName,city,as,org`,
  );
  if (!j || j.status !== "success") return null;
  const org = String(j.org ?? "");
  const { asnNum, asnDisplay } = parseAsnFields(org, j.as);
  const out: IpLookup = {
    country: String(j.country ?? ""),
    city: String(j.city ?? ""),
    region: String(j.regionName ?? ""),
    asnDisplay,
    asnNum,
    org,
  };
  return lookupHasGeo(out) ? out : null;
}

async function lookupIpFromIpWhoIs(ip: string): Promise<IpLookup | null> {
  const j = await fetchJsonWithTimeout(
    `https://ipwho.is/${encodeURIComponent(ip)}`,
  );
  if (!j || j.success !== true) return null;
  const conn = j.connection as Record<string, unknown> | undefined;
  const org = String(conn?.isp ?? j.org ?? "");
  const asnRaw = conn?.asn ?? j.asn;
  const { asnNum, asnDisplay } = parseAsnFields(org, asnRaw);
  const out: IpLookup = {
    country: String(j.country ?? ""),
    city: String(j.city ?? ""),
    region: String(j.region ?? ""),
    asnDisplay,
    asnNum,
    org,
  };
  return lookupHasGeo(out) ? out : null;
}

/** 多源回退查询 IP 归属（写入 access_logs / 管理页补全） */
async function lookupIp(ip: string): Promise<IpLookup> {
  const empty = emptyIpLookup();
  const x = ip.trim();
  if (!x) return empty;
  for (const fn of [
    lookupIpFromIpApiCom,
    lookupIpFromIpWhoIs,
    lookupIpFromIpApiCo,
  ]) {
    const hit = await fn(x);
    if (hit) return hit;
  }
  console.warn("[lookupIp] all providers failed for", x);
  return empty;
}

function storedGeoEmpty(
  country: string | null | undefined,
  region: string | null | undefined,
  city: string | null | undefined,
  asn: string | null | undefined,
): boolean {
  return !String(country ?? "").trim() &&
    !String(region ?? "").trim() &&
    !String(city ?? "").trim() &&
    !String(asn ?? "").trim();
}

async function backfillAccessLogGeoIfNeeded(
  env: ServiceEnv,
  id: number,
  ip: string,
  country: string | null | undefined,
  region: string | null | undefined,
  city: string | null | undefined,
  asn: string | null | undefined,
): Promise<{ country: string; region: string; city: string; asn: string }> {
  const c0 = String(country ?? "");
  const r0 = String(region ?? "");
  const cy0 = String(city ?? "");
  const a0 = String(asn ?? "");
  if (!storedGeoEmpty(c0, r0, cy0, a0) || !ip.trim()) {
    return { country: c0, region: r0, city: cy0, asn: a0 };
  }
  const lookup = await lookupIp(ip);
  const geo = buildAccessLogGeoRow(lookup, false, false);
  if (storedGeoEmpty(geo.country, geo.region, geo.city, geo.asn)) {
    return { country: c0, region: r0, city: cy0, asn: a0 };
  }
  bg((async () => {
    const { error } = await env.sb.from("access_logs").update({
      country: geo.country || null,
      city: geo.city || null,
      region: geo.region || null,
      asn: geo.asn || null,
    }).eq("id", id);
    if (error) console.error("[access_logs geo backfill]", error);
  })());
  return geo;
}

async function isAppleNetwork(env: ServiceEnv, lookup: IpLookup): Promise<boolean> {
  const asn = lookup.asnNum;
  if (typeof asn === "number") {
    const set = await getMergedAppleAsnSet(env);
    if (set.has(asn)) return true;
  }
  return lookup.org.toLowerCase().includes("apple");
}

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

function parseIosDeviceFromUserAgent(ua: string | null): { ios: string; model: string } {
  if (!ua) return { ios: "", model: "" };
  const m = ua.match(/\(\s*iOS\s+([^;]*?)\s*;\s*([^)]*?)\s*\)/i);
  if (!m) return { ios: "", model: "" };
  return { ios: m[1].trim(), model: m[2].trim() };
}

function pickDeviceMetaFromQueryJson(raw: string | null | undefined): {
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

function buildAccessLogGeoRow(
  lookup: IpLookup,
  mockAppleRequest: boolean,
  treatAsApple: boolean,
): { country: string; city: string; region: string; asn: string } {
  const country = lookup.country.trim();
  const city = lookup.city.trim();
  const region = lookup.region.trim();
  let asn = "";
  if (mockAppleRequest && !treatAsApple) {
    asn = "MOCK Apple Inc. (X-Mock-Apple-ASN)";
  } else {
    asn = lookup.asnDisplay;
  }
  return { country, city, region, asn };
}

async function isAppleAsnDeviceLocked(
  env: ServiceEnv,
  deviceId: string,
): Promise<boolean> {
  const d = deviceId.trim();
  if (!d) return false;
  const v = await kvGet(env, appleAsnDeviceLockKey(d));
  return v !== null && v !== undefined && String(v).trim() !== "";
}

async function isBlocklisted(
  env: ServiceEnv,
  ip: string,
  deviceId: string,
): Promise<boolean> {
  const d = deviceId.trim();
  if (d) {
    const v = await kvGet(env, blocklistDeviceKey(d));
    if (v !== null && v !== undefined && String(v).trim() !== "") return true;
  }
  const x = ip.trim();
  if (x) {
    const v = await kvGet(env, blocklistIpKey(x));
    if (v !== null && v !== undefined && String(v).trim() !== "") return true;
  }
  return false;
}

async function isDeviceForcedB(
  env: ServiceEnv,
  bundleId: string,
  deviceId: string,
): Promise<boolean> {
  const d = deviceId.trim();
  if (!d) return false;
  const b = (bundleId ?? "").trim();
  return kvMeansB(await kvGet(env, deviceForceKvKey(b, d)));
}

async function isBundleForcedB(env: ServiceEnv, bundleId: string): Promise<boolean> {
  const b = bundleId.trim();
  if (!b) return false;
  return kvMeansB(await kvGet(env, bundleForceKvKey(b)));
}

async function getEffectiveConfigAb(
  env: ServiceEnv,
  bundleId: string,
): Promise<"A" | "B"> {
  const b = bundleId.trim();
  if (!b) {
    const raw = await kvGet(env, KV_KEY.DEFAULT);
    return raw === "B" ? "B" : "A";
  }
  const kvKey = configKvKey(b);
  let raw = await kvGet(env, kvKey);
  if (raw === null) raw = await kvGet(env, KV_KEY.DEFAULT);
  return raw === "B" ? "B" : "A";
}

async function resolveFinalConfigAb(
  env: ServiceEnv,
  bundleId: string,
  deviceId: string,
  ip: string,
  fromAppleAsn: boolean,
): Promise<"A" | "B"> {
  if (fromAppleAsn) return "A";
  const [appleLocked, blocklisted, deviceForced, bundleForced] = await Promise.all([
    isAppleAsnDeviceLocked(env, deviceId),
    isBlocklisted(env, ip, deviceId),
    isDeviceForcedB(env, bundleId, deviceId),
    isBundleForcedB(env, bundleId),
  ]);
  if (appleLocked) return "A";
  if (blocklisted) return "A";
  if (deviceForced) return "B";
  if (bundleForced) return "B";
  return getEffectiveConfigAb(env, bundleId);
}

export interface BundleAbRow {
  kvKey: string;
  bundleId: string | null;
  ab: string;
}

async function listAllBundleAbConfigs(env: ServiceEnv): Promise<BundleAbRow[]> {
  const rows: BundleAbRow[] = [];
  const list = await kvListPrefix(env, KV_KEY.DEFAULT);
  const prefix = `${KV_KEY.DEFAULT}_`;
  for (const { key, value } of list) {
    if (key === KV_KEY.DEFAULT) {
      rows.push({ kvKey: key, bundleId: null, ab: value === "B" ? "B" : "A" });
    } else if (key.startsWith(prefix)) {
      const bid = key.slice(prefix.length);
      rows.push({ kvKey: key, bundleId: bid, ab: value === "B" ? "B" : "A" });
    }
  }
  rows.sort((a, b) => {
    if (a.bundleId === null) return -1;
    if (b.bundleId === null) return 1;
    return (a.bundleId ?? "").localeCompare(b.bundleId ?? "");
  });
  return rows;
}

async function distinctBundleIdsFromD1(env: ServiceEnv): Promise<string[]> {
  const { data, error } = await env.sb.from("access_logs").select("bundle_id")
    .not("bundle_id", "is", null);
  if (error) return [];
  const s = new Set<string>();
  for (const r of data ?? []) {
    const b = (r as { bundle_id: string | null }).bundle_id?.trim() ?? "";
    if (b) s.add(b);
  }
  return [...s].sort();
}

export interface SeenBundleRow {
  bundleId: string;
  effectiveAb: string;
  hasOwnKvKey: boolean;
  note: string;
  bundleForcedB: boolean;
}

async function buildSeenBundleRows(
  env: ServiceEnv,
  kvRows: BundleAbRow[],
): Promise<SeenBundleRow[]> {
  const kvBundleIds = new Set(
    kvRows.filter((r) => r.bundleId !== null).map((r) => r.bundleId as string),
  );
  const seen = await distinctBundleIdsFromD1(env);
  const rows = await Promise.all(seen.map(async (bid) => {
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
  }));
  rows.sort((a, b) => a.bundleId.localeCompare(b.bundleId));
  return rows;
}

export interface AccessLogRow {
  id: number;
  created_at: string;
  ip: string;
  ip_attribution: string;
  bundle_id: string | null;
  bundle_subtitle: string;
  device_id: string | null;
  device_subtitle: string;
  app_name: string | null;
  remark: string | null;
  device_forced_b: boolean;
  bundle_forced_b: boolean;
  blocklisted: boolean;
  device_force_b_disabled: boolean;
}

async function fetchAccessLogPage(
  env: ServiceEnv,
  page: number,
  pageSize: number,
  bundleIdFilter: string | null = null,
): Promise<{ rows: AccessLogRow[]; total: number }> {
  const p = Math.max(1, page);
  const ps = Math.min(100, Math.max(1, pageSize));
  const from = (p - 1) * ps;
  const to = from + ps - 1;
  const filt = (bundleIdFilter ?? "").trim();

  let countQ = env.sb.from("access_logs").select("*", {
    count: "exact",
    head: true,
  });
  let dataQ = env.sb.from("access_logs").select(
    "id,created_at,ip,country,city,region,asn,query_json,bundle_id,device_id,app_name,ios_version,device_model,remark",
  ).order("id", { ascending: false }).range(from, to);

  if (filt) {
    countQ = countQ.not("bundle_id", "is", null).ilike("bundle_id", `%${filt}%`);
    dataQ = dataQ.not("bundle_id", "is", null).ilike("bundle_id", `%${filt}%`);
  }

  const [{ count, error: cErr }, { data: rawRows, error: dErr }] = await Promise.all([
    countQ,
    dataQ,
  ]);
  if (cErr) throw cErr;
  if (dErr) throw dErr;
  const total = count ?? 0;

  const rows: AccessLogRow[] = await Promise.all((rawRows ?? []).map(async (row) => {
    const R = row as Record<string, unknown>;
    const ip = String(R.ip ?? "");
    const did = String(R.device_id ?? "");
    const bid = String(R.bundle_id ?? "");
    const [deviceForced, bundleForced, bl, appleLocked] = await Promise.all([
      did ? isDeviceForcedB(env, bid, did) : Promise.resolve(false),
      bid ? isBundleForcedB(env, bid) : Promise.resolve(false),
      isBlocklisted(env, ip, did),
      did ? isAppleAsnDeviceLocked(env, did) : Promise.resolve(false),
    ]);
    const remark = (R.remark as string | null) ?? null;
    const appleRemark = remark === REMARK_APPLE_ASN;
    const qj = R.query_json
      ? (typeof R.query_json === "string"
        ? R.query_json
        : JSON.stringify(R.query_json))
      : null;
    const qMeta = pickDeviceMetaFromQueryJson(qj);
    const iosEff = String(R.ios_version ?? "").trim() || qMeta.ios;
    const modelEff = String(R.device_model ?? "").trim() || qMeta.model;
    const deviceSubtitle = formatDeviceSubtitle(iosEff, modelEff);
    const bundleSubtitle = formatBundleSubtitle(qMeta.app_version, qMeta.build_number);
    const geoFilled = await backfillAccessLogGeoIfNeeded(
      env,
      Number(R.id),
      ip,
      R.country as string | null,
      R.region as string | null,
      R.city as string | null,
      R.asn as string | null,
    );
    const ipAttribution = formatIpAttribution(
      geoFilled.country,
      geoFilled.region,
      geoFilled.city,
      geoFilled.asn,
    );
    return {
      id: Number(R.id),
      created_at: String(R.created_at ?? "").replace("T", " ").slice(0, 19),
      ip,
      ip_attribution: ipAttribution,
      bundle_id: bid || null,
      bundle_subtitle: bundleSubtitle,
      device_id: did || null,
      device_subtitle: deviceSubtitle,
      app_name: (R.app_name as string | null) ?? null,
      remark,
      device_forced_b: deviceForced,
      bundle_forced_b: bundleForced,
      blocklisted: bl || appleRemark || appleLocked,
      device_force_b_disabled: appleRemark || appleLocked,
    };
  }));

  return { rows, total };
}

async function pruneAccessLogsToMax(env: ServiceEnv, maxRows: number): Promise<void> {
  if (maxRows < 1) return;
  const { count, error: cErr } = await env.sb.from("access_logs").select("*", {
    count: "exact",
    head: true,
  });
  if (cErr) return;
  const n = count ?? 0;
  if (n <= maxRows) return;
  const toDelete = n - maxRows;
  const { data: oldRows, error: oErr } = await env.sb.from("access_logs").select("id")
    .order("id", { ascending: true }).limit(toDelete);
  if (oErr || !oldRows?.length) return;
  const ids = (oldRows as { id: number }[]).map((r) => r.id);
  await env.sb.from("access_logs").delete().in("id", ids);
}

async function handleClientConfig(
  request: Request,
  env: ServiceEnv,
): Promise<Response> {
  const secret = env.CONFIG_AUTH_TOKEN?.trim() ?? "";
  if (secret.length > 0) {
    const token = request.headers.get("X-Config-Token") ?? "";
    if (token !== secret) {
      return jsonResponse({ code: 401, message: "Unauthorized" }, 401);
    }
  }

  const ip = clientIp(request);
  const ua = request.headers.get("User-Agent");
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

  const lookupRes = await lookupIp(ip);
  const treatApple = await isAppleNetwork(env, lookupRes);

  let fromAppleAsn = treatApple;
  const mockHeader = request.headers.get("X-Mock-Apple-ASN")?.trim() ?? "";
  const mockAppleRequest = demoMockApple(env) &&
    (mockHeader === "1" || mockHeader.toLowerCase() === "true" ||
      mockHeader.toLowerCase() === "yes");
  if (mockAppleRequest) fromAppleAsn = true;

  if (fromAppleAsn && deviceId.trim()) {
    bg(kvPut(env, appleAsnDeviceLockKey(deviceId.trim()), "1"));
  }
  const remarkForInsert = fromAppleAsn ? REMARK_APPLE_ASN : null;
  const geoRow = buildAccessLogGeoRow(lookupRes, mockAppleRequest, treatApple);

  bg((async () => {
    try {
      const { error } = await env.sb.from("access_logs").insert({
        ip: ip || null,
        country: geoRow.country || null,
        city: geoRow.city || null,
        region: geoRow.region || null,
        asn: geoRow.asn || null,
        query_json: queryForStore,
        bundle_id: bundleId.length > 0 ? bundleId : null,
        device_id: deviceId.length > 0 ? deviceId : null,
        app_name: appName.length > 0 ? appName : null,
        ios_version: iosVersion.length > 0 ? iosVersion : null,
        device_model: deviceModel.length > 0 ? deviceModel : null,
        remark: remarkForInsert,
      });
      if (error) console.error("[access_logs]", error);
      else await pruneAccessLogsToMax(env, ACCESS_LOGS_MAX_ROWS);
    } catch (e) {
      console.error("[access_logs]", e);
    }
  })());

  const configVal = await resolveFinalConfigAb(
    env,
    bundleId,
    deviceId,
    ip,
    fromAppleAsn,
  );
  return jsonResponse({ code: 0, data: { config: configVal } });
}

async function listBlocklist(env: ServiceEnv): Promise<{
  devices: string[];
  ips: string[];
}> {
  const devices: string[] = [];
  const ips: string[] = [];
  const rows = await kvListPrefix(env, "ab_blocklist_");
  for (const { key } of rows) {
    if (key.startsWith(KV_KEY.BLOCK_DEV)) {
      devices.push(key.slice(KV_KEY.BLOCK_DEV.length));
    } else if (key.startsWith(KV_KEY.BLOCK_IP)) {
      const enc = key.slice(KV_KEY.BLOCK_IP.length);
      try {
        ips.push(decodeURIComponent(enc));
      } catch {
        ips.push(enc);
      }
    }
  }
  devices.sort();
  ips.sort();
  return { devices, ips };
}

async function handleDeviceForceB(
  request: Request,
  env: ServiceEnv,
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
  if (!id) return jsonResponse({ code: 400, message: "deviceId required" }, 400);
  if (await isAppleAsnDeviceLocked(env, id)) {
    return jsonResponse({
      code: 400,
      message: "该设备已因苹果 ASN 锁定为 A（KV apple_asn_lock_a_*），不可强制 B",
    }, 400);
  }
  await kvPut(env, deviceForceKvKey(bundleId, id), "B");
  return jsonResponse({ code: 0, message: "ok", data: { deviceId: id, bundleId } });
}

async function handleBundleForceB(
  request: Request,
  env: ServiceEnv,
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
  if (!id) return jsonResponse({ code: 400, message: "bundleId required" }, 400);
  await kvPut(env, bundleForceKvKey(id), "B");
  return jsonResponse({ code: 0, message: "ok", data: { bundleId: id } });
}

async function handleBundleUnforceB(
  request: Request,
  env: ServiceEnv,
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
  if (!id) return jsonResponse({ code: 400, message: "bundleId required" }, 400);
  await kvDel(env, bundleForceKvKey(id));
  return jsonResponse({ code: 0, message: "ok", data: { bundleId: id } });
}

async function handleBlocklistAdd(
  request: Request,
  env: ServiceEnv,
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
  if (!val) return jsonResponse({ code: 400, message: "value required" }, 400);
  if (val.length > 500) return jsonResponse({ code: 400, message: "value too long" }, 400);
  if (ty === "device") {
    await kvPut(env, blocklistDeviceKey(val), "1");
    return jsonResponse({ code: 0, message: "ok", data: { type: "device", value: val } });
  }
  if (ty === "ip") {
    await kvPut(env, blocklistIpKey(val), "1");
    return jsonResponse({ code: 0, message: "ok", data: { type: "ip", value: val } });
  }
  return jsonResponse({ code: 400, message: "type must be device or ip" }, 400);
}

async function handleBlocklistRemove(
  request: Request,
  env: ServiceEnv,
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
  if (!val) return jsonResponse({ code: 400, message: "value required" }, 400);
  if (ty === "device") {
    await kvDel(env, blocklistDeviceKey(val));
    return jsonResponse({ code: 0, message: "ok", data: { type: "device", value: val } });
  }
  if (ty === "ip") {
    await kvDel(env, blocklistIpKey(val));
    return jsonResponse({ code: 0, message: "ok", data: { type: "ip", value: val } });
  }
  return jsonResponse({ code: 400, message: "type must be device or ip" }, 400);
}

async function handleAppleAsnRefresh(
  request: Request,
  env: ServiceEnv,
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
    await kvPut(env, KV_KEY.APPLE_FETCHED, JSON.stringify(payload));
    invalidateAppleAsnRuntimeCache();
    const merged = [...new Set<number>([...APPLE_ASNS_BUILTIN, ...asns])].sort(
      (a, b) => a - b,
    );
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
    return jsonResponse({ code: 502, message: dbErrMsg(e) }, 502);
  }
}

async function handleAppleAsnStatus(
  request: Request,
  env: ServiceEnv,
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

/** 对外访问本服务的 URL 前缀（含 /functions/v1/xxx）。根路径 Worker 部署时为 origin。 */
export function servicePublicBase(url: URL, functionName: string): string {
  const marker = `/functions/v1/${functionName}`;
  if (url.pathname.includes(marker)) {
    return `${url.origin}${marker}`;
  }
  return url.origin;
}

export function normalizePath(pathname: string, functionName: string): string {
  const marker = `/functions/v1/${functionName}`;
  let path = pathname;
  if (path.startsWith(marker)) {
    path = path.slice(marker.length) || "/";
  } else if (path === `/${functionName}` || path.startsWith(`/${functionName}/`)) {
    /* Supabase 网关有时只传 /{functionName}/…，不含 /functions/v1 */
    path = path.slice(`/${functionName}`.length) || "/";
  }
  return path.endsWith("/") && path.length > 1 ? path.slice(0, -1) : path;
}

export async function routeRequest(
  request: Request,
  env: ServiceEnv,
  url: URL,
  adminHtml: (
    origin: string,
    open: boolean,
    demo: boolean,
  ) => string,
): Promise<Response> {
  const path = normalizePath(url.pathname, "daddy-ab-config");

  if (request.method === "OPTIONS") {
    return new Response("ok", {
      headers: {
        "Access-Control-Allow-Origin": "*",
        "Access-Control-Allow-Headers":
          "authorization, x-client-info, apikey, content-type, accept, x-config-token, x-app-name, x-bundle-id, x-device-id, x-environment, x-ios-version, x-device-model, x-app-version, x-build-number, x-mock-apple-asn",
        "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
      },
    });
  }

  const cors = {
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Headers":
      "authorization, x-client-info, apikey, content-type, accept, x-config-token, x-app-name, x-bundle-id, x-device-id, x-environment, x-ios-version, x-device-model, x-app-version, x-build-number, x-mock-apple-asn",
  };

  if (
    (path === "/admin" || path === "/admin/") &&
    (request.method === "GET" || request.method === "POST")
  ) {
    const redir = env.ADMIN_STATIC_REDIRECT_URL?.trim();
    if (redir) {
      return Response.redirect(redir, 302);
    }
    const open = adminOpen(env);
    const demo = demoMockApple(env);
    const html = adminHtml(servicePublicBase(url, "daddy-ab-config"), open, demo);
    return new Response(html, {
      headers: {
        "Content-Type": "text/html; charset=utf-8",
        "Cache-Control": "no-store",
        ...cors,
      },
    });
  }

  if (path === "/admin/bundle-ab" && request.method === "GET") {
    const redir = env.ADMIN_STATIC_REDIRECT_URL?.trim();
    if (redir) {
      return Response.redirect(redir, 302);
    }
    const base = servicePublicBase(url, "daddy-ab-config");
    return Response.redirect(`${base}/admin`, 302);
  }

  if (path === "/admin/api/requests" && request.method === "GET") {
    const deny = assertAdmin(request, env);
    if (deny) {
      return new Response(deny.body, {
        status: deny.status,
        headers: { ...Object.fromEntries(deny.headers), ...cors },
      });
    }
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
      const j = jsonResponse({
        code: 0,
        data: {
          rows,
          page,
          pageSize,
          total,
          totalPages: Math.max(1, Math.ceil(total / pageSize)),
          d1Bound: true,
          bundleIdFilter: bundleIdFilter ?? "",
        },
      });
      return new Response(j.body, {
        status: j.status,
        headers: { ...Object.fromEntries(j.headers), ...cors },
      });
    } catch (e) {
      const j = jsonResponse({ code: 500, message: String(e) }, 500);
      return new Response(j.body, {
        status: j.status,
        headers: { ...Object.fromEntries(j.headers), ...cors },
      });
    }
  }

  if (path === "/admin/api/device-force-b" && request.method === "POST") {
    const r = await handleDeviceForceB(request, env);
    return new Response(r.body, {
      status: r.status,
      headers: { ...Object.fromEntries(r.headers), ...cors },
    });
  }
  if (path === "/admin/api/bundle-force-b" && request.method === "POST") {
    const r = await handleBundleForceB(request, env);
    return new Response(r.body, {
      status: r.status,
      headers: { ...Object.fromEntries(r.headers), ...cors },
    });
  }
  if (path === "/admin/api/bundle-unforce-b" && request.method === "POST") {
    const r = await handleBundleUnforceB(request, env);
    return new Response(r.body, {
      status: r.status,
      headers: { ...Object.fromEntries(r.headers), ...cors },
    });
  }
  if (path === "/admin/api/blocklist" && request.method === "GET") {
    const deny = assertAdmin(request, env);
    if (deny) {
      return new Response(deny.body, {
        status: deny.status,
        headers: { ...Object.fromEntries(deny.headers), ...cors },
      });
    }
    try {
      const bl = await listBlocklist(env);
      const j = jsonResponse({ code: 0, data: bl });
      return new Response(j.body, {
        status: j.status,
        headers: { ...Object.fromEntries(j.headers), ...cors },
      });
    } catch (e) {
      const j = jsonResponse({ code: 500, message: String(e) }, 500);
      return new Response(j.body, {
        status: j.status,
        headers: { ...Object.fromEntries(j.headers), ...cors },
      });
    }
  }
  if (path === "/admin/api/blocklist-add" && request.method === "POST") {
    const r = await handleBlocklistAdd(request, env);
    return new Response(r.body, {
      status: r.status,
      headers: { ...Object.fromEntries(r.headers), ...cors },
    });
  }
  if (path === "/admin/api/blocklist-remove" && request.method === "POST") {
    const r = await handleBlocklistRemove(request, env);
    return new Response(r.body, {
      status: r.status,
      headers: { ...Object.fromEntries(r.headers), ...cors },
    });
  }
  if (path === "/admin/api/apple-asn-refresh" && request.method === "POST") {
    const r = await handleAppleAsnRefresh(request, env);
    return new Response(r.body, {
      status: r.status,
      headers: { ...Object.fromEntries(r.headers), ...cors },
    });
  }
  if (path === "/admin/api/apple-asn-status" && request.method === "GET") {
    const r = await handleAppleAsnStatus(request, env);
    return new Response(r.body, {
      status: r.status,
      headers: { ...Object.fromEntries(r.headers), ...cors },
    });
  }
  if (path === "/admin/api/bundles" && request.method === "GET") {
    const deny = assertAdmin(request, env);
    if (deny) {
      return new Response(deny.body, {
        status: deny.status,
        headers: { ...Object.fromEntries(deny.headers), ...cors },
      });
    }
    try {
      const kvRows = await listAllBundleAbConfigs(env);
      const seenOnly = await buildSeenBundleRows(env, kvRows);
      const j = jsonResponse({ code: 0, data: { kvRows, seenOnly } });
      return new Response(j.body, {
        status: j.status,
        headers: { ...Object.fromEntries(j.headers), ...cors },
      });
    } catch (e) {
      const j = jsonResponse({ code: 500, message: String(e) }, 500);
      return new Response(j.body, {
        status: j.status,
        headers: { ...Object.fromEntries(j.headers), ...cors },
      });
    }
  }

  if (path === "/client/api/ping" && request.method === "GET") {
    const secret = env.CONFIG_AUTH_TOKEN?.trim() ?? "";
    if (secret.length > 0) {
      const token = request.headers.get("X-Config-Token") ?? "";
      if (token !== secret) {
        const j = jsonResponse({ code: 401, message: "Unauthorized" }, 401);
        return new Response(j.body, {
          status: j.status,
          headers: { ...Object.fromEntries(j.headers), ...cors },
        });
      }
    }
    const j = jsonResponse({ code: 0, data: { ping: true } });
    return new Response(j.body, {
      status: j.status,
      headers: { ...Object.fromEntries(j.headers), ...cors },
    });
  }

  if (path === CONFIG_PATH && request.method === "GET") {
    const r = await handleClientConfig(request, env);
    return new Response(r.body, {
      status: r.status,
      headers: { ...Object.fromEntries(r.headers), ...cors },
    });
  }

  return new Response("Not Found", {
    status: 404,
    headers: cors,
  });
}
