import { getSupabaseClient } from "/supabase-client.js";
import {
  redirectIfAuthenticated,
  resolvePostAuthPath,
  setCachedProfile,
  setStatus,
  startOAuth
} from "/auth-common.js";

const loginForm = document.getElementById("loginForm");
const loginEmailEl = document.getElementById("loginEmail");
const loginPasswordEl = document.getElementById("loginPassword");
const toggleLoginPasswordBtn = document.getElementById("toggleLoginPassword");
const forgotPasswordBtn = document.getElementById("forgotPasswordBtn");
const loginSubmitBtn = document.getElementById("loginSubmitBtn");
const googleLoginBtn = document.getElementById("googleLoginBtn");
const appleLoginBtn = document.getElementById("appleLoginBtn");
const loginStatusEl = document.getElementById("loginStatus");

function isInvalidCredentialError(error) {
  const msg = String(error?.message || "").toLowerCase();
  return msg.includes("invalid login credentials") || msg.includes("invalid_grant");
}

function isEmailNotConfirmedError(error) {
  const msg = String(error?.message || "").toLowerCase();
  const code = String(error?.code || "").toLowerCase();
  return msg.includes("email not confirmed") || code.includes("email_not_confirmed");
}

async function tryResendConfirmation(supabase, email) {
  if (!email) {
    return false;
  }
  const { error } = await supabase.auth.resend({
    type: "signup",
    email
  });
  return !error;
}

async function enforceRedirect() {
  if (await redirectIfAuthenticated()) {
    // Zaten oturum açık.
  }
}

await enforceRedirect();

window.addEventListener("pageshow", () => {
  void enforceRedirect();
});

function setLoading(loading) {
  loginSubmitBtn.disabled = loading;
  googleLoginBtn.disabled = loading;
  appleLoginBtn.disabled = loading;
  forgotPasswordBtn.disabled = loading;
  loginSubmitBtn.textContent = loading ? "Giriş yapılıyor..." : "Giriş yap";
}

toggleLoginPasswordBtn.addEventListener("click", () => {
  const isPassword = loginPasswordEl.type === "password";
  loginPasswordEl.type = isPassword ? "text" : "password";
  toggleLoginPasswordBtn.textContent = isPassword ? "Gizle" : "Göster";
});

forgotPasswordBtn.addEventListener("click", async () => {
  const email = loginEmailEl.value.trim();
  if (!email) {
    setStatus(loginStatusEl, "Şifre sıfırlama için önce e-posta adresini yaz.", true);
    return;
  }

  try {
    const supabase = await getSupabaseClient();
    const { error } = await supabase.auth.resetPasswordForEmail(email, {
      redirectTo: `${window.location.origin}/login.html`
    });
    if (error) {
      throw error;
    }
    setStatus(loginStatusEl, "Şifre sıfırlama bağlantısı gönderildi.");
  } catch (error) {
    setStatus(loginStatusEl, error?.message || "Şifre sıfırlama başarısız.", true);
  }
});

loginForm.addEventListener("submit", async (event) => {
  event.preventDefault();

  const email = loginEmailEl.value.trim().toLowerCase();
  const password = loginPasswordEl.value;

  if (!email || !password) {
    setStatus(loginStatusEl, "E-posta ve şifre alanları zorunlu.", true);
    return;
  }

  setLoading(true);
  setStatus(loginStatusEl, "", false);

  let supabase = null;
  try {
    supabase = await getSupabaseClient();
    const { data, error } = await supabase.auth.signInWithPassword({ email, password });
    if (error) {
      throw error;
    }

    const user = data?.user || null;
    if (user) {
      setCachedProfile({
        id: user.id,
        email: user.email || email,
        full_name: user?.user_metadata?.full_name || user?.user_metadata?.name || ""
      });
    }

    const nextPath = (await resolvePostAuthPath()) || "/onboarding-profile.html";
    window.location.replace(nextPath);
  } catch (error) {
    if (isEmailNotConfirmedError(error)) {
      const resent = supabase ? await tryResendConfirmation(supabase, email).catch(() => false) : false;
      setStatus(
        loginStatusEl,
        resent
          ? "E-posta doğrulaması gerekli. Doğrulama maili tekrar gönderildi."
          : "E-posta doğrulaması gerekli. Doğrulama mailini kontrol et.",
        true
      );
    } else if (isInvalidCredentialError(error)) {
      setStatus(
        loginStatusEl,
        "Giriş başarısız. E-posta veya şifre hatalı. Bu e-posta Google/Apple ile açıldıysa sosyal giriş kullan.",
        true
      );
    } else {
      setStatus(loginStatusEl, error?.message || "Giriş başarısız.", true);
    }
  } finally {
    setLoading(false);
  }
});

googleLoginBtn.addEventListener("click", async () => {
  await startOAuth("google", loginStatusEl, "Google ile giriş başlatılamadı.");
});

appleLoginBtn.addEventListener("click", async () => {
  await startOAuth("apple", loginStatusEl, "Apple ile giriş başlatılamadı.");
});
