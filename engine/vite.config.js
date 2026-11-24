// Bundles engine.js (YouTube.js + the proof-of-origin check) into ONE plain script. The Mac app loads it into a hidden web view
// only while it searches or downloads. Output (engine/dist/engine.js) is generated, not committed.
import { defineConfig } from "vite";
export default defineConfig({
  publicDir: false,
  build: {
    target: "es2020", outDir: "dist", emptyOutDir: true, minify: true, copyPublicDir: false,
    lib: { entry: "engine.js", formats: ["iife"], name: "AuraEng", fileName: () => "engine.js" },
  },
});
