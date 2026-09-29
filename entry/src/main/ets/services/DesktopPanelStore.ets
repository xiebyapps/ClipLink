import preferences from '@ohos.data.preferences';
import { ConfigService } from './ConfigService';
import { DesktopRequest } from './DesktopActionService';
import { HistoryRecordDto } from '../types/ApiTypes';
import { HashUtil } from '../utils/HashUtil';

export interface SavedDesktopPanel {
  request: DesktopRequest;
  record: HistoryRecordDto;
  accountId: string;
  signature: string;
  expiresAt: number;
}

/** Only attachment metadata is persisted. This never stores clipboard text or replays an upload. */
export class DesktopPanelStore {
  private static queue: Promise<void> = Promise.resolve();
  private static async signature(): Promise<string> {
    const server = ConfigService.getInstance().getActiveServer();
    if (!server) throw new Error('No available server');
    return await HashUtil.calculateTextHash(JSON.stringify([server.id, server.url, server.username, server.password]));
  }

  static async save(context: Context, request: DesktopRequest, record: HistoryRecordDto): Promise<void> {
    if (request.action !== 'sync' || record.type === 'Text') throw new Error('Invalid desktop panel');
    const accountId = ConfigService.getInstance().getConfig().activeServerId;
    const signature = await DesktopPanelStore.signature();
    const saved: SavedDesktopPanel = { request: request,
      record: { type: record.type, hash: record.hash, text: record.text, size: record.size,
        hasData: record.hasData, lastAccessed: record.lastAccessed },
      accountId: accountId, signature: signature, expiresAt: Date.now() + 30 * 60 * 1000 };
    const write = DesktopPanelStore.queue.then(async (): Promise<void> => {
      const store = await preferences.getPreferences(context, 'desktop_panel');
      await store.put('panel', JSON.stringify(saved)); await store.flush();
    });
    DesktopPanelStore.queue = write.catch((): void => {});
    await write;
  }

  static async restore(context: Context, id: string, formId: string = ''): Promise<SavedDesktopPanel | undefined> {
    await DesktopPanelStore.queue;
    const store = await preferences.getPreferences(context, 'desktop_panel');
    const raw = await store.get('panel', '') as string;
    if (!raw) return undefined;
    let saved: SavedDesktopPanel;
    try { saved = JSON.parse(raw) as SavedDesktopPanel; }
    catch (_) { return undefined; }
    if (!saved?.request || !saved.record || saved.request.id !== id || saved.request.action !== 'sync' ||
      (formId && formId !== saved.request.formId) || !saved.request.formId ||
      !['Image', 'File', 'Group'].includes(saved.record.type) || !saved.record.hash ||
      !Number.isFinite(saved.expiresAt) || saved.expiresAt <= Date.now()) return undefined;
    if (saved.accountId !== ConfigService.getInstance().getConfig().activeServerId ||
      saved.signature !== await DesktopPanelStore.signature()) throw new Error('Server changed during operation');
    return saved;
  }

  static async clear(context: Context, id: string): Promise<void> {
    const write = DesktopPanelStore.queue.then(async (): Promise<void> => {
      const store = await preferences.getPreferences(context, 'desktop_panel');
      const raw = await store.get('panel', '') as string;
      if (!raw) return;
      try { if ((JSON.parse(raw) as SavedDesktopPanel).request?.id !== id) return; }
      catch (_) { return; }
      await store.delete('panel'); await store.flush();
    });
    DesktopPanelStore.queue = write.catch((): void => {});
    await write;
  }
}
