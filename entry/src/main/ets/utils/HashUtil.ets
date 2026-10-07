import cryptoFramework from '@ohos.security.cryptoFramework';

/**
 * Hash utility - calculates SHA256 hash
 */
export class HashUtil {
  /**
   * Calculate SHA256 hash of text (uppercase hex)
   * Compatible with current mobile client hash rule
   */
  static async calculateTextHash(text: string): Promise<string> {
    try {
      const mdAlgorithm = cryptoFramework.createMd('SHA256');
      const data: cryptoFramework.DataBlob = {
        data: new Uint8Array(HashUtil.stringToBytes(text))
      };
      
      await mdAlgorithm.update(data);
      const result = await mdAlgorithm.digest();
      
      return HashUtil.bytesToHex(new Uint8Array(result.data)).toUpperCase();
    } catch (error) {
      console.error('[HashUtil] calculateTextHash error:', JSON.stringify(error));
      throw new Error('Failed to calculate text hash');
    }
  }

  /**
   * Convert string to byte array (UTF-8)
   */
  private static stringToBytes(str: string): number[] {
    const bytes: number[] = [];
    for (let i = 0; i < str.length; i++) {
      let code = str.charCodeAt(i);
      if (code >= 0xd800 && code <= 0xdbff) {
        const next = i + 1 < str.length ? str.charCodeAt(i + 1) : 0;
        if (next >= 0xdc00 && next <= 0xdfff) {
          code = 0x10000 + ((code - 0xd800) << 10) + (next - 0xdc00);
          i++;
        } else {
          code = 0xfffd;
        }
      } else if (code >= 0xdc00 && code <= 0xdfff) {
        code = 0xfffd;
      }
      if (code <= 0x7f) {
        bytes.push(code);
      } else if (code <= 0x7ff) {
        bytes.push(0xc0 | (code >> 6));
        bytes.push(0x80 | (code & 0x3f));
      } else if (code <= 0xffff) {
        bytes.push(0xe0 | (code >> 12));
        bytes.push(0x80 | ((code >> 6) & 0x3f));
        bytes.push(0x80 | (code & 0x3f));
      } else {
        bytes.push(0xf0 | (code >> 18));
        bytes.push(0x80 | ((code >> 12) & 0x3f));
        bytes.push(0x80 | ((code >> 6) & 0x3f));
        bytes.push(0x80 | (code & 0x3f));
      }
    }
    return bytes;
  }

  /**
   * Convert byte array to hex string
   */
  private static bytesToHex(bytes: Uint8Array): string {
    return Array.from(bytes)
      .map((b: number) => b.toString(16).padStart(2, '0'))
      .join('');
  }
}
