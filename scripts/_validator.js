#!/usr/bin/env node
// Single-process JSON Schema validator for validate-schemas.sh
// Uses cached node_modules at .gigacode/.cache/node/ (ajv@8 + ajv-formats@3 + js-yaml@4).
//
// Subcommands:
//   compile  <schema>                 — load schema, ensure ajv.compile() succeeds
//   validate <schema> <jsonOrYaml>    — validate one document
//   jsonl    <schema> <file>          — validate JSONL per-line, print "passed/total"
//   yaml2json <yamlFile>              — print JSON to stdout
//
// Exit codes: 0 success, 1 validation failure, 2 internal error.

const path = require("path");
const fs = require("fs");

function die(msg, code = 2) { process.stderr.write(`validator: ${msg}\n`); process.exit(code); }

function cacheDir() {
  // this script ships at .gigacode/scripts/ → cache lives at .gigacode/.cache/node
  return path.resolve(__dirname, "..", ".cache", "node");
}

function ensureCache() {
  const dir = cacheDir();
  const marker = path.join(dir, "node_modules", "ajv", "package.json");
  if (fs.existsSync(marker)) return dir;
  fs.mkdirSync(dir, { recursive: true });
  const pkg = path.join(dir, "package.json");
  if (!fs.existsSync(pkg)) {
    fs.writeFileSync(pkg, JSON.stringify({
      private: true, name: "harness-validator-cache", version: "0.0.1"
    }, null, 2));
  }
  const { spawnSync } = require("child_process");
  process.stderr.write("validator: installing ajv + js-yaml into .gigacode/.cache/node/ (one-time)...\n");
  const r = spawnSync("npm", [
    "install", "--silent", "--no-audit", "--no-fund",
    "ajv@8", "ajv-formats@3", "js-yaml@4"
  ], { cwd: dir, stdio: ["ignore", "inherit", "inherit"] });
  if (r.status !== 0) die("npm install failed in " + dir);
  return dir;
}

function loadModules() {
  const dir = ensureCache();
  const Ajv = require(path.join(dir, "node_modules", "ajv", "dist", "2020.js")).default
              || require(path.join(dir, "node_modules", "ajv", "dist", "2020.js"));
  const addFormats = require(path.join(dir, "node_modules", "ajv-formats"));
  const yaml = require(path.join(dir, "node_modules", "js-yaml"));
  return { Ajv, addFormats, yaml };
}

function readDoc(file, yaml) {
  const raw = fs.readFileSync(file, "utf8");
  if (file.endsWith(".yaml") || file.endsWith(".yml")) return yaml.load(raw);
  return JSON.parse(raw);
}

function makeValidator(schemaPath) {
  const { Ajv, addFormats } = loadModules();
  const ajv = new Ajv({ strict: false, allErrors: true });
  addFormats(ajv);
  const schema = JSON.parse(fs.readFileSync(schemaPath, "utf8"));
  return { ajv, validate: ajv.compile(schema) };
}

function cmdCompile(schemaPath) {
  try { makeValidator(schemaPath); process.exit(0); }
  catch (e) { process.stderr.write(`compile error: ${e.message}\n`); process.exit(1); }
}

function cmdValidate(schemaPath, file) {
  try {
    const { yaml } = loadModules();
    const { validate } = makeValidator(schemaPath);
    const doc = readDoc(file, yaml);
    if (validate(doc)) process.exit(0);
    for (const err of (validate.errors || [])) {
      process.stderr.write(`  ${err.instancePath || "/"} ${err.message}\n`);
    }
    process.exit(1);
  } catch (e) { process.stderr.write(`validate error: ${e.message}\n`); process.exit(2); }
}

function cmdJsonl(schemaPath, file) {
  try {
    const { validate } = makeValidator(schemaPath);
    let total = 0, passed = 0;
    const lines = fs.readFileSync(file, "utf8").split("\n");
    const sampleErrors = [];
    for (const line of lines) {
      if (!line.trim()) continue;
      total++;
      let obj;
      try { obj = JSON.parse(line); }
      catch { if (sampleErrors.length < 3) sampleErrors.push("json-parse-fail"); continue; }
      if (validate(obj)) passed++;
      else if (sampleErrors.length < 3) {
        sampleErrors.push((validate.errors || []).map(e => `${e.instancePath || "/"} ${e.message}`).join("; "));
      }
    }
    process.stdout.write(`${passed}/${total}\n`);
    for (const e of sampleErrors) process.stderr.write(`  sample: ${e}\n`);
    process.exit(0);
  } catch (e) { process.stderr.write(`jsonl error: ${e.message}\n`); process.exit(2); }
}

function cmdYaml2Json(file) {
  try {
    const { yaml } = loadModules();
    const obj = yaml.load(fs.readFileSync(file, "utf8"));
    process.stdout.write(JSON.stringify(obj));
    process.exit(0);
  } catch (e) { process.stderr.write(`yaml2json error: ${e.message}\n`); process.exit(2); }
}

const [, , sub, ...args] = process.argv;
switch (sub) {
  case "compile":   if (args.length < 1) die("usage: compile <schema>");           cmdCompile(args[0]); break;
  case "validate":  if (args.length < 2) die("usage: validate <schema> <file>");   cmdValidate(args[0], args[1]); break;
  case "jsonl":     if (args.length < 2) die("usage: jsonl <schema> <file>");      cmdJsonl(args[0], args[1]); break;
  case "yaml2json": if (args.length < 1) die("usage: yaml2json <yamlFile>");       cmdYaml2Json(args[0]); break;
  default: die(`unknown subcommand: ${sub || "(none)"}; expected compile|validate|jsonl|yaml2json`);
}
