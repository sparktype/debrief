// hook 이벤트 분류 및 처리 함수 — post-tool-bash / pre-tool-bash / notification
import { speakHook } from "./player.js";
import type { VoicePersonaConfig } from "./config.js";

type SpeakConfig = Pick<VoicePersonaConfig, "autoSpeak" | "voice" | "ttsSpeed">;

/**
 * post-tool-bash 이벤트에서 TTS 메시지를 생성하는 순수 함수
 * 반환값이 null이면 발화 없음
 */
export function classifyPostToolBash(
  cmd: string,
  output: string,
  exitCode: number,
): string | null {
  if (/npm run build|tsc\b|cargo build|go build/.test(cmd)) {
    return exitCode === 0 ? "빌드 완료." : "빌드 실패. 에러를 확인하세요.";
  }
  if (/npm\s+test|vitest|pytest|cargo\s+test|go\s+test/.test(cmd)) {
    const passed = output.match(/(\d+)\s*(passed|passing)/)?.[1];
    const failed = output.match(/(\d+)\s*(failed|failing)/)?.[1];
    if (failed && parseInt(failed, 10) > 0) {
      return `테스트 ${failed}개 실패${passed ? `, ${passed}개 통과` : ""}.`;
    }
    if (passed) return `전체 ${passed}개 통과.`;
    return null;
  }
  if (exitCode !== 0) {
    const snippet = cmd.split(/\s+/).slice(0, 3).join(" ");
    return `명령 실패: ${snippet}.`;
  }
  return null;
}

/**
 * pre-tool-bash 이벤트에서 TTS 메시지를 생성하는 순수 함수
 * 반환값이 null이면 발화 없음
 */
export function classifyPreToolBash(cmd: string): string | null {
  if (/rm\s+-rf|git\s+reset\s+--hard|DROP\s+TABLE/.test(cmd)) {
    return "주의: 되돌릴 수 없는 작업입니다.";
  }
  if (/npm run build|tsc\b|cargo build|go build/.test(cmd)) {
    return "빌드를 시작합니다.";
  }
  if (/npm\s+test|vitest|pytest|cargo\s+test|go\s+test/.test(cmd)) {
    return "테스트를 실행합니다.";
  }
  if (/npm\s+install|npm\s+ci|pip\s+install|uv\s+sync/.test(cmd)) {
    return "패키지를 설치합니다.";
  }
  return null;
}

/** post-tool-bash raw JSON을 파싱해 speakHook 호출 */
export async function handlePostToolBash(
  raw: string,
  config: SpeakConfig,
): Promise<void> {
  const data = JSON.parse(raw) as {
    tool_input?: { command?: string };
    tool_response?: { output?: string; exitCode?: number; exit_code?: number };
  };
  const cmd = data.tool_input?.command ?? "";
  const resp = data.tool_response ?? {};
  const out = (resp as Record<string, unknown>).output as string ?? "";
  const code: number =
    (resp as Record<string, unknown>).exitCode as number ??
    (resp as Record<string, unknown>).exit_code as number ??
    0;

  if (!config.autoSpeak) return;

  const msg = classifyPostToolBash(cmd, out, code);
  if (msg) await speakHook(msg, config.voice, config.ttsSpeed).catch(() => {});
}

/** pre-tool-bash raw JSON을 파싱해 speakHook 호출 */
export async function handlePreToolBash(
  raw: string,
  config: SpeakConfig,
): Promise<void> {
  const data = JSON.parse(raw) as { tool_input?: { command?: string } };
  const cmd = data.tool_input?.command ?? "";
  if (!config.autoSpeak || !cmd) return;

  const msg = classifyPreToolBash(cmd);
  if (msg) await speakHook(msg, config.voice, config.ttsSpeed).catch(() => {});
}

/** notification raw JSON을 파싱해 speakHook 호출 */
export async function handleNotification(
  raw: string,
  config: SpeakConfig,
): Promise<void> {
  const data = JSON.parse(raw) as { title?: string; message?: string };
  const msg = data.message ?? data.title ?? "";
  if (msg && config.autoSpeak) {
    await speakHook(msg, config.voice, config.ttsSpeed).catch(() => {});
  }
}
