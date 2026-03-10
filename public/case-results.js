import {
  DIMENSION_ORDER,
  clearCaseResult,
  deriveCaseContext,
  getDimensionLabel,
  hasSufficientEvidence,
  loadCaseResult,
  makeConciseText,
  saveCaseResult,
  score10To100,
  scoreTranscript
} from "/session-core.js";
import { syncCaseResultToDb } from "/case-sync.js";

const closeResultsBtn = document.getElementById("closeResultsBtn");
const caseTitleHeadingEl = document.getElementById("caseTitleHeading");
const caseDifficultyTagEl = document.getElementById("caseDifficultyTag");
const caseSpecialtyTagEl = document.getElementById("caseSpecialtyTag");
const resultsLoadingCardEl = document.getElementById("resultsLoadingCard");
const resultsNoDataCardEl = document.getElementById("resultsNoDataCard");
const resultsNoDataTextEl = document.getElementById("resultsNoDataText");
const resultsContentEl = document.getElementById("resultsContent");
const durationBadgeEl = document.getElementById("durationBadge");
const overallScoreValueEl = document.getElementById("overallScoreValue");
const performanceLabelPillEl = document.getElementById("performanceLabelPill");
const overviewSummaryTextEl = document.getElementById("overviewSummaryText");
const trueDiagnosisTextEl = document.getElementById("trueDiagnosisText");
const userDiagnosisTextEl = document.getElementById("userDiagnosisText");
const strengthsListEl = document.getElementById("strengthsList");
const improvementsListEl = document.getElementById("improvementsList");
const breakdownListEl = document.getElementById("breakdownList");
const viewDetailedBtn = document.getElementById("viewDetailedBtn");
const continueLearningBtn = document.getElementById("continueLearningBtn");

let resultPayload = loadCaseResult();
if (!resultPayload) {
  window.location.replace("/index.html");
  throw new Error("Vaka sonucu bulunamadı");
}

function isGenericCaseTitle(title) {
  const value = String(title || "").trim().toLowerCase();
  return !value || value === "oluşturulan klinik vaka" || value === "oluşturulan vaka";
}

function ensureResolvedCaseContext(payload) {
  const transcript = Array.isArray(payload?.transcript) ? payload.transcript : [];
  const existing = payload?.caseContext && typeof payload.caseContext === "object" ? payload.caseContext : {};
  const needsRebuild = isGenericCaseTitle(existing?.title) || !existing?.specialty;
  if (!needsRebuild) {
    return existing;
  }
  const derived = deriveCaseContext(transcript, payload?.score || null);
  return {
    ...existing,
    ...derived
  };
}

function getLabelTr(label) {
  const map = {
    Excellent: "Mükemmel",
    Good: "İyi",
    "Needs Improvement": "Geliştirilmeli",
    Poor: "Zayıf"
  };
  return map[label] || label || "Değerlendirme";
}

function labelClass(label) {
  if (label === "Excellent") {
    return "is-excellent";
  }
  if (label === "Good") {
    return "is-good";
  }
  if (label === "Needs Improvement") {
    return "is-needs-improvement";
  }
  return "is-poor";
}

function fillSimpleList(target, items, emptyText) {
  target.innerHTML = "";
  const list = Array.isArray(items) ? items : [];
  if (!list.length) {
    const li = document.createElement("li");
    li.textContent = emptyText;
    target.append(li);
    return;
  }

  list.slice(0, 4).forEach((item) => {
    const li = document.createElement("li");
    li.textContent = makeConciseText(item, 1, 110);
    target.append(li);
  });
}

function extractUserDiagnosisFromTranscript(transcript) {
  const list = Array.isArray(transcript) ? transcript : [];
  const userMessages = list
    .filter((item) => item?.source === "user")
    .map((item) => String(item?.message || "").trim())
    .filter(Boolean);

  if (!userMessages.length) {
    return "";
  }

  const reversed = [...userMessages].reverse();
  const patterns = [
    /(?:ön tanım|tanım|tanim|tanı koyuyorum|tani koyuyorum|nihai tanım|nihai tanim|en olası tanı|en olasi tani)[^:.]*[:\-]?\s*(.+)$/i,
    /(?:bence|muhtemelen|olası|olasi)\s+(.+)$/i
  ];

  for (const msg of reversed) {
    for (const pattern of patterns) {
      const match = msg.match(pattern);
      if (match && match[1]) {
        return makeConciseText(match[1], 1, 90);
      }
    }
  }

  return "";
}

function resolveDiagnosisSummary(payload) {
  const score = payload?.score || {};
  const trueDiagnosis = makeConciseText(
    score?.true_diagnosis || "",
    1,
    90
  );
  const userDiagnosis = makeConciseText(
    score?.user_diagnosis || extractUserDiagnosisFromTranscript(payload?.transcript),
    1,
    90
  );

  return {
    trueDiagnosis: trueDiagnosis || "Kesin tanı paylaşılmadı",
    userDiagnosis: userDiagnosis || "Belirtilmedi"
  };
}

function dimensionHint(key) {
  const hints = {
    data_gathering_quality: "Anamnez ve odaklı muayene",
    clinical_reasoning_logic: "Sistematik düşünme süreci",
    differential_diagnosis_depth: "Ayırıcı tanı derinliği",
    diagnostic_efficiency: "Uygun test isteme",
    management_plan_quality: "Kanıta dayalı planlama",
    safety_red_flags: "Kritik risk farkındalığı",
    decision_timing: "Zamanında karar verebilme",
    communication_clarity: "Açık ve net iletişim",
    guideline_consistency: "Kılavuza uygunluk",
    professionalism_empathy: "Profesyonellik ve empati"
  };
  return hints[key] || "Klinik performans alanı";
}

function renderBreakdown(dimensions) {
  breakdownListEl.innerHTML = "";
  const byKey = new Map((Array.isArray(dimensions) ? dimensions : []).map((item) => [item.key, item]));

  DIMENSION_ORDER.forEach((key) => {
    const dim = byKey.get(key);
    if (!dim) {
      return;
    }

    const row = document.createElement("article");
    row.className = "breakdown-row";

    const left = document.createElement("div");
    left.className = "breakdown-left";

    const icon = document.createElement("span");
    icon.className = "breakdown-icon";
    icon.textContent = key.slice(0, 2).toUpperCase();

    const text = document.createElement("div");
    const title = document.createElement("h4");
    title.textContent = getDimensionLabel(key);
    const subtitle = document.createElement("p");
    subtitle.textContent = dimensionHint(key);
    text.append(title, subtitle);
    left.append(icon, text);

    const scoreBadge = document.createElement("span");
    const percent = score10To100(dim.score);
    scoreBadge.className = "breakdown-score";
    if (percent < 75) {
      scoreBadge.classList.add("low");
    }
    scoreBadge.textContent = String(percent);

    row.append(left, scoreBadge);
    breakdownListEl.append(row);
  });
}

function renderCaseMeta(payload) {
  const context = ensureResolvedCaseContext(payload);
  const title = context.title || "Oluşturulan Klinik Vaka";
  const specialty = context.specialty || "Genel Tıp";
  const difficulty = payload.difficulty || "Random";

  caseTitleHeadingEl.textContent = title;
  caseDifficultyTagEl.textContent = `Zorluk: ${difficulty}`;
  caseSpecialtyTagEl.textContent = `Bölüm: ${specialty}`;
}

function renderReady(payload) {
  const score = payload.score;
  renderCaseMeta(payload);
  const diagnosis = resolveDiagnosisSummary(payload);

  resultsLoadingCardEl.hidden = true;
  resultsNoDataCardEl.hidden = true;
  resultsContentEl.hidden = false;
  overallScoreValueEl.textContent = String(Math.round(Number(score.overall_score) || 0));
  durationBadgeEl.textContent = `${payload.durationMin || 0} dk`;

  performanceLabelPillEl.className = "performance-pill";
  performanceLabelPillEl.classList.add(labelClass(score.label));
  performanceLabelPillEl.textContent = `${getLabelTr(score.label)} Performans`;

  overviewSummaryTextEl.textContent =
    makeConciseText(score.brief_summary, 2, 210) || "Değerlendirme özeti hazırlandı.";
  if (trueDiagnosisTextEl) {
    trueDiagnosisTextEl.textContent = diagnosis.trueDiagnosis;
  }
  if (userDiagnosisTextEl) {
    userDiagnosisTextEl.textContent = diagnosis.userDiagnosis;
  }
  fillSimpleList(strengthsListEl, score.strengths, "Belirgin güçlü yön bulunamadı.");
  fillSimpleList(
    improvementsListEl,
    score.improvements,
    "Gelişim alanı belirtilmedi."
  );
  renderBreakdown(score.dimensions);
  void syncCaseResultToDb(payload);
}

function setLoadingState(loading, message = "") {
  resultsLoadingCardEl.hidden = !loading;
  if (loading) {
    const p = resultsLoadingCardEl.querySelector("p");
    if (p && message) {
      p.textContent = message;
    }
    resultsNoDataCardEl.hidden = true;
    resultsContentEl.hidden = true;
  }
  continueLearningBtn.disabled = loading;
}

function renderNoData(message) {
  renderCaseMeta(resultPayload);
  resultsLoadingCardEl.hidden = true;
  resultsContentEl.hidden = true;
  resultsNoDataCardEl.hidden = false;
  resultsNoDataTextEl.textContent =
    makeConciseText(
      message ||
        "Yeterli görüşme kaydı olmadığı için skor ve geri bildirim oluşturulamadı. Vakayı birkaç klinik adımla tamamlayıp tekrar dene.",
      2,
      210
    ) || "Bu vaka için değerlendirme verisi oluşturulamadı.";
  continueLearningBtn.disabled = false;
  void syncCaseResultToDb(resultPayload);
}

async function ensureScored() {
  if (resultPayload.score) {
    resultPayload = {
      ...resultPayload,
      caseContext: ensureResolvedCaseContext(resultPayload)
    };
    saveCaseResult(resultPayload);
    renderReady(resultPayload);
    return;
  }

  const transcript = Array.isArray(resultPayload.transcript) ? resultPayload.transcript : [];
  if (resultPayload.status === "no_data" || !hasSufficientEvidence(transcript)) {
    renderNoData();
    return;
  }

  setLoadingState(true, "Skor ve geri bildirim oluşturuluyor...");
  renderCaseMeta(resultPayload);

  try {
    const scored = await scoreTranscript(
      transcript,
      resultPayload.mode || "voice",
      45000,
      resultPayload.optionalCaseWrapup || ""
    );
    const caseContext = deriveCaseContext(transcript, scored);
    resultPayload = {
      ...resultPayload,
      status: "ready",
      caseContext,
      score: scored
    };
    saveCaseResult(resultPayload);
    renderReady(resultPayload);
  } catch (error) {
    const message = String(error?.message || "");
    if (
      message.includes("yalnızca POST") ||
      message.includes("yalnizca POST") ||
      message.includes("method_required") ||
      message.includes("Cannot GET /api/score")
    ) {
      renderNoData("Skor servisine yanlış istek türü ulaştı. Sunucu yapılandırmasını kontrol edip tekrar dene.");
      return;
    }

    if (String(error?.message || "").includes("SCORE_TIMEOUT")) {
      setLoadingState(true, "İlk deneme zaman aşımına uğradı, tekrar deneniyor...");
      try {
        const retryScored = await scoreTranscript(
          transcript,
          resultPayload.mode || "voice",
          75000,
          resultPayload.optionalCaseWrapup || ""
        );
        const retryContext = deriveCaseContext(transcript, retryScored);
        resultPayload = {
          ...resultPayload,
          status: "ready",
          caseContext: retryContext,
          score: retryScored
        };
        saveCaseResult(resultPayload);
        renderReady(resultPayload);
        setLoadingState(false);
        return;
      } catch (retryError) {
        if (String(retryError?.message || "").includes("SCORE_TIMEOUT")) {
          renderNoData("Skor oluşturma uzun sürdü ve zaman aşımına uğradı. Biraz sonra tekrar dene.");
          return;
        }
        renderNoData("Skor oluşturulamadı. Lütfen vakayı yeniden tamamlayıp tekrar dene.");
        return;
      }
    }
    renderNoData("Skor oluşturulamadı. Lütfen vakayı yeniden tamamlayıp tekrar dene.");
    return;
  }

  setLoadingState(false);
}

viewDetailedBtn.addEventListener("click", () => {
  if (!resultPayload || !resultPayload.score) {
    return;
  }
  saveCaseResult(resultPayload);
  window.location.href = "/detailed-feedback.html";
});

function goHome() {
  clearCaseResult();
  window.location.replace("/index.html");
}

closeResultsBtn.addEventListener("click", goHome);
continueLearningBtn.addEventListener("click", goHome);

ensureScored();
