import { getPublicConfig, getSupabaseClient } from "/supabase-client.js";

const PROFILE_CACHE_KEY = "profile_cache_v1";
const CASE_LIST_CACHE_KEY = "case_list_cache_v1";
const ONBOARDING_ROUTE_KEY = "onboarding_route_v1";

function safeParseJson(raw) {
  if (!raw) {
    return null;
  }
  try {
    return JSON.parse(raw);
  } catch {
    return null;
  }
}

function safeReadLocalStorage(key) {
  try {
    return localStorage.getItem(key);
  } catch {
    return null;
  }
}

function safeWriteLocalStorage(key, value) {
  try {
    localStorage.setItem(key, value);
  } catch {
    // Depolama kapaliysa sessizce geç.
  }
}

function safeRemoveLocalStorage(key) {
  try {
    localStorage.removeItem(key);
  } catch {
    // Depolama kapaliysa sessizce geç.
  }
}

export function setStatus(targetEl, text, isError = false) {
  if (!targetEl) {
    return;
  }
  targetEl.textContent = text || "";
  targetEl.classList.toggle("error", Boolean(isError));
  targetEl.hidden = !text;
}

export function isOnboardingCompleted(profile) {
  return Boolean(profile?.onboarding_completed);
}

export async function getCurrentSession() {
  const supabase = await getSupabaseClient();
  const { data, error } = await supabase.auth.getSession();
  if (error || !data?.session) {
    return null;
  }
  return data.session;
}

export async function fetchMyProfile(accessToken) {
  if (!accessToken) {
    return null;
  }

  const cached = getCachedProfile();

  try {
    const response = await fetch("/api/profile/me", {
      method: "GET",
      headers: {
        Authorization: `Bearer ${accessToken}`
      }
    });

    const body = await response.json().catch(() => ({}));
    if (!response.ok) {
      throw new Error(body.error || "Profil bilgisi alınamadı.");
    }

    const profile = body.profile || null;
    if (profile) {
      setCachedProfile(profile);
    }
    return profile;
  } catch (error) {
    if (cached) {
      return cached;
    }
    throw error;
  }
}

export function getCachedProfile() {
  const raw = safeReadLocalStorage(PROFILE_CACHE_KEY);
  const parsed = safeParseJson(raw);
  return parsed && typeof parsed === "object" ? parsed : null;
}

export function setCachedProfile(profile) {
  if (!profile || typeof profile !== "object") {
    return;
  }
  safeWriteLocalStorage(PROFILE_CACHE_KEY, JSON.stringify(profile));
}

export function clearCachedProfile() {
  safeRemoveLocalStorage(PROFILE_CACHE_KEY);
}

export async function resolvePostAuthPath() {
  const session = await getCurrentSession();
  if (!session?.access_token) {
    return null;
  }

  const cached = getCachedProfile();
  if (cached && typeof cached.onboarding_completed === "boolean") {
    return cached.onboarding_completed ? "/index.html" : getOnboardingRoute() || "/onboarding-profile.html";
  }

  const profile = await fetchMyProfile(session.access_token).catch(() => "__PROFILE_FETCH_ERROR__");
  if (profile === "__PROFILE_FETCH_ERROR__") {
    // Profil servisi geçici hata verirse login/onboarding döngusune girmemek için dashboard'a geç.
    return "/index.html";
  }
  if (!isOnboardingCompleted(profile)) {
    return getOnboardingRoute() || "/onboarding-profile.html";
  }

  return "/index.html";
}

export function setOnboardingRoute(routePath) {
  const value = String(routePath || "").trim();
  if (!value.startsWith("/")) {
    return;
  }
  safeWriteLocalStorage(ONBOARDING_ROUTE_KEY, value);
}

export function getOnboardingRoute() {
  const raw = safeReadLocalStorage(ONBOARDING_ROUTE_KEY);
  const value = String(raw || "").trim();
  return value.startsWith("/") ? value : "";
}

export function clearOnboardingRoute() {
  safeRemoveLocalStorage(ONBOARDING_ROUTE_KEY);
}

export async function redirectIfAuthenticated(targetPath = null) {
  try {
    const session = await getCurrentSession();
    if (!session) {
      return false;
    }

    const nextPath = targetPath || (await resolvePostAuthPath()) || "/index.html";
    window.location.replace(nextPath);
    return true;
  } catch {
    return false;
  }
}

export async function requireAuth(redirectPath = "/login.html") {
  try {
    const session = await getCurrentSession();
    if (!session) {
      window.location.replace(redirectPath);
      return null;
    }
    return session;
  } catch {
    window.location.replace(redirectPath);
    return null;
  }
}

export async function guardProtectedRoute({
  redirectPath = "/login.html",
  allowOnboardingIncomplete = false,
  allowOnboardingComplete = true
} = {}) {
  const session = await requireAuth(redirectPath);
  if (!session?.access_token) {
    return null;
  }

  const profile = await fetchMyProfile(session.access_token).catch(() => null);
  if (!profile) {
    // Profil okunamazsa oturum varlığına güvenip sayfayı açık tut; aksi halde redirect loop oluşuyor.
    return { session, profile: null };
  }

  const completed = isOnboardingCompleted(profile);

  if (completed && !allowOnboardingComplete) {
    window.location.replace("/index.html");
    return null;
  }

  if (!completed && !allowOnboardingIncomplete) {
    window.location.replace("/onboarding-profile.html");
    return null;
  }

  return { session, profile };
}

export async function persistProfile(accessToken, payload = {}) {
  if (!accessToken) {
    return;
  }

  const existing = getCachedProfile() || {};
  setCachedProfile({
    ...existing,
    full_name: typeof payload.fullName === "string" ? payload.fullName : existing.full_name,
    marketing_opt_in:
      typeof payload.marketingOptIn === "boolean" ? payload.marketingOptIn : existing.marketing_opt_in
  });

  try {
    await fetch("/api/profile/upsert", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${accessToken}`
      },
      body: JSON.stringify({
        fullName: typeof payload.fullName === "string" ? payload.fullName : "",
        marketingOptIn: Boolean(payload.marketingOptIn)
      })
    });
  } catch {
    // Profil yazımi hata verirse auth akisini kesme.
  }
}

export async function saveOnboardingData(accessToken, payload = {}) {
  if (!accessToken) {
    throw new Error("Yetki belirteci bulunamadı.");
  }

  const existing = getCachedProfile() || {};
  setCachedProfile({
    ...existing,
    full_name: typeof payload.fullName === "string" ? payload.fullName : existing.full_name,
    phone_number: typeof payload.phoneNumber === "string" ? payload.phoneNumber : existing.phone_number,
    age_range: typeof payload.ageRange === "string" ? payload.ageRange : existing.age_range,
    role: typeof payload.role === "string" ? payload.role : existing.role,
    goals: Array.isArray(payload.goals) ? payload.goals : existing.goals,
    interest_areas: Array.isArray(payload.interestAreas)
      ? payload.interestAreas
      : existing.interest_areas,
    learning_level:
      typeof payload.learningLevel === "string" ? payload.learningLevel : existing.learning_level,
    onboarding_completed:
      typeof payload.onboardingCompleted === "boolean"
        ? payload.onboardingCompleted
        : existing.onboarding_completed
  });

  const response = await fetch("/api/profile/onboarding", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${accessToken}`
    },
    body: JSON.stringify(payload)
  });

  const body = await response.json().catch(() => ({}));
  if (!response.ok) {
    throw new Error(body.error || "Onboarding bilgisi kaydedilemedi.");
  }
  const profile = body.profile || null;
  if (profile) {
    setCachedProfile(profile);
  }
  return profile;
}

export async function fetchCaseList(accessToken, limit = 50) {
  if (!accessToken) {
    return [];
  }

  const cached = getCachedCaseList(limit);

  try {
    const response = await fetch(`/api/cases/list?limit=${encodeURIComponent(limit)}`, {
      method: "GET",
      headers: {
        Authorization: `Bearer ${accessToken}`
      }
    });

    const body = await response.json().catch(() => ({}));
    if (!response.ok) {
      throw new Error(body.error || "Vaka listesi alınamadı.");
    }

    const list = Array.isArray(body.cases) ? body.cases : [];
    setCachedCaseList(list);
    return list;
  } catch (error) {
    if (cached.length) {
      return cached;
    }
    throw error;
  }
}

export function getCachedCaseList(limit = 50) {
  const raw = safeReadLocalStorage(CASE_LIST_CACHE_KEY);
  const parsed = safeParseJson(raw);
  const list = Array.isArray(parsed?.cases) ? parsed.cases : [];
  const safeLimit = Number.isFinite(Number(limit)) ? Math.max(1, Number(limit)) : 50;
  return list.slice(0, safeLimit);
}

export function setCachedCaseList(cases) {
  const safeCases = Array.isArray(cases) ? cases : [];
  safeWriteLocalStorage(
    CASE_LIST_CACHE_KEY,
    JSON.stringify({
      updatedAt: new Date().toISOString(),
      cases: safeCases
    })
  );
}

export function clearCachedCaseList() {
  safeRemoveLocalStorage(CASE_LIST_CACHE_KEY);
}

export async function signOutAndRedirect() {
  try {
    const supabase = await getSupabaseClient();
    await supabase.auth.signOut();
  } finally {
    clearCachedProfile();
    clearCachedCaseList();
    clearOnboardingRoute();
    safeRemoveLocalStorage("dashboard_name_cache_v1");
    safeRemoveLocalStorage("dashboard_snapshot_v1");
    window.location.replace("/login.html");
  }
}

export function passwordStrongEnough(password) {
  const value = String(password || "");
  return value.length >= 8 && /[A-Z]/.test(value) && /\d/.test(value);
}

export async function startOAuth(provider, statusEl, fallbackText) {
  try {
    const supabase = await getSupabaseClient();
    const redirectTo = `${window.location.origin}/auth-callback.html`;
    const { error } = await supabase.auth.signInWithOAuth({
      provider,
      options: { redirectTo }
    });

    if (error) {
      const cfg = await getPublicConfig().catch(() => null);
      if (cfg?.authorizationUrl) {
        window.location.href = cfg.authorizationUrl;
        return;
      }
      throw error;
    }
  } catch (error) {
    setStatus(statusEl, fallbackText || error?.message || "Sosyal giriş başlatılamadı.", true);
  }
}
