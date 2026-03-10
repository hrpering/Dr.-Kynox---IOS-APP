import { guardProtectedRoute } from "/auth-common.js";

await guardProtectedRoute({
  redirectPath: "/login.html",
  allowOnboardingIncomplete: false,
  allowOnboardingComplete: true
});
