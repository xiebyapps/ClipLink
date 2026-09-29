import { UIExtensionContentSession } from '@kit.AbilityKit';
import { UploadFile, FileUploadTask } from './FileUploadService';

export class ShareTransferState {
  static files: UploadFile[] = [];
  static session: UIExtensionContentSession | null = null;
  static context: Context | null = null;
  static task: FileUploadTask | null = null;

  static clear(): void {
    ShareTransferState.task?.cancel();
    ShareTransferState.task = null;
    ShareTransferState.files = [];
    ShareTransferState.session = null;
    ShareTransferState.context = null;
  }
}
