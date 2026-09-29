import { DownloadRule } from '../types/ApiTypes';

export type NumericSettingKey = 'polling' | 'threshold' | 'capacity' | 'history';

export class NumericSettingSpec {
  min: number;
  max: number;
  step: number;
  decimals: number;
  constructor(min: number, max: number, step: number, decimals: number = 0) {
    this.min = min; this.max = max; this.step = step; this.decimals = decimals;
  }
}

export class SettingsPolicy {
  static numeric(key: NumericSettingKey): NumericSettingSpec {
    if (key === 'polling') return new NumericSettingSpec(10, 7200, 10);
    if (key === 'threshold') return new NumericSettingSpec(20, 1000, 10);
    if (key === 'capacity') return new NumericSettingSpec(0.5, 10, 0.1, 1);
    return new NumericSettingSpec(50, 1000, 50);
  }

  static parse(key: NumericSettingKey, text: string): number {
    const spec = SettingsPolicy.numeric(key);
    const pattern = spec.decimals ? /^\d+(\.\d)?$/ : /^\d+$/;
    if (!pattern.test(text.trim())) throw new Error('Enter a valid number');
    const value = Number(text.trim());
    if (!Number.isFinite(value) || value < spec.min || value > spec.max) {
      throw new Error('Number is outside the allowed range');
    }
    return value;
  }

  static adjust(key: NumericSettingKey, value: number, direction: number): number {
    const spec = SettingsPolicy.numeric(key);
    return Number(Math.min(spec.max, Math.max(spec.min, value + direction * spec.step)).toFixed(spec.decimals));
  }

  static normalize(key: NumericSettingKey, value: number, fallback: number): number {
    const spec = SettingsPolicy.numeric(key);
    return Number(Math.min(spec.max, Math.max(spec.min, Number.isFinite(value) ? value : fallback)).toFixed(spec.decimals));
  }

  static defaultRules(): DownloadRule[] {
    return [
      { id: 'sounds', folder: 'Sounds', extensions: ['mp3', 'm4a', 'aac', 'wav', 'flac', 'ogg', 'opus', 'wma', 'aiff', 'amr', 'mid', 'midi'] },
      { id: 'documents', folder: 'Documents', extensions: ['pdf', 'doc', 'docx', 'xls', 'xlsx', 'ppt', 'pptx', 'txt', 'md', 'rtf', 'csv', 'odt', 'ods', 'odp', 'epub'] }
    ];
  }

  static folderIsValid(folder: string): boolean {
    return !!folder.trim() && folder === folder.trim() && folder.length <= 100 &&
      folder !== '.' && folder !== '..' && !/[\\/<>:"|?*\x00-\x1f]/.test(folder) && !/[. ]$/.test(folder);
  }

  static validateRules(rules: DownloadRule[]): DownloadRule[] {
    const used = new Set<string>();
    const ids = new Set<string>();
    return rules.map((rule: DownloadRule): DownloadRule => {
      if (!SettingsPolicy.folderIsValid(rule.folder) || rule.folder === '云剪') {
        throw new Error('Enter a valid folder name');
      }
      if (!rule.id || ids.has(rule.id)) throw new Error('Invalid classification rule');
      ids.add(rule.id);
      if (!Array.isArray(rule.extensions) || rule.extensions.length === 0) throw new Error('Enter at least one extension');
      const extensions = rule.extensions.map((raw: string): string => {
        const extension = raw.trim().replace(/^\./, '').toLowerCase();
        if (!/^[a-z0-9][a-z0-9_-]{0,31}$/.test(extension)) throw new Error('Enter a valid extension');
        if (used.has(extension)) throw new Error('An extension appears in more than one rule');
        used.add(extension);
        return extension;
      });
      return { id: rule.id, folder: rule.folder, extensions: extensions };
    });
  }

  static folderFor(name: string, rules: DownloadRule[]): string {
    const dot = name.lastIndexOf('.');
    const extension = dot >= 0 ? name.slice(dot + 1).toLowerCase() : '';
    return rules.find((rule: DownloadRule): boolean => rule.extensions.includes(extension))?.folder || 'Other';
  }
}
