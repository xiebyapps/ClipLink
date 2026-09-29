import cryptoFramework from '@ohos.security.cryptoFramework';
import util from '@ohos.util';

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
        data: HashUtil.utf8Bytes(text)
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
  static utf8Bytes(str: string): Uint8Array {
    return new util.TextEncoder().encode(str);
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
