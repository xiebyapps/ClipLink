import http from '@ohos.net.http';
import { BusinessError } from '@kit.BasicServicesKit';
import { MultipartField } from '../types/ApiTypes';
import { fileIo as fs } from '@kit.CoreFileKit';
import { rcp } from '@kit.RemoteCommunicationKit';

export interface BinaryResponse {
  buffer: ArrayBuffer;
  fileName?: string;
  contentType?: string;
}

export interface StreamedBinaryResponse {
  path: string;
  prefix: ArrayBuffer;
  size: number;
  fileName?: string;
  contentType?: string;
}

/** Optional cancellation for file streams; existing callers need no changes. */
export class DownloadCancellation {
  canceled: boolean = false;
  private listener?: () => void;

  cancel(): void {
    if (this.canceled) return;
    this.canceled = true;
    this.listener?.();
  }

  subscribe(listener: () => void): void {
    this.listener = listener;
    if (this.canceled) listener();
  }

  unsubscribe(): void {
    this.listener = undefined;
  }
}

/**
 * HTTP Client - simple wrapper for SyncClipboard API requests
 */
export class HttpClient {
  private baseUrl: string = '';
  private username: string = '';
  private password: string = '';
  private timeoutMs: number = 30000;

  constructor(baseUrl?: string, username?: string, password?: string) {
    if (baseUrl) {
      this.setBaseUrl(baseUrl);
    }
    if (username) {
      this.username = username;
    }
    if (password) {
      this.password = password;
    }
  }

  /**
   * Set base URL
   */
  setBaseUrl(url: string): void {
    this.baseUrl = url.endsWith('/') ? url.slice(0, -1) : url;
  }

  /**
   * Set credentials
   */
  setCredentials(username: string, password: string): void {
    this.username = username;
    this.password = password;
  }

  /**
   * Create authorization header
   */
  private getAuthHeader(): string {
    if (this.username && this.password) {
      const credentials = `${this.username}:${this.password}`;
      const encoded = this.base64Encode(credentials);
      return `Basic ${encoded}`;
    }
    return '';
  }

  /**
   * Simple base64 encoding
   */
  private base64Encode(str: string): string {
    const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
    const bytes: number[] = this.stringToBytes(str);
    let result = '';
    for (let i = 0; i < bytes.length; i += 3) {
      const a: number = bytes[i];
      const hasB = i + 1 < bytes.length;
      const hasC = i + 2 < bytes.length;
      const b: number = hasB ? bytes[i + 1] : 0;
      const c: number = hasC ? bytes[i + 2] : 0;
      const bitmap = (a << 16) | (b << 8) | c;
      result += chars.charAt((bitmap >> 18) & 63);
      result += chars.charAt((bitmap >> 12) & 63);
      result += hasB ? chars.charAt((bitmap >> 6) & 63) : '=';
      result += hasC ? chars.charAt(bitmap & 63) : '=';
    }
    return result;
  }

  private stringToBytes(str: string): number[] {
    const bytes: number[] = [];
    for (let i = 0; i < str.length; i++) {
      const code = str.charCodeAt(i);
      if (code <= 0x7f) {
        bytes.push(code);
      } else if (code <= 0x7ff) {
        bytes.push(0xc0 | (code >> 6));
        bytes.push(0x80 | (code & 0x3f));
      } else {
        bytes.push(0xe0 | (code >> 12));
        bytes.push(0x80 | ((code >> 6) & 0x3f));
        bytes.push(0x80 | (code & 0x3f));
      }
    }
    return bytes;
  }

  private parseJson<T>(json: string): T {
    const parsed: T = JSON.parse(json) as T;
    return parsed;
  }

  private buildHeaders(contentType: string = 'application/json'): Record<string, string> {
    const headers: Record<string, string> = {
      'Content-Type': contentType
    };

    const auth = this.getAuthHeader();
    if (auth) {
      headers.Authorization = auth;
    }

    return headers;
  }

  private request(path: string, method: http.RequestMethod, body: string = '', contentType: string = 'application/json'): Promise<string> {
    return new Promise((resolve, reject) => {
      const request = http.createHttp();
      const options: http.HttpRequestOptions = {
        method,
        header: this.buildHeaders(contentType),
        readTimeout: this.timeoutMs,
        connectTimeout: this.timeoutMs,
        expectDataType: http.HttpDataType.STRING,
        // Clipboard and history metadata must reflect writes by this or other clients.
        usingCache: false
      };

      if (body.length > 0) {
        options.extraData = body;
      }

      request.request(`${this.baseUrl}${path}`, options, (err: BusinessError, data: http.HttpResponse) => {
        request.destroy();

        if (err) {
          reject(new Error(`REQUEST_${err.code}`));
          return;
        }

        const resultText = typeof data.result === 'string' ? data.result : JSON.stringify(data.result ?? '');
        if (data.responseCode < 200 || data.responseCode > 299) {
          reject(new Error(`HTTP ${data.responseCode}: ${resultText}`));
          return;
        }

        resolve(resultText);
      });
    });
  }

  private responseHeader(headers: Object, name: string): string | undefined {
    const values = headers as Record<string, string | string[]>;
    const key = Object.keys(values).find((entry: string): boolean => entry.toLowerCase() === name);
    if (!key) {
      return undefined;
    }
    const value = values[key];
    return Array.isArray(value) ? value[0] : value;
  }

  authorizationHeader(): string {
    return this.getAuthHeader();
  }

  setTimeout(milliseconds: number): void {
    this.timeoutMs = milliseconds;
  }

  private responseFileName(disposition: string | undefined): string | undefined {
    if (!disposition) {
      return undefined;
    }
    const encoded = /filename\*\s*=\s*(?:UTF-8'')?([^;]+)/i.exec(disposition);
    if (encoded) {
      try {
        return decodeURIComponent(encoded[1].trim().replace(/^"|"$/g, ''));
      } catch (_) {
        // Fall back to the plain filename parameter.
      }
    }
    const plain = /filename\s*=\s*(?:"([^"]+)"|([^;]+))/i.exec(disposition);
    return plain ? (plain[1] || plain[2]).trim() : undefined;
  }

  private requestBinary(path: string, method: http.RequestMethod): Promise<BinaryResponse> {
    return new Promise((resolve, reject) => {
      const request = http.createHttp();
      const options: http.HttpRequestOptions = {
        method,
        header: this.buildHeaders(''),
        readTimeout: this.timeoutMs,
        connectTimeout: this.timeoutMs,
        expectDataType: http.HttpDataType.ARRAY_BUFFER
      };

      request.request(`${this.baseUrl}${path}`, options, (err: BusinessError, data: http.HttpResponse) => {
        request.destroy();

        if (err) {
          reject(new Error(`REQUEST_${err.code}`));
          return;
        }

        if (data.responseCode < 200 || data.responseCode > 299) {
          reject(new Error(`HTTP ${data.responseCode}`));
          return;
        }

        if (data.result instanceof ArrayBuffer) {
          resolve({
            buffer: data.result,
            fileName: this.responseFileName(this.responseHeader(data.header, 'content-disposition')),
            contentType: this.responseHeader(data.header, 'content-type')
          });
          return;
        }
        reject(new Error('Unexpected binary response type'));
      });
    });
  }

  /**
   * GET request
   */
  async get<T>(path: string): Promise<T> {
    console.info(`[HttpClient] GET ${this.baseUrl}${path}`);
    const resultText = await this.request(path, http.RequestMethod.GET);
    return this.parseJson<T>(resultText);
  }

  async getText(path: string): Promise<string> {
    return await this.request(path, http.RequestMethod.GET, '', '');
  }

  async getArrayBuffer(path: string): Promise<ArrayBuffer> {
    return (await this.requestBinary(path, http.RequestMethod.GET)).buffer;
  }

  async getBinary(path: string): Promise<BinaryResponse> {
    return await this.requestBinary(path, http.RequestMethod.GET);
  }

  async getBinaryToFile(path: string, targetPath: string,
    onProgress?: (received: number, total: number) => void,
    cancellation?: DownloadCancellation): Promise<StreamedBinaryResponse> {
    if (cancellation?.canceled) throw new Error('Download canceled');
    return new Promise((resolve, reject) => {
      const request = http.createHttp();
      const file = fs.openSync(targetPath, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE);
      const prefix = new Uint8Array(16);
      let prefixSize = 0;
      let size = 0;
      let responseCode = -1;
      let streamEnded = false;
      let settled = false;
      let fileName: string | undefined;
      let contentType: string | undefined;
      let contentLength = 0;

      const close = (): void => {
        cancellation?.unsubscribe();
        fs.closeSync(file);
        request.destroy();
      };
      const fail = (error: Error): void => {
        if (settled) return;
        settled = true;
        close();
        reject(error);
      };
      const finish = (): void => {
        if (settled || !streamEnded || responseCode < 0) return;
        if (responseCode < 200 || responseCode > 299) {
          fail(new Error(`HTTP ${responseCode}`));
          return;
        }
        settled = true;
        close();
        resolve({ path: targetPath, prefix: prefix.buffer.slice(0, prefixSize), size, fileName, contentType });
      };

      cancellation?.subscribe((): void => fail(new Error('Download canceled')));
      if (settled) return;

      request.on('headersReceive', (headers: Object): void => {
        fileName = this.responseFileName(this.responseHeader(headers, 'content-disposition'));
        contentType = this.responseHeader(headers, 'content-type');
        const length = Number(this.responseHeader(headers, 'content-length'));
        contentLength = Number.isFinite(length) && length > 0 ? length : 0;
      });
      request.on('dataReceive', (chunk: ArrayBuffer): void => {
        if (settled) return;
        try {
          const bytes = new Uint8Array(chunk);
          const initial = Math.min(prefix.length - prefixSize, bytes.length);
          prefix.set(bytes.subarray(0, initial), prefixSize);
          prefixSize += initial;
          let offset = 0;
          while (offset < chunk.byteLength) {
            const written = fs.writeSync(file.fd, chunk.slice(offset));
            if (written <= 0) throw new Error('Failed to write temporary download');
            offset += written;
          }
          size += chunk.byteLength;
          onProgress?.(size, contentLength);
        } catch (error) {
          fail(error instanceof Error ? error : new Error(String(error)));
        }
      });
      request.on('dataEnd', (): void => {
        streamEnded = true;
        finish();
      });

      const options: http.HttpRequestOptions = {
        method: http.RequestMethod.GET,
        header: this.buildHeaders(''),
        connectTimeout: 30000,
        readTimeout: 120000,
        usingCache: false
      };
      request.requestInStream(`${this.baseUrl}${path}`, options)
        .then((code: number): void => {
          responseCode = code;
          finish();
        })
        .catch((error: BusinessError): void => {
          fail(new Error(`REQUEST_${error.code}`));
        });
    });
  }

  /**
   * PUT request
   */
  async put(path: string, data: object): Promise<void> {
    console.info(`[HttpClient] PUT ${this.baseUrl}${path}`);
    await this.request(path, http.RequestMethod.PUT, JSON.stringify(data));
  }

  async patch(path: string, data: object): Promise<void> {
    // net.http's PATCH enum requires API 26; RCP supports it on our minimum API 20.
    const session = rcp.createSession({ requestConfiguration: {
      transfer: { timeout: { connectMs: this.timeoutMs, transferMs: this.timeoutMs } }
    } });
    try {
      const response = await session.fetch(new rcp.Request(`${this.baseUrl}${path}`,
        'PATCH', this.buildHeaders(), JSON.stringify(data)));
      if (response.statusCode < 200 || response.statusCode > 299) {
        throw new Error(`HTTP ${response.statusCode}: ${response.toString() || ''}`);
      }
    } catch (error) {
      if (error instanceof Error) throw error;
      throw new Error(`REQUEST_${(error as BusinessError).code}`);
    } finally {
      session.close();
    }
  }

  /**
   * POST request
   */
  async post<T>(path: string, data: object): Promise<T> {
    console.info(`[HttpClient] POST ${this.baseUrl}${path}`);
    const resultText = await this.request(path, http.RequestMethod.POST, JSON.stringify(data));
    return this.parseJson<T>(resultText);
  }

  async postMultipart<T>(path: string, fields: MultipartField[]): Promise<T> {
    const boundary = `----SyncClipboard${Date.now()}${Math.random().toString(16).slice(2)}`;
    const body = this.buildMultipartBody(boundary, fields);
    const resultText = await this.request(
      path,
      http.RequestMethod.POST,
      body,
      `multipart/form-data; boundary=${boundary}`
    );
    if (!resultText) {
      return this.parseJson<T>('null');
    }
    return this.parseJson<T>(resultText);
  }

  private buildMultipartBody(boundary: string, fields: MultipartField[]): string {
    let body = '';
    fields.forEach((field: MultipartField): void => {
      if (field.value.includes(boundary)) {
        throw new Error(`Multipart field "${field.key}" contains boundary token`);
      }
      body += `--${boundary}\r\n`;
      body += `Content-Disposition: form-data; name="${field.key}"\r\n\r\n`;
      body += `${field.value}\r\n`;
    });
    body += `--${boundary}--\r\n`;
    return body;
  }
}
