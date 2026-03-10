import {
  clearOnboardingRoute,
  setOnboardingRoute,
  setStatus
} from "/auth-common.js";
import {
  clearOnboardingDraft,
  initOnboardingContext,
  persistOnboarding
} from "/onboarding-common.js";

const allowMicBtn = document.getElementById("allowMicBtn");
const skipMicBtn = document.getElementById("skipMicBtn");
const permissionStatusEl = document.getElementById("permissionStatus");

let accessToken = "";
let saving = false;

function setLoading(loading) {
  allowMicBtn.disabled = loading;
  skipMicBtn.disabled = loading;
  allowMicBtn.textContent = loading ? "Hazırlanıyor..." : "Mikrofon erişimine izin ver";
}

async function completeOnboarding(microphoneAllowed) {
  if (!accessToken || saving) {
    return;
  }

  saving = true;
  setLoading(true);
  setStatus(permissionStatusEl, "", false);

  try {
    await persistOnboarding(accessToken, {
      onboardingCompleted: true
    });

    try {
      localStorage.setItem("voice_permission_granted_v1", microphoneAllowed ? "true" : "false");
    } catch {
      // Tarayıcı depolaması kapalı olabilir.
    }

    clearOnboardingDraft();
    clearOnboardingRoute();
    window.location.replace("/index.html");
  } catch (error) {
    saving = false;
    setLoading(false);
    setStatus(permissionStatusEl, error?.message || "Onboarding tamamlarken hata oluştu.", true);
  }
}

allowMicBtn.addEventListener("click", async () => {
  setStatus(permissionStatusEl, "", false);

  if (!navigator.mediaDevices?.getUserMedia) {
    setStatus(
      permissionStatusEl,
      "Bu cihazda mikrofon izni API desteği yok. Yazı modu ile devam edebilirsin.",
      true
    );
    return;
  }

  try {
    const stream = await navigator.mediaDevices.getUserMedia({ audio: true });
    stream.getTracks().forEach((track) => track.stop());
    await completeOnboarding(true);
  } catch {
    setStatus(
      permissionStatusEl,
      "Mikrofon izni verilmedi. İstersen \"Şimdilik geç\" seçeneğiyle devam edebilirsin.",
      true
    );
  }
});

skipMicBtn.addEventListener("click", async () => {
  await completeOnboarding(false);
});

async function init() {
  setOnboardingRoute("/tutorial-permission.html");

  const context = await initOnboardingContext();
  if (!context?.session?.access_token) {
    return;
  }

  accessToken = context.session.access_token;

  if (context.draft.onboardingCompleted) {
    clearOnboardingDraft();
    clearOnboardingRoute();
    window.location.replace("/index.html");
  }
}

await init();
