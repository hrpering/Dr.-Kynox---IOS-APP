import { setOnboardingRoute, setStatus } from "/auth-common.js";
import { initOnboardingContext, persistOnboarding } from "/onboarding-common.js";

const INTEREST_OPTIONS = [
  "Kardiyoloji",
  "Nöroloji",
  "Pulmonoloji",
  "Gastroenteroloji",
  "Nefroloji",
  "Endokrinoloji",
  "Pediatri",
  "Cerrahi",
  "Psikiyatri",
  "Kadın Doğum",
  "Acil Tıp",
  "Radyoloji"
];

const MIN_SELECTION = 3;

const interestsBackBtn = document.getElementById("interestsBackBtn");
const interestSummaryEl = document.getElementById("interestSummary");
const interestGridEl = document.getElementById("interestGrid");
const selectAllInterestsBtn = document.getElementById("selectAllInterestsBtn");
const clearInterestsBtn = document.getElementById("clearInterestsBtn");
const interestsStatusEl = document.getElementById("interestsStatus");
const interestsContinueBtn = document.getElementById("interestsContinueBtn");

let selected = new Set();
let accessToken = "";

function renderSummary() {
  const count = selected.size;
  if (count >= MIN_SELECTION) {
    interestSummaryEl.textContent = `${count} alan seçili`;
    interestSummaryEl.classList.add("ok");
  } else {
    interestSummaryEl.textContent = `${count} alan seçili · en az ${MIN_SELECTION} seç`;
    interestSummaryEl.classList.remove("ok");
  }
}

function renderGrid() {
  interestGridEl.innerHTML = "";

  INTEREST_OPTIONS.forEach((name) => {
    const btn = document.createElement("button");
    btn.type = "button";
    btn.className = "interest-card";
    if (selected.has(name)) {
      btn.classList.add("selected");
    }

    const title = document.createElement("h3");
    title.textContent = name;

    const sub = document.createElement("p");
    sub.textContent = "Vaka odağı";

    btn.append(title, sub);

    btn.addEventListener("click", () => {
      if (selected.has(name)) {
        selected.delete(name);
      } else {
        selected.add(name);
      }
      renderSummary();
      renderGrid();
      setStatus(interestsStatusEl, "", false);
    });

    interestGridEl.append(btn);
  });
}

function setLoading(loading) {
  interestsContinueBtn.disabled = loading;
  interestsContinueBtn.textContent = loading ? "Kaydediliyor..." : "Devam et →";
}

interestsBackBtn.addEventListener("click", () => {
  window.location.href = "/onboarding-goal.html";
});

selectAllInterestsBtn.addEventListener("click", () => {
  selected = new Set(INTEREST_OPTIONS);
  renderSummary();
  renderGrid();
  setStatus(interestsStatusEl, "", false);
});

clearInterestsBtn.addEventListener("click", () => {
  selected = new Set();
  renderSummary();
  renderGrid();
});

interestsContinueBtn.addEventListener("click", async () => {
  if (selected.size < MIN_SELECTION) {
    setStatus(interestsStatusEl, `Lütfen en az ${MIN_SELECTION} alan seç.`, true);
    return;
  }

  setLoading(true);
  setStatus(interestsStatusEl, "", false);

  try {
    await persistOnboarding(accessToken, {
      interestAreas: Array.from(selected),
      onboardingCompleted: false
    });
    window.location.href = "/onboarding-level.html";
  } catch (error) {
    setStatus(interestsStatusEl, error?.message || "Kayıt başarısız.", true);
  } finally {
    setLoading(false);
  }
});

async function init() {
  setOnboardingRoute("/onboarding-interests.html");
  const context = await initOnboardingContext();
  if (!context?.session?.access_token) {
    return;
  }

  accessToken = context.session.access_token;
  selected = new Set(Array.isArray(context.draft.interestAreas) ? context.draft.interestAreas : []);

  renderSummary();
  renderGrid();
}

await init();
