export type DesktopAction = 'upload' | 'sync' | 'showLocal' | 'showRemote';

export interface DesktopRequest {
  id: string;
  action: DesktopAction;
  formId: string;
  token: string;
}

/** Owns launch requests across configuration loading and UI creation. Never persists requests. */
export class DesktopActionService {
  private static pending?: DesktopRequest;
  private static busy: boolean = false;
  private static configurationReady: boolean = false;
  private static foreground: boolean = false;
  private static consumer?: (request: DesktopRequest) => Promise<void>;
  private static completed: Set<string> = new Set<string>();

  static accept(action: string, formId: string = '', token: string = '', id: string = ''): void {
    if (!['upload', 'sync', 'showLocal', 'showRemote'].includes(action)) return;
    const requestId = id || `${Date.now()}-${Math.random().toString(36).slice(2)}`;
    if (DesktopActionService.busy || DesktopActionService.pending || DesktopActionService.completed.has(requestId)) return;
    DesktopActionService.pending = { id: requestId, action: action as DesktopAction, formId: formId, token: token };
    AppStorage.setOrCreate('desktopActionRevision', (AppStorage.get<number>('desktopActionRevision') || 0) + 1);
    DesktopActionService.drain();
  }

  static pendingWidgetToken(): string { return DesktopActionService.pending?.token || ''; }

  static cancelPending(): void { DesktopActionService.pending = undefined; }

  static configure(): void { DesktopActionService.configurationReady = true; DesktopActionService.drain(); }
  static setForeground(value: boolean): void { DesktopActionService.foreground = value; DesktopActionService.drain(); }
  static attach(consumer: (request: DesktopRequest) => Promise<void>): void {
    DesktopActionService.consumer = consumer; DesktopActionService.drain();
  }
  static detach(): void { DesktopActionService.consumer = undefined; }

  private static drain(): void {
    const request = DesktopActionService.pending;
    const consumer = DesktopActionService.consumer;
    if (!request || !consumer || DesktopActionService.busy || !DesktopActionService.foreground ||
      !DesktopActionService.configurationReady) return;
    DesktopActionService.pending = undefined;
    DesktopActionService.busy = true;
    DesktopActionService.completed.add(request.id);
    if (DesktopActionService.completed.size > 64) {
      const oldest: string = Array.from(DesktopActionService.completed)[0];
      if (oldest) DesktopActionService.completed.delete(oldest);
    }
    void consumer(request).catch((error: Error): void => {
      console.error('[DesktopAction] Action failed:', error.message);
    }).finally((): void => { DesktopActionService.busy = false; DesktopActionService.drain(); });
  }
}
