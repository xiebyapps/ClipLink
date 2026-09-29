import { promptAction } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { notificationManager } from '@kit.NotificationKit';
import preferences from '@ohos.data.preferences';
import { ConfigService } from './ConfigService';
import { LocalizationUtil } from '../utils/LocalizationUtil';

export class ClipboardActionFeedback {
  static text(value: string): string {
    return LocalizationUtil.text(value, ConfigService.getInstance().getConfig().language,
      LocalizationUtil.systemLanguage());
  }

  static async authorize(context: common.UIAbilityContext): Promise<void> {
    try {
      if (await notificationManager.isNotificationEnabled()) return;
      const store = await preferences.getPreferences(context, 'desktop_notifications');
      if (await store.get('asked', false)) return;
      await store.put('asked', true); await store.flush();
      await notificationManager.requestEnableNotification(context);
    } catch (_) { /* Denial leaves card feedback available and never opens Home. */ }
  }

  static async show(message: string, uiContext?: UIContext): Promise<void> {
    const text = ClipboardActionFeedback.text(message);
    if (uiContext) {
      try { uiContext.getPromptAction().showToast({ message: text, showMode: promptAction.ToastShowMode.TOP_MOST }); return; }
      catch (_) { }
    }
    try {
      if (!await notificationManager.isNotificationEnabled()) return;
      await notificationManager.publish({ id: 8302, notificationSlotType: notificationManager.SlotType.SERVICE_INFORMATION,
        content: { notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
          normal: { title: ClipboardActionFeedback.text('Clipboard action'), text: text } },
        autoDeletedTime: Date.now() + 8000 });
    } catch (_) { /* The card always carries the result even when notifications are disabled. */ }
  }
}
