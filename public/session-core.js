import { getSupabaseClient } from "/supabase-client.js";

export const VOICE_AGENT_ID = "agent_3701kj62fctpe75v3a0tca39fy26";
export const TEXT_AGENT_ID = "agent_3701kj62fctpe75v3a0tca39fy26";

const STORAGE_KEY = "medical_case_session_v2";
const RESULT_STORAGE_KEY = "medical_case_result_v2";
const PENDING_CHALLENGE_KEY = "medical_pending_challenge_v1";
const MAX_SCORING_MESSAGES = 24;
const SCORING_MESSAGE_CHAR_LIMIT = 260;
const SCORING_WRAPUP_CHAR_LIMIT = 560;
const SESSION_MAX_TOTAL_MESSAGES = 48;
const SESSION_MAX_USER_MESSAGES = 24;
const SESSION_MAX_USER_CHARS = 2800;

function safeParseJson(raw) {
  if (!raw) {
    return null;
  }
  try {
    return JSON.parse(raw);
  } catch {
    return null;
  }
}

function safeStorageWrite(storage, key, value) {
  try {
    storage.setItem(key, value);
  } catch {
    // Depolama yazımi tarayici tarafinda engellenirse sessizce devam et.
  }
}

function safeStorageRead(storage, key) {
  try {
    return storage.getItem(key);
  } catch {
    return null;
  }
}

function safeStorageRemove(storage, key) {
  try {
    storage.removeItem(key);
  } catch {
    // Depolama silme tarayici tarafinda engellenirse sessizce devam et.
  }
}

async function resolveAccessTokenForScore() {
  try {
    const supabase = await getSupabaseClient();
    const { data, error } = await supabase.auth.getSession();
    if (error || !data?.session?.access_token) {
      return "";
    }
    return String(data.session.access_token);
  } catch {
    return "";
  }
}

function createNeutralCaseData() {
  return {
    specialty: "Oluşturulan",
    difficulty: "Random",
    patientGender: null,
    patientAge: null,
    chiefComplaint: null,
    challengeType: null,
    challengeId: null,
    challengeTitle: null,
    challengeSummary: null,
    expectedDiagnosis: null,
    agentSeedPrompt: null
  };
}

export const DIMENSION_LABELS = {
  data_gathering_quality: "Veri Toplama Kalitesi",
  clinical_reasoning_logic: "Klinik Akıl Yürütme Mantığı",
  differential_diagnosis_depth: "Ayırıcı Tanı Derinliği",
  diagnostic_efficiency: "Tanısal Verimlilik",
  management_plan_quality: "Yönetim Planı Kalitesi",
  safety_red_flags: "Güvenlik ve Kırmızı Bayraklar",
  decision_timing: "Karar Zamanlaması",
  communication_clarity: "İletişim Netliği",
  guideline_consistency: "Kılavuz Tutarlılığı",
  professionalism_empathy: "Profesyonellik ve Empati"
};

export const DIMENSION_ORDER = [
  "data_gathering_quality",
  "clinical_reasoning_logic",
  "differential_diagnosis_depth",
  "diagnostic_efficiency",
  "management_plan_quality",
  "safety_red_flags",
  "decision_timing",
  "communication_clarity",
  "guideline_consistency",
  "professionalism_empathy"
];

export function createCaseSession(mode, caseDataOverrides = null) {
  const baseCaseData = createNeutralCaseData();
  const nextCaseData =
    caseDataOverrides && typeof caseDataOverrides === "object"
      ? { ...baseCaseData, ...caseDataOverrides }
      : baseCaseData;

  return {
    id: `case_${Date.now()}`,
    mode: mode === "text" ? "text" : "voice",
    createdAt: new Date().toISOString(),
    caseData: nextCaseData
  };
}

export function saveCaseSession(session) {
  sessionStorage.setItem(STORAGE_KEY, JSON.stringify(session));
}

export function loadCaseSession() {
  const raw = safeStorageRead(sessionStorage, STORAGE_KEY);
  return safeParseJson(raw);
}

export function ensureCaseSession(mode) {
  const expectedMode = mode === "text" ? "text" : "voice";
  const existing = loadCaseSession();
  if (existing && existing.caseData) {
    if (existing.mode !== expectedMode) {
      existing.mode = expectedMode;
    }
    existing.caseData = {
      ...createNeutralCaseData(),
      ...(existing.caseData && typeof existing.caseData === "object" ? existing.caseData : {})
    };
    saveCaseSession(existing);
    return existing;
  }

  const generated = createCaseSession(expectedMode);
  saveCaseSession(generated);
  return generated;
}

export function saveCaseResult(resultPayload) {
  const serialized = JSON.stringify(resultPayload);
  safeStorageWrite(sessionStorage, RESULT_STORAGE_KEY, serialized);
  safeStorageWrite(localStorage, RESULT_STORAGE_KEY, serialized);
}

export function loadCaseResult() {
  const sessionRaw = safeStorageRead(sessionStorage, RESULT_STORAGE_KEY);
  const sessionParsed = safeParseJson(sessionRaw);
  if (sessionParsed) {
    return sessionParsed;
  }

  const localRaw = safeStorageRead(localStorage, RESULT_STORAGE_KEY);
  const localParsed = safeParseJson(localRaw);
  if (localParsed) {
    safeStorageWrite(sessionStorage, RESULT_STORAGE_KEY, JSON.stringify(localParsed));
  }
  return localParsed;
}

export function clearCaseResult() {
  safeStorageRemove(sessionStorage, RESULT_STORAGE_KEY);
  safeStorageRemove(localStorage, RESULT_STORAGE_KEY);
}

export function savePendingChallenge(challenge) {
  if (!challenge || typeof challenge !== "object") {
    clearPendingChallenge();
    return;
  }
  const serialized = JSON.stringify(challenge);
  safeStorageWrite(sessionStorage, PENDING_CHALLENGE_KEY, serialized);
  safeStorageWrite(localStorage, PENDING_CHALLENGE_KEY, serialized);
}

export function loadPendingChallenge() {
  const sessionRaw = safeStorageRead(sessionStorage, PENDING_CHALLENGE_KEY);
  const sessionParsed = safeParseJson(sessionRaw);
  if (sessionParsed) {
    return sessionParsed;
  }
  const localRaw = safeStorageRead(localStorage, PENDING_CHALLENGE_KEY);
  const localParsed = safeParseJson(localRaw);
  if (localParsed) {
    safeStorageWrite(sessionStorage, PENDING_CHALLENGE_KEY, JSON.stringify(localParsed));
  }
  return localParsed;
}

export function clearPendingChallenge() {
  safeStorageRemove(sessionStorage, PENDING_CHALLENGE_KEY);
  safeStorageRemove(localStorage, PENDING_CHALLENGE_KEY);
}

export function hasSufficientEvidence(transcript) {
  const list = Array.isArray(transcript) ? transcript : [];
  if (!list.length) {
    return false;
  }

  const userMessages = list.filter(
    (item) =>
      item &&
      item.source === "user" &&
      typeof item.message === "string" &&
      item.message.trim().length >= 8
  );
  if (!userMessages.length) {
    return false;
  }

  const totalUserChars = userMessages.reduce((acc, item) => acc + item.message.trim().length, 0);
  return totalUserChars >= 24;
}

export function formatClock(timeLike = Date.now()) {
  return new Date(timeLike).toLocaleTimeString("tr-TR", {
    hour: "2-digit",
    minute: "2-digit",
    hour12: false
  });
}

export function formatDateTimeLabel(timeLike = Date.now()) {
  const dt = new Date(timeLike);
  return dt.toLocaleString("tr-TR", {
    month: "short",
    day: "numeric",
    hour: "2-digit",
    minute: "2-digit",
    hour12: false
  });
}

export function minutesBetween(startIso, endLike = Date.now()) {
  const start = new Date(startIso).getTime();
  const end = new Date(endLike).getTime();
  if (!Number.isFinite(start) || !Number.isFinite(end)) {
    return 0;
  }
  return Math.max(1, Math.round((end - start) / 60000));
}

export function normalizeSource(source) {
  return source === "user" ? "user" : "ai";
}

export function addTranscriptMessage(transcript, nextMessage) {
  const source = normalizeSource(nextMessage.source);
  const message = typeof nextMessage.message === "string" ? nextMessage.message.trim() : "";
  if (!message) {
    return false;
  }

  const timestamp = nextMessage.timestamp || Date.now();
  const eventId = nextMessage.eventId || null;
  if (eventId) {
    const existingIndex = transcript.findIndex((item) => item.eventId === eventId);
    if (existingIndex >= 0) {
      const existing = transcript[existingIndex];
      if (existing.source === source && existing.message === message) {
        return false;
      }
      if (message.length >= String(existing.message || "").length) {
        transcript[existingIndex] = {
          ...existing,
          source,
          message,
          timestamp
        };
        return true;
      }
      return false;
    }
  }

  const lastMessage = transcript[transcript.length - 1];
  if (
    lastMessage &&
    lastMessage.source === source &&
    lastMessage.message === message &&
    Math.abs(timestamp - lastMessage.timestamp) < 1200
  ) {
    return false;
  }

  transcript.push({ source, message, timestamp, eventId });
  return true;
}

export function getSessionUsageStats(transcript) {
  const list = Array.isArray(transcript) ? transcript : [];
  const totalMessages = list.length;
  const userMessages = list.filter((item) => item?.source === "user").length;
  const userChars = list.reduce((acc, item) => {
    if (item?.source !== "user") {
      return acc;
    }
    return acc + String(item?.message || "").trim().length;
  }, 0);
  return {
    totalMessages,
    userMessages,
    userChars
  };
}

export function getSessionBudgetState(transcript) {
  const usage = getSessionUsageStats(transcript);
  if (usage.totalMessages >= SESSION_MAX_TOTAL_MESSAGES) {
    return {
      reached: true,
      reason: "max_total_messages",
      message: `Oturum mesaj limiti doldu (${SESSION_MAX_TOTAL_MESSAGES}).`
    };
  }
  if (usage.userMessages >= SESSION_MAX_USER_MESSAGES) {
    return {
      reached: true,
      reason: "max_user_messages",
      message: `Bu oturum için kullanıcı mesaj limiti doldu (${SESSION_MAX_USER_MESSAGES}).`
    };
  }
  if (usage.userChars >= SESSION_MAX_USER_CHARS) {
    return {
      reached: true,
      reason: "max_user_chars",
      message: `Bu oturum için metin/konuşma karakter limiti doldu (${SESSION_MAX_USER_CHARS}).`
    };
  }
  return {
    reached: false,
    reason: "",
    message: ""
  };
}

export function buildCaseWrapupFromTranscript(transcript) {
  const list = Array.isArray(transcript) ? transcript : [];
  if (!list.length) {
    return "";
  }

  const coachLines = list
    .filter((item) => item?.source !== "user")
    .map((item) => String(item?.message || "").replace(/\s+/g, " ").trim())
    .filter(Boolean);

  if (!coachLines.length) {
    return "";
  }

  const diagnosisSignals = [
    "nihai tanı",
    "nihai tani",
    "kesin tanı",
    "kesin tani",
    "doğru tanı",
    "dogru tani",
    "tanı",
    "tani",
    "teşhis",
    "teshis",
    "appendisit",
    "myokard enfarktüsü",
    "myokard enfarktusu",
    "pnömoni",
    "pnomoni",
    "pulmoner emboli",
    "vaka özeti",
    "vaka ozeti",
    "özet",
    "ozet",
    "sonuç",
    "sonuc",
    "değerlendirme",
    "degerlendirme",
    "kapanış",
    "kapanis"
  ];

  const likelyWrapup = coachLines.filter((line) =>
    diagnosisSignals.some((signal) => line.toLocaleLowerCase("tr-TR").includes(signal))
  );

  const picked = (likelyWrapup.length ? likelyWrapup : coachLines.slice(-3)).slice(-4);
  const merged = picked.join(" ").slice(0, SCORING_WRAPUP_CHAR_LIMIT);
  return merged.replace(/\s+/g, " ").trim();
}

async function parseScoreResponse(response) {
  const raw = await response.text();
  try {
    return raw ? JSON.parse(raw) : {};
  } catch {
    return {
      error: raw || "Skor servisinden geçersiz yanıt alındı."
    };
  }
}

export async function scoreTranscript(transcript, mode, timeoutMs = 70000, optionalCaseWrapup = "") {
  const cleaned = transcript
    .filter((item) => item && item.message)
    .map((item) => ({
      source: item.source,
      message: String(item.message || "")
        .replace(/\s+/g, " ")
        .trim()
        .slice(0, SCORING_MESSAGE_CHAR_LIMIT)
    }));

  const conversation =
    cleaned.length <= MAX_SCORING_MESSAGES
      ? cleaned
      : [...cleaned.slice(0, 4), ...cleaned.slice(-20)];
  const wrapup =
    String(optionalCaseWrapup || "").replace(/\s+/g, " ").trim() ||
    buildCaseWrapupFromTranscript(cleaned);

  const controller = new AbortController();
  const timer = setTimeout(() => {
    controller.abort();
  }, Math.max(3000, Number(timeoutMs) || 70000));

  const requestPayload = {
    conversation,
    mode: mode === "text" ? "text" : "voice",
    optionalCaseWrapup: wrapup || undefined
  };
  const accessToken = await resolveAccessTokenForScore();
  if (!accessToken) {
    throw new Error("Skorlama için geçerli oturum bulunamadı.");
  }

  let response;
  try {
    response = await fetch("/api/score", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${accessToken}`
      },
      signal: controller.signal,
      body: JSON.stringify(requestPayload)
    });
  } catch (error) {
    if (error?.name === "AbortError") {
      throw new Error("SCORE_TIMEOUT");
    }
    throw error;
  } finally {
    clearTimeout(timer);
  }

  let body = await parseScoreResponse(response);

  if (!response.ok) {
    throw new Error(body.error || "Skor oluşturma başarısız");
  }
  if (!body || typeof body !== "object") {
    throw new Error("Skor servisinden beklenmeyen yanıt alındı.");
  }
  return body;
}

function collapseSpaces(text) {
  return String(text || "")
    .replace(/\s+/g, " ")
    .trim();
}

function firstSentence(text, maxLen = 96) {
  const cleaned = collapseSpaces(text);
  if (!cleaned) {
    return "";
  }
  const match = cleaned.match(/^(.*?[.!?])(\s|$)/);
  const sentence = match ? match[1] : cleaned;
  if (sentence.length <= maxLen) {
    return sentence;
  }
  return `${sentence.slice(0, maxLen - 1).trim()}...`;
}

function inferSpecialtyFromText(text) {
  const lower = text.toLowerCase();
  if (
    lower.includes("gogus agrisi") ||
    lower.includes("kalp") ||
    lower.includes("kardiyak") ||
    lower.includes("chest pain") ||
    lower.includes("troponin") ||
    lower.includes("ecg") ||
    lower.includes("ekg") ||
    lower.includes("cardiac")
  ) {
    return "Kardiyoloji";
  }
  if (
    lower.includes("karin agrisi") ||
    lower.includes("bulanti") ||
    lower.includes("kusma") ||
    lower.includes("abdominal") ||
    lower.includes("appendic") ||
    lower.includes("nausea") ||
    lower.includes("vomit")
  ) {
    return "Gastroenteroloji";
  }
  if (
    lower.includes("weakness") ||
    lower.includes("speech") ||
    lower.includes("stroke") ||
    lower.includes("seizure")
  ) {
    return "Nöroloji";
  }
  if (
    lower.includes("nefes darligi") ||
    lower.includes("oksuruk") ||
    lower.includes("dyspnea") ||
    lower.includes("shortness of breath") ||
    lower.includes("asthma") ||
    lower.includes("cough")
  ) {
    return "Göğüs Hastalıkları";
  }
  if (
    lower.includes("polyuria") ||
    lower.includes("polydipsia") ||
    lower.includes("insulin") ||
    lower.includes("glucose")
  ) {
    return "Endokrinoloji";
  }
  return "Genel Tıp";
}

function inferCaseTitleFromText(text) {
  const lower = text.toLowerCase();
  if (
    lower.includes("stemi") ||
    lower.includes("nstemi") ||
    lower.includes("myocardial infarction") ||
    lower.includes("mi")
  ) {
    return "Akut Koroner Sendrom";
  }
  if (lower.includes("pulmonary embol") || lower.includes("pulmoner embol")) {
    return "Pulmoner Emboli";
  }
  if (lower.includes("pneumonia") || lower.includes("pnomoni") || lower.includes("pnömoni")) {
    return "Pnömoni";
  }
  if (lower.includes("appendicitis") || lower.includes("apandisit")) {
    return "Akut Apandisit";
  }
  if (lower.includes("cholecystitis") || lower.includes("kolesistit")) {
    return "Akut Kolesistit";
  }
  if (lower.includes("stroke") || lower.includes("inme")) {
    return "Akut İnme";
  }
  if (lower.includes("chest pain") || lower.includes("gogus agrisi")) {
    return "Akut Göğüs Ağrısı";
  }
  if (lower.includes("abdominal pain") || lower.includes("karin agrisi")) {
    return "Akut Karın Ağrısı";
  }
  if (
    lower.includes("shortness of breath") ||
    lower.includes("dyspnea") ||
    lower.includes("nefes darligi")
  ) {
    return "İlerleyici Nefes Darlığı";
  }
  if (lower.includes("weakness") || lower.includes("stroke") || lower.includes("inme")) {
    return "Nörolojik Defisit";
  }
  if (lower.includes("fever") || lower.includes("ates")) {
    return "Kaynağı Belirsiz Ateş";
  }
  return "Oluşturulan Klinik Vaka";
}

export function deriveCaseContext(transcript, score) {
  const transcriptText = (Array.isArray(transcript) ? transcript : [])
    .map((item) => collapseSpaces(item.message))
    .filter(Boolean)
    .join(" ");

  const summaryText = collapseSpaces(score?.brief_summary || "");
  const combined = `${transcriptText} ${summaryText}`.trim();
  const specialty = inferSpecialtyFromText(combined);
  const trueDiagnosis = collapseSpaces(score?.true_diagnosis || "");
  const scoreTitle = collapseSpaces(score?.case_title || "");
  const title =
    trueDiagnosis && trueDiagnosis.toLowerCase() !== "kesin tanı paylaşılmadı"
      ? trueDiagnosis
      : scoreTitle || inferCaseTitleFromText(combined);
  const subtitle = firstSentence(summaryText || transcriptText, 98);

  return {
    title,
    specialty,
    subtitle: subtitle || "Vaka özeti konuşma kaydından oluşturuldu."
  };
}

export function getDimensionLabel(key) {
  return DIMENSION_LABELS[key] || key;
}

export function score10To100(score) {
  const numeric = Number(score);
  if (!Number.isFinite(numeric)) {
    return 0;
  }
  return Math.max(0, Math.min(100, Math.round(numeric * 10)));
}

export function sanitizeFeedbackText(input) {
  const raw = String(input || "");
  const replaced = raw
    .replace(/\b(katılımcı|katilimci|participant|student|öğrenci|ogrenci)\b/gi, "sen")
    .replace(/\b(transcript|transkript)\b/gi, "görüşme kaydı");

  return replaced
    .replace(/\s+/g, " ")
    .replace(/\s+([,.;!?])/g, "$1")
    .trim();
}

export function makeConciseText(input, maxSentences = 2, maxChars = 260) {
  const text = sanitizeFeedbackText(input);
  if (!text) {
    return "";
  }

  const sentenceMatches = text.match(/[^.!?]+[.!?]?/g) || [text];
  const picked = sentenceMatches
    .map((part) => part.trim())
    .filter(Boolean)
    .slice(0, Math.max(1, maxSentences))
    .join(" ");

  if (picked.length <= maxChars) {
    return picked;
  }
  return `${picked.slice(0, maxChars - 1).trim()}...`;
}
