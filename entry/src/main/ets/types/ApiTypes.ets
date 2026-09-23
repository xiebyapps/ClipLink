export type ClipboardContentType = 'Text' | 'Image' | 'File' | 'Group';

export interface MultipartField {
  key: string;
  value: string;
}

/**
 * Profile DTO - matches SyncClipboard server format
 */
export interface ProfileDto {
  type: ClipboardContentType;
  hash?: string;
  text: string;
  hasData: boolean;
  dataName?: string;
  size?: number;
}

/**
 * History Record DTO - matches /api/history format
 */
export interface HistoryRecordDto {
  hash: string;
  type: 'Text' | 'Image' | 'File' | 'Group';
  text?: string;
  createTime?: string;
  lastModified?: string;
  lastAccessed?: string;
  starred?: boolean;
  pinned?: boolean;
  size?: number;
  hasData?: boolean;
  version?: number;
  isDeleted?: boolean;
}

/**
 * History Query Parameters
 */
export interface HistoryQueryParams {
  page?: number;
  before?: string;
  after?: string;
  modifiedAfter?: string;
  types?: number;
  searchText?: string;
  starred?: boolean;
}

/**
 * Clipboard Content - internal representation
 */
export interface ClipboardContent {
  type: ClipboardContentType;
  text?: string;
  profileHash?: string;
  timestamp?: number;
  hasData?: boolean;
  fileName?: string;
  fileSize?: number;
}

/**
 * Server Config
 */
export interface ServerConfig {
  type: 'syncclipboard' | 'webdav';
  url: string;
  username?: string;
  password?: string;
}

/**
 * App Config
 */
export interface AppConfig {
  server: ServerConfig;
  pollingInterval: number;
  theme: 'light' | 'dark' | 'auto';
  language: 'system' | 'zh-CN' | 'en-US';
  preferPureBlackInDark: boolean;
  maxHistorySize: number;
}
