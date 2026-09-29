import { SyncOperationQueue } from './SyncOperationQueue';
import { HttpClient, BinaryResponse, StreamedBinaryResponse, DownloadCancellation } from './HttpClient';
import { ProfileDto, HistoryRecordDto, HistoryStarredUpdate, HistoryQueryParams, ClipboardContent, MultipartField } from '../types/ApiTypes';
import { HashUtil } from '../utils/HashUtil';

/**
 * SyncClipboard API Service
 * Provides methods to interact with SyncClipboard server
 */
export class SyncClipboardService {
  private httpClient: HttpClient;

  constructor(baseUrl: string, username?: string, password?: string) {
    this.httpClient = new HttpClient(baseUrl, username, password);
  }

  /**
   * Update HTTP client config
   */
  updateConfig(baseUrl: string, username?: string, password?: string): void {
    this.httpClient.setBaseUrl(baseUrl);
    if (username && password) {
      this.httpClient.setCredentials(username, password);
    }
  }

  /**
   * Get current clipboard profile from /SyncClipboard.json
   */
  async getServerTime(): Promise<string> {
    return await this.httpClient.get<string>('/api/time');
  }

  async getProfile(): Promise<ProfileDto> {
    return await this.httpClient.get<ProfileDto>('/SyncClipboard.json');
  }

  /**
   * Upload clipboard profile to /SyncClipboard.json
   */
  async putProfile(profile: ProfileDto): Promise<void> {
    await this.httpClient.put('/SyncClipboard.json', profile);
  }

  /**
   * Query history records
   */
  async queryHistory(params?: HistoryQueryParams): Promise<HistoryRecordDto[]> {
    const fields = this.buildFormFields(params);
    return await this.httpClient.postMultipart<HistoryRecordDto[]>('/api/history/query', fields);
  }

  async queryHistoryPage(page: number): Promise<HistoryRecordDto[]> {
    return await this.queryHistory({ page, sortByLastAccessed: true });
  }

  async queryHistoryPages(limit: number): Promise<HistoryRecordDto[]> {
    const merged: HistoryRecordDto[] = [];
    const seen = new Set<string>();
    let page = 1;

    while (merged.length < limit) {
      const pageRecords = await this.queryHistoryPage(page);
      if (pageRecords.length === 0) {
        break;
      }

      let added = 0;
      for (const record of pageRecords) {
        const key = `${record.type}-${record.hash}`;
        if (!seen.has(key)) {
          seen.add(key);
          merged.push(record);
          added += 1;
        }
        if (merged.length >= limit) {
          break;
        }
      }

      if (added === 0) {
        break;
      }
      page += 1;
    }

    return merged.slice(0, limit);
  }

  /**
   * Get single history record
   */
  async getHistoryRecord(profileId: string): Promise<HistoryRecordDto> {
    return await this.httpClient.get<HistoryRecordDto>(`/api/history/${profileId}`);
  }

  async setHistoryStarred(record: HistoryRecordDto, starred: boolean): Promise<HistoryRecordDto> {
    // Omit version/time so the server atomically advances its current revision.
    // PATCH only this field: pinned/deletion/access time remain server-owned.
    const update: HistoryStarredUpdate = { starred };
    await this.httpClient.patch(`/api/history/${record.type}/${encodeURIComponent(record.hash)}`, update);
    const updated = await this.getHistoryRecord(`${record.type}-${record.hash}`);
    if (updated.isDeleted || !!updated.starred !== starred) {
      throw new Error('Favorite update was not confirmed by server');
    }
    return updated;
  }

  /**
   * Upload new history record
   */
  async uploadHistoryRecord(record: HistoryRecordDto): Promise<HistoryRecordDto> {
    const fields: MultipartField[] = [
      { key: 'hash', value: record.hash },
      { key: 'type', value: record.type }
    ];
    if (record.text) {
      fields.push({ key: 'text', value: record.text });
    }
    if (record.createTime) {
      fields.push({ key: 'createTime', value: record.createTime });
    }
    if (record.lastModified) {
      fields.push({ key: 'lastModified', value: record.lastModified });
    }
    if (record.lastAccessed) {
      fields.push({ key: 'lastAccessed', value: record.lastAccessed });
    }
    if (record.starred !== undefined) {
      fields.push({ key: 'starred', value: record.starred.toString() });
    }
    if (record.pinned !== undefined) {
      fields.push({ key: 'pinned', value: record.pinned.toString() });
    }
    if (record.size !== undefined) {
      fields.push({ key: 'size', value: record.size.toString() });
    }
    if (record.hasData !== undefined) {
      fields.push({ key: 'hasData', value: record.hasData.toString() });
    }
    if (record.version !== undefined) {
      fields.push({ key: 'version', value: record.version.toString() });
    }
    if (record.isDeleted !== undefined) {
      fields.push({ key: 'isDeleted', value: record.isDeleted.toString() });
    }
    await this.httpClient.postMultipart<object>('/api/history', fields);
    return await this.getHistoryRecord(`${record.type}-${record.hash}`);
  }

  /**
   * Convert ClipboardContent to ProfileDto
   */
  async contentToProfile(content: ClipboardContent): Promise<ProfileDto> {
    let hash = content.profileHash;
    if (!hash && content.text) {
      hash = await HashUtil.calculateTextHash(content.text);
    }

    return {
      type: content.type,
      text: content.text || '',
      hash: hash,
      hasData: content.hasData || false,
      dataName: content.fileName,
      size: content.fileSize || content.text?.length || 0
    };
  }

  /**
   * Upload text clipboard content (text-focused)
   */
  async uploadTextContent(text: string): Promise<void> {
    await SyncOperationQueue.run((): Promise<void> => this.uploadTextContentExclusive(text));
  }

  // The coordinator already owns SyncOperationQueue when using this entry point.
  async uploadTextContentExclusive(text: string, beforeCommit?: () => Promise<void>): Promise<void> {
    const hash = await HashUtil.calculateTextHash(text);
    
    const profile: ProfileDto = {
      type: 'Text',
      text: text,
      hash: hash,
      hasData: false,
      size: text.length
    };

    // Check if history record exists
    const profileId = `Text-${hash}`;
    try {
      await this.getHistoryRecord(profileId);
      console.info('[SyncClipboardService] History record already exists');
    } catch (error) {
      if (!(error instanceof Error) || !error.message.includes('HTTP 404')) {
        throw error instanceof Error ? error : new Error(String(error));
      }
      const record: HistoryRecordDto = {
        hash: hash,
        type: 'Text',
        text: text,
        hasData: false,
        size: text.length,
        createTime: new Date().toISOString(),
        lastModified: new Date().toISOString(),
        lastAccessed: new Date().toISOString(),
        starred: false,
        pinned: false,
        version: 0,
        isDeleted: false
      };
      
      await this.uploadHistoryRecord(record);
    }

    // Recheck both ends after preparing history and immediately before committing.
    if (beforeCommit) await beforeCommit();
    await this.putProfile(profile);
    const confirmed = await this.getProfile();
    if (confirmed.type !== 'Text' || confirmed.hash !== hash) {
      throw new Error('Server clipboard changed before upload could be confirmed');
    }
  }

  /**
   * Download text clipboard content
   */
  async downloadTextContent(): Promise<string> {
    const profile = await this.getProfile();
    return await this.downloadTextFromProfile(profile);
  }

  async probe(): Promise<void> {
    this.httpClient.setTimeout(5000);
    await this.queryHistoryPage(1);
  }

  async downloadTextFromProfile(profile: ProfileDto): Promise<string> {
    if (profile.type === 'Text') {
      if (profile.hasData && profile.hash) {
        return await this.downloadHistoryText(`Text-${profile.hash}`);
      }
      return profile.text;
    }
    return '';
  }

  async downloadProfileBinary(profile: ProfileDto): Promise<ArrayBuffer> {
    return (await this.downloadProfileFile(profile)).buffer;
  }

  async downloadProfileFile(profile: ProfileDto): Promise<BinaryResponse> {
    if (!profile.hasData || !profile.dataName) {
      throw new Error('Clipboard file data is unavailable');
    }
    return await this.httpClient.getBinary(`/file/${encodeURIComponent(profile.dataName)}`);
  }

  async downloadHistoryText(profileId: string): Promise<string> {
    return await this.httpClient.getText(`/api/history/${profileId}/data`);
  }

  async downloadHistoryBinary(profileId: string): Promise<ArrayBuffer> {
    return await this.httpClient.getArrayBuffer(`/api/history/${profileId}/data`);
  }

  async downloadHistoryFile(profileId: string): Promise<BinaryResponse> {
    return await this.httpClient.getBinary(`/api/history/${profileId}/data`);
  }

  async downloadHistoryFileToPath(profileId: string, targetPath: string,
    onProgress?: (received: number, total: number) => void,
    cancellation?: DownloadCancellation): Promise<StreamedBinaryResponse> {
    return await this.httpClient.getBinaryToFile(`/api/history/${profileId}/data`, targetPath, onProgress, cancellation);
  }

  /**
   * Build query string from params
   */
  private buildFormFields(params?: HistoryQueryParams): MultipartField[] {
    const fields: MultipartField[] = [];
    if (!params) {
      return fields;
    }
    if (params.page !== undefined) {
      fields.push({ key: 'page', value: params.page.toString() });
    }
    if (params.sortByLastAccessed !== undefined) {
      fields.push({ key: 'sortByLastAccessed', value: params.sortByLastAccessed.toString() });
    }
    if (params.before) {
      fields.push({ key: 'before', value: params.before });
    }
    if (params.after) {
      fields.push({ key: 'after', value: params.after });
    }
    if (params.modifiedAfter) {
      fields.push({ key: 'modifiedAfter', value: params.modifiedAfter });
    }
    if (params.types !== undefined) {
      fields.push({ key: 'types', value: params.types.toString() });
    }
    if (params.searchText) {
      fields.push({ key: 'searchText', value: params.searchText });
    }
    if (params.starred !== undefined) {
      fields.push({ key: 'starred', value: params.starred.toString() });
    }
    return fields;
  }
}
