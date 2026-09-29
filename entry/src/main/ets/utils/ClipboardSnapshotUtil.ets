import { BusinessError } from '@kit.BasicServicesKit';
import pasteboard from '@ohos.pasteboard';
import systemDateTime from '@ohos.systemDateTime';
import cryptoFramework from '@ohos.security.cryptoFramework';
import { image } from '@kit.ImageKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { ClipboardUtil } from './ClipboardUtil';
import { HashUtil } from './HashUtil';

export interface ClipboardSnapshot {
  kind: 'Text' | 'Image' | 'Unsupported' | 'Empty';
  changeCount: number;
  time: number;
  bootEpoch: number;
  fingerprint: string;
  text: string;
  imagePath: string;
}

export class ClipboardSnapshotUtil {
  private static orphanCleanup?: Promise<void>;

  /** Run once before any ability starts work; do not remove temporaries owned by another live ability. */
  static async cleanupAbandoned(context: Context): Promise<void> {
    if (!ClipboardSnapshotUtil.orphanCleanup) {
      ClipboardSnapshotUtil.orphanCleanup = (async (): Promise<void> => {
        const root = context.cacheDir.replace(/\/$/, '');
        for (const name of fs.listFileSync(root)) {
          const image = /^auto-sync-\d+-[a-z0-9]+\.png$/.test(name);
          const upload = /^upload-\d+-[a-z0-9]+$/.test(name);
          if (!image && !upload) continue;
          const path = `${root}/${name}`;
          try {
            if (image && fs.lstatSync(path).isFile()) await fs.unlink(path);
            else if (upload && fs.lstatSync(path).isDirectory()) await fs.rmdir(path);
          } catch (_) { /* A missing or locked file can be retried after the next process start. */ }
        }
      })().catch((): void => {});
    }
    await ClipboardSnapshotUtil.orphanCleanup;
  }

  static changeCount(): number {
    return pasteboard.getSystemPasteboard().getChangeCount();
  }

  static bootEpoch(): number {
    return Date.now() - systemDateTime.getUptime(systemDateTime.TimeType.STARTUP);
  }

  static async fileHash(path: string): Promise<string> {
    const file = await fs.open(path, fs.OpenMode.READ_ONLY);
    try {
      const md = cryptoFramework.createMd('SHA256');
      const buffer = new ArrayBuffer(256 * 1024);
      while (true) {
        const count = await fs.read(file.fd, buffer);
        if (count === 0) break;
        await md.update({ data: new Uint8Array(buffer.slice(0, count)) });
      }
      const digest = await md.digest();
      return Array.from(digest.data).map((value: number): string =>
        value.toString(16).padStart(2, '0')).join('').toUpperCase();
    } finally {
      await fs.close(file);
    }
  }

  static async packImage(pixelMap: image.PixelMap, path: string): Promise<string> {
    const file = await fs.open(path, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY);
    const packer = image.createImagePacker();
    try {
      await packer.packToFile(pixelMap, file.fd, { format: 'image/png', quality: 100 });
    } finally {
      await packer.release();
      await fs.close(file);
    }
    return await ClipboardSnapshotUtil.fileHash(path);
  }

  static tempPath(owner?: Context): string {
    const context = owner || AppStorage.get<Context>('abilityContext');
    if (!context) throw new Error('Ability context is not initialized');
    return `${context.cacheDir}/auto-sync-${Date.now()}-${Math.random().toString(36).slice(2)}.png`;
  }

  static async remove(path: string): Promise<void> {
    if (path) await fs.unlink(path).catch((): void => {});
  }

  static async capture(context?: Context, allowPrompt: boolean = true): Promise<ClipboardSnapshot> {
    if (!await ClipboardUtil.ensureReadPermission(context, allowPrompt)) throw new Error('Clipboard permission denied');
    const board = pasteboard.getSystemPasteboard();
    const count = board.getChangeCount();
    const epoch = ClipboardSnapshotUtil.bootEpoch();
    const result: ClipboardSnapshot = {
      kind: 'Empty', changeCount: count, time: NaN, bootEpoch: epoch,
      fingerprint: 'Empty', text: '', imagePath: ''
    };
    try {
      if (await board.hasData()) {
        const data = await board.getData();
        const timestamp = data.getProperty().timestamp / 1000000;
        const uptime = systemDateTime.getUptime(systemDateTime.TimeType.STARTUP);
        result.time = Number.isFinite(timestamp) && timestamp > 0 && timestamp <= uptime + 100
          ? epoch + timestamp : NaN;
        const mime = data.getPrimaryMimeType();
        if (mime === pasteboard.MIMETYPE_TEXT_PLAIN) {
          result.kind = 'Text';
          result.text = data.getPrimaryText() || '';
          result.fingerprint = `Text-${await HashUtil.calculateTextHash(result.text)}`;
        } else if (mime === pasteboard.MIMETYPE_PIXELMAP) {
          result.kind = 'Image';
          const pixelMap = data.getPrimaryPixelMap();
          if (!pixelMap) throw new Error('Clipboard image is unavailable');
          result.imagePath = ClipboardSnapshotUtil.tempPath(context);
          try {
            result.fingerprint = `Image-${await ClipboardSnapshotUtil.packImage(pixelMap, result.imagePath)}`;
          } finally {
            await pixelMap.release();
          }
        } else {
          result.kind = 'Unsupported';
          result.fingerprint = `Unsupported-${count}`;
        }
      }
      if (board.getChangeCount() !== count) throw new Error('Clipboard changed during read');
      return result;
    } catch (error) {
      await ClipboardSnapshotUtil.remove(result.imagePath);
      if ((error as BusinessError)?.code === 201) throw new Error('Clipboard permission denied');
      throw error instanceof Error ? error : new Error(String(error));
    }
  }
}
