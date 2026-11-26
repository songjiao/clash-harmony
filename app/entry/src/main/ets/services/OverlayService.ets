import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { fileIo } from '@kit.CoreFileKit';
import { http } from '@kit.NetworkKit';
import { ClashProfile, createLocalProfile, createRemoteProfile, ProfileState } from '../models/Profile';
import { ProfileStore } from './ProfileStore';
import { TailscaleNativePrefs, TailscalePrefsService } from './TailscalePrefsService';

export interface AiProviderPreset {
  id: string;
  label: string;
  subtitle: string;
  domains: string[];
  keywords: string[];
}

export interface CustomOverlayConfig {
  enabled: boolean;
  selfHostedGroupName: string;
  failClosed: boolean;
  aiStrictEnabled: boolean;
  aiProviders: string[];
  aiDomains: string[];
  aiKeywords: string[];
  customProxiesYaml: string;
  customRules: string[];
  directDomains: string[];
}

export interface ParsedCustomProxies {
  names: string[];
  servers: string[];
  blocks: string[][];
}

export interface BackupImportResult {
  ok: boolean;
  message: string;
  importedProfiles: number;
  importedProfileUid: string;
  activated: boolean;
}

export const DEFAULT_AI_GROUP_NAME: string = '🛡️ AI严格自建';

export function getAllAiProviderPresets(): AiProviderPreset[] {
  return [
    {
      id: 'claude',
      label: 'Claude',
      subtitle: 'Anthropic / Claude.ai / Claude Code',
      domains: ['anthropic.com', 'claude.ai', 'claude.com', 'claudeusercontent.com', 'statsig.anthropic.com'],
      keywords: ['anthropic', 'claude']
    },
    {
      id: 'gemini',
      label: 'Gemini / Antigravity',
      subtitle: 'Gemini / AI Studio / Antigravity / Google AI',
      domains: [
        'gemini.google.com',
        'aistudio.google.com',
        'makersuite.google.com',
        'generativelanguage.googleapis.com',
        'ai.google.dev',
        'deepmind.google',
        'labs.google',
        'jules.google.com',
        'notebooklm.google.com',
        'antigravity.google',
        'antigravity.google.com',
        'cloudcode-pa.googleapis.com',
        'daily-cloudcode-pa.googleapis.com',
        'daily-cloudcode-pa.sandbox.googleapis.com',
        'autopush-cloudcode-pa.sandbox.googleapis.com',
        'proactivebackend-pa.googleapis.com',
        'aisandbox-pa.googleapis.com',
        'oauth2.googleapis.com',
        'accounts.google.com'
      ],
      keywords: []
    },
    {
      id: 'openai',
      label: 'OpenAI / ChatGPT',
      subtitle: 'ChatGPT / API / Sora / Codex',
      domains: ['openai.com', 'chatgpt.com', 'oaistatic.com', 'oaiusercontent.com', 'sora.com'],
      keywords: []
    },
    {
      id: 'cursor',
      label: 'Cursor / Copilot',
      subtitle: 'Cursor IDE / GitHub Copilot / Codeium',
      domains: ['cursor.sh', 'cursor.com', 'githubcopilot.com', 'copilot.github.com', 'copilot-proxy.githubusercontent.com', 'codeium.com'],
      keywords: []
    },
    {
      id: 'xai',
      label: 'Grok / xAI',
      subtitle: 'x.ai / grok.com',
      domains: ['x.ai', 'grok.com'],
      keywords: []
    },
    {
      id: 'other_ai',
      label: '其他 AI',
      subtitle: 'Perplexity / OpenRouter / Groq / Mistral / Poe / HF',
      domains: [
        'perplexity.ai',
        'poe.com',
        'openrouter.ai',
        'groq.com',
        'mistral.ai',
        'cohere.ai',
        'cohere.com',
        'huggingface.co',
        'hf.co',
        'copilot.microsoft.com',
        'openai.azure.com',
        'cognitiveservices.azure.com',
        'api.cognitive.microsoft.com',
        'midjourney.com',
        'suno.com',
        'runwayml.com',
        'elevenlabs.io'
      ],
      keywords: []
    }
  ];
}

export function getDefaultAiProviderIds(): string[] {
  const presets: AiProviderPreset[] = getAllAiProviderPresets();
  const ids: string[] = [];
  for (let i = 0; i < presets.length; i++) {
    ids.push(presets[i].id);
  }
  return ids;
}

export function createDefaultOverlayConfig(): CustomOverlayConfig {
  return {
    enabled: false,
    selfHostedGroupName: DEFAULT_AI_GROUP_NAME,
    failClosed: true,
    aiStrictEnabled: true,
    aiProviders: getDefaultAiProviderIds(),
    aiDomains: [],
    aiKeywords: [],
    customProxiesYaml: '',
    customRules: [],
    directDomains: []
  };
}

export class OverlayService {
  static getOverlayPath(context: common.Context): string {
    return `${context.filesDir}/runtime/overlay.json`;
  }

  static async load(context: common.Context): Promise<CustomOverlayConfig> {
    const defaults: CustomOverlayConfig = createDefaultOverlayConfig();
    const path: string = OverlayService.getOverlayPath(context);
    try {
      if (!(await fileIo.access(path))) {
        return defaults;
      }
      const raw: string = await fileIo.readText(path);
      if (raw.trim().length === 0) {
        return defaults;
      }
      const parsed = JSON.parse(raw) as Record<string, Object>;
      if (!parsed) {
        return defaults;
      }
      return OverlayService.parseConfigObj(parsed, defaults);
    } catch (_err) {
      return defaults;
    }
  }

  static async save(context: common.Context, cfg: CustomOverlayConfig): Promise<boolean> {
    const dir: string = `${context.filesDir}/runtime`;
    try {
      await fileIo.mkdir(dir, true);
    } catch (_err) {
    }
    const normalized: CustomOverlayConfig = OverlayService.normalizeConfig(cfg);
    const path: string = OverlayService.getOverlayPath(context);
    let file: fileIo.File | undefined = undefined;
    try {
      file = fileIo.openSync(path, fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
      await fileIo.write(file.fd, JSON.stringify(normalized, null, 2));
      return true;
    } catch (_err) {
      return false;
    } finally {
      if (file) {
        try {
          fileIo.closeSync(file);
        } catch (_closeErr) {
        }
      }
    }
  }

  static normalizeConfig(cfg: CustomOverlayConfig): CustomOverlayConfig {
    const groupName: string = cfg.selfHostedGroupName.trim().length > 0 ? cfg.selfHostedGroupName.trim() : DEFAULT_AI_GROUP_NAME;
    const validIds: Record<string, boolean> = {};
    const presets: AiProviderPreset[] = getAllAiProviderPresets();
    for (let i = 0; i < presets.length; i++) {
      validIds[presets[i].id] = true;
    }
    const cleanProviders: string[] = [];
    const seenProviders: Record<string, boolean> = {};
    for (let i = 0; i < cfg.aiProviders.length; i++) {
      const id: string = cfg.aiProviders[i].trim().toLowerCase();
      if (validIds[id] && !seenProviders[id]) {
        seenProviders[id] = true;
        cleanProviders.push(id);
      }
    }
    return {
      enabled: cfg.enabled,
      selfHostedGroupName: groupName,
      failClosed: cfg.failClosed,
      aiStrictEnabled: cfg.aiStrictEnabled,
      aiProviders: cleanProviders,
      aiDomains: OverlayService.cleanDomainList(cfg.aiDomains),
      aiKeywords: OverlayService.cleanStringList(cfg.aiKeywords),
      customProxiesYaml: cfg.customProxiesYaml,
      customRules: OverlayService.cleanStringList(cfg.customRules),
      directDomains: OverlayService.cleanDomainList(cfg.directDomains)
    };
  }

  /**
   * Parses self-hosted proxies from either Clash YAML blocks OR share URIs
   * (vless://, trojan://, ss://, vmess://, hy2://, hysteria2://).
   */
  static parseCustomProxiesYaml(snippet: string): ParsedCustomProxies {
    const trimmed: string = snippet.trim();
    if (trimmed.length === 0) {
      return { names: [], servers: [], blocks: [] };
    }
    const normalizedYaml: string = OverlayService.looksLikeShareUris(trimmed)
      ? OverlayService.convertShareUrisToYaml(trimmed)
      : trimmed;
    return OverlayService.parseYamlBlocksOnly(normalizedYaml);
  }

  private static looksLikeShareUris(text: string): boolean {
    const lines: string[] = text.replace(/\r\n/g, '\n').split('\n');
    for (let i = 0; i < lines.length; i++) {
      const l: string = lines[i].trim().toLowerCase();
      if (l.length === 0 || l.startsWith('#')) {
        continue;
      }
      return l.startsWith('vless://') ||
        l.startsWith('trojan://') ||
        l.startsWith('ss://') ||
        l.startsWith('vmess://') ||
        l.startsWith('hy2://') ||
        l.startsWith('hysteria2://');
    }
    return false;
  }

  private static convertShareUrisToYaml(text: string): string {
    const lines: string[] = text.replace(/\r\n/g, '\n').split('\n');
    const yamlLines: string[] = [];
    let idx: number = 0;
    for (let i = 0; i < lines.length; i++) {
      const line: string = lines[i].trim();
      if (line.length === 0 || line.startsWith('#')) {
        continue;
      }
      idx++;
      const lower: string = line.toLowerCase();
      let block: string[] = [];
      if (lower.startsWith('vless://')) {
        block = OverlayService.parseVlessUriToLines(line, idx);
      } else if (lower.startsWith('trojan://')) {
        block = OverlayService.parseTrojanUriToLines(line, idx);
      } else if (lower.startsWith('ss://')) {
        block = OverlayService.parseSsUriToLines(line, idx);
      } else if (lower.startsWith('vmess://')) {
        block = OverlayService.parseVmessUriToLines(line, idx);
      } else if (lower.startsWith('hy2://') || lower.startsWith('hysteria2://')) {
        block = OverlayService.parseHy2UriToLines(line, idx);
      }
      for (let j = 0; j < block.length; j++) {
        yamlLines.push(block[j]);
      }
    }
    return yamlLines.join('\n');
  }

  private static parseQueryParams(query: string): Record<string, string> {
    const out: Record<string, string> = {};
    if (query.length === 0) {
      return out;
    }
    const parts: string[] = query.split('&');
    for (let i = 0; i < parts.length; i++) {
      const eq: number = parts[i].indexOf('=');
      if (eq <= 0) {
        continue;
      }
      const k: string = parts[i].substring(0, eq).trim();
      const v: string = OverlayService.safeDecode(parts[i].substring(eq + 1).trim());
      out[k] = v;
    }
    return out;
  }

  private static safeDecode(raw: string): string {
    try {
      return decodeURIComponent(raw.replace(/\+/g, ' '));
    } catch (_err) {
      return raw;
    }
  }

  private static parseHostPort(rawHostPort: string, defaultPort: number): string[] {
    let host: string = rawHostPort.trim();
    let portStr: string = `${defaultPort}`;
    const slashIdx: number = host.indexOf('/');
    if (slashIdx >= 0) {
      host = host.substring(0, slashIdx);
    }
    if (host.startsWith('[')) {
      const endBracket: number = host.indexOf(']');
      if (endBracket > 0) {
        const rest: string = host.substring(endBracket + 1);
        host = host.substring(1, endBracket);
        if (rest.startsWith(':') && rest.length > 1) {
          portStr = rest.substring(1);
        }
      }
    } else {
      const colonIdx: number = host.lastIndexOf(':');
      if (colonIdx > 0) {
        portStr = host.substring(colonIdx + 1);
        host = host.substring(0, colonIdx);
      }
    }
    return [host, portStr];
  }

  private static splitUriParts(raw: string, prefixLen: number): string[] {
    let body: string = raw.substring(prefixLen);
    let fragment: string = '';
    const hashIdx: number = body.indexOf('#');
    if (hashIdx >= 0) {
      fragment = OverlayService.safeDecode(body.substring(hashIdx + 1).trim());
      body = body.substring(0, hashIdx);
    }
    let query: string = '';
    const qIdx: number = body.indexOf('?');
    if (qIdx >= 0) {
      query = body.substring(qIdx + 1);
      body = body.substring(0, qIdx);
    }
    return [body, query, fragment];
  }

  private static parseVlessUriToLines(raw: string, idx: number): string[] {
    const parts: string[] = OverlayService.splitUriParts(raw, 8);
    const body: string = parts[0];
    const params: Record<string, string> = OverlayService.parseQueryParams(parts[1]);
    const name: string = parts[2].length > 0 ? parts[2] : `自建-VLESS-${idx}`;
    const atIdx: number = body.indexOf('@');
    if (atIdx <= 0) {
      return [];
    }
    const uuid: string = body.substring(0, atIdx).trim();
    const hp: string[] = OverlayService.parseHostPort(body.substring(atIdx + 1), 443);
    const lines: string[] = [
      `- name: ${OverlayService.quoteYaml(name)}`,
      `  type: vless`,
      `  server: ${OverlayService.quoteYaml(hp[0])}`,
      `  port: ${hp[1]}`,
      `  uuid: ${OverlayService.quoteYaml(uuid)}`,
      `  udp: true`
    ];
    const sec: string = (params['security'] ? params['security'] : '').toLowerCase();
    if (sec === 'tls' || sec === 'reality') {
      lines.push(`  tls: true`);
    }
    const sni: string = params['sni'] ? params['sni'] : (params['servername'] ? params['servername'] : (params['host'] ? params['host'] : ''));
    if (sni.length > 0) {
      lines.push(`  servername: ${OverlayService.quoteYaml(sni)}`);
    }
    if (params['fp'] && params['fp'].length > 0) {
      lines.push(`  client-fingerprint: ${OverlayService.quoteYaml(params['fp'])}`);
    }
    if (params['flow'] && params['flow'].length > 0) {
      lines.push(`  flow: ${OverlayService.quoteYaml(params['flow'])}`);
    }
    if (params['allowInsecure'] === '1' || params['allowInsecure'] === 'true') {
      lines.push(`  skip-cert-verify: true`);
    }
    if (sec === 'reality' && ((params['pbk'] && params['pbk'].length > 0) || (params['sid'] && params['sid'].length > 0))) {
      lines.push(`  reality-opts:`);
      if (params['pbk'] && params['pbk'].length > 0) {
        lines.push(`    public-key: ${OverlayService.quoteYaml(params['pbk'])}`);
      }
      if (params['sid'] && params['sid'].length > 0) {
        lines.push(`    short-id: ${OverlayService.quoteYaml(params['sid'])}`);
      }
    }
    const netType: string = (params['type'] ? params['type'] : '').toLowerCase();
    if (netType.length > 0 && netType !== 'tcp') {
      lines.push(`  network: ${netType}`);
    }
    if (netType === 'ws') {
      lines.push(`  ws-opts:`);
      if (params['path'] && params['path'].length > 0) {
        lines.push(`    path: ${OverlayService.quoteYaml(params['path'])}`);
      }
      if (params['host'] && params['host'].length > 0) {
        lines.push(`    headers:`);
        lines.push(`      Host: ${OverlayService.quoteYaml(params['host'])}`);
      }
    } else if (netType === 'grpc' && params['serviceName'] && params['serviceName'].length > 0) {
      lines.push(`  grpc-opts:`);
      lines.push(`    grpc-service-name: ${OverlayService.quoteYaml(params['serviceName'])}`);
    }
    return lines;
  }

  private static parseTrojanUriToLines(raw: string, idx: number): string[] {
    const parts: string[] = OverlayService.splitUriParts(raw, 9);
    const body: string = parts[0];
    const params: Record<string, string> = OverlayService.parseQueryParams(parts[1]);
    const name: string = parts[2].length > 0 ? parts[2] : `自建-Trojan-${idx}`;
    const atIdx: number = body.indexOf('@');
    if (atIdx <= 0) {
      return [];
    }
    const password: string = OverlayService.safeDecode(body.substring(0, atIdx));
    const hp: string[] = OverlayService.parseHostPort(body.substring(atIdx + 1), 443);
    const lines: string[] = [
      `- name: ${OverlayService.quoteYaml(name)}`,
      `  type: trojan`,
      `  server: ${OverlayService.quoteYaml(hp[0])}`,
      `  port: ${hp[1]}`,
      `  password: ${OverlayService.quoteYaml(password)}`,
      `  udp: true`
    ];
    const sni: string = params['sni'] ? params['sni'] : (params['peer'] ? params['peer'] : (params['host'] ? params['host'] : ''));
    if (sni.length > 0) {
      lines.push(`  sni: ${OverlayService.quoteYaml(sni)}`);
    }
    if (params['allowInsecure'] === '1' || params['allowInsecure'] === 'true') {
      lines.push(`  skip-cert-verify: true`);
    }
    if ((params['type'] ? params['type'] : '').toLowerCase() === 'ws') {
      lines.push(`  network: ws`);
      lines.push(`  ws-opts:`);
      if (params['path'] && params['path'].length > 0) {
        lines.push(`    path: ${OverlayService.quoteYaml(params['path'])}`);
      }
      if (params['host'] && params['host'].length > 0) {
        lines.push(`    headers:`);
        lines.push(`      Host: ${OverlayService.quoteYaml(params['host'])}`);
      }
    }
    return lines;
  }

  private static parseSsUriToLines(raw: string, idx: number): string[] {
    const parts: string[] = OverlayService.splitUriParts(raw, 5);
    let body: string = parts[0];
    const name: string = parts[2].length > 0 ? parts[2] : `自建-SS-${idx}`;
    if (body.indexOf('@') < 0) {
      body = OverlayService.decodeBase64Text(body);
    }
    const atIdx: number = body.lastIndexOf('@');
    if (atIdx <= 0) {
      return [];
    }
    let userInfo: string = body.substring(0, atIdx);
    if (userInfo.indexOf(':') < 0) {
      userInfo = OverlayService.decodeBase64Text(userInfo);
    }
    const colon: number = userInfo.indexOf(':');
    if (colon <= 0) {
      return [];
    }
    const cipher: string = userInfo.substring(0, colon);
    const password: string = userInfo.substring(colon + 1);
    const hp: string[] = OverlayService.parseHostPort(body.substring(atIdx + 1), 8388);
    return [
      `- name: ${OverlayService.quoteYaml(name)}`,
      `  type: ss`,
      `  server: ${OverlayService.quoteYaml(hp[0])}`,
      `  port: ${hp[1]}`,
      `  cipher: ${OverlayService.quoteYaml(cipher)}`,
      `  password: ${OverlayService.quoteYaml(password)}`,
      `  udp: true`
    ];
  }

  private static parseVmessUriToLines(raw: string, idx: number): string[] {
    const decoded: string = OverlayService.decodeBase64Text(raw.substring(8).trim());
    if (decoded.length === 0) {
      return [];
    }
    try {
      const obj = JSON.parse(decoded) as Record<string, Object>;
      const str = (k: string): string => {
        const v: Object | undefined = obj[k];
        return v !== undefined && v !== null ? `${v}`.trim() : '';
      };
      const name: string = str('ps').length > 0 ? str('ps') : `自建-VMess-${idx}`;
      const port: string = str('port').length > 0 ? str('port') : '443';
      const aid: string = str('aid').length > 0 ? str('aid') : '0';
      const cipher: string = str('scy').length > 0 ? str('scy') : 'auto';
      const lines: string[] = [
        `- name: ${OverlayService.quoteYaml(name)}`,
        `  type: vmess`,
        `  server: ${OverlayService.quoteYaml(str('add'))}`,
        `  port: ${port}`,
        `  uuid: ${OverlayService.quoteYaml(str('id'))}`,
        `  alterId: ${aid}`,
        `  cipher: ${OverlayService.quoteYaml(cipher)}`,
        `  udp: true`
      ];
      if (str('tls').toLowerCase() === 'tls') {
        lines.push(`  tls: true`);
        const sni: string = str('sni').length > 0 ? str('sni') : str('host');
        if (sni.length > 0) {
          lines.push(`  servername: ${OverlayService.quoteYaml(sni)}`);
        }
      }
      if (str('net').toLowerCase() === 'ws') {
        lines.push(`  network: ws`);
        lines.push(`  ws-opts:`);
        if (str('path').length > 0) {
          lines.push(`    path: ${OverlayService.quoteYaml(str('path'))}`);
        }
        if (str('host').length > 0) {
          lines.push(`    headers:`);
          lines.push(`      Host: ${OverlayService.quoteYaml(str('host'))}`);
        }
      }
      return lines;
    } catch (_err) {
      return [];
    }
  }

  private static parseHy2UriToLines(raw: string, idx: number): string[] {
    const prefixLen: number = raw.toLowerCase().startsWith('hysteria2://') ? 12 : 6;
    const parts: string[] = OverlayService.splitUriParts(raw, prefixLen);
    const body: string = parts[0];
    const params: Record<string, string> = OverlayService.parseQueryParams(parts[1]);
    const name: string = parts[2].length > 0 ? parts[2] : `自建-HY2-${idx}`;
    const atIdx: number = body.indexOf('@');
    if (atIdx <= 0) {
      return [];
    }
    const password: string = OverlayService.safeDecode(body.substring(0, atIdx));
    const hp: string[] = OverlayService.parseHostPort(body.substring(atIdx + 1), 443);
    const lines: string[] = [
      `- name: ${OverlayService.quoteYaml(name)}`,
      `  type: hysteria2`,
      `  server: ${OverlayService.quoteYaml(hp[0])}`,
      `  port: ${hp[1]}`,
      `  password: ${OverlayService.quoteYaml(password)}`
    ];
    if (params['sni'] && params['sni'].length > 0) {
      lines.push(`  sni: ${OverlayService.quoteYaml(params['sni'])}`);
    }
    if (params['insecure'] === '1' || params['insecure'] === 'true') {
      lines.push(`  skip-cert-verify: true`);
    }
    if (params['obfs'] && params['obfs'].length > 0) {
      lines.push(`  obfs: ${OverlayService.quoteYaml(params['obfs'])}`);
      if (params['obfs-password'] && params['obfs-password'].length > 0) {
        lines.push(`  obfs-password: ${OverlayService.quoteYaml(params['obfs-password'])}`);
      }
    }
    return lines;
  }

  private static decodeBase64Text(raw: string): string {
    const compact: string = raw.replace(/\r/g, '').replace(/\n/g, '').trim();
    if (compact.length === 0) {
      return '';
    }
    const padded: string = compact.length % 4 === 0 ? compact : `${compact}${'='.repeat(4 - (compact.length % 4))}`;
    try {
      const helper: util.Base64Helper = new util.Base64Helper();
      const bytes: Uint8Array = helper.decodeSync(padded, util.Type.BASIC);
      const decoder: util.TextDecoder = util.TextDecoder.create('utf-8');
      return decoder.decodeToString(bytes).trim();
    } catch (_err) {
      try {
        const helper: util.Base64Helper = new util.Base64Helper();
        const bytes: Uint8Array = helper.decodeSync(padded, util.Type.BASIC_URL_SAFE);
        const decoder: util.TextDecoder = util.TextDecoder.create('utf-8');
        return decoder.decodeToString(bytes).trim();
      } catch (_inner) {
        return '';
      }
    }
  }

  private static parseYamlBlocksOnly(trimmed: string): ParsedCustomProxies {
    const result: ParsedCustomProxies = { names: [], servers: [], blocks: [] };
    if (trimmed.length === 0) {
      return result;
    }
    const rawLines: string[] = trimmed.replace(/\r\n/g, '\n').replace(/\r/g, '\n').split('\n');
    const contentLines: string[] = [];
    for (let i = 0; i < rawLines.length; i++) {
      const t: string = rawLines[i].trim();
      if (i === 0 && t === 'proxies:') {
        continue;
      }
      contentLines.push(rawLines[i]);
    }

    let baseIndentLen: number = -1;
    let currentBlock: string[] = [];
    for (let i = 0; i < contentLines.length; i++) {
      const line: string = contentLines[i];
      const t: string = line.trim();
      if (t.length === 0 || t.startsWith('#')) {
        continue;
      }
      const indentLen: number = OverlayService.countLeadingSpaces(line);
      if (t.startsWith('- ') || t.startsWith('-{')) {
        if (baseIndentLen < 0 || indentLen <= baseIndentLen) {
          if (baseIndentLen < 0) {
            baseIndentLen = indentLen;
          }
          if (currentBlock.length > 0) {
            result.blocks.push(currentBlock);
          }
          currentBlock = [line];
          continue;
        }
      }
      if (currentBlock.length > 0) {
        currentBlock.push(line);
      }
    }
    if (currentBlock.length > 0) {
      result.blocks.push(currentBlock);
    }

    const seenNames: Record<string, boolean> = {};
    const seenServers: Record<string, boolean> = {};
    for (let b = 0; b < result.blocks.length; b++) {
      const block: string[] = result.blocks[b];
      let name: string = '';
      let server: string = '';
      for (let j = 0; j < block.length; j++) {
        const t: string = block[j].trim();
        if (t.startsWith('- {') || t.startsWith('-{')) {
          const inlineName: string = OverlayService.extractInlineYamlField(t, 'name');
          const inlineServer: string = OverlayService.extractInlineYamlField(t, 'server');
          if (inlineName.length > 0) {
            name = inlineName;
          }
          if (inlineServer.length > 0) {
            server = inlineServer;
          }
        } else {
          if (name.length === 0 && (t.startsWith('- name:') || t.startsWith('name:'))) {
            const rawVal: string = t.startsWith('- name:') ? t.substring(7).trim() : t.substring(5).trim();
            name = OverlayService.stripQuotes(rawVal);
          }
          if (server.length === 0 && (t.startsWith('- server:') || t.startsWith('server:'))) {
            const rawVal: string = t.startsWith('- server:') ? t.substring(9).trim() : t.substring(7).trim();
            server = OverlayService.stripQuotes(rawVal);
          }
        }
      }
      if (name.length > 0 && !seenNames[name]) {
        seenNames[name] = true;
        result.names.push(name);
      }
      const cleanSrv: string = server.trim().toLowerCase();
      if (cleanSrv.length > 0 && !OverlayService.looksLikeIp(cleanSrv) && !seenServers[cleanSrv]) {
        seenServers[cleanSrv] = true;
        result.servers.push(cleanSrv);
      }
    }
    return result;
  }

  private static expandAiProviderDomainsAndKeywords(providerIds: string[]): string[][] {
    const want: Record<string, boolean> = {};
    for (let i = 0; i < providerIds.length; i++) {
      want[providerIds[i].trim().toLowerCase()] = true;
    }
    const domains: string[] = [];
    const keywords: string[] = [];
    const presets: AiProviderPreset[] = getAllAiProviderPresets();
    for (let i = 0; i < presets.length; i++) {
      const p: AiProviderPreset = presets[i];
      if (!want[p.id]) {
        continue;
      }
      for (let j = 0; j < p.domains.length; j++) {
        domains.push(p.domains[j]);
      }
      for (let j = 0; j < p.keywords.length; j++) {
        keywords.push(p.keywords[j]);
      }
    }
    return [domains, keywords];
  }

  /**
   * Merges self-hosted nodes, Fail-Closed AI Strict proxy group, protected direct hosts,
   * and custom high-priority rules onto a commercial subscription YAML without mutating the source file.
   */
  static applyOverlayToYaml(yamlText: string, rawCfg: CustomOverlayConfig): string {
    if (!rawCfg.enabled) {
      return yamlText;
    }
    const cfg: CustomOverlayConfig = OverlayService.normalizeConfig(rawCfg);
    let out: string = yamlText.replace(/\r\n/g, '\n').replace(/\r/g, '\n');

    const parsed: ParsedCustomProxies = OverlayService.parseCustomProxiesYaml(cfg.customProxiesYaml);

    if (parsed.blocks.length > 0) {
      out = OverlayService.injectCustomProxies(out, parsed);
    }

    if (cfg.aiStrictEnabled || parsed.names.length > 0) {
      const groupMembers: string[] = [];
      for (let i = 0; i < parsed.names.length; i++) {
        groupMembers.push(parsed.names[i]);
      }
      if (groupMembers.length === 0) {
        groupMembers.push(cfg.failClosed ? 'REJECT' : 'DIRECT');
      } else if (!cfg.failClosed) {
        groupMembers.push('DIRECT');
      }
      out = OverlayService.injectProxyGroup(out, cfg.selfHostedGroupName, groupMembers);
    }

    const directHosts: string[] = [];
    const seenDirect: Record<string, boolean> = {};
    for (let i = 0; i < parsed.servers.length; i++) {
      const h: string = parsed.servers[i];
      if (!seenDirect[h]) {
        seenDirect[h] = true;
        directHosts.push(h);
      }
    }
    for (let i = 0; i < cfg.directDomains.length; i++) {
      const h: string = cfg.directDomains[i];
      if (!seenDirect[h]) {
        seenDirect[h] = true;
        directHosts.push(h);
      }
    }
    if (directHosts.length > 0) {
      out = OverlayService.ensureFakeIpFilterHosts(out, directHosts);
    }

    const prependRules: string[] = [];
    for (let i = 0; i < directHosts.length; i++) {
      prependRules.push(`DOMAIN,${directHosts[i]},DIRECT`);
    }
    for (let i = 0; i < cfg.customRules.length; i++) {
      const r: string = cfg.customRules[i].trim();
      if (r.length > 0 && !r.startsWith('#')) {
        prependRules.push(r.startsWith('- ') ? r.substring(2).trim() : r);
      }
    }
    if (cfg.aiStrictEnabled) {
      const expanded: string[][] = OverlayService.expandAiProviderDomainsAndKeywords(cfg.aiProviders);
      const mergedDomainsRaw: string[] = [];
      for (let i = 0; i < expanded[0].length; i++) {
        mergedDomainsRaw.push(expanded[0][i]);
      }
      for (let i = 0; i < cfg.aiDomains.length; i++) {
        mergedDomainsRaw.push(cfg.aiDomains[i]);
      }
      const allDomains: string[] = OverlayService.cleanDomainList(mergedDomainsRaw);
      for (let i = 0; i < allDomains.length; i++) {
        prependRules.push(`DOMAIN-SUFFIX,${allDomains[i]},${cfg.selfHostedGroupName}`);
      }

      const mergedKwRaw: string[] = [];
      for (let i = 0; i < expanded[1].length; i++) {
        mergedKwRaw.push(expanded[1][i]);
      }
      for (let i = 0; i < cfg.aiKeywords.length; i++) {
        mergedKwRaw.push(cfg.aiKeywords[i]);
      }
      const allKw: string[] = OverlayService.cleanStringList(mergedKwRaw);
      for (let i = 0; i < allKw.length; i++) {
        prependRules.push(`DOMAIN-KEYWORD,${allKw[i]},${cfg.selfHostedGroupName}`);
      }
    }
    if (prependRules.length > 0) {
      out = OverlayService.prependRules(out, prependRules);
    }
    return out;
  }

  /**
   * Exports a cross-platform JSON backup bundle compatible with Clash Harmony Windows Desktop Edition.
   */
  static async exportBackupBundleJson(context: common.Context, sanitize: boolean): Promise<string> {
    const overlay: CustomOverlayConfig = await OverlayService.load(context);
    const tsPrefs: TailscaleNativePrefs = await TailscalePrefsService.load(context);
    const profileState: ProfileState = await ProfileStore.load(context);

    const outOverlay: CustomOverlayConfig = {
      enabled: overlay.enabled,
      selfHostedGroupName: overlay.selfHostedGroupName,
      failClosed: overlay.failClosed,
      aiStrictEnabled: overlay.aiStrictEnabled,
      aiProviders: overlay.aiProviders,
      aiDomains: overlay.aiDomains,
      aiKeywords: overlay.aiKeywords,
      customProxiesYaml: sanitize ? OverlayService.sanitizeYamlText(overlay.customProxiesYaml) : overlay.customProxiesYaml,
      customRules: overlay.customRules,
      directDomains: overlay.directDomains
    };

    const outTsPrefs: TailscaleNativePrefs = {
      managedByApp: tsPrefs.managedByApp,
      enabled: tsPrefs.enabled,
      proxyName: tsPrefs.proxyName,
      hostname: tsPrefs.hostname,
      controlUrl: tsPrefs.controlUrl,
      acceptRoutes: tsPrefs.acceptRoutes,
      exitNode: tsPrefs.exitNode,
      exitNodeAllowLan: tsPrefs.exitNodeAllowLan,
      authKey: sanitize && tsPrefs.authKey.length > 0 ? '<REDACTED>' : tsPrefs.authKey,
      autoInjectMagicDns: tsPrefs.autoInjectMagicDns,
      tailnetSuffix: tsPrefs.tailnetSuffix,
      autoSyncSplitDns: tsPrefs.autoSyncSplitDns,
      splitDnsDomains: tsPrefs.splitDnsDomains
    };

    const exportedProfiles: Record<string, Object>[] = [];
    for (let i = 0; i < profileState.items.length; i++) {
      const p: ClashProfile = profileState.items[i];
      let content: string = '';
      if (p.filePath.length > 0) {
        try {
          if (await fileIo.access(p.filePath)) {
            content = await fileIo.readText(p.filePath);
          }
        } catch (_err) {
          content = '';
        }
      }
      const url: string = p.type === 'remote' ? (sanitize ? OverlayService.sanitizeUrl(p.source) : p.source) : '';
      const entry: Record<string, Object> = {};
      entry['name'] = p.name;
      entry['url'] = url;
      entry['fetchMode'] = 'auto';
      entry['userAgent'] = p.userAgent ? p.userAgent : '';
      entry['active'] = p.uid === profileState.currentUid;
      entry['content'] = sanitize ? OverlayService.sanitizeYamlText(content) : content;
      exportedProfiles.push(entry);
    }

    const bundle: Record<string, Object> = {};
    bundle['formatVersion'] = 1;
    bundle['exportedAt'] = new Date().toISOString();
    bundle['sourcePlatform'] = 'harmonyos';
    bundle['sanitized'] = sanitize;
    bundle['overlay'] = outOverlay;
    bundle['tailscalePrefs'] = outTsPrefs;
    bundle['profiles'] = exportedProfiles;
    return JSON.stringify(bundle, null, 2);
  }

  /**
   * Fetches and imports a cross-device sync bundle from a QR code scanned from Windows Desktop.
   * Supports `clashharmony://sync?url=...`, direct `http://<lan-ip>:<port>/sync?token=...`, or raw JSON.
   */
  static async importFromQrSyncText(context: common.Context, rawQrValue: string): Promise<BackupImportResult> {
    const trimmed: string = rawQrValue.trim();
    if (trimmed.length === 0) {
      return { ok: false, message: '未扫描到有效二维码内容', importedProfiles: 0, importedProfileUid: '', activated: false };
    }
    if (trimmed.startsWith('{')) {
      return await OverlayService.importBackupBundleJson(context, trimmed);
    }

    let syncUrl: string = '';
    if (trimmed.toLowerCase().startsWith('clashharmony://sync')) {
      const qIdx: number = trimmed.indexOf('?');
      if (qIdx >= 0) {
        const params: Record<string, string> = OverlayService.parseQueryParams(trimmed.substring(qIdx + 1));
        syncUrl = params['url'] ? params['url'].trim() : '';
      }
    } else if (trimmed.toLowerCase().startsWith('http://') || trimmed.toLowerCase().startsWith('https://')) {
      syncUrl = trimmed;
    }

    if (syncUrl.length === 0) {
      return {
        ok: false,
        message: '二维码不是 Clash Harmony 同步码（请在电脑端点击「📱 扫码同步到手机」生成）',
        importedProfiles: 0,
        importedProfileUid: '',
        activated: false
      };
    }

    const request: http.HttpRequest = http.createHttp();
    try {
      const response: http.HttpResponse = await request.request(syncUrl, {
        method: http.RequestMethod.GET,
        expectDataType: http.HttpDataType.STRING,
        connectTimeout: 8000,
        readTimeout: 12000,
        usingCache: false
      });
      const code: number = response.responseCode as number;
      const body: string = typeof response.result === 'string' ? response.result : JSON.stringify(response.result);
      if (code < 200 || code >= 300) {
        let errDetail: string = `HTTP ${code}`;
        try {
          const obj = JSON.parse(body) as Record<string, Object>;
          const eStr: string = OverlayService.readStr(obj, 'error');
          if (eStr.length > 0) {
            errDetail = eStr;
          }
        } catch (_e) {
        }
        return { ok: false, message: `拉取电脑配置失败：${errDetail}`, importedProfiles: 0, importedProfileUid: '', activated: false };
      }
      return await OverlayService.importBackupBundleJson(context, body);
    } catch (_err) {
      return {
        ok: false,
        message: '无法连接电脑同步地址：请确认手机与电脑在同一 Wi-Fi，且电脑端切换正确局域网 IP / 防火墙放行',
        importedProfiles: 0,
        importedProfileUid: '',
        activated: false
      };
    } finally {
      request.destroy();
    }
  }

  /**
   * Imports a cross-platform JSON backup bundle (exported from Windows Desktop or HarmonyOS).
   * Tailscale sync strictly applies ONLY routing policy (SplitDNS domains, acceptRoutes, MagicDNS);
   * phone's own hostname, authKey, exitNode, and Tailscale login state are NEVER overwritten!
   */
  static async importBackupBundleJson(context: common.Context, rawJson: string): Promise<BackupImportResult> {
    try {
      const parsed = JSON.parse(rawJson.trim()) as Record<string, Object>;
      if (!parsed || typeof parsed !== 'object') {
        return { ok: false, message: '无效的迁移包 JSON 格式', importedProfiles: 0, importedProfileUid: '', activated: false };
      }

      const ovObj: Object | undefined = parsed['overlay'];
      let syncedCustomCount: number = 0;
      let syncedAiCount: number = 0;
      if (ovObj && typeof ovObj === 'object') {
        const defaults: CustomOverlayConfig = createDefaultOverlayConfig();
        const nextOv: CustomOverlayConfig = OverlayService.parseConfigObj(ovObj as Record<string, Object>, defaults);
        await OverlayService.save(context, nextOv);
        syncedCustomCount = OverlayService.parseCustomProxiesYaml(nextOv.customProxiesYaml).names.length;
        syncedAiCount = nextOv.aiProviders.length;
      }

      // Accept new clean `tailscaleRouting` or legacy `tailscalePrefs` — ALWAYS preserve device-local identity/credentials!
      const tsObj: Object | undefined = parsed['tailscaleRouting'] ? parsed['tailscaleRouting'] : parsed['tailscalePrefs'];
      let syncedSplitCount: number = 0;
      if (tsObj && typeof tsObj === 'object') {
        const curTs: TailscaleNativePrefs = await TailscalePrefsService.load(context);
        const rec = tsObj as Record<string, Object>;
        const nextSplit: string[] = OverlayService.readStrArr(rec, 'splitDnsDomains');
        syncedSplitCount = nextSplit.length;
        const nextTs: TailscaleNativePrefs = {
          managedByApp: typeof rec['managedByApp'] === 'boolean' ? rec['managedByApp'] as boolean : curTs.managedByApp,
          enabled: typeof rec['enabled'] === 'boolean' ? rec['enabled'] as boolean : curTs.enabled,
          proxyName: OverlayService.readNonEmpty(rec, 'proxyName', curTs.proxyName),
          // Device-local fields strictly preserved on phone:
          hostname: curTs.hostname,
          authKey: curTs.authKey,
          exitNode: curTs.exitNode,
          exitNodeAllowLan: curTs.exitNodeAllowLan,
          // Shared routing policy synced from PC:
          controlUrl: OverlayService.readStr(rec, 'controlUrl'),
          acceptRoutes: typeof rec['acceptRoutes'] === 'boolean' ? rec['acceptRoutes'] as boolean : curTs.acceptRoutes,
          autoInjectMagicDns: typeof rec['autoInjectMagicDns'] === 'boolean' ? rec['autoInjectMagicDns'] as boolean : curTs.autoInjectMagicDns,
          tailnetSuffix: OverlayService.readStr(rec, 'tailnetSuffix').length > 0 ? OverlayService.readStr(rec, 'tailnetSuffix') : curTs.tailnetSuffix,
          autoSyncSplitDns: typeof rec['autoSyncSplitDns'] === 'boolean' ? rec['autoSyncSplitDns'] as boolean : curTs.autoSyncSplitDns,
          splitDnsDomains: nextSplit.length > 0 ? nextSplit : curTs.splitDnsDomains
        };
        await TailscalePrefsService.save(context, nextTs);
      }

      const existingState: ProfileState = await ProfileStore.load(context);
      const hadExistingActive: boolean = existingState.currentUid.length > 0;
      let importedCount: number = 0;
      let lastImportedUid: string = '';
      let activatedNew: boolean = false;
      const rawProfiles: Object | undefined = parsed['profiles'];
      if (Array.isArray(rawProfiles)) {
        const arr: Object[] = rawProfiles as Object[];
        const dir: string = `${context.filesDir}/profiles`;
        try {
          await fileIo.mkdir(dir, true);
        } catch (_err) {
        }
        for (let i = 0; i < arr.length; i++) {
          const item = arr[i] as Record<string, Object>;
          if (!item) {
            continue;
          }
          const name: string = OverlayService.readNonEmpty(item, 'name', `同步配置 ${i + 1}`);
          const url: string = OverlayService.readStr(item, 'url');
          const userAgent: string = OverlayService.readStr(item, 'userAgent');
          const content: string = OverlayService.readStr(item, 'content');

          let profile: ClashProfile;
          if (url.length > 0 && url.indexOf('<REDACTED>') < 0) {
            profile = createRemoteProfile(name, url, userAgent);
          } else {
            profile = createLocalProfile(name, '', 0, `${Math.round(content.length / 1024)} KB`);
          }
          profile.uid = `${profile.type}_${Date.now()}_${i}`;

          if (content.trim().length > 0) {
            const path: string = `${dir}/${profile.uid}.yaml`;
            let file: fileIo.File | undefined = undefined;
            try {
              file = fileIo.openSync(path, fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
              await fileIo.write(file.fd, content);
              profile.filePath = path;
              if (profile.type === 'local') {
                profile.source = path;
              }
              profile.traffic = `${Math.max(1, Math.round(content.length / 1024))} KB`;
            } finally {
              if (file) {
                try {
                  fileIo.closeSync(file);
                } catch (_cErr) {
                }
              }
            }
          }
          await ProfileStore.addRemote(context, profile);
          lastImportedUid = profile.uid;
          // Auto-activate only when phone had no active profile yet; otherwise show as "待生效版本" card!
          if (!hadExistingActive && !activatedNew) {
            await ProfileStore.activate(context, profile.uid);
            activatedNew = true;
          }
          importedCount++;
        }
      }

      const modeHint: string = (!hadExistingActive && activatedNew)
        ? '已自动启用，可回首页点「连接」后登录 Tailscale'
        : (importedCount > 0 ? '新配置已列为「待生效」，确认后点「立即生效」切换' : '已生效（重连 VPN 应用最新分流）');
      return {
        ok: true,
        message: `同步成功：自建节点 ${syncedCustomCount} 个 · ${syncedAiCount} 家 AI · Tailscale 分流域 ${syncedSplitCount} 个 · 配置 ${importedCount} 份（${modeHint}）`,
        importedProfiles: importedCount,
        importedProfileUid: lastImportedUid,
        activated: activatedNew
      };
    } catch (_err) {
      return { ok: false, message: '解析迁移包 JSON 失败，请确认内容完整', importedProfiles: 0, importedProfileUid: '', activated: false };
    }
  }

  private static injectCustomProxies(yamlText: string, parsed: ParsedCustomProxies): string {
    const lines: string[] = yamlText.split('\n');
    const bounds: number[] = OverlayService.findTopLevelSection(lines, 'proxies:');
    const startIdx: number = bounds[0];
    const endIdx: number = bounds[1];

    let targetIndent: string = '  ';
    if (startIdx >= 0) {
      const sectionLines: string[] = lines.slice(startIdx + 1, endIdx);
      for (let i = 0; i < sectionLines.length; i++) {
        const t: string = sectionLines[i].trim();
        if (t.startsWith('- ') || t.startsWith('-{')) {
          const idx: number = sectionLines[i].indexOf('-');
          targetIndent = idx > 0 ? sectionLines[i].substring(0, idx) : '';
          break;
        }
      }
    }

    const reindentedBlocks: string[] = [];
    for (let b = 0; b < parsed.blocks.length; b++) {
      const block: string[] = parsed.blocks[b];
      if (block.length === 0) {
        continue;
      }
      const origBase: number = OverlayService.countLeadingSpaces(block[0]);
      for (let j = 0; j < block.length; j++) {
        const curSpaces: number = OverlayService.countLeadingSpaces(block[j]);
        const rel: number = curSpaces >= origBase ? curSpaces - origBase : 0;
        reindentedBlocks.push(`${targetIndent}${' '.repeat(rel)}${block[j].trim()}`);
      }
    }

    if (startIdx < 0) {
      const out: string[] = lines.slice();
      out.push('');
      out.push('proxies:');
      for (let i = 0; i < reindentedBlocks.length; i++) {
        out.push(reindentedBlocks[i]);
      }
      return out.join('\n');
    }

    const nameSet: Record<string, boolean> = {};
    for (let i = 0; i < parsed.names.length; i++) {
      nameSet[parsed.names[i].toLowerCase()] = true;
    }
    const existingSection: string[] = lines.slice(startIdx + 1, endIdx);
    const filteredSection: string[] = OverlayService.stripNamedBlocks(existingSection, nameSet);

    const out: string[] = [];
    for (let i = 0; i <= startIdx; i++) {
      out.push(lines[i]);
    }
    for (let i = 0; i < reindentedBlocks.length; i++) {
      out.push(reindentedBlocks[i]);
    }
    for (let i = 0; i < filteredSection.length; i++) {
      out.push(filteredSection[i]);
    }
    for (let i = endIdx; i < lines.length; i++) {
      out.push(lines[i]);
    }
    return out.join('\n');
  }

  private static injectProxyGroup(yamlText: string, groupName: string, members: string[]): string {
    const lines: string[] = yamlText.split('\n');
    const bounds: number[] = OverlayService.findTopLevelSection(lines, 'proxy-groups:');
    const startIdx: number = bounds[0];
    const endIdx: number = bounds[1];

    let itemIndent: string = '  ';
    if (startIdx >= 0) {
      const sectionLines: string[] = lines.slice(startIdx + 1, endIdx);
      for (let i = 0; i < sectionLines.length; i++) {
        const t: string = sectionLines[i].trim();
        if (t.startsWith('- ') || t.startsWith('-{')) {
          const idx: number = sectionLines[i].indexOf('-');
          itemIndent = idx > 0 ? sectionLines[i].substring(0, idx) : '';
          break;
        }
      }
    }

    const fieldIndent: string = `${itemIndent}  `;
    const memberIndent: string = `${fieldIndent}  `;
    const groupBlock: string[] = [
      `${itemIndent}- name: ${OverlayService.quoteYaml(groupName)}`,
      `${fieldIndent}type: select`,
      `${fieldIndent}proxies:`
    ];
    for (let i = 0; i < members.length; i++) {
      groupBlock.push(`${memberIndent}- ${OverlayService.quoteYaml(members[i])}`);
    }

    if (startIdx < 0) {
      const out: string[] = lines.slice();
      out.push('');
      out.push('proxy-groups:');
      for (let i = 0; i < groupBlock.length; i++) {
        out.push(groupBlock[i]);
      }
      return out.join('\n');
    }

    const nameSet: Record<string, boolean> = {};
    nameSet[groupName.toLowerCase()] = true;
    const existingSection: string[] = lines.slice(startIdx + 1, endIdx);
    const filteredSection: string[] = OverlayService.stripNamedBlocks(existingSection, nameSet);

    const out: string[] = [];
    for (let i = 0; i <= startIdx; i++) {
      out.push(lines[i]);
    }
    for (let i = 0; i < groupBlock.length; i++) {
      out.push(groupBlock[i]);
    }
    for (let i = 0; i < filteredSection.length; i++) {
      out.push(filteredSection[i]);
    }
    for (let i = endIdx; i < lines.length; i++) {
      out.push(lines[i]);
    }
    return out.join('\n');
  }

  private static ensureFakeIpFilterHosts(yamlText: string, hosts: string[]): string {
    const lines: string[] = yamlText.split('\n');
    const bounds: number[] = OverlayService.findTopLevelSection(lines, 'dns:');
    const dnsStart: number = bounds[0];
    const dnsEnd: number = bounds[1];
    if (dnsStart < 0) {
      return yamlText;
    }

    const dnsSection: string[] = lines.slice(dnsStart, dnsEnd);
    const dnsLower: string = dnsSection.join('\n').toLowerCase();
    const missing: string[] = [];
    for (let i = 0; i < hosts.length; i++) {
      const h: string = hosts[i].toLowerCase();
      if (dnsLower.indexOf(h) < 0) {
        missing.push(hosts[i]);
      }
    }
    if (missing.length === 0) {
      return yamlText;
    }

    const childIndent: string = OverlayService.detectSectionChildIndent(dnsSection, '  ');
    let filterIdx: number = -1;
    for (let i = 0; i < dnsSection.length; i++) {
      if (dnsSection[i].trim() === 'fake-ip-filter:') {
        filterIdx = i;
        break;
      }
    }

    const newDns: string[] = [];
    if (filterIdx >= 0) {
      let itemPrefix: string = `${childIndent}  - `;
      for (let i = filterIdx + 1; i < dnsSection.length; i++) {
        const t: string = dnsSection[i].trim();
        if (t.length === 0 || t.startsWith('#')) {
          continue;
        }
        if (t.startsWith('- ')) {
          const dash: number = dnsSection[i].indexOf('-');
          itemPrefix = `${dnsSection[i].substring(0, dash)}- `;
          break;
        }
        break;
      }
      for (let i = 0; i < dnsSection.length; i++) {
        newDns.push(dnsSection[i]);
        if (i === filterIdx) {
          for (let j = 0; j < missing.length; j++) {
            newDns.push(`${itemPrefix}${OverlayService.quoteYaml(missing[j])}`);
          }
        }
      }
    } else {
      for (let i = 0; i < dnsSection.length; i++) {
        newDns.push(dnsSection[i]);
      }
      newDns.push(`${childIndent}fake-ip-filter:`);
      for (let j = 0; j < missing.length; j++) {
        newDns.push(`${childIndent}  - ${OverlayService.quoteYaml(missing[j])}`);
      }
    }

    const out: string[] = [];
    for (let i = 0; i < dnsStart; i++) {
      out.push(lines[i]);
    }
    for (let i = 0; i < newDns.length; i++) {
      out.push(newDns[i]);
    }
    for (let i = dnsEnd; i < lines.length; i++) {
      out.push(lines[i]);
    }
    return out.join('\n');
  }

  private static prependRules(yamlText: string, prependList: string[]): string {
    const lines: string[] = yamlText.split('\n');
    const bounds: number[] = OverlayService.findTopLevelSection(lines, 'rules:');
    const startIdx: number = bounds[0];
    const endIdx: number = bounds[1];

    const dedupPrepend: string[] = [];
    const seen: Record<string, boolean> = {};
    for (let i = 0; i < prependList.length; i++) {
      const r: string = prependList[i].trim();
      const key: string = r.toLowerCase();
      if (r.length > 0 && !seen[key]) {
        seen[key] = true;
        dedupPrepend.push(r);
      }
    }

    if (startIdx < 0) {
      const out: string[] = lines.slice();
      out.push('');
      out.push('rules:');
      for (let i = 0; i < dedupPrepend.length; i++) {
        out.push(`  - ${OverlayService.quoteRuleIfNeeded(dedupPrepend[i])}`);
      }
      return out.join('\n');
    }

    let itemPrefix: string = '  - ';
    for (let i = startIdx + 1; i < endIdx; i++) {
      const t: string = lines[i].trim();
      if (t.startsWith('- ')) {
        const dash: number = lines[i].indexOf('-');
        itemPrefix = `${lines[i].substring(0, dash)}- `;
        break;
      }
    }

    const out: string[] = [];
    for (let i = 0; i <= startIdx; i++) {
      out.push(lines[i]);
    }
    for (let i = 0; i < dedupPrepend.length; i++) {
      out.push(`${itemPrefix}${OverlayService.quoteRuleIfNeeded(dedupPrepend[i])}`);
    }
    for (let i = startIdx + 1; i < endIdx; i++) {
      const t: string = lines[i].trim();
      if (t.startsWith('- ')) {
        const rawRule: string = OverlayService.stripQuotes(t.substring(2).trim()).toLowerCase();
        if (seen[rawRule]) {
          continue;
        }
      }
      out.push(lines[i]);
    }
    for (let i = endIdx; i < lines.length; i++) {
      out.push(lines[i]);
    }
    return out.join('\n');
  }

  private static findTopLevelSection(lines: string[], header: string): number[] {
    let startIdx: number = -1;
    let endIdx: number = lines.length;
    for (let i = 0; i < lines.length; i++) {
      const line: string = lines[i];
      const trimmed: string = line.trim();
      if (startIdx < 0) {
        if (!line.startsWith(' ') && !line.startsWith('\t') && trimmed === header) {
          startIdx = i;
        }
        continue;
      }
      if (trimmed.length === 0 || trimmed.startsWith('#')) {
        continue;
      }
      if (!line.startsWith(' ') && !line.startsWith('\t') && !line.startsWith('-')) {
        endIdx = i;
        break;
      }
    }
    return [startIdx, endIdx];
  }

  private static stripNamedBlocks(sectionLines: string[], dropNamesLower: Record<string, boolean>): string[] {
    const blocks: string[][] = [];
    let current: string[] = [];
    let itemIndentLen: number = -1;
    for (let i = 0; i < sectionLines.length; i++) {
      const line: string = sectionLines[i];
      const t: string = line.trim();
      const indent: number = OverlayService.countLeadingSpaces(line);
      if ((t.startsWith('- ') || t.startsWith('-{')) && (itemIndentLen < 0 || indent <= itemIndentLen)) {
        if (itemIndentLen < 0) {
          itemIndentLen = indent;
        }
        if (current.length > 0) {
          blocks.push(current);
        }
        current = [line];
      } else {
        current.push(line);
      }
    }
    if (current.length > 0) {
      blocks.push(current);
    }

    const kept: string[] = [];
    for (let b = 0; b < blocks.length; b++) {
      const block: string[] = blocks[b];
      let drop: boolean = false;
      for (let j = 0; j < block.length; j++) {
        const t: string = block[j].trim();
        let name: string = '';
        if (t.startsWith('- {') || t.startsWith('-{')) {
          name = OverlayService.extractInlineYamlField(t, 'name');
        } else if (t.startsWith('- name:')) {
          name = OverlayService.stripQuotes(t.substring(7).trim());
        } else if (t.startsWith('name:')) {
          name = OverlayService.stripQuotes(t.substring(5).trim());
        }
        if (name.length > 0) {
          if (dropNamesLower[name.toLowerCase()]) {
            drop = true;
          }
          break;
        }
      }
      if (!drop) {
        for (let j = 0; j < block.length; j++) {
          kept.push(block[j]);
        }
      }
    }
    return kept;
  }

  private static detectSectionChildIndent(sectionLines: string[], fallback: string): string {
    let minSpaces: number = -1;
    for (let i = 1; i < sectionLines.length; i++) {
      const t: string = sectionLines[i].trim();
      if (t.length === 0 || t.startsWith('#')) {
        continue;
      }
      const spaces: number = OverlayService.countLeadingSpaces(sectionLines[i]);
      if (spaces > 0 && (minSpaces < 0 || spaces < minSpaces)) {
        minSpaces = spaces;
      }
    }
    return minSpaces > 0 ? ' '.repeat(minSpaces) : fallback;
  }

  private static countLeadingSpaces(line: string): number {
    let count: number = 0;
    while (count < line.length && line.charAt(count) === ' ') {
      count++;
    }
    return count;
  }

  private static extractInlineYamlField(line: string, key: string): string {
    const pattern: RegExp = new RegExp(`(?:^|[{,\\s])${key}\\s*:\\s*(?:"([^"]+)"|'([^']+)'|([^,}]+))`);
    const match: RegExpMatchArray | null = line.match(pattern);
    if (!match) {
      return '';
    }
    const raw: string = match[1] ? match[1] : (match[2] ? match[2] : (match[3] ? match[3] : ''));
    return raw.trim();
  }

  private static stripQuotes(val: string): string {
    if (val.length >= 2) {
      if ((val.startsWith('"') && val.endsWith('"')) || (val.startsWith("'") && val.endsWith("'"))) {
        return val.substring(1, val.length - 1).trim();
      }
    }
    return val.trim();
  }

  private static quoteYaml(val: string): string {
    const escaped: string = val.replace(/\\/g, '\\\\').replace(/"/g, '\\"');
    return `"${escaped}"`;
  }

  private static quoteRuleIfNeeded(rule: string): string {
    if (rule.indexOf('(') >= 0 || rule.indexOf('"') >= 0 || rule.indexOf("'") >= 0 || rule.indexOf('#') >= 0) {
      return OverlayService.quoteYaml(rule);
    }
    return rule;
  }

  private static looksLikeIp(val: string): boolean {
    if (val.indexOf(':') >= 0) {
      return true;
    }
    const parts: string[] = val.split('.');
    if (parts.length !== 4) {
      return false;
    }
    for (let i = 0; i < 4; i++) {
      const n: number = Number(parts[i]);
      if (!Number.isInteger(n) || n < 0 || n > 255) {
        return false;
      }
    }
    return true;
  }

  private static cleanStringList(items: string[]): string[] {
    const out: string[] = [];
    const seen: Record<string, boolean> = {};
    for (let i = 0; i < items.length; i++) {
      const s: string = items[i].trim();
      const k: string = s.toLowerCase();
      if (s.length > 0 && !seen[k]) {
        seen[k] = true;
        out.push(s);
      }
    }
    return out;
  }

  private static cleanDomainList(items: string[]): string[] {
    const out: string[] = [];
    const seen: Record<string, boolean> = {};
    for (let i = 0; i < items.length; i++) {
      let s: string = items[i].trim().toLowerCase();
      while (s.startsWith('.') || s.startsWith('+') || s.startsWith('*')) {
        s = s.substring(1);
      }
      while (s.endsWith('.')) {
        s = s.substring(0, s.length - 1);
      }
      if (s.length > 0 && !seen[s]) {
        seen[s] = true;
        out.push(s);
      }
    }
    return out;
  }

  private static sanitizeYamlText(text: string): string {
    return text
      .replace(/(uuid|password|secret|auth-key|token|private-key|public-key|short-id)(\s*:\s*)([^\s,}\r\n]+)/gi, '$1$2"<REDACTED>"');
  }

  private static sanitizeUrl(rawUrl: string): string {
    return rawUrl.replace(/(token|key|password|secret|auth)=([^&#]+)/gi, '$1=<REDACTED>');
  }

  private static parseConfigObj(parsed: Record<string, Object>, defaults: CustomOverlayConfig): CustomOverlayConfig {
    const hasProviders: boolean = Array.isArray(parsed['aiProviders']);
    const aiDomains: string[] = OverlayService.readStrArr(parsed, 'aiDomains');
    const aiKeywords: string[] = OverlayService.readStrArr(parsed, 'aiKeywords');
    const providers: string[] = hasProviders
      ? OverlayService.readStrArr(parsed, 'aiProviders')
      : (aiDomains.length === 0 && aiKeywords.length === 0 ? defaults.aiProviders : []);

    const groupName: string = OverlayService.readNonEmpty(
      parsed,
      'selfHostedGroupName',
      OverlayService.readNonEmpty(parsed, 'aiGroupName', defaults.selfHostedGroupName)
    );
    const failClosed: boolean = typeof parsed['failClosed'] === 'boolean'
      ? parsed['failClosed'] as boolean
      : (typeof parsed['aiFailClosed'] === 'boolean' ? parsed['aiFailClosed'] as boolean : defaults.failClosed);

    return OverlayService.normalizeConfig({
      enabled: typeof parsed['enabled'] === 'boolean' ? parsed['enabled'] as boolean : defaults.enabled,
      selfHostedGroupName: groupName,
      failClosed: failClosed,
      aiStrictEnabled: typeof parsed['aiStrictEnabled'] === 'boolean' ? parsed['aiStrictEnabled'] as boolean : defaults.aiStrictEnabled,
      aiProviders: providers,
      aiDomains: aiDomains,
      aiKeywords: aiKeywords,
      customProxiesYaml: OverlayService.readStr(parsed, 'customProxiesYaml'),
      customRules: OverlayService.readStrArr(parsed, 'customRules'),
      directDomains: OverlayService.readStrArr(parsed, 'directDomains')
    });
  }

  private static readStr(obj: Record<string, Object>, key: string): string {
    const val: Object | undefined = obj[key];
    return typeof val === 'string' ? (val as string) : '';
  }

  private static readNonEmpty(obj: Record<string, Object>, key: string, fallback: string): string {
    const s: string = OverlayService.readStr(obj, key).trim();
    return s.length > 0 ? s : fallback;
  }

  private static readStrArr(obj: Record<string, Object>, key: string): string[] {
    const val: Object | undefined = obj[key];
    if (!Array.isArray(val)) {
      return [];
    }
    const raw: Object[] = val as Object[];
    const out: string[] = [];
    for (let i = 0; i < raw.length; i++) {
      if (typeof raw[i] === 'string') {
        const s: string = (raw[i] as string).trim();
        if (s.length > 0) {
          out.push(s);
        }
      }
    }
    return out;
  }
}
