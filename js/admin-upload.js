import { supabase } from "./supabase-client.js";

const SITE_IMAGES_BUCKET = "site-images";
const MAX_IMAGE_BYTES = 5 * 1024 * 1024;
const IMAGE_EXTENSIONS = {
  "image/jpeg": "jpg",
  "image/png": "png",
  "image/webp": "webp",
  "image/avif": "avif",
  "image/gif": "gif"
};

export const IMAGE_ACCEPT = Object.keys(IMAGE_EXTENSIONS).join(",");

export function imageFileProblem(file) {
  if (!IMAGE_EXTENSIONS[file.type]) return "Choose a JPEG, PNG, WebP, AVIF or GIF photo.";
  if (file.size > MAX_IMAGE_BYTES) return "Photos must be 5 MB or smaller.";
  return "";
}

export async function uploadSiteImage(file) {
  const problem = imageFileProblem(file);
  if (problem) throw new Error(problem);

  const path = `${crypto.randomUUID()}.${IMAGE_EXTENSIONS[file.type]}`;
  const storage = supabase.storage.from(SITE_IMAGES_BUCKET);
  const { error } = await storage.upload(path, file, { contentType: file.type, cacheControl: "3600" });

  if (error) {
    console.error("Photo upload failed:", error);
    throw new Error("The photo could not be uploaded. Please try again.");
  }

  return storage.getPublicUrl(path).data.publicUrl;
}
