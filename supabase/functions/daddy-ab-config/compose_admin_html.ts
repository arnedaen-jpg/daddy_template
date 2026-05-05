import { ADMIN_HTML } from "./admin_html.ts";

/** publicBase：API 根 URL，无尾斜杠；supabaseAnonKey：浏览器调 functions 网关所需（Dashboard → API → anon public），可空仅同域时。 */
export function composeAdminHtml(
  publicBase: string,
  open: boolean,
  demo: boolean,
  supabaseAnonKey = "",
): string {
  const tokenUi = open
    ? '<p class="muted">已开启 <code>ADMIN_OPEN</code>：无需 Token 即可加载管理数据。生产环境请删除该变量并仅用 Token 访问。</p><input type="hidden" id="tok" value="" />'
    : '<p><label for="tok">CONFIG_AUTH_TOKEN</label></p><input id="tok" type="password" autocomplete="off" placeholder="与 wrangler secret / Supabase Secrets 一致" />';
  const demoBanner = demo
    ? '<p class="muted" style="background:#fffbeb;border:1px solid #fcd34d;padding:8px;border-radius:6px"><strong>演示苹果 ASN：</strong>已开启 <code>DEMO_MOCK_APPLE</code>。终端执行：<br /><code style="display:block;word-break:break-all;margin-top:6px">curl -sS "' +
      publicBase.replace(/\/$/, "") +
      '/client/api/config" -H "X-Mock-Apple-ASN: 1" -H "X-Bundle-Id: com.demo.app" -H "X-Device-Id: demo-uuid"</code>若配置了 <code>CONFIG_AUTH_TOKEN</code>，请再加 <code>-H "X-Config-Token: …"</code>。应返回 <code>"config":"A"</code>；带设备 UUID 时会写入 <code>apple_asn_lock_a_*</code> 永久 A；刷新下方请求记录可见备注「苹果ASN」、锁 A。</p>'
    : "";
  const base = publicBase.replace(/\/$/, "");
  return ADMIN_HTML.replace("__API_PUBLIC_BASE__", base)
    .replace("__SUPABASE_ANON_JSON__", JSON.stringify(supabaseAnonKey))
    .replace("__DEMO_MOCK_BANNER__", demoBanner)
    .replace("__ADMIN_TOKEN_UI__", tokenUi)
    .replace("__ADMIN_OPEN_ATTR__", open ? "true" : "false");
}
