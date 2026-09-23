import HomePage from './HomePage';
import HistoryPage from './HistoryPage';
import SettingsPage from './SettingsPage';
import { ConfigurationConstant } from '@kit.AbilityKit';
import { HdsTabs, hdsMaterial } from '@kit.UIDesignKit';
import { ThemeUtil, ThemePalette } from '../utils/ThemeUtil';
import { LocalizationUtil } from '../utils/LocalizationUtil';
import { InteractionEffectUtil } from '../utils/InteractionEffectUtil';
import {
  getBottomTabLayoutSpec,
  getMainTabSpecs,
  MainTabSpec
} from '../utils/PageScaffoldUtil';

@Entry
@Component
struct Index {
  @State currentTabIndex: number = 0;
  @State pressedTab: string = '';
  @State useHdsEffects: boolean = false;
  @StorageLink('appTheme') appTheme: string = 'auto';
  @StorageLink('appLanguage') appLanguage: string = 'system';
  @StorageLink('systemLanguage') systemLanguage: string = 'en';
  @StorageLink('floatingTabsEnabled') supportsFloatingTabs: boolean = false;
  @StorageLink('preferPureBlackInDark') preferPureBlackInDark: boolean = false;
  @StorageLink('systemColorMode') systemColorMode: number =
    ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET;
  @State private supportsImmersiveMaterial: boolean = false;
  @State private supportsAdaptiveMaterial: boolean = false;
  private readonly tabs: MainTabSpec[] = getMainTabSpecs();
  private readonly tabLayout = getBottomTabLayoutSpec();

  aboutToAppear(): void {
    this.useHdsEffects = canIUse('SystemCapability.UIDesign.HDSComponent.Core');
    if (!this.supportsFloatingTabs) {
      return;
    }
    try {
      const materialTypes: Array<hdsMaterial.MaterialType> = hdsMaterial.getSystemMaterialTypes();
      this.supportsImmersiveMaterial =
        materialTypes.indexOf(hdsMaterial.MaterialType.IMMERSIVE) >= 0;
      this.supportsAdaptiveMaterial =
        materialTypes.indexOf(hdsMaterial.MaterialType.ADAPTIVE) >= 0;
    } catch (error) {
      console.warn('[Index] Unable to query supported material types');
    }
  }

  private t(value: string): string {
    return LocalizationUtil.text(value, this.appLanguage, this.systemLanguage);
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
    .visualEffect(InteractionEffectUtil.button(this.pressedTab === tab.key, this.useHdsEffects))
    .onTouch((event: TouchEvent) => {
      if (event.type === TouchType.Down) {
        this.pressedTab = tab.key;
      } else if ((event.type === TouchType.Up || event.type === TouchType.Cancel) &&
        this.pressedTab === tab.key) {
        this.pressedTab = '';
      }
    })
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
        barWidth: { smallWidth: 280, mediumWidth: 360, largeWidth: 432 },
        barBottomMargin: 16,
        adaptToHandedness: true,
        gradientMask: { maskColor: this.getPalette().isDark ? '#9911141A' : '#99F4F6F9', maskHeight: 112 },
        lightColor: this.getPalette().accent,
        systemMaterialEffect: {
          materialType: this.supportsImmersiveMaterial
            ? hdsMaterial.MaterialType.IMMERSIVE
            : this.supportsAdaptiveMaterial
              ? hdsMaterial.MaterialType.ADAPTIVE
              : hdsMaterial.MaterialType.NONE,
          materialLevel: this.supportsImmersiveMaterial
            ? hdsMaterial.MaterialLevel.EXQUISITE
            : hdsMaterial.MaterialLevel.SMOOTH
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
