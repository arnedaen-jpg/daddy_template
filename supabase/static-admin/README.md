# A/B 配置管理页（静态托管）

页面里的脚本会把所有 `/admin/api/*` 请求发到 **Edge Function 根 URL**（页面内已写死为导出时的地址），因此可与 Supabase Function 跨域配合（接口已带 `Access-Control-Allow-Origin: *`）。

## 生成 `index.html`

在仓库根目录 `daddy_template/` 执行（先安装 [Deno](https://deno.land/)）。

**必须写上脚本路径**（单独执行 `deno run` 会报错）：

```bash
deno run -A scripts/export-static-admin.ts \
  https://<project-ref>.supabase.co/functions/v1/daddy-ab-config
```

或用任务（根目录已有 `deno.json`）：

```bash
deno task export-static-admin -- \
  https://<project-ref>.supabase.co/functions/v1/daddy-ab-config
```

可选：与线上 Secrets 一致时再打开演示开关（会写进 HTML，一般仅本地调试用）：

```bash
deno run -A scripts/export-static-admin.ts \
  https://<project-ref>.supabase.co/functions/v1/daddy-ab-config \
  --admin-open --demo-mock-apple
```

生成结果：**本目录下的 `index.html`**。

## 部署到 GitHub Pages（推荐：GitHub Actions）

1. 把 **`daddy_template`** 当作仓库根目录推到 GitHub（或保证 `.github/workflows/`、`scripts/`、`supabase/` 相对根目录的路径与本仓库一致）。
2. 仓库 **Settings → Pages**：**Build and deployment → Source** 选 **GitHub Actions**。
3. **Settings → Secrets and variables → Actions → Variables**：**New repository variable**
   - **Name**：`SUPABASE_FUNCTION_BASE`
   - **Value**：Function 根 URL，**不要尾斜杠**，例如  
     `https://ydypblkwkhblghrivwhk.supabase.co/functions/v1/daddy-ab-config`
4. 把默认分支（`main` 或 `master`）推上去，或打开 **Actions** 手动运行 **Deploy A/B static admin to GitHub Pages**。
5. 发布产物里 **`index.html` 在站点根**，一般访问 **`https://<用户名>.github.io/<仓库名>/`**。把该地址（通常带尾斜杠即可）填入 Edge Secret **`ADMIN_STATIC_REDIRECT_URL`**。

工作流文件：仓库根目录 `.github/workflows/deploy-static-admin-pages.yml`（会安装 Deno、执行 `scripts/export-static-admin.ts`、再上传 `supabase/static-admin`）。

### 不用 Actions、从分支发布时

本地生成并 **提交** `supabase/static-admin/index.html` 后，在 Pages 里选 **Deploy from a branch**，根目录选 **`/supabase/static-admin`**（若你当前界面仍提供该选项）。新项目更推荐上面的 Actions。

## 其他托管

- **Cloudflare Pages / Netlify / Vercel**：站点根目录指向 **`supabase/static-admin`**，或只把 **`index.html`** 作为站点根文件。
- **Supabase Storage**：**Public** bucket 上传 **`index.html`**，对象元数据里设 **`Content-Type: text/html; charset=utf-8`** 更稳妥。

## 与 Edge Function 联动

1. Function 仍部署 **`daddy-ab-config`**，Secrets 照常（`CONFIG_AUTH_TOKEN`、`ADMIN_OPEN`、`DEMO_MOCK_APPLE` 等）。
2. （推荐）设置 Secret **`ADMIN_STATIC_REDIRECT_URL`** 为 GitHub Pages 地址，例如 `https://your-name.github.io/your-repo/`。之后访问 Function 的 `/admin` 会 **302** 到该静态页。
3. 管理页顶部的 Token / `ADMIN_OPEN` 行为与之前一致，只是 HTML 来源改为静态站。

## 修改 API 地址后

本地部署：重新执行 `deno run ...` 并更新托管文件。使用 GitHub Actions 时：改仓库变量 **`SUPABASE_FUNCTION_BASE`** 后重新跑工作流（或推一次相关文件）。
