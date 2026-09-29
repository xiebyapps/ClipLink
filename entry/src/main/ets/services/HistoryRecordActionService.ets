import { RecordCacheService } from './RecordCacheService';
import { ConfigService } from './ConfigService';
import { HistoryRecordDto } from '../types/ApiTypes';
import { SyncClipboardService } from './SyncClipboardService';
import { ClipboardUtil } from '../utils/ClipboardUtil';
import { UserFileSaveUtil } from '../utils/UserFileSaveUtil';
import { ImageUtil } from '../utils/ImageUtil';

export class HistoryRecordActionService {
  static async copyImage(record: HistoryRecordDto, service: SyncClipboardService,
    onProgress: (received: number, total: number) => void,
    isCurrent: () => boolean): Promise<void> {
    const lease = await RecordCacheService.getInstance().acquire(record,
      ConfigService.getInstance().getConfig().activeServerId, service, onProgress);
    try {
      if (!isCurrent()) throw new Error('Server changed during operation');
      const pixelMap = await ImageUtil.createPixelMapFromPath(lease.response.path);
      try {
        if (!isCurrent()) throw new Error('Server changed during operation');
        await ClipboardUtil.setClipboardImage(pixelMap);
      } finally {
        await pixelMap.release();
      }
    } finally {
      lease.release();
    }
  }
}
