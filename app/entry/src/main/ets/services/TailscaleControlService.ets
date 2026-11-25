import { http } from '@kit.NetworkKit';

const TS_API_BASE: string = 'http://127.0.0.1:9091';

export interface TailscalePeerItem {
  id: string;
  hostName: string;
  dnsName: string;
  os: string;
  tailscaleIPs: string[];
  online: boolean;
  active: boolean;
  exitNode: boolean;
  exitNodeOption: boolean;
  curAddr: string;
  relay: string;
  rxBytes: number;
  txBytes: number;
  primaryRoutes: string[];
}

export interface TailscaleAdvertisedRouteItem {
  cidr: string;
  peerName: string;
  peerIp: string;
  online: boolean;
}

export interface TailscaleSplitDnsItem {
  domain: string;
  nameservers: string[];
}

export interface TailscaleDnsQueryResult {
  ok: boolean;
  name: string;
  type: string;
  answers: string[];
  resolvers: string[];
  latencyMs: number;
  error: string;
}

export interface TailscaleControlStatus {
  reachable: boolean;
  available: boolean;
  proxyName: string;
  backendState: string;
  authUrl: string;
  tailnetName: string;
  magicDnsSuffix: string;
  controlUrl: string;
  hostname: string;
  loginName: string;
  tailscaleIPs: string[];
  acceptRoutes: boolean;
  exitNodeId: string;
  exitNodeIp: string;
  exitNodeAllowLan: boolean;
  health: string[];
  lastError: string;
  recentLogs: string[];
  peers: TailscalePeerItem[];
  advertisedRoutes: TailscaleAdvertisedRouteItem[];
  splitDns: TailscaleSplitDnsItem[];
  searchDomains: string[];
  updatedAt: string;
}

export interface TailscalePrefsPatch {
  hostname?: string;
  acceptRoutes?: boolean;
  exitNode?: string;
  exitNodeAllowLan?: boolean;
  controlUrl?: string;
}

export interface TailscaleActionResult {
  ok: boolean;
  error: string;
  status?: TailscaleControlStatus;
}

export interface TailscalePingResult {
  ok: boolean;
  ip: string;
  latencyMs: number;
  direct: boolean;
  endpoint: string;
  derpRegionCode: string;
  error: string;
}

export interface LiveRuleTestResult {
  ok: boolean;
  target: string;
  host: string;
  ip: string;
  port: number;
  network: string;
  mode: string;
  ruleType: string;
  rulePayload: string;
  ruleRaw: string;
  proxyChain: string[];
  finalOutbound: string;
  finalType: string;
  error: string;
}

export function createEmptyTailscaleControlStatus(): TailscaleControlStatus {
  return {
    reachable: false,
    available: false,
    proxyName: 'Tailscale',
    backendState: '',
    authUrl: '',
    tailnetName: '',
    magicDnsSuffix: '',
    controlUrl: '',
    hostname: '',
    loginName: '',
    tailscaleIPs: [],
    acceptRoutes: true,
    exitNodeId: '',
    exitNodeIp: '',
    exitNodeAllowLan: true,
    health: [],
    lastError: '',
    recentLogs: [],
    peers: [],
    advertisedRoutes: [],
    splitDns: [],
    searchDomains: [],
    updatedAt: ''
  };
}

interface RawHttpResult {
  ok: boolean;
  statusCode: number;
  body: string;
  error: string;
}

export class TailscaleControlService {
  static async getStatus(): Promise<TailscaleControlStatus> {
    const res: RawHttpResult = await TailscaleControlService.request('/tailscale/status', http.RequestMethod.GET, '', 3000);
    if (!res.ok) {
      return createEmptyTailscaleControlStatus();
    }
    return TailscaleControlService.parseStatus(res.body, true);
  }

  static async updatePrefs(patch: TailscalePrefsPatch): Promise<TailscaleActionResult> {
    const payload: Record<string, Object> = {};
    if (patch.hostname !== undefined) {
      payload['hostname'] = patch.hostname;
    }
    if (patch.acceptRoutes !== undefined) {
      payload['acceptRoutes'] = patch.acceptRoutes;
    }
    if (patch.exitNode !== undefined) {
      payload['exitNode'] = patch.exitNode;
    }
    if (patch.exitNodeAllowLan !== undefined) {
      payload['exitNodeAllowLan'] = patch.exitNodeAllowLan;
    }
    if (patch.controlUrl !== undefined) {
      payload['controlUrl'] = patch.controlUrl;
    }
    const res: RawHttpResult = await TailscaleControlService.request('/tailscale/prefs', http.RequestMethod.POST, JSON.stringify(payload), 8000);
    return TailscaleControlService.parseActionResponse(res);
  }

  static async startLogin(): Promise<TailscaleActionResult> {
    const res: RawHttpResult = await TailscaleControlService.request('/tailscale/login', http.RequestMethod.POST, '{}', 8000);
    return TailscaleControlService.parseActionResponse(res);
  }

  static async logout(): Promise<TailscaleActionResult> {
    const res: RawHttpResult = await TailscaleControlService.request('/tailscale/logout', http.RequestMethod.POST, '{}', 8000);
    return TailscaleControlService.parseActionResponse(res);
  }

  static async pingPeer(ip: string): Promise<TailscalePingResult> {
    const res: RawHttpResult = await TailscaleControlService.request(
      '/tailscale/ping',
      http.RequestMethod.POST,
      JSON.stringify({ ip: ip }),
      6000
    );
    if (!res.ok) {
      return {
        ok: false,
        ip: ip,
        latencyMs: 0,
        direct: false,
        endpoint: '',
        derpRegionCode: '',
        error: res.error.length > 0 ? res.error : 'Tailscale 控制接口未连接'
      };
    }
    try {
      const obj = JSON.parse(res.body) as Record<string, Object>;
      return {
        ok: obj['ok'] === true,
        ip: TailscaleControlService.str(obj, 'ip'),
        latencyMs: TailscaleControlService.num(obj, 'latencyMs'),
        direct: obj['direct'] === true,
        endpoint: TailscaleControlService.str(obj, 'endpoint'),
        derpRegionCode: TailscaleControlService.str(obj, 'derpRegionCode'),
        error: TailscaleControlService.str(obj, 'error')
      };
    } catch (_err) {
      return {
        ok: false,
        ip: ip,
        latencyMs: 0,
        direct: false,
        endpoint: '',
        derpRegionCode: '',
        error: '解析 Ping 响应失败'
      };
    }
  }

  static async queryDns(name: string, recordType: string = 'A'): Promise<TailscaleDnsQueryResult> {
    const cleanName: string = name.trim();
    const res: RawHttpResult = await TailscaleControlService.request(
      '/tailscale/dns-query',
      http.RequestMethod.POST,
      JSON.stringify({ name: cleanName, type: recordType }),
      6000
    );
    if (!res.ok) {
      return {
        ok: false,
        name: cleanName,
        type: recordType,
        answers: [],
        resolvers: [],
        latencyMs: 0,
        error: res.error.length > 0 ? res.error : 'Tailscale 控制接口未连接'
      };
    }
    try {
      const obj = JSON.parse(res.body) as Record<string, Object>;
      return {
        ok: obj['ok'] === true,
        name: TailscaleControlService.str(obj, 'name'),
        type: TailscaleControlService.str(obj, 'type'),
        answers: TailscaleControlService.strArr(obj, 'answers'),
        resolvers: TailscaleControlService.strArr(obj, 'resolvers'),
        latencyMs: TailscaleControlService.num(obj, 'latencyMs'),
        error: TailscaleControlService.str(obj, 'error')
      };
    } catch (_err) {
      return {
        ok: false,
        name: cleanName,
        type: recordType,
        answers: [],
        resolvers: [],
        latencyMs: 0,
        error: '解析 DNS 查询响应失败'
      };
    }
  }

  static async testRule(target: string, port: number = 443, network: string = 'tcp'): Promise<LiveRuleTestResult> {
    const cleanTarget: string = target.trim();
    const res: RawHttpResult = await TailscaleControlService.request(
      '/config/rule-test',
      http.RequestMethod.POST,
      JSON.stringify({ target: cleanTarget, port: port, network: network }),
      4000
    );
    if (!res.ok) {
      return {
        ok: false,
        target: cleanTarget,
        host: '',
        ip: '',
        port: port,
        network: network.toUpperCase(),
        mode: '',
        ruleType: '',
        rulePayload: '',
        ruleRaw: '',
        proxyChain: [],
        finalOutbound: '',
        finalType: '',
        error: res.error.length > 0 ? res.error : '核心控制接口未连接'
      };
    }
    try {
      const obj = JSON.parse(res.body) as Record<string, Object>;
      return {
        ok: obj['ok'] === true,
        target: TailscaleControlService.str(obj, 'target'),
        host: TailscaleControlService.str(obj, 'host'),
        ip: TailscaleControlService.str(obj, 'ip'),
        port: TailscaleControlService.num(obj, 'port'),
        network: TailscaleControlService.str(obj, 'network'),
        mode: TailscaleControlService.str(obj, 'mode'),
        ruleType: TailscaleControlService.str(obj, 'ruleType'),
        rulePayload: TailscaleControlService.str(obj, 'rulePayload'),
        ruleRaw: TailscaleControlService.str(obj, 'ruleRaw'),
        proxyChain: TailscaleControlService.strArr(obj, 'proxyChain'),
        finalOutbound: TailscaleControlService.str(obj, 'finalOutbound'),
        finalType: TailscaleControlService.str(obj, 'finalType'),
        error: TailscaleControlService.str(obj, 'error')
      };
    } catch (_err) {
      return {
        ok: false,
        target: cleanTarget,
        host: '',
        ip: '',
        port: port,
        network: network.toUpperCase(),
        mode: '',
        ruleType: '',
        rulePayload: '',
        ruleRaw: '',
        proxyChain: [],
        finalOutbound: '',
        finalType: '',
        error: '解析规则测试响应失败'
      };
    }
  }

  private static parseActionResponse(res: RawHttpResult): TailscaleActionResult {
    if (!res.ok) {
      return {
        ok: false,
        error: res.error.length > 0 ? res.error : `请求失败 (HTTP ${res.statusCode})`
      };
    }
    try {
      const obj = JSON.parse(res.body) as Record<string, Object>;
      const ok: boolean = obj['ok'] === true;
      const errMsg: string = TailscaleControlService.str(obj, 'error');
      const statusObj: Object | undefined = obj['status'];
      let parsedStatus: TailscaleControlStatus | undefined = undefined;
      if (statusObj && typeof statusObj === 'object') {
        parsedStatus = TailscaleControlService.parseStatusObj(statusObj as Record<string, Object>, true);
      }
      return {
        ok: ok,
        error: errMsg,
        status: parsedStatus
      };
    } catch (_err) {
      return { ok: false, error: '解析控制面响应失败' };
    }
  }

  private static parseStatus(raw: string, reachable: boolean): TailscaleControlStatus {
    try {
      const obj = JSON.parse(raw) as Record<string, Object>;
      return TailscaleControlService.parseStatusObj(obj, reachable);
    } catch (_err) {
      return createEmptyTailscaleControlStatus();
    }
  }

  private static parseStatusObj(obj: Record<string, Object>, reachable: boolean): TailscaleControlStatus {
    const peers: TailscalePeerItem[] = [];
    const rawPeers: Object | undefined = obj['peers'];
    if (Array.isArray(rawPeers)) {
      const arr: Object[] = rawPeers as Object[];
      for (let i = 0; i < arr.length; i++) {
        const p = arr[i] as Record<string, Object>;
        if (!p) {
          continue;
        }
        peers.push({
          id: TailscaleControlService.str(p, 'id'),
          hostName: TailscaleControlService.str(p, 'hostName'),
          dnsName: TailscaleControlService.str(p, 'dnsName'),
          os: TailscaleControlService.str(p, 'os'),
          tailscaleIPs: TailscaleControlService.strArr(p, 'tailscaleIPs'),
          online: p['online'] === true,
          active: p['active'] === true,
          exitNode: p['exitNode'] === true,
          exitNodeOption: p['exitNodeOption'] === true,
          curAddr: TailscaleControlService.str(p, 'curAddr'),
          relay: TailscaleControlService.str(p, 'relay'),
          rxBytes: TailscaleControlService.num(p, 'rxBytes'),
          txBytes: TailscaleControlService.num(p, 'txBytes'),
          primaryRoutes: TailscaleControlService.strArr(p, 'primaryRoutes')
        });
      }
    }

    const advertisedRoutes: TailscaleAdvertisedRouteItem[] = [];
    const rawRoutes: Object | undefined = obj['advertisedRoutes'];
    if (Array.isArray(rawRoutes)) {
      const arr: Object[] = rawRoutes as Object[];
      for (let i = 0; i < arr.length; i++) {
        const r = arr[i] as Record<string, Object>;
        if (!r) {
          continue;
        }
        advertisedRoutes.push({
          cidr: TailscaleControlService.str(r, 'cidr'),
          peerName: TailscaleControlService.str(r, 'peerName'),
          peerIp: TailscaleControlService.str(r, 'peerIp'),
          online: r['online'] === true
        });
      }
    }

    const splitDns: TailscaleSplitDnsItem[] = [];
    const rawSplit: Object | undefined = obj['splitDns'];
    if (Array.isArray(rawSplit)) {
      const arr: Object[] = rawSplit as Object[];
      for (let i = 0; i < arr.length; i++) {
        const s = arr[i] as Record<string, Object>;
        if (!s) {
          continue;
        }
        const dom: string = TailscaleControlService.str(s, 'domain');
        if (dom.length > 0) {
          splitDns.push({
            domain: dom,
            nameservers: TailscaleControlService.strArr(s, 'nameservers')
          });
        }
      }
    }

    return {
      reachable: reachable,
      available: obj['available'] === true,
      proxyName: TailscaleControlService.str(obj, 'proxyName'),
      backendState: TailscaleControlService.str(obj, 'backendState'),
      authUrl: TailscaleControlService.str(obj, 'authUrl'),
      tailnetName: TailscaleControlService.str(obj, 'tailnetName'),
      magicDnsSuffix: TailscaleControlService.str(obj, 'magicDnsSuffix'),
      controlUrl: TailscaleControlService.str(obj, 'controlUrl'),
      hostname: TailscaleControlService.str(obj, 'hostname'),
      loginName: TailscaleControlService.str(obj, 'loginName'),
      tailscaleIPs: TailscaleControlService.strArr(obj, 'tailscaleIPs'),
      acceptRoutes: obj['acceptRoutes'] === true,
      exitNodeId: TailscaleControlService.str(obj, 'exitNodeId'),
      exitNodeIp: TailscaleControlService.str(obj, 'exitNodeIp'),
      exitNodeAllowLan: obj['exitNodeAllowLan'] === true,
      health: TailscaleControlService.strArr(obj, 'health'),
      lastError: TailscaleControlService.str(obj, 'lastError'),
      recentLogs: TailscaleControlService.strArr(obj, 'recentLogs'),
      peers: peers,
      advertisedRoutes: advertisedRoutes,
      splitDns: splitDns,
      searchDomains: TailscaleControlService.strArr(obj, 'searchDomains'),
      updatedAt: TailscaleControlService.str(obj, 'updatedAt')
    };
  }

  private static async request(path: string, method: http.RequestMethod, body: string, timeoutMs: number): Promise<RawHttpResult> {
    const req: http.HttpRequest = http.createHttp();
    try {
      const resp: http.HttpResponse = await req.request(`${TS_API_BASE}${path}`, {
        method: method,
        extraData: body,
        expectDataType: http.HttpDataType.STRING,
        connectTimeout: 1500,
        readTimeout: timeoutMs,
        header: {
          'Content-Type': 'application/json'
        }
      });
      const text: string = typeof resp.result === 'string' ? resp.result as string : JSON.stringify(resp.result);
      const ok: boolean = resp.responseCode >= 200 && resp.responseCode < 300;
      return {
        ok: ok,
        statusCode: resp.responseCode,
        body: text,
        error: ok ? '' : `HTTP ${resp.responseCode}`
      };
    } catch (err) {
      const msg: string = err instanceof Error ? err.message : '连接 127.0.0.1:9091 失败';
      return {
        ok: false,
        statusCode: 0,
        body: '',
        error: msg
      };
    } finally {
      req.destroy();
    }
  }

  private static str(obj: Record<string, Object>, key: string): string {
    const v: Object | undefined = obj[key];
    return typeof v === 'string' ? (v as string).trim() : '';
  }

  private static num(obj: Record<string, Object>, key: string): number {
    const v: Object | undefined = obj[key];
    return typeof v === 'number' ? v as number : 0;
  }

  private static strArr(obj: Record<string, Object>, key: string): string[] {
    const v: Object | undefined = obj[key];
    if (!Array.isArray(v)) {
      return [];
    }
    const items: Object[] = v as Object[];
    const out: string[] = [];
    for (let i = 0; i < items.length; i++) {
      if (typeof items[i] === 'string') {
        const s: string = (items[i] as string).trim();
        if (s.length > 0) {
          out.push(s);
        }
      }
    }
    return out;
  }
}
