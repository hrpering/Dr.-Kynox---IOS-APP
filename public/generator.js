import { fetchMyProfile, getCachedProfile, getCurrentSession, setCachedProfile } from "/auth-common.js";
import {
  clearCaseResult,
  clearPendingChallenge,
  createCaseSession,
  loadPendingChallenge,
  saveCaseSession
} from "/session-core.js";

const goBackBtn = document.getElementById("goBackBtn");
const generateCaseBtn = document.getElementById("generateCaseBtn");
const modeCards = Array.from(document.querySelectorAll(".mode-card"));
const difficultyChips = Array.from(document.querySelectorAll('.pref-chip[data-type="difficulty"]'));
const specialtySelectEl = document.getElementById("specialtySelect");
const selectedDifficultyBadgeEl = document.getElementById("selectedDifficultyBadge");
const preferenceLockedTextEl = document.getElementById("preferenceLockedText");
const generatorPageTitleEl = document.getElementById("generatorPageTitle");
const generatorHeroTitleEl = document.getElementById("generatorHeroTitle");
const generatorHeroTextEl = document.getElementById("generatorHeroText");
const generatorInfoTextEl = document.getElementById("generatorInfoText");
const generatorWarnTextEl = document.getElementById("generatorWarnText");

const MODE_PREF_KEY = "preferred_case_mode_v1";
const SPECIALTY_OPTIONS = [
  "Kardiyoloji",
  "Göğüs Hastalıkları",
  "Gastroenteroloji",
  "Endokrinoloji",
  "Nefroloji",
  "Enfeksiyon Hastalıkları",
  "Romatoloji",
  "Hematoloji",
  "Onkoloji",
  "Acil Tıp",
  "Yoğun Bakım",
  "Nöroloji",
  "Psikiyatri",
  "Nörokritik Bakım - Toksikoloji",
  "Genel Cerrahi",
  "Damar Cerrahisi",
  "Kardiyotorasik Cerrahi",
  "Beyin ve Sinir Cerrahisi",
  "Ortopedi ve Travmatoloji",
  "Plastik Cerrahi",
  "Travma Cerrahisi",
  "Obstetri",
  "Jinekoloji",
  "Genel Pediatri",
  "Çocuk Acil",
  "Dermatoloji",
  "Neonatoloji",
  "Göz Hastalıkları",
  "Kulak Burun Boğaz (KBB)",
  "Geriatri",
  "Üroloji"
];

const SPECIALTY_ALIAS_MAP = {
  cardiology: "Kardiyoloji",
  pulmonology: "Göğüs Hastalıkları",
  "gogus hastaliklari": "Göğüs Hastalıkları",
  gastroenterology: "Gastroenteroloji",
  endocrinology: "Endokrinoloji",
  nephrology: "Nefroloji",
  "infectious diseases": "Enfeksiyon Hastalıkları",
  rheumatology: "Romatoloji",
  hematology: "Hematoloji",
  oncology: "Onkoloji",
  "emergency medicine": "Acil Tıp",
  "critical care medicine": "Yoğun Bakım",
  neurology: "Nöroloji",
  psychiatry: "Psikiyatri",
  "neurocritical care toxicology": "Nörokritik Bakım - Toksikoloji",
  "general surgery": "Genel Cerrahi",
  "vascular surgery": "Damar Cerrahisi",
  "cardiothoracic surgery": "Kardiyotorasik Cerrahi",
  neurosurgery: "Beyin ve Sinir Cerrahisi",
  "orthopedic surgery": "Ortopedi ve Travmatoloji",
  "plastic surgery": "Plastik Cerrahi",
  "trauma surgery": "Travma Cerrahisi",
  obstetrics: "Obstetri",
  gynecology: "Jinekoloji",
  "general pediatrics": "Genel Pediatri",
  "pediatric emergency": "Çocuk Acil",
  dermatology: "Dermatoloji",
  neonatology: "Neonatoloji",
  ophthalmology: "Göz Hastalıkları",
  "otolaryngology ent": "Kulak Burun Boğaz (KBB)",
  "geriatric medicine": "Geriatri",
  urology: "Üroloji",
  "genel tip": "Kardiyoloji",
  "general medicine": "Kardiyoloji",
  surgery: "Genel Cerrahi"
};

let selectedMode = "voice";
let preferredDifficulty = "Random";
let preferredSpecialty = "Kardiyoloji";
let selectedDifficulty = "Random";
let selectedSpecialty = "Kardiyoloji";
let pendingChallenge = null;
let preferencesLocked = false;
let hasManualPreferenceSelection = false;

function simplifyText(input) {
  return String(input || "")
    .trim()
    .toLocaleLowerCase("tr-TR")
    .replace(/ı/g, "i")
    .replace(/ğ/g, "g")
    .replace(/ü/g, "u")
    .replace(/ş/g, "s")
    .replace(/ö/g, "o")
    .replace(/ç/g, "c")
    .replace(/[()]/g, " ")
    .replace(/\s+/g, " ");
}

function buildSpecialtyOptions() {
  if (!specialtySelectEl) {
    return;
  }
  specialtySelectEl.innerHTML = "";
  SPECIALTY_OPTIONS.forEach((name) => {
    const option = document.createElement("option");
    option.value = name;
    option.textContent = name;
    specialtySelectEl.append(option);
  });
}

function ensureSpecialtyOption(value) {
  const safe = String(value || "").trim();
  if (!safe || !specialtySelectEl) {
    return;
  }
  const exists = Array.from(specialtySelectEl.options).some((opt) => opt.value === safe);
  if (exists) {
    return;
  }
  const option = document.createElement("option");
  option.value = safe;
  option.textContent = safe;
  specialtySelectEl.append(option);
}

function normalizeSpecialty(rawValue) {
  const value = String(rawValue || "").trim();
  if (!value) {
    return "Kardiyoloji";
  }

  if (SPECIALTY_OPTIONS.includes(value)) {
    return value;
  }

  const simple = simplifyText(value);
  const alias = SPECIALTY_ALIAS_MAP[simple];
  if (alias) {
    return alias;
  }

  const matched = SPECIALTY_OPTIONS.find((item) => simplifyText(item) === simple);
  return matched || "Kardiyoloji";
}

function normalizeDifficulty(rawValue) {
  const value = String(rawValue || "").trim();
  if (!value) {
    return "Random";
  }

  const simple = simplifyText(value);
  if (simple === "random" || simple.includes("uyarlanabilir") || simple.includes("adaptive")) {
    return "Random";
  }
  if (simple.includes("kolay") || simple.includes("beginner") || simple.includes("easy")) {
    return "Kolay";
  }
  if (simple.includes("orta") || simple.includes("intermediate") || simple.includes("medium")) {
    return "Orta";
  }
  if (simple.includes("zor") || simple.includes("ileri") || simple.includes("advanced") || simple.includes("hard")) {
    return "Zor";
  }

  return "Random";
}

function renderPreferenceSelection() {
  difficultyChips.forEach((chip) => {
    const value = String(chip.dataset.value || "").trim();
    const selected = value === selectedDifficulty;
    chip.classList.toggle("selected", selected);
    chip.setAttribute("aria-pressed", selected ? "true" : "false");
    chip.disabled = preferencesLocked;
  });

  if (selectedDifficultyBadgeEl) {
    selectedDifficultyBadgeEl.textContent = selectedDifficulty;
  }

  ensureSpecialtyOption(selectedSpecialty);
  if (specialtySelectEl) {
    specialtySelectEl.value = selectedSpecialty;
    specialtySelectEl.disabled = preferencesLocked;
  }

  if (preferenceLockedTextEl) {
    preferenceLockedTextEl.hidden = !preferencesLocked;
  }
}

function setPreference(type, value) {
  if (preferencesLocked) {
    return;
  }

  hasManualPreferenceSelection = true;
  if (type === "specialty") {
    selectedSpecialty = normalizeSpecialty(value);
  } else if (type === "difficulty") {
    selectedDifficulty = normalizeDifficulty(value);
  }
  renderPreferenceSelection();
}

function applyPreferenceDefaults(force = false) {
  if (hasManualPreferenceSelection && !force) {
    return;
  }

  selectedSpecialty = normalizeSpecialty(preferredSpecialty);
  selectedDifficulty = normalizeDifficulty(preferredDifficulty);
  renderPreferenceSelection();
}

function lockPreferences(specialty, difficulty) {
  preferencesLocked = true;
  selectedSpecialty = normalizeSpecialty(specialty || "Kardiyoloji");
  selectedDifficulty = normalizeDifficulty(difficulty || "Random");
  renderPreferenceSelection();
}

async function preloadCasePreferences() {
  if (pendingChallenge) {
    preferredDifficulty = pendingChallenge.difficulty || preferredDifficulty;
    preferredSpecialty = pendingChallenge.specialty || preferredSpecialty;
    lockPreferences(preferredSpecialty, preferredDifficulty);
    return;
  }

  try {
    const cachedProfile = getCachedProfile();
    if (cachedProfile && Array.isArray(cachedProfile.interest_areas) && cachedProfile.interest_areas.length) {
      preferredSpecialty = cachedProfile.interest_areas[0];
    }

    const session = await getCurrentSession();
    if (session?.access_token) {
      const profile = await fetchMyProfile(session.access_token).catch(() => null);
      if (profile) {
        setCachedProfile(profile);
        if (Array.isArray(profile.interest_areas) && profile.interest_areas.length) {
          preferredSpecialty = profile.interest_areas[0];
        }
      }
    }
  } catch {
    // Profil bilgisi alınamazsa varsayılanlarla devam et.
  }

  applyPreferenceDefaults();
}

function normalizePendingChallenge(raw) {
  if (!raw || typeof raw !== "object") {
    return null;
  }
  const id = String(raw.id || "").trim();
  const title = String(raw.title || "").trim();
  if (!id || !title) {
    return null;
  }

  return {
    id,
    title,
    summary: String(raw.summary || "").trim(),
    specialty: normalizeSpecialty(raw.specialty),
    difficulty: normalizeDifficulty(raw.difficulty),
    chiefComplaint: String(raw.chiefComplaint || "").trim() || null,
    patientGender: String(raw.patientGender || "").trim() || null,
    patientAge: Number(raw.patientAge) || null,
    expectedDiagnosis: String(raw.expectedDiagnosis || "").trim() || null,
    agentSeedPrompt: String(raw.agentSeedPrompt || "").trim() || "",
    challengeType: String(raw.challengeType || "daily").trim() || "daily"
  };
}

function applyChallengeUi() {
  if (!pendingChallenge) {
    return;
  }

  generatorPageTitleEl.textContent = "Bugünün Vaka Meydan Okuması";
  generatorHeroTitleEl.textContent = pendingChallenge.title;
  generatorHeroTextEl.textContent =
    pendingChallenge.summary ||
    `${pendingChallenge.specialty} · ${pendingChallenge.difficulty} ortak günlük vaka meydan okuması.`;
  generatorInfoTextEl.textContent = `Bölüm: ${pendingChallenge.specialty} · Zorluk: ${pendingChallenge.difficulty}`;
  generatorWarnTextEl.textContent = "Bu meydan okuma tüm kullanıcılara aynı vaka olarak sunulur.";
  generateCaseBtn.textContent = "Meydan Okumayı Başlat";

  lockPreferences(pendingChallenge.specialty, pendingChallenge.difficulty);
}

function setSelectedMode(mode) {
  selectedMode = mode === "text" ? "text" : "voice";
  try {
    localStorage.setItem(MODE_PREF_KEY, selectedMode);
  } catch {
    // localStorage kullanılamazsa sessizce devam et.
  }
  modeCards.forEach((card) => {
    const isSelected = card.dataset.mode === selectedMode;
    card.classList.toggle("selected", isSelected);
  });
}

modeCards.forEach((card) => {
  card.addEventListener("click", () => {
    setSelectedMode(card.dataset.mode);
  });
});

difficultyChips.forEach((chip) => {
  chip.addEventListener("click", () => {
    setPreference("difficulty", chip.dataset.value);
  });
});

specialtySelectEl?.addEventListener("change", () => {
  setPreference("specialty", specialtySelectEl.value);
});

generateCaseBtn.addEventListener("click", () => {
  clearCaseResult();
  const session = pendingChallenge
    ? createCaseSession(selectedMode, {
        difficulty: pendingChallenge.difficulty,
        specialty: pendingChallenge.specialty,
        patientGender: pendingChallenge.patientGender,
        patientAge: pendingChallenge.patientAge,
        chiefComplaint: pendingChallenge.chiefComplaint,
        challengeType: pendingChallenge.challengeType || "daily",
        challengeId: pendingChallenge.id,
        challengeTitle: pendingChallenge.title,
        challengeSummary: pendingChallenge.summary,
        expectedDiagnosis: pendingChallenge.expectedDiagnosis,
        agentSeedPrompt: pendingChallenge.agentSeedPrompt
      })
    : createCaseSession(selectedMode, {
        difficulty: selectedDifficulty,
        specialty: selectedSpecialty,
        challengeType: "random",
        challengeId: null,
        challengeTitle: null,
        challengeSummary: null,
        expectedDiagnosis: null,
        patientGender: null,
        patientAge: null,
        chiefComplaint: null,
        agentSeedPrompt: null
      });
  clearPendingChallenge();
  saveCaseSession(session);
  window.location.href = selectedMode === "text" ? "/text.html" : "/voice.html";
});

goBackBtn.addEventListener("click", () => {
  clearPendingChallenge();
  window.location.replace("/index.html");
});

try {
  const preferred = String(localStorage.getItem(MODE_PREF_KEY) || "").trim().toLowerCase();
  if (preferred === "text" || preferred === "voice") {
    selectedMode = preferred;
  }
} catch {
  // localStorage kullanılamazsa varsayılan mod ile devam et.
}

pendingChallenge = normalizePendingChallenge(loadPendingChallenge());
buildSpecialtyOptions();
setSelectedMode(selectedMode);
applyPreferenceDefaults(true);
applyChallengeUi();
void preloadCasePreferences();
