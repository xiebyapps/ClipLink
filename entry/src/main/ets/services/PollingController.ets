/**
 * Polling Controller - manages periodic sync polling
 */
export class PollingController {
  private static instances: Set<PollingController> = new Set();
  private timerId: number = -1;
  private isRunning: boolean = false;
  private resumeOnForeground: boolean = false;
  private isTicking: boolean = false;
  private intervalSeconds: number = 5;
  private callback: () => Promise<void> | void = () => {};

  constructor() {
    PollingController.instances.add(this);
  }

  /**
   * Start polling
   */
  start(intervalSeconds: number, callback: () => Promise<void> | void): void {
    if (this.isRunning) {
      this.stop();
    }

    this.intervalSeconds = intervalSeconds;
    this.callback = callback;
    this.isRunning = true;
    this.resumeOnForeground = true;

    console.info(`[PollingController] Starting with interval ${intervalSeconds}s`);
    
    this.timerId = setInterval(async (): Promise<void> => {
      if (this.isRunning && !this.isTicking) {
        this.isTicking = true;
        try {
          await this.callback();
        } catch (error) {
          console.error('[PollingController] Callback error:', JSON.stringify(error));
        } finally {
          this.isTicking = false;
        }
      }
    }, intervalSeconds * 1000);
  }

  /**
   * Stop polling
   */
  stop(): void {
    if (this.timerId !== -1) {
      clearInterval(this.timerId);
      this.timerId = -1;
    }
    this.isRunning = false;
    this.resumeOnForeground = false;
    console.info('[PollingController] Stopped');
  }

  /**
   * Check if polling is running
   */
  getIsRunning(): boolean {
    return this.isRunning;
  }

  static pauseAll(): void {
    PollingController.instances.forEach((instance: PollingController): void => {
      const shouldResume = instance.isRunning || instance.resumeOnForeground;
      instance.stop();
      instance.resumeOnForeground = shouldResume;
    });
  }

  static resumeAll(): void {
    PollingController.instances.forEach((instance: PollingController): void => {
      if (instance.resumeOnForeground) {
        instance.start(instance.intervalSeconds, instance.callback);
      }
    });
  }

  static stopAll(): void {
    PollingController.instances.forEach((instance: PollingController): void => {
      instance.stop();
    });
  }

  dispose(): void {
    this.stop();
    PollingController.instances.delete(this);
  }
}
