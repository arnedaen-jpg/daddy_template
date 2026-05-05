# A/B 配置管理页（静态托管）

页面里的脚本会把所有 `/admin/api/*` 请求发到 **Edge Function 根 URL**（页面内已写死为导出时的地址），因此可与 Supabase Function 跨域配合（接口已带 `Access-Control-Allow-Origin: *`）。

## 生成 `index.html`

在仓库根目录 `daddy_template/` 执行（先安装 [Deno](https://deno.land/)）。

**从静态站（如 github.io）在浏览器里调 Supabase Function 时**，网关要求请求带 **`apikey` + `Authorization: Bearer <anon>`**。生成页面前需设置 **anon public key**（与 Dashboard → Project Settings → API 里一致；可进 HTML，勿用 `service_role`）：

```bash
export SUPABASE_ANON_KEY='<anon public JWT>'
deno run -A scripts/export-static-admin.ts \
  https://<project-ref>.supabase.co/functions/v1/daddy-ab-config \
  --admin-open
```

不带 `SUPABASE_ANON_KEY` 时，页面仍可打开，但 **「更新苹果 ASN」等 fetch 会在网关层失败**（表现为无数据或按钮无有效响应）。

生成结果：**本目录下的 `index.html`**。

## 部署到 GitHub Pages（推荐：GitHub Actions）

1. 把 **`daddy_template`** 当作仓库根目录推到 GitHub（或保证 `.github/workflows/`、`scripts/`、`supabase/` 相对根目录的路径与本仓库一致）。
2. 仓库 **Settings → Pages**：**Build and deployment → Source** 选 **GitHub Actions**。
3. **Settings → Secrets and variables → Actions → Variables**：**New repository variable**
   - **`SUPABASE_FUNCTION_BASE`**：Function 根 URL，**不要尾斜杠**，例如  
     `https://ydypblkwkhblghrivwhk.supabase.co/functions/v1/daddy-ab-config`
   - **`SUPABASE_ANON_KEY`**：与 Supabase **Project Settings → API** 里的 **anon / public** 一致（不要用 `service_role`；会写进静态 HTML，仅用于通过 API 网关）。
4. 把默认分支（`main` 或 `master`）推上去，或打开 **Actions** 手动运行 **Deploy A/B static admin to GitHub Pages**。
5. 发布产物里 **`index.html` 在站点根**，一般访问 **`https://<用户名>.github.io/<仓库名>/`**。把该地址（通常带尾斜杠即可）填入 Edge Secret **`ADMIN_STATIC_REDIRECT_URL`**。

工作流文件：仓库根目录 `.github/workflows/deploy-static-admin-pages.yml`（会安装 Deno、执行 `scripts/export-static-admin.ts`、再上传 `supabase/static-admin`）。

### 部署失败（红色 X）时常见原因

1. **未设置变量 `SUPABASE_FUNCTION_BASE`**  
   → [Actions → Variables](https://github.com/arnedaen-jpg/daddy_template/settings/variables/actions) 里新增（值无尾斜杠）。

2. **`github-pages` 环境不允许当前分支**  
   → [Environments → github-pages](https://github.com/arnedaen-jpg/daddy_template/settings/environments)  
   → **Deployment branches**：改为 **All branches**，或至少勾选 **`dev`**（你在该分支上推过工作流）。

3. **Pages 源不是 GitHub Actions**  
   → [Settings → Pages](https://github.com/arnedaen-jpg/daddy_template/settings/pages) 里 **Source** 必须选 **GitHub Actions**。

4. 到 [Actions](https://github.com/arnedaen-jpg/daddy_template/actions) 打开失败的那条 run，展开 **build** / **deploy** 日志查看具体报错。

5. **`Resource not accessible by integration`**（与 Pages REST API / `configure-pages` 相关）  
   - 本仓库工作流已**不再使用** `configure-pages`（纯静态目录上传不需要读 Pages 站点 API）。若仍报错，打开  
     [Settings → Actions → General](https://github.com/arnedaen-jpg/daddy_template/settings/actions)  
     → **Workflow permissions**：选 **Read and write permissions**（勿选仅只读），保存后再重跑 workflow。  
   - 组织仓库需管理员允许上述权限或 Pages 功能。

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
