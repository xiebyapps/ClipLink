import { DesktopPanelStore } from './DesktopPanelStore';
import { ClipboardSnapshotUtil } from '../utils/ClipboardSnapshotUtil';
import { common } from '@kit.AbilityKit';
import { ConfigService } from './ConfigService';
import { DesktopRequest } from './DesktopActionService';
import { ClipboardWidgetService } from './ClipboardWidgetService';
import { ClipboardTaskLease } from './ClipboardTaskLease';
import { ClipboardActionFeedback } from './ClipboardActionFeedback';
import { SyncCoordinator, ManualOperationOptions } from './SyncCoordinator';
import { RecordCacheService } from './RecordCacheService';
import { RecordPreviewSession } from './RecordPreviewSession';
import { DownloadCancellation } from './HttpClient';
import { ClipboardUtil } from '../utils/ClipboardUtil';

/** A card call owns one task and one optional foreground sheet. No Home initialization. */
export class ClipboardBackgroundActionService {
  private static instance?: ClipboardBackgroundActionService;
  static getInstance(): ClipboardBackgroundActionService {
    if (!ClipboardBackgroundActionService.instance) ClipboardBackgroundActionService.instance = new ClipboardBackgroundActionService();
    return ClipboardBackgroundActionService.instance;
  }
  mode: string = '';
  status: string = '';
  session?: RecordPreviewSession;
  private context?: common.UIAbilityContext;
  private promote?: (id: string) => Promise<void>;
  private idle?: () => void;
  private uiContext?: UIContext;
  private request?: DesktopRequest;
  private account: string = '';
  private revision: number = 0;
  private busy: boolean = false;
  private lifetime: number = 0;
  private restoring?: Promise<boolean>;
  private continued: boolean = false;
  private finished: Set<string> = new Set();
  private signal: DownloadCancellation = new DownloadCancellation();
  private lease?: ClipboardTaskLease;
  private accountChanged: () => void = (): void => this.invalidate();

  bind(context: common.UIAbilityContext, promote: (id: string) => Promise<void>, idle: () => void): void {
    this.context = context; this.promote = promote; this.idle = idle;
    ConfigService.getInstance().observeAccount(this.accountChanged);
  }

  private accountKey(): string {
    const server = ConfigService.getInstance().getActiveServer();
    return server ? JSON.stringify([server.id, server.url, server.username, server.password]) : '';
  }
  private emit(): void {
    AppStorage.setOrCreate('clipboardActionRevision', (AppStorage.get<number>('clipboardActionRevision') || 0) + 1);
  }
  private valid(): boolean {
    return !!this.request && !this.signal.canceled && this.account === this.accountKey() &&
      this.revision === (AppStorage.get<number>('serverRevision') || 0);
  }
  private check(request?: DesktopRequest): void {
    if (!this.valid() || (request && request !== this.request)) throw new Error('Server changed during operation');
  }

  async accept(request: DesktopRequest, foreground: boolean = false, uiContext?: UIContext): Promise<void> {
    if (this.busy || this.mode === 'authorize' || this.mode === 'running' || this.finished.has(request.id) || !this.context) return;
    if (this.mode) this.close();
    this.request = request; this.busy = true; this.continued = false; this.status = foreground ? 'Working...' : '';
    if (foreground) { this.uiContext = uiContext; this.mode = 'running'; this.emit(); }
    this.signal = new DownloadCancellation();
    this.finished.add(request.id);
    if (this.finished.size > 64) this.finished.delete(Array.from(this.finished)[0]);
    const lifetime = this.lifetime;
    const lease = new ClipboardTaskLease(this.context, request.id, (): void => {
      this.signal.cancel(); this.status = 'Background task time expired'; this.emit();
    }, (): void => { void this.requireForeground(); });
    this.lease = lease;
    try {
      lease.start(foreground ? 'foreground' : 'call');
      ConfigService.getInstance().setContext(this.context);
      await ConfigService.getInstance().loadConfig();
      await ClipboardSnapshotUtil.cleanupAbandoned(this.context);
      await ClipboardWidgetService.validateForm(request.formId);
      this.account = this.accountKey();
      this.revision = AppStorage.get<number>('serverRevision') || 0;
      if (!this.account && request.action !== 'showLocal') throw new Error('No available server');
      RecordCacheService.getInstance().initialize(this.context);
      this.check(request);
      await this.execute(foreground);
    } catch (error) { if (lifetime === this.lifetime) await this.failed(error, foreground); }
    finally {
      await lease.stop();
      if (lifetime !== this.lifetime) return;
      this.lease = undefined; this.busy = false;
      await ClipboardWidgetService.completeRequest(request.formId, request.id);
      if (lifetime !== this.lifetime) return;
      if (this.mode === 'authorize' && this.uiContext) void this.foreground(this.request?.id || '', this.uiContext);
      if (!this.mode) this.idle?.();
    }
  }

  private async execute(foreground: boolean): Promise<void> {
    this.check();
    const request = this.request!;
    await ClipboardWidgetService.actionStatus(request.formId, 'Working...');
    const lease = this.lease;
    const options: ManualOperationOptions = { context: this.context, allowPrompt: foreground, cancellation: this.signal,
      onDownloadProgress: (received: number, total: number): void => { void lease?.progress(received, total); } };
    if (request.action === 'upload') {
      await SyncCoordinator.getInstance().uploadClipboard((_phase: string, received: number, total: number): void => {
        void lease?.progress(received, total);
      }, options);
      this.check(request); this.status = 'Clipboard uploaded';
    } else if (request.action === 'sync') {
      const record = await SyncCoordinator.getInstance().pullNow(options);
      this.check(request);
      if (record.type !== 'Text') {
        await DesktopPanelStore.save(this.context!, request, record);
        this.check(request);
        this.session = new RecordPreviewSession(record, false, this.context);
        this.mode = 'panel'; this.status = 'Open action panel'; this.emit();
        // Let the originating card route only after the server reports an attachment.
        await ClipboardWidgetService.actionStatus(request.formId, this.status, foreground ? '' : request.id);
        this.check(request);
        return;
      }
      this.status = 'Clipboard synchronized';
    } else {
      await ClipboardWidgetService.revealLatest(request.formId, request.action === 'showLocal' ? 'local' : 'remote',
        request.id, this.context!, false);
      this.check(request); this.status = 'Current content updated';
    }
    this.mode = foreground && request.action === 'sync' ? 'complete' : foreground || this.uiContext ? 'result' : '';
    await ClipboardWidgetService.actionStatus(request.formId, this.status);
    this.check(request);
    await ClipboardActionFeedback.show(this.status, this.uiContext);
    this.check(request); this.emit();
  }

  private async requireForeground(): Promise<void> {
    if (!this.valid() || this.mode || !this.busy) return;
    this.mode = 'running'; this.status = 'Keep this panel open to complete the transfer'; this.emit();
    await ClipboardWidgetService.actionStatus(this.request!.formId, this.status);
    await this.openWindow();
  }

  async restorePanel(id: string, formId: string = ''): Promise<boolean> {
    if (this.restoring) return await this.restoring;
    this.restoring = this.restorePanelInternal(id, formId).finally((): void => { this.restoring = undefined; });
    return await this.restoring;
  }

  private async restorePanelInternal(id: string, formId: string): Promise<boolean> {
    if (!id || !this.context) return false;
    if (this.request?.id === id && this.valid() && (this.mode !== 'panel' || this.session?.isActive())) return true;
    if (this.busy) return false;
    const lifetime = this.lifetime;
    const saved = await DesktopPanelStore.restore(this.context, id, formId);
    if (!saved || lifetime !== this.lifetime) return false;
    await ClipboardWidgetService.validateForm(saved.request.formId);
    if (lifetime !== this.lifetime) return false;
    this.session?.close();
    this.request = saved.request; this.signal = new DownloadCancellation();
    this.account = this.accountKey(); this.revision = AppStorage.get<number>('serverRevision') || 0;
    this.session = new RecordPreviewSession(saved.record, false, this.context);
    this.mode = 'panel'; this.status = 'Open action panel'; this.emit();
    await ClipboardWidgetService.actionStatus(saved.request.formId, this.status);
    return true;
  }

  private async failed(error: Object, foreground: boolean): Promise<void> {
    const message = this.signal.canceled ? (this.status || 'Operation canceled') :
      error instanceof Error ? error.message : String(error);
    // Only clipboard access failures request foreground authorization. Network errors stay on the card.
    const needsAccess = /clipboard.*(permission|access)|permission.*clipboard|\b201\b|background.*clipboard/i.test(message);
    if (!foreground && !this.continued && this.valid() && needsAccess) {
      this.mode = 'authorize'; this.status = 'Clipboard access required'; this.emit();
      await ClipboardWidgetService.actionStatus(this.request!.formId, this.status, this.request!.id);
      await this.openWindow(); return;
    }
    this.status = message;
    this.mode = foreground ? 'result' : '';
    this.emit();
    if (this.request) await ClipboardWidgetService.actionStatus(this.request.formId, message);
    await ClipboardActionFeedback.show(message, this.uiContext);
  }

  private async openWindow(): Promise<void> {
    try { await this.promote?.(this.request!.id); }
    catch (_) {
      this.status = 'Tap to open the action panel'; this.emit();
      await ClipboardWidgetService.actionStatus(this.request!.formId, this.status, this.request!.id);
      await ClipboardActionFeedback.show(this.status);
    }
  }

  previewExpired(): void {
    this.session?.close(); this.session = undefined;
    this.mode = 'result'; this.status = 'Background task time expired'; this.emit();
    if (this.request) void ClipboardWidgetService.actionStatus(this.request.formId, this.status);
  }

  async presentationFailed(message: string): Promise<void> {
    if (!this.request) return;
    this.status = message; this.emit();
    await ClipboardWidgetService.actionStatus(this.request.formId, message, this.request.id);
    await ClipboardActionFeedback.show(message);
  }

  /** Foreground continuation is one-shot and keeps the account/request selected at the original click. */
  async foreground(id: string, uiContext: UIContext, formId: string = '', action: string = ''): Promise<void> {
    // Repeated lifecycle callbacks must not submit a router sync twice.
    if (action === 'sync' && id && formId && !this.finished.has(id)) {
      await this.accept({ id: id, action: 'sync', formId: formId, token: '' }, true, uiContext);
      return;
    }
    if (this.busy && this.request?.id === id) {
      this.uiContext = uiContext;
      if (this.mode === 'running') this.lease?.foreground();
      return;
    }
    const invocationLifetime = this.lifetime;
    this.uiContext = uiContext;
    try { await this.restorePanel(id, formId); }
    catch (error) {
      if (invocationLifetime !== this.lifetime) return;
      this.mode = 'result'; this.status = error instanceof Error ? error.message : String(error); this.emit(); return;
    }
    if (invocationLifetime !== this.lifetime) return;
    if (!this.request || this.request.id !== id) {
      this.mode = 'result'; this.status = 'Action expired. Please try again from the card'; this.emit();
      if (formId) {
        await ClipboardWidgetService.validateForm(formId).then((): Promise<void> =>
          ClipboardWidgetService.actionStatus(formId, this.status)).catch((): void => {});
      }
      return;
    }
    if (!this.valid()) { this.mode = 'result'; this.status = 'Server changed during operation'; this.emit(); return; }
    // The window is now visible: remove the retry link without changing the sync button's action.
    await ClipboardWidgetService.actionStatus(this.request.formId, this.status);
    if (invocationLifetime !== this.lifetime) return;
    await ClipboardActionFeedback.authorize(this.context!);
    if (invocationLifetime !== this.lifetime) return;
    if (this.mode === 'running') this.lease?.foreground();
    if (this.mode !== 'authorize' || this.continued || this.busy) return;
    this.continued = true; this.busy = true;
    const request = this.request;
    const lifetime = this.lifetime;
    const lease = new ClipboardTaskLease(this.context!, request.id, (): void => {
      this.signal.cancel(); this.status = 'Background task time expired'; this.emit();
    });
    this.lease = lease;
    try {
      if (!await ClipboardUtil.ensureReadPermission(this.context, true)) throw new Error('Clipboard permission denied');
      lease.start('foreground');
      this.check(request);
      await this.execute(true);
    } catch (error) { if (lifetime === this.lifetime) await this.failed(error, true); }
    finally {
      await lease.stop();
      if (lifetime === this.lifetime) { this.busy = false; this.lease = undefined; }
    }
  }

  windowBackground(): void {
    this.uiContext = undefined;
    if (this.busy) this.lease?.background();
  }

  invalidate(): void {
    if (this.request && this.context) void DesktopPanelStore.clear(this.context, this.request.id);
    this.signal.cancel(); this.session?.close(); this.session = undefined;
    this.mode = this.mode ? 'result' : ''; this.status = 'Server changed during operation'; this.emit();
    void ClipboardWidgetService.resetAll();
  }

  async dismiss(): Promise<void> {
    const formId = this.request?.formId;
    this.close();
    // Retain only the bounded attachment descriptor: a delayed host tap can create a new session, never replay an upload.
    if (formId) await ClipboardWidgetService.actionStatus(formId, '');
  }

  close(): void {
    this.lifetime++; this.busy = false;
    this.signal.cancel(); this.session?.close(); this.session = undefined;
    void this.lease?.stop(); this.mode = ''; this.uiContext = undefined; this.request = undefined;
  }
  destroy(): void {
    this.close(); ConfigService.getInstance().unobserveAccount(this.accountChanged);
    this.context = undefined; this.promote = undefined; this.idle = undefined;
  }
}
