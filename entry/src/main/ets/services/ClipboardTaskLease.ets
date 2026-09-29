import { BusinessError } from '@kit.BasicServicesKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { common, wantAgent } from '@kit.AbilityKit';
import { notificationManager } from '@kit.NotificationKit';
import { ConfigService } from './ConfigService';
import { LocalizationUtil } from '../utils/LocalizationUtil';

/** One user initiated task, with a real system deadline and no idle keepalive. */
export class ClipboardTaskLease {
  private context: common.UIAbilityContext;
  private onExpired: () => void;
  private delayId: number = -1;
  private deadline: number = -1;
  private escalation: number = -1;
  private stopped: boolean = false;
  private continuous?: backgroundTaskManager.ContinuousTaskNotification;
  private starting?: Promise<void>;
  private lastProgress: number = 0;
  private previousBytes: number = 0;
  private previousTime: number = Date.now();
  private requestId: string;
  private mode: 'call' | 'foreground' | 'background' = 'background';
  private onForegroundRequired?: () => void;
  private cancelHandler = (info: backgroundTaskManager.ContinuousTaskCancelInfo): void => {
    if (this.stopped || !this.continuous || info.id !== this.continuous.continuousTaskId) return;
    this.onExpired(); void this.stop();
  };

  constructor(context: common.UIAbilityContext, requestId: string, onExpired: () => void, onForegroundRequired?: () => void) {
    this.context = context; this.requestId = requestId; this.onExpired = onExpired; this.onForegroundRequired = onForegroundRequired;
  }

  private t(value: string): string {
    return LocalizationUtil.text(value, ConfigService.getInstance().getConfig().language,
      LocalizationUtil.systemLanguage());
  }

  start(mode: 'call' | 'foreground' | 'background' = 'background'): void {
    this.mode = mode;
    // A card call does not reopen the system's five-second post-background transient-task window.
    // Foreground work also needs no suspend delay. Both use ordinary execution, with a bounded card deadline.
    if (mode === 'call') this.deadline = setTimeout((): void => this.expire(), 30000);
    if (mode === 'background') {
      try {
        const delay = backgroundTaskManager.requestSuspendDelay('Clipboard action', (): void => this.expire());
        this.delayId = delay.requestId;
        if (delay.actualDelayTime <= 0) { this.expire(); return; }
        this.deadline = setTimeout((): void => this.expire(), delay.actualDelayTime);
      } catch (error) {
        console.warn(`[ClipboardTaskLease] Suspend delay unavailable: ${(error as BusinessError).code}`);
        this.expire(); return;
      }
    }
    this.escalation = setTimeout((): void => {
      void this.ensureTransfer().catch((error: BusinessError): void => {
        if (this.stopped) return;
        console.warn(`[ClipboardTaskLease] Transfer background grant unavailable: ${error.code}`);
        if (this.mode === 'call') this.onForegroundRequired?.();
        else if (this.mode === 'background') this.expire();
        // A denied background grant must not cancel a download while its foreground window is visible.
      });
    }, 8000);
  }

  foreground(): void {
    this.mode = 'foreground';
    this.clearDelay();
    if (!this.continuous && !this.starting) {
      void this.ensureTransfer().catch((error: BusinessError): void => {
        console.warn(`[ClipboardTaskLease] Foreground transfer grant unavailable: ${error.code}`);
      });
    }
  }

  background(): void {
    if (this.stopped || this.continuous) return;
    this.clearDelay();
    this.start('background');
  }

  private clearDelay(): void {
    if (this.deadline !== -1) clearTimeout(this.deadline);
    if (this.escalation !== -1) clearTimeout(this.escalation);
    this.deadline = -1; this.escalation = -1;
    if (this.delayId !== -1) {
      try { backgroundTaskManager.cancelSuspendDelay(this.delayId); } catch (_) { }
      this.delayId = -1;
    }
  }

  private expire(): void {
    if (this.stopped || this.continuous || this.mode === 'foreground') return;
    this.onExpired();
    void this.stop();
  }

  async ensureTransfer(): Promise<void> {
    if (this.stopped || this.continuous) return;
    if (this.starting) return await this.starting;
    this.starting = (async (): Promise<void> => {
      const agent = await wantAgent.getWantAgent({ wants: [{
        bundleName: this.context.abilityInfo.bundleName, abilityName: 'ClipboardActionAbility',
        parameters: { requestId: this.requestId, actionWindow: true }
      }], operationType: wantAgent.OperationType.START_ABILITY, requestCode: 8301,
        wantAgentFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG] });
      if (this.stopped) return;
      const task = await backgroundTaskManager.startBackgroundRunning(this.context, ['dataTransfer'], agent);
      if (this.stopped) { await backgroundTaskManager.stopBackgroundRunning(this.context); return; }
      this.continuous = task;
      backgroundTaskManager.on('continuousTaskCancel', this.cancelHandler);
      this.clearDelay();
      await this.progress(0, 0);
    })();
    try { await this.starting; } finally { this.starting = undefined; }
  }

  async progress(received: number, total: number): Promise<void> {
    if (this.stopped || !this.continuous || Date.now() - this.lastProgress < 1000) return;
    this.lastProgress = Date.now();
    const elapsed = Math.max(1, this.lastProgress - this.previousTime);
    const speed = Math.max(0, received - this.previousBytes) * 1000 / elapsed;
    this.previousBytes = received; this.previousTime = this.lastProgress;
    const title = this.t('Clipboard transfer');
    const text = `${LocalizationUtil.formatBytes(received)} / ${total > 0 ? LocalizationUtil.formatBytes(total) : '—'} · ${LocalizationUtil.formatBytes(speed)}/s`;
    await notificationManager.publish({ id: this.continuous.notificationId,
      notificationSlotType: this.continuous.slotType,
      content: { notificationContentType: this.continuous.contentType,
        systemLiveView: { typeCode: 8, title: title, text: text } },
      template: { name: 'downloadTemplate', data: { title: title, fileName: this.t('Clipboard action'),
        progressValue: total > 0 ? received / total * 100 : 0 } }
    }).catch((): void => {});
  }

  async stop(): Promise<void> {
    if (this.stopped) return;
    this.stopped = true;
    this.clearDelay();
    if (this.starting) await this.starting.catch((): void => {});
    if (this.continuous) {
      backgroundTaskManager.off('continuousTaskCancel', this.cancelHandler);
      this.continuous = undefined;
      await backgroundTaskManager.stopBackgroundRunning(this.context).catch((): void => {});
    }
  }
}
