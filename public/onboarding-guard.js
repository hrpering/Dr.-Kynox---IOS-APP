import {
  fetchMyProfile,
  getCachedProfile,
  requireAuth,
  setCachedProfile
} from "/auth-common.js";

const session = await requireAuth("/login.html");
if (!session?.access_token) {
  // requireAuth yonlendirmeyi yapti.
} else {
  const cached = getCachedProfile();
  const cachedFlag = cached && typeof cached.onboarding_completed === "boolean" ? cached.onboarding_completed : null;

  if (cachedFlag === true) {
    window.location.replace("/index.html");
  } else if (cachedFlag !== false) {
    const profile = await fetchMyProfile(session.access_token).catch(() => null);
    if (profile) {
      setCachedProfile(profile);
      if (profile.onboarding_completed) {
        window.location.replace("/index.html");
      }
    }
  }
}
