import { supabase } from "./supabase-client.js";

const heroVideo = document.querySelector("#heroMedia video");

if (heroVideo) {
  heroVideo.addEventListener("playing", () => {
    supabase.from("video_views").insert({}).then(({ error }) => {
      if (error) console.error("Could not record video view:", error);
    });
  }, { once: true });
}
