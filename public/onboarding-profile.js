import { setOnboardingRoute, setStatus } from "/auth-common.js";
import { initOnboardingContext, persistOnboarding } from "/onboarding-common.js";

const AGE_RANGES = ["18-24", "25-34", "35-44", "45-54", "55+"];

const onboardingBackBtn = document.getElementById("onboardingBackBtn");
const fullNameInputEl = document.getElementById("fullNameInput");
const phoneInputEl = document.getElementById("phoneInput");
const ageRangeGridEl = document.getElementById("ageRangeGrid");
const onboardingProfileStatusEl = document.getElementById("onboardingProfileStatus");
const onboardingProfileContinueBtn = document.getElementById("onboardingProfileContinueBtn");

let selectedAgeRange = "";
let accessToken = "";

function renderAgeRange() {
  ageRangeGridEl.innerHTML = "";

  AGE_RANGES.forEach((range) => {
    const btn = document.createElement("button");
    btn.type = "button";
    btn.className = "chip-btn";
    btn.textContent = range;
    if (range === selectedAgeRange) {
      btn.classList.add("selected");
    }

    btn.addEventListener("click", () => {
      selectedAgeRange = range;
      renderAgeRange();
      setStatus(onboardingProfileStatusEl, "", false);
    });

    ageRangeGridEl.append(btn);
  });
}

function setLoading(loading) {
  onboardingProfileContinueBtn.disabled = loading;
  onboardingProfileContinueBtn.textContent = loading ? "Kaydediliyor..." : "Devam et";
}

async function init() {
  setOnboardingRoute("/onboarding-profile.html");
  const context = await initOnboardingContext();
  if (!context?.session?.access_token) {
    return;
  }

  accessToken = context.session.access_token;

  if (context.draft.fullName) {
    fullNameInputEl.value = context.draft.fullName;
  }
  if (context.draft.phoneNumber) {
    phoneInputEl.value = context.draft.phoneNumber;
  }
  if (context.draft.ageRange) {
    selectedAgeRange = context.draft.ageRange;
  }

  renderAgeRange();
}

onboardingBackBtn.addEventListener("click", () => {
  if (window.history.length > 1) {
    window.history.back();
    return;
  }
  window.location.replace("/welcome.html");
});

onboardingProfileContinueBtn.addEventListener("click", async () => {
  const fullName = fullNameInputEl.value.trim();
  const phoneNumber = phoneInputEl.value.trim();

  if (!fullName) {
    setStatus(onboardingProfileStatusEl, "Ad soyad zorunludur.", true);
    return;
  }

  if (!phoneNumber || phoneNumber.length < 7) {
    setStatus(onboardingProfileStatusEl, "Geçerli bir telefon numarası gir.", true);
    return;
  }

  if (!selectedAgeRange) {
    setStatus(onboardingProfileStatusEl, "Lütfen yaş aralığını seç.", true);
    return;
  }

  setLoading(true);
  setStatus(onboardingProfileStatusEl, "", false);

  try {
    await persistOnboarding(accessToken, {
      fullName,
      phoneNumber,
      ageRange: selectedAgeRange,
      onboardingCompleted: false
    });

    window.location.href = "/onboarding-goal.html";
  } catch (error) {
    setStatus(onboardingProfileStatusEl, error?.message || "Kayıt başarısız.", true);
  } finally {
    setLoading(false);
  }
});

await init();
