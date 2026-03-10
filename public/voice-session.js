import { Conversation } from "https://cdn.jsdelivr.net/npm/@elevenlabs/client/+esm";
import {
  VOICE_AGENT_ID,
  addTranscriptMessage,
  buildCaseWrapupFromTranscript,
  ensureCaseSession,
  formatClock,
  getSessionBudgetState,
  hasSufficientEvidence,
  loadCaseResult,
  minutesBetween,
  saveCaseResult
} from "/session-core.js";
import { syncCaseResultToDb } from "/case-sync.js";
import {
  endElevenLabsSessionAuth,
  getElevenLabsSessionAuth,
  invalidateElevenLabsSessionAuth
} from "/elevenlabs-session-auth.js";
import { fetchMyProfile, getCachedProfile, getCurrentSession } from "/auth-common.js";

const backToGeneratorBtn = document.getElementById("backToGeneratorBtn");
const caseSpecialtyEl = document.getElementById("caseSpecialty");
const caseDifficultyEl = document.getElementById("caseDifficulty");
const patientLineEl = document.getElementById("patientLine");
const patientComplaintEl = document.getElementById("patientComplaint");
const listeningPillEl = document.getElementById("listeningPill");
const transcriptListEl = document.getElementById("voiceTranscriptList");
const voiceTypingIndicatorEl = document.getElementById("voiceTypingIndicator");
const voiceMessageCountEl = document.getElementById("voiceMessageCount");
const pauseBtn = document.getElementById("pauseBtn");
const micBtn = document.getElementById("micBtn");
const endVoiceCaseBtn = document.getElementById("endVoiceCaseBtn");
const voiceStatusLineEl = document.getElementById("voiceStatusLine");

const session = ensureCaseSession("voice");

let conversation = null;
let transcript = [];
let isCaseEnded = false;
let isSessionPaused = false;
let isMicPressed = false;
let micHoldRequested = false;
let isConnecting = false;
let reconnectAttempts = 0;
let reconnectTimer = null;
let disconnectIntent = "none";
let micReleaseTimer = null;
let pendingTranscriptEl = null;
let activeConnectionType = "webrtc";
let microphoneReadyPromise = null;
let syncTimer = null;
let lastDbSyncAt = 0;
let hasConnectedOnce = false;
let challengeSeedSent = false;
let caseConfigReminderAutoSent = false;
let resolvedUserName = "";
let caseFinalizeTimer = null;
let hasFinalizedCaseEnd = false;
let isAwaitingAiReply = false;
const hiddenSeedMessages = new Set();
const SPECIALTY_CANONICAL_MAP = {
  cardiology: "Cardiology",
  kardiyoloji: "Cardiology",
  pulmonology: "Pulmonology",
  "gogus hastaliklari": "Pulmonology",
  gastroenterology: "Gastroenterology",
  gastroenteroloji: "Gastroenterology",
  endocrinology: "Endocrinology",
  endokrinoloji: "Endocrinology",
  nephrology: "Nephrology",
  nefroloji: "Nephrology",
  "infectious diseases": "Infectious Diseases",
  "enfeksiyon hastaliklari": "Infectious Diseases",
  rheumatology: "Rheumatology",
  romatoloji: "Rheumatology",
  hematology: "Hematology",
  hematoloji: "Hematology",
  oncology: "Oncology",
  onkoloji: "Oncology",
  "emergency medicine": "Emergency Medicine",
  "acil tip": "Emergency Medicine",
  "critical care medicine": "Critical Care Medicine",
  "yogun bakim": "Critical Care Medicine",
  neurology: "Neurology",
  noroloji: "Neurology",
  psychiatry: "Psychiatry",
  psikiyatri: "Psychiatry",
  "neurocritical care toxicology": "Neurocritical Care-Toxicology",
  "norokritik bakim toksikoloji": "Neurocritical Care-Toxicology",
  "general surgery": "General Surgery",
  "genel cerrahi": "General Surgery",
  "vascular surgery": "Vascular Surgery",
  "damar cerrahisi": "Vascular Surgery",
  "cardiothoracic surgery": "Cardiothoracic Surgery",
  "kardiyotorasik cerrahi": "Cardiothoracic Surgery",
  neurosurgery: "Neurosurgery",
  "beyin ve sinir cerrahisi": "Neurosurgery",
  "orthopedic surgery": "Orthopedic Surgery",
  "ortopedi ve travmatoloji": "Orthopedic Surgery",
  "plastic surgery": "Plastic Surgery",
  "plastik cerrahi": "Plastic Surgery",
  "trauma surgery": "Trauma Surgery",
  "travma cerrahisi": "Trauma Surgery",
  obstetrics: "Obstetrics",
  obstetri: "Obstetrics",
  gynecology: "Gynecology",
  jinekoloji: "Gynecology",
  "general pediatrics": "General Pediatrics",
  "genel pediatri": "General Pediatrics",
  "pediatric emergency": "Pediatric Emergency",
  "cocuk acil": "Pediatric Emergency",
  dermatology: "Dermatology",
  dermatoloji: "Dermatology",
  neonatology: "Neonatology",
  neonatoloji: "Neonatology",
  ophthalmology: "Ophthalmology",
  "goz hastaliklari": "Ophthalmology",
  "otolaryngology ent": "Otolaryngology (ENT)",
  "kulak burun bogaz kbb": "Otolaryngology (ENT)",
  "geriatric medicine": "Geriatric Medicine",
  geriatri: "Geriatric Medicine",
  urology: "Urology",
  uroloji: "Urology"
};

const MAX_RECONNECT_ATTEMPTS = 8;
const RECONNECT_DELAYS_MS = [700, 1200, 1800, 2600, 3800, 5200, 7000, 9000];
const LIVE_SYNC_DEBOUNCE_MS = 1800;
const LIVE_DB_SYNC_INTERVAL_MS = 5000;

function resetSeedDispatchState() {
  challengeSeedSent = false;
  caseConfigReminderAutoSent = false;
  hiddenSeedMessages.clear();
}

function sanitizeTranscript(list) {
  if (!Array.isArray(list)) {
    return [];
  }
  return list
    .filter((item) => item && typeof item.message === "string" && item.message.trim())
    .map((item) => ({
      source: item.source === "user" ? "user" : "ai",
      message: item.message.trim(),
      timestamp: Number(item.timestamp) || Date.now(),
      eventId: item.eventId || null
    }));
}

function restoreTranscriptFromSavedState() {
  const previous = loadCaseResult();
  if (
    !previous ||
    previous.sessionId !== session.id ||
    previous.mode !== "voice" ||
    previous.score ||
    !Array.isArray(previous.transcript)
  ) {
    return;
  }

  transcript = sanitizeTranscript(previous.transcript);
}

function buildSessionPayload(status = "in_progress", endedAt = null) {
  const hasEnoughData = hasSufficientEvidence(transcript);
  const challengeId = String(session.caseData?.challengeId || "").trim();
  const challengeType = String(session.caseData?.challengeType || "").trim();
  const challengeWrapup = buildChallengeWrapup();
  const transcriptWrapup = buildCaseWrapupFromTranscript(transcript);
  const optionalCaseWrapup = [challengeWrapup, transcriptWrapup].filter(Boolean).join(" ").trim();
  const normalizedStatus =
    status === "ready" ||
    status === "no_data" ||
    status === "pending" ||
    status === "in_progress"
      ? status
      : hasEnoughData
        ? "in_progress"
        : "no_data";

  return {
    status: normalizedStatus,
    sessionId: session.id,
    mode: "voice",
    startedAt: session.createdAt,
    endedAt: endedAt || null,
    durationMin: minutesBetween(session.createdAt, endedAt || Date.now()),
    messageCount: transcript.length,
    difficulty: session.caseData?.difficulty || "Random",
    challengeId: challengeId || null,
    challengeType: challengeType || null,
    transcript: transcript.map((item) => ({
      source: item.source,
      message: item.message,
      timestamp: item.timestamp
    })),
    caseContext: {
      title: resolveCaseTitle(),
      specialty: session.caseData?.specialty || "Genel Tıp",
      challenge_id: challengeId || null,
      challenge_type: challengeType || null,
      expected_diagnosis: session.caseData?.expectedDiagnosis || null,
      subtitle:
        normalizedStatus === "pending"
          ? "Skor ve geri bildirim hazırlanıyor."
          : session.caseData?.challengeSummary || "Görüşme devam ediyor."
    },
    optionalCaseWrapup,
    score: null
  };
}

function clearSyncTimer() {
  if (syncTimer) {
    clearTimeout(syncTimer);
    syncTimer = null;
  }
}

function scheduleProgressSync(forceDb = false) {
  if (isCaseEnded) {
    return;
  }
  clearSyncTimer();
  syncTimer = setTimeout(() => {
    const payload = buildSessionPayload("in_progress");
    saveCaseResult(payload);

    const now = Date.now();
    if (forceDb || now - lastDbSyncAt >= LIVE_DB_SYNC_INTERVAL_MS) {
      lastDbSyncAt = now;
      void syncCaseResultToDb(payload);
    }
  }, LIVE_SYNC_DEBOUNCE_MS);
}

async function ensureMicrophoneReady() {
  if (!microphoneReadyPromise) {
    microphoneReadyPromise = navigator.mediaDevices.getUserMedia({ audio: true });
  }
  try {
    await microphoneReadyPromise;
  } catch (error) {
    microphoneReadyPromise = null;
    throw error;
  }
}

function normalizeForHiddenCompare(input) {
  return String(input || "")
    .toLocaleLowerCase("tr-TR")
    .replace(/\s+/g, " ")
    .trim();
}

function normalizeToken(input) {
  return String(input || "")
    .trim()
    .toLocaleLowerCase("tr-TR")
    .normalize("NFD")
    .replace(/[\u0300-\u036f]/g, "")
    .replace(/[^a-z0-9]+/g, " ")
    .replace(/\s+/g, " ")
    .trim();
}

function toCanonicalSpecialty(input) {
  const raw = String(input || "").trim();
  if (!raw) {
    return "";
  }
  const mapped = SPECIALTY_CANONICAL_MAP[normalizeToken(raw)];
  return mapped || raw;
}

function normalizeDifficultyForAgent(input) {
  const raw = String(input || "").trim();
  const token = normalizeToken(raw);
  if (!token || token === "random" || token.includes("uyarlanabilir") || token.includes("adaptive")) {
    return "Random";
  }
  if (token.includes("kolay") || token.includes("easy") || token.includes("beginner")) {
    return "Kolay";
  }
  if (token.includes("orta") || token.includes("medium") || token.includes("intermediate")) {
    return "Orta";
  }
  if (token.includes("zor") || token.includes("hard") || token.includes("advanced") || token.includes("ileri")) {
    return "Zor";
  }
  return raw || "Random";
}

function normalizeUserName(input) {
  const compact = String(input || "")
    .replace(/\s+/g, " ")
    .trim()
    .slice(0, 80);
  if (!compact) {
    return "";
  }
  return compact.split(" ")[0].trim().slice(0, 40);
}

async function resolveUserNameForAgent() {
  if (resolvedUserName) {
    return resolvedUserName;
  }

  const cached = getCachedProfile();
  const cachedName = normalizeUserName(cached?.full_name);
  if (cachedName) {
    resolvedUserName = cachedName;
    return resolvedUserName;
  }

  try {
    const sessionData = await getCurrentSession();
    if (sessionData?.access_token) {
      const profile = await fetchMyProfile(sessionData.access_token).catch(() => null);
      const remoteName = normalizeUserName(profile?.full_name);
      if (remoteName) {
        resolvedUserName = remoteName;
        return resolvedUserName;
      }
    }
  } catch {
    // Profil okunamazsa adsız devam et.
  }

  return "";
}

function rememberHiddenSeedMessage(message) {
  const normalized = normalizeForHiddenCompare(message);
  if (!normalized) {
    return;
  }
  hiddenSeedMessages.add(normalized);
}

function isHiddenSeedMessage(message) {
  const normalized = normalizeForHiddenCompare(message);
  if (!normalized) {
    return false;
  }
  if (hiddenSeedMessages.has(normalized)) {
    return true;
  }
  return (
    normalized.startsWith("vaka kurgusu ayarı") ||
    normalized.startsWith("bugünün vaka meydan okuması ayarları") ||
    normalized.startsWith("bugunun vaka meydan okumasi ayarlari") ||
    normalized.startsWith("uygulama_vaka_parametreleri")
  );
}

function resolveCaseTitle() {
  const caseData = session.caseData || {};
  return caseData.challengeTitle || "Vaka Analizi";
}

function buildChallengeWrapup() {
  const expected = String(session.caseData?.expectedDiagnosis || "").trim();
  if (!expected) {
    return "";
  }
  return `Meydan okuma notu: Bu vakadaki doğru tanı ${expected}.`;
}

function buildChallengeSeedPrompt() {
  const caseData = session.caseData || {};
  const challengeType = String(caseData.challengeType || "random").trim() || "random";
  const rawSpecialty = String(caseData.specialty || "").trim();
  const rawDifficulty = String(caseData.difficulty || "Random").trim();
  const specialty = toCanonicalSpecialty(rawSpecialty);
  const difficulty = normalizeDifficultyForAgent(rawDifficulty);
  const explicitSeedPrompt = String(caseData.agentSeedPrompt || "").trim();
  const challengeTitle = String(caseData.challengeTitle || "").trim();
  const chiefComplaint = String(caseData.chiefComplaint || "").trim();
  const expectedDiagnosis = String(caseData.expectedDiagnosis || "").trim();
  const patientGender = String(caseData.patientGender || "").trim();
  const patientAge = Number(caseData.patientAge);
  const patientInfo =
    patientGender || Number.isFinite(patientAge)
      ? `${patientGender || "Belirtilmedi"}, ${Number.isFinite(patientAge) ? `${patientAge} yaş` : "yaş belirtilmedi"}`
      : "Belirtilmedi";

  if (!specialty || !difficulty) {
    return "Parametreleri alamadım.";
  }

  const lines = [
    "UYGULAMA_VAKA_PARAMETRELERI",
    `specialty: ${specialty}`,
    `difficulty_level: ${difficulty}`,
    `challenge_type: ${challengeType}`,
    "KESIN_KURAL: Vaka bu specialty ve difficulty_level ile birebir uyumlu olacak. Farklı bölümden vaka üretme."
  ];
  if (rawSpecialty && rawSpecialty !== specialty) {
    lines.push(`specialty_localized: ${rawSpecialty}`);
  }

  if (challengeType === "daily") {
    lines.push(`case_title: ${challengeTitle || "Belirtilmedi"}`);
    lines.push(`chief_complaint: ${chiefComplaint || "Belirtilmedi"}`);
    lines.push(`patient: ${patientInfo}`);
    lines.push(`expected_diagnosis_hidden: ${expectedDiagnosis || "Belirtilmedi"}`);
  }

  if (explicitSeedPrompt) {
    lines.push("EK_BAGLAM:");
    lines.push(explicitSeedPrompt);
  }

  return lines.join("\n");
}

function buildAgentDynamicVariables(userName = "") {
  const caseData = session.caseData || {};
  const rawSpecialty = String(caseData.specialty || "").trim();
  const rawDifficulty = String(caseData.difficulty || "Random").trim();
  const specialty = toCanonicalSpecialty(rawSpecialty);
  const difficulty = normalizeDifficultyForAgent(rawDifficulty);
  const challengeType = String(caseData.challengeType || "random").trim() || "random";
  const challengeId = String(caseData.challengeId || "").trim();
  const challengeTitle = String(caseData.challengeTitle || "").trim();
  const chiefComplaint = String(caseData.chiefComplaint || "").trim();
  const expectedDiagnosis = String(caseData.expectedDiagnosis || "").trim();
  const patientGender = String(caseData.patientGender || "").trim();
  const patientAge = Number(caseData.patientAge);

  if (!specialty || !difficulty) {
    return {};
  }

  const vars = {
    specialty,
    specialty_localized: rawSpecialty || specialty,
    difficulty,
    difficulty_level: difficulty,
    challenge_type: challengeType,
    mode: "voice",
    session_id: String(session.id || "").trim()
  };

  if (challengeId) {
    vars.challenge_id = challengeId;
  }
  if (challengeTitle) {
    vars.case_title = challengeTitle;
    vars.case = challengeTitle;
  }
  if (chiefComplaint) {
    vars.chief_complaint = chiefComplaint;
  }
  if (expectedDiagnosis) {
    vars.expected_diagnosis_hidden = expectedDiagnosis;
  }
  if (patientGender) {
    vars.patient_gender = patientGender;
  }
  if (Number.isFinite(patientAge) && patientAge > 0) {
    vars.patient_age = String(Math.round(patientAge));
  }
  if (userName) {
    vars.user_name = userName;
  }

  return vars;
}

function shouldAutoHandleCaseConfigQuestion(source, message) {
  if (source === "user" || caseConfigReminderAutoSent) {
    return false;
  }
  const text = normalizeForHiddenCompare(message);
  if (!text) {
    return false;
  }
  const triggers = [
    "hangi bolum",
    "hangi bölüm",
    "hangi uzmanlik",
    "hangi uzmanlık",
    "zorluk",
    "vaka zorlugu",
    "vaka zorluğu",
    "kolay mi orta mi",
    "which specialty",
    "what specialty",
    "which difficulty",
    "difficulty level"
  ];
  return triggers.some((trigger) => text.includes(trigger));
}

async function autoSendCaseConfigReminder() {
  if (!conversation || caseConfigReminderAutoSent) {
    return;
  }
  const seedPrompt = buildChallengeSeedPrompt();
  if (!seedPrompt) {
    return;
  }
  caseConfigReminderAutoSent = true;
  await dispatchSeedPrompt(seedPrompt);
}

async function dispatchSeedPrompt(seedPrompt) {
  if (!conversation || !seedPrompt) {
    return;
  }
  try {
    if (typeof conversation.sendContextualUpdate === "function") {
      await conversation.sendContextualUpdate(seedPrompt);
    }
  } catch {
    // Fallback
  }

  try {
    if (typeof conversation.sendUserMessage === "function") {
      rememberHiddenSeedMessage(seedPrompt);
      await conversation.sendUserMessage(seedPrompt);
      setAwaitingAiReply(true);
    }
  } catch {
    // Hata durumunda normal akış devam eder.
  }
}

async function sendChallengeSeedIfNeeded() {
  if (challengeSeedSent || !conversation) {
    return;
  }
  const seedPrompt = buildChallengeSeedPrompt();
  if (!seedPrompt) {
    challengeSeedSent = true;
    return;
  }

  await dispatchSeedPrompt(seedPrompt);
  challengeSeedSent = true;
}

function setStatus(text) {
  voiceStatusLineEl.textContent = text;
}

function renderVoiceTypingIndicator() {
  if (!voiceTypingIndicatorEl) {
    return;
  }

  const shouldShow = isAwaitingAiReply && !isCaseEnded;
  voiceTypingIndicatorEl.hidden = !shouldShow;
  if (shouldShow) {
    transcriptListEl.append(voiceTypingIndicatorEl);
  }
}

function setAwaitingAiReply(shouldAwait) {
  const next = Boolean(shouldAwait) && !isCaseEnded;
  if (isAwaitingAiReply === next) {
    return;
  }
  isAwaitingAiReply = next;
  renderVoiceTypingIndicator();
  if (next) {
    scrollTranscriptToBottom();
  }
}

function clearCaseFinalizeTimer() {
  if (caseFinalizeTimer) {
    clearTimeout(caseFinalizeTimer);
    caseFinalizeTimer = null;
  }
}

function finalizeCaseEnd(forceStatus = "") {
  if (hasFinalizedCaseEnd) {
    return;
  }
  hasFinalizedCaseEnd = true;
  clearCaseFinalizeTimer();
  disconnectIntent = "none";
  conversation = null;
  isConnecting = false;
  clearReconnectTimer();
  clearMicReleaseTimer();
  isMicPressed = false;
  micHoldRequested = false;
  clearPendingTranscript();
  setAwaitingAiReply(false);
  updateControls();
  if (forceStatus) {
    setStatus(forceStatus);
  }
  void endElevenLabsSessionAuth(VOICE_AGENT_ID);
  void runAutoScore();
}

function setListeningPill(text) {
  listeningPillEl.textContent = text;
}

function clearReconnectTimer() {
  if (reconnectTimer) {
    clearTimeout(reconnectTimer);
    reconnectTimer = null;
  }
}

function clearMicReleaseTimer() {
  if (micReleaseTimer) {
    clearTimeout(micReleaseTimer);
    micReleaseTimer = null;
  }
}

function canControlMic() {
  return Boolean(conversation && typeof conversation.setMicMuted === "function");
}

function updateControls() {
  const connected = Boolean(conversation);

  pauseBtn.disabled = isCaseEnded || isConnecting || !connected;
  micBtn.disabled = isCaseEnded || isConnecting || isSessionPaused;
  endVoiceCaseBtn.disabled = isCaseEnded;

  pauseBtn.textContent = isSessionPaused ? "DEVAM" : "DURDUR";
  micBtn.textContent = isMicPressed ? "KONUŞUYORSUN" : "BASILI TUT";
  micBtn.classList.toggle("is-pressed", isMicPressed);
}

function updateMessageCount() {
  voiceMessageCountEl.textContent = `${transcript.length} mesaj`;
}

function showPendingTranscript() {
  if (pendingTranscriptEl) {
    return;
  }

  const li = document.createElement("li");
  li.className = "voice-line user pending";

  const icon = document.createElement("span");
  icon.className = "voice-line-icon";
  icon.textContent = "SEN";

  const body = document.createElement("div");
  body.className = "voice-line-body";

  const speaker = document.createElement("p");
  speaker.className = "speaker";
  speaker.textContent = "Sen";

  const message = document.createElement("p");
  message.className = "message";
  message.textContent = "Konuşman yazıya dökülüyor...";

  const time = document.createElement("span");
  time.className = "time";
  time.textContent = formatClock(Date.now());

  body.append(speaker, message, time);
  li.append(icon, body);
  transcriptListEl.append(li);
  pendingTranscriptEl = li;
  scrollTranscriptToBottom();
}

function clearPendingTranscript() {
  if (!pendingTranscriptEl) {
    return;
  }
  pendingTranscriptEl.remove();
  pendingTranscriptEl = null;
}

function normalizeText(input) {
  return String(input || "")
    .toLocaleLowerCase("tr-TR")
    .replace(/\s+/g, " ")
    .trim();
}

function shouldAutoEndFromAgentMessage(message) {
  const text = normalizeText(message);
  if (!text) {
    return false;
  }

  const triggers = [
    "vakayı kapatıyorum",
    "vakayi kapatiyorum",
    "vakayı sonlandırıyorum",
    "vakayi sonlandiriyorum",
    "vakayı burada bitiriyorum",
    "vakayi burada bitiriyorum",
    "vaka tamamlandı",
    "vaka tamamlandi",
    "vaka kapatıldı",
    "vaka kapatildi",
    "case is closed",
    "closing the case",
    "ending the case"
  ];

  return triggers.some((trigger) => text.includes(trigger));
}

function scrollTranscriptToBottom() {
  const lastItem = transcriptListEl.lastElementChild;
  requestAnimationFrame(() => {
    if (lastItem && typeof lastItem.scrollIntoView === "function") {
      lastItem.scrollIntoView({ block: "end", behavior: "auto" });
    }
    transcriptListEl.scrollTop = transcriptListEl.scrollHeight;

    const transcriptCard = transcriptListEl.closest(".transcript-card");
    if (transcriptCard) {
      transcriptCard.scrollTop = transcriptCard.scrollHeight;
    }

    window.scrollTo({ top: document.body.scrollHeight, behavior: "auto" });
  });
}

function renderTranscript() {
  transcriptListEl.innerHTML = "";

  transcript.forEach((item) => {
    const li = document.createElement("li");
    li.className = `voice-line ${item.source}`;

    const icon = document.createElement("span");
    icon.className = "voice-line-icon";
    icon.textContent = item.source === "user" ? "SEN" : "KOÇ";

    const body = document.createElement("div");
    body.className = "voice-line-body";

    const speaker = document.createElement("p");
    speaker.className = "speaker";
    speaker.textContent = item.source === "user" ? "Sen" : "Vaka Koçu";

    const message = document.createElement("p");
    message.className = "message";
    message.textContent = item.message;

    const time = document.createElement("span");
    time.className = "time";
    time.textContent = formatClock(item.timestamp);

    body.append(speaker, message, time);
    li.append(icon, body);
    transcriptListEl.append(li);
  });

  renderVoiceTypingIndicator();
  updateMessageCount();
  scrollTranscriptToBottom();
}

function addMessage(source, message, eventId) {
  if (source === "user" && isHiddenSeedMessage(message)) {
    return;
  }
  clearPendingTranscript();

  const inserted = addTranscriptMessage(transcript, {
    source,
    message,
    eventId,
    timestamp: Date.now()
  });
  if (!inserted) {
    return;
  }
  const normalizedSource = source === "user" ? "user" : "ai";
  setAwaitingAiReply(normalizedSource === "user" && !isMicPressed);
  renderTranscript();
  scheduleProgressSync();

  const budget = getSessionBudgetState(transcript);
  if (!isCaseEnded && budget.reached) {
    setStatus(`${budget.message} Vaka otomatik sonlandırılıyor...`);
    setListeningPill("Limit doldu");
    void endCase();
    return;
  }

  if (normalizedSource === "ai" && !isCaseEnded && shouldAutoEndFromAgentMessage(message)) {
    setStatus("Koç vakayı kapattı. Sonuçlara geçiliyor...");
    void endCase();
  }
}

async function setMicMutedSafe(muted) {
  if (!conversation || !canControlMic()) {
    return;
  }
  await conversation.setMicMuted(Boolean(muted));
}

function scheduleReconnect() {
  if (isCaseEnded || isSessionPaused) {
    return;
  }
  if (reconnectAttempts >= MAX_RECONNECT_ATTEMPTS) {
    setStatus("Bağlantı kesildi. Mikrofon düğmesiyle tekrar deneyebilirsin.");
    setListeningPill("Bağlantı kesildi");
    return;
  }

  const attemptNo = reconnectAttempts + 1;
  const delay = RECONNECT_DELAYS_MS[Math.min(reconnectAttempts, RECONNECT_DELAYS_MS.length - 1)];
  reconnectAttempts += 1;
  if (reconnectAttempts >= 3) {
    activeConnectionType = "websocket";
  }

  setStatus(
    `Bağlantı kesildi, yeniden bağlanılıyor (${attemptNo}/${MAX_RECONNECT_ATTEMPTS}) - ${activeConnectionType.toUpperCase()}`
  );
  setListeningPill("Yeniden bağlanıyor...");
  clearReconnectTimer();
  reconnectTimer = setTimeout(() => {
    void startVoiceSession();
  }, delay);
}

async function runAutoScore() {
  clearCaseFinalizeTimer();
  clearSyncTimer();
  const hasEnoughData = hasSufficientEvidence(transcript);
  const endedAt = new Date().toISOString();
  const payload = buildSessionPayload(hasEnoughData ? "pending" : "no_data", endedAt);
  saveCaseResult(payload);
  void syncCaseResultToDb(payload);
  window.location.href = "/case-results.html";
}

async function startVoiceSession() {
  if (conversation || isConnecting || isCaseEnded) {
    return;
  }

  isConnecting = true;
  setAwaitingAiReply(false);
  updateControls();
  setStatus(
    hasConnectedOnce
      ? `Sesli oturum yeniden bağlanıyor (${activeConnectionType.toUpperCase()})...`
      : `Sesli oturum hazırlanıyor (${activeConnectionType.toUpperCase()})...`
  );
  setListeningPill("Bağlanılıyor...");

  try {
    resetSeedDispatchState();
    await ensureMicrophoneReady();
    let authPayload = null;
    try {
      authPayload = await getElevenLabsSessionAuth(VOICE_AGENT_ID, {
        mode: "voice"
      });
    } catch {
      invalidateElevenLabsSessionAuth(VOICE_AGENT_ID);
      setStatus("Güvenli ses oturumu bilgisi alınamadı. Standart bağlantı deneniyor...");
    }

    const sessionHandlers = {
      onConnect: async () => {
        clearReconnectTimer();
        clearMicReleaseTimer();
        reconnectAttempts = 0;
        isConnecting = false;
        isMicPressed = false;
        setAwaitingAiReply(false);
        hasConnectedOnce = true;
        activeConnectionType = "webrtc";
        setStatus("Vaka ayarları aktarılıyor...");
        await sendChallengeSeedIfNeeded();
        try {
          if (canControlMic()) {
            await setMicMutedSafe(true);
          }
        } catch {
          // Session acildiysa sessize alma hatasi kritigi degil.
        }
        scheduleProgressSync(true);
        setStatus("Sesli oturum aktif.");
        if (!canControlMic()) {
          setListeningPill("Konuşmaya hazır");
          setStatus("Sesli oturum aktif. Konuşmaya başla, sistem seni dinliyor.");
        } else {
          setListeningPill(isSessionPaused ? "Durduruldu" : "Hazır");
        }
        updateControls();
      },
      onDisconnect: () => {
        const intended = disconnectIntent;
        disconnectIntent = "none";
        conversation = null;
        isConnecting = false;
        isMicPressed = false;
        micHoldRequested = false;
        clearMicReleaseTimer();
        clearPendingTranscript();
        setAwaitingAiReply(false);
        updateControls();

        if (intended === "end") {
          setListeningPill("Vaka bitti");
          finalizeCaseEnd();
          return;
        }
        if (intended === "leave") {
          return;
        }

        if (isSessionPaused) {
          setStatus("Sesli oturum durduruldu.");
          setListeningPill("Durduruldu");
          return;
        }

        scheduleReconnect();
      },
      onError: (message) => {
        setAwaitingAiReply(false);
        setStatus(`Sesli oturum hatası: ${message}`);
      },
      onModeChange: ({ mode }) => {
        if (isSessionPaused) {
          return;
        }
        if (mode === "listening") {
          setListeningPill(isMicPressed ? "Konuşuyorsun..." : "Hazır");
        } else if (mode === "speaking") {
          setAwaitingAiReply(false);
          setListeningPill("Koç konuşuyor...");
        }
      },
      onMessage: ({ source, message, event_id: eventId }) => {
        if (shouldAutoHandleCaseConfigQuestion(source, message)) {
          void autoSendCaseConfigReminder();
          return;
        }
        addMessage(source, message, eventId);
      }
    };

    const startOptions = {
      connectionType: activeConnectionType,
      ...sessionHandlers
    };
    const userName = await resolveUserNameForAgent();
    const dynamicVariables = buildAgentDynamicVariables(userName);
    if (Object.keys(dynamicVariables).length) {
      startOptions.dynamicVariables = dynamicVariables;
    }

    if (activeConnectionType === "webrtc") {
      if (authPayload?.conversationToken) {
        startOptions.agentId = VOICE_AGENT_ID;
        startOptions.authorization = {
          type: "conversation_initiation_client_data",
          conversationToken: authPayload.conversationToken
        };
      } else if (authPayload?.signedUrl) {
        startOptions.connectionType = "websocket";
        startOptions.signedUrl = authPayload.signedUrl;
      } else {
        startOptions.agentId = VOICE_AGENT_ID;
      }
    } else if (authPayload?.signedUrl) {
      startOptions.signedUrl = authPayload.signedUrl;
    } else {
      startOptions.agentId = VOICE_AGENT_ID;
    }

    conversation = await Conversation.startSession(startOptions);
  } catch (error) {
    invalidateElevenLabsSessionAuth(VOICE_AGENT_ID);
    conversation = null;
    isConnecting = false;
    setAwaitingAiReply(false);
    updateControls();
    setListeningPill("Mikrofon gerekli");
    setStatus(`Sesli oturum başlatılamadı: ${error?.message || "Bilinmeyen hata"}`);
  }
}

async function pauseOrResume() {
  if (isCaseEnded || isConnecting) {
    return;
  }

  if (!conversation) {
    if (isSessionPaused) {
      isSessionPaused = false;
      await startVoiceSession();
      updateControls();
    }
    return;
  }

  if (isSessionPaused) {
    isSessionPaused = false;
    setAwaitingAiReply(false);
    try {
      if (canControlMic()) {
        await setMicMutedSafe(true);
      }
      setStatus("Sesli oturum devam ediyor.");
      setListeningPill(canControlMic() ? "Hazır" : "Konuşmaya hazır");
    } catch (error) {
      setStatus(`Devam etme başarısız: ${error?.message || "Bilinmeyen hata"}`);
    }
    updateControls();
    return;
  }

  isSessionPaused = true;
  isMicPressed = false;
  micHoldRequested = false;
  setAwaitingAiReply(false);
  try {
    if (canControlMic()) {
      await setMicMutedSafe(true);
      setStatus("Sesli oturum durduruldu.");
      setListeningPill("Durduruldu");
    } else {
      setStatus("Bu cihazda mikrofon kontrolü sınırlı. Durdurma komutu uygulandı.");
      setListeningPill("Durduruldu");
    }
  } catch (error) {
    setStatus(`Durdurma başarısız: ${error?.message || "Bilinmeyen hata"}`);
  }
  updateControls();
}

async function beginPushToTalk() {
  if (isCaseEnded || isSessionPaused || isConnecting) {
    return;
  }
  const budget = getSessionBudgetState(transcript);
  if (budget.reached) {
    setStatus(`${budget.message} Yeni konuşma alınmıyor.`);
    setListeningPill("Limit doldu");
    return;
  }
  clearMicReleaseTimer();
  clearPendingTranscript();

  if (!conversation) {
    await startVoiceSession();
    if (!conversation) {
      return;
    }
  }
  if (!micHoldRequested) {
    return;
  }
  if (isMicPressed) {
    return;
  }

  isMicPressed = true;
  setAwaitingAiReply(false);
  updateControls();
  try {
    if (canControlMic()) {
      await setMicMutedSafe(false);
    }
    setStatus("Konuşuyorsun...");
    setListeningPill("Konuşuyorsun...");
  } catch (error) {
    isMicPressed = false;
    updateControls();
    setStatus(`Mikrofon açılamadı: ${error?.message || "Bilinmeyen hata"}`);
  }
}

async function endPushToTalk() {
  micHoldRequested = false;
  clearMicReleaseTimer();
  if (!conversation || !isMicPressed) {
    return;
  }

  micReleaseTimer = setTimeout(async () => {
    isMicPressed = false;
    updateControls();
    if (!conversation) {
      return;
    }
    try {
      if (canControlMic()) {
        showPendingTranscript();
        await setMicMutedSafe(true);
      }
      setAwaitingAiReply(true);
      setStatus("Yanıt bekleniyor...");
      setListeningPill("Yanıt bekleniyor...");
    } catch (error) {
      setStatus(`Mikrofon sessize alınamadı: ${error?.message || "Bilinmeyen hata"}`);
    }
  }, 180);
}

async function endCase() {
  if (isCaseEnded) {
    return;
  }

  isCaseEnded = true;
  hasFinalizedCaseEnd = false;
  clearCaseFinalizeTimer();
  clearSyncTimer();
  isMicPressed = false;
  micHoldRequested = false;
  setAwaitingAiReply(false);
  clearReconnectTimer();
  clearMicReleaseTimer();
  clearPendingTranscript();
  updateControls();

  if (conversation) {
    disconnectIntent = "end";
    setStatus("Vaka sonlandırılıyor...");
    try {
      caseFinalizeTimer = setTimeout(() => {
        finalizeCaseEnd("Bağlantı kapatıldı. Sonuçlar hazırlanıyor...");
      }, 2200);
      await conversation.endSession();
    } catch (error) {
      setStatus(`Oturum temiz kapatılamadı: ${error?.message || "Bilinmeyen hata"}`);
      finalizeCaseEnd();
    }
    return;
  }

  finalizeCaseEnd();
}

function renderCaseInfo() {
  const caseData = session.caseData;
  caseSpecialtyEl.textContent = caseData.specialty || "Oluşturulan";
  caseDifficultyEl.textContent = caseData.difficulty || "Random";

  const gender = String(caseData.patientGender || "").trim();
  const age = Number(caseData.patientAge);
  const hasAge = Number.isFinite(age) && age > 0;
  if (gender || hasAge) {
    patientLineEl.textContent = `Hasta: ${gender || "Belirtilmedi"}${hasAge ? `, ${age} yaş` : ""}`;
  } else if (caseData.challengeTitle) {
    patientLineEl.textContent = caseData.challengeTitle;
  } else {
    patientLineEl.textContent = "Hasta detayları görüşme sırasında paylaşılacak";
  }

  patientComplaintEl.textContent =
    caseData.chiefComplaint || caseData.challengeSummary || "Başvuru şikayeti görüşme içinde netleşecek";
}

function bindPushToTalk() {
  const onPress = (event) => {
    event.preventDefault();
    if (typeof micBtn.setPointerCapture === "function" && event.pointerId != null) {
      micBtn.setPointerCapture(event.pointerId);
    }
    micHoldRequested = true;
    void beginPushToTalk();
  };
  const onRelease = (event) => {
    event.preventDefault();
    if (typeof micBtn.releasePointerCapture === "function" && event.pointerId != null) {
      try {
        micBtn.releasePointerCapture(event.pointerId);
      } catch {
        // capture zaten serbest olabilir.
      }
    }
    void endPushToTalk();
  };

  micBtn.addEventListener("pointerdown", onPress);
  micBtn.addEventListener("pointerup", onRelease);
  micBtn.addEventListener("pointercancel", onRelease);
  micBtn.addEventListener("pointerleave", onRelease);

  micBtn.addEventListener("keydown", (event) => {
    if (event.code === "Space" || event.code === "Enter") {
      event.preventDefault();
      micHoldRequested = true;
      void beginPushToTalk();
    }
  });
  micBtn.addEventListener("keyup", (event) => {
    if (event.code === "Space" || event.code === "Enter") {
      event.preventDefault();
      void endPushToTalk();
    }
  });
}

backToGeneratorBtn.addEventListener("click", async () => {
  isCaseEnded = true;
  clearSyncTimer();
  clearReconnectTimer();
  if (conversation) {
    disconnectIntent = "leave";
    try {
      await conversation.endSession();
    } catch {
      // Cikis sirasinda session kapatma hatasi yok sayilabilir.
    }
  }
  await endElevenLabsSessionAuth(VOICE_AGENT_ID);
  window.location.replace("/generator.html");
});

pauseBtn.addEventListener("click", () => {
  void pauseOrResume();
});
endVoiceCaseBtn.addEventListener("click", () => {
  void endCase();
});

restoreTranscriptFromSavedState();
renderCaseInfo();
if (transcript.length) {
  renderTranscript();
} else {
  updateMessageCount();
}
bindPushToTalk();
updateControls();
setListeningPill("Bağlanılıyor...");
setStatus("Sesli oturum hazırlanıyor...");
window.addEventListener("pagehide", () => {
  void endElevenLabsSessionAuth(VOICE_AGENT_ID);
  if (isCaseEnded) {
    return;
  }
  clearSyncTimer();
  const payload = buildSessionPayload("in_progress");
  saveCaseResult(payload);
});
void startVoiceSession();
