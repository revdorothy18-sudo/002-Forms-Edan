import { supabase } from "./supabase-client.js";
import { loadMemberships } from "./admin-memberships.js";
import { loadStayBookings } from "./admin-bookings.js";
import { loadAvailability } from "./admin-availability.js";
import { loadMemberContent } from "./admin-members-content.js";
import { loadKpis } from "./admin-kpis.js";
import "./admin-nav.js";

const message = document.getElementById("adminMessage");
const dashboard = document.getElementById("adminDashboard");
const restricted = document.getElementById("adminRestricted");
const logoutButton = document.getElementById("adminLogout");

function setMessage(text, isError = false) {
  message.textContent = text;
  message.classList.toggle("admin__message--error", isError);
}

async function refreshDashboard() {
  await Promise.all([
    loadKpis(),
    loadMemberships(),
    loadStayBookings(),
    loadAvailability(),
    loadMemberContent()
  ]);
}

logoutButton.addEventListener("click", async () => {
  logoutButton.disabled = true;
  const { error } = await supabase.auth.signOut();

  if (error) {
    setMessage("Couldn't log out. Please try again.", true);
    logoutButton.disabled = false;
    return;
  }

  window.location.replace("/login/");
});

async function init() {
  const { data, error } = await supabase.auth.getSession();

  if (error || !data.session) {
    window.location.replace("/login/?next=admin");
    return;
  }

  const { data: allowed, error: permissionError } = await supabase.rpc("is_edan_admin");

  // TEMPORARY DEBUG: remove these two lines once admin access works.
  console.log("session user:", data.session.user.id, data.session.user.email);
  console.log("is_edan_admin result:", allowed, "error:", permissionError);

  if (permissionError || allowed !== true) {
    restricted.hidden = false;
    setMessage("");
    return;
  }

  dashboard.hidden = false;
  setMessage("");
  await refreshDashboard();
}

init().catch(error => {
  console.error("Dashboard error:", error);
  setMessage("Something went wrong loading the dashboard. Refresh and try again.", true);
});