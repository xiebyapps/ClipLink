import { HistoryRecordDto } from '../types/ApiTypes';
import { UserFileSaveUtil } from './UserFileSaveUtil';
import { LocalizationUtil } from './LocalizationUtil';

export class FileRecordDisplayUtil {
  private static baseName(value: string): string {
    return value.trim().replace(/\\/g, '/').split('/').pop() || '';
  }

  static text(record: HistoryRecordDto, language: string, systemLanguage: string): string {
    if (record.type === 'Text') return record.text || LocalizationUtil.text('[No content]', language, systemLanguage);
    const names = (record.text || '').split(/\r?\n/)
      .map((name: string): string => FileRecordDisplayUtil.baseName(name)).filter((name: string): boolean => !!name);
    if (names.length > 0) return record.type === 'Group' ? names.join('\n') : names[0];
    return `${LocalizationUtil.text(record.type, language, systemLanguage)}-${record.hash.slice(0, 8)}`;
  }

  static icon(record: HistoryRecordDto): Resource {
    if (record.type === 'Text') return $r('app.media.record_text');
    if (record.type === 'Group') return $r('app.media.record_group');
    const name = FileRecordDisplayUtil.baseName((record.text || '').split(/\r?\n/)[0]);
    const category = UserFileSaveUtil.category(record.type, name);
    if (category === 'Image') return $r('app.media.record_image');
    if (category === 'Sounds') return $r('app.media.record_audio');
    if (category === 'Documents') return $r('app.media.record_document');
    const extension = name.split('.').pop()?.toLowerCase() || '';
    if (['mp4', 'mov', 'mkv', 'avi', 'webm', 'm4v', '3gp', 'ts', 'wmv'].includes(extension)) {
      return $r('app.media.record_video');
    }
    if (['zip', 'rar', '7z', 'tar', 'gz', 'bz2', 'xz'].includes(extension)) {
      return $r('app.media.record_archive');
    }
    return $r('app.media.record_file');
  }

  static cardBackground(record: HistoryRecordDto | undefined, isDark: boolean, normal: string): string {
    return record?.starred ? (isDark ? '#3B321B' : '#FFF7D6') : normal;
  }
}
