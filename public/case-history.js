import { fetchCaseList, getCachedCaseList, requireAuth, setCachedCaseList } from "/auth-common.js";
import { saveCaseResult } from "/session-core.js";

const backToDashboardBtn = document.getElementById("backToDashboardBtn");
const historySearchInputEl = document.getElementById("historySearchInput");
const historySummaryTextEl = document.getElementById("historySummaryText");
const historyListEl = document.getElementById("historyList");
const historyLoadingSkeletonEl = document.getElementById("historyLoadingSkeleton");
const historyMainEl = document.getElementById("historyMain");

let allCases = [];

function setHistoryLoading(isLoading) {
  if (historyLoadingSkeletonEl) {
    historyLoadingSkeletonEl.hidden = !isLoading;
  }
  if (historySearchInputEl) {
    historySearchInputEl.disabled = isLoading;
  }
  if (historyMainEl) {
    historyMainEl.setAttribute("aria-busy", isLoading ? "true" : "false");
  }
}

function titleOf(item) {
  const title = String(item?.case_context?.title || "").trim();
  if (title && title.toLowerCase() !== "oluşturulan klinik vaka" && title.toLowerCase() !== "oluşturulan vaka") {
    return title;
  }

  const scoreTitle = String(item?.score?.case_title || "").trim();
  if (scoreTitle) {
    return scoreTitle;
  }

  return "Oluşturulan Klinik Vaka";
}

function inferSpecialtyFromTranscript(item) {
  const transcript = Array.isArray(item?.transcript) ? item.transcript : [];
  const text = transcript
    .map((row) => String(row?.message || ""))
    .join(" ")
    .toLowerCase();

  if (!text) {
    return "Genel Tıp";
  }
  if (
    text.includes("göğüs ağrısı") ||
    text.includes("gogus agrisi") ||
    text.includes("chest pain") ||
    text.includes("troponin") ||
    text.includes("ekg") ||
    text.includes("ecg")
  ) {
    return "Kardiyoloji";
  }
  if (
    text.includes("nefes darlığı") ||
    text.includes("nefes darligi") ||
    text.includes("shortness of breath") ||
    text.includes("dyspnea") ||
    text.includes("öksürük") ||
    text.includes("oksuruk")
  ) {
    return "Göğüs Hastalıkları";
  }
  if (text.includes("karın ağrısı") || text.includes("karin agrisi") || text.includes("abdominal pain") || text.includes("kusma")) {
    return "Gastroenteroloji";
  }
  if (text.includes("inme") || text.includes("stroke") || text.includes("nörolojik")) {
    return "Nöroloji";
  }
  return "Genel Tıp";
}

function specialtyOf(item) {
  return item?.case_context?.specialty || inferSpecialtyFromTranscript(item);
}

function difficultyOf(item) {
  const value = String(item?.difficulty || "").trim();
  if (!value) {
    return "Random";
  }

  const map = {
    Beginner: "Başlangıç",
    Intermediate: "Orta",
    Advanced: "Zor",
    Uyarlanabilir: "Random",
    İleri: "Zor"
  };
  return map[value] || value;
}

function scoreOf(item) {
  const value = Number(item?.score?.overall_score);
  if (!Number.isFinite(value)) {
    return null;
  }
  return Math.round(value);
}

function toPayload(item) {
  return {
    status: item.status || "ready",
    sessionId: item.session_id || `case_${Date.now()}`,
    mode: item.mode === "text" ? "text" : "voice",
    startedAt: item.started_at || item.updated_at || new Date().toISOString(),
    endedAt: item.ended_at || item.updated_at || new Date().toISOString(),
    durationMin: Number(item.duration_min) || 1,
    messageCount: Number(item.message_count) || 0,
    difficulty: item.difficulty || "Random",
    transcript: Array.isArray(item.transcript) ? item.transcript : [],
    caseContext: item.case_context || {
      title: titleOf(item),
      specialty: specialtyOf(item),
      subtitle: "Geçmiş vaka kaydı"
    },
    score: item.score || null
  };
}

function formatDate(value) {
  const dt = new Date(value || Date.now());
  if (!Number.isFinite(dt.getTime())) {
    return "-";
  }
  return dt.toLocaleDateString("tr-TR", {
    day: "2-digit",
    month: "short"
  });
}

function filterList(query) {
  const q = String(query || "").trim().toLowerCase();
  if (!q) {
    return allCases;
  }
  return allCases.filter((item) => {
    const hay = `${titleOf(item)} ${specialtyOf(item)} ${item?.difficulty || ""}`.toLowerCase();
    return hay.includes(q);
  });
}

function renderSummary(cases) {
  const total = cases.length;
  const completed = cases.filter((item) => scoreOf(item) != null).length;
  historySummaryTextEl.textContent = `${total} kayıt bulundu · ${completed} kayıt skorlanmış`;
}

function renderList(cases) {
  historyListEl.innerHTML = "";

  if (!cases.length) {
    const empty = document.createElement("p");
    empty.className = "history-empty";
    empty.textContent = "Vaka kaydı bulunamadı.";
    historyListEl.append(empty);
    return;
  }

  cases.forEach((item) => {
    const row = document.createElement("button");
    row.type = "button";
    row.className = "history-item";

    const left = document.createElement("div");
    left.className = "history-item-left";

    const title = document.createElement("h3");
    title.textContent = titleOf(item);

    const meta = document.createElement("p");
    const score = scoreOf(item);
    const scoreText = score == null ? "Skor yok" : `${score}/100`;
    meta.textContent = `Bölüm: ${specialtyOf(item)} · Zorluk: ${difficultyOf(item)} · ${scoreText} · ${formatDate(item.updated_at)}`;

    left.append(title, meta);

    const right = document.createElement("span");
    right.className = "history-item-cta";
    right.textContent = "Aç";

    row.append(left, right);

    row.addEventListener("click", () => {
      saveCaseResult(toPayload(item));
      window.location.href = "/case-results.html";
    });

    historyListEl.append(row);
  });
}

historySearchInputEl.addEventListener("input", () => {
  const filtered = filterList(historySearchInputEl.value);
  renderSummary(filtered);
  renderList(filtered);
});

backToDashboardBtn.addEventListener("click", () => {
  window.location.replace("/index.html");
});

async function init() {
  setHistoryLoading(true);
  const cached = getCachedCaseList(120);
  if (cached.length) {
    allCases = cached;
    renderSummary(allCases);
    renderList(allCases);
    setHistoryLoading(false);
  }

  const session = await requireAuth("/login.html");
  if (!session?.access_token) {
    setHistoryLoading(false);
    return;
  }

  allCases = await fetchCaseList(session.access_token, 120).catch(() => cached);
  if (Array.isArray(allCases) && allCases.length) {
    setCachedCaseList(allCases);
  }
  renderSummary(allCases);
  renderList(allCases);
  setHistoryLoading(false);
}

await init();
