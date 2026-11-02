import { supabase } from "./supabase-client.js";

const ACCOUNT_PATH = "/login/";
const PLANS = {
  monthly: { label: "Monthly affiliate", amountGhs: 1000 },
  annual: { label: "Annual affiliate", amountGhs: 8000 },
};
const PRACTICE_LABELS = {
  researcher: "Researcher",
  creative: "Creative",
  spatial_practitioner: "Spatial practitioner",
  collective: "Collective",
  student: "Student",
  partner_institution: "Partner institution",
  other: "Other",
};
const BASED_LABELS = {
  accra: "Accra",
  passing_through: "Passing through",
};

const interestDialog = document.getElementById("interestDialog");
const interestForm = document.getElementById("interestForm");
const interestMessage = document.getElementById("interestMessage");
const interestSubmit = document.getElementById("interestSubmit");
const interestClose = document.getElementById("interestClose");

const reviewDialog = document.getElementById("reviewDialog");
const reviewDetails = document.getElementById("reviewDetails");
const reviewClose = document.getElementById("reviewClose");
const reviewDone = document.getElementById("reviewDone");

const statusLine = document.getElementById("payStatus");

function setMessage(element, text) {
  element.textContent = text;
  element.hidden = !text;
}

function setStatus(text, type = "success") {
  statusLine.textContent = text;
  statusLine.className = `pay-status${type === "error" ? " is-error" : ""}`;
  statusLine.hidden = false;
}

function requestedPlan() {
  const plan = new URLSearchParams(window.location.search).get("plan");
  return Object.hasOwn(PLANS, plan) ? plan : null;
}

async function currentSession() {
  const { data, error } = await supabase.auth.getSession();
  if (error) {
    console.error("Could not check the current session:", error.message);
    return null;
  }
  return data.session;
}

function addReviewRow(label, value) {
  const term = document.createElement("dt");
  term.textContent = label;
  const detail = document.createElement("dd");
  detail.textContent = value;
  reviewDetails.append(term, detail);
}

function showApplicationReview(form) {
  const fields = form.elements;
  const plan = fields.plan.value;
  reviewDetails.replaceChildren();

  addReviewRow("Full name", fields.fullName.value.trim());
  addReviewRow("Email", fields.email.value);
  addReviewRow("Phone", fields.phone.value.trim());
  addReviewRow("What best describes you", PRACTICE_LABELS[fields.practiceType.value] ?? fields.practiceType.value);
  addReviewRow("Based in", BASED_LABELS[fields.basedIn.value] ?? fields.basedIn.value);
  addReviewRow("Membership", `${PLANS[plan]?.label ?? plan} — GH₵ ${PLANS[plan]?.amountGhs ?? ""}`);
  addReviewRow("Status", "Under review");
  addReviewRow("About your work", fields.aboutWork.value.trim());

  interestDialog.close();
  statusLine.hidden = true;
  reviewDialog.showModal();
}

function openInterestForm(session, plan) {
  interestForm.reset();
  interestDialog.dataset.plan = plan;
  if (plan) interestForm.elements.plan.value = plan;
  interestForm.elements.fullName.value = session.user.user_metadata?.full_name || "";
  interestForm.elements.email.value = session.user.email || "";
  setMessage(interestMessage, "");
  statusLine.hidden = true;
  interestDialog.showModal();
}

async function handleInterestSubmit(event) {
  event.preventDefault();
  setMessage(interestMessage, "");

  if (!interestForm.reportValidity()) return;

  const session = await currentSession();
  if (!session) {
    window.location.assign(`${ACCOUNT_PATH}?plan=${interestDialog.dataset.plan}`);
    return;
  }

  const fields = interestForm.elements;
  interestSubmit.disabled = true;

  try {
    const { error } = await supabase.rpc("submit_membership_interest", {
      p_full_name: fields.fullName.value.trim(),
      p_phone: fields.phone.value.trim(),
      p_practice_type: fields.practiceType.value,
      p_based_in: fields.basedIn.value,
      p_about_work: fields.aboutWork.value.trim(),
      p_commitment_agreed: fields.commitment.checked,
      p_membership_tier: fields.plan.value,
    });

    if (error) {
      console.error("Could not save the membership interest form:", error.message);
      setMessage(interestMessage, "We couldn't save your form. Please check your answers and try again.");
      return;
    }

    supabase.functions
      .invoke("membership-submission-email")
      .then(({ error: emailError }) => {
        if (emailError) console.error("Could not send the application emails:", emailError.message);
      });

    showApplicationReview(interestForm);
  } finally {
    interestSubmit.disabled = false;
  }
}

async function handlePlanClick(event) {
  event.preventDefault();
  const plan = event.currentTarget.dataset.plan;
  const session = await currentSession();

  if (!session) {
    window.location.assign(`${ACCOUNT_PATH}?plan=${plan}`);
    return;
  }

  openInterestForm(session, plan);
}

document.querySelectorAll("[data-plan]").forEach((button) => {
  button.addEventListener("click", handlePlanClick);
});

interestForm.addEventListener("submit", handleInterestSubmit);
interestClose.addEventListener("click", () => interestDialog.close());
reviewClose.addEventListener("click", () => reviewDialog.close());
reviewDone.addEventListener("click", () => reviewDialog.close());

async function openRequestedPlan() {
  const plan = requestedPlan();
  if (!plan) return;

  const session = await currentSession();
  if (session) {
    openInterestForm(session, plan);
  } else {
    window.location.replace(`${ACCOUNT_PATH}?plan=${plan}`);
  }
}

openRequestedPlan();
