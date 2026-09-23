import { ConfigurationConstant } from '@kit.AbilityKit';

export type MainTabKey = 'home' | 'history' | 'settings';
export type StatusTone = 'neutral' | 'success' | 'danger';
export type ClipboardPreviewMode = 'text' | 'image';
export type ResolvedThemeVariant = 'light' | 'dark' | 'black';

export interface MainTabSpec {
  key: MainTabKey;
  label: string;
}

export interface SettingsSectionSpec {
  key: 'server' | 'preferences';
  title: string;
  description: string;
  rowCount: number;
}

export interface BottomTabLayoutSpec {
  barHeight: number;
  itemHeight: number;
  iconSize: number;
  labelTopMargin: number;
  usesSelectedBackground: boolean;
  usesSystemSafeAreaExpansion: boolean;
  usesExternalBottomBar: boolean;
  safeAreaFollowsBarSurface: boolean;
  rootOwnsBottomSafeArea: boolean;
  isFloating: boolean;
}

export interface SystemSafeAreaInsets {
  top: number;
  bottom: number;
}

export interface WindowChromeSpec {
  usesFullscreenLayout: boolean;
  usesTransparentSystemBars: boolean;
  managesNavigationBar: boolean;
}

export interface HistoryListStyleSpec {
  usesSubtitle: boolean;
  usesDivider: boolean;
  metaLines: number;
  previewHeight: number;
  showsCopyLabel: boolean;
  sideInset: number;
}

export interface AutoSyncIndicatorSpec {
  label: string;
  tone: StatusTone;
}

export interface ActionButtonSpec {
  controlSize: 'small' | 'normal';
  fullWidth: boolean;
}

export interface HistoryActionFeedbackSpec {
  mode: 'toast';
  message: string;
  duration: number;
}

export function getMainTabSpecs(): MainTabSpec[] {
  return [
    { key: 'home', label: 'Home' },
    { key: 'history', label: 'History' },
    { key: 'settings', label: 'Settings' }
  ];
}

export function getSyncStatusTone(status: string): StatusTone {
  if (status.includes('Error') || status.includes('failed')) {
    return 'danger';
  }

  if (status.includes('Success') || status.includes('updated')) {
    return 'success';
  }

  return 'neutral';
}

export function getSettingsSectionSpecs(): SettingsSectionSpec[] {
  return [
    {
      key: 'server',
      title: 'Server Connection',
      description: 'Connect to your SyncClipboard server.',
      rowCount: 3
    },
    {
      key: 'preferences',
      title: 'Preferences',
      description: 'Choose how ClipLink looks and syncs.',
      rowCount: 5
    }
  ];
}

export function getResolvedThemeVariant(
  appTheme: 'light' | 'dark' | 'auto',
  systemColorMode: number,
  preferPureBlackInDark: boolean
): ResolvedThemeVariant {
  if (appTheme === 'light') {
    return 'light';
  }

  const followsDarkAppearance =
    appTheme === 'dark' ||
    systemColorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;

  if (!followsDarkAppearance) {
    return 'light';
  }

  return preferPureBlackInDark ? 'black' : 'dark';
}

export function getBottomTabLayoutSpec(): BottomTabLayoutSpec {
  return {
    barHeight: 68,
    itemHeight: 54,
    iconSize: 24,
    labelTopMargin: 4,
    usesSelectedBackground: true,
    usesSystemSafeAreaExpansion: false,
    usesExternalBottomBar: false,
    safeAreaFollowsBarSurface: true,
    rootOwnsBottomSafeArea: true,
    isFloating: true
  };
}

export function getSystemSafeAreaInsets(topInset: number, bottomInset: number): SystemSafeAreaInsets {
  return {
    top: topInset > 0 ? topInset : 0,
    bottom: bottomInset > 0 ? bottomInset : 0
  };
}

export function getWindowChromeSpec(): WindowChromeSpec {
  return {
    usesFullscreenLayout: true,
    usesTransparentSystemBars: true,
    managesNavigationBar: false
  };
}

export function getClipboardPreviewMode(summary: string): ClipboardPreviewMode {
  return summary.includes('[Image') ? 'image' : 'text';
}

export function getHistoryListStyleSpec(): HistoryListStyleSpec {
  return {
    usesSubtitle: false,
    usesDivider: false,
    metaLines: 1,
    previewHeight: 132,
    showsCopyLabel: false,
    sideInset: 0
  };
}

export function getAutoSyncIndicatorSpec(isActive: boolean): AutoSyncIndicatorSpec {
  return {
    label: 'Auto Sync',
    tone: isActive ? 'success' : 'neutral'
  };
}

export function getActionButtonSpec(kind: 'home-primary' | 'home-secondary' | 'settings-save'): ActionButtonSpec {
  switch (kind) {
    case 'settings-save':
      return { controlSize: 'small', fullWidth: false };
    default:
      return { controlSize: 'small', fullWidth: false };
  }
}

export function getCardEffectMode(isDark: boolean): 'none' | 'subtle' {
  return isDark ? 'none' : 'subtle';
}

export function getHistoryActionFeedback(
  action: 'copy-text' | 'copy-image' | 'save-image',
  success: boolean
): HistoryActionFeedbackSpec {
  if (action === 'save-image') {
    return {
      mode: 'toast',
      message: success ? 'Image saved' : 'Image download failed',
      duration: 1800
    };
  }

  return {
    mode: 'toast',
    message: success ? 'Copied to clipboard' : 'Copy failed',
    duration: 1600
  };
}
