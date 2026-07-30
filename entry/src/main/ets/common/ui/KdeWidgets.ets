import { UiTheme } from './UiTheme';
import { KdeIcon, KdeIconRes } from './KdeIcons';

/**
 * Shared widgets aligning with Android KDE Connect Material 3 UI.
 * Icons use HarmonyOS system SymbolGlyph.
 */

@Component
export struct KdeTopBar {
  /** Status-bar inset (vp) from ImmersiveUtil — pads toolbar under transparent system bar. */
  @StorageProp('statusBarHeight') statusBarHeight: number = 0;
  @Prop title: ResourceStr = '';
  @Prop subtitle: ResourceStr = '';
  @Prop showBack: boolean = false;
  @Prop showMenu: boolean = false;
  @Prop showRefresh: boolean = false;
  @Prop showOverflow: boolean = false;
  @Prop refreshing: boolean = false;
  onBack: () => void = () => {
  };
  onMenu: () => void = () => {
  };
  onRefresh: () => void = () => {
  };
  onOverflow: () => void = () => {
  };

  private subtitleNotEmpty(): boolean {
    if (typeof this.subtitle === 'string') {
      return this.subtitle.length > 0;
    }
    return typeof this.subtitle === 'object' && this.subtitle !== null;
  }

  build() {
    // One continuous surface: status-bar region + toolbar (no separate spacer strip).
    Column() {
      Row() {
        if (this.showMenu) {
          Column() {
            KdeIcon({ symbol: KdeIconRes.menu(), iconSize: 24, color: UiTheme.iconOnSurface })
          }
          .width(48)
          .height(48)
          .justifyContent(FlexAlign.Center)
          .borderRadius(24)
          .onClick(() => {
            this.onMenu();
          })
        }

        if (this.showBack) {
          Column() {
            KdeIcon({ symbol: KdeIconRes.arrowBack(), iconSize: 24, color: UiTheme.onSurface })
          }
          .width(48)
          .height(48)
          .justifyContent(FlexAlign.Center)
          .borderRadius(24)
          .onClick(() => {
            this.onBack();
          })
        }

        Column() {
          Text(this.title)
            .fontSize(this.subtitleNotEmpty() ? 18 : 20)
            .fontWeight(FontWeight.Medium)
            .fontColor(UiTheme.onSurface)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
          if (this.subtitleNotEmpty()) {
            Text(this.subtitle)
              .fontSize(13)
              .fontColor(UiTheme.onSurfaceVariant)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .margin({ top: 2 })
              .width('100%')
          }
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        .margin({ left: 4, right: 4 })

        if (this.showRefresh) {
          Column() {
            KdeIcon({ symbol: KdeIconRes.refresh(), iconSize: 24, color: UiTheme.iconTint })
          }
          .width(48)
          .height(48)
          .justifyContent(FlexAlign.Center)
          .borderRadius(24)
          .rotate({ angle: this.refreshing ? 360 : 0 })
          .animation({
            duration: this.refreshing ? 900 : 0,
            iterations: this.refreshing ? -1 : 1,
            curve: Curve.Linear
          })
          .onClick(() => {
            this.onRefresh();
          })
        }

        if (this.showOverflow) {
          Column() {
            KdeIcon({ symbol: KdeIconRes.moreVert(), iconSize: 24, color: UiTheme.iconTint })
          }
          .width(48)
          .height(48)
          .justifyContent(FlexAlign.Center)
          .borderRadius(24)
          .onClick(() => {
            this.onOverflow();
          })
        }
      }
      .width('100%')
      .height(UiTheme.toolbarH)
      .padding({ left: 4, right: 4 })
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .padding({ top: this.statusBarHeight })
    .backgroundColor(UiTheme.surface)
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP])
  }
}

@Component
export struct KdeSectionHeader {
  @Prop title: string = '';

  build() {
    Text(this.title)
      .fontSize(UiTheme.titleMd)
      .fontWeight(FontWeight.Medium)
      .fontColor(UiTheme.onSurfaceVariant)
      .width('100%')
      .padding({
        left: UiTheme.sectionPadH,
        right: UiTheme.sectionPadH,
        top: UiTheme.sectionPadTop,
        bottom: 4
      })
  }
}

@Component
export struct KdeDeviceCard {
  @Prop name: string = '';
  @Prop deviceType: string = 'laptop';
  @Prop summary: ResourceStr = '';
  @Prop deviceId: string = '';
  onOpen: () => void = () => {
  };

  private summaryNotEmpty(): boolean {
    if (typeof this.summary === 'string') {
      return this.summary.length > 0;
    }
    return typeof this.summary === 'object' && this.summary !== null;
  }

  build() {
    Row() {
      KdeIcon({
        symbol: KdeIconRes.forDeviceType(this.deviceType),
        iconSize: UiTheme.deviceIconSize,
        color: UiTheme.iconTint
      })
        .margin({ left: 12, right: 8 })

      Column() {
        Text(this.name)
          .fontSize(UiTheme.bodyLg)
          .fontWeight(FontWeight.Medium)
          .fontColor(UiTheme.onSurface)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        // Android: summary is optional warning only (red #CC2222), not connection state
        if (this.summaryNotEmpty()) {
          Text(this.summary)
            .fontSize(14)
            .fontColor(UiTheme.danger)
            .maxLines(1)
            .margin({ top: 2 })
            .width('100%')
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      .padding({ right: 16 })
    }
    .width('100%')
    .constraintSize({ minHeight: UiTheme.listItemMinH })
    .padding({ top: 14, bottom: 14 })
    .backgroundColor(UiTheme.cardBg)
    .borderRadius(UiTheme.radiusCard)
    .margin({
      left: UiTheme.cardMargin,
      right: UiTheme.cardMargin,
      top: UiTheme.cardMargin,
      bottom: UiTheme.cardMargin
    })
    // No scale/shadow animation on press — those leave a residual overlay after navigation.
    .onClick(() => {
      this.onOpen();
    })
  }
}

@Component
export struct KdePrimaryButton {
  @Prop label: ResourceStr = '';
  /** Avoid naming `enabled` — conflicts with CustomComponent.enabled(). */
  @Prop isEnabled: boolean = true;
  @Prop tonal: boolean = false;
  onTap: () => void = () => {
  };

  build() {
    Button(this.label)
      .width('100%')
      .height(48)
      .fontSize(15)
      .fontWeight(FontWeight.Medium)
      .fontColor(this.tonal ? UiTheme.onPrimaryContainer : UiTheme.onPrimary)
      .backgroundColor(this.tonal ? UiTheme.primaryContainer : UiTheme.primary)
      .borderRadius(UiTheme.radiusButton)
      .enabled(this.isEnabled)
      .opacity(this.isEnabled ? 1 : 0.5)
      .onClick(() => {
        if (this.isEnabled) {
          this.onTap();
        }
      })
  }
}

@Component
export struct KdePluginTile {
  @Prop title: string = '';
  @Prop symbol: Resource = $r('sys.symbol.dot_radiowaves_left_and_right');
  onTap: () => void = () => {
  };

  build() {
    Column() {
      KdeIcon({
        symbol: this.symbol,
        iconSize: UiTheme.pluginIconSize,
        color: UiTheme.iconTint
      })
        .margin({ top: 12 })

      Text(this.title)
        .fontSize(UiTheme.bodyLg)
        .fontColor(UiTheme.onSurface)
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .height(44)
        .width('100%')
        .textAlign(TextAlign.Start)
        .margin({ top: 10 })
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 10, bottom: 10 })
    .backgroundColor(UiTheme.cardBg)
    .borderRadius(UiTheme.radiusCard)
    .shadow({
      radius: 2,
      color: '#1A000000',
      offsetX: 0,
      offsetY: 1
    })
    .alignItems(HorizontalAlign.Start)
    .onClick(() => {
      this.onTap();
    })
  }
}

@Component
export struct KdeNavRow {
  @Prop label: string = '';
  @Prop symbol: Resource = $r('sys.symbol.info_circle');
  @Prop selected: boolean = false;
  onTap: () => void = () => {
  };

  build() {
    // No horizontal margin on width-100% rows (would overflow drawer).
    // Parent drawer provides horizontal padding.
    Row() {
      KdeIcon({
        symbol: this.symbol,
        iconSize: 22,
        color: this.selected ? UiTheme.primary : UiTheme.iconTint
      })

      Text(this.label)
        .fontSize(14)
        .fontWeight(this.selected ? FontWeight.Medium : FontWeight.Normal)
        .fontColor(this.selected ? UiTheme.primary : UiTheme.onSurface)
        .margin({ left: 12 })
        .layoutWeight(1)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .height(48)
    .padding({ left: 12, right: 12 })
    .backgroundColor(this.selected ? UiTheme.primaryContainer : Color.Transparent)
    .borderRadius(UiTheme.radiusFull)
    .alignItems(VerticalAlign.Center)
    .clip(true)
    .onClick(() => {
      this.onTap();
    })
  }
}

@Component
export struct KdeEmptyText {
  @Prop text: string = '无设备';

  build() {
    Text(this.text)
      .fontSize(UiTheme.bodySm)
      .fontColor(UiTheme.onSurfaceVariant)
      .width('100%')
      .textAlign(TextAlign.Center)
      .padding(10)
  }
}
