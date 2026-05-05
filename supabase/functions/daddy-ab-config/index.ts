import "jsr:@supabase/functions-js/edge-runtime.d.ts";

import { createClient } from "https://esm.sh/@supabase/supabase-js@2.49.1";
import { composeAdminHtml } from "./compose_admin_html.ts";
import { routeRequest, type ServiceEnv } from "./handler.ts";

Deno.serve(async (request: Request) => {
  const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? "";
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
  if (!supabaseUrl || !serviceKey) {
    return new Response(
      JSON.stringify({
        error: "Missing SUPABASE_URL or SUPABASE_SERVICE_ROLE_KEY",
      }),
      { status: 500, headers: { "Content-Type": "application/json" } },
    );
  }
  const sb = createClient(supabaseUrl, serviceKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const env: ServiceEnv = {
    sb,
    CONFIG_AUTH_TOKEN: Deno.env.get("CONFIG_AUTH_TOKEN") ?? undefined,
    ADMIN_OPEN: Deno.env.get("ADMIN_OPEN") ?? undefined,
    DEMO_MOCK_APPLE: Deno.env.get("DEMO_MOCK_APPLE") ?? undefined,
    ADMIN_STATIC_REDIRECT_URL: Deno.env.get("ADMIN_STATIC_REDIRECT_URL") ??
      undefined,
  };
  const url = new URL(request.url);
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY") ?? "";
  return await routeRequest(request, env, url, (pb, o, d) =>
    composeAdminHtml(pb, o, d, anonKey));
});
