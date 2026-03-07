import esbuild from "esbuild";
import { copyFileSync, mkdirSync } from "node:fs";
import path from "node:path";

const watch = process.argv.includes("--watch");
const projectRoot = process.cwd();

const vaultRoot = process.env.OBSIDIAN_VAULT_ROOT
  ? path.resolve(process.env.OBSIDIAN_VAULT_ROOT)
  : null;

const defaultOutDir = path.join(projectRoot, "build-output");

const outDir = process.env.OBSIDIAN_PLUGIN_OUTDIR
  ? path.resolve(process.env.OBSIDIAN_PLUGIN_OUTDIR)
  : vaultRoot
    ? path.join(vaultRoot, ".obsidian/plugins/yazi-exporter")
    : defaultOutDir;

mkdirSync(outDir, { recursive: true });
copyFileSync(path.join(projectRoot, "manifest.json"), path.join(outDir, "manifest.json"));
copyFileSync(path.join(projectRoot, "styles.css"), path.join(outDir, "styles.css"));

const ctx = await esbuild.context({
  entryPoints: ["src/main.ts"],
  bundle: true,
  format: "cjs",
  target: "es2020",
  platform: "node",
  external: ["obsidian", "electron", "@codemirror/state", "@codemirror/view"],
  logLevel: "info",
  outfile: path.join(outDir, "main.js")
});

if (watch) {
  await ctx.watch();
  console.log("watch mode started");
} else {
  await ctx.rebuild();
  await ctx.dispose();
}
