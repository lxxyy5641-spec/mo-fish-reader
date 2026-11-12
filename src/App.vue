<script setup lang="ts">
import { computed, nextTick, onBeforeUnmount, onMounted, reactive, ref, watch } from "vue";
import { decodeText, fileNameFromPath, parseChapters, type TextEncoding } from "./lib/text";
import {
  loadProgress,
  loadSettings,
  makeBookId,
  saveProgress,
  saveSettings,
} from "./lib/storage";

const welcomeText = `Mo Fish Reader 1.0.0
Local terminal session initialized.

第1章 快速开始

点击右上角 OPEN，或在下方输入 /open，选择一个 TXT 文件。
阅读进度只保存在本机，不上传小说内容。

第2章 键盘操作

Space / PageDown    向下翻页
Shift+Space         向上翻页
[ / ]               上一章 / 下一章
Ctrl+P              聚焦命令行
Alt+\`               快速隐藏或恢复桌面窗口

输入 /help 可以查看全部命令。`;

const isTauri = Boolean(window.__TAURI_INTERNALS__);
const text = ref(welcomeText);
const fileName = ref("session-readme.txt");
const encoding = ref<TextEncoding | "DEMO">("DEMO");
const bookId = ref(makeBookId(fileName.value, text.value.length));
const progress = ref(0);
const reader = ref<HTMLElement | null>(null);
const fileInput = ref<HTMLInputElement | null>(null);
const commandInput = ref<HTMLInputElement | null>(null);
const command = ref("");
const sidebarOpen = ref(false);
const privacyMode = ref(false);
const statusMessage = ref("LOCAL SESSION");
const settings = reactive(loadSettings());
const chapters = computed(() => parseChapters(text.value));
let saveTimer: number | undefined;
let unregisterShortcut: (() => Promise<void>) | undefined;

const progressPercent = computed(() => `${(progress.value * 100).toFixed(1)}%`);
const currentChapterIndex = computed(() => {
  if (!chapters.value.length) return -1;
  const currentOffset = Math.floor(text.value.length * progress.value);
  let result = 0;
  for (let index = 0; index < chapters.value.length; index += 1) {
    if (chapters.value[index].offset > currentOffset) break;
    result = index;
  }
  return result;
});
const currentChapter = computed(() =>
  currentChapterIndex.value >= 0 ? chapters.value[currentChapterIndex.value].title : "NO INDEX",
);
const readerStyle = computed(() => ({
  fontSize: `${settings.fontSize}px`,
  lineHeight: String(settings.lineHeight),
}));

watch(settings, (value) => saveSettings({ ...value }), { deep: true });

function restoreScroll(): void {
  nextTick(() => {
    if (!reader.value) return;
    const maxScroll = Math.max(0, reader.value.scrollHeight - reader.value.clientHeight);
    reader.value.scrollTop = loadProgress(bookId.value) * maxScroll;
    updateProgress();
  });
}

function loadBytes(bytes: Uint8Array, name: string, modified = 0): void {
  const decoded = decodeText(bytes);
  text.value = decoded.text.replace(/\u0000/g, "");
  fileName.value = name;
  encoding.value = decoded.encoding;
  bookId.value = makeBookId(name, bytes.byteLength, modified);
  privacyMode.value = false;
  sidebarOpen.value = false;
  statusMessage.value = `${bytes.byteLength.toLocaleString()} BYTES LOADED`;
  restoreScroll();
}

async function openBook(): Promise<void> {
  if (!isTauri) {
    fileInput.value?.click();
    return;
  }

  try {
    const [{ open }, { readFile }] = await Promise.all([
      import("@tauri-apps/plugin-dialog"),
      import("@tauri-apps/plugin-fs"),
    ]);
    const selected = await open({
      multiple: false,
      directory: false,
      filters: [{ name: "Text", extensions: ["txt", "log", "md"] }],
    });
    if (!selected || Array.isArray(selected)) return;
    const bytes = await readFile(selected);
    loadBytes(bytes, fileNameFromPath(selected));
  } catch (error) {
    statusMessage.value = `OPEN ERROR: ${String(error)}`;
  }
}

async function onBrowserFile(event: Event): Promise<void> {
  const input = event.target as HTMLInputElement;
  const file = input.files?.[0];
  if (!file) return;
  loadBytes(new Uint8Array(await file.arrayBuffer()), file.name, file.lastModified);
  input.value = "";
}

async function onDrop(event: DragEvent): Promise<void> {
  const file = event.dataTransfer?.files[0];
  if (!file || !/\.(txt|log|md)$/i.test(file.name)) {
    statusMessage.value = "DROP A TXT / LOG / MD FILE";
    return;
  }
  loadBytes(new Uint8Array(await file.arrayBuffer()), file.name, file.lastModified);
}

function updateProgress(): void {
  if (!reader.value) return;
  const maxScroll = reader.value.scrollHeight - reader.value.clientHeight;
  progress.value = maxScroll > 0 ? reader.value.scrollTop / maxScroll : 0;
  window.clearTimeout(saveTimer);
  saveTimer = window.setTimeout(() => saveProgress(bookId.value, progress.value), 180);
}

function scrollPage(direction: 1 | -1): void {
  reader.value?.scrollBy({
    top: direction * (reader.value.clientHeight * 0.86),
    behavior: "smooth",
  });
}

function goToChapter(index: number): void {
  const chapter = chapters.value[index];
  if (!chapter || !reader.value) return;
  const ratio = chapter.offset / Math.max(1, text.value.length);
  const maxScroll = reader.value.scrollHeight - reader.value.clientHeight;
  reader.value.scrollTo({ top: ratio * maxScroll, behavior: "smooth" });
  sidebarOpen.value = false;
}

function jumpChapter(delta: number): void {
  if (!chapters.value.length) return;
  const next = Math.min(
    chapters.value.length - 1,
    Math.max(0, currentChapterIndex.value + delta),
  );
  goToChapter(next);
}

function cycleTheme(): void {
  const themes = ["ssh", "powershell", "paper"] as const;
  settings.theme = themes[(themes.indexOf(settings.theme) + 1) % themes.length];
  statusMessage.value = `THEME: ${settings.theme.toUpperCase()}`;
}

async function currentWindow() {
  const { getCurrentWindow } = await import("@tauri-apps/api/window");
  return getCurrentWindow();
}

async function quickHide(): Promise<void> {
  if (!isTauri) {
    privacyMode.value = !privacyMode.value;
    return;
  }
  await (await currentWindow()).hide();
}

async function windowAction(action: "minimize" | "maximize" | "close"): Promise<void> {
  if (!isTauri) return;
  const window = await currentWindow();
  if (action === "minimize") await window.minimize();
  if (action === "maximize") await window.toggleMaximize();
  if (action === "close") await window.close();
}

function showHelp(): void {
  statusMessage.value = "/open /chapter N /theme NAME /font N /line N /clear /resume";
}

async function runCommand(): Promise<void> {
  const value = command.value.trim();
  command.value = "";
  if (!value) return;

  const [rawName, ...args] = value.split(/\s+/);
  const name = rawName.toLowerCase();

  if (name === "/open") return openBook();
  if (name === "/help") return showHelp();
  if (name === "/clear") {
    privacyMode.value = true;
    statusMessage.value = "OUTPUT CLEARED";
    return;
  }
  if (name === "/resume") {
    privacyMode.value = false;
    statusMessage.value = "SESSION RESTORED";
    return;
  }
  if (name === "/theme") {
    if (["ssh", "powershell", "paper"].includes(args[0])) {
      settings.theme = args[0] as typeof settings.theme;
      statusMessage.value = `THEME: ${args[0].toUpperCase()}`;
    } else cycleTheme();
    return;
  }
  if (name === "/font") {
    const size = Number(args[0]);
    if (size >= 12 && size <= 30) settings.fontSize = size;
    statusMessage.value = `FONT: ${settings.fontSize}px`;
    return;
  }
  if (name === "/line") {
    const height = Number(args[0]);
    if (height >= 1.2 && height <= 2.8) settings.lineHeight = height;
    statusMessage.value = `LINE HEIGHT: ${settings.lineHeight}`;
    return;
  }
  if (name === "/chapter") {
    const index = Number(args[0]) - 1;
    if (Number.isInteger(index)) goToChapter(index);
    return;
  }

  statusMessage.value = `COMMAND NOT FOUND: ${rawName}`;
}

function onGlobalKey(event: KeyboardEvent): void {
  const target = event.target as HTMLElement;
  const isTyping = target.tagName === "INPUT";
  if (event.ctrlKey && event.key.toLowerCase() === "p") {
    event.preventDefault();
    commandInput.value?.focus();
    return;
  }
  if (isTyping) return;
  if (event.code === "Space") {
    event.preventDefault();
    scrollPage(event.shiftKey ? -1 : 1);
  }
  if (event.key === "PageDown") scrollPage(1);
  if (event.key === "PageUp") scrollPage(-1);
  if (event.key === "]") jumpChapter(1);
  if (event.key === "[") jumpChapter(-1);
  if (event.key === "Escape") privacyMode.value = true;
}

async function registerQuickHide(): Promise<void> {
  if (!isTauri) return;
  try {
    const { register, unregister } = await import("@tauri-apps/plugin-global-shortcut");
    const shortcut = "Alt+Backquote";
    await register(shortcut, async (event) => {
      if (event.state !== "Pressed") return;
      const window = await currentWindow();
      if (await window.isVisible()) await window.hide();
      else {
        await window.show();
        await window.setFocus();
      }
    });
    unregisterShortcut = () => unregister(shortcut);
  } catch {
    statusMessage.value = "GLOBAL SHORTCUT UNAVAILABLE";
  }
}

onMounted(() => {
  window.addEventListener("keydown", onGlobalKey);
  registerQuickHide();
});

onBeforeUnmount(() => {
  window.removeEventListener("keydown", onGlobalKey);
  window.clearTimeout(saveTimer);
  unregisterShortcut?.();
});
</script>

<template>
  <div
    class="terminal"
    :data-theme="settings.theme"
    @dragover.prevent
    @drop.prevent="onDrop"
  >
    <header class="titlebar" data-tauri-drag-region>
      <div class="session-title" data-tauri-drag-region>
        <span class="terminal-mark">›_</span>
        <span>workspace-console — {{ fileName }}</span>
      </div>
      <div class="window-actions">
        <button aria-label="最小化" @click="windowAction('minimize')">—</button>
        <button aria-label="最大化" @click="windowAction('maximize')">□</button>
        <button class="close" aria-label="关闭" @click="windowAction('close')">×</button>
      </div>
    </header>

    <div class="app-shell">
      <aside v-if="sidebarOpen" class="chapter-panel">
        <div class="panel-heading">
          <span>INDEX / {{ chapters.length }}</span>
          <button @click="sidebarOpen = false">×</button>
        </div>
        <button
          v-for="(chapter, index) in chapters"
          :key="`${chapter.offset}-${chapter.title}`"
          class="chapter-item"
          :class="{ active: index === currentChapterIndex }"
          @click="goToChapter(index)"
        >
          <span>{{ String(index + 1).padStart(3, "0") }}</span>
          {{ chapter.title }}
        </button>
        <p v-if="!chapters.length" class="empty-index">No chapter pattern matched.</p>
      </aside>

      <main class="console-pane">
        <nav class="hover-tools" aria-label="阅读工具">
          <button @click="openBook">OPEN</button>
          <button @click="sidebarOpen = !sidebarOpen">INDEX</button>
          <button @click="settings.fontSize = Math.max(12, settings.fontSize - 1)">A−</button>
          <button @click="settings.fontSize = Math.min(30, settings.fontSize + 1)">A+</button>
          <button @click="cycleTheme">THEME</button>
          <button @click="quickHide">HIDE</button>
        </nav>

        <div class="content-split" :class="{ 'privacy-active': privacyMode }">
          <section class="work-pane" aria-label="PowerShell 工作输出">
            <div class="pane-tabbar">
              <span class="active">PowerShell</span>
              <span>OUTPUT</span>
              <span>PROBLEMS</span>
            </div>
            <div class="work-output">
              <p><span class="prompt">PS C:\workspace\client&gt;</span> git status --short</p>
              <p class="muted"> M src\services\reader.ts</p>
              <p class="muted"> M src\components\Workspace.vue</p>
              <p class="muted">?? tests\reader.spec.ts</p>
              <p class="work-gap"><span class="prompt">PS C:\workspace\client&gt;</span> npm run check</p>
              <p class="muted">&gt; workspace-client@2.4.0 check</p>
              <p class="muted">&gt; tsc --noEmit &amp;&amp; vitest run</p>
              <p class="work-gap"> RUN <span class="muted">v3.2.1 C:/workspace/client</span></p>
              <p class="ok"> ✓ tests/config.spec.ts <span class="muted">(8 tests) 36ms</span></p>
              <p class="ok"> ✓ tests/parser.spec.ts <span class="muted">(14 tests) 71ms</span></p>
              <p class="ok"> ✓ tests/reader.spec.ts <span class="muted">(6 tests) 42ms</span></p>
              <div class="test-summary">
                <p><span class="ok">Test Files</span> 3 passed (3)</p>
                <p><span class="ok">Tests</span> 28 passed (28)</p>
                <p><span class="muted">Duration</span> 1.24s</p>
              </div>
              <p class="work-gap"><span class="prompt">PS C:\workspace\client&gt;</span> Get-ChildItem .\src -Recurse</p>
              <div class="tree-output muted">
                <p>src</p>
                <p>├── components</p>
                <p>│&nbsp;&nbsp; ├── CommandBar.vue</p>
                <p>│&nbsp;&nbsp; ├── StatusPanel.vue</p>
                <p>│&nbsp;&nbsp; └── Workspace.vue</p>
                <p>├── services</p>
                <p>│&nbsp;&nbsp; ├── config.ts</p>
                <p>│&nbsp;&nbsp; └── reader.ts</p>
                <p>└── main.ts</p>
              </div>
              <p class="work-gap"><span class="prompt">PS C:\workspace\client&gt;</span> <span class="terminal-caret"></span></p>
              <button v-if="privacyMode" class="resume-link" @click="privacyMode = false">
                restore previous pane
              </button>
            </div>
          </section>

          <section
            ref="reader"
            class="reader reader-pane"
            :style="readerStyle"
            tabindex="0"
            @scroll.passive="updateProgress"
          >
            <div class="reader-tabbar">
              <span class="active">TERMINAL</span>
              <span>OUTPUT</span>
              <span>DEBUG CONSOLE</span>
              <span>PORTS</span>
              <span class="reader-process">pwsh</span>
            </div>
            <div class="reader-content">
              <p class="prompt-line">
                <span class="prompt">PS C:\workspace\docs&gt;</span> Get-Content {{ fileName }}
              </p>
              <article class="book-text">{{ text }}</article>
              <p class="eof">[EOF]</p>
            </div>
          </section>
        </div>

        <footer class="statusbar">
          <span>{{ encoding }}</span>
          <span>{{ privacyMode ? "FOCUS: OUTPUT" : "SPLIT 68/32" }}</span>
          <span class="chapter-status" :title="currentChapter">{{ currentChapter }}</span>
          <span>{{ progressPercent }}</span>
          <span>{{ statusMessage }}</span>
        </footer>

        <form class="commandbar" @submit.prevent="runCommand">
          <span class="prompt">reader&gt;</span>
          <input
            ref="commandInput"
            v-model="command"
            aria-label="阅读器命令"
            autocomplete="off"
            spellcheck="false"
            placeholder="/help"
          />
          <span class="cursor" aria-hidden="true"></span>
        </form>
      </main>
    </div>

    <input
      ref="fileInput"
      class="hidden-input"
      type="file"
      accept=".txt,.log,.md,text/plain"
      @change="onBrowserFile"
    />
  </div>
</template>
