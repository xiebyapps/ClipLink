import relationalStore from '@ohos.data.relationalStore';
import { HistoryRecordDto } from '../types/ApiTypes';

/**
 * History Storage Service
 * Manages local history records using RDB
 */
export class HistoryStorageService {
  private static instance: HistoryStorageService;
  private store: relationalStore.RdbStore | null = null;
  private initPromise: Promise<void> | null = null;
  private initError: Error | null = null;
  private readonly DB_NAME = 'SyncClipboardHistory.db';
  private readonly TABLE_NAME = 'history';

  private constructor() {}

  private getAbilityContext(): Context {
    const context = AppStorage.get<Context>('abilityContext');
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
  async init(): Promise<void> {
    const config: relationalStore.StoreConfig = {
      name: this.DB_NAME,
      securityLevel: relationalStore.SecurityLevel.S1
    };

    try {
      this.initError = null;
      this.store = await relationalStore.getRdbStore(this.getAbilityContext(), config);

      const createTableSql = `
        CREATE TABLE IF NOT EXISTS ${this.TABLE_NAME} (
          profileHash TEXT PRIMARY KEY,
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
          isDeleted INTEGER DEFAULT 0
        )
      `;

      await this.store.executeSql(createTableSql);
      console.info('[HistoryStorage] Database initialized');
    } catch (error) {
      console.error('[HistoryStorage] init error:', JSON.stringify(error));
      this.store = null;
      throw error instanceof Error ? error : new Error(String(error));
    }
  }

  private async ensureStore(): Promise<relationalStore.RdbStore> {
    if (this.initError) {
      throw this.initError;
    }
    if (!this.store) {
      if (!this.initPromise) {
        this.initPromise = this.init()
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
  async upsertRecord(record: HistoryRecordDto): Promise<void> {
    try {
      const store = await this.ensureStore();
      const profileHash = `${record.type}-${record.hash}`;
      const valueBucket: relationalStore.ValuesBucket = {
        profileHash: profileHash,
        type: record.type,
        text: record.text || '',
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
    } catch (error) {
      console.error('[HistoryStorage] upsertRecord error:', JSON.stringify(error));
      throw error instanceof Error ? error : new Error(String(error));
    }
  }

  /**
   * Query history records
   */
  async queryRecords(limit: number = 50, offset: number = 0): Promise<HistoryRecordDto[]> {
    try {
      const store = await this.ensureStore();
      const predicates = new relationalStore.RdbPredicates(this.TABLE_NAME);
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
            isDeleted: resultSet.getLong(resultSet.getColumnIndex('isDeleted')) === 1
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
  async deleteRecord(profileHash: string): Promise<void> {
    try {
      const store = await this.ensureStore();
      const predicates = new relationalStore.RdbPredicates(this.TABLE_NAME);
      predicates.equalTo('profileHash', profileHash);
      await store.delete(predicates);
    } catch (error) {
      console.error('[HistoryStorage] deleteRecord error:', JSON.stringify(error));
      throw error instanceof Error ? error : new Error(String(error));
    }
  }

  /**
   * Clear all records
   */
  async clearAll(): Promise<void> {
    try {
      const store = await this.ensureStore();
      await store.executeSql(`DELETE FROM ${this.TABLE_NAME}`);
    } catch (error) {
      console.error('[HistoryStorage] clearAll error:', JSON.stringify(error));
      throw error instanceof Error ? error : new Error(String(error));
    }
  }
}
