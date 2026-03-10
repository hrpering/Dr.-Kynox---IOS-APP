import { redirectIfAuthenticated } from "/auth-common.js";

const startBtn = document.getElementById("startBtn");
const haveAccountBtn = document.getElementById("haveAccountBtn");

async function enforceRedirect() {
  await redirectIfAuthenticated();
}

await enforceRedirect();

window.addEventListener("pageshow", () => {
  void enforceRedirect();
});

startBtn.addEventListener("click", () => {
  window.location.replace("/signup.html");
});

haveAccountBtn.addEventListener("click", () => {
  window.location.replace("/login.html");
});
