import { hdsEffect } from '@kit.UIDesignKit';

export class InteractionEffectUtil {
  static button(pressed: boolean, available: boolean): VisualEffect | undefined {
    if (!available) return undefined;
    return new hdsEffect.HdsEffectBuilder()
      .pressShadow(pressed ? hdsEffect.PressShadowType.BLEND_WHITE : hdsEffect.PressShadowType.NONE)
      .pointLight({
        sourceType: pressed ? hdsEffect.PointLightSourceType.SOFT : hdsEffect.PointLightSourceType.NONE,
        illuminatedType: hdsEffect.PointLightIlluminatedType.DEFAULT_FEATHERING_BORDER
      })
      .buildEffect();
  }

  static card(available: boolean): VisualEffect | undefined {
    if (!available) return undefined;
    return new hdsEffect.HdsEffectBuilder()
      .pointLight({
        illuminatedType: hdsEffect.PointLightIlluminatedType.DEFAULT_FEATHERING_BORDER
      })
      .buildEffect();
  }
}
