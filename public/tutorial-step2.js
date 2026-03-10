import { setOnboardingRoute } from "/auth-common.js";

const tutorialStep2NextBtn = document.getElementById("tutorialStep2NextBtn");

setOnboardingRoute("/tutorial-step2.html");

tutorialStep2NextBtn.addEventListener("click", () => {
  window.location.href = "/tutorial-step3.html";
});
