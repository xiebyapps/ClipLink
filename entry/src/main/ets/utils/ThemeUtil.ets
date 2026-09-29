import window from '@ohos.window';
import { ConfigurationConstant } from '@kit.AbilityKit';
import { getResolvedThemeVariant, getWindowChromeSpec, ResolvedThemeVariant } from './PageScaffoldUtil';

export interface ThemePalette {
  isDark: boolean;
  pageBackground: string;
  pageSurface: string;
  navigationSurface: string;
  heroStart: string;
  heroEnd: string;
  cardBackground: string;
  elevatedBackground: string;
  inputBackground: string;
  borderColor: string;
  shadowColor: string;
  textPrimary: string;
  textSecondary: string;
  textMuted: string;
  accent: string;
  accentSoft: string;
  buttonPrimaryBackground: string;
  buttonPrimaryText: string;
  buttonSecondaryBackground: string;
  buttonSecondaryText: string;
  buttonDangerBackground: string;
  buttonDangerText: string;
  success: string;
  successSurface: string;
  successBorder: string;
  danger: string;
}

export class ThemeUtil {
  static getResolvedThemeVariant(
    appTheme: 'light' | 'dark' | 'auto',
    systemColorMode: number,
    preferPureBlackInDark: boolean
  ): ResolvedThemeVariant {
    return getResolvedThemeVariant(appTheme, systemColorMode, preferPureBlackInDark);
  }

  static isDarkTheme(
    appTheme: 'light' | 'dark' | 'auto',
    systemColorMode: number,
    preferPureBlackInDark: boolean = false
  ): boolean {
    return ThemeUtil.getResolvedThemeVariant(appTheme, systemColorMode, preferPureBlackInDark) !== 'light';
  }

  static getPalette(
    appTheme: 'light' | 'dark' | 'auto',
    systemColorMode: number,
    preferPureBlackInDark: boolean = false
  ): ThemePalette {
    const resolvedTheme = ThemeUtil.getResolvedThemeVariant(
      appTheme,
      systemColorMode,
      preferPureBlackInDark
    );

    return resolvedTheme === 'black'
      ? {
          isDark: true,
          pageBackground: '#000000',
          pageSurface: '#000000',
          navigationSurface: '#E6000000',
          heroStart: '#101A2A',
          heroEnd: '#06090F',
          cardBackground: '#060606',
          elevatedBackground: '#111318',
          inputBackground: '#15171C',
          borderColor: '#242830',
          shadowColor: '#00000000',
          textPrimary: '#FAFAFA',
          textSecondary: '#CACACA',
          textMuted: '#8A8A8A',
          accent: '#83B7FF',
          accentSoft: '#172A46',
          buttonPrimaryBackground: '#83B7FF',
          buttonPrimaryText: '#05070B',
          buttonSecondaryBackground: '#20242D',
          buttonSecondaryText: '#F3F3F3',
          buttonDangerBackground: '#A63C4A',
          buttonDangerText: '#FFF5F7',
          success: '#58D07B',
          successSurface: '#0E2B1A',
          successBorder: '#287746',
          danger: '#FF7D8A'
        }
      : resolvedTheme === 'dark'
        ? {
          isDark: true,
          pageBackground: '#11141A',
          pageSurface: '#1C2028',
          navigationSurface: '#E51C2028',
          heroStart: '#243A59',
          heroEnd: '#1C2028',
          cardBackground: '#222731',
          elevatedBackground: '#292F3B',
          inputBackground: '#2A303B',
          borderColor: '#383F4D',
          shadowColor: '#00000040',
          textPrimary: '#F6F7FA',
          textSecondary: '#C2C8D2',
          textMuted: '#929CAA',
          accent: '#88B9FF',
          accentSoft: '#273E5D',
          buttonPrimaryBackground: '#88B9FF',
          buttonPrimaryText: '#08111F',
          buttonSecondaryBackground: '#303744',
          buttonSecondaryText: '#E6EDF7',
          buttonDangerBackground: '#A63C4A',
          buttonDangerText: '#FFF5F7',
          success: '#4ECF7A',
          successSurface: '#183B29',
          successBorder: '#347C50',
          danger: '#FF7D8A'
        }
      : {
          isDark: false,
          pageBackground: '#F4F6F9',
          pageSurface: '#FFFFFF',
          navigationSurface: '#EDFFFFFF',
          heroStart: '#E7F1FF',
          heroEnd: '#FFFFFF',
          cardBackground: '#FFFFFF',
          elevatedBackground: '#F5F7FB',
          inputBackground: '#F5F7FB',
          borderColor: '#E6EAF0',
          shadowColor: '#20395C14',
          textPrimary: '#18212F',
          textSecondary: '#596677',
          textMuted: '#8290A0',
          accent: '#166AE8',
          accentSoft: '#E8F1FF',
          buttonPrimaryBackground: '#166AE8',
          buttonPrimaryText: '#FFFFFF',
          buttonSecondaryBackground: '#F0F3F8',
          buttonSecondaryText: '#26374F',
          buttonDangerBackground: '#E64D4F',
          buttonDangerText: '#FFFFFF',
          success: '#00A65A',
          successSurface: '#E4F6E9',
          successBorder: '#80D49D',
           danger: '#D93838'
         };
  }

  static async applyTheme(
    appTheme: 'light' | 'dark' | 'auto',
    systemColorMode: number,
    preferPureBlackInDark: boolean = false
  ): Promise<void> {
    const windowStage = AppStorage.get<window.WindowStage>('mainWindowStage');
    if (!windowStage) {
      return;
    }
    const palette = ThemeUtil.getPalette(appTheme, systemColorMode, preferPureBlackInDark);
    const systemBarContentColor = palette.isDark ? '#FFFFFF' : '#000000';
    const windowChrome = getWindowChromeSpec();
    try {
      const mainWindow = windowStage.getMainWindowSync();
      mainWindow.setWindowBackgroundColor(palette.pageBackground);
      await mainWindow.setWindowLayoutFullScreen(windowChrome.usesFullscreenLayout);
      if (windowChrome.managesNavigationBar) {
        await mainWindow.setWindowSystemBarEnable(['status', 'navigation']);
        await mainWindow.setWindowSystemBarProperties({
          statusBarColor: windowChrome.usesTransparentSystemBars ? '#00000000' : palette.pageBackground,
          navigationBarColor: windowChrome.usesTransparentSystemBars ? '#00000000' : palette.pageSurface,
          statusBarContentColor: systemBarContentColor,
          navigationBarContentColor: systemBarContentColor
        });
      } else {
        await mainWindow.setWindowSystemBarEnable(['status']);
        await mainWindow.setWindowSystemBarProperties({
          statusBarColor: windowChrome.usesTransparentSystemBars ? '#00000000' : palette.pageBackground,
          statusBarContentColor: systemBarContentColor
        });
      }
    } catch (error) {
      console.error('[ThemeUtil] applyTheme error:', JSON.stringify(error));
    }
  }

  static async applyStoredTheme(): Promise<void> {
    const appTheme = (AppStorage.get<string>('appTheme') ?? 'auto') as 'light' | 'dark' | 'auto';
    const systemColorMode =
      AppStorage.get<number>('systemColorMode') ??
      ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET;
    const preferPureBlackInDark = AppStorage.get<boolean>('preferPureBlackInDark') ?? false;
    await ThemeUtil.applyTheme(appTheme, systemColorMode, preferPureBlackInDark);
  }
}
