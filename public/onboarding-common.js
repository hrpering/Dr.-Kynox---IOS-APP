import {
  fetchMyProfile,
  getCachedProfile,
  requireAuth,
  saveOnboardingData,
  setCachedProfile
} from "/auth-common.js";

const ONBOARDING_DRAFT_KEY = "onboarding_draft_v1";

function parseJson(raw) {
  if (!raw) {
    return null;
  }
  try {
    return JSON.parse(raw);
  } catch {
    return null;
  }
}

function normalizeArray(value) {
  if (!Array.isArray(value)) {
    return [];
  }
  return value
    .map((item) => String(item || "").trim())
    .filter(Boolean);
}

function sanitizeDraft(raw = {}) {
  return {
    fullName: typeof raw.fullName === "string" ? raw.fullName.trim() : "",
    phoneNumber: typeof raw.phoneNumber === "string" ? raw.phoneNumber.trim() : "",
    ageRange: typeof raw.ageRange === "string" ? raw.ageRange.trim() : "",
    role: typeof raw.role === "string" ? raw.role.trim() : "",
    goals: normalizeArray(raw.goals),
    interestAreas: normalizeArray(raw.interestAreas),
    learningLevel: typeof raw.learningLevel === "string" ? raw.learningLevel.trim() : "",
    onboardingCompleted: Boolean(raw.onboardingCompleted)
  };
}

function profileToDraft(profile) {
  if (!profile) {
    return sanitizeDraft();
  }

  return sanitizeDraft({
    fullName: profile.full_name || "",
    phoneNumber: profile.phone_number || "",
    ageRange: profile.age_range || "",
    role: profile.role || "",
    goals: Array.isArray(profile.goals) ? profile.goals : [],
    interestAreas: Array.isArray(profile.interest_areas) ? profile.interest_areas : [],
    learningLevel: profile.learning_level || "",
    onboardingCompleted: Boolean(profile.onboarding_completed)
  });
}

export function readOnboardingDraft() {
  const raw = sessionStorage.getItem(ONBOARDING_DRAFT_KEY);
  return sanitizeDraft(parseJson(raw) || {});
}

export function writeOnboardingDraft(nextDraft) {
  const clean = sanitizeDraft(nextDraft || {});
  sessionStorage.setItem(ONBOARDING_DRAFT_KEY, JSON.stringify(clean));
  return clean;
}

export function patchOnboardingDraft(patch = {}) {
  const current = readOnboardingDraft();
  return writeOnboardingDraft({
    ...current,
    ...patch
  });
}

export function clearOnboardingDraft() {
  sessionStorage.removeItem(ONBOARDING_DRAFT_KEY);
}

export async function initOnboardingContext() {
  const session = await requireAuth("/login.html");
  if (!session?.access_token) {
    return null;
  }

  const cachedProfile = getCachedProfile();
  let profile = cachedProfile;

  // Onboarding adimlari arasinda sayfa gecisi hizli olsun diye cache'i onceliklendir.
  if (!profile) {
    profile = await fetchMyProfile(session.access_token).catch(() => null);
    if (profile) {
      setCachedProfile(profile);
    }
  } else {
    // Arka planda sessizce yenile, UI'yi bloke etme.
    void fetchMyProfile(session.access_token)
      .then((fresh) => {
        if (fresh) {
          setCachedProfile(fresh);
        }
      })
      .catch(() => null);
  }

  const profileDraft = profileToDraft(profile);
  const localDraft = readOnboardingDraft();

  const merged = writeOnboardingDraft({
    ...profileDraft,
    ...localDraft,
    goals: localDraft.goals.length ? localDraft.goals : profileDraft.goals,
    interestAreas: localDraft.interestAreas.length ? localDraft.interestAreas : profileDraft.interestAreas
  });

  return {
    session,
    profile,
    draft: merged
  };
}

export async function persistOnboarding(accessToken, patch = {}) {
  if (!accessToken) {
    throw new Error("Oturum bulunamadı.");
  }

  const draft = patchOnboardingDraft(patch);

  await saveOnboardingData(accessToken, {
    fullName: draft.fullName,
    phoneNumber: draft.phoneNumber,
    ageRange: draft.ageRange,
    role: draft.role,
    goals: draft.goals,
    interestAreas: draft.interestAreas,
    learningLevel: draft.learningLevel,
    onboardingCompleted: draft.onboardingCompleted
  });

  return draft;
}
