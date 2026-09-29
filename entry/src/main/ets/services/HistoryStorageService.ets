import { RecordCacheService } from './RecordCacheService';
import relationalStore from '@ohos.data.relationalStore';
import { HistoryRecordDto } from '../types/ApiTypes';
import { ConfigService } from './ConfigService';

interface LegacyText {
  serverId: string;
  profileHash: string;
  text: string;
  lastAccessed: string;
  hasData: boolean;
}

/**
 * History Storage Service
 * Manages local history records using RDB
 */
export class HistoryStorageService {
  private static instance: HistoryStorageService;
  private store: relationalStore.RdbStore | null = null;
  private initPromise: Promise<void> | null = null;
  private initError: Error | null = null;
  private recordWriteQueue: Promise<void> = Promise.resolve();
  private readonly DB_NAME = 'SyncClipboardHistory.db';
  private readonly TABLE_NAME = 'history_by_server';

  private constructor() {}

  private getAbilityContext(fallback?: Context): Context {
    const context = AppStorage.get<Context>('abilityContext') || fallback;
    if (!context) {
      throw new Error('Ability context is not initialized');
    }
    return context as Context;
  }

  static getInstance(): HistoryStorageService {
    if (!HistoryStorageService.instance) {
      HistoryStorageService.instance = new HistoryStorageService();
    }
    return HistoryStorageService.instance;
  }

  /**
   * Initialize database
   */
  async init(context?: Context): Promise<void> {
    RecordCacheService.getInstance().initialize(context);
    const config: relationalStore.StoreConfig = {
      name: this.DB_NAME,
      securityLevel: relationalStore.SecurityLevel.S1
    };

    try {
      this.initError = null;
      this.store = await relationalStore.getRdbStore(this.getAbilityContext(context), config);

      const createTableSql = `
        CREATE TABLE IF NOT EXISTS ${this.TABLE_NAME} (
          serverId TEXT NOT NULL,
          profileHash TEXT NOT NULL,
          type TEXT NOT NULL,
          text TEXT,
          createTime TEXT,
          lastModified TEXT,
          lastAccessed TEXT,
          starred INTEGER DEFAULT 0,
          pinned INTEGER DEFAULT 0,
          size INTEGER DEFAULT 0,
          hasData INTEGER DEFAULT 0,
          version INTEGER DEFAULT 0,
          isDeleted INTEGER DEFAULT 0,
          textComplete INTEGER DEFAULT 0,
          PRIMARY KEY (serverId, profileHash)
        )
      `;

      await this.store.executeSql(createTableSql);
      const columns = await this.store.querySql(`PRAGMA table_info(${this.TABLE_NAME})`);
      let hasTextComplete = false;
      try {
        while (columns.goToNextRow()) {
          if (columns.getString(columns.getColumnIndex('name')) === 'textComplete') hasTextComplete = true;
        }
      } finally { columns.close(); }
      if (!hasTextComplete) {
        await this.store.executeSql(`ALTER TABLE ${this.TABLE_NAME} ADD COLUMN textComplete INTEGER DEFAULT 1`);
      }
      // The original database used one global history table. Assign its rows to
      // the migrated account before removing it; this is safe to retry on startup.
      const legacy = await this.store.querySql(
        "SELECT name FROM sqlite_master WHERE type='table' AND name='history'");
      const hasLegacy = legacy.rowCount > 0;
      legacy.close();
      if (hasLegacy) {
        await this.store.executeSql(`INSERT OR IGNORE INTO ${this.TABLE_NAME}
          (serverId, profileHash, type, text, createTime, lastModified, lastAccessed,
           starred, pinned, size, hasData, version, isDeleted, textComplete)
          SELECT 'original', profileHash, type, text, createTime, lastModified,
            lastAccessed, starred, pinned, size, hasData, version, isDeleted, 1 FROM history`);
        await this.store.executeSql('DROP TABLE history');
      }
      for (const account of ConfigService.getInstance().getConfig().servers) {
        await this.pruneStore(this.store, account.id);
      }
      // Move legacy inline bodies into the bounded payload pool before truncating them.
      const legacyText = await this.store.querySql(`SELECT serverId, profileHash, text, lastAccessed,
        hasData FROM ${this.TABLE_NAME} WHERE type='Text' AND textComplete=1`);
      const texts: LegacyText[] = [];
      try {
        while (legacyText.goToNextRow()) texts.push({
          serverId: legacyText.getString(legacyText.getColumnIndex('serverId')),
          profileHash: legacyText.getString(legacyText.getColumnIndex('profileHash')),
          text: legacyText.getString(legacyText.getColumnIndex('text')),
          lastAccessed: legacyText.getString(legacyText.getColumnIndex('lastAccessed')),
          hasData: legacyText.getLong(legacyText.getColumnIndex('hasData')) === 1
        });
      } finally { legacyText.close(); }
      for (const item of texts) {
        const record: HistoryRecordDto = { type: 'Text', hash: item.profileHash.slice(5),
          text: item.text, lastAccessed: item.lastAccessed, hasData: item.hasData };
        RecordCacheService.getInstance().allowRecord(item.serverId, record);
        await RecordCacheService.getInstance().storeInline(record, item.serverId, context);
        const predicates = new relationalStore.RdbPredicates(this.TABLE_NAME);
        predicates.equalTo('serverId', item.serverId).equalTo('profileHash', item.profileHash);
        await this.store.update({ text: item.text.slice(0, 1024), textComplete: 0 }, predicates);
      }
      console.info('[HistoryStorage] Database initialized');
    } catch (error) {
      console.error('[HistoryStorage] init error:', JSON.stringify(error));
      this.store = null;
      throw error instanceof Error ? error : new Error(String(error));
    }
  }

  private async ensureStore(context?: Context): Promise<relationalStore.RdbStore> {
    if (this.initPromise) await this.initPromise;
    if (this.initError) {
      throw this.initError;
    }
    if (!this.store) {
      if (!this.initPromise) {
        this.initPromise = this.init(context)
          .then(() => {
            this.initError = null;
          })
          .catch((error: Error | Object | string) => {
            this.initError = error instanceof Error ? error : new Error(String(error));
            throw this.initError;
          })
          .finally(() => {
            this.initPromise = null;
          });
      }
      await this.initPromise;
    }
    if (!this.store) {
      throw this.initError || new Error('History database is unavailable');
    }
    return this.store;
  }

  /**
   * Insert or update history record
   */
  async upsertRecord(record: HistoryRecordDto,
    serverId: string = ConfigService.getInstance().getConfig().activeServerId,
    context?: Context): Promise<void> {
    const write = this.recordWriteQueue.then((): Promise<void> => this.writeRecord(record, serverId, context));
    this.recordWriteQueue = write.catch((): void => {});
    await write;
  }

  private async writeRecord(record: HistoryRecordDto, serverId: string, context?: Context): Promise<void> {
    if (!ConfigService.getInstance().getConfig().servers.some((account) => account.id === serverId)) return;
    try {
      const store = await this.ensureStore(context);
      const profileHash = `${record.type}-${record.hash}`;
      // A history response started before a favorite change must not undo that change.
      if (record.version !== undefined && record.lastModified) {
        const predicates = new relationalStore.RdbPredicates(this.TABLE_NAME);
        predicates.equalTo('serverId', serverId);
        predicates.equalTo('profileHash', profileHash);
        const existing = await store.query(predicates, ['version', 'lastModified']);
        try {
          if (existing.goToFirstRow()) {
            const version = existing.getLong(existing.getColumnIndex('version'));
            const modified = Date.parse(existing.getString(existing.getColumnIndex('lastModified')));
            const incomingModified = Date.parse(record.lastModified);
            if (version >= record.version && modified >= incomingModified &&
              (version > record.version || modified > incomingModified)) return;
          }
        } finally {
          existing.close();
        }
      }
      const valueBucket: relationalStore.ValuesBucket = {
        serverId: serverId,
        profileHash: profileHash,
        type: record.type,
        text: record.type === 'Text' ? (record.text || '').slice(0, 1024) : record.text || '',
        textComplete: record.type === 'Text' ? 0 : 1,
        createTime: record.createTime || new Date().toISOString(),
        lastModified: record.lastModified || new Date().toISOString(),
        lastAccessed: record.lastAccessed || new Date().toISOString(),
        starred: record.starred ? 1 : 0,
        pinned: record.pinned ? 1 : 0,
        size: record.size || 0,
        hasData: record.hasData ? 1 : 0,
        version: record.version || 0,
        isDeleted: record.isDeleted ? 1 : 0
      };

      await store.insert(this.TABLE_NAME, valueBucket, 
        relationalStore.ConflictResolution.ON_CONFLICT_REPLACE);
      const retained = await this.pruneStore(store, serverId);
      if (!retained.includes(profileHash)) return;
      AppStorage.setOrCreate('historyCountRevision', (AppStorage.get<number>('historyCountRevision') || 0) + 1);
      RecordCacheService.getInstance().allowRecord(serverId, record);
      await RecordCacheService.getInstance().storeInline(record, serverId, context);
    } catch (error) {
      console.error('[HistoryStorage] upsertRecord error:', JSON.stringify(error));
      throw error instanceof Error ? error : new Error(String(error));
    }
  }

  /**
   * Query history records
   */
  async queryRecords(limit: number = 50, offset: number = 0,
    serverId: string = ConfigService.getInstance().getConfig().activeServerId): Promise<HistoryRecordDto[]> {
    try {
      const store = await this.ensureStore();
      const maximum = ConfigService.getInstance().getConfig().maxHistorySize || 100;
      if (offset >= maximum) return [];
      limit = Math.min(limit, maximum - offset);
      const predicates = new relationalStore.RdbPredicates(this.TABLE_NAME);
      predicates.equalTo('serverId', serverId);
      predicates.equalTo('isDeleted', 0);
      predicates.orderByDesc('lastAccessed');
      predicates.limitAs(limit);
      if (offset > 0) {
        predicates.offsetAs(offset);
      }

      const resultSet = await store.query(predicates);
      const records: HistoryRecordDto[] = [];

      try {
        while (resultSet.goToNextRow()) {
          const profileHash = resultSet.getString(resultSet.getColumnIndex('profileHash'));
          const hashParts = profileHash.split('-');
          const hash = hashParts.slice(1).join('-');

          records.push({
            hash: hash,
            type: resultSet.getString(resultSet.getColumnIndex('type')) as 'Text' | 'Image' | 'File' | 'Group',
            text: resultSet.getString(resultSet.getColumnIndex('text')),
            createTime: resultSet.getString(resultSet.getColumnIndex('createTime')),
            lastModified: resultSet.getString(resultSet.getColumnIndex('lastModified')),
            lastAccessed: resultSet.getString(resultSet.getColumnIndex('lastAccessed')),
            starred: resultSet.getLong(resultSet.getColumnIndex('starred')) === 1,
            pinned: resultSet.getLong(resultSet.getColumnIndex('pinned')) === 1,
            size: resultSet.getLong(resultSet.getColumnIndex('size')),
            hasData: resultSet.getLong(resultSet.getColumnIndex('hasData')) === 1,
            version: resultSet.getLong(resultSet.getColumnIndex('version')),
            isDeleted: resultSet.getLong(resultSet.getColumnIndex('isDeleted')) === 1,
            textComplete: resultSet.getLong(resultSet.getColumnIndex('textComplete')) === 1
          });
        }
      } finally {
        resultSet.close();
      }
      return records;
    } catch (error) {
      console.error('[HistoryStorage] queryRecords error:', JSON.stringify(error));
      return [];
    }
  }

  /**
   * Delete record
   */
  async deleteRecord(profileHash: string,
    serverId: string = ConfigService.getInstance().getConfig().activeServerId): Promise<void> {
    try {
      const store = await this.ensureStore();
      const predicates = new relationalStore.RdbPredicates(this.TABLE_NAME);
      predicates.equalTo('serverId', serverId);
      predicates.equalTo('profileHash', profileHash);
      await store.delete(predicates);
      RecordCacheService.getInstance().removeRecords(serverId, [profileHash]);
      AppStorage.setOrCreate('historyCountRevision', (AppStorage.get<number>('historyCountRevision') || 0) + 1);
    } catch (error) {
      console.error('[HistoryStorage] deleteRecord error:', JSON.stringify(error));
      throw error instanceof Error ? error : new Error(String(error));
    }
  }

  /**
   * Clear all records
   */
  async clearAll(serverId: string = ConfigService.getInstance().getConfig().activeServerId): Promise<void> {
    const operation = this.recordWriteQueue.then(async (): Promise<void> => {
      try {
        const store = await this.ensureStore();
        const predicates = new relationalStore.RdbPredicates(this.TABLE_NAME);
        predicates.equalTo('serverId', serverId);
        await store.delete(predicates);
        RecordCacheService.getInstance().removeAccount(serverId);
        AppStorage.setOrCreate('historyCountRevision', (AppStorage.get<number>('historyCountRevision') || 0) + 1);
      } catch (error) {
        console.error('[HistoryStorage] clearAll error:', JSON.stringify(error));
        throw error instanceof Error ? error : new Error(String(error));
      }
    });
    this.recordWriteQueue = operation.catch((): void => {});
    await operation;
  }

  private async pruneStore(store: relationalStore.RdbStore, serverId: string): Promise<string[]> {
    const predicates = new relationalStore.RdbPredicates(this.TABLE_NAME);
    predicates.equalTo('serverId', serverId).orderByDesc('lastAccessed').orderByDesc('profileHash');
    const rows = await store.query(predicates, ['profileHash', 'isDeleted']);
    const retained: string[] = [];
    const removed: string[] = [];
    const maximum = ConfigService.getInstance().getConfig().maxHistorySize || 100;
    try {
      while (rows.goToNextRow()) {
        const key = rows.getString(rows.getColumnIndex('profileHash'));
        if (rows.getLong(rows.getColumnIndex('isDeleted')) === 1 || retained.length >= maximum) removed.push(key);
        else retained.push(key);
      }
    } finally { rows.close(); }
    for (const key of removed) {
      const removal = new relationalStore.RdbPredicates(this.TABLE_NAME);
      removal.equalTo('serverId', serverId).equalTo('profileHash', key);
      await store.delete(removal);
    }
    if (removed.length) RecordCacheService.getInstance().removeRecords(serverId, removed);
    RecordCacheService.getInstance().retainRecords(serverId, retained);
    return retained;
  }

  async countRecords(serverId: string): Promise<number> {
    if (!serverId) return 0;
    await this.recordWriteQueue;
    const store = await this.ensureStore();
    const predicates = new relationalStore.RdbPredicates(this.TABLE_NAME);
    predicates.equalTo('serverId', serverId).equalTo('isDeleted', 0);
    const rows = await store.query(predicates, ['profileHash']);
    try { return rows.rowCount; } finally { rows.close(); }
  }

  async applyLimits(): Promise<void> {
    const operation = this.recordWriteQueue.then(async (): Promise<void> => {
      const store = await this.ensureStore();
      for (const account of ConfigService.getInstance().getConfig().servers) await this.pruneStore(store, account.id);
      RecordCacheService.getInstance().enforceLimits();
      AppStorage.setOrCreate('historyMetadataRevision', (AppStorage.get<number>('historyMetadataRevision') || 0) + 1);
    });
    this.recordWriteQueue = operation.catch((): void => {});
    await operation;
  }

}
