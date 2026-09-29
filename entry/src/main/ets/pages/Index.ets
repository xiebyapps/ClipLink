import { ClipboardWidgetService } from '../services/ClipboardWidgetService';
import HomePage from './HomePage';
import HistoryPage from './HistoryPage';
import SettingsPage from './SettingsPage';
import { DownloadProgressSnackBar } from '../components/DownloadProgressSnackBar';
import { DownloadNoticeService } from '../services/DownloadNoticeService';
import { ConfigurationConstant } from '@kit.AbilityKit';
import { HdsTabs, hdsMaterial } from '@kit.UIDesignKit';
import { ThemeUtil, ThemePalette } from '../utils/ThemeUtil';
import { LocalizationUtil } from '../utils/LocalizationUtil';
import {
  getBottomTabLayoutSpec,
  getMainTabSpecs,
  MainTabSpec
} from '../utils/PageScaffoldUtil';

@Entry
@Component
struct Index {
  @StorageLink('downloadNoticeRevision') @Watch('handleDownloadNoticeChange') downloadNoticeRevision: number = 0;
  private noticeOpened: boolean = false;
  private noticeController: CustomDialogController = new CustomDialogController({
    builder: DownloadProgressSnackBar(),
    alignment: DialogAlignment.Bottom,
    offset: { dx: 0, dy: -(116 + (AppStorage.get<number>('safeAreaBottom') || 0)) },
    autoCancel: false,
    customStyle: true,
    isModal: false,
    onWillDismiss: (action: DismissDialogAction): void => {
      if (!DownloadNoticeService.snapshot().visible) action.dismiss();
    }
  });
  @StorageLink('desktopActionRevision') @Watch('showDesktopHome') desktopActionRevision: number = 0;
  private showDesktopHome(): void { this.currentTabIndex = 0; }
  @State currentTabIndex: number = 0;
  @StorageLink('appTheme') @Watch('refreshCards') appTheme: string = 'auto';
  @StorageLink('appLanguage') @Watch('refreshCards') appLanguage: string = 'system';
  @StorageLink('systemLanguage') systemLanguage: string = 'en';
  @StorageLink('floatingTabsEnabled') supportsFloatingTabs: boolean = false;
  @StorageLink('preferPureBlackInDark') @Watch('refreshCards') preferPureBlackInDark: boolean = false;
  @StorageLink('systemColorMode') systemColorMode: number =
    ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET;
  private readonly tabs: MainTabSpec[] = getMainTabSpecs();
  private readonly tabLayout = getBottomTabLayoutSpec();

  private refreshCards(): void { void ClipboardWidgetService.resetAll(); }

  private t(value: string): string {
    return LocalizationUtil.text(value, this.appLanguage, this.systemLanguage);
  }

  private handleDownloadNoticeChange(): void {
    const visible = DownloadNoticeService.snapshot().visible;
    if (visible && !this.noticeOpened) {
      this.noticeOpened = true;
      this.noticeController.open();
    } else if (!visible && this.noticeOpened) {
      this.noticeOpened = false;
      this.noticeController.close();
    }
  }

  aboutToAppear(): void { this.handleDownloadNoticeChange(); }

  aboutToDisappear(): void {
    this.noticeController.close();
    this.noticeOpened = false;
  }

  private getPalette(): ThemePalette {
    return ThemeUtil.getPalette(
      this.appTheme as 'light' | 'dark' | 'auto',
      this.systemColorMode,
      this.preferPureBlackInDark
    );
  }

  private getTabIcon(key: string): Resource {
    switch (key) {
      case 'history':
        return $r('sys.symbol.clock_fill');
      case 'settings':
        return $r('sys.symbol.gearshape_fill');
      default:
        return $r('sys.symbol.house_fill');
    }
  }

  @Builder TabBuilder(tab: MainTabSpec, targetIndex: number) {
    Column({ space: 3 }) {
      SymbolGlyph(this.getTabIcon(tab.key))
        .fontSize(this.tabLayout.iconSize)
        .fontColor([
          this.currentTabIndex === targetIndex
            ? this.getPalette().accent
            : this.getPalette().textSecondary
        ])
        .fontWeight(this.currentTabIndex === targetIndex ? FontWeight.Bold : FontWeight.Medium)
      Text(this.t(tab.label))
        .margin({ top: this.tabLayout.labelTopMargin })
        .fontSize($r('sys.float.Caption_L'))
        .fontWeight(this.currentTabIndex === targetIndex ? FontWeight.Bold : FontWeight.Medium)
        .fontColor(
          this.currentTabIndex === targetIndex
            ? this.getPalette().accent
            : this.getPalette().textSecondary
        )
    }
    .width('84%')
    .height(this.tabLayout.itemHeight)
    .margin({ top: 7, bottom: 7 })
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .backgroundColor(!this.supportsFloatingTabs && this.currentTabIndex === targetIndex
      ? this.getPalette().accentSoft : Color.Transparent)
    .borderRadius(20)
  }

  build() {
    if (this.supportsFloatingTabs) {
      HdsTabs({ index: this.currentTabIndex }) {
        ForEach(this.tabs, (tab: MainTabSpec, index: number) => {
          TabContent() {
            if (tab.key === 'home') {
              HomePage()
            } else if (tab.key === 'history') {
              HistoryPage()
            } else {
              SettingsPage()
            }
          }
          .tabBar(this.TabBuilder(tab, index))
          .clip(false)
          .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP])
        }, (tab: MainTabSpec) => tab.key)
      }
      .width('100%')
      .height('100%')
      .vertical(false)
      .barPosition(BarPosition.End)
      .barHeight(this.tabLayout.barHeight)
      .barMode(BarMode.Fixed)
      .barOverlap(true)
      .barFloatingStyle({
        barBottomMargin: 16,
        adaptToHandedness: true,
        gradientMask: { maskColor: this.getPalette().isDark ? '#9911141A' : '#99F4F6F9', maskHeight: 112 },
        lightColor: this.getPalette().accent,
        systemMaterialEffect: {
          materialType: hdsMaterial.MaterialType.ADAPTIVE,
          materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE
        }
      })
      .scrollable(false)
      .clip(false)
      .backgroundColor(this.getPalette().pageBackground)
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP])
      .onChange((index: number) => {
        this.currentTabIndex = index;
      })
    } else {
      Tabs({ index: this.currentTabIndex }) {
        ForEach(this.tabs, (tab: MainTabSpec, index: number) => {
          TabContent() {
            if (tab.key === 'home') {
              HomePage()
            } else if (tab.key === 'history') {
              HistoryPage()
            } else {
              SettingsPage()
            }
          }
          .tabBar(this.TabBuilder(tab, index))
          .clip(false)
          .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP])
        }, (tab: MainTabSpec) => tab.key)
      }
      .width('100%')
      .height('100%')
      .barPosition(BarPosition.End)
      .barHeight(this.tabLayout.barHeight)
      .barBackgroundColor(this.getPalette().navigationSurface)
      .barBackgroundBlurStyle(BlurStyle.Thin)
      .barMode(BarMode.Fixed)
      .scrollable(false)
      .clip(false)
      .backgroundColor(this.getPalette().pageBackground)
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP])
      .onChange((index: number) => {
        this.currentTabIndex = index;
      })
    }
  }
}
