export class DownloadNoticeSnapshot {
  visible: boolean = false;
  name: string = '';
  status: string = 'Downloading...';
  received: number = 0;
  total: number = 0;
  speed: number = 0;
  finished: boolean = false;
  failed: boolean = false;
}

class DownloadNoticeTask {
  id: number = 0;
  snapshot: DownloadNoticeSnapshot = new DownloadNoticeSnapshot();
  previousTime: number = 0;
  previousBytes: number = 0;
}

/** App-wide resident download notice; task IDs protect newer downloads from old timers. */
export class DownloadNoticeService {
  private static tasks: Map<number, DownloadNoticeTask> = new Map();
  private static current: DownloadNoticeSnapshot = new DownloadNoticeSnapshot();
  private static selectedId: number = 0;
  private static sequence: number = 0;
  private static dismissTimer: number = -1;

  static snapshot(): DownloadNoticeSnapshot { return DownloadNoticeService.current; }

  private static publish(snapshot: DownloadNoticeSnapshot): void {
    DownloadNoticeService.current = snapshot;
    AppStorage.setOrCreate('downloadNoticeRevision', (AppStorage.get<number>('downloadNoticeRevision') || 0) + 1);
  }

  static begin(name: string, total: number = 0): number {
    if (DownloadNoticeService.dismissTimer !== -1) {
      clearTimeout(DownloadNoticeService.dismissTimer);
      DownloadNoticeService.dismissTimer = -1;
    }
    const task = new DownloadNoticeTask();
    task.id = ++DownloadNoticeService.sequence;
    task.previousTime = Date.now();
    task.snapshot.visible = true;
    task.snapshot.name = name;
    task.snapshot.total = Math.max(0, total);
    DownloadNoticeService.tasks.set(task.id, task);
    DownloadNoticeService.selectedId = task.id;
    DownloadNoticeService.publish(task.snapshot);
    return task.id;
  }

  static progress(id: number, received: number, total: number): void {
    const task = DownloadNoticeService.tasks.get(id);
    if (!task) return;
    const now = Date.now();
    const elapsed = now - task.previousTime;
    if (elapsed < 350 && (total <= 0 || received < total)) return;
    task.snapshot.received = Math.max(0, received);
    if (total > 0) task.snapshot.total = total;
    task.snapshot.speed = elapsed > 0 ? Math.max(0, (received - task.previousBytes) * 1000 / elapsed) : 0;
    task.previousBytes = received;
    task.previousTime = now;
    if (id === DownloadNoticeService.selectedId) DownloadNoticeService.publish(task.snapshot);
  }

  static status(id: number, status: string, name?: string): void {
    const task = DownloadNoticeService.tasks.get(id);
    if (!task) return;
    task.snapshot.status = status;
    if (name) task.snapshot.name = name;
    if (id === DownloadNoticeService.selectedId) DownloadNoticeService.publish(task.snapshot);
  }

  static finish(id: number, status: string = 'Download complete', failed: boolean = false): void {
    const task = DownloadNoticeService.tasks.get(id);
    if (!task) return;
    DownloadNoticeService.tasks.delete(id);
    if (id !== DownloadNoticeService.selectedId) return;
    const pending = Array.from(DownloadNoticeService.tasks.values());
    if (pending.length > 0) {
      const next = pending[pending.length - 1];
      DownloadNoticeService.selectedId = next.id;
      DownloadNoticeService.publish(next.snapshot);
      return;
    }
    task.snapshot.status = status;
    task.snapshot.finished = true;
    task.snapshot.failed = failed;
    DownloadNoticeService.publish(task.snapshot);
    DownloadNoticeService.dismissTimer = setTimeout((): void => {
      DownloadNoticeService.dismissTimer = -1;
      if (id !== DownloadNoticeService.selectedId || DownloadNoticeService.tasks.size > 0) return;
      DownloadNoticeService.publish(new DownloadNoticeSnapshot());
    }, 2000);
  }
}
