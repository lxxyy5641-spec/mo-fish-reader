export interface ReaderSettings {
  fontSize: number;
  lineHeight: number;
  theme: "powershell" | "ssh" | "paper";
}

const SETTINGS_KEY = "fish-reader:settings";

export const defaultSettings: ReaderSettings = {
  fontSize: 17,
  lineHeight: 1.9,
  theme: "ssh",
};

export function loadSettings(): ReaderSettings {
  try {
    const saved = JSON.parse(localStorage.getItem(SETTINGS_KEY) || "{}") as Partial<ReaderSettings>;
    return { ...defaultSettings, ...saved };
  } catch {
    return { ...defaultSettings };
  }
}

export function saveSettings(settings: ReaderSettings): void {
  localStorage.setItem(SETTINGS_KEY, JSON.stringify(settings));
}

export function makeBookId(name: string, size: number, modified = 0): string {
  return `${name}:${size}:${modified}`;
}

export function loadProgress(bookId: string): number {
  const value = Number(localStorage.getItem(`fish-reader:progress:${bookId}`));
  return Number.isFinite(value) ? Math.min(1, Math.max(0, value)) : 0;
}

export function saveProgress(bookId: string, progress: number): void {
  localStorage.setItem(`fish-reader:progress:${bookId}`, String(progress));
}
