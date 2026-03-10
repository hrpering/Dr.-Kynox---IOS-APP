import { setOnboardingRoute, setStatus } from "/auth-common.js";
import { initOnboardingContext, persistOnboarding } from "/onboarding-common.js";

const ROLE_OPTIONS = [
  {
    key: "medical_student",
    title: "Tıp öğrencisi",
    subtitle: "Sınavlara ve klinik rotasyonlara hazırlanıyorum",
    tags: ["Çalışma Modu", "Sınav Hazırlığı", "Temel Beceriler"],
    goals: ["Çalışma modu", "Sınav hazırlığı", "Temel güçlendirme"]
  },
  {
    key: "intern_resident",
    title: "İntern / Asistan",
    subtitle: "Klinikte aktif hasta yönetimi yapıyorum",
    tags: ["Klinik Pratik", "Hızlı Referans", "İleri Vakalar"],
    goals: ["Klinik pratik", "Hızlı referans", "İleri vaka"]
  },
  {
    key: "other_healthcare",
    title: "Diğer sağlık profesyoneli",
    subtitle: "Farklı disiplinlerde klinik bilgisini artırmak istiyorum",
    tags: ["Disiplinler arası", "Esnek öğrenme"],
    goals: ["Disiplinler arası yaklaşım", "Esnek öğrenme"]
  }
];

const goalBackBtn = document.getElementById("goalBackBtn");
const roleCardsEl = document.getElementById("roleCards");
const goalStatusEl = document.getElementById("goalStatus");
const goalContinueBtn = document.getElementById("goalContinueBtn");

let selectedRole = "";
let selectedGoals = [];
let accessToken = "";

function roleByKey(key) {
  return ROLE_OPTIONS.find((item) => item.key === key) || null;
}

function renderRoleCards() {
  roleCardsEl.innerHTML = "";

  ROLE_OPTIONS.forEach((role) => {
    const button = document.createElement("button");
    button.type = "button";
    button.className = "role-card";
    if (role.key === selectedRole) {
      button.classList.add("selected");
    }

    const title = document.createElement("h3");
    title.textContent = role.title;

    const subtitle = document.createElement("p");
    subtitle.textContent = role.subtitle;

    const tags = document.createElement("div");
    tags.className = "role-tags";
    role.tags.forEach((tag) => {
      const chip = document.createElement("span");
      chip.textContent = tag;
      tags.append(chip);
    });

    button.append(title, subtitle, tags);

    button.addEventListener("click", () => {
      selectedRole = role.key;
      selectedGoals = role.goals;
      renderRoleCards();
      setStatus(goalStatusEl, "", false);
    });

    roleCardsEl.append(button);
  });
}

function setLoading(loading) {
  goalContinueBtn.disabled = loading;
  goalContinueBtn.textContent = loading ? "Kaydediliyor..." : "Devam et →";
}

goalBackBtn.addEventListener("click", () => {
  window.location.href = "/onboarding-profile.html";
});

goalContinueBtn.addEventListener("click", async () => {
  if (!selectedRole) {
    setStatus(goalStatusEl, "Lütfen bir rol seç.", true);
    return;
  }

  setLoading(true);
  setStatus(goalStatusEl, "", false);

  try {
    await persistOnboarding(accessToken, {
      role: selectedRole,
      goals: selectedGoals,
      onboardingCompleted: false
    });

    window.location.href = "/onboarding-interests.html";
  } catch (error) {
    setStatus(goalStatusEl, error?.message || "Kayıt başarısız.", true);
  } finally {
    setLoading(false);
  }
});

async function init() {
  setOnboardingRoute("/onboarding-goal.html");
  const context = await initOnboardingContext();
  if (!context?.session?.access_token) {
    return;
  }

  accessToken = context.session.access_token;

  if (context.draft.role) {
    selectedRole = context.draft.role;
    const selected = roleByKey(selectedRole);
    selectedGoals = selected?.goals || context.draft.goals;
  }

  renderRoleCards();
}

await init();
