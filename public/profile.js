import {
  fetchMyProfile,
  getCachedProfile,
  requireAuth,
  setCachedProfile,
  signOutAndRedirect
} from "/auth-common.js";

const profileBackBtn = document.getElementById("profileBackBtn");
const profileNameEl = document.getElementById("profileName");
const profileEmailEl = document.getElementById("profileEmail");
const profilePhoneEl = document.getElementById("profilePhone");
const profileRoleTagEl = document.getElementById("profileRoleTag");
const profileLevelTagEl = document.getElementById("profileLevelTag");
const profileInterestsEl = document.getElementById("profileInterests");
const profileHistoryBtn = document.getElementById("profileHistoryBtn");
const profileLogoutBtn = document.getElementById("profileLogoutBtn");

function roleLabel(role) {
  const map = {
    medical_student: "Tıp öğrencisi",
    intern_resident: "İntern / Asistan",
    other_healthcare: "Diğer sağlık profesyoneli"
  };
  return map[role] || "Belirtilmedi";
}

function levelLabel(level) {
  const map = {
    Beginner: "Başlangıç",
    Intermediate: "Orta",
    Advanced: "İleri"
  };
  return map[level] || "Belirtilmedi";
}

function renderInterests(interests) {
  profileInterestsEl.innerHTML = "";
  const list = Array.isArray(interests) ? interests.filter(Boolean) : [];

  if (!list.length) {
    const empty = document.createElement("p");
    empty.className = "profile-empty";
    empty.textContent = "İlgi alanı seçimi yok.";
    profileInterestsEl.append(empty);
    return;
  }

  list.forEach((item) => {
    const chip = document.createElement("span");
    chip.className = "profile-interest-chip";
    chip.textContent = item;
    profileInterestsEl.append(chip);
  });
}

function renderProfile(profile) {
  profileNameEl.textContent = profile?.full_name || "Kullanıcı";
  profileEmailEl.textContent = profile?.email || "-";
  profilePhoneEl.textContent = profile?.phone_number || "-";
  profileRoleTagEl.textContent = `Rol: ${roleLabel(profile?.role)}`;
  profileLevelTagEl.textContent = `Seviye: ${levelLabel(profile?.learning_level)}`;
  renderInterests(profile?.interest_areas);
}

profileBackBtn.addEventListener("click", () => {
  window.location.replace("/index.html");
});

profileHistoryBtn.addEventListener("click", () => {
  window.location.href = "/case-history.html";
});

profileLogoutBtn.addEventListener("click", async () => {
  profileLogoutBtn.disabled = true;
  profileLogoutBtn.textContent = "Çıkış yapılıyor...";
  await signOutAndRedirect();
});

async function initProfile() {
  const cached = getCachedProfile();
  if (cached) {
    renderProfile(cached);
  }

  const session = await requireAuth("/login.html");
  if (!session?.access_token) {
    return;
  }

  const profile = await fetchMyProfile(session.access_token).catch(() => null);
  if (profile) {
    setCachedProfile(profile);
    renderProfile(profile);
  }
}

await initProfile();
