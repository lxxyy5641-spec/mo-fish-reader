export type TextEncoding = "UTF-8" | "UTF-16LE" | "UTF-16BE" | "GB18030";

export interface DecodedText {
  text: string;
  encoding: TextEncoding;
}

function decodeUtf16Be(bytes: Uint8Array): string {
  const swapped = new Uint8Array(bytes.length);
  for (let index = 0; index + 1 < bytes.length; index += 2) {
    swapped[index] = bytes[index + 1];
    swapped[index + 1] = bytes[index];
  }
  return new TextDecoder("utf-16le").decode(swapped);
}

export function decodeText(bytes: Uint8Array): DecodedText {
  if (bytes[0] === 0xef && bytes[1] === 0xbb && bytes[2] === 0xbf) {
    return { text: new TextDecoder("utf-8").decode(bytes.subarray(3)), encoding: "UTF-8" };
  }

  if (bytes[0] === 0xff && bytes[1] === 0xfe) {
    return { text: new TextDecoder("utf-16le").decode(bytes.subarray(2)), encoding: "UTF-16LE" };
  }

  if (bytes[0] === 0xfe && bytes[1] === 0xff) {
    return { text: decodeUtf16Be(bytes.subarray(2)), encoding: "UTF-16BE" };
  }

  try {
    return {
      text: new TextDecoder("utf-8", { fatal: true }).decode(bytes),
      encoding: "UTF-8",
    };
  } catch {
    return {
      text: new TextDecoder("gb18030").decode(bytes),
      encoding: "GB18030",
    };
  }
}

export interface Chapter {
  title: string;
  offset: number;
}

const chapterPattern = /^\s*(第[零〇一二三四五六七八九十百千万两\d]+[章节卷回部篇](?:\s+|[:：、.-])?.{0,45})\s*$/gm;

export function parseChapters(text: string): Chapter[] {
  const chapters: Chapter[] = [];
  for (const match of text.matchAll(chapterPattern)) {
    chapters.push({ title: match[1].trim(), offset: match.index ?? 0 });
  }
  return chapters;
}

export function fileNameFromPath(path: string): string {
  return path.split(/[\\/]/).pop() || "untitled.txt";
}
