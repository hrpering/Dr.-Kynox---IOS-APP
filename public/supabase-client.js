import { createClient } from "https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2/+esm";

let configPromise = null;
let supabaseClient = null;
const PUBLIC_CONFIG_CACHE_KEY = "public_config_cache_v1";
const PUBLIC_CONFIG_TTL_MS = 6 * 60 * 60 * 1000;

function readCachedPublicConfig() {
  try {
    const raw = sessionStorage.getItem(PUBLIC_CONFIG_CACHE_KEY);
    if (!raw) {
      return null;
    }
    const parsed = JSON.parse(raw);
    if (!parsed || typeof parsed !== "object") {
      return null;
    }
    if (!parsed.supabaseUrl || !parsed.supabaseAnonKey) {
      return null;
    }
    const updatedAt = Number(parsed.updatedAt) || 0;
    if (!updatedAt || Date.now() - updatedAt > PUBLIC_CONFIG_TTL_MS) {
      return null;
    }
    return {
      supabaseUrl: parsed.supabaseUrl,
      supabaseAnonKey: parsed.supabaseAnonKey,
      authorizationUrl: parsed.authorizationUrl || ""
    };
  } catch {
    return null;
  }
}

function writeCachedPublicConfig(config) {
  try {
    sessionStorage.setItem(
      PUBLIC_CONFIG_CACHE_KEY,
      JSON.stringify({
        supabaseUrl: config?.supabaseUrl || "",
        supabaseAnonKey: config?.supabaseAnonKey || "",
        authorizationUrl: config?.authorizationUrl || "",
        updatedAt: Date.now()
      })
    );
  } catch {
    // sessionStorage devre disi olabilir.
  }
}

export async function getPublicConfig() {
  if (!configPromise) {
    const cached = readCachedPublicConfig();
    if (cached) {
      configPromise = Promise.resolve(cached);
    }
  }

  if (!configPromise) {
    configPromise = fetch("/api/public-config", { cache: "no-store" })
      .then(async (response) => {
        if (!response.ok) {
          const body = await response.json().catch(() => ({}));
          throw new Error(body.error || "Uygulama ayarları yüklenemedi.");
        }
        const config = await response.json();
        writeCachedPublicConfig(config);
        return config;
      })
      .catch((error) => {
        configPromise = null;
        throw error;
      });
  }
  return configPromise;
}

export async function getSupabaseClient() {
  if (supabaseClient) {
    return supabaseClient;
  }

  const config = await getPublicConfig();
  if (!config.supabaseUrl || !config.supabaseAnonKey) {
    throw new Error("Supabase bağlantı ayarları eksik.");
  }

  supabaseClient = createClient(config.supabaseUrl, config.supabaseAnonKey, {
    auth: {
      persistSession: true,
      autoRefreshToken: true,
      detectSessionInUrl: true
    }
  });

  return supabaseClient;
}
