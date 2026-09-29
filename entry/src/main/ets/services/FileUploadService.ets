import { SyncOperationQueue } from './SyncOperationQueue';
import { fileIo as fs } from '@kit.CoreFileKit';
import cryptoFramework from '@ohos.security.cryptoFramework';
import zlib from '@ohos.zlib';
import { rcp } from '@kit.RemoteCommunicationKit';
import { ServerAccount, ProfileDto, HistoryRecordDto, ClipboardContentType } from '../types/ApiTypes';
import { HashUtil } from '../utils/HashUtil';
import { HttpClient } from './HttpClient';
import { SyncClipboardService } from './SyncClipboardService';

export interface UploadFile {
  uri: string;
  name?: string;
  image?: boolean;
}

export type UploadProgress = (phase: string, transferred: number, total: number) => void;

interface PreparedFile {
  path: string;
  name: string;
  size: number;
  contentHash: string;
  image: boolean;
}

/** Uploads one clipboard entry to one pinned account. */
export class FileUploadTask {
  private canceled: boolean = false;
  private session: rcp.Session | null = null;

  cancel(): void {
    this.canceled = true;
    this.session?.cancel();
  }

  private checkCanceled(): void {
    if (this.canceled) throw new Error('Upload canceled');
  }

  private cleanName(value: string, fallback: string): string {
    const name = value.replace(/[\\/:*?"<>|\x00-\x1F]/g, '_').trim();
    return name && name !== '.' && name !== '..' ? name.slice(0, 180) : fallback;
  }

  private nameFromUri(uri: string, index: number): string {
    try {
      return this.cleanName(decodeURIComponent(uri.split('?')[0].split('/').pop() || ''), `file-${index + 1}`);
    } catch (error) {
      return `file-${index + 1}`;
    }
  }

  private imageExtension(bytes: Uint8Array): string {
    if (bytes.length >= 3 && bytes[0] === 0xFF && bytes[1] === 0xD8 && bytes[2] === 0xFF) return '.jpg';
    if (bytes.length >= 8 && bytes[0] === 0x89 && bytes[1] === 0x50 && bytes[2] === 0x4E) return '.png';
    if (bytes.length >= 6 && bytes[0] === 0x47 && bytes[1] === 0x49 && bytes[2] === 0x46) return '.gif';
    if (bytes.length >= 12 && bytes[0] === 0x52 && bytes[1] === 0x49 && bytes[2] === 0x46 &&
      bytes[8] === 0x57 && bytes[9] === 0x45) return '.webp';
    if (bytes.length >= 12 && bytes[4] === 0x66 && bytes[5] === 0x74 && bytes[6] === 0x79 &&
      bytes[7] === 0x70) return '.heic';
    return '';
  }

  private hex(bytes: Uint8Array): string {
    return Array.from(bytes).map((value: number): string => value.toString(16).padStart(2, '0')).join('').toUpperCase();
  }

  private async stage(file: UploadFile, index: number, directory: string,
    used: Set<string>, onProgress: UploadProgress): Promise<PreparedFile> {
    let name = this.cleanName(file.name || this.nameFromUri(file.uri, index), `file-${index + 1}`);
    let detectedImage = false;
    if (file.image && !/\.(png|jpe?g|gif|webp|heic|heif|bmp)$/i.test(name)) {
      const input = await fs.open(file.uri, fs.OpenMode.READ_ONLY);
      try {
        const prefix = new ArrayBuffer(16);
        const count = await fs.read(input.fd, prefix);
        const extension = this.imageExtension(new Uint8Array(prefix.slice(0, count)));
        if (extension) {
          name += extension;
          detectedImage = true;
        }
      } finally {
        await fs.close(input);
      }
    }
    const dot = name.lastIndexOf('.');
    const stem = dot > 0 ? name.slice(0, dot) : name;
    const ext = dot > 0 ? name.slice(dot) : '';
    let suffix = 2;
    while (used.has(name.toLowerCase())) name = `${stem} (${suffix++})${ext}`;
    used.add(name.toLowerCase());
    const path = `${directory}/${name}`;
    const source = await fs.open(file.uri, fs.OpenMode.READ_ONLY);
    let output: fs.File | null = null;
    try {
      output = await fs.open(path, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY);
      const md = cryptoFramework.createMd('SHA256');
      const buffer = new ArrayBuffer(256 * 1024);
      let size = 0;
      while (true) {
        this.checkCanceled();
        const count = await fs.read(source.fd, buffer);
        if (count <= 0) break;
        const chunk = buffer.slice(0, count);
        await md.update({ data: new Uint8Array(chunk) });
        let written = 0;
        while (written < count) {
          const countWritten = await fs.write(output.fd, chunk.slice(written));
          if (countWritten <= 0) throw new Error('Failed writing upload cache');
          written += countWritten;
        }
        size += count;
        onProgress('Preparing...', size, 0);
      }
      const digest = await md.digest();
      return { path: path, name: name, size: size,
        contentHash: this.hex(new Uint8Array(digest.data)),
        image: detectedImage || /\.(png|jpe?g|gif|webp|heic|heif|bmp)$/i.test(name) };
    } finally {
      if (output) await fs.close(output);
      await fs.close(source);
    }
  }

  private async uploadBinary(server: ServerAccount, path: string, dataName: string,
    onProgress: UploadProgress): Promise<void> {
    const http = new HttpClient(server.url, server.username, server.password);
    const headers: Record<string, string> = { 'Content-Type': 'application/octet-stream' };
    const authorization = http.authorizationHeader();
    if (authorization) headers.Authorization = authorization;
    this.session = rcp.createSession({
      requestConfiguration: { tracing: { httpEventsHandler: {
        onUploadProgress: (total: number, sent: number): void => onProgress('Uploading...', sent, total)
      } } }
    });
    try {
      const request = new rcp.Request(
        `${server.url.replace(/\/$/, '')}/file/${encodeURIComponent(dataName)}`,
        'PUT', headers, new rcp.UploadFromFile(path));
      const response = await this.session.fetch(request);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw new Error(`HTTP ${response.statusCode}`);
      }
    } finally {
      this.session.close();
      this.session = null;
    }
  }

  async upload(files: UploadFile[], server: ServerAccount, context: Context,
    onProgress: UploadProgress): Promise<HistoryRecordDto> {
    return await SyncOperationQueue.run((): Promise<HistoryRecordDto> =>
      this.uploadExclusive(files, server, context, onProgress));
  }

  // Caller must own SyncOperationQueue for the whole arbitration and transfer.
  async uploadExclusive(files: UploadFile[], server: ServerAccount, context: Context,
    onProgress: UploadProgress, beforeCommit?: () => Promise<void>): Promise<HistoryRecordDto> {
    if (files.length === 0) throw new Error('No files selected');
    if (files.length > 100) throw new Error('Too many files');
    const root = `${context.cacheDir}/upload-${Date.now()}-${Math.random().toString(36).slice(2)}`;
    const directory = `${root}/files`;
    let archive = '';
    try {
      await fs.mkdir(root);
      await fs.mkdir(directory);
      const used = new Set<string>();
      const prepared: PreparedFile[] = [];
      for (let i = 0; i < files.length; i++) {
        prepared.push(await this.stage(files[i], i, directory, used, onProgress));
      }
      this.checkCanceled();
      const group = prepared.length > 1;
      const type: ClipboardContentType = group ? 'Group' : prepared[0].image ? 'Image' : 'File';
      const size = prepared.reduce((sum: number, item: PreparedFile): number => sum + item.size, 0);
      const text = prepared.map((item: PreparedFile): string => item.name).join('\n');
      let hash = '';
      let uploadPath = prepared[0].path;
      let dataName = this.cleanName(prepared[0].name, 'file');
      if (group) {
        const entries = prepared.slice().sort((a: PreparedFile, b: PreparedFile): number => {
          const left = HashUtil.utf8Bytes(a.name);
          const right = HashUtil.utf8Bytes(b.name);
          for (let i = 0; i < Math.min(left.length, right.length); i++) {
            if (left[i] !== right[i]) return left[i] - right[i];
          }
          return left.length - right.length;
        });
        const input = entries.map((item: PreparedFile): string =>
          `F|${item.name}|${item.size}|${item.contentHash}\0`).join('');
        hash = await HashUtil.calculateTextHash(input);
        archive = `${root}/group.pcj.zip`;
        onProgress('Preparing...', 0, size);
        await zlib.compressFiles(prepared.map((item: PreparedFile): string => item.path), archive, {});
        uploadPath = archive;
        dataName = `Group-${Date.now()}-${Math.random().toString(36).slice(2)}.pcj.zip`;
      } else {
        hash = await HashUtil.calculateTextHash(`${prepared[0].name}|${prepared[0].contentHash}`);
        // The server recomputes File/Image hashes from the uploaded file's
        // name, so DataName must match the name used above for the hash.
        dataName = prepared[0].name;
      }
      this.checkCanceled();
      await this.uploadBinary(server, uploadPath, dataName, onProgress);
      this.checkCanceled();
      const profile: ProfileDto = { type: type, hash: hash, text: text,
        hasData: true, dataName: dataName, size: size };
      const syncService = new SyncClipboardService(server.url, server.username, server.password);
      if (beforeCommit) await beforeCommit();
      this.checkCanceled();
      await syncService.putProfile(profile);
      const savedProfile = await syncService.getProfile();
      if (savedProfile.type !== type || savedProfile.hash !== hash) {
        throw new Error('Server clipboard changed before upload could be confirmed');
      }
      const record = await syncService.getHistoryRecord(`${type}-${hash}`);
      if (record.type !== type || record.hash !== hash || !record.hasData || record.isDeleted) {
        throw new Error('Uploaded file is missing from server history');
      }
      onProgress('Upload Success', size, size);
      return record;
    } finally {
      for (const name of await fs.listFile(directory).catch((): string[] => [])) {
        await fs.unlink(`${directory}/${name}`).catch((): void => {});
      }
      if (archive) await fs.unlink(archive).catch((): void => {});
      await fs.rmdir(directory).catch((): void => {});
      await fs.rmdir(root).catch((): void => {});
    }
  }
}
