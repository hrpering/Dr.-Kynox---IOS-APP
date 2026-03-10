import { getSupabaseClient } from "/supabase-client.js";
import {
  passwordStrongEnough,
  persistProfile,
  redirectIfAuthenticated,
  resolvePostAuthPath,
  setCachedProfile,
  setStatus,
  startOAuth
} from "/auth-common.js";

const signupForm = document.getElementById("signupForm");
const signupNameEl = document.getElementById("signupName");
const signupEmailEl = document.getElementById("signupEmail");
const signupPasswordEl = document.getElementById("signupPassword");
const toggleSignupPasswordBtn = document.getElementById("toggleSignupPassword");
const termsCheckEl = document.getElementById("termsCheck");
const marketingCheckEl = document.getElementById("marketingCheck");
const signupSubmitBtn = document.getElementById("signupSubmitBtn");
const googleSignupBtn = document.getElementById("googleSignupBtn");
const appleSignupBtn = document.getElementById("appleSignupBtn");
const signupStatusEl = document.getElementById("signupStatus");

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
  signupSubmitBtn.disabled = loading;
  googleSignupBtn.disabled = loading;
  appleSignupBtn.disabled = loading;
  signupSubmitBtn.textContent = loading ? "Hesap oluşturuluyor..." : "Hesap oluştur";
}

toggleSignupPasswordBtn.addEventListener("click", () => {
  const isPassword = signupPasswordEl.type === "password";
  signupPasswordEl.type = isPassword ? "text" : "password";
  toggleSignupPasswordBtn.textContent = isPassword ? "Gizle" : "Göster";
});

signupForm.addEventListener("submit", async (event) => {
  event.preventDefault();

  const fullName = signupNameEl.value.trim();
  const email = signupEmailEl.value.trim().toLowerCase();
  const password = signupPasswordEl.value;
  const termsAccepted = termsCheckEl.checked;
  const marketingOptIn = marketingCheckEl.checked;

  if (!fullName || !email || !password) {
    setStatus(signupStatusEl, "Tüm zorunlu alanları doldur.", true);
    return;
  }

  if (!passwordStrongEnough(password)) {
    setStatus(signupStatusEl, "Şifre kuralı sağlanmadı.", true);
    return;
  }

  if (!termsAccepted) {
    setStatus(signupStatusEl, "Devam etmek için koşulları kabul etmelisin.", true);
    return;
  }

  setLoading(true);
  setStatus(signupStatusEl, "", false);

  try {
    const supabase = await getSupabaseClient();
    const { data, error } = await supabase.auth.signUp({
      email,
      password,
      options: {
        emailRedirectTo: `${window.location.origin}/auth-callback.html`,
        data: {
          full_name: fullName,
          marketing_opt_in: marketingOptIn
        }
      }
    });

    if (error) {
      throw error;
    }

    const identities = Array.isArray(data?.user?.identities) ? data.user.identities : null;
    if (identities && identities.length === 0) {
      setStatus(signupStatusEl, "Bu e-posta zaten kayıtlı. Giriş yapabilir veya şifreni sıfırlayabilirsin.", true);
      return;
    }

    if (data?.session?.access_token) {
      if (data?.user) {
        setCachedProfile({
          id: data.user.id,
          email: data.user.email || email,
          full_name: fullName,
          marketing_opt_in: marketingOptIn
        });
      }
      await persistProfile(data.session.access_token, { fullName, marketingOptIn });
      const nextPath = (await resolvePostAuthPath()) || "/onboarding-profile.html";
      window.location.replace(nextPath);
      return;
    }

    await supabase.auth.resend({
      type: "signup",
      email
    }).catch(() => {});

    setStatus(
      signupStatusEl,
      "Hesap oluşturuldu. Giriş yapmadan önce e-posta doğrulamasını tamamla. Doğrulama maili tekrar gönderildi."
    );
  } catch (error) {
    setStatus(signupStatusEl, error?.message || "Hesap oluşturma başarısız.", true);
  } finally {
    setLoading(false);
  }
});

googleSignupBtn.addEventListener("click", async () => {
  await startOAuth("google", signupStatusEl, "Google ile kayıt başlatılamadı.");
});

appleSignupBtn.addEventListener("click", async () => {
  await startOAuth("apple", signupStatusEl, "Apple ile kayıt başlatılamadı.");
});
