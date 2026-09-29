import { FormExtensionAbility, formBindingData, formInfo, formProvider } from '@kit.FormKit';
import { Want, Configuration } from '@kit.AbilityKit';
import { LocalizationUtil } from '../utils/LocalizationUtil';
import { ConfigService } from '../services/ConfigService';
import { ClipboardWidgetService, WidgetSide } from '../services/ClipboardWidgetService';

interface CardMessage { side?: string; hide?: boolean; refresh?: boolean; token?: string; }

export default class ClipboardFormAbility extends FormExtensionAbility {
  onAddForm(want: Want): formBindingData.FormBindingData {
    ConfigService.getInstance().setContext(this.context);
    const id = String(want.parameters?.[formInfo.FormParam.IDENTITY_KEY] || '');
    const dimension = Number(want.parameters?.[formInfo.FormParam.DIMENSION_KEY] || 2);
    const data = ClipboardWidgetService.add(id, dimension);
    void ConfigService.getInstance().loadConfig().then((): void => { void this.onUpdateForm(id); });
    return formBindingData.createFormBindingData(data);
  }

  onUpdateForm(formId: string): void {
    void this.refreshForm(formId).catch((error: Error): void => {
      console.error('[ClipboardForm] Update:', error.message);
    });
  }

  private async refreshForm(formId: string, status: string = ''): Promise<void> {
    ConfigService.getInstance().setContext(this.context);
    await ConfigService.getInstance().loadConfig();
    let dimension: number | undefined;
    try { dimension = (await formProvider.getPublishedRunningFormInfoById(formId)).dimension; }
    catch (_) { /* onAddForm may run before the host finishes publishing the card. */ }
    const data = ClipboardWidgetService.add(formId, dimension);
    data.actionStatus = LocalizationUtil.text(status, ConfigService.getInstance().getConfig().language,
      LocalizationUtil.systemLanguage());
    await formProvider.updateForm(formId, formBindingData.createFormBindingData(data));
  }

  onFormEvent(formId: string, message: string): void {
    ConfigService.getInstance().setContext(this.context);
    try {
      const event = JSON.parse(message) as CardMessage;
      if (event.refresh === true) {
        void this.refreshForm(formId, 'Widget refreshed. Tap again').catch((error: Error): void => {
          console.error('[ClipboardForm] Repair:', error.message);
        });
        return;
      }
      if (event.side !== 'local' && event.side !== 'remote') return;
      const side = event.side as WidgetSide;
      void ConfigService.getInstance().loadConfig().then((): Promise<void> => {
        if (event.hide === true && event.token) return ClipboardWidgetService.hideExpired(formId, side, event.token);
        return ClipboardWidgetService.toggle(formId, side, event.hide === true);
      })
        .catch((error: Error): void => { console.error('[ClipboardForm] Read:', error.message); });
    } catch (_) { /* Ignore malformed host events. */ }
  }

  onStop(): void { /* Stopping the form provider must not invalidate an in-flight card call. */ }

  onRemoveForm(formId: string): void { ClipboardWidgetService.remove(formId); }
  onConfigurationUpdate(config: Configuration): void { void ClipboardWidgetService.resetAll(this.context); }
  onAcquireFormState(want: Want): formInfo.FormState { return formInfo.FormState.READY; }
}
