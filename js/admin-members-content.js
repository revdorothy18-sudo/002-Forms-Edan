import { supabase } from "./supabase-client.js";
import { createActionCell, createRow, createTableButton, renderEmptyRow, setMessageText } from "./admin-table.js";
import { IMAGE_ACCEPT, uploadSiteImage } from "./admin-upload.js";

const ITEM_LIMIT = 100;
const IMAGE_REFERENCE_PATTERN = /^(\/images\/[^/\\]+|https:\/\/\S+)$/;
const HTTPS_PATTERN = /^https:\/\/\S+$/;

const CONTENT_TYPES = {
  gatherings: {
    table: "member_gatherings",
    singular: "gathering",
    fields: [
      { name: "title", label: "Title", type: "text", required: true, maxLength: 160 },
      { name: "starts_at", label: "Date and time", type: "datetime-local" },
      { name: "location", label: "Location", type: "text", maxLength: 160 },
      { name: "description", label: "Description", type: "textarea", maxLength: 2000 },
      { name: "image_path", label: "Photo", type: "image" },
      { name: "registration_url", label: "Registration link (https://)", type: "url" },
      { name: "sort_order", label: "Display order (lower first)", type: "number" }
    ]
  },
  research: {
    table: "member_research_items",
    singular: "research item",
    fields: [
      { name: "title", label: "Title", type: "text", required: true, maxLength: 160 },
      { name: "category", label: "Category", type: "text", maxLength: 80 },
      { name: "summary", label: "Summary", type: "textarea", maxLength: 500 },
      { name: "body", label: "Full text (blank lines start new paragraphs)", type: "textarea", maxLength: 20000 },
      { name: "image_path", label: "Photo", type: "image" },
      { name: "read_more_url", label: "Read more link (https://)", type: "url" },
      { name: "sort_order", label: "Display order (lower first)", type: "number" }
    ]
  },
  process: {
    table: "member_process_items",
    singular: "in-process item",
    fields: [
      { name: "title", label: "Title", type: "text", required: true, maxLength: 160 },
      { name: "category", label: "Category", type: "text", maxLength: 80 },
      { name: "summary", label: "Summary", type: "textarea", maxLength: 500 },
      { name: "body", label: "Full text (blank lines start new paragraphs)", type: "textarea", maxLength: 20000 },
      { name: "image_path", label: "Photo", type: "image" },
      { name: "sort_order", label: "Display order (lower first)", type: "number" }
    ]
  },
  videos: {
    table: "member_bonus_videos",
    singular: "bonus video",
    fields: [
      { name: "title", label: "Title", type: "text", required: true, maxLength: 160 },
      { name: "description", label: "Description", type: "textarea", maxLength: 2000 },
      { name: "video_path", label: "Video file path in the site-videos bucket", type: "text", maxLength: 300 },
      { name: "poster_path", label: "Poster photo", type: "image" },
      { name: "sort_order", label: "Display order (lower first)", type: "number" }
    ]
  }
};

const contentSection = document.getElementById("content");
const contentTypeButtons = document.querySelectorAll("[data-content-type]");
const contentAddButton = document.getElementById("contentAddButton");
const contentBody = document.getElementById("contentBody");
const contentError = document.getElementById("contentError");
const contentDialog = document.getElementById("contentDialog");
const contentDialogHeading = document.getElementById("contentDialogHeading");
const contentForm = document.getElementById("contentForm");
const contentFields = document.getElementById("contentFields");
const contentFormError = document.getElementById("contentFormError");
const contentSave = document.getElementById("contentSave");
const contentCancel = document.getElementById("contentCancel");

function selectedType() {
  return document.querySelector("[data-content-type][aria-pressed='true']")?.dataset.contentType ?? "gatherings";
}

function renderItemRow(item) {
  const row = createRow([
    item.title,
    item.is_published ? "Published" : "Draft",
    String(item.sort_order)
  ], ["Title", "Status", "Order"]);

  const editButton = createTableButton("Edit", "admin__button admin__button--small", { editId: item.id });
  const toggleButton = createTableButton(
    item.is_published ? "Unpublish" : "Publish",
    "admin__button admin__button--small",
    { toggleId: item.id, nextPublished: String(!item.is_published) }
  );
  const deleteButton = createTableButton(
    "Delete",
    "admin__button admin__button--small admin__button--danger",
    { deleteId: item.id, itemTitle: item.title }
  );

  row.append(createActionCell(editButton, toggleButton, deleteButton));
  return row;
}

export async function loadMemberContent() {
  const config = CONTENT_TYPES[selectedType()];
  setMessageText(contentError, "");

  const { data, error } = await supabase
    .from(config.table)
    .select("id, title, is_published, sort_order")
    .order("sort_order")
    .order("created_at", { ascending: false })
    .limit(ITEM_LIMIT);

  if (error) {
    setMessageText(contentError, `Entries could not be loaded: ${error.message}`);
    renderEmptyRow(contentBody, 4, "Entries could not be loaded.");
    return;
  }

  if (!data.length) {
    renderEmptyRow(contentBody, 4, "No entries yet.");
    return;
  }

  contentBody.replaceChildren(...data.map(renderItemRow));
}

function toDateTimeLocal(isoValue) {
  const date = new Date(isoValue);
  const localTime = new Date(date.getTime() - date.getTimezoneOffset() * 60000);
  return localTime.toISOString().slice(0, 16);
}

function fieldValue(field, item) {
  const value = item?.[field.name];
  if (field.type === "datetime-local") return value ? toDateTimeLocal(value) : "";
  if (value == null) return field.type === "number" ? "0" : "";
  return String(value);
}

function renderImageField(field, value) {
  const wrapper = document.createElement("div");
  wrapper.className = "admin__image-field";

  const current = document.createElement("input");
  current.type = "hidden";
  current.name = field.name;
  current.value = value;

  const preview = document.createElement("img");
  preview.className = "admin__image-preview";
  preview.alt = "";
  preview.hidden = !value;
  if (value) preview.src = value;

  const file = document.createElement("input");
  file.type = "file";
  file.id = `content-${field.name}-file`;
  file.className = "admin__file";
  file.accept = IMAGE_ACCEPT;
  file.dataset.imageField = field.name;

  const removeButton = createTableButton("Remove photo", "admin__button admin__button--small", {});
  removeButton.addEventListener("click", () => {
    current.value = "";
    file.value = "";
    preview.hidden = true;
    preview.removeAttribute("src");
  });

  wrapper.append(current, preview, file, removeButton);
  return wrapper;
}

function renderFields(config, item) {
  contentFields.replaceChildren(...config.fields.flatMap(field => {
    const value = fieldValue(field, item);
    const label = document.createElement("label");
    label.className = "admin__label";
    label.textContent = field.label;

    if (field.type === "image") {
      label.htmlFor = `content-${field.name}-file`;
      return [label, renderImageField(field, value)];
    }

    label.htmlFor = `content-${field.name}`;
    const input = field.type === "textarea" ? document.createElement("textarea") : document.createElement("input");
    input.id = `content-${field.name}`;
    input.name = field.name;
    input.className = "admin__file";

    if (field.type === "textarea") {
      input.rows = 4;
    } else {
      input.type = field.type;
    }

    input.required = Boolean(field.required);
    if (field.maxLength) input.maxLength = field.maxLength;
    input.value = value;

    return [label, input];
  }));
}

function openEditor(type, item = null) {
  const config = CONTENT_TYPES[type];
  contentForm.reset();
  setMessageText(contentFormError, "");
  contentDialog.dataset.contentType = type;
  contentDialog.dataset.itemId = item?.id ?? "";
  contentDialogHeading.textContent = `${item ? "Edit" : "Add"} ${config.singular}`;
  renderFields(config, item);
  contentDialog.showModal();
}

async function readFieldValue(field) {
  if (field.type === "image") {
    const file = contentFields.querySelector(`input[type="file"][data-image-field="${field.name}"]`).files[0];
    if (file) return uploadSiteImage(file);
    return contentFields.querySelector(`input[type="hidden"][name="${field.name}"]`).value;
  }

  const input = contentFields.querySelector(`[name="${field.name}"]`);

  if (field.type === "datetime-local") return input.value ? new Date(input.value).toISOString() : null;
  if (field.type === "number") return Math.trunc(Number(input.value)) || 0;
  return input.value.trim();
}

async function readPayload(config) {
  const payload = {};
  for (const field of config.fields) {
    payload[field.name] = await readFieldValue(field);
  }
  return payload;
}

function validatePayload(config, payload) {
  for (const field of config.fields) {
    const value = payload[field.name];
    if (field.type === "image" && value && !IMAGE_REFERENCE_PATTERN.test(value)) {
      return "That photo could not be used. Please upload it again.";
    }
    if (field.type === "url" && value && !HTTPS_PATTERN.test(value)) {
      return "Links must start with https://.";
    }
  }
  return "";
}

async function saveEntry(event) {
  event.preventDefault();
  setMessageText(contentFormError, "");

  if (!contentForm.reportValidity()) return;

  const type = contentDialog.dataset.contentType;
  const config = CONTENT_TYPES[type];
  const itemId = contentDialog.dataset.itemId;

  contentSave.disabled = true;

  let payload;
  try {
    payload = await readPayload(config);
  } catch (error) {
    setMessageText(contentFormError, error.message);
    contentSave.disabled = false;
    return;
  }

  const problem = validatePayload(config, payload);
  if (problem) {
    setMessageText(contentFormError, problem);
    contentSave.disabled = false;
    return;
  }

  const request = itemId
    ? supabase.from(config.table).update(payload).eq("id", itemId).select("id")
    : supabase.from(config.table).insert({ ...payload, is_published: false }).select("id");
  const { data, error } = await request;

  contentSave.disabled = false;

  if (error || !data?.length) {
    setMessageText(contentFormError, error?.message ?? "That entry could not be saved.");
    return;
  }

  contentDialog.close();
  await loadMemberContent();
}

async function togglePublished(button) {
  button.disabled = true;
  setMessageText(contentError, "");

  const { data, error } = await supabase
    .from(CONTENT_TYPES[selectedType()].table)
    .update({ is_published: button.dataset.nextPublished === "true" })
    .eq("id", button.dataset.toggleId)
    .select("id");

  if (error || !data?.length) {
    setMessageText(contentError, error?.message ?? "That entry could not be updated.");
    button.disabled = false;
    return;
  }

  await loadMemberContent();
}

async function deleteEntry(button) {
  if (!window.confirm(`Delete "${button.dataset.itemTitle}"? This cannot be undone.`)) return;

  button.disabled = true;
  setMessageText(contentError, "");

  const { data, error } = await supabase
    .from(CONTENT_TYPES[selectedType()].table)
    .delete()
    .eq("id", button.dataset.deleteId)
    .select("id");

  if (error || !data?.length) {
    setMessageText(contentError, error?.message ?? "That entry could not be deleted.");
    button.disabled = false;
    return;
  }

  await loadMemberContent();
}

async function openExistingEntry(itemId) {
  setMessageText(contentError, "");

  const { data, error } = await supabase
    .from(CONTENT_TYPES[selectedType()].table)
    .select("*")
    .eq("id", itemId)
    .maybeSingle();

  if (error || !data) {
    setMessageText(contentError, error?.message ?? "That entry could not be found.");
    return;
  }

  openEditor(selectedType(), data);
}

contentSection.addEventListener("click", (event) => {
  const typeButton = event.target.closest("[data-content-type]");
  if (typeButton) {
    contentTypeButtons.forEach(other => other.setAttribute("aria-pressed", String(other === typeButton)));
    loadMemberContent();
  }
});

contentAddButton.addEventListener("click", () => openEditor(selectedType()));

contentBody.addEventListener("click", (event) => {
  const editButton = event.target.closest("button[data-edit-id]");
  if (editButton) return openExistingEntry(editButton.dataset.editId);

  const toggleButton = event.target.closest("button[data-toggle-id]");
  if (toggleButton) return togglePublished(toggleButton);

  const deleteButton = event.target.closest("button[data-delete-id]");
  if (deleteButton) deleteEntry(deleteButton);
});

contentForm.addEventListener("submit", saveEntry);
contentCancel.addEventListener("click", () => contentDialog.close());
