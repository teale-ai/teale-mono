import { cpSync, mkdirSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const docsSiteRoot = path.resolve(__dirname, "..");
const sourceDir = path.resolve(
  docsSiteRoot,
  "..",
  "Sources",
  "InferencePoolApp",
  "Resources",
  "DesktopCompanionWeb",
);
const targetDir = path.resolve(docsSiteRoot, "static", "desktop-companion");

mkdirSync(targetDir, { recursive: true });
cpSync(sourceDir, targetDir, { recursive: true });
