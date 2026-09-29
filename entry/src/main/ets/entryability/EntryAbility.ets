import { ClipboardSnapshotUtil } from '../utils/ClipboardSnapshotUtil';
import { ClipboardActionFeedback } from '../services/ClipboardActionFeedback';
import { DesktopActionService } from '../services/DesktopActionService';
import { ClipboardWidgetService } from '../services/ClipboardWidgetService';
import { DownloadOrganizationService } from '../services/DownloadOrganizationService';
import { RecordCacheService } from '../services/RecordCacheService';
import { HistoryStorageService } from '../services/HistoryStorageService';
import UIAbility from '@ohos.app.ability.UIAbility';
import window from '@ohos.window';
import { AbilityConstant, Configuration, ConfigurationConstant, Want } from '@kit.AbilityKit';
import { BusinessError, deviceInfo } from '@kit.BasicServicesKit';
import { ConfigService } from '../services/ConfigService';
import { PollingController } from '../services/PollingController';
import { ServerManager } from '../services/ServerManager';
import { ThemeUtil } from '../utils/ThemeUtil';
import { LocalizationUtil } from '../utils/LocalizationUtil';

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    this.acceptDesktopWant(want);
    console.info('[EntryAbility] onCreate');
    AppStorage.setOrCreate('abilityContext', this.context);
    void ClipboardSnapshotUtil.cleanupAbandoned(this.context);
    AppStorage.setOrCreate('historyRefreshToken', 0);
    AppStorage.setOrCreate('serverRevision', 0);
    AppStorage.setOrCreate('serverConnectionStatus', 'checking');
    AppStorage.setOrCreate('appForeground', true);
    ConfigService.getInstance().setContext(this.context);
    AppStorage.setOrCreate('floatingTabsEnabled', deviceInfo.sdkApiVersion >= 23);
    AppStorage.setOrCreate('systemLanguage', LocalizationUtil.systemLanguage());
    AppStorage.setOrCreate('safeAreaTop', 44);
    AppStorage.setOrCreate('safeAreaBottom', 0);
    this.syncSystemTheme(this.context?.config?.colorMode);
    void ConfigService.getInstance()
      .loadConfig()
      .then(async (): Promise<void> => {
        RecordCacheService.getInstance().start(this.context);
        void DownloadOrganizationService.getInstance().resume();
        void HistoryStorageService.getInstance().applyLimits().catch((error: Error): void => {
          console.error('[EntryAbility] history limits:', error.message);
        });
        await ClipboardWidgetService.resetAll(this.context, DesktopActionService.pendingWidgetToken());
        DesktopActionService.configure();
        ServerManager.getInstance().start();
        return ThemeUtil.applyStoredTheme();
      })
      .catch((error: Error | Object | string) => {
        console.error('[EntryAbility] loadConfig error:', JSON.stringify(error));
      });
  }

  private acceptDesktopWant(want: Want): void {
    const params = want.parameters;
    if (!params || typeof params.desktopAction !== 'string') return;
    DesktopActionService.accept(params.desktopAction,
      typeof params.formId === 'string' ? params.formId : '',
      typeof params.widgetToken === 'string' ? params.widgetToken : '',
      typeof params.requestId === 'string' ? params.requestId : '');
  }

  onNewWant(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    this.acceptDesktopWant(want);
  }

  onDestroy(): void {
    ServerManager.getInstance().stop();
    RecordCacheService.getInstance().stop();
    console.info('[EntryAbility] onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    console.info('[EntryAbility] onWindowStageCreate');
    AppStorage.setOrCreate('mainWindowStage', windowStage);
    this.syncWindowAvoidAreas(windowStage);
    
    windowStage.loadContent('pages/Index', (err: BusinessError) => {
      if (err.code) {
        console.error(`[EntryAbility] Failed to load content. Error: ${JSON.stringify(err)}`);
        return;
      }
      void ThemeUtil.applyStoredTheme();
      void ClipboardActionFeedback.authorize(this.context);
      console.info('[EntryAbility] Succeeded in loading content');
    });
  }

  onWindowStageDestroy(): void {
    console.info('[EntryAbility] onWindowStageDestroy');
  }

  onForeground(): void {
    console.info('[EntryAbility] onForeground');
    DesktopActionService.setForeground(true);
    ConfigService.getInstance().setContext(this.context);
    AppStorage.setOrCreate('appForeground', true);
    this.syncSystemTheme(this.context?.config?.colorMode);
    AppStorage.setOrCreate('systemLanguage', LocalizationUtil.systemLanguage());
    void ThemeUtil.applyStoredTheme();
    void ConfigService.getInstance().loadConfig().then((): void => {
      RecordCacheService.getInstance().start(this.context);
      void DownloadOrganizationService.getInstance().resume();
    });
    ServerManager.getInstance().start();
  }

  onBackground(): void {
    console.info('[EntryAbility] onBackground');
    DesktopActionService.setForeground(false);
    AppStorage.setOrCreate('appForeground', false);
    PollingController.stopAll();
    RecordCacheService.getInstance().stop();
    ServerManager.getInstance().stop();
  }

  onConfigurationUpdate(config: Configuration): void {
    this.syncSystemTheme(config.colorMode);
    AppStorage.setOrCreate('systemLanguage', LocalizationUtil.systemLanguage());
    void ThemeUtil.applyStoredTheme();
  }

  private syncSystemTheme(colorMode: ConfigurationConstant.ColorMode | undefined): void {
    AppStorage.setOrCreate(
      'systemColorMode',
      colorMode ?? ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET
    );
  }

  private syncWindowAvoidAreas(windowStage: window.WindowStage): void {
    try {
      const mainWindow = windowStage.getMainWindowSync();
      const uiContext = mainWindow.getUIContext();

      const updateInsets = (): void => {
        const systemArea = mainWindow.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
        const navigationArea = mainWindow.getWindowAvoidArea(
          window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR
        );
        const topInset = uiContext.px2vp(systemArea.topRect.height);
        const bottomInset = Math.max(
          uiContext.px2vp(systemArea.bottomRect.height),
          uiContext.px2vp(navigationArea.bottomRect.height)
        );

        AppStorage.setOrCreate('safeAreaTop', topInset > 0 ? topInset : 44);
        AppStorage.setOrCreate(
          'safeAreaBottom',
          bottomInset > 0 ? bottomInset : 0
        );
      };

      updateInsets();
      mainWindow.on('avoidAreaChange', (avoidAreaOption) => {
        if (
          avoidAreaOption.type === window.AvoidAreaType.TYPE_SYSTEM ||
          avoidAreaOption.type === window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR
        ) {
          updateInsets();
        }
      });
    } catch (error) {
      console.error('[EntryAbility] syncWindowAvoidAreas error:', JSON.stringify(error));
    }
  }
}
