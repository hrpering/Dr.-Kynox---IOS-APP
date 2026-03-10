import {
  DIMENSION_ORDER,
  clearCaseResult,
  formatDateTimeLabel,
  getDimensionLabel,
  loadCaseResult,
  makeConciseText
} from "/session-core.js";

const backToResultsBtn = document.getElementById("backToResultsBtn");
const caseMetaTitleEl = document.getElementById("caseMetaTitle");
const caseMetaTimeEl = document.getElementById("caseMetaTime");
const overallSubtitleEl = document.getElementById("overallSubtitle");
const feedbackOverallScoreEl = document.getElementById("feedbackOverallScore");
const feedbackLabelBadgeEl = document.getElementById("feedbackLabelBadge");
const feedbackTrueDiagnosisEl = document.getElementById("feedbackTrueDiagnosis");
const feedbackUserDiagnosisEl = document.getElementById("feedbackUserDiagnosis");
const generalAssessmentTextEl = document.getElementById("generalAssessmentText");
const dimensionAccordionEl = document.getElementById("dimensionAccordion");
const exportBtn = document.getElementById("exportBtn");
const continueFromDetailBtn = document.getElementById("continueFromDetailBtn");

const resultPayload = loadCaseResult();
if (!resultPayload || !resultPayload.score) {
  window.location.replace("/case-results.html");
  throw new Error("Detaylı geri bildirim için skor verisi bulunamadı");
}

const score = resultPayload.score;

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

function meterDots(scoreOutOf10) {
  const numeric = Number(scoreOutOf10);
  if (!Number.isFinite(numeric)) {
    return 0;
  }
  return Math.max(0, Math.min(5, Math.round(numeric / 2)));
}

function pickDimensionImprovement(dimension) {
  const recommendation = makeConciseText(dimension?.recommendation, 1, 170);
  if (recommendation) {
    return recommendation;
  }
  return "Bu alanda daha yapılandırılmış bir yaklaşım dene.";
}

function extractUserDiagnosisFromTranscript(transcript) {
  const list = Array.isArray(transcript) ? transcript : [];
  const userMessages = list
    .filter((item) => item?.source === "user")
    .map((item) => String(item?.message || "").trim())
    .filter(Boolean);

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

function buildDimensionCard(index, dimension, expanded) {
  const article = document.createElement("article");
  article.className = "dimension-item";
  if (expanded) {
    article.classList.add("expanded");
  }

  const headerBtn = document.createElement("button");
  headerBtn.type = "button";
  headerBtn.className = "dimension-header";

  const left = document.createElement("div");
  left.className = "dimension-header-left";

  const indexBadge = document.createElement("span");
  indexBadge.className = "dimension-index";
  indexBadge.textContent = String(index + 1);

  const titleWrap = document.createElement("div");
  titleWrap.className = "dimension-title-wrap";
  const title = document.createElement("h4");
  title.textContent = getDimensionLabel(dimension.key);

  const meter = document.createElement("div");
  meter.className = "score-meter";
  const filled = meterDots(dimension.score);
  for (let i = 0; i < 5; i += 1) {
    const dot = document.createElement("span");
    dot.className = "meter-dot";
    if (i < filled) {
      dot.classList.add("filled");
    }
    meter.append(dot);
  }

  const scoreText = document.createElement("span");
  scoreText.className = "meter-score";
  scoreText.textContent = `${Number(dimension.score).toFixed(1)}/10`;
  meter.append(scoreText);

  titleWrap.append(title, meter);
  left.append(indexBadge, titleWrap);

  const chevron = document.createElement("span");
  chevron.className = "dimension-chevron";
  chevron.textContent = "v";

  headerBtn.append(left, chevron);

  const details = document.createElement("div");
  details.className = "dimension-details";

  const strengthsPanel = document.createElement("section");
  strengthsPanel.className = "detail-panel positive";
  const strengthsTitle = document.createElement("h5");
  strengthsTitle.textContent = "Güçlü Yönler";
  const strengthsText = document.createElement("p");
  strengthsText.textContent =
    makeConciseText(dimension.explanation, 1, 180) || "Bu alan için açıklama bulunamadı.";
  strengthsPanel.append(strengthsTitle, strengthsText);

  const improvePanel = document.createElement("section");
  improvePanel.className = "detail-panel warning";
  const improveTitle = document.createElement("h5");
  improveTitle.textContent = "Gelişim Alanı";
  const improveText = document.createElement("p");
  improveText.textContent = pickDimensionImprovement(dimension);
  improvePanel.append(improveTitle, improveText);

  const recPanel = document.createElement("section");
  recPanel.className = "detail-panel info";
  const recTitle = document.createElement("h5");
  recTitle.textContent = "Öneri";
  const recText = document.createElement("p");
  recText.textContent =
    makeConciseText(dimension.recommendation, 1, 180) || "Bu alan için özel öneri bulunamadı.";
  recPanel.append(recTitle, recText);

  details.append(strengthsPanel, improvePanel, recPanel);
  article.append(headerBtn, details);

  headerBtn.addEventListener("click", () => {
    article.classList.toggle("expanded");
  });

  return article;
}

function renderDimensions() {
  const byKey = new Map((Array.isArray(score.dimensions) ? score.dimensions : []).map((d) => [d.key, d]));
  dimensionAccordionEl.innerHTML = "";

  let rendered = 0;
  DIMENSION_ORDER.forEach((key) => {
    const dim = byKey.get(key);
    if (!dim) {
      return;
    }

    const card = buildDimensionCard(rendered, dim, rendered === 0);
    dimensionAccordionEl.append(card);
    rendered += 1;
  });
}

const caseContext = resultPayload.caseContext || {
  title: "Oluşturulan Klinik Vaka",
  specialty: "Genel Tıp",
  subtitle: "Vaka özeti konuşma kaydından oluşturuldu."
};

caseMetaTitleEl.textContent = `${caseContext.title} - ${caseContext.specialty}`;
caseMetaTimeEl.textContent = formatDateTimeLabel(resultPayload.endedAt || Date.now());
overallSubtitleEl.textContent = caseContext.subtitle || score.brief_summary || "";
overallSubtitleEl.textContent =
  makeConciseText(overallSubtitleEl.textContent, 1, 120) || "Klinik performans özeti";
feedbackOverallScoreEl.textContent = String(Math.round(Number(score.overall_score) || 0));
feedbackLabelBadgeEl.textContent = getLabelTr(score.label);
feedbackLabelBadgeEl.classList.add(labelClass(score.label));
if (feedbackTrueDiagnosisEl) {
  feedbackTrueDiagnosisEl.textContent =
    makeConciseText(score?.true_diagnosis, 1, 90) || "Kesin tanı paylaşılmadı";
}
if (feedbackUserDiagnosisEl) {
  feedbackUserDiagnosisEl.textContent =
    makeConciseText(score?.user_diagnosis || extractUserDiagnosisFromTranscript(resultPayload.transcript), 1, 90) ||
    "Belirtilmedi";
}
generalAssessmentTextEl.textContent =
  makeConciseText(score.brief_summary, 2, 260) || "Bu vaka için genel değerlendirme oluşturulamadı.";

renderDimensions();

backToResultsBtn.addEventListener("click", () => {
  window.location.href = "/case-results.html";
});

exportBtn.addEventListener("click", () => {
  exportBtn.textContent = "Yakında";
  setTimeout(() => {
    exportBtn.textContent = "Raporu Dışa Aktar";
  }, 1200);
});

continueFromDetailBtn.addEventListener("click", () => {
  clearCaseResult();
  window.location.replace("/index.html");
});
