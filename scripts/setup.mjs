#!/usr/bin/env node
// Post-install setup CLI for tauri-plugin-rekognition-liveness-api.
//
// Patches a consumer Tauri project so iOS + Android builds succeed:
//   - tauri.conf.json:         bundle.iOS.minimumSystemVersion = "15.0"
//   - src-tauri/build.rs:      16 KB ELF alignment linker flags (Google Play)
//   - gen/apple/project.yml:   IPHONEOS_DEPLOYMENT_TARGET = 15.0,
//                              LD_RUNPATH_SEARCH_PATHS includes /usr/lib/swift,
//                              NSCameraUsageDescription set,
//                              "Copy SwiftPM resource bundles" postCompileScripts
//   - gen/android/build.gradle.kts:     Kotlin 2.2.0 + compose-compiler-gradle-plugin
//   - gen/android/app/build.gradle.kts: desugar_jdk_libs >= 2.1.5,
//                                       isCoreLibraryDesugaringEnabled = true
//
// Idempotent: every patch is guarded by a presence check, so re-running is a
// no-op once the project is already configured.
//
// `tauri ios init` / `tauri android init` regenerate gen/apple and gen/android
// from templates and will wipe these patches; re-run setup afterwards.

import { execSync } from "node:child_process";
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";

const SCRIPT_DIR = dirname(fileURLToPath(import.meta.url));

function findTauriDir(start) {
  let dir = resolve(start);
  while (true) {
    if (existsSync(join(dir, "src-tauri/tauri.conf.json"))) {
      return join(dir, "src-tauri");
    }
    if (existsSync(join(dir, "tauri.conf.json"))) return dir;
    const parent = dirname(dir);
    if (parent === dir) return null;
    dir = parent;
  }
}

function info(msg) {
  console.log(`  ${msg}`);
}
function ok(msg) {
  console.log(`  \x1b[32m✓\x1b[0m ${msg}`);
}
function skip(msg) {
  console.log(`  \x1b[2m·\x1b[0m ${msg}`);
}
function warn(msg) {
  console.log(`  \x1b[33m!\x1b[0m ${msg}`);
}

// ---------- tauri.conf.json ----------

function patchTauriConf(tauriDir, dryRun) {
  const path = join(tauriDir, "tauri.conf.json");
  if (!existsSync(path)) {
    warn(`tauri.conf.json missing at ${path}`);
    return;
  }
  const orig = readFileSync(path, "utf8");
  const conf = JSON.parse(orig);
  conf.bundle ||= {};
  conf.bundle.iOS ||= {};
  let changed = false;
  if (conf.bundle.iOS.minimumSystemVersion !== "15.0") {
    conf.bundle.iOS.minimumSystemVersion = "15.0";
    changed = true;
  }
  if (changed) {
    if (!dryRun)
      writeFileSync(path, JSON.stringify(conf, null, 2) + "\n");
    ok(`tauri.conf.json: bundle.iOS.minimumSystemVersion = "15.0"`);
  } else {
    skip(`tauri.conf.json: already set`);
  }
}

// ---------- src-tauri/build.rs ----------

function patchBuildRs(tauriDir, dryRun) {
  const path = join(tauriDir, "build.rs");
  if (!existsSync(path)) {
    warn(`build.rs missing at ${path}`);
    return;
  }
  let content = readFileSync(path, "utf8");
  if (content.includes("max-page-size=16384")) {
    skip(`build.rs: 16 KB alignment already present`);
    return;
  }
  const injection =
    `    // Added by tauri-plugin-rekognition-liveness setup. Google Play requires\n` +
    `    // 16 KB-aligned native libs for new submissions from 2025-11-01.\n` +
    `    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("android") {\n` +
    `        println!("cargo:rustc-link-arg=-Wl,-z,max-page-size=16384");\n` +
    `        println!("cargo:rustc-link-arg=-Wl,-z,common-page-size=16384");\n` +
    `    }\n\n`;
  if (!/fn main\(\)\s*\{\s*\n/.test(content)) {
    warn(`build.rs has no recognisable fn main() — skipping`);
    return;
  }
  content = content.replace(/(fn main\(\)\s*\{\s*\n)/, `$1${injection}`);
  if (!dryRun) writeFileSync(path, content);
  ok(`build.rs: injected 16 KB ELF alignment linker flags`);
}

// ---------- gen/apple/project.yml ----------

function patchProjectYml(tauriDir, dryRun) {
  const path = join(tauriDir, "gen/apple/project.yml");
  if (!existsSync(path)) {
    skip(`gen/apple/project.yml not found — run \`tauri ios init\` first`);
    return false;
  }
  let content = readFileSync(path, "utf8");
  let changed = false;

  // 1. Bump iOS deployment target to >= 15.0
  const dtRegex = /(deploymentTarget:\s*\n\s*iOS:\s*)(\d+\.\d+)/;
  const dtMatch = content.match(dtRegex);
  if (dtMatch && versionLt(dtMatch[2], "15.0")) {
    content = content.replace(dtRegex, `$115.0`);
    changed = true;
    ok(`project.yml: deploymentTarget.iOS bumped ${dtMatch[2]} → 15.0`);
  } else if (dtMatch) {
    skip(`project.yml: deploymentTarget.iOS already ${dtMatch[2]}`);
  }

  // 2. Add LD_RUNPATH_SEARCH_PATHS with /usr/lib/swift
  if (!/LD_RUNPATH_SEARCH_PATHS/.test(content)) {
    const anchor = /(\s+ALWAYS_EMBED_SWIFT_STANDARD_LIBRARIES:\s*true\n)/;
    if (anchor.test(content)) {
      content = content.replace(
        anchor,
        `$1` +
          `        # Added by tauri-plugin-rekognition-liveness setup. dyld must be able to\n` +
          `        # locate /usr/lib/swift/libswiftCore.dylib referenced by embedded\n` +
          `        # back-deployed Swift runtime libs. Tauri's iOS template only sets\n` +
          `        # @executable_path/Frameworks here.\n` +
          `        LD_RUNPATH_SEARCH_PATHS: $(inherited) @executable_path/Frameworks /usr/lib/swift\n`,
      );
      changed = true;
      ok(`project.yml: added LD_RUNPATH_SEARCH_PATHS`);
    } else {
      warn(`project.yml: ALWAYS_EMBED_SWIFT_STANDARD_LIBRARIES anchor not found — skipped LD_RUNPATH_SEARCH_PATHS`);
    }
  } else if (!/LD_RUNPATH_SEARCH_PATHS:[^\n]*\/usr\/lib\/swift/.test(content)) {
    warn(`project.yml: LD_RUNPATH_SEARCH_PATHS exists but is missing /usr/lib/swift — leaving alone, please review`);
  } else {
    skip(`project.yml: LD_RUNPATH_SEARCH_PATHS already includes /usr/lib/swift`);
  }

  // 3. Add NSCameraUsageDescription
  if (!/NSCameraUsageDescription/.test(content)) {
    const anchor = /(\s+CFBundleVersion:\s*"[^"]*"\n)/;
    if (anchor.test(content)) {
      content = content.replace(
        anchor,
        `$1` +
          `        # Added by tauri-plugin-rekognition-liveness setup. iOS aborts the\n` +
          `        # process when AVCaptureDevice.requestAccess is called without\n` +
          `        # this string. Edit the prompt text to match your app.\n` +
          `        NSCameraUsageDescription: This app uses the camera to verify identity via AWS Face Liveness.\n`,
      );
      changed = true;
      ok(`project.yml: added NSCameraUsageDescription`);
    } else {
      warn(`project.yml: CFBundleVersion anchor not found — skipped NSCameraUsageDescription`);
    }
  } else {
    skip(`project.yml: NSCameraUsageDescription already present`);
  }

  // 4. Add postCompileScripts entry
  if (!/Copy SwiftPM resource bundles/.test(content)) {
    const indent = "    ";
    const block =
      `${indent}postCompileScripts:\n` +
      `${indent}  # Added by tauri-plugin-rekognition-liveness setup. SwiftPM-generated\n` +
      `${indent}  # resource bundles (e.g. AmplifyUILiveness_FaceLiveness.bundle\n` +
      `${indent}  # holding the BlazeFace .mlmodelc) emitted by swift-rs's nested\n` +
      `${indent}  # SwiftPM build aren't copied into the .app by Tauri's template.\n` +
      `${indent}  # Without them \`Bundle.module\` aborts at runtime as soon as\n` +
      `${indent}  # FaceLivenessDetectorView mounts.\n` +
      `${indent}  - name: Copy SwiftPM resource bundles\n` +
      `${indent}    basedOnDependencyAnalysis: false\n` +
      `${indent}    shell: /bin/bash\n` +
      `${indent}    script: |\n` +
      `${indent}      set -euo pipefail\n` +
      `${indent}      CARGO_PROFILE=$(echo "\${CONFIGURATION}" | tr '[:upper:]' '[:lower:]')\n` +
      `${indent}      for arch in \${ARCHS}; do\n` +
      `${indent}        case "$arch" in\n` +
      `${indent}          arm64) CARGO_TRIPLE="aarch64-apple-ios" ;;\n` +
      `${indent}          x86_64) CARGO_TRIPLE="x86_64-apple-ios" ;;\n` +
      `${indent}          *) echo "warning: unrecognised arch $arch, skipping" >&2; continue ;;\n` +
      `${indent}        esac\n` +
      `${indent}        BUILD_DIR="\${SRCROOT}/../../target/\${CARGO_TRIPLE}/\${CARGO_PROFILE}/build"\n` +
      `${indent}        if [ ! -d "$BUILD_DIR" ]; then continue; fi\n` +
      `${indent}        find "$BUILD_DIR" -path '*/swift-rs/*/*.bundle' -type d 2>/dev/null | while IFS= read -r bundle; do\n` +
      `${indent}          name=$(basename "$bundle")\n` +
      `${indent}          dest="\${BUILT_PRODUCTS_DIR}/\${WRAPPER_NAME}/\${name}"\n` +
      `${indent}          echo "copying $name -> $dest"\n` +
      `${indent}          rm -rf "$dest"\n` +
      `${indent}          /bin/cp -R "$bundle" "$dest"\n` +
      `${indent}        done\n` +
      `${indent}      done\n`;

    // Insert just before preBuildScripts (or, if absent, just before dependencies)
    if (/^\s+preBuildScripts:\s*\n/m.test(content)) {
      content = content.replace(
        /(^\s+preBuildScripts:\s*\n)/m,
        `${block}$1`,
      );
    } else if (/^\s+dependencies:\s*\n/m.test(content)) {
      content = content.replace(/(^\s+dependencies:\s*\n)/m, `${block}$1`);
    } else {
      content += `\n${block}`;
    }
    changed = true;
    ok(`project.yml: added "Copy SwiftPM resource bundles" build phase`);
  } else {
    skip(`project.yml: "Copy SwiftPM resource bundles" already present`);
  }

  if (changed) {
    if (!dryRun) writeFileSync(path, content);
    return true;
  }
  return false;
}

function runXcodegen(tauriDir, dryRun) {
  const dir = join(tauriDir, "gen/apple");
  if (!existsSync(join(dir, "project.yml"))) return;
  if (dryRun) {
    info(`(dry-run) would run: xcodegen generate in ${dir}`);
    return;
  }
  try {
    execSync("xcodegen generate", { cwd: dir, stdio: "inherit" });
    ok(`ran xcodegen generate`);
  } catch (e) {
    warn(`could not run xcodegen (${e.message})`);
    warn(`  install via: brew install xcodegen`);
    warn(`  then run:    cd ${dir} && xcodegen generate`);
  }
}

// ---------- gen/android/build.gradle.kts ----------

function patchAndroidRootGradle(tauriDir, dryRun) {
  const path = join(tauriDir, "gen/android/build.gradle.kts");
  if (!existsSync(path)) {
    skip(`gen/android/build.gradle.kts not found — run \`tauri android init\` first`);
    return;
  }
  let content = readFileSync(path, "utf8");
  let changed = false;

  // Bump kotlin-gradle-plugin to >= 2.2.0
  const kgpRegex =
    /(classpath\(["']org\.jetbrains\.kotlin:kotlin-gradle-plugin:)([^"']+)(["']\))/;
  const kgpMatch = content.match(kgpRegex);
  if (kgpMatch && versionLt(kgpMatch[2], "2.2.0")) {
    content = content.replace(kgpRegex, `$12.2.0$3`);
    changed = true;
    ok(`android root gradle: kotlin-gradle-plugin ${kgpMatch[2]} → 2.2.0`);
  } else if (kgpMatch) {
    skip(`android root gradle: kotlin-gradle-plugin already ${kgpMatch[2]}`);
  } else {
    warn(`android root gradle: kotlin-gradle-plugin classpath not found`);
  }

  // Add compose-compiler-gradle-plugin classpath
  if (!content.includes("compose-compiler-gradle-plugin")) {
    const anchor = /(classpath\(["']org\.jetbrains\.kotlin:kotlin-gradle-plugin:[^"']+["']\)\n)/;
    if (anchor.test(content)) {
      content = content.replace(
        anchor,
        `$1        classpath("org.jetbrains.kotlin:compose-compiler-gradle-plugin:2.2.0")\n`,
      );
      changed = true;
      ok(`android root gradle: added compose-compiler-gradle-plugin classpath`);
    } else {
      warn(`android root gradle: anchor for compose plugin not found`);
    }
  } else {
    skip(`android root gradle: compose-compiler-gradle-plugin already present`);
  }

  if (changed && !dryRun) writeFileSync(path, content);
}

// ---------- gen/android/app/build.gradle.kts ----------

function patchAndroidAppGradle(tauriDir, dryRun) {
  const path = join(tauriDir, "gen/android/app/build.gradle.kts");
  if (!existsSync(path)) {
    skip(`gen/android/app/build.gradle.kts not found`);
    return;
  }
  let content = readFileSync(path, "utf8");
  let changed = false;

  // Ensure compileOptions { ... } exists and has the three settings desugaring needs.
  // Tauri's freshly-generated app/build.gradle.kts doesn't include compileOptions
  // at all, so we either insert into the existing block or synthesise the whole one.
  if (/isCoreLibraryDesugaringEnabled\s*=\s*true/.test(content)) {
    skip(`android app gradle: isCoreLibraryDesugaringEnabled already true`);
  } else if (/compileOptions\s*\{/.test(content)) {
    content = content.replace(
      /(compileOptions\s*\{\s*\n)/,
      `$1        isCoreLibraryDesugaringEnabled = true\n` +
        `        sourceCompatibility = JavaVersion.VERSION_1_8\n` +
        `        targetCompatibility = JavaVersion.VERSION_1_8\n`,
    );
    changed = true;
    ok(`android app gradle: enabled isCoreLibraryDesugaringEnabled in existing compileOptions`);
  } else {
    // No compileOptions block — synthesise the whole thing. Anchor on the
    // kotlinOptions block (Tauri's template puts one in) so we land inside
    // the `android { }` scope, ahead of dependencies.
    const ktAnchor = /(\n\s*kotlinOptions\s*\{)/;
    if (ktAnchor.test(content)) {
      content = content.replace(
        ktAnchor,
        `\n    compileOptions {\n` +
          `        // Required for Amplify Liveness — its libs use java.time.*\n` +
          `        // which Android desugars for pre-API-26.\n` +
          `        isCoreLibraryDesugaringEnabled = true\n` +
          `        sourceCompatibility = JavaVersion.VERSION_1_8\n` +
          `        targetCompatibility = JavaVersion.VERSION_1_8\n` +
          `    }\n$1`,
      );
      changed = true;
      ok(`android app gradle: inserted compileOptions block with desugaring enabled`);
    } else {
      warn(`android app gradle: no kotlinOptions anchor found — please add a compileOptions block manually`);
    }
  }

  // Bump or add coreLibraryDesugaring desugar_jdk_libs >= 2.1.5
  const desugarRegex =
    /(coreLibraryDesugaring\(["']com\.android\.tools:desugar_jdk_libs:)([^"']+)(["']\))/;
  const desugarMatch = content.match(desugarRegex);
  if (desugarMatch) {
    if (versionLt(desugarMatch[2], "2.1.5")) {
      content = content.replace(desugarRegex, `$12.1.5$3`);
      changed = true;
      ok(`android app gradle: desugar_jdk_libs ${desugarMatch[2]} → 2.1.5`);
    } else {
      skip(`android app gradle: desugar_jdk_libs already ${desugarMatch[2]}`);
    }
  } else {
    // Insert into the dependencies { } block
    const depAnchor = /(dependencies\s*\{\s*\n)/;
    if (depAnchor.test(content)) {
      content = content.replace(
        depAnchor,
        `$1    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.5")\n`,
      );
      changed = true;
      ok(`android app gradle: added desugar_jdk_libs 2.1.5`);
    } else {
      warn(`android app gradle: dependencies block not found, skipping desugar`);
    }
  }

  if (changed && !dryRun) writeFileSync(path, content);
}

// ---------- helpers ----------

function versionLt(a, b) {
  const av = a.split(".").map((n) => Number(n) || 0);
  const bv = b.split(".").map((n) => Number(n) || 0);
  for (let i = 0; i < Math.max(av.length, bv.length); i++) {
    const x = av[i] || 0;
    const y = bv[i] || 0;
    if (x < y) return true;
    if (x > y) return false;
  }
  return false;
}

// ---------- subcommands ----------

function bootstrapIosCaches(extraArgs) {
  const script = join(SCRIPT_DIR, "bootstrap-ios-caches.sh");
  if (!existsSync(script)) {
    console.error(`bootstrap-ios-caches.sh not found at ${script}`);
    process.exit(1);
  }
  execSync(`bash "${script}" ${extraArgs.join(" ")}`, { stdio: "inherit" });
}

function setupIos(tauriDir, dryRun) {
  console.log("\niOS");
  patchTauriConf(tauriDir, dryRun);
  if (patchProjectYml(tauriDir, dryRun)) {
    runXcodegen(tauriDir, dryRun);
  }
}

function setupAndroid(tauriDir, dryRun) {
  console.log("\nAndroid");
  patchBuildRs(tauriDir, dryRun);
  patchAndroidRootGradle(tauriDir, dryRun);
  patchAndroidAppGradle(tauriDir, dryRun);
}

const HELP = `Usage: tauri-plugin-rekognition-liveness <command> [flags]

Commands:
  setup [ios|android]    Patch the consumer Tauri project (default: both).
                         Idempotent — re-run after \`tauri ios init\` /
                         \`tauri android init\` to re-apply.
  bootstrap-ios-caches   Pre-populate SwiftPM caches before the first iOS
                         build so cargo doesn't full-clone aws-sdk-swift
                         (~5 GB) live. Pass-through flags accepted (see
                         scripts/bootstrap-ios-caches.sh --help).
  help                   Show this message.

Flags:
  --dry-run              Print intended edits without writing.
`;

function main() {
  const argv = process.argv.slice(2);
  const dryRun = argv.includes("--dry-run");
  const positional = argv.filter((a) => !a.startsWith("--"));
  const cmd = positional[0] || "setup";
  const sub = positional[1];

  if (cmd === "help" || cmd === "--help" || cmd === "-h") {
    console.log(HELP);
    return;
  }

  if (cmd === "bootstrap-ios-caches") {
    bootstrapIosCaches(argv.slice(1).filter((a) => a !== "--dry-run"));
    return;
  }

  if (cmd !== "setup") {
    console.error(`Unknown command: ${cmd}\n`);
    console.log(HELP);
    process.exit(1);
  }

  const tauriDir = findTauriDir(process.cwd());
  if (!tauriDir) {
    console.error(
      "Could not locate src-tauri/tauri.conf.json. Run from inside a Tauri project.",
    );
    process.exit(1);
  }
  console.log(`Tauri project: ${tauriDir}${dryRun ? " (dry-run)" : ""}`);

  if (sub === "ios") setupIos(tauriDir, dryRun);
  else if (sub === "android") setupAndroid(tauriDir, dryRun);
  else {
    setupIos(tauriDir, dryRun);
    setupAndroid(tauriDir, dryRun);
  }

  console.log("\nDone.");
}

main();
