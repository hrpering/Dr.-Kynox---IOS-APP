import { setOnboardingRoute } from "/auth-common.js";

const tutorialStep3NextBtn = document.getElementById("tutorialStep3NextBtn");

setOnboardingRoute("/tutorial-step3.html");

tutorialStep3NextBtn.addEventListener("click", () => {
  window.location.href = "/tutorial-permission.html";
});
