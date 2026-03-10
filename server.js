import dotenv from "dotenv";
import express from "express";
import path from "path";
import crypto from "crypto";
import fs from "fs/promises";
import http2 from "http2";
import { fileURLToPath } from "url";
import OpenAI from "openai";
import { z } from "zod";
import * as Sentry from "@sentry/node";
import { serve as workflowServe } from "@upstash/workflow/express";
import { Client as WorkflowClient } from "@upstash/workflow";
import { Client as QStashClient } from "@upstash/qstash";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const envPath = path.join(__dirname, ".env");

function refreshEnv() {
  dotenv.config({ path: envPath, override: true });
}

function assertNoPublicSecretEnv() {
  const blockedPatterns = [
    /OPENAI/i,
    /ELEVENLABS/i,
    /UPSTASH/i,
    /AI_ADMIN/i,
    /SERVICE_ROLE/i,
    /_SECRET$/i,
    /_TOKEN$/i
  ];
  const violations = Object.keys(process.env || {}).filter((key) => {
    if (!/^NEXT_PUBLIC_/i.test(key)) {
      return false;
    }
    return blockedPatterns.some((pattern) => pattern.test(key));
  });

  if (violations.length > 0) {
    throw new Error(
      `Güvenlik hatası: Gizli değişkenler NEXT_PUBLIC_ olarak tanımlanamaz: ${violations.join(", ")}`
    );
  }
}

refreshEnv();
assertNoPublicSecretEnv();

const sentryCfg = getSentryConfig();
if (sentryCfg.dsn && sentryCfg.enabled) {
  Sentry.init({
    dsn: sentryCfg.dsn,
    environment: sentryCfg.environment || "development",
    tracesSampleRate: sentryCfg.tracesSampleRate
  });
}

const app = express();
const port = Number(process.env.PORT || 3000);
app.set("trust proxy", 1);
const model = process.env.OPENAI_MODEL || "gpt-5-mini";
const scoreModel = process.env.OPENAI_SCORE_MODEL || "gpt-4.1-nano";
const scoreRetryModel = process.env.OPENAI_SCORE_RETRY_MODEL || "gpt-4.1-mini";
const dailyChallengeModel = process.env.OPENAI_DAILY_CHALLENGE_MODEL || "gpt-4.1-mini";
const scoreRequestTimeoutMs = Math.max(
  8000,
  Math.min(45000, Number(process.env.OPENAI_SCORE_TIMEOUT_MS || 12000))
);
const scoreMaxOutputTokens = Math.max(
  900,
  Math.min(2600, Number(process.env.OPENAI_SCORE_MAX_OUTPUT_TOKENS || 1400))
);
const SCORE_CACHE_TTL_MS = 5 * 60 * 1000;
const SCORE_PROMPT_VERSION = "2026-03-09-r7-signal-gated";
const FLASHCARD_DRAFT_CACHE_TTL_MS = 24 * 60 * 60 * 1000;
const WEAK_AREA_CACHE_TTL_MS = 10 * 60 * 1000;
const WEAK_AREA_USER_CACHE_TTL_MS = 45 * 1000;
const WEAK_AREA_PROMPT_VERSION = "2026-03-09-r1";
const FLASHCARD_PROMPT_VERSION = "2026-03-08-r1";
const AI_PROMPT_CATALOG_VERSION = "2026-03-09-r1";
const DAILY_CHALLENGE_INSTRUCTIONS =
  "Tıbbi eğitim odaklı vaka üreticisisin. Güvenli, gerçekçi ve eğitim amaçlı kısa vaka üret. " +
  "Alanlar net, kısa ve uygulanabilir olsun. Tanıyı expectedDiagnosis alanına yaz. " +
  "Aynı kurguyu farklı başlıkla tekrar üretme.";
const FLASHCARD_GENERATION_INSTRUCTIONS =
  "Tıp vakası için yalnızca JSON üret. " +
  "Sadece verilen yapılandırılmış skor/geri bildirim verisini kullan; konuşma transkripti varsayma. " +
  "Flashcard'lar Türkçe ve kısa olmalı. " +
  "Her kartın önü soru, arkası net ve öğretici yanıt içersin. " +
  "Kart tipleri: diagnosis, drug, red_flag, differential, management, lab, imaging, procedure, concept. " +
  "Aynı bilgiyi tekrar etme. Klinik olarak doğru ve uygulanabilir içerik üret.";
const TEXT_AGENT_START_INSTRUCTIONS =
  "Sen tıp eğitimi için canlı vaka simülasyonu yapan klinik asistansın. " +
  "Sadece vaka giriş cümlesini üret. 1-2 kısa cümle yaz. " +
  "Sadece başvuru şikayeti ve kısa bağlam ver, tanıyı söyleme, çözüm verme, maddeli yazma. " +
  "Zorluk veya bölüm adını kullanıcıya tekrar etme. Türkçe yaz.";
const TEXT_AGENT_REPLY_INSTRUCTIONS =
  "Sen canlı klinik vaka simülasyonusun. Kullanıcı tıbbi karar verir, sen vaka akışını gerçekçi ilerletirsin. " +
  "Sadece bir sonraki kısa yanıtı ver (2-4 cümle). İpucu yağmuru yapma. " +
  "Tanıyı kullanıcı açıkça doğrulayana kadar açıklama. Güvenlik kritikse klinik sonucu göster. " +
  "Türkçe yaz. Zorluk/bölüm bilgisini kullanıcıya tekrar etme.";
const DEFAULT_ELEVENLABS_VOICE_AGENT_ID = "agent_3701kj62fctpe75v3a0tca39fy26";
const DEFAULT_ELEVENLABS_TEXT_AGENT_ID = "agent_3701kj62fctpe75v3a0tca39fy26";
const SCORE_SYSTEM_INSTRUCTIONS = [
  "You are a strict evaluator.",
  "Use only evidence from the conversation.",
  "Evaluate only the KULLANICI messages as performance evidence.",
  "Never use HASTA_VEYA_KOC lines as proof of user actions.",
  "Return valid JSON only.",
  "Generate case_title as a short Turkish title. If diagnosis is explicit, use diagnosis-focused title.",
  "Return true_diagnosis as the actual diagnosis from wrapup/coach statements. If explicit diagnosis is absent, infer the most likely diagnosis from clinical flow.",
  "Return user_diagnosis as what the user explicitly diagnosed; if none, use Belirtilmedi.",
  "Do not set true_diagnosis from user guesses unless coach/wrapup explicitly confirms it.",
  "Write all free-text feedback fields in Turkish.",
  "Address the user directly in second person singular (sen/senin).",
  "Do not use these words in output fields: OpenAI, participant, katilimci, student, ogrenci, transcript, transkript.",
  "Do not repeat generic improvement lines. Improvements must be concrete and distinct.",
  "Keep brief_summary short (maximum 2 concise sentences)."
].join(" ");
const SCORE_REPAIR_INSTRUCTIONS =
  "Return only valid JSON matching the requested schema. Do not add markdown or commentary.";
const FLASHCARD_ALLOWED_TYPES = Object.freeze([
  "diagnosis",
  "drug",
  "red_flag",
  "differential",
  "management",
  "lab",
  "imaging",
  "procedure",
  "concept"
]);
const FLASHCARD_TYPE_ALIASES = Object.freeze({
  tani: "diagnosis",
  tani_karti: "diagnosis",
  diagnosis: "diagnosis",
  drug: "drug",
  ilac: "drug",
  redflag: "red_flag",
  red_flag: "red_flag",
  kirmizi_bayrak: "red_flag",
  kirmizi_bayraklar: "red_flag",
  differential: "differential",
  differential_diagnosis: "differential",
  ayirici_tani: "differential",
  management: "management",
  yonetim: "management",
  lab: "lab",
  laboratuvar: "lab",
  imaging: "imaging",
  goruntuleme: "imaging",
  procedure: "procedure",
  prosedur: "procedure",
  concept: "concept",
  kavram: "concept"
});
const WEAK_AREA_DIMENSION_META = Object.freeze([
  { key: "data_gathering_quality", label: "Veri Toplama", shortLabel: "Veri" },
  { key: "clinical_reasoning_logic", label: "Klinik Akıl Yürütme", shortLabel: "Akıl" },
  { key: "differential_diagnosis_depth", label: "Ayırıcı Tanı", shortLabel: "Ayırıcı" },
  { key: "diagnostic_efficiency", label: "Tanısal Verim", shortLabel: "Verim" },
  { key: "management_plan_quality", label: "Yönetim Planı", shortLabel: "Yönetim" },
  { key: "safety_red_flags", label: "Güvenlik / Kırmızı Bayrak", shortLabel: "Güvenlik" },
  { key: "decision_timing", label: "Karar Zamanlaması", shortLabel: "Zaman" },
  { key: "communication_clarity", label: "İletişim", shortLabel: "İletişim" },
  { key: "guideline_consistency", label: "Kılavuz Uyumu", shortLabel: "Kılavuz" },
  { key: "professionalism_empathy", label: "Profesyonellik / Empati", shortLabel: "Empati" }
]);
const WEAK_AREA_DIMENSION_KEY_SET = new Set(WEAK_AREA_DIMENSION_META.map((item) => item.key));
const WEAK_AREA_SPECIALTY_LABEL_MAP = Object.freeze({
  Cardiology: "Kardiyoloji",
  Pulmonology: "Pulmonoloji",
  Gastroenterology: "Gastroenteroloji",
  Endocrinology: "Endokrinoloji",
  Nephrology: "Nefroloji",
  "Infectious Diseases": "Enfeksiyon Hastalıkları",
  Rheumatology: "Romatoloji",
  Hematology: "Hematoloji",
  Oncology: "Onkoloji",
  "Emergency Medicine": "Acil Tıp",
  "Critical Care Medicine": "Yoğun Bakım",
  Neurology: "Nöroloji",
  Psychiatry: "Psikiyatri",
  "Neurocritical Care-Toxicology": "Nörokritik Bakım-Toksikoloji",
  "General Surgery": "Genel Cerrahi",
  "Vascular Surgery": "Vasküler Cerrahi",
  "Cardiothoracic Surgery": "Kardiyotorasik Cerrahi",
  Neurosurgery: "Nöroşirürji",
  "Orthopedic Surgery": "Ortopedi",
  "Plastic Surgery": "Plastik Cerrahi",
  "Trauma Surgery": "Travma Cerrahisi",
  Obstetrics: "Obstetri",
  Gynecology: "Jinekoloji",
  "General Pediatrics": "Genel Pediatri",
  "Pediatric Emergency": "Pediatrik Acil",
  Dermatology: "Dermatoloji",
  Neonatology: "Neonatoloji",
  Ophthalmology: "Oftalmoloji",
  "Otolaryngology (ENT)": "Kulak Burun Boğaz",
  "Geriatric Medicine": "Geriatri",
  Urology: "Üroloji"
});
const scoreCache = new Map();
const flashcardDraftCache = new Map();
const weakAreaCache = new Map();
const weakAreaUserSnapshotCache = new Map();
const rateLimitStore = new Map();
const authFailureStore = new Map();
const activeElevenSessionStore = new Map();
const dailyChallengeCache = new Map();
const dailyChallengeWarmupLocks = new Set();
const suspiciousAlertStore = new Map();
const spamFingerprintStore = new Map();
const runtimeErrorLogStore = [];
const apiRequestRuntimeStore = [];
const APP_ERROR_LOG_TTL_SECONDS = 60 * 60 * 24 * 14;
const ERROR_CODES = Object.freeze({
  UNKNOWN: "UNKNOWN",
  VALIDATION: "VALIDATION",
  AUTH_REQUIRED: "AUTH_REQUIRED",
  AUTH_FORBIDDEN: "AUTH_FORBIDDEN",
  RATE_LIMIT: "RATE_LIMIT",
  UPSTASH_UNAVAILABLE: "UPSTASH_UNAVAILABLE",
  SUPABASE_UNAVAILABLE: "SUPABASE_UNAVAILABLE",
  ELEVENLABS_UNAVAILABLE: "ELEVENLABS_UNAVAILABLE",
  OPENAI_UNAVAILABLE: "OPENAI_UNAVAILABLE",
  EXTERNAL_TIMEOUT: "EXTERNAL_TIMEOUT",
  INTERNAL: "INTERNAL"
});
const UPSTASH_TIMEOUT_MS = 4000;
const SUPABASE_SCHEMA_SQL_FILES = [
  path.join(__dirname, "supabase", "profiles.sql"),
  path.join(__dirname, "supabase", "case_sessions.sql"),
  path.join(__dirname, "supabase", "daily_challenges.sql"),
  path.join(__dirname, "supabase", "flashcards.sql"),
  path.join(__dirname, "supabase", "content_reports.sql"),
  path.join(__dirname, "supabase", "user_feedback.sql"),
  path.join(__dirname, "supabase", "platform_ops.sql"),
  path.join(__dirname, "supabase", "push_broadcast.sql")
];
const DAILY_WORKFLOW_ROUTE_PATH = "/api/workflow/daily-challenge";
const DAILY_CHALLENGE_TEMPLATES = [
  {
    slug: "appendisit",
    title: "Akut Appendisit Şüphesi",
    specialty: "Genel Cerrahi",
    difficulty: "Kolay",
    summary: "22 yaş erkek hastada sağ alt kadran ağrısı ve bulantı ile cerrahi değerlendirme.",
    chiefComplaint: "Sağ alt kadran karın ağrısı",
    patientGender: "Erkek",
    patientAge: 22,
    expectedDiagnosis: "Akut appendisit",
    seedFocus: "anamnez + fizik muayene + zamanında cerrahi karar"
  },
  {
    slug: "nstemi",
    title: "Göğüs Ağrısı - Olası NSTEMI",
    specialty: "Kardiyoloji",
    difficulty: "Orta",
    summary: "58 yaş hastada tipik olmayan göğüs ağrısında risk sınıflaması ve tanısal yolak.",
    chiefComplaint: "Göğüste baskı tarzı ağrı",
    patientGender: "Erkek",
    patientAge: 58,
    expectedDiagnosis: "NSTEMI",
    seedFocus: "risk değerlendirmesi, EKG-troponin zamanlaması"
  },
  {
    slug: "astim-atak",
    title: "Astım Alevlenmesi Yönetimi",
    specialty: "Göğüs Hastalıkları",
    difficulty: "Kolay",
    summary: "Genç erişkinde nefes darlığı ve wheezing ile akut atak yönetimi.",
    chiefComplaint: "Nefes darlığı ve hışıltı",
    patientGender: "Kadın",
    patientAge: 27,
    expectedDiagnosis: "Akut astım alevlenmesi",
    seedFocus: "şiddet değerlendirmesi, bronkodilatör ve güvenlik adımları"
  },
  {
    slug: "inme-acil",
    title: "Akut İnme Değerlendirmesi",
    specialty: "Nöroloji",
    difficulty: "Zor",
    summary: "Ani konuşma bozukluğu ve hemiparezi ile gelen hastada hızlı nörolojik karar akışı.",
    chiefComplaint: "Ani gelişen konuşma bozukluğu",
    patientGender: "Kadın",
    patientAge: 69,
    expectedDiagnosis: "Akut iskemik inme",
    seedFocus: "zaman penceresi, kontraendikasyonlar, hızlı görüntüleme"
  },
  {
    slug: "dka",
    title: "Diyabetik Ketoasidoz Şüphesi",
    specialty: "Endokrinoloji",
    difficulty: "Orta",
    summary: "Polidipsi, bulantı ve taşipne ile başvuran hastada metabolik acil yönetimi.",
    chiefComplaint: "Bulantı, kusma ve halsizlik",
    patientGender: "Erkek",
    patientAge: 24,
    expectedDiagnosis: "Diyabetik ketoasidoz",
    seedFocus: "sıvı-elektrolit-insülin sıralaması ve monitorizasyon"
  },
  {
    slug: "ektopik-gebelik",
    title: "Ektopik Gebelik Acili",
    specialty: "Kadın Doğum",
    difficulty: "Orta",
    summary: "Alt karın ağrısı ve adet gecikmesi olan hastada jinekolojik acil ayırıcı tanı.",
    chiefComplaint: "Alt karın ağrısı ve lekelenme",
    patientGender: "Kadın",
    patientAge: 31,
    expectedDiagnosis: "Ektopik gebelik",
    seedFocus: "hemodinami, β-hCG ve ultrason korelasyonu"
  },
  {
    slug: "sepsis",
    title: "Sepsis Erken Tanı ve Yönetimi",
    specialty: "Acil Tıp",
    difficulty: "Zor",
    summary: "Ateş, hipotansiyon ve taşikardi ile gelen hastada sepsis paketinin zamanında uygulanması.",
    chiefComplaint: "Ateş ve halsizlik",
    patientGender: "Erkek",
    patientAge: 64,
    expectedDiagnosis: "Sepsis",
    seedFocus: "erken antibiyotik, sıvı tedavisi, organ disfonksiyonu takibi"
  },
  {
    slug: "pyelonefrit",
    title: "Komplike Üriner Enfeksiyon",
    specialty: "Enfeksiyon Hastalıkları",
    difficulty: "Kolay",
    summary: "Yan ağrısı ve ateş ile başvuran hastada üst üriner enfeksiyon yönetimi.",
    chiefComplaint: "Yan ağrısı ve ateş",
    patientGender: "Kadın",
    patientAge: 35,
    expectedDiagnosis: "Akut piyelonefrit",
    seedFocus: "odak sorgulama, uygun tetkik ve tedavi seçimi"
  },
  {
    slug: "aki",
    title: "Akut Böbrek Hasarı Değerlendirmesi",
    specialty: "Nefroloji",
    difficulty: "Orta",
    summary: "Az idrar çıkışı ve kreatinin yükselişi ile başvuran hastada etyoloji ayrımı.",
    chiefComplaint: "İdrar miktarında azalma",
    patientGender: "Erkek",
    patientAge: 72,
    expectedDiagnosis: "Akut böbrek hasarı",
    seedFocus: "prerenal/renal/postrenal ayrımı ve ilk yaklaşım"
  },
  {
    slug: "bronsiyolit",
    title: "Pediatrik Solunum Sıkıntısı",
    specialty: "Pediatri",
    difficulty: "Kolay",
    summary: "Bebekte öksürük ve beslenme azalması ile solunum sıkıntısı değerlendirmesi.",
    chiefComplaint: "Öksürük ve hızlı solunum",
    patientGender: "Erkek",
    patientAge: 1,
    expectedDiagnosis: "Akut bronşiolit",
    seedFocus: "klinik şiddet sınıflaması ve destek tedavisi"
  }
];

function getSupabaseConfig() {
  refreshEnv();
  return {
    supabaseUrl: process.env.SUPABASE_URL || "",
    supabaseAnonKey: process.env.SUPABASE_ANON_KEY || "",
    supabaseServiceRoleKey: process.env.SUPABASE_SERVICE_ROLE_KEY || "",
    authorizationUrl: process.env.AUTHORIZATION_URL || "http://localhost:6000/oauth/consent"
  };
}

function getResendConfig() {
  refreshEnv();
  const fromEmailRaw = String(process.env.RESEND_FROM_EMAIL || "").trim();
  const fromNameRaw = String(process.env.RESEND_FROM_NAME || "Dr.Kynox").trim();
  const verifyRedirectRaw = String(
    process.env.EMAIL_VERIFY_REDIRECT_URL || process.env.APP_DEEP_LINK_URL || "drkynox://auth/login"
  ).trim();

  return {
    apiKey: String(process.env.RESEND_API_KEY || "").trim(),
    fromEmail: fromEmailRaw,
    fromName: fromNameRaw || "Dr.Kynox",
    verifyRedirectUrl: verifyRedirectRaw || "drkynox://auth/login"
  };
}

function appendQueryParam(rawUrl, key, value) {
  const raw = String(rawUrl || "").trim();
  const safeKey = String(key || "").trim();
  if (!raw || !safeKey) {
    return raw;
  }
  try {
    const parsed = new URL(raw);
    parsed.searchParams.set(safeKey, String(value ?? ""));
    return parsed.toString();
  } catch {
    return raw;
  }
}

function getLegalConfig() {
  refreshEnv();
  const supportEmail = String(process.env.APP_SUPPORT_EMAIL || "support@medcase.website")
    .trim()
    .toLowerCase();
  const lastUpdated = String(process.env.LEGAL_LAST_UPDATED || "7 Mart 2026").trim() || "7 Mart 2026";
  const appDeepLink = String(process.env.APP_DEEP_LINK_URL || "drkynox://auth/login").trim() || "drkynox://auth/login";

  return {
    supportEmail,
    lastUpdated,
    appDeepLink
  };
}

function getAdminPanelConfig() {
  refreshEnv();
  return {
    username: String(process.env.ADMIN_USERNAME || "").trim(),
    password: String(process.env.ADMIN_PASSWORD || "").trim(),
    sessionSecret: String(process.env.ADMIN_SESSION_SECRET || "").trim(),
    sessionTtlSec: clampRateLimitValue(process.env.ADMIN_SESSION_TTL_SEC, 8 * 60 * 60, 10 * 60, 48 * 60 * 60)
  };
}

function getApnsConfig() {
  refreshEnv();
  const keyId = String(process.env.APNS_KEY_ID || "").trim();
  const teamId = String(process.env.APNS_TEAM_ID || "").trim();
  const bundleId = String(process.env.APNS_BUNDLE_ID || "").trim();
  const rawPrivateKey = String(process.env.APNS_PRIVATE_KEY || "").trim();
  const privateKey = rawPrivateKey.replace(/\\n/g, "\n");
  const useSandboxRaw = String(process.env.APNS_USE_SANDBOX || process.env.APNS_ENV || "")
    .trim()
    .toLowerCase();
  const environment = useSandboxRaw === "1" || useSandboxRaw === "true" || useSandboxRaw === "sandbox"
    ? "sandbox"
    : "production";
  return {
    keyId,
    teamId,
    bundleId,
    privateKey,
    environment
  };
}

function getSentryConfig() {
  refreshEnv();
  return {
    dsn: String(process.env.SENTRY_DSN || "").trim(),
    environment: String(process.env.SENTRY_ENVIRONMENT || process.env.NODE_ENV || "development").trim(),
    tracesSampleRate: Math.max(
      0,
      Math.min(1, Number(process.env.SENTRY_TRACES_SAMPLE_RATE || 0))
    ),
    enabled:
      String(process.env.SENTRY_ENABLED || "").trim().toLowerCase() === "true" ||
      String(process.env.SENTRY_ENABLED || "").trim() === "1"
  };
}

function getDebugErrorConfig() {
  refreshEnv();
  const enabledRaw = String(process.env.DEBUG_ERROR_SIMULATION_ENABLED || "")
    .trim()
    .toLowerCase();
  return {
    enabled: enabledRaw === "true" || enabledRaw === "1" || enabledRaw === "yes"
  };
}

function isDebugFlagEnabled(envName) {
  const raw = String(process.env?.[envName] || "")
    .trim()
    .toLowerCase();
  return raw === "true" || raw === "1" || raw === "yes" || raw === "on";
}

class AppError extends Error {
  constructor({
    message,
    code = ERROR_CODES.INTERNAL,
    status = 500,
    service = "app",
    details = null,
    expose = true,
    cause = null
  } = {}) {
    super(String(message || "Bilinmeyen hata."));
    this.name = "AppError";
    this.code = String(code || ERROR_CODES.INTERNAL);
    this.status = Number.isFinite(Number(status)) ? Number(status) : 500;
    this.service = String(service || "app").slice(0, 48) || "app";
    this.details = details && typeof details === "object" ? details : null;
    this.expose = expose !== false;
    if (cause) {
      this.cause = cause;
    }
  }
}

function isAppError(error) {
  return error instanceof AppError;
}

function toAppError(error, fallback = {}) {
  if (isAppError(error)) {
    return error;
  }
  const fallbackStatus = Number.isFinite(Number(fallback?.status)) ? Number(fallback.status) : 500;
  const fallbackCode = String(fallback?.code || ERROR_CODES.INTERNAL);
  const fallbackService = String(fallback?.service || "app");
  const statusFromError = Number(error?.status || error?.statusCode || 0);
  const status = statusFromError >= 100 && statusFromError <= 599 ? statusFromError : fallbackStatus;
  const message =
    typeof error?.message === "string" && error.message.trim()
      ? error.message.trim()
      : String(fallback?.message || "Bilinmeyen hata.");

  return new AppError({
    message,
    status,
    code: fallbackCode,
    service: fallbackService,
    details: fallback?.details || null,
    expose: fallback?.expose !== false,
    cause: error
  });
}

function mapStatusToErrorCode(statusCode) {
  const status = Number(statusCode || 0);
  if (status === 400) {
    return ERROR_CODES.VALIDATION;
  }
  if (status === 401) {
    return ERROR_CODES.AUTH_REQUIRED;
  }
  if (status === 403) {
    return ERROR_CODES.AUTH_FORBIDDEN;
  }
  if (status === 429) {
    return ERROR_CODES.RATE_LIMIT;
  }
  if (status === 503 || status === 504) {
    return ERROR_CODES.EXTERNAL_TIMEOUT;
  }
  return ERROR_CODES.INTERNAL;
}

function normalizeErrorForLog(error, fallback = {}) {
  const appError = toAppError(error, fallback);
  const status = Number(appError.status || 500);
  const code = String(appError.code || mapStatusToErrorCode(status));
  return {
    appError: new AppError({
      message: appError.message,
      service: appError.service,
      details: appError.details,
      expose: appError.expose,
      cause: appError.cause,
      status,
      code
    }),
    status,
    code
  };
}

function extractDebugErrorCase(req) {
  const fromHeader = String(req?.headers?.["x-debug-simulate-error"] || "")
    .trim()
    .toLowerCase();
  if (fromHeader) {
    return fromHeader;
  }
  const fromQuery = String(req?.query?.debugError || "")
    .trim()
    .toLowerCase();
  if (fromQuery) {
    return fromQuery;
  }
  const fromBody = String(req?.body?.debugError || "")
    .trim()
    .toLowerCase();
  if (fromBody) {
    return fromBody;
  }
  return "";
}

function maybeSimulateServiceError(req, serviceName, options = {}) {
  const cfg = getDebugErrorConfig();
  const normalizedService = String(serviceName || "")
    .trim()
    .toLowerCase();
  const envForceName = `DEBUG_FORCE_${normalizedService.replace(/[^a-z0-9]/gi, "_").toUpperCase()}_ERROR`;
  const forceByEnv = cfg.enabled && isDebugFlagEnabled(envForceName);
  if (!cfg.enabled) {
    return;
  }
  const requestedCase = extractDebugErrorCase(req);
  if (!requestedCase && !forceByEnv) {
    return;
  }
  const allowed = new Set([
    normalizedService,
    `${normalizedService}:down`,
    `${normalizedService}:timeout`,
    `${normalizedService}:error`,
    "all"
  ]);
  if (!forceByEnv && !allowed.has(requestedCase)) {
    return;
  }
  const timeoutStyle = forceByEnv ? false : requestedCase.includes("timeout");
  const activeCase = forceByEnv ? `${normalizedService}:env` : requestedCase;
  throw new AppError({
    message: timeoutStyle
      ? `${serviceName} debug simülasyon timeout hatası`
      : `${serviceName} debug simülasyon hatası`,
    code: timeoutStyle ? ERROR_CODES.EXTERNAL_TIMEOUT : options.code || ERROR_CODES.INTERNAL,
    status: Number(options.status || (timeoutStyle ? 504 : 503)),
    service: normalizedService || "debug",
    details: {
      simulated: true,
      debug_case: activeCase
    },
    expose: true
  });
}

function formatZodErrors(error) {
  if (!error?.issues || !Array.isArray(error.issues)) {
    return "Geçersiz istek gövdesi.";
  }
  return error.issues
    .slice(0, 5)
    .map((issue) => {
      const pathText = Array.isArray(issue.path) && issue.path.length ? issue.path.join(".") : "body";
      return `${pathText}: ${issue.message}`;
    })
    .join(" | ");
}

function parseJsonWithZod(res, schema, payload, { message = "Geçersiz istek gövdesi." } = {}) {
  const parsed = schema.safeParse(payload ?? {});
  if (!parsed.success) {
    res.status(400).json({
      error: `${message} ${formatZodErrors(parsed.error)}`
    });
    return null;
  }
  return parsed.data;
}

function rejectUnsupportedMethod(req, res, allowedMethod, endpointPath) {
  if (String(req.method || "").toUpperCase() === String(allowedMethod || "POST").toUpperCase()) {
    return false;
  }
  res.status(405).json({
    error: `Bu endpoint yalnızca ${String(allowedMethod || "POST").toUpperCase()} kabul eder.`,
    method_required: String(allowedMethod || "POST").toUpperCase(),
    endpoint: endpointPath || req.originalUrl || req.url || ""
  });
  return true;
}

function getSuspiciousSecurityConfig() {
  return {
    failedAuthThresholdPerHour: clampRateLimitValue(
      process.env.SUSPICIOUS_FAILED_AUTH_PER_HOUR,
      5,
      3,
      80
    ),
    failedAuthWindowMs: clampRateLimitValue(
      process.env.SUSPICIOUS_FAILED_AUTH_WINDOW_MS,
      60 * 60_000,
      5 * 60_000,
      24 * 60 * 60_000
    ),
    caseStartThresholdPerHour: clampRateLimitValue(
      process.env.SUSPICIOUS_CASE_START_PER_HOUR,
      30,
      10,
      500
    ),
    caseStartWindowMs: clampRateLimitValue(
      process.env.SUSPICIOUS_CASE_START_WINDOW_MS,
      60 * 60_000,
      10 * 60_000,
      24 * 60 * 60_000
    ),
    alertCooldownMs: clampRateLimitValue(
      process.env.SUSPICIOUS_ALERT_COOLDOWN_MS,
      15 * 60_000,
      60_000,
      24 * 60 * 60_000
    )
  };
}

function safeConstantCompare(a, b) {
  const left = Buffer.from(String(a || ""), "utf8");
  const right = Buffer.from(String(b || ""), "utf8");
  if (left.length !== right.length) {
    return false;
  }
  return crypto.timingSafeEqual(left, right);
}

function parseCookieHeader(rawCookieHeader) {
  const cookieHeader = String(rawCookieHeader || "");
  const pairs = cookieHeader.split(";").map((item) => item.trim()).filter(Boolean);
  const out = {};
  for (const pair of pairs) {
    const idx = pair.indexOf("=");
    if (idx <= 0) {
      continue;
    }
    const key = pair.slice(0, idx).trim();
    const value = pair.slice(idx + 1).trim();
    if (!key) {
      continue;
    }
    try {
      out[key] = decodeURIComponent(value);
    } catch {
      out[key] = value;
    }
  }
  return out;
}

function serializeCookie(name, value, options = {}) {
  const key = String(name || "").trim();
  if (!key) {
    return "";
  }
  const attrs = [`${key}=${encodeURIComponent(String(value || ""))}`];
  attrs.push(`Path=${options.path || "/"}`);
  if (Number.isFinite(Number(options.maxAge))) {
    attrs.push(`Max-Age=${Math.max(0, Math.floor(Number(options.maxAge)))}`);
  }
  if (options.httpOnly !== false) {
    attrs.push("HttpOnly");
  }
  if (options.secure) {
    attrs.push("Secure");
  }
  attrs.push(`SameSite=${options.sameSite || "Lax"}`);
  return attrs.join("; ");
}

function getSupabaseBootstrapConfig() {
  refreshEnv();
  const managementToken = String(
    process.env.SUPABASE_MANAGEMENT_TOKEN || process.env.SUPABASE_ACCESS_TOKEN || ""
  ).trim();
  const autoApplyRaw = String(process.env.SUPABASE_SCHEMA_AUTO_APPLY || "")
    .trim()
    .toLowerCase();
  return {
    managementToken,
    autoApply: autoApplyRaw === "true" || autoApplyRaw === "1" || autoApplyRaw === "yes"
  };
}

function getQStashConfig() {
  refreshEnv();
  const normalizeBase = (value) => {
    const raw = String(value || "").trim();
    if (!raw) {
      return "";
    }
    return raw.replace(/\/+$/g, "");
  };

  return {
    qstashUrl: normalizeBase(process.env.QSTASH_URL || ""),
    qstashToken: String(process.env.QSTASH_TOKEN || "").trim(),
    currentSigningKey: String(process.env.QSTASH_CURRENT_SIGNING_KEY || "").trim(),
    nextSigningKey: String(process.env.QSTASH_NEXT_SIGNING_KEY || "").trim(),
    workflowPublicBaseUrl: normalizeBase(
      process.env.WORKFLOW_PUBLIC_BASE_URL ||
        process.env.PUBLIC_BASE_URL ||
        process.env.APP_BASE_URL ||
        ""
    ),
    dailyWorkflowCron: String(process.env.QSTASH_DAILY_WORKFLOW_CRON || "0 0 * * *").trim() || "0 0 * * *",
    dailyWorkflowScheduleId:
      String(process.env.QSTASH_DAILY_WORKFLOW_SCHEDULE_ID || "daily-challenge-refresh-v1").trim() ||
      "daily-challenge-refresh-v1",
    autoSetupSchedule:
      String(process.env.QSTASH_DAILY_SCHEDULE_AUTO_SETUP || "")
        .trim()
        .toLowerCase() === "true"
  };
}

function isQStashWorkflowConfigured() {
  const cfg = getQStashConfig();
  return Boolean(cfg.qstashUrl && cfg.qstashToken && cfg.currentSigningKey && cfg.nextSigningKey);
}

function resolveWorkflowBaseUrl(req = null) {
  const cfg = getQStashConfig();
  if (cfg.workflowPublicBaseUrl) {
    return cfg.workflowPublicBaseUrl;
  }

  const vercelUrl = String(process.env.VERCEL_URL || "").trim();
  if (vercelUrl) {
    if (/^https?:\/\//i.test(vercelUrl)) {
      return vercelUrl.replace(/\/+$/g, "");
    }
    return `https://${vercelUrl.replace(/\/+$/g, "")}`;
  }

  if (req) {
    const protocol = String(req.protocol || "https");
    const host = String(req.get?.("host") || req.headers?.host || "").trim();
    if (host) {
      return `${protocol}://${host}`.replace(/\/+$/g, "");
    }
  }

  return "";
}

function extractSupabaseProjectRef(supabaseUrl) {
  try {
    const parsed = new URL(String(supabaseUrl || ""));
    const host = String(parsed.hostname || "");
    const ref = host.split(".")[0] || "";
    return ref.trim();
  } catch {
    return "";
  }
}

async function readSupabaseSchemaFiles() {
  const files = [];
  for (const absPath of SUPABASE_SCHEMA_SQL_FILES) {
    const sql = await fs.readFile(absPath, "utf8");
    const compact = String(sql || "").trim();
    if (!compact) {
      continue;
    }
    files.push({
      name: path.basename(absPath),
      absPath,
      sql: compact
    });
  }
  return files;
}

async function runSupabaseSqlViaManagementApi({ supabaseUrl, managementToken, sql }) {
  const projectRef = extractSupabaseProjectRef(supabaseUrl);
  if (!projectRef || !managementToken) {
    throw new Error("Supabase Management API için project ref veya token eksik.");
  }

  const endpoint = `https://api.supabase.com/v1/projects/${projectRef}/database/query`;
  const resp = await fetch(endpoint, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${managementToken}`,
      "Content-Type": "application/json"
    },
    body: JSON.stringify({
      query: sql
    })
  });

  const raw = await resp.text();
  let payload = null;
  try {
    payload = raw ? JSON.parse(raw) : null;
  } catch {
    payload = raw;
  }

  if (!resp.ok) {
    const err = new Error(
      `Management API SQL hatası (${resp.status}): ${
        typeof payload === "string" ? payload.slice(0, 260) : JSON.stringify(payload).slice(0, 260)
      }`
    );
    err.status = resp.status;
    throw err;
  }
  return payload;
}

async function runSupabaseSqlViaProjectDataApi({ supabaseUrl, supabaseServiceRoleKey, sql }) {
  const base = String(supabaseUrl || "").trim().replace(/\/+$/g, "");
  if (!base || !supabaseServiceRoleKey) {
    throw new Error("Project Data API SQL için Supabase URL veya service role key eksik.");
  }

  const attempts = [
    `${base}/sql/v1`,
    `${base}/pg/v1/query`,
    `${base}/rest/v1/rpc/exec_sql`
  ];
  let lastError = "SQL endpoint başarısız.";

  for (const endpoint of attempts) {
    try {
      const resp = await fetch(endpoint, {
        method: "POST",
        headers: {
          apikey: supabaseServiceRoleKey,
          Authorization: `Bearer ${supabaseServiceRoleKey}`,
          "Content-Type": "application/json"
        },
        body: JSON.stringify({
          query: sql
        })
      });
      const raw = await resp.text();
      if (!resp.ok) {
        lastError = `${endpoint} -> ${resp.status}: ${raw.slice(0, 220)}`;
        continue;
      }
      try {
        return raw ? JSON.parse(raw) : null;
      } catch {
        return raw;
      }
    } catch (error) {
      lastError = `${endpoint} -> ${error?.message || "Bilinmeyen hata"}`;
    }
  }

  throw new Error(lastError);
}

async function applySupabaseSchemaBundle({
  supabaseUrl,
  supabaseServiceRoleKey,
  managementToken,
  preferredEngine = "auto"
}) {
  const files = await readSupabaseSchemaFiles();
  if (!files.length) {
    return {
      ok: true,
      applied: [],
      engine: "none"
    };
  }

  const allowed = new Set(["auto", "management", "data-api"]);
  const mode = allowed.has(preferredEngine) ? preferredEngine : "auto";
  const order =
    mode === "management"
      ? ["management", "data-api"]
      : mode === "data-api"
        ? ["data-api", "management"]
        : ["management", "data-api"];

  const applied = [];
  let selectedEngine = null;

  for (const file of files) {
    let done = false;
    let lastError = null;

    for (const engine of order) {
      try {
        if (engine === "management" && managementToken) {
          await runSupabaseSqlViaManagementApi({
            supabaseUrl,
            managementToken,
            sql: file.sql
          });
          selectedEngine = selectedEngine || "management";
          applied.push({
            file: file.name,
            engine: "management",
            ok: true
          });
          done = true;
          break;
        }

        if (engine === "data-api") {
          await runSupabaseSqlViaProjectDataApi({
            supabaseUrl,
            supabaseServiceRoleKey,
            sql: file.sql
          });
          selectedEngine = selectedEngine || "data-api";
          applied.push({
            file: file.name,
            engine: "data-api",
            ok: true
          });
          done = true;
          break;
        }
      } catch (error) {
        lastError = error;
      }
    }

    if (!done) {
      const err = new Error(
        `Supabase şema kurulumu başarısız (${file.name}): ${lastError?.message || "Bilinmeyen hata"}`
      );
      err.details = {
        file: file.name,
        absolutePath: file.absPath,
        message: lastError?.message || "Bilinmeyen hata"
      };
      throw err;
    }
  }

  return {
    ok: true,
    engine: selectedEngine || "unknown",
    applied
  };
}

function getElevenLabsConfig() {
  refreshEnv();
  const { voiceAgentId, textAgentId } = getElevenLabsAgentModeConfig();
  const envAllowedAgentIds = String(process.env.ELEVENLABS_ALLOWED_AGENT_IDS || "")
    .split(",")
    .map((item) => item.trim())
    .filter(Boolean);
  const allowedAgentIds = Array.from(
    new Set([...envAllowedAgentIds, voiceAgentId, textAgentId].filter(Boolean))
  );
  return {
    elevenLabsApiKey: process.env.ELEVENLABS_API_KEY || "",
    elevenLabsApiBase: process.env.ELEVENLABS_API_BASE || "https://api.elevenlabs.io",
    allowedAgentIds
  };
}

function getElevenLabsAgentModeConfig() {
  refreshEnv();
  const configuredVoiceAgentId = sanitizeAgentId(process.env.ELEVENLABS_VOICE_AGENT_ID);
  const configuredTextAgentId = sanitizeAgentId(process.env.ELEVENLABS_TEXT_AGENT_ID);
  return {
    voiceAgentId: configuredVoiceAgentId || DEFAULT_ELEVENLABS_VOICE_AGENT_ID,
    textAgentId: configuredTextAgentId || DEFAULT_ELEVENLABS_TEXT_AGENT_ID
  };
}

function getAiAccessConfig() {
  refreshEnv();
  const rawGlobal = String(process.env.AI_FEATURES_ENABLED || "true")
    .trim()
    .toLowerCase();
  return {
    globalEnabled: !(rawGlobal === "false" || rawGlobal === "0" || rawGlobal === "off"),
    adminToken: String(process.env.AI_ADMIN_TOKEN || "").trim()
  };
}

function sanitizeAgentId(value) {
  const id = String(value || "").trim();
  if (!id) {
    return "";
  }
  if (!/^agent_[a-z0-9]+$/i.test(id)) {
    return "";
  }
  return id;
}

function sanitizeDynamicVariables(input) {
  if (!input || typeof input !== "object" || Array.isArray(input)) {
    return {};
  }

  const output = {};
  const entries = Object.entries(input).slice(0, 40);
  for (const [rawKey, rawValue] of entries) {
    const key = String(rawKey || "")
      .trim()
      .replace(/[^a-z0-9_]/gi, "")
      .slice(0, 64);
    if (!key) {
      continue;
    }

    const value = String(rawValue ?? "")
      .trim()
      .replace(/\s+/g, " ")
      .slice(0, 280);
    if (!value) {
      continue;
    }
    output[key] = value;
  }

  return output;
}

function normalizeTextAgentSource(raw) {
  const value = String(raw || "")
    .toLocaleLowerCase("tr-TR")
    .trim();
  if (value === "user" || value === "you" || value === "kullanici" || value === "kullanıcı") {
    return "user";
  }
  return "ai";
}

function normalizeTextAgentConversation(raw) {
  if (!Array.isArray(raw)) {
    return [];
  }

  return raw
    .map((item) => {
      const message = sanitizeChallengeLine(item?.message || item?.content || "", 340);
      if (!message) {
        return null;
      }
      return {
        source: normalizeTextAgentSource(item?.source || item?.speaker || item?.role),
        message
      };
    })
    .filter(Boolean)
    .slice(-30);
}

function computeConversationUsage(list) {
  const rows = Array.isArray(list) ? list : [];
  const totalMessages = rows.length;
  const userMessages = rows.filter((item) => item?.source === "user").length;
  const userChars = rows.reduce((acc, item) => {
    if (item?.source !== "user") {
      return acc;
    }
    return acc + String(item?.message || "").trim().length;
  }, 0);
  const totalChars = rows.reduce((acc, item) => acc + String(item?.message || "").trim().length, 0);
  return {
    totalMessages,
    userMessages,
    userChars,
    totalChars
  };
}

function safePositiveNumber(value, fallback = 0) {
  const parsed = Number(value);
  if (!Number.isFinite(parsed)) {
    return fallback;
  }
  return Math.max(0, parsed);
}

function roundCost(value) {
  const safe = safePositiveNumber(value, 0);
  return Number(safe.toFixed(6));
}

function resolveSessionDurationMin({ durationMin, startedAt, endedAt }) {
  const direct = safePositiveNumber(durationMin, NaN);
  if (Number.isFinite(direct)) {
    return direct;
  }
  const startedMs = Date.parse(String(startedAt || ""));
  const endedMs = Date.parse(String(endedAt || ""));
  if (Number.isFinite(startedMs) && Number.isFinite(endedMs) && endedMs > startedMs) {
    return Math.max(0, (endedMs - startedMs) / 60000);
  }
  return 0;
}

function buildSessionUsageMetrics({ mode, transcript, durationMin }) {
  const safeMode = mode === "text" ? "text" : "voice";
  const rows = Array.isArray(transcript) ? transcript : [];

  let userMessages = 0;
  let userChars = 0;
  let aiMessages = 0;
  let aiChars = 0;

  for (const item of rows) {
    const source = normalizeTextAgentSource(item?.source || item?.role || item?.speaker);
    const message = String(item?.message || item?.content || "").trim();
    if (!message) {
      continue;
    }
    if (source === "user") {
      userMessages += 1;
      userChars += message.length;
    } else {
      aiMessages += 1;
      aiChars += message.length;
    }
  }

  return {
    mode: safeMode,
    duration_min: roundCost(durationMin),
    total_messages: userMessages + aiMessages,
    total_chars: userChars + aiChars,
    text_user_message_count: safeMode === "text" ? userMessages : 0,
    text_user_char_count: safeMode === "text" ? userChars : 0,
    text_ai_message_count: safeMode === "text" ? aiMessages : 0,
    text_ai_char_count: safeMode === "text" ? aiChars : 0,
    voice_user_transcript_message_count: safeMode === "voice" ? userMessages : 0,
    voice_user_transcript_char_count: safeMode === "voice" ? userChars : 0,
    voice_user_message_count: safeMode === "voice" ? userMessages : 0,
    voice_user_char_count: safeMode === "voice" ? userChars : 0,
    voice_ai_message_count: safeMode === "voice" ? aiMessages : 0,
    voice_ai_char_count: safeMode === "voice" ? aiChars : 0
  };
}

function getSessionCostRateCard() {
  return {
    voice: {
      perMinute: safePositiveNumber(process.env.COST_VOICE_PER_MINUTE, 0),
      perMessage: safePositiveNumber(process.env.COST_VOICE_PER_MESSAGE, 0)
    },
    text: {
      perMinute: safePositiveNumber(process.env.COST_TEXT_PER_MINUTE, 0),
      perMessage: safePositiveNumber(process.env.COST_TEXT_PER_MESSAGE, 0)
    }
  };
}

function buildSessionCostMetrics({ mode, usageMetrics, durationMin }) {
  const safeMode = mode === "text" ? "text" : "voice";
  const rates = getSessionCostRateCard();
  const modeRate = safeMode === "text" ? rates.text : rates.voice;
  const totalMessages = safePositiveNumber(usageMetrics?.total_messages, 0);
  const minuteCost = roundCost(safePositiveNumber(durationMin, 0) * modeRate.perMinute);
  const messageCost = roundCost(totalMessages * modeRate.perMessage);
  const modeCostTotal = roundCost(minuteCost + messageCost);

  const textCost = safeMode === "text" ? modeCostTotal : 0;
  const voiceCost = safeMode === "voice" ? modeCostTotal : 0;

  return {
    currency: "USD",
    rate_card: {
      voice: {
        per_minute: rates.voice.perMinute,
        per_message: rates.voice.perMessage
      },
      text: {
        per_minute: rates.text.perMinute,
        per_message: rates.text.perMessage
      }
    },
    minute_cost_component: minuteCost,
    message_cost_component: messageCost,
    mode_cost_total: modeCostTotal,
    text_cost_total: textCost,
    voice_cost_total: voiceCost,
    total_cost: roundCost(textCost + voiceCost)
  };
}

function extractBearerToken(req) {
  const authHeader = String(req.headers.authorization || "");
  if (!authHeader.toLowerCase().startsWith("bearer ")) {
    return "";
  }
  return authHeader.slice(7).trim();
}

function sanitizeUuid(value) {
  const raw = String(value || "").trim();
  if (!raw) {
    return "";
  }
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(raw)) {
    return "";
  }
  return raw;
}

function sanitizeEmail(value) {
  const raw = String(value || "").trim().toLowerCase();
  if (!raw) {
    return "";
  }
  if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(raw)) {
    return "";
  }
  return raw.slice(0, 240);
}

function sanitizeDeviceToken(value) {
  const compact = String(value || "")
    .trim()
    .replace(/[<>\s]/g, "")
    .toLowerCase();
  if (!compact) {
    return "";
  }
  if (!/^[0-9a-f]{32,512}$/.test(compact)) {
    return "";
  }
  return compact;
}

function sanitizeApnsEnvironment(value) {
  const raw = String(value || "").trim().toLowerCase();
  return raw === "sandbox" ? "sandbox" : "production";
}

function sanitizePublicHttpUrl(value) {
  const raw = String(value || "").trim();
  if (!raw) {
    return "";
  }
  try {
    const parsed = new URL(raw);
    if (parsed.protocol !== "https:" && parsed.protocol !== "http:") {
      return "";
    }
    return parsed.toString();
  } catch {
    return "";
  }
}

function renderInfoPage({
  title,
  subtitle,
  sections = [],
  lastUpdated = "",
  supportEmail = "",
  supportUrl = "/support",
  appDeepLink = "drkynox://auth/login"
}) {
  const safeTitle = sanitizeReportText(title || "", 120) || "Bilgilendirme";
  const safeSubtitle = sanitizeReportText(subtitle || "", 260);
  const safeUpdated = sanitizeReportText(lastUpdated || "", 80);
  const safeSupportEmail = sanitizeEmail(supportEmail) || "support@medcase.website";
  const safeSupportUrl = sanitizePublicHttpUrl(supportUrl) || String(supportUrl || "/support");
  const safeDeepLink = String(appDeepLink || "drkynox://auth/login").trim() || "drkynox://auth/login";

  const bodyBlocks = (Array.isArray(sections) ? sections : [])
    .slice(0, 24)
    .map((section) => {
      const heading = sanitizeReportText(section?.heading || "", 100);
      const paragraphs = (Array.isArray(section?.paragraphs) ? section.paragraphs : [])
        .map((line) => sanitizeReportText(line, 1200))
        .filter(Boolean)
        .slice(0, 8);
      if (!heading && paragraphs.length === 0) {
        return "";
      }
      const headingHtml = heading ? `<h2>${heading}</h2>` : "";
      const paragraphsHtml = paragraphs.map((line) => `<p>${line}</p>`).join("");
      return `<section class="block">${headingHtml}${paragraphsHtml}</section>`;
    })
    .join("");

  return `<!doctype html>
<html lang="tr">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>${safeTitle}</title>
  <style>
    :root {
      color-scheme: light;
      --bg: #f8fafc;
      --surface: #ffffff;
      --text: #0f172a;
      --muted: #475569;
      --primary: #1d6fe8;
      --border: #dbe4ef;
    }
    * { box-sizing: border-box; }
    body {
      margin: 0;
      min-height: 100vh;
      background: var(--bg);
      color: var(--text);
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
      padding: 18px;
    }
    .wrap {
      max-width: 860px;
      margin: 0 auto;
      background: var(--surface);
      border: 1px solid var(--border);
      border-radius: 18px;
      padding: 24px 20px;
      box-shadow: 0 10px 30px rgba(15, 23, 42, 0.05);
    }
    h1 {
      margin: 0;
      font-size: 32px;
      line-height: 1.16;
      letter-spacing: -0.01em;
    }
    .subtitle {
      margin: 10px 0 0;
      color: var(--muted);
      font-size: 16px;
      line-height: 1.55;
    }
    .meta {
      margin: 12px 0 0;
      font-size: 13px;
      color: #64748b;
    }
    .stack {
      margin-top: 20px;
      display: grid;
      gap: 12px;
    }
    .block {
      border: 1px solid var(--border);
      border-radius: 12px;
      padding: 14px;
      background: #fff;
    }
    h2 {
      margin: 0 0 8px;
      font-size: 19px;
      line-height: 1.3;
    }
    p {
      margin: 0 0 8px;
      font-size: 15px;
      line-height: 1.65;
      color: #334155;
    }
    p:last-child { margin-bottom: 0; }
    .footer {
      margin-top: 18px;
      border: 1px solid var(--border);
      border-radius: 12px;
      padding: 12px;
      background: #fff;
      display: grid;
      gap: 10px;
    }
    .links {
      display: flex;
      flex-wrap: wrap;
      gap: 8px;
    }
    .chip {
      display: inline-flex;
      align-items: center;
      justify-content: center;
      min-height: 36px;
      padding: 0 12px;
      border: 1px solid var(--border);
      border-radius: 999px;
      text-decoration: none;
      color: var(--text);
      font-size: 13px;
      font-weight: 600;
      background: #fff;
    }
    .chip.primary {
      color: #fff;
      border-color: var(--primary);
      background: var(--primary);
    }
  </style>
</head>
<body>
  <main class="wrap">
    <h1>${safeTitle}</h1>
    ${safeSubtitle ? `<p class="subtitle">${safeSubtitle}</p>` : ""}
    ${safeUpdated ? `<p class="meta">Son güncelleme: ${safeUpdated}</p>` : ""}

    <div class="stack">
      ${bodyBlocks}
    </div>

    <div class="footer">
      <div class="links">
        <a class="chip primary" href="${safeDeepLink}">Uygulamayı Aç</a>
        <a class="chip" href="${safeSupportUrl}">Destek</a>
        <a class="chip" href="mailto:${safeSupportEmail}">${safeSupportEmail}</a>
      </div>
    </div>
  </main>
</body>
</html>`;
}

function sanitizeAdminReason(value) {
  const text = String(value || "")
    .replace(/\s+/g, " ")
    .trim()
    .slice(0, 180);
  return text || null;
}

const REPORT_CATEGORY_ALLOWLIST = new Set([
  "zararli_icerik",
  "yanlis_vaka",
  "yanlis_tani_geri_bildirim",
  "uygunsuz_dil",
  "teknik_sorun",
  "diger"
]);

const FEEDBACK_TOPIC_ALLOWLIST = new Set([
  "genel",
  "ui_ux",
  "vaka_kalitesi",
  "skorlama_geri_bildirim",
  "performans_hiz",
  "teknik_hata",
  "ozellik_onerisi",
  "diger"
]);

function sanitizeReportCategory(value) {
  const normalized = String(value || "")
    .trim()
    .toLocaleLowerCase("tr-TR")
    .replace(/\s+/g, "_");
  if (!REPORT_CATEGORY_ALLOWLIST.has(normalized)) {
    return "";
  }
  return normalized;
}

function sanitizeReportText(value, maxLen = 1200) {
  const text = String(value || "")
    .replace(/\s+/g, " ")
    .trim()
    .slice(0, Math.max(80, Number(maxLen) || 1200));
  return text;
}

function sanitizeFeedbackTopic(value) {
  const normalized = String(value || "")
    .trim()
    .toLocaleLowerCase("tr-TR")
    .replace(/\s+/g, "_");
  if (!FEEDBACK_TOPIC_ALLOWLIST.has(normalized)) {
    return "";
  }
  return normalized;
}

function clampRateLimitValue(value, fallback, min, max) {
  const num = Number(value);
  if (!Number.isFinite(num)) {
    return fallback;
  }
  return Math.min(max, Math.max(min, Math.round(num)));
}

function getClientIp(req) {
  const forwarded = String(req.headers["x-forwarded-for"] || "")
    .split(",")
    .map((part) => part.trim())
    .filter(Boolean);
  if (forwarded.length > 0) {
    return forwarded[0];
  }
  return String(req.ip || req.socket?.remoteAddress || "unknown");
}

function sha256Short(value) {
  return crypto.createHash("sha256").update(String(value || "")).digest("hex").slice(0, 24);
}

function getUpstashConfig() {
  const url = String(process.env.UPSTASH_REDIS_REST_URL || "").trim().replace(/\/+$/g, "");
  const token = String(process.env.UPSTASH_REDIS_REST_TOKEN || "").trim();
  const prefix = String(process.env.UPSTASH_REDIS_PREFIX || "drkynox").trim() || "drkynox";
  return { url, token, prefix };
}

function isUpstashEnabled() {
  const cfg = getUpstashConfig();
  return Boolean(cfg.url && cfg.token);
}

function buildRedisKey(suffix) {
  const cfg = getUpstashConfig();
  return `${cfg.prefix}:${String(suffix || "").trim()}`;
}

async function runRedisCommand(command) {
  if (isDebugFlagEnabled("DEBUG_FORCE_UPSTASH_ERROR")) {
    throw new AppError({
      message: "Upstash debug simülasyon hatası",
      code: ERROR_CODES.UPSTASH_UNAVAILABLE,
      status: 503,
      service: "upstash"
    });
  }
  if (!isUpstashEnabled()) {
    return null;
  }
  const cfg = getUpstashConfig();
  if (!Array.isArray(command) || !command.length) {
    throw new Error("Geçersiz Redis komutu.");
  }

  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), UPSTASH_TIMEOUT_MS);
  try {
    const resp = await fetch(cfg.url, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${cfg.token}`,
        "Content-Type": "application/json"
      },
      body: JSON.stringify(command),
      signal: controller.signal
    });
    const raw = await resp.text();
    let payload = null;
    try {
      payload = raw ? JSON.parse(raw) : null;
    } catch {
      payload = null;
    }
    if (!resp.ok) {
      throw new Error(
        payload?.error || payload?.message || raw || `Upstash Redis hatası (${resp.status})`
      );
    }
    if (payload && typeof payload === "object" && Object.prototype.hasOwnProperty.call(payload, "error")) {
      throw new Error(payload.error || "Upstash Redis komut hatası.");
    }
    return payload?.result ?? null;
  } finally {
    clearTimeout(timer);
  }
}

async function redisGetJson(key) {
  const raw = await runRedisCommand(["GET", key]);
  if (raw == null || typeof raw !== "string") {
    return null;
  }
  try {
    return JSON.parse(raw);
  } catch {
    return null;
  }
}

async function redisSetJsonPx(key, value, ttlMs, opts = {}) {
  const safeTtl = Math.max(1000, Number(ttlMs) || 1000);
  const command = ["SET", key, JSON.stringify(value), "PX", String(Math.round(safeTtl))];
  if (opts.nx) {
    command.push("NX");
  }
  if (opts.xx) {
    command.push("XX");
  }
  return runRedisCommand(command);
}

function hourKey(date = new Date()) {
  const d = date instanceof Date ? date : new Date(date);
  return `${d.getUTCFullYear()}${String(d.getUTCMonth() + 1).padStart(2, "0")}${String(d.getUTCDate()).padStart(2, "0")}${String(d.getUTCHours()).padStart(2, "0")}`;
}

function minuteKey(date = new Date()) {
  const d = date instanceof Date ? date : new Date(date);
  return `${hourKey(d)}${String(d.getUTCMinutes()).padStart(2, "0")}`;
}

function normalizeApiMetricPath(rawPath = "/") {
  let value = String(rawPath || "/").trim();
  if (!value) {
    value = "/";
  }
  const queryAt = value.indexOf("?");
  if (queryAt >= 0) {
    value = value.slice(0, queryAt);
  }
  value = value.replace(/\/{2,}/g, "/");
  if (!value.startsWith("/")) {
    value = `/${value}`;
  }
  value = value
    .replace(
      /\/[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}(?=\/|$)/gi,
      "/:id"
    )
    .replace(/\/\d{2,}(?=\/|$)/g, "/:id")
    .replace(/\/[A-Za-z0-9_-]{24,}(?=\/|$)/g, "/:token");
  if (value.length > 140) {
    value = `${value.slice(0, 137)}...`;
  }
  return value || "/";
}

function requestStatusBucket(statusCode) {
  const code = Number(statusCode || 0);
  if (!Number.isFinite(code) || code >= 400) {
    return "error";
  }
  return "success";
}

function cleanupApiRequestRuntimeStore(nowMs = Date.now()) {
  if (!apiRequestRuntimeStore.length) {
    return;
  }
  const floor = nowMs - 2 * 60 * 60 * 1000;
  let keepFrom = apiRequestRuntimeStore.length;
  for (let idx = 0; idx < apiRequestRuntimeStore.length; idx += 1) {
    const item = apiRequestRuntimeStore[idx];
    if (Number(item?.ts || 0) >= floor) {
      keepFrom = idx;
      break;
    }
  }
  if (keepFrom > 0) {
    apiRequestRuntimeStore.splice(0, keepFrom);
  }
}

async function incrementApiTrafficMetrics({ method = "GET", path = "/", statusCode = 200, callerHash = "unknown", atMs } = {}) {
  const nowMs = Number.isFinite(Number(atMs)) ? Number(atMs) : Date.now();
  const now = new Date(nowMs);
  const safeMethod = String(method || "GET").toUpperCase();
  const safePath = normalizeApiMetricPath(path);
  const safeStatusCode = Number(statusCode || 0);
  const bucket = requestStatusBucket(safeStatusCode);
  const safeCaller = String(callerHash || "unknown").slice(0, 32) || "unknown";

  apiRequestRuntimeStore.push({
    ts: nowMs,
    method: safeMethod,
    path: safePath,
    statusCode: safeStatusCode,
    bucket,
    caller: safeCaller
  });
  if (apiRequestRuntimeStore.length > 4000) {
    apiRequestRuntimeStore.splice(0, apiRequestRuntimeStore.length - 4000);
  }
  cleanupApiRequestRuntimeStore(nowMs);

  if (!isUpstashEnabled()) {
    return;
  }

  const hourToken = hourKey(now);
  const minuteToken = minuteKey(now);
  const encodedPath = toBase64Url(safePath);
  const hKey = buildRedisKey(`metrics:requests:hour:${hourToken}`);
  const mKey = buildRedisKey(`metrics:requests:minute:${minuteToken}`);
  const endpointTotalKey = buildRedisKey(`metrics:requests:endpoint:hour:${hourToken}:${safeMethod}:${encodedPath}:total`);
  const endpointBucketKey = buildRedisKey(`metrics:requests:endpoint:hour:${hourToken}:${safeMethod}:${encodedPath}:${bucket}`);
  const callerTotalKey = buildRedisKey(`metrics:requests:caller:hour:${hourToken}:${safeCaller}:total`);
  const callerBucketKey = buildRedisKey(`metrics:requests:caller:hour:${hourToken}:${safeCaller}:${bucket}`);
  const ttlSec = String(60 * 60 * 48);

  try {
    await runRedisCommand(["INCR", buildRedisKey("metrics:requests:total")]);
    await runRedisCommand(["EXPIRE", buildRedisKey("metrics:requests:total"), ttlSec]);
    await runRedisCommand(["INCR", hKey]);
    await runRedisCommand(["EXPIRE", hKey, ttlSec]);
    await runRedisCommand(["INCR", mKey]);
    await runRedisCommand(["EXPIRE", mKey, String(60 * 60 * 3)]);
    await runRedisCommand(["INCR", endpointTotalKey]);
    await runRedisCommand(["EXPIRE", endpointTotalKey, ttlSec]);
    await runRedisCommand(["INCR", endpointBucketKey]);
    await runRedisCommand(["EXPIRE", endpointBucketKey, ttlSec]);
    await runRedisCommand(["INCR", callerTotalKey]);
    await runRedisCommand(["EXPIRE", callerTotalKey, ttlSec]);
    await runRedisCommand(["INCR", callerBucketKey]);
    await runRedisCommand(["EXPIRE", callerBucketKey, ttlSec]);
  } catch {
    // metrik yazim hatasi ana akisyi etkilemesin
  }
}

async function incrementElevenLabsMetrics({ agentId = "", mode = "" } = {}) {
  if (!isUpstashEnabled()) {
    return;
  }
  const safeAgent = sanitizeAgentId(agentId) || "unknown";
  const safeMode = mode === "text" ? "text" : "voice";
  const hourToken = hourKey(new Date());
  const keys = [
    buildRedisKey("metrics:elevenlabs:sessions:total"),
    buildRedisKey(`metrics:elevenlabs:sessions:hour:${hourToken}`),
    buildRedisKey(`metrics:elevenlabs:agent:${safeAgent}:total`),
    buildRedisKey(`metrics:elevenlabs:agent:${safeAgent}:hour:${hourToken}`),
    buildRedisKey(`metrics:elevenlabs:mode:${safeMode}:hour:${hourToken}`)
  ];
  try {
    for (const key of keys) {
      await runRedisCommand(["INCR", key]);
      await runRedisCommand(["EXPIRE", key, String(60 * 60 * 24 * 7)]);
    }
  } catch {
    // metrik yazim hatasi ana akisyi etkilemesin
  }
}

function pushRuntimeErrorLog(entry) {
  if (!entry || typeof entry !== "object") {
    return;
  }
  runtimeErrorLogStore.unshift(entry);
  if (runtimeErrorLogStore.length > 200) {
    runtimeErrorLogStore.length = 200;
  }
  if (!isUpstashEnabled()) {
    return;
  }
  void (async () => {
    const redisKey = buildRedisKey("logs:errors");
    try {
      await runRedisCommand(["LPUSH", redisKey, JSON.stringify(entry)]);
      await runRedisCommand(["LTRIM", redisKey, "0", "199"]);
      await runRedisCommand(["EXPIRE", redisKey, String(APP_ERROR_LOG_TTL_SECONDS)]);
    } catch {
      // log saklama hatasi ana akisyi etkilemesin
    }
  })();
}

async function getRuntimeErrorLogs(limit = 50) {
  const safeLimit = clampRateLimitValue(limit, 50, 1, 200);
  if (isUpstashEnabled()) {
    try {
      const redisKey = buildRedisKey("logs:errors");
      const rawEntries = await runRedisCommand(["LRANGE", redisKey, "0", String(safeLimit - 1)]);
      if (Array.isArray(rawEntries)) {
        return rawEntries
          .map((item) => {
            try {
              return JSON.parse(String(item || "{}"));
            } catch {
              return null;
            }
          })
          .filter(Boolean);
      }
    } catch {
      // fallback asagida memory
    }
  }
  return runtimeErrorLogStore.slice(0, safeLimit);
}

function buildRequestErrorContext(req, res, extra = {}) {
  const method = String(req?.method || "GET").toUpperCase();
  const path = String(req?.originalUrl || req?.url || "");
  const status = Number(extra?.status || res?.statusCode || 500);
  return {
    requestId: String(req?.requestId || "").trim() || null,
    method,
    path,
    status,
    latencyMs: Number.isFinite(Number(extra?.latencyMs))
      ? Number(extra.latencyMs)
      : Number.isFinite(Number(req?.startedAtMs))
        ? Math.max(0, Date.now() - Number(req.startedAtMs))
        : null,
    ipHash: sha256Short(getClientIp(req || {})),
    userId: sanitizeUuid(extra?.userId || req?.authUserId || req?.userId || null)
  };
}

async function persistAppErrorEvent(logEntry) {
  if (!logEntry || typeof logEntry !== "object") {
    return false;
  }
  const { supabaseUrl, supabaseServiceRoleKey } = getSupabaseConfig();
  if (!supabaseUrl || !supabaseServiceRoleKey) {
    return false;
  }

  const row = {
    request_id: logEntry.requestId || null,
    service: sanitizeReportText(logEntry.service || "app", 48) || "app",
    code: sanitizeReportText(logEntry.code || ERROR_CODES.UNKNOWN, 64) || ERROR_CODES.UNKNOWN,
    message: sanitizeReportText(logEntry.message || "Bilinmeyen hata", 600) || "Bilinmeyen hata",
    status: Number.isFinite(Number(logEntry.status)) ? Number(logEntry.status) : 500,
    method: sanitizeReportText(logEntry.method || "", 16) || null,
    path: sanitizeReportText(logEntry.path || "", 220) || null,
    user_id: sanitizeUuid(logEntry.userId),
    identity_hash: sanitizeReportText(logEntry.ipHash || "", 40) || null,
    latency_ms: Number.isFinite(Number(logEntry.latencyMs)) ? Number(logEntry.latencyMs) : null,
    metadata:
      logEntry.metadata && typeof logEntry.metadata === "object" && !Array.isArray(logEntry.metadata)
        ? logEntry.metadata
        : {},
    created_at: toIsoString(logEntry.timestamp || new Date().toISOString()) || new Date().toISOString()
  };

  try {
    const resp = await fetchWithTimeout(
      `${supabaseUrl}/rest/v1/app_error_events`,
      {
        method: "POST",
        headers: {
          apikey: supabaseServiceRoleKey,
          Authorization: `Bearer ${supabaseServiceRoleKey}`,
          "Content-Type": "application/json",
          Prefer: "return=minimal"
        },
        body: JSON.stringify([row])
      },
      8000
    );
    return resp.ok;
  } catch {
    return false;
  }
}

async function fetchPersistedAppErrorLogs({
  limit = 120,
  rangeHours = 24,
  statusFilter = "",
  endpointFilter = ""
} = {}) {
  const { supabaseUrl, supabaseServiceRoleKey } = getSupabaseConfig();
  if (!supabaseUrl || !supabaseServiceRoleKey) {
    return [];
  }
  const safeLimit = clampRateLimitValue(limit, 120, 1, 500);
  const safeRange = clampRateLimitValue(rangeHours, 24, 0, 24 * 30);
  const safeStatusFilter = String(statusFilter || "")
    .trim()
    .toLowerCase();
  const safeEndpointFilter = String(endpointFilter || "")
    .trim()
    .toLowerCase();

  const qs = new URLSearchParams({
    select: "request_id,service,code,message,status,method,path,user_id,identity_hash,latency_ms,metadata,created_at",
    order: "created_at.desc",
    limit: String(safeLimit)
  });
  if (safeRange > 0) {
    const startIso = new Date(Date.now() - safeRange * 60 * 60 * 1000).toISOString();
    qs.append("created_at", `gte.${startIso}`);
  }
  if (/^\d{3}$/.test(safeStatusFilter)) {
    qs.append("status", `eq.${safeStatusFilter}`);
  } else if (/^\dxx$/.test(safeStatusFilter)) {
    const firstDigit = Number(safeStatusFilter[0]);
    qs.append("status", `gte.${firstDigit * 100}`);
    qs.append("status", `lt.${firstDigit * 100 + 100}`);
  }
  if (safeEndpointFilter) {
    qs.append("path", `ilike.*${safeEndpointFilter.replace(/\*/g, "")}*`);
  }

  try {
    const resp = await fetchWithTimeout(
      `${supabaseUrl}/rest/v1/app_error_events?${qs.toString()}`,
      {
        method: "GET",
        headers: {
          apikey: supabaseServiceRoleKey,
          Authorization: `Bearer ${supabaseServiceRoleKey}`
        }
      },
      9000
    );
    if (!resp.ok) {
      return [];
    }
    const rows = await resp.json().catch(() => []);
    return Array.isArray(rows) ? rows : [];
  } catch {
    return [];
  }
}

async function captureAppError({
  error,
  req = null,
  res = null,
  fallback = {},
  metadata = {}
} = {}) {
  const normalized = normalizeErrorForLog(error, fallback);
  const appError = normalized.appError;
  const requestCtx = req ? buildRequestErrorContext(req, res, { status: normalized.status }) : {};

  const logEntry = {
    timestamp: new Date().toISOString(),
    requestId: requestCtx.requestId || null,
    status: normalized.status,
    code: normalized.code,
    service: sanitizeReportText(appError.service || fallback?.service || "app", 48) || "app",
    message: sanitizeReportText(appError.message || fallback?.message || "Bilinmeyen hata", 600),
    method: requestCtx.method || sanitizeReportText(fallback?.method || "", 16) || null,
    path: requestCtx.path || sanitizeReportText(fallback?.path || "", 220) || null,
    latencyMs: requestCtx.latencyMs ?? null,
    ipHash: requestCtx.ipHash || null,
    userId: requestCtx.userId || sanitizeUuid(fallback?.userId) || null,
    metadata:
      metadata && typeof metadata === "object" && !Array.isArray(metadata)
        ? metadata
        : {}
  };

  if (req && typeof req === "object") {
    req.__errorCaptured = true;
  }

  pushRuntimeErrorLog(logEntry);
  await persistAppErrorEvent(logEntry);

  if (sentryCfg?.dsn && sentryCfg.enabled) {
    Sentry.withScope((scope) => {
      scope.setTag("service", logEntry.service || "app");
      scope.setTag("error_code", normalized.code || ERROR_CODES.UNKNOWN);
      scope.setTag("http_status", String(logEntry.status || 500));
      if (logEntry.requestId) scope.setTag("request_id", logEntry.requestId);
      if (logEntry.method) scope.setTag("http_method", logEntry.method);
      if (logEntry.path) scope.setTag("http_path", logEntry.path.slice(0, 160));
      if (logEntry.userId) scope.setUser({ id: logEntry.userId });
      scope.setContext("app_error", {
        code: normalized.code,
        service: logEntry.service,
        metadata: logEntry.metadata
      });
      Sentry.captureException(error instanceof Error ? error : appError);
    });
  }

  return {
    appError,
    status: normalized.status,
    code: normalized.code
  };
}

async function getRecentErrorLogsForAdmin(limit = 20) {
  const safeLimit = clampRateLimitValue(limit, 20, 1, 200);
  const persisted = await fetchPersistedAppErrorLogs({
    limit: safeLimit,
    rangeHours: 24 * 7
  });
  if (Array.isArray(persisted) && persisted.length > 0) {
    return persisted.map((item) => ({
      timestamp: item?.created_at || null,
      requestId: item?.request_id || null,
      status: Number(item?.status || 500),
      method: String(item?.method || "GET").toUpperCase(),
      path: String(item?.path || ""),
      latencyMs: Number(item?.latency_ms || 0),
      ipHash: String(item?.identity_hash || ""),
      source: "supabase",
      service: String(item?.service || "app"),
      code: String(item?.code || ERROR_CODES.UNKNOWN),
      message: String(item?.message || "")
    }));
  }
  const runtime = await getRuntimeErrorLogs(safeLimit);
  return (Array.isArray(runtime) ? runtime : []).map((item) => ({
    ...item,
    source: item?.source || "runtime"
  }));
}

async function listRedisKeysByPattern(pattern) {
  if (!isUpstashEnabled()) {
    return [];
  }
  const safePattern = String(pattern || "").trim();
  if (!safePattern) {
    return [];
  }
  try {
    const keys = await runRedisCommand(["KEYS", safePattern]);
    return Array.isArray(keys) ? keys.filter((item) => typeof item === "string" && item.length > 0) : [];
  } catch {
    return [];
  }
}

async function countActiveSessionKeys() {
  const cfg = getUpstashConfig();
  if (!isUpstashEnabled()) {
    cleanupActiveElevenSessionStore(Date.now());
    let voice = 0;
    let text = 0;
    for (const item of activeElevenSessionStore.values()) {
      if (!item) {
        continue;
      }
      if (String(item.mode || "voice") === "text") {
        text += 1;
      } else {
        voice += 1;
      }
    }
    return {
      total: voice + text,
      voice,
      text
    };
  }

  const indexKeys = getActiveSessionIndexKeys();
  const trackedUsersRaw = await runRedisCommand(["SMEMBERS", indexKeys.users]);
  const trackedUsers = Array.isArray(trackedUsersRaw)
    ? trackedUsersRaw
        .map((item) => sanitizeUuid(item))
        .filter((item) => Boolean(item))
    : [];

  if (trackedUsers.length > 0) {
    let voice = 0;
    let text = 0;
    for (const userId of trackedUsers) {
      const redisKey = buildRedisKey(`active-session:${userId}`);
      const raw = await runRedisCommand(["GET", redisKey]);
      if (!raw || typeof raw !== "string") {
        await removeActiveSessionIndexes(userId);
        continue;
      }
      try {
        const entry = JSON.parse(raw);
        const lockUntilMs = Number(entry?.lockUntilMs || 0);
        if (!lockUntilMs || lockUntilMs <= Date.now()) {
          await runRedisCommand(["DEL", redisKey]);
          await removeActiveSessionIndexes(userId);
          continue;
        }
        const mode = String(entry?.mode || "voice") === "text" ? "text" : "voice";
        if (mode === "text") {
          text += 1;
        } else {
          voice += 1;
        }
        await runRedisCommand(["SADD", mode === "text" ? indexKeys.text : indexKeys.voice, userId]);
        await runRedisCommand(["SREM", mode === "text" ? indexKeys.voice : indexKeys.text, userId]);
      } catch {
        voice += 1;
      }
    }
    return {
      total: voice + text,
      voice,
      text
    };
  }

  // Legacy fallback: older deployments may not have session index sets yet.
  const patternA = `${cfg.prefix}:active-session:*`;
  const patternB = `${cfg.prefix}:active_session:*`;
  const keysA = await listRedisKeysByPattern(patternA);
  const keysB = await listRedisKeysByPattern(patternB);
  const uniqKeys = Array.from(new Set([...keysA, ...keysB]));

  let voice = 0;
  let text = 0;
  for (const key of uniqKeys) {
    const raw = await runRedisCommand(["GET", key]);
    if (!raw || typeof raw !== "string") {
      continue;
    }
    try {
      const entry = JSON.parse(raw);
      if (String(entry?.mode || "voice") === "text") {
        text += 1;
      } else {
        voice += 1;
      }
    } catch {
      voice += 1;
    }
  }
  return {
    total: uniqKeys.length,
    voice,
    text
  };
}

function getActiveSessionIndexKeys() {
  return {
    users: buildRedisKey("active-session:index:users"),
    voice: buildRedisKey("active-session:index:voice"),
    text: buildRedisKey("active-session:index:text")
  };
}

async function addActiveSessionIndexes(userId, mode = "voice") {
  const key = sanitizeUuid(userId);
  if (!key || !isUpstashEnabled()) {
    return;
  }
  const safeMode = String(mode || "voice") === "text" ? "text" : "voice";
  const indexKeys = getActiveSessionIndexKeys();
  await runRedisCommand(["SADD", indexKeys.users, key]);
  if (safeMode === "text") {
    await runRedisCommand(["SADD", indexKeys.text, key]);
    await runRedisCommand(["SREM", indexKeys.voice, key]);
  } else {
    await runRedisCommand(["SADD", indexKeys.voice, key]);
    await runRedisCommand(["SREM", indexKeys.text, key]);
  }
}

async function removeActiveSessionIndexes(userId) {
  const key = sanitizeUuid(userId);
  if (!key || !isUpstashEnabled()) {
    return;
  }
  const indexKeys = getActiveSessionIndexKeys();
  await runRedisCommand(["SREM", indexKeys.users, key]);
  await runRedisCommand(["SREM", indexKeys.voice, key]);
  await runRedisCommand(["SREM", indexKeys.text, key]);
}

async function checkRateLimit({ scope, identity, maxRequests, windowMs }) {
  const now = Date.now();
  const safeScope = String(scope || "global").trim() || "global";
  const safeIdentity = String(identity || "anon").trim() || "anon";
  const key = `${safeScope}:${sha256Short(safeIdentity)}`;
  const safeWindow = clampRateLimitValue(windowMs, 60_000, 10_000, 15 * 60_000);
  const safeMax = clampRateLimitValue(maxRequests, 12, 1, 500);

  if (isUpstashEnabled()) {
    try {
      const redisKey = buildRedisKey(`rl:${key}`);
      const countRaw = await runRedisCommand(["INCR", redisKey]);
      const count = Number(countRaw);
      if (count === 1) {
        await runRedisCommand(["PEXPIRE", redisKey, String(safeWindow)]);
      }
      let ttlMs = Number(await runRedisCommand(["PTTL", redisKey]));
      if (!Number.isFinite(ttlMs) || ttlMs < 0) {
        ttlMs = safeWindow;
        await runRedisCommand(["PEXPIRE", redisKey, String(safeWindow)]);
      }
      const resetAt = now + Math.max(1000, ttlMs);
      const remaining = Math.max(0, safeMax - count);
      const retryAfterSec = Math.max(1, Math.ceil((resetAt - now) / 1000));
      return {
        allowed: count <= safeMax,
        limit: safeMax,
        remaining,
        resetAt,
        retryAfterSec
      };
    } catch (error) {
      // eslint-disable-next-line no-console
      console.warn(`[ratelimit] upstash fallback -> memory: ${error?.message || "unknown"}`);
    }
  }

  const existing = rateLimitStore.get(key);
  let bucket = existing;

  if (!bucket || now >= bucket.resetAt) {
    bucket = {
      count: 0,
      resetAt: now + safeWindow
    };
  }

  bucket.count += 1;
  rateLimitStore.set(key, bucket);

  const remaining = Math.max(0, safeMax - bucket.count);
  const retryAfterSec = Math.max(1, Math.ceil((bucket.resetAt - now) / 1000));
  const allowed = bucket.count <= safeMax;

  if (rateLimitStore.size > 6000) {
    for (const [entryKey, entry] of rateLimitStore.entries()) {
      if (!entry || now >= Number(entry.resetAt || 0)) {
        rateLimitStore.delete(entryKey);
      }
    }
  }

  return {
    allowed,
    limit: safeMax,
    remaining,
    resetAt: bucket.resetAt,
    retryAfterSec
  };
}

function applyRateLimitHeaders(res, state) {
  const exposeRateHeaders = String(process.env.EXPOSE_RATE_LIMIT_HEADERS || "")
    .trim()
    .toLowerCase() === "true";
  if (!exposeRateHeaders) {
    return;
  }
  res.setHeader("X-RateLimit-Limit", String(state.limit));
  res.setHeader("X-RateLimit-Remaining", String(state.remaining));
  res.setHeader("X-RateLimit-Reset", String(state.resetAt));
}

function parseRateLimitMetadata(value) {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    return {};
  }
  return value;
}

function inferRateLimitEventSource({ scope, endpoint, req = null, metadata = null } = {}) {
  const safeScope = String(scope || "").trim().toLowerCase();
  const safeEndpoint = String(endpoint || "").trim().toLowerCase();
  const safeMetadata = parseRateLimitMetadata(metadata);

  const headers = req && req.headers && typeof req.headers === "object" ? req.headers : {};
  const userAgent = String(headers["user-agent"] || safeMetadata.user_agent || "")
    .trim()
    .toLowerCase();
  const hasQStashSignature = Boolean(
    String(headers["upstash-signature"] || headers["upstash-signature-v2"] || safeMetadata.upstash_signature || "")
      .trim()
  );

  const normalizedPath = safeEndpoint.split("?")[0];
  const isAdminPath = normalizedPath.startsWith("/api/admin/");
  const isWorkflowPath = normalizedPath.startsWith("/api/workflow/");
  const isHealthPath = normalizedPath === "/api/health" || normalizedPath === "/api/public-config";
  const isAdminScope = safeScope.startsWith("admin-") || safeScope.includes("admin-panel");
  const isWorkflowScope = safeScope.includes("workflow");

  if (hasQStashSignature || isWorkflowPath || isWorkflowScope) {
    return {
      sourceCategory: "internal",
      sourceLabel: "workflow",
      sourceReason: hasQStashSignature ? "qstash-signed-request" : "workflow-route"
    };
  }

  if (isAdminPath || isAdminScope) {
    return {
      sourceCategory: "internal",
      sourceLabel: "admin",
      sourceReason: "admin-route-or-scope"
    };
  }

  const monitoringUaHints = ["uptime", "healthcheck", "monitor", "statuscake", "checkly", "vercel"];
  const looksMonitoringUa = monitoringUaHints.some((hint) => userAgent.includes(hint));
  if (isHealthPath || looksMonitoringUa) {
    return {
      sourceCategory: "monitoring",
      sourceLabel: "health-monitor",
      sourceReason: isHealthPath ? "health-endpoint" : "monitoring-user-agent"
    };
  }

  return {
    sourceCategory: "external",
    sourceLabel: "external-client",
    sourceReason: "api-client-traffic"
  };
}

async function logRateLimitAuditEvent({ scope, identity, endpoint, state, decision = "blocked", req = null }) {
  const { supabaseUrl, supabaseServiceRoleKey } = getSupabaseConfig();
  if (!supabaseUrl || !supabaseServiceRoleKey) {
    return;
  }
  try {
    const source = inferRateLimitEventSource({ scope, endpoint, req });
    const headers = req && req.headers && typeof req.headers === "object" ? req.headers : {};
    const method = String(req?.method || "").trim().toUpperCase();
    const userAgent = String(headers["user-agent"] || "").trim();
    const hasQStashSignature = Boolean(
      String(headers["upstash-signature"] || headers["upstash-signature-v2"] || "").trim()
    );
    const row = {
      scope: String(scope || "global").slice(0, 120),
      identity_hash: sha256Short(identity || "anon"),
      endpoint: String(endpoint || "").slice(0, 200) || null,
      decision: String(decision || "blocked").slice(0, 40),
      request_count: Number.isFinite(Number(state?.limit) - Number(state?.remaining))
        ? Number(state.limit) - Number(state.remaining)
        : null,
      window_ms: Number.isFinite(Number(state?.resetAt))
        ? Math.max(0, Number(state.resetAt) - Date.now())
        : null,
      metadata: {
        limit: Number(state?.limit || 0),
        remaining: Number(state?.remaining || 0),
        retry_after_seconds: Number(state?.retryAfterSec || 0),
        source_category: source.sourceCategory,
        source_label: source.sourceLabel,
        source_reason: source.sourceReason,
        method: method || null,
        user_agent: userAgent ? userAgent.slice(0, 180) : null,
        upstash_signature: hasQStashSignature ? "present" : "missing"
      },
      created_at: new Date().toISOString()
    };
    await fetch(`${supabaseUrl}/rest/v1/rate_limit_audit_events`, {
      method: "POST",
      headers: {
        apikey: supabaseServiceRoleKey,
        Authorization: `Bearer ${supabaseServiceRoleKey}`,
        "Content-Type": "application/json",
        Prefer: "return=minimal"
      },
      body: JSON.stringify([row])
    });
  } catch {
    // audit yazimi kritik akisi etkilemez
  }
}

function cleanupSuspiciousAlertStore(nowMs = Date.now()) {
  if (suspiciousAlertStore.size <= 4000) {
    return;
  }
  for (const [key, expiresAt] of suspiciousAlertStore.entries()) {
    if (!Number.isFinite(Number(expiresAt)) || Number(expiresAt) <= nowMs) {
      suspiciousAlertStore.delete(key);
    }
  }
}

async function shouldEmitSuspiciousAlert(key, cooldownMs) {
  const safeKey = String(key || "").trim();
  if (!safeKey) {
    return true;
  }
  const ttlMs = Math.max(15_000, Number(cooldownMs || 15 * 60_000));
  if (isUpstashEnabled()) {
    try {
      const redisKey = buildRedisKey(`suspicious:dedupe:${safeKey}`);
      const result = await runRedisCommand(["SET", redisKey, "1", "PX", String(ttlMs), "NX"]);
      return result === "OK";
    } catch {
      // memory fallback
    }
  }
  const now = Date.now();
  const currentUntil = Number(suspiciousAlertStore.get(safeKey) || 0);
  if (currentUntil > now) {
    return false;
  }
  suspiciousAlertStore.set(safeKey, now + ttlMs);
  cleanupSuspiciousAlertStore(now);
  return true;
}

async function logSuspiciousActivityEvent({
  eventType,
  scope,
  identity,
  userId = null,
  endpoint = "",
  requestCount = null,
  threshold = null,
  windowMs = null,
  metadata = {}
}) {
  const { supabaseUrl, supabaseServiceRoleKey } = getSupabaseConfig();
  if (!supabaseUrl || !supabaseServiceRoleKey) {
    return;
  }
  const safeEventType = sanitizeReportText(eventType || "suspicious_activity", 80) || "suspicious_activity";
  const safeScope = sanitizeReportText(scope || "unknown_scope", 120) || "unknown_scope";
  const safeEndpoint = sanitizeReportText(endpoint || "", 220) || null;
  const safeUserId = sanitizeUuid(userId);
  const cooldown = getSuspiciousSecurityConfig().alertCooldownMs;
  const dedupeKey = `${safeEventType}:${safeScope}:${sha256Short(identity || safeUserId || "anon")}`;
  const shouldWrite = await shouldEmitSuspiciousAlert(dedupeKey, cooldown);
  if (!shouldWrite) {
    return;
  }
  const row = {
    event_type: safeEventType,
    scope: safeScope,
    user_id: safeUserId,
    identity_hash: sha256Short(identity || safeUserId || "anon"),
    endpoint: safeEndpoint,
    request_count: Number.isFinite(Number(requestCount)) ? Number(requestCount) : null,
    threshold: Number.isFinite(Number(threshold)) ? Number(threshold) : null,
    window_ms: Number.isFinite(Number(windowMs)) ? Number(windowMs) : null,
    metadata:
      metadata && typeof metadata === "object" && !Array.isArray(metadata)
        ? metadata
        : {},
    created_at: new Date().toISOString()
  };
  try {
    await fetch(`${supabaseUrl}/rest/v1/suspicious_activity_events`, {
      method: "POST",
      headers: {
        apikey: supabaseServiceRoleKey,
        Authorization: `Bearer ${supabaseServiceRoleKey}`,
        "Content-Type": "application/json",
        Prefer: "return=minimal"
      },
      body: JSON.stringify([row])
    });
  } catch {
    // audit yazimi kritik akisi etkilemez
  }
}

async function trackSuspiciousThreshold({
  eventType,
  scope,
  identity,
  userId = null,
  endpoint = "",
  threshold,
  windowMs,
  metadata = {}
}) {
  const state = await checkRateLimit({
    scope: `suspicious:${scope}`,
    identity,
    maxRequests: threshold,
    windowMs
  });
  if (state.allowed) {
    return state;
  }
  const requestCount = Number(state?.limit || 0) - Number(state?.remaining || 0);
  await logSuspiciousActivityEvent({
    eventType,
    scope,
    identity,
    userId,
    endpoint,
    requestCount,
    threshold,
    windowMs,
    metadata: {
      ...metadata,
      retry_after_seconds: Number(state?.retryAfterSec || 0)
    }
  });
  return state;
}

function sanitizeSpamFingerprintInput(raw, maxLen = 1200) {
  return String(raw || "")
    .replace(/\s+/g, " ")
    .trim()
    .slice(0, Math.max(1, maxLen));
}

async function enforceSpamFingerprintGuard(req, res, { scope, identity, fingerprint, cooldownMs = 25_000 }) {
  const safeFingerprint = sanitizeSpamFingerprintInput(fingerprint, 600);
  if (!safeFingerprint) {
    return true;
  }
  const hash = sha256Short(`${scope}:${identity}:${safeFingerprint}`);
  const ttlMs = Math.max(5000, Number(cooldownMs || 25_000));
  if (isUpstashEnabled()) {
    try {
      const redisKey = buildRedisKey(`spam:${hash}`);
      const result = await runRedisCommand(["SET", redisKey, "1", "PX", String(ttlMs), "NX"]);
      if (result === "OK") {
        return true;
      }
      await logSuspiciousActivityEvent({
        eventType: "spam_repeat_payload",
        scope,
        identity,
        endpoint: req?.originalUrl || req?.url || "",
        metadata: { cooldown_ms: ttlMs }
      });
      return res.status(429).json({
        error: "Aynı içerik çok hızlı tekrarlandı. Lütfen kısa bir süre bekleyip tekrar dene."
      });
    } catch {
      // memory fallback
    }
  }

  const now = Date.now();
  const expiry = Number(spamFingerprintStore.get(hash) || 0);
  if (expiry > now) {
    await logSuspiciousActivityEvent({
      eventType: "spam_repeat_payload",
      scope,
      identity,
      endpoint: req?.originalUrl || req?.url || "",
      metadata: { cooldown_ms: ttlMs }
    });
    return res.status(429).json({
      error: "Aynı içerik çok hızlı tekrarlandı. Lütfen kısa bir süre bekleyip tekrar dene."
    });
  }
  spamFingerprintStore.set(hash, now + ttlMs);
  if (spamFingerprintStore.size > 6000) {
    for (const [key, until] of spamFingerprintStore.entries()) {
      if (Number(until || 0) <= now) {
        spamFingerprintStore.delete(key);
      }
    }
  }
  return true;
}

async function enforceRateLimit(
  req,
  res,
  { scope, identity, maxRequests, windowMs, errorMessage, suspiciousEventType = "", suspiciousUserId = null }
) {
  const state = await checkRateLimit({
    scope,
    identity,
    maxRequests,
    windowMs
  });
  applyRateLimitHeaders(res, state);
  if (state.allowed) {
    return true;
  }
  void logRateLimitAuditEvent({
    scope,
    identity,
    endpoint: req?.originalUrl || req?.url || "",
    state,
    decision: "blocked",
    req
  });
  if (suspiciousEventType) {
    void logSuspiciousActivityEvent({
      eventType: suspiciousEventType,
      scope,
      identity,
      userId: suspiciousUserId,
      endpoint: req?.originalUrl || req?.url || "",
      requestCount: Number(state?.limit || 0) - Number(state?.remaining || 0),
      threshold: Number(state?.limit || 0),
      windowMs: Number.isFinite(Number(state?.resetAt)) ? Math.max(0, Number(state.resetAt) - Date.now()) : null,
      metadata: {
        retry_after_seconds: Number(state?.retryAfterSec || 0)
      }
    });
  }
  res.setHeader("Retry-After", String(state.retryAfterSec));
  res.status(429).json({
    error:
      errorMessage ||
      "Çok fazla istek gönderildi. Lütfen kısa bir süre bekleyip tekrar dene.",
    retry_after_seconds: state.retryAfterSec
  });
  return false;
}

function bruteForceConfig() {
  return {
    threshold: clampRateLimitValue(process.env.BRUTE_FORCE_THRESHOLD, 8, 3, 50),
    windowMs: clampRateLimitValue(process.env.BRUTE_FORCE_WINDOW_MS, 15 * 60_000, 30_000, 24 * 60 * 60 * 1000),
    blockMs: clampRateLimitValue(process.env.BRUTE_FORCE_BLOCK_MS, 15 * 60_000, 30_000, 24 * 60 * 60 * 1000)
  };
}

function authFailureKey(scope, identity) {
  const safeScope = String(scope || "auth").trim() || "auth";
  const safeIdentity = String(identity || "anon").trim() || "anon";
  return `${safeScope}:${sha256Short(safeIdentity)}`;
}

function cleanupAuthFailureStore(now = Date.now()) {
  if (authFailureStore.size <= 6000) {
    return;
  }
  for (const [key, entry] of authFailureStore.entries()) {
    if (!entry) {
      authFailureStore.delete(key);
      continue;
    }
    const blockedUntil = Number(entry.blockedUntil || 0);
    const firstFailedAt = Number(entry.firstFailedAt || 0);
    const stale = blockedUntil > 0 ? blockedUntil <= now : firstFailedAt + 2 * bruteForceConfig().windowMs <= now;
    if (stale) {
      authFailureStore.delete(key);
    }
  }
}

async function registerAuthFailure({ scope, identity, endpoint = "", userId = null }) {
  const now = Date.now();
  const cfg = bruteForceConfig();
  const key = authFailureKey(scope, identity);

  if (isUpstashEnabled()) {
    try {
      const failKey = buildRedisKey(`bf:fail:${key}`);
      const blockKey = buildRedisKey(`bf:block:${key}`);
      const countRaw = await runRedisCommand(["INCR", failKey]);
      const count = Number(countRaw);
      if (count === 1) {
        await runRedisCommand(["PEXPIRE", failKey, String(cfg.windowMs)]);
      }
      if (count >= cfg.threshold) {
        await runRedisCommand(["SET", blockKey, "1", "PX", String(cfg.blockMs)]);
        await runRedisCommand(["DEL", failKey]);
      }
      const entry = {
        count: Number.isFinite(count) ? count : 0,
        firstFailedAt: now,
        lastFailedAt: now,
        blockedUntil: count >= cfg.threshold ? now + cfg.blockMs : 0
      };
      const suspiciousCfg = getSuspiciousSecurityConfig();
      await trackSuspiciousThreshold({
        eventType: "failed_auth_burst",
        scope: `failed-auth:${scope}`,
        identity: identity || "anon",
        userId,
        endpoint,
        threshold: suspiciousCfg.failedAuthThresholdPerHour,
        windowMs: suspiciousCfg.failedAuthWindowMs,
        metadata: {
          source: "registerAuthFailure",
          in_memory_count: entry.count
        }
      });
      return entry;
    } catch (error) {
      // eslint-disable-next-line no-console
      console.warn(`[bruteforce] upstash fallback -> memory: ${error?.message || "unknown"}`);
    }
  }

  const existing = authFailureStore.get(key);
  let entry = existing;

  if (!entry || now - Number(entry.firstFailedAt || 0) > cfg.windowMs) {
    entry = {
      count: 0,
      firstFailedAt: now,
      lastFailedAt: now,
      blockedUntil: 0
    };
  }

  entry.count += 1;
  entry.lastFailedAt = now;
  if (entry.count >= cfg.threshold) {
    entry.blockedUntil = now + cfg.blockMs;
  }

  authFailureStore.set(key, entry);
  cleanupAuthFailureStore(now);

  const suspiciousCfg = getSuspiciousSecurityConfig();
  await trackSuspiciousThreshold({
    eventType: "failed_auth_burst",
    scope: `failed-auth:${scope}`,
    identity: identity || "anon",
    userId,
    endpoint,
    threshold: suspiciousCfg.failedAuthThresholdPerHour,
    windowMs: suspiciousCfg.failedAuthWindowMs,
    metadata: {
      source: "registerAuthFailure",
      in_memory_count: entry.count
    }
  });

  return entry;
}

async function clearAuthFailures({ scope, identity }) {
  const key = authFailureKey(scope, identity);
  if (isUpstashEnabled()) {
    try {
      await runRedisCommand(["DEL", buildRedisKey(`bf:fail:${key}`), buildRedisKey(`bf:block:${key}`)]);
    } catch (error) {
      // eslint-disable-next-line no-console
      console.warn(`[bruteforce] clear upstash failed, memory fallback only: ${error?.message || "unknown"}`);
    }
  }
  authFailureStore.delete(key);
}

async function enforceBruteForceGuard(req, res, { scope, identity, errorMessage }) {
  const now = Date.now();
  const key = authFailureKey(scope, identity);

  if (isUpstashEnabled()) {
    try {
      const ttlMsRaw = await runRedisCommand(["PTTL", buildRedisKey(`bf:block:${key}`)]);
      const ttlMs = Number(ttlMsRaw);
      if (Number.isFinite(ttlMs) && ttlMs > 0) {
        const retryAfterSec = Math.max(1, Math.ceil(ttlMs / 1000));
        res.setHeader("Retry-After", String(retryAfterSec));
        return res.status(429).json({
          error: errorMessage || "Çok sayıda başarısız deneme tespit edildi. Lütfen bir süre sonra tekrar dene.",
          retry_after_seconds: retryAfterSec
        });
      }
      return true;
    } catch (error) {
      // eslint-disable-next-line no-console
      console.warn(`[bruteforce] guard upstash fallback -> memory: ${error?.message || "unknown"}`);
    }
  }

  const entry = authFailureStore.get(key);
  if (!entry) {
    return true;
  }
  const blockedUntil = Number(entry.blockedUntil || 0);
  if (!blockedUntil || blockedUntil <= now) {
    return true;
  }

  const retryAfterSec = Math.max(1, Math.ceil((blockedUntil - now) / 1000));
  res.setHeader("Retry-After", String(retryAfterSec));
  return res.status(429).json({
    error: errorMessage || "Çok sayıda başarısız deneme tespit edildi. Lütfen bir süre sonra tekrar dene.",
    retry_after_seconds: retryAfterSec
  });
}

async function ensureAdminAuthorized(req, res, { scope, rateScope, maxPerMinute = 30, authErrorMessage }) {
  const adminIdentity = getClientIp(req);
  if (
    (await enforceBruteForceGuard(req, res, {
      scope,
      identity: adminIdentity,
      errorMessage: authErrorMessage || "Çok fazla hatalı yönetim denemesi tespit edildi. Lütfen daha sonra tekrar dene."
    })) !== true
  ) {
    return {
      ok: false
    };
  }

  const ipLimitOk = await enforceRateLimit(req, res, {
    scope: rateScope,
    identity: adminIdentity,
    maxRequests: clampRateLimitValue(maxPerMinute, maxPerMinute, 1, 300),
    windowMs: 60_000,
    errorMessage: "Yönetim isteği sınırına ulaşıldı. Kısa süre sonra tekrar dene."
  });
  if (!ipLimitOk) {
    return {
      ok: false
    };
  }

  const aiConfig = getAiAccessConfig();
  const providedToken = String(req.headers["x-admin-token"] || req.body?.adminToken || "").trim();
  if (!aiConfig.adminToken || providedToken !== aiConfig.adminToken) {
    await registerAuthFailure({
      scope,
      identity: adminIdentity
    });
    res.status(403).json({
      error: "Yönetim yetkisi doğrulanamadı."
    });
    return {
      ok: false
    };
  }
  await clearAuthFailures({
    scope,
    identity: adminIdentity
  });
  return {
    ok: true
  };
}

function buildDailyWorkflowRequestPayload(overrides = {}) {
  return {
    forceRefresh: true,
    source: "qstash-workflow",
    requestedAt: new Date().toISOString(),
    ...((overrides && typeof overrides === "object" && !Array.isArray(overrides)) ? overrides : {})
  };
}

function buildDailyWorkflowUrl(req = null) {
  const base = resolveWorkflowBaseUrl(req);
  if (!base) {
    return "";
  }
  return `${base}${DAILY_WORKFLOW_ROUTE_PATH}`;
}

async function triggerDailyWorkflow({ req = null, payload = {}, label = "daily-challenge-workflow" } = {}) {
  const cfg = getQStashConfig();
  if (!cfg.qstashUrl || !cfg.qstashToken) {
    const err = new Error("QStash URL/token eksik.");
    err.status = 503;
    throw err;
  }
  const workflowUrl = buildDailyWorkflowUrl(req);
  if (!workflowUrl) {
    const err = new Error("Workflow public base URL çözümlenemedi.");
    err.status = 500;
    throw err;
  }

  const client = new WorkflowClient({
    baseUrl: cfg.qstashUrl,
    token: cfg.qstashToken
  });

  const result = await client.trigger({
    url: workflowUrl,
    body: buildDailyWorkflowRequestPayload(payload),
    headers: {
      "Content-Type": "application/json"
    },
    retries: 3,
    label
  });

  return {
    workflowUrl,
    workflowRunId: result?.workflowRunId || null
  };
}

async function ensureDailyWorkflowSchedule({ req = null, cron, scheduleId, payload = {} } = {}) {
  const cfg = getQStashConfig();
  if (!cfg.qstashUrl || !cfg.qstashToken) {
    const err = new Error("QStash URL/token eksik.");
    err.status = 503;
    throw err;
  }
  const workflowUrl = buildDailyWorkflowUrl(req);
  if (!workflowUrl) {
    const err = new Error("Workflow public base URL çözümlenemedi.");
    err.status = 500;
    throw err;
  }

  const qstash = new QStashClient({
    baseUrl: cfg.qstashUrl,
    token: cfg.qstashToken
  });

  const safeCron = String(cron || cfg.dailyWorkflowCron).trim() || "0 0 * * *";
  const safeScheduleId = String(scheduleId || cfg.dailyWorkflowScheduleId).trim() || cfg.dailyWorkflowScheduleId;
  const body = JSON.stringify(buildDailyWorkflowRequestPayload(payload));

  const result = await qstash.schedules.create({
    scheduleId: safeScheduleId,
    destination: workflowUrl,
    cron: safeCron,
    method: "POST",
    headers: {
      "Content-Type": "application/json"
    },
    body,
    retries: 3,
    label: "daily-challenge-workflow"
  });

  return {
    scheduleId: result?.scheduleId || safeScheduleId,
    workflowUrl,
    cron: safeCron
  };
}

function isAuthFailureStatus(status) {
  const code = Number(status || 0);
  return code === 401 || code === 403;
}

function toBase64Url(input) {
  const raw = Buffer.isBuffer(input) ? input : Buffer.from(String(input || ""), "utf8");
  return raw
    .toString("base64")
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/g, "");
}

function fromBase64Url(input) {
  const normalized = String(input || "")
    .replace(/-/g, "+")
    .replace(/_/g, "/");
  const padding = normalized.length % 4 === 0 ? "" : "=".repeat(4 - (normalized.length % 4));
  return Buffer.from(`${normalized}${padding}`, "base64");
}

const ADMIN_SESSION_COOKIE = "drkynox_admin_session";
const ADMIN_LOGIN_CSRF_COOKIE = "drkynox_admin_login_csrf";

function createCsrfToken() {
  return crypto.randomBytes(24).toString("base64url");
}

function readAdminLoginCsrfToken(req) {
  const cookies = parseCookieHeader(req.headers?.cookie || "");
  return String(cookies[ADMIN_LOGIN_CSRF_COOKIE] || "").trim();
}

function setAdminLoginCsrfCookie(req, res, token) {
  const cookie = serializeCookie(ADMIN_LOGIN_CSRF_COOKIE, token, {
    path: "/admin",
    httpOnly: true,
    secure: isSecureRequest(req) || String(process.env.NODE_ENV || "").toLowerCase() === "production",
    sameSite: "Strict",
    maxAge: 15 * 60
  });
  res.append("Set-Cookie", cookie);
}

function clearAdminLoginCsrfCookie(req, res) {
  const cookie = serializeCookie(ADMIN_LOGIN_CSRF_COOKIE, "", {
    path: "/admin",
    httpOnly: true,
    secure: isSecureRequest(req) || String(process.env.NODE_ENV || "").toLowerCase() === "production",
    sameSite: "Strict",
    maxAge: 0
  });
  res.append("Set-Cookie", cookie);
}

function ensureAdminLoginCsrf(req, res) {
  const existing = readAdminLoginCsrfToken(req);
  if (existing) {
    return existing;
  }
  const token = createCsrfToken();
  setAdminLoginCsrfCookie(req, res, token);
  return token;
}

function validateAdminLoginCsrf(req, bodyToken = "") {
  const cookieToken = readAdminLoginCsrfToken(req);
  const headerToken = String(req.headers["x-csrf-token"] || bodyToken || "").trim();
  if (!cookieToken || !headerToken) {
    return false;
  }
  return safeConstantCompare(cookieToken, headerToken);
}

function createAdminSessionToken({ username }) {
  const cfg = getAdminPanelConfig();
  if (!cfg.sessionSecret) {
    const err = new Error("Admin session secret tanımlı değil.");
    err.status = 503;
    throw err;
  }
  const nowSec = Math.floor(Date.now() / 1000);
  const payload = {
    sub: String(username || cfg.username || "admin"),
    iat: nowSec,
    exp: nowSec + cfg.sessionTtlSec,
    nonce: crypto.randomBytes(12).toString("hex"),
    csrf: createCsrfToken()
  };
  const header = { alg: "HS256", typ: "JWT" };
  const h = toBase64Url(JSON.stringify(header));
  const p = toBase64Url(JSON.stringify(payload));
  const signedPart = `${h}.${p}`;
  const signature = crypto.createHmac("sha256", cfg.sessionSecret).update(signedPart).digest();
  return {
    token: `${signedPart}.${toBase64Url(signature)}`,
    payload
  };
}

function verifyAdminSessionToken(token) {
  const cfg = getAdminPanelConfig();
  if (!cfg.sessionSecret) {
    return null;
  }
  const raw = String(token || "").trim();
  const parts = raw.split(".");
  if (parts.length !== 3) {
    return null;
  }
  const [h, p, s] = parts;
  const signedPart = `${h}.${p}`;
  let payload = null;
  try {
    const expectedSig = crypto.createHmac("sha256", cfg.sessionSecret).update(signedPart).digest();
    const actualSig = fromBase64Url(s);
    if (expectedSig.length !== actualSig.length || !crypto.timingSafeEqual(expectedSig, actualSig)) {
      return null;
    }
    payload = JSON.parse(fromBase64Url(p).toString("utf8"));
  } catch {
    return null;
  }
  const exp = Number(payload?.exp || 0);
  const nowSec = Math.floor(Date.now() / 1000);
  if (!exp || exp <= nowSec) {
    return null;
  }
  return payload;
}

function extractAdminSession(req) {
  const cookies = parseCookieHeader(req.headers?.cookie || "");
  const raw = String(cookies[ADMIN_SESSION_COOKIE] || "").trim();
  if (!raw) {
    return null;
  }
  return verifyAdminSessionToken(raw);
}

function extractAdminCsrfFromRequest(req) {
  const headerToken = String(req.headers["x-csrf-token"] || "").trim();
  if (headerToken) {
    return headerToken;
  }
  const bodyToken = String(req.body?.csrfToken || "").trim();
  return bodyToken;
}

function isSecureRequest(req) {
  if (req.secure) {
    return true;
  }
  const proto = String(req.headers["x-forwarded-proto"] || "").trim().toLowerCase();
  return proto.split(",").map((part) => part.trim()).includes("https");
}

function setAdminSessionCookie(req, res, token, ttlSec) {
  const cookie = serializeCookie(ADMIN_SESSION_COOKIE, token, {
    path: "/",
    httpOnly: true,
    secure: isSecureRequest(req) || String(process.env.NODE_ENV || "").toLowerCase() === "production",
    sameSite: "Lax",
    maxAge: Math.max(60, Number(ttlSec || 0))
  });
  res.append("Set-Cookie", cookie);
}

function clearAdminSessionCookie(req, res) {
  const cookie = serializeCookie(ADMIN_SESSION_COOKIE, "", {
    path: "/",
    httpOnly: true,
    secure: isSecureRequest(req) || String(process.env.NODE_ENV || "").toLowerCase() === "production",
    sameSite: "Lax",
    maxAge: 0
  });
  res.append("Set-Cookie", cookie);
}

function requireAdminCsrf(req, res, next) {
  const method = String(req.method || "").toUpperCase();
  if (method === "GET" || method === "HEAD" || method === "OPTIONS") {
    return next();
  }
  const session = req.adminSession || extractAdminSession(req);
  const expected = String(session?.csrf || "").trim();
  const provided = extractAdminCsrfFromRequest(req);
  if (!expected || !provided || !safeConstantCompare(expected, provided)) {
    return res.status(403).json({
      error: "CSRF doğrulaması başarısız."
    });
  }
  return next();
}

function normalizeAdminNextPath(rawValue) {
  const raw = String(rawValue || "").trim();
  const safePattern = /^\/admin[\/a-zA-Z0-9._?=&-]*$/;
  if (!safePattern.test(raw)) {
    return "/admin/dashboard";
  }
  if (raw.startsWith("/admin/login")) {
    return "/admin/dashboard";
  }
  return raw;
}

function parseSupabaseCountFromContentRange(contentRangeHeader) {
  const raw = String(contentRangeHeader || "").trim();
  if (!raw.includes("/")) {
    return 0;
  }
  const tail = raw.split("/").pop();
  const count = Number(tail);
  return Number.isFinite(count) && count >= 0 ? Math.floor(count) : 0;
}

function utcDayStart(date = new Date()) {
  const d = date instanceof Date ? date : new Date(date);
  return new Date(Date.UTC(d.getUTCFullYear(), d.getUTCMonth(), d.getUTCDate(), 0, 0, 0, 0));
}

function utcDayKey(date = new Date()) {
  const d = date instanceof Date ? date : new Date(date);
  return `${d.getUTCFullYear()}-${String(d.getUTCMonth() + 1).padStart(2, "0")}-${String(d.getUTCDate()).padStart(2, "0")}`;
}

function buildLastNDaysKeys(days = 7) {
  const safeDays = Math.max(1, Math.min(31, Number(days) || 7));
  const out = [];
  const start = utcDayStart(new Date());
  for (let idx = safeDays - 1; idx >= 0; idx -= 1) {
    const day = new Date(start.getTime() - idx * 24 * 60 * 60 * 1000);
    out.push(utcDayKey(day));
  }
  return out;
}

async function fetchSupabaseRestCount({ supabaseUrl, supabaseServiceRoleKey, table, filters = [] }) {
  const qs = new URLSearchParams({ select: "id" });
  for (const [key, value] of filters) {
    qs.append(key, value);
  }
  const resp = await fetch(`${supabaseUrl}/rest/v1/${table}?${qs.toString()}`, {
    method: "GET",
    headers: {
      apikey: supabaseServiceRoleKey,
      Authorization: `Bearer ${supabaseServiceRoleKey}`,
      Prefer: "count=exact,head=true",
      Range: "0-0"
    }
  });
  if (!resp.ok) {
    const txt = await resp.text();
    throw new Error(txt || `Supabase count hatası (${resp.status})`);
  }
  return parseSupabaseCountFromContentRange(resp.headers.get("content-range"));
}

async function fetchAuthUsersOverview({ supabaseUrl, supabaseServiceRoleKey }) {
  const pageSize = 200;
  const maxPages = 25;
  const todayStartIso = utcDayStart(new Date()).toISOString();
  const nowTs = Date.now();
  const active24hFloor = nowTs - 24 * 60 * 60 * 1000;
  let page = 1;
  let total = 0;
  let today = 0;
  let confirmed = 0;
  let unconfirmed = 0;
  let suspended = 0;
  let activeLast24h = 0;

  while (page <= maxPages) {
    const qs = new URLSearchParams({
      page: String(page),
      per_page: String(pageSize)
    });
    const resp = await fetch(`${supabaseUrl}/auth/v1/admin/users?${qs.toString()}`, {
      method: "GET",
      headers: {
        apikey: supabaseServiceRoleKey,
        Authorization: `Bearer ${supabaseServiceRoleKey}`
      }
    });
    if (!resp.ok) {
      const txt = await resp.text();
      throw new Error(txt || `Auth users okunamadı (${resp.status})`);
    }
    const body = await resp.json();
    const users = Array.isArray(body?.users) ? body.users : [];
    total += users.length;
    for (const user of users) {
      const createdAt = String(user?.created_at || "").trim();
      if (createdAt && createdAt >= todayStartIso) {
        today += 1;
      }
      const confirmedAt = String(user?.email_confirmed_at || user?.confirmed_at || "").trim();
      if (confirmedAt) {
        confirmed += 1;
      } else {
        unconfirmed += 1;
      }
      const bannedUntil = String(user?.banned_until || "").trim();
      if (bannedUntil) {
        const bannedUntilTs = Date.parse(bannedUntil);
        if (Number.isFinite(bannedUntilTs) && bannedUntilTs > nowTs) {
          suspended += 1;
        }
      }
      const lastSignInAt = String(user?.last_sign_in_at || "").trim();
      if (lastSignInAt) {
        const signInTs = Date.parse(lastSignInAt);
        if (Number.isFinite(signInTs) && signInTs >= active24hFloor) {
          activeLast24h += 1;
        }
      }
    }
    if (users.length < pageSize) {
      break;
    }
    page += 1;
  }

  return {
    totalUsers: total,
    todayUsers: today,
    confirmedUsers: confirmed,
    unconfirmedUsers: unconfirmed,
    suspendedUsers: suspended,
    activeUsersLast24h: activeLast24h
  };
}

async function fetchCaseCompletionStats({ supabaseUrl, supabaseServiceRoleKey }) {
  const todayIso = utcDayStart(new Date()).toISOString();
  const totalCompleted = await fetchSupabaseRestCount({
    supabaseUrl,
    supabaseServiceRoleKey,
    table: "case_sessions",
    filters: [["status", "eq.completed"]]
  });
  const todayCompleted = await fetchSupabaseRestCount({
    supabaseUrl,
    supabaseServiceRoleKey,
    table: "case_sessions",
    filters: [
      ["status", "eq.completed"],
      ["ended_at", `gte.${todayIso}`]
    ]
  });
  return {
    totalCompleted,
    todayCompleted
  };
}

async function fetchLast7DaysCaseSeries({ supabaseUrl, supabaseServiceRoleKey }) {
  const keys = buildLastNDaysKeys(7);
  const firstDay = `${keys[0]}T00:00:00.000Z`;
  const qs = new URLSearchParams({
    select: "ended_at",
    status: "eq.completed",
    ended_at: `gte.${firstDay}`,
    order: "ended_at.asc",
    limit: "5000"
  });
  const resp = await fetch(`${supabaseUrl}/rest/v1/case_sessions?${qs.toString()}`, {
    method: "GET",
    headers: {
      apikey: supabaseServiceRoleKey,
      Authorization: `Bearer ${supabaseServiceRoleKey}`
    }
  });
  if (!resp.ok) {
    const txt = await resp.text();
    throw new Error(txt || `case series okunamadı (${resp.status})`);
  }
  const rows = await resp.json();
  const bucket = new Map(keys.map((key) => [key, 0]));
  for (const row of Array.isArray(rows) ? rows : []) {
    const ended = String(row?.ended_at || "");
    if (!ended || !ended.includes("T")) {
      continue;
    }
    const key = ended.slice(0, 10);
    if (!bucket.has(key)) {
      continue;
    }
    bucket.set(key, Number(bucket.get(key) || 0) + 1);
  }
  return keys.map((key) => ({
    date: key,
    value: Number(bucket.get(key) || 0)
  }));
}

async function fetchProfilesOverview({ supabaseUrl, supabaseServiceRoleKey }) {
  const totalProfiles = await fetchSupabaseRestCount({
    supabaseUrl,
    supabaseServiceRoleKey,
    table: "profiles"
  });
  const onboardingDone = await fetchSupabaseRestCount({
    supabaseUrl,
    supabaseServiceRoleKey,
    table: "profiles",
    filters: [["onboarding_completed", "eq.true"]]
  });

  const qs = new URLSearchParams({
    select: "id,full_name,email,role,learning_level,onboarding_completed,updated_at",
    order: "updated_at.desc",
    limit: "20"
  });
  const listResp = await fetch(`${supabaseUrl}/rest/v1/profiles?${qs.toString()}`, {
    method: "GET",
    headers: {
      apikey: supabaseServiceRoleKey,
      Authorization: `Bearer ${supabaseServiceRoleKey}`
    }
  });
  if (!listResp.ok) {
    const txt = await listResp.text();
    throw new Error(txt || `profiles list okunamadı (${listResp.status})`);
  }
  const latestProfiles = await listResp.json();

  return {
    totalProfiles,
    onboardingDone,
    latestProfiles: Array.isArray(latestProfiles) ? latestProfiles : []
  };
}

function sanitizeAdminSearchTerm(value) {
  const raw = String(value || "").trim();
  if (!raw) {
    return "";
  }
  const normalized = raw
    .replace(/[,*()]/g, " ")
    .replace(/\s+/g, " ")
    .trim()
    .slice(0, 64);
  return normalized;
}

async function fetchAdminProfilesPage({
  supabaseUrl,
  supabaseServiceRoleKey,
  page = 1,
  perPage = 12,
  search = ""
}) {
  const safePerPage = clampRateLimitValue(perPage, 12, 5, 50);
  const requestedPage = clampRateLimitValue(page, 1, 1, 100000);
  const safeSearch = sanitizeAdminSearchTerm(search);
  const filters = [];
  if (safeSearch) {
    filters.push(["or", `(full_name.ilike.*${safeSearch}*,email.ilike.*${safeSearch}*)`]);
  }

  const total = await fetchSupabaseRestCount({
    supabaseUrl,
    supabaseServiceRoleKey,
    table: "profiles",
    filters
  });
  const totalPages = Math.max(1, Math.ceil(total / safePerPage));
  const safePage = Math.min(requestedPage, totalPages);
  const offset = Math.max(0, (safePage - 1) * safePerPage);

  const qs = new URLSearchParams({
    select: "id,full_name,email,role,learning_level,onboarding_completed,updated_at,phone_number",
    order: "updated_at.desc",
    limit: String(safePerPage),
    offset: String(offset)
  });
  if (safeSearch) {
    qs.append("or", `(full_name.ilike.*${safeSearch}*,email.ilike.*${safeSearch}*)`);
  }

  const resp = await fetch(`${supabaseUrl}/rest/v1/profiles?${qs.toString()}`, {
    method: "GET",
    headers: {
      apikey: supabaseServiceRoleKey,
      Authorization: `Bearer ${supabaseServiceRoleKey}`
    }
  });
  if (!resp.ok) {
    const txt = await resp.text();
    throw new Error(txt || `profiles page okunamadı (${resp.status})`);
  }
  const rows = await resp.json().catch(() => []);

  return {
    total,
    page: safePage,
    perPage: safePerPage,
    totalPages,
    search: safeSearch,
    rows: Array.isArray(rows) ? rows : []
  };
}

async function fetchCaseStatsForUserIds({
  supabaseUrl,
  supabaseServiceRoleKey,
  userIds = []
}) {
  const cleanIds = Array.from(
    new Set(
      (Array.isArray(userIds) ? userIds : [])
        .map((item) => sanitizeUuid(item))
        .filter(Boolean)
    )
  );
  if (!cleanIds.length) {
    return {};
  }

  const qs = new URLSearchParams({
    select: "user_id,score,ended_at,updated_at",
    status: "eq.completed",
    order: "ended_at.desc",
    limit: "10000"
  });
  qs.append("user_id", `in.(${cleanIds.join(",")})`);

  const resp = await fetch(`${supabaseUrl}/rest/v1/case_sessions?${qs.toString()}`, {
    method: "GET",
    headers: {
      apikey: supabaseServiceRoleKey,
      Authorization: `Bearer ${supabaseServiceRoleKey}`
    }
  });
  if (!resp.ok) {
    const txt = await resp.text();
    throw new Error(txt || `case_stats okunamadı (${resp.status})`);
  }
  const rows = await resp.json().catch(() => []);
  const grouped = {};

  for (const row of Array.isArray(rows) ? rows : []) {
    const uid = sanitizeUuid(row?.user_id);
    if (!uid) {
      continue;
    }
    if (!grouped[uid]) {
      grouped[uid] = {
        completedCases: 0,
        scoreCount: 0,
        scoreSum: 0,
        averageScore: null,
        lastCompletedAt: null
      };
    }
    const current = grouped[uid];
    current.completedCases += 1;
    const score = extractScoreNumber(row?.score);
    if (score != null) {
      current.scoreCount += 1;
      current.scoreSum += Number(score);
      current.averageScore = Number((current.scoreSum / current.scoreCount).toFixed(1));
    }
    const candidateTime = String(row?.ended_at || row?.updated_at || "").trim();
    if (candidateTime && (!current.lastCompletedAt || candidateTime > current.lastCompletedAt)) {
      current.lastCompletedAt = candidateTime;
    }
  }

  return grouped;
}

async function fetchRateLimitViolationsLast24h({ supabaseUrl, supabaseServiceRoleKey }) {
  const sinceIso = new Date(Date.now() - 24 * 60 * 60 * 1000).toISOString();
  return fetchSupabaseRestCount({
    supabaseUrl,
    supabaseServiceRoleKey,
    table: "rate_limit_audit_events",
    filters: [
      ["created_at", `gte.${sinceIso}`],
      ["decision", "eq.blocked"]
    ]
  });
}

function summarizeRateLimitMap(map, { limit = 8 } = {}) {
  return Array.from(map.values())
    .sort((a, b) => Number(b.count || 0) - Number(a.count || 0))
    .slice(0, Math.max(1, Number(limit || 8)))
    .map((item) => ({
      key: item.key,
      count: item.count,
      sourceCategory: item.sourceCategory,
      sourceLabel: item.sourceLabel,
      lastSeenAt: item.lastSeenAt
    }));
}

async function fetchRateLimitViolationsInsights({
  supabaseUrl,
  supabaseServiceRoleKey,
  hours = 24,
  limit = 500
}) {
  const safeHours = clampRateLimitValue(hours, 24, 1, 24 * 7);
  const safeLimit = clampRateLimitValue(limit, 500, 50, 2500);
  const sinceIso = new Date(Date.now() - safeHours * 60 * 60 * 1000).toISOString();
  const qs = new URLSearchParams({
    select: "scope,endpoint,decision,identity_hash,request_count,metadata,created_at",
    created_at: `gte.${sinceIso}`,
    decision: "eq.blocked",
    order: "created_at.desc",
    limit: String(safeLimit)
  });
  const resp = await fetch(`${supabaseUrl}/rest/v1/rate_limit_audit_events?${qs.toString()}`, {
    method: "GET",
    headers: {
      apikey: supabaseServiceRoleKey,
      Authorization: `Bearer ${supabaseServiceRoleKey}`
    }
  });
  if (!resp.ok) {
    const txt = await resp.text();
    throw new Error(txt || `rate_limit_audit_events okunamadı (${resp.status})`);
  }

  const rows = await resp.json().catch(() => []);
  const list = Array.isArray(rows) ? rows : [];
  const scopeMap = new Map();
  const endpointMap = new Map();
  const identityMap = new Map();
  const categories = {
    internal: 0,
    external: 0,
    monitoring: 0,
    unknown: 0
  };
  const recentEvents = [];

  for (const row of list) {
    const scope = String(row?.scope || "unknown").trim() || "unknown";
    const endpoint = String(row?.endpoint || "").trim() || "(endpoint yok)";
    const metadata = parseRateLimitMetadata(row?.metadata);
    const source = inferRateLimitEventSource({
      scope,
      endpoint,
      metadata
    });
    const sourceCategory = ["internal", "external", "monitoring"].includes(source.sourceCategory)
      ? source.sourceCategory
      : "unknown";
    categories[sourceCategory] += 1;

    const scopeKey = scope.toLowerCase();
    if (!scopeMap.has(scopeKey)) {
      scopeMap.set(scopeKey, {
        key: scope,
        count: 0,
        sourceCategory,
        sourceLabel: source.sourceLabel,
        lastSeenAt: null
      });
    }
    const scopeEntry = scopeMap.get(scopeKey);
    scopeEntry.count += 1;
    if (!scopeEntry.lastSeenAt || String(row?.created_at || "") > scopeEntry.lastSeenAt) {
      scopeEntry.lastSeenAt = String(row?.created_at || "");
    }

    const endpointKey = endpoint.toLowerCase();
    if (!endpointMap.has(endpointKey)) {
      endpointMap.set(endpointKey, {
        key: endpoint,
        count: 0,
        sourceCategory,
        sourceLabel: source.sourceLabel,
        lastSeenAt: null
      });
    }
    const endpointEntry = endpointMap.get(endpointKey);
    endpointEntry.count += 1;
    if (!endpointEntry.lastSeenAt || String(row?.created_at || "") > endpointEntry.lastSeenAt) {
      endpointEntry.lastSeenAt = String(row?.created_at || "");
    }

    const identityHash = String(row?.identity_hash || "").trim();
    if (identityHash) {
      identityMap.set(identityHash, Number(identityMap.get(identityHash) || 0) + 1);
    }

    if (recentEvents.length < 15) {
      recentEvents.push({
        createdAt: String(row?.created_at || ""),
        scope,
        endpoint,
        sourceCategory,
        sourceLabel: source.sourceLabel,
        identityHash: identityHash || null,
        requestCount: Number.isFinite(Number(row?.request_count)) ? Number(row.request_count) : null
      });
    }
  }

  const total = list.length;
  const topScopes = summarizeRateLimitMap(scopeMap, { limit: 8 });
  const topEndpoints = summarizeRateLimitMap(endpointMap, { limit: 8 });
  const topIdentities = Array.from(identityMap.entries())
    .sort((a, b) => Number(b[1]) - Number(a[1]))
    .slice(0, 8)
    .map(([identityHash, count]) => ({ identityHash, count }));

  const internalLike = categories.internal + categories.monitoring;
  const diagnosis =
    total === 0
      ? "Son 24 saatte rate limit aşımı yok."
      : internalLike >= Math.ceil(total * 0.6)
        ? "İhlallerin çoğu iç trafik/monitoring kaynaklı görünüyor."
        : "İhlallerin önemli kısmı dış istemci trafiğinden geliyor olabilir.";

  return {
    windowHours: safeHours,
    sampledRows: total,
    categories,
    diagnosis,
    uniqueIdentities: identityMap.size,
    topScopes,
    topEndpoints,
    topIdentities,
    recentEvents
  };
}

function summarizeCountMap(map, { limit = 8 } = {}) {
  return Array.from(map.values())
    .sort((a, b) => Number(b.count || 0) - Number(a.count || 0))
    .slice(0, Math.max(1, Number(limit || 8)))
    .map((item) => ({
      key: item.key,
      count: Number(item.count || 0),
      lastSeenAt: item.lastSeenAt || null
    }));
}

async function fetchSuspiciousActivityInsights({
  supabaseUrl,
  supabaseServiceRoleKey,
  hours = 24,
  limit = 500
}) {
  const safeHours = clampRateLimitValue(hours, 24, 1, 24 * 7);
  const safeLimit = clampRateLimitValue(limit, 500, 50, 2500);
  const sinceIso = new Date(Date.now() - safeHours * 60 * 60 * 1000).toISOString();
  const qs = new URLSearchParams({
    select: "event_type,scope,user_id,identity_hash,endpoint,request_count,threshold,window_ms,metadata,created_at",
    created_at: `gte.${sinceIso}`,
    order: "created_at.desc",
    limit: String(safeLimit)
  });
  const resp = await fetch(`${supabaseUrl}/rest/v1/suspicious_activity_events?${qs.toString()}`, {
    method: "GET",
    headers: {
      apikey: supabaseServiceRoleKey,
      Authorization: `Bearer ${supabaseServiceRoleKey}`
    }
  });
  if (!resp.ok) {
    const txt = await resp.text();
    throw new Error(txt || `suspicious_activity_events okunamadı (${resp.status})`);
  }

  const rows = await resp.json().catch(() => []);
  const list = Array.isArray(rows) ? rows : [];
  const eventTypeMap = new Map();
  const scopeMap = new Map();
  const identityMap = new Map();
  const userSet = new Set();
  const recentEvents = [];

  for (const row of list) {
    const eventType = String(row?.event_type || "unknown").trim() || "unknown";
    const scope = String(row?.scope || "unknown").trim() || "unknown";
    const identityHash = String(row?.identity_hash || "").trim();
    const userId = sanitizeUuid(row?.user_id);
    const createdAt = String(row?.created_at || "").trim();

    const eventKey = eventType.toLowerCase();
    if (!eventTypeMap.has(eventKey)) {
      eventTypeMap.set(eventKey, {
        key: eventType,
        count: 0,
        lastSeenAt: null
      });
    }
    const eventEntry = eventTypeMap.get(eventKey);
    eventEntry.count += 1;
    if (!eventEntry.lastSeenAt || createdAt > eventEntry.lastSeenAt) {
      eventEntry.lastSeenAt = createdAt || null;
    }

    const scopeKey = scope.toLowerCase();
    if (!scopeMap.has(scopeKey)) {
      scopeMap.set(scopeKey, {
        key: scope,
        count: 0,
        lastSeenAt: null
      });
    }
    const scopeEntry = scopeMap.get(scopeKey);
    scopeEntry.count += 1;
    if (!scopeEntry.lastSeenAt || createdAt > scopeEntry.lastSeenAt) {
      scopeEntry.lastSeenAt = createdAt || null;
    }

    if (identityHash) {
      identityMap.set(identityHash, Number(identityMap.get(identityHash) || 0) + 1);
    }
    if (userId) {
      userSet.add(userId);
    }

    if (recentEvents.length < 20) {
      recentEvents.push({
        createdAt: createdAt || null,
        eventType,
        scope,
        endpoint: String(row?.endpoint || "").trim() || null,
        userId: userId || null,
        requestCount: Number.isFinite(Number(row?.request_count)) ? Number(row.request_count) : null,
        threshold: Number.isFinite(Number(row?.threshold)) ? Number(row.threshold) : null,
        windowMs: Number.isFinite(Number(row?.window_ms)) ? Number(row.window_ms) : null
      });
    }
  }

  const total = list.length;
  const diagnosis =
    total === 0
      ? "Son 24 saatte şüpheli aktivite olayı yok."
      : total >= 100
        ? "Şüpheli aktivite hacmi yüksek. Scope ve endpoint bazlı kaynakları önceliklendir."
        : "Şüpheli aktiviteler sınırlı. Dış trafik ve auth kaynaklarını izlemeye devam et.";

  return {
    windowHours: safeHours,
    sampledRows: total,
    uniqueIdentities: identityMap.size,
    uniqueUsers: userSet.size,
    topEventTypes: summarizeCountMap(eventTypeMap, { limit: 8 }),
    topScopes: summarizeCountMap(scopeMap, { limit: 8 }),
    topIdentities: Array.from(identityMap.entries())
      .sort((a, b) => Number(b[1]) - Number(a[1]))
      .slice(0, 8)
      .map(([identityHash, count]) => ({ identityHash, count })),
    recentEvents,
    diagnosis
  };
}

function parseScopeAndIdentityFromAuthFailureKey(rawKey) {
  const safe = String(rawKey || "").trim();
  if (!safe) {
    return {
      scope: "unknown",
      identityHash: ""
    };
  }
  const lastColon = safe.lastIndexOf(":");
  if (lastColon <= 0) {
    return {
      scope: safe,
      identityHash: ""
    };
  }
  return {
    scope: safe.slice(0, lastColon) || "unknown",
    identityHash: safe.slice(lastColon + 1) || ""
  };
}

async function fetchBruteForceBlocksSnapshot({ limit = 120 } = {}) {
  const safeLimit = clampRateLimitValue(limit, 120, 20, 400);
  const scopeMap = new Map();
  const samples = [];
  const nowMs = Date.now();
  let activeBlocks = 0;

  if (isUpstashEnabled()) {
    const cfg = getUpstashConfig();
    const prefix = `${cfg.prefix}:bf:block:`;
    const keys = await listRedisKeysByPattern(`${prefix}*`);
    const inspectedKeys = keys.slice(0, Math.max(safeLimit * 4, 120));
    for (const fullKey of inspectedKeys) {
      const suffix = fullKey.startsWith(prefix) ? fullKey.slice(prefix.length) : fullKey;
      const ttlMsRaw = await runRedisCommand(["PTTL", fullKey]);
      const ttlMs = Number(ttlMsRaw);
      if (!Number.isFinite(ttlMs) || ttlMs <= 0) {
        continue;
      }

      activeBlocks += 1;
      const ttlSec = Math.max(1, Math.ceil(ttlMs / 1000));
      const { scope, identityHash } = parseScopeAndIdentityFromAuthFailureKey(suffix);

      const scopeKey = String(scope || "unknown").toLowerCase();
      if (!scopeMap.has(scopeKey)) {
        scopeMap.set(scopeKey, { key: scope, count: 0, maxTtlSec: 0 });
      }
      const scopeEntry = scopeMap.get(scopeKey);
      scopeEntry.count += 1;
      scopeEntry.maxTtlSec = Math.max(Number(scopeEntry.maxTtlSec || 0), ttlSec);

      if (samples.length < safeLimit) {
        samples.push({
          scope,
          identityHash: identityHash || null,
          ttlSec
        });
      }
    }
  } else {
    cleanupAuthFailureStore(nowMs);
    for (const [key, entry] of authFailureStore.entries()) {
      const blockedUntil = Number(entry?.blockedUntil || 0);
      if (!blockedUntil || blockedUntil <= nowMs) {
        continue;
      }
      const ttlSec = Math.max(1, Math.ceil((blockedUntil - nowMs) / 1000));
      const { scope, identityHash } = parseScopeAndIdentityFromAuthFailureKey(key);
      activeBlocks += 1;
      const scopeKey = String(scope || "unknown").toLowerCase();
      if (!scopeMap.has(scopeKey)) {
        scopeMap.set(scopeKey, { key: scope, count: 0, maxTtlSec: 0 });
      }
      const scopeEntry = scopeMap.get(scopeKey);
      scopeEntry.count += 1;
      scopeEntry.maxTtlSec = Math.max(Number(scopeEntry.maxTtlSec || 0), ttlSec);
      if (samples.length < safeLimit) {
        samples.push({
          scope,
          identityHash: identityHash || null,
          ttlSec
        });
      }
    }
  }

  const topScopes = Array.from(scopeMap.values())
    .sort((a, b) => Number(b.count || 0) - Number(a.count || 0))
    .slice(0, 10)
    .map((item) => ({
      scope: item.key,
      count: Number(item.count || 0),
      maxTtlSec: Number(item.maxTtlSec || 0)
    }));

  const sortedSamples = samples
    .sort((a, b) => Number(b.ttlSec || 0) - Number(a.ttlSec || 0))
    .slice(0, safeLimit);

  return {
    source: isUpstashEnabled() ? "upstash" : "memory",
    activeBlocks,
    topScopes,
    samples: sortedSamples
  };
}

async function fetchApiRequestsLastHour() {
  cleanupApiRequestRuntimeStore(Date.now());
  if (!isUpstashEnabled()) {
    const floor = Date.now() - 60 * 60 * 1000;
    return apiRequestRuntimeStore.reduce((sum, item) => {
      return sum + (Number(item?.ts || 0) >= floor ? 1 : 0);
    }, 0);
  }
  const keys = [];
  for (let idx = 0; idx < 60; idx += 1) {
    const d = new Date(Date.now() - idx * 60_000);
    keys.push(buildRedisKey(`metrics:requests:minute:${minuteKey(d)}`));
  }
  try {
    const values = await runRedisCommand(["MGET", ...keys]);
    if (!Array.isArray(values)) {
      return 0;
    }
    return values.reduce((sum, raw) => {
      const n = Number(raw);
      return sum + (Number.isFinite(n) ? n : 0);
    }, 0);
  } catch {
    return 0;
  }
}

function mergeMapRecord(target, key, initFactory) {
  if (!target.has(key)) {
    target.set(key, initFactory());
  }
  return target.get(key);
}

async function fetchApiRequestBreakdownLastHour({ endpointLimit = 8, callerLimit = 6 } = {}) {
  const safeEndpointLimit = clampRateLimitValue(endpointLimit, 8, 3, 20);
  const safeCallerLimit = clampRateLimitValue(callerLimit, 6, 3, 20);
  const endpointMap = new Map();
  const callerMap = new Map();
  let total = 0;
  let success = 0;
  let error = 0;

  if (!isUpstashEnabled()) {
    cleanupApiRequestRuntimeStore(Date.now());
    const floor = Date.now() - 60 * 60 * 1000;
    for (const item of apiRequestRuntimeStore) {
      if (Number(item?.ts || 0) < floor) {
        continue;
      }
      const statusBucket = String(item?.bucket || "error");
      const endpointKey = `${item?.method || "GET"} ${item?.path || "/"}`;
      const endpoint = mergeMapRecord(endpointMap, endpointKey, () => ({
        method: item?.method || "GET",
        path: item?.path || "/",
        total: 0,
        success: 0,
        error: 0
      }));
      endpoint.total += 1;
      if (statusBucket === "success") {
        endpoint.success += 1;
        success += 1;
      } else {
        endpoint.error += 1;
        error += 1;
      }
      const callerKey = String(item?.caller || "unknown");
      const caller = mergeMapRecord(callerMap, callerKey, () => ({
        caller: callerKey,
        total: 0,
        success: 0,
        error: 0
      }));
      caller.total += 1;
      if (statusBucket === "success") {
        caller.success += 1;
      } else {
        caller.error += 1;
      }
      total += 1;
    }
  } else {
    const cfg = getUpstashConfig();
    const now = new Date();
    const hourTokens = Array.from(new Set([hourKey(now), hourKey(new Date(now.getTime() - 60 * 60 * 1000))]));
    const endpointKeys = [];
    const callerKeys = [];

    for (const token of hourTokens) {
      const endpointPattern = `${cfg.prefix}:metrics:requests:endpoint:hour:${token}:*`;
      const callerPattern = `${cfg.prefix}:metrics:requests:caller:hour:${token}:*`;
      endpointKeys.push(...(await listRedisKeysByPattern(endpointPattern)));
      callerKeys.push(...(await listRedisKeysByPattern(callerPattern)));
    }

    const uniqEndpointKeys = Array.from(new Set(endpointKeys));
    const uniqCallerKeys = Array.from(new Set(callerKeys));
    let endpointValues = [];
    let callerValues = [];
    try {
      endpointValues = uniqEndpointKeys.length ? await runRedisCommand(["MGET", ...uniqEndpointKeys]) : [];
      callerValues = uniqCallerKeys.length ? await runRedisCommand(["MGET", ...uniqCallerKeys]) : [];
    } catch {
      endpointValues = [];
      callerValues = [];
    }

    const endpointValueMap = new Map();
    uniqEndpointKeys.forEach((key, idx) => {
      endpointValueMap.set(key, Number(Array.isArray(endpointValues) ? endpointValues[idx] : 0) || 0);
    });
    const callerValueMap = new Map();
    uniqCallerKeys.forEach((key, idx) => {
      callerValueMap.set(key, Number(Array.isArray(callerValues) ? callerValues[idx] : 0) || 0);
    });

    for (const key of uniqEndpointKeys) {
      const value = Number(endpointValueMap.get(key) || 0);
      if (value <= 0) {
        continue;
      }
      const marker = `${cfg.prefix}:metrics:requests:endpoint:hour:`;
      const idx = key.indexOf(marker);
      if (idx < 0) {
        continue;
      }
      const rest = key.slice(idx + marker.length);
      const firstColon = rest.indexOf(":");
      if (firstColon < 0) {
        continue;
      }
      const remaining = rest.slice(firstColon + 1);
      const secondColon = remaining.indexOf(":");
      if (secondColon < 0) {
        continue;
      }
      const method = remaining.slice(0, secondColon);
      const afterMethod = remaining.slice(secondColon + 1);
      const lastColon = afterMethod.lastIndexOf(":");
      if (lastColon < 0) {
        continue;
      }
      const encodedPath = afterMethod.slice(0, lastColon);
      const kind = afterMethod.slice(lastColon + 1);
      let pathValue = "/";
      try {
        pathValue = fromBase64Url(encodedPath).toString("utf8") || "/";
      } catch {
        pathValue = "/";
      }
      const endpointKey = `${method} ${pathValue}`;
      const endpoint = mergeMapRecord(endpointMap, endpointKey, () => ({
        method,
        path: pathValue,
        total: 0,
        success: 0,
        error: 0
      }));
      if (kind === "total") {
        endpoint.total += value;
        total += value;
      } else if (kind === "success") {
        endpoint.success += value;
        success += value;
      } else if (kind === "error") {
        endpoint.error += value;
        error += value;
      }
    }

    for (const key of uniqCallerKeys) {
      const value = Number(callerValueMap.get(key) || 0);
      if (value <= 0) {
        continue;
      }
      const marker = `${cfg.prefix}:metrics:requests:caller:hour:`;
      const idx = key.indexOf(marker);
      if (idx < 0) {
        continue;
      }
      const rest = key.slice(idx + marker.length);
      const firstColon = rest.indexOf(":");
      if (firstColon < 0) {
        continue;
      }
      const afterHour = rest.slice(firstColon + 1);
      const lastColon = afterHour.lastIndexOf(":");
      if (lastColon < 0) {
        continue;
      }
      const callerHash = afterHour.slice(0, lastColon);
      const kind = afterHour.slice(lastColon + 1);
      const caller = mergeMapRecord(callerMap, callerHash, () => ({
        caller: callerHash,
        total: 0,
        success: 0,
        error: 0
      }));
      if (kind === "total") {
        caller.total += value;
      } else if (kind === "success") {
        caller.success += value;
      } else if (kind === "error") {
        caller.error += value;
      }
    }

    if (total < success + error) {
      total = success + error;
    }
  }

  const topEndpoints = Array.from(endpointMap.values())
    .sort((a, b) => Number(b.total || 0) - Number(a.total || 0))
    .slice(0, safeEndpointLimit);
  const topCallers = Array.from(callerMap.values())
    .sort((a, b) => Number(b.total || 0) - Number(a.total || 0))
    .slice(0, safeCallerLimit)
    .map((item) => ({
      ...item,
      callerLabel: item.caller ? `ip#${String(item.caller).slice(0, 8)}` : "ip#unknown"
    }));

  return {
    total,
    success,
    error,
    endpointCount: endpointMap.size,
    callerCount: callerMap.size,
    topEndpoints,
    topCallers
  };
}

async function fetchApiRequestsHourlySeriesLast24h() {
  const now = new Date();
  const tokens = [];
  for (let idx = 23; idx >= 0; idx -= 1) {
    const d = new Date(now.getTime() - idx * 60 * 60 * 1000);
    tokens.push(hourKey(d));
  }

  if (!isUpstashEnabled()) {
    cleanupApiRequestRuntimeStore(Date.now());
    const floor = Date.now() - 24 * 60 * 60 * 1000;
    const bucket = new Map(tokens.map((token) => [token, 0]));
    for (const item of apiRequestRuntimeStore) {
      const ts = Number(item?.ts || 0);
      if (ts < floor) {
        continue;
      }
      const token = hourKey(new Date(ts));
      if (!bucket.has(token)) {
        continue;
      }
      bucket.set(token, Number(bucket.get(token) || 0) + 1);
    }
    return tokens.map((token) => ({
      hourToken: token,
      label: `${token.slice(6, 8)}/${token.slice(8, 10)} ${token.slice(10, 12)}:00`,
      value: Number(bucket.get(token) || 0)
    }));
  }

  const keys = tokens.map((token) => buildRedisKey(`metrics:requests:hour:${token}`));
  let values = [];
  try {
    values = await runRedisCommand(["MGET", ...keys]);
  } catch {
    values = [];
  }
  return tokens.map((token, idx) => {
    const raw = Array.isArray(values) ? values[idx] : 0;
    const count = Number(raw);
    return {
      hourToken: token,
      label: `${token.slice(6, 8)}/${token.slice(8, 10)} ${token.slice(10, 12)}:00`,
      value: Number.isFinite(count) ? count : 0
    };
  });
}

async function fetchProfilesByUserIds({
  supabaseUrl,
  supabaseServiceRoleKey,
  userIds = []
}) {
  const cleanIds = Array.from(
    new Set(
      (Array.isArray(userIds) ? userIds : [])
        .map((item) => sanitizeUuid(item))
        .filter(Boolean)
    )
  );
  if (!cleanIds.length) {
    return {};
  }
  const qs = new URLSearchParams({
    select: "id,full_name,email"
  });
  qs.append("id", `in.(${cleanIds.join(",")})`);

  const resp = await fetch(`${supabaseUrl}/rest/v1/profiles?${qs.toString()}`, {
    method: "GET",
    headers: {
      apikey: supabaseServiceRoleKey,
      Authorization: `Bearer ${supabaseServiceRoleKey}`
    }
  });
  if (!resp.ok) {
    const txt = await resp.text();
    throw new Error(txt || `profiles map okunamadı (${resp.status})`);
  }
  const rows = await resp.json().catch(() => []);
  const map = {};
  for (const row of Array.isArray(rows) ? rows : []) {
    const id = sanitizeUuid(row?.id);
    if (!id) {
      continue;
    }
    map[id] = {
      full_name: row?.full_name || null,
      email: row?.email || null
    };
  }
  return map;
}

async function fetchRecentSessionsForAdmin({
  supabaseUrl,
  supabaseServiceRoleKey,
  limit = 40
}) {
  const safeLimit = clampRateLimitValue(limit, 40, 10, 120);
  const qs = new URLSearchParams({
    select: "id,user_id,session_id,mode,status,difficulty,created_at,updated_at,started_at,ended_at,message_count,duration_min,case_context,score",
    order: "created_at.desc",
    limit: String(safeLimit)
  });
  const resp = await fetch(`${supabaseUrl}/rest/v1/case_sessions?${qs.toString()}`, {
    method: "GET",
    headers: {
      apikey: supabaseServiceRoleKey,
      Authorization: `Bearer ${supabaseServiceRoleKey}`
    }
  });
  if (!resp.ok) {
    const txt = await resp.text();
    throw new Error(txt || `recent sessions okunamadı (${resp.status})`);
  }
  const rows = await resp.json().catch(() => []);
  const list = Array.isArray(rows) ? rows : [];
  const profileMap = await fetchProfilesByUserIds({
    supabaseUrl,
    supabaseServiceRoleKey,
    userIds: list.map((item) => item?.user_id)
  });

  return list.map((row) => {
    const uid = sanitizeUuid(row?.user_id);
    const profile = profileMap?.[uid] || {};
    const context = row?.case_context && typeof row.case_context === "object" ? row.case_context : {};
    return {
      id: row?.id || null,
      user_id: uid || null,
      user_name: String(profile?.full_name || "").trim() || "Belirtilmemiş",
      email: profile?.email || "Belirtilmemiş",
      session_id: row?.session_id || null,
      mode: row?.mode || null,
      status: row?.status || null,
      difficulty: row?.difficulty || null,
      specialty: context?.specialty || context?.specialty_name || "Belirtilmemiş",
      created_at: row?.created_at || null,
      started_at: row?.started_at || row?.created_at || null,
      updated_at: row?.updated_at || null,
      ended_at: row?.ended_at || null,
      message_count: Number(row?.message_count || 0),
      duration_min: Number(row?.duration_min || 0),
      score: extractScoreNumber(row?.score)
    };
  });
}

async function fetchCaseSessionsForAnalytics({
  supabaseUrl,
  supabaseServiceRoleKey,
  limit = 5000
}) {
  const safeLimit = clampRateLimitValue(limit, 5000, 100, 20000);
  const buildQuery = (includeMetrics) => {
    const selectBase = "id,mode,status,started_at,ended_at,duration_min,message_count,transcript,created_at,updated_at";
    const select = includeMetrics ? `${selectBase},usage_metrics,cost_metrics` : selectBase;
    const qs = new URLSearchParams({
      select,
      order: "created_at.desc",
      limit: String(safeLimit)
    });
    return `${supabaseUrl}/rest/v1/case_sessions?${qs.toString()}`;
  };

  const runFetch = async (includeMetrics) =>
    fetch(buildQuery(includeMetrics), {
      method: "GET",
      headers: {
        apikey: supabaseServiceRoleKey,
        Authorization: `Bearer ${supabaseServiceRoleKey}`
      }
    });

  let resp = await runFetch(true);
  if (!resp.ok) {
    const txt = await resp.text();
    const lowered = String(txt || "").toLowerCase();
    const metricsColumnMissing =
      lowered.includes("usage_metrics") ||
      lowered.includes("cost_metrics") ||
      (lowered.includes("column") && lowered.includes("does not exist"));
    if (!metricsColumnMissing) {
      throw new Error(txt || `analytics session sorgusu başarısız (${resp.status})`);
    }
    resp = await runFetch(false);
  }
  if (!resp.ok) {
    const txt = await resp.text();
    throw new Error(txt || `analytics session sorgusu başarısız (${resp.status})`);
  }
  const rows = await resp.json().catch(() => []);
  return Array.isArray(rows) ? rows : [];
}

function buildAdminAnalyticsSummary(rows) {
  const safeRows = Array.isArray(rows) ? rows : [];
  const totals = {
    sessions: 0,
    text: {
      sessions: 0,
      durationMin: 0,
      userMessages: 0,
      userChars: 0,
      aiMessages: 0,
      aiChars: 0
    },
    voice: {
      sessions: 0,
      durationMin: 0,
      userTranscriptMessages: 0,
      userTranscriptChars: 0,
      userMessages: 0,
      userChars: 0,
      aiMessages: 0,
      aiChars: 0
    },
    cost: {
      total: 0,
      text: 0,
      voice: 0
    }
  };

  for (const row of safeRows) {
    const mode = row?.mode === "text" ? "text" : "voice";
    const durationMin = resolveSessionDurationMin({
      durationMin: row?.duration_min,
      startedAt: row?.started_at,
      endedAt: row?.ended_at
    });
    const usage = buildSessionUsageMetrics({
      mode,
      transcript: Array.isArray(row?.transcript) ? row.transcript : [],
      durationMin
    });
    const cost = buildSessionCostMetrics({
      mode,
      usageMetrics: usage,
      durationMin
    });

    totals.sessions += 1;
    if (mode === "text") {
      totals.text.sessions += 1;
      totals.text.durationMin += durationMin;
      totals.text.userMessages += safePositiveNumber(usage.text_user_message_count, 0);
      totals.text.userChars += safePositiveNumber(usage.text_user_char_count, 0);
      totals.text.aiMessages += safePositiveNumber(usage.text_ai_message_count, 0);
      totals.text.aiChars += safePositiveNumber(usage.text_ai_char_count, 0);
      totals.cost.text += safePositiveNumber(cost.text_cost_total, 0);
    } else {
      totals.voice.sessions += 1;
      totals.voice.durationMin += durationMin;
      totals.voice.userTranscriptMessages += safePositiveNumber(usage.voice_user_transcript_message_count, 0);
      totals.voice.userTranscriptChars += safePositiveNumber(usage.voice_user_transcript_char_count, 0);
      totals.voice.userMessages += safePositiveNumber(usage.voice_user_message_count, 0);
      totals.voice.userChars += safePositiveNumber(usage.voice_user_char_count, 0);
      totals.voice.aiMessages += safePositiveNumber(usage.voice_ai_message_count, 0);
      totals.voice.aiChars += safePositiveNumber(usage.voice_ai_char_count, 0);
      totals.cost.voice += safePositiveNumber(cost.voice_cost_total, 0);
    }
  }

  totals.cost.total = totals.cost.text + totals.cost.voice;

  const avg = (value, count) => (count > 0 ? roundCost(value / count) : 0);
  const averages = {
    text: {
      sessionDurationMin: avg(totals.text.durationMin, totals.text.sessions),
      userMessagesPerSession: avg(totals.text.userMessages, totals.text.sessions),
      userCharsPerSession: avg(totals.text.userChars, totals.text.sessions),
      aiMessagesPerSession: avg(totals.text.aiMessages, totals.text.sessions),
      aiCharsPerSession: avg(totals.text.aiChars, totals.text.sessions)
    },
    voice: {
      sessionDurationMin: avg(totals.voice.durationMin, totals.voice.sessions),
      userTranscriptMessagesPerSession: avg(totals.voice.userTranscriptMessages, totals.voice.sessions),
      userTranscriptCharsPerSession: avg(totals.voice.userTranscriptChars, totals.voice.sessions),
      userMessagesPerSession: avg(totals.voice.userMessages, totals.voice.sessions),
      userCharsPerSession: avg(totals.voice.userChars, totals.voice.sessions),
      aiMessagesPerSession: avg(totals.voice.aiMessages, totals.voice.sessions),
      aiCharsPerSession: avg(totals.voice.aiChars, totals.voice.sessions)
    },
    cost: {
      perSessionAll: avg(totals.cost.total, totals.sessions),
      perTextSession: avg(totals.cost.text, totals.text.sessions),
      perVoiceSession: avg(totals.cost.voice, totals.voice.sessions)
    }
  };

  return {
    generatedAt: new Date().toISOString(),
    rowsAnalyzed: safeRows.length,
    rates: getSessionCostRateCard(),
    totals: {
      sessions: totals.sessions,
      textSessions: totals.text.sessions,
      voiceSessions: totals.voice.sessions,
      text: {
        durationMin: roundCost(totals.text.durationMin),
        userMessages: totals.text.userMessages,
        userChars: totals.text.userChars,
        aiMessages: totals.text.aiMessages,
        aiChars: totals.text.aiChars
      },
      voice: {
        durationMin: roundCost(totals.voice.durationMin),
        userTranscriptMessages: totals.voice.userTranscriptMessages,
        userTranscriptChars: totals.voice.userTranscriptChars,
        userMessages: totals.voice.userMessages,
        userChars: totals.voice.userChars,
        aiMessages: totals.voice.aiMessages,
        aiChars: totals.voice.aiChars
      },
      cost: {
        total: roundCost(totals.cost.total),
        text: roundCost(totals.cost.text),
        voice: roundCost(totals.cost.voice)
      }
    },
    averages
  };
}

async function fetchElevenLabsUsageSummary() {
  if (!isUpstashEnabled()) {
    return {
      totalSessions: 0,
      lastHourSessions: 0,
      agents: []
    };
  }
  const currentHour = hourKey(new Date());
  let totalSessions = 0;
  let lastHourSessions = 0;
  try {
    totalSessions = Number(await runRedisCommand(["GET", buildRedisKey("metrics:elevenlabs:sessions:total")])) || 0;
    lastHourSessions =
      Number(await runRedisCommand(["GET", buildRedisKey(`metrics:elevenlabs:sessions:hour:${currentHour}`)])) || 0;
  } catch {
    // noop
  }

  const cfg = getUpstashConfig();
  const agentKeys = await listRedisKeysByPattern(`${cfg.prefix}:metrics:elevenlabs:agent:*:total`);
  const agents = [];
  for (const key of agentKeys.slice(0, 20)) {
    const parts = String(key).split(":");
    const agentId = parts.length >= 2 ? parts[parts.length - 2] : "unknown";
    let total = 0;
    try {
      total = Number(await runRedisCommand(["GET", key])) || 0;
    } catch {
      total = 0;
    }
    agents.push({
      agentId,
      totalSessions: total
    });
  }
  agents.sort((a, b) => Number(b.totalSessions || 0) - Number(a.totalSessions || 0));

  return {
    totalSessions,
    lastHourSessions,
    agents: agents.slice(0, 8)
  };
}

function getSessionAuthTokenConfig() {
  const secret = String(
    process.env.ELEVENLABS_SESSION_TOKEN_SECRET ||
      process.env.SESSION_AUTH_TOKEN_SECRET ||
      process.env.AI_ADMIN_TOKEN ||
      process.env.OPENAI_API_KEY ||
      ""
  ).trim();
  const ttlSec = clampRateLimitValue(process.env.ELEVENLABS_SESSION_TOKEN_TTL_SEC, 3600, 300, 24 * 60 * 60);
  const windowSec = clampRateLimitValue(
    process.env.ELEVENLABS_SESSION_WINDOW_SEC,
    90,
    60,
    Math.max(120, ttlSec)
  );
  return {
    secret,
    ttlSec,
    windowSec: Math.min(windowSec, ttlSec)
  };
}

function getActiveSessionHeartbeatConfig() {
  const refreshSec = clampRateLimitValue(
    process.env.ELEVENLABS_ACTIVE_SESSION_HEARTBEAT_SEC,
    75,
    20,
    300
  );
  return {
    refreshSec
  };
}

function isSingleSessionEnforced() {
  const raw = String(process.env.ELEVENLABS_SINGLE_ACTIVE_SESSION_ENABLED || "true")
    .trim()
    .toLowerCase();
  return raw !== "false" && raw !== "0" && raw !== "off";
}

function cleanupActiveElevenSessionStore(nowMs = Date.now()) {
  if (activeElevenSessionStore.size === 0) {
    return;
  }
  for (const [key, entry] of activeElevenSessionStore.entries()) {
    if (!entry) {
      activeElevenSessionStore.delete(key);
      continue;
    }
    const lockUntilMs = Number(entry.lockUntilMs || 0);
    if (!lockUntilMs || lockUntilMs <= nowMs) {
      activeElevenSessionStore.delete(key);
    }
  }
}

async function getActiveElevenSession(userId) {
  const key = sanitizeUuid(userId);
  if (!key) {
    return null;
  }
  if (isUpstashEnabled()) {
    try {
      const redisKey = buildRedisKey(`active-session:${key}`);
      const entry = await redisGetJson(redisKey);
      if (!entry || typeof entry !== "object") {
        await removeActiveSessionIndexes(key);
        return null;
      }
      if (Number(entry.lockUntilMs || 0) <= Date.now()) {
        await runRedisCommand(["DEL", redisKey]);
        await removeActiveSessionIndexes(key);
        return null;
      }
      await addActiveSessionIndexes(key, String(entry.mode || "voice"));
      return entry;
    } catch (error) {
      // eslint-disable-next-line no-console
      console.warn(`[active-session] upstash fallback -> memory: ${error?.message || "unknown"}`);
    }
  }
  cleanupActiveElevenSessionStore(Date.now());
  const entry = activeElevenSessionStore.get(key);
  if (!entry) {
    return null;
  }
  if (Number(entry.lockUntilMs || 0) <= Date.now()) {
    activeElevenSessionStore.delete(key);
    return null;
  }
  return entry;
}

async function setActiveElevenSession({
  userId,
  jti,
  agentId,
  mode,
  issuedAtSec,
  expiresAtSec,
  activeWindowEndsAtSec
}, options = {}) {
  const key = sanitizeUuid(userId);
  if (!key) {
    return null;
  }
  const lockUntilSec = Math.max(
    Number(activeWindowEndsAtSec || 0),
    0
  ) || Number(expiresAtSec || 0);
  const lockUntilMs = lockUntilSec > 0 ? lockUntilSec * 1000 : Date.now() + 10 * 60_000;
  const entry = {
    userId: key,
    jti: String(jti || "").trim(),
    agentId: String(agentId || "").trim() || null,
    mode: mode === "text" ? "text" : "voice",
    issuedAtSec: Number(issuedAtSec || 0),
    expiresAtSec: Number(expiresAtSec || 0),
    activeWindowEndsAtSec: Number(activeWindowEndsAtSec || 0),
    lockUntilMs,
    updatedAtMs: Date.now()
  };

  if (isUpstashEnabled()) {
    try {
      const redisKey = buildRedisKey(`active-session:${key}`);
      const ttlMs = Math.max(1000, lockUntilMs - Date.now());
      const result = await redisSetJsonPx(redisKey, entry, ttlMs, {
        nx: Boolean(options?.ifNotExists)
      });
      if (options?.ifNotExists && result !== "OK") {
        return null;
      }
      await addActiveSessionIndexes(key, entry.mode);
      return entry;
    } catch (error) {
      // eslint-disable-next-line no-console
      console.warn(`[active-session] upstash fallback -> memory: ${error?.message || "unknown"}`);
    }
  }

  if (options?.ifNotExists) {
    const existing = activeElevenSessionStore.get(key);
    if (existing && Number(existing.lockUntilMs || 0) > Date.now()) {
      return null;
    }
  }
  activeElevenSessionStore.set(key, entry);
  cleanupActiveElevenSessionStore(Date.now());
  return entry;
}

async function clearActiveElevenSession({ userId, expectedJti } = {}) {
  const key = sanitizeUuid(userId);
  if (!key) {
    return false;
  }
  if (isUpstashEnabled()) {
    try {
      const redisKey = buildRedisKey(`active-session:${key}`);
      const current = await redisGetJson(redisKey);
      if (!current) {
        await removeActiveSessionIndexes(key);
        return false;
      }
      if (expectedJti && String(current.jti || "") !== String(expectedJti || "")) {
        return false;
      }
      await runRedisCommand(["DEL", redisKey]);
      await removeActiveSessionIndexes(key);
      return true;
    } catch (error) {
      // eslint-disable-next-line no-console
      console.warn(`[active-session] clear upstash fallback -> memory: ${error?.message || "unknown"}`);
    }
  }
  const current = activeElevenSessionStore.get(key);
  if (!current) {
    return false;
  }
  if (expectedJti && String(current.jti || "") !== String(expectedJti || "")) {
    return false;
  }
  activeElevenSessionStore.delete(key);
  return true;
}

async function touchActiveElevenSession({
  userId,
  expectedJti,
  expectedAgentId,
  mode,
  lockUntilMs
} = {}) {
  const key = sanitizeUuid(userId);
  if (!key) {
    return null;
  }
  const nextLockUntilMs = Math.max(Date.now() + 1000, Number(lockUntilMs || 0));
  const safeMode = String(mode || "voice") === "text" ? "text" : "voice";

  if (isUpstashEnabled()) {
    try {
      const redisKey = buildRedisKey(`active-session:${key}`);
      const current = await redisGetJson(redisKey);
      if (!current || typeof current !== "object") {
        await removeActiveSessionIndexes(key);
        return null;
      }
      if (expectedJti && String(current.jti || "") !== String(expectedJti || "")) {
        return null;
      }
      if (expectedAgentId && String(current.agentId || "") !== String(expectedAgentId || "")) {
        return null;
      }

      const updated = {
        ...current,
        mode: safeMode,
        lockUntilMs: nextLockUntilMs,
        updatedAtMs: Date.now()
      };
      const ttlMs = Math.max(1000, nextLockUntilMs - Date.now());
      await redisSetJsonPx(redisKey, updated, ttlMs);
      await addActiveSessionIndexes(key, safeMode);
      return updated;
    } catch (error) {
      // eslint-disable-next-line no-console
      console.warn(`[active-session] touch upstash fallback -> memory: ${error?.message || "unknown"}`);
    }
  }

  cleanupActiveElevenSessionStore(Date.now());
  const current = activeElevenSessionStore.get(key);
  if (!current) {
    return null;
  }
  if (expectedJti && String(current.jti || "") !== String(expectedJti || "")) {
    return null;
  }
  if (expectedAgentId && String(current.agentId || "") !== String(expectedAgentId || "")) {
    return null;
  }

  const updated = {
    ...current,
    mode: safeMode,
    lockUntilMs: nextLockUntilMs,
    updatedAtMs: Date.now()
  };
  activeElevenSessionStore.set(key, updated);
  cleanupActiveElevenSessionStore(Date.now());
  return updated;
}

function createSessionWindowToken({ userId, agentId, mode }) {
  const cfg = getSessionAuthTokenConfig();
  if (!cfg.secret) {
    const err = new Error("Session token secret tanımlı değil.");
    err.status = 503;
    throw err;
  }
  const nowSec = Math.floor(Date.now() / 1000);
  const payload = {
    uid: String(userId || ""),
    aid: String(agentId || ""),
    mode: mode === "text" ? "text" : "voice",
    iat: nowSec,
    exp: nowSec + cfg.ttlSec,
    win: nowSec + cfg.windowSec,
    jti: crypto.randomBytes(12).toString("hex")
  };
  const header = {
    alg: "HS256",
    typ: "JWT"
  };
  const h = toBase64Url(JSON.stringify(header));
  const p = toBase64Url(JSON.stringify(payload));
  const signedPart = `${h}.${p}`;
  const signature = crypto.createHmac("sha256", cfg.secret).update(signedPart).digest();
  return {
    token: `${signedPart}.${toBase64Url(signature)}`,
    payload
  };
}

function verifySessionWindowToken(token, { expectedUserId, expectedAgentId } = {}) {
  const cfg = getSessionAuthTokenConfig();
  if (!cfg.secret) {
    const err = new Error("Session token secret tanımlı değil.");
    err.status = 503;
    throw err;
  }
  const parts = String(token || "").split(".");
  if (parts.length !== 3) {
    const err = new Error("Geçersiz session window token formatı.");
    err.status = 401;
    throw err;
  }

  const [h, p, s] = parts;
  const signedPart = `${h}.${p}`;
  const expectedSig = crypto.createHmac("sha256", cfg.secret).update(signedPart).digest();
  const actualSig = fromBase64Url(s);
  if (
    expectedSig.length !== actualSig.length ||
    !crypto.timingSafeEqual(expectedSig, actualSig)
  ) {
    const err = new Error("Session window token imzası geçersiz.");
    err.status = 401;
    throw err;
  }

  let payload = null;
  try {
    payload = JSON.parse(fromBase64Url(p).toString("utf8"));
  } catch {
    const err = new Error("Session window token payload çözümlenemedi.");
    err.status = 401;
    throw err;
  }

  const nowSec = Math.floor(Date.now() / 1000);
  if (!payload || typeof payload !== "object") {
    const err = new Error("Session window token payload geçersiz.");
    err.status = 401;
    throw err;
  }
  if (!payload.uid || !payload.iat || !payload.exp || !payload.win) {
    const err = new Error("Session window token alanları eksik.");
    err.status = 401;
    throw err;
  }
  if (expectedUserId && String(payload.uid) !== String(expectedUserId)) {
    const err = new Error("Session window token kullanıcı eşleşmiyor.");
    err.status = 401;
    throw err;
  }
  if (expectedAgentId && String(payload.aid || "") !== String(expectedAgentId)) {
    const err = new Error("Session window token agent eşleşmiyor.");
    err.status = 401;
    throw err;
  }
  if (nowSec >= Number(payload.exp || 0)) {
    const err = new Error("Session window token süresi dolmuş.");
    err.status = 401;
    throw err;
  }
  if (nowSec >= Number(payload.win || 0)) {
    const err = new Error("Session oturum penceresi süresi dolmuş.");
    err.status = 401;
    throw err;
  }

  return payload;
}

async function fetchWithTimeout(url, options = {}, timeoutMs = 12000) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), Math.max(1000, Number(timeoutMs) || 12000));
  try {
    return await fetch(url, { ...options, signal: controller.signal });
  } finally {
    clearTimeout(timer);
  }
}

async function executeWithServiceFallback({
  req = null,
  res = null,
  service = "external",
  primary,
  fallback = null,
  fallbackMessage = "Fallback çalıştırıldı.",
  capturePrimaryFailure = false
} = {}) {
  if (typeof primary !== "function") {
    throw new AppError({
      message: "Primary fonksiyon eksik.",
      service,
      status: 500,
      code: ERROR_CODES.INTERNAL
    });
  }
  try {
    return await primary();
  } catch (primaryError) {
    if (typeof fallback !== "function") {
      throw primaryError;
    }
    if (capturePrimaryFailure) {
      await captureAppError({
        error: primaryError,
        req,
        res,
        fallback: {
          service,
          code: ERROR_CODES.INTERNAL,
          status: Number(primaryError?.status || 502)
        },
        metadata: {
          phase: "primary",
          fallback_used: true
        }
      });
    }
    try {
      const fallbackResult = await fallback();
      return {
        result: fallbackResult,
        usedFallback: true,
        fallbackMessage
      };
    } catch (fallbackError) {
      await captureAppError({
        error: primaryError,
        req,
        res,
        fallback: {
          service,
          code: ERROR_CODES.INTERNAL,
          status: Number(primaryError?.status || 502)
        },
        metadata: {
          phase: "primary",
          fallback_used: true,
          fallback_failed: true
        }
      });
      await captureAppError({
        error: fallbackError,
        req,
        res,
        fallback: {
          service,
          code: ERROR_CODES.INTERNAL,
          status: Number(fallbackError?.status || 502)
        },
        metadata: {
          phase: "fallback",
          fallback_used: true
        }
      });
      throw fallbackError;
    }
  }
}

async function triggerSupabaseSignupResend({
  supabaseUrl,
  supabaseAnonKey,
  supabaseServiceRoleKey,
  email,
  emailRedirectTo
}) {
  const cleanEmail = sanitizeEmail(email);
  if (!cleanEmail) {
    const err = new Error("Geçerli e-posta gerekli.");
    err.status = 400;
    throw err;
  }

  const apiKey = String(supabaseAnonKey || supabaseServiceRoleKey || "").trim();
  if (!supabaseUrl || !apiKey) {
    const err = new Error("Supabase resend çağrısı için yapılandırma eksik.");
    err.status = 503;
    throw err;
  }

  const payload = {
    type: "signup",
    email: cleanEmail,
    email_redirect_to: String(emailRedirectTo || "").trim() || undefined,
    options: {
      emailRedirectTo: String(emailRedirectTo || "").trim() || undefined,
      email_redirect_to: String(emailRedirectTo || "").trim() || undefined
    }
  };

  const resp = await fetchWithTimeout(
    `${String(supabaseUrl || "").replace(/\/+$/g, "")}/auth/v1/resend`,
    {
      method: "POST",
      headers: {
        apikey: apiKey,
        Authorization: `Bearer ${apiKey}`,
        "Content-Type": "application/json"
      },
      body: JSON.stringify(payload)
    },
    10000
  );

  if (!resp.ok) {
    const txt = await resp.text().catch(() => "");
    const err = new Error(`Supabase doğrulama e-postası tetiklenemedi: ${txt || resp.status}`);
    err.status = resp.status || 500;
    throw err;
  }

  return true;
}

async function generateSupabaseSignupActionLink({
  supabaseUrl,
  supabaseServiceRoleKey,
  email,
  redirectTo
}) {
  const cleanEmail = sanitizeEmail(email);
  if (!cleanEmail) {
    const err = new Error("Geçerli e-posta gerekli.");
    err.status = 400;
    throw err;
  }

  const serviceRoleKey = String(supabaseServiceRoleKey || "").trim();
  if (!supabaseUrl || !serviceRoleKey) {
    const err = new Error("Supabase admin generate_link için service role key eksik.");
    err.status = 503;
    throw err;
  }

  const payload = {
    type: "signup",
    email: cleanEmail,
    redirect_to: String(redirectTo || "").trim() || undefined,
    options: {
      redirectTo: String(redirectTo || "").trim() || undefined
    }
  };

  const resp = await fetchWithTimeout(
    `${String(supabaseUrl || "").replace(/\/+$/g, "")}/auth/v1/admin/generate_link`,
    {
      method: "POST",
      headers: {
        apikey: serviceRoleKey,
        Authorization: `Bearer ${serviceRoleKey}`,
        "Content-Type": "application/json"
      },
      body: JSON.stringify(payload)
    },
    10000
  );

  if (!resp.ok) {
    const txt = await resp.text().catch(() => "");
    const err = new Error(`Supabase generate_link çağrısı başarısız: ${txt || resp.status}`);
    err.status = resp.status || 500;
    throw err;
  }

  const raw = await resp.json().catch(() => ({}));
  const actionLink =
    String(
      raw?.action_link ||
        raw?.properties?.action_link ||
        raw?.data?.action_link ||
        ""
    ).trim();

  if (!actionLink) {
    const err = new Error("Supabase generate_link yanıtında action_link bulunamadı.");
    err.status = 500;
    throw err;
  }

  return actionLink;
}

async function verifySupabaseActionToken({
  supabaseUrl,
  supabaseAnonKey,
  supabaseServiceRoleKey,
  type,
  token,
  tokenHash
}) {
  const base = String(supabaseUrl || "").trim().replace(/\/+$/g, "");
  const apiKey = String(supabaseAnonKey || supabaseServiceRoleKey || "").trim();
  const actionType = String(type || "").trim().toLowerCase();
  const cleanToken = String(token || "").trim();
  const cleanTokenHash = String(tokenHash || "").trim();

  if (!base || !apiKey) {
    const err = new Error("Supabase doğrulama yapılandırması eksik.");
    err.status = 503;
    throw err;
  }
  if (!actionType || (!cleanToken && !cleanTokenHash)) {
    const err = new Error("Doğrulama için token bilgisi eksik.");
    err.status = 400;
    throw err;
  }

  const payload = {
    type: actionType
  };
  if (cleanTokenHash) {
    payload.token_hash = cleanTokenHash;
  }
  if (cleanToken) {
    payload.token = cleanToken;
  }

  const resp = await fetchWithTimeout(
    `${base}/auth/v1/verify`,
    {
      method: "POST",
      headers: {
        apikey: apiKey,
        Authorization: `Bearer ${apiKey}`,
        "Content-Type": "application/json"
      },
      body: JSON.stringify(payload)
    },
    10000
  );

  if (!resp.ok) {
    const raw = await resp.text().catch(() => "");
    const err = new Error(raw || `Supabase doğrulama başarısız (${resp.status})`);
    err.status = resp.status || 500;
    throw err;
  }

  return resp.json().catch(() => ({}));
}

function extractVerifiedAuthUser(payload) {
  if (payload && typeof payload === "object") {
    if (payload.user && typeof payload.user === "object") {
      return payload.user;
    }
    if (payload.session?.user && typeof payload.session.user === "object") {
      return payload.session.user;
    }
    if (payload.data?.user && typeof payload.data.user === "object") {
      return payload.data.user;
    }
  }
  return null;
}

function buildFullNameFromAuthUser(authUser) {
  const metadata = authUser?.user_metadata || {};
  const firstName = String(metadata?.first_name || metadata?.given_name || "").trim();
  const lastName = String(metadata?.last_name || metadata?.family_name || "").trim();
  const explicitFullName = String(metadata?.full_name || metadata?.name || "").trim();

  const merged = `${firstName} ${lastName}`.trim();
  return merged || explicitFullName || null;
}

function buildVerificationResendTemplate({ fullName, email, verificationUrl }) {
  const safeName = sanitizeReportText(fullName || "", 80) || "Merhaba";
  const safeEmail = sanitizeEmail(email) || "hesabın";
  const safeVerificationUrl = sanitizePublicHttpUrl(verificationUrl);
  const title = "Dr.Kynox doğrulama adımı";
  const verificationActionHtml = safeVerificationUrl
    ? `
      <p style="margin:16px 0 0;">
        <a href="${safeVerificationUrl}" target="_blank" rel="noopener noreferrer"
           style="display:inline-block;background:#1d6fe8;color:#ffffff;text-decoration:none;border-radius:10px;padding:12px 16px;font-weight:600;font-size:15px;">
          E-postamı doğrula
        </a>
      </p>
      <p style="margin:12px 0 0;font-size:12px;line-height:1.5;color:#64748b;word-break:break-all;">
        Buton çalışmazsa bu bağlantıyı aç: ${safeVerificationUrl}
      </p>`
    : "";
  const html = `
  <div style="font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Helvetica,Arial,sans-serif;background:#f8fafc;padding:24px;">
    <div style="max-width:560px;margin:0 auto;background:#ffffff;border:1px solid #e2e8f0;border-radius:16px;padding:24px;">
      <h1 style="margin:0 0 12px;font-size:24px;line-height:1.2;color:#0f172a;">${title}</h1>
      <p style="margin:0 0 12px;font-size:16px;line-height:1.6;color:#334155;">${safeName},</p>
      <p style="margin:0 0 12px;font-size:16px;line-height:1.6;color:#334155;">
        <strong>${safeEmail}</strong> adresin için doğrulama bağlantısı tekrar gönderildi.
      </p>
      <p style="margin:0 0 12px;font-size:15px;line-height:1.6;color:#475569;">
        Gelen kutunu ve spam klasörünü kontrol et. Doğrulama tamamlandıktan sonra uygulamada giriş yapabilirsin.
      </p>
      ${verificationActionHtml}
      <p style="margin:16px 0 0;font-size:13px;line-height:1.5;color:#64748b;">
        Eğer bu talebi sen yapmadıysan bu e-postayı görmezden gelebilirsin.
      </p>
    </div>
  </div>`;

  const text = [
    "Dr.Kynox doğrulama adımı",
    "",
    `${safeName},`,
    `${safeEmail} adresin için doğrulama bağlantısı tekrar gönderildi.`,
    safeVerificationUrl ? `Doğrulama bağlantısı: ${safeVerificationUrl}` : "",
    "Gelen kutunu ve spam klasörünü kontrol et. Doğrulama tamamlandıktan sonra uygulamada giriş yapabilirsin.",
    "Eğer bu talebi sen yapmadıysan bu e-postayı görmezden gelebilirsin."
  ].filter(Boolean).join("\n");

  return {
    subject: "Dr.Kynox · E-posta doğrulama bağlantısı",
    html,
    text
  };
}

async function sendResendEmail({ to, subject, html, text }) {
  const resend = getResendConfig();
  const cleanTo = sanitizeEmail(to);
  if (!cleanTo || !resend.apiKey || !resend.fromEmail) {
    return { sent: false, skipped: true };
  }

  const fromHeader = resend.fromName
    ? `${resend.fromName} <${resend.fromEmail}>`
    : resend.fromEmail;

  const resp = await fetchWithTimeout(
    "https://api.resend.com/emails",
    {
      method: "POST",
      headers: {
        Authorization: `Bearer ${resend.apiKey}`,
        "Content-Type": "application/json"
      },
      body: JSON.stringify({
        from: fromHeader,
        to: [cleanTo],
        subject: String(subject || "").trim() || "Dr.Kynox bildirimi",
        html: String(html || "").trim() || undefined,
        text: String(text || "").trim() || undefined
      })
    },
    10000
  );

  if (!resp.ok) {
    const raw = await resp.text().catch(() => "");
    const err = new Error(`Resend e-posta gönderimi başarısız: ${raw || resp.status}`);
    err.status = resp.status || 500;
    throw err;
  }

  const payload = await resp.json().catch(() => null);
  return {
    sent: true,
    id: payload?.id || null
  };
}

function toNullableIso(value) {
  if (!value) {
    return null;
  }
  const dt = new Date(value);
  if (!Number.isFinite(dt.getTime())) {
    return null;
  }
  return dt.toISOString();
}

function toNullableInt(value) {
  const numeric = Number(value);
  if (!Number.isFinite(numeric)) {
    return null;
  }
  return Math.round(numeric);
}

async function fetchSupabaseUserByToken({ supabaseUrl, userApiKey, accessToken }) {
  if (isDebugFlagEnabled("DEBUG_FORCE_SUPABASE_ERROR")) {
    throw new AppError({
      message: "Supabase debug simülasyon hatası",
      code: ERROR_CODES.SUPABASE_UNAVAILABLE,
      status: 503,
      service: "supabase"
    });
  }
  const userResp = await fetchWithTimeout(`${supabaseUrl}/auth/v1/user`, {
    method: "GET",
    headers: {
      apikey: userApiKey,
      Authorization: `Bearer ${accessToken}`
    }
  }, 9000);

  if (!userResp.ok) {
    const txt = await userResp.text();
    const err = new Error(`Oturum dogrulanamadi: ${txt || userResp.status}`);
    err.status = 401;
    throw err;
  }

  return userResp.json();
}

async function fetchProfileRow({ supabaseUrl, supabaseServiceRoleKey, userId }) {
  const qs = new URLSearchParams({
    id: `eq.${userId}`,
    select: "*",
    limit: "1"
  });

  const resp = await fetch(`${supabaseUrl}/rest/v1/profiles?${qs.toString()}`, {
    method: "GET",
    headers: {
      apikey: supabaseServiceRoleKey,
      Authorization: `Bearer ${supabaseServiceRoleKey}`
    }
  });

  if (!resp.ok) {
    const txt = await resp.text();
    const err = new Error(`Profil bilgisi okunamadı: ${txt || resp.status}`);
    err.status = 500;
    throw err;
  }

  const rows = await resp.json();
  return Array.isArray(rows) ? rows[0] || null : null;
}

async function fetchProfileRowByEmail({ supabaseUrl, supabaseServiceRoleKey, email }) {
  const normalizedEmail = String(email || "").trim().toLowerCase();
  if (!normalizedEmail) {
    return null;
  }

  const qs = new URLSearchParams({
    email: `eq.${normalizedEmail}`,
    select: "*",
    limit: "1"
  });

  const resp = await fetch(`${supabaseUrl}/rest/v1/profiles?${qs.toString()}`, {
    method: "GET",
    headers: {
      apikey: supabaseServiceRoleKey,
      Authorization: `Bearer ${supabaseServiceRoleKey}`
    }
  });

  if (!resp.ok) {
    const txt = await resp.text();
    const err = new Error(`Profil email ile okunamadı: ${txt || resp.status}`);
    err.status = 500;
    throw err;
  }

  const rows = await resp.json();
  return Array.isArray(rows) ? rows[0] || null : null;
}

async function updateProfileAiSwitch({
  supabaseUrl,
  supabaseServiceRoleKey,
  userId,
  enabled,
  reason
}) {
  const cleanUserId = sanitizeUuid(userId);
  if (!cleanUserId) {
    const err = new Error("Geçerli userId gerekli.");
    err.status = 400;
    throw err;
  }

  const payload = {
    ai_enabled: Boolean(enabled),
    ai_disabled_reason: enabled ? null : sanitizeAdminReason(reason),
    ai_disabled_at: enabled ? null : new Date().toISOString(),
    updated_at: new Date().toISOString()
  };

  const qs = new URLSearchParams({
    id: `eq.${cleanUserId}`
  });
  const resp = await fetch(`${supabaseUrl}/rest/v1/profiles?${qs.toString()}`, {
    method: "PATCH",
    headers: {
      apikey: supabaseServiceRoleKey,
      Authorization: `Bearer ${supabaseServiceRoleKey}`,
      "Content-Type": "application/json",
      Prefer: "return=representation"
    },
    body: JSON.stringify(payload)
  });

  if (!resp.ok) {
    const txt = await resp.text();
    const err = new Error(`AI anahtarı güncellenemedi: ${txt || resp.status}`);
    err.status = 500;
    throw err;
  }

  const rows = await resp.json().catch(() => []);
  return Array.isArray(rows) ? rows[0] || null : null;
}

async function deleteCaseSessionsByUserId({
  supabaseUrl,
  supabaseServiceRoleKey,
  userId
}) {
  const cleanUserId = sanitizeUuid(userId);
  if (!cleanUserId) {
    const err = new Error("Geçerli kullanıcı kimliği gerekli.");
    err.status = 400;
    throw err;
  }

  const qs = new URLSearchParams({
    user_id: `eq.${cleanUserId}`,
    select: "id"
  });

  const resp = await fetch(`${supabaseUrl}/rest/v1/case_sessions?${qs.toString()}`, {
    method: "DELETE",
    headers: {
      apikey: supabaseServiceRoleKey,
      Authorization: `Bearer ${supabaseServiceRoleKey}`,
      Prefer: "return=representation"
    }
  });

  if (!resp.ok) {
    const txt = await resp.text();
    const err = new Error(`Vaka kayıtları silinemedi: ${txt || resp.status}`);
    err.status = 500;
    throw err;
  }

  const rows = await resp.json().catch(() => []);
  return Array.isArray(rows) ? rows.length : 0;
}

async function resetProfileDataByUserId({
  supabaseUrl,
  supabaseServiceRoleKey,
  userId
}) {
  const cleanUserId = sanitizeUuid(userId);
  if (!cleanUserId) {
    const err = new Error("Geçerli kullanıcı kimliği gerekli.");
    err.status = 400;
    throw err;
  }

  const payload = {
    onboarding_completed: false,
    marketing_opt_in: false,
    age_range: null,
    role: null,
    goals: [],
    interest_areas: [],
    learning_level: null,
    updated_at: new Date().toISOString()
  };

  const qs = new URLSearchParams({
    id: `eq.${cleanUserId}`
  });
  const resp = await fetch(`${supabaseUrl}/rest/v1/profiles?${qs.toString()}`, {
    method: "PATCH",
    headers: {
      apikey: supabaseServiceRoleKey,
      Authorization: `Bearer ${supabaseServiceRoleKey}`,
      "Content-Type": "application/json",
      Prefer: "return=representation"
    },
    body: JSON.stringify(payload)
  });

  if (!resp.ok) {
    const txt = await resp.text();
    const err = new Error(`Profil verileri sıfırlanamadı: ${txt || resp.status}`);
    err.status = 500;
    throw err;
  }

  const rows = await resp.json().catch(() => []);
  return Array.isArray(rows) && rows.length > 0;
}

async function deleteProfileByUserId({
  supabaseUrl,
  supabaseServiceRoleKey,
  userId
}) {
  const cleanUserId = sanitizeUuid(userId);
  if (!cleanUserId) {
    const err = new Error("Geçerli kullanıcı kimliği gerekli.");
    err.status = 400;
    throw err;
  }

  const qs = new URLSearchParams({
    id: `eq.${cleanUserId}`,
    select: "id"
  });

  const resp = await fetch(`${supabaseUrl}/rest/v1/profiles?${qs.toString()}`, {
    method: "DELETE",
    headers: {
      apikey: supabaseServiceRoleKey,
      Authorization: `Bearer ${supabaseServiceRoleKey}`,
      Prefer: "return=representation"
    }
  });

  if (!resp.ok) {
    const txt = await resp.text();
    const err = new Error(`Profil kaydı silinemedi: ${txt || resp.status}`);
    err.status = 500;
    throw err;
  }

  const rows = await resp.json().catch(() => []);
  return Array.isArray(rows) ? rows.length : 0;
}

async function deleteAuthUserById({
  supabaseUrl,
  supabaseServiceRoleKey,
  userId
}) {
  const cleanUserId = sanitizeUuid(userId);
  if (!cleanUserId) {
    const err = new Error("Geçerli kullanıcı kimliği gerekli.");
    err.status = 400;
    throw err;
  }

  const resp = await fetch(`${supabaseUrl}/auth/v1/admin/users/${cleanUserId}`, {
    method: "DELETE",
    headers: {
      apikey: supabaseServiceRoleKey,
      Authorization: `Bearer ${supabaseServiceRoleKey}`,
      "Content-Type": "application/json"
    }
  });

  if (!resp.ok) {
    const txt = await resp.text();
    const err = new Error(`Kullanıcı hesabı silinemedi: ${txt || resp.status}`);
    err.status = 500;
    throw err;
  }
}

function isSupabaseMissingRelationError(rawText) {
  const txt = String(rawText || "").toLowerCase();
  if (!txt) {
    return false;
  }
  return (
    txt.includes("relation") && txt.includes("does not exist")
  ) || txt.includes("undefined table");
}

async function deleteRowsByUserId({
  supabaseUrl,
  supabaseServiceRoleKey,
  table,
  userId,
  userColumn = "user_id"
}) {
  const cleanUserId = sanitizeUuid(userId);
  const cleanTable = String(table || "").trim();
  const cleanColumn = String(userColumn || "").trim();
  if (!cleanUserId || !cleanTable || !cleanColumn) {
    return 0;
  }

  const qs = new URLSearchParams({
    [cleanColumn]: `eq.${cleanUserId}`,
    select: "id"
  });
  const resp = await fetch(`${supabaseUrl}/rest/v1/${cleanTable}?${qs.toString()}`, {
    method: "DELETE",
    headers: {
      apikey: supabaseServiceRoleKey,
      Authorization: `Bearer ${supabaseServiceRoleKey}`,
      Prefer: "return=representation"
    }
  });

  if (!resp.ok) {
    const txt = await resp.text();
    if (isSupabaseMissingRelationError(txt)) {
      return 0;
    }
    const err = new Error(`${cleanTable} temizlenemedi: ${txt || resp.status}`);
    err.status = 500;
    throw err;
  }

  const rows = await resp.json().catch(() => []);
  return Array.isArray(rows) ? rows.length : 0;
}

async function createAuthUserByAdmin({
  supabaseUrl,
  supabaseServiceRoleKey,
  email,
  password,
  emailConfirmed = false,
  firstName = "",
  lastName = "",
  fullName = "",
  phoneNumber = ""
}) {
  const cleanEmail = sanitizeEmail(email);
  const cleanPassword = String(password || "").trim();
  if (!cleanEmail) {
    const err = new Error("Geçerli e-posta gerekli.");
    err.status = 400;
    throw err;
  }
  if (cleanPassword.length < 8) {
    const err = new Error("Şifre en az 8 karakter olmalı.");
    err.status = 400;
    throw err;
  }

  const payload = {
    email: cleanEmail,
    password: cleanPassword,
    email_confirm: Boolean(emailConfirmed),
    user_metadata: {
      first_name: String(firstName || "").trim() || null,
      last_name: String(lastName || "").trim() || null,
      full_name: String(fullName || "").trim() || null,
      phone_number: String(phoneNumber || "").trim() || null
    }
  };

  const resp = await fetch(`${supabaseUrl}/auth/v1/admin/users`, {
    method: "POST",
    headers: {
      apikey: supabaseServiceRoleKey,
      Authorization: `Bearer ${supabaseServiceRoleKey}`,
      "Content-Type": "application/json"
    },
    body: JSON.stringify(payload)
  });

  if (!resp.ok) {
    const txt = await resp.text();
    const err = new Error(`Auth kullanıcı oluşturulamadı: ${txt || resp.status}`);
    err.status = 500;
    throw err;
  }
  const body = await resp.json().catch(() => ({}));
  const user = body?.user && typeof body.user === "object" ? body.user : body;
  const createdUserId = sanitizeUuid(user?.id);
  if (!createdUserId) {
    const err = new Error("Auth kullanıcı oluşturuldu ancak kullanıcı kimliği alınamadı.");
    err.status = 500;
    throw err;
  }
  return user;
}

async function fetchAuthUsersByIds({
  supabaseUrl,
  supabaseServiceRoleKey,
  userIds = []
}) {
  const cleanIds = Array.from(
    new Set(
      (Array.isArray(userIds) ? userIds : [])
        .map((item) => sanitizeUuid(item))
        .filter(Boolean)
    )
  );
  if (!cleanIds.length) {
    return {};
  }
  const pairs = await Promise.all(
    cleanIds.map(async (userId) => {
      try {
        const user = await fetchAuthUserById({ supabaseUrl, supabaseServiceRoleKey, userId });
        return [userId, user && typeof user === "object" ? user : null];
      } catch {
        return [userId, null];
      }
    })
  );
  return Object.fromEntries(pairs);
}

async function fetchAuthUserById({
  supabaseUrl,
  supabaseServiceRoleKey,
  userId
}) {
  const cleanUserId = sanitizeUuid(userId);
  if (!cleanUserId) {
    const err = new Error("Geçerli kullanıcı kimliği gerekli.");
    err.status = 400;
    throw err;
  }

  const resp = await fetch(`${supabaseUrl}/auth/v1/admin/users/${cleanUserId}`, {
    method: "GET",
    headers: {
      apikey: supabaseServiceRoleKey,
      Authorization: `Bearer ${supabaseServiceRoleKey}`
    }
  });
  if (!resp.ok) {
    const txt = await resp.text();
    const err = new Error(`Auth kullanıcı detayı okunamadı: ${txt || resp.status}`);
    err.status = 500;
    throw err;
  }
  const payload = await resp.json().catch(() => ({}));
  const user = payload?.user && typeof payload.user === "object" ? payload.user : payload;
  return user && typeof user === "object" ? user : null;
}

async function updateAuthUserBanStatus({
  supabaseUrl,
  supabaseServiceRoleKey,
  userId,
  suspended,
  hours = 24
}) {
  const cleanUserId = sanitizeUuid(userId);
  if (!cleanUserId) {
    const err = new Error("Geçerli kullanıcı kimliği gerekli.");
    err.status = 400;
    throw err;
  }
  const safeHours = clampRateLimitValue(hours, 24, 1, 24 * 365);
  const payload = {
    ban_duration: suspended ? `${safeHours}h` : "none"
  };

  const resp = await fetch(`${supabaseUrl}/auth/v1/admin/users/${cleanUserId}`, {
    method: "PUT",
    headers: {
      apikey: supabaseServiceRoleKey,
      Authorization: `Bearer ${supabaseServiceRoleKey}`,
      "Content-Type": "application/json"
    },
    body: JSON.stringify(payload)
  });
  if (!resp.ok) {
    const txt = await resp.text();
    const err = new Error(`Kullanıcı askı durumu güncellenemedi: ${txt || resp.status}`);
    err.status = 500;
    throw err;
  }

  return fetchAuthUserById({
    supabaseUrl,
    supabaseServiceRoleKey,
    userId: cleanUserId
  });
}

async function fetchRecentCaseSessionsForUser({
  supabaseUrl,
  supabaseServiceRoleKey,
  userId,
  limit = 10
}) {
  const cleanUserId = sanitizeUuid(userId);
  if (!cleanUserId) {
    return [];
  }
  const safeLimit = clampRateLimitValue(limit, 10, 1, 50);
  const qs = new URLSearchParams({
    user_id: `eq.${cleanUserId}`,
    select: "id,session_id,status,mode,difficulty,created_at,ended_at,score,case_context",
    order: "created_at.desc",
    limit: String(safeLimit)
  });
  const resp = await fetch(`${supabaseUrl}/rest/v1/case_sessions?${qs.toString()}`, {
    method: "GET",
    headers: {
      apikey: supabaseServiceRoleKey,
      Authorization: `Bearer ${supabaseServiceRoleKey}`
    }
  });
  if (!resp.ok) {
    const txt = await resp.text();
    throw new Error(txt || `Kullanıcı vaka oturumları alınamadı (${resp.status})`);
  }
  const rows = await resp.json().catch(() => []);
  return Array.isArray(rows) ? rows : [];
}

async function fetchCaseSessionForUser({
  supabaseUrl,
  supabaseServiceRoleKey,
  userId,
  caseSessionId
}) {
  const cleanUserId = sanitizeUuid(userId);
  const cleanCaseSessionId = sanitizeUuid(caseSessionId);
  if (!cleanUserId || !cleanCaseSessionId) {
    return null;
  }

  const qs = new URLSearchParams({
    id: `eq.${cleanCaseSessionId}`,
    user_id: `eq.${cleanUserId}`,
    select: "id,session_id,mode,difficulty,case_context",
    limit: "1"
  });

  const resp = await fetch(`${supabaseUrl}/rest/v1/case_sessions?${qs.toString()}`, {
    method: "GET",
    headers: {
      apikey: supabaseServiceRoleKey,
      Authorization: `Bearer ${supabaseServiceRoleKey}`
    }
  });

  if (!resp.ok) {
    const txt = await resp.text();
    const err = new Error(`Vaka kaydı doğrulanamadı: ${txt || resp.status}`);
    err.status = 500;
    throw err;
  }

  const rows = await resp.json().catch(() => []);
  return Array.isArray(rows) ? rows[0] || null : null;
}

async function insertContentReport({
  supabaseUrl,
  supabaseServiceRoleKey,
  row
}) {
  const resp = await fetch(`${supabaseUrl}/rest/v1/content_reports`, {
    method: "POST",
    headers: {
      apikey: supabaseServiceRoleKey,
      Authorization: `Bearer ${supabaseServiceRoleKey}`,
      "Content-Type": "application/json",
      Prefer: "return=representation"
    },
    body: JSON.stringify([row])
  });

  if (!resp.ok) {
    const txt = await resp.text();
    const err = new Error(`Rapor kaydedilemedi: ${txt || resp.status}`);
    err.status = 500;
    throw err;
  }

  const rows = await resp.json().catch(() => []);
  return Array.isArray(rows) ? rows[0] || null : null;
}

async function insertUserFeedback({
  supabaseUrl,
  supabaseServiceRoleKey,
  row
}) {
  const resp = await fetch(`${supabaseUrl}/rest/v1/user_feedback`, {
    method: "POST",
    headers: {
      apikey: supabaseServiceRoleKey,
      Authorization: `Bearer ${supabaseServiceRoleKey}`,
      "Content-Type": "application/json",
      Prefer: "return=representation"
    },
    body: JSON.stringify([row])
  });

  if (!resp.ok) {
    const txt = await resp.text();
    const err = new Error(`Feedback kaydedilemedi: ${txt || resp.status}`);
    err.status = 500;
    throw err;
  }

  const rows = await resp.json().catch(() => []);
  return Array.isArray(rows) ? rows[0] || null : null;
}

function chunkItems(items, size = 500) {
  const safe = Array.isArray(items) ? items : [];
  const chunkSize = Math.max(1, Math.min(1000, Number(size) || 500));
  const out = [];
  for (let idx = 0; idx < safe.length; idx += chunkSize) {
    out.push(safe.slice(idx, idx + chunkSize));
  }
  return out;
}

async function upsertUserPushDevice({
  supabaseUrl,
  supabaseServiceRoleKey,
  row
}) {
  const payload = row && typeof row === "object" ? row : null;
  if (!payload) {
    throw new Error("Push cihaz kaydı boş olamaz.");
  }

  const qs = new URLSearchParams({
    on_conflict: "user_id,device_token",
    select: "id,user_id,device_token,notifications_enabled,is_active,last_seen_at,updated_at"
  });

  const resp = await fetch(`${supabaseUrl}/rest/v1/user_push_devices?${qs.toString()}`, {
    method: "POST",
    headers: {
      apikey: supabaseServiceRoleKey,
      Authorization: `Bearer ${supabaseServiceRoleKey}`,
      "Content-Type": "application/json",
      Prefer: "resolution=merge-duplicates,return=representation"
    },
    body: JSON.stringify([payload])
  });

  if (!resp.ok) {
    const txt = await resp.text().catch(() => "");
    const err = new Error(`Push cihaz kaydı yazılamadı: ${txt || resp.status}`);
    err.status = 500;
    throw err;
  }
  const rows = await resp.json().catch(() => []);
  return Array.isArray(rows) ? rows[0] || null : null;
}

async function fetchPushEligibleDevices({
  supabaseUrl,
  supabaseServiceRoleKey,
  limit = 12000
}) {
  const safeLimit = clampRateLimitValue(limit, 5000, 100, 20000);
  const qs = new URLSearchParams({
    select: "user_id,device_token,apns_environment,last_seen_at,updated_at",
    platform: "eq.ios",
    notifications_enabled: "eq.true",
    is_active: "eq.true",
    order: "last_seen_at.desc",
    limit: String(safeLimit)
  });
  const resp = await fetch(`${supabaseUrl}/rest/v1/user_push_devices?${qs.toString()}`, {
    method: "GET",
    headers: {
      apikey: supabaseServiceRoleKey,
      Authorization: `Bearer ${supabaseServiceRoleKey}`
    }
  });
  if (!resp.ok) {
    const txt = await resp.text().catch(() => "");
    const err = new Error(`Push cihazları okunamadı: ${txt || resp.status}`);
    err.status = 500;
    throw err;
  }
  const rows = await resp.json().catch(() => []);
  const list = Array.isArray(rows) ? rows : [];
  const dedupe = new Set();
  const out = [];
  for (const item of list) {
    const userId = sanitizeUuid(item?.user_id);
    const token = sanitizeDeviceToken(item?.device_token);
    if (!userId || !token) {
      continue;
    }
    const key = `${userId}:${token}`;
    if (dedupe.has(key)) {
      continue;
    }
    dedupe.add(key);
    out.push({
      userId,
      deviceToken: token,
      apnsEnvironment: sanitizeApnsEnvironment(item?.apns_environment),
      lastSeenAt: toIsoString(item?.last_seen_at),
      updatedAt: toIsoString(item?.updated_at)
    });
  }
  return out;
}

async function fetchInAppEligibleUserIds({
  supabaseUrl,
  supabaseServiceRoleKey,
  limit = 50000
}) {
  const safeLimit = clampRateLimitValue(limit, 20000, 100, 100000);
  const pageSize = 1000;
  const ids = [];
  const dedupe = new Set();
  let offset = 0;

  while (ids.length < safeLimit) {
    const remaining = safeLimit - ids.length;
    const take = Math.min(pageSize, remaining);
    const qs = new URLSearchParams({
      select: "id",
      onboarding_completed: "eq.true",
      order: "updated_at.desc",
      limit: String(take),
      offset: String(offset)
    });
    const resp = await fetch(`${supabaseUrl}/rest/v1/profiles?${qs.toString()}`, {
      method: "GET",
      headers: {
        apikey: supabaseServiceRoleKey,
        Authorization: `Bearer ${supabaseServiceRoleKey}`
      }
    });
    if (!resp.ok) {
      const txt = await resp.text().catch(() => "");
      const err = new Error(`In-app hedef kullanıcıları okunamadı: ${txt || resp.status}`);
      err.status = 500;
      throw err;
    }
    const rows = await resp.json().catch(() => []);
    const list = Array.isArray(rows) ? rows : [];
    if (!list.length) {
      break;
    }
    for (const row of list) {
      const userId = sanitizeUuid(row?.id);
      if (!userId || dedupe.has(userId)) {
        continue;
      }
      dedupe.add(userId);
      ids.push(userId);
      if (ids.length >= safeLimit) {
        break;
      }
    }
    if (list.length < take) {
      break;
    }
    offset += list.length;
  }

  return ids;
}

async function insertBroadcast({
  supabaseUrl,
  supabaseServiceRoleKey,
  row
}) {
  const resp = await fetch(`${supabaseUrl}/rest/v1/app_broadcasts`, {
    method: "POST",
    headers: {
      apikey: supabaseServiceRoleKey,
      Authorization: `Bearer ${supabaseServiceRoleKey}`,
      "Content-Type": "application/json",
      Prefer: "return=representation"
    },
    body: JSON.stringify([row])
  });
  if (!resp.ok) {
    const txt = await resp.text().catch(() => "");
    const err = new Error(`Broadcast kaydı yazılamadı: ${txt || resp.status}`);
    err.status = 500;
    throw err;
  }
  const rows = await resp.json().catch(() => []);
  return Array.isArray(rows) ? rows[0] || null : null;
}

async function upsertBroadcastTargets({
  supabaseUrl,
  supabaseServiceRoleKey,
  rows
}) {
  const safeRows = Array.isArray(rows) ? rows : [];
  if (!safeRows.length) {
    return 0;
  }
  let written = 0;
  const chunks = chunkItems(safeRows, 500);
  for (const chunk of chunks) {
    const resp = await fetch(
      `${supabaseUrl}/rest/v1/app_broadcast_targets?on_conflict=broadcast_id,user_id`,
      {
        method: "POST",
        headers: {
          apikey: supabaseServiceRoleKey,
          Authorization: `Bearer ${supabaseServiceRoleKey}`,
          "Content-Type": "application/json",
          Prefer: "resolution=merge-duplicates,return=minimal"
        },
        body: JSON.stringify(chunk)
      }
    );
    if (!resp.ok) {
      const txt = await resp.text().catch(() => "");
      const err = new Error(`Broadcast hedefleri yazılamadı: ${txt || resp.status}`);
      err.status = 500;
      throw err;
    }
    written += chunk.length;
  }
  return written;
}

async function fetchRecentBroadcasts({
  supabaseUrl,
  supabaseServiceRoleKey,
  limit = 12
}) {
  const safeLimit = clampRateLimitValue(limit, 8, 1, 30);
  const qs = new URLSearchParams({
    select: "id,title,body,deep_link,push_enabled,in_app_enabled,expires_at,created_by,created_at",
    order: "created_at.desc",
    limit: String(safeLimit)
  });
  const resp = await fetch(`${supabaseUrl}/rest/v1/app_broadcasts?${qs.toString()}`, {
    method: "GET",
    headers: {
      apikey: supabaseServiceRoleKey,
      Authorization: `Bearer ${supabaseServiceRoleKey}`
    }
  });
  if (!resp.ok) {
    const txt = await resp.text().catch(() => "");
    const err = new Error(`Broadcast listesi okunamadı: ${txt || resp.status}`);
    err.status = 500;
    throw err;
  }
  const rows = await resp.json().catch(() => []);
  const broadcasts = Array.isArray(rows) ? rows : [];
  const out = [];
  for (const item of broadcasts) {
    const broadcastId = sanitizeUuid(item?.id);
    if (!broadcastId) {
      continue;
    }
    const countQs = new URLSearchParams({
      broadcast_id: `eq.${broadcastId}`,
      select: "user_id"
    });
    const countResp = await fetch(`${supabaseUrl}/rest/v1/app_broadcast_targets?${countQs.toString()}`, {
      method: "GET",
      headers: {
        apikey: supabaseServiceRoleKey,
        Authorization: `Bearer ${supabaseServiceRoleKey}`,
        Prefer: "count=exact,head=true",
        Range: "0-0"
      }
    });
    const targetsCount = countResp.ok
      ? parseSupabaseCountFromContentRange(countResp.headers.get("content-range"))
      : 0;
    out.push({
      id: broadcastId,
      title: sanitizeReportText(item?.title || "", 120),
      body: sanitizeReportText(item?.body || "", 420),
      deep_link: sanitizeReportText(item?.deep_link || "", 280),
      push_enabled: Boolean(item?.push_enabled),
      in_app_enabled: Boolean(item?.in_app_enabled),
      expires_at: toIsoString(item?.expires_at),
      created_by: sanitizeReportText(item?.created_by || "", 120),
      created_at: toIsoString(item?.created_at),
      targets_count: targetsCount
    });
  }
  return out;
}

function buildApnsProviderJwt({ keyId, teamId, privateKey }) {
  const nowSec = Math.floor(Date.now() / 1000);
  const header = toBase64Url(JSON.stringify({ alg: "ES256", kid: keyId }));
  const payload = toBase64Url(JSON.stringify({ iss: teamId, iat: nowSec }));
  const signInput = `${header}.${payload}`;
  const sign = crypto.createSign("SHA256");
  sign.update(signInput);
  sign.end();
  const signature = sign.sign(privateKey);
  return `${signInput}.${toBase64Url(signature)}`;
}

async function sendApnsNotification({
  config,
  deviceToken,
  title,
  body,
  deepLink
}) {
  const authority =
    config.environment === "sandbox"
      ? "https://api.sandbox.push.apple.com"
      : "https://api.push.apple.com";
  const jwt = buildApnsProviderJwt(config);
  const payload = {
    aps: {
      alert: {
        title,
        body
      },
      sound: "default"
    },
    deep_link: deepLink || null
  };

  return await new Promise((resolve, reject) => {
    let closed = false;
    const client = http2.connect(authority);
    const timer = setTimeout(() => {
      if (closed) {
        return;
      }
      closed = true;
      try {
        client.close();
      } catch {}
      const err = new Error("APNs timeout");
      err.status = 504;
      reject(err);
    }, 12000);

    const finalize = (result, error = null) => {
      if (closed) {
        return;
      }
      closed = true;
      clearTimeout(timer);
      try {
        client.close();
      } catch {}
      if (error) {
        reject(error);
      } else {
        resolve(result);
      }
    };

    client.on("error", (error) => {
      finalize(null, error);
    });

    const req = client.request({
      ":method": "POST",
      ":path": `/3/device/${deviceToken}`,
      authorization: `bearer ${jwt}`,
      "apns-topic": config.bundleId,
      "apns-push-type": "alert",
      "apns-priority": "10",
      "content-type": "application/json"
    });

    let responseStatus = 0;
    let responseBody = "";

    req.setEncoding("utf8");
    req.on("response", (headers) => {
      responseStatus = Number(headers?.[":status"] || 0);
    });
    req.on("data", (chunk) => {
      responseBody += String(chunk || "");
    });
    req.on("error", (error) => {
      finalize(null, error);
    });
    req.on("end", () => {
      let reason = "";
      if (responseBody) {
        try {
          const parsed = JSON.parse(responseBody);
          reason = String(parsed?.reason || parsed?.error || "").trim();
        } catch {}
      }
      if (responseStatus >= 200 && responseStatus < 300) {
        finalize({
          ok: true,
          status: responseStatus,
          reason: ""
        });
        return;
      }
      finalize({
        ok: false,
        status: responseStatus || 500,
        reason: reason || "APNS_SEND_FAILED"
      });
    });

    req.end(JSON.stringify(payload));
  });
}

async function sendApnsBatch({
  devices,
  title,
  body,
  deepLink
}) {
  const cfg = getApnsConfig();
  if (!cfg.keyId || !cfg.teamId || !cfg.bundleId || !cfg.privateKey) {
    const missing = [];
    if (!cfg.keyId) missing.push("APNS_KEY_ID");
    if (!cfg.teamId) missing.push("APNS_TEAM_ID");
    if (!cfg.bundleId) missing.push("APNS_BUNDLE_ID");
    if (!cfg.privateKey) missing.push("APNS_PRIVATE_KEY");
    const err = new Error(`APNs ayarları eksik: ${missing.join(", ")}`);
    err.status = 503;
    throw err;
  }

  const safeDevices = Array.isArray(devices) ? devices : [];
  const statuses = [];
  let sentCount = 0;
  let failedCount = 0;

  for (const device of safeDevices) {
    const token = sanitizeDeviceToken(device?.deviceToken);
    const userId = sanitizeUuid(device?.userId);
    if (!token || !userId) {
      continue;
    }
    try {
      const result = await sendApnsNotification({
        config: {
          keyId: cfg.keyId,
          teamId: cfg.teamId,
          bundleId: cfg.bundleId,
          privateKey: cfg.privateKey,
          environment: sanitizeApnsEnvironment(device?.apnsEnvironment || cfg.environment)
        },
        deviceToken: token,
        title,
        body,
        deepLink
      });
      if (result?.ok) {
        sentCount += 1;
      } else {
        failedCount += 1;
      }
      statuses.push({
        userId,
        ok: Boolean(result?.ok),
        status: Number(result?.status || 0),
        reason: String(result?.reason || "").trim() || null
      });
    } catch (error) {
      failedCount += 1;
      statuses.push({
        userId,
        ok: false,
        status: Number(error?.status || 500),
        reason: sanitizeReportText(error?.message || "APNS_SEND_FAILED", 160)
      });
    }
  }

  return {
    sentCount,
    failedCount,
    statuses
  };
}

async function fetchUserLatestInAppBanner({
  supabaseUrl,
  supabaseServiceRoleKey,
  userId
}) {
  const cleanUserId = sanitizeUuid(userId);
  if (!cleanUserId) {
    return null;
  }

  const qs = new URLSearchParams({
    select: "broadcast_id,seen_at,dismissed_at,created_at,broadcast:app_broadcasts!inner(id,title,body,deep_link,push_enabled,in_app_enabled,expires_at,created_at)",
    user_id: `eq.${cleanUserId}`,
    order: "created_at.desc",
    limit: "12"
  });

  const resp = await fetch(`${supabaseUrl}/rest/v1/app_broadcast_targets?${qs.toString()}`, {
    method: "GET",
    headers: {
      apikey: supabaseServiceRoleKey,
      Authorization: `Bearer ${supabaseServiceRoleKey}`
    }
  });
  if (!resp.ok) {
    const txt = await resp.text().catch(() => "");
    const err = new Error(`In-app duyurular okunamadı: ${txt || resp.status}`);
    err.status = 500;
    throw err;
  }

  const rows = await resp.json().catch(() => []);
  const items = Array.isArray(rows) ? rows : [];
  const nowMs = Date.now();

  for (const item of items) {
    if (item?.dismissed_at) {
      continue;
    }
    const broadcast = item?.broadcast && typeof item.broadcast === "object" ? item.broadcast : null;
    const broadcastId = sanitizeUuid(item?.broadcast_id || broadcast?.id);
    if (!broadcast || !broadcastId) {
      continue;
    }
    if (!Boolean(broadcast?.in_app_enabled)) {
      continue;
    }
    const expiresAt = toIsoString(broadcast?.expires_at);
    if (expiresAt) {
      const expiresMs = Date.parse(expiresAt);
      if (Number.isFinite(expiresMs) && expiresMs <= nowMs) {
        continue;
      }
    }
    return {
      id: broadcastId,
      title: sanitizeReportText(broadcast?.title || "", 120),
      body: sanitizeReportText(broadcast?.body || "", 420),
      deepLink: sanitizeReportText(broadcast?.deep_link || "", 280),
      createdAt: toIsoString(broadcast?.created_at || item?.created_at),
      expiresAt,
      seenAt: toIsoString(item?.seen_at),
      dismissedAt: toIsoString(item?.dismissed_at)
    };
  }
  return null;
}

async function patchInAppBannerTarget({
  supabaseUrl,
  supabaseServiceRoleKey,
  userId,
  broadcastId,
  action
}) {
  const cleanUserId = sanitizeUuid(userId);
  const cleanBroadcastId = sanitizeUuid(broadcastId);
  const safeAction = String(action || "").trim().toLowerCase();
  if (!cleanUserId || !cleanBroadcastId || !["seen", "dismiss"].includes(safeAction)) {
    return null;
  }

  const nowIso = new Date().toISOString();
  const patch = safeAction === "dismiss"
    ? { dismissed_at: nowIso, seen_at: nowIso }
    : { seen_at: nowIso };
  const qs = new URLSearchParams({
    user_id: `eq.${cleanUserId}`,
    broadcast_id: `eq.${cleanBroadcastId}`,
    select: "broadcast_id,user_id,seen_at,dismissed_at",
    limit: "1"
  });

  const resp = await fetch(`${supabaseUrl}/rest/v1/app_broadcast_targets?${qs.toString()}`, {
    method: "PATCH",
    headers: {
      apikey: supabaseServiceRoleKey,
      Authorization: `Bearer ${supabaseServiceRoleKey}`,
      "Content-Type": "application/json",
      Prefer: "return=representation"
    },
    body: JSON.stringify(patch)
  });
  if (!resp.ok) {
    const txt = await resp.text().catch(() => "");
    const err = new Error(`In-app duyuru güncellenemedi: ${txt || resp.status}`);
    err.status = 500;
    throw err;
  }
  const rows = await resp.json().catch(() => []);
  return Array.isArray(rows) ? rows[0] || null : null;
}

async function upsertFlashcards({
  supabaseUrl,
  supabaseServiceRoleKey,
  rows
}) {
  const safeRows = Array.isArray(rows) ? rows : [];
  if (!safeRows.length) {
    return [];
  }

  const resp = await fetch(`${supabaseUrl}/rest/v1/flashcards?on_conflict=user_id,source_id`, {
    method: "POST",
    headers: {
      apikey: supabaseServiceRoleKey,
      Authorization: `Bearer ${supabaseServiceRoleKey}`,
      "Content-Type": "application/json",
      Prefer: "resolution=merge-duplicates,return=representation"
    },
    body: JSON.stringify(safeRows)
  });

  if (!resp.ok) {
    const txt = await resp.text();
    const err = new Error(`Flashcard kaydı yazılamadı: ${txt || resp.status}`);
    err.status = 500;
    throw err;
  }

  const saved = await resp.json().catch(() => []);
  return Array.isArray(saved) ? saved : [];
}

async function fetchFlashcardsForUser({
  supabaseUrl,
  supabaseServiceRoleKey,
  userId,
  sessionId,
  onlyDue = false,
  specialty,
  cardType,
  limit = 200
}) {
  const cleanUserId = sanitizeUuid(userId);
  if (!cleanUserId) {
    return [];
  }

  const safeLimit = clampRateLimitValue(limit, 120, 1, 500);
  const qs = new URLSearchParams({
    user_id: `eq.${cleanUserId}`,
    select:
      "id,session_id,source_id,card_type,specialty,difficulty,title,front,back,tags,interval_days,repetition_count,ease_factor,due_at,last_reviewed_at,created_at,updated_at",
    order: "due_at.asc",
    limit: String(safeLimit)
  });

  const safeSpecialty = sanitizeFlashcardText(specialty, 80, false);
  if (safeSpecialty) {
    qs.append("specialty", `eq.${safeSpecialty}`);
  }
  const safeSessionId = sanitizeFlashcardText(sessionId, 120, false);
  if (safeSessionId) {
    qs.append("session_id", `eq.${safeSessionId}`);
  }
  const safeType = normalizeFlashcardType(cardType);
  if (cardType && safeType) {
    qs.append("card_type", `eq.${safeType}`);
  }
  if (onlyDue) {
    qs.append("or", `(due_at.is.null,due_at.lte.${new Date().toISOString()})`);
  }

  const resp = await fetch(`${supabaseUrl}/rest/v1/flashcards?${qs.toString()}`, {
    method: "GET",
    headers: {
      apikey: supabaseServiceRoleKey,
      Authorization: `Bearer ${supabaseServiceRoleKey}`
    }
  });

  if (!resp.ok) {
    const txt = await resp.text();
    const err = new Error(`Flashcard verisi okunamadı: ${txt || resp.status}`);
    err.status = 500;
    throw err;
  }

  const rows = await resp.json().catch(() => []);
  return Array.isArray(rows) ? rows : [];
}

async function fetchFlashcardByIdForUser({
  supabaseUrl,
  supabaseServiceRoleKey,
  userId,
  cardId
}) {
  const cleanUserId = sanitizeUuid(userId);
  const cleanCardId = sanitizeUuid(cardId);
  if (!cleanUserId || !cleanCardId) {
    return null;
  }

  const qs = new URLSearchParams({
    id: `eq.${cleanCardId}`,
    user_id: `eq.${cleanUserId}`,
    select:
      "id,session_id,source_id,card_type,specialty,difficulty,title,front,back,tags,interval_days,repetition_count,ease_factor,due_at,last_reviewed_at,created_at,updated_at",
    limit: "1"
  });

  const resp = await fetch(`${supabaseUrl}/rest/v1/flashcards?${qs.toString()}`, {
    method: "GET",
    headers: {
      apikey: supabaseServiceRoleKey,
      Authorization: `Bearer ${supabaseServiceRoleKey}`
    }
  });

  if (!resp.ok) {
    const txt = await resp.text();
    const err = new Error(`Flashcard doğrulanamadı: ${txt || resp.status}`);
    err.status = 500;
    throw err;
  }

  const rows = await resp.json().catch(() => []);
  return Array.isArray(rows) ? rows[0] || null : null;
}

async function updateFlashcardById({
  supabaseUrl,
  supabaseServiceRoleKey,
  cardId,
  patch
}) {
  const cleanCardId = sanitizeUuid(cardId);
  if (!cleanCardId) {
    return null;
  }

  const qs = new URLSearchParams({
    id: `eq.${cleanCardId}`,
    select:
      "id,session_id,source_id,card_type,specialty,difficulty,title,front,back,tags,interval_days,repetition_count,ease_factor,due_at,last_reviewed_at,created_at,updated_at",
    limit: "1"
  });

  const resp = await fetch(`${supabaseUrl}/rest/v1/flashcards?${qs.toString()}`, {
    method: "PATCH",
    headers: {
      apikey: supabaseServiceRoleKey,
      Authorization: `Bearer ${supabaseServiceRoleKey}`,
      "Content-Type": "application/json",
      Prefer: "return=representation"
    },
    body: JSON.stringify(patch)
  });

  if (!resp.ok) {
    const txt = await resp.text();
    const err = new Error(`Flashcard güncellenemedi: ${txt || resp.status}`);
    err.status = 500;
    throw err;
  }

  const rows = await resp.json().catch(() => []);
  return Array.isArray(rows) ? rows[0] || null : null;
}

async function assertAiAccessAllowed({
  supabaseUrl,
  supabaseServiceRoleKey,
  userId
}) {
  const aiConfig = getAiAccessConfig();
  if (!aiConfig.globalEnabled) {
    const err = new Error("AI özellikleri şu anda geçici olarak kapalı.");
    err.status = 503;
    throw err;
  }

  const profile = await fetchProfileRow({
    supabaseUrl,
    supabaseServiceRoleKey,
    userId
  });

  const aiEnabled = profile?.ai_enabled == null ? true : Boolean(profile.ai_enabled);
  if (aiEnabled) {
    return {
      allowed: true,
      profile
    };
  }

  const reason = sanitizeAdminReason(profile?.ai_disabled_reason);
  const err = new Error(
    reason
      ? `AI özellikleri hesabın için devre dışı: ${reason}`
      : "AI özellikleri hesabın için devre dışı bırakıldı."
  );
  err.status = 403;
  throw err;
}

function parseJsonMaybe(raw) {
  if (!raw) {
    return null;
  }
  try {
    return JSON.parse(raw);
  } catch {
    return null;
  }
}

function extractMissingProfilesColumn(errorLike) {
  const message =
    typeof errorLike === "string"
      ? errorLike
      : typeof errorLike?.message === "string"
        ? errorLike.message
        : "";
  if (!message) {
    return "";
  }

  const match = message.match(/'([^']+)'\s+column of 'profiles'/i);
  return match?.[1] ? String(match[1]).trim() : "";
}

function utcDateKey(dateLike = new Date()) {
  const dt = new Date(dateLike);
  if (!Number.isFinite(dt.getTime())) {
    return new Date().toISOString().slice(0, 10);
  }
  return dt.toISOString().slice(0, 10);
}

function buildManualChallengeDateKey(dateLike = new Date()) {
  const dt = new Date(dateLike);
  const fallback = `manual-${Date.now()}`;
  if (!Number.isFinite(dt.getTime())) {
    return fallback;
  }
  const stamp = dt.toISOString().replace(/[-:TZ.]/g, "").slice(0, 17);
  return `manual-${stamp || Date.now()}`;
}

function toIsoString(value) {
  const dt = new Date(value);
  if (!Number.isFinite(dt.getTime())) {
    return null;
  }
  return dt.toISOString();
}

function addHoursIso(value, hours) {
  const dt = new Date(value);
  if (!Number.isFinite(dt.getTime())) {
    return null;
  }
  dt.setTime(dt.getTime() + Math.max(1, Number(hours) || 24) * 60 * 60 * 1000);
  return dt.toISOString();
}

function isFutureIso(value, nowLike = Date.now()) {
  const ts = new Date(value).getTime();
  const nowTs = new Date(nowLike).getTime();
  if (!Number.isFinite(ts) || !Number.isFinite(nowTs)) {
    return false;
  }
  return ts > nowTs;
}

function computeChallengeTimeLeft(challenge, nowLike = Date.now()) {
  const expiresAt =
    toIsoString(challenge?.expiresAt || challenge?.expires_at || null) ||
    toIsoString(addHoursIso(nowLike, 24));
  const expiresTs = new Date(expiresAt || 0).getTime();
  const nowTs = new Date(nowLike).getTime();
  if (!Number.isFinite(expiresTs) || !Number.isFinite(nowTs)) {
    return {
      expires_at: expiresAt || null,
      minutes_left: null,
      hours_left: null
    };
  }
  const diffMs = Math.max(0, expiresTs - nowTs);
  const minutesLeft = Math.ceil(diffMs / (60 * 1000));
  const hoursLeft = Number((diffMs / (60 * 60 * 1000)).toFixed(2));
  return {
    expires_at: new Date(expiresTs).toISOString(),
    minutes_left: minutesLeft,
    hours_left: hoursLeft
  };
}

function resolveChallengeWindow(challengeLike, fallbackNowLike = Date.now()) {
  const source = challengeLike && typeof challengeLike === "object" ? challengeLike : {};
  const generatedAt =
    toIsoString(source.generatedAt || source.generated_at || source.created_at || fallbackNowLike) ||
    toIsoString(fallbackNowLike);
  const expiresAt =
    toIsoString(source.expiresAt || source.expires_at || addHoursIso(generatedAt, 24)) ||
    addHoursIso(generatedAt, 24);
  return {
    generatedAt,
    expiresAt
  };
}

function isChallengeActiveNow(challengeLike, nowLike = Date.now()) {
  const nowTs = new Date(nowLike).getTime();
  const window = resolveChallengeWindow(challengeLike, nowLike);
  const startTs = new Date(window.generatedAt || 0).getTime();
  const endTs = new Date(window.expiresAt || 0).getTime();
  if (!Number.isFinite(nowTs) || !Number.isFinite(startTs) || !Number.isFinite(endTs)) {
    return false;
  }
  return nowTs >= startTs && nowTs < endTs;
}

function isChallengeUpcoming(challengeLike, nowLike = Date.now()) {
  const nowTs = new Date(nowLike).getTime();
  const window = resolveChallengeWindow(challengeLike, nowLike);
  const startTs = new Date(window.generatedAt || 0).getTime();
  if (!Number.isFinite(nowTs) || !Number.isFinite(startTs)) {
    return false;
  }
  return startTs > nowTs;
}

function hashString(input) {
  let hash = 0;
  const text = String(input || "");
  for (let i = 0; i < text.length; i += 1) {
    hash = (hash * 31 + text.charCodeAt(i)) % 2147483647;
  }
  return hash;
}

function resolveDailyChallengeTemplate(dateKey) {
  const idx = hashString(`daily-challenge|${dateKey}`) % DAILY_CHALLENGE_TEMPLATES.length;
  return DAILY_CHALLENGE_TEMPLATES[idx];
}

function challengeBonusByDifficulty(difficulty) {
  const value = String(difficulty || "").toLocaleLowerCase("tr-TR");
  if (value.includes("zor") || value.includes("ileri")) {
    return 70;
  }
  if (value.includes("orta")) {
    return 55;
  }
  return 40;
}

function buildDailyChallengePayload(dateKey, baseTime = Date.now()) {
  const template = resolveDailyChallengeTemplate(dateKey);
  const id = `daily-${dateKey}-${template.slug}`;
  const bonus = challengeBonusByDifficulty(template.difficulty);
  const generatedAt = toIsoString(baseTime) || new Date().toISOString();
  const expiresAt = addHoursIso(generatedAt, 24) || addHoursIso(Date.now(), 24) || new Date(Date.now() + 24 * 60 * 60 * 1000).toISOString();
  const seedPrompt =
    `Bugünün vaka meydan okuması ayarları:\n` +
    `- Zorluk: ${template.difficulty}\n` +
    `- Bölüm: ${template.specialty}\n` +
    `- Vaka başlığı: ${template.title}\n` +
    `- Başvuru şikayeti: ${template.chiefComplaint}\n` +
    `- Hasta: ${template.patientGender}, ${template.patientAge} yaş\n` +
    `- Eğitsel odak: ${template.seedFocus}\n` +
    `- Hedef doğru tanı: ${template.expectedDiagnosis}\n` +
    "Bu ayarlara uygun şekilde vakayı yönet. Tanıyı başta söyleme; anamnez ve klinik akışa göre adım adım ilerle. Bu parametreler kesin, kullanıcıya bölüm/zorluk tekrar sorma.";

  return {
    dateKey,
    id,
    type: "daily",
    generatedAt,
    expiresAt,
    title: template.title,
    summary: template.summary,
    specialty: template.specialty,
    difficulty: template.difficulty,
    chiefComplaint: template.chiefComplaint,
    patientGender: template.patientGender,
    patientAge: template.patientAge,
    expectedDiagnosis: template.expectedDiagnosis,
    durationMin: 15,
    bonusPoints: bonus,
    seedFocus: template.seedFocus,
    agentSeedPrompt: seedPrompt
  };
}

function sanitizeChallengeLine(input, maxLength = 140) {
  const text = String(input || "")
    .replace(/\s+/g, " ")
    .trim();
  if (!text) {
    return "";
  }
  if (text.length <= maxLength) {
    return text;
  }
  return `${text.slice(0, Math.max(8, maxLength - 1)).trim()}…`;
}

function normalizeFlashcardType(input) {
  const normalized = String(input || "")
    .toLocaleLowerCase("tr-TR")
    .normalize("NFD")
    .replace(/[\u0300-\u036f]/g, "")
    .replace(/[^a-z0-9]+/g, "_")
    .replace(/^_+|_+$/g, "");
  if (!normalized) {
    return "concept";
  }
  const mapped = FLASHCARD_TYPE_ALIASES[normalized] || normalized;
  if (FLASHCARD_ALLOWED_TYPES.includes(mapped)) {
    return mapped;
  }
  return "concept";
}

function sanitizeFlashcardText(input, maxLength = 300, allowMultiline = false) {
  const raw = String(input || "");
  const text = allowMultiline
    ? raw
        .replace(/\r/g, "")
        .replace(/[ \t]+\n/g, "\n")
        .replace(/\n{3,}/g, "\n\n")
        .trim()
    : raw.replace(/\s+/g, " ").trim();

  if (!text) {
    return "";
  }
  if (text.length <= maxLength) {
    return text;
  }
  return `${text.slice(0, Math.max(8, maxLength - 1)).trim()}…`;
}

function sanitizeFlashcardTags(input) {
  const tags = Array.isArray(input) ? input : [];
  const cleaned = [];
  const seen = new Set();
  for (const item of tags) {
    const normalized = sanitizeFlashcardText(item, 40, false)
      .toLocaleLowerCase("tr-TR")
      .replace(/[^a-z0-9çğıöşü\-\s]/gi, "")
      .replace(/\s+/g, "-")
      .replace(/-+/g, "-")
      .replace(/^-+|-+$/g, "");
    if (!normalized || seen.has(normalized)) {
      continue;
    }
    seen.add(normalized);
    cleaned.push(normalized);
    if (cleaned.length >= 8) {
      break;
    }
  }
  return cleaned;
}

function dedupeFlashcards(cards, maxCards = 10) {
  const list = Array.isArray(cards) ? cards : [];
  const unique = [];
  const seen = new Set();

  for (const item of list) {
    if (!item || typeof item !== "object") {
      continue;
    }
    const front = sanitizeFlashcardText(item.front, 700, true);
    const back = sanitizeFlashcardText(item.back, 1400, true);
    if (!front || !back) {
      continue;
    }
    const key = `${normalizeForComparison(front)}|${normalizeForComparison(back)}`;
    if (seen.has(key)) {
      continue;
    }
    seen.add(key);
    unique.push({
      id: sanitizeFlashcardText(item.id || crypto.randomUUID(), 80, false),
      cardType: normalizeFlashcardType(item.cardType || item.card_type),
      title: sanitizeFlashcardText(item.title || "Klinik Kart", 120, false) || "Klinik Kart",
      front,
      back,
      specialty: sanitizeFlashcardText(item.specialty, 80, false) || null,
      difficulty: normalizeDifficulty(item.difficulty, "Orta"),
      tags: sanitizeFlashcardTags(item.tags)
    });
    if (unique.length >= maxCards) {
      break;
    }
  }

  return unique;
}

function buildStableFlashcardSourceId({ sessionId, card }) {
  const explicitId = sanitizeFlashcardText(card?.id, 120, false);
  if (explicitId) {
    return explicitId;
  }
  const safeSession = sanitizeFlashcardText(sessionId, 120, false) || "session";
  const safeType = normalizeFlashcardType(card?.cardType || card?.card_type);
  const safeTitle = sanitizeFlashcardText(card?.title, 120, false) || "kart";
  const safeFront = sanitizeFlashcardText(card?.front, 700, true) || "";
  const digest = crypto
    .createHash("sha1")
    .update(`${safeSession}|${safeType}|${safeTitle}|${safeFront}`)
    .digest("hex");
  return `fc_${digest.slice(0, 24)}`;
}

function mapStoredFlashcardToDraft(row) {
  const card = {
    id: sanitizeFlashcardText(row?.source_id || row?.id || crypto.randomUUID(), 120, false),
    cardType: normalizeFlashcardType(row?.card_type || row?.cardType),
    title: sanitizeFlashcardText(row?.title, 120, false) || "Klinik Kart",
    front: sanitizeFlashcardText(row?.front, 700, true),
    back: sanitizeFlashcardText(row?.back, 1400, true),
    specialty: sanitizeFlashcardText(row?.specialty, 80, false) || null,
    difficulty: normalizeDifficulty(row?.difficulty, "Orta"),
    tags: sanitizeFlashcardTags(row?.tags)
  };
  return card.front && card.back ? card : null;
}

function buildFlashcardDraftCacheKey({ userId, sessionId }) {
  const safeUserId = sanitizeUuid(userId);
  const safeSessionId = sanitizeFlashcardText(sessionId, 120, false);
  if (!safeUserId || !safeSessionId) {
    return "";
  }
  return crypto.createHash("sha1").update(`${safeUserId}|${safeSessionId}`).digest("hex");
}

async function getCachedFlashcardDrafts(cacheKey) {
  if (!cacheKey) {
    return null;
  }

  if (isUpstashEnabled()) {
    try {
      const payload = await redisGetJson(buildRedisKey(`flashcard-draft:${cacheKey}`));
      if (payload && typeof payload === "object" && Array.isArray(payload.cards)) {
        return payload;
      }
    } catch (error) {
      // eslint-disable-next-line no-console
      console.warn(`[flashcard-cache] upstash fallback -> memory: ${error?.message || "unknown"}`);
    }
  }

  const entry = flashcardDraftCache.get(cacheKey);
  if (!entry) {
    return null;
  }
  if (Date.now() - entry.savedAt > FLASHCARD_DRAFT_CACHE_TTL_MS) {
    flashcardDraftCache.delete(cacheKey);
    return null;
  }
  return entry.payload;
}

async function setCachedFlashcardDrafts(cacheKey, payload) {
  if (!cacheKey || !payload || typeof payload !== "object") {
    return;
  }

  if (isUpstashEnabled()) {
    try {
      await redisSetJsonPx(
        buildRedisKey(`flashcard-draft:${cacheKey}`),
        payload,
        FLASHCARD_DRAFT_CACHE_TTL_MS
      );
    } catch (error) {
      // eslint-disable-next-line no-console
      console.warn(`[flashcard-cache] set upstash failed, memory fallback only: ${error?.message || "unknown"}`);
    }
  }

  flashcardDraftCache.set(cacheKey, {
    savedAt: Date.now(),
    payload
  });
}

async function clearCachedFlashcardDrafts(cacheKey) {
  if (!cacheKey) {
    return;
  }

  if (isUpstashEnabled()) {
    try {
      await runRedisCommand(["DEL", buildRedisKey(`flashcard-draft:${cacheKey}`)]);
    } catch (error) {
      // eslint-disable-next-line no-console
      console.warn(`[flashcard-cache] clear upstash failed: ${error?.message || "unknown"}`);
    }
  }

  flashcardDraftCache.delete(cacheKey);
}

function buildFallbackFlashcards(payload, maxCards = 5) {
  const safeSpecialty = sanitizeFlashcardText(payload?.specialty, 80, false) || "Genel Tıp";
  const safeDifficulty = normalizeDifficulty(payload?.difficulty, "Orta");
  const caseTitle = sanitizeFlashcardText(payload?.caseTitle, 120, false) || "Klinik Vaka";
  const trueDx = sanitizeFlashcardText(payload?.trueDiagnosis, 120, false) || "Belirtilmedi";
  const userDx = sanitizeFlashcardText(payload?.userDiagnosis, 120, false) || "Belirtilmedi";
  const strengths = Array.isArray(payload?.strengths) ? payload.strengths : [];
  const improvements = Array.isArray(payload?.improvements) ? payload.improvements : [];

  const base = [
    {
      id: crypto.randomUUID(),
      cardType: "diagnosis",
      title: "Tanı Odak",
      front: `${caseTitle} için en olası tanı neydi?`,
      back: `Doğru tanı: ${trueDx}\nSenin tanın: ${userDx}`,
      specialty: safeSpecialty,
      difficulty: safeDifficulty,
      tags: ["tani", "vaka-ozeti"]
    },
    {
      id: crypto.randomUUID(),
      cardType: "red_flag",
      title: "Kırmızı Bayrak",
      front: "Bu vaka için kaçırılmaması gereken kırmızı bayrak neydi?",
      back:
        sanitizeFlashcardText(improvements[0], 600, true) ||
        "Hayati risk yaratabilecek bulguları erken sorgulamak kritik.",
      specialty: safeSpecialty,
      difficulty: safeDifficulty,
      tags: ["guvenlik", "kirmizi-bayrak"]
    },
    {
      id: crypto.randomUUID(),
      cardType: "differential",
      title: "Ayırıcı Tanı",
      front: "İlk 3 ayırıcı tanıyı nasıl sıralardın?",
      back:
        sanitizeFlashcardText(strengths[0], 600, true) ||
        "Semptom başlangıcı, süre ve risk faktörlerine göre ayırıcı tanıyı daralt.",
      specialty: safeSpecialty,
      difficulty: safeDifficulty,
      tags: ["ayirici-tani"]
    },
    {
      id: crypto.randomUUID(),
      cardType: "management",
      title: "Yönetim Planı",
      front: "Bu vakada ilk yönetim adımı ne olmalıydı?",
      back:
        sanitizeFlashcardText(strengths[1] || improvements[1], 600, true) ||
        "Stabilizasyon, hedefli tetkik ve zamanında konsültasyon sıralamasını koru.",
      specialty: safeSpecialty,
      difficulty: safeDifficulty,
      tags: ["yonetim", "ilk-adim"]
    }
  ];

  return dedupeFlashcards(base, Math.max(3, Math.min(10, maxCards)));
}

function addDaysIso(days) {
  const safeDays = Math.max(1, Math.min(365, Number(days) || 1));
  return new Date(Date.now() + safeDays * 24 * 60 * 60 * 1000).toISOString();
}

function computeFlashcardNextSchedule(card, rating) {
  const currentInterval = Math.max(1, Math.min(365, Number(card?.interval_days || 1)));
  const currentRepetition = Math.max(0, Math.min(100, Number(card?.repetition_count || 0)));
  const currentEase = Math.max(1.3, Math.min(3.0, Number(card?.ease_factor || 2.5)));

  if (rating === "again") {
    return {
      intervalDays: 1,
      repetitionCount: 0,
      easeFactor: Math.max(1.3, Number((currentEase - 0.2).toFixed(2))),
      dueAt: addDaysIso(1)
    };
  }

  if (rating === "hard") {
    const intervalDays = Math.max(3, Math.min(365, Math.round(currentInterval * 1.2)));
    return {
      intervalDays,
      repetitionCount: Math.min(100, currentRepetition + 1),
      easeFactor: Math.max(1.3, Number((currentEase - 0.05).toFixed(2))),
      dueAt: addDaysIso(intervalDays)
    };
  }

  const intervalDays = currentRepetition >= 2
    ? Math.max(14, Math.min(365, Math.round(currentInterval * 2.0)))
    : Math.max(7, Math.min(365, Math.round(currentInterval * 1.7)));
  return {
    intervalDays,
    repetitionCount: Math.min(100, currentRepetition + 1),
    easeFactor: Math.min(3.0, Number((currentEase + 0.05).toFixed(2))),
    dueAt: addDaysIso(intervalDays)
  };
}

function normalizeDifficulty(input, fallback = "Orta") {
  const value = String(input || "")
    .toLocaleLowerCase("tr-TR")
    .replace(/\s+/g, " ")
    .trim();
  if (!value) {
    return fallback;
  }
  if (value.includes("kolay") || value.includes("beginner")) {
    return "Kolay";
  }
  if (value.includes("ileri") || value.includes("advanced") || value.includes("zor") || value.includes("hard")) {
    return "Zor";
  }
  if (value.includes("orta") || value.includes("intermediate")) {
    return "Orta";
  }
  return fallback;
}

function slugifyText(input, fallback = "challenge") {
  const slug = String(input || "")
    .toLocaleLowerCase("tr-TR")
    .normalize("NFD")
    .replace(/[\u0300-\u036f]/g, "")
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "")
    .slice(0, 48);
  return slug || fallback;
}

function normalizeChallengePayloadForDate(rawChallenge, dateKey) {
  const fallback = buildDailyChallengePayload(dateKey);
  const source = rawChallenge && typeof rawChallenge === "object" ? rawChallenge : {};
  const generatedAt = toIsoString(source.generatedAt || source.generated_at || fallback.generatedAt) || fallback.generatedAt;
  const expiresAt =
    toIsoString(source.expiresAt || source.expires_at || addHoursIso(generatedAt, 24)) ||
    addHoursIso(generatedAt, 24) ||
    fallback.expiresAt;

  const title = sanitizeChallengeLine(source.title, 86) || fallback.title;
  const specialty = sanitizeChallengeLine(source.specialty, 48) || fallback.specialty;
  const difficulty = normalizeDifficulty(source.difficulty, fallback.difficulty);
  const summary = sanitizeChallengeLine(source.summary, 220) || fallback.summary;
  const chiefComplaint = sanitizeChallengeLine(source.chiefComplaint, 120) || fallback.chiefComplaint;
  const patientGender = sanitizeChallengeLine(source.patientGender, 24) || fallback.patientGender;
  const patientAgeRaw = Number(source.patientAge);
  const patientAge = Number.isFinite(patientAgeRaw)
    ? Math.max(1, Math.min(95, Math.round(patientAgeRaw)))
    : fallback.patientAge;
  const expectedDiagnosis =
    sanitizeChallengeLine(source.expectedDiagnosis, 90) || fallback.expectedDiagnosis;
  const seedFocus = sanitizeChallengeLine(source.seedFocus, 120) || fallback.seedFocus;
  const bonusPointsRaw = Number(source.bonusPoints);
  const bonusPoints = Number.isFinite(bonusPointsRaw)
    ? Math.max(20, Math.min(120, Math.round(bonusPointsRaw)))
    : challengeBonusByDifficulty(difficulty);
  const durationRaw = Number(source.durationMin);
  const durationMin = Number.isFinite(durationRaw) ? Math.max(8, Math.min(30, Math.round(durationRaw))) : 15;
  const id = `daily-${dateKey}-${slugifyText(source.slug || title, "vaka")}`;

  const agentSeedPrompt =
    `Bugünün vaka meydan okuması ayarları:\n` +
    `- Zorluk: ${difficulty}\n` +
    `- Bölüm: ${specialty}\n` +
    `- Vaka başlığı: ${title}\n` +
    `- Başvuru şikayeti: ${chiefComplaint}\n` +
    `- Hasta: ${patientGender}, ${patientAge} yaş\n` +
    `- Eğitsel odak: ${seedFocus}\n` +
    `- Hedef doğru tanı: ${expectedDiagnosis}\n` +
    "Bu ayarlara uygun şekilde vakayı yönet. Tanıyı başta söyleme; anamnez ve klinik akışa göre adım adım ilerle. Bu parametreler kesin, kullanıcıya bölüm/zorluk tekrar sorma.";

  return {
    dateKey,
    id,
    type: "daily",
    generatedAt,
    expiresAt,
    title,
    summary,
    specialty,
    difficulty,
    chiefComplaint,
    patientGender,
    patientAge,
    expectedDiagnosis,
    durationMin,
    bonusPoints,
    seedFocus,
    agentSeedPrompt
  };
}

function normalizeCompareText(input) {
  return String(input || "")
    .toLocaleLowerCase("tr-TR")
    .normalize("NFD")
    .replace(/[\u0300-\u036f]/g, "")
    .replace(/[^a-z0-9çğıöşü\s-]/gi, " ")
    .replace(/\s+/g, " ")
    .trim();
}

function isSameChallengeSignature(a, b) {
  const left = a && typeof a === "object" ? a : {};
  const right = b && typeof b === "object" ? b : {};
  const sameSpecialty =
    normalizeCompareText(left.specialty) &&
    normalizeCompareText(left.specialty) === normalizeCompareText(right.specialty);
  const sameDifficulty =
    normalizeDifficulty(left.difficulty, "") &&
    normalizeDifficulty(left.difficulty, "") === normalizeDifficulty(right.difficulty, "");
  const sameDiagnosis =
    normalizeCompareText(left.expectedDiagnosis) &&
    normalizeCompareText(left.expectedDiagnosis) === normalizeCompareText(right.expectedDiagnosis);
  const sameTitle =
    normalizeCompareText(left.title) &&
    normalizeCompareText(left.title) === normalizeCompareText(right.title);

  if (sameTitle && sameDiagnosis) {
    return true;
  }
  return Boolean(sameSpecialty && sameDifficulty && sameDiagnosis);
}

async function getCachedDailyChallenge(nowLike = Date.now()) {
  if (isUpstashEnabled()) {
    try {
      const entry = await redisGetJson(buildRedisKey("daily:active"));
      if (!entry || typeof entry !== "object") {
        return null;
      }
      if (!isChallengeActiveNow(entry, nowLike)) {
        await runRedisCommand(["DEL", buildRedisKey("daily:active")]);
        return null;
      }
      return entry;
    } catch (error) {
      // eslint-disable-next-line no-console
      console.warn(`[daily-cache] upstash fallback -> memory: ${error?.message || "unknown"}`);
    }
  }

  const entry = dailyChallengeCache.get("active");
  if (!entry) {
    return null;
  }
  if (!isChallengeActiveNow(entry, nowLike)) {
    dailyChallengeCache.delete("active");
    return null;
  }
  return entry;
}

async function setCachedDailyChallenge(payload) {
  if (!payload || typeof payload !== "object") {
    return;
  }
  if (!isChallengeActiveNow(payload, Date.now())) {
    return;
  }
  if (isUpstashEnabled()) {
    try {
      const ttlMs = Math.max(
        15_000,
        new Date(payload.expiresAt || Date.now() + 60_000).getTime() - Date.now()
      );
      await redisSetJsonPx(buildRedisKey("daily:active"), payload, ttlMs);
    } catch (error) {
      // eslint-disable-next-line no-console
      console.warn(`[daily-cache] set upstash failed, memory fallback only: ${error?.message || "unknown"}`);
    }
  }
  dailyChallengeCache.set("active", payload);
}

async function acquireDailyWarmupLock(lockKey, ttlMs = 90_000) {
  const safeKey = String(lockKey || "").trim();
  if (!safeKey) {
    return false;
  }
  if (isUpstashEnabled()) {
    try {
      const redisKey = buildRedisKey(`daily:warmup:${safeKey}`);
      const result = await runRedisCommand([
        "SET",
        redisKey,
        "1",
        "PX",
        String(Math.max(5000, Number(ttlMs) || 90_000)),
        "NX"
      ]);
      return result === "OK";
    } catch (error) {
      // eslint-disable-next-line no-console
      console.warn(`[daily-warmup] upstash fallback -> memory: ${error?.message || "unknown"}`);
    }
  }
  if (dailyChallengeWarmupLocks.has(safeKey)) {
    return false;
  }
  dailyChallengeWarmupLocks.add(safeKey);
  return true;
}

async function releaseDailyWarmupLock(lockKey) {
  const safeKey = String(lockKey || "").trim();
  if (!safeKey) {
    return;
  }
  if (isUpstashEnabled()) {
    try {
      await runRedisCommand(["DEL", buildRedisKey(`daily:warmup:${safeKey}`)]);
    } catch {
      // best effort
    }
  }
  dailyChallengeWarmupLocks.delete(safeKey);
}

async function fetchDailyChallengeFromSupabase({ supabaseUrl, supabaseServiceRoleKey, dateKey, nowIso }) {
  try {
    const headers = {
      apikey: supabaseServiceRoleKey,
      Authorization: `Bearer ${supabaseServiceRoleKey}`
    };

    const pickBestCandidate = (rows) => {
      const list = (Array.isArray(rows) ? rows : [])
        .map((row) => {
          if (!row?.payload || typeof row.payload !== "object") {
            return null;
          }
          return normalizeChallengePayloadForDate(
            {
              ...row.payload,
              generatedAt: row.payload.generatedAt || row.created_at || row.updated_at || null,
              expiresAt: row.payload.expiresAt || row.expires_at || null
            },
            String(row.date_key || dateKey)
          );
        })
        .filter(Boolean);

      if (!list.length) {
        return null;
      }

      const active = list
        .filter((item) => isChallengeActiveNow(item, nowIso))
        .sort((a, b) => new Date(b.generatedAt).getTime() - new Date(a.generatedAt).getTime())[0];
      if (active) {
        return active;
      }

      const upcoming = list
        .filter((item) => isChallengeUpcoming(item, nowIso))
        .sort((a, b) => new Date(a.generatedAt).getTime() - new Date(b.generatedAt).getTime())[0];
      if (upcoming) {
        return upcoming;
      }

      return list.sort((a, b) => new Date(b.generatedAt).getTime() - new Date(a.generatedAt).getTime())[0];
    };

    const activeQs = new URLSearchParams({
      expires_at: `gt.${nowIso}`,
      select: "date_key,payload,created_at,updated_at,expires_at",
      order: "expires_at.desc",
      limit: "30"
    });

    const activeResp = await fetch(`${supabaseUrl}/rest/v1/daily_challenges?${activeQs.toString()}`, {
      method: "GET",
      headers
    });

    if (activeResp.ok) {
      const activeRows = await activeResp.json();
      const picked = pickBestCandidate(activeRows);
      if (picked) {
        return picked;
      }
    }

    const fallbackQs = new URLSearchParams({
      select: "date_key,payload,created_at,updated_at,expires_at",
      order: "created_at.desc",
      limit: "30"
    });

    const fallbackResp = await fetch(`${supabaseUrl}/rest/v1/daily_challenges?${fallbackQs.toString()}`, {
      method: "GET",
      headers
    });

    if (!fallbackResp.ok) {
      return null;
    }

    const fallbackRows = await fallbackResp.json();
    return pickBestCandidate(fallbackRows);
  } catch {
    return null;
  }
}

async function fetchDailyChallengeByDateKey({ supabaseUrl, supabaseServiceRoleKey, dateKey }) {
  try {
    const qs = new URLSearchParams({
      date_key: `eq.${dateKey}`,
      select: "date_key,payload,created_at,updated_at,expires_at",
      order: "updated_at.desc",
      limit: "1"
    });
    const resp = await fetch(`${supabaseUrl}/rest/v1/daily_challenges?${qs.toString()}`, {
      method: "GET",
      headers: {
        apikey: supabaseServiceRoleKey,
        Authorization: `Bearer ${supabaseServiceRoleKey}`
      }
    });
    if (!resp.ok) {
      return null;
    }
    const rows = await resp.json();
    const row = Array.isArray(rows) ? rows[0] : null;
    if (!row?.payload || typeof row.payload !== "object") {
      return null;
    }
    return normalizeChallengePayloadForDate(
      {
        ...row.payload,
        generatedAt: row.payload.generatedAt || row.created_at || row.updated_at || null,
        expiresAt: row.payload.expiresAt || row.expires_at || null
      },
      String(row.date_key || dateKey)
    );
  } catch {
    return null;
  }
}

async function upsertDailyChallengeToSupabase({ supabaseUrl, supabaseServiceRoleKey, dateKey, challenge }) {
  try {
    const generatedAt = toIsoString(challenge?.generatedAt) || new Date().toISOString();
    const expiresAt = toIsoString(challenge?.expiresAt) || addHoursIso(generatedAt, 24) || new Date(Date.now() + 24 * 60 * 60 * 1000).toISOString();
    const row = {
      date_key: dateKey,
      payload: challenge,
      created_at: generatedAt,
      expires_at: expiresAt,
      updated_at: new Date().toISOString()
    };

    const resp = await fetch(`${supabaseUrl}/rest/v1/daily_challenges?on_conflict=date_key`, {
      method: "POST",
      headers: {
        apikey: supabaseServiceRoleKey,
        Authorization: `Bearer ${supabaseServiceRoleKey}`,
        "Content-Type": "application/json",
        Prefer: "resolution=merge-duplicates,return=minimal"
      },
      body: JSON.stringify([row])
    });
    return resp.ok;
  } catch {
    return false;
  }
}

async function prepareNextDailyChallenge({
  supabaseUrl,
  supabaseServiceRoleKey,
  currentChallenge,
  nowIso
}) {
  if (!supabaseUrl || !supabaseServiceRoleKey || !currentChallenge) {
    return null;
  }

  const currentWindow = resolveChallengeWindow(currentChallenge, nowIso);
  if (!currentWindow?.expiresAt) {
    return null;
  }

  const nextGeneratedAt = toIsoString(currentWindow.expiresAt) || addHoursIso(nowIso, 24);
  if (!nextGeneratedAt) {
    return null;
  }
  const nextExpiresAt = addHoursIso(nextGeneratedAt, 24) || addHoursIso(Date.now(), 24);
  const nextDateKey = utcDateKey(nextGeneratedAt);
  const lockKey = `${nextDateKey}|${nextGeneratedAt}`;
  const lockAcquired = await acquireDailyWarmupLock(lockKey, 90_000);
  if (!lockAcquired) {
    return null;
  }
  try {
    const existing = await fetchDailyChallengeByDateKey({
      supabaseUrl,
      supabaseServiceRoleKey,
      dateKey: nextDateKey
    });
    if (existing) {
      const existingWindow = resolveChallengeWindow(existing, nowIso);
      if (
        existingWindow.generatedAt &&
        existingWindow.expiresAt &&
        new Date(existingWindow.expiresAt).getTime() > new Date(nextGeneratedAt).getTime()
      ) {
        return existing;
      }
    }

    let generated = await generateDailyChallengeWithLlm(nextDateKey, {
      previousChallenge: currentChallenge,
      hardDiversify: true,
      timeoutMs: 12000
    });

    let prepared = normalizeChallengePayloadForDate(
      {
        ...(generated || buildDailyChallengePayload(nextDateKey)),
        generatedAt: nextGeneratedAt,
        expiresAt: nextExpiresAt
      },
      nextDateKey
    );

    if (isSameChallengeSignature(prepared, currentChallenge)) {
      const alt = buildDailyChallengePayload(`${nextDateKey}-alt-${Date.now()}`);
      prepared = normalizeChallengePayloadForDate(
        {
          ...alt,
          generatedAt: nextGeneratedAt,
          expiresAt: nextExpiresAt
        },
        nextDateKey
      );
    }

    await upsertDailyChallengeToSupabase({
      supabaseUrl,
      supabaseServiceRoleKey,
      dateKey: nextDateKey,
      challenge: prepared
    });
    return prepared;
  } catch {
    return null;
  } finally {
    await releaseDailyWarmupLock(lockKey);
  }
}

async function generateDailyChallengeWithLlm(dateKey, options = {}) {
  if (!process.env.OPENAI_API_KEY) {
    return null;
  }

  const opts = options && typeof options === "object" ? options : {};
  const timeoutMs = Math.max(5000, Math.min(45000, Number(opts.timeoutMs || 35000)));
  const previous = opts.previousChallenge && typeof opts.previousChallenge === "object" ? opts.previousChallenge : null;
  const avoidSpecialty = sanitizeChallengeLine(previous?.specialty, 50);
  const avoidDifficulty = normalizeDifficulty(previous?.difficulty, "");
  const avoidDiagnosis = sanitizeChallengeLine(previous?.expectedDiagnosis, 90);
  const hardDiversify = Boolean(opts.hardDiversify);

  const diversifyRules = previous
    ? `Önceki aktif günlük vaka: bölüm=${avoidSpecialty || "bilinmiyor"}, zorluk=${avoidDifficulty || "bilinmiyor"}, tanı=${avoidDiagnosis || "bilinmiyor"}.\n` +
      "Yeni vakada önceki vakayı tekrar etme. Bölüm veya zorluktan en az birini değiştir."
    : "Vaka parametrelerini çeşitlendir, yakın geçmişte aynı bölüm-zorluk kombinasyonunu tekrarlama.";

  try {
    const response = await openai.responses.create(
      {
        model: dailyChallengeModel || scoreModel || model,
        input:
          `Tarih: ${dateKey}\n` +
          "Türkiye Türkçesi ile günlük tek bir klinik vaka meydan okuması üret.\n" +
          `${diversifyRules}\n` +
          (hardDiversify
            ? "Bu üretimde çeşitlilik zorunlu: önceki vaka ile aynı bölüm-zorluk-tanı kombinasyonunu kullanma.\n"
            : "") +
          "Dönüş JSON olsun.",
        instructions: DAILY_CHALLENGE_INSTRUCTIONS,
        max_output_tokens: 520,
        temperature: hardDiversify ? 1 : 0.75,
        text: {
          format: {
            type: "json_schema",
            name: "daily_challenge",
            strict: true,
            schema: {
              type: "object",
              additionalProperties: false,
              properties: {
                title: { type: "string", maxLength: 90 },
                specialty: { type: "string", maxLength: 50 },
                difficulty: { type: "string", enum: ["Kolay", "Orta", "Zor"] },
                summary: { type: "string", maxLength: 230 },
                chiefComplaint: { type: "string", maxLength: 120 },
                patientGender: { type: "string", maxLength: 20 },
                patientAge: { type: "number", minimum: 1, maximum: 95 },
                expectedDiagnosis: { type: "string", maxLength: 90 },
                seedFocus: { type: "string", maxLength: 120 },
                durationMin: { type: "number", minimum: 8, maximum: 30 },
                bonusPoints: { type: "number", minimum: 20, maximum: 120 }
              },
              required: [
                "title",
                "specialty",
                "difficulty",
                "summary",
                "chiefComplaint",
                "patientGender",
                "patientAge",
                "expectedDiagnosis",
                "seedFocus",
                "durationMin",
                "bonusPoints"
              ]
            }
          }
        }
      },
      { timeout: timeoutMs }
    );

    const structured = extractStructuredModelPayload(response);
    const rawText = extractOutputText(response);
    const parsed =
      (structured && typeof structured === "object" ? structured : null) ||
      parseModelJsonPayload(rawText);
    if (!parsed || typeof parsed !== "object") {
      return null;
    }
    return normalizeChallengePayloadForDate(parsed, dateKey);
  } catch {
    return null;
  }
}

async function resolveDailyChallenge({
  supabaseUrl,
  supabaseServiceRoleKey,
  dateKey,
  nowIso,
  forceRefresh = false
}) {
  const triggerWarmup = (activeChallenge) => {
    if (!supabaseUrl || !supabaseServiceRoleKey || !activeChallenge) {
      return;
    }
    void prepareNextDailyChallenge({
      supabaseUrl,
      supabaseServiceRoleKey,
      currentChallenge: activeChallenge,
      nowIso
    }).catch(() => {});
  };

  let previousActive = null;
  if (forceRefresh) {
    const cachedActive = await getCachedDailyChallenge(nowIso);
    if (cachedActive) {
      previousActive = cachedActive;
    } else if (supabaseUrl && supabaseServiceRoleKey) {
      previousActive = await fetchDailyChallengeFromSupabase({
        supabaseUrl,
        supabaseServiceRoleKey,
        dateKey,
        nowIso
      });
    }
  }

  if (!forceRefresh) {
    const cached = await getCachedDailyChallenge(nowIso);
    if (cached) {
      triggerWarmup(cached);
      return cached;
    }

    const fromDb =
      supabaseUrl && supabaseServiceRoleKey
        ? await fetchDailyChallengeFromSupabase({
            supabaseUrl,
            supabaseServiceRoleKey,
            dateKey,
            nowIso
          })
        : null;
    if (fromDb) {
      await setCachedDailyChallenge(fromDb);
      triggerWarmup(fromDb);
      return fromDb;
    }
  }

  let generated = await generateDailyChallengeWithLlm(dateKey, {
    previousChallenge: previousActive,
    timeoutMs: 6000
  });
  if (previousActive && generated && isSameChallengeSignature(generated, previousActive)) {
    const retryDateKey = `${dateKey}-retry-${Date.now()}`;
    generated = await generateDailyChallengeWithLlm(retryDateKey, {
      previousChallenge: previousActive,
      hardDiversify: true,
      timeoutMs: 6000
    });
  }

  const generatedAt = toIsoString(nowIso) || new Date().toISOString();
  const expiresAt =
    addHoursIso(generatedAt, 24) ||
    addHoursIso(Date.now(), 24) ||
    new Date(Date.now() + 24 * 60 * 60 * 1000).toISOString();
  let challenge = normalizeChallengePayloadForDate(
    {
      ...(generated || buildDailyChallengePayload(dateKey)),
      generatedAt,
      expiresAt
    },
    dateKey
  );
  if (previousActive && isSameChallengeSignature(challenge, previousActive)) {
    const fallbackAlt = buildDailyChallengePayload(`${dateKey}-alt-${Date.now()}`);
    challenge = normalizeChallengePayloadForDate(
      {
        ...fallbackAlt,
        generatedAt,
        expiresAt
      },
      dateKey
    );
  }

  if (supabaseUrl && supabaseServiceRoleKey) {
    await upsertDailyChallengeToSupabase({
      supabaseUrl,
      supabaseServiceRoleKey,
      dateKey,
      challenge
    });

    const persisted = await fetchDailyChallengeFromSupabase({
      supabaseUrl,
      supabaseServiceRoleKey,
      dateKey,
      nowIso
    });
    if (persisted) {
      await setCachedDailyChallenge(persisted);
      triggerWarmup(persisted);
      return persisted;
    }
  }

  await setCachedDailyChallenge(challenge);
  triggerWarmup(challenge);
  return challenge;
}

function extractChallengeIdFromCaseContext(context) {
  const source = context && typeof context === "object" ? context : {};
  const id = String(source.challenge_id || source.challengeId || "").trim();
  return id || "";
}

function extractScoreNumber(scoreLike) {
  const parsed =
    scoreLike && typeof scoreLike === "object" ? scoreLike : parseJsonMaybe(String(scoreLike || ""));
  const numeric = Number(parsed?.overall_score);
  return Number.isFinite(numeric) ? numeric : null;
}

function computeChallengeStats(rows, challengeId) {
  const list = Array.isArray(rows) ? rows : [];
  const filtered = list.filter((item) => {
    const rowChallengeId =
      String(item?.challenge_id || "").trim() || extractChallengeIdFromCaseContext(item?.case_context);
    return rowChallengeId === challengeId;
  });

  if (!filtered.length) {
    return {
      attemptedUsers: 0,
      participantCount: 0,
      averageScore: null
    };
  }

  const sorted = [...filtered].sort((a, b) => {
    const at = new Date(a?.updated_at || 0).getTime();
    const bt = new Date(b?.updated_at || 0).getTime();
    return bt - at;
  });

  const latestByUser = new Map();
  for (const row of sorted) {
    const uid = String(row?.user_id || "").trim();
    if (!uid || latestByUser.has(uid)) {
      continue;
    }
    latestByUser.set(uid, row);
  }

  let scoredCount = 0;
  let scoreSum = 0;
  for (const row of latestByUser.values()) {
    const score = extractScoreNumber(row?.score);
    if (score == null) {
      continue;
    }
    scoredCount += 1;
    scoreSum += score;
  }

  return {
    attemptedUsers: latestByUser.size,
    participantCount: scoredCount,
    averageScore: scoredCount > 0 ? Number((scoreSum / scoredCount).toFixed(1)) : null
  };
}

async function fetchChallengeStatsFromAttempts({
  supabaseUrl,
  supabaseServiceRoleKey,
  challengeId,
  dateKey
}) {
  const cleanChallengeId = String(challengeId || "").trim();
  if (!supabaseUrl || !supabaseServiceRoleKey || !cleanChallengeId) {
    return null;
  }

  const qs = new URLSearchParams({
    select: "user_id,best_score,updated_at,date_key",
    order: "updated_at.desc",
    limit: "5000"
  });
  qs.append("challenge_id", `eq.${cleanChallengeId}`);
  if (dateKey) {
    qs.append("date_key", `eq.${dateKey}`);
  }

  const resp = await fetch(`${supabaseUrl}/rest/v1/daily_challenge_attempts?${qs.toString()}`, {
    method: "GET",
    headers: {
      apikey: supabaseServiceRoleKey,
      Authorization: `Bearer ${supabaseServiceRoleKey}`
    }
  });

  if (!resp.ok) {
    const txt = await resp.text();
    throw new Error(txt || `daily_challenge_attempts okunamadi (${resp.status})`);
  }

  const rows = await resp.json().catch(() => []);
  const list = Array.isArray(rows) ? rows : [];
  if (!list.length) {
    return {
      attemptedUsers: 0,
      participantCount: 0,
      averageScore: null
    };
  }

  const attemptedUsers = new Set();
  let participantCount = 0;
  let totalScore = 0;

  for (const row of list) {
    const uid = sanitizeUuid(row?.user_id);
    if (uid) {
      attemptedUsers.add(uid);
    }
    const score = Number(row?.best_score);
    if (Number.isFinite(score)) {
      participantCount += 1;
      totalScore += score;
    }
  }

  return {
    attemptedUsers: attemptedUsers.size || list.length,
    participantCount,
    averageScore: participantCount > 0 ? Number((totalScore / participantCount).toFixed(1)) : null
  };
}

function extractChallengeTypeFromCaseContext(context) {
  const source = context && typeof context === "object" ? context : {};
  const raw = String(source.challenge_type || source.challengeType || "").trim().toLocaleLowerCase("tr-TR");
  return raw || "";
}

function extractChallengeDateKey(challengeId, fallbackIso = new Date().toISOString()) {
  const rawId = String(challengeId || "").trim();
  const match = rawId.match(/(\d{4}-\d{2}-\d{2})/);
  if (match?.[1]) {
    return match[1];
  }
  return utcDateKey(fallbackIso);
}

async function upsertDailyChallengeAttempt({
  supabaseUrl,
  supabaseServiceRoleKey,
  userId,
  row
}) {
  const cleanUserId = sanitizeUuid(userId);
  if (!cleanUserId || !row || typeof row !== "object") {
    return;
  }

  const challengeType = extractChallengeTypeFromCaseContext(row.case_context);
  if (challengeType !== "daily") {
    return;
  }

  const challengeId = extractChallengeIdFromCaseContext(row.case_context);
  if (!challengeId) {
    return;
  }

  const dateKey = extractChallengeDateKey(challengeId, row.updated_at || new Date().toISOString());
  const sessionId = String(row.session_id || "").trim() || null;
  const score = extractScoreNumber(row.score);
  const nowIso = new Date().toISOString();

  const selectQs = new URLSearchParams({
    user_id: `eq.${cleanUserId}`,
    challenge_id: `eq.${challengeId}`,
    select: "id,attempt_count,best_score,last_session_id",
    limit: "1"
  });

  const commonHeaders = {
    apikey: supabaseServiceRoleKey,
    Authorization: `Bearer ${supabaseServiceRoleKey}`
  };

  const existingResp = await fetch(`${supabaseUrl}/rest/v1/daily_challenge_attempts?${selectQs.toString()}`, {
    method: "GET",
    headers: commonHeaders
  });
  if (!existingResp.ok) {
    return;
  }
  const existingRows = await existingResp.json().catch(() => []);
  const existing = Array.isArray(existingRows) ? existingRows[0] || null : null;

  if (!existing) {
    const insertRow = {
      user_id: cleanUserId,
      challenge_id: challengeId,
      date_key: dateKey,
      attempt_count: 1,
      completed_count: score != null ? 1 : 0,
      best_score: score,
      last_score: score,
      last_session_id: sessionId,
      first_attempted_at: nowIso,
      last_attempted_at: nowIso,
      created_at: nowIso,
      updated_at: nowIso
    };
    await fetch(`${supabaseUrl}/rest/v1/daily_challenge_attempts`, {
      method: "POST",
      headers: {
        ...commonHeaders,
        "Content-Type": "application/json",
        Prefer: "return=minimal"
      },
      body: JSON.stringify([insertRow])
    });
    return;
  }

  const prevAttempts = Number(existing.attempt_count || 0);
  const prevBest = Number(existing.best_score);
  const prevCompleted = Number(existing.completed_count || 0);
  const prevSessionId = String(existing.last_session_id || "").trim() || null;
  const isNewAttempt = sessionId && prevSessionId ? sessionId !== prevSessionId : true;
  const nextAttempts = isNewAttempt ? prevAttempts + 1 : Math.max(1, prevAttempts);
  const nextCompleted = score != null ? (isNewAttempt ? prevCompleted + 1 : Math.max(prevCompleted, 1)) : prevCompleted;
  const nextBest = score == null
    ? (Number.isFinite(prevBest) ? prevBest : null)
    : (!Number.isFinite(prevBest) ? score : Math.max(prevBest, score));

  const patch = {
    date_key: dateKey,
    attempt_count: nextAttempts,
    completed_count: nextCompleted,
    best_score: nextBest,
    last_score: score,
    last_session_id: sessionId,
    last_attempted_at: nowIso,
    updated_at: nowIso
  };

  const patchQs = new URLSearchParams({
    id: `eq.${existing.id}`
  });
  await fetch(`${supabaseUrl}/rest/v1/daily_challenge_attempts?${patchQs.toString()}`, {
    method: "PATCH",
    headers: {
      ...commonHeaders,
      "Content-Type": "application/json",
      Prefer: "return=minimal"
    },
    body: JSON.stringify(patch)
  });
}

async function upsertProfileRow({
  supabaseUrl,
  supabaseServiceRoleKey,
  row,
  errorPrefix = "Profil kaydı yazılamadı"
}) {
  const payload = { ...(row || {}) };
  const droppedColumns = [];

  for (let attempt = 0; attempt < 8; attempt += 1) {
    const upsertResp = await fetch(`${supabaseUrl}/rest/v1/profiles?on_conflict=id`, {
      method: "POST",
      headers: {
        apikey: supabaseServiceRoleKey,
        Authorization: `Bearer ${supabaseServiceRoleKey}`,
        "Content-Type": "application/json",
        Prefer: "resolution=merge-duplicates,return=minimal"
      },
      body: JSON.stringify([payload])
    });

    if (upsertResp.ok) {
      return {
        droppedColumns
      };
    }

    const txt = await upsertResp.text();
    const parsedError = parseJsonMaybe(txt);
    const missingColumn = extractMissingProfilesColumn(parsedError || txt);
    const isSchemaCacheError = String(parsedError?.code || "").toUpperCase() === "PGRST204";

    if (
      isSchemaCacheError &&
      missingColumn &&
      Object.prototype.hasOwnProperty.call(payload, missingColumn)
    ) {
      delete payload[missingColumn];
      droppedColumns.push(missingColumn);
      continue;
    }

    const error = new Error(`${errorPrefix}: ${txt || upsertResp.status}`);
    error.status = 500;
    throw error;
  }

  const error = new Error(`${errorPrefix}: Beklenmeyen schema uyumsuzlugu.`);
  error.status = 500;
  throw error;
}

function normalizeProfileRow(profile) {
  if (!profile) {
    return null;
  }
  return {
    ...profile,
    ai_enabled: profile.ai_enabled == null ? true : Boolean(profile.ai_enabled),
    ai_disabled_reason: sanitizeAdminReason(profile.ai_disabled_reason),
    onboarding_completed: Boolean(profile.onboarding_completed),
    marketing_opt_in: Boolean(profile.marketing_opt_in),
    goals: Array.isArray(profile.goals) ? profile.goals : [],
    interest_areas: Array.isArray(profile.interest_areas) ? profile.interest_areas : []
  };
}
const defaultRubricPrompt = `You are grading clinical reasoning based ONLY on the case conversation.

INPUTS
1) FULL_CONVERSATION: a chronological conversation log (user + simulated patient/coach).
2) MODE: voice or text.
3) OPTIONAL_CASE_WRAPUP: may include the final diagnosis and teaching points stated by the coach at the end.
4) RUBRIC_KEYS (10):
- data_gathering_quality
- clinical_reasoning_logic
- differential_diagnosis_depth
- diagnostic_efficiency
- management_plan_quality
- safety_red_flags
- decision_timing
- communication_clarity
- guideline_consistency
- professionalism_empathy

TASK
Return ONLY valid JSON with:
{
  "case_title": "short Turkish title reflecting likely diagnosis if explicit",
  "true_diagnosis": "ground-truth diagnosis from coach/wrapup; short Turkish phrase",
  "user_diagnosis": "diagnosis the user proposed; short Turkish phrase or Belirtilmedi",
  "overall_score": 0-100,
  "label": "Excellent|Good|Needs Improvement|Poor",
  "strengths": ["...","...","..."],
  "improvements": ["...","...","..."],
  "dimensions": [
    {"key":"data_gathering_quality","score":0-10,"explanation":"...","recommendation":"..."},
    {"key":"clinical_reasoning_logic","score":0-10,"explanation":"...","recommendation":"..."},
    {"key":"differential_diagnosis_depth","score":0-10,"explanation":"...","recommendation":"..."},
    {"key":"diagnostic_efficiency","score":0-10,"explanation":"...","recommendation":"..."},
    {"key":"management_plan_quality","score":0-10,"explanation":"...","recommendation":"..."},
    {"key":"safety_red_flags","score":0-10,"explanation":"...","recommendation":"..."},
    {"key":"decision_timing","score":0-10,"explanation":"...","recommendation":"..."},
    {"key":"communication_clarity","score":0-10,"explanation":"...","recommendation":"..."},
    {"key":"guideline_consistency","score":0-10,"explanation":"...","recommendation":"..."},
    {"key":"professionalism_empathy","score":0-10,"explanation":"...","recommendation":"..."}
  ],
  "brief_summary": "3-6 sentences summarizing performance",
  "missed_opportunities": ["...","...","..."],
  "next_practice_suggestions": [
    {"focus":"...", "micro-drill":"...", "example_prompt":"..."},
    {"focus":"...", "micro-drill":"...", "example_prompt":"..."}
  ]
}

SCORING RULES
- Score strictly based on what is explicitly present in the conversation.
- Evaluate performance ONLY from KULLANICI messages. HASTA_VEYA_KOC messages are context only.
- Never treat coach praise or coach actions as the user's performance evidence.
- Determine true_diagnosis from OPTIONAL_CASE_WRAPUP first, then explicit coach statements in conversation.
- If true diagnosis is not explicitly available, infer the most likely diagnosis from the clinical flow and write a short Turkish phrase.
- Set user_diagnosis based on what the user explicitly proposed; if absent set "Belirtilmedi".
- Never copy user_diagnosis into true_diagnosis unless coach/wrapup explicitly confirms the same diagnosis.
- Do not assume they performed steps unless explicitly stated.
- Reward structured approaches (OPQRST, ABCDE, etc.).
- Penalize missing red flags, unsafe plans, or delayed critical tests.
- If OPTIONAL_CASE_WRAPUP is absent, still score reasoning quality based on process.
- Keep feedback actionable and specific, not generic.
- Write all free-text feedback fields in Turkish.
- Directly address the user with "sen/senin".
- Do not use these words in output: OpenAI, participant, katilimci, student, ogrenci, transcript, transkript.
- Improvements must be distinct, concrete, and tied to specific missed or delayed steps.
- Avoid template feedback like "daha kapsamlı diferansiyel tanı geliştirebilirsin" unless supported with a concrete missed step.
- Keep brief_summary short (max 2 concise sentences).`;

const adminLoginBodySchema = z.object({
  username: z.string().trim().min(1).max(120),
  password: z.string().min(1).max(240),
  next: z.string().trim().max(240).optional(),
  csrfToken: z.string().trim().max(240).optional()
});

const adminCreateUserBodySchema = z.object({
  firstName: z.string().trim().min(1).max(80),
  lastName: z.string().trim().min(1).max(80),
  email: z.string().trim().email().max(240),
  password: z.string().trim().min(8).max(128).optional(),
  role: z.string().trim().max(80).optional(),
  learningLevel: z.string().trim().max(80).optional(),
  phoneNumber: z.string().trim().max(32).optional(),
  onboardingCompleted: z.boolean().optional(),
  marketingOptIn: z.boolean().optional(),
  emailConfirmed: z.boolean().optional()
});

const authResendBodySchema = z.object({
  email: z.string().trim().email().max(160),
  fullName: z.string().trim().max(120).optional()
});

const authResetPasswordCompleteBodySchema = z.object({
  accessToken: z.string().trim().min(20).max(4096),
  newPassword: z.string().min(8).max(256)
});

const profileUpsertBodySchema = z.object({
  firstName: z.string().trim().max(80).optional(),
  lastName: z.string().trim().max(80).optional(),
  fullName: z.string().trim().max(120).optional(),
  phoneNumber: z.string().trim().max(32).optional(),
  marketingOptIn: z.boolean().optional()
});

const profileOnboardingBodySchema = z.object({
  fullName: z.string().trim().max(120).optional(),
  phoneNumber: z.string().trim().max(32).optional(),
  marketingOptIn: z.boolean().optional(),
  ageRange: z.string().trim().max(40).optional(),
  role: z.string().trim().max(80).optional(),
  goals: z.array(z.string().trim().max(80)).max(8).optional(),
  interestAreas: z.array(z.string().trim().max(80)).max(16).optional(),
  learningLevel: z.string().trim().max(80).optional(),
  onboardingCompleted: z.boolean().optional()
});

const reportCreateBodySchema = z.object({
  category: z.string().trim().max(64),
  details: z.string().trim().min(8).max(1200),
  caseSessionId: z.string().uuid().optional(),
  caseTitle: z.string().trim().max(120).optional(),
  mode: z.enum(["voice", "text"]).optional(),
  difficulty: z.string().trim().max(40).optional(),
  specialty: z.string().trim().max(80).optional(),
  metadata: z.record(z.unknown()).optional()
});

const feedbackCreateBodySchema = z.object({
  topic: z.string().trim().max(64),
  message: z.string().trim().min(8).max(1600)
});

const caseSaveBodySchema = z.object({
  sessionId: z.string().trim().min(1).max(160),
  mode: z.enum(["voice", "text"]).optional(),
  status: z.string().trim().max(80).optional(),
  startedAt: z.string().trim().max(60).optional().nullable(),
  endedAt: z.string().trim().max(60).optional().nullable(),
  durationMin: z.number().int().min(0).max(1440).optional().nullable(),
  messageCount: z.number().int().min(0).max(20000).optional().nullable(),
  difficulty: z.string().trim().max(32).optional().nullable(),
  caseContext: z.record(z.unknown()).optional().nullable(),
  transcript: z.array(z.record(z.unknown())).max(1000).optional(),
  score: z.record(z.unknown()).optional().nullable(),
  usageMetrics: z.record(z.unknown()).optional().nullable(),
  costMetrics: z.record(z.unknown()).optional().nullable()
});

const elevenSessionAuthBodySchema = z.object({
  agentId: z.string().trim().max(128).optional(),
  mode: z.enum(["voice", "text"]).optional(),
  sessionWindowToken: z.string().trim().max(4096).optional(),
  dynamicVariables: z.record(z.union([z.string(), z.number(), z.boolean(), z.null()])).optional()
});

const elevenSessionTouchBodySchema = z.object({
  agentId: z.string().trim().max(128).optional(),
  sessionWindowToken: z.string().trim().max(4096)
});

const textAgentStartBodySchema = z.object({
  difficulty: z.string().trim().max(40).optional(),
  specialty: z.string().trim().max(80).optional(),
  userName: z.string().trim().max(80).optional(),
  dynamicVariables: z.record(z.union([z.string(), z.number(), z.boolean(), z.null()])).optional(),
  sessionWindowToken: z.string().trim().max(4096).optional()
});

const textAgentReplyBodySchema = z.object({
  difficulty: z.string().trim().max(40).optional(),
  specialty: z.string().trim().max(80).optional(),
  userName: z.string().trim().max(80).optional(),
  userMessage: z.string().trim().min(1).max(200),
  conversation: z.array(
    z.object({
      source: z.string().trim().max(32),
      message: z.string().trim().max(1200)
    })
  ).max(400).optional(),
  dynamicVariables: z.record(z.union([z.string(), z.number(), z.boolean(), z.null()])).optional()
});

const scoreRequestBodySchema = z.object({
  conversation: z.array(
    z.object({
      source: z.string().trim().max(32),
      message: z.string().trim().max(1800)
    })
  ).min(1).max(1200),
  rubricPrompt: z.string().trim().max(12000).optional(),
  mode: z.enum(["voice", "text"]).optional(),
  optionalCaseWrapup: z.string().trim().max(8000).optional()
});

const flashcardGenerateBodySchema = z.object({
  sessionId: z.string().trim().max(120).optional(),
  specialty: z.string().trim().max(120).optional(),
  difficulty: z.string().trim().max(40).optional(),
  caseTitle: z.string().trim().max(180).optional(),
  trueDiagnosis: z.string().trim().max(180).optional(),
  userDiagnosis: z.string().trim().max(180).optional(),
  overallScore: z.number().min(0).max(100).optional(),
  scoreLabel: z.string().trim().max(64).optional(),
  briefSummary: z.string().trim().max(600).optional(),
  strengths: z.array(z.string().trim().max(220)).max(10).optional(),
  improvements: z.array(z.string().trim().max(220)).max(10).optional(),
  missedOpportunities: z.array(z.string().trim().max(220)).max(10).optional(),
  dimensions: z.array(z.record(z.unknown())).max(20).optional(),
  nextPracticeSuggestions: z.array(z.record(z.unknown())).max(10).optional(),
  maxCards: z.number().int().min(3).max(10).optional()
});

const flashcardSaveBodySchema = z.object({
  sessionId: z.string().trim().max(120).optional(),
  cards: z.array(
    z.object({
      id: z.string().trim().max(120).optional(),
      cardType: z.string().trim().max(40),
      title: z.string().trim().max(160),
      front: z.string().trim().max(700),
      back: z.string().trim().max(1400),
      specialty: z.string().trim().max(120).optional(),
      difficulty: z.string().trim().max(40).optional(),
      tags: z.array(z.string().trim().max(60)).max(8).optional()
    })
  ).min(1).max(30)
});

const flashcardReviewBodySchema = z.object({
  cardId: z.string().trim().min(1).max(120),
  rating: z.enum(["again", "hard", "easy"])
});

const debugSimulateBodySchema = z.object({
  case: z.enum([
    "openai",
    "openai-timeout",
    "elevenlabs",
    "elevenlabs-timeout",
    "supabase",
    "upstash",
    "validation",
    "rate-limit",
    "unknown"
  ]),
  message: z.string().trim().max(160).optional()
});

const pushDeviceRegisterBodySchema = z.object({
  deviceToken: z.string().trim().min(16).max(600),
  notificationsEnabled: z.boolean().optional(),
  apnsEnvironment: z.enum(["production", "sandbox"]).optional(),
  deviceModel: z.string().trim().max(120).optional(),
  appVersion: z.string().trim().max(80).optional(),
  locale: z.string().trim().max(40).optional(),
  timezone: z.string().trim().max(80).optional()
});

const inAppBannerAckBodySchema = z.object({
  broadcastId: z.string().uuid(),
  action: z.enum(["seen", "dismiss"])
});

const adminBroadcastSendBodySchema = z.object({
  title: z.string().trim().min(2).max(120),
  body: z.string().trim().min(3).max(420),
  deepLink: z.string().trim().max(300).optional(),
  pushEnabled: z.boolean().optional(),
  inAppEnabled: z.boolean().optional(),
  expiresHours: z.number().int().min(1).max(168).optional()
});

const openai = new OpenAI({
  apiKey: process.env.OPENAI_API_KEY
});

app.use(express.json({ limit: "1mb" }));
app.use((req, res, next) => {
  req.requestId = crypto.randomUUID();
  req.startedAtMs = Date.now();
  res.setHeader("X-Request-Id", req.requestId);
  next();
});

app.use((req, res, next) => {
  const startedAt = Number(req.startedAtMs || Date.now());
  const ipHash = sha256Short(getClientIp(req));
  res.on("finish", () => {
    const isApiRequest = String(req.path || "").startsWith("/api");
    const isOptions = String(req.method || "").toUpperCase() === "OPTIONS";
    if (isApiRequest && !isOptions) {
      void incrementApiTrafficMetrics({
        method: req.method,
        path: req.path || req.originalUrl || req.url || "/",
        statusCode: Number(res.statusCode || 0),
        callerHash: ipHash,
        atMs: Date.now()
      });
    }
    if (!isApiRequest) {
      return;
    }
    if (Number(res.statusCode || 0) < 500) {
      return;
    }
    if (req.__errorCaptured) {
      return;
    }
    const entry = {
      timestamp: new Date().toISOString(),
      requestId: String(req.requestId || "").trim() || null,
      service: "api",
      code: mapStatusToErrorCode(Number(res.statusCode || 500)),
      status: Number(res.statusCode || 500),
      method: String(req.method || "GET").toUpperCase(),
      path: String(req.originalUrl || req.url || ""),
      latencyMs: Math.max(0, Date.now() - startedAt),
      ipHash
    };
    pushRuntimeErrorLog(entry);
    void persistAppErrorEvent({
      ...entry,
      message: `HTTP ${entry.status} ${entry.method} ${entry.path}`,
      metadata: {
        source: "response-finish"
      }
    });
  });
  next();
});

app.use(async (req, res, next) => {
  if (!String(req.path || "").startsWith("/api")) {
    return next();
  }

  if (String(req.method || "").toUpperCase() === "OPTIONS") {
    return next();
  }

  const normalizedPath = String(req.path || req.originalUrl || "")
    .split("?")[0]
    .trim();
  const hasQStashSignature = Boolean(
    String(req.headers?.["upstash-signature"] || req.headers?.["upstash-signature-v2"] || "").trim()
  );
  if (normalizedPath === DAILY_WORKFLOW_ROUTE_PATH && hasQStashSignature) {
    return next();
  }

  const ipIdentity = getClientIp(req);
  try {
    const globalTotalPerMinute = await enforceRateLimit(req, res, {
      scope: "global-total-minute",
      identity: "all",
      maxRequests: clampRateLimitValue(process.env.RATE_LIMIT_GLOBAL_TOTAL_PER_MIN, 3000, 100, 200000),
      windowMs: 60_000,
      errorMessage: "Sistem yoğunluğu nedeniyle istek sınırına ulaşıldı. Lütfen kısa süre sonra tekrar dene."
    });
    if (!globalTotalPerMinute) {
      return;
    }

    const globalIpPerMinute = await enforceRateLimit(req, res, {
      scope: "global-ip-minute",
      identity: ipIdentity,
      maxRequests: clampRateLimitValue(process.env.RATE_LIMIT_GLOBAL_IP_PER_MIN, 240, 20, 5000),
      windowMs: 60_000,
      errorMessage: "Bu IP için istek sınırı aşıldı. Lütfen kısa süre sonra tekrar dene."
    });
    if (!globalIpPerMinute) {
      return;
    }

    const globalTotalBurst = await enforceRateLimit(req, res, {
      scope: "global-total-burst",
      identity: "all",
      maxRequests: clampRateLimitValue(process.env.RATE_LIMIT_GLOBAL_TOTAL_PER_10S, 700, 50, 50000),
      windowMs: 10_000,
      errorMessage: "Ani trafik yoğunluğu tespit edildi. Lütfen birkaç saniye sonra tekrar dene."
    });
    if (!globalTotalBurst) {
      return;
    }

    const globalIpBurst = await enforceRateLimit(req, res, {
      scope: "global-ip-burst",
      identity: ipIdentity,
      maxRequests: clampRateLimitValue(process.env.RATE_LIMIT_GLOBAL_IP_PER_10S, 45, 5, 2000),
      windowMs: 10_000,
      errorMessage: "Bu IP için ani istek sınırı aşıldı. Lütfen birkaç saniye sonra tekrar dene."
    });
    if (!globalIpBurst) {
      return;
    }
  } catch (error) {
    await captureAppError({
      error,
      req,
      res,
      fallback: {
        service: "rate-limit",
        code: ERROR_CODES.UPSTASH_UNAVAILABLE,
        status: 503
      },
      metadata: {
        route: "global-rate-limit-guard"
      }
    });
    return res.status(503).json({
      error: "Sistem koruma katmanı geçici olarak yanıt veremiyor. Lütfen tekrar dene."
    });
  }

  return next();
});

if (isQStashWorkflowConfigured()) {
  app.use(
    DAILY_WORKFLOW_ROUTE_PATH,
    workflowServe(async (context) => {
      const requestPayload =
        context?.requestPayload && typeof context.requestPayload === "object" && !Array.isArray(context.requestPayload)
          ? context.requestPayload
          : {};

      const forceRefresh = requestPayload.forceRefresh !== false;
      const source = String(requestPayload.source || "workflow").trim().slice(0, 80) || "workflow";
      const nowIso = new Date().toISOString();
      const dateKey = utcDateKey(nowIso);
      const { supabaseUrl, supabaseServiceRoleKey } = getSupabaseConfig();

      const challenge = await context.run("resolve-daily-challenge", async () => {
        return resolveDailyChallenge({
          supabaseUrl,
          supabaseServiceRoleKey,
          dateKey,
          nowIso,
          forceRefresh
        });
      });

      await context.run("prepare-next-daily-challenge", async () => {
        await prepareNextDailyChallenge({
          supabaseUrl,
          supabaseServiceRoleKey,
          currentChallenge: challenge,
          nowIso
        });
        return {
          ok: true
        };
      });

      return {
        ok: true,
        source,
        date_key: dateKey,
        challenge_id: challenge?.id || null,
        challenge_specialty: challenge?.specialty || null,
        challenge_difficulty: challenge?.difficulty || null
      };
    }, { retries: 2 })
  );
} else {
  app.post(DAILY_WORKFLOW_ROUTE_PATH, (req, res) => {
    return res.status(503).json({
      error: "QStash workflow yapılandırması eksik."
    });
  });
}

app.get("/", (req, res) => {
  const appStoreUrl =
    sanitizePublicHttpUrl(process.env.IOS_APP_STORE_URL || "") ||
    "https://apps.apple.com";
  const testFlightUrl =
    sanitizePublicHttpUrl(process.env.IOS_TESTFLIGHT_URL || "") ||
    "https://testflight.apple.com";

  const html = `<!doctype html>
<html lang="tr">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>Dr.Kynox Backend</title>
  <style>
    :root {
      color-scheme: light;
      --bg: #f8fafc;
      --surface: #ffffff;
      --text: #0f172a;
      --muted: #475569;
      --primary: #1d6fe8;
      --ok: #0d9e6e;
      --error: #dc2626;
      --border: #dbe4ef;
    }
    * { box-sizing: border-box; }
    body {
      margin: 0;
      min-height: 100vh;
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
      background: var(--bg);
      color: var(--text);
      display: grid;
      place-items: center;
      padding: 20px;
    }
    .card {
      width: 100%;
      max-width: 620px;
      background: var(--surface);
      border: 1px solid var(--border);
      border-radius: 18px;
      padding: 24px;
      box-shadow: 0 10px 30px rgba(15, 23, 42, 0.06);
    }
    h1 {
      margin: 0 0 6px;
      font-size: 30px;
      line-height: 1.15;
    }
    .subtitle {
      margin: 0 0 20px;
      color: var(--muted);
      font-size: 16px;
      line-height: 1.55;
    }
    .row {
      display: grid;
      grid-template-columns: 1fr 1fr;
      gap: 10px;
      margin-bottom: 18px;
    }
    .btn {
      min-height: 48px;
      border-radius: 12px;
      border: 1px solid transparent;
      text-decoration: none;
      display: inline-flex;
      align-items: center;
      justify-content: center;
      font-weight: 600;
      font-size: 15px;
      cursor: pointer;
    }
    .btn-primary {
      background: var(--primary);
      color: #fff;
    }
    .btn-secondary {
      background: #fff;
      border-color: var(--border);
      color: var(--text);
    }
    .status {
      border: 1px solid var(--border);
      border-radius: 12px;
      padding: 14px 14px;
      margin-bottom: 12px;
      display: flex;
      align-items: center;
      gap: 10px;
    }
    .dot {
      width: 12px;
      height: 12px;
      border-radius: 999px;
      background: #94a3b8;
      flex: 0 0 auto;
    }
    .meta {
      font-size: 13px;
      color: var(--muted);
      line-height: 1.5;
      margin-top: 8px;
    }
    code {
      background: #f1f5f9;
      border: 1px solid #e2e8f0;
      padding: 1px 6px;
      border-radius: 6px;
      font-size: 12px;
    }
    @media (max-width: 560px) {
      .row { grid-template-columns: 1fr; }
    }
  </style>
</head>
<body>
  <main class="card">
    <h1>Dr.Kynox</h1>
    <p class="subtitle">iOS uygulamasını indirip giriş yap. Bu sayfa backend durumunu canlı gösterir.</p>

    <div class="row">
      <a class="btn btn-primary" href="${appStoreUrl}" target="_blank" rel="noopener noreferrer">App Store'dan indir</a>
      <a class="btn btn-secondary" href="${testFlightUrl}" target="_blank" rel="noopener noreferrer">TestFlight ile dene</a>
    </div>

    <section class="status" id="healthBox">
      <span class="dot" id="healthDot"></span>
      <div>
        <strong id="healthTitle">Backend durumu kontrol ediliyor...</strong>
        <div class="meta" id="healthMeta">Lütfen bekle</div>
      </div>
    </section>

    <div class="meta">
      Güvenlik nedeniyle teknik endpoint adresleri bu sayfada paylaşılmaz.
    </div>
  </main>

  <script>
    (async function () {
      const dot = document.getElementById("healthDot");
      const title = document.getElementById("healthTitle");
      const meta = document.getElementById("healthMeta");
      try {
        const res = await fetch("/api/health", { cache: "no-store" });
        const payload = await res.json();
        if (res.ok && payload && payload.ok) {
          dot.style.background = getComputedStyle(document.documentElement).getPropertyValue('--ok').trim() || "#0d9e6e";
          title.textContent = "Backend çalışıyor";
          meta.textContent = "Sunucu zamanı: " + (payload.timestamp || "-");
        } else {
          dot.style.background = getComputedStyle(document.documentElement).getPropertyValue('--error').trim() || "#dc2626";
          title.textContent = "Backend hata veriyor";
          meta.textContent = "Durum kodu: " + res.status;
        }
      } catch (error) {
        dot.style.background = getComputedStyle(document.documentElement).getPropertyValue('--error').trim() || "#dc2626";
        title.textContent = "Backend'e erişilemiyor";
        meta.textContent = "Ağ hatası: " + (error && error.message ? error.message : "bilinmiyor");
      }
    })();
  </script>
</body>
</html>`;

  return res.status(200).set("Content-Type", "text/html; charset=utf-8").send(html);
});

function noStoreAdminResponse(res) {
  res.setHeader("Cache-Control", "no-store, max-age=0");
  res.setHeader("Pragma", "no-cache");
}

function requireAdminPageSession(req, res, next) {
  const session = extractAdminSession(req);
  if (!session) {
    const nextPath = encodeURIComponent(String(req.originalUrl || "/admin/dashboard"));
    return res.redirect(302, `/admin/login?next=${nextPath}`);
  }
  req.adminSession = session;
  return next();
}

function requireAdminApiSession(req, res, next) {
  const session = extractAdminSession(req);
  if (!session) {
    return res.status(401).json({
      error: "Admin oturumu gerekli."
    });
  }
  req.adminSession = session;
  return next();
}

function buildAdminAiPromptCatalog() {
  refreshEnv();
  const resolvedModels = {
    OPENAI_MODEL: String(process.env.OPENAI_MODEL || "gpt-5-mini"),
    OPENAI_SCORE_MODEL: String(process.env.OPENAI_SCORE_MODEL || "gpt-4.1-nano"),
    OPENAI_SCORE_RETRY_MODEL: String(process.env.OPENAI_SCORE_RETRY_MODEL || "gpt-4.1-mini"),
    OPENAI_DAILY_CHALLENGE_MODEL: String(process.env.OPENAI_DAILY_CHALLENGE_MODEL || "gpt-4.1-mini"),
    OPENAI_FLASHCARD_MODEL: String(process.env.OPENAI_FLASHCARD_MODEL || "gpt-5-nano"),
    OPENAI_TEXT_AGENT_MODEL: String(process.env.OPENAI_TEXT_AGENT_MODEL || "gpt-4.1-mini")
  };

  return {
    catalog_version: AI_PROMPT_CATALOG_VERSION,
    generated_at: new Date().toISOString(),
    models: resolvedModels,
    flows: [
      {
        key: "score_feedback",
        label: "Skor ve Feedback",
        routes: ["POST /api/score"],
        prompt_version: SCORE_PROMPT_VERSION,
        models: [resolvedModels.OPENAI_SCORE_MODEL, resolvedModels.OPENAI_SCORE_RETRY_MODEL],
        output_schema: "medical_reasoning_score_result (json_schema, strict)",
        prompts: [
          {
            name: "rubric_prompt_default",
            text: defaultRubricPrompt
          },
          {
            name: "instructions",
            text: SCORE_SYSTEM_INSTRUCTIONS
          },
          {
            name: "repair_instructions",
            text: SCORE_REPAIR_INSTRUCTIONS
          },
          {
            name: "input_template",
            text:
              "{RUBRIC_PROMPT}\\n\\nFULL_CONVERSATION:\\n{TRANSCRIPT}\\n\\nUSER_ONLY_MESSAGES:\\n{USER_ONLY}\\n\\nMODE:\\n{voice|text}\\n\\nOPTIONAL_CASE_WRAPUP:\\n{WRAPUP}"
          }
        ]
      },
      {
        key: "flashcards_generation",
        label: "Flashcard Üretimi",
        routes: ["POST /api/flashcards/generate"],
        prompt_version: FLASHCARD_PROMPT_VERSION,
        models: [resolvedModels.OPENAI_FLASHCARD_MODEL],
        output_schema: "flashcard_generation_result (json_schema, strict)",
        prompts: [
          {
            name: "instructions",
            text: FLASHCARD_GENERATION_INSTRUCTIONS
          },
          {
            name: "input_template",
            text:
              "YAPILANDIRILMIS_VAKA_VERISI:\\n{specialty,difficulty,caseTitle,trueDiagnosis,userDiagnosis,overallScore,label,briefSummary,strong/improve lists,dimensions,nextPracticeSuggestions}\\n\\nMAKS_KART: {3..10}\\n3 ile 10 arasında kart üret. Her kart benzersiz olsun."
          }
        ]
      },
      {
        key: "weak_area_deterministic",
        label: "Zayıf Alan Analizi (Deterministik)",
        routes: ["GET /api/analytics/weak-areas"],
        prompt_version: WEAK_AREA_PROMPT_VERSION,
        models: [],
        output_schema: "deterministic_math",
        prompts: [
          {
            name: "calculation_rules",
            text:
              "Kullanıcı skorları normalize edilir (0-100), specialty ve boyut bazında ortalamalar hesaplanır, en düşük specialty + en zayıf boyut seçilerek öneri fallback metninden üretilir."
          }
        ]
      },
      {
        key: "daily_challenge_generation",
        label: "Günlük Vaka Üretimi",
        routes: ["GET /api/challenge/today (generation path)", "POST /api/admin/workflow/daily/trigger"],
        prompt_version: "daily-challenge-v1",
        models: [resolvedModels.OPENAI_DAILY_CHALLENGE_MODEL, resolvedModels.OPENAI_SCORE_MODEL, resolvedModels.OPENAI_MODEL],
        output_schema: "daily_challenge (json_schema, strict)",
        prompts: [
          {
            name: "instructions",
            text: DAILY_CHALLENGE_INSTRUCTIONS
          },
          {
            name: "input_template",
            text:
              "Tarih: {YYYY-MM-DD}\\nTürkiye Türkçesi ile günlük tek bir klinik vaka meydan okuması üret.\\n{diversify_rules}\\nDönüş JSON olsun."
          }
        ]
      },
      {
        key: "text_agent_start",
        label: "Text Agent Başlangıç Mesajı",
        routes: ["POST /api/text-agent/start"],
        prompt_version: "text-agent-start-v1",
        models: [resolvedModels.OPENAI_TEXT_AGENT_MODEL],
        output_schema: "plain_text",
        prompts: [
          {
            name: "instructions",
            text: TEXT_AGENT_START_INSTRUCTIONS
          },
          {
            name: "input_template",
            text:
              "Kullanıcı: {user_name}\\nSeçilen bölüm: {specialty}\\nSeçilen zorluk: {difficulty}\\nVaka açılışını şimdi üret."
          }
        ]
      },
      {
        key: "text_agent_reply",
        label: "Text Agent Mesaj Yanıtı",
        routes: ["POST /api/text-agent/reply"],
        prompt_version: "text-agent-reply-v1",
        models: [resolvedModels.OPENAI_TEXT_AGENT_MODEL],
        output_schema: "plain_text",
        prompts: [
          {
            name: "instructions",
            text: TEXT_AGENT_REPLY_INSTRUCTIONS
          },
          {
            name: "input_template",
            text:
              "Kullanıcı adı: {user_name}\\nBölüm: {specialty}\\nZorluk: {difficulty}\\nGeçmiş konuşma:\\n{conversation}\\n\\nKullanıcının son mesajı: {user_message}\\nSadece vaka rolünde yanıt üret."
          }
        ]
      }
    ]
  };
}

function renderAdminShell({ title, activePath, contentHtml, scriptsHtml = "", showTopMeta = true, csrfToken = "" }) {
  const navItems = [
    { href: "/admin/dashboard", label: "Dashboard" },
    { href: "/admin/analytics", label: "Analytics" },
    { href: "/admin/broadcast", label: "Duyuru / Push" },
    { href: "/admin/users", label: "Kullanıcılar" },
    { href: "/admin/sessions", label: "Sessionlar" },
    { href: "/admin/abuse", label: "Abuse Protection" },
    { href: "/admin/errors", label: "Hata Logları" },
    { href: "/admin/ai-prompts", label: "AI Promptlar" }
  ];
  const nav = navItems
    .map((item) => {
      const isActive = activePath === item.href;
      const klass = isActive
        ? "bg-blue-600 text-white"
        : "bg-white text-slate-700 border border-slate-200 hover:border-blue-300";
      return `<a href="${item.href}" class="rounded-xl px-3 py-2 text-sm font-semibold transition ${klass}">${item.label}</a>`;
    })
    .join("");

  return `<!doctype html>
<html lang="tr">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>${title}</title>
  <script src="https://cdn.tailwindcss.com"></script>
  <script>
    tailwind.config = {
      theme: {
        extend: {
          colors: {
            brand: {
              50: '#eff6ff',
              100: '#dbeafe',
              500: '#2563eb',
              600: '#1d4ed8'
            }
          }
        }
      }
    };
  </script>
</head>
<body class="bg-slate-50 text-slate-900 min-h-screen">
  <header class="border-b border-slate-200 bg-white/95 backdrop-blur sticky top-0 z-20">
    <div class="max-w-7xl mx-auto px-4 py-3 flex flex-col gap-3 md:flex-row md:items-center md:justify-between">
      <div>
        <p class="text-xs uppercase tracking-wide text-slate-500">Dr.Kynox Admin</p>
        <h1 class="text-xl font-bold">${title}</h1>
      </div>
      <div class="flex flex-wrap items-center gap-2">${nav}</div>
      <form id="logoutForm" class="ml-auto">
        <button type="submit" class="rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm font-semibold text-slate-700 hover:bg-slate-100">
          Çıkış Yap
        </button>
      </form>
    </div>
  </header>
  <main class="max-w-7xl mx-auto px-4 py-5 space-y-4">
    ${showTopMeta ? `<p class="text-sm text-slate-500">Admin paneline sadece doğrulanmış oturum çerezi ile erişilir.</p>` : ""}
    ${contentHtml}
  </main>
  <script>
    const __ADMIN_CSRF_TOKEN__ = ${JSON.stringify(String(csrfToken || ""))};
    window.__ADMIN_CSRF_TOKEN__ = __ADMIN_CSRF_TOKEN__;
    const __originalFetch__ = window.fetch.bind(window);
    window.fetch = (input, init = {}) => {
      const reqInit = { ...(init || {}) };
      const method = String(reqInit.method || 'GET').toUpperCase();
      const safeMethod = method === 'GET' || method === 'HEAD' || method === 'OPTIONS';
      if (!safeMethod && __ADMIN_CSRF_TOKEN__) {
        const headers = new Headers(reqInit.headers || {});
        if (!headers.has('x-csrf-token')) {
          headers.set('x-csrf-token', __ADMIN_CSRF_TOKEN__);
        }
        reqInit.headers = headers;
      }
      if (!reqInit.credentials) {
        reqInit.credentials = 'include';
      }
      return __originalFetch__(input, reqInit);
    };

    document.getElementById('logoutForm')?.addEventListener('submit', async (event) => {
      event.preventDefault();
      try {
        await fetch('/admin/logout', {
          method: 'POST',
          headers: { 'x-csrf-token': __ADMIN_CSRF_TOKEN__ || '' },
          credentials: 'include'
        });
      } catch {}
      window.location.href = '/admin/login';
    });
  </script>
  ${scriptsHtml}
</body>
</html>`;
}

function renderAdminLoginPage(nextPath = "/admin/dashboard", csrfToken = "") {
  const safeNext = normalizeAdminNextPath(nextPath);
  const safeCsrf = String(csrfToken || "").trim();
  return `<!doctype html>
<html lang="tr">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>Admin Giriş</title>
  <script src="https://cdn.tailwindcss.com"></script>
</head>
<body class="bg-slate-50 min-h-screen grid place-items-center p-4">
  <div class="w-full max-w-md rounded-2xl border border-slate-200 bg-white shadow-sm p-6">
    <h1 class="text-2xl font-bold mb-1">Admin Giriş</h1>
    <p class="text-sm text-slate-500 mb-5">Kullanıcı adı ve şifren ile giriş yap.</p>
    <form id="adminLoginForm" class="space-y-4">
      <input type="hidden" id="nextPath" value="${safeNext}" />
      <div>
        <label class="block text-sm font-medium mb-1 text-slate-700">Kullanıcı adı</label>
        <input id="username" class="w-full rounded-xl border border-slate-300 px-3 py-2 text-base outline-none focus:ring-2 focus:ring-blue-500" required />
      </div>
      <div>
        <label class="block text-sm font-medium mb-1 text-slate-700">Şifre</label>
        <input id="password" type="password" class="w-full rounded-xl border border-slate-300 px-3 py-2 text-base outline-none focus:ring-2 focus:ring-blue-500" required />
      </div>
      <button id="submitBtn" type="submit" class="w-full rounded-xl bg-blue-600 text-white font-semibold px-4 py-3 hover:bg-blue-700 transition">
        Giriş Yap
      </button>
      <p id="errorBox" class="hidden rounded-lg border border-red-200 bg-red-50 p-2 text-sm text-red-700"></p>
    </form>
  </div>
  <script>
    const form = document.getElementById('adminLoginForm');
    const errorBox = document.getElementById('errorBox');
    const submitBtn = document.getElementById('submitBtn');
    const csrfToken = ${JSON.stringify(safeCsrf)};
    form?.addEventListener('submit', async (event) => {
      event.preventDefault();
      errorBox.classList.add('hidden');
      submitBtn.disabled = true;
      submitBtn.textContent = 'Kontrol ediliyor...';
      try {
        const resp = await fetch('/admin/login', {
          method: 'POST',
          headers: {
            'Content-Type': 'application/json',
            'x-csrf-token': csrfToken
          },
          credentials: 'include',
          body: JSON.stringify({
            username: document.getElementById('username').value,
            password: document.getElementById('password').value,
            next: document.getElementById('nextPath').value,
            csrfToken
          })
        });
        const payload = await resp.json().catch(() => ({}));
        if (!resp.ok || !payload?.ok) {
          throw new Error(payload?.error || 'Giriş başarısız');
        }
        window.location.href = payload.redirectTo || '/admin/dashboard';
      } catch (error) {
        errorBox.textContent = error?.message || 'Giriş başarısız';
        errorBox.classList.remove('hidden');
      } finally {
        submitBtn.disabled = false;
        submitBtn.textContent = 'Giriş Yap';
      }
    });
  </script>
</body>
</html>`;
}

function renderAdminDashboardPage(csrfToken = "") {
  const content = `
    <section class="grid grid-cols-1 sm:grid-cols-2 xl:grid-cols-3 gap-4" id="overviewCards"></section>
    <section class="grid grid-cols-1 xl:grid-cols-5 gap-4">
      <article class="xl:col-span-3 rounded-2xl border border-slate-200 bg-white p-4">
        <div class="mb-3">
          <h2 class="text-lg font-semibold">Son 7 Gün Tamamlanan Vaka</h2>
          <p class="text-sm text-slate-500">Günlük tamamlanan vaka trendi (son 7 gün)</p>
        </div>
        <div id="lineChartRoot" class="h-72"></div>
        <div id="lineChartEmpty" class="hidden rounded-xl border border-slate-200 bg-slate-50 p-6 text-center text-sm text-slate-600">
          Bu aralıkta tamamlanan vaka verisi yok. İlk tamamlanan vakadan sonra grafik burada görünecek.
        </div>
      </article>
      <article class="xl:col-span-2 rounded-2xl border border-slate-200 bg-white p-4">
        <h2 class="text-lg font-semibold mb-1">API Trafik Özeti (Son 1 Saat)</h2>
        <p class="text-sm text-slate-500 mb-3">Top endpoint'ler, çağıran kimlikleri ve başarı/hata kırılımı</p>
        <div id="apiBreakdownRoot" class="space-y-3"></div>
      </article>
    </section>
    <section class="grid grid-cols-1 lg:grid-cols-2 gap-4">
      <article class="rounded-2xl border border-slate-200 bg-white p-4">
        <h2 class="text-lg font-semibold mb-1">Son Kayıt Olan Kullanıcılar</h2>
        <p class="text-sm text-slate-500 mb-3">En güncel profil kayıtları</p>
        <div id="latestUsersList" class="space-y-2"></div>
      </article>
      <article class="rounded-2xl border border-slate-200 bg-white p-4">
        <h2 class="text-lg font-semibold mb-1">Son Hatalar</h2>
        <p class="text-sm text-slate-500 mb-3">5xx yanıtları ve son hata akışı</p>
        <div id="recentErrorsList" class="space-y-2"></div>
      </article>
    </section>
    <section class="grid grid-cols-1 lg:grid-cols-2 gap-4">
      <article class="rounded-2xl border border-slate-200 bg-white p-4">
        <h2 class="text-lg font-semibold mb-1">ElevenLabs Agent Kullanımı</h2>
        <p class="text-sm text-slate-500 mb-3">Toplam ve son 1 saat session kullanım kırılımı</p>
        <div id="elevenUsageRoot" class="space-y-2"></div>
      </article>
      <article class="rounded-2xl border border-slate-200 bg-white p-4">
        <h2 class="text-lg font-semibold mb-1">Kullanıcı Sağlığı</h2>
        <p class="text-sm text-slate-500 mb-3">Doğrulama, aktiflik ve askı durum özeti</p>
        <div id="userHealthRoot" class="space-y-2"></div>
      </article>
    </section>
    <section class="rounded-2xl border border-slate-200 bg-white p-4">
      <h2 class="text-lg font-semibold mb-1">Rate Limit Detayı (Son 24 Saat)</h2>
      <p class="text-sm text-slate-500 mb-3">Aşımın iç trafik (admin/workflow/monitoring) mi yoksa dış trafik mi olduğunu buradan görürsün.</p>
      <div id="rateLimitInsightsRoot" class="space-y-3"></div>
    </section>
  `;
  const scripts = `
    <script src="https://unpkg.com/react@18/umd/react.production.min.js"></script>
    <script src="https://unpkg.com/react-dom@18/umd/react-dom.production.min.js"></script>
    <script src="https://unpkg.com/recharts/umd/Recharts.min.js"></script>
    <script>
      function escapeHtml(value) {
        return String(value || '')
          .replaceAll('&', '&amp;')
          .replaceAll('<', '&lt;')
          .replaceAll('>', '&gt;')
          .replaceAll('"', '&quot;')
          .replaceAll("'", '&#39;');
      }

      function toNumber(value, fallback = 0) {
        const n = Number(value);
        return Number.isFinite(n) ? n : fallback;
      }

      function formatAgo(timestamp) {
        const iso = String(timestamp || '');
        if (!iso) return '-';
        const ts = Date.parse(iso);
        if (!Number.isFinite(ts)) return '-';
        const diff = Math.max(0, Date.now() - ts);
        const sec = Math.floor(diff / 1000);
        if (sec < 60) return sec + ' sn önce';
        const min = Math.floor(sec / 60);
        if (min < 60) return min + ' dk önce';
        const hour = Math.floor(min / 60);
        if (hour < 24) return hour + ' sa önce';
        const day = Math.floor(hour / 24);
        return day + ' gün önce';
      }

      async function loadOverview() {
        const resp = await fetch('/api/admin/panel/stats/overview', { credentials: 'include', cache: 'no-store' });
        if (!resp.ok) throw new Error('Overview alınamadı');
        return resp.json();
      }

      function card(options) {
        const title = escapeHtml(options?.title || '-');
        const value = escapeHtml(options?.value || '0');
        const subtitle = escapeHtml(options?.subtitle || '');
        const icon = escapeHtml(options?.icon || '📊');
        const tone = String(options?.tone || 'neutral');
        const tones = {
          success: 'border-emerald-200 bg-emerald-50',
          warning: 'border-amber-200 bg-amber-50',
          danger: 'border-rose-200 bg-rose-50',
          info: 'border-blue-200 bg-blue-50',
          neutral: 'border-slate-200 bg-white'
        };
        const valueColor = tone === 'danger' ? 'text-rose-700' : tone === 'warning' ? 'text-amber-700' : tone === 'success' ? 'text-emerald-700' : 'text-slate-900';
        const klass = tones[tone] || tones.neutral;
        return '<article class="rounded-2xl border p-4 ' + klass + '">' +
          '<p class="text-sm font-medium text-slate-600">' + icon + ' ' + title + '</p>' +
          '<p class="mt-1 text-3xl font-bold ' + valueColor + '">' + value + '</p>' +
          '<p class="mt-2 text-xs text-slate-600 min-h-[18px]">' + subtitle + '</p>' +
        '</article>';
      }

      function renderChart(series) {
        const rootEl = document.getElementById('lineChartRoot');
        const emptyEl = document.getElementById('lineChartEmpty');
        if (!rootEl || !window.Recharts || !window.React || !window.ReactDOM) return;
        const normalizedSeries = Array.isArray(series) ? series : [];
        const hasAnyData = normalizedSeries.some((item) => toNumber(item?.value, 0) > 0);
        if (!hasAnyData) {
          rootEl.innerHTML = '';
          rootEl.classList.add('hidden');
          emptyEl?.classList.remove('hidden');
          return;
        }
        rootEl.classList.remove('hidden');
        emptyEl?.classList.add('hidden');
        const root = rootEl.__chartRoot || ReactDOM.createRoot(rootEl);
        rootEl.__chartRoot = root;
        const { ResponsiveContainer, LineChart, Line, CartesianGrid, XAxis, YAxis, Tooltip } = Recharts;
        const chart = React.createElement(
          ResponsiveContainer,
          { width: '100%', height: '100%' },
          React.createElement(
            LineChart,
            { data: series, margin: { top: 10, right: 20, left: 0, bottom: 0 } },
            React.createElement(CartesianGrid, { strokeDasharray: '3 3', stroke: '#e2e8f0' }),
            React.createElement(XAxis, { dataKey: 'label', tick: { fontSize: 12 } }),
            React.createElement(YAxis, { allowDecimals: false, tick: { fontSize: 12 } }),
            React.createElement(Tooltip, { formatter: (v) => [v, 'Vaka'] }),
            React.createElement(Line, { type: 'monotone', dataKey: 'value', stroke: '#2563eb', strokeWidth: 3, dot: { r: 4 } })
          )
        );
        root.render(chart);
      }

      function renderApiBreakdown(breakdown) {
        const root = document.getElementById('apiBreakdownRoot');
        if (!root) return;
        const data = breakdown && typeof breakdown === 'object' ? breakdown : {};
        const total = toNumber(data.total, 0);
        const success = toNumber(data.success, 0);
        const error = toNumber(data.error, 0);
        const successRate = total > 0 ? Math.round((success / total) * 100) : 0;
        const topEndpoints = Array.isArray(data.topEndpoints) ? data.topEndpoints.slice(0, 5) : [];
        const topCallers = Array.isArray(data.topCallers) ? data.topCallers.slice(0, 4) : [];
        const endpointRows = topEndpoints.length
          ? topEndpoints.map((item) => {
              const method = escapeHtml(item?.method || 'GET');
              const path = escapeHtml(item?.path || '/');
              const itemTotal = toNumber(item?.total, 0);
              const itemSuccess = toNumber(item?.success, 0);
              const itemError = toNumber(item?.error, 0);
              return '<div class="rounded-xl border border-slate-200 bg-slate-50 px-3 py-2 text-sm">' +
                '<div class="font-semibold text-slate-800">' + method + ' ' + path + '</div>' +
                '<div class="text-slate-600 text-xs mt-1">Toplam: ' + itemTotal + ' · Başarılı: ' + itemSuccess + ' · Hata: ' + itemError + '</div>' +
              '</div>';
            }).join('')
          : '<div class="rounded-xl border border-slate-200 bg-slate-50 px-3 py-2 text-sm text-slate-600">Son 1 saatte API çağrısı kaydı yok.</div>';

        const callerRows = topCallers.length
          ? topCallers.map((item) => {
              const caller = escapeHtml(item?.callerLabel || item?.caller || 'ip#unknown');
              const itemTotal = toNumber(item?.total, 0);
              const itemError = toNumber(item?.error, 0);
              return '<div class="flex items-center justify-between text-xs border-b border-slate-100 py-1">' +
                '<span class="text-slate-600">' + caller + '</span>' +
                '<strong class="' + (itemError > 0 ? 'text-rose-700' : 'text-slate-700') + '">' + itemTotal + ' (' + itemError + ' hata)</strong>' +
              '</div>';
            }).join('')
          : '<div class="text-xs text-slate-500">Çağıran kırılım verisi yok.</div>';

        root.innerHTML =
          '<div class="rounded-xl border border-slate-200 bg-slate-50 p-3">' +
            '<div class="text-sm font-semibold text-slate-800">Toplam trafik: ' + total + '</div>' +
            '<div class="mt-1 text-xs text-slate-600">Başarılı: ' + success + ' · Hata: ' + error + ' · Başarı oranı: %' + successRate + '</div>' +
            '<div class="mt-1 text-xs text-slate-500">Endpoint: ' + toNumber(data.endpointCount, 0) + ' · Çağıran: ' + toNumber(data.callerCount, 0) + '</div>' +
          '</div>' +
          '<div>' +
            '<p class="text-xs uppercase tracking-wide text-slate-500 mb-2">Top Endpointler</p>' +
            '<div class="space-y-2">' + endpointRows + '</div>' +
          '</div>' +
          '<div>' +
            '<p class="text-xs uppercase tracking-wide text-slate-500 mb-1">Top Çağıranlar</p>' +
            '<div class="rounded-xl border border-slate-200 bg-white px-3 py-2">' + callerRows + '</div>' +
          '</div>';
      }

      function renderLatestUsers(users) {
        const root = document.getElementById('latestUsersList');
        if (!root) return;
        const rows = Array.isArray(users) ? users.slice(0, 6) : [];
        if (!rows.length) {
          root.innerHTML = '<div class="rounded-xl border border-slate-200 bg-slate-50 px-3 py-2 text-sm text-slate-600">Henüz kullanıcı kaydı görünmüyor.</div>';
          return;
        }
        root.innerHTML = rows.map((row) => {
          const name = escapeHtml(row?.full_name || '-');
          const email = escapeHtml(row?.email || '-');
          const role = escapeHtml(row?.role || '-');
          const updated = formatAgo(row?.updated_at);
          return '<article class="rounded-xl border border-slate-200 bg-slate-50 p-3">' +
            '<div class="flex items-start justify-between gap-3">' +
              '<div>' +
                '<div class="font-semibold text-slate-800">' + name + '</div>' +
                '<div class="text-xs text-slate-600 mt-0.5">' + email + '</div>' +
                '<div class="text-xs text-slate-500 mt-1">Rol: ' + role + '</div>' +
              '</div>' +
              '<span class="text-xs text-slate-500 whitespace-nowrap">' + escapeHtml(updated) + '</span>' +
            '</div>' +
          '</article>';
        }).join('');
      }

      function renderRecentErrors(errors) {
        const root = document.getElementById('recentErrorsList');
        if (!root) return;
        const rows = Array.isArray(errors) ? errors.slice(0, 6) : [];
        if (!rows.length) {
          root.innerHTML = '<div class="rounded-xl border border-emerald-200 bg-emerald-50 px-3 py-2 text-sm text-emerald-700">Son hata kaydı yok.</div>';
          return;
        }
        root.innerHTML = rows.map((row) => {
          const method = escapeHtml(row?.method || 'GET');
          const path = escapeHtml(row?.path || '/');
          const status = toNumber(row?.status, 500);
          const latency = toNumber(row?.latencyMs, 0);
          const when = formatAgo(row?.timestamp);
          return '<article class="rounded-xl border border-rose-200 bg-rose-50 p-3">' +
            '<div class="font-semibold text-rose-800">' + method + ' ' + path + '</div>' +
            '<div class="text-xs text-rose-700 mt-1">HTTP ' + status + ' · ' + latency + 'ms · ' + escapeHtml(when) + '</div>' +
          '</article>';
        }).join('');
      }

      function renderElevenUsage(usage) {
        const root = document.getElementById('elevenUsageRoot');
        if (!root) return;
        const safeUsage = usage && typeof usage === 'object' ? usage : {};
        const totalSessions = toNumber(safeUsage.totalSessions, 0);
        const lastHourSessions = toNumber(safeUsage.lastHourSessions, 0);
        const agents = Array.isArray(safeUsage.agents) ? safeUsage.agents.slice(0, 6) : [];
        const rows = agents.length
          ? agents.map((item) => {
              const name = escapeHtml(item?.agentName || item?.agentId || 'Bilinmeyen Agent');
              const total = toNumber(item?.total, 0);
              const hour = toNumber(item?.lastHour, 0);
              return '<div class="rounded-xl border border-slate-200 bg-slate-50 px-3 py-2 text-sm">' +
                '<div class="font-semibold text-slate-800">' + name + '</div>' +
                '<div class="text-xs text-slate-600 mt-1">Toplam: ' + total + ' · Son 1 saat: ' + hour + '</div>' +
              '</div>';
            }).join('')
          : '<div class="rounded-xl border border-slate-200 bg-slate-50 px-3 py-2 text-sm text-slate-600">Agent kullanım verisi henüz yok.</div>';
        root.innerHTML =
          '<div class="rounded-xl border border-slate-200 bg-slate-50 px-3 py-3 text-sm">' +
            '<div class="font-semibold text-slate-800">Toplam session: ' + totalSessions + '</div>' +
            '<div class="text-xs text-slate-600 mt-1">Son 1 saat session: ' + lastHourSessions + '</div>' +
          '</div>' +
          rows;
      }

      function renderUserHealth(data) {
        const root = document.getElementById('userHealthRoot');
        if (!root) return;
        const total = toNumber(data?.totalUsers, 0);
        const confirmed = toNumber(data?.confirmedUsers, 0);
        const unconfirmed = toNumber(data?.unconfirmedUsers, 0);
        const suspended = toNumber(data?.suspendedUsers, 0);
        const active24h = toNumber(data?.activeUsersLast24h, 0);
        const confirmRate = total > 0 ? Math.round((confirmed / total) * 100) : 0;
        const activeRate = total > 0 ? Math.round((active24h / total) * 100) : 0;
        root.innerHTML = [
          '<div class="rounded-xl border border-slate-200 bg-slate-50 px-3 py-2 text-sm"><span class="text-slate-600">Doğrulanmış kullanıcı</span><div class="font-semibold text-slate-900">' + confirmed + ' / ' + total + ' (%' + confirmRate + ')</div></div>',
          '<div class="rounded-xl border border-slate-200 bg-slate-50 px-3 py-2 text-sm"><span class="text-slate-600">Doğrulanmamış kullanıcı</span><div class="font-semibold ' + (unconfirmed > 0 ? 'text-amber-700' : 'text-slate-900') + '">' + unconfirmed + '</div></div>',
          '<div class="rounded-xl border border-slate-200 bg-slate-50 px-3 py-2 text-sm"><span class="text-slate-600">Son 24s aktif</span><div class="font-semibold text-emerald-700">' + active24h + ' (%' + activeRate + ')</div></div>',
          '<div class="rounded-xl border border-slate-200 bg-slate-50 px-3 py-2 text-sm"><span class="text-slate-600">Askıya alınmış</span><div class="font-semibold ' + (suspended > 0 ? 'text-rose-700' : 'text-slate-900') + '">' + suspended + '</div></div>'
        ].join('');
      }

      function renderRateLimitInsights(insights) {
        const root = document.getElementById('rateLimitInsightsRoot');
        if (!root) return;
        const data = insights && typeof insights === 'object' ? insights : {};
        const categories = data.categories && typeof data.categories === 'object' ? data.categories : {};
        const internal = toNumber(categories.internal, 0);
        const monitoring = toNumber(categories.monitoring, 0);
        const external = toNumber(categories.external, 0);
        const unknown = toNumber(categories.unknown, 0);
        const total = toNumber(data.sampledRows, 0);
        const diagnosis = escapeHtml(data.diagnosis || 'Detay bulunamadı.');
        const topScopes = Array.isArray(data.topScopes) ? data.topScopes.slice(0, 6) : [];
        const topEndpoints = Array.isArray(data.topEndpoints) ? data.topEndpoints.slice(0, 6) : [];

        const scopeRows = topScopes.length
          ? topScopes.map((item) => {
              const key = escapeHtml(item?.key || '-');
              const count = toNumber(item?.count, 0);
              const label = escapeHtml(item?.sourceLabel || '-');
              return '<div class="flex items-center justify-between rounded-lg border border-slate-200 bg-slate-50 px-3 py-2 text-xs">' +
                '<div><div class="font-semibold text-slate-800">' + key + '</div><div class="text-slate-500 mt-0.5">Kaynak: ' + label + '</div></div>' +
                '<strong class="text-slate-700">' + count + '</strong>' +
              '</div>';
            }).join('')
          : '<div class="rounded-lg border border-slate-200 bg-slate-50 px-3 py-2 text-xs text-slate-500">Top scope verisi yok.</div>';

        const endpointRows = topEndpoints.length
          ? topEndpoints.map((item) => {
              const key = escapeHtml(item?.key || '-');
              const count = toNumber(item?.count, 0);
              const label = escapeHtml(item?.sourceLabel || '-');
              return '<div class="flex items-center justify-between rounded-lg border border-slate-200 bg-slate-50 px-3 py-2 text-xs">' +
                '<div><div class="font-semibold text-slate-800">' + key + '</div><div class="text-slate-500 mt-0.5">Kaynak: ' + label + '</div></div>' +
                '<strong class="text-slate-700">' + count + '</strong>' +
              '</div>';
            }).join('')
          : '<div class="rounded-lg border border-slate-200 bg-slate-50 px-3 py-2 text-xs text-slate-500">Top endpoint verisi yok.</div>';

        root.innerHTML =
          '<div class="grid grid-cols-1 md:grid-cols-4 gap-2">' +
            '<div class="rounded-xl border border-blue-200 bg-blue-50 px-3 py-2 text-xs"><div class="text-blue-700">İç trafik</div><div class="mt-1 text-lg font-bold text-blue-800">' + internal + '</div></div>' +
            '<div class="rounded-xl border border-violet-200 bg-violet-50 px-3 py-2 text-xs"><div class="text-violet-700">Monitoring</div><div class="mt-1 text-lg font-bold text-violet-800">' + monitoring + '</div></div>' +
            '<div class="rounded-xl border border-amber-200 bg-amber-50 px-3 py-2 text-xs"><div class="text-amber-700">Dış trafik</div><div class="mt-1 text-lg font-bold text-amber-800">' + external + '</div></div>' +
            '<div class="rounded-xl border border-slate-200 bg-slate-50 px-3 py-2 text-xs"><div class="text-slate-600">Toplam örnek</div><div class="mt-1 text-lg font-bold text-slate-800">' + total + '</div></div>' +
          '</div>' +
          '<div class="rounded-xl border border-slate-200 bg-white px-3 py-2 text-sm text-slate-700">' + diagnosis + ' <span class="text-xs text-slate-500">(unknown: ' + unknown + ')</span></div>' +
          '<div class="grid grid-cols-1 lg:grid-cols-2 gap-3">' +
            '<div><p class="text-xs uppercase tracking-wide text-slate-500 mb-1">En çok scope</p><div class="space-y-2">' + scopeRows + '</div></div>' +
            '<div><p class="text-xs uppercase tracking-wide text-slate-500 mb-1">En çok endpoint</p><div class="space-y-2">' + endpointRows + '</div></div>' +
          '</div>';
      }

      let dashboardRefreshTimer = null;

      async function refreshDashboard() {
        const cards = document.getElementById('overviewCards');
        try {
          const data = await loadOverview();
          const apiBreakdown = data.apiRequestBreakdown && typeof data.apiRequestBreakdown === 'object'
            ? data.apiRequestBreakdown
            : { total: toNumber(data.apiRequestsLastHour, 0), success: 0, error: 0, endpointCount: 0, callerCount: 0, topEndpoints: [], topCallers: [] };
          const todayCompleted = toNumber(data.todayCompletedCases, 0);
          const totalCompleted = toNumber(data.totalCompletedCases, 0);
          const todayUsers = toNumber(data.todayUsers, 0);
          const apiErrors = toNumber(apiBreakdown.error, 0);
          const apiTone = apiErrors > 0 ? 'warning' : 'info';
          const rlInsights = data.rateLimitInsights && typeof data.rateLimitInsights === 'object' ? data.rateLimitInsights : {};
          const rlCats = rlInsights.categories && typeof rlInsights.categories === 'object' ? rlInsights.categories : {};
          const rlExternal = toNumber(rlCats.external, 0);
          const rlInternal = toNumber(rlCats.internal, 0) + toNumber(rlCats.monitoring, 0);
          cards.innerHTML = [
            card({ title: 'Toplam kullanıcı', value: toNumber(data.totalUsers, 0), subtitle: 'Kayıtlı toplam hesap', icon: '👥', tone: 'info' }),
            card({ title: 'Bugün kayıt', value: todayUsers, subtitle: todayUsers > 0 ? 'Bugün yeni kayıt var' : 'Bugün yeni kayıt yok', icon: '🆕', tone: todayUsers > 0 ? 'success' : 'neutral' }),
            card({ title: 'Toplam tamamlanan vaka', value: totalCompleted, subtitle: totalCompleted > 0 ? 'Kümülatif tamamlanan vaka' : 'Henüz tamamlanan vaka yok', icon: '✅', tone: totalCompleted > 0 ? 'info' : 'warning' }),
            card({ title: 'Bugün tamamlanan vaka', value: todayCompleted, subtitle: todayCompleted > 0 ? 'Güncel üretim aktif' : 'Bugün tamamlanan vaka yok', icon: '📅', tone: todayCompleted > 0 ? 'success' : 'danger' }),
            card({ title: 'Aktif session', value: toNumber(data.activeSessions?.total, 0), subtitle: 'Voice: ' + toNumber(data.activeSessions?.voice, 0) + ' · Text: ' + toNumber(data.activeSessions?.text, 0), icon: '🎙️', tone: toNumber(data.activeSessions?.total, 0) > 0 ? 'info' : 'neutral' }),
            card({ title: 'API trafiği (1s)', value: toNumber(apiBreakdown.total, 0), subtitle: 'Başarılı: ' + toNumber(apiBreakdown.success, 0) + ' · Hata: ' + toNumber(apiBreakdown.error, 0) + ' · RL 24s dış:' + rlExternal + ' iç:' + rlInternal, icon: '🌐', tone: apiTone }),
            card({ title: 'Doğrulanan hesap', value: toNumber(data.confirmedUsers, 0), subtitle: 'Doğrulanmamış: ' + toNumber(data.unconfirmedUsers, 0), icon: '📨', tone: toNumber(data.unconfirmedUsers, 0) > 0 ? 'warning' : 'success' }),
            card({ title: 'Askıdaki hesap', value: toNumber(data.suspendedUsers, 0), subtitle: 'Son 24s aktif kullanıcı: ' + toNumber(data.activeUsersLast24h, 0), icon: '🛡️', tone: toNumber(data.suspendedUsers, 0) > 0 ? 'warning' : 'neutral' }),
            card({ title: 'ElevenLabs oturum', value: toNumber(data.elevenLabsUsage?.totalSessions, 0), subtitle: 'Son 1s: ' + toNumber(data.elevenLabsUsage?.lastHourSessions, 0), icon: '🤖', tone: toNumber(data.elevenLabsUsage?.lastHourSessions, 0) > 0 ? 'info' : 'neutral' })
          ].join('');
          renderChart(Array.isArray(data.last7CaseSeries) ? data.last7CaseSeries : []);
          renderApiBreakdown(apiBreakdown);
          renderLatestUsers(Array.isArray(data.latestUsers) ? data.latestUsers : []);
          renderRecentErrors(Array.isArray(data.recentErrors) ? data.recentErrors : []);
          renderElevenUsage(data.elevenLabsUsage);
          renderUserHealth(data);
          renderRateLimitInsights(data.rateLimitInsights);
        } catch (error) {
          cards.innerHTML = '<article class="rounded-2xl border border-red-200 bg-red-50 p-4 text-red-700">Dashboard verisi alınamadı: ' + escapeHtml(error?.message || 'bilinmeyen hata') + '</article>';
          const apiRoot = document.getElementById('apiBreakdownRoot');
          if (apiRoot) {
            apiRoot.innerHTML = '<div class="rounded-xl border border-red-200 bg-red-50 px-3 py-2 text-sm text-red-700">API kırılımı alınamadı.</div>';
          }
          const usersRoot = document.getElementById('latestUsersList');
          if (usersRoot) {
            usersRoot.innerHTML = '<div class="rounded-xl border border-red-200 bg-red-50 px-3 py-2 text-sm text-red-700">Kullanıcı listesi alınamadı.</div>';
          }
          const errorsRoot = document.getElementById('recentErrorsList');
          if (errorsRoot) {
            errorsRoot.innerHTML = '<div class="rounded-xl border border-red-200 bg-red-50 px-3 py-2 text-sm text-red-700">Hata özeti alınamadı.</div>';
          }
          const elevenRoot = document.getElementById('elevenUsageRoot');
          if (elevenRoot) {
            elevenRoot.innerHTML = '<div class="rounded-xl border border-red-200 bg-red-50 px-3 py-2 text-sm text-red-700">ElevenLabs kullanım verisi alınamadı.</div>';
          }
          const healthRoot = document.getElementById('userHealthRoot');
          if (healthRoot) {
            healthRoot.innerHTML = '<div class="rounded-xl border border-red-200 bg-red-50 px-3 py-2 text-sm text-red-700">Kullanıcı sağlık özeti alınamadı.</div>';
          }
          const rlRoot = document.getElementById('rateLimitInsightsRoot');
          if (rlRoot) {
            rlRoot.innerHTML = '<div class="rounded-xl border border-red-200 bg-red-50 px-3 py-2 text-sm text-red-700">Rate limit detay verisi alınamadı.</div>';
          }
        }
      }

      function scheduleDashboardRefresh() {
        if (dashboardRefreshTimer) {
          clearInterval(dashboardRefreshTimer);
          dashboardRefreshTimer = null;
        }
        dashboardRefreshTimer = setInterval(() => {
          if (document.visibilityState === 'visible') {
            refreshDashboard().catch(() => {});
          }
        }, 5000);
      }

      refreshDashboard().catch(() => {});
      scheduleDashboardRefresh();

      document.addEventListener('visibilitychange', () => {
        if (document.visibilityState === 'visible') {
          refreshDashboard().catch(() => {});
        }
      });
    </script>
  `;
  return renderAdminShell({
    title: "Admin Dashboard",
    activePath: "/admin/dashboard",
    contentHtml: content,
    scriptsHtml: scripts,
    csrfToken
  });
}

function renderAdminAnalyticsPage(csrfToken = "") {
  const content = `
    <section class="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-4" id="analyticsSummaryCards"></section>
    <section class="grid grid-cols-1 lg:grid-cols-2 gap-4">
      <article class="rounded-2xl border border-slate-200 bg-white p-4 space-y-3">
        <h2 class="text-lg font-semibold">Text Agent Metrikleri</h2>
        <p class="text-sm text-slate-500">Toplam ve ortalama değerler oturum bazında hesaplanır.</p>
        <div id="textMetricsTable"></div>
      </article>
      <article class="rounded-2xl border border-slate-200 bg-white p-4 space-y-3">
        <h2 class="text-lg font-semibold">Voice Agent Metrikleri</h2>
        <p class="text-sm text-slate-500">Transkript kaynaklı kullanıcı metrikleri ve süre dağılımı.</p>
        <div id="voiceMetricsTable"></div>
      </article>
    </section>
    <section class="grid grid-cols-1 lg:grid-cols-2 gap-4">
      <article class="rounded-2xl border border-slate-200 bg-white p-4 space-y-3">
        <h2 class="text-lg font-semibold">Maliyet Hazırlık Katmanı</h2>
        <p class="text-sm text-slate-500">Şu an oranlar env üzerinden okunur. Değerler daha sonra gerçek maliyet hesabına bağlanabilir.</p>
        <div id="rateCardTable"></div>
      </article>
      <article class="rounded-2xl border border-slate-200 bg-white p-4 space-y-3">
        <h2 class="text-lg font-semibold">Cost Snapshot</h2>
        <p class="text-sm text-slate-500">Toplam maliyet, oturum başı ortalama maliyet ve voice/text split.</p>
        <div id="costSnapshotTable"></div>
      </article>
    </section>
    <section id="analyticsMetaInfo" class="rounded-2xl border border-slate-200 bg-white p-4 text-sm text-slate-600"></section>
  `;

  const scripts = `
    <script>
      function escapeHtml(value) {
        return String(value || '')
          .replaceAll('&', '&amp;')
          .replaceAll('<', '&lt;')
          .replaceAll('>', '&gt;')
          .replaceAll('"', '&quot;')
          .replaceAll("'", '&#39;');
      }

      function toNumber(value, fallback = 0) {
        const n = Number(value);
        return Number.isFinite(n) ? n : fallback;
      }

      function formatNumber(value, digits = 2) {
        return toNumber(value, 0).toLocaleString('tr-TR', {
          minimumFractionDigits: digits,
          maximumFractionDigits: digits
        });
      }

      function metricRow(label, totalValue, avgValue, unit = '') {
        const suffix = unit ? ' ' + unit : '';
        return '<tr class="border-b border-slate-100">' +
          '<td class="py-2 pr-2 text-slate-700">' + escapeHtml(label) + '</td>' +
          '<td class="py-2 pr-2 text-slate-900 font-semibold">' + escapeHtml(totalValue + suffix) + '</td>' +
          '<td class="py-2 text-slate-700">' + escapeHtml(avgValue + suffix) + '</td>' +
        '</tr>';
      }

      function renderSummaryCards(payload) {
        const root = document.getElementById('analyticsSummaryCards');
        if (!root) return;
        const totals = payload?.totals || {};
        const cards = [
          { title: 'Analiz Edilen Session', value: toNumber(totals.sessions, 0), subtitle: 'Toplam session satırı' },
          { title: 'Text Session', value: toNumber(totals.textSessions, 0), subtitle: 'Yazılı oturum adedi' },
          { title: 'Voice Session', value: toNumber(totals.voiceSessions, 0), subtitle: 'Sesli oturum adedi' },
          { title: 'Toplam Cost', value: '$' + formatNumber(totals?.cost?.total, 4), subtitle: 'Voice + Text toplamı' }
        ];
        root.innerHTML = cards.map((item) =>
          '<article class="rounded-2xl border border-slate-200 bg-white p-4">' +
            '<p class="text-xs uppercase tracking-wide text-slate-500">' + escapeHtml(item.title) + '</p>' +
            '<p class="mt-1 text-2xl font-bold text-slate-900">' + escapeHtml(String(item.value)) + '</p>' +
            '<p class="mt-1 text-xs text-slate-500">' + escapeHtml(item.subtitle) + '</p>' +
          '</article>'
        ).join('');
      }

      function renderTextMetrics(payload) {
        const root = document.getElementById('textMetricsTable');
        if (!root) return;
        const totals = payload?.totals?.text || {};
        const avg = payload?.averages?.text || {};
        root.innerHTML =
          '<table class="w-full text-sm">' +
            '<thead><tr class="text-left text-slate-500 border-b border-slate-200">' +
              '<th class="py-2 pr-2">Metric</th><th class="py-2 pr-2">Toplam</th><th class="py-2">Ortalama</th>' +
            '</tr></thead>' +
            '<tbody>' +
              metricRow('Session Duration', formatNumber(totals.durationMin, 2), formatNumber(avg.sessionDurationMin, 2), 'dk') +
              metricRow('User Message Count', formatNumber(totals.userMessages, 0), formatNumber(avg.userMessagesPerSession, 2)) +
              metricRow('User Character Count', formatNumber(totals.userChars, 0), formatNumber(avg.userCharsPerSession, 2), 'karakter') +
              metricRow('AI Message Count', formatNumber(totals.aiMessages, 0), formatNumber(avg.aiMessagesPerSession, 2)) +
              metricRow('AI Character Count', formatNumber(totals.aiChars, 0), formatNumber(avg.aiCharsPerSession, 2), 'karakter') +
            '</tbody>' +
          '</table>';
      }

      function renderVoiceMetrics(payload) {
        const root = document.getElementById('voiceMetricsTable');
        if (!root) return;
        const totals = payload?.totals?.voice || {};
        const avg = payload?.averages?.voice || {};
        root.innerHTML =
          '<table class="w-full text-sm">' +
            '<thead><tr class="text-left text-slate-500 border-b border-slate-200">' +
              '<th class="py-2 pr-2">Metric</th><th class="py-2 pr-2">Toplam</th><th class="py-2">Ortalama</th>' +
            '</tr></thead>' +
            '<tbody>' +
              metricRow('Session Duration', formatNumber(totals.durationMin, 2), formatNumber(avg.sessionDurationMin, 2), 'dk') +
              metricRow('User Transcript Message Count', formatNumber(totals.userTranscriptMessages, 0), formatNumber(avg.userTranscriptMessagesPerSession, 2)) +
              metricRow('User Transcript Character Count', formatNumber(totals.userTranscriptChars, 0), formatNumber(avg.userTranscriptCharsPerSession, 2), 'karakter') +
              metricRow('User Message Count', formatNumber(totals.userMessages, 0), formatNumber(avg.userMessagesPerSession, 2)) +
              metricRow('User Character Count', formatNumber(totals.userChars, 0), formatNumber(avg.userCharsPerSession, 2), 'karakter') +
              metricRow('AI Message Count', formatNumber(totals.aiMessages, 0), formatNumber(avg.aiMessagesPerSession, 2)) +
              metricRow('AI Character Count', formatNumber(totals.aiChars, 0), formatNumber(avg.aiCharsPerSession, 2), 'karakter') +
            '</tbody>' +
          '</table>';
      }

      function renderRateCard(payload) {
        const root = document.getElementById('rateCardTable');
        if (!root) return;
        const rates = payload?.rates || {};
        const voice = rates?.voice || {};
        const text = rates?.text || {};
        root.innerHTML =
          '<table class="w-full text-sm">' +
            '<thead><tr class="text-left text-slate-500 border-b border-slate-200">' +
              '<th class="py-2 pr-2">Mode</th><th class="py-2 pr-2">Cost/Minute</th><th class="py-2">Cost/Message</th>' +
            '</tr></thead>' +
            '<tbody>' +
              '<tr class="border-b border-slate-100"><td class="py-2 pr-2 font-semibold">Voice</td><td class="py-2 pr-2">$' + formatNumber(voice.perMinute, 6) + '</td><td class="py-2">$' + formatNumber(voice.perMessage, 6) + '</td></tr>' +
              '<tr><td class="py-2 pr-2 font-semibold">Text</td><td class="py-2 pr-2">$' + formatNumber(text.perMinute, 6) + '</td><td class="py-2">$' + formatNumber(text.perMessage, 6) + '</td></tr>' +
            '</tbody>' +
          '</table>';
      }

      function renderCostSnapshot(payload) {
        const root = document.getElementById('costSnapshotTable');
        if (!root) return;
        const totals = payload?.totals?.cost || {};
        const avg = payload?.averages?.cost || {};
        root.innerHTML =
          '<table class="w-full text-sm">' +
            '<tbody>' +
              '<tr class="border-b border-slate-100"><td class="py-2 pr-2 text-slate-700">Total Cost</td><td class="py-2 font-semibold text-slate-900">$' + formatNumber(totals.total, 4) + '</td></tr>' +
              '<tr class="border-b border-slate-100"><td class="py-2 pr-2 text-slate-700">Voice Split</td><td class="py-2 text-slate-900">$' + formatNumber(totals.voice, 4) + '</td></tr>' +
              '<tr class="border-b border-slate-100"><td class="py-2 pr-2 text-slate-700">Text Split</td><td class="py-2 text-slate-900">$' + formatNumber(totals.text, 4) + '</td></tr>' +
              '<tr class="border-b border-slate-100"><td class="py-2 pr-2 text-slate-700">Avg Cost / Session</td><td class="py-2 text-slate-900">$' + formatNumber(avg.perSessionAll, 4) + '</td></tr>' +
              '<tr class="border-b border-slate-100"><td class="py-2 pr-2 text-slate-700">Avg Cost / Text Session</td><td class="py-2 text-slate-900">$' + formatNumber(avg.perTextSession, 4) + '</td></tr>' +
              '<tr><td class="py-2 pr-2 text-slate-700">Avg Cost / Voice Session</td><td class="py-2 text-slate-900">$' + formatNumber(avg.perVoiceSession, 4) + '</td></tr>' +
            '</tbody>' +
          '</table>';
      }

      async function loadAnalytics() {
        const resp = await fetch('/api/admin/panel/stats/analytics', { credentials: 'include', cache: 'no-store' });
        const payload = await resp.json().catch(() => ({}));
        if (!resp.ok || !payload?.ok) {
          throw new Error(payload?.error || 'Analytics verisi alınamadı');
        }
        renderSummaryCards(payload);
        renderTextMetrics(payload);
        renderVoiceMetrics(payload);
        renderRateCard(payload);
        renderCostSnapshot(payload);
        const metaRoot = document.getElementById('analyticsMetaInfo');
        if (metaRoot) {
          metaRoot.textContent =
            'Generated: ' + String(payload.generatedAt || '-') +
            ' · Rows analyzed: ' + String(payload.rowsAnalyzed || 0);
        }
      }

      let analyticsRefreshTimer = null;

      async function refreshAnalytics() {
        try {
          await loadAnalytics();
          const root = document.getElementById('analyticsMetaInfo');
          if (root) {
            root.className = 'rounded-2xl border border-slate-200 bg-white p-4 text-sm text-slate-600';
          }
        } catch (error) {
          const root = document.getElementById('analyticsMetaInfo');
          if (root) {
            root.className = 'rounded-2xl border border-red-200 bg-red-50 p-4 text-sm text-red-700';
            root.textContent = 'Analytics verisi yüklenemedi: ' + (error?.message || 'bilinmeyen hata');
          }
        }
      }

      function scheduleAnalyticsRefresh() {
        if (analyticsRefreshTimer) {
          clearInterval(analyticsRefreshTimer);
          analyticsRefreshTimer = null;
        }
        analyticsRefreshTimer = setInterval(() => {
          if (document.visibilityState === 'visible') {
            refreshAnalytics().catch(() => {});
          }
        }, 10000);
      }

      refreshAnalytics().catch(() => {});
      scheduleAnalyticsRefresh();

      document.addEventListener('visibilitychange', () => {
        if (document.visibilityState === 'visible') {
          refreshAnalytics().catch(() => {});
        }
      });
    </script>
  `;

  return renderAdminShell({
    title: "Agent Analytics",
    activePath: "/admin/analytics",
    contentHtml: content,
    scriptsHtml: scripts,
    csrfToken
  });
}

function renderAdminBroadcastPage(csrfToken = "") {
  const content = `
    <section class="grid grid-cols-1 sm:grid-cols-2 xl:grid-cols-4 gap-4" id="broadcastCards"></section>
    <section class="grid grid-cols-1 xl:grid-cols-5 gap-4">
      <article class="xl:col-span-3 rounded-2xl border border-slate-200 bg-white p-4 space-y-4">
        <div>
          <h2 class="text-lg font-semibold">Push + In-App Duyuru Gönder</h2>
          <p class="text-sm text-slate-500">Sadece uygulaması olan ve bildirim izni aktif kullanıcılara gönderim yapılır.</p>
        </div>
        <form id="broadcastForm" class="space-y-3">
          <label class="block text-sm text-slate-700">Başlık
            <input id="broadcastTitle" maxlength="120" required class="mt-1 w-full rounded-xl border border-slate-300 px-3 py-2 outline-none focus:ring-2 focus:ring-blue-500" placeholder="Uygulama geri bildirimin önemli" />
          </label>
          <label class="block text-sm text-slate-700">Mesaj
            <textarea id="broadcastBody" maxlength="420" rows="4" required class="mt-1 w-full rounded-xl border border-slate-300 px-3 py-2 outline-none focus:ring-2 focus:ring-blue-500" placeholder="Dr.Kynox deneyimini 1 dakikada paylaşır mısın?"></textarea>
          </label>
          <div class="grid grid-cols-1 md:grid-cols-2 gap-3">
            <label class="block text-sm text-slate-700">Deep Link (opsiyonel)
              <input id="broadcastDeepLink" maxlength="300" class="mt-1 w-full rounded-xl border border-slate-300 px-3 py-2 outline-none focus:ring-2 focus:ring-blue-500" placeholder="drkynox://home?open=weekly" />
            </label>
            <label class="block text-sm text-slate-700">Geçerlilik (saat)
              <input id="broadcastExpiresHours" type="number" min="1" max="168" value="48" class="mt-1 w-full rounded-xl border border-slate-300 px-3 py-2 outline-none focus:ring-2 focus:ring-blue-500" />
            </label>
          </div>
          <div class="flex flex-wrap items-center gap-4 text-sm text-slate-700">
            <label class="inline-flex items-center gap-2">
              <input id="broadcastPushEnabled" type="checkbox" checked class="h-4 w-4 rounded border-slate-300 text-blue-600 focus:ring-blue-500" />
              Push gönder
            </label>
            <label class="inline-flex items-center gap-2">
              <input id="broadcastInAppEnabled" type="checkbox" checked class="h-4 w-4 rounded border-slate-300 text-blue-600 focus:ring-blue-500" />
              In-app banner göster
            </label>
          </div>
          <div class="flex items-center gap-3">
            <button id="broadcastSubmit" type="submit" class="rounded-xl bg-blue-600 text-white px-4 py-2.5 text-sm font-semibold hover:bg-blue-700 disabled:opacity-50 disabled:cursor-not-allowed">
              Duyuruyu Gönder
            </button>
            <p id="broadcastFormStatus" class="text-sm text-slate-600"></p>
          </div>
        </form>
      </article>
      <article class="xl:col-span-2 rounded-2xl border border-slate-200 bg-white p-4">
        <h2 class="text-lg font-semibold mb-1">Son Gönderimler</h2>
        <p class="text-sm text-slate-500 mb-3">Son 10 duyuru ve hedeflenen kullanıcı sayısı</p>
        <div id="recentBroadcastList" class="space-y-2"></div>
      </article>
    </section>
  `;

  const scripts = `
    <script>
      function escapeHtml(value) {
        return String(value || '')
          .replaceAll('&', '&amp;')
          .replaceAll('<', '&lt;')
          .replaceAll('>', '&gt;')
          .replaceAll('"', '&quot;')
          .replaceAll("'", '&#39;');
      }

      function toNumber(value, fallback = 0) {
        const n = Number(value);
        return Number.isFinite(n) ? n : fallback;
      }

      function card(title, value, subtitle, tone = 'neutral') {
        const tones = {
          neutral: 'border-slate-200 bg-white text-slate-900',
          success: 'border-emerald-200 bg-emerald-50 text-emerald-900',
          warning: 'border-amber-200 bg-amber-50 text-amber-900',
          danger: 'border-rose-200 bg-rose-50 text-rose-900',
          info: 'border-blue-200 bg-blue-50 text-blue-900'
        };
        const klass = tones[tone] || tones.neutral;
        return '<article class="rounded-2xl border p-4 ' + klass + '">' +
          '<p class="text-xs uppercase tracking-wide">' + escapeHtml(title) + '</p>' +
          '<p class="mt-1 text-2xl font-bold">' + escapeHtml(String(value)) + '</p>' +
          '<p class="mt-1 text-xs opacity-80">' + escapeHtml(subtitle || '') + '</p>' +
        '</article>';
      }

      async function loadOverview() {
        const resp = await fetch('/api/admin/panel/broadcast/overview', { credentials: 'include', cache: 'no-store' });
        const payload = await resp.json().catch(() => ({}));
        if (!resp.ok || !payload?.ok) {
          throw new Error(payload?.error || 'Broadcast overview alınamadı');
        }
        return payload;
      }

      function renderCards(payload) {
        const root = document.getElementById('broadcastCards');
        if (!root) return;
        const recipients = payload?.recipients || {};
        const apns = payload?.apns || {};
        const recent = Array.isArray(payload?.recent) ? payload.recent : [];
        const totalUsers = toNumber(recipients.pushUsers ?? recipients.users, 0);
        const inAppUsers = toNumber(recipients.inAppUsers, totalUsers);
        const totalDevices = toNumber(recipients.devices, 0);
        const apnsReady = Boolean(apns.ready);
        root.innerHTML = [
          card('Push Hedef Kullanıcı', totalUsers, 'Bildirim izni açık kullanıcı', totalUsers > 0 ? 'info' : 'warning'),
          card('In-App Hedef Kullanıcı', inAppUsers, 'Onboarding tamamlayan kullanıcı', inAppUsers > 0 ? 'info' : 'warning'),
          card('Hedef Cihaz', totalDevices, 'iOS device token adedi', totalDevices > 0 ? 'info' : 'warning'),
          card('APNs Durumu', apnsReady ? 'Hazır' : 'Eksik', apnsReady ? 'Push gönderime hazır' : 'APNS env eksik', apnsReady ? 'success' : 'danger'),
          card('Son Gönderim', recent[0]?.created_at ? new Date(recent[0].created_at).toLocaleString('tr-TR') : '-', recent[0]?.title || 'Henüz yok', 'neutral'),
        ].join('');
      }

      function renderRecent(payload) {
        const root = document.getElementById('recentBroadcastList');
        if (!root) return;
        const rows = Array.isArray(payload?.recent) ? payload.recent : [];
        if (!rows.length) {
          root.innerHTML = '<div class="rounded-xl border border-slate-200 bg-slate-50 px-3 py-2 text-sm text-slate-600">Henüz gönderim yok.</div>';
          return;
        }
        root.innerHTML = rows.map((item) => {
          const title = escapeHtml(item?.title || '-');
          const body = escapeHtml(item?.body || '-');
          const createdAt = item?.created_at ? new Date(item.created_at).toLocaleString('tr-TR') : '-';
          const count = toNumber(item?.targets_count, 0);
          const channels = (item?.push_enabled ? 'Push' : '') + (item?.in_app_enabled ? (item?.push_enabled ? ' + In-App' : 'In-App') : '');
          return '<article class="rounded-xl border border-slate-200 bg-slate-50 p-3">' +
            '<div class="flex items-start justify-between gap-3">' +
              '<div>' +
                '<div class="font-semibold text-slate-800">' + title + '</div>' +
                '<div class="text-xs text-slate-600 mt-0.5">' + body + '</div>' +
                '<div class="text-xs text-slate-500 mt-1">' + escapeHtml(channels || '-') + ' · Hedef: ' + count + '</div>' +
              '</div>' +
              '<span class="text-xs text-slate-500 whitespace-nowrap">' + escapeHtml(createdAt) + '</span>' +
            '</div>' +
          '</article>';
        }).join('');
      }

      async function refreshOverview() {
        try {
          const payload = await loadOverview();
          renderCards(payload);
          renderRecent(payload);
        } catch (error) {
          const root = document.getElementById('broadcastCards');
          if (root) {
            root.innerHTML = '<article class="rounded-2xl border border-red-200 bg-red-50 p-4 text-red-700">Broadcast overview alınamadı: ' + escapeHtml(error?.message || 'bilinmeyen hata') + '</article>';
          }
        }
      }

      const form = document.getElementById('broadcastForm');
      const submitBtn = document.getElementById('broadcastSubmit');
      const statusBox = document.getElementById('broadcastFormStatus');

      form?.addEventListener('submit', async (event) => {
        event.preventDefault();
        const title = document.getElementById('broadcastTitle')?.value || '';
        const body = document.getElementById('broadcastBody')?.value || '';
        const deepLink = document.getElementById('broadcastDeepLink')?.value || '';
        const expiresHours = toNumber(document.getElementById('broadcastExpiresHours')?.value, 48);
        const pushEnabled = Boolean(document.getElementById('broadcastPushEnabled')?.checked);
        const inAppEnabled = Boolean(document.getElementById('broadcastInAppEnabled')?.checked);
        statusBox.textContent = '';

        submitBtn.disabled = true;
        submitBtn.textContent = 'Gönderiliyor...';
        try {
          const resp = await fetch('/api/admin/panel/broadcast/send', {
            method: 'POST',
            headers: {
              'Content-Type': 'application/json',
              'x-csrf-token': window.__ADMIN_CSRF_TOKEN__ || ''
            },
            credentials: 'include',
            body: JSON.stringify({
              title,
              body,
              deepLink,
              expiresHours,
              pushEnabled,
              inAppEnabled
            })
          });
          const payload = await resp.json().catch(() => ({}));
          if (!resp.ok || !payload?.ok) {
            throw new Error(payload?.error || 'Gönderim başarısız');
          }
          const pushSent = toNumber(payload?.push?.sent, 0);
          const pushFailed = toNumber(payload?.push?.failed, 0);
          const users = toNumber(payload?.targets?.users, 0);
          const pushUsers = toNumber(payload?.targets?.pushUsers, 0);
          const inAppUsers = toNumber(payload?.targets?.inAppUsers, 0);
          statusBox.textContent = 'Gönderildi. Hedef: ' + users + ' · Push hedef: ' + pushUsers + ' · In-app hedef: ' + inAppUsers + ' · Push başarılı: ' + pushSent + ' · Push hata: ' + pushFailed;
          form.reset();
          document.getElementById('broadcastPushEnabled').checked = true;
          document.getElementById('broadcastInAppEnabled').checked = true;
          document.getElementById('broadcastExpiresHours').value = '48';
          await refreshOverview();
        } catch (error) {
          statusBox.textContent = 'Hata: ' + (error?.message || 'bilinmeyen hata');
        } finally {
          submitBtn.disabled = false;
          submitBtn.textContent = 'Duyuruyu Gönder';
        }
      });

      let refreshTimer = null;
      function scheduleRefresh() {
        if (refreshTimer) clearInterval(refreshTimer);
        refreshTimer = setInterval(() => {
          if (document.visibilityState === 'visible') {
            refreshOverview().catch(() => {});
          }
        }, 10000);
      }

      refreshOverview().catch(() => {});
      scheduleRefresh();
      document.addEventListener('visibilitychange', () => {
        if (document.visibilityState === 'visible') {
          refreshOverview().catch(() => {});
        }
      });
    </script>
  `;

  return renderAdminShell({
    title: "Duyuru ve Push Yönetimi",
    activePath: "/admin/broadcast",
    contentHtml: content,
    scriptsHtml: scripts,
    csrfToken
  });
}

function renderAdminUsersPage(csrfToken = "") {
  const content = `
    <section class="grid grid-cols-1 sm:grid-cols-3 lg:grid-cols-6 gap-4" id="userCards"></section>
    <section class="rounded-2xl border border-slate-200 bg-white p-4 space-y-4">
      <div>
        <h2 class="text-lg font-semibold">Yeni Kullanıcı Ekle</h2>
        <p class="text-sm text-slate-500">Admin panelinden hesap oluştur, profili aynı adımda tanımla</p>
      </div>
      <form id="createUserForm" class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-4 gap-3">
        <label class="text-sm text-slate-600">Ad
          <input id="createFirstName" required class="mt-1 w-full rounded-xl border border-slate-300 px-3 py-2 text-sm outline-none focus:ring-2 focus:ring-blue-500" />
        </label>
        <label class="text-sm text-slate-600">Soyad
          <input id="createLastName" required class="mt-1 w-full rounded-xl border border-slate-300 px-3 py-2 text-sm outline-none focus:ring-2 focus:ring-blue-500" />
        </label>
        <label class="text-sm text-slate-600 lg:col-span-2">E-posta
          <input id="createEmail" type="email" required class="mt-1 w-full rounded-xl border border-slate-300 px-3 py-2 text-sm outline-none focus:ring-2 focus:ring-blue-500" />
        </label>
        <label class="text-sm text-slate-600">Geçici Şifre (opsiyonel)
          <input id="createPassword" type="text" placeholder="Boş bırakılırsa otomatik üretilir" class="mt-1 w-full rounded-xl border border-slate-300 px-3 py-2 text-sm outline-none focus:ring-2 focus:ring-blue-500" />
        </label>
        <label class="text-sm text-slate-600">Telefon
          <input id="createPhoneNumber" type="tel" placeholder="+90..." class="mt-1 w-full rounded-xl border border-slate-300 px-3 py-2 text-sm outline-none focus:ring-2 focus:ring-blue-500" />
        </label>
        <label class="text-sm text-slate-600">Rol
          <input id="createRole" placeholder="medical_student" class="mt-1 w-full rounded-xl border border-slate-300 px-3 py-2 text-sm outline-none focus:ring-2 focus:ring-blue-500" />
        </label>
        <label class="text-sm text-slate-600">Seviye
          <input id="createLearningLevel" placeholder="beginner/intermediate/advanced" class="mt-1 w-full rounded-xl border border-slate-300 px-3 py-2 text-sm outline-none focus:ring-2 focus:ring-blue-500" />
        </label>
        <label class="inline-flex items-center gap-2 text-sm text-slate-600">
          <input id="createEmailConfirmed" type="checkbox" class="h-4 w-4 rounded border-slate-300 text-blue-600 focus:ring-blue-500" />
          E-posta doğrulanmış başlat
        </label>
        <label class="inline-flex items-center gap-2 text-sm text-slate-600">
          <input id="createOnboardingCompleted" type="checkbox" class="h-4 w-4 rounded border-slate-300 text-blue-600 focus:ring-blue-500" />
          Onboarding tamamlandı
        </label>
        <label class="inline-flex items-center gap-2 text-sm text-slate-600">
          <input id="createMarketingOptIn" type="checkbox" class="h-4 w-4 rounded border-slate-300 text-blue-600 focus:ring-blue-500" />
          Marketing izni açık
        </label>
        <div class="flex items-end">
          <button id="createUserSubmitBtn" type="submit" class="w-full rounded-xl bg-blue-600 text-white px-4 py-2.5 text-sm font-semibold hover:bg-blue-700 disabled:cursor-not-allowed disabled:opacity-60">Kullanıcı Oluştur</button>
        </div>
      </form>
      <section id="createUserResultBox" class="hidden rounded-xl border px-3 py-3 text-sm"></section>
    </section>
    <section class="rounded-2xl border border-slate-200 bg-white p-4 space-y-4">
      <div class="flex flex-col gap-3 md:flex-row md:items-center md:justify-between">
        <div>
          <h2 class="text-lg font-semibold">Kullanıcı Listesi</h2>
          <p class="text-sm text-slate-500">Arama, sayfalama ve kullanıcı bazlı yönetim aksiyonları</p>
        </div>
        <form id="usersSearchForm" class="flex items-center gap-2">
          <input id="usersSearchInput" placeholder="Ad veya e-posta ara..." class="w-64 max-w-[60vw] rounded-xl border border-slate-300 px-3 py-2 text-sm outline-none focus:ring-2 focus:ring-blue-500" />
          <button type="submit" class="rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm font-semibold text-slate-700 hover:bg-slate-50">Ara</button>
          <button type="button" id="usersSearchClearBtn" class="rounded-xl border border-slate-200 bg-slate-50 px-3 py-2 text-sm font-medium text-slate-600 hover:bg-slate-100">Temizle</button>
        </form>
      </div>
      <div class="overflow-auto">
        <table class="w-full text-sm min-w-[1240px]">
          <thead class="text-left text-slate-500 border-b border-slate-200">
            <tr>
              <th class="py-2 pr-2">Ad</th>
              <th class="py-2 pr-2">E-posta</th>
              <th class="py-2 pr-2">Rol</th>
              <th class="py-2 pr-2">Seviye</th>
              <th class="py-2 pr-2">Vaka</th>
              <th class="py-2 pr-2">Ort. Skor</th>
              <th class="py-2 pr-2">E-posta Doğr.</th>
              <th class="py-2 pr-2">Durum</th>
              <th class="py-2 pr-2">Son Giriş</th>
              <th class="py-2 pr-2 text-right">İşlemler</th>
            </tr>
          </thead>
          <tbody id="usersTableBody" class="divide-y divide-slate-100"></tbody>
        </table>
      </div>
      <div class="flex items-center justify-between gap-3">
        <p id="usersPaginationInfo" class="text-xs text-slate-500"></p>
        <div class="flex items-center gap-2">
          <button id="usersPrevBtn" class="rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm font-semibold text-slate-700 hover:bg-slate-50">Önceki</button>
          <button id="usersNextBtn" class="rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm font-semibold text-slate-700 hover:bg-slate-50">Sonraki</button>
        </div>
      </div>
    </section>
    <section id="usersErrorBox" class="hidden rounded-2xl border border-red-200 bg-red-50 p-4 text-sm text-red-700"></section>
    <div id="userDetailModal" class="hidden fixed inset-0 z-40 bg-slate-950/30">
      <div class="absolute right-0 top-0 h-full w-full max-w-2xl bg-white shadow-2xl border-l border-slate-200 overflow-y-auto">
        <div class="sticky top-0 bg-white border-b border-slate-200 px-4 py-3 flex items-center justify-between">
          <h3 class="text-lg font-semibold">Kullanıcı Detayı</h3>
          <button id="detailCloseBtn" class="rounded-xl border border-slate-300 px-3 py-2 text-sm font-semibold text-slate-700 hover:bg-slate-50">Kapat</button>
        </div>
        <div id="userDetailContent" class="p-4 space-y-4"></div>
      </div>
    </div>
  `;
  const scripts = `
    <script>
      function escapeHtml(value) {
        return String(value || '')
          .replaceAll('&', '&amp;')
          .replaceAll('<', '&lt;')
          .replaceAll('>', '&gt;')
          .replaceAll('"', '&quot;')
          .replaceAll("'", '&#39;');
      }

      function toNumber(value, fallback = 0) {
        const n = Number(value);
        return Number.isFinite(n) ? n : fallback;
      }

      function formatDate(value) {
        const raw = String(value || '').trim();
        if (!raw) return 'Belirtilmemiş';
        const parsed = new Date(raw);
        if (!Number.isFinite(parsed.getTime())) return 'Belirtilmemiş';
        return parsed.toLocaleString('tr-TR', { year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit' });
      }

      function scoreBadge(score) {
        if (!Number.isFinite(Number(score))) {
          return '<span class="text-slate-500">Belirtilmemiş</span>';
        }
        const safe = toNumber(score, 0);
        const tone = safe >= 70 ? 'text-emerald-700 bg-emerald-50 border-emerald-200' : safe >= 40 ? 'text-amber-700 bg-amber-50 border-amber-200' : 'text-rose-700 bg-rose-50 border-rose-200';
        return '<span class="inline-flex items-center rounded-lg border px-2 py-1 text-xs font-semibold ' + tone + '">' + safe.toFixed(1) + '</span>';
      }

      const state = {
        page: 1,
        perPage: 12,
        totalPages: 1,
        total: 0,
        search: '',
        users: [],
        loading: false,
        currentDetailUserId: ''
      };

      const cards = document.getElementById('userCards');
      const tbody = document.getElementById('usersTableBody');
      const paginationInfo = document.getElementById('usersPaginationInfo');
      const prevBtn = document.getElementById('usersPrevBtn');
      const nextBtn = document.getElementById('usersNextBtn');
      const searchForm = document.getElementById('usersSearchForm');
      const searchInput = document.getElementById('usersSearchInput');
      const searchClearBtn = document.getElementById('usersSearchClearBtn');
      const errorBox = document.getElementById('usersErrorBox');
      const modal = document.getElementById('userDetailModal');
      const detailContent = document.getElementById('userDetailContent');
      const detailCloseBtn = document.getElementById('detailCloseBtn');
      const createUserForm = document.getElementById('createUserForm');
      const createUserResultBox = document.getElementById('createUserResultBox');
      const createUserSubmitBtn = document.getElementById('createUserSubmitBtn');
      const createFirstName = document.getElementById('createFirstName');
      const createLastName = document.getElementById('createLastName');
      const createEmail = document.getElementById('createEmail');
      const createPassword = document.getElementById('createPassword');
      const createPhoneNumber = document.getElementById('createPhoneNumber');
      const createRole = document.getElementById('createRole');
      const createLearningLevel = document.getElementById('createLearningLevel');
      const createEmailConfirmed = document.getElementById('createEmailConfirmed');
      const createOnboardingCompleted = document.getElementById('createOnboardingCompleted');
      const createMarketingOptIn = document.getElementById('createMarketingOptIn');

      function showCreateResult(message, type) {
        if (!createUserResultBox) return;
        const tone = String(type || 'info');
        const classes = tone === 'success'
          ? 'border-emerald-200 bg-emerald-50 text-emerald-800'
          : tone === 'error'
            ? 'border-red-200 bg-red-50 text-red-700'
            : 'border-slate-200 bg-slate-50 text-slate-700';
        createUserResultBox.className = 'rounded-xl border px-3 py-3 text-sm ' + classes;
        createUserResultBox.textContent = message || '';
        createUserResultBox.classList.remove('hidden');
      }

      function renderCards(data) {
        cards.innerHTML = [
          ['Toplam Profil', data.totalProfiles || 0],
          ['Toplam Auth Kullanıcı', data.totalUsers || 0],
          ['Doğrulanmış E-posta', data.confirmedUsers || 0],
          ['Doğrulanmamış E-posta', data.unconfirmedUsers || 0],
          ['Onboarding Tamamlayan', data.onboardingDone || 0],
          ['Askıya Alınmış', data.suspendedUsers || 0]
        ].map(([t, v]) => '<article class="rounded-2xl border border-slate-200 bg-white p-4"><p class="text-sm text-slate-500">' + escapeHtml(t) + '</p><p class="mt-1 text-3xl font-bold">' + escapeHtml(v) + '</p></article>').join('');
      }

      function renderTableRows() {
        const rows = Array.isArray(state.users) ? state.users : [];
        if (!rows.length) {
          tbody.innerHTML = '<tr><td colspan="10" class="py-6 text-center text-slate-500">Bu filtrede kullanıcı bulunamadı.</td></tr>';
          return;
        }
        tbody.innerHTML = rows.map((row) => {
          const userId = escapeHtml(row.id || '');
          const name = escapeHtml(row.display_name || row.full_name || 'Belirtilmemiş');
          const email = escapeHtml(row.email || 'Belirtilmemiş');
          const role = escapeHtml(row.role || 'Belirtilmemiş');
          const level = escapeHtml(row.learning_level || 'Belirtilmemiş');
          const caseCount = toNumber(row.case_count, 0);
          const emailConfirmed = row.email_confirmed_at ? 'Evet' : 'Hayır';
          const suspendedText = row.is_suspended ? 'Askıda' : 'Aktif';
          const suspendedClass = row.is_suspended ? 'text-rose-700' : 'text-emerald-700';
          return '<tr class="hover:bg-slate-50 cursor-pointer" data-user-id="' + userId + '">' +
            '<td class="py-3 pr-2 font-medium text-slate-800">' + name + '</td>' +
            '<td class="py-3 pr-2 text-slate-700">' + email + '</td>' +
            '<td class="py-3 pr-2 text-slate-700">' + role + '</td>' +
            '<td class="py-3 pr-2 text-slate-700">' + level + '</td>' +
            '<td class="py-3 pr-2 text-slate-700">' + caseCount + '</td>' +
            '<td class="py-3 pr-2">' + scoreBadge(row.average_score) + '</td>' +
            '<td class="py-3 pr-2 text-slate-700">' + emailConfirmed + '</td>' +
            '<td class="py-3 pr-2 font-semibold ' + suspendedClass + '">' + suspendedText + '</td>' +
            '<td class="py-3 pr-2 text-slate-600">' + escapeHtml(formatDate(row.last_sign_in_at)) + '</td>' +
            '<td class="py-3 pr-2 text-right">' +
              '<div class="inline-flex gap-1">' +
                '<button data-action="detail" data-user-id="' + userId + '" class="rounded-lg border border-slate-300 px-2 py-1 text-xs font-semibold text-slate-700 hover:bg-slate-100">Detay</button>' +
                '<button data-action="suspend" data-user-id="' + userId + '" class="rounded-lg border border-amber-300 bg-amber-50 px-2 py-1 text-xs font-semibold text-amber-800 hover:bg-amber-100">Askıya Al</button>' +
                '<button data-action="delete" data-user-id="' + userId + '" class="rounded-lg border border-rose-300 bg-rose-50 px-2 py-1 text-xs font-semibold text-rose-800 hover:bg-rose-100">Sil</button>' +
              '</div>' +
            '</td>' +
          '</tr>';
        }).join('');
      }

      function renderPagination() {
        paginationInfo.textContent = 'Toplam ' + state.total + ' kullanıcı · Sayfa ' + state.page + '/' + state.totalPages;
        prevBtn.disabled = state.page <= 1 || state.loading;
        nextBtn.disabled = state.page >= state.totalPages || state.loading;
      }

      async function loadUsers() {
        state.loading = true;
        errorBox.classList.add('hidden');
        try {
          const qs = new URLSearchParams({
            page: String(state.page),
            perPage: String(state.perPage),
            search: state.search
          });
          const resp = await fetch('/api/admin/panel/stats/users?' + qs.toString(), { credentials: 'include', cache: 'no-store' });
          const data = await resp.json().catch(() => ({}));
          if (!resp.ok || !data?.ok) {
            throw new Error(data?.error || 'Kullanıcı verisi alınamadı');
          }
          renderCards(data);
          state.users = Array.isArray(data.users) ? data.users : [];
          state.total = toNumber(data.pagination?.total, 0);
          state.totalPages = Math.max(1, toNumber(data.pagination?.totalPages, 1));
          state.page = Math.min(state.page, state.totalPages);
          renderTableRows();
          renderPagination();
        } catch (error) {
          cards.innerHTML = '';
          state.users = [];
          renderTableRows();
          renderPagination();
          errorBox.textContent = 'Kullanıcı verisi alınamadı: ' + (error?.message || 'bilinmeyen hata');
          errorBox.classList.remove('hidden');
        } finally {
          state.loading = false;
        }
      }

      function openModal() {
        modal.classList.remove('hidden');
        document.body.classList.add('overflow-hidden');
      }

      function closeModal() {
        modal.classList.add('hidden');
        detailContent.innerHTML = '';
        state.currentDetailUserId = '';
        document.body.classList.remove('overflow-hidden');
      }

      function renderRecentSessions(rows) {
        const items = Array.isArray(rows) ? rows : [];
        if (!items.length) {
          return '<div class="rounded-xl border border-slate-200 bg-slate-50 px-3 py-2 text-sm text-slate-600">Kullanıcının son vaka oturumu görünmüyor.</div>';
        }
        return '<div class="space-y-2">' + items.map((item) => {
          const status = escapeHtml(item?.status || 'Belirtilmemiş');
          const mode = escapeHtml(item?.mode || 'Belirtilmemiş');
          const specialty = escapeHtml(item?.specialty || 'Belirtilmemiş');
          const difficulty = escapeHtml(item?.difficulty || 'Belirtilmemiş');
          const score = Number.isFinite(Number(item?.score)) ? Number(item.score).toFixed(1) : 'Belirtilmemiş';
          return '<article class="rounded-xl border border-slate-200 bg-slate-50 p-3 text-sm">' +
            '<div class="flex items-center justify-between gap-3">' +
              '<strong class="text-slate-800">' + specialty + ' · ' + difficulty + '</strong>' +
              '<span class="text-xs text-slate-600">' + status + '</span>' +
            '</div>' +
            '<div class="mt-1 text-xs text-slate-600">Mod: ' + mode + ' · Skor: ' + score + '</div>' +
            '<div class="mt-1 text-xs text-slate-500">Başlangıç: ' + escapeHtml(formatDate(item?.created_at)) + '</div>' +
          '</article>';
        }).join('') + '</div>';
      }

      async function loadUserDetail(userId) {
        if (!userId) return;
        state.currentDetailUserId = userId;
        openModal();
        detailContent.innerHTML = '<div class="rounded-xl border border-slate-200 bg-slate-50 px-3 py-3 text-sm text-slate-600">Detay yükleniyor...</div>';
        try {
          const resp = await fetch('/api/admin/panel/users/' + encodeURIComponent(userId), { credentials: 'include', cache: 'no-store' });
          const data = await resp.json().catch(() => ({}));
          if (!resp.ok || !data?.ok) {
            throw new Error(data?.error || 'Kullanıcı detayı alınamadı');
          }
          const user = data.user || {};
          const stats = data.caseStats || {};
          const isSuspended = Boolean(user.is_suspended);
          detailContent.innerHTML =
            '<section class="rounded-xl border border-slate-200 bg-white p-4">' +
              '<h4 class="text-base font-semibold text-slate-900 mb-2">' + escapeHtml(user.display_name || 'Belirtilmemiş') + '</h4>' +
              '<div class="grid grid-cols-1 sm:grid-cols-2 gap-2 text-sm">' +
                '<div><span class="text-slate-500">E-posta:</span> ' + escapeHtml(user.email || 'Belirtilmemiş') + '</div>' +
                '<div><span class="text-slate-500">Telefon:</span> ' + escapeHtml(user.phone_number || 'Belirtilmemiş') + '</div>' +
                '<div><span class="text-slate-500">Rol:</span> ' + escapeHtml(user.role || 'Belirtilmemiş') + '</div>' +
                '<div><span class="text-slate-500">Seviye:</span> ' + escapeHtml(user.learning_level || 'Belirtilmemiş') + '</div>' +
                '<div><span class="text-slate-500">Onboarding:</span> ' + (user.onboarding_completed ? 'Evet' : 'Hayır') + '</div>' +
                '<div><span class="text-slate-500">E-posta onayı:</span> ' + (user.email_confirmed_at ? 'Evet' : 'Hayır') + '</div>' +
                '<div><span class="text-slate-500">Son giriş:</span> ' + escapeHtml(formatDate(user.last_sign_in_at)) + '</div>' +
                '<div><span class="text-slate-500">Kayıt tarihi:</span> ' + escapeHtml(formatDate(user.created_at)) + '</div>' +
                '<div><span class="text-slate-500">Profil güncelleme:</span> ' + escapeHtml(formatDate(user.updated_at)) + '</div>' +
                '<div><span class="text-slate-500">Durum:</span> ' + (isSuspended ? '<span class="text-rose-700 font-semibold">Askıda</span>' : '<span class="text-emerald-700 font-semibold">Aktif</span>') + '</div>' +
              '</div>' +
            '</section>' +
            '<section class="rounded-xl border border-slate-200 bg-white p-4">' +
              '<h4 class="text-base font-semibold text-slate-900 mb-2">Vaka Performansı</h4>' +
              '<div class="grid grid-cols-1 sm:grid-cols-3 gap-2 text-sm">' +
                '<div class="rounded-lg border border-slate-200 bg-slate-50 px-3 py-2"><div class="text-slate-500 text-xs">Tamamlanan vaka</div><div class="font-semibold text-slate-900">' + toNumber(stats.completedCases, 0) + '</div></div>' +
                '<div class="rounded-lg border border-slate-200 bg-slate-50 px-3 py-2"><div class="text-slate-500 text-xs">Ortalama skor</div><div class="font-semibold text-slate-900">' + (Number.isFinite(Number(stats.averageScore)) ? Number(stats.averageScore).toFixed(1) : 'Belirtilmemiş') + '</div></div>' +
                '<div class="rounded-lg border border-slate-200 bg-slate-50 px-3 py-2"><div class="text-slate-500 text-xs">Son tamamlanan</div><div class="font-semibold text-slate-900">' + escapeHtml(formatDate(stats.lastCompletedAt)) + '</div></div>' +
              '</div>' +
            '</section>' +
            '<section class="rounded-xl border border-slate-200 bg-white p-4">' +
              '<h4 class="text-base font-semibold text-slate-900 mb-2">Son Oturumlar</h4>' +
              renderRecentSessions(data.recentSessions) +
            '</section>' +
            '<section class="rounded-xl border border-slate-200 bg-white p-4">' +
              '<h4 class="text-base font-semibold text-slate-900 mb-2">Yönetim</h4>' +
              '<div class="flex flex-wrap gap-2">' +
                '<button id="detailSuspendBtn" class="rounded-xl border px-3 py-2 text-sm font-semibold ' + (isSuspended ? 'border-emerald-300 bg-emerald-50 text-emerald-800' : 'border-amber-300 bg-amber-50 text-amber-800') + '">' + (isSuspended ? 'Askıyı Kaldır' : '24s Askıya Al') + '</button>' +
                '<button id="detailDeleteBtn" class="rounded-xl border border-rose-300 bg-rose-50 px-3 py-2 text-sm font-semibold text-rose-800">Kullanıcıyı Sil</button>' +
              '</div>' +
            '</section>';

          const suspendBtn = document.getElementById('detailSuspendBtn');
          const deleteBtn = document.getElementById('detailDeleteBtn');
          suspendBtn?.addEventListener('click', async () => {
            await actionSuspend(userId, !isSuspended);
          });
          deleteBtn?.addEventListener('click', async () => {
            await actionDelete(userId);
          });
        } catch (error) {
          detailContent.innerHTML = '<article class="rounded-xl border border-red-200 bg-red-50 px-3 py-2 text-sm text-red-700">Detay alınamadı: ' + escapeHtml(error?.message || 'bilinmeyen hata') + '</article>';
        }
      }

      async function actionSuspend(userId, suspended) {
        const label = suspended ? 'Bu kullanıcıyı 24 saat askıya almak istiyor musun?' : 'Kullanıcının askı durumunu kaldırmak istiyor musun?';
        if (!window.confirm(label)) return;
        try {
          const resp = await fetch('/api/admin/panel/users/' + encodeURIComponent(userId) + '/suspend', {
            method: 'POST',
            credentials: 'include',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ suspended, hours: 24 })
          });
          const data = await resp.json().catch(() => ({}));
          if (!resp.ok || !data?.ok) throw new Error(data?.error || 'Askı işlemi başarısız');
          await loadUsers();
          if (state.currentDetailUserId === userId) {
            await loadUserDetail(userId);
          }
        } catch (error) {
          window.alert(error?.message || 'Askı işlemi başarısız');
        }
      }

      async function actionDelete(userId) {
        const approved = window.confirm('Bu kullanıcıyı kalıcı olarak silmek istiyor musun? Bu işlem geri alınamaz.');
        if (!approved) return;
        try {
          const resp = await fetch('/api/admin/panel/users/' + encodeURIComponent(userId), {
            method: 'DELETE',
            credentials: 'include'
          });
          const data = await resp.json().catch(() => ({}));
          if (!resp.ok || !data?.ok) throw new Error(data?.error || 'Silme işlemi başarısız');
          const warnings = Array.isArray(data.cleanupWarnings) ? data.cleanupWarnings.filter(Boolean) : [];
          if (warnings.length > 0) {
            window.alert('Kullanıcı silindi ancak bazı temizlik adımları uyarı verdi:\\n- ' + warnings.join('\\n- '));
          }
          if (state.currentDetailUserId === userId) {
            closeModal();
          }
          await loadUsers();
        } catch (error) {
          window.alert(error?.message || 'Silme işlemi başarısız');
        }
      }

      tbody?.addEventListener('click', async (event) => {
        const actionBtn = event.target?.closest?.('button[data-action]');
        const rowEl = event.target?.closest?.('tr[data-user-id]');
        const userId = actionBtn?.dataset?.userId || rowEl?.dataset?.userId || '';
        if (!userId) return;
        if (actionBtn) {
          event.stopPropagation();
          const action = String(actionBtn.dataset.action || '');
          if (action === 'detail') {
            await loadUserDetail(userId);
            return;
          }
          if (action === 'suspend') {
            await actionSuspend(userId, true);
            return;
          }
          if (action === 'delete') {
            await actionDelete(userId);
            return;
          }
        }
        if (rowEl) {
          await loadUserDetail(userId);
        }
      });

      searchForm?.addEventListener('submit', async (event) => {
        event.preventDefault();
        state.search = String(searchInput?.value || '').trim();
        state.page = 1;
        await loadUsers();
      });

      searchClearBtn?.addEventListener('click', async () => {
        state.search = '';
        if (searchInput) searchInput.value = '';
        state.page = 1;
        await loadUsers();
      });

      createUserForm?.addEventListener('submit', async (event) => {
        event.preventDefault();
        if (!createUserSubmitBtn) return;
        createUserSubmitBtn.disabled = true;
        createUserSubmitBtn.textContent = 'Oluşturuluyor...';
        showCreateResult('', 'info');
        createUserResultBox?.classList.add('hidden');

        const payload = {
          firstName: String(createFirstName?.value || '').trim(),
          lastName: String(createLastName?.value || '').trim(),
          email: String(createEmail?.value || '').trim(),
          password: String(createPassword?.value || '').trim(),
          phoneNumber: String(createPhoneNumber?.value || '').trim(),
          role: String(createRole?.value || '').trim(),
          learningLevel: String(createLearningLevel?.value || '').trim(),
          emailConfirmed: Boolean(createEmailConfirmed?.checked),
          onboardingCompleted: Boolean(createOnboardingCompleted?.checked),
          marketingOptIn: Boolean(createMarketingOptIn?.checked)
        };
        if (!payload.password) {
          delete payload.password;
        }
        if (!payload.phoneNumber) {
          delete payload.phoneNumber;
        }
        if (!payload.role) {
          delete payload.role;
        }
        if (!payload.learningLevel) {
          delete payload.learningLevel;
        }

        try {
          const resp = await fetch('/api/admin/panel/users', {
            method: 'POST',
            credentials: 'include',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify(payload)
          });
          const data = await resp.json().catch(() => ({}));
          if (!resp.ok || !data?.ok) {
            throw new Error(data?.error || 'Kullanıcı oluşturulamadı');
          }

          const generatedPassword = String(data?.generatedPassword || '').trim();
          if (generatedPassword) {
            showCreateResult('Kullanıcı oluşturuldu. Geçici şifre: ' + generatedPassword + ' (kullanıcıya güvenli kanaldan ilet).', 'success');
          } else {
            showCreateResult('Kullanıcı başarıyla oluşturuldu.', 'success');
          }
          createUserForm.reset();
          state.page = 1;
          await loadUsers();
          const createdId = String(data?.user?.id || '').trim();
          if (createdId) {
            await loadUserDetail(createdId);
          }
        } catch (error) {
          showCreateResult('Kullanıcı oluşturma hatası: ' + (error?.message || 'bilinmeyen hata'), 'error');
        } finally {
          createUserSubmitBtn.disabled = false;
          createUserSubmitBtn.textContent = 'Kullanıcı Oluştur';
        }
      });

      prevBtn?.addEventListener('click', async () => {
        if (state.page <= 1 || state.loading) return;
        state.page -= 1;
        await loadUsers();
      });

      nextBtn?.addEventListener('click', async () => {
        if (state.page >= state.totalPages || state.loading) return;
        state.page += 1;
        await loadUsers();
      });

      detailCloseBtn?.addEventListener('click', closeModal);
      modal?.addEventListener('click', (event) => {
        if (event.target === modal) {
          closeModal();
        }
      });

      loadUsers();
    </script>
  `;
  return renderAdminShell({
    title: "Kullanıcı İstatistikleri",
    activePath: "/admin/users",
    contentHtml: content,
    scriptsHtml: scripts,
    csrfToken
  });
}

function renderAdminSessionsPage(csrfToken = "") {
  const content = `
    <section class="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-4" id="sessionCards"></section>
    <section class="grid grid-cols-1 xl:grid-cols-5 gap-4">
      <article class="xl:col-span-3 rounded-2xl border border-slate-200 bg-white p-4">
        <div class="mb-3">
          <h2 class="text-lg font-semibold">API Trafiği (Son 24 Saat)</h2>
          <p class="text-sm text-slate-500">Saatlik istek dağılımı</p>
        </div>
        <div id="api24hChartRoot" class="h-72"></div>
        <div id="api24hChartEmpty" class="hidden rounded-xl border border-slate-200 bg-slate-50 p-6 text-center text-sm text-slate-600">
          Son 24 saatte API istek verisi yok.
        </div>
      </article>
      <article class="xl:col-span-2 rounded-2xl border border-slate-200 bg-white p-4">
        <h2 class="text-lg font-semibold mb-1">Endpoint Dağılımı (Son 1 Saat)</h2>
        <p class="text-sm text-slate-500 mb-3">“18 istek” hangi endpoint’ten geldiğini burada görürsün</p>
        <div id="endpointBreakdownList" class="space-y-2"></div>
      </article>
    </section>
    <section class="rounded-2xl border border-slate-200 bg-white p-4">
      <h2 class="text-lg font-semibold mb-1">Rate Limit Aşım Detayı (24 Saat)</h2>
      <p class="text-sm text-slate-500 mb-3">Aşım kayıtlarını iç trafik ve dış trafik olarak ayrıştırır.</p>
      <div id="sessionRateLimitInsightsRoot" class="space-y-3"></div>
    </section>
    <section class="rounded-2xl border border-slate-200 bg-white p-4">
      <h2 class="text-lg font-semibold mb-1">Son Sessionlar</h2>
      <p class="text-sm text-slate-500 mb-3">Kim, ne zaman bağlandı ve ne durumda</p>
      <div class="overflow-auto">
        <table class="w-full text-sm min-w-[1080px]">
          <thead class="text-left text-slate-500 border-b border-slate-200">
            <tr>
              <th class="py-2 pr-2">Kullanıcı</th>
              <th class="py-2 pr-2">E-posta</th>
              <th class="py-2 pr-2">Mod</th>
              <th class="py-2 pr-2">Durum</th>
              <th class="py-2 pr-2">Bölüm</th>
              <th class="py-2 pr-2">Zorluk</th>
              <th class="py-2 pr-2">Mesaj</th>
              <th class="py-2 pr-2">Skor</th>
              <th class="py-2 pr-2">Başlangıç</th>
              <th class="py-2 pr-2">Bitiş</th>
            </tr>
          </thead>
          <tbody id="sessionsTableBody" class="divide-y divide-slate-100"></tbody>
        </table>
      </div>
    </section>
    <section class="rounded-2xl border border-slate-200 bg-white p-4">
      <h2 class="text-lg font-semibold mb-3">ElevenLabs Agent Kullanımı</h2>
      <div id="agentUsageList" class="space-y-2 text-sm text-slate-700"></div>
    </section>
  `;
  const scripts = `
    <script src="https://unpkg.com/react@18/umd/react.production.min.js"></script>
    <script src="https://unpkg.com/react-dom@18/umd/react-dom.production.min.js"></script>
    <script src="https://unpkg.com/recharts/umd/Recharts.min.js"></script>
    <script>
      function escapeHtml(value) {
        return String(value || '')
          .replaceAll('&', '&amp;')
          .replaceAll('<', '&lt;')
          .replaceAll('>', '&gt;')
          .replaceAll('"', '&quot;')
          .replaceAll("'", '&#39;');
      }

      function toNumber(value, fallback = 0) {
        const n = Number(value);
        return Number.isFinite(n) ? n : fallback;
      }

      function formatDate(value) {
        const raw = String(value || '').trim();
        if (!raw) return 'Belirtilmemiş';
        const parsed = new Date(raw);
        if (!Number.isFinite(parsed.getTime())) return 'Belirtilmemiş';
        return parsed.toLocaleString('tr-TR', { year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit' });
      }

      function scoreBadge(score) {
        if (!Number.isFinite(Number(score))) {
          return '<span class="text-slate-500">Belirtilmemiş</span>';
        }
        const safe = toNumber(score, 0);
        const tone = safe >= 70 ? 'text-emerald-700 bg-emerald-50 border-emerald-200' : safe >= 40 ? 'text-amber-700 bg-amber-50 border-amber-200' : 'text-rose-700 bg-rose-50 border-rose-200';
        return '<span class="inline-flex items-center rounded-lg border px-2 py-1 text-xs font-semibold ' + tone + '">' + safe.toFixed(1) + '</span>';
      }

      function card(options) {
        const title = escapeHtml(options?.title || '-');
        const value = escapeHtml(options?.value || '0');
        const subtitle = escapeHtml(options?.subtitle || '');
        const icon = escapeHtml(options?.icon || '📊');
        const tone = String(options?.tone || 'neutral');
        const tones = {
          success: 'border-emerald-200 bg-emerald-50',
          warning: 'border-amber-200 bg-amber-50',
          danger: 'border-rose-200 bg-rose-50',
          info: 'border-blue-200 bg-blue-50',
          neutral: 'border-slate-200 bg-white'
        };
        const valueColor = tone === 'danger' ? 'text-rose-700' : tone === 'warning' ? 'text-amber-700' : tone === 'success' ? 'text-emerald-700' : 'text-slate-900';
        const klass = tones[tone] || tones.neutral;
        return '<article class="rounded-2xl border p-4 ' + klass + '">' +
          '<p class="text-sm font-medium text-slate-600">' + icon + ' ' + title + '</p>' +
          '<p class="mt-1 text-3xl font-bold ' + valueColor + '">' + value + '</p>' +
          '<p class="mt-2 text-xs text-slate-600 min-h-[18px]">' + subtitle + '</p>' +
        '</article>';
      }

      function renderApi24hChart(series) {
        const rootEl = document.getElementById('api24hChartRoot');
        const emptyEl = document.getElementById('api24hChartEmpty');
        if (!rootEl || !window.Recharts || !window.React || !window.ReactDOM) return;
        const normalizedSeries = Array.isArray(series) ? series : [];
        const hasAnyData = normalizedSeries.some((item) => toNumber(item?.value, 0) > 0);
        if (!hasAnyData) {
          rootEl.innerHTML = '';
          rootEl.classList.add('hidden');
          emptyEl?.classList.remove('hidden');
          return;
        }
        rootEl.classList.remove('hidden');
        emptyEl?.classList.add('hidden');
        const root = rootEl.__chartRoot || ReactDOM.createRoot(rootEl);
        rootEl.__chartRoot = root;
        const { ResponsiveContainer, BarChart, Bar, CartesianGrid, XAxis, YAxis, Tooltip } = Recharts;
        const compact = normalizedSeries.map((item) => ({
          ...item,
          shortLabel: String(item?.label || '').slice(-5)
        }));
        root.render(
          React.createElement(
            ResponsiveContainer,
            { width: '100%', height: '100%' },
            React.createElement(
              BarChart,
              { data: compact, margin: { top: 8, right: 12, left: 0, bottom: 0 } },
              React.createElement(CartesianGrid, { strokeDasharray: '3 3', stroke: '#e2e8f0' }),
              React.createElement(XAxis, { dataKey: 'shortLabel', tick: { fontSize: 11 } }),
              React.createElement(YAxis, { allowDecimals: false, tick: { fontSize: 11 } }),
              React.createElement(Tooltip, { formatter: (v) => [v, 'İstek'], labelFormatter: (_, payload) => payload?.[0]?.payload?.label || '' }),
              React.createElement(Bar, { dataKey: 'value', fill: '#2563eb', radius: [6, 6, 0, 0] })
            )
          )
        );
      }

      function renderEndpointBreakdown(breakdown) {
        const root = document.getElementById('endpointBreakdownList');
        if (!root) return;
        const data = breakdown && typeof breakdown === 'object' ? breakdown : {};
        const total = toNumber(data.total, 0);
        const success = toNumber(data.success, 0);
        const error = toNumber(data.error, 0);
        const topEndpoints = Array.isArray(data.topEndpoints) ? data.topEndpoints.slice(0, 10) : [];
        if (!topEndpoints.length) {
          root.innerHTML = '<div class="rounded-xl border border-slate-200 bg-slate-50 px-3 py-2 text-sm text-slate-600">Endpoint dağılım verisi henüz yok.</div>';
          return;
        }
        root.innerHTML =
          '<div class="rounded-xl border border-slate-200 bg-slate-50 px-3 py-2 text-xs text-slate-600">Toplam: ' + total + ' · Başarılı: ' + success + ' · Hata: ' + error + '</div>' +
          topEndpoints.map((item) => {
            const method = escapeHtml(item?.method || 'GET');
            const path = escapeHtml(item?.path || '/');
            const itemTotal = toNumber(item?.total, 0);
            const itemSuccess = toNumber(item?.success, 0);
            const itemError = toNumber(item?.error, 0);
            const tone = itemError > 0 ? 'border-amber-200 bg-amber-50' : 'border-slate-200 bg-slate-50';
            return '<article class="rounded-xl border px-3 py-2 text-sm ' + tone + '">' +
              '<div class="font-semibold text-slate-800">' + method + ' ' + path + '</div>' +
              '<div class="text-xs text-slate-600 mt-1">Toplam: ' + itemTotal + ' · Başarılı: ' + itemSuccess + ' · Hata: ' + itemError + '</div>' +
            '</article>';
          }).join('');
      }

      function renderSessionRateLimitInsights(insights) {
        const root = document.getElementById('sessionRateLimitInsightsRoot');
        if (!root) return;
        const data = insights && typeof insights === 'object' ? insights : {};
        const categories = data.categories && typeof data.categories === 'object' ? data.categories : {};
        const internal = toNumber(categories.internal, 0);
        const monitoring = toNumber(categories.monitoring, 0);
        const external = toNumber(categories.external, 0);
        const unknown = toNumber(categories.unknown, 0);
        const sampled = toNumber(data.sampledRows, 0);
        const diagnosis = escapeHtml(data.diagnosis || 'Detay verisi yok.');
        const topScopes = Array.isArray(data.topScopes) ? data.topScopes.slice(0, 6) : [];
        const topEndpoints = Array.isArray(data.topEndpoints) ? data.topEndpoints.slice(0, 6) : [];
        const recentEvents = Array.isArray(data.recentEvents) ? data.recentEvents.slice(0, 8) : [];

        const scopeRows = topScopes.length
          ? topScopes.map((item) => {
              return '<div class="flex items-center justify-between rounded-lg border border-slate-200 bg-slate-50 px-3 py-2 text-xs">' +
                '<div><div class="font-semibold text-slate-800">' + escapeHtml(item?.key || '-') + '</div><div class="text-slate-500 mt-0.5">' + escapeHtml(item?.sourceLabel || '-') + '</div></div>' +
                '<strong class="text-slate-700">' + toNumber(item?.count, 0) + '</strong>' +
              '</div>';
            }).join('')
          : '<div class="rounded-lg border border-slate-200 bg-slate-50 px-3 py-2 text-xs text-slate-500">Top scope verisi yok.</div>';

        const endpointRows = topEndpoints.length
          ? topEndpoints.map((item) => {
              return '<div class="flex items-center justify-between rounded-lg border border-slate-200 bg-slate-50 px-3 py-2 text-xs">' +
                '<div><div class="font-semibold text-slate-800">' + escapeHtml(item?.key || '-') + '</div><div class="text-slate-500 mt-0.5">' + escapeHtml(item?.sourceLabel || '-') + '</div></div>' +
                '<strong class="text-slate-700">' + toNumber(item?.count, 0) + '</strong>' +
              '</div>';
            }).join('')
          : '<div class="rounded-lg border border-slate-200 bg-slate-50 px-3 py-2 text-xs text-slate-500">Top endpoint verisi yok.</div>';

        const recentRows = recentEvents.length
          ? recentEvents.map((item) => {
              const ts = formatDate(item?.createdAt);
              return '<tr class="border-b border-slate-100">' +
                '<td class="py-2 pr-2">' + escapeHtml(ts) + '</td>' +
                '<td class="py-2 pr-2">' + escapeHtml(item?.scope || '-') + '</td>' +
                '<td class="py-2 pr-2">' + escapeHtml(item?.endpoint || '-') + '</td>' +
                '<td class="py-2 pr-2">' + escapeHtml(item?.sourceLabel || '-') + '</td>' +
                '<td class="py-2 pr-2 text-right font-semibold">' + toNumber(item?.requestCount, 0) + '</td>' +
              '</tr>';
            }).join('')
          : '<tr><td colspan="5" class="py-3 text-center text-slate-500">Son olay kaydı yok.</td></tr>';

        root.innerHTML =
          '<div class="grid grid-cols-1 sm:grid-cols-5 gap-2">' +
            '<div class="rounded-xl border border-blue-200 bg-blue-50 px-3 py-2 text-xs"><div class="text-blue-700">İç trafik</div><div class="mt-1 text-lg font-bold text-blue-800">' + internal + '</div></div>' +
            '<div class="rounded-xl border border-violet-200 bg-violet-50 px-3 py-2 text-xs"><div class="text-violet-700">Monitoring</div><div class="mt-1 text-lg font-bold text-violet-800">' + monitoring + '</div></div>' +
            '<div class="rounded-xl border border-amber-200 bg-amber-50 px-3 py-2 text-xs"><div class="text-amber-700">Dış trafik</div><div class="mt-1 text-lg font-bold text-amber-800">' + external + '</div></div>' +
            '<div class="rounded-xl border border-slate-200 bg-slate-50 px-3 py-2 text-xs"><div class="text-slate-600">Unknown</div><div class="mt-1 text-lg font-bold text-slate-800">' + unknown + '</div></div>' +
            '<div class="rounded-xl border border-slate-200 bg-slate-50 px-3 py-2 text-xs"><div class="text-slate-600">Örneklenen kayıt</div><div class="mt-1 text-lg font-bold text-slate-800">' + sampled + '</div></div>' +
          '</div>' +
          '<div class="rounded-xl border border-slate-200 bg-white px-3 py-2 text-sm text-slate-700">' + diagnosis + '</div>' +
          '<div class="grid grid-cols-1 xl:grid-cols-2 gap-3">' +
            '<div><p class="text-xs uppercase tracking-wide text-slate-500 mb-1">Top Scope</p><div class="space-y-2">' + scopeRows + '</div></div>' +
            '<div><p class="text-xs uppercase tracking-wide text-slate-500 mb-1">Top Endpoint</p><div class="space-y-2">' + endpointRows + '</div></div>' +
          '</div>' +
          '<div class="overflow-auto rounded-xl border border-slate-200">' +
            '<table class="w-full text-xs min-w-[760px]"><thead class="bg-slate-50 text-slate-600"><tr><th class="py-2 px-2 text-left">Zaman</th><th class="py-2 px-2 text-left">Scope</th><th class="py-2 px-2 text-left">Endpoint</th><th class="py-2 px-2 text-left">Kaynak</th><th class="py-2 px-2 text-right">Count</th></tr></thead><tbody>' + recentRows + '</tbody></table>' +
          '</div>';
      }

      function renderSessionsTable(rows) {
        const tbody = document.getElementById('sessionsTableBody');
        if (!tbody) return;
        const list = Array.isArray(rows) ? rows : [];
        if (!list.length) {
          tbody.innerHTML = '<tr><td colspan="10" class="py-6 text-center text-slate-500">Session kaydı bulunamadı.</td></tr>';
          return;
        }
        tbody.innerHTML = list.map((item) => {
          const modeRaw = String(item?.mode || '').toLowerCase();
          const modeLabel = modeRaw === 'voice' ? 'Sesli' : modeRaw === 'text' ? 'Yazılı' : 'Belirtilmemiş';
          const modeTone = modeRaw === 'voice' ? 'bg-blue-50 border-blue-200 text-blue-700' : 'bg-emerald-50 border-emerald-200 text-emerald-700';
          return '<tr>' +
            '<td class="py-3 pr-2 font-medium text-slate-800">' + escapeHtml(item?.user_name || 'Belirtilmemiş') + '</td>' +
            '<td class="py-3 pr-2 text-slate-700">' + escapeHtml(item?.email || 'Belirtilmemiş') + '</td>' +
            '<td class="py-3 pr-2"><span class="inline-flex items-center rounded-lg border px-2 py-1 text-xs font-semibold ' + modeTone + '">' + escapeHtml(modeLabel) + '</span></td>' +
            '<td class="py-3 pr-2 text-slate-700">' + escapeHtml(item?.status || 'Belirtilmemiş') + '</td>' +
            '<td class="py-3 pr-2 text-slate-700">' + escapeHtml(item?.specialty || 'Belirtilmemiş') + '</td>' +
            '<td class="py-3 pr-2 text-slate-700">' + escapeHtml(item?.difficulty || 'Belirtilmemiş') + '</td>' +
            '<td class="py-3 pr-2 text-slate-700">' + toNumber(item?.message_count, 0) + '</td>' +
            '<td class="py-3 pr-2">' + scoreBadge(item?.score) + '</td>' +
            '<td class="py-3 pr-2 text-slate-700">' + escapeHtml(formatDate(item?.started_at || item?.created_at)) + '</td>' +
            '<td class="py-3 pr-2 text-slate-700">' + escapeHtml(formatDate(item?.ended_at)) + '</td>' +
          '</tr>';
        }).join('');
      }

      let sessionsRefreshTimer = null;

      async function refreshSessionsPage() {
        const cards = document.getElementById('sessionCards');
        const list = document.getElementById('agentUsageList');
        try {
          const resp = await fetch('/api/admin/panel/stats/sessions', { credentials: 'include', cache: 'no-store' });
          const data = await resp.json();
          if (!resp.ok) throw new Error(data?.error || 'session stats alınamadı');
          const breakdown = data.apiRequestBreakdown && typeof data.apiRequestBreakdown === 'object' ? data.apiRequestBreakdown : { total: toNumber(data.apiRequestsLastHour, 0), success: 0, error: 0, topEndpoints: [] };
          const apiErrors = toNumber(breakdown.error, 0);
          const rlInsights = data.rateLimitInsights && typeof data.rateLimitInsights === 'object' ? data.rateLimitInsights : {};
          const rlCats = rlInsights.categories && typeof rlInsights.categories === 'object' ? rlInsights.categories : {};
          const rlExternal = toNumber(rlCats.external, 0);
          const rlInternal = toNumber(rlCats.internal, 0) + toNumber(rlCats.monitoring, 0);
          cards.innerHTML = [
            card({ title: 'Aktif Voice Session', value: toNumber(data.activeSessions?.voice, 0), subtitle: 'Canlı sesli vaka oturumları', icon: '🎤', tone: toNumber(data.activeSessions?.voice, 0) > 0 ? 'info' : 'neutral' }),
            card({ title: 'Aktif Text Session', value: toNumber(data.activeSessions?.text, 0), subtitle: 'Canlı yazılı vaka oturumları', icon: '⌨️', tone: toNumber(data.activeSessions?.text, 0) > 0 ? 'info' : 'neutral' }),
            card({ title: 'API istek (1s)', value: toNumber(data.apiRequestsLastHour, 0), subtitle: 'Endpoint sayısı: ' + toNumber(breakdown.endpointCount, 0) + ' · Hata: ' + apiErrors, icon: '🌐', tone: apiErrors > 0 ? 'warning' : 'info' }),
            card({ title: 'Rate limit ihlali (24s)', value: toNumber(data.rateLimitViolationsLast24h, 0), subtitle: 'Dış: ' + rlExternal + ' · İç/Monitor: ' + rlInternal, icon: '🛡️', tone: toNumber(data.rateLimitViolationsLast24h, 0) > 0 ? 'warning' : 'success' })
          ].join('');

          renderApi24hChart(Array.isArray(data.apiRequestsHourlySeries) ? data.apiRequestsHourlySeries : []);
          renderEndpointBreakdown(breakdown);
          renderSessionRateLimitInsights(data.rateLimitInsights);
          renderSessionsTable(Array.isArray(data.recentSessions) ? data.recentSessions : []);

          const agents = Array.isArray(data.elevenLabsUsage?.agents) ? data.elevenLabsUsage.agents : [];
          if (!agents.length) {
            list.innerHTML = '<div class="rounded-xl border border-slate-200 bg-slate-50 px-3 py-2">Agent kullanım verisi henüz yok.</div>';
          } else {
            list.innerHTML = agents.map((item) =>
              '<div class="rounded-xl border border-slate-200 px-3 py-2 flex items-center justify-between"><span>' +
              (item.agentId || '-') + '</span><strong>' + (item.totalSessions || 0) + ' session</strong></div>'
            ).join('');
          }
        } catch (error) {
          cards.innerHTML = '<article class="rounded-2xl border border-red-200 bg-red-50 p-4 text-red-700">Session verisi alınamadı: ' + escapeHtml(error?.message || 'hata') + '</article>';
          document.getElementById('endpointBreakdownList').innerHTML = '<div class="rounded-xl border border-red-200 bg-red-50 px-3 py-2 text-sm text-red-700">Endpoint dağılımı alınamadı.</div>';
          document.getElementById('sessionsTableBody').innerHTML = '<tr><td colspan="10" class="py-6 text-center text-red-700">Session listesi alınamadı.</td></tr>';
          document.getElementById('api24hChartRoot').innerHTML = '';
          const rlRoot = document.getElementById('sessionRateLimitInsightsRoot');
          if (rlRoot) {
            rlRoot.innerHTML = '<div class="rounded-xl border border-red-200 bg-red-50 px-3 py-2 text-sm text-red-700">Rate limit detay verisi alınamadı.</div>';
          }
          const emptyEl = document.getElementById('api24hChartEmpty');
          if (emptyEl) {
            emptyEl.textContent = 'Saatlik API grafiği alınamadı.';
            emptyEl.classList.remove('hidden');
          }
          list.innerHTML = '';
        }
      }

      function scheduleSessionsRefresh() {
        if (sessionsRefreshTimer) {
          clearInterval(sessionsRefreshTimer);
          sessionsRefreshTimer = null;
        }
        sessionsRefreshTimer = setInterval(() => {
          if (document.visibilityState === 'visible') {
            refreshSessionsPage().catch(() => {});
          }
        }, 5000);
      }

      refreshSessionsPage().catch(() => {});
      scheduleSessionsRefresh();

      document.addEventListener('visibilitychange', () => {
        if (document.visibilityState === 'visible') {
          refreshSessionsPage().catch(() => {});
        }
      });
    </script>
  `;
  return renderAdminShell({
    title: "Session ve Kullanım",
    activePath: "/admin/sessions",
    contentHtml: content,
    scriptsHtml: scripts,
    csrfToken
  });
}

function renderAdminAbusePage(csrfToken = "") {
  const content = `
    <section class="grid grid-cols-1 sm:grid-cols-2 xl:grid-cols-5 gap-4" id="abuseSummaryCards"></section>
    <section class="grid grid-cols-1 xl:grid-cols-2 gap-4">
      <article class="rounded-2xl border border-slate-200 bg-white p-4 space-y-3">
        <div>
          <h2 class="text-lg font-semibold">Rate Limit Kaynak Analizi</h2>
          <p class="text-sm text-slate-500">İç trafik, monitoring ve dış trafik dağılımı</p>
        </div>
        <div id="abuseRateLimitRoot" class="space-y-3"></div>
      </article>
      <article class="rounded-2xl border border-slate-200 bg-white p-4 space-y-3">
        <div>
          <h2 class="text-lg font-semibold">Brute Force Blokları</h2>
          <p class="text-sm text-slate-500">Aktif bloklar ve scope bazlı yoğunluk</p>
        </div>
        <div id="abuseBruteForceRoot" class="space-y-3"></div>
      </article>
    </section>
    <section class="grid grid-cols-1 xl:grid-cols-2 gap-4">
      <article class="rounded-2xl border border-slate-200 bg-white p-4 space-y-3">
        <div>
          <h2 class="text-lg font-semibold">Suspicious Activity</h2>
          <p class="text-sm text-slate-500">Eşik aşımı kaynaklı güvenlik olayları</p>
        </div>
        <div id="abuseSuspiciousRoot" class="space-y-3"></div>
      </article>
      <article class="rounded-2xl border border-slate-200 bg-white p-4 space-y-3">
        <div>
          <h2 class="text-lg font-semibold">API Trafik Dağılımı (Son 1 Saat)</h2>
          <p class="text-sm text-slate-500">En yoğun endpoint ve caller kırılımı</p>
        </div>
        <div id="abuseTrafficRoot" class="space-y-3"></div>
      </article>
    </section>
    <section id="abuseMetaInfo" class="rounded-2xl border border-slate-200 bg-white p-4 text-sm text-slate-600"></section>
  `;

  const scripts = `
    <script>
      function escapeHtml(value) {
        return String(value || '')
          .replaceAll('&', '&amp;')
          .replaceAll('<', '&lt;')
          .replaceAll('>', '&gt;')
          .replaceAll('"', '&quot;')
          .replaceAll("'", '&#39;');
      }

      function toNumber(value, fallback = 0) {
        const n = Number(value);
        return Number.isFinite(n) ? n : fallback;
      }

      function formatDate(value) {
        const raw = String(value || '').trim();
        if (!raw) return 'Belirtilmemiş';
        const parsed = new Date(raw);
        if (!Number.isFinite(parsed.getTime())) return 'Belirtilmemiş';
        return parsed.toLocaleString('tr-TR', {
          year: 'numeric',
          month: '2-digit',
          day: '2-digit',
          hour: '2-digit',
          minute: '2-digit'
        });
      }

      function formatSeconds(totalSec) {
        const sec = Math.max(0, toNumber(totalSec, 0));
        const h = Math.floor(sec / 3600);
        const m = Math.floor((sec % 3600) / 60);
        const s = sec % 60;
        if (h > 0) return h + 's ' + m + 'dk';
        if (m > 0) return m + 'dk ' + s + 'sn';
        return s + 'sn';
      }

      function summaryCard({ title, value, subtitle, tone = 'neutral', icon = '📊' }) {
        const root = {
          neutral: 'border-slate-200 bg-white',
          info: 'border-blue-200 bg-blue-50',
          warning: 'border-amber-200 bg-amber-50',
          danger: 'border-rose-200 bg-rose-50',
          success: 'border-emerald-200 bg-emerald-50'
        };
        const valueTone = tone === 'danger'
          ? 'text-rose-700'
          : tone === 'warning'
            ? 'text-amber-700'
            : tone === 'success'
              ? 'text-emerald-700'
              : 'text-slate-900';
        return '<article class="rounded-2xl border p-4 ' + (root[tone] || root.neutral) + '">' +
          '<p class="text-sm font-medium text-slate-600">' + escapeHtml(icon) + ' ' + escapeHtml(title) + '</p>' +
          '<p class="mt-1 text-3xl font-bold ' + valueTone + '">' + escapeHtml(String(value)) + '</p>' +
          '<p class="mt-2 text-xs text-slate-600 min-h-[18px]">' + escapeHtml(subtitle || '') + '</p>' +
        '</article>';
      }

      function renderSummary(payload) {
        const root = document.getElementById('abuseSummaryCards');
        if (!root) return;
        const rl = payload?.rateLimit || {};
        const suspicious = payload?.suspicious || {};
        const bf = payload?.bruteForce || {};
        const sessions = payload?.activeSessions || {};
        const requests = payload?.requests || {};
        const rlCategories = rl?.insights?.categories || {};
        const externalBlocked = toNumber(rlCategories.external, 0);
        root.innerHTML = [
          summaryCard({
            title: 'Rate Limit Blok (24s)',
            value: toNumber(rl.blockedLast24h, 0),
            subtitle: 'Dış trafik: ' + externalBlocked,
            tone: toNumber(rl.blockedLast24h, 0) > 0 ? 'warning' : 'success',
            icon: '🛡️'
          }),
          summaryCard({
            title: 'Suspicious Event (24s)',
            value: toNumber(suspicious.sampledRows, 0),
            subtitle: 'Unique identity: ' + toNumber(suspicious.uniqueIdentities, 0),
            tone: toNumber(suspicious.sampledRows, 0) > 0 ? 'warning' : 'success',
            icon: '🚨'
          }),
          summaryCard({
            title: 'Aktif BF Blok',
            value: toNumber(bf.activeBlocks, 0),
            subtitle: 'Kaynak: ' + String(bf.source || '-'),
            tone: toNumber(bf.activeBlocks, 0) > 0 ? 'danger' : 'success',
            icon: '🔐'
          }),
          summaryCard({
            title: 'API İstek (1s)',
            value: toNumber(requests.lastHour, 0),
            subtitle: 'Toplam caller: ' + toNumber(requests.breakdown?.callerCount, 0),
            tone: toNumber(requests.lastHour, 0) > 0 ? 'info' : 'neutral',
            icon: '🌐'
          }),
          summaryCard({
            title: 'Aktif Session',
            value: toNumber(sessions.total, 0),
            subtitle: 'Voice: ' + toNumber(sessions.voice, 0) + ' · Text: ' + toNumber(sessions.text, 0),
            tone: toNumber(sessions.total, 0) > 0 ? 'info' : 'neutral',
            icon: '📡'
          })
        ].join('');
      }

      function renderRateLimit(payload) {
        const root = document.getElementById('abuseRateLimitRoot');
        if (!root) return;
        const insights = payload?.rateLimit?.insights || {};
        const categories = insights?.categories || {};
        const topScopes = Array.isArray(insights?.topScopes) ? insights.topScopes.slice(0, 8) : [];
        const topEndpoints = Array.isArray(insights?.topEndpoints) ? insights.topEndpoints.slice(0, 8) : [];
        const topIdentities = Array.isArray(insights?.topIdentities) ? insights.topIdentities.slice(0, 8) : [];
        const diagnosis = String(insights?.diagnosis || 'Detay verisi bulunamadı.');

        const scopeRows = topScopes.length
          ? topScopes.map((item) =>
              '<tr class="border-b border-slate-100"><td class="py-2 pr-2">' + escapeHtml(item?.key || '-') + '</td><td class="py-2 pr-2">' + escapeHtml(item?.sourceLabel || '-') + '</td><td class="py-2 text-right font-semibold">' + toNumber(item?.count, 0) + '</td></tr>'
            ).join('')
          : '<tr><td colspan="3" class="py-3 text-center text-slate-500">Scope verisi yok.</td></tr>';

        const endpointRows = topEndpoints.length
          ? topEndpoints.map((item) =>
              '<tr class="border-b border-slate-100"><td class="py-2 pr-2">' + escapeHtml(item?.key || '-') + '</td><td class="py-2 pr-2">' + escapeHtml(item?.sourceLabel || '-') + '</td><td class="py-2 text-right font-semibold">' + toNumber(item?.count, 0) + '</td></tr>'
            ).join('')
          : '<tr><td colspan="3" class="py-3 text-center text-slate-500">Endpoint verisi yok.</td></tr>';

        const identityRows = topIdentities.length
          ? topIdentities.map((item) =>
              '<tr class="border-b border-slate-100"><td class="py-2 pr-2 font-mono text-xs">' + escapeHtml(item?.identityHash || '-') + '</td><td class="py-2 text-right font-semibold">' + toNumber(item?.count, 0) + '</td></tr>'
            ).join('')
          : '<tr><td colspan="2" class="py-3 text-center text-slate-500">Identity verisi yok.</td></tr>';

        root.innerHTML =
          '<div class="grid grid-cols-2 lg:grid-cols-4 gap-2">' +
            '<div class="rounded-xl border border-blue-200 bg-blue-50 p-3 text-xs"><p class="text-blue-700">İç</p><p class="text-xl font-bold text-blue-800">' + toNumber(categories.internal, 0) + '</p></div>' +
            '<div class="rounded-xl border border-violet-200 bg-violet-50 p-3 text-xs"><p class="text-violet-700">Monitoring</p><p class="text-xl font-bold text-violet-800">' + toNumber(categories.monitoring, 0) + '</p></div>' +
            '<div class="rounded-xl border border-amber-200 bg-amber-50 p-3 text-xs"><p class="text-amber-700">Dış</p><p class="text-xl font-bold text-amber-800">' + toNumber(categories.external, 0) + '</p></div>' +
            '<div class="rounded-xl border border-slate-200 bg-slate-50 p-3 text-xs"><p class="text-slate-600">Unknown</p><p class="text-xl font-bold text-slate-800">' + toNumber(categories.unknown, 0) + '</p></div>' +
          '</div>' +
          '<div class="rounded-xl border border-slate-200 bg-slate-50 px-3 py-2 text-sm text-slate-700">' + escapeHtml(diagnosis) + '</div>' +
          '<div class="grid grid-cols-1 lg:grid-cols-2 gap-3">' +
            '<div class="overflow-auto rounded-xl border border-slate-200"><table class="w-full text-xs min-w-[360px]"><thead class="bg-slate-50 text-slate-600"><tr><th class="py-2 px-2 text-left">Top Scope</th><th class="py-2 px-2 text-left">Kaynak</th><th class="py-2 px-2 text-right">Count</th></tr></thead><tbody>' + scopeRows + '</tbody></table></div>' +
            '<div class="overflow-auto rounded-xl border border-slate-200"><table class="w-full text-xs min-w-[360px]"><thead class="bg-slate-50 text-slate-600"><tr><th class="py-2 px-2 text-left">Top Endpoint</th><th class="py-2 px-2 text-left">Kaynak</th><th class="py-2 px-2 text-right">Count</th></tr></thead><tbody>' + endpointRows + '</tbody></table></div>' +
          '</div>' +
          '<div class="overflow-auto rounded-xl border border-slate-200"><table class="w-full text-xs min-w-[520px]"><thead class="bg-slate-50 text-slate-600"><tr><th class="py-2 px-2 text-left">Top Identity Hash</th><th class="py-2 px-2 text-right">Count</th></tr></thead><tbody>' + identityRows + '</tbody></table></div>';
      }

      function renderBruteForce(payload) {
        const root = document.getElementById('abuseBruteForceRoot');
        if (!root) return;
        const bf = payload?.bruteForce || {};
        const topScopes = Array.isArray(bf?.topScopes) ? bf.topScopes.slice(0, 10) : [];
        const samples = Array.isArray(bf?.samples) ? bf.samples.slice(0, 20) : [];

        const scopeRows = topScopes.length
          ? topScopes.map((item) =>
              '<tr class="border-b border-slate-100"><td class="py-2 pr-2">' + escapeHtml(item?.scope || '-') + '</td><td class="py-2 pr-2 text-right font-semibold">' + toNumber(item?.count, 0) + '</td><td class="py-2 text-right">' + formatSeconds(toNumber(item?.maxTtlSec, 0)) + '</td></tr>'
            ).join('')
          : '<tr><td colspan="3" class="py-3 text-center text-slate-500">Aktif brute force bloğu yok.</td></tr>';

        const sampleRows = samples.length
          ? samples.map((item) =>
              '<tr class="border-b border-slate-100"><td class="py-2 pr-2">' + escapeHtml(item?.scope || '-') + '</td><td class="py-2 pr-2 font-mono text-xs">' + escapeHtml(item?.identityHash || '-') + '</td><td class="py-2 text-right font-semibold">' + formatSeconds(toNumber(item?.ttlSec, 0)) + '</td></tr>'
            ).join('')
          : '<tr><td colspan="3" class="py-3 text-center text-slate-500">Örnek blok kaydı yok.</td></tr>';

        root.innerHTML =
          '<div class="rounded-xl border border-slate-200 bg-slate-50 px-3 py-2 text-sm text-slate-700">Aktif blok: <strong>' + toNumber(bf.activeBlocks, 0) + '</strong> · Kaynak: <strong>' + escapeHtml(String(bf.source || '-')) + '</strong></div>' +
          '<div class="overflow-auto rounded-xl border border-slate-200"><table class="w-full text-xs min-w-[520px]"><thead class="bg-slate-50 text-slate-600"><tr><th class="py-2 px-2 text-left">Scope</th><th class="py-2 px-2 text-right">Aktif Blok</th><th class="py-2 px-2 text-right">Maks Kalan</th></tr></thead><tbody>' + scopeRows + '</tbody></table></div>' +
          '<div class="overflow-auto rounded-xl border border-slate-200"><table class="w-full text-xs min-w-[620px]"><thead class="bg-slate-50 text-slate-600"><tr><th class="py-2 px-2 text-left">Scope</th><th class="py-2 px-2 text-left">Identity Hash</th><th class="py-2 px-2 text-right">Kalan Süre</th></tr></thead><tbody>' + sampleRows + '</tbody></table></div>';
      }

      function renderSuspicious(payload) {
        const root = document.getElementById('abuseSuspiciousRoot');
        if (!root) return;
        const data = payload?.suspicious || {};
        const topEvents = Array.isArray(data?.topEventTypes) ? data.topEventTypes.slice(0, 8) : [];
        const topScopes = Array.isArray(data?.topScopes) ? data.topScopes.slice(0, 8) : [];
        const recentEvents = Array.isArray(data?.recentEvents) ? data.recentEvents.slice(0, 16) : [];

        const topEventRows = topEvents.length
          ? topEvents.map((item) => '<tr class="border-b border-slate-100"><td class="py-2 pr-2">' + escapeHtml(item?.key || '-') + '</td><td class="py-2 text-right font-semibold">' + toNumber(item?.count, 0) + '</td></tr>').join('')
          : '<tr><td colspan="2" class="py-3 text-center text-slate-500">Event type verisi yok.</td></tr>';
        const topScopeRows = topScopes.length
          ? topScopes.map((item) => '<tr class="border-b border-slate-100"><td class="py-2 pr-2">' + escapeHtml(item?.key || '-') + '</td><td class="py-2 text-right font-semibold">' + toNumber(item?.count, 0) + '</td></tr>').join('')
          : '<tr><td colspan="2" class="py-3 text-center text-slate-500">Scope verisi yok.</td></tr>';
        const recentRows = recentEvents.length
          ? recentEvents.map((item) =>
              '<tr class="border-b border-slate-100"><td class="py-2 pr-2">' + escapeHtml(formatDate(item?.createdAt)) + '</td><td class="py-2 pr-2">' + escapeHtml(item?.eventType || '-') + '</td><td class="py-2 pr-2">' + escapeHtml(item?.scope || '-') + '</td><td class="py-2 pr-2">' + escapeHtml(item?.endpoint || '-') + '</td><td class="py-2 text-right font-semibold">' + toNumber(item?.requestCount, 0) + '</td></tr>'
            ).join('')
          : '<tr><td colspan="5" class="py-3 text-center text-slate-500">Recent event kaydı yok.</td></tr>';

        root.innerHTML =
          '<div class="grid grid-cols-2 gap-2">' +
            '<div class="rounded-xl border border-amber-200 bg-amber-50 p-3 text-xs"><p class="text-amber-700">Sampled Event</p><p class="text-xl font-bold text-amber-800">' + toNumber(data.sampledRows, 0) + '</p></div>' +
            '<div class="rounded-xl border border-blue-200 bg-blue-50 p-3 text-xs"><p class="text-blue-700">Unique Identity</p><p class="text-xl font-bold text-blue-800">' + toNumber(data.uniqueIdentities, 0) + '</p></div>' +
          '</div>' +
          '<div class="rounded-xl border border-slate-200 bg-slate-50 px-3 py-2 text-sm text-slate-700">' + escapeHtml(String(data?.diagnosis || 'Detay verisi bulunamadı.')) + '</div>' +
          '<div class="grid grid-cols-1 lg:grid-cols-2 gap-3">' +
            '<div class="overflow-auto rounded-xl border border-slate-200"><table class="w-full text-xs min-w-[320px]"><thead class="bg-slate-50 text-slate-600"><tr><th class="py-2 px-2 text-left">Top Event Type</th><th class="py-2 px-2 text-right">Count</th></tr></thead><tbody>' + topEventRows + '</tbody></table></div>' +
            '<div class="overflow-auto rounded-xl border border-slate-200"><table class="w-full text-xs min-w-[320px]"><thead class="bg-slate-50 text-slate-600"><tr><th class="py-2 px-2 text-left">Top Scope</th><th class="py-2 px-2 text-right">Count</th></tr></thead><tbody>' + topScopeRows + '</tbody></table></div>' +
          '</div>' +
          '<div class="overflow-auto rounded-xl border border-slate-200"><table class="w-full text-xs min-w-[760px]"><thead class="bg-slate-50 text-slate-600"><tr><th class="py-2 px-2 text-left">Zaman</th><th class="py-2 px-2 text-left">Event</th><th class="py-2 px-2 text-left">Scope</th><th class="py-2 px-2 text-left">Endpoint</th><th class="py-2 px-2 text-right">Count</th></tr></thead><tbody>' + recentRows + '</tbody></table></div>';
      }

      function renderTraffic(payload) {
        const root = document.getElementById('abuseTrafficRoot');
        if (!root) return;
        const breakdown = payload?.requests?.breakdown || {};
        const topEndpoints = Array.isArray(breakdown?.topEndpoints) ? breakdown.topEndpoints.slice(0, 10) : [];
        const topCallers = Array.isArray(breakdown?.topCallers) ? breakdown.topCallers.slice(0, 10) : [];
        const endpointRows = topEndpoints.length
          ? topEndpoints.map((item) =>
              '<tr class="border-b border-slate-100"><td class="py-2 pr-2">' + escapeHtml(item?.method || 'GET') + '</td><td class="py-2 pr-2">' + escapeHtml(item?.path || '-') + '</td><td class="py-2 pr-2 text-right">' + toNumber(item?.success, 0) + '</td><td class="py-2 pr-2 text-right">' + toNumber(item?.error, 0) + '</td><td class="py-2 text-right font-semibold">' + toNumber(item?.total, 0) + '</td></tr>'
            ).join('')
          : '<tr><td colspan="5" class="py-3 text-center text-slate-500">Endpoint verisi yok.</td></tr>';
        const callerRows = topCallers.length
          ? topCallers.map((item) =>
              '<tr class="border-b border-slate-100"><td class="py-2 pr-2 font-mono text-xs">' + escapeHtml(item?.callerHash || '-') + '</td><td class="py-2 pr-2 text-right">' + toNumber(item?.success, 0) + '</td><td class="py-2 pr-2 text-right">' + toNumber(item?.error, 0) + '</td><td class="py-2 text-right font-semibold">' + toNumber(item?.total, 0) + '</td></tr>'
            ).join('')
          : '<tr><td colspan="4" class="py-3 text-center text-slate-500">Caller verisi yok.</td></tr>';

        root.innerHTML =
          '<div class="rounded-xl border border-slate-200 bg-slate-50 px-3 py-2 text-sm text-slate-700">Toplam: <strong>' + toNumber(breakdown.total, 0) + '</strong> · Başarılı: <strong>' + toNumber(breakdown.success, 0) + '</strong> · Hata: <strong>' + toNumber(breakdown.error, 0) + '</strong></div>' +
          '<div class="overflow-auto rounded-xl border border-slate-200"><table class="w-full text-xs min-w-[620px]"><thead class="bg-slate-50 text-slate-600"><tr><th class="py-2 px-2 text-left">Method</th><th class="py-2 px-2 text-left">Endpoint</th><th class="py-2 px-2 text-right">Success</th><th class="py-2 px-2 text-right">Error</th><th class="py-2 px-2 text-right">Total</th></tr></thead><tbody>' + endpointRows + '</tbody></table></div>' +
          '<div class="overflow-auto rounded-xl border border-slate-200"><table class="w-full text-xs min-w-[520px]"><thead class="bg-slate-50 text-slate-600"><tr><th class="py-2 px-2 text-left">Caller Hash</th><th class="py-2 px-2 text-right">Success</th><th class="py-2 px-2 text-right">Error</th><th class="py-2 px-2 text-right">Total</th></tr></thead><tbody>' + callerRows + '</tbody></table></div>';
      }

      async function loadAbuseStats() {
        const resp = await fetch('/api/admin/panel/stats/abuse', { credentials: 'include', cache: 'no-store' });
        const payload = await resp.json().catch(() => ({}));
        if (!resp.ok || !payload?.ok) {
          throw new Error(payload?.error || 'Abuse verisi alınamadı');
        }
        renderSummary(payload);
        renderRateLimit(payload);
        renderBruteForce(payload);
        renderSuspicious(payload);
        renderTraffic(payload);
        const metaRoot = document.getElementById('abuseMetaInfo');
        if (metaRoot) {
          metaRoot.textContent =
            'Generated: ' + String(payload.generatedAt || '-') +
            ' · Window: ' + String(payload.windowHours || 24) + ' saat' +
            ' · RL sampled: ' + toNumber(payload?.rateLimit?.insights?.sampledRows, 0) +
            ' · Suspicious sampled: ' + toNumber(payload?.suspicious?.sampledRows, 0);
        }
      }

      let abuseRefreshTimer = null;

      async function refreshAbuse() {
        try {
          await loadAbuseStats();
          const root = document.getElementById('abuseMetaInfo');
          if (root) {
            root.className = 'rounded-2xl border border-slate-200 bg-white p-4 text-sm text-slate-600';
          }
        } catch (error) {
          const root = document.getElementById('abuseMetaInfo');
          if (root) {
            root.className = 'rounded-2xl border border-red-200 bg-red-50 p-4 text-sm text-red-700';
            root.textContent = 'Abuse verisi yüklenemedi: ' + (error?.message || 'bilinmeyen hata');
          }
        }
      }

      function scheduleAbuseRefresh() {
        if (abuseRefreshTimer) {
          clearInterval(abuseRefreshTimer);
          abuseRefreshTimer = null;
        }
        abuseRefreshTimer = setInterval(() => {
          if (document.visibilityState === 'visible') {
            refreshAbuse().catch(() => {});
          }
        }, 5000);
      }

      refreshAbuse().catch(() => {});
      scheduleAbuseRefresh();
      document.addEventListener('visibilitychange', () => {
        if (document.visibilityState === 'visible') {
          refreshAbuse().catch(() => {});
        }
      });
    </script>
  `;

  return renderAdminShell({
    title: "Abuse Protection",
    activePath: "/admin/abuse",
    contentHtml: content,
    scriptsHtml: scripts,
    csrfToken
  });
}

function renderAdminErrorsPage(csrfToken = "") {
  const content = `
    <section class="rounded-2xl border border-slate-200 bg-white p-4 space-y-4">
      <div class="flex flex-col gap-3 lg:flex-row lg:items-end lg:justify-between">
        <div>
          <h2 class="text-lg font-semibold">Hata Logları</h2>
          <p class="text-sm text-slate-500">Endpoint, status ve tarih filtresiyle hata kaydını incele</p>
        </div>
        <form id="errorsFilterForm" class="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-2 w-full lg:max-w-4xl">
          <input id="errorsEndpointInput" placeholder="Endpoint ara (örn: /api/score)" class="rounded-xl border border-slate-300 px-3 py-2 text-sm outline-none focus:ring-2 focus:ring-blue-500" />
          <select id="errorsStatusSelect" class="rounded-xl border border-slate-300 px-3 py-2 text-sm outline-none focus:ring-2 focus:ring-blue-500">
            <option value="">Tüm status</option>
            <option value="5xx">5xx</option>
            <option value="500">500</option>
            <option value="502">502</option>
            <option value="503">503</option>
            <option value="504">504</option>
            <option value="429">429</option>
            <option value="4xx">4xx</option>
          </select>
          <select id="errorsRangeSelect" class="rounded-xl border border-slate-300 px-3 py-2 text-sm outline-none focus:ring-2 focus:ring-blue-500">
            <option value="1">Son 1 saat</option>
            <option value="24" selected>Son 24 saat</option>
            <option value="168">Son 7 gün</option>
            <option value="0">Tümü</option>
          </select>
          <div class="flex items-center gap-2">
            <button type="submit" class="rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm font-semibold text-slate-700 hover:bg-slate-50">Uygula</button>
            <button type="button" id="errorsClearBtn" class="rounded-xl border border-slate-200 bg-slate-50 px-3 py-2 text-sm font-medium text-slate-600 hover:bg-slate-100">Temizle</button>
          </div>
        </form>
      </div>
      <div id="errorsHealthBanner"></div>
      <div class="grid grid-cols-1 sm:grid-cols-4 gap-3" id="errorsSummaryCards"></div>
      <div class="overflow-auto">
        <table class="w-full text-sm min-w-[980px]">
          <thead class="text-left text-slate-500 border-b border-slate-200">
            <tr>
              <th class="py-2 pr-2">Zaman</th>
              <th class="py-2 pr-2">Method</th>
              <th class="py-2 pr-2">Endpoint</th>
              <th class="py-2 pr-2">Status</th>
              <th class="py-2 pr-2">Gecikme</th>
              <th class="py-2 pr-2">Mesaj</th>
              <th class="py-2 pr-2">Kaynak</th>
            </tr>
          </thead>
          <tbody id="errorsTableBody" class="divide-y divide-slate-100"></tbody>
        </table>
      </div>
      <div id="errorsInfoText" class="text-xs text-slate-500"></div>
    </section>
  `;
  const scripts = `
    <script>
      function escapeHtml(value) {
        return String(value || '')
          .replaceAll('&', '&amp;')
          .replaceAll('<', '&lt;')
          .replaceAll('>', '&gt;')
          .replaceAll('"', '&quot;')
          .replaceAll("'", '&#39;');
      }

      function toNumber(value, fallback = 0) {
        const n = Number(value);
        return Number.isFinite(n) ? n : fallback;
      }

      function formatDate(value) {
        const raw = String(value || '').trim();
        if (!raw) return 'Belirtilmemiş';
        const parsed = new Date(raw);
        if (!Number.isFinite(parsed.getTime())) return 'Belirtilmemiş';
        return parsed.toLocaleString('tr-TR', { year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit', second: '2-digit' });
      }

      function statusBadge(status) {
        const safe = toNumber(status, 0);
        const tone = safe >= 500 ? 'border-rose-200 bg-rose-50 text-rose-700' : safe >= 400 ? 'border-amber-200 bg-amber-50 text-amber-700' : 'border-slate-200 bg-slate-50 text-slate-700';
        return '<span class="inline-flex items-center rounded-lg border px-2 py-1 text-xs font-semibold ' + tone + '">' + safe + '</span>';
      }

      function summaryCard(title, value, tone = 'neutral') {
        const tones = {
          success: 'border-emerald-200 bg-emerald-50',
          warning: 'border-amber-200 bg-amber-50',
          danger: 'border-rose-200 bg-rose-50',
          neutral: 'border-slate-200 bg-white'
        };
        const valueColor = tone === 'danger' ? 'text-rose-700' : tone === 'warning' ? 'text-amber-700' : tone === 'success' ? 'text-emerald-700' : 'text-slate-900';
        return '<article class="rounded-xl border p-3 ' + (tones[tone] || tones.neutral) + '">' +
          '<p class="text-xs text-slate-500">' + escapeHtml(title) + '</p>' +
          '<p class="mt-1 text-2xl font-bold ' + valueColor + '">' + escapeHtml(value) + '</p>' +
        '</article>';
      }

      function renderHealthBanner(totalLogs, filteredCount) {
        const banner = document.getElementById('errorsHealthBanner');
        if (!banner) return;
        if (totalLogs === 0) {
          banner.innerHTML = '<div class="rounded-xl border border-emerald-200 bg-emerald-50 px-4 py-3 text-sm text-emerald-800">✅ Sistem sağlıklı: Son kayıt aralığında sunucu hata logu bulunmuyor.</div>';
          return;
        }
        if (filteredCount === 0) {
          banner.innerHTML = '<div class="rounded-xl border border-amber-200 bg-amber-50 px-4 py-3 text-sm text-amber-800">Filtreye uyan log bulunamadı. Filtreleri genişletip tekrar deneyebilirsin.</div>';
          return;
        }
        banner.innerHTML = '<div class="rounded-xl border border-slate-200 bg-slate-50 px-4 py-3 text-sm text-slate-700">Toplam ' + totalLogs + ' kayıttan ' + filteredCount + ' kayıt gösteriliyor.</div>';
      }

      function renderSummary(summary) {
        const root = document.getElementById('errorsSummaryCards');
        if (!root) return;
        const total = toNumber(summary?.total, 0);
        const server5xx = toNumber(summary?.server5xx, 0);
        const client4xx = toNumber(summary?.client4xx, 0);
        const rate429 = toNumber(summary?.rate429, 0);
        root.innerHTML = [
          summaryCard('Toplam Kayıt', total, total > 0 ? 'warning' : 'success'),
          summaryCard('5xx', server5xx, server5xx > 0 ? 'danger' : 'success'),
          summaryCard('4xx', client4xx, client4xx > 0 ? 'warning' : 'neutral'),
          summaryCard('429', rate429, rate429 > 0 ? 'warning' : 'neutral')
        ].join('');
      }

      function renderTable(logs) {
        const tbody = document.getElementById('errorsTableBody');
        if (!tbody) return;
        const rows = Array.isArray(logs) ? logs : [];
        if (!rows.length) {
          tbody.innerHTML = '<tr><td colspan="7" class="py-8 text-center text-slate-500">Filtreye uygun log bulunamadı.</td></tr>';
          return;
        }
        tbody.innerHTML = rows.map((item) => {
          const method = escapeHtml(item?.method || '-');
          const path = escapeHtml(item?.path || '-');
          const latency = toNumber(item?.latencyMs, 0);
          const source = escapeHtml(item?.source || 'runtime');
          const service = escapeHtml(item?.service || '-');
          const code = escapeHtml(item?.code || '-');
          const reqId = escapeHtml(item?.requestId ? String(item.requestId).slice(0, 12) : '-');
          const message = escapeHtml(item?.message || '-');
          const sourceText = service + ' · ' + code + ' · ' + source + ' · req#' + reqId;
          return '<tr>' +
            '<td class="py-3 pr-2 text-slate-700">' + escapeHtml(formatDate(item?.timestamp)) + '</td>' +
            '<td class="py-3 pr-2 text-slate-700">' + method + '</td>' +
            '<td class="py-3 pr-2 font-medium text-slate-800">' + path + '</td>' +
            '<td class="py-3 pr-2">' + statusBadge(item?.status) + '</td>' +
            '<td class="py-3 pr-2 text-slate-700">' + latency + 'ms</td>' +
            '<td class="py-3 pr-2 text-slate-600">' + message + '</td>' +
            '<td class="py-3 pr-2 text-slate-600">' + sourceText + '</td>' +
          '</tr>';
        }).join('');
      }

      const state = {
        endpoint: '',
        status: '',
        rangeHours: 24
      };

      const form = document.getElementById('errorsFilterForm');
      const endpointInput = document.getElementById('errorsEndpointInput');
      const statusSelect = document.getElementById('errorsStatusSelect');
      const rangeSelect = document.getElementById('errorsRangeSelect');
      const clearBtn = document.getElementById('errorsClearBtn');
      const infoText = document.getElementById('errorsInfoText');

      async function loadLogs() {
        const qs = new URLSearchParams({
          limit: '200',
          endpoint: state.endpoint,
          status: state.status,
          rangeHours: String(state.rangeHours || 0)
        });
        const resp = await fetch('/api/admin/panel/stats/errors?' + qs.toString(), { credentials: 'include', cache: 'no-store' });
        const data = await resp.json().catch(() => ({}));
        if (!resp.ok || !data?.ok) {
          throw new Error(data?.error || 'Hata logları alınamadı');
        }
        const logs = Array.isArray(data.logs) ? data.logs : [];
        const summary = data.summary && typeof data.summary === 'object' ? data.summary : {};
        renderSummary(summary);
        renderHealthBanner(toNumber(summary.total, 0), logs.length);
        renderTable(logs);
        infoText.textContent = 'Filtre: endpoint=' + (state.endpoint || 'tümü') + ', status=' + (state.status || 'tümü') + ', aralık=' + (state.rangeHours > 0 ? (state.rangeHours + 's') : 'tümü');
      }

      form?.addEventListener('submit', async (event) => {
        event.preventDefault();
        state.endpoint = String(endpointInput?.value || '').trim();
        state.status = String(statusSelect?.value || '').trim();
        state.rangeHours = toNumber(rangeSelect?.value, 24);
        try {
          await loadLogs();
        } catch (error) {
          const tbody = document.getElementById('errorsTableBody');
          if (tbody) {
            tbody.innerHTML = '<tr><td colspan="7" class="py-8 text-center text-red-700">Hata logları alınamadı: ' + escapeHtml(error?.message || 'bilinmeyen hata') + '</td></tr>';
          }
        }
      });

      clearBtn?.addEventListener('click', async () => {
        state.endpoint = '';
        state.status = '';
        state.rangeHours = 24;
        if (endpointInput) endpointInput.value = '';
        if (statusSelect) statusSelect.value = '';
        if (rangeSelect) rangeSelect.value = '24';
        try {
          await loadLogs();
        } catch (error) {
          const tbody = document.getElementById('errorsTableBody');
          if (tbody) {
            tbody.innerHTML = '<tr><td colspan="7" class="py-8 text-center text-red-700">Hata logları alınamadı: ' + escapeHtml(error?.message || 'bilinmeyen hata') + '</td></tr>';
          }
        }
      });

      loadLogs().catch((error) => {
        const tbody = document.getElementById('errorsTableBody');
        if (tbody) {
          tbody.innerHTML = '<tr><td colspan="7" class="py-8 text-center text-red-700">Hata logları alınamadı: ' + escapeHtml(error?.message || 'bilinmeyen hata') + '</td></tr>';
        }
      });
    </script>
  `;
  return renderAdminShell({
    title: "Hata Logları",
    activePath: "/admin/errors",
    contentHtml: content,
    scriptsHtml: scripts,
    csrfToken
  });
}

function renderAdminAiPromptsPage(csrfToken = "") {
  const content = `
    <section class="rounded-2xl border border-slate-200 bg-white p-4">
      <h2 class="text-lg font-semibold">AI Prompt ve Model Envanteri</h2>
      <p class="mt-1 text-sm text-slate-600">Hangi endpoint için hangi modelin ve hangi prompt metninin kullanıldığı canlı olarak gösterilir.</p>
    </section>
    <section id="aiPromptSummary" class="grid grid-cols-1 sm:grid-cols-3 gap-3"></section>
    <section id="aiPromptList" class="space-y-3"></section>
    <section id="aiPromptError" class="hidden rounded-2xl border border-red-200 bg-red-50 p-4 text-sm text-red-700"></section>
  `;
  const scripts = `
    <script>
      function escapeHtml(value) {
        return String(value || '')
          .replaceAll('&', '&amp;')
          .replaceAll('<', '&lt;')
          .replaceAll('>', '&gt;')
          .replaceAll('"', '&quot;')
          .replaceAll("'", '&#39;');
      }

      function summaryCard(title, value, subtitle) {
        return '<article class="rounded-xl border border-slate-200 bg-white p-4">' +
          '<p class="text-xs uppercase tracking-wide text-slate-500">' + escapeHtml(title) + '</p>' +
          '<p class="mt-1 text-2xl font-bold text-slate-900">' + escapeHtml(value) + '</p>' +
          '<p class="mt-1 text-xs text-slate-500">' + escapeHtml(subtitle || '') + '</p>' +
        '</article>';
      }

      function badge(text, tone = 'slate') {
        const toneMap = {
          blue: 'border-blue-200 bg-blue-50 text-blue-700',
          emerald: 'border-emerald-200 bg-emerald-50 text-emerald-700',
          amber: 'border-amber-200 bg-amber-50 text-amber-700',
          slate: 'border-slate-200 bg-slate-50 text-slate-700'
        };
        return '<span class="inline-flex items-center rounded-lg border px-2 py-1 text-xs font-semibold ' + (toneMap[tone] || toneMap.slate) + '">' + escapeHtml(text) + '</span>';
      }

      function renderSummary(payload) {
        const root = document.getElementById('aiPromptSummary');
        if (!root) return;
        const flows = Array.isArray(payload?.flows) ? payload.flows : [];
        const uniqueModels = new Set();
        for (const flow of flows) {
          for (const model of (Array.isArray(flow?.models) ? flow.models : [])) {
            if (String(model || '').trim()) uniqueModels.add(String(model || '').trim());
          }
        }
        root.innerHTML = [
          summaryCard('Prompt Akışı', String(flows.length || 0), 'Toplam AI akışı'),
          summaryCard('Aktif Model', String(uniqueModels.size || 0), 'Benzersiz model sayısı'),
          summaryCard('Catalog Versiyonu', String(payload?.catalog_version || '-'), 'Üretim zamanı: ' + String(payload?.generated_at || '-'))
        ].join('');
      }

      function renderFlows(payload) {
        const list = document.getElementById('aiPromptList');
        if (!list) return;
        const flows = Array.isArray(payload?.flows) ? payload.flows : [];
        if (!flows.length) {
          list.innerHTML = '<article class="rounded-2xl border border-slate-200 bg-white p-4 text-sm text-slate-600">Kayıtlı prompt akışı bulunamadı.</article>';
          return;
        }

        list.innerHTML = flows.map((flow) => {
          const routes = (Array.isArray(flow?.routes) ? flow.routes : []).map((route) => badge(route, 'blue')).join('');
          const models = (Array.isArray(flow?.models) ? flow.models : []).map((model) => badge(model, 'emerald')).join('');
          const prompts = (Array.isArray(flow?.prompts) ? flow.prompts : []).map((prompt) => {
            const text = String(prompt?.text || '');
            return '<details class="rounded-xl border border-slate-200 bg-slate-50 p-3">' +
              '<summary class="cursor-pointer text-sm font-semibold text-slate-800">' + escapeHtml(prompt?.name || 'prompt') + '</summary>' +
              '<pre class="mt-2 whitespace-pre-wrap break-words rounded-lg bg-white p-3 text-xs text-slate-700 border border-slate-200">' + escapeHtml(text) + '</pre>' +
            '</details>';
          }).join('');

          return '<article class="rounded-2xl border border-slate-200 bg-white p-4 space-y-3">' +
            '<div class="flex flex-col gap-2 md:flex-row md:items-center md:justify-between">' +
              '<div><h3 class="text-base font-semibold text-slate-900">' + escapeHtml(flow?.label || flow?.key || '-') + '</h3>' +
              '<p class="text-xs text-slate-500">Prompt sürümü: ' + escapeHtml(flow?.prompt_version || '-') + '</p></div>' +
              '<div class="text-xs text-slate-500">Şema: ' + escapeHtml(flow?.output_schema || '-') + '</div>' +
            '</div>' +
            '<div class="flex flex-wrap gap-2">' + routes + '</div>' +
            '<div class="flex flex-wrap gap-2">' + models + '</div>' +
            '<div class="space-y-2">' + prompts + '</div>' +
          '</article>';
        }).join('');
      }

      async function loadAiPrompts() {
        const err = document.getElementById('aiPromptError');
        if (err) {
          err.classList.add('hidden');
          err.textContent = '';
        }
        try {
          const resp = await fetch('/api/admin/panel/ai-prompts', { credentials: 'include', cache: 'no-store' });
          const payload = await resp.json().catch(() => ({}));
          if (!resp.ok || !payload?.ok) {
            throw new Error(payload?.error || 'AI prompt envanteri alınamadı.');
          }
          renderSummary(payload);
          renderFlows(payload);
        } catch (error) {
          if (err) {
            err.textContent = 'AI prompt envanteri alınamadı: ' + (error?.message || 'bilinmeyen hata');
            err.classList.remove('hidden');
          }
        }
      }

      loadAiPrompts();
    </script>
  `;
  return renderAdminShell({
    title: "AI Promptlar",
    activePath: "/admin/ai-prompts",
    contentHtml: content,
    scriptsHtml: scripts,
    csrfToken
  });
}

app.get("/admin/login", async (req, res) => {
  noStoreAdminResponse(res);
  const currentSession = extractAdminSession(req);
  if (currentSession) {
    return res.redirect(302, "/admin/dashboard");
  }
  const nextPath = normalizeAdminNextPath(req.query?.next || "/admin/dashboard");
  const csrfToken = ensureAdminLoginCsrf(req, res);
  return res.status(200).set("Content-Type", "text/html; charset=utf-8").send(renderAdminLoginPage(nextPath, csrfToken));
});

app.post("/admin/login", async (req, res) => {
  const identity = getClientIp(req);
  const scope = "admin-panel-login-auth";
  const parsedBody = parseJsonWithZod(res, adminLoginBodySchema, req.body, {
    message: "Admin giriş isteği doğrulanamadı."
  });
  if (!parsedBody) {
    return;
  }
  if (!validateAdminLoginCsrf(req, parsedBody.csrfToken)) {
    await registerAuthFailure({
      scope,
      identity,
      endpoint: req.originalUrl || req.url || ""
    });
    return res.status(403).json({
      error: "CSRF doğrulaması başarısız."
    });
  }

  if (
    (await enforceBruteForceGuard(req, res, {
      scope,
      identity,
      errorMessage: "Çok fazla hatalı admin giriş denemesi. Lütfen daha sonra tekrar dene."
    })) !== true
  ) {
    return;
  }

  const ipLimitOk = await enforceRateLimit(req, res, {
    scope: "admin-panel-login-ip",
    identity,
    maxRequests: clampRateLimitValue(process.env.RATE_LIMIT_ADMIN_LOGIN_IP_PER_MIN, 20, 3, 120),
    windowMs: 60_000,
    errorMessage: "Admin giriş isteği sınırına ulaşıldı."
  });
  if (!ipLimitOk) {
    return;
  }

  const cfg = getAdminPanelConfig();
  if (!cfg.username || !cfg.password || !cfg.sessionSecret) {
    return res.status(503).json({
      error: "Admin panel yapılandırması eksik. ADMIN_USERNAME, ADMIN_PASSWORD, ADMIN_SESSION_SECRET gerekli."
    });
  }

  const username = String(parsedBody.username || "").trim();
  const password = String(parsedBody.password || "");
  const validUsername = safeConstantCompare(username, cfg.username);
  const validPassword = safeConstantCompare(password, cfg.password);

  if (!validUsername || !validPassword) {
    await registerAuthFailure({
      scope,
      identity,
      endpoint: req.originalUrl || req.url || ""
    });
    return res.status(401).json({
      error: "Kullanıcı adı veya şifre hatalı."
    });
  }
  await clearAuthFailures({ scope, identity });

  const session = createAdminSessionToken({ username: cfg.username });
  setAdminSessionCookie(req, res, session.token, cfg.sessionTtlSec);
  clearAdminLoginCsrfCookie(req, res);
  noStoreAdminResponse(res);

  const redirectTo = normalizeAdminNextPath(parsedBody.next || "/admin/dashboard");
  return res.json({
    ok: true,
    redirectTo,
    csrfToken: String(session?.payload?.csrf || "")
  });
});

app.post("/admin/logout", requireAdminApiSession, requireAdminCsrf, async (req, res) => {
  clearAdminSessionCookie(req, res);
  clearAdminLoginCsrfCookie(req, res);
  noStoreAdminResponse(res);
  return res.json({ ok: true });
});

app.get("/admin", requireAdminPageSession, (req, res) => {
  noStoreAdminResponse(res);
  return res.redirect(302, "/admin/dashboard");
});

app.get("/admin/dashboard", requireAdminPageSession, (req, res) => {
  noStoreAdminResponse(res);
  return res.status(200).set("Content-Type", "text/html; charset=utf-8").send(
    renderAdminDashboardPage(String(req.adminSession?.csrf || ""))
  );
});

app.get("/admin/analytics", requireAdminPageSession, (req, res) => {
  noStoreAdminResponse(res);
  return res.status(200).set("Content-Type", "text/html; charset=utf-8").send(
    renderAdminAnalyticsPage(String(req.adminSession?.csrf || ""))
  );
});

app.get("/admin/broadcast", requireAdminPageSession, (req, res) => {
  noStoreAdminResponse(res);
  return res.status(200).set("Content-Type", "text/html; charset=utf-8").send(
    renderAdminBroadcastPage(String(req.adminSession?.csrf || ""))
  );
});

app.get("/admin/users", requireAdminPageSession, (req, res) => {
  noStoreAdminResponse(res);
  return res.status(200).set("Content-Type", "text/html; charset=utf-8").send(
    renderAdminUsersPage(String(req.adminSession?.csrf || ""))
  );
});

app.get("/admin/sessions", requireAdminPageSession, (req, res) => {
  noStoreAdminResponse(res);
  return res.status(200).set("Content-Type", "text/html; charset=utf-8").send(
    renderAdminSessionsPage(String(req.adminSession?.csrf || ""))
  );
});

app.get("/admin/abuse", requireAdminPageSession, (req, res) => {
  noStoreAdminResponse(res);
  return res.status(200).set("Content-Type", "text/html; charset=utf-8").send(
    renderAdminAbusePage(String(req.adminSession?.csrf || ""))
  );
});

app.get("/admin/errors", requireAdminPageSession, (req, res) => {
  noStoreAdminResponse(res);
  return res.status(200).set("Content-Type", "text/html; charset=utf-8").send(
    renderAdminErrorsPage(String(req.adminSession?.csrf || ""))
  );
});

app.get("/admin/ai-prompts", requireAdminPageSession, (req, res) => {
  noStoreAdminResponse(res);
  return res.status(200).set("Content-Type", "text/html; charset=utf-8").send(
    renderAdminAiPromptsPage(String(req.adminSession?.csrf || ""))
  );
});

app.get("/auth/confirm", async (req, res) => {
  const { supabaseUrl } = getSupabaseConfig();
  const supabaseAuthBase = String(supabaseUrl || "").trim().replace(/\/+$/g, "");
  const errorDescription = sanitizeReportText(req.query?.error_description || "", 240);
  const hasError = Boolean(errorDescription);
  let verifiedFlag = String(req.query?.verified || "").trim() === "1";
  const tokenHash = String(req.query?.token_hash || "").trim();
  const token = String(req.query?.token || "").trim();
  const tokenType = String(req.query?.type || "").trim().toLowerCase();
  const accessToken = String(req.query?.access_token || "").trim();
  const canVerifyType = (tokenType === "signup" || tokenType === "email") && (Boolean(tokenHash) || Boolean(token));

  if (!hasError && !verifiedFlag && !accessToken && canVerifyType) {
    // Gerçek doğrulamayı server-side yap: e-posta doğrulaması gerçekten başarılı
    // olmadan "başarılı" ekranı dönmeyelim.
    const verifyTypes = Array.from(
      new Set([tokenType, tokenType === "email" ? "signup" : null].filter(Boolean))
    );

    let verified = false;
    let lastError = null;
    let verifiedPayload = null;
    for (const candidateType of verifyTypes) {
      try {
        const payload = await verifySupabaseActionToken({
          supabaseUrl: supabaseAuthBase || "https://vhqkddzcxsxgkjblrdtt.supabase.co",
          type: candidateType,
          token,
          tokenHash
        });
        verifiedPayload = payload;
        verified = true;
        break;
      } catch (verifyError) {
        lastError = verifyError;
      }
    }

    if (verified) {
      try {
        const { supabaseUrl, supabaseServiceRoleKey } = getSupabaseConfig();
        const verifiedUser = extractVerifiedAuthUser(verifiedPayload);
        const verifiedUserId = sanitizeUuid(verifiedUser?.id);
        if (supabaseUrl && supabaseServiceRoleKey && verifiedUserId) {
          const metadata = verifiedUser?.user_metadata || {};
          const emailRaw =
            typeof verifiedUser?.email === "string" ? verifiedUser.email : metadata?.email || null;
          const phoneRaw =
            typeof metadata?.phone_number === "string"
              ? metadata.phone_number
              : typeof metadata?.phone === "string"
                ? metadata.phone
                : null;
          const firstName = String(metadata?.first_name || metadata?.given_name || "").trim() || null;
          const lastName = String(metadata?.last_name || metadata?.family_name || "").trim() || null;
          const fullName = buildFullNameFromAuthUser(verifiedUser);
          const profileRow = {
            id: verifiedUserId,
            email: sanitizeEmail(emailRaw) || null,
            first_name: firstName,
            last_name: lastName,
            full_name: fullName,
            phone_number: String(phoneRaw || "").trim().slice(0, 32) || null,
            updated_at: new Date().toISOString()
          };
          await upsertProfileRow({
            supabaseUrl,
            supabaseServiceRoleKey,
            row: profileRow,
            errorPrefix: "E-posta doğrulama sonrası profil kaydı yazılamadı"
          });
        }
      } catch (upsertAfterVerifyError) {
        console.warn(
          `[auth/confirm] profile upsert warning: ${upsertAfterVerifyError?.message || upsertAfterVerifyError}`
        );
      }
      try {
        const cleanTarget = new URL("https://www.medcase.website/auth/confirm");
        cleanTarget.searchParams.set("verified", "1");
        return res.redirect(302, cleanTarget.toString());
      } catch {
        verifiedFlag = true;
      }
    } else if (lastError) {
      const safeMessage = sanitizeReportText(lastError?.message || "Doğrulama başarısız.", 240);
      try {
        const failTarget = new URL("https://www.medcase.website/auth/confirm");
        failTarget.searchParams.set("error_description", safeMessage);
        return res.redirect(302, failTarget.toString());
      } catch {
        // Redirect üretilemezse mevcut request'te error ekranına düşelim.
      }
    }
  }

  const isVerified = verifiedFlag || Boolean(accessToken);
  const title = hasError
    ? "Doğrulama tamamlanamadı"
    : isVerified
      ? "E-posta doğrulandı!"
      : "Doğrulama bekleniyor";
  const subtitle = hasError
    ? "Bağlantı geçersiz veya süresi dolmuş olabilir. Uygulamadan yeniden doğrulama isteyebilirsin."
    : isVerified
      ? "Hesabın aktifleştirildi. Uygulamaya dön ve e-posta ile şifrenle giriş yap."
      : "Bu sayfa tek başına doğrulama yapmaz. E-postadaki doğrulama bağlantısından gelerek işlemi tamamla.";
  const detail = hasError ? errorDescription : "";

  const html = `<!doctype html>
<html lang="tr">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>${title}</title>
  <style>
    :root {
      color-scheme: light;
      --bg: #f8fafc;
      --surface: #ffffff;
      --text: #0f172a;
      --muted: #475569;
      --primary: #1d6fe8;
      --border: #dbe4ef;
      --ok: #0d9e6e;
      --error: #dc2626;
    }
    * { box-sizing: border-box; }
    body {
      margin: 0;
      min-height: 100vh;
      display: grid;
      place-items: center;
      background: var(--bg);
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
      color: var(--text);
      padding: 20px;
    }
    .card {
      width: 100%;
      max-width: 520px;
      background: var(--surface);
      border: 1px solid var(--border);
      border-radius: 20px;
      padding: 28px 22px;
      box-shadow: 0 10px 30px rgba(15, 23, 42, 0.05);
      text-align: center;
    }
    .badge {
      width: 56px;
      height: 56px;
      margin: 0 auto 14px;
      border-radius: 50%;
      display: grid;
      place-items: center;
      color: #fff;
      font-size: 26px;
      font-weight: 700;
      background: ${hasError ? "var(--error)" : isVerified ? "var(--ok)" : "var(--primary)"};
    }
    h1 { margin: 0 0 10px; font-size: 30px; line-height: 1.15; }
    p { margin: 0; color: var(--muted); font-size: 17px; line-height: 1.55; }
    .detail {
      margin-top: 12px;
      padding: 10px 12px;
      border-radius: 10px;
      background: #fff5f5;
      color: #7f1d1d;
      border: 1px solid #fecaca;
      font-size: 14px;
      line-height: 1.45;
      text-align: left;
      word-break: break-word;
    }
    .actions {
      margin-top: 18px;
      display: grid;
      gap: 10px;
    }
    .btn {
      display: inline-flex;
      justify-content: center;
      align-items: center;
      min-height: 48px;
      border-radius: 12px;
      border: 1px solid transparent;
      text-decoration: none;
      font-weight: 600;
      font-size: 16px;
      cursor: pointer;
    }
    .btn-primary {
      background: var(--primary);
      color: #fff;
    }
    .btn-secondary {
      background: #fff;
      color: var(--text);
      border-color: var(--border);
    }
  </style>
</head>
<body>
  <main class="card">
    <div class="badge">${hasError ? "!" : isVerified ? "✓" : "…"}</div>
    <h1>${title}</h1>
    <p>${subtitle}</p>
    ${detail ? `<div class="detail">${detail}</div>` : ""}
    <div class="actions">
      <a class="btn btn-primary" href="drkynox://auth/login">Uygulamayı Aç</a>
      <a class="btn btn-secondary" href="https://www.medcase.website/">Ana Sayfaya Dön</a>
    </div>
  </main>
</body>
</html>`;

  return res.status(hasError ? 400 : 200).set("Content-Type", "text/html; charset=utf-8").send(html);
});

app.get("/aut/confirm", (req, res) => {
  const target = new URL("/auth/confirm", "https://www.medcase.website");
  const original = new URL(req.originalUrl || "/aut/confirm", "https://www.medcase.website");
  original.searchParams.forEach((value, key) => target.searchParams.set(key, value));
  return res.redirect(302, target.pathname + target.search);
});

app.get("/auth/reset-password", (req, res) => {
  const { supabaseUrl } = getSupabaseConfig();
  const supabaseAuthBase = String(supabaseUrl || "").trim().replace(/\/+$/g, "");
  const appDeepLink = String(process.env.APP_DEEP_LINK_URL || "drkynox://auth/login").trim() || "drkynox://auth/login";
  const html = `<!doctype html>
<html lang="tr">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>Şifre Yenile · Dr.Kynox</title>
  <style>
    :root {
      color-scheme: light;
      --bg: #f8fafc;
      --surface: #ffffff;
      --text: #0f172a;
      --muted: #475569;
      --primary: #1d6fe8;
      --ok: #0d9e6e;
      --error: #dc2626;
      --border: #dbe4ef;
    }
    * { box-sizing: border-box; }
    body {
      margin: 0;
      min-height: 100vh;
      display: grid;
      place-items: center;
      background: var(--bg);
      color: var(--text);
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
      padding: 20px;
    }
    .card {
      width: 100%;
      max-width: 540px;
      background: var(--surface);
      border: 1px solid var(--border);
      border-radius: 18px;
      padding: 24px 20px;
      box-shadow: 0 10px 30px rgba(15, 23, 42, 0.06);
    }
    h1 { margin: 0 0 8px; font-size: 28px; line-height: 1.15; }
    .desc { margin: 0 0 16px; color: var(--muted); font-size: 16px; line-height: 1.55; }
    .status {
      display: flex;
      align-items: center;
      gap: 10px;
      border: 1px solid var(--border);
      border-radius: 10px;
      padding: 10px 12px;
      margin-bottom: 14px;
      background: #fff;
      font-size: 14px;
    }
    .dot {
      width: 10px;
      height: 10px;
      border-radius: 999px;
      background: #94a3b8;
      flex: 0 0 auto;
    }
    form { display: grid; gap: 12px; }
    label {
      font-weight: 600;
      font-size: 14px;
      color: #1e293b;
      margin-bottom: 4px;
      display: inline-block;
    }
    .field {
      width: 100%;
      min-height: 48px;
      border-radius: 12px;
      border: 1px solid var(--border);
      padding: 12px 14px;
      font-size: 16px;
      color: var(--text);
      background: #fff;
      outline: none;
    }
    .field:focus {
      border-color: var(--primary);
      box-shadow: 0 0 0 3px rgba(29, 111, 232, 0.12);
    }
    .hint {
      color: var(--muted);
      font-size: 13px;
      line-height: 1.5;
    }
    .actions {
      margin-top: 6px;
      display: grid;
      gap: 10px;
    }
    .btn {
      min-height: 50px;
      border: 1px solid transparent;
      border-radius: 12px;
      font-size: 16px;
      font-weight: 700;
      cursor: pointer;
      display: inline-flex;
      align-items: center;
      justify-content: center;
      text-decoration: none;
    }
    .btn-primary {
      background: var(--primary);
      color: #fff;
    }
    .btn-secondary {
      background: #fff;
      border-color: var(--border);
      color: var(--text);
      font-weight: 600;
    }
    .btn:disabled {
      opacity: 0.55;
      cursor: not-allowed;
    }
    .msg {
      margin-top: 10px;
      border-radius: 10px;
      padding: 10px 12px;
      font-size: 14px;
      line-height: 1.5;
      border: 1px solid var(--border);
      display: none;
      white-space: pre-line;
    }
    .msg.ok {
      background: #ecfdf5;
      border-color: #86efac;
      color: #14532d;
    }
    .msg.err {
      background: #fef2f2;
      border-color: #fecaca;
      color: #7f1d1d;
    }
  </style>
</head>
<body>
  <main class="card">
    <h1>Şifreni yenile</h1>
    <p class="desc">Yeni şifreni belirle. İşlem tamamlandığında uygulamaya dönüp giriş yapabilirsin.</p>

    <div class="status" id="tokenStatus">
      <span class="dot" id="tokenDot"></span>
      <span id="tokenText">Doğrulama bağlantısı kontrol ediliyor...</span>
    </div>

    <form id="resetForm">
      <div>
        <label for="password">Yeni şifre</label>
        <input id="password" class="field" type="password" autocomplete="new-password" minlength="8" required />
      </div>
      <div>
        <label for="passwordConfirm">Yeni şifre (tekrar)</label>
        <input id="passwordConfirm" class="field" type="password" autocomplete="new-password" minlength="8" required />
      </div>
      <div class="hint">En az 8 karakter, mümkünse büyük harf ve sayı kullan.</div>
      <div class="actions">
        <button class="btn btn-primary" id="submitBtn" type="submit" disabled>Şifreyi güncelle</button>
        <a class="btn btn-secondary" href="${appDeepLink}">Uygulamayı Aç</a>
      </div>
    </form>

    <div class="msg" id="messageBox"></div>
  </main>

  <script>
    const tokenDot = document.getElementById("tokenDot");
    const tokenText = document.getElementById("tokenText");
    const messageBox = document.getElementById("messageBox");
    const submitBtn = document.getElementById("submitBtn");
    const form = document.getElementById("resetForm");
    const passwordEl = document.getElementById("password");
    const confirmEl = document.getElementById("passwordConfirm");

    function showMessage(type, text) {
      messageBox.className = "msg " + (type === "ok" ? "ok" : "err");
      messageBox.style.display = "block";
      messageBox.textContent = text;
    }

    function parseFragmentParams() {
      const hash = window.location.hash ? window.location.hash.slice(1) : "";
      const q = new URLSearchParams(hash);
      return {
        accessToken: q.get("access_token") || "",
        refreshToken: q.get("refresh_token") || "",
        type: q.get("type") || ""
      };
    }

    function parseQueryParams() {
      const q = new URLSearchParams(window.location.search);
      return {
        accessToken: q.get("access_token") || "",
        token: q.get("token") || "",
        type: q.get("type") || "",
        errorDescription: q.get("error_description") || ""
      };
    }

    function setTokenState(ok, text) {
      tokenDot.style.background = ok ? "var(--ok)" : "var(--error)";
      tokenText.textContent = text;
      submitBtn.disabled = !ok;
    }

    (function init() {
      const f = parseFragmentParams();
      const q = parseQueryParams();

      if (q.errorDescription) {
        setTokenState(false, "Bağlantı doğrulanamadı");
        showMessage("err", q.errorDescription);
        return;
      }

      const accessToken = f.accessToken || q.accessToken;
      if (accessToken) {
        window.__RECOVERY_ACCESS_TOKEN__ = accessToken;
        setTokenState(true, "Bağlantı doğrulandı. Yeni şifreyi girebilirsin.");
        return;
      }

      if (q.token && q.type === "recovery") {
        setTokenState(false, "Bağlantı doğrulanıyor...");
        const target = new URL(window.location.href);
        target.search = "";
        target.hash = "";
        const redirectTo = target.toString();
        const supabaseBase = "${supabaseAuthBase}";
        const verifyBase = (supabaseBase || window.location.origin).replace(/\/+$/g, "");
        const verifyUrl = \`${'${'}verifyBase}/auth/v1/verify?token=\${encodeURIComponent(q.token)}&type=recovery&redirect_to=\${encodeURIComponent(redirectTo)}\`;
        window.location.replace(verifyUrl);
        return;
      }

      setTokenState(false, "Geçersiz veya süresi dolmuş bağlantı.");
      showMessage("err", "Şifre yenileme bağlantısı geçersiz görünüyor. Uygulamadan yeniden şifre sıfırlama isteği gönder.");
    })();

    form.addEventListener("submit", async (event) => {
      event.preventDefault();
      messageBox.style.display = "none";

      const accessToken = window.__RECOVERY_ACCESS_TOKEN__ || "";
      if (!accessToken) {
        setTokenState(false, "Geçersiz bağlantı");
        showMessage("err", "Doğrulama bağlantısı bulunamadı. Lütfen e-postadaki linke tekrar tıkla.");
        return;
      }

      const password = String(passwordEl.value || "");
      const passwordConfirm = String(confirmEl.value || "");

      if (password.length < 8) {
        showMessage("err", "Şifre en az 8 karakter olmalı.");
        return;
      }
      if (password !== passwordConfirm) {
        showMessage("err", "Şifreler eşleşmiyor.");
        return;
      }

      submitBtn.disabled = true;
      submitBtn.textContent = "Güncelleniyor...";
      try {
        const resp = await fetch("/api/auth/reset-password/complete", {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({
            accessToken,
            newPassword: password
          })
        });
        const payload = await resp.json().catch(() => ({}));
        if (!resp.ok || !payload.ok) {
          throw new Error(payload.error || "Şifre güncellenemedi.");
        }
        setTokenState(true, "Şifre başarıyla güncellendi.");
        showMessage("ok", "Şifren güncellendi. Uygulamaya dönüp yeni şifrenle giriş yapabilirsin.");
      } catch (error) {
        showMessage("err", error && error.message ? error.message : "Şifre güncellenemedi.");
      } finally {
        submitBtn.disabled = false;
        submitBtn.textContent = "Şifreyi güncelle";
      }
    });
  </script>
</body>
</html>`;

  return res.status(200).set("Content-Type", "text/html; charset=utf-8").send(html);
});

app.get("/aut/reset-password", (req, res) => {
  const target = new URL("/auth/reset-password", "https://www.medcase.website");
  const original = new URL(req.originalUrl || "/aut/reset-password", "https://www.medcase.website");
  original.searchParams.forEach((value, key) => target.searchParams.set(key, value));
  return res.redirect(302, target.pathname + target.search);
});

app.get("/legal/privacy", (req, res) => {
  const cfg = getLegalConfig();
  const html = renderInfoPage({
    title: "Gizlilik Politikası",
    subtitle: "Dr.Kynox uygulamasında kişisel verilerin nasıl işlendiğini ve korunduğunu açıklar.",
    lastUpdated: cfg.lastUpdated,
    supportEmail: cfg.supportEmail,
    appDeepLink: cfg.appDeepLink,
    sections: [
      {
        heading: "Toplanan Veriler",
        paragraphs: [
          "Hesap oluşturma, giriş, vaka oturumları, skorlar ve gönüllü geri bildirim kayıtları toplanabilir.",
          "Sadece hizmetin çalışması, güvenlik kontrolleri ve ürün kalitesi için gerekli minimum veriler işlenir."
        ]
      },
      {
        heading: "Kullanım Amaçları",
        paragraphs: [
          "Vaka deneyimini sunmak, kişiselleştirilmiş performans geri bildirimi üretmek ve hesap güvenliğini korumak için kullanılır.",
          "Kötüye kullanım, güvenlik ihlali ve hata tespiti için teknik log kayıtları sınırlı süre saklanabilir."
        ]
      },
      {
        heading: "Saklama ve Güvenlik",
        paragraphs: [
          "Veriler şifreli iletişim kanalları üzerinden işlenir ve yetkisiz erişime karşı teknik-idari önlemler uygulanır.",
          "Yasal zorunluluklar ve meşru operasyon ihtiyaçları sona erdiğinde veriler silinir veya anonimleştirilir."
        ]
      },
      {
        heading: "Haklar ve Başvurular",
        paragraphs: [
          "Profil ekranından veri silme veya hesap kapatma işlemlerini başlatabilirsin.",
          `Ek talepler için ${cfg.supportEmail} adresinden bize ulaşabilirsin.`
        ]
      }
    ]
  });
  return res.status(200).set("Content-Type", "text/html; charset=utf-8").send(html);
});

app.get("/legal/terms", (req, res) => {
  const cfg = getLegalConfig();
  const html = renderInfoPage({
    title: "Kullanım Koşulları",
    subtitle: "Dr.Kynox hizmetini kullanırken geçerli olan kuralları ve sorumluluk sınırlarını belirtir.",
    lastUpdated: cfg.lastUpdated,
    supportEmail: cfg.supportEmail,
    appDeepLink: cfg.appDeepLink,
    sections: [
      {
        heading: "Hizmetin Kapsamı",
        paragraphs: [
          "Dr.Kynox eğitim amaçlı klinik vaka simülasyonu sunar. Gerçek hasta tanı ve tedavisi yerine geçmez.",
          "Hizmet içerikleri haber verilmeksizin güncellenebilir, geliştirilebilir veya kısıtlanabilir."
        ]
      },
      {
        heading: "Kullanıcı Yükümlülükleri",
        paragraphs: [
          "Hesap bilgilerinin güvenliğini sağlamak ve hizmeti hukuka uygun kullanmak kullanıcı sorumluluğundadır.",
          "Sistemi kötüye kullanma, yetkisiz erişim denemesi veya zarar verici içerik paylaşımı yasaktır."
        ]
      },
      {
        heading: "Fikri Mülkiyet ve İçerik",
        paragraphs: [
          "Uygulama markası, tasarımı ve içerikleri ilgili fikri mülkiyet mevzuatı kapsamında korunur.",
          "İzinsiz çoğaltma, yeniden dağıtım veya ticari kullanım yapılamaz."
        ]
      },
      {
        heading: "Sorumluluk Sınırı",
        paragraphs: [
          "Hizmet mümkün olan en iyi şekilde sunulsa da kesintisiz veya hatasız çalışma garantisi verilmez.",
          "Kullanım koşullarını kabul etmiyorsan uygulamayı kullanmamalısın."
        ]
      }
    ]
  });
  return res.status(200).set("Content-Type", "text/html; charset=utf-8").send(html);
});

app.get("/legal/medical-disclaimer", (req, res) => {
  const cfg = getLegalConfig();
  const html = renderInfoPage({
    title: "Tıbbi Sorumluluk Reddi",
    subtitle: "Uygulama çıktılarının eğitim amaçlı olduğunu ve klinik kararın tek kaynağı olamayacağını açıklar.",
    lastUpdated: cfg.lastUpdated,
    supportEmail: cfg.supportEmail,
    appDeepLink: cfg.appDeepLink,
    sections: [
      {
        heading: "Eğitim Amaçlı İçerik",
        paragraphs: [
          "Dr.Kynox tarafından üretilen vaka içerikleri, geri bildirimler ve skorlar yalnızca eğitim/pratik amaçlıdır.",
          "Gerçek hastaya ilişkin tanı, tedavi, ilaç veya müdahale kararlarında tek başına kullanılmamalıdır."
        ]
      },
      {
        heading: "Klinik Karar Sorumluluğu",
        paragraphs: [
          "Klinik uygulamada nihai değerlendirme ve sorumluluk yetkili sağlık profesyoneline aittir.",
          "Acil durumlarda yerel protokoller ve güncel klinik kılavuzlar öncelikli olmalıdır."
        ]
      },
      {
        heading: "Garanti Reddi",
        paragraphs: [
          "Uygulama çıktıları her senaryoda tam doğruluk veya eksiksizlik garantisi vermez.",
          "Çelişkili durumlarda resmi kılavuzlar ve kurum politikaları esas alınmalıdır."
        ]
      }
    ]
  });
  return res.status(200).set("Content-Type", "text/html; charset=utf-8").send(html);
});

app.get("/legal/kvkk", (req, res) => {
  const cfg = getLegalConfig();
  const html = renderInfoPage({
    title: "KVKK Aydınlatma Metni",
    subtitle: "6698 sayılı KVKK kapsamında veri işleme süreçleri hakkında bilgilendirme metnidir.",
    lastUpdated: cfg.lastUpdated,
    supportEmail: cfg.supportEmail,
    appDeepLink: cfg.appDeepLink,
    sections: [
      {
        heading: "Veri Sorumlusu",
        paragraphs: [
          "Dr.Kynox hizmeti kapsamında işlenen kişisel veriler ilgili mevzuata uygun olarak korunur ve yönetilir."
        ]
      },
      {
        heading: "İşlenen Kişisel Veri Kategorileri",
        paragraphs: [
          "Kimlik ve iletişim verileri (ad, e-posta, telefon), hesap ve oturum verileri, vaka etkileşim kayıtları.",
          "Geri bildirim/rapor içerikleri, güvenlik logları ve hizmet kalite ölçümleri."
        ]
      },
      {
        heading: "İşleme Amaçları ve Hukuki Sebepler",
        paragraphs: [
          "Hizmetin kurulması ve ifası, kullanıcı deneyiminin geliştirilmesi, güvenlik ve mevzuat yükümlülüklerinin yerine getirilmesi.",
          "Kanunda belirtilen hukuki sebepler çerçevesinde ve ölçülülük ilkesine uygun olarak işlenir."
        ]
      },
      {
        heading: "KVKK Hakları",
        paragraphs: [
          "Kişisel verilerin işlenip işlenmediğini öğrenme, düzeltme, silme ve itiraz haklarını kullanabilirsin.",
          `Başvurular için ${cfg.supportEmail} adresine e-posta gönderebilirsin.`
        ]
      }
    ]
  });
  return res.status(200).set("Content-Type", "text/html; charset=utf-8").send(html);
});

app.get("/legal/consent", (req, res) => {
  const cfg = getLegalConfig();
  const html = renderInfoPage({
    title: "Açık Rıza Beyanı",
    subtitle: "Belirli veri işleme faaliyetleri için kullanıcı onayına ilişkin bilgilendirme metnidir.",
    lastUpdated: cfg.lastUpdated,
    supportEmail: cfg.supportEmail,
    appDeepLink: cfg.appDeepLink,
    sections: [
      {
        heading: "Rıza Kapsamı",
        paragraphs: [
          "Açık rıza gerektiren işlemler yalnızca ilgili izin verildiğinde yürütülür.",
          "Rıza metni, işleme amacı, kapsamı ve saklama süresi konusunda açık bilgi sağlar."
        ]
      },
      {
        heading: "Rızanın Geri Alınması",
        paragraphs: [
          "Rıza herhangi bir zamanda geri alınabilir. Geri alma işlemi geçmişe dönük değil, ileriye etkili olarak uygulanır.",
          "Rıza geri alındığında ilgili işleme faaliyeti durdurulur."
        ]
      },
      {
        heading: "Tercih Yönetimi",
        paragraphs: [
          "Bildirim ve pazarlama tercihlerinin yönetimi profil ve ayar alanlarından yapılabilir.",
          "Detaylı talepler için destek kanalları üzerinden iletişime geçebilirsin."
        ]
      }
    ]
  });
  return res.status(200).set("Content-Type", "text/html; charset=utf-8").send(html);
});

app.get("/support", (req, res) => {
  const cfg = getLegalConfig();
  const html = renderInfoPage({
    title: "Destek",
    subtitle: "Teknik sorunlar, hesap işlemleri ve içerik geri bildirimleri için destek kanalları.",
    lastUpdated: cfg.lastUpdated,
    supportEmail: cfg.supportEmail,
    appDeepLink: cfg.appDeepLink,
    sections: [
      {
        heading: "Hızlı Destek",
        paragraphs: [
          "Uygulama içinde Profil > Gizlilik ve Hesap alanından 'Sorunlu İçeriği Raporla' ve 'Feedback Gönder' seçeneklerini kullanabilirsin.",
          "Bu bildirimler doğrudan destek inceleme kuyruğuna düşer."
        ]
      },
      {
        heading: "E-posta İletişimi",
        paragraphs: [
          `Destek taleplerin için ${cfg.supportEmail} adresine e-posta gönderebilirsin.`,
          "Mesajında mümkünse cihaz modeli, uygulama sürümü ve karşılaştığın hatayı paylaş."
        ]
      },
      {
        heading: "Yanıt Süresi",
        paragraphs: [
          "Yoğunluğa göre destek dönüş süresi değişebilir. Kritik erişim problemleri öncelikli ele alınır."
        ]
      }
    ]
  });
  return res.status(200).set("Content-Type", "text/html; charset=utf-8").send(html);
});

app.get("/api/health", (req, res) => {
  return res.json({
    ok: true,
    service: "drkynox-backend",
    timestamp: new Date().toISOString()
  });
});

app.post("/api/debug/simulate-error", async (req, res, next) => {
  try {
    const debugCfg = getDebugErrorConfig();
    if (!debugCfg.enabled) {
      return res.status(404).json({
        error: "Debug error simülasyonu kapalı."
      });
    }

    const aiCfg = getAiAccessConfig();
    const token = String(req.headers["x-admin-token"] || req.body?.adminToken || "").trim();
    if (aiCfg.adminToken && token !== aiCfg.adminToken) {
      return res.status(403).json({
        error: "Debug simülasyon yetkisi reddedildi."
      });
    }

    const parsedBody = parseJsonWithZod(res, debugSimulateBodySchema, req.body, {
      message: "Debug simülasyon isteği geçersiz."
    });
    if (!parsedBody) {
      return;
    }

    const customMessage = sanitizeReportText(parsedBody.message || "", 120) || null;
    const errorMap = {
      openai: {
        status: 503,
        code: ERROR_CODES.OPENAI_UNAVAILABLE,
        service: "openai",
        message: "OpenAI servis bağlantısı simüle edildi."
      },
      "openai-timeout": {
        status: 504,
        code: ERROR_CODES.EXTERNAL_TIMEOUT,
        service: "openai",
        message: "OpenAI timeout simülasyonu."
      },
      elevenlabs: {
        status: 503,
        code: ERROR_CODES.ELEVENLABS_UNAVAILABLE,
        service: "elevenlabs",
        message: "ElevenLabs servis hatası simülasyonu."
      },
      "elevenlabs-timeout": {
        status: 504,
        code: ERROR_CODES.EXTERNAL_TIMEOUT,
        service: "elevenlabs",
        message: "ElevenLabs timeout simülasyonu."
      },
      supabase: {
        status: 503,
        code: ERROR_CODES.SUPABASE_UNAVAILABLE,
        service: "supabase",
        message: "Supabase servis hatası simülasyonu."
      },
      upstash: {
        status: 503,
        code: ERROR_CODES.UPSTASH_UNAVAILABLE,
        service: "upstash",
        message: "Upstash servis hatası simülasyonu."
      },
      validation: {
        status: 400,
        code: ERROR_CODES.VALIDATION,
        service: "api",
        message: "Validation hatası simülasyonu."
      },
      "rate-limit": {
        status: 429,
        code: ERROR_CODES.RATE_LIMIT,
        service: "api",
        message: "Rate limit hatası simülasyonu."
      },
      unknown: {
        status: 500,
        code: ERROR_CODES.UNKNOWN,
        service: "app",
        message: "Bilinmeyen hata simülasyonu."
      }
    };

    const cfg = errorMap[parsedBody.case] || errorMap.unknown;
    return next(
      new AppError({
        status: cfg.status,
        code: cfg.code,
        service: cfg.service,
        message: customMessage || cfg.message,
        details: {
          simulated: true,
          case: parsedBody.case
        }
      })
    );
  } catch (error) {
    return next(error);
  }
});

app.get("/api/public-config", (req, res) => {
  const { supabaseUrl, supabaseAnonKey, authorizationUrl } = getSupabaseConfig();
  const missing = [];
  if (!supabaseUrl) {
    missing.push("SUPABASE_URL");
  }
  if (!supabaseAnonKey) {
    missing.push("SUPABASE_ANON_KEY");
  }

  if (missing.length) {
    return res.status(503).json({
      error: `Supabase bağlantı ayarları eksik: ${missing.join(", ")}`
    });
  }

  return res.json({
    supabaseUrl,
    supabaseAnonKey,
    authorizationUrl
  });
});

app.get("/api/admin/panel/stats/overview", requireAdminApiSession, async (req, res) => {
  noStoreAdminResponse(res);
  const { supabaseUrl, supabaseServiceRoleKey } = getSupabaseConfig();
  if (!supabaseUrl || !supabaseServiceRoleKey) {
    return res.status(503).json({
      error: "Supabase ayarları eksik."
    });
  }

  try {
    const settled = await Promise.allSettled([
      fetchAuthUsersOverview({ supabaseUrl, supabaseServiceRoleKey }),
      fetchCaseCompletionStats({ supabaseUrl, supabaseServiceRoleKey }),
      countActiveSessionKeys(),
      fetchLast7DaysCaseSeries({ supabaseUrl, supabaseServiceRoleKey }),
      fetchApiRequestsLastHour(),
      fetchRateLimitViolationsLast24h({ supabaseUrl, supabaseServiceRoleKey }),
      fetchRateLimitViolationsInsights({ supabaseUrl, supabaseServiceRoleKey, hours: 24, limit: 600 }),
      fetchElevenLabsUsageSummary(),
      fetchApiRequestBreakdownLastHour({ endpointLimit: 8, callerLimit: 8 }),
      fetchProfilesOverview({ supabaseUrl, supabaseServiceRoleKey }),
      getRecentErrorLogsForAdmin(10)
    ]);

    const authUsers =
      settled[0].status === "fulfilled"
        ? settled[0].value
        : {
            totalUsers: 0,
            todayUsers: 0,
            confirmedUsers: 0,
            unconfirmedUsers: 0,
            suspendedUsers: 0,
            activeUsersLast24h: 0
          };
    const completion =
      settled[1].status === "fulfilled" ? settled[1].value : { totalCompleted: 0, todayCompleted: 0 };
    const activeSessions =
      settled[2].status === "fulfilled"
        ? settled[2].value
        : {
            total: 0,
            voice: 0,
            text: 0
          };
    const series = settled[3].status === "fulfilled" ? settled[3].value : [];
    const requestsLastHour = settled[4].status === "fulfilled" ? settled[4].value : 0;
    const rlViolations = settled[5].status === "fulfilled" ? settled[5].value : 0;
    const rlInsights =
      settled[6].status === "fulfilled"
        ? settled[6].value
        : {
            windowHours: 24,
            sampledRows: 0,
            categories: { internal: 0, external: 0, monitoring: 0, unknown: 0 },
            diagnosis: "Rate limit detay verisi alınamadı.",
            uniqueIdentities: 0,
            topScopes: [],
            topEndpoints: [],
            topIdentities: [],
            recentEvents: []
          };
    const elevenUsage =
      settled[7].status === "fulfilled"
        ? settled[7].value
        : {
            totalSessions: 0,
            lastHourSessions: 0,
            agents: []
          };
    const apiRequestBreakdown =
      settled[8].status === "fulfilled"
        ? settled[8].value
        : {
            total: requestsLastHour,
            success: 0,
            error: 0,
            endpointCount: 0,
            callerCount: 0,
            topEndpoints: [],
            topCallers: []
          };
    const profileStats =
      settled[9].status === "fulfilled"
        ? settled[9].value
        : {
            latestProfiles: []
          };
    const recentErrors = settled[10].status === "fulfilled" ? settled[10].value : [];

    const formattedSeries = Array.isArray(series)
      ? series.map((item) => ({
          ...item,
          label: String(item.date || "").slice(5).replace("-", "/")
        }))
      : [];

    return res.json({
      ok: true,
      totalUsers: authUsers.totalUsers,
      todayUsers: authUsers.todayUsers,
      confirmedUsers: authUsers.confirmedUsers,
      unconfirmedUsers: authUsers.unconfirmedUsers,
      suspendedUsers: authUsers.suspendedUsers,
      activeUsersLast24h: authUsers.activeUsersLast24h,
      totalCompletedCases: completion.totalCompleted,
      todayCompletedCases: completion.todayCompleted,
      activeSessions,
      last7CaseSeries: formattedSeries,
      apiRequestsLastHour: requestsLastHour,
      apiRequestBreakdown,
      rateLimitViolationsLast24h: rlViolations,
      rateLimitInsights: rlInsights,
      elevenLabsUsage: elevenUsage,
      latestUsers: Array.isArray(profileStats?.latestProfiles) ? profileStats.latestProfiles.slice(0, 8) : [],
      recentErrors: Array.isArray(recentErrors) ? recentErrors.slice(0, 8) : []
    });
  } catch (error) {
    await captureAppError({
      error,
      req,
      res,
      fallback: {
        service: "admin-api",
        code: ERROR_CODES.INTERNAL,
        status: 500
      },
      metadata: {
        route: "/api/admin/panel/stats/overview"
      }
    });
    return res.status(500).json({
      error: error?.message || "Overview istatistikleri hazırlanamadı."
    });
  }
});

app.get("/api/admin/panel/stats/analytics", requireAdminApiSession, async (req, res) => {
  noStoreAdminResponse(res);
  const { supabaseUrl, supabaseServiceRoleKey } = getSupabaseConfig();
  if (!supabaseUrl || !supabaseServiceRoleKey) {
    return res.status(503).json({
      error: "Supabase ayarları eksik."
    });
  }

  try {
    const rows = await fetchCaseSessionsForAnalytics({
      supabaseUrl,
      supabaseServiceRoleKey,
      limit: clampRateLimitValue(process.env.ADMIN_ANALYTICS_MAX_ROWS, 5000, 200, 20000)
    });
    const summary = buildAdminAnalyticsSummary(rows);
    return res.json({
      ok: true,
      ...summary
    });
  } catch (error) {
    return res.status(500).json({
      error: error?.message || "Analytics verisi hazırlanamadı."
    });
  }
});

app.get("/api/admin/panel/ai-prompts", requireAdminApiSession, async (req, res) => {
  noStoreAdminResponse(res);
  try {
    const catalog = buildAdminAiPromptCatalog();
    return res.json({
      ok: true,
      ...catalog
    });
  } catch (error) {
    return res.status(500).json({
      error: error?.message || "AI prompt envanteri alınamadı."
    });
  }
});

app.get("/api/admin/panel/broadcast/overview", requireAdminApiSession, async (req, res) => {
  noStoreAdminResponse(res);
  const { supabaseUrl, supabaseServiceRoleKey } = getSupabaseConfig();
  if (!supabaseUrl || !supabaseServiceRoleKey) {
    return res.status(503).json({
      error: "Supabase ayarları eksik."
    });
  }

  try {
    const [devices, inAppUsers, recent] = await Promise.all([
      fetchPushEligibleDevices({
        supabaseUrl,
        supabaseServiceRoleKey,
        limit: clampRateLimitValue(process.env.ADMIN_BROADCAST_ELIGIBLE_LIMIT, 12000, 100, 50000)
      }),
      fetchInAppEligibleUserIds({
        supabaseUrl,
        supabaseServiceRoleKey,
        limit: clampRateLimitValue(process.env.ADMIN_BROADCAST_IN_APP_LIMIT, 20000, 100, 100000)
      }),
      fetchRecentBroadcasts({
        supabaseUrl,
        supabaseServiceRoleKey,
        limit: 10
      })
    ]);
    const pushUsers = Array.from(
      new Set(devices.map((item) => sanitizeUuid(item?.userId)).filter(Boolean))
    );
    const apnsCfg = getApnsConfig();
    return res.json({
      ok: true,
      recipients: {
        users: pushUsers.length,
        pushUsers: pushUsers.length,
        inAppUsers: inAppUsers.length,
        devices: devices.length
      },
      apns: {
        ready: Boolean(apnsCfg.keyId && apnsCfg.teamId && apnsCfg.bundleId && apnsCfg.privateKey),
        environment: apnsCfg.environment
      },
      recent
    });
  } catch (error) {
    return res.status(500).json({
      error: error?.message || "Broadcast overview alınamadı."
    });
  }
});

app.post("/api/admin/panel/broadcast/send", requireAdminApiSession, requireAdminCsrf, async (req, res) => {
  noStoreAdminResponse(res);
  const parsedBody = parseJsonWithZod(res, adminBroadcastSendBodySchema, req.body, {
    message: "Broadcast gönderim isteği geçersiz."
  });
  if (!parsedBody) {
    return;
  }

  const { supabaseUrl, supabaseServiceRoleKey } = getSupabaseConfig();
  if (!supabaseUrl || !supabaseServiceRoleKey) {
    return res.status(503).json({
      error: "Supabase ayarları eksik."
    });
  }

  const pushEnabled = parsedBody.pushEnabled !== false;
  const inAppEnabled = parsedBody.inAppEnabled !== false;
  if (!pushEnabled && !inAppEnabled) {
    return res.status(400).json({
      error: "En az bir gönderim kanalı seçmelisin."
    });
  }

  const title = sanitizeReportText(parsedBody.title || "", 120);
  const body = sanitizeReportText(parsedBody.body || "", 420);
  const deepLink = String(parsedBody.deepLink || "").trim().slice(0, 300);
  if (!title || !body) {
    return res.status(400).json({
      error: "Başlık ve mesaj zorunlu."
    });
  }

  try {
    const devices = await fetchPushEligibleDevices({
      supabaseUrl,
      supabaseServiceRoleKey,
      limit: clampRateLimitValue(process.env.ADMIN_BROADCAST_ELIGIBLE_LIMIT, 12000, 100, 50000)
    });
    const pushUserIds = Array.from(
      new Set(devices.map((item) => sanitizeUuid(item?.userId)).filter(Boolean))
    );
    const inAppUserIds = inAppEnabled
      ? await fetchInAppEligibleUserIds({
          supabaseUrl,
          supabaseServiceRoleKey,
          limit: clampRateLimitValue(process.env.ADMIN_BROADCAST_IN_APP_LIMIT, 20000, 100, 100000)
        })
      : [];
    const targetUserIds = Array.from(new Set([...pushUserIds, ...inAppUserIds]));
    const pushUserSet = new Set(pushUserIds);

    if (!targetUserIds.length) {
      return res.status(409).json({
        error: "Hedef kullanıcı bulunamadı."
      });
    }

    const now = new Date();
    const expiresHours = clampRateLimitValue(parsedBody.expiresHours, 48, 1, 168);
    const expiresAtIso = new Date(now.getTime() + expiresHours * 60 * 60 * 1000).toISOString();
    const createdBy = String(req.adminSession?.sub || "admin").trim().slice(0, 120);

    const broadcastRow = await insertBroadcast({
      supabaseUrl,
      supabaseServiceRoleKey,
      row: {
        title,
        body,
        deep_link: deepLink || null,
        push_enabled: pushEnabled,
        in_app_enabled: inAppEnabled,
        expires_at: expiresAtIso,
        created_by: createdBy,
        created_at: now.toISOString()
      }
    });

    const broadcastId = sanitizeUuid(broadcastRow?.id);
    if (!broadcastId) {
      throw new Error("Broadcast kaydı oluşturuldu ancak id alınamadı.");
    }

    const targetRows = targetUserIds.map((userId) => ({
      broadcast_id: broadcastId,
      user_id: userId,
      push_status: pushEnabled && pushUserSet.has(userId) ? "pending" : "skipped",
      created_at: now.toISOString(),
      updated_at: now.toISOString()
    }));
    await upsertBroadcastTargets({
      supabaseUrl,
      supabaseServiceRoleKey,
      rows: targetRows
    });

    let pushResult = {
      sent: 0,
      failed: 0
    };

    if (pushEnabled) {
      const delivery = await sendApnsBatch({
        devices,
        title,
        body,
        deepLink
      });
      pushResult = {
        sent: delivery.sentCount,
        failed: delivery.failedCount
      };

      const statusByUser = new Map();
      for (const item of delivery.statuses) {
        const userId = sanitizeUuid(item?.userId);
        if (!userId) {
          continue;
        }
        const prev = statusByUser.get(userId);
        if (!prev) {
          statusByUser.set(userId, {
            ok: Boolean(item?.ok),
            reason: String(item?.reason || "").trim()
          });
          continue;
        }
        if (prev.ok) {
          continue;
        }
        if (item?.ok) {
          statusByUser.set(userId, {
            ok: true,
            reason: ""
          });
        } else if (!prev.reason) {
          prev.reason = String(item?.reason || "").trim();
        }
      }

      const statusRows = targetUserIds.map((userId) => {
        if (!pushUserSet.has(userId)) {
          return {
            broadcast_id: broadcastId,
            user_id: userId,
            push_status: "skipped",
            push_error: "NO_ELIGIBLE_DEVICE",
            updated_at: new Date().toISOString()
          };
        }
        const userStatus = statusByUser.get(userId);
        if (!userStatus) {
          return {
            broadcast_id: broadcastId,
            user_id: userId,
            push_status: "failed",
            push_error: "APNS_SEND_SKIPPED",
            updated_at: new Date().toISOString()
          };
        }
        if (userStatus.ok) {
          return {
            broadcast_id: broadcastId,
            user_id: userId,
            push_status: "sent",
            push_sent_at: new Date().toISOString(),
            push_error: null,
            updated_at: new Date().toISOString()
          };
        }
        return {
          broadcast_id: broadcastId,
          user_id: userId,
          push_status: "failed",
          push_error: sanitizeReportText(userStatus.reason || "APNS_SEND_FAILED", 160),
          updated_at: new Date().toISOString()
        };
      });

      await upsertBroadcastTargets({
        supabaseUrl,
        supabaseServiceRoleKey,
        rows: statusRows
      });
    }

    return res.json({
      ok: true,
      broadcast: {
        id: broadcastId,
        title,
        created_at: broadcastRow?.created_at || now.toISOString()
      },
      targets: {
        users: targetUserIds.length,
        pushUsers: pushUserIds.length,
        inAppUsers: inAppUserIds.length,
        devices: devices.length
      },
      push: pushResult,
      in_app: {
        enabled: inAppEnabled
      }
    });
  } catch (error) {
    await captureAppError({
      error,
      req,
      res,
      fallback: {
        service: "admin-broadcast",
        code: ERROR_CODES.INTERNAL,
        status: 500
      },
      metadata: {
        route: "/api/admin/panel/broadcast/send"
      }
    });
    return res.status(500).json({
      error: error?.message || "Broadcast gönderimi başarısız."
    });
  }
});

app.get("/api/admin/panel/stats/users", requireAdminApiSession, async (req, res) => {
  noStoreAdminResponse(res);
  const { supabaseUrl, supabaseServiceRoleKey } = getSupabaseConfig();
  if (!supabaseUrl || !supabaseServiceRoleKey) {
    return res.status(503).json({
      error: "Supabase ayarları eksik."
    });
  }
  try {
    const page = clampRateLimitValue(req.query?.page, 1, 1, 100000);
    const perPage = clampRateLimitValue(req.query?.perPage, 12, 5, 50);
    const search = sanitizeAdminSearchTerm(req.query?.search || "");
    const settled = await Promise.allSettled([
      fetchAuthUsersOverview({ supabaseUrl, supabaseServiceRoleKey }),
      fetchProfilesOverview({ supabaseUrl, supabaseServiceRoleKey }),
      fetchAdminProfilesPage({
        supabaseUrl,
        supabaseServiceRoleKey,
        page,
        perPage,
        search
      })
    ]);
    const authUsers =
      settled[0].status === "fulfilled"
        ? settled[0].value
        : {
            totalUsers: 0,
            todayUsers: 0,
            confirmedUsers: 0,
            unconfirmedUsers: 0,
            suspendedUsers: 0,
            activeUsersLast24h: 0
          };
    const profileStats =
      settled[1].status === "fulfilled"
        ? settled[1].value
        : {
            totalProfiles: 0,
            onboardingDone: 0,
            latestProfiles: []
          };
    const pageData =
      settled[2].status === "fulfilled"
        ? settled[2].value
        : {
            total: 0,
            page,
            perPage,
            totalPages: 1,
            search,
            rows: []
          };

    let caseStatsByUser = {};
    try {
      caseStatsByUser = await fetchCaseStatsForUserIds({
        supabaseUrl,
        supabaseServiceRoleKey,
        userIds: pageData.rows.map((row) => row?.id)
      });
    } catch {
      caseStatsByUser = {};
    }

    let authUsersById = {};
    try {
      authUsersById = await fetchAuthUsersByIds({
        supabaseUrl,
        supabaseServiceRoleKey,
        userIds: pageData.rows.map((row) => row?.id)
      });
    } catch {
      authUsersById = {};
    }

    const users = pageData.rows.map((row) => {
      const userId = sanitizeUuid(row?.id);
      const stats = caseStatsByUser?.[userId] || {};
      const authRow = authUsersById?.[userId] || null;
      const bannedUntil = String(authRow?.banned_until || "").trim();
      const isSuspended = Boolean(bannedUntil && Date.parse(bannedUntil) > Date.now());
      return {
        id: userId,
        full_name: row?.full_name || null,
        display_name: String(row?.full_name || "").trim() || "Belirtilmemiş",
        email: row?.email || authRow?.email || null,
        role: row?.role || null,
        learning_level: row?.learning_level || null,
        onboarding_completed: Boolean(row?.onboarding_completed),
        updated_at: row?.updated_at || null,
        phone_number: row?.phone_number || null,
        email_confirmed_at: authRow?.email_confirmed_at || authRow?.confirmed_at || null,
        last_sign_in_at: authRow?.last_sign_in_at || null,
        created_at: authRow?.created_at || null,
        is_suspended: isSuspended,
        banned_until: bannedUntil || null,
        case_count: Number(stats?.completedCases || 0),
        average_score: Number.isFinite(Number(stats?.averageScore)) ? Number(stats.averageScore) : null,
        last_case_at: stats?.lastCompletedAt || null
      };
    });

    const onboardingDone = Number(profileStats.onboardingDone || 0);
    const totalProfiles = Number(profileStats.totalProfiles || 0);
    const onboardingPending = Math.max(0, totalProfiles - onboardingDone);

    return res.json({
      ok: true,
      totalUsers: authUsers.totalUsers,
      todayUsers: authUsers.todayUsers,
      confirmedUsers: authUsers.confirmedUsers,
      unconfirmedUsers: authUsers.unconfirmedUsers,
      suspendedUsers: authUsers.suspendedUsers,
      activeUsersLast24h: authUsers.activeUsersLast24h,
      totalProfiles: profileStats.totalProfiles,
      onboardingDone,
      onboardingPending,
      latestProfiles: profileStats.latestProfiles,
      users,
      pagination: {
        page: pageData.page,
        perPage: pageData.perPage,
        total: pageData.total,
        totalPages: pageData.totalPages
      },
      search: pageData.search
    });
  } catch (error) {
    return res.status(500).json({
      error: error?.message || "Kullanıcı istatistikleri hazırlanamadı."
    });
  }
});

app.post("/api/admin/panel/users", requireAdminApiSession, requireAdminCsrf, async (req, res) => {
  noStoreAdminResponse(res);
  const { supabaseUrl, supabaseServiceRoleKey } = getSupabaseConfig();
  if (!supabaseUrl || !supabaseServiceRoleKey) {
    return res.status(503).json({
      error: "Supabase ayarları eksik."
    });
  }

  const parsedBody = parseJsonWithZod(
    res,
    adminCreateUserBodySchema,
    req.body,
    { message: "Yeni kullanıcı gövdesi geçersiz." }
  );
  if (!parsedBody) {
    return;
  }

  const cleanEmail = sanitizeEmail(parsedBody.email);
  if (!cleanEmail) {
    return res.status(400).json({
      error: "Geçerli e-posta gerekli."
    });
  }
  const firstName = String(parsedBody.firstName || "").trim();
  const lastName = String(parsedBody.lastName || "").trim();
  const fullName = `${firstName} ${lastName}`.trim();
  const fallbackPassword = `DrKynox!${crypto.randomBytes(4).toString("hex")}`;
  const providedPassword = String(parsedBody.password || "").trim();
  const effectivePassword = providedPassword || fallbackPassword;
  const role = String(parsedBody.role || "").trim() || null;
  const learningLevel = String(parsedBody.learningLevel || "").trim() || null;
  const phoneNumber = String(parsedBody.phoneNumber || "").trim() || null;
  const onboardingCompleted = Boolean(parsedBody.onboardingCompleted);
  const marketingOptIn = Boolean(parsedBody.marketingOptIn);
  const emailConfirmed = Boolean(parsedBody.emailConfirmed);

  let createdUser = null;
  try {
    createdUser = await createAuthUserByAdmin({
      supabaseUrl,
      supabaseServiceRoleKey,
      email: cleanEmail,
      password: effectivePassword,
      emailConfirmed,
      firstName,
      lastName,
      fullName,
      phoneNumber: phoneNumber || ""
    });
    const userId = sanitizeUuid(createdUser?.id);
    if (!userId) {
      throw new Error("Oluşturulan kullanıcı kimliği alınamadı.");
    }

    await upsertProfileRow({
      supabaseUrl,
      supabaseServiceRoleKey,
      row: {
        id: userId,
        email: cleanEmail,
        full_name: fullName || cleanEmail.split("@")[0],
        role,
        learning_level: learningLevel,
        phone_number: phoneNumber,
        onboarding_completed: onboardingCompleted,
        marketing_opt_in: marketingOptIn,
        updated_at: new Date().toISOString()
      },
      errorPrefix: "Yeni kullanıcı profili yazılamadı"
    });

    return res.status(201).json({
      ok: true,
      user: {
        id: userId,
        email: cleanEmail,
        full_name: fullName || null,
        role,
        learning_level: learningLevel,
        onboarding_completed: onboardingCompleted,
        email_confirmed_at: emailConfirmed ? new Date().toISOString() : null
      },
      generatedPassword: providedPassword ? null : fallbackPassword
    });
  } catch (error) {
    const createdUserId = sanitizeUuid(createdUser?.id);
    if (createdUserId) {
      try {
        await deleteAuthUserById({
          supabaseUrl,
          supabaseServiceRoleKey,
          userId: createdUserId
        });
      } catch {
        // rollback best-effort
      }
    }
    return res.status(500).json({
      error: error?.message || "Yeni kullanıcı oluşturulamadı."
    });
  }
});

app.get("/api/admin/panel/users/:userId", requireAdminApiSession, async (req, res) => {
  noStoreAdminResponse(res);
  const { supabaseUrl, supabaseServiceRoleKey } = getSupabaseConfig();
  if (!supabaseUrl || !supabaseServiceRoleKey) {
    return res.status(503).json({
      error: "Supabase ayarları eksik."
    });
  }
  const userId = sanitizeUuid(req.params?.userId);
  if (!userId) {
    return res.status(400).json({
      error: "Geçerli kullanıcı kimliği gerekli."
    });
  }

  try {
    const settled = await Promise.allSettled([
      fetchProfileRow({ supabaseUrl, supabaseServiceRoleKey, userId }),
      fetchAuthUserById({ supabaseUrl, supabaseServiceRoleKey, userId }),
      fetchCaseStatsForUserIds({ supabaseUrl, supabaseServiceRoleKey, userIds: [userId] }),
      fetchRecentCaseSessionsForUser({ supabaseUrl, supabaseServiceRoleKey, userId, limit: 12 })
    ]);

    const profile = settled[0].status === "fulfilled" ? settled[0].value : null;
    const authUser = settled[1].status === "fulfilled" ? settled[1].value : null;
    const statsMap = settled[2].status === "fulfilled" ? settled[2].value : {};
    const recentSessions = settled[3].status === "fulfilled" ? settled[3].value : [];
    const stats = statsMap?.[userId] || {};
    const bannedUntil = String(authUser?.banned_until || "").trim() || null;
    const isSuspended = Boolean(bannedUntil && Date.parse(bannedUntil) > Date.now());

    return res.json({
      ok: true,
      user: {
        id: userId,
        full_name: profile?.full_name || null,
        display_name: String(profile?.full_name || "").trim() || "Belirtilmemiş",
        email: profile?.email || authUser?.email || null,
        phone_number: profile?.phone_number || null,
        role: profile?.role || null,
        learning_level: profile?.learning_level || null,
        onboarding_completed: Boolean(profile?.onboarding_completed),
        marketing_opt_in: Boolean(profile?.marketing_opt_in),
        updated_at: profile?.updated_at || authUser?.updated_at || null,
        created_at: authUser?.created_at || null,
        last_sign_in_at: authUser?.last_sign_in_at || null,
        email_confirmed_at: authUser?.email_confirmed_at || authUser?.confirmed_at || null,
        is_suspended: isSuspended,
        banned_until: bannedUntil
      },
      caseStats: {
        completedCases: Number(stats?.completedCases || 0),
        averageScore: Number.isFinite(Number(stats?.averageScore)) ? Number(stats.averageScore) : null,
        lastCompletedAt: stats?.lastCompletedAt || null
      },
      recentSessions: (Array.isArray(recentSessions) ? recentSessions : []).map((row) => ({
        id: row?.id || null,
        session_id: row?.session_id || null,
        status: row?.status || null,
        mode: row?.mode || null,
        difficulty: row?.difficulty || null,
        specialty: row?.case_context?.specialty || row?.case_context?.specialty_name || null,
        created_at: row?.created_at || null,
        ended_at: row?.ended_at || null,
        score: extractScoreNumber(row?.score)
      }))
    });
  } catch (error) {
    return res.status(500).json({
      error: error?.message || "Kullanıcı detayı alınamadı."
    });
  }
});

app.post("/api/admin/panel/users/:userId/suspend", requireAdminApiSession, requireAdminCsrf, async (req, res) => {
  noStoreAdminResponse(res);
  const { supabaseUrl, supabaseServiceRoleKey } = getSupabaseConfig();
  if (!supabaseUrl || !supabaseServiceRoleKey) {
    return res.status(503).json({
      error: "Supabase ayarları eksik."
    });
  }
  const userId = sanitizeUuid(req.params?.userId);
  if (!userId) {
    return res.status(400).json({
      error: "Geçerli kullanıcı kimliği gerekli."
    });
  }

  const parsedBody = parseJsonWithZod(
    res,
    z.object({
      suspended: z.boolean(),
      hours: z.number().int().min(1).max(24 * 365).optional()
    }),
    req.body,
    { message: "Askı işlemi gövdesi geçersiz." }
  );
  if (!parsedBody) {
    return;
  }

  const suspended = Boolean(parsedBody.suspended);
  const hours = clampRateLimitValue(parsedBody.hours, 24, 1, 24 * 365);
  try {
    const user = await updateAuthUserBanStatus({
      supabaseUrl,
      supabaseServiceRoleKey,
      userId,
      suspended,
      hours
    });
    if (suspended) {
      await clearActiveElevenSession({ userId });
    }
    return res.json({
      ok: true,
      userId,
      suspended,
      banned_until: user?.banned_until || null
    });
  } catch (error) {
    return res.status(500).json({
      error: error?.message || "Askı durumu güncellenemedi."
    });
  }
});

app.delete("/api/admin/panel/users/:userId", requireAdminApiSession, requireAdminCsrf, async (req, res) => {
  noStoreAdminResponse(res);
  const { supabaseUrl, supabaseServiceRoleKey } = getSupabaseConfig();
  if (!supabaseUrl || !supabaseServiceRoleKey) {
    return res.status(503).json({
      error: "Supabase ayarları eksik."
    });
  }
  const userId = sanitizeUuid(req.params?.userId);
  if (!userId) {
    return res.status(400).json({
      error: "Geçerli kullanıcı kimliği gerekli."
    });
  }

  try {
    await clearActiveElevenSession({ userId });
    const cleanupWarnings = [];
    const cleanupCounts = {};

    const safeCleanup = async (label, fn) => {
      try {
        const count = await fn();
        cleanupCounts[label] = Number(count || 0);
      } catch (error) {
        cleanupWarnings.push(`${label}: ${error?.message || "temizlenemedi"}`);
      }
    };

    await safeCleanup("case_sessions", () =>
      deleteCaseSessionsByUserId({ supabaseUrl, supabaseServiceRoleKey, userId })
    );
    await safeCleanup("profiles", () =>
      deleteProfileByUserId({ supabaseUrl, supabaseServiceRoleKey, userId })
    );
    await safeCleanup("flashcards", () =>
      deleteRowsByUserId({ supabaseUrl, supabaseServiceRoleKey, table: "flashcards", userId })
    );
    await safeCleanup("daily_challenge_attempts", () =>
      deleteRowsByUserId({ supabaseUrl, supabaseServiceRoleKey, table: "daily_challenge_attempts", userId })
    );
    await safeCleanup("content_reports", () =>
      deleteRowsByUserId({ supabaseUrl, supabaseServiceRoleKey, table: "content_reports", userId })
    );
    await safeCleanup("user_feedback", () =>
      deleteRowsByUserId({ supabaseUrl, supabaseServiceRoleKey, table: "user_feedback", userId })
    );
    await safeCleanup("app_sessions", () =>
      deleteRowsByUserId({ supabaseUrl, supabaseServiceRoleKey, table: "app_sessions", userId })
    );
    await safeCleanup("scoring_jobs", () =>
      deleteRowsByUserId({ supabaseUrl, supabaseServiceRoleKey, table: "scoring_jobs", userId })
    );
    await safeCleanup("widget_events", () =>
      deleteRowsByUserId({ supabaseUrl, supabaseServiceRoleKey, table: "widget_events", userId })
    );
    await safeCleanup("gdpr_requests", () =>
      deleteRowsByUserId({ supabaseUrl, supabaseServiceRoleKey, table: "gdpr_requests", userId })
    );

    await deleteAuthUserById({ supabaseUrl, supabaseServiceRoleKey, userId });

    return res.json({
      ok: true,
      userId,
      cleanupCounts,
      cleanupWarnings
    });
  } catch (error) {
    return res.status(500).json({
      error: error?.message || "Kullanıcı silinemedi."
    });
  }
});

app.get("/api/admin/panel/stats/sessions", requireAdminApiSession, async (req, res) => {
  noStoreAdminResponse(res);
  const { supabaseUrl, supabaseServiceRoleKey } = getSupabaseConfig();
  if (!supabaseUrl || !supabaseServiceRoleKey) {
    return res.status(503).json({
      error: "Supabase ayarları eksik."
    });
  }
  try {
    const settled = await Promise.allSettled([
      countActiveSessionKeys(),
      fetchApiRequestsLastHour(),
      fetchRateLimitViolationsLast24h({ supabaseUrl, supabaseServiceRoleKey }),
      fetchRateLimitViolationsInsights({ supabaseUrl, supabaseServiceRoleKey, hours: 24, limit: 700 }),
      fetchElevenLabsUsageSummary(),
      fetchApiRequestBreakdownLastHour({ endpointLimit: 12, callerLimit: 12 }),
      fetchApiRequestsHourlySeriesLast24h(),
      fetchRecentSessionsForAdmin({ supabaseUrl, supabaseServiceRoleKey, limit: 60 })
    ]);
    const activeSessions =
      settled[0].status === "fulfilled"
        ? settled[0].value
        : {
            total: 0,
            voice: 0,
            text: 0
          };
    const apiRequestsLastHour = settled[1].status === "fulfilled" ? settled[1].value : 0;
    const rlViolations = settled[2].status === "fulfilled" ? settled[2].value : 0;
    const rlInsights =
      settled[3].status === "fulfilled"
        ? settled[3].value
        : {
            windowHours: 24,
            sampledRows: 0,
            categories: { internal: 0, external: 0, monitoring: 0, unknown: 0 },
            diagnosis: "Rate limit detay verisi alınamadı.",
            uniqueIdentities: 0,
            topScopes: [],
            topEndpoints: [],
            topIdentities: [],
            recentEvents: []
          };
    const elevenLabsUsage =
      settled[4].status === "fulfilled"
        ? settled[4].value
        : {
            totalSessions: 0,
            lastHourSessions: 0,
            agents: []
          };
    const apiRequestBreakdown =
      settled[5].status === "fulfilled"
        ? settled[5].value
        : {
            total: apiRequestsLastHour,
            success: 0,
            error: 0,
            endpointCount: 0,
            callerCount: 0,
            topEndpoints: [],
            topCallers: []
          };
    const apiRequestsHourlySeries =
      settled[6].status === "fulfilled" && Array.isArray(settled[6].value) ? settled[6].value : [];
    const recentSessions =
      settled[7].status === "fulfilled" && Array.isArray(settled[7].value) ? settled[7].value : [];
    return res.json({
      ok: true,
      activeSessions,
      apiRequestsLastHour,
      rateLimitViolationsLast24h: rlViolations,
      rateLimitInsights: rlInsights,
      elevenLabsUsage,
      apiRequestBreakdown,
      apiRequestsHourlySeries,
      recentSessions
    });
  } catch (error) {
    await captureAppError({
      error,
      req,
      res,
      fallback: {
        service: "admin-api",
        code: ERROR_CODES.INTERNAL,
        status: 500
      },
      metadata: {
        route: "/api/admin/panel/stats/sessions"
      }
    });
    return res.status(500).json({
      error: error?.message || "Session istatistikleri hazırlanamadı."
    });
  }
});

app.get("/api/admin/panel/stats/abuse", requireAdminApiSession, async (req, res) => {
  noStoreAdminResponse(res);
  const { supabaseUrl, supabaseServiceRoleKey } = getSupabaseConfig();
  if (!supabaseUrl || !supabaseServiceRoleKey) {
    return res.status(503).json({
      error: "Supabase ayarları eksik."
    });
  }

  const windowHours = clampRateLimitValue(req.query?.hours, 24, 1, 24 * 7);
  try {
    const settled = await Promise.allSettled([
      fetchRateLimitViolationsLast24h({ supabaseUrl, supabaseServiceRoleKey }),
      fetchRateLimitViolationsInsights({
        supabaseUrl,
        supabaseServiceRoleKey,
        hours: windowHours,
        limit: 1200
      }),
      fetchSuspiciousActivityInsights({
        supabaseUrl,
        supabaseServiceRoleKey,
        hours: windowHours,
        limit: 1200
      }),
      fetchBruteForceBlocksSnapshot({ limit: 200 }),
      fetchApiRequestsLastHour(),
      fetchApiRequestBreakdownLastHour({ endpointLimit: 12, callerLimit: 12 }),
      countActiveSessionKeys()
    ]);

    const rateLimitBlockedLast24h = settled[0].status === "fulfilled" ? settled[0].value : 0;
    const rateLimitInsights =
      settled[1].status === "fulfilled"
        ? settled[1].value
        : {
            windowHours,
            sampledRows: 0,
            categories: { internal: 0, external: 0, monitoring: 0, unknown: 0 },
            diagnosis: "Rate limit detay verisi alınamadı.",
            uniqueIdentities: 0,
            topScopes: [],
            topEndpoints: [],
            topIdentities: [],
            recentEvents: []
          };
    const suspiciousInsights =
      settled[2].status === "fulfilled"
        ? settled[2].value
        : {
            windowHours,
            sampledRows: 0,
            uniqueIdentities: 0,
            uniqueUsers: 0,
            topEventTypes: [],
            topScopes: [],
            topIdentities: [],
            recentEvents: [],
            diagnosis: "Suspicious activity verisi alınamadı."
          };
    const bruteForce =
      settled[3].status === "fulfilled"
        ? settled[3].value
        : {
            source: "unavailable",
            activeBlocks: 0,
            topScopes: [],
            samples: []
          };
    const apiRequestsLastHour = settled[4].status === "fulfilled" ? settled[4].value : 0;
    const apiBreakdown =
      settled[5].status === "fulfilled"
        ? settled[5].value
        : {
            total: apiRequestsLastHour,
            success: 0,
            error: 0,
            endpointCount: 0,
            callerCount: 0,
            topEndpoints: [],
            topCallers: []
          };
    const activeSessions =
      settled[6].status === "fulfilled"
        ? settled[6].value
        : {
            total: 0,
            voice: 0,
            text: 0
          };

    return res.json({
      ok: true,
      generatedAt: new Date().toISOString(),
      windowHours,
      rateLimit: {
        blockedLast24h: rateLimitBlockedLast24h,
        insights: rateLimitInsights
      },
      suspicious: suspiciousInsights,
      bruteForce,
      requests: {
        lastHour: apiRequestsLastHour,
        breakdown: apiBreakdown
      },
      activeSessions
    });
  } catch (error) {
    await captureAppError({
      error,
      req,
      res,
      fallback: {
        service: "admin-api",
        code: ERROR_CODES.INTERNAL,
        status: 500
      },
      metadata: {
        route: "/api/admin/panel/stats/abuse"
      }
    });
    return res.status(500).json({
      error: error?.message || "Abuse verisi hazırlanamadı."
    });
  }
});

app.get("/api/admin/panel/stats/errors", requireAdminApiSession, async (req, res) => {
  noStoreAdminResponse(res);
  try {
    const limit = clampRateLimitValue(req.query?.limit, 200, 20, 500);
    const statusFilter = String(req.query?.status || "")
      .trim()
      .toLowerCase();
    const endpointFilter = String(req.query?.endpoint || "")
      .trim()
      .toLowerCase();
    const rangeHours = clampRateLimitValue(req.query?.rangeHours, 24, 0, 24 * 30);

    const maxReadCount = Math.max(limit * 3, 260);
    const nowMs = Date.now();
    const rangeStartMs = rangeHours > 0 ? nowMs - rangeHours * 60 * 60 * 1000 : 0;
    const mapPersistedRow = (item) => ({
      timestamp: String(item?.created_at || ""),
      requestId: item?.request_id || null,
      status: Number(item?.status || 500),
      method: String(item?.method || "GET").toUpperCase(),
      path: String(item?.path || ""),
      latencyMs: Number(item?.latency_ms || 0),
      ipHash: String(item?.identity_hash || ""),
      source: "supabase",
      service: String(item?.service || "app"),
      code: String(item?.code || ERROR_CODES.UNKNOWN),
      message: String(item?.message || "")
    });
    const persistedLogsRaw = await fetchPersistedAppErrorLogs({
      limit: maxReadCount,
      rangeHours: rangeHours > 0 ? rangeHours : 24 * 30
    });
    const persistedLogs = persistedLogsRaw.map(mapPersistedRow);
    const fallbackRuntimeLogs = persistedLogs.length > 0 ? [] : await getRuntimeErrorLogs(maxReadCount);
    const logs = persistedLogs.length > 0 ? persistedLogs : fallbackRuntimeLogs.map((item) => ({
      ...item,
      source: item?.source || "runtime"
    }));

    const rangeScopedLogs = (Array.isArray(logs) ? logs : []).filter((item) => {
      if (rangeStartMs <= 0) {
        return true;
      }
      const at = Date.parse(String(item?.timestamp || ""));
      if (!Number.isFinite(at)) {
        return false;
      }
      return at >= rangeStartMs;
    });

    const matchesStatusFilter = (statusCode) => {
      if (!statusFilter) {
        return true;
      }
      const code = Number(statusCode || 0);
      if (!Number.isFinite(code) || code <= 0) {
        return false;
      }
      if (/^\dxx$/.test(statusFilter)) {
        return Math.floor(code / 100) === Number(statusFilter[0]);
      }
      if (/^\d{3}$/.test(statusFilter)) {
        return code === Number(statusFilter);
      }
      return true;
    };

    const filteredLogs = rangeScopedLogs
      .filter((item) => {
        const path = String(item?.path || "").toLowerCase();
        const endpointOk = !endpointFilter || path.includes(endpointFilter);
        const statusOk = matchesStatusFilter(item?.status);
        return endpointOk && statusOk;
      })
      .slice(0, limit);

    const summary = {
      total: rangeScopedLogs.length,
      filtered: filteredLogs.length,
      server5xx: filteredLogs.filter((item) => Number(item?.status || 0) >= 500).length,
      client4xx: filteredLogs.filter((item) => {
        const code = Number(item?.status || 0);
        return code >= 400 && code < 500;
      }).length,
      rate429: filteredLogs.filter((item) => Number(item?.status || 0) === 429).length
    };

    return res.json({
      ok: true,
      logs: filteredLogs,
      summary,
      source: persistedLogs.length > 0 ? "supabase" : "runtime"
    });
  } catch (error) {
    await captureAppError({
      error,
      req,
      res,
      fallback: {
        service: "admin-errors",
        code: ERROR_CODES.INTERNAL,
        status: 500
      },
      metadata: {
        route: "/api/admin/panel/stats/errors"
      }
    });
    return res.status(500).json({
      error: error?.message || "Hata logları alınamadı."
    });
  }
});

app.post("/api/admin/ai-switch", async (req, res) => {
  const adminIdentity = getClientIp(req);
  if (
    (await enforceBruteForceGuard(req, res, {
      scope: "admin-ai-switch-auth",
      identity: adminIdentity,
      errorMessage: "Çok fazla hatalı yönetim denemesi tespit edildi. Lütfen daha sonra tekrar dene."
    })) !== true
  ) {
    return;
  }

  const adminIpLimitOk = await enforceRateLimit(req, res, {
    scope: "admin-ai-switch-ip",
    identity: adminIdentity,
    maxRequests: clampRateLimitValue(process.env.RATE_LIMIT_ADMIN_SWITCH_IP_PER_MIN, 30, 5, 120),
    windowMs: 60_000,
    errorMessage: "Yönetim isteği sınırına ulaşıldı. Kısa süre sonra tekrar dene."
  });
  if (!adminIpLimitOk) {
    return;
  }

  const aiConfig = getAiAccessConfig();
  const providedToken = String(req.headers["x-admin-token"] || req.body?.adminToken || "").trim();
  if (!aiConfig.adminToken || providedToken !== aiConfig.adminToken) {
    await registerAuthFailure({
      scope: "admin-ai-switch-auth",
      identity: adminIdentity
    });
    return res.status(403).json({
      error: "Yönetim yetkisi doğrulanamadı."
    });
  }
  await clearAuthFailures({
    scope: "admin-ai-switch-auth",
    identity: adminIdentity
  });

  const { supabaseUrl, supabaseServiceRoleKey } = getSupabaseConfig();
  if (!supabaseUrl || !supabaseServiceRoleKey) {
    return res.status(503).json({
      error: "Supabase sunucu ayarları eksik."
    });
  }

  const requestedUserId = sanitizeUuid(req.body?.userId);
  const requestedEmail = String(req.body?.email || "")
    .trim()
    .toLowerCase();
  const enabled = Boolean(req.body?.enabled);
  const reason = sanitizeAdminReason(req.body?.reason);

  if (!requestedUserId && !requestedEmail) {
    return res.status(400).json({
      error: "userId veya email gerekli."
    });
  }

  try {
    let targetUserId = requestedUserId;
    if (!targetUserId && requestedEmail) {
      const profileByEmail = await fetchProfileRowByEmail({
        supabaseUrl,
        supabaseServiceRoleKey,
        email: requestedEmail
      });
      targetUserId = sanitizeUuid(profileByEmail?.id);
      if (!targetUserId) {
        return res.status(404).json({
          error: "Bu email için profil kaydı bulunamadı."
        });
      }
    }

    const updated = await updateProfileAiSwitch({
      supabaseUrl,
      supabaseServiceRoleKey,
      userId: targetUserId,
      enabled,
      reason
    });

    return res.json({
      ok: true,
      userId: targetUserId,
      aiEnabled: Boolean(updated?.ai_enabled),
      aiDisabledReason: updated?.ai_disabled_reason || null,
      aiDisabledAt: updated?.ai_disabled_at || null
    });
  } catch (error) {
    return res.status(error?.status || 500).json({
      error: error?.message || "AI switch güncellenemedi."
    });
  }
});

app.post("/api/admin/workflow/daily/trigger", async (req, res) => {
  const auth = await ensureAdminAuthorized(req, res, {
    scope: "admin-workflow-daily-trigger-auth",
    rateScope: "admin-workflow-daily-trigger-ip",
    maxPerMinute: clampRateLimitValue(process.env.RATE_LIMIT_ADMIN_WORKFLOW_TRIGGER_IP_PER_MIN, 20, 1, 120),
    authErrorMessage: "Çok fazla hatalı workflow tetikleme denemesi tespit edildi. Lütfen daha sonra tekrar dene."
  });
  if (!auth.ok) {
    return;
  }

  if (!isQStashWorkflowConfigured()) {
    return res.status(503).json({
      error: "QStash workflow ayarları eksik. QSTASH_URL/TOKEN ve signing key alanlarını kontrol et."
    });
  }

  try {
    const result = await triggerDailyWorkflow({
      req,
      payload: req.body?.payload && typeof req.body.payload === "object" ? req.body.payload : {},
      label: String(req.body?.label || "daily-challenge-workflow").slice(0, 120)
    });

    return res.json({
      ok: true,
      workflow_url: result.workflowUrl,
      workflow_run_id: result.workflowRunId
    });
  } catch (error) {
    return res.status(error?.status || 500).json({
      error: error?.message || "Workflow tetiklenemedi."
    });
  }
});

app.post("/api/admin/workflow/daily/schedule/setup", async (req, res) => {
  const auth = await ensureAdminAuthorized(req, res, {
    scope: "admin-workflow-daily-schedule-auth",
    rateScope: "admin-workflow-daily-schedule-ip",
    maxPerMinute: clampRateLimitValue(process.env.RATE_LIMIT_ADMIN_WORKFLOW_SCHEDULE_IP_PER_MIN, 10, 1, 60),
    authErrorMessage: "Çok fazla hatalı workflow schedule denemesi tespit edildi. Lütfen daha sonra tekrar dene."
  });
  if (!auth.ok) {
    return;
  }

  if (!isQStashWorkflowConfigured()) {
    return res.status(503).json({
      error: "QStash workflow ayarları eksik. QSTASH_URL/TOKEN ve signing key alanlarını kontrol et."
    });
  }

  try {
    const result = await ensureDailyWorkflowSchedule({
      req,
      cron: req.body?.cron,
      scheduleId: req.body?.scheduleId,
      payload: req.body?.payload && typeof req.body.payload === "object" ? req.body.payload : {}
    });

    return res.json({
      ok: true,
      schedule_id: result.scheduleId,
      cron: result.cron,
      workflow_url: result.workflowUrl
    });
  } catch (error) {
    return res.status(error?.status || 500).json({
      error: error?.message || "Workflow schedule oluşturulamadı."
    });
  }
});

app.post("/api/admin/supabase/bootstrap", async (req, res) => {
  const adminIdentity = getClientIp(req);
  if (
    (await enforceBruteForceGuard(req, res, {
      scope: "admin-supabase-bootstrap-auth",
      identity: adminIdentity,
      errorMessage: "Çok fazla hatalı şema kurulum denemesi tespit edildi. Lütfen daha sonra tekrar dene."
    })) !== true
  ) {
    return;
  }

  const adminIpLimitOk = await enforceRateLimit(req, res, {
    scope: "admin-supabase-bootstrap-ip",
    identity: adminIdentity,
    maxRequests: clampRateLimitValue(process.env.RATE_LIMIT_ADMIN_BOOTSTRAP_IP_PER_MIN, 8, 1, 40),
    windowMs: 60_000,
    errorMessage: "Şema kurulum isteği sınırına ulaşıldı. Kısa süre sonra tekrar dene."
  });
  if (!adminIpLimitOk) {
    return;
  }

  const aiConfig = getAiAccessConfig();
  const providedToken = String(req.headers["x-admin-token"] || req.body?.adminToken || "").trim();
  if (!aiConfig.adminToken || providedToken !== aiConfig.adminToken) {
    await registerAuthFailure({
      scope: "admin-supabase-bootstrap-auth",
      identity: adminIdentity
    });
    return res.status(403).json({
      error: "Yönetim yetkisi doğrulanamadı."
    });
  }
  await clearAuthFailures({
    scope: "admin-supabase-bootstrap-auth",
    identity: adminIdentity
  });

  const { supabaseUrl, supabaseServiceRoleKey } = getSupabaseConfig();
  const { managementToken } = getSupabaseBootstrapConfig();
  if (!supabaseUrl || !supabaseServiceRoleKey) {
    return res.status(503).json({
      error: "Supabase sunucu ayarları eksik."
    });
  }

  const preferredEngine = String(req.body?.engine || "auto")
    .trim()
    .toLowerCase();
  const dryRun = Boolean(req.body?.dryRun);

  try {
    const files = await readSupabaseSchemaFiles();
    if (dryRun) {
      return res.json({
        ok: true,
        dry_run: true,
        file_count: files.length,
        files: files.map((file) => file.name),
        available_engines: {
          management: Boolean(managementToken),
          data_api: Boolean(supabaseUrl && supabaseServiceRoleKey)
        }
      });
    }

    const result = await applySupabaseSchemaBundle({
      supabaseUrl,
      supabaseServiceRoleKey,
      managementToken,
      preferredEngine
    });

    return res.json({
      ok: true,
      engine: result.engine,
      applied_count: result.applied.length,
      applied: result.applied
    });
  } catch (error) {
    return res.status(500).json({
      error: error?.message || "Supabase şema kurulumu başarısız.",
      details: error?.details || null
    });
  }
});

app.get("/api/auth/session", async (req, res) => {
  const ipIdentity = getClientIp(req);
  if (
    (await enforceBruteForceGuard(req, res, {
      scope: "auth-session-check",
      identity: ipIdentity,
      errorMessage: "Çok fazla hatalı kimlik denemesi tespit edildi. Lütfen daha sonra tekrar dene."
    })) !== true
  ) {
    return;
  }

  const ipLimitOk = await enforceRateLimit(req, res, {
    scope: "auth-session-check-ip",
    identity: ipIdentity,
    maxRequests: clampRateLimitValue(process.env.RATE_LIMIT_AUTH_SESSION_IP_PER_MIN, 45, 5, 300),
    windowMs: 60_000,
    errorMessage: "Oturum doğrulama sınırına ulaşıldı. Lütfen kısa süre sonra tekrar dene."
  });
  if (!ipLimitOk) {
    return;
  }

  const accessToken = extractBearerToken(req);
  if (!accessToken) {
    await registerAuthFailure({
      scope: "auth-session-check",
      identity: ipIdentity,
      endpoint: req.originalUrl || req.url || ""
    });
    return res.status(401).json({
      error: "Yetkili oturum gerekli."
    });
  }

  const { supabaseUrl, supabaseAnonKey, supabaseServiceRoleKey } = getSupabaseConfig();
  const userApiKey = supabaseAnonKey || supabaseServiceRoleKey;
  if (!supabaseUrl || !userApiKey) {
    return res.status(503).json({
      error: "Kimlik doğrulama servisi geçici olarak kullanılamıyor."
    });
  }

  try {
    const userPayload = await fetchSupabaseUserByToken({
      supabaseUrl,
      userApiKey,
      accessToken
    });
    await clearAuthFailures({
      scope: "auth-session-check",
      identity: ipIdentity
    });
    return res.json({
      ok: true,
      user: {
        id: sanitizeUuid(userPayload?.id),
        email: typeof userPayload?.email === "string" ? userPayload.email : null,
        email_confirmed:
          Boolean(userPayload?.email_confirmed_at) ||
          Boolean(userPayload?.confirmed_at) ||
          Boolean(userPayload?.user_metadata?.email_verified),
        last_sign_in_at: userPayload?.last_sign_in_at || null
      }
    });
  } catch (error) {
    if (isAuthFailureStatus(error?.status)) {
      await registerAuthFailure({
        scope: "auth-session-check",
        identity: ipIdentity,
        endpoint: req.originalUrl || req.url || ""
      });
    }
    return res.status(error?.status || 401).json({
      error: error?.message || "Oturum doğrulanamadı."
    });
  }
});

app.post("/api/push/register-device", async (req, res) => {
  const parsedBody = parseJsonWithZod(res, pushDeviceRegisterBodySchema, req.body, {
    message: "Push cihaz kaydı gövdesi geçersiz."
  });
  if (!parsedBody) {
    return;
  }

  const ipIdentity = getClientIp(req);
  const ipLimitOk = await enforceRateLimit(req, res, {
    scope: "push-register-device-ip",
    identity: ipIdentity,
    maxRequests: clampRateLimitValue(process.env.RATE_LIMIT_PUSH_REGISTER_IP_PER_MIN, 60, 5, 240),
    windowMs: 60_000,
    errorMessage: "Cihaz kaydı istek sınırına ulaşıldı. Kısa süre sonra tekrar dene."
  });
  if (!ipLimitOk) {
    return;
  }

  const accessToken = extractBearerToken(req);
  if (!accessToken) {
    return res.status(401).json({
      error: "Yetkili oturum gerekli."
    });
  }

  const { supabaseUrl, supabaseAnonKey, supabaseServiceRoleKey } = getSupabaseConfig();
  const userApiKey = supabaseAnonKey || supabaseServiceRoleKey;
  if (!supabaseUrl || !supabaseServiceRoleKey || !userApiKey) {
    return res.status(503).json({
      error: "Sunucu ayarları eksik."
    });
  }

  const deviceToken = sanitizeDeviceToken(parsedBody.deviceToken);
  if (!deviceToken) {
    return res.status(400).json({
      error: "Geçerli bir cihaz token değeri gerekli."
    });
  }

  let userPayload = null;
  try {
    userPayload = await fetchSupabaseUserByToken({
      supabaseUrl,
      userApiKey,
      accessToken
    });
  } catch (error) {
    return res.status(error?.status || 401).json({
      error: error?.message || "Kullanıcı doğrulanamadı."
    });
  }

  const userId = sanitizeUuid(userPayload?.id);
  if (!userId) {
    return res.status(401).json({
      error: "Geçerli kullanıcı kimliği bulunamadı."
    });
  }

  const notificationsEnabled = parsedBody.notificationsEnabled !== false;
  const apnsEnvironment = sanitizeApnsEnvironment(parsedBody.apnsEnvironment);

  try {
    const saved = await upsertUserPushDevice({
      supabaseUrl,
      supabaseServiceRoleKey,
      row: {
        user_id: userId,
        platform: "ios",
        device_token: deviceToken,
        notifications_enabled: notificationsEnabled,
        is_active: notificationsEnabled,
        apns_environment: apnsEnvironment,
        device_model: sanitizeReportText(parsedBody.deviceModel || "", 120) || null,
        app_version: sanitizeReportText(parsedBody.appVersion || "", 80) || null,
        locale: sanitizeReportText(parsedBody.locale || "", 40) || null,
        timezone: sanitizeReportText(parsedBody.timezone || "", 80) || null,
        last_seen_at: new Date().toISOString()
      }
    });
    return res.json({
      ok: true,
      device: {
        id: saved?.id || null,
        notifications_enabled: Boolean(saved?.notifications_enabled),
        is_active: Boolean(saved?.is_active),
        last_seen_at: saved?.last_seen_at || null
      }
    });
  } catch (error) {
    return res.status(error?.status || 500).json({
      error: error?.message || "Push cihaz kaydı başarısız."
    });
  }
});

app.get("/api/in-app/banner", async (req, res) => {
  const accessToken = extractBearerToken(req);
  if (!accessToken) {
    return res.status(401).json({
      error: "Yetkili oturum gerekli."
    });
  }

  const { supabaseUrl, supabaseAnonKey, supabaseServiceRoleKey } = getSupabaseConfig();
  const userApiKey = supabaseAnonKey || supabaseServiceRoleKey;
  if (!supabaseUrl || !supabaseServiceRoleKey || !userApiKey) {
    return res.status(503).json({
      error: "Sunucu ayarları eksik."
    });
  }

  let userPayload = null;
  try {
    userPayload = await fetchSupabaseUserByToken({
      supabaseUrl,
      userApiKey,
      accessToken
    });
  } catch (error) {
    return res.status(error?.status || 401).json({
      error: error?.message || "Kullanıcı doğrulanamadı."
    });
  }

  const userId = sanitizeUuid(userPayload?.id);
  if (!userId) {
    return res.status(401).json({
      error: "Geçerli kullanıcı kimliği bulunamadı."
    });
  }

  try {
    const banner = await fetchUserLatestInAppBanner({
      supabaseUrl,
      supabaseServiceRoleKey,
      userId
    });
    return res.json({
      ok: true,
      banner: banner || null
    });
  } catch (error) {
    return res.status(error?.status || 500).json({
      error: error?.message || "In-app duyuru alınamadı."
    });
  }
});

app.post("/api/in-app/banner/ack", async (req, res) => {
  const parsedBody = parseJsonWithZod(res, inAppBannerAckBodySchema, req.body, {
    message: "In-app duyuru işaretleme gövdesi geçersiz."
  });
  if (!parsedBody) {
    return;
  }

  const accessToken = extractBearerToken(req);
  if (!accessToken) {
    return res.status(401).json({
      error: "Yetkili oturum gerekli."
    });
  }

  const { supabaseUrl, supabaseAnonKey, supabaseServiceRoleKey } = getSupabaseConfig();
  const userApiKey = supabaseAnonKey || supabaseServiceRoleKey;
  if (!supabaseUrl || !supabaseServiceRoleKey || !userApiKey) {
    return res.status(503).json({
      error: "Sunucu ayarları eksik."
    });
  }

  let userPayload = null;
  try {
    userPayload = await fetchSupabaseUserByToken({
      supabaseUrl,
      userApiKey,
      accessToken
    });
  } catch (error) {
    return res.status(error?.status || 401).json({
      error: error?.message || "Kullanıcı doğrulanamadı."
    });
  }

  const userId = sanitizeUuid(userPayload?.id);
  if (!userId) {
    return res.status(401).json({
      error: "Geçerli kullanıcı kimliği bulunamadı."
    });
  }

  try {
    const patched = await patchInAppBannerTarget({
      supabaseUrl,
      supabaseServiceRoleKey,
      userId,
      broadcastId: parsedBody.broadcastId,
      action: parsedBody.action
    });
    if (!patched) {
      return res.status(404).json({
        error: "Duyuru kaydı bulunamadı."
      });
    }
    return res.json({
      ok: true
    });
  } catch (error) {
    return res.status(error?.status || 500).json({
      error: error?.message || "Duyuru güncellenemedi."
    });
  }
});

app.post("/api/profile/upsert", async (req, res) => {
  const parsedBody = parseJsonWithZod(res, profileUpsertBodySchema, req.body, {
    message: "Profil güncelleme gövdesi geçersiz."
  });
  if (!parsedBody) {
    return;
  }

  const { supabaseUrl, supabaseAnonKey, supabaseServiceRoleKey } = getSupabaseConfig();
  const missing = [];
  if (!supabaseUrl) {
    missing.push("SUPABASE_URL");
  }
  if (!supabaseServiceRoleKey) {
    missing.push("SUPABASE_SERVICE_ROLE_KEY");
  }

  // Bu endpoint icin anon key zorunlu degil; service role ile user dogrulanir.
  const userApiKey = supabaseAnonKey || supabaseServiceRoleKey;

  if (!supabaseUrl || !supabaseServiceRoleKey) {
    return res.status(503).json({
      error: `Supabase sunucu ayarları eksik: ${missing.join(", ")}`
    });
  }

  const accessToken = extractBearerToken(req);
  if (!accessToken) {
    return res.status(401).json({
      error: "Yetki belirteci boş."
    });
  }

  let userPayload;
  try {
    userPayload = await fetchSupabaseUserByToken({
      supabaseUrl,
      userApiKey,
      accessToken
    });
  } catch (error) {
    return res.status(error?.status || 500).json({
      error: error?.message || "Kullanıcı bilgisi alınamadı."
    });
  }

  const email = typeof userPayload?.email === "string" ? userPayload.email : null;
  const firstNameInput = typeof parsedBody.firstName === "string" ? parsedBody.firstName.trim() : "";
  const lastNameInput = typeof parsedBody.lastName === "string" ? parsedBody.lastName.trim() : "";
  const fullNameInput = typeof parsedBody.fullName === "string" ? parsedBody.fullName.trim() : "";
  const phoneNumberInput =
    typeof parsedBody.phoneNumber === "string" ? parsedBody.phoneNumber.trim().slice(0, 32) : "";
  const marketingOptIn = Boolean(parsedBody.marketingOptIn);
  const mergedName = `${firstNameInput} ${lastNameInput}`.trim();
  const fullName =
    fullNameInput || mergedName || userPayload?.user_metadata?.full_name || userPayload?.user_metadata?.name || null;

  const profileRow = {
    id: userPayload.id,
    email,
    first_name: firstNameInput || null,
    last_name: lastNameInput || null,
    full_name: fullName,
    phone_number: phoneNumberInput || null,
    marketing_opt_in: marketingOptIn,
    onboarding_completed: false,
    updated_at: new Date().toISOString()
  };

  try {
    const upsertResult = await upsertProfileRow({
      supabaseUrl,
      supabaseServiceRoleKey,
      row: profileRow,
      errorPrefix: "Profil kaydı yazılamadı"
    });

    if (upsertResult.droppedColumns.length > 0) {
      console.warn(
        `[supabase] profiles upsert fallback aktif. Kullanilmayan kolonlar: ${upsertResult.droppedColumns.join(", ")}`
      );
    }

    return res.json({ ok: true });
  } catch (error) {
    return res.status(error?.status || 500).json({
      error: error?.message || "Profil kaydı yazılamadı."
    });
  }
});

app.post("/api/auth/resend-verification", async (req, res) => {
  const ipIdentity = getClientIp(req);
  if (
    (await enforceBruteForceGuard(req, res, {
      scope: "auth-resend-verification",
      identity: ipIdentity,
      errorMessage: "Çok fazla hatalı doğrulama denemesi tespit edildi. Lütfen daha sonra tekrar dene."
    })) !== true
  ) {
    return;
  }

  const ipLimitOk = await enforceRateLimit(req, res, {
    scope: "auth-resend-verification-ip",
    identity: ipIdentity,
    maxRequests: clampRateLimitValue(process.env.RATE_LIMIT_AUTH_RESEND_VERIFY_IP_PER_MIN, 10, 2, 80),
    windowMs: 60_000,
    errorMessage: "Doğrulama e-postası gönderim sınırına ulaşıldı. Lütfen biraz sonra tekrar dene."
  });
  if (!ipLimitOk) {
    return;
  }

  const parsedBody = parseJsonWithZod(res, authResendBodySchema, req.body, {
    message: "Doğrulama e-postası isteği geçersiz."
  });
  if (!parsedBody) {
    return;
  }

  const cleanEmail = sanitizeEmail(parsedBody.email);
  if (!cleanEmail) {
    return res.status(400).json({
      error: "Geçerli bir e-posta adresi gir."
    });
  }

  const spamGuardOk = await enforceSpamFingerprintGuard(req, res, {
    scope: "auth-resend-verification",
    identity: cleanEmail,
    fingerprint: cleanEmail,
    cooldownMs: clampRateLimitValue(process.env.SPAM_RESEND_EMAIL_COOLDOWN_MS, 120_000, 20_000, 10 * 60_000)
  });
  if (spamGuardOk !== true) {
    return;
  }

  const emailLimitOk = await enforceRateLimit(req, res, {
    scope: "auth-resend-verification-email",
    identity: cleanEmail,
    maxRequests: clampRateLimitValue(process.env.RATE_LIMIT_AUTH_RESEND_VERIFY_EMAIL_PER_HOUR, 6, 1, 40),
    windowMs: 60 * 60_000,
    errorMessage: "Bu e-posta için gönderim limiti doldu. Lütfen daha sonra tekrar dene."
  });
  if (!emailLimitOk) {
    return;
  }

  const { supabaseUrl, supabaseAnonKey, supabaseServiceRoleKey } = getSupabaseConfig();
  if (!supabaseUrl || !(supabaseAnonKey || supabaseServiceRoleKey)) {
    return res.status(503).json({
      error: "Doğrulama servisi geçici olarak kullanılamıyor."
    });
  }

  const resendCfg = getResendConfig();
  const fullName = sanitizeReportText(parsedBody.fullName || "", 100);
  const redirectTo = appendQueryParam(resendCfg.verifyRedirectUrl, "verified", "1");

  try {
    let deliveredWithCustomEmail = false;
    let responseChannel = "supabase";
    if (resendCfg.apiKey && resendCfg.fromEmail && supabaseServiceRoleKey) {
      try {
        const verificationUrl = await generateSupabaseSignupActionLink({
          supabaseUrl,
          supabaseServiceRoleKey,
          email: cleanEmail,
          redirectTo
        });
        const template = buildVerificationResendTemplate({
          fullName,
          email: cleanEmail,
          verificationUrl
        });
        await sendResendEmail({
          to: cleanEmail,
          subject: template.subject,
          html: template.html,
          text: template.text
        });
        deliveredWithCustomEmail = true;
        responseChannel = "resend";
      } catch (mailError) {
        console.warn(
          `[resend] custom verification email failed, falling back to Supabase resend: ${mailError?.message || "unknown"}`
        );
      }
    }

    if (!deliveredWithCustomEmail) {
      await triggerSupabaseSignupResend({
        supabaseUrl,
        supabaseAnonKey,
        supabaseServiceRoleKey,
        email: cleanEmail,
        emailRedirectTo: redirectTo
      });
      if (resendCfg.apiKey && resendCfg.fromEmail) {
        console.info("[resend] Supabase resend path used.");
      }
    }

    return res.json({
      ok: true,
      message: "E-posta doğrulama bağlantısı gönderildi.",
      channel: responseChannel
    });
  } catch (error) {
    const statusCode = Number(error?.status || 500);
    const isClientError = statusCode >= 400 && statusCode < 500;
    if (isClientError) {
      // Kullanıcı varlığı bilgisini sızdırmamak için genel başarı döndür.
      return res.json({
        ok: true,
        message: "E-posta doğrulama bağlantısı gönderildi."
      });
    }
    return res.status(500).json({
      error: "Doğrulama e-postası şu anda gönderilemiyor."
    });
  }
});

app.all("/api/auth/resend-verification", (req, res) => {
  return rejectUnsupportedMethod(req, res, "POST", "/api/auth/resend-verification");
});

app.post("/api/auth/reset-password/complete", async (req, res) => {
  const ipIdentity = getClientIp(req);
  if (
    (await enforceBruteForceGuard(req, res, {
      scope: "auth-reset-password-complete",
      identity: ipIdentity,
      errorMessage: "Çok fazla hatalı şifre yenileme denemesi tespit edildi. Lütfen daha sonra tekrar dene."
    })) !== true
  ) {
    return;
  }

  const ipLimitOk = await enforceRateLimit(req, res, {
    scope: "auth-reset-password-complete-ip",
    identity: ipIdentity,
    maxRequests: clampRateLimitValue(process.env.RATE_LIMIT_AUTH_RESET_PASSWORD_IP_PER_MIN, 14, 2, 100),
    windowMs: 60_000,
    errorMessage: "Şifre güncelleme istek sınırına ulaşıldı. Lütfen biraz sonra tekrar dene."
  });
  if (!ipLimitOk) {
    return;
  }

  const parsedBody = parseJsonWithZod(res, authResetPasswordCompleteBodySchema, req.body, {
    message: "Şifre güncelleme isteği geçersiz."
  });
  if (!parsedBody) {
    return;
  }

  const accessToken = String(parsedBody.accessToken || "").trim();
  const newPassword = String(parsedBody.newPassword || "");

  if (!accessToken || accessToken.length < 20) {
    return res.status(400).json({
      error: "Geçerli bir doğrulama bağlantısı gerekli."
    });
  }

  if (newPassword.length < 8) {
    return res.status(400).json({
      error: "Şifre en az 8 karakter olmalı."
    });
  }

  const { supabaseUrl, supabaseAnonKey, supabaseServiceRoleKey } = getSupabaseConfig();
  const userApiKey = String(supabaseAnonKey || supabaseServiceRoleKey || "").trim();
  if (!supabaseUrl || !userApiKey) {
    return res.status(503).json({
      error: "Şifre yenileme servisi geçici olarak kullanılamıyor."
    });
  }

  try {
    const resp = await fetchWithTimeout(
      `${String(supabaseUrl || "").replace(/\/+$/g, "")}/auth/v1/user`,
      {
        method: "PUT",
        headers: {
          apikey: userApiKey,
          Authorization: `Bearer ${accessToken}`,
          "Content-Type": "application/json"
        },
        body: JSON.stringify({
          password: newPassword
        })
      },
      12000
    );

    if (!resp.ok) {
      const txt = await resp.text().catch(() => "");
      const status = Number(resp.status || 500);
      const isClient = status >= 400 && status < 500;
      return res.status(isClient ? 400 : 502).json({
        error: isClient
          ? "Doğrulama bağlantısının süresi dolmuş olabilir. Lütfen yeni bir şifre sıfırlama bağlantısı iste."
          : `Şifre güncellenemedi. ${txt || "Lütfen tekrar dene."}`
      });
    }

    return res.json({
      ok: true,
      message: "Şifre başarıyla güncellendi."
    });
  } catch (error) {
    return res.status(500).json({
      error: "Şifre güncellenirken beklenmeyen bir hata oluştu."
    });
  }
});

app.all("/api/auth/reset-password/complete", (req, res) => {
  return rejectUnsupportedMethod(req, res, "POST", "/api/auth/reset-password/complete");
});

app.get("/api/profile/me", async (req, res) => {
  const { supabaseUrl, supabaseAnonKey, supabaseServiceRoleKey } = getSupabaseConfig();
  const missing = [];
  if (!supabaseUrl) {
    missing.push("SUPABASE_URL");
  }
  if (!supabaseServiceRoleKey) {
    missing.push("SUPABASE_SERVICE_ROLE_KEY");
  }

  const userApiKey = supabaseAnonKey || supabaseServiceRoleKey;

  if (!supabaseUrl || !supabaseServiceRoleKey) {
    return res.status(503).json({
      error: `Supabase sunucu ayarları eksik: ${missing.join(", ")}`
    });
  }

  const accessToken = extractBearerToken(req);
  if (!accessToken) {
    return res.status(401).json({
      error: "Yetki belirteci boş."
    });
  }

  let userPayload;
  try {
    userPayload = await fetchSupabaseUserByToken({
      supabaseUrl,
      userApiKey,
      accessToken
    });
  } catch (error) {
    return res.status(error?.status || 500).json({
      error: error?.message || "Kullanıcı bilgisi alınamadı."
    });
  }

  try {
    let profile = await fetchProfileRow({
      supabaseUrl,
      supabaseServiceRoleKey,
      userId: userPayload.id
    });

    if (!profile) {
      const initialRow = {
        id: userPayload.id,
        email: typeof userPayload.email === "string" ? userPayload.email : null,
        full_name:
          userPayload?.user_metadata?.full_name || userPayload?.user_metadata?.name || null,
        marketing_opt_in: Boolean(userPayload?.user_metadata?.marketing_opt_in),
        onboarding_completed: false,
        updated_at: new Date().toISOString()
      };

      const upsertResult = await upsertProfileRow({
        supabaseUrl,
        supabaseServiceRoleKey,
        row: initialRow,
        errorPrefix: "Profil kaydı yazılamadı"
      });

      if (upsertResult.droppedColumns.length > 0) {
        console.warn(
          `[supabase] profiles ilk kayit fallback aktif. Kullanilmayan kolonlar: ${upsertResult.droppedColumns.join(", ")}`
        );
      }

      profile = await fetchProfileRow({
        supabaseUrl,
        supabaseServiceRoleKey,
        userId: userPayload.id
      });
    }

    return res.json({
      profile: normalizeProfileRow(profile)
    });
  } catch (error) {
    return res.status(error?.status || 500).json({
      error: error?.message || "Profil bilgisi alınamadı."
    });
  }
});

app.post("/api/profile/onboarding", async (req, res) => {
  const body = parseJsonWithZod(res, profileOnboardingBodySchema, req.body, {
    message: "Onboarding verisi geçersiz."
  });
  if (!body) {
    return;
  }

  const { supabaseUrl, supabaseAnonKey, supabaseServiceRoleKey } = getSupabaseConfig();
  const missing = [];
  if (!supabaseUrl) {
    missing.push("SUPABASE_URL");
  }
  if (!supabaseServiceRoleKey) {
    missing.push("SUPABASE_SERVICE_ROLE_KEY");
  }

  const userApiKey = supabaseAnonKey || supabaseServiceRoleKey;

  if (!supabaseUrl || !supabaseServiceRoleKey) {
    return res.status(503).json({
      error: `Supabase sunucu ayarları eksik: ${missing.join(", ")}`
    });
  }

  const accessToken = extractBearerToken(req);
  if (!accessToken) {
    return res.status(401).json({
      error: "Yetki belirteci boş."
    });
  }

  let userPayload;
  try {
    userPayload = await fetchSupabaseUserByToken({
      supabaseUrl,
      userApiKey,
      accessToken
    });
  } catch (error) {
    return res.status(error?.status || 500).json({
      error: error?.message || "Kullanıcı bilgisi alınamadı."
    });
  }

  const row = {
    id: userPayload.id,
    email: typeof userPayload.email === "string" ? userPayload.email : null,
    updated_at: new Date().toISOString()
  };

  if (typeof body.fullName === "string" && body.fullName.trim()) {
    row.full_name = body.fullName.trim();
  }
  if (typeof body.phoneNumber === "string" && body.phoneNumber.trim()) {
    row.phone_number = body.phoneNumber.trim();
  }
  if (typeof body.marketingOptIn === "boolean") {
    row.marketing_opt_in = body.marketingOptIn;
  }
  if (typeof body.ageRange === "string" && body.ageRange.trim()) {
    row.age_range = body.ageRange.trim();
  }
  if (typeof body.role === "string" && body.role.trim()) {
    row.role = body.role.trim();
  }
  if (Array.isArray(body.goals)) {
    row.goals = body.goals.filter((item) => typeof item === "string" && item.trim()).slice(0, 8);
  }
  if (Array.isArray(body.interestAreas)) {
    row.interest_areas = body.interestAreas
      .filter((item) => typeof item === "string" && item.trim())
      .slice(0, 16);
  }
  if (typeof body.learningLevel === "string" && body.learningLevel.trim()) {
    row.learning_level = body.learningLevel.trim();
  }
  if (typeof body.onboardingCompleted === "boolean") {
    row.onboarding_completed = body.onboardingCompleted;
  }

  try {
    const upsertResult = await upsertProfileRow({
      supabaseUrl,
      supabaseServiceRoleKey,
      row,
      errorPrefix: "Onboarding kaydı yazılamadı"
    });

    if (upsertResult.droppedColumns.length > 0) {
      console.warn(
        `[supabase] onboarding fallback aktif. Kullanilmayan kolonlar: ${upsertResult.droppedColumns.join(", ")}`
      );
    }

    const profile = await fetchProfileRow({
      supabaseUrl,
      supabaseServiceRoleKey,
      userId: userPayload.id
    });

    return res.json({
      ok: true,
      profile: normalizeProfileRow(profile)
    });
  } catch (error) {
    return res.status(error?.status || 500).json({
      error: error?.message || "Onboarding bilgisi kaydedilemedi."
    });
  }
});

app.post("/api/profile/delete-data", async (req, res) => {
  const ipIdentity = getClientIp(req);
  if (
    (await enforceBruteForceGuard(req, res, {
      scope: "profile-delete-data-auth",
      identity: ipIdentity,
      errorMessage: "Çok fazla hatalı deneme tespit edildi. Lütfen daha sonra tekrar dene."
    })) !== true
  ) {
    return;
  }

  const limitOk = await enforceRateLimit(req, res, {
    scope: "profile-delete-data-ip",
    identity: ipIdentity,
    maxRequests: clampRateLimitValue(process.env.RATE_LIMIT_PROFILE_DELETE_DATA_IP_PER_MIN, 8, 2, 30),
    windowMs: 60_000,
    errorMessage: "Bu işlem için kısa süreli istek sınırına ulaşıldı. Lütfen tekrar dene."
  });
  if (!limitOk) {
    return;
  }

  const confirmation = String(req.body?.confirmation || "").trim().toUpperCase();
  if (confirmation !== "DELETE_DATA") {
    return res.status(400).json({
      error: "Onay kodu gerekli: DELETE_DATA"
    });
  }

  const { supabaseUrl, supabaseAnonKey, supabaseServiceRoleKey } = getSupabaseConfig();
  const missing = [];
  if (!supabaseUrl) missing.push("SUPABASE_URL");
  if (!supabaseServiceRoleKey) missing.push("SUPABASE_SERVICE_ROLE_KEY");
  const userApiKey = supabaseAnonKey || supabaseServiceRoleKey;

  if (!supabaseUrl || !supabaseServiceRoleKey) {
    return res.status(503).json({
      error: `Supabase sunucu ayarları eksik: ${missing.join(", ")}`
    });
  }

  const accessToken = extractBearerToken(req);
  if (!accessToken) {
    await registerAuthFailure({
      scope: "profile-delete-data-auth",
      identity: ipIdentity
    });
    return res.status(401).json({
      error: "Yetki belirteci boş."
    });
  }
  maybeSimulateServiceError(req, "supabase", {
    code: ERROR_CODES.SUPABASE_UNAVAILABLE,
    status: 503
  });

  let userPayload = null;
  try {
    userPayload = await fetchSupabaseUserByToken({
      supabaseUrl,
      userApiKey,
      accessToken
    });
    await clearAuthFailures({
      scope: "profile-delete-data-auth",
      identity: ipIdentity
    });
  } catch (error) {
    if (isAuthFailureStatus(error?.status)) {
      await registerAuthFailure({
        scope: "profile-delete-data-auth",
        identity: ipIdentity
      });
    }
    return res.status(error?.status || 401).json({
      error: error?.message || "Kullanıcı doğrulanamadı."
    });
  }

  const userId = sanitizeUuid(userPayload?.id);
  if (!userId) {
    return res.status(401).json({
      error: "Geçerli kullanıcı kimliği bulunamadı."
    });
  }

  try {
    const deletedSessions = await deleteCaseSessionsByUserId({
      supabaseUrl,
      supabaseServiceRoleKey,
      userId
    });
    const profileReset = await resetProfileDataByUserId({
      supabaseUrl,
      supabaseServiceRoleKey,
      userId
    });
    await clearActiveElevenSession({ userId });

    return res.json({
      ok: true,
      deleted_case_sessions: deletedSessions,
      profile_reset: profileReset
    });
  } catch (error) {
    return res.status(error?.status || 500).json({
      error: error?.message || "Kullanıcı verileri silinemedi."
    });
  }
});

app.post("/api/profile/delete-account", async (req, res) => {
  const ipIdentity = getClientIp(req);
  if (
    (await enforceBruteForceGuard(req, res, {
      scope: "profile-delete-account-auth",
      identity: ipIdentity,
      errorMessage: "Çok fazla hatalı deneme tespit edildi. Lütfen daha sonra tekrar dene."
    })) !== true
  ) {
    return;
  }

  const limitOk = await enforceRateLimit(req, res, {
    scope: "profile-delete-account-ip",
    identity: ipIdentity,
    maxRequests: clampRateLimitValue(process.env.RATE_LIMIT_PROFILE_DELETE_ACCOUNT_IP_PER_MIN, 5, 1, 20),
    windowMs: 60_000,
    errorMessage: "Bu işlem için kısa süreli istek sınırına ulaşıldı. Lütfen tekrar dene."
  });
  if (!limitOk) {
    return;
  }

  const confirmation = String(req.body?.confirmation || "").trim().toUpperCase();
  if (confirmation !== "DELETE_ACCOUNT") {
    return res.status(400).json({
      error: "Onay kodu gerekli: DELETE_ACCOUNT"
    });
  }

  const { supabaseUrl, supabaseAnonKey, supabaseServiceRoleKey } = getSupabaseConfig();
  const missing = [];
  if (!supabaseUrl) missing.push("SUPABASE_URL");
  if (!supabaseServiceRoleKey) missing.push("SUPABASE_SERVICE_ROLE_KEY");
  const userApiKey = supabaseAnonKey || supabaseServiceRoleKey;

  if (!supabaseUrl || !supabaseServiceRoleKey) {
    return res.status(503).json({
      error: `Supabase sunucu ayarları eksik: ${missing.join(", ")}`
    });
  }

  const accessToken = extractBearerToken(req);
  if (!accessToken) {
    await registerAuthFailure({
      scope: "profile-delete-account-auth",
      identity: ipIdentity
    });
    return res.status(401).json({
      error: "Yetki belirteci boş."
    });
  }
  maybeSimulateServiceError(req, "supabase", {
    code: ERROR_CODES.SUPABASE_UNAVAILABLE,
    status: 503
  });

  let userPayload = null;
  try {
    userPayload = await fetchSupabaseUserByToken({
      supabaseUrl,
      userApiKey,
      accessToken
    });
    await clearAuthFailures({
      scope: "profile-delete-account-auth",
      identity: ipIdentity
    });
  } catch (error) {
    if (isAuthFailureStatus(error?.status)) {
      await registerAuthFailure({
        scope: "profile-delete-account-auth",
        identity: ipIdentity
      });
    }
    return res.status(error?.status || 401).json({
      error: error?.message || "Kullanıcı doğrulanamadı."
    });
  }

  const userId = sanitizeUuid(userPayload?.id);
  if (!userId) {
    return res.status(401).json({
      error: "Geçerli kullanıcı kimliği bulunamadı."
    });
  }

  try {
    const deletedSessions = await deleteCaseSessionsByUserId({
      supabaseUrl,
      supabaseServiceRoleKey,
      userId
    });
    const deletedProfiles = await deleteProfileByUserId({
      supabaseUrl,
      supabaseServiceRoleKey,
      userId
    });
    await clearActiveElevenSession({ userId });
    await deleteAuthUserById({
      supabaseUrl,
      supabaseServiceRoleKey,
      userId
    });

    return res.json({
      ok: true,
      deleted_case_sessions: deletedSessions,
      deleted_profiles: deletedProfiles,
      deleted_auth_user: true
    });
  } catch (error) {
    return res.status(error?.status || 500).json({
      error: error?.message || "Hesap silinemedi."
    });
  }
});

app.post("/api/reports/create", async (req, res) => {
  const ipIdentity = getClientIp(req);
  if (
    (await enforceBruteForceGuard(req, res, {
      scope: "report-create-auth",
      identity: ipIdentity,
      errorMessage: "Çok fazla hatalı deneme tespit edildi. Lütfen daha sonra tekrar dene."
    })) !== true
  ) {
    return;
  }

  const reportIpLimitOk = await enforceRateLimit(req, res, {
    scope: "report-create-ip",
    identity: ipIdentity,
    maxRequests: clampRateLimitValue(process.env.RATE_LIMIT_REPORT_CREATE_IP_PER_MIN, 20, 3, 100),
    windowMs: 60_000,
    errorMessage: "Rapor gönderim sınırına ulaşıldı. Lütfen biraz sonra tekrar dene."
  });
  if (!reportIpLimitOk) {
    return;
  }

  const { supabaseUrl, supabaseAnonKey, supabaseServiceRoleKey } = getSupabaseConfig();
  const missing = [];
  if (!supabaseUrl) missing.push("SUPABASE_URL");
  if (!supabaseServiceRoleKey) missing.push("SUPABASE_SERVICE_ROLE_KEY");
  const userApiKey = supabaseAnonKey || supabaseServiceRoleKey;

  if (!supabaseUrl || !supabaseServiceRoleKey) {
    return res.status(503).json({
      error: `Supabase sunucu ayarları eksik: ${missing.join(", ")}`
    });
  }

  const accessToken = extractBearerToken(req);
  if (!accessToken) {
    await registerAuthFailure({
      scope: "report-create-auth",
      identity: ipIdentity
    });
    return res.status(401).json({
      error: "Yetki belirteci boş."
    });
  }

  let userPayload = null;
  try {
    userPayload = await fetchSupabaseUserByToken({
      supabaseUrl,
      userApiKey,
      accessToken
    });
    await clearAuthFailures({
      scope: "report-create-auth",
      identity: ipIdentity
    });
  } catch (error) {
    if (isAuthFailureStatus(error?.status)) {
      await registerAuthFailure({
        scope: "report-create-auth",
        identity: ipIdentity
      });
    }
    return res.status(error?.status || 401).json({
      error: error?.message || "Kullanıcı doğrulanamadı."
    });
  }

  const userId = sanitizeUuid(userPayload?.id);
  if (!userId) {
    return res.status(401).json({
      error: "Geçerli kullanıcı kimliği bulunamadı."
    });
  }

  const reportUserLimitOk = await enforceRateLimit(req, res, {
    scope: "report-create-user",
    identity: userId,
    maxRequests: clampRateLimitValue(process.env.RATE_LIMIT_REPORT_CREATE_USER_PER_MIN, 10, 1, 40),
    windowMs: 60_000,
    errorMessage: "Bu dakika için rapor gönderim sınırına ulaştın."
  });
  if (!reportUserLimitOk) {
    return;
  }

  const parsedBody = parseJsonWithZod(res, reportCreateBodySchema, req.body, {
    message: "Rapor isteği gövdesi geçersiz."
  });
  if (!parsedBody) {
    return;
  }

  const spamGuardOk = await enforceSpamFingerprintGuard(req, res, {
    scope: "report-create",
    identity: userId,
    fingerprint: `${parsedBody.category}:${parsedBody.details}`,
    cooldownMs: clampRateLimitValue(process.env.SPAM_REPORT_COOLDOWN_MS, 45_000, 10_000, 5 * 60_000)
  });
  if (spamGuardOk !== true) {
    return;
  }

  const category = sanitizeReportCategory(parsedBody.category);
  if (!category) {
    return res.status(400).json({
      error: "Geçerli rapor kategorisi seçmelisin."
    });
  }

  const details = sanitizeReportText(parsedBody.details, 1200);
  if (details.length < 8) {
    return res.status(400).json({
      error: "Sorun açıklaması en az 8 karakter olmalı."
    });
  }

  const caseSessionId = sanitizeUuid(parsedBody.caseSessionId);
  let linkedCase = null;
  if (caseSessionId) {
    try {
      linkedCase = await fetchCaseSessionForUser({
        supabaseUrl,
        supabaseServiceRoleKey,
        userId,
        caseSessionId
      });
    } catch (error) {
      return res.status(error?.status || 500).json({
        error: error?.message || "Vaka kaydı doğrulanamadı."
      });
    }
    if (!linkedCase) {
      return res.status(404).json({
        error: "Seçilen vaka kaydı bulunamadı."
      });
    }
  }

  const caseTitleInput = sanitizeReportText(parsedBody.caseTitle, 120);
  const modeInput = String(parsedBody.mode || "").trim().toLowerCase();
  const difficultyInput = sanitizeReportText(parsedBody.difficulty, 40);
  const specialtyInput = sanitizeReportText(parsedBody.specialty, 80);

  const row = {
    user_id: userId,
    case_session_id: caseSessionId || null,
    case_session_ref: linkedCase?.session_id || null,
    category,
    details,
    status: "open",
    case_title: caseTitleInput || linkedCase?.case_context?.title || null,
    mode: modeInput === "text" ? "text" : modeInput === "voice" ? "voice" : linkedCase?.mode || null,
    difficulty: difficultyInput || linkedCase?.difficulty || null,
    specialty: specialtyInput || linkedCase?.case_context?.specialty || null,
    metadata:
      parsedBody?.metadata && typeof parsedBody.metadata === "object" && !Array.isArray(parsedBody.metadata)
        ? parsedBody.metadata
        : null,
    created_at: new Date().toISOString(),
    updated_at: new Date().toISOString()
  };

  try {
    const saved = await insertContentReport({
      supabaseUrl,
      supabaseServiceRoleKey,
      row
    });
    return res.json({
      ok: true,
      reportId: saved?.id || null,
      status: saved?.status || "open"
    });
  } catch (error) {
    return res.status(error?.status || 500).json({
      error: error?.message || "Rapor kaydedilemedi."
    });
  }
});

app.post("/api/feedback/create", async (req, res) => {
  const ipIdentity = getClientIp(req);
  if (
    (await enforceBruteForceGuard(req, res, {
      scope: "feedback-create-auth",
      identity: ipIdentity,
      errorMessage: "Çok fazla hatalı deneme tespit edildi. Lütfen daha sonra tekrar dene."
    })) !== true
  ) {
    return;
  }

  const feedbackIpLimitOk = await enforceRateLimit(req, res, {
    scope: "feedback-create-ip",
    identity: ipIdentity,
    maxRequests: clampRateLimitValue(process.env.RATE_LIMIT_FEEDBACK_CREATE_IP_PER_MIN, 20, 2, 100),
    windowMs: 60_000,
    errorMessage: "Feedback gönderim sınırına ulaşıldı. Lütfen biraz sonra tekrar dene."
  });
  if (!feedbackIpLimitOk) {
    return;
  }

  const { supabaseUrl, supabaseAnonKey, supabaseServiceRoleKey } = getSupabaseConfig();
  const missing = [];
  if (!supabaseUrl) missing.push("SUPABASE_URL");
  if (!supabaseServiceRoleKey) missing.push("SUPABASE_SERVICE_ROLE_KEY");
  const userApiKey = supabaseAnonKey || supabaseServiceRoleKey;

  if (!supabaseUrl || !supabaseServiceRoleKey) {
    return res.status(503).json({
      error: `Supabase sunucu ayarları eksik: ${missing.join(", ")}`
    });
  }

  const accessToken = extractBearerToken(req);
  if (!accessToken) {
    await registerAuthFailure({
      scope: "feedback-create-auth",
      identity: ipIdentity
    });
    return res.status(401).json({
      error: "Yetki belirteci boş."
    });
  }

  let userPayload = null;
  try {
    userPayload = await fetchSupabaseUserByToken({
      supabaseUrl,
      userApiKey,
      accessToken
    });
    await clearAuthFailures({
      scope: "feedback-create-auth",
      identity: ipIdentity
    });
  } catch (error) {
    if (isAuthFailureStatus(error?.status)) {
      await registerAuthFailure({
        scope: "feedback-create-auth",
        identity: ipIdentity
      });
    }
    return res.status(error?.status || 401).json({
      error: error?.message || "Kullanıcı doğrulanamadı."
    });
  }

  const userId = sanitizeUuid(userPayload?.id);
  if (!userId) {
    return res.status(401).json({
      error: "Geçerli kullanıcı kimliği bulunamadı."
    });
  }

  const feedbackUserLimitOk = await enforceRateLimit(req, res, {
    scope: "feedback-create-user",
    identity: userId,
    maxRequests: clampRateLimitValue(process.env.RATE_LIMIT_FEEDBACK_CREATE_USER_PER_MIN, 8, 1, 30),
    windowMs: 60_000,
    errorMessage: "Bu dakika için feedback gönderim sınırına ulaştın."
  });
  if (!feedbackUserLimitOk) {
    return;
  }

  const parsedBody = parseJsonWithZod(res, feedbackCreateBodySchema, req.body, {
    message: "Feedback isteği gövdesi geçersiz."
  });
  if (!parsedBody) {
    return;
  }

  const spamGuardOk = await enforceSpamFingerprintGuard(req, res, {
    scope: "feedback-create",
    identity: userId,
    fingerprint: `${parsedBody.topic}:${parsedBody.message}`,
    cooldownMs: clampRateLimitValue(process.env.SPAM_FEEDBACK_COOLDOWN_MS, 45_000, 10_000, 5 * 60_000)
  });
  if (spamGuardOk !== true) {
    return;
  }

  const topic = sanitizeFeedbackTopic(parsedBody.topic);
  if (!topic) {
    return res.status(400).json({
      error: "Geçerli bir feedback konusu seçmelisin."
    });
  }

  const message = sanitizeReportText(parsedBody.message, 1600);
  if (message.length < 8) {
    return res.status(400).json({
      error: "Feedback mesajı en az 8 karakter olmalı."
    });
  }

  const row = {
    user_id: userId,
    topic,
    message,
    status: "open",
    email: typeof userPayload?.email === "string" ? userPayload.email : null,
    full_name:
      sanitizeReportText(userPayload?.user_metadata?.full_name || userPayload?.user_metadata?.name || "", 120) ||
      null,
    created_at: new Date().toISOString(),
    updated_at: new Date().toISOString()
  };

  try {
    const saved = await insertUserFeedback({
      supabaseUrl,
      supabaseServiceRoleKey,
      row
    });

    return res.json({
      ok: true,
      feedbackId: saved?.id || null,
      status: saved?.status || "open"
    });
  } catch (error) {
    return res.status(error?.status || 500).json({
      error: error?.message || "Feedback kaydedilemedi."
    });
  }
});

app.post("/api/cases/save", async (req, res) => {
  const body = parseJsonWithZod(res, caseSaveBodySchema, req.body, {
    message: "Vaka kayıt gövdesi geçersiz."
  });
  if (!body) {
    return;
  }

  const { supabaseUrl, supabaseAnonKey, supabaseServiceRoleKey } = getSupabaseConfig();
  const missing = [];
  if (!supabaseUrl) {
    missing.push("SUPABASE_URL");
  }
  if (!supabaseServiceRoleKey) {
    missing.push("SUPABASE_SERVICE_ROLE_KEY");
  }

  const userApiKey = supabaseAnonKey || supabaseServiceRoleKey;

  if (!supabaseUrl || !supabaseServiceRoleKey) {
    return res.status(503).json({
      error: `Supabase sunucu ayarları eksik: ${missing.join(", ")}`
    });
  }

  const accessToken = extractBearerToken(req);
  if (!accessToken) {
    return res.status(401).json({
      error: "Yetki belirteci boş."
    });
  }

  let userPayload;
  try {
    userPayload = await fetchSupabaseUserByToken({
      supabaseUrl,
      userApiKey,
      accessToken
    });
  } catch (error) {
    return res.status(error?.status || 500).json({
      error: error?.message || "Kullanıcı bilgisi alınamadı."
    });
  }

  const sessionId = typeof body.sessionId === "string" ? body.sessionId.trim() : "";
  if (!sessionId) {
    return res.status(400).json({
      error: "sessionId zorunlu."
    });
  }

  const safeMode = body.mode === "text" ? "text" : "voice";
  const transcriptRows = Array.isArray(body.transcript) ? body.transcript : [];
  const resolvedDurationMin = resolveSessionDurationMin({
    durationMin: body.durationMin,
    startedAt: body.startedAt,
    endedAt: body.endedAt
  });
  const usageMetrics = buildSessionUsageMetrics({
    mode: safeMode,
    transcript: transcriptRows,
    durationMin: resolvedDurationMin
  });
  const costMetrics = buildSessionCostMetrics({
    mode: safeMode,
    usageMetrics,
    durationMin: resolvedDurationMin
  });

  const baseRow = {
    user_id: userPayload.id,
    session_id: sessionId,
    mode: safeMode,
    status: typeof body.status === "string" ? body.status : "pending",
    started_at: toNullableIso(body.startedAt),
    ended_at: toNullableIso(body.endedAt),
    duration_min: toNullableInt(Math.round(resolvedDurationMin)),
    message_count: toNullableInt(body.messageCount),
    difficulty: typeof body.difficulty === "string" ? body.difficulty : null,
    case_context: body.caseContext && typeof body.caseContext === "object" ? body.caseContext : null,
    transcript: transcriptRows,
    score: body.score && typeof body.score === "object" ? body.score : null,
    updated_at: new Date().toISOString()
  };
  const rowWithMetrics = {
    ...baseRow,
    usage_metrics: usageMetrics,
    cost_metrics: costMetrics
  };

  const upsertCaseRow = async (rowPayload) =>
    fetch(`${supabaseUrl}/rest/v1/case_sessions?on_conflict=user_id,session_id`, {
      method: "POST",
      headers: {
        apikey: supabaseServiceRoleKey,
        Authorization: `Bearer ${supabaseServiceRoleKey}`,
        "Content-Type": "application/json",
        Prefer: "resolution=merge-duplicates,return=minimal"
      },
      body: JSON.stringify([rowPayload])
    });

  try {
    let upsertResp = await upsertCaseRow(rowWithMetrics);
    if (!upsertResp.ok) {
      const txt = await upsertResp.text();
      const lowered = String(txt || "").toLowerCase();
      const missingMetricColumns =
        lowered.includes("usage_metrics") ||
        lowered.includes("cost_metrics") ||
        lowered.includes("column") && lowered.includes("does not exist");
      if (missingMetricColumns) {
        upsertResp = await upsertCaseRow(baseRow);
      } else {
        return res.status(500).json({
          error: `Vaka kaydı yazılamadı: ${txt || upsertResp.status}`
        });
      }
    }

    if (!upsertResp.ok) {
      const txt = await upsertResp.text();
      return res.status(500).json({
        error: `Vaka kaydı yazılamadı: ${txt || upsertResp.status}`
      });
    }

    try {
      await upsertDailyChallengeAttempt({
        supabaseUrl,
        supabaseServiceRoleKey,
        userId: userPayload.id,
        row: baseRow
      });
    } catch (attemptError) {
      // eslint-disable-next-line no-console
      console.warn(`[daily_challenge_attempts] upsert atlandi: ${attemptError?.message || "unknown"}`);
    }

    return res.json({ ok: true });
  } catch (error) {
    return res.status(500).json({
      error: `Vaka kaydı yazılamadı: ${error?.message || "Bilinmeyen hata"}`
    });
  }
});

app.get("/api/cases/list", async (req, res) => {
  const { supabaseUrl, supabaseAnonKey, supabaseServiceRoleKey } = getSupabaseConfig();
  const missing = [];
  if (!supabaseUrl) {
    missing.push("SUPABASE_URL");
  }
  if (!supabaseServiceRoleKey) {
    missing.push("SUPABASE_SERVICE_ROLE_KEY");
  }

  const userApiKey = supabaseAnonKey || supabaseServiceRoleKey;

  if (!supabaseUrl || !supabaseServiceRoleKey) {
    return res.status(503).json({
      error: `Supabase sunucu ayarları eksik: ${missing.join(", ")}`
    });
  }

  const accessToken = extractBearerToken(req);
  if (!accessToken) {
    return res.status(401).json({
      error: "Yetki belirteci boş."
    });
  }

  let userPayload;
  try {
    userPayload = await fetchSupabaseUserByToken({
      supabaseUrl,
      userApiKey,
      accessToken
    });
  } catch (error) {
    return res.status(error?.status || 500).json({
      error: error?.message || "Kullanıcı bilgisi alınamadı."
    });
  }

  const limitRaw = Number(req.query.limit);
  const limit = Number.isFinite(limitRaw) ? Math.max(1, Math.min(200, Math.round(limitRaw))) : 50;

  try {
    const qs = new URLSearchParams({
      user_id: `eq.${userPayload.id}`,
      select:
        "id,session_id,mode,status,started_at,ended_at,duration_min,message_count,difficulty,case_context,transcript,score,updated_at",
      order: "updated_at.desc",
      limit: String(limit)
    });

    const listResp = await fetch(`${supabaseUrl}/rest/v1/case_sessions?${qs.toString()}`, {
      method: "GET",
      headers: {
        apikey: supabaseServiceRoleKey,
        Authorization: `Bearer ${supabaseServiceRoleKey}`
      }
    });

    if (!listResp.ok) {
      const txt = await listResp.text();
      return res.status(500).json({
        error: `Vaka listesi okunamadı: ${txt || listResp.status}`
      });
    }

    const rows = await listResp.json();
    return res.json({
      cases: Array.isArray(rows) ? rows : []
    });
  } catch (error) {
    return res.status(500).json({
      error: error?.message || "Vaka listesi okunamadı."
    });
  }
});

app.get("/api/analytics/weak-areas", async (req, res) => {
  const ipIdentity = getClientIp(req);
  if (
    (await enforceBruteForceGuard(req, res, {
      scope: "weak-analysis-auth",
      identity: ipIdentity,
      errorMessage: "Çok fazla hatalı deneme tespit edildi. Lütfen daha sonra tekrar dene."
    })) !== true
  ) {
    return;
  }

  const ipLimitOk = await enforceRateLimit(req, res, {
    scope: "weak-analysis-ip",
    identity: ipIdentity,
    maxRequests: clampRateLimitValue(process.env.RATE_LIMIT_WEAK_ANALYSIS_IP_PER_MIN, 35, 4, 200),
    windowMs: 60_000,
    errorMessage: "Analiz isteği sınırına ulaşıldı. Lütfen kısa süre sonra tekrar dene."
  });
  if (!ipLimitOk) {
    return;
  }

  const { supabaseUrl, supabaseAnonKey, supabaseServiceRoleKey } = getSupabaseConfig();
  const missing = [];
  if (!supabaseUrl) {
    missing.push("SUPABASE_URL");
  }
  if (!supabaseServiceRoleKey) {
    missing.push("SUPABASE_SERVICE_ROLE_KEY");
  }
  if (!supabaseUrl || !supabaseServiceRoleKey) {
    return res.status(503).json({
      error: `Analiz için sunucu ayarları eksik: ${missing.join(", ")}`
    });
  }

  const accessToken = extractBearerToken(req);
  if (!accessToken) {
    await registerAuthFailure({
      scope: "weak-analysis-auth",
      identity: ipIdentity
    });
    return res.status(401).json({
      error: "Analiz için yetkili oturum gerekli."
    });
  }

  let userPayload = null;
  try {
    userPayload = await fetchSupabaseUserByToken({
      supabaseUrl,
      userApiKey: supabaseAnonKey || supabaseServiceRoleKey,
      accessToken
    });
    await clearAuthFailures({
      scope: "weak-analysis-auth",
      identity: ipIdentity
    });
  } catch (error) {
    if (isAuthFailureStatus(error?.status)) {
      await registerAuthFailure({
        scope: "weak-analysis-auth",
        identity: ipIdentity
      });
    }
    return res.status(error?.status || 401).json({
      error: error?.message || "Kullanıcı doğrulanamadı."
    });
  }

  const userId = sanitizeUuid(userPayload?.id);
  if (!userId) {
    return res.status(401).json({
      error: "Geçerli kullanıcı kimliği bulunamadı."
    });
  }

  const quickCachedPayload = await getCachedWeakAreaByUser(userId);
  if (quickCachedPayload) {
    return res.json(quickCachedPayload);
  }

  const userLimitOk = await enforceRateLimit(req, res, {
    scope: "weak-analysis-user",
    identity: userId,
    maxRequests: clampRateLimitValue(process.env.RATE_LIMIT_WEAK_ANALYSIS_USER_PER_MIN, 16, 2, 90),
    windowMs: 60_000,
    errorMessage: "Bu dakika için analiz sınırına ulaştın. Lütfen kısa süre sonra tekrar dene."
  });
  if (!userLimitOk) {
    return;
  }

  try {
    const userLimit = clampRateLimitValue(process.env.WEAK_ANALYSIS_USER_SESSION_LIMIT, 220, 20, 400);
    const globalLimit = clampRateLimitValue(process.env.WEAK_ANALYSIS_GLOBAL_SESSION_LIMIT, 1200, 100, 4000);
    const globalDays = clampRateLimitValue(process.env.WEAK_ANALYSIS_GLOBAL_DAYS, 45, 7, 180);
    const { userRows, globalRows } = await fetchWeakAreaCaseRows({
      supabaseUrl,
      supabaseServiceRoleKey,
      userId,
      limit: globalLimit,
      days: globalDays
    });

    const scopedUserRows = userRows.slice(0, userLimit);
    const normalizedUser = scopedUserRows
      .map(weakAreaNormalizeSessionRow)
      .filter(Boolean)
      .sort((a, b) => Number(b.updatedAtMs || 0) - Number(a.updatedAtMs || 0));
    const normalizedGlobal = globalRows
      .map(weakAreaNormalizeSessionRow)
      .filter(Boolean)
      .sort((a, b) => Number(b.updatedAtMs || 0) - Number(a.updatedAtMs || 0));

    const cacheKey = weakAreaBuildCacheKey({
      userId,
      userSessions: normalizedUser,
      globalSessions: normalizedGlobal
    });

    const cached = await getCachedWeakArea(cacheKey);
    if (cached) {
      await setCachedWeakAreaByUser(userId, cached);
      return res.json(cached);
    }

    const payload = await buildWeakAreaAnalysisPayload({
      userRows: scopedUserRows,
      globalRows,
      weeklyTarget: clampRateLimitValue(process.env.WEAK_ANALYSIS_DEFAULT_WEEKLY_TARGET, 5, 1, 14)
    });

    await setCachedWeakArea(cacheKey, payload);
    await setCachedWeakAreaByUser(userId, payload);
    return res.json(payload);
  } catch (error) {
    await captureAppError({
      error,
      req,
      res,
      fallback: {
        service: "analytics",
        code: ERROR_CODES.INTERNAL,
        status: 500
      },
      metadata: {
        route: "/api/analytics/weak-areas"
      }
    });
    return res.status(error?.status || 500).json({
      error: error?.message || "Zayıf alan analizi oluşturulamadı."
    });
  }
});

app.all("/api/analytics/weak-areas", (req, res) => {
  return rejectUnsupportedMethod(req, res, "GET", "/api/analytics/weak-areas");
});

app.post("/api/flashcards/generate", async (req, res) => {
  const ipIdentity = getClientIp(req);
  if (
    (await enforceBruteForceGuard(req, res, {
      scope: "flashcards-generate-auth",
      identity: ipIdentity,
      errorMessage: "Çok fazla hatalı deneme tespit edildi. Lütfen daha sonra tekrar dene."
    })) !== true
  ) {
    return;
  }

  const ipLimitOk = await enforceRateLimit(req, res, {
    scope: "flashcards-generate-ip",
    identity: ipIdentity,
    maxRequests: clampRateLimitValue(process.env.RATE_LIMIT_FLASHCARDS_GENERATE_IP_PER_MIN, 20, 2, 150),
    windowMs: 60_000,
    errorMessage: "Flashcard üretim sınırına ulaşıldı. Lütfen biraz sonra tekrar dene."
  });
  if (!ipLimitOk) {
    return;
  }

  const parsedBody = parseJsonWithZod(res, flashcardGenerateBodySchema, req.body, {
    message: "Flashcard üretim isteği geçersiz."
  });
  if (!parsedBody) {
    return;
  }

  const { supabaseUrl, supabaseAnonKey, supabaseServiceRoleKey } = getSupabaseConfig();
  const missing = [];
  if (!supabaseUrl) missing.push("SUPABASE_URL");
  if (!supabaseServiceRoleKey) missing.push("SUPABASE_SERVICE_ROLE_KEY");
  if (missing.length > 0) {
    return res.status(503).json({
      error: `Sunucu ayarları eksik: ${missing.join(", ")}`
    });
  }

  const accessToken = extractBearerToken(req);
  if (!accessToken) {
    await registerAuthFailure({
      scope: "flashcards-generate-auth",
      identity: ipIdentity
    });
    return res.status(401).json({
      error: "Yetki belirteci boş."
    });
  }
  maybeSimulateServiceError(req, "supabase", {
    code: ERROR_CODES.SUPABASE_UNAVAILABLE,
    status: 503
  });

  const userApiKey = supabaseAnonKey || supabaseServiceRoleKey;
  let userPayload = null;
  try {
    userPayload = await fetchSupabaseUserByToken({
      supabaseUrl,
      userApiKey,
      accessToken
    });
    await clearAuthFailures({
      scope: "flashcards-generate-auth",
      identity: ipIdentity
    });

    await assertAiAccessAllowed({
      supabaseUrl,
      supabaseServiceRoleKey,
      userId: userPayload?.id
    });
  } catch (error) {
    if (isAuthFailureStatus(error?.status)) {
      await registerAuthFailure({
        scope: "flashcards-generate-auth",
        identity: ipIdentity
      });
    }
    return res.status(error?.status || 401).json({
      error: error?.message || "Kullanıcı doğrulanamadı."
    });
  }

  const userLimitOk = await enforceRateLimit(req, res, {
    scope: "flashcards-generate-user",
    identity: userPayload?.id || accessToken,
    maxRequests: clampRateLimitValue(process.env.RATE_LIMIT_FLASHCARDS_GENERATE_USER_PER_MIN, 8, 1, 60),
    windowMs: 60_000,
    errorMessage: "Bu dakika için flashcard üretim sınırına ulaştın."
  });
  if (!userLimitOk) {
    return;
  }

  const maxCards = Math.max(3, Math.min(10, Number(parsedBody.maxCards || 6)));
  const safeSessionId = sanitizeFlashcardText(parsedBody.sessionId, 120, false) || null;
  const draftCacheKey = buildFlashcardDraftCacheKey({
    userId: userPayload?.id,
    sessionId: safeSessionId
  });

  if (safeSessionId) {
    try {
      const existingRows = await fetchFlashcardsForUser({
        supabaseUrl,
        supabaseServiceRoleKey,
        userId: userPayload?.id,
        sessionId: safeSessionId,
        limit: Math.max(3, maxCards)
      });
      const existingCards = dedupeFlashcards(
        existingRows.map((row) => mapStoredFlashcardToDraft(row)).filter(Boolean),
        maxCards
      );
      if (existingCards.length >= 3) {
        return res.json({
          ok: true,
          cards: existingCards,
          generated_count: existingCards.length,
          prompt_version: FLASHCARD_PROMPT_VERSION,
          fallback_used: false,
          source: "session_saved"
        });
      }
    } catch (error) {
      // eslint-disable-next-line no-console
      console.warn(`[flashcards/generate] session lookup skipped: ${error?.message || "unknown"}`);
    }
  }

  if (draftCacheKey) {
    const cachedDraft = await getCachedFlashcardDrafts(draftCacheKey);
    const cachedCards = dedupeFlashcards(cachedDraft?.cards || [], maxCards);
    if (cachedCards.length >= 3) {
      return res.json({
        ok: true,
        cards: cachedCards,
        generated_count: cachedCards.length,
        prompt_version: FLASHCARD_PROMPT_VERSION,
        fallback_used: Boolean(cachedDraft?.fallback_used),
        source: "session_cache"
      });
    }
  }

  if (!process.env.OPENAI_API_KEY) {
    return res.status(503).json({
      error: "Sunucu ayarları eksik: OPENAI_API_KEY"
    });
  }

  maybeSimulateServiceError(req, "openai", {
    code: ERROR_CODES.OPENAI_UNAVAILABLE,
    status: 503
  });

  const overallScore = Number.isFinite(Number(parsedBody.overallScore))
    ? Math.max(0, Math.min(100, Number(parsedBody.overallScore)))
    : null;
  const scoreLabel = sanitizeFlashcardText(parsedBody.scoreLabel, 64, false);
  const briefSummary = sanitizeFlashcardText(parsedBody.briefSummary, 420, true);
  const dimensions = (Array.isArray(parsedBody.dimensions) ? parsedBody.dimensions : [])
    .map((item) => {
      const key = sanitizeFlashcardText(item?.key, 80, false);
      const scoreRaw = Number(item?.score);
      const score = Number.isFinite(scoreRaw) ? Math.max(0, Math.min(10, scoreRaw)) : null;
      const explanation = sanitizeFlashcardText(item?.explanation, 220, true);
      const recommendation = sanitizeFlashcardText(item?.recommendation, 220, true);
      if (!key && score == null && !explanation && !recommendation) {
        return null;
      }
      return { key, score, explanation, recommendation };
    })
    .filter(Boolean)
    .slice(0, 10);
  const nextPracticeSuggestions = (Array.isArray(parsedBody.nextPracticeSuggestions) ? parsedBody.nextPracticeSuggestions : [])
    .map((item) => {
      const focus = sanitizeFlashcardText(item?.focus, 180, true);
      const microDrill = sanitizeFlashcardText(item?.microDrill ?? item?.micro_drill ?? item?.["micro-drill"], 220, true);
      const examplePrompt = sanitizeFlashcardText(item?.examplePrompt ?? item?.example_prompt, 220, true);
      if (!focus && !microDrill && !examplePrompt) {
        return null;
      }
      return { focus, microDrill, examplePrompt };
    })
    .filter(Boolean)
    .slice(0, 4);

  const contextPayload = {
    sessionId: safeSessionId,
    specialty: sanitizeFlashcardText(parsedBody.specialty, 80, false) || "Genel Tıp",
    difficulty: normalizeDifficulty(parsedBody.difficulty, "Orta"),
    caseTitle: sanitizeFlashcardText(parsedBody.caseTitle, 140, false) || "Klinik Vaka",
    trueDiagnosis: sanitizeFlashcardText(parsedBody.trueDiagnosis, 140, false) || "Belirtilmedi",
    userDiagnosis: sanitizeFlashcardText(parsedBody.userDiagnosis, 140, false) || "Belirtilmedi",
    overallScore,
    scoreLabel: scoreLabel || null,
    briefSummary: briefSummary || null,
    strengths: (Array.isArray(parsedBody.strengths) ? parsedBody.strengths : [])
      .map((item) => sanitizeFlashcardText(item, 180, false))
      .filter(Boolean)
      .slice(0, 5),
    improvements: (Array.isArray(parsedBody.improvements) ? parsedBody.improvements : [])
      .map((item) => sanitizeFlashcardText(item, 180, false))
      .filter(Boolean)
      .slice(0, 5),
    missedOpportunities: (Array.isArray(parsedBody.missedOpportunities) ? parsedBody.missedOpportunities : [])
      .map((item) => sanitizeFlashcardText(item, 180, false))
      .filter(Boolean)
      .slice(0, 5),
    dimensions,
    nextPracticeSuggestions
  };

  const flashcardSchema = {
    type: "object",
    additionalProperties: false,
    properties: {
      cards: {
        type: "array",
        minItems: 3,
        maxItems: maxCards,
        items: {
          type: "object",
          additionalProperties: false,
          properties: {
            id: { type: "string", maxLength: 80 },
            cardType: {
              type: "string",
              enum: [
                "diagnosis",
                "drug",
                "red_flag",
                "differential",
                "management",
                "lab",
                "imaging",
                "procedure",
                "concept"
              ]
            },
            title: { type: "string", maxLength: 120 },
            front: { type: "string", maxLength: 700 },
            back: { type: "string", maxLength: 1400 },
            specialty: { type: "string", maxLength: 80 },
            difficulty: { type: "string", maxLength: 40 },
            tags: {
              type: "array",
              maxItems: 8,
              items: { type: "string", maxLength: 40 }
            }
          },
          required: ["id", "cardType", "title", "front", "back", "specialty", "difficulty", "tags"]
        }
      }
    },
    required: ["cards"]
  };

  const modelName = process.env.OPENAI_FLASHCARD_MODEL || "gpt-5-nano";
  const timeoutMs = Math.max(8000, Math.min(30_000, Number(process.env.OPENAI_FLASHCARD_TIMEOUT_MS || 16_000)));
  const maxOutputTokens = Math.max(700, Math.min(2200, Number(process.env.OPENAI_FLASHCARD_MAX_OUTPUT_TOKENS || 1400)));

  try {
    const response = await openai.responses.create(
      {
        model: modelName,
        max_output_tokens: maxOutputTokens,
        instructions: FLASHCARD_GENERATION_INSTRUCTIONS,
        input:
          `YAPILANDIRILMIS_VAKA_VERISI:\n${JSON.stringify(contextPayload, null, 2)}\n\n` +
          `MAKS_KART: ${maxCards}\n` +
          "3 ile 10 arasında kart üret. Her kart benzersiz olsun. Konuşma transkripti varsayma.",
        text: {
          format: {
            type: "json_schema",
            name: "flashcard_generation_result",
            strict: true,
            schema: flashcardSchema
          }
        }
      },
      {
        timeout: timeoutMs
      }
    );

    const structured = extractStructuredModelPayload(response);
    const parsed = structured && typeof structured === "object"
      ? structured
      : parseModelJsonPayload(extractOutputText(response) || "");
    const generated = dedupeFlashcards(parsed?.cards, maxCards);

    const cards = generated.length >= 3
      ? generated
      : dedupeFlashcards(
          [...generated, ...buildFallbackFlashcards(contextPayload, maxCards)],
          maxCards
        );

    if (cards.length < 3) {
      const fallbackCards = buildFallbackFlashcards(contextPayload, maxCards);
      if (draftCacheKey) {
        await setCachedFlashcardDrafts(draftCacheKey, {
          cards: fallbackCards,
          fallback_used: true
        });
      }
      return res.json({
        ok: true,
        cards: fallbackCards,
        generated_count: fallbackCards.length,
        prompt_version: FLASHCARD_PROMPT_VERSION,
        fallback_used: true,
        source: "fallback_generated"
      });
    }

    if (draftCacheKey) {
      await setCachedFlashcardDrafts(draftCacheKey, {
        cards,
        fallback_used: generated.length < 3
      });
    }
    return res.json({
      ok: true,
      cards,
      generated_count: cards.length,
      prompt_version: FLASHCARD_PROMPT_VERSION,
      fallback_used: generated.length < 3,
      source: generated.length < 3 ? "fallback_generated" : "ai_generated"
    });
  } catch (error) {
    await captureAppError({
      error,
      req,
      res,
      fallback: {
        service: "openai",
        code: ERROR_CODES.OPENAI_UNAVAILABLE,
        status: Number(error?.name === "AbortError" ? 504 : 502)
      },
      metadata: {
        route: "/api/flashcards/generate",
        model: modelName
      }
    });
    const fallbackCards = buildFallbackFlashcards(contextPayload, maxCards);
    if (draftCacheKey) {
      await setCachedFlashcardDrafts(draftCacheKey, {
        cards: fallbackCards,
        fallback_used: true
      });
    }
    return res.status(200).json({
      ok: true,
      cards: fallbackCards,
      generated_count: fallbackCards.length,
      prompt_version: FLASHCARD_PROMPT_VERSION,
      fallback_used: true,
      source: "fallback_generated",
      warning: "AI üretimi başarısız olduğu için yedek kartlar döndürüldü."
    });
  }
});

app.post("/api/flashcards/save", async (req, res) => {
  const ipIdentity = getClientIp(req);
  if (
    (await enforceBruteForceGuard(req, res, {
      scope: "flashcards-save-auth",
      identity: ipIdentity,
      errorMessage: "Çok fazla hatalı deneme tespit edildi. Lütfen daha sonra tekrar dene."
    })) !== true
  ) {
    return;
  }

  const ipLimitOk = await enforceRateLimit(req, res, {
    scope: "flashcards-save-ip",
    identity: ipIdentity,
    maxRequests: clampRateLimitValue(process.env.RATE_LIMIT_FLASHCARDS_SAVE_IP_PER_MIN, 50, 4, 240),
    windowMs: 60_000,
    errorMessage: "Flashcard kayıt sınırına ulaşıldı. Lütfen biraz sonra tekrar dene."
  });
  if (!ipLimitOk) {
    return;
  }

  const parsedBody = parseJsonWithZod(res, flashcardSaveBodySchema, req.body, {
    message: "Flashcard kayıt isteği geçersiz."
  });
  if (!parsedBody) {
    return;
  }

  const { supabaseUrl, supabaseAnonKey, supabaseServiceRoleKey } = getSupabaseConfig();
  const missing = [];
  if (!supabaseUrl) missing.push("SUPABASE_URL");
  if (!supabaseServiceRoleKey) missing.push("SUPABASE_SERVICE_ROLE_KEY");
  if (missing.length > 0) {
    return res.status(503).json({
      error: `Sunucu ayarları eksik: ${missing.join(", ")}`
    });
  }

  const accessToken = extractBearerToken(req);
  if (!accessToken) {
    await registerAuthFailure({
      scope: "flashcards-save-auth",
      identity: ipIdentity
    });
    return res.status(401).json({
      error: "Yetki belirteci boş."
    });
  }
  maybeSimulateServiceError(req, "supabase", {
    code: ERROR_CODES.SUPABASE_UNAVAILABLE,
    status: 503
  });

  const userApiKey = supabaseAnonKey || supabaseServiceRoleKey;
  let userPayload = null;
  try {
    userPayload = await fetchSupabaseUserByToken({
      supabaseUrl,
      userApiKey,
      accessToken
    });
    await clearAuthFailures({
      scope: "flashcards-save-auth",
      identity: ipIdentity
    });
  } catch (error) {
    if (isAuthFailureStatus(error?.status)) {
      await registerAuthFailure({
        scope: "flashcards-save-auth",
        identity: ipIdentity
      });
    }
    return res.status(error?.status || 401).json({
      error: error?.message || "Kullanıcı doğrulanamadı."
    });
  }

  const userId = sanitizeUuid(userPayload?.id);
  if (!userId) {
    return res.status(401).json({
      error: "Geçerli kullanıcı kimliği bulunamadı."
    });
  }

  const userLimitOk = await enforceRateLimit(req, res, {
    scope: "flashcards-save-user",
    identity: userId,
    maxRequests: clampRateLimitValue(process.env.RATE_LIMIT_FLASHCARDS_SAVE_USER_PER_MIN, 30, 3, 160),
    windowMs: 60_000,
    errorMessage: "Bu dakika için flashcard kayıt sınırına ulaştın."
  });
  if (!userLimitOk) {
    return;
  }

  const safeCards = dedupeFlashcards(parsedBody.cards, 30);
  if (!safeCards.length) {
    return res.status(400).json({
      error: "Kaydedilecek geçerli flashcard bulunamadı."
    });
  }

  const safeSessionId = sanitizeFlashcardText(parsedBody.sessionId, 120, false) || null;
  const draftCacheKey = buildFlashcardDraftCacheKey({
    userId,
    sessionId: safeSessionId
  });
  const nowIso = new Date().toISOString();
  const rows = safeCards.map((card) => ({
    user_id: userId,
    session_id: safeSessionId,
    source_id: buildStableFlashcardSourceId({ sessionId: safeSessionId, card }),
    card_type: normalizeFlashcardType(card.cardType),
    specialty: sanitizeFlashcardText(card.specialty, 80, false) || null,
    difficulty: normalizeDifficulty(card.difficulty, "Orta"),
    title: sanitizeFlashcardText(card.title, 160, false) || "Klinik Kart",
    front: sanitizeFlashcardText(card.front, 700, true),
    back: sanitizeFlashcardText(card.back, 1400, true),
    tags: sanitizeFlashcardTags(card.tags),
    interval_days: 1,
    repetition_count: 0,
    ease_factor: 2.5,
    due_at: nowIso,
    last_reviewed_at: null,
    created_at: nowIso,
    updated_at: nowIso
  }));

  try {
    const savedRows = await upsertFlashcards({
      supabaseUrl,
      supabaseServiceRoleKey,
      rows
    });
    if (draftCacheKey) {
      await clearCachedFlashcardDrafts(draftCacheKey);
    }

    return res.json({
      ok: true,
      saved_count: savedRows.length,
      cards: savedRows
    });
  } catch (error) {
    return res.status(error?.status || 500).json({
      error: error?.message || "Flashcard kaydı sırasında hata oluştu."
    });
  }
});

app.get("/api/flashcards/today", async (req, res) => {
  const { supabaseUrl, supabaseAnonKey, supabaseServiceRoleKey } = getSupabaseConfig();
  const missing = [];
  if (!supabaseUrl) missing.push("SUPABASE_URL");
  if (!supabaseServiceRoleKey) missing.push("SUPABASE_SERVICE_ROLE_KEY");
  if (missing.length > 0) {
    return res.status(503).json({
      error: `Sunucu ayarları eksik: ${missing.join(", ")}`
    });
  }

  const accessToken = extractBearerToken(req);
  if (!accessToken) {
    return res.status(401).json({
      error: "Yetki belirteci boş."
    });
  }

  const userApiKey = supabaseAnonKey || supabaseServiceRoleKey;
  let userPayload = null;
  try {
    userPayload = await fetchSupabaseUserByToken({
      supabaseUrl,
      userApiKey,
      accessToken
    });
  } catch (error) {
    return res.status(error?.status || 401).json({
      error: error?.message || "Kullanıcı doğrulanamadı."
    });
  }

  const limit = clampRateLimitValue(req.query.limit, 25, 3, 120);
  const specialty = sanitizeFlashcardText(req.query.specialty, 80, false);
  const cardType = sanitizeFlashcardText(req.query.cardType || req.query.card_type, 40, false);

  try {
    const rows = await fetchFlashcardsForUser({
      supabaseUrl,
      supabaseServiceRoleKey,
      userId: userPayload?.id,
      onlyDue: true,
      specialty,
      cardType,
      limit
    });

    return res.json({
      ok: true,
      cards: rows,
      due_count: rows.length
    });
  } catch (error) {
    return res.status(error?.status || 500).json({
      error: error?.message || "Bugünkü flashcard tekrarları alınamadı."
    });
  }
});

app.get("/api/flashcards/collections", async (req, res) => {
  const { supabaseUrl, supabaseAnonKey, supabaseServiceRoleKey } = getSupabaseConfig();
  const missing = [];
  if (!supabaseUrl) missing.push("SUPABASE_URL");
  if (!supabaseServiceRoleKey) missing.push("SUPABASE_SERVICE_ROLE_KEY");
  if (missing.length > 0) {
    return res.status(503).json({
      error: `Sunucu ayarları eksik: ${missing.join(", ")}`
    });
  }

  const accessToken = extractBearerToken(req);
  if (!accessToken) {
    return res.status(401).json({
      error: "Yetki belirteci boş."
    });
  }

  const userApiKey = supabaseAnonKey || supabaseServiceRoleKey;
  let userPayload = null;
  try {
    userPayload = await fetchSupabaseUserByToken({
      supabaseUrl,
      userApiKey,
      accessToken
    });
  } catch (error) {
    return res.status(error?.status || 401).json({
      error: error?.message || "Kullanıcı doğrulanamadı."
    });
  }

  const limit = clampRateLimitValue(req.query.limit, 200, 10, 500);
  const specialty = sanitizeFlashcardText(req.query.specialty, 80, false);
  const cardType = sanitizeFlashcardText(req.query.cardType || req.query.card_type, 40, false);
  const now = Date.now();

  try {
    const rows = await fetchFlashcardsForUser({
      supabaseUrl,
      supabaseServiceRoleKey,
      userId: userPayload?.id,
      specialty,
      cardType,
      limit
    });

    const bySpecialty = {};
    const byCardType = {};
    let dueToday = 0;
    for (const row of rows) {
      const specialtyKey = sanitizeFlashcardText(row?.specialty, 80, false) || "Diğer";
      const typeKey = normalizeFlashcardType(row?.card_type);
      bySpecialty[specialtyKey] = (bySpecialty[specialtyKey] || 0) + 1;
      byCardType[typeKey] = (byCardType[typeKey] || 0) + 1;

      const dueMs = Number(new Date(row?.due_at || "").getTime());
      if (!Number.isNaN(dueMs) && dueMs <= now) {
        dueToday += 1;
      }
    }

    return res.json({
      ok: true,
      cards: rows,
      stats: {
        total: rows.length,
        due_today: dueToday,
        by_specialty: bySpecialty,
        by_card_type: byCardType
      }
    });
  } catch (error) {
    return res.status(error?.status || 500).json({
      error: error?.message || "Flashcard koleksiyonları alınamadı."
    });
  }
});

app.post("/api/flashcards/review", async (req, res) => {
  const ipIdentity = getClientIp(req);
  if (
    (await enforceBruteForceGuard(req, res, {
      scope: "flashcards-review-auth",
      identity: ipIdentity,
      errorMessage: "Çok fazla hatalı deneme tespit edildi. Lütfen daha sonra tekrar dene."
    })) !== true
  ) {
    return;
  }

  const ipLimitOk = await enforceRateLimit(req, res, {
    scope: "flashcards-review-ip",
    identity: ipIdentity,
    maxRequests: clampRateLimitValue(process.env.RATE_LIMIT_FLASHCARDS_REVIEW_IP_PER_MIN, 150, 8, 500),
    windowMs: 60_000,
    errorMessage: "Flashcard tekrar sınırına ulaşıldı. Lütfen biraz sonra tekrar dene."
  });
  if (!ipLimitOk) {
    return;
  }

  const parsedBody = parseJsonWithZod(res, flashcardReviewBodySchema, req.body, {
    message: "Flashcard tekrar isteği geçersiz."
  });
  if (!parsedBody) {
    return;
  }

  const { supabaseUrl, supabaseAnonKey, supabaseServiceRoleKey } = getSupabaseConfig();
  const missing = [];
  if (!supabaseUrl) missing.push("SUPABASE_URL");
  if (!supabaseServiceRoleKey) missing.push("SUPABASE_SERVICE_ROLE_KEY");
  if (missing.length > 0) {
    return res.status(503).json({
      error: `Sunucu ayarları eksik: ${missing.join(", ")}`
    });
  }

  const accessToken = extractBearerToken(req);
  if (!accessToken) {
    await registerAuthFailure({
      scope: "flashcards-review-auth",
      identity: ipIdentity
    });
    return res.status(401).json({
      error: "Yetki belirteci boş."
    });
  }
  maybeSimulateServiceError(req, "supabase", {
    code: ERROR_CODES.SUPABASE_UNAVAILABLE,
    status: 503
  });

  const userApiKey = supabaseAnonKey || supabaseServiceRoleKey;
  let userPayload = null;
  try {
    userPayload = await fetchSupabaseUserByToken({
      supabaseUrl,
      userApiKey,
      accessToken
    });
    await clearAuthFailures({
      scope: "flashcards-review-auth",
      identity: ipIdentity
    });
  } catch (error) {
    if (isAuthFailureStatus(error?.status)) {
      await registerAuthFailure({
        scope: "flashcards-review-auth",
        identity: ipIdentity
      });
    }
    return res.status(error?.status || 401).json({
      error: error?.message || "Kullanıcı doğrulanamadı."
    });
  }

  const userId = sanitizeUuid(userPayload?.id);
  if (!userId) {
    return res.status(401).json({
      error: "Geçerli kullanıcı kimliği bulunamadı."
    });
  }

  const userLimitOk = await enforceRateLimit(req, res, {
    scope: "flashcards-review-user",
    identity: userId,
    maxRequests: clampRateLimitValue(process.env.RATE_LIMIT_FLASHCARDS_REVIEW_USER_PER_MIN, 90, 6, 320),
    windowMs: 60_000,
    errorMessage: "Bu dakika için tekrar sınırına ulaştın."
  });
  if (!userLimitOk) {
    return;
  }

  try {
    const card = await fetchFlashcardByIdForUser({
      supabaseUrl,
      supabaseServiceRoleKey,
      userId,
      cardId: parsedBody.cardId
    });
    if (!card) {
      return res.status(404).json({
        error: "Flashcard bulunamadı."
      });
    }

    const schedule = computeFlashcardNextSchedule(card, parsedBody.rating);
    const nowIso = new Date().toISOString();
    const updated = await updateFlashcardById({
      supabaseUrl,
      supabaseServiceRoleKey,
      cardId: card.id,
      patch: {
        interval_days: schedule.intervalDays,
        repetition_count: schedule.repetitionCount,
        ease_factor: schedule.easeFactor,
        due_at: schedule.dueAt,
        last_reviewed_at: nowIso,
        updated_at: nowIso
      }
    });

    return res.json({
      ok: true,
      card: updated,
      next_due_at: schedule.dueAt
    });
  } catch (error) {
    return res.status(error?.status || 500).json({
      error: error?.message || "Flashcard tekrar kaydı başarısız."
    });
  }
});

app.get("/api/challenge/today", async (req, res) => {
  const { supabaseUrl, supabaseServiceRoleKey } = getSupabaseConfig();
  const nowIso = new Date().toISOString();
  const dateKey = utcDateKey(nowIso);
  const challenge = await resolveDailyChallenge({
    supabaseUrl,
    supabaseServiceRoleKey,
    dateKey,
    nowIso
  });
  const timeLeft = computeChallengeTimeLeft(challenge, nowIso);

  if (!supabaseUrl || !supabaseServiceRoleKey) {
    return res.json({
      challenge,
      time_left: timeLeft,
      stats: {
        attempted_users: 0,
        participant_count: 0,
        average_score: null
      }
    });
  }

  try {
    const statsFromAttempts = await fetchChallengeStatsFromAttempts({
      supabaseUrl,
      supabaseServiceRoleKey,
      challengeId: challenge.id,
      dateKey
    });
    if (statsFromAttempts) {
      return res.json({
        challenge,
        time_left: timeLeft,
        stats: {
          attempted_users: statsFromAttempts.attemptedUsers,
          participant_count: statsFromAttempts.participantCount,
          average_score: statsFromAttempts.averageScore
        }
      });
    }
  } catch {
    // case_sessions fallback asagida
  }

  const baseSelect = "user_id,status,score,updated_at,case_context";
  const baseHeaders = {
    apikey: supabaseServiceRoleKey,
    Authorization: `Bearer ${supabaseServiceRoleKey}`
  };

  const tryFetch = async (url) => {
    const resp = await fetch(url, {
      method: "GET",
      headers: baseHeaders
    });
    if (!resp.ok) {
      const txt = await resp.text();
      throw new Error(txt || String(resp.status));
    }
    const rows = await resp.json();
    return Array.isArray(rows) ? rows : [];
  };

  try {
    let rows = [];

    try {
      const qs = new URLSearchParams({
        select: baseSelect,
        order: "updated_at.desc",
        limit: "5000"
      });
      qs.append("case_context->>challenge_id", `eq.${challenge.id}`);
      rows = await tryFetch(`${supabaseUrl}/rest/v1/case_sessions?${qs.toString()}`);
    } catch {
      const challengeStart = toIsoString(challenge.generatedAt) || new Date(Date.now() - 24 * 60 * 60 * 1000).toISOString();
      const challengeEnd = toIsoString(challenge.expiresAt) || addHoursIso(challengeStart, 24) || new Date().toISOString();
      const qs = new URLSearchParams({
        select: baseSelect,
        order: "updated_at.desc",
        limit: "5000"
      });
      qs.append("updated_at", `gte.${challengeStart}`);
      qs.append("updated_at", `lt.${challengeEnd}`);
      rows = await tryFetch(`${supabaseUrl}/rest/v1/case_sessions?${qs.toString()}`);
    }

    const stats = computeChallengeStats(rows, challenge.id);
    return res.json({
      challenge,
      time_left: timeLeft,
      stats: {
        attempted_users: stats.attemptedUsers,
        participant_count: stats.participantCount,
        average_score: stats.averageScore
      }
    });
  } catch {
    return res.json({
      challenge,
      time_left: timeLeft,
      stats: {
        attempted_users: 0,
        participant_count: 0,
        average_score: null
      }
    });
  }
});

app.post("/api/challenge/today/reset", async (req, res) => {
  const resetIdentity = getClientIp(req);
  if (
    (await enforceBruteForceGuard(req, res, {
      scope: "challenge-reset-auth",
      identity: resetIdentity,
      errorMessage: "Çok fazla hatalı günlük vaka sıfırlama denemesi tespit edildi. Lütfen daha sonra tekrar dene."
    })) !== true
  ) {
    return;
  }

  refreshEnv();
  const configuredResetToken = String(process.env.CHALLENGE_RESET_TOKEN || "").trim();
  const providedResetToken = String(
    req.headers["x-challenge-reset-token"] || req.body?.resetToken || ""
  ).trim();

  if (configuredResetToken && providedResetToken !== configuredResetToken) {
    await registerAuthFailure({
      scope: "challenge-reset-auth",
      identity: resetIdentity
    });
    return res.status(403).json({
      error: "Günlük vaka sıfırlama yetkisi reddedildi."
    });
  }
  await clearAuthFailures({
    scope: "challenge-reset-auth",
    identity: resetIdentity
  });

  const { supabaseUrl, supabaseServiceRoleKey } = getSupabaseConfig();
  const nowIso = new Date().toISOString();
  const dateKey = buildManualChallengeDateKey(nowIso);

  const challenge = await resolveDailyChallenge({
    supabaseUrl,
    supabaseServiceRoleKey,
    dateKey,
    nowIso,
    forceRefresh: true
  });

  const timeLeft = computeChallengeTimeLeft(challenge, nowIso);
  return res.json({
    ok: true,
    challenge,
    time_left: timeLeft
  });
});

app.post("/api/elevenlabs/session-auth", async (req, res) => {
  const parsedBody = parseJsonWithZod(res, elevenSessionAuthBodySchema, req.body, {
    message: "ElevenLabs oturum isteği geçersiz."
  });
  if (!parsedBody) {
    return;
  }

  const accessToken = extractBearerToken(req);
  const authIdentityHint = accessToken ? `token:${sha256Short(accessToken)}` : "token:missing";

  if (
    (await enforceBruteForceGuard(req, res, {
      scope: "elevenlabs-session-auth",
      identity: authIdentityHint,
      errorMessage: "Çok fazla hatalı oturum denemesi tespit edildi. Lütfen daha sonra tekrar dene."
    })) !== true
  ) {
    return;
  }

  const { supabaseUrl, supabaseAnonKey, supabaseServiceRoleKey } = getSupabaseConfig();
  const { elevenLabsApiKey, elevenLabsApiBase, allowedAgentIds } = getElevenLabsConfig();
  const missing = [];

  if (!supabaseUrl) {
    missing.push("SUPABASE_URL");
  }
  if (!supabaseServiceRoleKey) {
    missing.push("SUPABASE_SERVICE_ROLE_KEY");
  }
  if (!elevenLabsApiKey) {
    missing.push("ELEVENLABS_API_KEY");
  }
  if (!elevenLabsApiBase) {
    missing.push("ELEVENLABS_API_BASE");
  }

  const userApiKey = supabaseAnonKey || supabaseServiceRoleKey;

  if (!supabaseUrl || !supabaseServiceRoleKey || !elevenLabsApiKey || !elevenLabsApiBase) {
    return res.status(503).json({
      error: `Sunucu ayarları eksik: ${missing.join(", ")}`
    });
  }

  if (!accessToken) {
    await registerAuthFailure({
      scope: "elevenlabs-session-auth",
      identity: authIdentityHint
    });
    return res.status(401).json({
      error: "Yetki belirteci boş."
    });
  }

  let userPayload = null;
  try {
    userPayload = await fetchSupabaseUserByToken({
      supabaseUrl,
      userApiKey,
      accessToken
    });

    if (
      (await enforceBruteForceGuard(req, res, {
        scope: "elevenlabs-session-auth",
        identity: userPayload?.id || authIdentityHint,
        errorMessage: "Çok fazla hatalı oturum denemesi tespit edildi. Lütfen daha sonra tekrar dene."
      })) !== true
    ) {
      return;
    }

    await clearAuthFailures({
      scope: "elevenlabs-session-auth",
      identity: authIdentityHint
    });
    await clearAuthFailures({
      scope: "elevenlabs-session-auth",
      identity: userPayload?.id || authIdentityHint
    });
  } catch (error) {
    if (isAuthFailureStatus(error?.status)) {
      await registerAuthFailure({
        scope: "elevenlabs-session-auth",
        identity: authIdentityHint
      });
    }
    return res.status(error?.status || 500).json({
      error: error?.message || "Kullanıcı doğrulanamadı."
    });
  }

  try {
    await assertAiAccessAllowed({
      supabaseUrl,
      supabaseServiceRoleKey,
      userId: userPayload?.id
    });

    const userLimitOk = await enforceRateLimit(req, res, {
      scope: "elevenlabs-auth-user",
      identity: userPayload?.id,
      maxRequests: clampRateLimitValue(process.env.RATE_LIMIT_ELEVENLABS_AUTH_USER_PER_MIN, 24, 3, 120),
      windowMs: clampRateLimitValue(
        process.env.RATE_LIMIT_ELEVENLABS_AUTH_USER_WINDOW_MS,
        10 * 60_000,
        30_000,
        60 * 60_000
      ),
      errorMessage: "Oturum oluşturma sınırına ulaştın. Lütfen kısa bir süre sonra tekrar dene."
    });
    if (!userLimitOk) {
      return;
    }
  } catch (error) {
    return res.status(error?.status || 500).json({
      error: error?.message || "Kullanıcı doğrulanamadı."
    });
  }

  const userId = sanitizeUuid(userPayload?.id);
  if (!userId) {
    return res.status(401).json({
      error: "Geçerli kullanıcı kimliği bulunamadı."
    });
  }

  const requestedMode = String(parsedBody?.mode || "").trim().toLowerCase() === "text" ? "text" : "voice";
  const {
    voiceAgentId: requiredVoiceAgentId,
    textAgentId: requiredTextAgentId
  } = getElevenLabsAgentModeConfig();
  const providedAgentId = sanitizeAgentId(parsedBody.agentId);
  const agentId = requestedMode === "text"
    ? requiredTextAgentId
    : (providedAgentId || requiredVoiceAgentId);
  if (providedAgentId && providedAgentId !== agentId) {
    console.warn(
      `[session-auth] mode-agent mismatch provided=${providedAgentId} resolved=${agentId} mode=${requestedMode}`
    );
  }

  if (allowedAgentIds.length > 0 && !allowedAgentIds.includes(agentId)) {
    return res.status(403).json({
      error: "Bu agentId için yetki tanımlı değil."
    });
  }

  const sessionTokenCfg = getSessionAuthTokenConfig();
  if (!sessionTokenCfg.secret) {
    return res.status(503).json({
      error: "Session token secret ayarı eksik."
    });
  }

  const providedSessionWindowToken = String(
    parsedBody?.sessionWindowToken || req.headers["x-session-window-token"] || ""
  ).trim();
  let providedWindowPayload = null;
  let sameSession = false;
  if (providedSessionWindowToken) {
    try {
      providedWindowPayload = verifySessionWindowToken(providedSessionWindowToken, {
        expectedUserId: userId,
        expectedAgentId: agentId
      });
    } catch (error) {
      if (isAuthFailureStatus(error?.status)) {
        await registerAuthFailure({
          scope: "elevenlabs-session-auth",
          identity: userId
        });
      }
      return res.status(error?.status || 401).json({
        error: error?.message || "Session window token doğrulanamadı."
      });
    }
  }

  if (isSingleSessionEnforced()) {
    const activeSession = await getActiveElevenSession(userId);
    if (activeSession) {
      sameSession =
        Boolean(providedWindowPayload) &&
        String(providedWindowPayload?.jti || "") === String(activeSession.jti || "");

      if (!sameSession) {
        const remainingSeconds = Math.max(
          1,
          Math.ceil((Number(activeSession.lockUntilMs || Date.now()) - Date.now()) / 1000)
        );
        return res.status(409).json({
          error: "Bu kullanıcı için zaten aktif bir ElevenLabs oturumu var.",
          code: "ACTIVE_SESSION_EXISTS",
          active_agent_id: activeSession.agentId || null,
          retry_after_seconds: remainingSeconds
        });
      }
    }
  }

  const dynamicVariables = sanitizeDynamicVariables(parsedBody.dynamicVariables);
  if (requestedMode === "text") {
    const missingRequiredVars = [];
    if (!dynamicVariables.specialty) {
      missingRequiredVars.push("specialty");
    }
    if (!dynamicVariables.difficulty_level) {
      missingRequiredVars.push("difficulty_level");
    }
    if (missingRequiredVars.length > 0) {
      return res.status(400).json({
        error: "Text mode için zorunlu dynamic variable eksik.",
        code: "MISSING_DYNAMIC_VARIABLES",
        missing: missingRequiredVars
      });
    }
  }
  const conversationConfigOverride =
    requestedMode === "text"
      ? {
          conversation: {
            text_only: true
          }
        }
      : null;

  const caseStartHourlyLimitOk = await enforceRateLimit(req, res, {
    scope: "case-start-user-hour",
    identity: userId,
    maxRequests: getSuspiciousSecurityConfig().caseStartThresholdPerHour,
    windowMs: getSuspiciousSecurityConfig().caseStartWindowMs,
    errorMessage: "1 saat içinde çok fazla vaka başlatıldı. Lütfen bir süre bekleyip tekrar dene.",
    suspiciousEventType: "excessive_case_start",
    suspiciousUserId: userId
  });
  if (!caseStartHourlyLimitOk) {
    return;
  }
  maybeSimulateServiceError(req, "elevenlabs", {
    code: ERROR_CODES.ELEVENLABS_UNAVAILABLE,
    status: 503
  });
  const base = String(elevenLabsApiBase).replace(/\/+$/g, "");
  const authHeaders = {
    "xi-api-key": elevenLabsApiKey,
    "Content-Type": "application/json"
  };

  const buildAuthUrl = (endpointPath, { includeTextOnlyOverride = false } = {}) => {
    const qs = new URLSearchParams();
    qs.set("agent_id", agentId);
    for (const [key, value] of Object.entries(dynamicVariables)) {
      qs.append(`dynamic_variables[${key}]`, value);
    }
    if (includeTextOnlyOverride) {
      qs.set("conversation_config_override[conversation][text_only]", "true");
    }
    return `${base}${endpointPath}?${qs.toString()}`;
  };

  const tokenUrl = buildAuthUrl("/v1/convai/conversation/token", {
    includeTextOnlyOverride: requestedMode === "text"
  });
  const signedUrlEndpoint = buildAuthUrl("/v1/convai/conversation/get-signed-url", {
    includeTextOnlyOverride: requestedMode === "text"
  });
  const authTimeoutMs = Math.max(
    5000,
    Math.min(30000, Number(process.env.ELEVENLABS_AUTH_TIMEOUT_MS || 12000))
  );
  const requestPayload = {
    agent_id: agentId,
    dynamic_variables: dynamicVariables
  };
  if (conversationConfigOverride) {
    requestPayload.conversation_config_override = conversationConfigOverride;
  }
  const requestBody = JSON.stringify(requestPayload);
  console.info(
    `[session-auth] agentId=${agentId} mode=${requestedMode} textOnlyOverride=${Boolean(conversationConfigOverride)} dynamicVarCount=${Object.keys(dynamicVariables).length}`
  );
  console.info(
    `[session-auth] dynamicVarKeys=${Object.keys(dynamicVariables).sort().join(",")} specialty=${dynamicVariables.specialty || "-"} difficulty_level=${dynamicVariables.difficulty_level || "-"} mode=${dynamicVariables.mode || "-"} client_mode=${dynamicVariables.client_mode || "-"}`
  );

  try {
    const tokenRequest = await executeWithServiceFallback({
      req,
      res,
      service: "elevenlabs",
      primary: async () => {
        const getResp = await fetchWithTimeout(
          tokenUrl,
          {
            method: "GET",
            headers: authHeaders
          },
          authTimeoutMs
        );
        if (!getResp.ok) {
          throw new AppError({
            message: `ElevenLabs token GET başarısız (${getResp.status})`,
            code: ERROR_CODES.ELEVENLABS_UNAVAILABLE,
            status: getResp.status >= 500 ? 502 : getResp.status,
            service: "elevenlabs"
          });
        }
        return getResp;
      },
      fallback: () =>
        fetchWithTimeout(
          `${base}/v1/convai/conversation/token`,
          { method: "POST", headers: authHeaders, body: requestBody },
          authTimeoutMs
        ),
      fallbackMessage: "ElevenLabs token POST fallback"
    });

    const tokenResp = tokenRequest?.result instanceof Response ? tokenRequest.result : tokenRequest;

    const tokenRaw = await tokenResp.text();
    const tokenBody = parseJsonMaybe(tokenRaw) || {};

    let conversationToken =
      tokenBody?.token || tokenBody?.conversation_token || tokenBody?.conversationToken || null;
    let signedUrl = null;
    let signedStatus = null;

    if (!conversationToken) {
      try {
        const signedRequest = await executeWithServiceFallback({
          req,
          res,
          service: "elevenlabs",
          primary: async () => {
            const getResp = await fetchWithTimeout(
              signedUrlEndpoint,
              {
                method: "GET",
                headers: authHeaders
              },
              Math.min(authTimeoutMs, 9000)
            );
            if (!getResp.ok) {
              throw new AppError({
                message: `ElevenLabs signed-url GET başarısız (${getResp.status})`,
                code: ERROR_CODES.ELEVENLABS_UNAVAILABLE,
                status: getResp.status >= 500 ? 502 : getResp.status,
                service: "elevenlabs"
              });
            }
            return getResp;
          },
          fallback: () =>
            fetchWithTimeout(
              `${base}/v1/convai/conversation/get-signed-url`,
              { method: "POST", headers: authHeaders, body: requestBody },
              Math.min(authTimeoutMs, 9000)
            ),
          fallbackMessage: "ElevenLabs signed-url POST fallback"
        });
        const signedResp =
          signedRequest?.result instanceof Response ? signedRequest.result : signedRequest;
        signedStatus = signedResp.status;
        const signedRaw = await signedResp.text();
        const signedBody = parseJsonMaybe(signedRaw) || {};
        signedUrl = signedBody?.signed_url || signedBody?.signedUrl || null;
        if (!conversationToken && signedUrl) {
          conversationToken = extractConversationTokenFromSignedUrl(signedUrl);
        }
      } catch {
        // signed-url fallback opsiyonel; token var ise buna gerek kalmaz.
      }
    }

    if (!conversationToken && !signedUrl) {
      return res.status(502).json({
        error: "ElevenLabs oturum yetkilendirmesi alınamadı.",
        details: {
          tokenStatus: tokenResp.status,
          signedUrlStatus: signedStatus
        }
      });
    }

    const windowToken = createSessionWindowToken({
      userId,
      agentId,
      mode: requestedMode
    });
    const verifiedWindowPayload = verifySessionWindowToken(windowToken.token, {
      expectedUserId: userId,
      expectedAgentId: agentId
    });
    const activeSet = await setActiveElevenSession({
      userId,
      jti: verifiedWindowPayload.jti,
      agentId,
      mode: requestedMode,
      issuedAtSec: verifiedWindowPayload.iat,
      expiresAtSec: verifiedWindowPayload.exp,
      activeWindowEndsAtSec: verifiedWindowPayload.win
    }, {
      ifNotExists: isSingleSessionEnforced() && !sameSession
    });

    if (isSingleSessionEnforced() && !activeSet) {
      return res.status(409).json({
        error: "Bu kullanıcı için zaten aktif bir ElevenLabs oturumu var.",
        code: "ACTIVE_SESSION_EXISTS",
        active_agent_id: agentId
      });
    }

    res.setHeader("Cache-Control", "no-store, max-age=0");
    res.setHeader("Pragma", "no-cache");
    await incrementElevenLabsMetrics({
      agentId,
      mode: requestedMode
    });

    return res.json({
      ok: true,
      agentId,
      conversationToken,
      signedUrl,
      expiresInSeconds: Number(tokenBody?.expires_in) || null,
      sessionWindowToken: windowToken.token,
      sessionWindowTokenTtlSeconds: Number(verifiedWindowPayload.exp) - Number(verifiedWindowPayload.iat),
      sessionActiveWindowSeconds: Number(verifiedWindowPayload.win) - Number(verifiedWindowPayload.iat),
      sessionWindowIssuedAt: new Date(Number(verifiedWindowPayload.iat) * 1000).toISOString(),
      sessionWindowExpiresAt: new Date(Number(verifiedWindowPayload.exp) * 1000).toISOString(),
      sessionActiveWindowEndsAt: new Date(Number(verifiedWindowPayload.win) * 1000).toISOString(),
      dynamicVariables
    });
  } catch (error) {
    await captureAppError({
      error,
      req,
      res,
      fallback: {
        service: "elevenlabs",
        code: ERROR_CODES.ELEVENLABS_UNAVAILABLE,
        status: Number(error?.name === "AbortError" ? 504 : 502)
      },
      metadata: {
        route: "/api/elevenlabs/session-auth"
      }
    });
    const message =
      error?.name === "AbortError"
        ? `ElevenLabs auth timeout (${authTimeoutMs}ms)`
        : error?.message || "Bilinmeyen hata";
    return res.status(502).json({
      error: `ElevenLabs erişimi başarısız: ${message}`
    });
  }
});

app.post("/api/elevenlabs/session-end", async (req, res) => {
  const { supabaseUrl, supabaseAnonKey, supabaseServiceRoleKey } = getSupabaseConfig();
  const missing = [];
  if (!supabaseUrl) missing.push("SUPABASE_URL");
  if (!supabaseServiceRoleKey) missing.push("SUPABASE_SERVICE_ROLE_KEY");
  const userApiKey = supabaseAnonKey || supabaseServiceRoleKey;

  if (!supabaseUrl || !supabaseServiceRoleKey) {
    return res.status(503).json({
      error: `Sunucu ayarları eksik: ${missing.join(", ")}`
    });
  }

  const accessToken = extractBearerToken(req);
  if (!accessToken) {
    return res.status(401).json({
      error: "Yetki belirteci boş."
    });
  }

  let userPayload = null;
  try {
    userPayload = await fetchSupabaseUserByToken({
      supabaseUrl,
      userApiKey,
      accessToken
    });
  } catch (error) {
    return res.status(error?.status || 401).json({
      error: error?.message || "Kullanıcı doğrulanamadı."
    });
  }

  const userId = sanitizeUuid(userPayload?.id);
  if (!userId) {
    return res.status(401).json({
      error: "Geçerli kullanıcı kimliği bulunamadı."
    });
  }

  const providedSessionWindowToken = String(
    req.body?.sessionWindowToken || req.headers["x-session-window-token"] || ""
  ).trim();
  const providedAgentId = sanitizeAgentId(req.body?.agentId || req.headers["x-eleven-agent-id"]);
  let expectedJti = null;

  if (providedSessionWindowToken) {
    try {
      const payload = verifySessionWindowToken(providedSessionWindowToken, {
        expectedUserId: userId,
        expectedAgentId: providedAgentId || undefined
      });
      expectedJti = String(payload?.jti || "").trim() || null;
    } catch (error) {
      return res.status(error?.status || 401).json({
        error: error?.message || "Session window token doğrulanamadı."
      });
    }
  }

  const released = await clearActiveElevenSession({
    userId,
    expectedJti: expectedJti || undefined
  });

  return res.json({
    ok: true,
    released
  });
});

app.post("/api/elevenlabs/session-touch", async (req, res) => {
  const parsedBody = parseJsonWithZod(res, elevenSessionTouchBodySchema, req.body, {
    message: "Session touch isteği geçersiz."
  });
  if (!parsedBody) {
    return;
  }

  const { supabaseUrl, supabaseAnonKey, supabaseServiceRoleKey } = getSupabaseConfig();
  const missing = [];
  if (!supabaseUrl) missing.push("SUPABASE_URL");
  if (!supabaseServiceRoleKey) missing.push("SUPABASE_SERVICE_ROLE_KEY");
  const userApiKey = supabaseAnonKey || supabaseServiceRoleKey;

  if (!supabaseUrl || !supabaseServiceRoleKey) {
    return res.status(503).json({
      error: `Sunucu ayarları eksik: ${missing.join(", ")}`
    });
  }

  const accessToken = extractBearerToken(req);
  if (!accessToken) {
    return res.status(401).json({
      error: "Yetki belirteci boş."
    });
  }

  let userPayload = null;
  try {
    userPayload = await fetchSupabaseUserByToken({
      supabaseUrl,
      userApiKey,
      accessToken
    });
  } catch (error) {
    return res.status(error?.status || 401).json({
      error: error?.message || "Kullanıcı doğrulanamadı."
    });
  }

  const userId = sanitizeUuid(userPayload?.id);
  if (!userId) {
    return res.status(401).json({
      error: "Geçerli kullanıcı kimliği bulunamadı."
    });
  }

  const sessionWindowToken = String(parsedBody.sessionWindowToken || "").trim();
  const providedAgentId = sanitizeAgentId(parsedBody.agentId || req.headers["x-eleven-agent-id"]);

  let payload = null;
  try {
    payload = verifySessionWindowToken(sessionWindowToken, {
      expectedUserId: userId,
      expectedAgentId: providedAgentId || undefined
    });
  } catch (error) {
    return res.status(error?.status || 401).json({
      error: error?.message || "Session window token doğrulanamadı."
    });
  }

  const nowSec = Math.floor(Date.now() / 1000);
  const { refreshSec } = getActiveSessionHeartbeatConfig();
  const lockUntilSec = Math.min(
    Number(payload.exp || nowSec + refreshSec),
    nowSec + refreshSec
  );
  const lockUntilMs = lockUntilSec * 1000;
  if (lockUntilMs <= Date.now()) {
    return res.status(401).json({
      error: "Session window süresi dolmuş."
    });
  }

  const touched = await touchActiveElevenSession({
    userId,
    expectedJti: String(payload.jti || ""),
    expectedAgentId: String(payload.aid || ""),
    mode: payload.mode,
    lockUntilMs
  });

  if (!touched) {
    return res.status(409).json({
      error: "Aktif session bulunamadı.",
      code: "ACTIVE_SESSION_NOT_FOUND"
    });
  }

  return res.json({
    ok: true,
    lockUntilMs: Number(touched.lockUntilMs || 0),
    ttlSeconds: Math.max(1, Math.ceil((Number(touched.lockUntilMs || Date.now()) - Date.now()) / 1000))
  });
});

app.post("/api/text-agent/start", async (req, res) => {
  const parsedBody = parseJsonWithZod(res, textAgentStartBodySchema, req.body, {
    message: "Text oturum başlangıç isteği geçersiz."
  });
  if (!parsedBody) {
    return;
  }

  const ipIdentity = getClientIp(req);
  if (
    (await enforceBruteForceGuard(req, res, {
      scope: "text-agent-start-auth",
      identity: ipIdentity,
      errorMessage: "Çok fazla hatalı kimlik denemesi tespit edildi. Lütfen daha sonra tekrar dene."
    })) !== true
  ) {
    return;
  }

  const textStartIpLimitOk = await enforceRateLimit(req, res, {
    scope: "text-agent-start-ip",
    identity: ipIdentity,
    maxRequests: clampRateLimitValue(process.env.RATE_LIMIT_TEXT_START_IP_PER_MIN, 40, 5, 220),
    windowMs: 60_000,
    errorMessage: "Text vaka başlangıç isteği sınırına ulaşıldı. Lütfen biraz sonra tekrar dene."
  });
  if (!textStartIpLimitOk) {
    return;
  }

  const { supabaseUrl, supabaseAnonKey, supabaseServiceRoleKey } = getSupabaseConfig();
  const missing = [];

  if (!supabaseUrl) missing.push("SUPABASE_URL");
  if (!supabaseServiceRoleKey) missing.push("SUPABASE_SERVICE_ROLE_KEY");
  if (!process.env.OPENAI_API_KEY) missing.push("OPENAI_API_KEY");

  if (missing.length > 0) {
    return res.status(503).json({
      error: `Sunucu ayarları eksik: ${missing.join(", ")}`
    });
  }

  const accessToken = extractBearerToken(req);
  if (!accessToken) {
    await registerAuthFailure({
      scope: "text-agent-start-auth",
      identity: ipIdentity
    });
    return res.status(401).json({ error: "Yetki belirteci boş." });
  }
  maybeSimulateServiceError(req, "supabase", {
    code: ERROR_CODES.SUPABASE_UNAVAILABLE,
    status: 503
  });

  const userApiKey = supabaseAnonKey || supabaseServiceRoleKey;
  let userPayload = null;
  try {
    userPayload = await fetchSupabaseUserByToken({
      supabaseUrl,
      userApiKey,
      accessToken
    });
    await clearAuthFailures({
      scope: "text-agent-start-auth",
      identity: ipIdentity
    });
  } catch (error) {
    if (isAuthFailureStatus(error?.status)) {
      await registerAuthFailure({
        scope: "text-agent-start-auth",
        identity: ipIdentity
      });
    }
    return res.status(error?.status || 500).json({
      error: error?.message || "Kullanıcı doğrulanamadı."
    });
  }

  try {
    await assertAiAccessAllowed({
      supabaseUrl,
      supabaseServiceRoleKey,
      userId: userPayload?.id
    });

    const userLimitOk = await enforceRateLimit(req, res, {
      scope: "text-agent-start-user",
      identity: userPayload?.id || accessToken,
      maxRequests: clampRateLimitValue(process.env.RATE_LIMIT_TEXT_START_USER_PER_MIN, 20, 2, 120),
      windowMs: 60_000,
      errorMessage: "Kısa sürede çok fazla text vaka başlatıldı. Lütfen kısa süre bekleyip tekrar dene."
    });
    if (!userLimitOk) {
      return;
    }
  } catch (error) {
    return res.status(error?.status || 500).json({
      error: error?.message || "Kullanıcı doğrulanamadı."
    });
  }

  const userId = sanitizeUuid(userPayload?.id);
  const caseStartHourlyLimitOk = await enforceRateLimit(req, res, {
    scope: "case-start-user-hour",
    identity: userId || accessToken,
    maxRequests: getSuspiciousSecurityConfig().caseStartThresholdPerHour,
    windowMs: getSuspiciousSecurityConfig().caseStartWindowMs,
    errorMessage: "1 saat içinde çok fazla vaka başlatıldı. Lütfen bir süre bekleyip tekrar dene.",
    suspiciousEventType: "excessive_case_start",
    suspiciousUserId: userId || null
  });
  if (!caseStartHourlyLimitOk) {
    return;
  }

  const difficulty = normalizeDifficulty(parsedBody?.difficulty, "Orta");
  const specialty = sanitizeChallengeLine(parsedBody?.specialty || "Dahiliye", 56) || "Dahiliye";
  const dynamicVariables = sanitizeDynamicVariables(parsedBody?.dynamicVariables);
  const userName =
    sanitizeChallengeLine(dynamicVariables.user_name || parsedBody?.userName || "Kullanıcı", 42) || "Kullanıcı";
  const textModel = process.env.OPENAI_TEXT_AGENT_MODEL || "gpt-4.1-mini";
  maybeSimulateServiceError(req, "openai", {
    code: ERROR_CODES.OPENAI_UNAVAILABLE,
    status: 503
  });

  try {
    const response = await openai.responses.create(
      {
        model: textModel,
        temperature: 0.7,
        max_output_tokens: 220,
        instructions: TEXT_AGENT_START_INSTRUCTIONS,
        input:
          `Kullanıcı: ${userName}\n` +
          `Seçilen bölüm: ${specialty}\n` +
          `Seçilen zorluk: ${difficulty}\n` +
          "Vaka açılışını şimdi üret."
      },
      { timeout: 12000 }
    );

    const opening =
      sanitizeChallengeLine(extractOutputText(response), 320) ||
      "Yeni vaka başladı. Şikayetini değerlendirmek için ilk sorunu sor.";

    return res.json({
      ok: true,
      opening_message: opening
    });
  } catch (error) {
    await captureAppError({
      error,
      req,
      res,
      fallback: {
        service: "openai",
        code: ERROR_CODES.OPENAI_UNAVAILABLE,
        status: Number(error?.name === "AbortError" ? 504 : 502)
      },
      metadata: {
        route: "/api/text-agent/start",
        model: textModel
      }
    });
    const msg = error?.message || "Bilinmeyen hata";
    return res.status(502).json({
      error: `Text vaka başlangıcı üretilemedi: ${msg}`
    });
  }
});

app.post("/api/text-agent/reply", async (req, res) => {
  const parsedBody = parseJsonWithZod(res, textAgentReplyBodySchema, req.body, {
    message: "Text mesaj isteği gövdesi geçersiz."
  });
  if (!parsedBody) {
    return;
  }

  const ipIdentity = getClientIp(req);
  if (
    (await enforceBruteForceGuard(req, res, {
      scope: "text-agent-reply-auth",
      identity: ipIdentity,
      errorMessage: "Çok fazla hatalı kimlik denemesi tespit edildi. Lütfen daha sonra tekrar dene."
    })) !== true
  ) {
    return;
  }

  const textReplyIpLimitOk = await enforceRateLimit(req, res, {
    scope: "text-agent-reply-ip",
    identity: ipIdentity,
    maxRequests: clampRateLimitValue(process.env.RATE_LIMIT_TEXT_REPLY_IP_PER_MIN, 120, 10, 500),
    windowMs: 60_000,
    errorMessage: "Kısa sürede çok fazla mesaj gönderildi. Lütfen birkaç saniye bekleyip tekrar dene."
  });
  if (!textReplyIpLimitOk) {
    return;
  }

  const { supabaseUrl, supabaseAnonKey, supabaseServiceRoleKey } = getSupabaseConfig();
  const missing = [];

  if (!supabaseUrl) missing.push("SUPABASE_URL");
  if (!supabaseServiceRoleKey) missing.push("SUPABASE_SERVICE_ROLE_KEY");
  if (!process.env.OPENAI_API_KEY) missing.push("OPENAI_API_KEY");

  if (missing.length > 0) {
    return res.status(503).json({
      error: `Sunucu ayarları eksik: ${missing.join(", ")}`
    });
  }

  const accessToken = extractBearerToken(req);
  if (!accessToken) {
    await registerAuthFailure({
      scope: "text-agent-reply-auth",
      identity: ipIdentity
    });
    return res.status(401).json({ error: "Yetki belirteci boş." });
  }
  maybeSimulateServiceError(req, "supabase", {
    code: ERROR_CODES.SUPABASE_UNAVAILABLE,
    status: 503
  });

  const userApiKey = supabaseAnonKey || supabaseServiceRoleKey;
  let userPayload = null;
  try {
    userPayload = await fetchSupabaseUserByToken({
      supabaseUrl,
      userApiKey,
      accessToken
    });
    await clearAuthFailures({
      scope: "text-agent-reply-auth",
      identity: ipIdentity
    });
  } catch (error) {
    if (isAuthFailureStatus(error?.status)) {
      await registerAuthFailure({
        scope: "text-agent-reply-auth",
        identity: ipIdentity
      });
    }
    return res.status(error?.status || 500).json({
      error: error?.message || "Kullanıcı doğrulanamadı."
    });
  }

  try {
    await assertAiAccessAllowed({
      supabaseUrl,
      supabaseServiceRoleKey,
      userId: userPayload?.id
    });

    const userLimitOk = await enforceRateLimit(req, res, {
      scope: "text-agent-reply-user",
      identity: userPayload?.id || accessToken,
      maxRequests: clampRateLimitValue(process.env.RATE_LIMIT_TEXT_REPLY_USER_PER_MIN, 80, 8, 300),
      windowMs: 60_000,
      errorMessage: "Mesaj sınırına ulaşıldı. Lütfen kısa bir süre sonra tekrar dene."
    });
    if (!userLimitOk) {
      return;
    }
  } catch (error) {
    return res.status(error?.status || 500).json({
      error: error?.message || "Kullanıcı doğrulanamadı."
    });
  }

  const difficulty = normalizeDifficulty(parsedBody?.difficulty, "Orta");
  const specialty = sanitizeChallengeLine(parsedBody?.specialty || "Dahiliye", 56) || "Dahiliye";
  const dynamicVariables = sanitizeDynamicVariables(parsedBody?.dynamicVariables);
  const userName =
    sanitizeChallengeLine(dynamicVariables.user_name || parsedBody?.userName || "Kullanıcı", 42) || "Kullanıcı";
  const userMessage = sanitizeChallengeLine(parsedBody?.userMessage || "", 200);
  const conversation = normalizeTextAgentConversation(parsedBody?.conversation);

  if (!userMessage) {
    return res.status(400).json({
      error: "userMessage boş olamaz."
    });
  }
  if (userMessage.length > 200) {
    return res.status(400).json({
      error: "Maximum message length is 200 characters."
    });
  }

  const textSessionMaxMessages = clampRateLimitValue(process.env.TEXT_SESSION_MAX_MESSAGES, 48, 8, 240);
  const textSessionMaxUserMessages = clampRateLimitValue(
    process.env.TEXT_SESSION_MAX_USER_MESSAGES,
    24,
    4,
    120
  );
  const textSessionMaxUserChars = clampRateLimitValue(
    process.env.TEXT_SESSION_MAX_USER_CHARS,
    4000,
    400,
    50000
  );
  const projectedConversation = [...conversation, { source: "user", message: userMessage }];
  const projectedUsage = computeConversationUsage(projectedConversation);
  if (
    projectedUsage.totalMessages > textSessionMaxMessages ||
    projectedUsage.userMessages > textSessionMaxUserMessages ||
    projectedUsage.userChars >= textSessionMaxUserChars
  ) {
    return res.status(429).json({ error: "Session character limit reached." });
  }

  const convoBlock = conversation
    .slice(-24)
    .map((item) => `${item.source === "user" ? "KULLANICI" : "HASTA_VEYA_KOC"}: ${item.message}`)
    .join("\n");

  const textModel = process.env.OPENAI_TEXT_AGENT_MODEL || "gpt-4.1-mini";
  maybeSimulateServiceError(req, "openai", {
    code: ERROR_CODES.OPENAI_UNAVAILABLE,
    status: 503
  });

  try {
    const response = await openai.responses.create(
      {
        model: textModel,
        temperature: 0.65,
        max_output_tokens: 300,
        instructions: TEXT_AGENT_REPLY_INSTRUCTIONS,
        input:
          `Kullanıcı adı: ${userName}\n` +
          `Bölüm: ${specialty}\n` +
          `Zorluk: ${difficulty}\n` +
          `Geçmiş konuşma:\n${convoBlock || "N/A"}\n\n` +
          `Kullanıcının son mesajı: ${userMessage}\n` +
          "Sadece vaka rolünde yanıt üret."
      },
      { timeout: 15000 }
    );

    const reply =
      sanitizeChallengeLine(extractOutputText(response), 340) ||
      "Anladım. Devam etmek için hastaya bir sonraki klinik sorunu sorabilirsin.";

    return res.json({
      ok: true,
      reply,
      should_end: false
    });
  } catch (error) {
    await captureAppError({
      error,
      req,
      res,
      fallback: {
        service: "openai",
        code: ERROR_CODES.OPENAI_UNAVAILABLE,
        status: Number(error?.name === "AbortError" ? 504 : 502)
      },
      metadata: {
        route: "/api/text-agent/reply",
        model: textModel
      }
    });
    const msg = error?.message || "Bilinmeyen hata";
    return res.status(502).json({
      error: `Text yanıt üretilemedi: ${msg}`
    });
  }
});

function extractOutputText(response) {
  if (typeof response.output_text === "string" && response.output_text.trim()) {
    return response.output_text.trim();
  }

  const chunks = [];
  for (const outputItem of response.output || []) {
    if (outputItem.type !== "message") {
      continue;
    }

    for (const contentItem of outputItem.content || []) {
      if (contentItem.type === "output_text" && contentItem.text) {
        chunks.push(contentItem.text);
      }
      if (contentItem.type === "text" && contentItem.text) {
        chunks.push(contentItem.text);
      }
    }
  }

  return chunks.join("\n").trim();
}

function extractConversationTokenFromSignedUrl(rawSignedUrl) {
  if (!rawSignedUrl || typeof rawSignedUrl !== "string") {
    return null;
  }
  try {
    const parsed = new URL(rawSignedUrl);
    const candidates = [
      "conversation_token",
      "conversationToken",
      "token"
    ];
    for (const key of candidates) {
      const value = parsed.searchParams.get(key);
      if (value && String(value).trim()) {
        return String(value).trim();
      }
    }
  } catch {
    return null;
  }
  return null;
}

function parseModelJsonPayload(rawText) {
  const text = String(rawText || "").trim();
  if (!text) {
    return null;
  }

  try {
    return JSON.parse(text);
  } catch {
    const fencedMatch = text.match(/```(?:json)?\s*([\s\S]*?)```/i);
    if (fencedMatch?.[1]) {
      try {
        return JSON.parse(fencedMatch[1].trim());
      } catch {
        // bir sonraki denemeye geç
      }
    }

    const start = text.indexOf("{");
    const end = text.lastIndexOf("}");
    if (start >= 0 && end > start) {
      const candidate = text.slice(start, end + 1);
      try {
        return JSON.parse(candidate);
      } catch {
        return null;
      }
    }

    return null;
  }
}

function extractStructuredModelPayload(response) {
  if (response?.output_parsed && typeof response.output_parsed === "object") {
    return response.output_parsed;
  }

  for (const outputItem of response?.output || []) {
    if (outputItem?.type !== "message") {
      continue;
    }

    for (const contentItem of outputItem.content || []) {
      if (contentItem?.parsed && typeof contentItem.parsed === "object") {
        return contentItem.parsed;
      }
      if (contentItem?.json && typeof contentItem.json === "object") {
        return contentItem.json;
      }
      if (contentItem?.output && typeof contentItem.output === "object") {
        return contentItem.output;
      }
    }
  }

  return null;
}

function sanitizeFeedbackText(input) {
  const raw = String(input || "");
  const replaced = raw
    .replace(/\b(katılımcı|katilimci|participant|student|öğrenci|ogrenci)\b/gi, "sen")
    .replace(/\b(transcript|transkript)\b/gi, "görüşme kaydı")
    .replace(/\bopenai\b/gi, "model");

  return replaced
    .replace(/\s+/g, " ")
    .replace(/\s+([,.;!?])/g, "$1")
    .trim();
}

function conciseText(input, maxSentences = 2, maxChars = 240) {
  const text = sanitizeFeedbackText(input);
  if (!text) {
    return "";
  }

  const parts = text.match(/[^.!?]+[.!?]?/g) || [text];
  const picked = parts
    .map((part) => part.trim())
    .filter(Boolean)
    .slice(0, Math.max(1, maxSentences))
    .join(" ");

  if (picked.length <= maxChars) {
    return picked;
  }
  return `${picked.slice(0, maxChars - 1).trim()}...`;
}

function ensureDirectAddress(input) {
  const text = sanitizeFeedbackText(input);
  if (!text) {
    return "";
  }
  if (/\bsen(in)?\b/i.test(text)) {
    return text;
  }
  return `Senin açından, ${text.charAt(0).toLowerCase()}${text.slice(1)}`;
}

function sanitizeList(input, fallbackText, maxItems = 4, maxChars = 120) {
  const list = Array.isArray(input) ? input : [];
  const cleaned = list
    .map((item) => conciseText(item, 1, maxChars))
    .filter(Boolean)
    .slice(0, maxItems);

  if (cleaned.length) {
    return cleaned;
  }
  return [fallbackText];
}

function normalizeForComparison(text) {
  return String(text || "")
    .toLocaleLowerCase("tr-TR")
    .replace(/[^a-z0-9çğıöşü\s]/gi, " ")
    .replace(/\s+/g, " ")
    .trim();
}

function dedupeItems(items, maxItems = 4) {
  const list = Array.isArray(items) ? items : [];
  const seen = new Set();
  const output = [];

  for (const item of list) {
    const normalized = normalizeForComparison(item);
    if (!normalized || seen.has(normalized)) {
      continue;
    }
    seen.add(normalized);
    output.push(item);
    if (output.length >= maxItems) {
      break;
    }
  }

  return output;
}

function isGenericImprovementLine(text) {
  const normalized = normalizeForComparison(text);
  if (!normalized) {
    return true;
  }

  const genericPatterns = [
    "daha kapsamli diferansiyel tani gelistirebilirsin",
    "daha kapsamli ayirici tani gelistirebilirsin",
    "iletisimini gelistirebilirsin",
    "zaman yonetimini gelistirebilirsin",
    "daha sistematik olabilirsin",
    "daha dikkatli olmalisin"
  ];

  return genericPatterns.some((pattern) => normalized.includes(pattern));
}

function buildDimensionDrivenImprovements(dimensions) {
  const list = Array.isArray(dimensions) ? dimensions : [];

  return list
    .map((item) => ({
      score: Number(item?.score),
      recommendation: conciseText(item?.recommendation, 1, 120),
      explanation: conciseText(item?.explanation, 1, 120)
    }))
    .filter((item) => Number.isFinite(item.score))
    .sort((a, b) => a.score - b.score)
    .slice(0, 4)
    .map((item) => item.recommendation || item.explanation)
    .filter(Boolean);
}

function normalizeDiagnosisText(text) {
  return String(text || "")
    .replace(/\s+/g, " ")
    .replace(/^[\s:,\-–—]+|[\s:,\-–—]+$/g, "")
    .trim();
}

function isDiagnosisPlaceholder(text) {
  const normalized = normalizeForComparison(text);
  if (!normalized) {
    return true;
  }

  return (
    normalized.includes("kesin tani paylasilmadi") ||
    normalized.includes("belirtilmedi") ||
    normalized.includes("n a") ||
    normalized.includes("bilgi yok")
  );
}

function extractDiagnosisCandidate(text) {
  const input = String(text || "");
  if (!input.trim()) {
    return "";
  }

  const patterns = [
    /(?:nihai|kesin|doğru|dogru|final)\s*(?:tanı|tani|teşhis|teshis)\s*(?:[:\-]|olarak|=)?\s*([^.;\n]+)/i,
    /(?:tanı|tani|teşhis|teshis)\s*(?:[:\-]|olarak|=)\s*([^.;\n]+)/i,
    /(?:diagnosis|final diagnosis)\s*(?:[:\-]|is)\s*([^.;\n]+)/i
  ];

  for (const pattern of patterns) {
    const match = input.match(pattern);
    if (!match || !match[1]) {
      continue;
    }
    const candidate = conciseText(normalizeDiagnosisText(match[1]), 1, 90);
    if (!candidate || isDiagnosisPlaceholder(candidate)) {
      continue;
    }
    if (candidate.length < 4) {
      continue;
    }
    return candidate;
  }

  return "";
}

function inferDiagnosisFromCaseTitle(title) {
  const cleaned = conciseText(normalizeDiagnosisText(title), 1, 90);
  if (!cleaned) {
    return "";
  }
  const normalized = normalizeForComparison(cleaned);
  const genericTokens = [
    "klinik vaka",
    "vaka oturumu",
    "vaka",
    "oturum",
    "gunun vakasi",
    "rastgele"
  ];
  if (genericTokens.some((token) => normalized.includes(token))) {
    return "";
  }
  return cleaned;
}

function inferTrueDiagnosisFallback(wrapup, conversation) {
  const fromWrapup = extractDiagnosisCandidate(wrapup);
  if (fromWrapup) {
    return fromWrapup;
  }

  const messages = Array.isArray(conversation) ? conversation : [];
  for (let i = messages.length - 1; i >= 0; i -= 1) {
    const item = messages[i];
    if (item?.speaker !== "HASTA_VEYA_KOC") {
      continue;
    }
    const line = String(item?.message || "").trim();
    if (!line) {
      continue;
    }
    const diagnosis = extractDiagnosisCandidate(line);
    if (diagnosis) {
      return diagnosis;
    }
  }

  return "";
}

function inferUserDiagnosisFallback(conversation) {
  const messages = Array.isArray(conversation) ? conversation : [];
  const patterns = [
    /(?:ön tanım|ön tani|tanım|tanim|tanı koyuyorum|tani koyuyorum|nihai tanım|nihai tanim|en olası tanı|en olasi tani)[^:.]*[:\-]?\s*(.+)$/i,
    /(?:bence|muhtemelen|olası|olasi)\s+(.+)$/i
  ];

  for (let i = messages.length - 1; i >= 0; i -= 1) {
    const item = messages[i];
    if (item?.speaker !== "KULLANICI") {
      continue;
    }
    const line = String(item?.message || "").trim();
    if (!line) {
      continue;
    }
    for (const pattern of patterns) {
      const match = line.match(pattern);
      if (match && match[1]) {
        const candidate = conciseText(normalizeDiagnosisText(match[1]), 1, 90);
        if (candidate && !isDiagnosisPlaceholder(candidate)) {
          return candidate;
        }
      }
    }
  }

  return "";
}

function postProcessScorePayload(payload, context = {}) {
  const dimensions = Array.isArray(payload?.dimensions) ? payload.dimensions : [];
  const nextPracticeSuggestions = Array.isArray(payload?.next_practice_suggestions)
    ? payload.next_practice_suggestions
    : [];
  const inferredTrueDiagnosis = inferTrueDiagnosisFallback(context?.wrapup, context?.conversation);
  const inferredUserDiagnosis = inferUserDiagnosisFallback(context?.conversation);

  const rawImprovements = sanitizeList(
    payload?.improvements,
    "Bu vakada gelişim alanını netleştirmek için biraz daha veri gerekiyor."
  );
  let improvements = dedupeItems(rawImprovements, 4);

  const genericCount = improvements.filter((item) => isGenericImprovementLine(item)).length;
  const allGeneric = improvements.length > 0 && genericCount === improvements.length;
  if (allGeneric || improvements.length < 2) {
    const dimensionBased = dedupeItems(buildDimensionDrivenImprovements(dimensions), 4);
    if (dimensionBased.length) {
      improvements = dimensionBased;
    }
  }

  const trueDiagnosisRaw = conciseText(payload?.true_diagnosis, 1, 90);
  const userDiagnosisRaw = conciseText(payload?.user_diagnosis, 1, 90);
  const trueDiagnosis =
    !isDiagnosisPlaceholder(trueDiagnosisRaw) && trueDiagnosisRaw
      ? trueDiagnosisRaw
      : inferredTrueDiagnosis ||
        inferDiagnosisFromCaseTitle(payload?.case_title) ||
        "Muhtemel tanı netleşmedi";
  const userDiagnosis =
    !isDiagnosisPlaceholder(userDiagnosisRaw) && userDiagnosisRaw
      ? userDiagnosisRaw
      : inferredUserDiagnosis || "Belirtilmedi";

  return {
    ...payload,
    case_title: conciseText(payload?.case_title, 1, 80) || "Klinik Vaka",
    true_diagnosis: trueDiagnosis,
    user_diagnosis: userDiagnosis,
    brief_summary: ensureDirectAddress(conciseText(payload?.brief_summary, 2, 260)),
    strengths: dedupeItems(
      sanitizeList(payload?.strengths, "Bu vaka adımında belirgin bir güçlü yön görünmüyor."),
      4
    ),
    improvements: improvements.length
      ? improvements
      : ["Bu vakada gelişim alanını netleştirmek için biraz daha veri gerekiyor."],
    missed_opportunities: sanitizeList(
      payload?.missed_opportunities,
      "Bu vakada kaçan fırsatları analiz etmek için biraz daha veri gerekiyor."
    ),
    dimensions: dimensions.map((item) => ({
      ...item,
      explanation: ensureDirectAddress(conciseText(item?.explanation, 1, 170)),
      recommendation: ensureDirectAddress(conciseText(item?.recommendation, 1, 170))
    })),
    next_practice_suggestions: nextPracticeSuggestions.slice(0, 3).map((item) => ({
      focus: ensureDirectAddress(conciseText(item?.focus, 1, 110)),
      "micro-drill": ensureDirectAddress(conciseText(item?.["micro-drill"], 1, 120)),
      example_prompt: ensureDirectAddress(conciseText(item?.example_prompt, 1, 140))
    }))
  };
}

function computeScoreSignal(conversation) {
  const rows = Array.isArray(conversation) ? conversation : [];
  const userRows = rows.filter((item) => item?.speaker === "KULLANICI");
  const userText = userRows.map((item) => String(item?.message || "")).join(" ").trim();
  const userWordCount = userText ? userText.split(/\s+/).filter(Boolean).length : 0;
  const userCharCount = userText.length;
  const userQuestionCount = (userText.match(/[?]/g) || []).length;
  const hasClinicalKeyword = /\b(ağrı|ates|ateş|nabiz|nabız|kan|tahlil|tetkik|ekg|ekokardiyografi|muayene|tan[ıi]|teshis|teşhis|ayirici|ayırıcı|tedavi|ilaç|ilac|öner|oner)\b/i.test(userText);
  const hasDiagnosisGuess = /\b(tan[ıi]|teşhis|teshis|diagnosis|bence|muhtemelen|olasi|olası)\b/i.test(userText);
  const turns = rows.length;
  return {
    turns,
    userMessageCount: userRows.length,
    userWordCount,
    userCharCount,
    userQuestionCount,
    hasClinicalKeyword,
    hasDiagnosisGuess
  };
}

function classifyScoreLabel(overallScore) {
  const value = Number(overallScore);
  if (!Number.isFinite(value)) {
    return "Needs Improvement";
  }
  if (value >= 80) return "Excellent";
  if (value >= 60) return "Good";
  if (value >= 35) return "Needs Improvement";
  return "Poor";
}

function buildLowSignalDimensions() {
  return WEAK_AREA_DIMENSION_META.map((item, index) => {
    const base = 0.8 + (index % 3) * 0.3;
    return {
      key: item.key,
      score: Number(base.toFixed(1)),
      explanation: "Senin yanıtın bu alanı değerlendirmek için yeterli değil.",
      recommendation: "Senaryoda hedefli soru, ayırıcı tanı ve plan adımlarını açıkça yazmalısın."
    };
  });
}

function buildLowSignalScorePayload({ conversation, wrapup }) {
  const signal = computeScoreSignal(conversation);
  const inferredTrueDiagnosis = inferTrueDiagnosisFallback(wrapup, conversation) || "Muhtemel tanı netleşmedi";
  const inferredUserDiagnosis = inferUserDiagnosisFallback(conversation) || "Belirtilmedi";

  const rawScore =
    6 +
    Math.min(3, signal.userMessageCount) * 4 +
    Math.min(40, signal.userWordCount) * 0.35 +
    (signal.hasClinicalKeyword ? 2 : 0) +
    (signal.hasDiagnosisGuess ? 2 : 0);
  const cappedScore = Math.max(0, Math.min(30, Number(rawScore.toFixed(1))));

  return {
    case_title: "Kısa Oturum",
    true_diagnosis: inferredTrueDiagnosis,
    user_diagnosis: inferredUserDiagnosis,
    overall_score: cappedScore,
    label: classifyScoreLabel(cappedScore),
    brief_summary:
      "Senaryoda çok kısa etkileşim olduğu için güvenilir klinik performans skoru üretilemedi. Daha net anamnez, tetkik ve plan adımlarıyla tekrar denemelisin.",
    strengths: [
      "Oturumu başlatıp ilk yanıtını verdin."
    ],
    improvements: [
      "Önce hedefli anamnez soruları ile klinik tabloyu netleştirmelisin.",
      "Ayırıcı tanıyı en az 2-3 olasılıkla kısa gerekçelerle belirtmelisin.",
      "Tetkik ve tedavi planını öncelik sırasıyla açıkça yazmalısın."
    ],
    missed_opportunities: [
      "Kritik kırmızı bayrakları sorgulamadın.",
      "Klinik karar zincirini adım adım göstermedin."
    ],
    dimensions: buildLowSignalDimensions(),
    next_practice_suggestions: [
      {
        focus: "Yapılandırılmış anamnez akışı",
        "micro-drill": "Her vakada önce 5 hedefli soru yaz: başlangıç, süre, şiddet, eşlik eden bulgu, risk faktörü.",
        example_prompt: "Bu hasta için önce anamnezde soracağın 5 kritik soruyu sırala."
      }
    ],
    scoring_note: "low_signal_short_circuit",
    scoring_signal: signal
  };
}

function getScoreCacheKey({ mode, transcript, wrapup, version }) {
  return crypto.createHash("sha1").update(`${version}|${mode}|${wrapup}|${transcript}`).digest("hex");
}

async function getCachedScore(cacheKey) {
  if (isUpstashEnabled()) {
    try {
      const payload = await redisGetJson(buildRedisKey(`score-cache:${cacheKey}`));
      if (payload && typeof payload === "object") {
        return payload;
      }
    } catch (error) {
      // eslint-disable-next-line no-console
      console.warn(`[score-cache] upstash fallback -> memory: ${error?.message || "unknown"}`);
    }
  }

  const entry = scoreCache.get(cacheKey);
  if (!entry) {
    return null;
  }
  if (Date.now() - entry.savedAt > SCORE_CACHE_TTL_MS) {
    scoreCache.delete(cacheKey);
    return null;
  }
  return entry.payload;
}

async function setCachedScore(cacheKey, payload) {
  if (isUpstashEnabled()) {
    try {
      await redisSetJsonPx(buildRedisKey(`score-cache:${cacheKey}`), payload, SCORE_CACHE_TTL_MS);
    } catch (error) {
      // eslint-disable-next-line no-console
      console.warn(`[score-cache] set upstash failed, memory fallback only: ${error?.message || "unknown"}`);
    }
  }

  scoreCache.set(cacheKey, {
    savedAt: Date.now(),
    payload
  });
}

function weakAreaRound(value) {
  const num = Number(value);
  if (!Number.isFinite(num)) {
    return 0;
  }
  return Math.round(num * 10) / 10;
}

function weakAreaToPercent(rawValue) {
  const num = Number(rawValue);
  if (!Number.isFinite(num)) {
    return null;
  }
  const normalized = num <= 10 ? num * 10 : num;
  return weakAreaRound(Math.max(0, Math.min(100, normalized)));
}

function weakAreaNormalizeSpecialty(rawValue) {
  const value = sanitizeChallengeLine(rawValue, 80);
  if (!value) {
    return "General Medicine";
  }
  return value;
}

function weakAreaSpecialtyLabel(value) {
  const clean = weakAreaNormalizeSpecialty(value);
  return WEAK_AREA_SPECIALTY_LABEL_MAP[clean] || clean;
}

function weakAreaNormalizeDifficulty(rawValue) {
  const clean = sanitizeChallengeLine(rawValue, 24);
  if (!clean) {
    return "Orta";
  }
  const normalized = clean.toLocaleLowerCase("tr-TR");
  if (normalized === "random") {
    return "Orta";
  }
  return clean;
}

function weakAreaDimensionLabel(key) {
  const meta = WEAK_AREA_DIMENSION_META.find((item) => item.key === key);
  return meta?.label || key;
}

function weakAreaDimensionShortLabel(key) {
  const meta = WEAK_AREA_DIMENSION_META.find((item) => item.key === key);
  return meta?.shortLabel || key;
}

function weakAreaNormalizeSessionRow(row) {
  const score = row?.score && typeof row.score === "object" ? row.score : null;
  const overallScore = weakAreaToPercent(score?.overall_score ?? score?.overallScore);
  const caseContext = row?.case_context && typeof row.case_context === "object"
    ? row.case_context
    : row?.caseContext && typeof row.caseContext === "object"
      ? row.caseContext
      : null;
  const specialty = weakAreaNormalizeSpecialty(caseContext?.specialty || caseContext?.specialty_name || row?.specialty);
  const difficulty = weakAreaNormalizeDifficulty(row?.difficulty || caseContext?.difficulty || "Orta");
  const updatedAtMs = Number(new Date(row?.updated_at || row?.ended_at || row?.started_at || Date.now()).getTime());

  const dimensions = {};
  const rawDimensions = Array.isArray(score?.dimensions) ? score.dimensions : [];
  for (const rawDimension of rawDimensions) {
    const key = String(rawDimension?.key || "").trim();
    if (!WEAK_AREA_DIMENSION_KEY_SET.has(key)) {
      continue;
    }
    const normalizedScore = weakAreaToPercent(rawDimension?.score);
    if (normalizedScore == null) {
      continue;
    }
    dimensions[key] = normalizedScore;
  }

  const hasDimension = Object.keys(dimensions).length > 0;
  if (overallScore == null && !hasDimension) {
    return null;
  }

  return {
    overallScore,
    specialty,
    difficulty,
    updatedAtMs: Number.isFinite(updatedAtMs) ? updatedAtMs : Date.now(),
    dimensions
  };
}

function weakAreaCreateAggregate() {
  return {
    caseCount: 0,
    overallSum: 0,
    difficultyCounts: {},
    dimensionTotals: WEAK_AREA_DIMENSION_META.reduce((acc, item) => {
      acc[item.key] = { sum: 0, count: 0 };
      return acc;
    }, {})
  };
}

function weakAreaApplySession(aggregate, session) {
  if (!aggregate || !session) {
    return;
  }

  if (Number.isFinite(session.overallScore)) {
    aggregate.caseCount += 1;
    aggregate.overallSum += session.overallScore;
  }

  if (session.difficulty) {
    aggregate.difficultyCounts[session.difficulty] = (aggregate.difficultyCounts[session.difficulty] || 0) + 1;
  }

  for (const key of WEAK_AREA_DIMENSION_META.map((item) => item.key)) {
    const score = session.dimensions[key];
    if (!Number.isFinite(score)) {
      continue;
    }
    aggregate.dimensionTotals[key].sum += score;
    aggregate.dimensionTotals[key].count += 1;
  }
}

function weakAreaAverage(sum, count, fallback = 0) {
  if (!Number.isFinite(sum) || !Number.isFinite(count) || count <= 0) {
    return weakAreaRound(fallback);
  }
  return weakAreaRound(sum / count);
}

function weakAreaMostUsedDifficulty(counts) {
  const entries = Object.entries(counts || {});
  if (!entries.length) {
    return "Orta";
  }
  entries.sort((left, right) => {
    if (left[1] === right[1]) {
      return String(left[0]).localeCompare(String(right[0]), "tr");
    }
    return Number(right[1]) - Number(left[1]);
  });
  return weakAreaNormalizeDifficulty(entries[0][0]);
}

function weakAreaAggregateBySpecialty(sessions) {
  const map = new Map();
  for (const session of sessions) {
    const specialty = weakAreaNormalizeSpecialty(session?.specialty);
    const current = map.get(specialty) || weakAreaCreateAggregate();
    weakAreaApplySession(current, session);
    map.set(specialty, current);
  }
  return map;
}

function weakAreaBuildDimensionsResponse(userAggregate, globalAggregate, fallbackScore) {
  return WEAK_AREA_DIMENSION_META.map((dimension) => {
    const userMetric = userAggregate?.dimensionTotals?.[dimension.key] || { sum: 0, count: 0 };
    const globalMetric = globalAggregate?.dimensionTotals?.[dimension.key] || { sum: 0, count: 0 };
    const userAvg = weakAreaAverage(userMetric.sum, userMetric.count, fallbackScore);
    const globalAvg = weakAreaAverage(globalMetric.sum, globalMetric.count, userAvg);
    return {
      key: dimension.key,
      label: dimension.label,
      user_average_score: userAvg,
      global_average_score: globalAvg,
      user_case_count: userMetric.count || userAggregate?.caseCount || 0,
      global_case_count: globalMetric.count || globalAggregate?.caseCount || 0
    };
  });
}

function weakAreaBuildFallbackRecommendation({
  specialtyBreakdown,
  defaultWeeklyTarget = 5
}) {
  const weakest = Array.isArray(specialtyBreakdown) ? specialtyBreakdown[0] : null;
  if (!weakest) {
    return {
      title: "Dr.Kynox Öneriyor",
      message: "Düzenli vaka çözerek skor haritanı genişlet. 3-5 vaka sonra kişisel odak önerisi netleşir.",
      recommended_specialty: "Random",
      recommended_specialty_label: "Rastgele",
      recommended_difficulty: "Orta",
      focus_dimension_key: "data_gathering_quality",
      focus_dimension_label: weakAreaDimensionLabel("data_gathering_quality"),
      focus_dimension_score: 0,
      suggested_weekly_target: defaultWeeklyTarget,
      cta_label: "Yeni Vaka Başlat"
    };
  }

  const focusLabel = weakest.weakest_dimension_label || "kritik alan";
  const focusScore = Number(weakest.weakest_dimension_score || weakest.user_average_score || 0);
  const weeklyTarget = Math.max(2, Math.min(12, Number(defaultWeeklyTarget) || 5));

  return {
    title: "Dr.Kynox Öneriyor",
    message:
      `Son 10 vakanda ${weakest.specialty_label} alanında ${focusLabel} skorun düşük (${weakAreaRound(focusScore)}/100). ` +
      `Bu hafta ${weakest.specialty_label} odaklı en az 2 vaka çöz ve özellikle klinik önceliklendirmeye dikkat et.`,
    recommended_specialty: weakest.specialty,
    recommended_specialty_label: weakest.specialty_label,
    recommended_difficulty: weakest.recommended_difficulty || "Orta",
    focus_dimension_key: weakest.weakest_dimension_key || null,
    focus_dimension_label: focusLabel,
    focus_dimension_score: weakAreaRound(focusScore),
    suggested_weekly_target: weeklyTarget,
    cta_label: `${weakest.specialty_label} Vakası Başlat`
  };
}

function weakAreaBuildCacheKey({
  userId,
  userSessions,
  globalSessions
}) {
  const latestUserTs = userSessions[0]?.updatedAtMs || 0;
  const latestGlobalTs = globalSessions[0]?.updatedAtMs || 0;
  const base = `${WEAK_AREA_PROMPT_VERSION}|${userId}|${userSessions.length}|${globalSessions.length}|${latestUserTs}|${latestGlobalTs}`;
  return crypto.createHash("sha1").update(base).digest("hex");
}

async function getCachedWeakArea(cacheKey) {
  if (isUpstashEnabled()) {
    try {
      const payload = await redisGetJson(buildRedisKey(`weak-area-cache:${cacheKey}`));
      if (payload && typeof payload === "object") {
        return payload;
      }
    } catch (error) {
      // eslint-disable-next-line no-console
      console.warn(`[weak-area-cache] upstash fallback -> memory: ${error?.message || "unknown"}`);
    }
  }

  const entry = weakAreaCache.get(cacheKey);
  if (!entry) {
    return null;
  }
  if (Date.now() - entry.savedAt > WEAK_AREA_CACHE_TTL_MS) {
    weakAreaCache.delete(cacheKey);
    return null;
  }
  return entry.payload;
}

async function getCachedWeakAreaByUser(userId) {
  const safeUserId = sanitizeUuid(userId);
  if (!safeUserId) {
    return null;
  }
  if (isUpstashEnabled()) {
    try {
      const payload = await redisGetJson(buildRedisKey(`weak-area-user-cache:${safeUserId}`));
      if (payload && typeof payload === "object") {
        return payload;
      }
    } catch (error) {
      // eslint-disable-next-line no-console
      console.warn(`[weak-area-user-cache] upstash fallback -> memory: ${error?.message || "unknown"}`);
    }
  }

  const entry = weakAreaUserSnapshotCache.get(safeUserId);
  if (!entry) {
    return null;
  }
  if (Date.now() - Number(entry.savedAt || 0) > WEAK_AREA_USER_CACHE_TTL_MS) {
    weakAreaUserSnapshotCache.delete(safeUserId);
    return null;
  }
  return entry.payload;
}

async function setCachedWeakAreaByUser(userId, payload) {
  const safeUserId = sanitizeUuid(userId);
  if (!safeUserId || !payload || typeof payload !== "object") {
    return;
  }
  if (isUpstashEnabled()) {
    try {
      await redisSetJsonPx(
        buildRedisKey(`weak-area-user-cache:${safeUserId}`),
        payload,
        WEAK_AREA_USER_CACHE_TTL_MS
      );
    } catch (error) {
      // eslint-disable-next-line no-console
      console.warn(`[weak-area-user-cache] set upstash failed, memory fallback only: ${error?.message || "unknown"}`);
    }
  }

  weakAreaUserSnapshotCache.set(safeUserId, {
    savedAt: Date.now(),
    payload
  });
  if (weakAreaUserSnapshotCache.size > 6000) {
    const now = Date.now();
    for (const [key, entry] of weakAreaUserSnapshotCache.entries()) {
      if (!entry || now - Number(entry.savedAt || 0) > WEAK_AREA_USER_CACHE_TTL_MS) {
        weakAreaUserSnapshotCache.delete(key);
      }
    }
  }
}

async function setCachedWeakArea(cacheKey, payload) {
  if (isUpstashEnabled()) {
    try {
      await redisSetJsonPx(buildRedisKey(`weak-area-cache:${cacheKey}`), payload, WEAK_AREA_CACHE_TTL_MS);
    } catch (error) {
      // eslint-disable-next-line no-console
      console.warn(`[weak-area-cache] set upstash failed, memory fallback only: ${error?.message || "unknown"}`);
    }
  }

  weakAreaCache.set(cacheKey, {
    savedAt: Date.now(),
    payload
  });
}

async function fetchWeakAreaCaseRows({
  supabaseUrl,
  supabaseServiceRoleKey,
  userId,
  limit = 200,
  days = 45
}) {
  const safeLimit = clampRateLimitValue(limit, 200, 20, 3000);
  const safeDays = clampRateLimitValue(days, 45, 7, 180);
  const since = new Date(Date.now() - safeDays * 24 * 60 * 60 * 1000).toISOString();

  const userQs = new URLSearchParams({
    user_id: `eq.${userId}`,
    score: "not.is.null",
    select: "id,updated_at,ended_at,started_at,difficulty,case_context,score,status",
    order: "updated_at.desc",
    limit: String(Math.min(400, safeLimit))
  });

  const globalQs = new URLSearchParams({
    user_id: `neq.${userId}`,
    score: "not.is.null",
    updated_at: `gte.${since}`,
    select: "id,updated_at,ended_at,started_at,difficulty,case_context,score,status",
    order: "updated_at.desc",
    limit: String(safeLimit)
  });

  const headers = {
    apikey: supabaseServiceRoleKey,
    Authorization: `Bearer ${supabaseServiceRoleKey}`
  };

  const [userResp, globalResp] = await Promise.all([
    fetch(`${supabaseUrl}/rest/v1/case_sessions?${userQs.toString()}`, {
      method: "GET",
      headers
    }),
    fetch(`${supabaseUrl}/rest/v1/case_sessions?${globalQs.toString()}`, {
      method: "GET",
      headers
    })
  ]);

  if (!userResp.ok) {
    const txt = await userResp.text();
    const err = new Error(`Kullanıcı vaka analizi okunamadı: ${txt || userResp.status}`);
    err.status = 500;
    throw err;
  }
  if (!globalResp.ok) {
    const txt = await globalResp.text();
    const err = new Error(`Global vaka analizi okunamadı: ${txt || globalResp.status}`);
    err.status = 500;
    throw err;
  }

  const userRows = await userResp.json().catch(() => []);
  const globalRows = await globalResp.json().catch(() => []);

  return {
    userRows: Array.isArray(userRows) ? userRows : [],
    globalRows: Array.isArray(globalRows) ? globalRows : []
  };
}

async function buildWeakAreaAnalysisPayload({
  userRows,
  globalRows,
  weeklyTarget
}) {
  const normalizedUserSessions = (Array.isArray(userRows) ? userRows : [])
    .map(weakAreaNormalizeSessionRow)
    .filter(Boolean)
    .sort((a, b) => Number(b.updatedAtMs || 0) - Number(a.updatedAtMs || 0));

  const normalizedGlobalSessions = (Array.isArray(globalRows) ? globalRows : [])
    .map(weakAreaNormalizeSessionRow)
    .filter(Boolean)
    .sort((a, b) => Number(b.updatedAtMs || 0) - Number(a.updatedAtMs || 0));

  const userAggregate = weakAreaCreateAggregate();
  normalizedUserSessions.forEach((session) => weakAreaApplySession(userAggregate, session));

  const globalAggregate = weakAreaCreateAggregate();
  normalizedGlobalSessions.forEach((session) => weakAreaApplySession(globalAggregate, session));

  const userAverageScore = weakAreaAverage(userAggregate.overallSum, userAggregate.caseCount, 0);
  const globalAverageScore = weakAreaAverage(globalAggregate.overallSum, globalAggregate.caseCount, userAverageScore);

  const scoreMapAxes = WEAK_AREA_DIMENSION_META.map((item) => ({
    key: item.key,
    label: item.label,
    short_label: item.shortLabel
  }));
  const scoreMapUserValues = WEAK_AREA_DIMENSION_META.map((item) => {
    const metric = userAggregate.dimensionTotals[item.key];
    return weakAreaAverage(metric.sum, metric.count, userAverageScore);
  });
  const scoreMapGlobalValues = WEAK_AREA_DIMENSION_META.map((item) => {
    const metric = globalAggregate.dimensionTotals[item.key];
    return weakAreaAverage(metric.sum, metric.count, globalAverageScore);
  });

  const userSpecialtyMap = weakAreaAggregateBySpecialty(normalizedUserSessions);
  const globalSpecialtyMap = weakAreaAggregateBySpecialty(normalizedGlobalSessions);

  const specialtyBreakdown = Array.from(userSpecialtyMap.entries())
    .map(([specialty, aggregate]) => {
      const global = globalSpecialtyMap.get(specialty) || weakAreaCreateAggregate();
      const userAverage = weakAreaAverage(aggregate.overallSum, aggregate.caseCount, userAverageScore);
      const globalAverage = weakAreaAverage(global.overallSum, global.caseCount, globalAverageScore);
      const dimensions = weakAreaBuildDimensionsResponse(aggregate, global, userAverage);
      const weakest = dimensions
        .slice()
        .sort((left, right) => Number(left.user_average_score || 0) - Number(right.user_average_score || 0))[0];

      return {
        specialty,
        specialty_label: weakAreaSpecialtyLabel(specialty),
        user_average_score: userAverage,
        global_average_score: globalAverage,
        user_case_count: aggregate.caseCount,
        global_case_count: global.caseCount,
        recommended_difficulty: weakAreaMostUsedDifficulty(aggregate.difficultyCounts),
        weakest_dimension_key: weakest?.key || null,
        weakest_dimension_label: weakest?.label || null,
        weakest_dimension_score: weakAreaRound(weakest?.user_average_score || userAverage),
        dimensions
      };
    })
    .sort((left, right) => {
      if (left.user_average_score === right.user_average_score) {
        return Number(right.user_case_count || 0) - Number(left.user_case_count || 0);
      }
      return Number(left.user_average_score || 0) - Number(right.user_average_score || 0);
    });

  const fallbackRecommendation = weakAreaBuildFallbackRecommendation({
    specialtyBreakdown,
    defaultWeeklyTarget: Math.max(2, Math.min(14, Number(weeklyTarget) || 5))
  });

  return {
    generated_at: new Date().toISOString(),
    summary: {
      user_case_count: userAggregate.caseCount,
      user_average_score: userAverageScore,
      global_average_score: globalAverageScore
    },
    score_map: {
      axes: scoreMapAxes,
      user_values: scoreMapUserValues,
      global_values: scoreMapGlobalValues
    },
    specialty_breakdown: specialtyBreakdown,
    ai_recommendation: fallbackRecommendation
  };
}

function extractScoreRequestPayload(req) {
  const bodyPayload = req.body && typeof req.body === "object" ? req.body : null;
  return bodyPayload || {};
}

async function handleScoreRequest(req, res) {
  if (req.method !== "POST") {
    return res.status(405).json({
      error: "Bu endpoint yalnızca POST kabul eder.",
      method_required: "POST",
      endpoint: "/api/score"
    });
  }

  const scoreIdentity = getClientIp(req);
  if (
    (await enforceBruteForceGuard(req, res, {
      scope: "score-auth",
      identity: scoreIdentity,
      errorMessage: "Çok fazla hatalı skor denemesi tespit edildi. Lütfen daha sonra tekrar dene."
    })) !== true
  ) {
    return;
  }

  const scoreIpLimitOk = await enforceRateLimit(req, res, {
    scope: "score-ip",
    identity: scoreIdentity,
    maxRequests: clampRateLimitValue(process.env.RATE_LIMIT_SCORE_IP_PER_MIN, 35, 5, 220),
    windowMs: 60_000,
    errorMessage: "Skor istek sınırına ulaşıldı. Lütfen kısa bir süre bekleyip tekrar dene."
  });
  if (!scoreIpLimitOk) {
    return;
  }

  const { supabaseUrl, supabaseAnonKey, supabaseServiceRoleKey } = getSupabaseConfig();
  const missingConfig = [];
  if (!supabaseUrl) missingConfig.push("SUPABASE_URL");
  if (!supabaseServiceRoleKey) missingConfig.push("SUPABASE_SERVICE_ROLE_KEY");
  if (missingConfig.length > 0) {
    return res.status(503).json({
      error: `Skorlama için sunucu ayarları eksik: ${missingConfig.join(", ")}`
    });
  }

  const accessToken = extractBearerToken(req);
  if (!accessToken) {
    await registerAuthFailure({
      scope: "score-auth",
      identity: scoreIdentity
    });
    return res.status(401).json({
      error: "Skorlama için yetkili oturum gerekli."
    });
  }
  maybeSimulateServiceError(req, "supabase", {
    code: ERROR_CODES.SUPABASE_UNAVAILABLE,
    status: 503
  });

  const userApiKey = supabaseAnonKey || supabaseServiceRoleKey;
  let userPayload = null;
  try {
    userPayload = await fetchSupabaseUserByToken({
      supabaseUrl,
      userApiKey,
      accessToken
    });
    await clearAuthFailures({
      scope: "score-auth",
      identity: scoreIdentity
    });

    await assertAiAccessAllowed({
      supabaseUrl,
      supabaseServiceRoleKey,
      userId: userPayload?.id
    });
  } catch (error) {
    if (isAuthFailureStatus(error?.status)) {
      await registerAuthFailure({
        scope: "score-auth",
        identity: scoreIdentity
      });
    }
    return res.status(error?.status || 401).json({
      error: error?.message || "Skorlama için kullanıcı doğrulanamadı."
    });
  }

  const scoreUserLimitOk = await enforceRateLimit(req, res, {
    scope: "score-user",
    identity: userPayload?.id || accessToken,
    maxRequests: clampRateLimitValue(process.env.RATE_LIMIT_SCORE_USER_PER_MIN, 10, 2, 80),
    windowMs: 60_000,
    errorMessage: "Bu dakika için skor oluşturma sınırına ulaştın. Lütfen kısa süre sonra tekrar dene."
  });
  if (!scoreUserLimitOk) {
    return;
  }

  const requestPayload = extractScoreRequestPayload(req);
  const parsedBody = parseJsonWithZod(res, scoreRequestBodySchema, requestPayload, {
    message: "Skorlama isteği geçersiz."
  });
  if (!parsedBody) {
    return;
  }
  const { conversation, rubricPrompt, mode, optionalCaseWrapup } = parsedBody;

  const safeRubricPrompt =
    typeof rubricPrompt === "string" && rubricPrompt.trim()
      ? rubricPrompt.trim()
      : defaultRubricPrompt;
  const safeMode = mode === "text" ? "text" : "voice";
  const safeWrapup =
    typeof optionalCaseWrapup === "string" && optionalCaseWrapup.trim()
      ? optionalCaseWrapup.trim()
      : "N/A";

  if (!process.env.OPENAI_API_KEY) {
    return res.status(500).json({
      error: "API anahtarı sunucuda ayarlı değil."
    });
  }
  maybeSimulateServiceError(req, "openai", {
    code: ERROR_CODES.OPENAI_UNAVAILABLE,
    status: 503
  });

  const scoreTranscriptMaxMessages = clampRateLimitValue(
    process.env.SCORE_TRANSCRIPT_MAX_MESSAGES,
    18,
    6,
    120
  );
  const scoreTranscriptMaxUserMessages = clampRateLimitValue(
    process.env.SCORE_TRANSCRIPT_MAX_USER_MESSAGES,
    12,
    2,
    80
  );
  const scoreTranscriptMaxCharsPerMessage = clampRateLimitValue(
    process.env.SCORE_TRANSCRIPT_MAX_CHARS_PER_MESSAGE,
    180,
    40,
    800
  );
  const scoreTranscriptMaxTotalChars = clampRateLimitValue(
    process.env.SCORE_TRANSCRIPT_MAX_TOTAL_CHARS,
    2600,
    500,
    50000
  );

  const compactConversation = conversation
    .filter(
      (item) =>
        item &&
        typeof item.message === "string" &&
        item.message.trim() &&
        typeof item.source === "string"
    )
    .map((item) => {
      const compactMessage = item.message
        .replace(/\s+/g, " ")
        .trim()
        .slice(0, scoreTranscriptMaxCharsPerMessage);
      const speaker = item.source === "user" ? "KULLANICI" : "HASTA_VEYA_KOC";
      return { speaker, message: compactMessage };
    });

  const boundedReversed = [];
  let boundedChars = 0;
  let boundedUserCount = 0;
  for (let idx = compactConversation.length - 1; idx >= 0; idx -= 1) {
    const item = compactConversation[idx];
    if (!item || !item.message) {
      continue;
    }
    const nextChars = boundedChars + item.message.length;
    if (nextChars > scoreTranscriptMaxTotalChars) {
      continue;
    }
    if (item.speaker === "KULLANICI" && boundedUserCount >= scoreTranscriptMaxUserMessages) {
      continue;
    }
    boundedReversed.push(item);
    boundedChars = nextChars;
    if (item.speaker === "KULLANICI") {
      boundedUserCount += 1;
    }
    if (boundedReversed.length >= scoreTranscriptMaxMessages) {
      break;
    }
  }
  const shortenedConversation = boundedReversed.reverse();

  const transcript = shortenedConversation
    .map((item) => `${item.speaker}: ${item.message}`)
    .join("\n");

  const userOnlyTranscript = shortenedConversation
    .filter((item) => item.speaker === "KULLANICI")
    .map((item) => `KULLANICI: ${item.message}`)
    .join("\n");

  if (!transcript) {
    return res.status(400).json({
      error: "Konuşma kaydında kullanılabilir mesaj bulunamadı."
    });
  }

  const scoreMinUserMessagesForLlm = clampRateLimitValue(
    process.env.SCORE_MIN_USER_MESSAGES_FOR_LLM,
    2,
    1,
    20
  );
  const scoreMinUserWordsForLlm = clampRateLimitValue(
    process.env.SCORE_MIN_USER_WORDS_FOR_LLM,
    14,
    4,
    120
  );
  const scoreMinTurnsForLlm = clampRateLimitValue(
    process.env.SCORE_MIN_TURNS_FOR_LLM,
    4,
    2,
    80
  );
  const scoreSignal = computeScoreSignal(shortenedConversation);
  const insufficientSignal =
    scoreSignal.userMessageCount < scoreMinUserMessagesForLlm ||
    scoreSignal.userWordCount < scoreMinUserWordsForLlm ||
    scoreSignal.turns < scoreMinTurnsForLlm ||
    (!scoreSignal.hasClinicalKeyword && scoreSignal.userWordCount < scoreMinUserWordsForLlm + 8);

  const cacheKey = getScoreCacheKey({
    mode: safeMode,
    transcript,
    wrapup: safeWrapup,
    version: SCORE_PROMPT_VERSION
  });
  const cached = await getCachedScore(cacheKey);
  if (cached) {
    return res.json(cached);
  }

  if (insufficientSignal) {
    const lowSignalPayload = postProcessScorePayload(
      buildLowSignalScorePayload({
        conversation: shortenedConversation,
        wrapup: safeWrapup
      }),
      {
        wrapup: safeWrapup,
        conversation: shortenedConversation
      }
    );
    await setCachedScore(cacheKey, lowSignalPayload);
    return res.json(lowSignalPayload);
  }

  const instructions = SCORE_SYSTEM_INSTRUCTIONS;

  const input =
    `${safeRubricPrompt}\n\n` +
    `FULL_CONVERSATION:\n${transcript}\n\n` +
    `USER_ONLY_MESSAGES:\n${userOnlyTranscript || "N/A"}\n\n` +
    `MODE:\n${safeMode}\n\n` +
    `OPTIONAL_CASE_WRAPUP:\n${safeWrapup}`;

  try {
    const scoreSchema = {
      type: "object",
      additionalProperties: false,
      properties: {
        case_title: { type: "string", maxLength: 80 },
        true_diagnosis: { type: "string", maxLength: 90 },
        user_diagnosis: { type: "string", maxLength: 90 },
        overall_score: { type: "number", minimum: 0, maximum: 100 },
        label: {
          type: "string",
          enum: ["Excellent", "Good", "Needs Improvement", "Poor"]
        },
        strengths: {
          type: "array",
          items: { type: "string", maxLength: 120 },
          minItems: 1,
          maxItems: 4
        },
        improvements: {
          type: "array",
          items: { type: "string", maxLength: 120 },
          minItems: 1,
          maxItems: 4
        },
        dimensions: {
          type: "array",
          minItems: 10,
          maxItems: 10,
          items: {
            type: "object",
            additionalProperties: false,
            properties: {
              key: {
                type: "string",
                enum: [
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
                ]
              },
              score: { type: "number", minimum: 0, maximum: 10 },
              explanation: { type: "string", maxLength: 180 },
              recommendation: { type: "string", maxLength: 180 }
            },
            required: ["key", "score", "explanation", "recommendation"]
          }
        },
        brief_summary: { type: "string", maxLength: 260 },
        missed_opportunities: {
          type: "array",
          items: { type: "string", maxLength: 120 },
          minItems: 1,
          maxItems: 4
        },
        next_practice_suggestions: {
          type: "array",
          minItems: 1,
          maxItems: 2,
          items: {
            type: "object",
            additionalProperties: false,
            properties: {
              focus: { type: "string", maxLength: 110 },
              "micro-drill": { type: "string", maxLength: 120 },
              example_prompt: { type: "string", maxLength: 140 }
            },
            required: ["focus", "micro-drill", "example_prompt"]
          }
        }
      },
      required: [
        "case_title",
        "true_diagnosis",
        "user_diagnosis",
        "overall_score",
        "label",
        "strengths",
        "improvements",
        "dimensions",
        "brief_summary",
        "missed_opportunities",
        "next_practice_suggestions"
      ]
    };

    const runScoreRequest = async ({ modelName, timeoutMs, maxOutputTokens }) =>
      openai.responses.create(
        {
          model: modelName,
          instructions,
          input,
          max_output_tokens: maxOutputTokens,
          text: {
            format: {
              type: "json_schema",
              name: "medical_reasoning_score_result",
              strict: true,
              schema: scoreSchema
            }
          }
        },
        {
          timeout: timeoutMs
        }
      );

    const parseScorePayloadFromResponse = (response) => {
      const structured = extractStructuredModelPayload(response);
      if (structured && typeof structured === "object") {
        return structured;
      }
      const rawText = extractOutputText(response);
      if (!rawText) {
        return null;
      }
      return parseModelJsonPayload(rawText);
    };

    const attempts = [
      {
        modelName: scoreModel || model,
        timeoutMs: scoreRequestTimeoutMs,
        maxOutputTokens: scoreMaxOutputTokens
      },
      {
        modelName: scoreRetryModel || scoreModel || model,
        timeoutMs: Math.max(14000, scoreRequestTimeoutMs + 8000),
        maxOutputTokens: Math.max(1700, scoreMaxOutputTokens + 300)
      }
    ];

    let parsed = null;
    const attemptErrors = [];
    let lastRawOutput = "";

    for (const attempt of attempts) {
      try {
        const response = await runScoreRequest(attempt);
        const rawText = extractOutputText(response) || "";
        if (rawText) {
          lastRawOutput = rawText;
        }
        parsed = parseScorePayloadFromResponse(response);
        if (parsed && typeof parsed === "object") {
          break;
        }
        attemptErrors.push(`${attempt.modelName}: Model çıktısı JSON olarak ayrıştırılamadı.`);
      } catch (error) {
        const details = error?.error?.message || error?.message || "Bilinmeyen hata";
        attemptErrors.push(`${attempt.modelName}: ${details}`);
      }
    }

    if ((!parsed || typeof parsed !== "object") && lastRawOutput.trim()) {
      try {
        const repairResponse = await openai.responses.create(
          {
            model: scoreRetryModel || scoreModel || model,
            instructions: SCORE_REPAIR_INSTRUCTIONS,
            input: `Convert the following model output into strict JSON for the scoring schema:\n\n${lastRawOutput.slice(0, 5000)}`,
            max_output_tokens: Math.max(1000, scoreMaxOutputTokens),
            text: {
              format: {
                type: "json_schema",
                name: "medical_reasoning_score_result",
                strict: true,
                schema: scoreSchema
              }
            }
          },
          {
            timeout: Math.max(10000, scoreRequestTimeoutMs)
          }
        );
        parsed = parseScorePayloadFromResponse(repairResponse);
      } catch (error) {
        const details = error?.error?.message || error?.message || "Bilinmeyen hata";
        attemptErrors.push(`repair: ${details}`);
      }
    }

    if (!parsed || typeof parsed !== "object") {
      await captureAppError({
        error: new AppError({
          message: `Skor model çıktısı ayrıştırılamadı: ${attemptErrors.join(" | ").slice(0, 420)}`,
          code: ERROR_CODES.OPENAI_UNAVAILABLE,
          status: 500,
          service: "openai"
        }),
        req,
        res,
        fallback: {
          service: "openai",
          code: ERROR_CODES.OPENAI_UNAVAILABLE,
          status: 500
        },
        metadata: {
          route: "/api/score",
          model: scoreModel || model,
          retry_model: scoreRetryModel || scoreModel || model
        }
      });
      return res.status(500).json({
        error: `Skor oluşturma başarısız: ${attemptErrors.join(" | ").slice(0, 420)}`
      });
    }

    const cleaned = postProcessScorePayload(parsed, {
      wrapup: safeWrapup,
      conversation: shortenedConversation
    });
    await setCachedScore(cacheKey, cleaned);
    return res.json(cleaned);
  } catch (error) {
    await captureAppError({
      error,
      req,
      res,
      fallback: {
        service: "openai",
        code: ERROR_CODES.OPENAI_UNAVAILABLE,
        status: 500
      },
      metadata: {
        route: "/api/score",
        model: scoreModel || model
      }
    });
    const details = error?.error?.message || error?.message || "Bilinmeyen hata";
    const status = Number(error?.status || error?.code || 0);
    const statusSuffix = status ? ` (kod: ${status})` : "";
    return res.status(500).json({
      error: `Skor oluşturma başarısız: ${details}${statusSuffix}`
    });
  }
}

app.get("/api/score", handleScoreRequest);
app.post("/api/score", handleScoreRequest);

app.use((req, res, next) => {
  if (res.headersSent) {
    return next();
  }
  if (String(req.path || "").startsWith("/api")) {
    return res.status(404).json({
      error: "Endpoint bulunamadı.",
      request_id: String(req.requestId || "").trim() || null
    });
  }
  return next();
});

app.use((error, req, res, next) => {
  if (res.headersSent) {
    return next(error);
  }
  const normalized = normalizeErrorForLog(error, {
    service: "express",
    code: ERROR_CODES.INTERNAL,
    status: Number(error?.status || 500)
  });

  void captureAppError({
    error,
    req,
    res,
    fallback: {
      service: "express",
      code: normalized.code,
      status: normalized.status
    },
    metadata: {
      route: String(req?.originalUrl || req?.url || ""),
      method: String(req?.method || "GET").toUpperCase()
    }
  }).finally(() => {
    const payload = {
      error:
        normalized.appError.expose !== false
          ? normalized.appError.message
          : "İşlem sırasında beklenmeyen bir hata oluştu.",
      code: normalized.code,
      request_id: String(req.requestId || "").trim() || null
    };
    res.status(normalized.status || 500).json(payload);
  });
});

process.on("unhandledRejection", (reason) => {
  // eslint-disable-next-line no-console
  console.error("[process] unhandledRejection:", reason);
  void captureAppError({
    error: reason instanceof Error ? reason : new Error(String(reason || "Unhandled rejection")),
    fallback: {
      service: "process",
      code: ERROR_CODES.INTERNAL,
      status: 500,
      message: "Unhandled rejection"
    },
    metadata: {
      process_event: "unhandledRejection"
    }
  });
});

process.on("uncaughtException", (error) => {
  // eslint-disable-next-line no-console
  console.error("[process] uncaughtException:", error);
  void captureAppError({
    error,
    fallback: {
      service: "process",
      code: ERROR_CODES.INTERNAL,
      status: 500,
      message: "Uncaught exception"
    },
    metadata: {
      process_event: "uncaughtException"
    }
  }).finally(() => {
    if (!process.env.VERCEL) {
      process.exitCode = 1;
    }
  });
});

async function maybeAutoApplySupabaseSchemaOnBoot() {
  const { autoApply, managementToken } = getSupabaseBootstrapConfig();
  if (!autoApply) {
    return;
  }

  const { supabaseUrl, supabaseServiceRoleKey } = getSupabaseConfig();
  if (!supabaseUrl || !supabaseServiceRoleKey) {
    // eslint-disable-next-line no-console
    console.warn("[supabase-bootstrap] auto-apply atlandi: SUPABASE_URL/SERVICE_ROLE eksik.");
    return;
  }

  try {
    const result = await applySupabaseSchemaBundle({
      supabaseUrl,
      supabaseServiceRoleKey,
      managementToken,
      preferredEngine: "auto"
    });
    // eslint-disable-next-line no-console
    console.log(
      `[supabase-bootstrap] tamamlandi. engine=${result.engine} applied=${result.applied.length}`
    );
  } catch (error) {
    // eslint-disable-next-line no-console
    console.error(`[supabase-bootstrap] hata: ${error?.message || "unknown"}`);
  }
}

async function maybeAutoSetupDailyWorkflowScheduleOnBoot() {
  const qstash = getQStashConfig();
  if (!qstash.autoSetupSchedule) {
    return;
  }
  if (!isQStashWorkflowConfigured()) {
    // eslint-disable-next-line no-console
    console.warn("[workflow] auto schedule atlandi: QStash config eksik.");
    return;
  }

  try {
    const result = await ensureDailyWorkflowSchedule({
      cron: qstash.dailyWorkflowCron,
      scheduleId: qstash.dailyWorkflowScheduleId,
      payload: { source: "boot-auto-schedule", forceRefresh: true }
    });
    // eslint-disable-next-line no-console
    console.log(
      `[workflow] auto schedule hazir. scheduleId=${result.scheduleId} cron=${result.cron}`
    );
  } catch (error) {
    // eslint-disable-next-line no-console
    console.error(`[workflow] auto schedule hatasi: ${error?.message || "unknown"}`);
  }
}

if (!process.env.VERCEL) {
  app.listen(port, () => {
    // eslint-disable-next-line no-console
    console.log(`Server running at http://localhost:${port}`);
    void maybeAutoApplySupabaseSchemaOnBoot();
    void maybeAutoSetupDailyWorkflowScheduleOnBoot();
  });
}

export default app;
