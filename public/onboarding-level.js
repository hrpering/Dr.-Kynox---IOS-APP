import { setOnboardingRoute, setStatus } from "/auth-common.js";
import {
  initOnboardingContext,
  persistOnboarding
} from "/onboarding-common.js";

const LEVEL_OPTIONS = [
  {
    key: "Beginner",
    title: "Başlangıç",
    subtitle: "Temel klinik kavramları güçlendir",
    points: ["Detaylı açıklama", "Sık görülen tablolar", "Adım adım yönlendirme"]
  },
  {
    key: "Intermediate",
    title: "Orta",
    subtitle: "Ayırıcı tanı ve klinik akıl yürütmeyi geliştir",
    points: ["Karma vakalar", "Ayırıcı tanı odağı", "Klinik karar vurgusu"]
  },
  {
    key: "Advanced",
    title: "İleri",
    subtitle: "Nadir ve çok sistemli olgularla zorluk seviyesini artır",
    points: ["Nadir tablolar", "Çok sistemli vakalar", "Minimal yönlendirme"]
  }
];

const levelBackBtn = document.getElementById("levelBackBtn");
const levelCardsEl = document.getElementById("levelCards");
const levelStatusEl = document.getElementById("levelStatus");
const levelContinueBtn = document.getElementById("levelContinueBtn");

let selectedLevel = "";
let accessToken = "";

function renderCards() {
  levelCardsEl.innerHTML = "";

  LEVEL_OPTIONS.forEach((level) => {
    const card = document.createElement("button");
    card.type = "button";
    card.className = "level-card";
    if (level.key === selectedLevel) {
      card.classList.add("selected");
    }

    const title = document.createElement("h3");
    title.textContent = level.title;

    const subtitle = document.createElement("p");
    subtitle.className = "level-subtitle";
    subtitle.textContent = level.subtitle;

    const list = document.createElement("ul");
    level.points.forEach((point) => {
      const li = document.createElement("li");
      li.textContent = point;
      list.append(li);
    });

    card.append(title, subtitle, list);

    card.addEventListener("click", () => {
      selectedLevel = level.key;
      renderCards();
      setStatus(levelStatusEl, "", false);
    });

    levelCardsEl.append(card);
  });
}

function setLoading(loading) {
  levelContinueBtn.disabled = loading;
  levelContinueBtn.textContent = loading ? "Tamamlanıyor..." : "Devam et →";
}

levelBackBtn.addEventListener("click", () => {
  window.location.href = "/onboarding-interests.html";
});

levelContinueBtn.addEventListener("click", async () => {
  if (!selectedLevel) {
    setStatus(levelStatusEl, "Lütfen bir seviye seç.", true);
    return;
  }

  setLoading(true);
  setStatus(levelStatusEl, "", false);

  try {
    await persistOnboarding(accessToken, {
      learningLevel: selectedLevel,
      onboardingCompleted: false
    });

    window.location.href = "/tutorial-step2.html";
  } catch (error) {
    setStatus(levelStatusEl, error?.message || "Kayıt başarısız.", true);
  } finally {
    setLoading(false);
  }
});

async function init() {
  setOnboardingRoute("/onboarding-level.html");
  const context = await initOnboardingContext();
  if (!context?.session?.access_token) {
    return;
  }

  accessToken = context.session.access_token;
  selectedLevel = context.draft.learningLevel || "";
  renderCards();
}

await init();
