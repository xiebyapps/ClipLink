import connection from '@ohos.net.connection';
import { ConfigService } from './ConfigService';
import { SyncClipboardService } from './SyncClipboardService';
import { ServerAccount } from '../types/ApiTypes';

class ServerHealth {
  signature: string = '';
  online: boolean = false;
}

/** Keeps one active account. Health checks are sequential and only run on
 * foreground/network changes or after an actual request failure. */
export class ServerManager {
  private static instance: ServerManager = new ServerManager();
  private network?: connection.NetConnection;
  private checking: Promise<string | null> | null = null;
  private selectionEpoch: number = 0;
  private health: Map<string, ServerHealth> = new Map();
  private probes: Map<string, number> = new Map();
  private commitQueue: Promise<void> = Promise.resolve();

  static getInstance(): ServerManager { return ServerManager.instance; }

  private signature(server: ServerAccount): string {
    return JSON.stringify([server.url, server.username || '', server.password || '']);
  }

  private changed(): void {
    AppStorage.setOrCreate('serverHealthRevision', (AppStorage.get<number>('serverHealthRevision') || 0) + 1);
  }

  isOnline(id: string): boolean {
    const account = ConfigService.getInstance().getConfig().servers.find((item: ServerAccount): boolean => item.id === id);
    const value = this.health.get(id);
    return !!account && value?.signature === this.signature(account) && value.online;
  }

  invalidate(id: string): void {
    this.selectionEpoch++;
    this.probes.set(id, (this.probes.get(id) || 0) + 1);
    this.health.delete(id);
    if (ConfigService.getInstance().getConfig().activeServerId === id) {
      AppStorage.setOrCreate('serverConnectionStatus', 'unverified');
    }
    this.changed();
  }

  recordTest(server: ServerAccount, online: boolean): void {
    const current = ConfigService.getInstance().getConfig().servers.find((item: ServerAccount): boolean => item.id === server.id);
    if (!current || this.signature(current) !== this.signature(server)) return;
    this.health.set(server.id, { signature: this.signature(server), online: online });
    this.changed();
  }

  async refreshHealth(): Promise<void> {
    await ConfigService.getInstance().loadConfig();
    const accounts = ConfigService.getInstance().getConfig().servers.slice();
    for (let i = 0; i < accounts.length; i += 2) {
      await Promise.all(accounts.slice(i, i + 2).map((account: ServerAccount): Promise<boolean> => this.probe(account)));
    }
  }

  start(): void {
    if (this.network) return;
    this.network = connection.createNetConnection();
    const update = (): void => { void this.refreshHealth(); void this.ensureAvailable(); };
    this.network.on('netAvailable', update);
    this.network.on('netLost', update);
    this.network.register((): void => {});
    update();
  }

  stop(): void {
    if (!this.network) return;
    this.network.unregister((): void => {});
    this.network = undefined;
  }

  private async probe(server: ServerAccount): Promise<boolean> {
    const token = (this.probes.get(server.id) || 0) + 1;
    this.probes.set(server.id, token);
    let online = false;
    try {
      await new SyncClipboardService(server.url, server.username, server.password).probe();
      online = true;
    } catch (_) { }
    if (this.probes.get(server.id) === token) {
      this.recordTest(server, online);
      const config = ConfigService.getInstance().getConfig();
      if (config.activeServerId === server.id && config.servers.some((item: ServerAccount): boolean =>
        item.id === server.id && this.signature(item) === this.signature(server))) {
        AppStorage.setOrCreate('serverConnectionStatus', online ? 'connected' : 'offline');
      }
    }
    return online;
  }

  private async commit(server: ServerAccount, epoch: number): Promise<void> {
    const operation = this.commitQueue.then(async (): Promise<void> => {
      const config = ConfigService.getInstance();
      const current = config.getConfig().servers.find((item: ServerAccount): boolean => item.id === server.id);
      if (epoch !== this.selectionEpoch || !current || this.signature(current) !== this.signature(server)) {
        throw new Error('Server changed during operation');
      }
      await config.switchServer(server.id, (): boolean => epoch === this.selectionEpoch &&
        config.getConfig().servers.some((item: ServerAccount): boolean =>
          item.id === server.id && this.signature(item) === this.signature(server)));
      await config.markConnected(server.id);
      if (epoch !== this.selectionEpoch) throw new Error('Server changed during operation');
      AppStorage.setOrCreate('serverConnectionStatus', 'connected');
      this.changed();
    });
    this.commitQueue = operation.catch((): void => {});
    await operation;
  }

  async select(id: string): Promise<void> {
    const epoch = ++this.selectionEpoch;
    await ConfigService.getInstance().loadConfig();
    const config = ConfigService.getInstance();
    const target = config.getConfig().servers.find((item: ServerAccount): boolean => item.id === id);
    if (!target) throw new Error('Server not found');
    if (!await this.probe(target)) throw new Error('Server unavailable');
    await this.commit(target, epoch);
  }

  async ensureAvailable(): Promise<string | null> {
    if (AppStorage.get<string>('syncPausedReason')) return null;
    if (this.checking) return this.checking;
    this.checking = this.checkAvailable();
    try { return await this.checking; }
    finally { this.checking = null; }
  }

  private async checkAvailable(): Promise<string | null> {
    const epoch = this.selectionEpoch;
    await ConfigService.getInstance().loadConfig();
    const service = ConfigService.getInstance();
    const config = service.getConfig();
    if (config.servers.length === 0) {
      AppStorage.setOrCreate('serverConnectionStatus', 'unconfigured');
      return null;
    }
    if (AppStorage.get<string>('syncPausedReason')) return null;
    const candidates = config.servers.slice().sort((a: ServerAccount, b: ServerAccount): number => {
      if (a.id === config.activeServerId) return -1;
      if (b.id === config.activeServerId) return 1;
      return b.lastConnectedAt - a.lastConnectedAt;
    });
    for (const account of candidates) {
      if (!await this.probe(account)) continue;
      if (AppStorage.get<string>('syncPausedReason')) return null;
      if (epoch !== this.selectionEpoch) return service.getConfig().activeServerId;
      try { await this.commit(account, epoch); } catch (_) { return null; }
      return account.id;
    }
    if (epoch !== this.selectionEpoch) return service.getConfig().activeServerId;
    AppStorage.setOrCreate('serverConnectionStatus', 'offline');
    return null;
  }
}
