import { Conversation } from "https://cdn.jsdelivr.net/npm/@elevenlabs/client/+esm";
import {
  TEXT_AGENT_ID,
  addTranscriptMessage,
  buildCaseWrapupFromTranscript,
  ensureCaseSession,
  formatClock,
  getSessionBudgetState,
  hasSufficientEvidence,
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
const textCaseSpecialtyEl = document.getElementById("textCaseSpecialty");
const textCaseDifficultyEl = document.getElementById("textCaseDifficulty");
const sessionClockEl = document.getElementById("sessionClock");
const textMessageCountEl = document.getElementById("textMessageCount");
const textTranscriptListEl = document.getElementById("textTranscriptList");
const textTypingIndicatorEl = document.getElementById("textTypingIndicator");
const textInputEl = document.getElementById("textInput");
const sendTextBtn = document.getElementById("sendTextBtn");
const endTextCaseBtn = document.getElementById("endTextCaseBtn");
const textStatusLineEl = document.getElementById("textStatusLine");

const session = ensureCaseSession("text");

let conversation = null;
let transcript = [];
let disconnectIntent = "none";
let isConnecting = false;
let reconnectAttempts = 0;
let reconnectTimer = null;
let hasConnectedOnce = false;
let isCaseEnded = false;
let challengeSeedSent = false;
let caseConfigReminderAutoSent = false;
let resolvedUserName = "";
let caseFinalizeTimer = null;
let hasFinalizedCaseEnd = false;
let isAwaitingAiReply = false;
const hiddenSeedMessages = new Set();
const MAX_RECONNECT_ATTEMPTS = 6;
const RECONNECT_DELAYS_MS = [700, 1200, 1800, 2600, 3800, 5200];
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

function resetSeedDispatchState() {
  challengeSeedSent = false;
  caseConfigReminderAutoSent = false;
  hiddenSeedMessages.clear();
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
  return String(session.caseData?.challengeTitle || "Vaka Analizi").trim();
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
  const specialtyLocalized = rawSpecialty;
  const specialtyCanonical = toCanonicalSpecialty(rawSpecialty);
  const specialty = specialtyLocalized || specialtyCanonical;
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
  if (specialtyLocalized && specialtyCanonical && specialtyLocalized !== specialtyCanonical) {
    lines.push(`specialty_canonical: ${specialtyCanonical}`);
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
  const specialtyLocalized = rawSpecialty;
  const specialtyCanonical = toCanonicalSpecialty(rawSpecialty);
  const specialty = specialtyLocalized || specialtyCanonical;
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
    specialty_localized: specialtyLocalized || specialty,
    specialty_canonical: specialtyCanonical || specialty,
    difficulty,
    difficulty_level: difficulty,
    challenge_type: challengeType,
    mode: "text",
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
  } else {
    vars.user_name = "Kullanıcı";
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
  textStatusLineEl.textContent = text;
}

function renderTypingIndicator() {
  if (!textTypingIndicatorEl) {
    return;
  }

  const shouldShow = isAwaitingAiReply && !isCaseEnded;
  textTypingIndicatorEl.hidden = !shouldShow;
  if (shouldShow) {
    textTranscriptListEl.append(textTypingIndicatorEl);
  }
}

function setAwaitingAiReply(shouldAwait) {
  const next = Boolean(shouldAwait) && !isCaseEnded;
  if (isAwaitingAiReply === next) {
    return;
  }
  isAwaitingAiReply = next;
  renderTypingIndicator();
  if (next) {
    scrollTranscriptToBottom();
  }
}

function clearReconnectTimer() {
  if (reconnectTimer) {
    clearTimeout(reconnectTimer);
    reconnectTimer = null;
  }
}

function scheduleReconnect() {
  if (isCaseEnded) {
    return;
  }
  if (reconnectAttempts >= MAX_RECONNECT_ATTEMPTS) {
    setStatus("Yazı oturumu kesildi. Sayfayı yenileyerek yeniden bağlanabilirsin.");
    updateComposer();
    return;
  }

  const attemptNo = reconnectAttempts + 1;
  const delay = RECONNECT_DELAYS_MS[Math.min(reconnectAttempts, RECONNECT_DELAYS_MS.length - 1)];
  reconnectAttempts += 1;
  setStatus(`Bağlantı koptu, yeniden bağlanılıyor (${attemptNo}/${MAX_RECONNECT_ATTEMPTS})...`);
  clearReconnectTimer();
  reconnectTimer = setTimeout(() => {
    void startTextSession();
  }, delay);
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
  clearReconnectTimer();
  disconnectIntent = "none";
  conversation = null;
  isConnecting = false;
  updateComposer();
  if (forceStatus) {
    setStatus(forceStatus);
  }
  setAwaitingAiReply(false);
  void endElevenLabsSessionAuth(TEXT_AGENT_ID);
  runAutoScore();
}

function updateMessageCount() {
  textMessageCountEl.textContent = `${transcript.length} mesaj`;
}

function updateComposer() {
  const enabled = Boolean(conversation) && !isCaseEnded && !isConnecting;
  textInputEl.disabled = !enabled;
  sendTextBtn.disabled = !enabled;
  endTextCaseBtn.disabled = isCaseEnded && !conversation;
}

function scrollTranscriptToBottom() {
  const lastItem = textTranscriptListEl.lastElementChild;
  requestAnimationFrame(() => {
    if (lastItem && typeof lastItem.scrollIntoView === "function") {
      lastItem.scrollIntoView({ block: "end", behavior: "auto" });
    }
    textTranscriptListEl.scrollTop = textTranscriptListEl.scrollHeight;

    const chatCard = textTranscriptListEl.closest(".chat-card");
    if (chatCard) {
      chatCard.scrollTop = chatCard.scrollHeight;
    }

    window.scrollTo({ top: document.body.scrollHeight, behavior: "auto" });
  });
}

function renderTranscript() {
  textTranscriptListEl.innerHTML = "";

  transcript.forEach((item) => {
    const li = document.createElement("li");
    li.className = `chat-message ${item.source}`;

    const bubble = document.createElement("div");
    bubble.className = "bubble";
    bubble.textContent = item.message;

    const time = document.createElement("span");
    time.className = "time";
    time.textContent = formatClock(item.timestamp);

    li.append(bubble, time);
    textTranscriptListEl.append(li);
  });

  renderTypingIndicator();
  updateMessageCount();
  scrollTranscriptToBottom();
}

function addMessage(source, message, eventId) {
  if (source === "user" && isHiddenSeedMessage(message)) {
    return;
  }
  const inserted = addTranscriptMessage(transcript, {
    source,
    message,
    eventId,
    timestamp: Date.now()
  });
  if (!inserted) {
    return;
  }
  if (source === "ai") {
    setAwaitingAiReply(false);
  }
  renderTranscript();

  const budget = getSessionBudgetState(transcript);
  if (!isCaseEnded && budget.reached) {
    setStatus(`${budget.message} Vaka otomatik sonlandırılıyor...`);
    void endCase();
  }
}

async function runAutoScore() {
  clearCaseFinalizeTimer();
  const hasEnoughData = hasSufficientEvidence(transcript);
  const challengeId = String(session.caseData?.challengeId || "").trim();
  const challengeType = String(session.caseData?.challengeType || "").trim();
  const challengeWrapup = buildChallengeWrapup();
  const transcriptWrapup = buildCaseWrapupFromTranscript(transcript);
  const optionalCaseWrapup = [challengeWrapup, transcriptWrapup].filter(Boolean).join(" ").trim();

  const caseContext = {
    title: resolveCaseTitle(),
    specialty: session.caseData?.specialty || "Genel Tıp",
    challenge_id: challengeId || null,
    challenge_type: challengeType || null,
    expected_diagnosis: session.caseData?.expectedDiagnosis || null,
    subtitle: session.caseData?.challengeSummary || "Skor ve geri bildirim hazırlanıyor."
  };
  const payload = {
    status: hasEnoughData ? "pending" : "no_data",
    sessionId: session.id,
    mode: "text",
    startedAt: session.createdAt,
    endedAt: new Date().toISOString(),
    durationMin: minutesBetween(session.createdAt),
    messageCount: transcript.length,
    difficulty: session.caseData?.difficulty || "Random",
    challengeId: challengeId || null,
    challengeType: challengeType || null,
    transcript: transcript.map((item) => ({
      source: item.source,
      message: item.message,
      timestamp: item.timestamp
    })),
    caseContext,
    optionalCaseWrapup,
    score: null
  };
  saveCaseResult(payload);
  void syncCaseResultToDb(payload);

  window.location.href = "/case-results.html";
}

async function startTextSession() {
  if (conversation || isConnecting || isCaseEnded) {
    return;
  }

  isConnecting = true;
  setStatus(
    hasConnectedOnce
      ? "Yazı oturumu yeniden bağlanıyor..."
      : "Yazı oturumuna bağlanılıyor..."
  );
  updateComposer();

  try {
    resetSeedDispatchState();
    const userName = await resolveUserNameForAgent();
    const dynamicVariables = buildAgentDynamicVariables(userName);
    const missingRequired = [];
    if (!dynamicVariables.specialty) {
      missingRequired.push("specialty");
    }
    if (!dynamicVariables.difficulty_level) {
      missingRequired.push("difficulty_level");
    }
    if (!dynamicVariables.user_name) {
      missingRequired.push("user_name");
    }
    if (missingRequired.length) {
      throw new Error(`Vaka parametreleri eksik: ${missingRequired.join(", ")}`);
    }

    let authPayload = null;
    try {
      authPayload = await getElevenLabsSessionAuth(TEXT_AGENT_ID, {
        mode: "text",
        dynamicVariables
      });
      console.info("[TextDebug] session-auth dynamicVariables", dynamicVariables);
    } catch (error) {
      invalidateElevenLabsSessionAuth(TEXT_AGENT_ID);
      throw new Error(error?.message || "Güvenli yazı oturumu bilgisi alınamadı.");
    }

    const startOptions = {
      textOnly: true,
      connectionType: "webrtc",
      onConnect: async () => {
        clearReconnectTimer();
        reconnectAttempts = 0;
        hasConnectedOnce = true;
        isConnecting = false;
        disconnectIntent = "none";
        setStatus("Vaka ayarları aktarılıyor...");
        await sendChallengeSeedIfNeeded();
        setAwaitingAiReply(true);
        setStatus("Yazı oturumu aktif.");
        updateComposer();
      },
      onDisconnect: () => {
        const intended = disconnectIntent;
        disconnectIntent = "none";
        conversation = null;
        isConnecting = false;
        setAwaitingAiReply(false);
        updateComposer();

        if (intended === "end") {
          finalizeCaseEnd();
          return;
        }
        if (intended === "leave") {
          return;
        }
        setStatus("Bağlantı kesildi. Vakayı yeniden başlatmak için sayfayı yenile.");
      },
      onError: (message) => {
        setAwaitingAiReply(false);
        setStatus(`Yazı oturumu hatası: ${message}`);
      },
      onStatusChange: ({ status }) => {
        if (status) {
          setStatus(`Yazı durumu: ${status}`);
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
    startOptions.dynamicVariables = dynamicVariables;

    if (authPayload?.signedUrl) {
      startOptions.connectionType = "websocket";
      startOptions.signedUrl = authPayload.signedUrl;
    } else if (authPayload?.conversationToken) {
      startOptions.agentId = TEXT_AGENT_ID;
      startOptions.authorization = {
        type: "conversation_initiation_client_data",
        conversationToken: authPayload.conversationToken
      };
    } else {
      throw new Error("Güvenli oturum anahtarı alınamadı.");
    }

    conversation = await Conversation.startSession(startOptions);

    updateComposer();
    textInputEl.focus();
  } catch (error) {
    invalidateElevenLabsSessionAuth(TEXT_AGENT_ID);
    conversation = null;
    isConnecting = false;
    setAwaitingAiReply(false);
    updateComposer();
    setStatus(`Yazı oturumu başlatılamadı: ${error?.message || "Bilinmeyen hata"}`);
  }
}

function sendTextMessage() {
  if (!conversation || isCaseEnded) {
    return;
  }
  const budget = getSessionBudgetState(transcript);
  if (budget.reached) {
    setStatus(`${budget.message} Yeni mesaj gönderilemiyor.`);
    return;
  }

  const message = textInputEl.value.trim();
  if (!message) {
    return;
  }

  try {
    addMessage("user", message, null);
    conversation.sendUserMessage(message);
    setAwaitingAiReply(true);
    textInputEl.value = "";
    textInputEl.focus();
  } catch (error) {
    setStatus(`Mesaj gönderilemedi: ${error?.message || "Bilinmeyen hata"}`);
  }
}

async function endCase() {
  if (isCaseEnded) {
    return;
  }

  isCaseEnded = true;
  hasFinalizedCaseEnd = false;
  clearCaseFinalizeTimer();
  clearReconnectTimer();
  setAwaitingAiReply(false);
  updateComposer();

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
  textCaseSpecialtyEl.textContent = caseData.specialty || "Oluşturulan";
  textCaseDifficultyEl.textContent = caseData.difficulty || "Random";
  sessionClockEl.textContent = formatClock(session.createdAt);
}

backToGeneratorBtn.addEventListener("click", async () => {
  disconnectIntent = "leave";
  clearReconnectTimer();
  await endElevenLabsSessionAuth(TEXT_AGENT_ID);
  window.location.replace("/generator.html");
});
sendTextBtn.addEventListener("click", sendTextMessage);
textInputEl.addEventListener("keydown", (event) => {
  if (event.key === "Enter") {
    event.preventDefault();
    sendTextMessage();
  }
});
endTextCaseBtn.addEventListener("click", endCase);
window.addEventListener("pagehide", () => {
  disconnectIntent = "leave";
  clearReconnectTimer();
  void endElevenLabsSessionAuth(TEXT_AGENT_ID);
});

renderCaseInfo();
updateComposer();
setStatus("Yazı modu başlatılıyor...");
startTextSession();
