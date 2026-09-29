import pasteboard from '@ohos.pasteboard';
import abilityAccessCtrl from '@ohos.abilityAccessCtrl';
import { image } from '@kit.ImageKit';

/**
 * Clipboard utility - read/write clipboard text
 */
export class ClipboardUtil {
  private static permissionPromise: Promise<boolean> | null = null;

  static resetReadPermission(): void {
    ClipboardUtil.permissionPromise = null;
  }

  private static getAbilityContext(): Context {
    const context = AppStorage.get<Context>('abilityContext');
    if (!context) {
      throw new Error('Ability context is not initialized');
    }
    return context as Context;
  }

  static async ensureReadPermission(context?: Context, allowPrompt: boolean = true): Promise<boolean> {
    const owner = context || ClipboardUtil.getAbilityContext();
    const manager = abilityAccessCtrl.createAtManager();
    try {
      const status = await manager.checkAccessToken(owner.applicationInfo.accessTokenId,
        'ohos.permission.READ_PASTEBOARD');
      if (status === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED) return true;
    } catch (_) { /* A permission check failure must never grant access. */ }
    if (!allowPrompt) return false;
    if (!ClipboardUtil.permissionPromise) {
      ClipboardUtil.permissionPromise = manager.requestPermissionsFromUser(owner,
        ['ohos.permission.READ_PASTEBOARD']).then((result): boolean =>
          result.authResults.length > 0 && result.authResults[0] === 0).catch((): boolean => false);
    }
    try { return await ClipboardUtil.permissionPromise; }
    finally { ClipboardUtil.permissionPromise = null; }
  }

  /**
   * Read text from system clipboard
   */
  static async getClipboardText(): Promise<string> {
    try {
      const hasPermission = await ClipboardUtil.ensureReadPermission();
      if (!hasPermission) {
        return '';
      }
      const systemPasteboard = pasteboard.getSystemPasteboard();
      if (!(await systemPasteboard.hasData())) {
        return '';
      }

      const pasteData = await systemPasteboard.getData();
      const primaryMimeType = pasteData.getPrimaryMimeType();
      if (primaryMimeType === pasteboard.MIMETYPE_TEXT_PLAIN) {
        return pasteData.getPrimaryText() || '';
      }

      return '';
    } catch (error) {
      console.error('[ClipboardUtil] getClipboardText error:', JSON.stringify(error));
      return '';
    }
  }

  static async getClipboardSummary(): Promise<string> {
    try {
      const hasPermission = await ClipboardUtil.ensureReadPermission();
      if (!hasPermission) {
        return 'Clipboard permission denied';
      }
      const systemPasteboard = pasteboard.getSystemPasteboard();
      if (!(await systemPasteboard.hasData())) {
        return 'Empty clipboard';
      }

      const pasteData = await systemPasteboard.getData();
      const primaryMimeType = pasteData.getPrimaryMimeType();
      if (primaryMimeType === pasteboard.MIMETYPE_PIXELMAP) {
        return '[Image in clipboard]';
      }
      if (primaryMimeType === pasteboard.MIMETYPE_TEXT_URI) {
        return pasteData.getPrimaryUri() || 'URI in clipboard';
      }

      const plainText =
        pasteData.getRecordCount() > 0 ? pasteData.getRecord(0).toPlainText() || '' : '';
      return plainText || '[Clipboard data unavailable]';
    } catch (error) {
      console.error('[ClipboardUtil] getClipboardSummary error:', JSON.stringify(error));
      return 'Error reading clipboard';
    }
  }

  static async getClipboardImage(): Promise<image.PixelMap | undefined> {
    try {
      const hasPermission = await ClipboardUtil.ensureReadPermission();
      if (!hasPermission) {
        return undefined;
      }
      const systemPasteboard = pasteboard.getSystemPasteboard();
      if (!(await systemPasteboard.hasData())) {
        return undefined;
      }

      const pasteData = await systemPasteboard.getData();
      if (pasteData.getPrimaryMimeType() !== pasteboard.MIMETYPE_PIXELMAP) {
        return undefined;
      }
      return pasteData.getPrimaryPixelMap();
    } catch (error) {
      console.error('[ClipboardUtil] getClipboardImage error:', JSON.stringify(error));
      return undefined;
    }
  }

  /**
   * Write text to system clipboard
   */
  static async setClipboardText(text: string): Promise<void> {
    try {
      const systemPasteboard = pasteboard.getSystemPasteboard();
      const pasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text);
      await systemPasteboard.setData(pasteData);
    } catch (error) {
      console.error('[ClipboardUtil] setClipboardText error:', JSON.stringify(error));
      throw new Error('Failed to set clipboard text');
    }
  }

  static async setClipboardImage(pixelMap: image.PixelMap): Promise<void> {
    try {
      const systemPasteboard = pasteboard.getSystemPasteboard();
      const pasteData = pasteboard.createData(pasteboard.MIMETYPE_PIXELMAP, pixelMap);
      await systemPasteboard.setData(pasteData);
    } catch (error) {
      console.error('[ClipboardUtil] setClipboardImage error:', JSON.stringify(error));
      throw new Error('Failed to set clipboard image');
    }
  }

  /**
   * Check if clipboard has text data
   */
  static async hasText(): Promise<boolean> {
    try {
      const hasPermission = await ClipboardUtil.ensureReadPermission();
      if (!hasPermission) {
        return false;
      }
      const systemPasteboard = pasteboard.getSystemPasteboard();
      if (!(await systemPasteboard.hasData())) {
        return false;
      }
      const pasteData = await systemPasteboard.getData();
      const mimeType = pasteData.getPrimaryMimeType();
      return mimeType === pasteboard.MIMETYPE_TEXT_PLAIN;
    } catch (error) {
      console.error('[ClipboardUtil] hasText error:', JSON.stringify(error));
      return false;
    }
  }

  static onUpdate(callback: () => void): void {
    pasteboard.getSystemPasteboard().on('update', callback);
  }

  static offUpdate(callback?: () => void): void {
    pasteboard.getSystemPasteboard().off('update', callback);
  }
}
