import { image } from '@kit.ImageKit';

export class ImageUtil {
  static async createPixelMapFromPath(path: string): Promise<image.PixelMap> {
    const imageSource = image.createImageSource(path);
    try {
      return await imageSource.createPixelMap({ desiredPixelFormat: image.PixelMapFormat.RGBA_8888 });
    } finally {
      await imageSource.release();
    }
  }

  static async createPixelMapFromBuffer(buffer: ArrayBuffer): Promise<image.PixelMap> {
    const imageSource = image.createImageSource(buffer.slice(0, buffer.byteLength));
    try {
      return await imageSource.createPixelMap({
        desiredPixelFormat: image.PixelMapFormat.RGBA_8888
      });
    } finally {
      await imageSource.release();
    }
  }

  static guessImageExtension(buffer: ArrayBuffer): string {
    const bytes = new Uint8Array(buffer);
    if (bytes.length >= 8 &&
      bytes[0] === 0x89 &&
      bytes[1] === 0x50 &&
      bytes[2] === 0x4E &&
      bytes[3] === 0x47) {
      return '.png';
    }
    if (bytes.length >= 3 &&
      bytes[0] === 0xFF &&
      bytes[1] === 0xD8 &&
      bytes[2] === 0xFF) {
      return '.jpg';
    }
    if (bytes.length >= 4 &&
      bytes[0] === 0x47 &&
      bytes[1] === 0x49 &&
      bytes[2] === 0x46 &&
      bytes[3] === 0x38) {
      return '.gif';
    }
    if (bytes.length >= 12 &&
      bytes[0] === 0x52 &&
      bytes[1] === 0x49 &&
      bytes[2] === 0x46 &&
      bytes[3] === 0x46 &&
      bytes[8] === 0x57 &&
      bytes[9] === 0x45 &&
      bytes[10] === 0x42 &&
      bytes[11] === 0x50) {
      return '.webp';
    }
    if (bytes.length >= 2 &&
      bytes[0] === 0x42 &&
      bytes[1] === 0x4D) {
      return '.bmp';
    }
    return '.img';
  }
}
