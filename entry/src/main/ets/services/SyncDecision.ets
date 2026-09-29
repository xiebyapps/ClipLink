export type SyncDirection = 'none' | 'local' | 'remote' | 'pause';

export interface SyncComparison {
  equal: boolean;
  hasBaseline: boolean;
  localChanged: boolean;
  remoteChanged: boolean;
  localTime: number;
  remoteTime: number;
  uncertainty: number;
  clockStable: boolean;
}

/** Compare contents first; timestamps are required only when both sides compete. */
export class SyncDecision {
  static decide(value: SyncComparison): SyncDirection {
    if (value.equal) return 'none';
    if (value.hasBaseline) {
      if (!value.localChanged && !value.remoteChanged) return 'none';
      if (value.localChanged && !value.remoteChanged) return 'local';
      if (!value.localChanged && value.remoteChanged) return 'remote';
    }
    if (!value.clockStable || !Number.isFinite(value.localTime) || value.localTime <= 0 ||
      !Number.isFinite(value.remoteTime) || value.remoteTime <= 0 ||
      !Number.isFinite(value.uncertainty) || value.uncertainty < 0 ||
      Math.abs(value.localTime - value.remoteTime) <= value.uncertainty) return 'pause';
    return value.localTime > value.remoteTime ? 'local' : 'remote';
  }
}
