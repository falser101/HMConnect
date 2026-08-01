import { common } from '@kit.AbilityKit';

/**
 * Material 3–inspired tokens matching Android KDE Connect.
 * Colors are resource-qualified ($r('app.color.*')) so they follow the
 * app's color mode: `setColorMode(COLOR_MODE_DARK)` → resources/dark palette,
 * COLOR_MODE_LIGHT → base palette, NOT_SET → system.
 */
export class UiTheme {
  // Brand
  static readonly kdeBlue: Resource = $r('app.color.theme_kde_blue');
  static readonly primary: Resource = $r('app.color.theme_primary');
  static readonly onPrimary: Resource = $r('app.color.theme_on_primary');
  static readonly primaryContainer: Resource = $r('app.color.theme_primary_container');
  static readonly onPrimaryContainer: Resource = $r('app.color.theme_on_primary_container');

  // Surfaces
  static readonly pageBg: Resource = $r('app.color.theme_page_bg');
  static readonly surface: Resource = $r('app.color.theme_surface');
  static readonly surfaceVariant: Resource = $r('app.color.theme_surface_variant');
  static readonly cardBg: Resource = $r('app.color.theme_card_bg');
  static readonly cardElevated: Resource = $r('app.color.theme_card_elevated');
  static readonly sidebarBg: Resource = $r('app.color.theme_sidebar_bg');
  static readonly divider: Resource = $r('app.color.theme_divider');
  static readonly scrim: Resource = $r('app.color.theme_scrim');
  static readonly ripple: Resource = $r('app.color.theme_ripple');

  // Text
  static readonly onSurface: Resource = $r('app.color.theme_on_surface');
  static readonly onSurfaceVariant: Resource = $r('app.color.theme_on_surface_variant');
  static readonly outline: Resource = $r('app.color.theme_outline');
  static readonly textMuted: Resource = $r('app.color.theme_text_muted');

  // Semantic
  static readonly danger: Resource = $r('app.color.theme_danger');
  static readonly error: Resource = $r('app.color.theme_error');
  static readonly success: Resource = $r('app.color.theme_success');
  static readonly findPhone: Resource = $r('app.color.theme_find_phone');
  static readonly findPhoneDark: Resource = $r('app.color.theme_find_phone_dark');

  // Icon
  static readonly iconTint: Resource = $r('app.color.theme_icon_tint');
  static readonly iconOnSurface: Resource = $r('app.color.theme_icon_on_surface');

  // Elevation / radius (Material 3 card)
  static readonly radiusCard: number = 12;
  static readonly radiusButton: number = 24;
  static readonly radiusChip: number = 8;
  static readonly radiusFull: number = 999;
  static readonly cardMargin: number = 4;
  static readonly pageHPad: number = 12;
  static readonly sectionPadTop: number = 16;
  static readonly sectionPadH: number = 16;
  static readonly listItemMinH: number = 56;
  static readonly toolbarH: number = 56;
  static readonly iconSize: number = 24;
  static readonly deviceIconSize: number = 32;
  static readonly pluginIconSize: number = 28;

  // Motion (Material standard)
  static readonly durationShort: number = 150;
  static readonly durationMedium: number = 250;
  static readonly durationLong: number = 350;
  static readonly durationDrawer: number = 280;
  static readonly durationRefresh: number = 1500;

  // Typography sizes (sp ≈ vp)
  static readonly titleLg: number = 22;
  static readonly titleMd: number = 16;
  static readonly bodyLg: number = 18;
  static readonly bodyMd: number = 14;
  static readonly bodySm: number = 12;
  static readonly labelMd: number = 14;
}

/** Resolve a color resource to a '#RRGGBB' css string (for window/system-bar APIs). */
export function cssColor(ctx: common.Context, res: Resource): string {
  try {
    const v: number = ctx.resourceManager.getColorSync(res.id);
    const rgb: string = (v & 0xFFFFFF).toString(16).padStart(6, '0');
    return `#${rgb}`;
  } catch (_e) {
    return '#000000';
  }
}
