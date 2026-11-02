const EMAIL_FROM = "Ɛdan <onboarding@resend.dev>";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "GET, POST, PUT, DELETE, OPTIONS",
  "Access-Control-Allow-Headers": "Content-Type, Authorization, X-Client-Info, Apikey",
};

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

function escapeHtml(value: string): string {
  return value
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

const PRACTICE_LABELS: Record<string, string> = {
  researcher: "Researcher",
  creative: "Creative",
  spatial_practitioner: "Spatial practitioner",
  collective: "Collective",
  student: "Student",
  partner_institution: "Partner institution",
  other: "Other",
};

const BASED_IN_LABELS: Record<string, string> = {
  accra: "Based in Accra",
  passing_through: "Passing through Accra",
};

type Application = {
  id: string;
  applicant_email: string;
  full_name: string | null;
  phone: string | null;
  practice_type: string | null;
  based_in: string | null;
  about_work: string | null;
  submitted_at: string | null;
  submission_emailed_at: string | null;
};

type Email = { to: string[]; subject: string; html: string; text: string };

async function userIdFromToken(supabaseUrl: string, serviceKey: string, accessToken: string): Promise<string | null> {
  const response = await fetch(`${supabaseUrl}/auth/v1/user`, {
    headers: { apikey: serviceKey, Authorization: `Bearer ${accessToken}` },
  });
  if (!response.ok) return null;
  const user = (await response.json()) as { id?: unknown };
  return typeof user.id === "string" ? user.id : null;
}

async function loadLatestPendingApplication(
  supabaseUrl: string,
  serviceKey: string,
  userId: string,
): Promise<Application | null> {
  const select = "id,applicant_email,full_name,phone,practice_type,based_in,about_work,submitted_at,submission_emailed_at";
  const query = new URLSearchParams({
    user_id: `eq.${userId}`,
    status: "eq.pending",
    order: "created_at.desc",
    limit: "1",
    select,
  });
  const response = await fetch(`${supabaseUrl}/rest/v1/membership_applications?${query}`, {
    headers: { apikey: serviceKey, Authorization: `Bearer ${serviceKey}` },
  });
  if (!response.ok) {
    throw new Error(`Loading the application failed (${response.status})`);
  }
  const rows = (await response.json()) as Application[];
  return rows[0] ?? null;
}

async function setEmailedAt(
  supabaseUrl: string,
  serviceKey: string,
  applicationId: string,
  value: string | null,
  onlyIfUnsent: boolean,
): Promise<boolean> {
  const filter = onlyIfUnsent ? "&submission_emailed_at=is.null" : "";
  const response = await fetch(
    `${supabaseUrl}/rest/v1/membership_applications?id=eq.${applicationId}${filter}&select=id`,
    {
      method: "PATCH",
      headers: {
        apikey: serviceKey,
        Authorization: `Bearer ${serviceKey}`,
        "Content-Type": "application/json",
        Prefer: "return=representation",
      },
      body: JSON.stringify({ submission_emailed_at: value }),
    },
  );
  if (!response.ok) {
    throw new Error(`Updating the email status failed (${response.status})`);
  }
  const rows = (await response.json()) as unknown[];
  return rows.length > 0;
}

async function adminEmails(supabaseUrl: string, serviceKey: string): Promise<string[]> {
  const response = await fetch(`${supabaseUrl}/rest/v1/admins?select=user_id`, {
    headers: { apikey: serviceKey, Authorization: `Bearer ${serviceKey}` },
  });
  if (!response.ok) {
    throw new Error(`Loading the admins failed (${response.status})`);
  }
  const rows = (await response.json()) as { user_id: string }[];
  const emails: string[] = [];
  for (const row of rows) {
    const userResponse = await fetch(`${supabaseUrl}/auth/v1/admin/users/${row.user_id}`, {
      headers: { apikey: serviceKey, Authorization: `Bearer ${serviceKey}` },
    });
    if (!userResponse.ok) {
      throw new Error(`Loading an admin account failed (${userResponse.status})`);
    }
    const user = (await userResponse.json()) as { email?: unknown };
    if (typeof user.email === "string" && user.email) emails.push(user.email);
  }
  return emails;
}

function buildApplicantEmail(application: Application): Email {
  const name = application.full_name ?? "there";
  const subject = "We have received your Ɛdan membership application";
  const text = [
    `Hi ${name},`,
    "",
    "Thank you for applying to become an Ɛdan member. We have received your application and will be in touch as it moves forward.",
    "",
    "With thanks,",
    "The Ɛdan team",
  ].join("\n");
  const html = `
<div style="background:#F2EAD9;padding:24px 12px;font-family:Helvetica,Arial,sans-serif">
  <div style="max-width:560px;margin:0 auto;background:#FFFFFF;border-radius:12px;overflow:hidden">
    <div style="background:#DDB29A;padding:24px 28px">
      <div style="font-size:28px;font-weight:700;color:#2B2118">Ɛdan</div>
      <div style="font-size:14px;color:#2B2118">Membership application</div>
    </div>
    <div style="padding:28px">
      <p style="margin:0 0 12px;font-size:16px;line-height:1.5;color:#2B2118">Hi ${escapeHtml(name)},</p>
      <p style="margin:0 0 12px;font-size:16px;line-height:1.5;color:#2B2118">Thank you for applying to become an Ɛdan member. We have received your application and will be in touch as it moves forward.</p>
      <p style="margin:24px 0 0;font-size:14px;line-height:1.5;color:#6B5E50">With thanks,<br>The Ɛdan team</p>
    </div>
  </div>
</div>`;
  return { to: [application.applicant_email], subject, html, text };
}

function buildAdminEmail(application: Application, to: string[]): Email {
  const practice = PRACTICE_LABELS[application.practice_type ?? ""] ?? application.practice_type ?? "";
  const basedIn = BASED_IN_LABELS[application.based_in ?? ""] ?? application.based_in ?? "";
  const rows: [string, string][] = [
    ["Name", application.full_name ?? ""],
    ["Email", application.applicant_email],
    ["Phone", application.phone ?? ""],
    ["Practice", practice],
    ["Location", basedIn],
    ["Submitted", application.submitted_at ?? ""],
  ];
  const subject = `New membership application from ${application.full_name ?? application.applicant_email}`;
  const aboutWork = application.about_work ?? "";
  const text = [
    "A new membership application has been submitted.",
    "",
    ...rows.map(([label, value]) => `${label}: ${value}`),
    "",
    "About their work:",
    aboutWork,
  ].join("\n");
  const rowsHtml = rows
    .map(([label, value]) => `<tr><td style="padding:10px 16px;color:#6B5E50;border-bottom:1px solid #E8DCC8">${escapeHtml(label)}</td><td style="padding:10px 16px;color:#2B2118;font-weight:600;border-bottom:1px solid #E8DCC8">${escapeHtml(value)}</td></tr>`)
    .join("");
  const html = `
<div style="background:#F2EAD9;padding:24px 12px;font-family:Helvetica,Arial,sans-serif">
  <div style="max-width:560px;margin:0 auto;background:#FFFFFF;border-radius:12px;overflow:hidden">
    <div style="background:#DDB29A;padding:24px 28px">
      <div style="font-size:24px;font-weight:700;color:#2B2118">New membership application</div>
    </div>
    <div style="padding:28px">
      <table cellspacing="0" cellpadding="0" style="width:100%;border-collapse:collapse;font-size:15px">${rowsHtml}</table>
      <p style="margin:24px 0 8px;font-size:14px;font-weight:700;color:#2B2118">About their work</p>
      <p style="margin:0;font-size:14px;line-height:1.5;color:#2B2118;white-space:pre-wrap">${escapeHtml(aboutWork)}</p>
    </div>
  </div>
</div>`;
  return { to, subject, html, text };
}

async function sendEmail(email: Email) {
  const resendKey = Deno.env.get("RESEND_API_KEY");
  if (!resendKey) {
    throw new Error("Email is not configured");
  }
  const response = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${resendKey}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      from: EMAIL_FROM,
      to: email.to,
      subject: email.subject,
      html: email.html,
      text: email.text,
    }),
  });
  if (!response.ok) {
    throw new Error(`Sending the email failed (${response.status})`);
  }
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { status: 200, headers: corsHeaders });
  }

  if (req.method !== "POST") {
    return json({ error: "Method not allowed" }, 405);
  }

  try {
    const supabaseUrl = Deno.env.get("SUPABASE_URL");
    const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
    if (!supabaseUrl || !serviceKey) {
      return json({ error: "Notifications are not configured" }, 500);
    }

    const authHeader = req.headers.get("Authorization") ?? "";
    const accessToken = authHeader.startsWith("Bearer ") ? authHeader.slice(7) : "";
    if (!accessToken) {
      return json({ error: "Sign in to submit your application" }, 401);
    }

    const userId = await userIdFromToken(supabaseUrl, serviceKey, accessToken);
    if (!userId) {
      return json({ error: "Sign in to submit your application" }, 401);
    }

    const application = await loadLatestPendingApplication(supabaseUrl, serviceKey, userId);
    if (!application || !application.submitted_at) {
      return json({ error: "No submitted application found" }, 404);
    }
    if (application.submission_emailed_at) {
      return json({ sent: false, reason: "already_sent" });
    }

    const claimed = await setEmailedAt(supabaseUrl, serviceKey, application.id, new Date().toISOString(), true);
    if (!claimed) {
      return json({ sent: false, reason: "already_sent" });
    }

    try {
      await sendEmail(buildApplicantEmail(application));
      const admins = await adminEmails(supabaseUrl, serviceKey);
      if (admins.length > 0) {
        await sendEmail(buildAdminEmail(application, admins));
      }
    } catch (error) {
      await setEmailedAt(supabaseUrl, serviceKey, application.id, null, false);
      throw error;
    }

    return json({ sent: true });
  } catch (error) {
    console.error("Membership submission email failed:", error instanceof Error ? error.message : error);
    return json({ error: "Sending the notification failed" }, 500);
  }
});
