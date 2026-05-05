import { composeAdminHtml } from "../supabase/functions/daddy-ab-config/compose_admin_html.ts";

const args = Deno.args.filter((a) => !a.startsWith("--"));
const flags = new Set(Deno.args.filter((a) => a.startsWith("--")));

const baseArg = args[0]?.trim() ?? "";
if (!baseArg.startsWith("http://") && !baseArg.startsWith("https://")) {
  console.error(
    [
      "用法: deno run -A scripts/export-static-admin.ts <API根URL> [--admin-open] [--demo-mock-apple]",
      "示例: deno run -A scripts/export-static-admin.ts \\",
      "  https://ydypblkwkhblghrivwhk.supabase.co/functions/v1/daddy-ab-config",
      "",
      "需设置环境变量 SUPABASE_ANON_KEY（Dashboard → API → anon public），否则从 GitHub Pages 等跨域调用会被网关拦截。",
      "示例: export SUPABASE_ANON_KEY='eyJ...'; deno run -A scripts/export-static-admin.ts \"https://...\" --admin-open",
      "",
      "API根URL 不要尾斜杠；须与客户端拉配置的 Function 根路径一致。",
    ].join("\n"),
  );
  Deno.exit(1);
}

const open = flags.has("--admin-open");
const demo = flags.has("--demo-mock-apple");
const anonKey = (Deno.env.get("SUPABASE_ANON_KEY") ?? "").trim();

const html = composeAdminHtml(
  baseArg.replace(/\/$/, ""),
  open,
  demo,
  anonKey,
);

const repoRoot = new URL("../", import.meta.url);
const out = new URL("supabase/static-admin/index.html", repoRoot);
await Deno.mkdir(new URL("supabase/static-admin/", repoRoot).pathname, {
  recursive: true,
});
await Deno.writeTextFile(out.pathname, html);
console.log("已写入:", out.pathname);
