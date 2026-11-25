import { common } from '@kit.AbilityKit';
import { pasteboard } from '@kit.BasicServicesKit';
import { fileIo } from '@kit.CoreFileKit';
import { ClashProfile, createLocalProfile, createRemoteProfile, ProfileState } from '../models/Profile';
import { ClashConfigParserService, ParsedProxyNode } from './ClashConfigParserService';
import { ConvertedSubscription, GenericSubscriptionConverterService } from './GenericSubscriptionConverterService';
import { ProfileStore } from './ProfileStore';

export interface ClipboardReadResult {
  ok: boolean;
  text: string;
  message: string;
}

export interface ClipboardImportResult {
  ok: boolean;
  message: string;
  state: ProfileState;
  importedUid: string;
  isRemote: boolean;
}

export class ClipboardImportService {
  static async readClipboardText(): Promise<ClipboardReadResult> {
    try {
      const systemPasteboard: pasteboard.SystemPasteboard = pasteboard.getSystemPasteboard();
      const data: pasteboard.PasteData = await systemPasteboard.getData();
      const text: string = data.getPrimaryText();
      if (text.trim().length === 0) {
        return {
          ok: false,
          text: '',
          message: '剪贴板为空，请先复制配置 YAML 或订阅链接后再粘贴'
        };
      }
      return {
        ok: true,
        text: text,
        message: '已读取剪贴板内容，请核对校验结果后保存'
      };
    } catch (err) {
      const detail: string = err ? String(err) : '';
      const hint: string = detail.length > 0 ? `（${detail}）` : '';
      return {
        ok: false,
        text: '',
        message: `剪贴板读取失败${hint}，可直接长按下方文本框手动粘贴`
      };
    }
  }

  static async saveValidatedYamlProfile(
    context: common.Context,
    name: string,
    yamlText: string
  ): Promise<ClipboardImportResult> {
    const state: ProfileState = await ProfileStore.load(context);
    try {
      const uid: string = `clipboard_${Date.now()}`;
      const dir: string = `${context.filesDir}/profiles`;
      await ClipboardImportService.ensureDir(dir);
      const path: string = `${dir}/${uid}.yaml`;
      await ClipboardImportService.writeText(path, yamlText);
      const nodes: ParsedProxyNode[] = ClashConfigParserService.parseProxyNodes(yamlText);
      const cleanName: string = name.trim().length > 0 ? name.trim() : `剪贴板配置`;
      const profile: ClashProfile = createLocalProfile(cleanName, path, nodes.length, ClipboardImportService.formatBytes(yamlText.length));
      const nextState: ProfileState = await ProfileStore.replace(context, profile);
      return {
        ok: true,
        message: `已保存新配置「${cleanName}」，解析 ${nodes.length} 个节点`,
        state: nextState,
        importedUid: profile.uid,
        isRemote: false
      };
    } catch (_err) {
      return ClipboardImportService.failure('保存剪贴板配置失败，请检查存储权限', state);
    }
  }

  static async importProfile(context: common.Context): Promise<ClipboardImportResult> {
    const state: ProfileState = await ProfileStore.load(context);
    try {
      const systemPasteboard: pasteboard.SystemPasteboard = pasteboard.getSystemPasteboard();
      const data: pasteboard.PasteData = await systemPasteboard.getData();
      const text: string = data.getPrimaryText().trim();
      if (text.length === 0) {
        return ClipboardImportService.failure('剪贴板为空，请先复制订阅链接或 Clash YAML 配置', state);
      }

      if (text.startsWith('http://') || text.startsWith('https://')) {
        const firstLine: string = text.split('\n')[0].trim();
        const name: string = ClipboardImportService.createProfileNameFromUrl(firstLine);
        const remote: ClashProfile = createRemoteProfile(name, firstLine);
        const next: ProfileState = await ProfileStore.addRemote(context, remote);
        return {
          ok: true,
          message: `已从剪贴板导入订阅：${name}`,
          state: next,
          importedUid: remote.uid,
          isRemote: true
        };
      }

      let yamlText: string = text;
      let nodeCount: number = 0;
      if (!ClipboardImportService.looksLikeClashYaml(text)) {
        const converted: ConvertedSubscription = GenericSubscriptionConverterService.normalizeToClashYaml(text);
        if (!converted.ok) {
          return ClipboardImportService.failure('剪贴板内容不是订阅 URL、节点链接或 Clash YAML', state);
        }
        yamlText = converted.text;
        nodeCount = converted.nodeCount;
      }

      const uid: string = `clipboard_${Date.now()}`;
      const dir: string = `${context.filesDir}/profiles`;
      await ClipboardImportService.ensureDir(dir);
      const path: string = `${dir}/${uid}.yaml`;
      await ClipboardImportService.writeText(path, yamlText);
      const nodes: ParsedProxyNode[] = ClashConfigParserService.parseProxyNodes(yamlText);
      const finalCount: number = nodes.length > 0 ? nodes.length : nodeCount;
      const profile: ClashProfile = createLocalProfile('剪贴板配置', path, finalCount, ClipboardImportService.formatBytes(yamlText.length));
      const nextState: ProfileState = await ProfileStore.replace(context, profile);
      return {
        ok: true,
        message: `已从剪贴板导入本地配置，解析 ${finalCount} 个节点`,
        state: nextState,
        importedUid: profile.uid,
        isRemote: false
      };
    } catch (err) {
      const detail: string = err ? String(err) : '';
      const hint: string = detail.length > 0 ? `（${detail}）` : '';
      return ClipboardImportService.failure(`剪贴板读取失败，请确认已复制文本并允许粘贴${hint}`, state);
    }
  }

  private static looksLikeClashYaml(text: string): boolean {
    return text.indexOf('proxies:') >= 0 ||
      text.indexOf('proxy-providers:') >= 0 ||
      text.indexOf('proxy-groups:') >= 0 ||
      text.indexOf('rules:') >= 0;
  }

  private static async ensureDir(path: string): Promise<void> {
    try {
      await fileIo.mkdir(path, true);
    } catch (err) {
    }
  }

  private static async writeText(path: string, text: string): Promise<void> {
    let file: fileIo.File | undefined = undefined;
    try {
      file = fileIo.openSync(path, fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
      await fileIo.write(file.fd, text);
    } finally {
      if (file) {
        try {
          fileIo.closeSync(file);
        } catch (err) {
        }
      }
    }
  }

  private static createProfileNameFromUrl(url: string): string {
    let value: string = url.replace('https://', '').replace('http://', '');
    const slashIndex: number = value.indexOf('/');
    if (slashIndex > 0) {
      value = value.substring(0, slashIndex);
    }
    return value.length > 0 ? value : '远程订阅';
  }

  private static formatBytes(length: number): string {
    if (length < 1024) {
      return `${length} B`;
    }
    if (length < 1024 * 1024) {
      return `${Math.round(length / 1024)} KB`;
    }
    return `${Math.round(length / 1024 / 1024)} MB`;
  }

  private static failure(message: string, state: ProfileState): ClipboardImportResult {
    return {
      ok: false,
      message: message,
      state: state,
      importedUid: '',
      isRemote: false
    };
  }
}
