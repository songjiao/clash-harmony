import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { ClashProfile, ProfileState } from '../models/Profile';
import { ClashConfigParserService } from './ClashConfigParserService';
import { ProfileStore } from './ProfileStore';

export type ProfileVersionSource = 'import' | 'edit' | 'rule' | 'rollback';

export interface ProfileVersionEntry {
  version: number;
  note: string;
  source: ProfileVersionSource;
  createdAt: number;
  sizeBytes: number;
  nodeCount: number;
  ruleCount: number;
  filePath: string;
}

export interface ProfileVersionManifest {
  uid: string;
  activeVersion: number;
  nextVersion: number;
  versions: ProfileVersionEntry[];
}

export interface VersionCommitResult {
  ok: boolean;
  message: string;
  state: ProfileState;
  manifest: ProfileVersionManifest;
  version: number;
}

export class ProfileVersionService {
  static async loadManifest(context: common.Context, profile: ClashProfile): Promise<ProfileVersionManifest> {
    const baseDir: string = ProfileVersionService.profileVersionDir(context, profile.uid);
    const metaPath: string = `${baseDir}/meta.json`;
    try {
      if (await fileIo.access(metaPath)) {
        const raw: string = await fileIo.readText(metaPath);
        const parsed = JSON.parse(raw) as ProfileVersionManifest;
        if (parsed && Array.isArray(parsed.versions) && parsed.versions.length > 0) {
          return parsed;
        }
      }
    } catch (_err) {
    }

    // Bootstrap v1 snapshot from existing profile.filePath so legacy profiles immediately get version history.
    const initialManifest: ProfileVersionManifest = {
      uid: profile.uid,
      activeVersion: 0,
      nextVersion: 1,
      versions: []
    };
    if (profile.filePath.length > 0) {
      try {
        if (await fileIo.access(profile.filePath)) {
          const text: string = await fileIo.readText(profile.filePath);
          await ProfileVersionService.ensureDir(baseDir);
          const v1Path: string = `${baseDir}/v1.yaml`;
          await ProfileVersionService.writeText(v1Path, text);
          const nodeCount: number = ClashConfigParserService.parseProxyNodes(text).length;
          const ruleCount: number = ProfileVersionService.countRulesFast(text);
          initialManifest.activeVersion = 1;
          initialManifest.nextVersion = 2;
          initialManifest.versions.push({
            version: 1,
            note: '初始导入版本',
            source: 'import',
            createdAt: profile.updatedAt > 0 ? profile.updatedAt : Date.now(),
            sizeBytes: text.length,
            nodeCount: nodeCount,
            ruleCount: ruleCount,
            filePath: v1Path
          });
          await ProfileVersionService.saveManifest(context, initialManifest);
        }
      } catch (_err) {
      }
    }
    return initialManifest;
  }

  static async readCurrentText(context: common.Context, profile: ClashProfile): Promise<string> {
    const manifest: ProfileVersionManifest = await ProfileVersionService.loadManifest(context, profile);
    const active: ProfileVersionEntry | undefined = ProfileVersionService.findVersion(manifest, manifest.activeVersion);
    if (active && active.filePath.length > 0) {
      try {
        if (await fileIo.access(active.filePath)) {
          return await fileIo.readText(active.filePath);
        }
      } catch (_err) {
      }
    }
    if (profile.filePath.length > 0) {
      try {
        if (await fileIo.access(profile.filePath)) {
          return await fileIo.readText(profile.filePath);
        }
      } catch (_err) {
      }
    }
    return '';
  }

  static async readVersionText(filePath: string): Promise<string> {
    if (filePath.length === 0) {
      return '';
    }
    try {
      if (await fileIo.access(filePath)) {
        return await fileIo.readText(filePath);
      }
    } catch (_err) {
    }
    return '';
  }

  static async commitNewVersion(
    context: common.Context,
    profile: ClashProfile,
    yamlText: string,
    source: ProfileVersionSource,
    note: string
  ): Promise<VersionCommitResult> {
    const manifest: ProfileVersionManifest = await ProfileVersionService.loadManifest(context, profile);
    const baseDir: string = ProfileVersionService.profileVersionDir(context, profile.uid);
    await ProfileVersionService.ensureDir(baseDir);

    const nextVer: number = manifest.nextVersion > 0 ? manifest.nextVersion : manifest.versions.length + 1;
    const versionFilePath: string = `${baseDir}/v${nextVer}.yaml`;
    await ProfileVersionService.writeText(versionFilePath, yamlText);

    // Keep legacy profile.filePath in sync if it points elsewhere.
    if (profile.filePath.length > 0 && profile.filePath !== versionFilePath) {
      try {
        await ProfileVersionService.writeText(profile.filePath, yamlText);
      } catch (_err) {
      }
    }

    const nodeCount: number = ClashConfigParserService.parseProxyNodes(yamlText).length;
    const ruleCount: number = ProfileVersionService.countRulesFast(yamlText);
    const now: number = Date.now();
    const entry: ProfileVersionEntry = {
      version: nextVer,
      note: note.trim().length > 0 ? note.trim() : ProfileVersionService.defaultNote(source),
      source: source,
      createdAt: now,
      sizeBytes: yamlText.length,
      nodeCount: nodeCount,
      ruleCount: ruleCount,
      filePath: versionFilePath
    };

    const nextVersions: ProfileVersionEntry[] = [];
    for (let i = 0; i < manifest.versions.length; i++) {
      nextVersions.push(manifest.versions[i]);
    }
    nextVersions.push(entry);

    const nextManifest: ProfileVersionManifest = {
      uid: profile.uid,
      activeVersion: nextVer,
      nextVersion: nextVer + 1,
      versions: nextVersions
    };
    await ProfileVersionService.saveManifest(context, nextManifest);

    const updatedProfile: ClashProfile = {
      uid: profile.uid,
      type: profile.type,
      name: profile.name,
      source: profile.source,
      userAgent: profile.userAgent ? profile.userAgent : '',
      filePath: versionFilePath,
      updatedAt: now,
      nodeCount: nodeCount,
      traffic: profile.traffic && profile.traffic.length > 0 && profile.traffic !== '未知'
        ? profile.traffic
        : ProfileVersionService.formatSize(yamlText.length)
    };
    const nextState: ProfileState = await ProfileStore.replace(context, updatedProfile);
    return {
      ok: true,
      message: `已保存为 v${nextVer}（${nodeCount} 节点 / ${ruleCount} 规则）`,
      state: nextState,
      manifest: nextManifest,
      version: nextVer
    };
  }

  static async rollbackToVersion(
    context: common.Context,
    profile: ClashProfile,
    targetVersion: number
  ): Promise<VersionCommitResult> {
    const manifest: ProfileVersionManifest = await ProfileVersionService.loadManifest(context, profile);
    const target: ProfileVersionEntry | undefined = ProfileVersionService.findVersion(manifest, targetVersion);
    if (!target) {
      const currentState: ProfileState = await ProfileStore.load(context);
      return {
        ok: false,
        message: `未找到历史版本 v${targetVersion}`,
        state: currentState,
        manifest: manifest,
        version: manifest.activeVersion
      };
    }
    const text: string = await ProfileVersionService.readVersionText(target.filePath);
    if (text.length === 0) {
      const currentState: ProfileState = await ProfileStore.load(context);
      return {
        ok: false,
        message: `历史版本 v${targetVersion} 文件为空或不可读`,
        state: currentState,
        manifest: manifest,
        version: manifest.activeVersion
      };
    }
    return ProfileVersionService.commitNewVersion(
      context,
      profile,
      text,
      'rollback',
      `回滚至 v${targetVersion}`
    );
  }

  static findVersion(manifest: ProfileVersionManifest, version: number): ProfileVersionEntry | undefined {
    for (let i = 0; i < manifest.versions.length; i++) {
      if (manifest.versions[i].version === version) {
        return manifest.versions[i];
      }
    }
    return undefined;
  }

  static reversedVersions(manifest: ProfileVersionManifest): ProfileVersionEntry[] {
    const out: ProfileVersionEntry[] = [];
    for (let i = manifest.versions.length - 1; i >= 0; i--) {
      out.push(manifest.versions[i]);
    }
    return out;
  }

  static sourceLabel(source: ProfileVersionSource): string {
    if (source === 'edit') {
      return '在线编辑';
    }
    if (source === 'rule') {
      return '规则调整';
    }
    if (source === 'rollback') {
      return '版本回滚';
    }
    return '导入';
  }

  private static profileVersionDir(context: common.Context, uid: string): string {
    return `${context.filesDir}/profile_versions/${uid}`;
  }

  private static async saveManifest(context: common.Context, manifest: ProfileVersionManifest): Promise<void> {
    const dir: string = ProfileVersionService.profileVersionDir(context, manifest.uid);
    await ProfileVersionService.ensureDir(dir);
    await ProfileVersionService.writeText(`${dir}/meta.json`, JSON.stringify(manifest, null, 2));
  }

  private static async ensureDir(path: string): Promise<void> {
    try {
      await fileIo.mkdir(path, true);
    } catch (_err) {
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
        } catch (_err) {
        }
      }
    }
  }

  private static countRulesFast(yamlText: string): number {
    const lines: string[] = yamlText.split('\n');
    let inRules: boolean = false;
    let count: number = 0;
    for (let i = 0; i < lines.length; i++) {
      const line: string = lines[i];
      const trimmed: string = line.trim();
      if (trimmed.length === 0 || trimmed.startsWith('#')) {
        continue;
      }
      if (!line.startsWith(' ') && !line.startsWith('\t') && !line.startsWith('-')) {
        inRules = trimmed === 'rules:';
        continue;
      }
      if (inRules && trimmed.startsWith('- ')) {
        count++;
      }
    }
    return count;
  }

  private static defaultNote(source: ProfileVersionSource): string {
    if (source === 'edit') {
      return '手动修改 YAML';
    }
    if (source === 'rule') {
      return '可视化规则调整';
    }
    if (source === 'rollback') {
      return '回滚历史版本';
    }
    return '导入配置';
  }

  private static formatSize(length: number): string {
    if (length < 1024) {
      return `${length} B`;
    }
    return `${Math.round(length / 1024)} KB`;
  }
}
