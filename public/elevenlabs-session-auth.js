import { getSupabaseClient } from "/supabase-client.js";

const sessionWindowTokenByAgent = new Map();

function normalizeAuthPayload(agentId, payload) {
  return {
    agentId: String(agentId || "").trim(),
    conversationToken: String(payload?.conversationToken || "").trim() || null,
    signedUrl: String(payload?.signedUrl || "").trim() || null,
    expiresInSeconds: Number(payload?.expiresInSeconds) || null,
    sessionWindowToken: String(payload?.sessionWindowToken || "").trim() || null,
    sessionWindowExpiresAt: String(payload?.sessionWindowExpiresAt || "").trim() || null,
    sessionActiveWindowEndsAt: String(payload?.sessionActiveWindowEndsAt || "").trim() || null
  };
}

export function invalidateElevenLabsSessionAuth(agentId) {
  const key = String(agentId || "").trim();
  if (!key) {
    return;
  }
  sessionWindowTokenByAgent.delete(key);
}

export function getElevenLabsSessionWindowToken(agentId) {
  const key = String(agentId || "").trim();
  if (!key) {
    return null;
  }
  return sessionWindowTokenByAgent.get(key) || null;
}

export async function getElevenLabsSessionAuth(agentId, options = {}) {
  const key = String(agentId || "").trim();
  if (!key) {
    throw new Error("ELEVEN_AGENT_ID_REQUIRED");
  }

  const mode = String(options?.mode || "").trim().toLowerCase() === "text" ? "text" : "voice";
  const priorToken =
    String(options?.sessionWindowToken || "").trim() || getElevenLabsSessionWindowToken(key) || null;

  const supabase = await getSupabaseClient();
  const { data, error } = await supabase.auth.getSession();
  if (error || !data?.session?.access_token) {
    throw new Error("ELEVEN_AUTH_SESSION_MISSING");
  }

  const payload = {
    agentId: key,
    mode
  };
  if (options?.dynamicVariables && typeof options.dynamicVariables === "object") {
    const entries = Object.entries(options.dynamicVariables)
      .map(([rawKey, rawValue]) => [String(rawKey || "").trim(), String(rawValue ?? "").trim()])
      .filter(([k, v]) => k && v);
    if (entries.length) {
      payload.dynamicVariables = Object.fromEntries(entries);
    }
  }
  if (priorToken) {
    payload.sessionWindowToken = priorToken;
  }

  const response = await fetch("/api/elevenlabs/session-auth", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${data.session.access_token}`
    },
    body: JSON.stringify(payload)
  });
  const body = await response.json().catch(() => ({}));
  if (!response.ok) {
    throw new Error(body?.error || "ELEVEN_AUTH_FETCH_FAILED");
  }

  const normalized = normalizeAuthPayload(key, body);
  if (!normalized.conversationToken && !normalized.signedUrl) {
    throw new Error("ELEVEN_AUTH_EMPTY");
  }
  if (normalized.sessionWindowToken) {
    sessionWindowTokenByAgent.set(key, normalized.sessionWindowToken);
  }
  return normalized;
}

export async function endElevenLabsSessionAuth(agentId, options = {}) {
  const key = String(agentId || "").trim();
  if (!key) {
    return { ok: false, released: false };
  }

  const sessionWindowToken =
    String(options?.sessionWindowToken || "").trim() || getElevenLabsSessionWindowToken(key) || null;

  const supabase = await getSupabaseClient();
  const { data, error } = await supabase.auth.getSession();
  if (error || !data?.session?.access_token) {
    invalidateElevenLabsSessionAuth(key);
    return { ok: false, released: false };
  }

  try {
    const response = await fetch("/api/elevenlabs/session-end", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${data.session.access_token}`
      },
      body: JSON.stringify({
        agentId: key,
        sessionWindowToken: sessionWindowToken || undefined
      })
    });
    const body = await response.json().catch(() => ({}));
    invalidateElevenLabsSessionAuth(key);
    return {
      ok: response.ok,
      released: Boolean(body?.released)
    };
  } catch {
    invalidateElevenLabsSessionAuth(key);
    return {
      ok: false,
      released: false
    };
  }
}
