import { ClipboardSnapshotUtil } from '../utils/ClipboardSnapshotUtil';
import { ShareExtensionAbility, Want, UIExtensionContentSession } from '@kit.AbilityKit';
import { systemShare } from '@kit.ShareKit';
import { ShareTransferState } from '../services/ShareTransferState';
import { ConfigService } from '../services/ConfigService';
import { UploadFile } from '../services/FileUploadService';
import { LocalizationUtil } from '../utils/LocalizationUtil';

export default class ShareAbility extends ShareExtensionAbility {
  onSessionCreate(want: Want, session: UIExtensionContentSession): void {
    ConfigService.getInstance().setContext(this.context);
    AppStorage.setOrCreate('systemLanguage', LocalizationUtil.systemLanguage());
    void ClipboardSnapshotUtil.cleanupAbandoned(this.context).then(() => systemShare.getSharedData(want)).then((data: systemShare.SharedData): void => {
      const files: UploadFile[] = data.getRecords()
        .filter((record: systemShare.SharedRecord): boolean => !!record.uri)
        .map((record: systemShare.SharedRecord): UploadFile => ({
          uri: record.uri || '', name: record.title,
          image: record.utd.startsWith('general.image') ||
            ['general.png', 'general.jpeg', 'general.gif', 'general.webp',
              'general.heic', 'general.heif', 'general.bmp'].includes(record.utd)
        }));
      ShareTransferState.files = files;
      ShareTransferState.session = session;
      ShareTransferState.context = this.context;
      session.loadContent('pages/SharePage');
    }).catch((error: Error): void => {
      console.error('[ShareAbility] Failed to receive files:', error.message);
      session.loadContent('pages/SharePage');
    });
  }

  onSessionDestroy(session: UIExtensionContentSession): void {
    ShareTransferState.clear();
    const mainContext = AppStorage.get<Context>('abilityContext');
    if (mainContext) ConfigService.getInstance().setContext(mainContext);
  }
}
