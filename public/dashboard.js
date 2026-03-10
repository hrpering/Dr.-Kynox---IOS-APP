import {
  fetchCaseList,
  fetchMyProfile,
  getCachedCaseList,
  getCachedProfile,
  requireAuth,
  setCachedCaseList,
  setCachedProfile
} from "/auth-common.js";
import { clearCaseResult, clearPendingChallenge, saveCaseResult, savePendingChallenge } from "/session-core.js";

const dashboardNameEl = document.getElementById("dashboardName");
const dashboardGreetingEl = document.getElementById("dashboardGreeting");
const dashboardMainEl = document.getElementById("dashboardMain");
const streakTitleEl = document.getElementById("streakTitle");
const streakTextEl = document.getElementById("streakText");
const streakBarEl = document.getElementById("streakBar");
const challengeSpecialtyTagEl = document.getElementById("challengeSpecialtyTag");
const challengeDifficultyTagEl = document.getElementById("challengeDifficultyTag");
const challengeTextEl = document.getElementById("challengeText");
const challengeTimeLeftEl = document.getElementById("challengeTimeLeft");
const challengeDurationEl = document.getElementById("challengeDuration");
const challengeBonusEl = document.getElementById("challengeBonus");
const challengeParticipantsEl = document.getElementById("challengeParticipants");
const challengeAverageEl = document.getElementById("challengeAverage");
const casesCompletedValueEl = document.getElementById("casesCompletedValue");
const casesCompletedSubEl = document.getElementById("casesCompletedSub");
const accuracyValueEl = document.getElementById("accuracyValue");
const accuracySubEl = document.getElementById("accuracySub");
const continueLearningListEl = document.getElementById("continueLearningList");
const dashboardSearchInputEl = document.getElementById("dashboardSearchInput");

const openGeneratorBtn = document.getElementById("openGeneratorBtn");
const startChallengeBtn = document.getElementById("startChallengeBtn");
const openHistoryBtn = document.getElementById("openHistoryBtn");
const openHistoryBtn2 = document.getElementById("openHistoryBtn2");
const casesNavBtn = document.getElementById("casesNavBtn");
const newCaseNavBtn = document.getElementById("newCaseNavBtn");
const statsNavBtn = document.getElementById("statsNavBtn");
const profileNavBtn = document.getElementById("profileNavBtn");
const DASHBOARD_NAME_CACHE_KEY = "dashboard_name_cache_v1";
const DASHBOARD_SNAPSHOT_KEY = "dashboard_snapshot_v1";
const MODE_PREF_KEY = "preferred_case_mode_v1";
const CHALLENGE_CACHE_KEY = "daily_challenge_cache_v1";

let allCases = [];
let todaysChallenge = fallbackChallenge();
let isChallengeLoading = true;
let challengeCountdownTimer = null;

function applyDashboardData(profile, cases) {
  const safeCases = Array.isArray(cases) ? cases : [];
  allCases = safeCases;

  const cachedName = readCachedName();
  const resolvedName = firstName(profile?.full_name) || cachedName || "";
  dashboardNameEl.textContent = resolvedName;
  writeCachedName(resolvedName);
  renderGreetingByLocalTime();

  renderStreak(computeStreak(safeCases));
  renderProgress(safeCases);
  renderChallenge();
  renderContinueList(safeCases);

  writeDashboardSnapshot({
    name: dashboardNameEl.textContent || "",
    streakTitle: streakTitleEl.textContent || "",
    streakText: streakTextEl.textContent || "",
    challengeSpecialty: challengeSpecialtyTagEl.textContent || "",
    challengeDifficulty: challengeDifficultyTagEl.textContent || "",
    challengeText: challengeTextEl.textContent || "",
    challengeTimeLeft: challengeTimeLeftEl?.textContent || "",
    challengeDuration: challengeDurationEl?.textContent || "",
    challengeBonus: challengeBonusEl?.textContent || "",
    challengeParticipants: challengeParticipantsEl?.textContent || "",
    challengeAverage: challengeAverageEl?.textContent || "",
    casesCompletedValue: casesCompletedValueEl.textContent || "",
    casesCompletedSub: casesCompletedSubEl.textContent || "",
    accuracyValue: accuracyValueEl.textContent || "",
    accuracySub: accuracySubEl.textContent || ""
  });
}

function localGreetingLabel(date = new Date()) {
  const hour = date.getHours();
  if (hour >= 5 && hour < 12) {
    return "Günaydın,";
  }
  if (hour >= 12 && hour < 18) {
    return "İyi günler,";
  }
  if (hour >= 18 && hour < 22) {
    return "İyi akşamlar,";
  }
  return "İyi geceler,";
}

function renderGreetingByLocalTime() {
  if (!dashboardGreetingEl) {
    return;
  }
  dashboardGreetingEl.textContent = localGreetingLabel(new Date());
}

function readCachedName() {
  try {
    return String(localStorage.getItem(DASHBOARD_NAME_CACHE_KEY) || "").trim();
  } catch {
    return "";
  }
}

function writeCachedName(name) {
  const safe = String(name || "").trim();
  if (!safe) {
    return;
  }
  try {
    localStorage.setItem(DASHBOARD_NAME_CACHE_KEY, safe);
  } catch {
    // localStorage kapaliysa sessizce geç.
  }
}

function writeDashboardSnapshot(snapshot) {
  if (!snapshot || typeof snapshot !== "object") {
    return;
  }
  try {
    localStorage.setItem(
      DASHBOARD_SNAPSHOT_KEY,
      JSON.stringify({
        ...snapshot,
        updatedAt: new Date().toISOString()
      })
    );
  } catch {
    // localStorage kapaliysa sessizce geç.
  }
}

function firstName(fullName) {
  const txt = String(fullName || "").trim();
  if (!txt) {
    return "";
  }
  return txt.split(/\s+/)[0] || txt;
}

function getPreferredMode() {
  try {
    const value = String(localStorage.getItem(MODE_PREF_KEY) || "").trim().toLowerCase();
    return value === "text" ? "text" : "voice";
  } catch {
    return "voice";
  }
}

function normalizeDifficultyLabel(input, fallback = "Orta") {
  const value = String(input || "")
    .trim()
    .toLocaleLowerCase("tr-TR");

  if (!value) {
    return fallback;
  }
  if (value.includes("random") || value.includes("uyarlanabilir") || value.includes("adaptive")) {
    return "Random";
  }
  if (value.includes("kolay") || value.includes("beginner") || value.includes("easy")) {
    return "Kolay";
  }
  if (value.includes("orta") || value.includes("intermediate") || value.includes("medium")) {
    return "Orta";
  }
  if (value.includes("zor") || value.includes("ileri") || value.includes("advanced") || value.includes("hard")) {
    return "Zor";
  }
  return fallback;
}

function utcDateKey(dateLike = new Date()) {
  const dt = new Date(dateLike);
  if (!Number.isFinite(dt.getTime())) {
    return new Date().toISOString().slice(0, 10);
  }
  return dt.toISOString().slice(0, 10);
}

function addHoursIso(value, hours = 24) {
  const dt = new Date(value || Date.now());
  if (!Number.isFinite(dt.getTime())) {
    return new Date(Date.now() + Math.max(1, Number(hours) || 24) * 60 * 60 * 1000).toISOString();
  }
  dt.setTime(dt.getTime() + Math.max(1, Number(hours) || 24) * 60 * 60 * 1000);
  return dt.toISOString();
}

function fallbackChallenge() {
  const nowIso = new Date().toISOString();
  const templates = [
    {
      id: "fallback-cardiology-medium",
      title: "Göğüs Ağrısı Değerlendirmesi",
      summary: "Acil serviste göğüs ağrısı ile başvuran hastada sistematik yaklaşımı tamamla.",
      specialty: "Kardiyoloji",
      difficulty: "Orta",
      chiefComplaint: "Göğüs ağrısı",
      patientGender: "Erkek",
      patientAge: 55,
      expectedDiagnosis: "Akut koroner sendrom",
      agentSeedPrompt:
        "Vaka kurgusu ayarı: Kardiyoloji - Orta. Tanıyı en başta söyleme; anamnez, risk değerlendirmesi ve test sıralaması ile ilerle. Bu parametreler kesin, kullanıcıya bölüm/zorluk tekrar sorma.",
      durationMin: 15,
      bonusPoints: 50,
      stats: {
        attemptedUsers: 0,
        participantCount: 0,
        averageScore: null
      }
    },
    {
      id: "fallback-neuro-advanced",
      title: "Ani Nörolojik Defisit",
      summary: "Ani nörolojik yakınmalarla gelen hastada zaman penceresini kaçırmadan ilerle.",
      specialty: "Nöroloji",
      difficulty: "Zor",
      chiefComplaint: "Konuşma bozukluğu",
      patientGender: "Kadın",
      patientAge: 67,
      expectedDiagnosis: "Akut iskemik inme",
      agentSeedPrompt:
        "Vaka kurgusu ayarı: Nöroloji - Zor. Hızlı karar ver, kritik kırmızı bayrakları atlama. Bu parametreler kesin, kullanıcıya bölüm/zorluk tekrar sorma.",
      durationMin: 15,
      bonusPoints: 70,
      stats: {
        attemptedUsers: 0,
        participantCount: 0,
        averageScore: null
      }
    },
    {
      id: "fallback-surgery-easy",
      title: "Akut Karın Ön Değerlendirmesi",
      summary: "Akut karın ağrısı olan hastada ilk cerrahi değerlendirme adımlarını uygula.",
      specialty: "Genel Cerrahi",
      difficulty: "Kolay",
      chiefComplaint: "Karın ağrısı",
      patientGender: "Erkek",
      patientAge: 24,
      expectedDiagnosis: "Akut appendisit",
      agentSeedPrompt:
        "Vaka kurgusu ayarı: Genel Cerrahi - Kolay. Adım adım anamnez ve fizik muayene ile ilerle. Bu parametreler kesin, kullanıcıya bölüm/zorluk tekrar sorma.",
      durationMin: 15,
      bonusPoints: 40,
      stats: {
        attemptedUsers: 0,
        participantCount: 0,
        averageScore: null
      }
    }
  ];
  const idx = Math.abs(hashCode(utcDateKey())) % templates.length;
  return {
    ...templates[idx],
    generatedAt: nowIso,
    expiresAt: addHoursIso(nowIso, 24),
    mode: getPreferredMode()
  };
}

function hashCode(text) {
  let hash = 0;
  const value = String(text || "");
  for (let i = 0; i < value.length; i += 1) {
    hash = (hash * 31 + value.charCodeAt(i)) % 2147483647;
  }
  return hash;
}

function normalizeChallengePayload(body) {
  const source = body && typeof body === "object" ? body : {};
  const challenge = source.challenge && typeof source.challenge === "object" ? source.challenge : {};
  const stats = source.stats && typeof source.stats === "object" ? source.stats : {};
  const generatedAt = String(challenge.generatedAt || challenge.generated_at || "").trim() || new Date().toISOString();
  const expiresAt = String(challenge.expiresAt || challenge.expires_at || "").trim() || addHoursIso(generatedAt, 24);

  return {
    id: String(challenge.id || "").trim() || `daily-${utcDateKey()}-fallback`,
    mode: getPreferredMode(),
    title: String(challenge.title || "").trim() || "Bugünün Vaka Meydan Okuması",
    summary: String(challenge.summary || "").trim() || "Bugünün ortak vakasını başlat.",
    specialty: String(challenge.specialty || "").trim() || "Genel Tıp",
    difficulty: normalizeDifficultyLabel(challenge.difficulty, "Orta"),
    chiefComplaint: String(challenge.chiefComplaint || "").trim() || "Başvuru şikayeti oturumda paylaşılacak",
    patientGender: String(challenge.patientGender || "").trim() || null,
    patientAge: Number(challenge.patientAge) || null,
    expectedDiagnosis: String(challenge.expectedDiagnosis || "").trim() || null,
    agentSeedPrompt: String(challenge.agentSeedPrompt || "").trim() || "",
    durationMin: Number(challenge.durationMin) || 15,
    bonusPoints: Number(challenge.bonusPoints) || 50,
    generatedAt,
    expiresAt,
    stats: {
      attemptedUsers: Number(stats.attempted_users) || Number(stats.attemptedUsers) || 0,
      participantCount: Number(stats.participant_count) || Number(stats.participantCount) || 0,
      averageScore:
        Number.isFinite(Number(stats.average_score)) || Number.isFinite(Number(stats.averageScore))
          ? Number(stats.average_score ?? stats.averageScore)
          : null
    },
    dateKey: String(challenge.dateKey || source.date_key || utcDateKey()).trim() || utcDateKey()
  };
}

function readCachedChallenge() {
  try {
    const raw = localStorage.getItem(CHALLENGE_CACHE_KEY);
    if (!raw) {
      return null;
    }
    const parsed = JSON.parse(raw);
    if (!parsed || typeof parsed !== "object") {
      return null;
    }
    const expiresAt = new Date(parsed.expiresAt || 0).getTime();
    if (!Number.isFinite(expiresAt) || expiresAt <= Date.now()) {
      return null;
    }
    return parsed;
  } catch {
    return null;
  }
}

function writeCachedChallenge(challenge) {
  if (!challenge || typeof challenge !== "object") {
    return;
  }
  try {
    localStorage.setItem(CHALLENGE_CACHE_KEY, JSON.stringify(challenge));
  } catch {
    // localStorage engelliyse sessizce devam.
  }
}

async function fetchTodayChallenge() {
  const response = await fetch("/api/challenge/today");
  const body = await response.json().catch(() => ({}));
  if (!response.ok) {
    throw new Error(body?.error || "CHALLENGE_FETCH_FAILED");
  }
  return normalizeChallengePayload(body);
}

async function resetTodayChallengeNow(resetToken = "") {
  const headers = { "Content-Type": "application/json" };
  const token = String(resetToken || "").trim();
  if (token) {
    headers["x-challenge-reset-token"] = token;
  }

  const response = await fetch("/api/challenge/today/reset", {
    method: "POST",
    headers,
    body: token ? JSON.stringify({ resetToken: token }) : "{}"
  });
  const body = await response.json().catch(() => ({}));
  if (!response.ok) {
    throw new Error(body?.error || "CHALLENGE_RESET_FAILED");
  }
  return normalizeChallengePayload(body);
}

function toDateOnlyIso(value) {
  if (!value) {
    return null;
  }
  const d = new Date(value);
  if (!Number.isFinite(d.getTime())) {
    return null;
  }
  return d.toISOString().slice(0, 10);
}

function computeStreak(cases) {
  const dateSet = new Set(
    cases
      .map((item) => toDateOnlyIso(item.ended_at || item.updated_at || item.started_at))
      .filter(Boolean)
  );

  if (!dateSet.size) {
    return 0;
  }

  let streak = 0;
  const cursor = new Date();
  cursor.setHours(0, 0, 0, 0);

  while (streak < 30) {
    const key = cursor.toISOString().slice(0, 10);
    if (!dateSet.has(key)) {
      break;
    }
    streak += 1;
    cursor.setDate(cursor.getDate() - 1);
  }

  return streak;
}

function renderStreak(streak) {
  streakTitleEl.textContent = `${streak || 0} Gün Seri!`;
  streakTextEl.textContent = streak > 0 ? "Harika gidiyorsun, devam et." : "İlk vakanı tamamlayarak seriyi başlat.";

  streakBarEl.innerHTML = "";
  const slots = 7;
  for (let i = 0; i < slots; i += 1) {
    const dot = document.createElement("span");
    dot.className = "streak-dot";
    if (i < Math.min(streak, slots)) {
      dot.classList.add("active");
    }
    streakBarEl.append(dot);
  }
}

function formatCompletion(item) {
  if (item?.status === "ready" && item?.score?.overall_score != null) {
    return "Tamamlandı";
  }
  if (item?.status === "pending") {
    return "Skor bekleniyor";
  }
  if (item?.status === "no_data") {
    return "Yetersiz veri";
  }
  return "Devam ediyor";
}

function safeTitle(item) {
  return item?.case_context?.title || "Oluşturulan Klinik Vaka";
}

function safeSpecialty(item) {
  return item?.case_context?.specialty || "Genel Tıp";
}

function openCaseFromHistory(item) {
  const payload = {
    status: item.status || "ready",
    sessionId: item.session_id || `case_${Date.now()}`,
    mode: item.mode === "text" ? "text" : "voice",
    startedAt: item.started_at || item.updated_at || new Date().toISOString(),
    endedAt: item.ended_at || item.updated_at || new Date().toISOString(),
    durationMin: Number(item.duration_min) || 1,
    messageCount: Number(item.message_count) || 0,
    difficulty: normalizeDifficultyLabel(item.difficulty, "Random"),
    transcript: Array.isArray(item.transcript) ? item.transcript : [],
    caseContext: item.case_context || {
      title: safeTitle(item),
      specialty: safeSpecialty(item),
      subtitle: "Geçmiş vaka kaydı"
    },
    score: item.score || null
  };

  saveCaseResult(payload);
  window.location.href = "/case-results.html";
}

function renderContinueList(filtered) {
  continueLearningListEl.innerHTML = "";

  const list = filtered.slice(0, 4);
  if (!list.length) {
    const empty = document.createElement("p");
    empty.className = "continue-empty";
    empty.textContent = "Henüz kayıtlı vaka yok. Yeni bir vaka oluşturarak başla.";
    continueLearningListEl.append(empty);
    return;
  }

  list.forEach((item) => {
    const row = document.createElement("button");
    row.type = "button";
    row.className = "continue-item";

    const left = document.createElement("div");
    left.className = "continue-item-left";

    const icon = document.createElement("span");
    icon.className = "continue-item-icon";
    icon.textContent = safeSpecialty(item).slice(0, 2).toUpperCase();

    const text = document.createElement("div");
    const title = document.createElement("h4");
    title.textContent = safeTitle(item);

    const meta = document.createElement("p");
    const scoreText = item?.score?.overall_score != null ? `${Math.round(item.score.overall_score)} puan` : formatCompletion(item);
    meta.textContent = `${safeSpecialty(item)} · ${scoreText}`;

    text.append(title, meta);
    left.append(icon, text);

    const chevron = document.createElement("span");
    chevron.className = "continue-item-chevron";
    chevron.textContent = ">";

    row.append(left, chevron);
    row.addEventListener("click", () => openCaseFromHistory(item));
    continueLearningListEl.append(row);
  });
}

function renderProgress(cases) {
  const completed = cases.filter((item) => item?.status === "ready" && item?.score?.overall_score != null);
  const completedCount = completed.length;

  const now = Date.now();
  const weeklyCount = completed.filter((item) => {
    const time = new Date(item.ended_at || item.updated_at || item.started_at).getTime();
    return Number.isFinite(time) && now - time <= 7 * 24 * 60 * 60 * 1000;
  }).length;

  const average = completedCount
    ? Math.round(
        completed.reduce((acc, item) => acc + (Number(item?.score?.overall_score) || 0), 0) / completedCount
      )
    : 0;

  casesCompletedValueEl.textContent = String(completedCount);
  casesCompletedSubEl.textContent = `Bu hafta +${weeklyCount}`;
  accuracyValueEl.textContent = `${average}%`;
  accuracySubEl.textContent = completedCount ? "Skor ortalaması" : "Henüz skor verisi yok";
}

function clearChallengeCountdownTimer() {
  if (!challengeCountdownTimer) {
    return;
  }
  clearInterval(challengeCountdownTimer);
  challengeCountdownTimer = null;
}

function formatChallengeTimeLeft(expiresAt) {
  const endTs = new Date(expiresAt || 0).getTime();
  if (!Number.isFinite(endTs)) {
    return "Süre bilgisi yok";
  }
  const diffMs = endTs - Date.now();
  if (diffMs <= 0) {
    return "Süre doldu";
  }

  const hoursLeft = diffMs / (60 * 60 * 1000);
  if (hoursLeft < 1) {
    return "1 saatten az kaldı";
  }
  return `${Math.ceil(hoursLeft)} saat kaldı`;
}

async function refreshChallengeAfterExpiry() {
  if (isChallengeLoading) {
    return;
  }

  isChallengeLoading = true;
  if (startChallengeBtn) {
    startChallengeBtn.disabled = true;
    startChallengeBtn.textContent = "Yeni günlük vaka hazırlanıyor...";
  }

  try {
    const challenge = await fetchTodayChallenge();
    if (challenge) {
      challenge.mode = getPreferredMode();
      challenge.difficulty = normalizeDifficultyLabel(challenge.difficulty, "Orta");
      todaysChallenge = challenge;
      writeCachedChallenge(challenge);
    }
  } catch {
    // Hata durumunda mevcut challenge kartı korunur.
  } finally {
    isChallengeLoading = false;
    renderChallenge();
  }
}

function updateChallengeCountdown() {
  const challenge = todaysChallenge || fallbackChallenge();
  if (challengeTimeLeftEl) {
    challengeTimeLeftEl.textContent = formatChallengeTimeLeft(challenge.expiresAt);
  }
}

function startChallengeCountdown() {
  clearChallengeCountdownTimer();
  updateChallengeCountdown();

  challengeCountdownTimer = setInterval(() => {
    updateChallengeCountdown();
    const expiresTs = new Date(todaysChallenge?.expiresAt || 0).getTime();
    if (Number.isFinite(expiresTs) && expiresTs <= Date.now()) {
      clearChallengeCountdownTimer();
      void refreshChallengeAfterExpiry();
    }
  }, 30000);
}

function renderChallenge() {
  const challenge = todaysChallenge || fallbackChallenge();
  if (startChallengeBtn) {
    startChallengeBtn.disabled = false;
    startChallengeBtn.textContent = "Vakayı Başlat";
  }
  challengeSpecialtyTagEl.textContent = challenge.specialty;
  challengeDifficultyTagEl.textContent = normalizeDifficultyLabel(challenge.difficulty, "Orta");
  challengeTextEl.textContent = challenge.summary;
  if (challengeDurationEl) {
    challengeDurationEl.textContent = `Tahmini ${challenge.durationMin || 15} dk`;
  }
  if (challengeBonusEl) {
    challengeBonusEl.textContent = `+${challenge.bonusPoints || 50} puan`;
  }
  if (challengeParticipantsEl) {
    const doneCount = Number(challenge.stats?.attemptedUsers) || Number(challenge.stats?.participantCount) || 0;
    challengeParticipantsEl.textContent = `${doneCount} kişi yaptı`;
  }
  if (challengeAverageEl) {
    const avg = challenge.stats?.averageScore;
    challengeAverageEl.textContent = Number.isFinite(avg) ? `Ortalama: ${Math.round(avg)} puan` : "Ortalama: -";
  }
  startChallengeCountdown();
}

function filterCasesByQuery(cases, query) {
  const q = String(query || "").trim().toLowerCase();
  if (!q) {
    return cases;
  }
  return cases.filter((item) => {
    const hay = `${safeTitle(item)} ${safeSpecialty(item)} ${item?.difficulty || ""}`.toLowerCase();
    return hay.includes(q);
  });
}

function goHistory() {
  window.location.href = "/case-history.html";
}

function goProfile() {
  window.location.href = "/profile.html";
}

function goGenerator() {
  clearCaseResult();
  clearPendingChallenge();
  window.location.href = "/generator.html";
}

function startDailyChallenge() {
  if (!todaysChallenge && isChallengeLoading) {
    return;
  }
  clearCaseResult();
  const challenge = todaysChallenge || fallbackChallenge();
  savePendingChallenge({
    ...challenge,
    challengeType: "daily",
    mode: getPreferredMode()
  });
  window.location.href = "/generator.html";
}

openGeneratorBtn.addEventListener("click", goGenerator);
startChallengeBtn.addEventListener("click", startDailyChallenge);
openHistoryBtn.addEventListener("click", goHistory);
openHistoryBtn2.addEventListener("click", goHistory);
casesNavBtn.addEventListener("click", goHistory);
newCaseNavBtn.addEventListener("click", goGenerator);
statsNavBtn.addEventListener("click", goHistory);
profileNavBtn.addEventListener("click", goProfile);

dashboardSearchInputEl.addEventListener("input", () => {
  const filtered = filterCasesByQuery(allCases, dashboardSearchInputEl.value);
  renderContinueList(filtered);
});

async function initDashboard() {
  renderGreetingByLocalTime();
  const cachedChallenge = readCachedChallenge();
  if (cachedChallenge) {
    todaysChallenge = cachedChallenge;
    isChallengeLoading = false;
  } else {
    todaysChallenge = fallbackChallenge();
    isChallengeLoading = true;
  }
  renderChallenge();

  const cachedProfile = getCachedProfile();
  const cachedCases = getCachedCaseList(80);
  if (cachedProfile || cachedCases.length) {
    applyDashboardData(cachedProfile, cachedCases);
    dashboardMainEl?.classList.remove("is-loading");
    dashboardMainEl?.setAttribute("aria-busy", "false");
  }

  const session = await requireAuth("/login.html");
  if (!session?.access_token) {
    dashboardMainEl?.classList.remove("is-loading");
    dashboardMainEl?.setAttribute("aria-busy", "false");
    return;
  }

  const [profile, cases, challenge] = await Promise.all([
    fetchMyProfile(session.access_token).catch(() => null),
    fetchCaseList(session.access_token, 80).catch(() => []),
    fetchTodayChallenge().catch(() => null)
  ]);

  if (profile) {
    setCachedProfile(profile);
  }
  if (Array.isArray(cases)) {
    setCachedCaseList(cases);
  }
  if (challenge) {
    challenge.mode = getPreferredMode();
    challenge.difficulty = normalizeDifficultyLabel(challenge.difficulty, "Orta");
    todaysChallenge = challenge;
    isChallengeLoading = false;
    writeCachedChallenge(challenge);
    renderChallenge();
  } else {
    isChallengeLoading = false;
    renderChallenge();
  }

  applyDashboardData(profile || cachedProfile, Array.isArray(cases) ? cases : cachedCases);
  dashboardMainEl?.classList.remove("is-loading");
  dashboardMainEl?.setAttribute("aria-busy", "false");
}

window.resetDailyChallenge = async (token = "") => {
  const challenge = await resetTodayChallengeNow(token);
  challenge.mode = getPreferredMode();
  challenge.difficulty = normalizeDifficultyLabel(challenge.difficulty, "Orta");
  todaysChallenge = challenge;
  isChallengeLoading = false;
  writeCachedChallenge(challenge);
  renderChallenge();
  return challenge;
};

await initDashboard();

window.addEventListener("beforeunload", () => {
  clearChallengeCountdownTimer();
});
