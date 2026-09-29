import { DownloadOrganizationService } from '../services/DownloadOrganizationService';
import { fileIo as fs, fileUri, picker } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { ClipboardContentType } from '../types/ApiTypes';
import { BinaryResponse, StreamedBinaryResponse } from '../services/HttpClient';
import { ImageUtil } from './ImageUtil';

export type SaveCategory = 'Image' | 'Sounds' | 'Documents' | 'Other';

export interface SavedFile {
  uri: string;
  category: SaveCategory;
  fileName: string;
  location?: string;
}

interface UniqueTarget {
  path: string;
  name: string;
}

type DownloadedBinary = BinaryResponse | StreamedBinaryResponse;

/** Saves downloaded data to Gallery or the user-visible Download directory. */
export class UserFileSaveUtil {
  private static readonly appDirectory = '云剪';
  private static gallerySequence: number = 0;
  private static readonly audioExtensions = new Set<string>([
    'mp3', 'm4a', 'aac', 'wav', 'flac', 'ogg', 'opus', 'wma', 'aiff', 'amr', 'mid', 'midi'
  ]);
  private static readonly documentExtensions = new Set<string>([
    'pdf', 'doc', 'docx', 'xls', 'xlsx', 'ppt', 'pptx', 'txt', 'md', 'rtf', 'csv', 'odt', 'ods', 'odp', 'epub'
  ]);
  private static readonly imageExtensions = new Set<string>([
    'png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp', 'heic', 'heif'
  ]);

  private static getContext(): common.UIAbilityContext {
    const context = AppStorage.get<Context>('abilityContext');
    if (!context) {
      throw new Error('Ability context is not initialized');
    }
    return context as common.UIAbilityContext;
  }

  static fileName(suggestedName: string | undefined, fallbackName: string): string {
    const firstLine = (suggestedName || '').split(/\r?\n/)[0].trim();
    const parts = firstLine.replace(/\\/g, '/').split('/');
    const baseName = parts[parts.length - 1]
      .replace(/[<>:"|?*\x00-\x1f]/g, '_')
      .replace(/[. ]+$/g, '')
      .trim();
    if (/\.[a-zA-Z0-9]{1,12}$/.test(baseName) && baseName.length <= 200) {
      return baseName;
    }
    if (!fallbackName) {
      return '';
    }
    const safeFallback = fallbackName.split(/[\\/]/).pop() || 'File.bin';
    return safeFallback.replace(/[<>:"|?*\x00-\x1f]/g, '_').replace(/[. ]+$/g, '').slice(0, 200) || 'File.bin';
  }

  static suggestedFileName(response: DownloadedBinary, preview: string | undefined,
    dataName: string | undefined, fallbackName: string): string {
    for (const candidate of [response.fileName, preview, dataName]) {
      const name = UserFileSaveUtil.fileName(candidate, '');
      if (name) {
        return name;
      }
    }
    return UserFileSaveUtil.fileName(fallbackName, 'File.bin');
  }

  private static extension(fileName: string): string {
    const index = fileName.lastIndexOf('.');
    return index < 0 ? '' : fileName.slice(index + 1).toLowerCase();
  }

  static category(type: ClipboardContentType, fileName: string, contentType?: string, buffer?: ArrayBuffer): SaveCategory {
    if (type === 'Group') {
      return 'Other';
    }
    const extension = UserFileSaveUtil.extension(fileName);
    const mime = (contentType || '').split(';')[0].toLowerCase();
    if (type === 'Image' || UserFileSaveUtil.imageExtensions.has(extension) || mime.startsWith('image/') ||
      (buffer !== undefined && ImageUtil.guessImageExtension(buffer) !== '.img')) {
      return 'Image';
    }
    if (UserFileSaveUtil.audioExtensions.has(extension) || mime.startsWith('audio/')) {
      return 'Sounds';
    }
    if (UserFileSaveUtil.documentExtensions.has(extension) || mime.startsWith('text/') ||
      mime === 'application/pdf' || mime === 'application/msword' ||
      mime.includes('officedocument') || mime.includes('opendocument')) {
      return 'Documents';
    }
    return 'Other';
  }

  static isLikelyImage(type: ClipboardContentType, name?: string): boolean {
    return type === 'Image' || (type === 'File' &&
      UserFileSaveUtil.imageExtensions.has(UserFileSaveUtil.extension(name || '')));
  }

  private static writeBuffer(file: fs.File, buffer: ArrayBuffer): void {
    let offset = 0;
    while (offset < buffer.byteLength) {
      const chunk = buffer.slice(offset, Math.min(offset + 1024 * 1024, buffer.byteLength));
      const written = fs.writeSync(file.fd, chunk);
      if (written <= 0) {
        throw new Error('Failed to write downloaded file');
      }
      offset += written;
    }
  }

  private static sample(response: DownloadedBinary): ArrayBuffer {
    const binary = response as BinaryResponse;
    return binary.buffer !== undefined ? binary.buffer : (response as StreamedBinaryResponse).prefix;
  }

  private static async writeDownloaded(file: fs.File, response: DownloadedBinary): Promise<void> {
    const binary = response as BinaryResponse;
    if (binary.buffer !== undefined) {
      UserFileSaveUtil.writeBuffer(file, binary.buffer);
      return;
    }
    const source = fs.openSync((response as StreamedBinaryResponse).path, fs.OpenMode.READ_ONLY);
    try {
      await fs.copyFile(source.fd, file.fd);
    } finally {
      fs.closeSync(source);
    }
  }

  static temporaryDownloadPath(): string {
    const context = UserFileSaveUtil.getContext();
    return `${context.cacheDir}/cliplink-${Date.now()}-${Math.floor(Math.random() * 1000000000)}.part`;
  }

  static removeTemporaryDownload(path: string): void {
    if (fs.accessSync(path)) {
      fs.unlinkSync(path);
    }
  }

  private static uniquePath(directory: string, fileName: string): UniqueTarget {
    const extension = UserFileSaveUtil.extension(fileName);
    const dot = extension ? fileName.length - extension.length - 1 : fileName.length;
    const base = fileName.slice(0, dot);
    const suffix = extension ? `.${extension}` : '';
    for (let index = 0; index < 10000; index++) {
      const name = index === 0 ? fileName : `${base} (${index})${suffix}`;
      const target = `${directory}/${name}`;
      if (!fs.accessSync(target)) {
        return { path: target, name: name };
      }
    }
    throw new Error('Too many files with the same name');
  }

  private static ensureDirectory(directory: string): void {
    if (fs.accessSync(directory)) {
      if (!fs.statSync(directory).isDirectory()) {
        throw new Error(`Save directory is occupied by a file: ${directory}`);
      }
      return;
    }
    try {
      fs.mkdirSync(directory);
    } catch (error) {
      // Another save may have created the directory after the existence check.
      if (fs.accessSync(directory) && fs.statSync(directory).isDirectory()) {
        return;
      }
      throw error instanceof Error ? error : new Error(String(error));
    }
  }

  static async saveAutomatically(response: DownloadedBinary, type: ClipboardContentType,
    preview: string | undefined, dataName: string | undefined, fallbackName: string, context?: common.UIAbilityContext): Promise<SavedFile> {
    const fileName = UserFileSaveUtil.suggestedFileName(response, preview, dataName, fallbackName);
    const category = UserFileSaveUtil.category(type, fileName, response.contentType,
      UserFileSaveUtil.sample(response));
    if (category === 'Image') {
      throw new Error('Use Save to Gallery for images');
    }
    const placement = await DownloadOrganizationService.getInstance().save(fileName, async (path: string): Promise<void> => {
      const file = fs.openSync(path, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE);
      try { await UserFileSaveUtil.writeDownloaded(file, response); }
      finally { fs.closeSync(file); }
    }, context);
    const bundle = (context || UserFileSaveUtil.getContext()).abilityInfo.bundleName;
    return { uri: placement.path, category: category, fileName: placement.name,
      location: `Download/${bundle}${placement.folder ? `/${placement.folder}` : ''}` };
  }

  static savedMessage(saved: SavedFile): string {
    return `Saved to ${saved.location || saved.uri}`;
  }

  static async saveToGallery(response: DownloadedBinary, preview: string | undefined,
    fallbackName: string, context?: common.UIAbilityContext): Promise<SavedFile> {
    const detected = ImageUtil.guessImageExtension(UserFileSaveUtil.sample(response));
    const extension = detected === '.img' ? UserFileSaveUtil.extension(
      UserFileSaveUtil.suggestedFileName(response, preview, undefined, fallbackName)) : detected.slice(1);
    if (!UserFileSaveUtil.imageExtensions.has(extension)) {
      throw new Error('Unsupported image format');
    }
    const original = UserFileSaveUtil.suggestedFileName(response, preview, undefined, fallbackName);
    const base = original.replace(/\.[^.]+$/, '').replace(/[.\\/:*?"'`<>|{}\[\]]/g, '_');
    const title = `${base.slice(0, 160)}-${Date.now()}-${++UserFileSaveUtil.gallerySequence}`;
    const helper = photoAccessHelper.getPhotoAccessHelper(context || UserFileSaveUtil.getContext());
    const uri = await helper.createAsset(photoAccessHelper.PhotoType.IMAGE, extension, { title: title });
    const file = fs.openSync(uri, fs.OpenMode.READ_WRITE);
    try {
      await UserFileSaveUtil.writeDownloaded(file, response);
    } finally {
      fs.closeSync(file);
    }
    return { uri: uri, category: 'Image', fileName: `${title}.${extension}` };
  }

  static async saveAs(response: DownloadedBinary, preview: string | undefined,
    dataName: string | undefined, fallbackName: string, context?: common.UIAbilityContext): Promise<string | null> {
    const options = new picker.DocumentSaveOptions();
    options.newFileNames = [UserFileSaveUtil.suggestedFileName(response, preview, dataName, fallbackName)];
    const documentPicker = new picker.DocumentViewPicker(context || UserFileSaveUtil.getContext());
    const uris = await documentPicker.save(options);
    if (!uris || uris.length === 0) {
      return null;
    }
    const file = fs.openSync(uris[0], fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
    try {
      await UserFileSaveUtil.writeDownloaded(file, response);
    } finally {
      fs.closeSync(file);
    }
    return uris[0];
  }
}
