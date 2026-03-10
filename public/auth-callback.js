import { getSupabaseClient } from "/supabase-client.js";
import { resolvePostAuthPath, setCachedProfile, setStatus } from "/auth-common.js";

const callbackStatusEl = document.getElementById("callbackStatus");

async function finalizeAuth() {
  try {
    const supabase = await getSupabaseClient();
    const { data, error } = await supabase.auth.getSession();

    if (error) {
      throw error;
    }

    if (data?.session) {
      const user = data?.session?.user || null;
      if (user) {
        setCachedProfile({
          id: user.id,
          email: user.email || "",
          full_name: user?.user_metadata?.full_name || user?.user_metadata?.name || ""
        });
      }
      const nextPath = (await resolvePostAuthPath()) || "/onboarding-profile.html";
      window.location.replace(nextPath);
      return;
    }

    setStatus(callbackStatusEl, "Oturum bulunamadı. Giriş ekranına yönlendiriliyorsun.", true);
    setTimeout(() => {
      window.location.replace("/login.html");
    }, 900);
  } catch (error) {
    setStatus(callbackStatusEl, error?.message || "Oturum tamamlanamadı.", true);
    setTimeout(() => {
      window.location.replace("/login.html");
    }, 900);
  }
}

await finalizeAuth();
