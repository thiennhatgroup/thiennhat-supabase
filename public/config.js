// Supabase project connection settings.
//
// Where to find these values:
//   Supabase Dashboard -> your project -> Project Settings -> API
//   - "Project URL"      -> supabaseUrl
//   - "anon public" key  -> supabaseAnonKey  (this key is safe to ship in a browser,
//                           it has NO table access by default — every table in this
//                           project has Row Level Security enabled with zero policies,
//                           so the anon/authenticated keys can only call the RPC
//                           functions defined in supabase/migrations/*.sql)
//
// This file is loaded by public/index.html before app.js. Replace the two
// REPLACE_ME values, commit, and push — that's the only per-deployment change
// this project needs.
window.APP_CONFIG = {
  supabaseUrl: "https://REPLACE_ME.supabase.co",
  supabaseAnonKey: "REPLACE_ME",
};
