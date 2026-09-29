import { ConfigService } from '../services/ConfigService';
import { ServerManager } from '../services/ServerManager';
import { ShareTransferState } from '../services/ShareTransferState';
import { FileUploadTask, UploadFile } from '../services/FileUploadService';
import { HistoryStorageService } from '../services/HistoryStorageService';
import { ServerAccount } from '../types/ApiTypes';
import { LocalizationUtil } from '../utils/LocalizationUtil';

@Entry
@Component
struct SharePage {
  @State files: UploadFile[] = [];
  @State accounts: ServerAccount[] = [];
  @State selectedServerId: string = '';
  @State status: string = '';
  @State busy: boolean = false;
  @State received: number = 0;
  @State total: number = 0;
  @State speed: number = 0;
  @StorageLink('appLanguage') appLanguage: string = 'system';
  @StorageLink('systemLanguage') systemLanguage: string = 'en';
  private progressTime: number = 0;
  private progressBytes: number = 0;

  private t(value: string): string {
    return LocalizationUtil.text(value, this.appLanguage, this.systemLanguage);
  }

  aboutToAppear(): void {
    this.systemLanguage = LocalizationUtil.systemLanguage();
    this.files = ShareTransferState.files.slice();
    void this.loadAccounts();
  }

  private async loadAccounts(): Promise<void> {
    await ConfigService.getInstance().loadConfig();
    const config = ConfigService.getInstance().getConfig();
    this.appLanguage = config.language;
    this.accounts = config.servers.slice();
    this.selectedServerId = config.activeServerId || this.accounts[0]?.id || '';
    if (!this.accounts.length) this.status = 'No available server';
  }

  private async close(): Promise<void> {
    await ShareTransferState.session?.terminateSelf();
  }

  private async upload(): Promise<void> {
    const context = ShareTransferState.context;
    if (this.busy || this.files.length === 0 || !context) return;
    this.busy = true;
    this.status = 'Checking connection...';
    this.received = 0;
    this.total = 0;
    this.speed = 0;
    this.progressTime = Date.now();
    this.progressBytes = 0;
    try {
      const serverId = this.selectedServerId;
      const server = this.accounts.find((account: ServerAccount): boolean => account.id === serverId);
      if (!server) throw new Error('Server not found');
      await ServerManager.getInstance().select(serverId);
      const task = new FileUploadTask();
      ShareTransferState.task = task;
      const uploadedRecord = await task.upload(this.files, server, context,
        (phase: string, received: number, total: number): void => {
          const now = Date.now();
          if (phase !== this.status) {
            this.progressTime = now;
            this.progressBytes = received;
            this.received = received;
            this.total = total;
            this.speed = 0;
          }
          const elapsed = now - this.progressTime;
          if (elapsed >= 350 || received === total) {
            this.speed = elapsed > 0 ? Math.max(0, (received - this.progressBytes) * 1000 / elapsed) : 0;
            this.received = received;
            this.total = total;
            this.progressTime = now;
            this.progressBytes = received;
          }
          this.status = phase;
        });
      await HistoryStorageService.getInstance().upsertRecord(uploadedRecord, server.id, context);
      AppStorage.setOrCreate('historyRefreshToken',
        (AppStorage.get<number>('historyRefreshToken') || 0) + 1);
      this.status = 'Upload Success';
    } catch (error) {
      this.status = `Upload Error: ${error instanceof Error ? error.message : String(error)}`;
    } finally {
      ShareTransferState.task = null;
      this.busy = false;
    }
  }

  build() {
    Column({ space: 16 }) {
      Text(this.t('Upload Files'))
        .fontSize(24)
        .fontWeight(FontWeight.Bold)
        .width('100%')
      if (this.files.length === 0) {
        Text(this.t('No files selected'))
          .fontColor('#C62828')
      } else {
        Text(`${this.files.length} ${this.t(this.files.length === 1 ? 'File' : 'Files')}`)
          .fontSize(15)
          .width('100%')
        Scroll() {
          Column({ space: 8 }) {
            ForEach(this.files, (file: UploadFile, index: number) => {
              Text(file.name || file.uri.split('/').pop() || `${this.t('File')} ${index + 1}`)
                .fontSize(14)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .width('100%')
            }, (file: UploadFile, index: number) => `${index}-${file.uri}`)
          }
        }
        .height(120)
      }
      Text(this.t('Servers'))
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .width('100%')
      Scroll() {
        Column({ space: 8 }) {
          ForEach(this.accounts, (account: ServerAccount) => {
            Button(this.t(account.name), { type: ButtonType.Capsule })
              .width('100%')
              .backgroundColor(this.selectedServerId === account.id ? '#0A7F5A' : '#637080')
              .onClick(() => { this.selectedServerId = account.id; })
          }, (account: ServerAccount) => account.id)
        }
      }
      .height(120)
      if (this.status) {
        Text(this.t(this.status))
          .fontSize(14)
          .width('100%')
      }
      if (this.busy) {
        if (this.total > 0) {
          Progress({ value: Math.min(this.received, this.total), total: this.total,
            type: ProgressType.Linear }).width('100%')
        } else {
          LoadingProgress().width(24).height(24)
        }
        Text(`${LocalizationUtil.formatBytes(this.received)}` +
          (this.total ? ` / ${LocalizationUtil.formatBytes(this.total)}` : '') +
          ` · ${LocalizationUtil.formatBytes(this.speed)}/s`)
          .fontSize(12)
      }
      Row({ space: 12 }) {
        Button(this.t('Cancel'), { type: ButtonType.Capsule })
          .layoutWeight(1)
          .onClick(() => {
            if (this.busy) ShareTransferState.task?.cancel();
            else void this.close();
          })
        Button(this.t(this.status === 'Upload Success' ? 'Done' : 'Upload Files'),
          { type: ButtonType.Capsule })
          .layoutWeight(1)
          .enabled(this.accounts.length > 0 && !this.busy && this.files.length > 0)
          .onClick(() => {
            if (this.status === 'Upload Success') void this.close();
            else void this.upload();
          })
      }
      .width('100%')
    }
    .width('100%')
    .height('100%')
    .padding(24)
    .backgroundColor('#F5F7F9')
  }
}
