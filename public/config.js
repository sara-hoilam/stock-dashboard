// Alpha Ticker — deployed configuration.
//
// This file is what turns the page from "talks to a local server.py" into
// "talks to Supabase". It is served alongside index.html by Cloudflare Pages;
// locally it does not exist and the page falls back to server.py.
//
// The anon key is meant to be public. It ships in every visitor's browser and
// reaches exactly four read-only functions; the tables live in a schema the
// API does not expose. The service-role key must never appear here.

window.ALPHATICKER_CONFIG = {
  supabaseUrl: "https://etembhwwbqswzcepfhxp.supabase.co",
  supabaseAnonKey: "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImV0ZW1iaHd3YnFzd3pjZXBmaHhwIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODU1NjM1MDEsImV4cCI6MjEwMTEzOTUwMX0.LpaWoQxaF0Xl0FPRq7nK7aDi7Wr_hMelnPtXJzO3y9Y",
};
