import { invoke as tauriInvoke } from "@tauri-apps/api/core";

export function isTauri(): boolean {
  return typeof window !== "undefined" && !!(window as unknown as { __TAURI_INTERNALS__?: unknown }).__TAURI_INTERNALS__;
}

let cachedProxyPort = 13370;

export function setProxyPort(port: number): void {
  cachedProxyPort = port;
}

export function apiOrigin(): string {
  return isTauri() ? `http://127.0.0.1:${cachedProxyPort}` : "";
}

export async function invoke<T>(cmd: string, args: Record<string, unknown> = {}): Promise<T> {
  return tauriInvoke<T>(cmd, args);
}
