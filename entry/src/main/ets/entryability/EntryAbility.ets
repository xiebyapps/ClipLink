import UIAbility from '@ohos.app.ability.UIAbility';
import window from '@ohos.window';
import { AbilityConstant, Configuration, ConfigurationConstant, Want } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { ConfigService } from '../services/ConfigService';
import { PollingController } from '../services/PollingController';
import { ThemeUtil } from '../utils/ThemeUtil';

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    console.info('[EntryAbility] onCreate');
    AppStorage.setOrCreate('abilityContext', this.context);
    AppStorage.setOrCreate('historyRefreshToken', 0);
    AppStorage.setOrCreate('safeAreaTop', 44);
    AppStorage.setOrCreate('safeAreaBottom', 0);
    this.syncSystemTheme(this.context?.config?.colorMode);
    void ConfigService.getInstance()
      .loadConfig()
      .then(() => ThemeUtil.applyStoredTheme())
      .catch((error: Error | Object | string) => {
        console.error('[EntryAbility] loadConfig error:', JSON.stringify(error));
      });
  }

  onDestroy(): void {
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
      console.info('[EntryAbility] Succeeded in loading content');
    });
  }

  onWindowStageDestroy(): void {
    console.info('[EntryAbility] onWindowStageDestroy');
  }

  onForeground(): void {
    console.info('[EntryAbility] onForeground');
    PollingController.resumeAll();
    this.syncSystemTheme(this.context?.config?.colorMode);
    void ThemeUtil.applyStoredTheme();
  }

  onBackground(): void {
    console.info('[EntryAbility] onBackground');
    PollingController.pauseAll();
  }

  onConfigurationUpdate(config: Configuration): void {
    this.syncSystemTheme(config.colorMode);
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
