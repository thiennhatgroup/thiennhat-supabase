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
  supabaseUrl: "https://supabase.com/dashboard/project/nsxvasvceslhhvgjkedh",
  supabaseAnonKey: "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im5zeHZhc3ZjZXNsaGh2Z2prZWRoIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODI4NzY2MDgsImV4cCI6MjA5ODQ1MjYwOH0.PuGwDEVHu3n0V4X5uhx-X04swUjQfjZLuhN5Ug6K924",
};
