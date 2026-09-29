import { BusinessError } from '@kit.BasicServicesKit';
import { formProvider, formBindingData } from '@kit.FormKit';
import { common } from '@kit.AbilityKit';
import pasteboard from '@ohos.pasteboard';
import { ConfigService } from './ConfigService';
import { HttpClient } from './HttpClient';
import { ProfileDto } from '../types/ApiTypes';
import { ClipboardUtil } from '../utils/ClipboardUtil';
import { LocalizationUtil } from '../utils/LocalizationUtil';

export type WidgetSide = 'local' | 'remote';

export class ClipboardCardData {
  formId: string = '';
  formDimension: number = 2;
  localVisible: boolean = false;
  remoteVisible: boolean = false;
  localContent: string = '';
  remoteContent: string = '';
  localTime: string = '';
  remoteTime: string = '';
  localExpiresAt: number = 0;
  remoteExpiresAt: number = 0;
  localToken: string = '';
  remoteToken: string = '';
  actionStatus: string = '';
  openRequestId: string = '';
  completedRequestId: string = '';
  openLabel: string = '';
  fallbackSide: string = '';
  fallbackToken: string = '';
  uploadLabel: string = 'Upload';
  uploadActionLabel: string = 'Upload clipboard';
  syncLabel: string = 'Sync';
  syncActionLabel: string = 'Sync clipboard';
  localLabel: string = 'Local clipboard';
  remoteLabel: string = 'Server content';
  hiddenLabel: string = 'Tap to show';
  hideLabel: string = 'Tap to hide';
  surface: string = '';
  button: string = '';
  textColor: string = '';
  secondary: string = '';
  accent: string = '';
}

/** Only per-click data is kept in memory. No clipboard payload or credentials are persisted to forms. */
export class ClipboardWidgetService {
  private static states: Map<string, ClipboardCardData> = new Map<string, ClipboardCardData>();
  private static epoch: number = 0;
  private static invalidTokens: Set<string> = new Set<string>();
  private static systemLanguage(): string { return LocalizationUtil.systemLanguage(); }
  private static t(value: string): string {
    return LocalizationUtil.text(value, ConfigService.getInstance().getConfig().language,
      ClipboardWidgetService.systemLanguage());
  }

  static empty(): ClipboardCardData {
    const data = new ClipboardCardData();
    data.openLabel = ClipboardWidgetService.t('Open action panel');
    data.uploadLabel = ClipboardWidgetService.t('Upload');
    data.uploadActionLabel = ClipboardWidgetService.t('Upload clipboard');
    data.syncLabel = ClipboardWidgetService.t('Sync');
    data.syncActionLabel = ClipboardWidgetService.t('Sync clipboard');
    data.localLabel = ClipboardWidgetService.t('Local clipboard');
    data.remoteLabel = ClipboardWidgetService.t('Server content');
    data.hiddenLabel = ClipboardWidgetService.t('Tap to show');
    data.hideLabel = ClipboardWidgetService.t('Tap to hide');
    const config = ConfigService.getInstance().getConfig();
    if (config.theme === 'dark') {
      data.surface = config.preferPureBlackInDark ? '#000000' : '#161D28';
      data.button = '#243043'; data.textColor = '#F1F5FB'; data.secondary = '#ABB7C9'; data.accent = '#80B8FF';
    } else if (config.theme === 'light') {
      data.surface = '#F4F6F9'; data.button = '#FFFFFF'; data.textColor = '#17212D';
      data.secondary = '#647082'; data.accent = '#1677FF';
    }
    return data;
  }

  static add(formId: string, dimension?: number): ClipboardCardData {
    const previous = ClipboardWidgetService.states.get(formId);
    const data = ClipboardWidgetService.empty();
    data.formId = formId;
    data.formDimension = dimension && [1, 2, 3].includes(dimension) ? dimension : previous?.formDimension || 2;
    ClipboardWidgetService.states.set(formId, data);
    return data;
  }

  private static invalidateTokens(data: ClipboardCardData, preserve: string = ''): void {
    for (const token of [data.localToken, data.remoteToken]) {
      if (token && token !== preserve) ClipboardWidgetService.invalidTokens.add(token);
    }
    while (ClipboardWidgetService.invalidTokens.size > 256) {
      ClipboardWidgetService.invalidTokens.delete(Array.from(ClipboardWidgetService.invalidTokens)[0]);
    }
  }

  static remove(formId: string): void {
    const data = ClipboardWidgetService.states.get(formId);
    if (data) ClipboardWidgetService.invalidateTokens(data);
    ClipboardWidgetService.states.delete(formId);
  }

  private static async update(formId: string, data: ClipboardCardData): Promise<void> {
    await formProvider.updateForm(formId, formBindingData.createFormBindingData(data));
  }

  static async resetAll(context?: Context, preserveToken: string = ''): Promise<void> {
    ClipboardWidgetService.epoch++;
    if (context) ConfigService.getInstance().setContext(context);
    ClipboardWidgetService.states.forEach((data: ClipboardCardData): void => ClipboardWidgetService.invalidateTokens(data, preserveToken));
    ClipboardWidgetService.states.clear();
    try {
      const forms = await formProvider.getPublishedRunningFormInfos();
      for (const form of forms) {
        if (form.formName !== 'ClipboardActions') continue;
        await ClipboardWidgetService.update(form.formId, ClipboardWidgetService.add(form.formId, form.dimension)).catch((): void => {});
      }
    } catch (_) { /* No installed cards, or widget service is not available. */ }
  }

  static async validateForm(formId: string): Promise<void> {
    const info = await formProvider.getPublishedRunningFormInfoById(formId);
    if (info.formName !== 'ClipboardActions') throw new Error('Unable to read current content');
    const data = ClipboardWidgetService.states.get(formId) || ClipboardWidgetService.add(formId, info.dimension);
    data.formId = formId;
    if ([1, 2, 3].includes(info.dimension)) data.formDimension = info.dimension;
  }

  static async actionStatus(formId: string, message: string, openRequestId: string = ''): Promise<void> {
    if (!formId) return;
    const data = ClipboardWidgetService.states.get(formId) || ClipboardWidgetService.add(formId);
    data.actionStatus = ClipboardWidgetService.t(message);
    data.openRequestId = openRequestId;
    await ClipboardWidgetService.update(formId, data).catch((): void => {});
  }

  static async completeRequest(formId: string, requestId: string): Promise<void> {
    const data = ClipboardWidgetService.states.get(formId);
    if (!data) return;
    data.completedRequestId = requestId;
    await ClipboardWidgetService.update(formId, data).catch((): void => {});
  }

  static async revealLatest(formId: string, side: WidgetSide, token: string,
    context: Context, allowPrompt: boolean): Promise<void> {
    await ClipboardWidgetService.validateForm(formId);
    const data = ClipboardWidgetService.states.get(formId) || ClipboardWidgetService.add(formId);
    if (side === 'local') {
      data.localToken = token; data.localVisible = true; data.localContent = ''; data.localTime = ''; data.localExpiresAt = 0;
    } else {
      data.remoteToken = token; data.remoteVisible = true; data.remoteContent = ''; data.remoteTime = ''; data.remoteExpiresAt = 0;
    }
    await ClipboardWidgetService.finishRead(formId, side, token, true, context, allowPrompt);
  }

  /** Token checks keep an old host timer from hiding a newer reveal. */
  static async hideExpired(formId: string, side: WidgetSide, token: string): Promise<void> {
    const data = ClipboardWidgetService.states.get(formId);
    if (data) {
      if ((side === 'local' ? data.localToken : data.remoteToken) !== token ||
        (side === 'local' ? data.localExpiresAt : data.remoteExpiresAt) > Date.now()) return;
    } else {
      // A recreated provider has no plaintext snapshot; publish a hidden card.
      await ClipboardWidgetService.validateForm(formId);
    }
    await ClipboardWidgetService.toggle(formId, side, true);
  }

  private static accountKey(): string {
    const server = ConfigService.getInstance().getActiveServer();
    return server ? JSON.stringify([server.id, server.url, server.username || '', server.password || '']) : '';
  }

  private static timeLabel(): string {
    const date = new Date();
    return `${ClipboardWidgetService.t('Updated')} ${date.getHours().toString().padStart(2, '0')}:${date.getMinutes().toString().padStart(2, '0')}:${date.getSeconds().toString().padStart(2, '0')}`;
  }

  private static async read(side: WidgetSide, foreground: boolean, context?: Context): Promise<string> {
    if (side === 'remote') {
      const server = ConfigService.getInstance().getActiveServer();
      if (!server) throw new Error('No available server');
      const http = new HttpClient(server.url, server.username, server.password);
      http.setTimeout(5000);
      const profile = await http.get<ProfileDto>('/SyncClipboard.json');
      if (profile.type === 'Text') {
        return profile.text ? profile.text.slice(0, 180) : ClipboardWidgetService.t(
          profile.hasData ? 'Content is stored separately' : 'Empty clipboard');
      }
      return `${ClipboardWidgetService.t(profile.type)} · ${(profile.dataName || profile.text || '').slice(0, 180)}`;
    }
    if (!await ClipboardUtil.ensureReadPermission(context, foreground)) throw new Error('Clipboard permission denied');
    const board = pasteboard.getSystemPasteboard();
    const count = board.getChangeCount();
    // Read without trying to display a permission dialog inside the extension.
    let data: pasteboard.PasteData;
    try { data = await board.getData(); }
    catch (error) {
      if ((error as BusinessError)?.code === 201) throw new Error('Clipboard permission denied');
      throw error instanceof Error ? error : new Error(String(error));
    }
    let content: string;
    if (data.getRecordCount() === 0) content = ClipboardWidgetService.t('Empty clipboard');
    else if (data.getPrimaryMimeType() === pasteboard.MIMETYPE_TEXT_PLAIN) content = (data.getPrimaryText() || '').slice(0, 180);
    else if (data.getPrimaryMimeType() === pasteboard.MIMETYPE_PIXELMAP) content = ClipboardWidgetService.t('Image');
    else if (data.getPrimaryMimeType() === pasteboard.MIMETYPE_TEXT_URI) {
      const uri = data.getPrimaryUri() || '';
      content = `${ClipboardWidgetService.t('File')} · ${uri.split('/').pop()?.split('?')[0].slice(0, 100) || ''}`;
    } else content = ClipboardWidgetService.t('Unsupported clipboard type');
    if (count !== board.getChangeCount()) throw new Error('Clipboard changed during read');
    return content || ClipboardWidgetService.t('Empty clipboard');
  }

  /** The host uses a message for reads and a router action for the foreground fallback. */
  static async toggle(formId: string, side: WidgetSide, hide: boolean = false): Promise<void> {
    const data = ClipboardWidgetService.states.get(formId) || ClipboardWidgetService.add(formId);
    const visible = hide || (side === 'local' ? data.localVisible : data.remoteVisible);
    const token = `${Date.now()}-${Math.random().toString(36).slice(2)}`;
    if (side === 'local') {
      data.localToken = token; data.localVisible = !visible; data.localContent = ''; data.localTime = ''; data.localExpiresAt = 0;
    } else {
      data.remoteToken = token; data.remoteVisible = !visible; data.remoteContent = ''; data.remoteTime = ''; data.remoteExpiresAt = 0;
    }
    data.fallbackSide = ''; data.fallbackToken = '';
    if (visible) { await ClipboardWidgetService.update(formId, data); return; }
    await ClipboardWidgetService.finishRead(formId, side, token, false);
  }

  static async revealInApp(formId: string, side: WidgetSide, token: string): Promise<void> {
    if (!formId || !token) throw new Error('Unable to read current content');
    if (ClipboardWidgetService.invalidTokens.has(token)) throw new Error('Server changed during operation');
    const info = await formProvider.getPublishedRunningFormInfoById(formId);
    if (info.formName !== 'ClipboardActions') throw new Error('Unable to read current content');
    let data = ClipboardWidgetService.states.get(formId);
    if (!data || !(side === 'local' ? data.localToken : data.remoteToken)) {
      data = data || ClipboardWidgetService.add(formId);
      if (side === 'local') { data.localToken = token; data.localVisible = true; }
      else { data.remoteToken = token; data.remoteVisible = true; }
    }
    await ClipboardWidgetService.finishRead(formId, side, token, true);
  }

  private static async finishRead(formId: string, side: WidgetSide, token: string,
    foreground: boolean, context?: Context, allowPrompt: boolean = foreground): Promise<void> {
    const data = ClipboardWidgetService.states.get(formId);
    if (!data || (side === 'local' ? data.localToken : data.remoteToken) !== token) return;
    const epoch = ClipboardWidgetService.epoch;
    const account = ClipboardWidgetService.accountKey();
    const valid = (): boolean => epoch === ClipboardWidgetService.epoch && account === ClipboardWidgetService.accountKey() &&
      ClipboardWidgetService.states.get(formId) === data && (side === 'local' ? data.localToken : data.remoteToken) === token;
    try {
      if (side === 'local') { data.localContent = ClipboardWidgetService.t('Reading...'); data.localExpiresAt = Date.now() + 20000; }
      else { data.remoteContent = ClipboardWidgetService.t('Reading...'); data.remoteExpiresAt = Date.now() + 20000; }
      await ClipboardWidgetService.update(formId, data);
      const content = await ClipboardWidgetService.read(side, allowPrompt, context);
      if (!valid()) return;
      if (side === 'local') { data.localContent = content; data.localTime = ClipboardWidgetService.timeLabel(); }
      else { data.remoteContent = content; data.remoteTime = ClipboardWidgetService.timeLabel(); }
      if (side === 'local') data.localExpiresAt = Date.now() + 20000;
      else data.remoteExpiresAt = Date.now() + 20000;
      data.fallbackSide = ''; data.fallbackToken = '';
      await ClipboardWidgetService.update(formId, data);
    } catch (error) {
      if (!valid()) return;
      const message = error instanceof Error ? error.message : String(error);
      if (side === 'local') { data.localContent = ClipboardWidgetService.t(message); data.localTime = ''; }
      else { data.remoteContent = ClipboardWidgetService.t(message); data.remoteTime = ''; }
      if (side === 'local') data.localExpiresAt = Date.now() + 20000;
      else data.remoteExpiresAt = Date.now() + 20000;
      const permissionFallback = !foreground && side === 'local' &&
        (message.toLowerCase().includes('permission') || message.includes('201'));
      data.fallbackSide = permissionFallback ? side : '';
      data.fallbackToken = permissionFallback ? token : '';
      await ClipboardWidgetService.update(formId, data);
      if (foreground) throw new Error(message);
    }
  }
}
