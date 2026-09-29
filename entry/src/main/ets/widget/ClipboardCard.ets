@Entry
@Component
struct ClipboardCard {
  @LocalStorageProp('formId') @Watch('identityUpdated') formId: string = '';
  @LocalStorageProp('formDimension') formDimension: number = 2;
  @LocalStorageProp('localVisible') @Watch('visibilityUpdated') localVisible: boolean = false;
  @LocalStorageProp('remoteVisible') @Watch('visibilityUpdated') remoteVisible: boolean = false;
  @LocalStorageProp('localToken') @Watch('visibilityUpdated') localToken: string = '';
  @LocalStorageProp('remoteToken') @Watch('visibilityUpdated') remoteToken: string = '';
  @LocalStorageProp('localExpiresAt') @Watch('visibilityUpdated') localExpiresAt: number = 0;
  @LocalStorageProp('remoteExpiresAt') @Watch('visibilityUpdated') remoteExpiresAt: number = 0;
  @LocalStorageProp('localContent') localContent: string = '';
  @LocalStorageProp('remoteContent') remoteContent: string = '';
  @LocalStorageProp('localTime') localTime: string = '';
  @LocalStorageProp('remoteTime') remoteTime: string = '';
  @LocalStorageProp('fallbackSide') fallbackSide: string = '';
  @LocalStorageProp('fallbackToken') fallbackToken: string = '';
  @LocalStorageProp('uploadLabel') uploadLabel: string = '';
  @LocalStorageProp('syncLabel') syncLabel: string = '';
  @LocalStorageProp('uploadActionLabel') uploadActionLabel: string = '';
  @LocalStorageProp('syncActionLabel') syncActionLabel: string = '';
  @LocalStorageProp('localLabel') localLabel: string = '';
  @LocalStorageProp('remoteLabel') remoteLabel: string = '';
  @LocalStorageProp('hiddenLabel') hiddenLabel: string = '';
  @LocalStorageProp('hideLabel') hideLabel: string = '';
  @LocalStorageProp('surface') surface: string = '';
  @LocalStorageProp('button') button: string = '';
  @LocalStorageProp('textColor') textColor: string = '';
  @LocalStorageProp('secondary') secondary: string = '';
  @LocalStorageProp('accent') accent: string = '';
  @LocalStorageProp('actionStatus') actionStatus: string = '';
  @LocalStorageProp('openRequestId') @Watch('openRequestUpdated') openRequestId: string = '';
  @LocalStorageProp('completedRequestId') @Watch('requestCompleted') completedRequestId: string = '';
  @LocalStorageProp('openLabel') openLabel: string = '';


  @State identityMissing: boolean = false;
  private identityUpdated(): void { if (this.formId) this.identityMissing = false; }

  private call(action: string): void {
    if (!this.formId) {
      this.identityMissing = true;
      // The message callback receives the authoritative ID from the host, even for an old card without binding data.
      postCardAction(this, { action: 'message', params: { refresh: true } });
      return;
    }
    if (action === 'sync' && this.pendingSyncId && Date.now() <= this.pendingSyncUntil) return;
    const id = `${Date.now()}-${Math.random().toString(36).slice(2)}`;
    if (action === 'sync') { this.pendingSyncId = id; this.pendingSyncUntil = Date.now() + 30000; }
    postCardAction(this, { action: 'call', moduleName: 'entry', abilityName: 'ClipboardActionAbility',
      params: { method: 'perform', desktopAction: action, formId: this.formId, requestId: id } });
  }
  private openPanel(): void {
    postCardAction(this, { action: 'router', moduleName: 'entry', abilityName: 'ClipboardActionAbility',
      params: { actionWindow: 'panel', formId: this.formId, requestId: this.openRequestId } });
  }

  // Only the file result of this card's current click can open a window.
  private pendingSyncId: string = '';
  private pendingSyncUntil: number = 0;
  private openRequestUpdated(): void {
    if (!this.openRequestId || this.openRequestId !== this.pendingSyncId) return;
    const current = Date.now() <= this.pendingSyncUntil;
    this.pendingSyncId = ''; this.pendingSyncUntil = 0;
    if (current) this.openPanel();
  }

  private requestCompleted(): void {
    if (this.completedRequestId !== this.pendingSyncId) return;
    this.openRequestUpdated();
    this.pendingSyncId = ''; this.pendingSyncUntil = 0;
  }

  @State localExpired: boolean = false;
  @State remoteExpired: boolean = false;
  private expiryClock: TextTimerController = new TextTimerController();
  aboutToAppear(): void { this.visibilityUpdated(); }
  aboutToDisappear(): void {
    this.expiryClock.pause();
    this.pendingSyncId = ''; this.pendingSyncUntil = 0;
  }
  private visibilityUpdated(): void {
    this.localExpired = false; this.remoteExpired = false;
    this.expiryTick();
  }
  private isShown(local: boolean): boolean {
    return local ? this.localVisible && !this.localExpired : this.remoteVisible && !this.remoteExpired;
  }
  private expiryTick(): void { this.expireSide(true); this.expireSide(false); }
  private expireSide(local: boolean): void {
    const visible = local ? this.localVisible : this.remoteVisible;
    const expired = local ? this.localExpired : this.remoteExpired;
    const expires = local ? this.localExpiresAt : this.remoteExpiresAt;
    const token = local ? this.localToken : this.remoteToken;
    if (!visible || expired || !expires || !token || Date.now() < expires) return;
    if (local) this.localExpired = true; else this.remoteExpired = true;
    postCardAction(this, { action: 'message', params: { side: local ? 'local' : 'remote', hide: true, token } });
  }

  @Builder
  private actionButton(upload: boolean) {
    Button() {
      if (this.formDimension === 1) {
        Row({ space: 6 }) {
          Image(upload ? $r('app.media.widget_upload') : $r('app.media.widget_sync'))
            .width(24).height(24).fillColor(this.textColor || $r('app.color.widget_text'))
          Text(upload ? (this.uploadLabel || $r('app.string.widget_upload')) :
            (this.syncLabel || $r('app.string.widget_sync')))
            .fontSize(13).fontWeight(FontWeight.Medium).minFontSize(10).maxFontSize(13)
            .maxLines(1).fontColor(this.textColor || $r('app.color.widget_text'))
        }.width('100%').height('100%').padding({ left: 6, right: 6 }).justifyContent(FlexAlign.Center)
      } else {
        Column({ space: 10 }) {
          Image(upload ? $r('app.media.widget_upload') : $r('app.media.widget_sync'))
            .width(28).height(28)
            .fillColor(this.textColor || $r('app.color.widget_text'))
          Text(upload ? (this.uploadLabel || $r('app.string.widget_upload')) :
            (this.syncLabel || $r('app.string.widget_sync')))
            .fontSize(14).fontWeight(FontWeight.Medium)
            .minFontSize(10).maxFontSize(14).maxLines(1).textAlign(TextAlign.Center)
            .fontColor(this.textColor || $r('app.color.widget_text'))
        }.width('100%').height('100%').justifyContent(FlexAlign.Center)
      }
    }.type(ButtonType.Normal).borderRadius(14).layoutWeight(1).height('100%')
      .backgroundColor(this.button || $r('app.color.widget_button'))
      .accessibilityText(upload ? (this.uploadActionLabel || 'Upload clipboard') :
        (this.syncActionLabel || 'Sync clipboard'))
      .onClick(() => { this.call(upload ? 'upload' : 'sync'); })
  }

  @Builder
  private contentArea(local: boolean) {
    Column({ space: 4 }) {
      Text(local ? (this.localLabel || $r('app.string.widget_local')) :
        (this.remoteLabel || $r('app.string.widget_remote')))
        .fontSize(12).fontWeight(FontWeight.Medium).fontColor(this.textColor || $r('app.color.widget_text'))
      Text(this.isShown(local) ?
        (local ? this.localContent : this.remoteContent) : (this.hiddenLabel || $r('app.string.widget_hidden')))
        .fontSize(12).maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
        .fontColor(this.secondary || $r('app.color.widget_secondary'))
      if (this.isShown(local)) {
        Text(local ? this.localTime : this.remoteTime).fontSize(10)
          .fontColor(this.secondary || $r('app.color.widget_secondary')).maxLines(1)
      }
    }.alignItems(HorizontalAlign.Start).width('100%').layoutWeight(1).padding(10).borderRadius(12)
      .backgroundColor(this.button || $r('app.color.widget_button'))
      .onClick(() => {
        if (this.isShown(local)) {
          postCardAction(this, { action: 'message', params: { side: local ? 'local' : 'remote', hide: true } });
        } else this.call(local ? 'showLocal' : 'showRemote');
      })
  }

  build() {
    Column({ space: 4 }) {
      if (this.formDimension === 3) {
        // Native form timer: no JS timers or background keepalive are required.
        TextTimer({ isCountDown: false, controller: this.expiryClock }).format('ss')
          .width(0).height(0).opacity(0)
          .onTimer(() => { this.expiryTick(); })
          .onAppear(() => { this.expiryTick(); this.expiryClock.start(); })
          .onDisAppear(() => { this.expiryClock.pause(); })
      }
      Row({ space: 8 }) {
      Row({ space: 8 }) {
        this.actionButton(true)
        this.actionButton(false)
      }.height('100%').width(this.formDimension === 3 ? '46%' : '100%')
      if (this.formDimension === 3) {
        Column({ space: 6 }) {
          this.contentArea(true)
          this.contentArea(false)
        }.height('100%').layoutWeight(1)
      }
      }.width('100%').layoutWeight(1)
      if (this.identityMissing) {
        Text($r('app.string.widget_refresh_required')).fontSize(10).maxLines(2)
          .fontColor(this.secondary || $r('app.color.widget_secondary'))
      } else if (this.openRequestId) {
        Text(this.openLabel).fontSize(10).maxLines(2)
          .fontColor(this.accent || $r('app.color.widget_accent'))
          .accessibilityText(this.openLabel).onClick(() => { this.openPanel(); })
      } else if (this.actionStatus) {
        Text(this.actionStatus).fontSize(10).maxLines(1).fontColor(this.secondary || $r('app.color.widget_secondary'))
      }
    }.width('100%').height('100%').padding(10).borderRadius(20)
      .backgroundColor(this.surface || $r('app.color.widget_surface'))
  }
}
