import { ClashConfigParserService, ParsedProxyNode } from './ClashConfigParserService';

export type TrafficCategory = 'tailscale' | 'proxy' | 'direct' | 'reject';

export interface ParsedGroupDef {
  name: string;
  type: string;
  proxies: string[];
}

export interface ParsedRuleItem {
  index: number;
  lineIndex: number;
  raw: string;
  ruleType: string;
  payload: string;
  target: string;
  noResolve: boolean;
  category: TrafficCategory;
  chainLabel: string;
}

export interface DnsPolicyItem {
  domain: string;
  server: string;
}

export interface FlowBucket {
  id: string;
  title: string;
  category: TrafficCategory;
  targetName: string;
  chainPreview: string;
  ruleCount: number;
  sampleRules: string[];
}

export interface TrafficAnalysis {
  proxies: ParsedProxyNode[];
  groups: ParsedGroupDef[];
  rules: ParsedRuleItem[];
  dnsPolicies: DnsPolicyItem[];
  fakeIpFilters: string[];
  buckets: FlowBucket[];
  availableTargets: string[];
  tailscaleRuleCount: number;
  proxyRuleCount: number;
  directRuleCount: number;
  rejectRuleCount: number;
}

export interface RouteSimulationResult {
  query: string;
  matched: boolean;
  ruleIndex: number;
  matchedRuleRaw: string;
  target: string;
  category: TrafficCategory;
  chain: string[];
  dnsNote: string;
}

export class TrafficRuleAnalyzerService {
  static analyze(yamlText: string): TrafficAnalysis {
    const normalized: string = yamlText.replace(/\r\n/g, '\n').replace(/\r/g, '\n');
    const lines: string[] = normalized.split('\n');
    const proxies: ParsedProxyNode[] = ClashConfigParserService.parseProxyNodes(normalized);
    const groups: ParsedGroupDef[] = TrafficRuleAnalyzerService.parseProxyGroups(lines);
    const dnsPolicies: DnsPolicyItem[] = TrafficRuleAnalyzerService.parseDnsPolicies(lines);
    const fakeIpFilters: string[] = TrafficRuleAnalyzerService.parseFakeIpFilters(lines);

    const groupMap: Record<string, ParsedGroupDef> = {};
    for (let i = 0; i < groups.length; i++) {
      groupMap[groups[i].name] = groups[i];
    }

    const tailscaleNames: Record<string, boolean> = {};
    tailscaleNames['Tailscale'] = true;
    for (let i = 0; i < proxies.length; i++) {
      if (proxies[i].type.toLowerCase() === 'tailscale') {
        tailscaleNames[proxies[i].name] = true;
      }
    }

    const rules: ParsedRuleItem[] = TrafficRuleAnalyzerService.parseRules(lines, groupMap, tailscaleNames);

    let tsCount: number = 0;
    let proxyCount: number = 0;
    let directCount: number = 0;
    let rejectCount: number = 0;

    const bucketOrder: string[] = [];
    const bucketMap: Record<string, FlowBucket> = {};

    for (let i = 0; i < rules.length; i++) {
      const r: ParsedRuleItem = rules[i];
      if (r.category === 'tailscale') {
        tsCount++;
      } else if (r.category === 'direct') {
        directCount++;
      } else if (r.category === 'reject') {
        rejectCount++;
      } else {
        proxyCount++;
      }

      const key: string = `${r.category}:${r.target}`;
      let bucket: FlowBucket | undefined = bucketMap[key];
      if (!bucket) {
        bucket = {
          id: key,
          title: TrafficRuleAnalyzerService.bucketTitle(r.category, r.target),
          category: r.category,
          targetName: r.target,
          chainPreview: r.chainLabel,
          ruleCount: 0,
          sampleRules: []
        };
        bucketMap[key] = bucket;
        bucketOrder.push(key);
      }
      bucket.ruleCount++;
      if (bucket.sampleRules.length < 6) {
        bucket.sampleRules.push(r.payload.length > 0 ? `${r.ruleType}: ${r.payload}` : r.ruleType);
      }
    }

    // Order buckets: tailscale first, then proxy groups, then direct, then reject.
    const categoryOrder: TrafficCategory[] = ['tailscale', 'proxy', 'direct', 'reject'];
    const buckets: FlowBucket[] = [];
    for (let c = 0; c < categoryOrder.length; c++) {
      for (let i = 0; i < bucketOrder.length; i++) {
        const b: FlowBucket = bucketMap[bucketOrder[i]];
        if (b.category === categoryOrder[c]) {
          buckets.push(b);
        }
      }
    }

    const availableTargets: string[] = ['Tailscale', 'DIRECT', 'REJECT'];
    for (let i = 0; i < groups.length; i++) {
      if (availableTargets.indexOf(groups[i].name) < 0) {
        availableTargets.push(groups[i].name);
      }
    }

    return {
      proxies: proxies,
      groups: groups,
      rules: rules,
      dnsPolicies: dnsPolicies,
      fakeIpFilters: fakeIpFilters,
      buckets: buckets,
      availableTargets: availableTargets,
      tailscaleRuleCount: tsCount,
      proxyRuleCount: proxyCount,
      directRuleCount: directCount,
      rejectRuleCount: rejectCount
    };
  }

  static simulateRoute(analysis: TrafficAnalysis, rawQuery: string, proxyMode: string): RouteSimulationResult {
    const query: string = rawQuery.trim();
    const lower: string = query.toLowerCase();
    const dnsNote: string = TrafficRuleAnalyzerService.evaluateDnsNote(analysis, lower);

    if (query.length === 0) {
      return {
        query: '',
        matched: false,
        ruleIndex: 0,
        matchedRuleRaw: '',
        target: '',
        category: 'direct',
        chain: [],
        dnsNote: ''
      };
    }

    if (proxyMode === 'direct') {
      return {
        query: query,
        matched: true,
        ruleIndex: 0,
        matchedRuleRaw: '直连模式 (mode: direct)',
        target: 'DIRECT',
        category: 'direct',
        chain: ['DIRECT'],
        dnsNote: dnsNote
      };
    }

    if (proxyMode === 'global') {
      return {
        query: query,
        matched: true,
        ruleIndex: 0,
        matchedRuleRaw: '全局模式 (mode: global)',
        target: 'GLOBAL',
        category: 'proxy',
        chain: ['GLOBAL'],
        dnsNote: dnsNote
      };
    }

    const isIpv4: boolean = TrafficRuleAnalyzerService.parseIpv4(query) >= 0;
    const isIpv6: boolean = query.indexOf(':') >= 0;

    for (let i = 0; i < analysis.rules.length; i++) {
      const rule: ParsedRuleItem = analysis.rules[i];
      if (TrafficRuleAnalyzerService.matchesRule(rule, lower, isIpv4, isIpv6)) {
        const chain: string[] = rule.chainLabel.split(' -> ');
        return {
          query: query,
          matched: true,
          ruleIndex: rule.index,
          matchedRuleRaw: rule.raw,
          target: rule.target,
          category: rule.category,
          chain: chain,
          dnsNote: dnsNote
        };
      }
    }

    return {
      query: query,
      matched: false,
      ruleIndex: 0,
      matchedRuleRaw: '未命中规则（将回退默认兜底）',
      target: 'DIRECT',
      category: 'direct',
      chain: ['DIRECT'],
      dnsNote: dnsNote
    };
  }

  static addRuleToYaml(yamlText: string, ruleLine: string, prepend: boolean): string {
    const cleanRule: string = ruleLine.trim();
    if (cleanRule.length === 0) {
      return yamlText;
    }
    const normalized: string = yamlText.replace(/\r\n/g, '\n').replace(/\r/g, '\n');
    const lines: string[] = normalized.split('\n');

    let rulesHeader: number = -1;
    let rulesEnd: number = lines.length;
    let firstItemIdx: number = -1;
    let matchItemIdx: number = -1;
    let indent: string = '';

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
        if (firstItemIdx < 0) {
          firstItemIdx = i;
          const dashIdx: number = line.indexOf('-');
          indent = dashIdx > 0 ? line.substring(0, dashIdx) : '';
        }
        const content: string = trimmed.substring(2).trim();
        if (content.toUpperCase().startsWith('MATCH,')) {
          matchItemIdx = i;
        }
      }
    }

    const formatted: string = `${indent}- ${cleanRule}`;
    if (rulesHeader < 0) {
      return `${normalized}\nrules:\n- ${cleanRule}\n`;
    }

    let insertAt: number = rulesEnd;
    if (prepend) {
      insertAt = firstItemIdx >= 0 ? firstItemIdx : rulesHeader + 1;
    } else if (matchItemIdx >= 0) {
      insertAt = matchItemIdx;
    }

    const out: string[] = [];
    for (let i = 0; i < lines.length; i++) {
      if (i === insertAt) {
        out.push(formatted);
      }
      out.push(lines[i]);
    }
    if (insertAt >= lines.length) {
      out.push(formatted);
    }
    return out.join('\n');
  }

  static deleteRuleFromYaml(yamlText: string, lineIndex: number): string {
    const normalized: string = yamlText.replace(/\r\n/g, '\n').replace(/\r/g, '\n');
    const lines: string[] = normalized.split('\n');
    if (lineIndex < 0 || lineIndex >= lines.length) {
      return yamlText;
    }
    const out: string[] = [];
    for (let i = 0; i < lines.length; i++) {
      if (i !== lineIndex) {
        out.push(lines[i]);
      }
    }
    return out.join('\n');
  }

  static moveRuleInYaml(yamlText: string, rules: ParsedRuleItem[], rulePos: number, delta: number): string {
    const targetPos: number = rulePos + delta;
    if (rulePos < 0 || rulePos >= rules.length || targetPos < 0 || targetPos >= rules.length) {
      return yamlText;
    }
    const normalized: string = yamlText.replace(/\r\n/g, '\n').replace(/\r/g, '\n');
    const lines: string[] = normalized.split('\n');
    const idxA: number = rules[rulePos].lineIndex;
    const idxB: number = rules[targetPos].lineIndex;
    if (idxA < 0 || idxA >= lines.length || idxB < 0 || idxB >= lines.length) {
      return yamlText;
    }
    const temp: string = lines[idxA];
    lines[idxA] = lines[idxB];
    lines[idxB] = temp;
    return lines.join('\n');
  }

  static hasRuleLine(yamlText: string, ruleLine: string): boolean {
    const target: string = ruleLine.trim().toLowerCase();
    const lines: string[] = yamlText.replace(/\r\n/g, '\n').split('\n');
    for (let i = 0; i < lines.length; i++) {
      const trimmed: string = lines[i].trim();
      if (trimmed.startsWith('- ')) {
        const content: string = trimmed.substring(2).trim().toLowerCase();
        if (content === target) {
          return true;
        }
      }
    }
    return false;
  }

  private static parseProxyGroups(lines: string[]): ParsedGroupDef[] {
    const groups: ParsedGroupDef[] = [];
    let inSection: boolean = false;
    let inGroupProxies: boolean = false;
    let current: ParsedGroupDef | undefined = undefined;

    for (let i = 0; i < lines.length; i++) {
      const line: string = lines[i];
      const trimmed: string = line.trim();
      if (trimmed.length === 0 || trimmed.startsWith('#')) {
        continue;
      }
      if (!line.startsWith(' ') && !line.startsWith('\t') && !line.startsWith('-')) {
        if (inSection && current && current.name.length > 0) {
          groups.push(current);
          current = undefined;
        }
        inSection = trimmed === 'proxy-groups:';
        inGroupProxies = false;
        continue;
      }
      if (!inSection) {
        continue;
      }

      if (trimmed.startsWith('- name:')) {
        if (current && current.name.length > 0) {
          groups.push(current);
        }
        current = {
          name: TrafficRuleAnalyzerService.stripQuotes(trimmed.substring(7).trim()),
          type: 'select',
          proxies: []
        };
        inGroupProxies = false;
        continue;
      }

      if (!current) {
        continue;
      }

      if (trimmed.startsWith('type:')) {
        current.type = TrafficRuleAnalyzerService.stripQuotes(trimmed.substring(5).trim());
        inGroupProxies = false;
      } else if (trimmed === 'proxies:') {
        inGroupProxies = true;
      } else if (trimmed.startsWith('url:') || trimmed.startsWith('interval:') || trimmed.startsWith('use:')) {
        inGroupProxies = false;
      } else if (inGroupProxies && trimmed.startsWith('- ')) {
        const ref: string = TrafficRuleAnalyzerService.stripQuotes(trimmed.substring(2).trim());
        if (ref.length > 0) {
          current.proxies.push(ref);
        }
      }
    }
    if (inSection && current && current.name.length > 0) {
      groups.push(current);
    }
    return groups;
  }

  private static parseRules(
    lines: string[],
    groupMap: Record<string, ParsedGroupDef>,
    tailscaleNames: Record<string, boolean>
  ): ParsedRuleItem[] {
    const rules: ParsedRuleItem[] = [];
    let inRules: boolean = false;

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
      if (!inRules || !trimmed.startsWith('- ')) {
        continue;
      }
      const raw: string = TrafficRuleAnalyzerService.stripQuotes(trimmed.substring(2).trim());
      if (raw.length === 0) {
        continue;
      }

      const parsed = TrafficRuleAnalyzerService.splitRule(raw);
      const chain: string[] = TrafficRuleAnalyzerService.resolveChain(parsed.target, groupMap);
      const category: TrafficCategory = TrafficRuleAnalyzerService.classifyTarget(parsed.target, chain, tailscaleNames);
      rules.push({
        index: rules.length + 1,
        lineIndex: i,
        raw: raw,
        ruleType: parsed.ruleType,
        payload: parsed.payload,
        target: parsed.target,
        noResolve: parsed.noResolve,
        category: category,
        chainLabel: chain.join(' -> ')
      });
    }
    return rules;
  }

  private static splitRule(raw: string): SplitRuleParts {
    const upper: string = raw.toUpperCase();
    if (upper.startsWith('AND,') || upper.startsWith('OR,') || upper.startsWith('NOT,')) {
      const lastComma: number = raw.lastIndexOf(',');
      const firstComma: number = raw.indexOf(',');
      if (lastComma > firstComma) {
        return {
          ruleType: raw.substring(0, firstComma).trim().toUpperCase(),
          payload: raw.substring(firstComma + 1, lastComma).trim(),
          target: raw.substring(lastComma + 1).trim(),
          noResolve: false
        };
      }
    }
    const parts: string[] = raw.split(',');
    const ruleType: string = parts.length > 0 ? parts[0].trim().toUpperCase() : '';
    if (ruleType === 'MATCH') {
      return {
        ruleType: 'MATCH',
        payload: '',
        target: parts.length > 1 ? parts[1].trim() : 'DIRECT',
        noResolve: false
      };
    }
    const payload: string = parts.length > 1 ? parts[1].trim() : '';
    const target: string = parts.length > 2 ? parts[2].trim() : '';
    const noResolve: boolean = parts.length > 3 && parts[3].trim().toLowerCase() === 'no-resolve';
    return {
      ruleType: ruleType,
      payload: payload,
      target: target,
      noResolve: noResolve
    };
  }

  private static resolveChain(target: string, groupMap: Record<string, ParsedGroupDef>): string[] {
    const chain: string[] = [target];
    const visited: Record<string, boolean> = {};
    visited[target] = true;
    let cursor: string = target;
    for (let depth = 0; depth < 5; depth++) {
      const grp: ParsedGroupDef | undefined = groupMap[cursor];
      if (!grp || grp.proxies.length === 0) {
        break;
      }
      const next: string = grp.proxies[0];
      if (visited[next]) {
        break;
      }
      visited[next] = true;
      chain.push(next);
      cursor = next;
    }
    return chain;
  }

  private static classifyTarget(target: string, chain: string[], tailscaleNames: Record<string, boolean>): TrafficCategory {
    const upper: string = target.toUpperCase();
    if (upper === 'DIRECT') {
      return 'direct';
    }
    if (upper === 'REJECT' || upper === 'REJECT-DROP') {
      return 'reject';
    }
    if (tailscaleNames[target]) {
      return 'tailscale';
    }
    for (let i = 0; i < chain.length; i++) {
      if (tailscaleNames[chain[i]]) {
        return 'tailscale';
      }
    }
    return 'proxy';
  }

  private static bucketTitle(category: TrafficCategory, target: string): string {
    if (category === 'tailscale') {
      return `Tailscale · ${target}`;
    }
    if (category === 'direct') {
      return '直连 · DIRECT';
    }
    if (category === 'reject') {
      return `拦截 · ${target}`;
    }
    return `代理 · ${target}`;
  }

  private static parseDnsPolicies(lines: string[]): DnsPolicyItem[] {
    const out: DnsPolicyItem[] = [];
    let inDns: boolean = false;
    let inPolicy: boolean = false;
    let policyIndent: number = 0;

    for (let i = 0; i < lines.length; i++) {
      const line: string = lines[i];
      const trimmed: string = line.trim();
      if (trimmed.length === 0 || trimmed.startsWith('#')) {
        continue;
      }
      if (!line.startsWith(' ') && !line.startsWith('\t')) {
        inDns = trimmed === 'dns:';
        inPolicy = false;
        continue;
      }
      if (!inDns) {
        continue;
      }
      const indent: number = TrafficRuleAnalyzerService.leadingSpaces(line);
      if (trimmed === 'nameserver-policy:') {
        inPolicy = true;
        policyIndent = indent;
        continue;
      }
      if (inPolicy) {
        if (indent <= policyIndent) {
          inPolicy = false;
          continue;
        }
        const colonIdx: number = trimmed.indexOf(':');
        if (colonIdx > 0) {
          out.push({
            domain: TrafficRuleAnalyzerService.stripQuotes(trimmed.substring(0, colonIdx).trim()),
            server: TrafficRuleAnalyzerService.stripQuotes(trimmed.substring(colonIdx + 1).trim())
          });
        }
      }
    }
    return out;
  }

  private static parseFakeIpFilters(lines: string[]): string[] {
    const out: string[] = [];
    let inDns: boolean = false;
    let inFilter: boolean = false;
    let filterIndent: number = 0;

    for (let i = 0; i < lines.length; i++) {
      const line: string = lines[i];
      const trimmed: string = line.trim();
      if (trimmed.length === 0 || trimmed.startsWith('#')) {
        continue;
      }
      if (!line.startsWith(' ') && !line.startsWith('\t')) {
        inDns = trimmed === 'dns:';
        inFilter = false;
        continue;
      }
      if (!inDns) {
        continue;
      }
      const indent: number = TrafficRuleAnalyzerService.leadingSpaces(line);
      if (trimmed === 'fake-ip-filter:') {
        inFilter = true;
        filterIndent = indent;
        continue;
      }
      if (inFilter) {
        if (!trimmed.startsWith('- ') && indent <= filterIndent) {
          inFilter = false;
          continue;
        }
        if (trimmed.startsWith('- ')) {
          out.push(TrafficRuleAnalyzerService.stripQuotes(trimmed.substring(2).trim()));
        }
      }
    }
    return out;
  }

  private static matchesRule(rule: ParsedRuleItem, queryLower: string, isIpv4: boolean, isIpv6: boolean): boolean {
    const p: string = rule.payload.toLowerCase();
    if (rule.ruleType === 'MATCH') {
      return true;
    }
    if (rule.ruleType === 'DOMAIN') {
      return queryLower === p;
    }
    if (rule.ruleType === 'DOMAIN-SUFFIX') {
      return queryLower === p || queryLower.endsWith(`.${p}`);
    }
    if (rule.ruleType === 'DOMAIN-KEYWORD') {
      return p.length > 0 && queryLower.indexOf(p) >= 0;
    }
    if (rule.ruleType === 'IP-CIDR' && isIpv4) {
      return TrafficRuleAnalyzerService.matchIpv4Cidr(queryLower, p);
    }
    if (rule.ruleType === 'IP-CIDR6' && isIpv6) {
      if (p === 'fd7a:115c:a1e0::/48') {
        return queryLower.startsWith('fd7a:115c:a1e0:');
      }
      const slash: number = p.indexOf('/');
      const prefix: string = slash > 0 ? p.substring(0, slash).replace(/::$/, '') : p;
      return prefix.length > 0 && queryLower.startsWith(prefix);
    }
    if (rule.ruleType === 'GEOIP' && p === 'lan' && isIpv4) {
      return TrafficRuleAnalyzerService.matchIpv4Cidr(queryLower, '10.0.0.0/8') ||
        TrafficRuleAnalyzerService.matchIpv4Cidr(queryLower, '172.16.0.0/12') ||
        TrafficRuleAnalyzerService.matchIpv4Cidr(queryLower, '192.168.0.0/16') ||
        TrafficRuleAnalyzerService.matchIpv4Cidr(queryLower, '127.0.0.0/8');
    }
    return false;
  }

  private static evaluateDnsNote(analysis: TrafficAnalysis, queryLower: string): string {
    if (TrafficRuleAnalyzerService.parseIpv4(queryLower) >= 0 || queryLower.indexOf(':') >= 0) {
      return '直接 IP 连接（无需域名解析）';
    }
    for (let i = 0; i < analysis.dnsPolicies.length; i++) {
      const pol: DnsPolicyItem = analysis.dnsPolicies[i];
      if (TrafficRuleAnalyzerService.matchDomainPattern(queryLower, pol.domain.toLowerCase())) {
        return `命中 nameserver-policy -> ${pol.server}`;
      }
    }
    for (let i = 0; i < analysis.fakeIpFilters.length; i++) {
      if (TrafficRuleAnalyzerService.matchDomainPattern(queryLower, analysis.fakeIpFilters[i].toLowerCase())) {
        return '命中 fake-ip-filter（返回真实 IP，不走 Fake-IP）';
      }
    }
    return '默认 DNS（Fake-IP 198.18.0.1/16）';
  }

  private static matchDomainPattern(host: string, pattern: string): boolean {
    if (pattern.startsWith('+.')) {
      const suffix: string = pattern.substring(2);
      return host === suffix || host.endsWith(`.${suffix}`);
    }
    if (pattern.startsWith('*.')) {
      const suffix: string = pattern.substring(2);
      return host.endsWith(`.${suffix}`);
    }
    return host === pattern;
  }

  private static parseIpv4(ip: string): number {
    const parts: string[] = ip.split('.');
    if (parts.length !== 4) {
      return -1;
    }
    let acc: number = 0;
    for (let i = 0; i < 4; i++) {
      if (parts[i].length === 0 || parts[i].length > 3) {
        return -1;
      }
      const n: number = parseInt(parts[i], 10);
      if (isNaN(n) || n < 0 || n > 255 || `${n}` !== parts[i]) {
        return -1;
      }
      acc = (acc * 256) + n;
    }
    return acc;
  }

  private static matchIpv4Cidr(ip: string, cidr: string): boolean {
    const slash: number = cidr.indexOf('/');
    const netIpStr: string = slash > 0 ? cidr.substring(0, slash) : cidr;
    const prefixLen: number = slash > 0 ? parseInt(cidr.substring(slash + 1), 10) : 32;
    if (isNaN(prefixLen) || prefixLen < 0 || prefixLen > 32) {
      return false;
    }
    const ipVal: number = TrafficRuleAnalyzerService.parseIpv4(ip);
    const netVal: number = TrafficRuleAnalyzerService.parseIpv4(netIpStr);
    if (ipVal < 0 || netVal < 0) {
      return false;
    }
    if (prefixLen === 0) {
      return true;
    }
    const shift: number = 32 - prefixLen;
    return Math.floor(ipVal / Math.pow(2, shift)) === Math.floor(netVal / Math.pow(2, shift));
  }

  private static leadingSpaces(line: string): number {
    let count: number = 0;
    while (count < line.length && line.charAt(count) === ' ') {
      count++;
    }
    return count;
  }

  private static stripQuotes(val: string): string {
    if ((val.startsWith('"') && val.endsWith('"')) || (val.startsWith("'") && val.endsWith("'"))) {
      return val.length >= 2 ? val.substring(1, val.length - 1) : val;
    }
    return val;
  }
}

interface SplitRuleParts {
  ruleType: string;
  payload: string;
  target: string;
  noResolve: boolean;
}
