import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';

export interface TailscaleNativePrefs {
  managedByApp: boolean;
  enabled: boolean;
  proxyName: string;
  hostname: string;
  controlUrl: string;
  acceptRoutes: boolean;
  exitNode: string;
  exitNodeAllowLan: boolean;
  authKey: string;
  autoInjectMagicDns: boolean;
  tailnetSuffix: string;
  autoSyncSplitDns: boolean;
  splitDnsDomains: string[];
}

export function createDefaultTailscalePrefs(): TailscaleNativePrefs {
  return {
    managedByApp: true,
    enabled: true,
    proxyName: 'Tailscale',
    hostname: 'harmony-phone',
    controlUrl: '',
    acceptRoutes: true,
    exitNode: '',
    exitNodeAllowLan: true,
    authKey: '',
    autoInjectMagicDns: true,
    tailnetSuffix: '',
    autoSyncSplitDns: true,
    splitDnsDomains: []
  };
}

export class TailscalePrefsService {
  static getPrefsPath(context: common.Context): string {
    return `${context.filesDir}/runtime/tailscale-prefs.json`;
  }

  static async load(context: common.Context): Promise<TailscaleNativePrefs> {
    const defaults: TailscaleNativePrefs = createDefaultTailscalePrefs();
    const path: string = TailscalePrefsService.getPrefsPath(context);
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
      return {
        managedByApp: typeof parsed['managedByApp'] === 'boolean' ? parsed['managedByApp'] as boolean : defaults.managedByApp,
        enabled: typeof parsed['enabled'] === 'boolean' ? parsed['enabled'] as boolean : defaults.enabled,
        proxyName: TailscalePrefsService.readNonEmptyString(parsed, 'proxyName', defaults.proxyName),
        hostname: TailscalePrefsService.readNonEmptyString(parsed, 'hostname', defaults.hostname),
        controlUrl: TailscalePrefsService.readString(parsed, 'controlUrl'),
        acceptRoutes: typeof parsed['acceptRoutes'] === 'boolean' ? parsed['acceptRoutes'] as boolean : defaults.acceptRoutes,
        exitNode: TailscalePrefsService.readString(parsed, 'exitNode'),
        exitNodeAllowLan: typeof parsed['exitNodeAllowLan'] === 'boolean' ? parsed['exitNodeAllowLan'] as boolean : defaults.exitNodeAllowLan,
        authKey: TailscalePrefsService.readString(parsed, 'authKey'),
        autoInjectMagicDns: typeof parsed['autoInjectMagicDns'] === 'boolean' ? parsed['autoInjectMagicDns'] as boolean : defaults.autoInjectMagicDns,
        tailnetSuffix: TailscalePrefsService.readString(parsed, 'tailnetSuffix'),
        autoSyncSplitDns: typeof parsed['autoSyncSplitDns'] === 'boolean' ? parsed['autoSyncSplitDns'] as boolean : defaults.autoSyncSplitDns,
        splitDnsDomains: TailscalePrefsService.readStringArray(parsed, 'splitDnsDomains')
      };
    } catch (_err) {
      return defaults;
    }
  }

  static async save(context: common.Context, prefs: TailscaleNativePrefs): Promise<boolean> {
    const dir: string = `${context.filesDir}/runtime`;
    try {
      await fileIo.mkdir(dir, true);
    } catch (_err) {
    }
    const path: string = TailscalePrefsService.getPrefsPath(context);
    let file: fileIo.File | undefined = undefined;
    try {
      file = fileIo.openSync(path, fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
      await fileIo.write(file.fd, JSON.stringify(prefs, null, 2));
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

  /**
   * Decouples Tailscale parameters from Mihomo YAML:
   * - Removes any existing `type: tailscale` or same-named `Tailscale` entry from `proxies:`.
   * - When `prefs.enabled` is true, injects a clean, properly indented `Tailscale` outbound block
   *   built from native Tailscale prefs.
   * - Ensures `dns.fake-ip-filter` and `dns.nameserver-policy` contain Tailscale entries if requested.
   */
  static applyTailscalePrefsToYaml(yamlText: string, prefs: TailscaleNativePrefs): string {
    if (!prefs.managedByApp) {
      return yamlText;
    }

    const proxyName: string = prefs.proxyName.trim().length > 0 ? prefs.proxyName.trim() : 'Tailscale';
    const normalized: string = yamlText.replace(/\r\n/g, '\n').replace(/\r/g, '\n');
    const lines: string[] = normalized.split('\n');

    let proxiesHeaderIndex: number = -1;
    let proxiesEndIndex: number = lines.length;
    let listIndent: string = '';

    for (let i = 0; i < lines.length; i++) {
      const line: string = lines[i];
      const trimmed: string = line.trim();
      if (proxiesHeaderIndex < 0) {
        if (!line.startsWith(' ') && !line.startsWith('\t') && trimmed === 'proxies:') {
          proxiesHeaderIndex = i;
        }
        continue;
      }
      if (trimmed.length === 0 || trimmed.startsWith('#')) {
        continue;
      }
      if (!line.startsWith(' ') && !line.startsWith('\t') && !line.startsWith('-')) {
        proxiesEndIndex = i;
        break;
      }
      if (listIndent.length === 0 && trimmed.startsWith('- ')) {
        const dashIdx: number = line.indexOf('-');
        if (dashIdx > 0) {
          listIndent = line.substring(0, dashIdx);
        }
      }
    }

    const builtBlock: string[] = prefs.enabled ? TailscalePrefsService.buildProxyBlockLines(prefs, listIndent) : [];

    let outputLines: string[] = [];
    if (proxiesHeaderIndex < 0) {
      for (let i = 0; i < lines.length; i++) {
        outputLines.push(lines[i]);
      }
      if (builtBlock.length > 0) {
        outputLines.push('');
        outputLines.push('proxies:');
        for (let i = 0; i < builtBlock.length; i++) {
          outputLines.push(builtBlock[i]);
        }
      }
    } else {
      for (let i = 0; i <= proxiesHeaderIndex; i++) {
        outputLines.push(lines[i]);
      }

      // Parse existing proxy blocks and drop any existing Tailscale outbound so we replace cleanly.
      const sectionLines: string[] = lines.slice(proxiesHeaderIndex + 1, proxiesEndIndex);
      const filteredSection: string[] = TailscalePrefsService.stripExistingTailscaleProxy(sectionLines, proxyName);

      if (builtBlock.length > 0) {
        for (let i = 0; i < builtBlock.length; i++) {
          outputLines.push(builtBlock[i]);
        }
      }
      for (let i = 0; i < filteredSection.length; i++) {
        outputLines.push(filteredSection[i]);
      }
      for (let i = proxiesEndIndex; i < lines.length; i++) {
        outputLines.push(lines[i]);
      }
    }

    let resultText: string = outputLines.join('\n');
    const activeSplitDomains: string[] = prefs.enabled && prefs.autoSyncSplitDns
      ? TailscalePrefsService.normalizeDomainList(prefs.splitDnsDomains)
      : [];
    if (prefs.enabled && (prefs.autoInjectMagicDns || activeSplitDomains.length > 0)) {
      resultText = TailscalePrefsService.ensureTailscaleDnsEntries(
        resultText,
        proxyName,
        prefs.autoInjectMagicDns ? prefs.tailnetSuffix : '',
        prefs.autoInjectMagicDns,
        activeSplitDomains
      );
    }
    if (prefs.enabled && activeSplitDomains.length > 0) {
      resultText = TailscalePrefsService.ensureSplitDnsRules(resultText, proxyName, activeSplitDomains);
    }
    if (prefs.enabled) {
      resultText = TailscalePrefsService.ensureTailscaleBaseRules(resultText, proxyName);
    }
    return resultText;
  }

  /**
   * Explicitly writes a Tailscale SplitDNS domain into a profile YAML:
   * - Adds `+.domain: tailscale://<proxyName>` to `dns.nameserver-policy` (while protecting exact DIRECT/proxy subdomains)
   * - Adds `+.domain` to `dns.fake-ip-filter`
   * - Adds/normalizes `DOMAIN-SUFFIX,<domain>,<proxyName>` right after any exact `DOMAIN,*.<domain>,DIRECT` rules
   */
  static applySplitDnsDomainToProfileYaml(yamlText: string, rawDomain: string, proxyName: string): string {
    const cleanDomain: string = TailscalePrefsService.normalizeDomain(rawDomain);
    if (cleanDomain.length === 0) {
      return yamlText;
    }
    const targetProxy: string = proxyName.trim().length > 0 ? proxyName.trim() : 'Tailscale';
    let updated: string = yamlText.replace(/\r\n/g, '\n').replace(/\r/g, '\n');
    updated = TailscalePrefsService.ensureTailscaleDnsEntries(updated, targetProxy, '', false, [cleanDomain]);
    updated = TailscalePrefsService.ensureSplitDnsRules(updated, targetProxy, [cleanDomain]);
    return updated;
  }

  private static buildProxyBlockLines(prefs: TailscaleNativePrefs, indent: string): string[] {
    const fieldIndent: string = `${indent}  `;
    const proxyName: string = prefs.proxyName.trim().length > 0 ? prefs.proxyName.trim() : 'Tailscale';
    const hostname: string = prefs.hostname.trim().length > 0 ? prefs.hostname.trim() : 'harmony-phone';
    const block: string[] = [
      `${indent}- name: ${TailscalePrefsService.quoteIfNeeded(proxyName)}`,
      `${fieldIndent}type: tailscale`,
      `${fieldIndent}udp: true`,
      `${fieldIndent}hostname: ${TailscalePrefsService.quoteIfNeeded(hostname)}`,
      `${fieldIndent}state-dir: tailscale`,
      `${fieldIndent}accept-routes: ${prefs.acceptRoutes ? 'true' : 'false'}`
    ];
    if (prefs.controlUrl.trim().length > 0) {
      block.push(`${fieldIndent}control-url: ${TailscalePrefsService.quoteIfNeeded(prefs.controlUrl.trim())}`);
    }
    if (prefs.authKey.trim().length > 0) {
      block.push(`${fieldIndent}auth-key: ${TailscalePrefsService.quoteIfNeeded(prefs.authKey.trim())}`);
    }
    if (prefs.exitNode.trim().length > 0) {
      block.push(`${fieldIndent}exit-node: ${TailscalePrefsService.quoteIfNeeded(prefs.exitNode.trim())}`);
      block.push(`${fieldIndent}exit-node-allow-lan-access: ${prefs.exitNodeAllowLan ? 'true' : 'false'}`);
    }
    return block;
  }

  private static stripExistingTailscaleProxy(sectionLines: string[], proxyName: string): string[] {
    const blocks: string[][] = [];
    let current: string[] = [];
    for (let i = 0; i < sectionLines.length; i++) {
      const line: string = sectionLines[i];
      const trimmed: string = line.trim();
      const isItemStart: boolean = trimmed.startsWith('- ');
      if (isItemStart) {
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
    const targetLower: string = proxyName.toLowerCase();
    for (let b = 0; b < blocks.length; b++) {
      const block: string[] = blocks[b];
      let isTailscaleBlock: boolean = false;
      for (let j = 0; j < block.length; j++) {
        const t: string = block[j].trim();
        if (t.startsWith('type:') && t.substring(5).trim().toLowerCase() === 'tailscale') {
          isTailscaleBlock = true;
          break;
        }
        if (t.indexOf('type: tailscale') >= 0) {
          isTailscaleBlock = true;
          break;
        }
        if (t.startsWith('- name:') || t.startsWith('name:')) {
          const val: string = TailscalePrefsService.stripQuotes(
            t.startsWith('- name:') ? t.substring(7).trim() : t.substring(5).trim()
          );
          if (val.toLowerCase() === targetLower) {
            isTailscaleBlock = true;
            break;
          }
        }
      }
      if (!isTailscaleBlock) {
        for (let j = 0; j < block.length; j++) {
          kept.push(block[j]);
        }
      }
    }
    return kept;
  }

  private static ensureTailscaleDnsEntries(
    yamlText: string,
    proxyName: string,
    tailnetSuffix: string,
    includeMagicDns: boolean,
    splitDomains: string[]
  ): string {
    const lines: string[] = yamlText.split('\n');
    let dnsStart: number = -1;
    let dnsEnd: number = lines.length;
    for (let i = 0; i < lines.length; i++) {
      const line: string = lines[i];
      const trimmed: string = line.trim();
      if (dnsStart < 0) {
        if (!line.startsWith(' ') && !line.startsWith('\t') && trimmed === 'dns:') {
          dnsStart = i;
        }
        continue;
      }
      if (trimmed.length === 0 || trimmed.startsWith('#')) {
        continue;
      }
      if (!line.startsWith(' ') && !line.startsWith('\t') && !line.startsWith('-')) {
        dnsEnd = i;
        break;
      }
    }

    if (dnsStart < 0) {
      return yamlText;
    }

    const dnsSectionLines: string[] = lines.slice(dnsStart, dnsEnd);
    const dnsText: string = dnsSectionLines.join('\n');
    const dnsTextLower: string = dnsText.toLowerCase();
    const policyTarget: string = `tailscale://${proxyName}`;
    const directDnsServer: string = TailscalePrefsService.detectPrimaryPublicDns(dnsSectionLines);
    const protectedHosts: string[] = TailscalePrefsService.collectProtectedSubdomains(lines, splitDomains);

    // Detect actual direct child indent inside `dns:` (handles 2-space and 4-space YAML like BitzNet).
    const dnsChildIndent: string = TailscalePrefsService.detectSectionChildIndent(dnsSectionLines, '  ');
    const hasPolicyHeader: boolean = TailscalePrefsService.hasTrimmedLine(dnsSectionLines, 'nameserver-policy:');
    const hasFilterHeader: boolean = TailscalePrefsService.hasTrimmedLine(dnsSectionLines, 'fake-ip-filter:');
    const policyIndent: string = hasPolicyHeader
      ? TailscalePrefsService.detectMappingChildIndent(dnsSectionLines, 'nameserver-policy:', `${dnsChildIndent}  `)
      : `${dnsChildIndent}  `;
    const filterItemPrefix: string = hasFilterHeader
      ? TailscalePrefsService.detectSequenceItemPrefix(dnsSectionLines, 'fake-ip-filter:', `${dnsChildIndent}  - `)
      : `${dnsChildIndent}  - `;

    const extraPolicyLines: string[] = [];
    if (includeMagicDns) {
      if (dnsTextLower.indexOf('+.ts.net:') < 0) {
        extraPolicyLines.push(`${policyIndent}+.ts.net: ${policyTarget}`);
      }
      const cleanSuffix: string = TailscalePrefsService.normalizeDomain(tailnetSuffix);
      if (cleanSuffix.length > 0 && dnsTextLower.indexOf(`+.${cleanSuffix}:`) < 0) {
        extraPolicyLines.push(`${policyIndent}+.${cleanSuffix}: ${policyTarget}`);
      }
    }

    for (let i = 0; i < splitDomains.length; i++) {
      const dom: string = splitDomains[i];
      if (dnsTextLower.indexOf(`+.${dom}:`) < 0) {
        extraPolicyLines.push(`${policyIndent}+.${dom}: ${policyTarget}`);
      }
    }
    for (let i = 0; i < protectedHosts.length; i++) {
      const host: string = protectedHosts[i];
      if (dnsTextLower.indexOf(`${host}:`) < 0) {
        extraPolicyLines.push(`${policyIndent}${host}: ${directDnsServer}`);
      }
    }

    const extraFilterLines: string[] = [];
    const requiredFilters: string[] = [];
    if (includeMagicDns) {
      requiredFilters.push('+.tailscale.com', '+.tailscale.io', '+.ts.net');
      const cleanSuffix: string = TailscalePrefsService.normalizeDomain(tailnetSuffix);
      if (cleanSuffix.length > 0) {
        requiredFilters.push(`+.${cleanSuffix}`);
      }
    }
    for (let i = 0; i < splitDomains.length; i++) {
      requiredFilters.push(`+.${splitDomains[i]}`);
    }
    for (let i = 0; i < requiredFilters.length; i++) {
      const entry: string = requiredFilters[i];
      if (!TailscalePrefsService.hasFilterEntry(dnsTextLower, entry)) {
        extraFilterLines.push(`${filterItemPrefix}${entry}`);
      }
    }

    if (extraPolicyLines.length === 0 && extraFilterLines.length === 0) {
      return yamlText;
    }

    const out: string[] = [];
    let insertedPolicy: boolean = false;
    let insertedFilter: boolean = false;
    for (let i = 0; i < lines.length; i++) {
      out.push(lines[i]);
      if (i > dnsStart && i < dnsEnd) {
        const trimmed: string = lines[i].trim();
        if (!insertedPolicy && trimmed === 'nameserver-policy:' && extraPolicyLines.length > 0) {
          for (let k = 0; k < extraPolicyLines.length; k++) {
            out.push(extraPolicyLines[k]);
          }
          insertedPolicy = true;
        }
        if (!insertedFilter && trimmed === 'fake-ip-filter:' && extraFilterLines.length > 0) {
          for (let k = 0; k < extraFilterLines.length; k++) {
            out.push(extraFilterLines[k]);
          }
          insertedFilter = true;
        }
      }
      if (i === dnsEnd - 1) {
        if (!insertedPolicy && extraPolicyLines.length > 0) {
          out.push(`${dnsChildIndent}nameserver-policy:`);
          for (let k = 0; k < extraPolicyLines.length; k++) {
            out.push(extraPolicyLines[k]);
          }
        }
        if (!insertedFilter && extraFilterLines.length > 0) {
          out.push(`${dnsChildIndent}fake-ip-filter:`);
          for (let k = 0; k < extraFilterLines.length; k++) {
            out.push(extraFilterLines[k]);
          }
        }
      }
    }
    return out.join('\n');
  }

  private static ensureSplitDnsRules(yamlText: string, proxyName: string, splitDomains: string[]): string {
    if (splitDomains.length === 0) {
      return yamlText;
    }
    const lines: string[] = yamlText.split('\n');
    let rulesHeader: number = -1;
    let rulesEnd: number = lines.length;
    let rulePrefix: string = '- ';

    for (let i = 0; i < lines.length; i++) {
      const line: string = lines[i];
      const trimmed: string = line.trim();
      if (rulesHeader < 0) {
        if (!line.startsWith(' ') && !line.startsWith('\t') && trimmed === 'rules:') {
          rulesHeader = i;
        }
        continue;
      }
      if (trimmed.length === 0 || trimmed.startsWith('#')) {
        continue;
      }
      if (!line.startsWith(' ') && !line.startsWith('\t') && !line.startsWith('-')) {
        rulesEnd = i;
        break;
      }
      if (trimmed.startsWith('- ')) {
        const dashIdx: number = line.indexOf('-');
        rulePrefix = `${line.substring(0, dashIdx)}- `;
        break;
      }
    }

    if (rulesHeader < 0) {
      return yamlText;
    }

    // Re-scan end index accurately when we broke early on first rule item.
    rulesEnd = lines.length;
    for (let i = rulesHeader + 1; i < lines.length; i++) {
      const line: string = lines[i];
      const trimmed: string = line.trim();
      if (trimmed.length === 0 || trimmed.startsWith('#')) {
        continue;
      }
      if (!line.startsWith(' ') && !line.startsWith('\t') && !line.startsWith('-')) {
        rulesEnd = i;
        break;
      }
    }

    // Normalize any malformed rule like `DOMAIN-SUFFIX,sjfarm.cc,Tailscale,DIRECT` and track existing rules.
    const working: string[] = [];
    for (let i = 0; i < lines.length; i++) {
      working.push(lines[i]);
    }

    for (let d = 0; d < splitDomains.length; d++) {
      const domain: string = splitDomains[d];
      let hasSuffixRule: boolean = false;
      let insertAfterIdx: number = rulesHeader;

      for (let i = rulesHeader + 1; i < rulesEnd; i++) {
        const trimmed: string = working[i].trim();
        if (!trimmed.startsWith('- ')) {
          continue;
        }
        const rawRule: string = TailscalePrefsService.stripQuotes(trimmed.substring(2).trim());
        const parts: string[] = rawRule.split(',');
        if (parts.length < 3) {
          continue;
        }
        const ruleType: string = parts[0].trim().toUpperCase();
        const payload: string = parts[1].trim().toLowerCase();
        const target: string = parts[2].trim();

        if (ruleType === 'DOMAIN-SUFFIX' && payload === domain) {
          hasSuffixRule = true;
          // Clean up accidental trailing extra arg (e.g. `DOMAIN-SUFFIX,sjfarm.cc,Tailscale,DIRECT `)
          if (parts.length > 3 && target.toLowerCase() === proxyName.toLowerCase()) {
            working[i] = `${rulePrefix}DOMAIN-SUFFIX,${domain},${proxyName}`;
          }
        } else if (ruleType === 'DOMAIN' && (payload === domain || payload.endsWith(`.${domain}`))) {
          // Keep exact DOMAIN rules (like derp.sjfarm.cc / node.sjfarm.cc DIRECT) ABOVE the suffix rule!
          insertAfterIdx = i;
        } else if (
          insertAfterIdx === rulesHeader &&
          (payload === 'tailscale.com' || payload === 'tailscale.io')
        ) {
          insertAfterIdx = i;
        }
      }

      if (!hasSuffixRule) {
        const newRuleLine: string = `${rulePrefix}DOMAIN-SUFFIX,${domain},${proxyName}`;
        working.splice(insertAfterIdx + 1, 0, newRuleLine);
        rulesEnd = rulesEnd + 1;
      }
    }

    return working.join('\n');
  }

  private static ensureTailscaleBaseRules(yamlText: string, proxyName: string): string {
    const lines: string[] = yamlText.split('\n');
    let rulesHeader: number = -1;
    let rulesEnd: number = lines.length;
    let rulePrefix: string = '  - ';
    let foundPrefix: boolean = false;
    for (let i = 0; i < lines.length; i++) {
      const line: string = lines[i];
      const trimmed: string = line.trim();
      if (rulesHeader < 0) {
        if (!line.startsWith(' ') && !line.startsWith('\t') && trimmed === 'rules:') {
          rulesHeader = i;
        }
        continue;
      }
      if (trimmed.length === 0 || trimmed.startsWith('#')) {
        continue;
      }
      if (!line.startsWith(' ') && !line.startsWith('\t') && !line.startsWith('-')) {
        rulesEnd = i;
        break;
      }
      if (!foundPrefix && trimmed.startsWith('- ')) {
        const dashIdx: number = line.indexOf('-');
        rulePrefix = `${line.substring(0, dashIdx)}- `;
        foundPrefix = true;
      }
    }
    if (rulesHeader < 0) {
      return yamlText;
    }

    const sectionLower: string = lines.slice(rulesHeader, rulesEnd).join('\n').toLowerCase();
    const proxyLower: string = proxyName.toLowerCase();
    const toInsert: string[] = [];
    if (sectionLower.indexOf('tailscale.com,') < 0) {
      toInsert.push(`${rulePrefix}DOMAIN-SUFFIX,tailscale.com,DIRECT`);
    }
    if (sectionLower.indexOf('tailscale.io,') < 0) {
      toInsert.push(`${rulePrefix}DOMAIN-SUFFIX,tailscale.io,DIRECT`);
    }
    if (sectionLower.indexOf('domain-suffix,ts.net,') < 0) {
      toInsert.push(`${rulePrefix}DOMAIN-SUFFIX,ts.net,${proxyName}`);
    }
    if (sectionLower.indexOf(`100.64.0.0/10,${proxyLower}`) < 0) {
      toInsert.push(`${rulePrefix}IP-CIDR,100.64.0.0/10,${proxyName},no-resolve`);
    }
    if (sectionLower.indexOf(`fd7a:115c:a1e0::/48,${proxyLower}`) < 0) {
      toInsert.push(`${rulePrefix}IP-CIDR6,fd7a:115c:a1e0::/48,${proxyName},no-resolve`);
    }
    if (toInsert.length === 0) {
      return yamlText;
    }

    const out: string[] = [];
    for (let i = 0; i <= rulesHeader; i++) {
      out.push(lines[i]);
    }
    for (let i = 0; i < toInsert.length; i++) {
      out.push(toInsert[i]);
    }
    for (let i = rulesHeader + 1; i < lines.length; i++) {
      out.push(lines[i]);
    }
    return out.join('\n');
  }

  private static collectProtectedSubdomains(lines: string[], splitDomains: string[]): string[] {
    if (splitDomains.length === 0) {
      return [];
    }
    const found: string[] = [];
    const seen: Record<string, boolean> = {};
    const maybeAdd = (rawHost: string): void => {
      const host: string = TailscalePrefsService.normalizeDomain(TailscalePrefsService.stripQuotes(rawHost));
      if (host.length === 0 || seen[host]) {
        return;
      }
      for (let i = 0; i < splitDomains.length; i++) {
        const dom: string = splitDomains[i];
        if (host !== dom && host.endsWith(`.${dom}`)) {
          seen[host] = true;
          found.push(host);
          return;
        }
      }
    };

    for (let i = 0; i < lines.length; i++) {
      const trimmed: string = lines[i].trim();
      if (trimmed.length === 0 || trimmed.startsWith('#')) {
        continue;
      }
      // Proxy server host (e.g. `server: node.sjfarm.cc`)
      if (trimmed.startsWith('server:')) {
        maybeAdd(trimmed.substring(7).trim());
        continue;
      }
      // Exact DIRECT rule (e.g. `- DOMAIN,derp.sjfarm.cc,DIRECT`)
      if (trimmed.startsWith('- ')) {
        const ruleBody: string = TailscalePrefsService.stripQuotes(trimmed.substring(2).trim());
        const parts: string[] = ruleBody.split(',');
        if (parts.length >= 3 && parts[0].trim().toUpperCase() === 'DOMAIN' && parts[2].trim().toUpperCase() === 'DIRECT') {
          maybeAdd(parts[1].trim());
        }
      }
    }
    return found;
  }

  private static detectPrimaryPublicDns(dnsLines: string[]): string {
    const preferredKeys: string[] = ['default-nameserver:', 'proxy-server-nameserver:', 'nameserver:'];
    for (let k = 0; k < preferredKeys.length; k++) {
      const key: string = preferredKeys[k];
      for (let i = 0; i < dnsLines.length; i++) {
        if (dnsLines[i].trim() !== key) {
          continue;
        }
        for (let j = i + 1; j < dnsLines.length; j++) {
          const t: string = dnsLines[j].trim();
          if (t.length === 0 || t.startsWith('#')) {
            continue;
          }
          if (t.startsWith('- ')) {
            const candidate: string = TailscalePrefsService.stripQuotes(t.substring(2).trim());
            if (candidate.length > 0 && !candidate.toLowerCase().startsWith('tailscale://')) {
              return candidate;
            }
          } else {
            break;
          }
        }
      }
    }
    return '223.5.5.5';
  }

  private static detectSectionChildIndent(sectionLines: string[], fallbackIndent: string): string {
    let best: string = '';
    for (let i = 1; i < sectionLines.length; i++) {
      const t: string = sectionLines[i].trim();
      if (t.length === 0 || t.startsWith('#')) {
        continue;
      }
      const sp: string = TailscalePrefsService.leadingSpaces(sectionLines[i]);
      if (sp.length > 0 && (best.length === 0 || sp.length < best.length)) {
        best = sp;
      }
    }
    return best.length > 0 ? best : fallbackIndent;
  }

  private static hasTrimmedLine(sectionLines: string[], target: string): boolean {
    for (let i = 0; i < sectionLines.length; i++) {
      if (sectionLines[i].trim() === target) {
        return true;
      }
    }
    return false;
  }

  private static detectMappingChildIndent(sectionLines: string[], headerKey: string, fallbackIndent: string): string {
    for (let i = 0; i < sectionLines.length; i++) {
      if (sectionLines[i].trim() !== headerKey) {
        continue;
      }
      const headerIndentLen: number = TailscalePrefsService.leadingSpaces(sectionLines[i]).length;
      for (let j = i + 1; j < sectionLines.length; j++) {
        const line: string = sectionLines[j];
        const t: string = line.trim();
        if (t.length === 0 || t.startsWith('#')) {
          continue;
        }
        const childIndent: string = TailscalePrefsService.leadingSpaces(line);
        if (childIndent.length > headerIndentLen) {
          return childIndent;
        }
        break;
      }
    }
    return fallbackIndent;
  }

  private static detectSequenceItemPrefix(sectionLines: string[], headerKey: string, fallbackPrefix: string): string {
    for (let i = 0; i < sectionLines.length; i++) {
      if (sectionLines[i].trim() !== headerKey) {
        continue;
      }
      for (let j = i + 1; j < sectionLines.length; j++) {
        const line: string = sectionLines[j];
        const t: string = line.trim();
        if (t.length === 0 || t.startsWith('#')) {
          continue;
        }
        if (t.startsWith('- ')) {
          const dashIdx: number = line.indexOf('-');
          return `${line.substring(0, dashIdx)}- `;
        }
        break;
      }
    }
    return fallbackPrefix;
  }

  private static leadingSpaces(line: string): string {
    let idx: number = 0;
    while (idx < line.length && (line[idx] === ' ' || line[idx] === '\t')) {
      idx++;
    }
    return line.substring(0, idx);
  }

  private static hasFilterEntry(dnsTextLower: string, entry: string): boolean {
    const lower: string = entry.toLowerCase();
    return dnsTextLower.indexOf(`- ${lower}`) >= 0 ||
      dnsTextLower.indexOf(`- '${lower}'`) >= 0 ||
      dnsTextLower.indexOf(`- "${lower}"`) >= 0;
  }

  private static normalizeDomain(raw: string): string {
    let s: string = raw.trim().toLowerCase();
    while (s.startsWith('+.')) {
      s = s.substring(2);
    }
    while (s.startsWith('.')) {
      s = s.substring(1);
    }
    while (s.endsWith('.')) {
      s = s.substring(0, s.length - 1);
    }
    return s;
  }

  private static normalizeDomainList(items: string[]): string[] {
    const out: string[] = [];
    const seen: Record<string, boolean> = {};
    for (let i = 0; i < items.length; i++) {
      const clean: string = TailscalePrefsService.normalizeDomain(items[i]);
      if (clean.length > 0 && !seen[clean]) {
        seen[clean] = true;
        out.push(clean);
      }
    }
    return out;
  }

  private static readStringArray(obj: Record<string, Object>, key: string): string[] {
    const raw: Object | undefined = obj[key];
    if (!Array.isArray(raw)) {
      return [];
    }
    const arr: Object[] = raw as Object[];
    const out: string[] = [];
    for (let i = 0; i < arr.length; i++) {
      if (typeof arr[i] === 'string') {
        const clean: string = TailscalePrefsService.normalizeDomain(arr[i] as string);
        if (clean.length > 0 && out.indexOf(clean) < 0) {
          out.push(clean);
        }
      }
    }
    return out;
  }

  private static readString(obj: Record<string, Object>, key: string): string {
    const val: Object | undefined = obj[key];
    return typeof val === 'string' ? (val as string).trim() : '';
  }

  private static readNonEmptyString(obj: Record<string, Object>, key: string, fallback: string): string {
    const val: string = TailscalePrefsService.readString(obj, key);
    return val.length > 0 ? val : fallback;
  }

  private static stripQuotes(val: string): string {
    if ((val.startsWith('"') && val.endsWith('"')) || (val.startsWith("'") && val.endsWith("'"))) {
      return val.length >= 2 ? val.substring(1, val.length - 1) : val;
    }
    return val;
  }

  private static quoteIfNeeded(val: string): string {
    if (val.indexOf(':') >= 0 || val.indexOf(' ') >= 0 || val.indexOf('#') >= 0) {
      return `"${val.replace(/"/g, '\\"')}"`;
    }
    return val;
  }
}
