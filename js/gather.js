import { supabase } from "./supabase-client.js";

const PAYSTACK_PUBLIC_KEY = "pk_test_41f2f237f5c3ece88a2e4873079e1bb0ceb70ed4";
const ACCOUNT_PATH = "/login/";
const PLANS = {
  monthly: { label: "Monthly affiliate", amountGhs: 1000 },
  annual: { label: "Annual affiliate", amountGhs: 8000 },
};

const interestDialog = document.getElementById("interestDialog");
const interestForm = document.getElementById("interestForm");
const interestMessage = document.getElementById("interestMessage");
const interestSubmit = document.getElementById("interestSubmit");
const interestClose = document.getElementById("interestClose");

const planDialog = document.getElementById("planDialog");
const planForm = document.getElementById("planForm");
const planMessage = document.getElementById("planMessage");
const planSubmit = document.getElementById("planSubmit");
const planClose = document.getElementById("planClose");

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

function openInterestForm(session, plan) {
  interestForm.reset();
  interestDialog.dataset.plan = plan;
  interestForm.elements.fullName.value = session.user.user_metadata?.full_name || "";
  interestForm.elements.email.value = session.user.email || "";
  setMessage(interestMessage, "");
  statusLine.hidden = true;
  interestDialog.showModal();
}

function openPlanChoice(plan) {
  planForm.elements.plan.value = plan;
  setMessage(planMessage, "");
  planDialog.showModal();
}

function startPaystack({ email, fullName, phone, plan, userId, reference, amount }) {
  const handler = window.PaystackPop.setup({
    key: PAYSTACK_PUBLIC_KEY,
    email,
    amount,
    currency: "GHS",
    channels: ["card", "mobile_money"],
    ref: reference,
    metadata: {
      user_id: userId,
      plan,
      custom_fields: [
        { display_name: "Full name", variable_name: "full_name", value: fullName },
        { display_name: "Phone", variable_name: "phone", value: phone },
      ],
    },
    callback: () => {
      setStatus(
        "Payment submitted. We're verifying it now; your membership will be confirmed after verification."
      );
    },
    onClose: () => {
      setStatus(
        "Payment was not completed. Your application is saved, and you can try paying again from the membership section.",
        "error"
      );
    },
  });

  handler.openIframe();
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

    interestDialog.close();
    openPlanChoice(interestDialog.dataset.plan);
  } finally {
    interestSubmit.disabled = false;
  }
}

async function handlePlanSubmit(event) {
  event.preventDefault();
  setMessage(planMessage, "");

  if (!planForm.reportValidity()) return;

  if (!PAYSTACK_PUBLIC_KEY.startsWith("pk_")) {
    setMessage(planMessage, "Online payment isn't connected yet. Please try again later.");
    return;
  }

  const session = await currentSession();
  if (!session) {
    window.location.assign(`${ACCOUNT_PATH}?plan=${planForm.elements.plan.value}`);
    return;
  }

  const plan = planForm.elements.plan.value;
  const fullName = interestForm.elements.fullName.value.trim();
  const phone = interestForm.elements.phone.value.trim();

  planSubmit.disabled = true;

  try {
    const { data, error } = await supabase.functions.invoke("create-payment", {
      body: { plan },
    });

    if (error) {
      console.error("Payment initialization failed:", error.message);
      throw new Error("Could not initialize payment");
    }

    if (
      !data?.reference ||
      !Number.isInteger(data.amount) ||
      data.amount <= 0 ||
      data?.currency !== "GHS"
    ) {
      throw new Error("Invalid payment initialization response");
    }

    planDialog.close();

    startPaystack({
      email: data.email || session.user.email,
      fullName,
      phone,
      plan,
      userId: session.user.id,
      reference: data.reference,
      amount: data.amount,
    });
  } catch (error) {
    console.error("Could not start the membership payment:", error);
    setMessage(planMessage, "We couldn't start your payment. Please try again.");
  } finally {
    planSubmit.disabled = false;
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

planForm.addEventListener("submit", handlePlanSubmit);
planClose.addEventListener("click", () => planDialog.close());

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
