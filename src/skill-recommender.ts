// 사용자 transcript 분석 → HMG LLM → 스킬 추천 + 쿨다운 관리
import { readFileSync, writeFileSync, existsSync, mkdirSync, readdirSync, statSync } from "fs";
import { homedir } from "os";
import { join, dirname } from "path";
import { fileURLToPath } from "url";
import OpenAI from "openai";

const __dirname = dirname(fileURLToPath(import.meta.url));

const HUB_BASE_URL = process.env.HUB_BASE_URL ?? "https://internal-apigw-kr.hmg-corp.io/hchat-in/api/v3";
const HUB_API_KEY  = process.env.HUB_API_KEY  ?? "";
const HUB_PROJECT_ID = process.env.HUB_PROJECT_ID ?? "";
const CATALOG_FILE = join(__dirname, "..", "skills-catalog.json");

function getDataDir(): string {
  return process.env.SIREN_DATA_DIR ?? join(homedir(), ".local", "share", "summary-voice-mcp");
}

function getCooldownsFile(): string {
  return join(getDataDir(), "skill-cooldowns.json");
}

export interface SkillEntry {
  skill: string;
  description: string;
}

export interface Recommendation {
  skill: string;
  reason: string;
}

export function parseCatalog(raw: string): SkillEntry[] {
  try {
    const arr = JSON.parse(raw);
    if (!Array.isArray(arr)) return [];
    return arr;
  } catch {
    return [];
  }
}

export function parseRecommendation(raw: string, catalog: SkillEntry[]): Recommendation | null {
  try {
    const rec = JSON.parse(raw);
    if (!rec?.skill) return null;
    if (!catalog.some((s) => s.skill === rec.skill)) return null;
    return { skill: rec.skill, reason: rec.reason ?? "" };
  } catch {
    return null;
  }
}

export function loadCatalog(): SkillEntry[] {
  try {
    return parseCatalog(readFileSync(CATALOG_FILE, "utf-8"));
  } catch {
    return [];
  }
}

export function readRecentTranscripts(
  transcriptsDir = join(homedir(), ".claude", "transcripts"),
  maxFiles = 3,
  maxLinesPerFile = 50
): string {
  try {
    if (!existsSync(transcriptsDir)) return "";
    const files = readdirSync(transcriptsDir)
      .filter((f) => f.endsWith(".jsonl"))
      .map((f) => ({ name: f, mtime: statSync(join(transcriptsDir, f)).mtimeMs }))
      .sort((a, b) => b.mtime - a.mtime)
      .slice(0, maxFiles)
      .map((f) => f.name);

    return files
      .map((file) => {
        const lines = readFileSync(join(transcriptsDir, file), "utf-8")
          .split("\n")
          .filter(Boolean)
          .slice(-maxLinesPerFile);
        return lines
          .map((line) => {
            try {
              const entry = JSON.parse(line);
              const content = String(entry.content ?? "").slice(0, 300);
              if (entry.type === "user") return `User: ${content}`;
              if (entry.type === "assistant") return `Assistant: ${content}`;
              return null;
            } catch {
              return null;
            }
          })
          .filter(Boolean)
          .join("\n");
      })
      .join("\n---\n");
  } catch {
    return "";
  }
}

export function loadCooldowns(): Record<string, string> {
  try {
    if (!existsSync(getCooldownsFile())) return {};
    return JSON.parse(readFileSync(getCooldownsFile(), "utf-8"));
  } catch {
    return {};
  }
}

export function saveCooldown(skill: string): void {
  try {
    const dir = getDataDir();
    if (!existsSync(dir)) mkdirSync(dir, { recursive: true });
    const cooldowns = loadCooldowns();
    cooldowns[skill] = new Date().toISOString();
    writeFileSync(getCooldownsFile(), JSON.stringify(cooldowns, null, 2), "utf-8");
  } catch { /* silent fail */ }
}

export function isInCooldown(
  skill: string,
  cooldowns: Record<string, string>,
  cooldownMinutes: number
): boolean {
  const last = cooldowns[skill];
  if (!last) return false;
  const elapsedMin = (Date.now() - new Date(last).getTime()) / 60000;
  return elapsedMin < cooldownMinutes;
}

export async function recommendSkill(
  context: string,
  bypassCooldown = false,
  cooldownMinutes = 30
): Promise<Recommendation | null> {
  const catalog = loadCatalog();
  if (catalog.length === 0 || !context.trim()) return null;

  const skillsText = catalog.map((s) => `- ${s.skill}: ${s.description}`).join("\n");
  const prompt =
    `다음은 Claude Code 대화 히스토리 일부입니다:\n<transcript>\n${context}\n</transcript>\n\n` +
    `다음은 사용 가능한 스킬 목록입니다:\n<skills>\n${skillsText}\n</skills>\n\n` +
    `위 맥락을 보고, 지금 작업에 가장 유용한 스킬 1개를 선택하세요.\n` +
    `반드시 아래 JSON 형식으로만 응답하세요. 다른 텍스트는 포함하지 마세요.\n` +
    `{"skill": "<스킬명>", "reason": "<한 문장 이유>"}`;

  try {
    const extraHeaders: Record<string, string> = {};
    if (HUB_PROJECT_ID) extraHeaders["X-Project-Id"] = HUB_PROJECT_ID;
    const client = new OpenAI({
      apiKey: HUB_API_KEY,
      baseURL: `${HUB_BASE_URL}/openai/deployments/gpt-5.4`,
      defaultHeaders: extraHeaders,
    });

    const resp = await client.chat.completions.create({
      model: "gpt-5.4",
      messages: [{ role: "user", content: prompt }],
      max_completion_tokens: 100,
      temperature: 0.2,
    });

    const raw = resp.choices[0]?.message?.content?.trim() ?? "";
    const rec = parseRecommendation(raw, catalog);
    if (!rec) return null;

    if (!bypassCooldown && isInCooldown(rec.skill, loadCooldowns(), cooldownMinutes)) return null;

    return rec;
  } catch {
    return null;
  }
}
