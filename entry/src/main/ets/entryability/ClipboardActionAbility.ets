import { ClipboardActionFeedback } from '../services/ClipboardActionFeedback';
import { ClipboardWidgetService } from '../services/ClipboardWidgetService';
import UIAbility from '@ohos.app.ability.UIAbility';
import { AbilityConstant, Want, Configuration } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { rpc } from '@kit.IPCKit';
import { DesktopRequest, DesktopAction } from '../services/DesktopActionService';
import { ClipboardBackgroundActionService } from '../services/ClipboardBackgroundActionService';
import { ConfigService } from '../services/ConfigService';
import { LocalizationUtil } from '../utils/LocalizationUtil';

interface CardCall {
  desktopAction?: string;
  requestId?: string;
  formId?: string;
  widgetToken?: string;
}
class CallAck implements rpc.Parcelable {
  private status: string;
  constructor(status: string = 'accepted') { this.status = status; }
  marshalling(data: rpc.MessageSequence): boolean { data.writeString(this.status); return true; }
  unmarshalling(data: rpc.MessageSequence): boolean { data.readString(); return true; }
}

/** Singleton callee creates no window until authorization or a file operation sheet is needed. */
export default class ClipboardActionAbility extends UIAbility {
  private foregroundWindow: boolean = false;
  private windowStage?: window.WindowStage;
  private contentLoaded: boolean = false;
  private callHandler = (data: rpc.MessageSequence): rpc.Parcelable => {
    try {
      const request = JSON.parse(data.readString()) as CardCall;
      if (typeof request.formId === 'string' && request.formId &&
        typeof request.requestId === 'string' && request.requestId && typeof request.desktopAction === 'string' &&
        ['upload', 'sync', 'showLocal', 'showRemote'].includes(request.desktopAction)) {
        const action: DesktopRequest = { id: request.requestId,
          action: request.desktopAction as DesktopAction, formId: request.formId,
          token: request.widgetToken || '' };
        void ClipboardBackgroundActionService.getInstance().accept(action);
        return new CallAck();
      }
    } catch (_) { /* Do not log payloads from malformed messages. */ }
    console.error('[ClipboardAction] Rejected invalid card call parameters');
    void this.repairCards();
    return new CallAck('rejected');
  };

  private async repairCards(): Promise<void> {
    try {
      ConfigService.getInstance().setContext(this.context);
      await ConfigService.getInstance().loadConfig();
      await ClipboardWidgetService.resetAll(this.context);
      await ClipboardActionFeedback.show('Widget refreshed. Tap again');
    } catch (_) { console.error('[ClipboardAction] Failed to refresh card identity'); }
    finally { if (!this.foregroundWindow) void this.context.terminateSelf(); }
  }

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    const service = ClipboardBackgroundActionService.getInstance();
    service.bind(this.context, async (id: string): Promise<void> => {
      await this.context.startAbility({ bundleName: this.context.abilityInfo.bundleName,
        abilityName: 'ClipboardActionAbility', parameters: { actionWindow: 'panel', requestId: id } });
    }, (): void => { if (!this.foregroundWindow) void this.context.terminateSelf(); });
    this.callee.on('perform', this.callHandler);
    this.acceptWant(want);
  }

  private acceptWant(want: Want): boolean {
    const params = want.parameters;
    if (!params) return false;
    const marker = params.actionWindow;
    if (marker !== true && marker !== 'true' && marker !== 'panel') return false;
    this.foregroundWindow = true;
    AppStorage.setOrCreate('clipboardActionFormId', String(params.formId || ''));
    AppStorage.setOrCreate('clipboardActionDirectAction', params.desktopAction === 'sync' ? 'sync' : '');
    AppStorage.setOrCreate('clipboardActionRequestId', String(params.requestId || ''));
    return true;
  }
  onNewWant(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    if (!this.acceptWant(want)) return;
    AppStorage.setOrCreate('clipboardActionRevision', (AppStorage.get<number>('clipboardActionRevision') || 0) + 1);
    if (this.windowStage && !this.contentLoaded) this.onWindowStageCreate(this.windowStage);
    else if (this.windowStage && this.contentLoaded) this.onForeground();
  }

  onWindowStageCreate(stage: window.WindowStage): void {
    this.foregroundWindow = true; this.windowStage = stage;
    ConfigService.getInstance().setContext(this.context);
    void ConfigService.getInstance().loadConfig().then(async (): Promise<void> => {
      if (AppStorage.get<string>('clipboardActionDirectAction') !== 'sync') await ClipboardBackgroundActionService.getInstance().restorePanel(
        AppStorage.get<string>('clipboardActionRequestId') || '', AppStorage.get<string>('clipboardActionFormId') || '')
        .catch((): void => {});
      AppStorage.setOrCreate('systemLanguage', LocalizationUtil.systemLanguage());
      AppStorage.setOrCreate('systemColorMode', this.context.config.colorMode);
      stage.loadContent('pages/ClipboardActionPage', (error): void => {
        if (error.code) { this.presentationFailed(); return; }
        this.contentLoaded = true;
        // Apply transparency after content loading; the real desktop remains underneath.
        try { stage.getMainWindowSync().setWindowBackgroundColor('#00000000'); }
        catch (_) { this.presentationFailed(); }
      });
    });
  }
  onForeground(): void {
    AppStorage.setOrCreate('clipboardActionForeground', true);
    if (!this.windowStage || !this.contentLoaded) return;
    void ClipboardBackgroundActionService.getInstance().foreground(
      AppStorage.get<string>('clipboardActionRequestId') || '', this.windowStage.getMainWindowSync().getUIContext(),
      AppStorage.get<string>('clipboardActionFormId') || '', AppStorage.get<string>('clipboardActionDirectAction') || '');
  }
  onBackground(): void {
    this.foregroundWindow = false;
    AppStorage.setOrCreate('clipboardActionForeground', false);
    ClipboardBackgroundActionService.getInstance().windowBackground();
  }

  onWindowStageDestroy(): void { this.windowStage = undefined; this.contentLoaded = false; this.foregroundWindow = false; }

  private presentationFailed(): void {
    void ClipboardBackgroundActionService.getInstance().presentationFailed('Desktop panel is unavailable on this device')
      .finally((): void => { void this.context.moveAbilityToBackground().catch((): void => {}); });
  }

  onConfigurationUpdate(config: Configuration): void {
    AppStorage.setOrCreate('systemLanguage', LocalizationUtil.systemLanguage());
    AppStorage.setOrCreate('systemColorMode', config.colorMode);
  }
  onDestroy(): void {
    this.callee.off('perform');
    ClipboardBackgroundActionService.getInstance().destroy();
  }
}
